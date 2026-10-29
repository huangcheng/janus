"""Retention sweeper + manual prune endpoint (observability-depth Task 8).

Sweeps dashboard-owned tables by ts cutoff (plus the failure-observability
ops tables at JANUS_OPS_RETENTION_DAYS=14 — closed rows only, see
_OPS_TABLES):

  - audit_events        older than JANUS_AUDIT_RETENTION_DAYS (default 90)
  - gateway_log_events  older than JANUS_LOG_RETENTION_DAYS   (default 14)
  - alert_events        older than JANUS_ALERT_RETENTION_DAYS (default 30),
                        but ONLY rows with delivered=true OR
                        detail->>'delivery'='failed_permanent' — a row
                        still being retried is never pruned (record-only
                        rows insert delivered=true, so they prune
                        normally).

Schedule: one lifespan asyncio task checks hourly (CHECK_INTERVAL_SEC)
and runs a sweep when the in-memory last_run is older than 24h or the
sweeper never ran (catch-up on boot). The cadence is approximate by
design — a dashboard restart is a catch-up sweep.

Single-flight: session-level advisory lock 90110012 (auto_reorder's
90110011 precedent) taken on ONE pooled connection — the lock, every
batched delete and the count collection all run on that connection,
with try/finally: pg_advisory_unlock on the same connection object (a
leaked session lock would make every later sweep, and the manual prune
on a different pooled connection, skip forever). Lock busy: the sweeper
logs + skips and the next hourly check retries (a skipped sweep is
never silent); POST /api/maintenance/prune answers 409
maintenance_busy and the gate retries.

Bounded batches (DELETE ... WHERE id IN (SELECT ... LIMIT 10000) looped
until 0 rows) keep any single statement short. audit.log(
"maintenance.prune") is written after each prune with the per-table
counts — after the delete, so the entry's ts is strictly past the
cutoff and never deletes itself.

The automatic hourly/nightly schedule is NOT gate-exercised: plan O.6
drives the manual endpoint, which shares this exact delete+lock code
path.
"""

import asyncio
import base64
import json
import logging
import os
import shutil
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

import asyncpg
import httpx
from fastapi import APIRouter, Depends, HTTPException

from . import audit, database, egress
from .auth import require_auth
from .config import config
from .nodes import stats_url
from .task_runs_writer import record_run

logger = logging.getLogger("janus.dashboard.maintenance")

# Session-level advisory lock serializing the sweeper and the manual
# prune (distinct from auto_reorder's 90110011 and alerts' 90110013).
ADVISORY_LOCK_KEY = 90110012
CHECK_INTERVAL_SEC = 3600  # hourly due-check
SWEEP_INTERVAL_SEC = 86400  # run when last_run is older than 24h
BATCH_SIZE = 10000  # per-statement delete bound

# (table, config attr with the retention days, extra WHERE predicate).
# Table/predicate are module constants, never user input; the only
# query parameter is the retention window.
_TABLES = (
    ("audit_events", "audit_retention_days", "TRUE"),
    ("gateway_log_events", "log_retention_days", "TRUE"),
    (
        "alert_events",
        "alert_retention_days",
        "(delivered = TRUE OR detail->>'delivery' = 'failed_permanent')",
    ),
)

# Failure-observability retention (spec 2026-10-13 section 5): 14d
# (JANUS_OPS_RETENTION_DAYS). These tables have no id column, so the
# batch is bounded by ctid. NEVER pruned: open episodes
# (ended_at IS NULL) and unfinished runs (finished_at IS NULL) — the
# predicates require a closed row. The high-water row of a node's
# CURRENT ops_boot_id is exempt too (an idle node must not re-apply an
# old ring after a prune). The predicate may reference the table by
# name; the only query parameter is the retention window ($1).
_OPS_TABLES = (
    ("gateway_ops_events", "gateway_ops_events.ts < NOW() - make_interval(days => $1)"),
    ("gateway_ops_markers", "gateway_ops_markers.ts < NOW() - make_interval(days => $1)"),
    (
        "cool_episodes",
        "cool_episodes.ended_at IS NOT NULL "
        "AND cool_episodes.ended_at < NOW() - make_interval(days => $1)",
    ),
    (
        "task_runs",
        "task_runs.finished_at IS NOT NULL "
        "AND task_runs.finished_at < NOW() - make_interval(days => $1)",
    ),
    (
        "gateway_ops_highwater",
        "gateway_ops_highwater.updated_at < NOW() - make_interval(days => $1) "
        "AND NOT EXISTS (SELECT 1 FROM gateway_nodes n "
        "WHERE n.id::text = gateway_ops_highwater.node_id "
        "AND n.ops_boot_id = gateway_ops_highwater.boot_id)",
    ),
)

# asyncio keeps only weak refs to tasks; hold ours or a GC cycle could
# drop the sweeper (the alerts.py discipline).
_tasks: set[asyncio.Task] = set()
_sweeper_task: asyncio.Task | None = None
_last_run: float | None = None


async def _prune_table(
    conn: asyncpg.Connection, table: str, retention_days: int, extra_where: str
) -> int:
    """Batched delete loop on the caller's connection (the advisory
    lock holder). Returns the total rows deleted."""
    total = 0
    while True:
        tag = await conn.execute(
            f"DELETE FROM {table} WHERE id IN ("
            f"  SELECT id FROM {table}"
            f"  WHERE ts < NOW() - make_interval(days => $1) AND {extra_where}"
            f"  ORDER BY id LIMIT $2"
            f")",
            retention_days,
            BATCH_SIZE,
        )
        n = int(tag.split()[-1])
        total += n
        if n == 0:
            return total


async def _prune_ops_table(
    conn: asyncpg.Connection, table: str, predicate: str, retention_days: int
) -> int:
    """Batched ctid delete for the id-less ops tables (also used for the
    cascade journal, whose batches are bounded the same way). Table/predicate
    are module constants."""
    total = 0
    while True:
        tag = await conn.execute(
            f"DELETE FROM {table} WHERE ctid = ANY(ARRAY("
            f"  SELECT ctid FROM {table} WHERE {predicate} LIMIT $2"
            f"))",
            retention_days,
            BATCH_SIZE,
        )
        n = int(tag.split()[-1])
        total += n
        if n == 0:
            return total


async def run_prune(trigger: str) -> dict | None:
    """Shared core for the sweeper and POST /api/maintenance/prune: one
    prune pass under the session advisory lock. Returns the per-table
    delete counts, or None when the lock is busy (the caller decides
    skip-vs-409). Instrumented as dashboard-native task_runs row."""
    async with record_run(
        "retention_prune",
        expected_duration_ms=60_000,
        schedule_interval_ms=SWEEP_INTERVAL_SEC * 1000,
    ) as run:
        async with database.pool().acquire() as conn:
            got = await conn.fetchval("SELECT pg_try_advisory_lock($1)", ADVISORY_LOCK_KEY)
            if not got:
                run.ok()  # lock busy is not a task failure
                return None
            try:
                counts = {
                    table: await _prune_table(conn, table, getattr(config, attr), where)
                    for table, attr, where in _TABLES
                }
                for table, predicate in _OPS_TABLES:
                    counts[table] = await _prune_ops_table(
                        conn, table, predicate, config.ops_retention_days
                    )
                # Cascade journal (spec 2026-10-22 §3): 30 days AFTER a restore
                # replayed it. Unrestored rows are kept — they are still owed
                # to a later provider re-enable / re-create / route add.
                counts["config_cascade_events"] = await _prune_ops_table(
                    conn,
                    "config_cascade_events",
                    "config_cascade_events.restored_at IS NOT NULL "
                    "AND config_cascade_events.restored_at < NOW() - make_interval(days => $1)",
                    30,
                )
                # Deferred tier surgery (spec 2026-10-22 §5.3): resolved
                # intents are kept 30 days for the audit trail. UNRESOLVED rows
                # are never pruned — they are still owed to the tiers, and a
                # permanently busy lock must leave them visible rather than
                # silently drop the surgery.
                counts["config_cascade_pending"] = await _prune_ops_table(
                    conn,
                    "config_cascade_pending",
                    "config_cascade_pending.resolved_at IS NOT NULL "
                    "AND config_cascade_pending.resolved_at < NOW() - make_interval(days => $1)",
                    30,
                )
            finally:
                await conn.execute("SELECT pg_advisory_unlock($1)", ADVISORY_LOCK_KEY)
        audit.log(
            "maintenance.prune",
            detail=json.dumps({"trigger": trigger, "counts": counts}),
        )
        run.ok()
        return counts


# ---------------------------------------------------------------------------
# Sweeper loop (lifespan-managed, mirrors alerts.start_sender/stop_sender)
# ---------------------------------------------------------------------------


async def _sweeper_loop() -> None:
    global _last_run
    while True:
        try:
            if _last_run is None or time.time() - _last_run >= SWEEP_INTERVAL_SEC:
                counts = await run_prune(trigger="sweep")
                if counts is None:
                    # Busy does NOT stamp last_run — the next hourly
                    # check retries (a skipped sweep is never silent).
                    logger.warning(
                        "maintenance sweep skipped: prune advisory lock busy "
                        "(retried at the next hourly check)"
                    )
                else:
                    _last_run = time.time()
                    logger.info("maintenance sweep done: %s", counts)
        except asyncio.CancelledError:
            raise
        except Exception:
            # A failed sweep leaves last_run alone too — retried hourly.
            logger.exception("maintenance sweep failed; retried at the next hourly check")
        await asyncio.sleep(CHECK_INTERVAL_SEC)


async def start_sweeper() -> None:
    """Start the hourly-check retention sweeper (lifespan-managed)."""
    global _sweeper_task
    if _sweeper_task is None or _sweeper_task.done():
        t = asyncio.create_task(_sweeper_loop())
        _tasks.add(t)
        t.add_done_callback(_tasks.discard)
        _sweeper_task = t
        logger.info(
            "maintenance sweeper started (check every %ds, sweep cadence %ds; "
            "audit %dd / logs %dd / alerts %dd)",
            CHECK_INTERVAL_SEC,
            SWEEP_INTERVAL_SEC,
            config.audit_retention_days,
            config.log_retention_days,
            config.alert_retention_days,
        )


async def stop_sweeper() -> None:
    global _sweeper_task
    if _sweeper_task is not None:
        _sweeper_task.cancel()
        try:
            await _sweeper_task
        except asyncio.CancelledError:
            pass
    _sweeper_task = None
    logger.info("maintenance sweeper stopped")


# ---------------------------------------------------------------------------
# Manual trigger (plan O.6) — same delete+lock path as the sweep
# ---------------------------------------------------------------------------

router = APIRouter()


@router.post("/prune")
async def post_prune(user: dict = Depends(require_auth)):
    """POST /api/maintenance/prune — run one retention prune now with
    the configured thresholds (no parameters). 409 maintenance_busy
    when a sweep holds the advisory lock; the gate retries."""
    counts = await run_prune(trigger="manual")
    if counts is None:
        raise HTTPException(
            409,
            detail={
                "error": {
                    "code": "maintenance_busy",
                    "message": "a retention sweep is in progress; retry shortly",
                }
            },
        )
    return {
        "ok": True,
        "counts": counts,
        "retention_days": {
            "audit_events": config.audit_retention_days,
            "gateway_log_events": config.log_retention_days,
            "alert_events": config.alert_retention_days,
            **{table: config.ops_retention_days for table, _ in _OPS_TABLES},
        },
    }


_MAXMIND_URL = "https://download.maxmind.com/geoip/databases/GeoLite2-City/download?suffix=tar.gz"


async def _resolve_maxmind_creds() -> tuple[str, str]:
    """Prefer settings.maxmind (encrypted license); fall back to env.

    Never logs credential values.
    """
    from .crypto import decrypt

    row = await database.fetchrow("SELECT value FROM settings WHERE key = 'maxmind'")
    account = ""
    license_key = ""
    if row:
        raw = row["value"]
        try:
            stored = json.loads(raw) if isinstance(raw, (str, bytes)) else raw
        except Exception:
            stored = None
        if isinstance(stored, dict):
            account = str(stored.get("account_id") or "").strip()
            ct = stored.get("license_key_ciphertext")
            if ct:
                try:
                    license_key = decrypt(bytes.fromhex(ct)).decode()
                except Exception:
                    logger.warning("maxmind license_key_ciphertext undecryptable")
    if not account:
        account = (config.maxmind_account_id or "").strip()
    if not license_key:
        license_key = (config.maxmind_license_key or "").strip()
    if not account or not license_key:
        raise HTTPException(
            503,
            detail={
                "error": {
                    "code": "maxmind_unconfigured",
                    "message": "Save MaxMind Account ID + License Key on Maintenance, or set JANUS_MAXMIND_* env",
                }
            },
        )
    return account, license_key


def _download_geolite2_city(dest: Path, account: str, license_key: str) -> int:
    """Fetch GeoLite2-City.mmdb to dest (atomic replace). Returns byte size.

    Credentials passed in — never logged. Failed download leaves any
    existing dest untouched.
    """
    if not account or not license_key:
        raise HTTPException(
            503,
            detail={
                "error": {
                    "code": "maxmind_unconfigured",
                    "message": "MaxMind Account ID / License Key not set",
                }
            },
        )

    dest.parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="janus-geolite2-"))
    try:
        tgz = work / "GeoLite2-City.tar.gz"
        auth = base64.b64encode(f"{account}:{license_key}".encode()).decode()
        req = urllib.request.Request(
            _MAXMIND_URL,
            headers={"Authorization": f"Basic {auth}"},
            method="GET",
        )
        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                tgz.write_bytes(resp.read())
        except urllib.error.HTTPError as e:
            raise HTTPException(
                502,
                detail={
                    "error": {
                        "code": "maxmind_download_failed",
                        "message": f"MaxMind HTTP {e.code}",
                    }
                },
            ) from e
        except Exception as e:
            raise HTTPException(
                502,
                detail={
                    "error": {
                        "code": "maxmind_download_failed",
                        "message": str(e)[:200],
                    }
                },
            ) from e

        with tarfile.open(tgz, "r:gz") as tf:
            member = next(
                (m for m in tf.getmembers() if m.name.endswith("GeoLite2-City.mmdb")),
                None,
            )
            if member is None:
                raise HTTPException(
                    502,
                    detail={
                        "error": {
                            "code": "maxmind_bad_archive",
                            "message": "tar.gz has no GeoLite2-City.mmdb",
                        }
                    },
                )
            # Path-traversal guard (Python 3.11 has no tarfile filter=).
            name = os.path.normpath(member.name)
            if os.path.isabs(name) or name.startswith("..") or ".." in name.split(os.sep):
                raise HTTPException(
                    502,
                    detail={
                        "error": {
                            "code": "maxmind_bad_archive",
                            "message": "tar member has unsafe path",
                        }
                    },
                )
            tf.extract(member, path=work)
            src = work / member.name
        size = src.stat().st_size
        if size < 1_000_000:
            raise HTTPException(
                502,
                detail={
                    "error": {
                        "code": "maxmind_bad_archive",
                        "message": f"mmdb too small ({size} bytes)",
                    }
                },
            )
        new = dest.with_suffix(dest.suffix + f".new.{os.getpid()}")
        shutil.copyfile(src, new)
        os.chmod(new, 0o664)
        os.replace(new, dest)
        return size
    finally:
        shutil.rmtree(work, ignore_errors=True)


async def _master_stats_target() -> tuple[str, int, str | None]:
    """Pick the lowest-id healthy master from gateway_nodes + health cache."""
    from . import nodes as nodes_mod

    rows = await database.fetch(
        "SELECT id, name, stats_host, stats_port, stats_token_ciphertext, enabled "
        "FROM gateway_nodes WHERE enabled = true ORDER BY id"
    )
    health = getattr(nodes_mod, "_health", {}) or {}
    policy_on = await egress.egress_policy_on()
    for row in rows:
        h = health.get(row["id"]) or {}
        role = str(h.get("role") or "").lower()
        status = str(h.get("status") or "")
        if role == "master" and status == "healthy":
            token = egress.stats_token_for(
                row["stats_host"],
                row["stats_token_ciphertext"],
                config.stats_token,
                policy_on=policy_on,
            )
            return row["stats_host"], int(row["stats_port"] or 8090), token
    # Soft fallback: first enabled node named master/leader,
    # even if the health cache is cold right after dashboard recreate.
    for row in rows:
        name = str(row["name"] or "").lower()
        if name in ("master", "leader"):
            token = egress.stats_token_for(
                row["stats_host"],
                row["stats_token_ciphertext"],
                config.stats_token,
                policy_on=policy_on,
            )
            return row["stats_host"], int(row["stats_port"] or 8090), token
    raise HTTPException(
        503,
        detail={
            "error": {
                "code": "no_master",
                "message": "no healthy master gateway to reload mmdb",
            }
        },
    )


@router.post("/mmdb/refresh")
async def post_mmdb_refresh(user: dict = Depends(require_auth)):
    """Download a fresh GeoLite2-City.mmdb onto the shared geo volume,
    then ask the master gateway to reload locus (POST /stats/mmdb/reload).

    Requires MaxMind creds (settings.maxmind or JANUS_MAXMIND_* env) and a
    rw mount of JANUS_MMDB_PATH (same host path the master reads).
    """
    account, license_key = await _resolve_maxmind_creds()
    dest = Path(config.mmdb_path)
    # Fail with a CLEAR 4xx when the geo volume is not mounted/rw in
    # this container (live 2026-10-28: unmounted dashboard -> raw 500
    # PermissionError on the button).
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        if not os.access(dest.parent, os.W_OK):
            raise OSError(f"{dest.parent} is not writable")
    except OSError as e:
        raise HTTPException(
            503,
            detail={
                "error": {
                    "code": "mmdb_volume_unavailable",
                    "message": (
                        f"mmdb path {dest.parent} missing or read-only in the dashboard "
                        f"container - mount the shared geo volume rw ({e})"
                    )[:240],
                }
            },
        ) from e
    size = await asyncio.to_thread(_download_geolite2_city, dest, account, license_key)

    host, port, token = await _master_stats_target()
    url = stats_url(host, port, "/stats/mmdb/reload")
    headers = {}
    if token:
        headers["authorization"] = f"Bearer {token}"
    try:
        async with httpx.AsyncClient(timeout=90.0) as client:
            resp = await client.post(url, headers=headers)
    except Exception as e:
        raise HTTPException(
            502,
            detail={
                "error": {
                    "code": "mmdb_reload_unreachable",
                    "message": f"downloaded ({size} bytes) but reload failed: {e!s}"[:240],
                }
            },
        ) from e

    if resp.status_code != 200:
        logger.warning(
            "mmdb reload HTTP %s body=%s",
            resp.status_code,
            (resp.text or "")[:500],
        )
        raise HTTPException(
            502,
            detail={
                "error": {
                    "code": "mmdb_reload_failed",
                    "message": f"downloaded ({size} bytes); master reload HTTP {resp.status_code}",
                }
            },
        )

    try:
        body = resp.json() if resp.content else {}
    except Exception:
        body = {}
    audit.log(
        "maintenance.mmdb_refresh",
        "maxmind",
        f"bytes={size} geo_enabled={body.get('geo_enabled')}",
    )
    return {
        "ok": True,
        "bytes": size,
        "path": str(dest),
        "reload": body,
    }
