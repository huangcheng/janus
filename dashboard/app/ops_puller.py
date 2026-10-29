"""Failure-observability puller (spec 2026-10-13 sections 3, 4, 5).

After each master node's SUCCESSFUL /stats poll (app/nodes.py), one
ops pull is spawned as a strong-ref'd, single-flight asyncio task (never
awaited — the health cadence is unaffected). A pull does, in order:

  1. GET /stats/health  -> boot-change check (exactly once, one txn),
     upsert the live snapshot JSON onto the node's gateway_nodes row.
  2. Drain GET /stats/ops-events under a SESSION advisory lock per node
     (all pages): insert events, apply cool_edge / task_run, advance the
     high-water in the SAME transaction as the batch (never on peek).
  3. Reconcile (only when the drain is caught up, so ops_lagging=false,
     cool_ids is not truncated, and the snapshot is not stale vs. the
     ring): seed episodes for cooling targets we hold no episode for,
     refresh open ones, close open ones absent for 2 polls ('reconcile').
  4. Orphan reaper for unfinished task runs (same lagging gate).

Steps 1 and 2 use independent try/except: a failed ops drain with a good
snapshot sets ops_lagging=true (UI badge + reconcile gate); a failed
snapshot never blocks the drain. This module shares nothing with the
OTP log puller (nodes.py _log_pull_task) — a failure in one never
touches the other.

Failure modes guarded (each is an acceptance check for this task):
  * Double drain: pg_try_advisory_lock(class, node) held on ONE pooled
    connection for the whole node drain; busy => skip + count.
  * Event loss: high-water advances only inside the transaction that
    durably inserted + applied the batch.
  * Replay: PK (node_id, boot_id, idx) + ON CONFLICT DO NOTHING; an
    event whose insert is a no-op is NOT re-applied.
  * Restart storm: boot-change is keyed by UNIQUE (node_id,
    prior_boot_id, reason); a second trigger (health vs ops reset) in
    the same or a later poll hits the conflict and is a no-op.
  * Overflow: write an overflow marker, recover the high-water, do NOT
    close open episodes/runs (reconcile is the closer).
  * False close during an outage: reconcile never runs while lagging.
  * Stale snapshot vs fresher events: identities touched by any event
    applied this poll are excluded from seed and absence counting.
  * model_id NULL: stored as '' everywhere (the open-episode partial
    unique index needs a value, SQL NULLs are distinct).
  * First close wins: every close carries WHERE ended_at IS NULL and a
    BEFORE UPDATE trigger pins ended_at/end_reason.
"""

import asyncio
import json
import logging
import time
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx

from . import database, egress
from .config import config

logger = logging.getLogger("janus.dashboard.ops_puller")

# Session advisory lock key space: pg_try_advisory_lock(CLASS, node_id)
# is the two-int form, a different key space from the single-bigint
# locks (90110011/12/13), so it can never collide with them.
OPS_LOCK_CLASS = 90110014
STATEMENT_TIMEOUT_MS = 5000
HTTP_TIMEOUT_SEC = 3.0
DRAIN_PAGE_LIMIT = 500
DRAIN_MAX_PAGES = 20
DRAIN_DEADLINE_SEC = 20.0
SCHEMA_VERSION = 1
RECONCILE_ABSENT_POLLS = 2
ORPHAN_GRACE_MS = 60_000
DEFAULT_RUN_BUDGET_MS = 600_000  # unfinished run with no expected_duration_ms
ERROR_MAX_CHARS = 2000

_KINDS = ("provider_key", "provider", "route")
_START_PHASES = ("start", "started", "begin", "running")

_tasks: set[asyncio.Task] = set()
_in_flight: set[int] = set()
_stats = {
    "pulls": 0,
    "overlap_skips": 0,
    "lock_busy_skips": 0,
    "unsupported": 0,
    "snapshot_failures": 0,
    "drain_failures": 0,
    "egress_rejected": 0,
    "events_inserted": 0,
    "events_dropped": 0,
    "boot_changes": 0,
    "overflow_markers": 0,
    "reconcile_closes": 0,
    "seeded": 0,
    "reaped_runs": 0,
}


def pull_stats() -> dict:
    """Module counters for diagnostics."""
    return dict(_stats)


def forget_node(nid: int) -> None:
    """Hook for nodes.py when a node leaves the enabled set (all state
    is in Postgres; nothing to drop beyond a stale in-flight marker)."""
    _in_flight.discard(nid)


# ---------------------------------------------------------------------------
# Small parsing helpers (payloads are JSON-decoded: binary-key dicts, ints,
# null — never trust a shape)
# ---------------------------------------------------------------------------


def _parse_ts(raw: Any) -> datetime | None:
    if not isinstance(raw, str) or not raw:
        return None
    text = raw[:-1] + "+00:00" if raw.endswith("Z") else raw
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt


def _int_or_none(v: Any) -> int | None:
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, float) and v == v and abs(v) < 1e18:  # noqa: PLR0124 — v == v is the NaN filter
        return int(v)
    return None


# datetime.fromtimestamp platform range is far narrower than _int_or_none's
# 1e18 gate. Clamp epoch-ms to ~1970..2100 so a garbage until_ms cannot
# OverflowError the whole reconcile transaction (OCR Medium on cc9c770).
_MS_MIN = 0
_MS_MAX = 4_102_444_800_000  # 2100-01-01 UTC


def _ms_to_dt(ms: int) -> datetime:
    clamped = max(_MS_MIN, min(int(ms), _MS_MAX))
    return datetime.fromtimestamp(clamped / 1000.0, tz=UTC)


def _str_or_none(v: Any) -> str | None:
    return v if isinstance(v, str) and v != "" else None


def _ident(target: Any) -> tuple[str, str, str, str] | None:
    """(kind, id, provider_id, model_id) from a spec 4.1 target; model_id
    None -> ''. Unknown kinds / missing ids are dropped (None)."""
    if not isinstance(target, dict):
        return None
    kind = target.get("kind")
    tid = target.get("id")
    if kind not in _KINDS or not isinstance(tid, (str, int)) or isinstance(tid, bool):
        return None
    tid = str(tid)
    if tid == "":
        return None
    prov = target.get("provider_id")
    prov = str(prov) if isinstance(prov, (str, int)) and not isinstance(prov, bool) else ""
    model = target.get("model_id")
    model = str(model) if isinstance(model, (str, int)) and not isinstance(model, bool) else ""
    return kind, tid, prov, model


def _key(ident: tuple[str, str, str, str]) -> tuple[str, str, str]:
    """Open-episode identity: (kind, id, model_id); provider_id is
    descriptive and not part of identity."""
    return ident[0], ident[1], ident[3]


async def _set_timeout(conn) -> None:
    await conn.execute(f"SET LOCAL statement_timeout = '{STATEMENT_TIMEOUT_MS}'")


# ---------------------------------------------------------------------------
# DB operations — callers own the surrounding transaction
# ---------------------------------------------------------------------------


async def _boot_change(conn, node_key: str, prior: str, new: str, trigger: str) -> bool:
    """Boot-change procedure, once per (node, prior boot). The marker's
    unique key is the exactly-once latch: when the insert conflicts the
    whole procedure already ran and this is a no-op. Closes open
    episodes ('lost_edge') and unfinished runs ('timeout'); the new
    boot's high-water starts absent (= 0)."""
    marker = await conn.fetchval(
        "INSERT INTO gateway_ops_markers (node_id, reason, prior_boot_id, boot_id, detail) "
        "VALUES ($1, 'boot_change', $2, $3, $4::jsonb) "
        "ON CONFLICT (node_id, prior_boot_id, reason) DO NOTHING "
        "RETURNING marker_seq",
        node_key,
        prior,
        new,
        json.dumps({"trigger": trigger}),
    )
    if marker is None:
        return False
    eps = await conn.execute(
        "UPDATE cool_episodes SET ended_at = NOW(), end_reason = 'lost_edge' "
        "WHERE node_id = $1 AND ended_at IS NULL",
        node_key,
    )
    runs = await conn.execute(
        "UPDATE task_runs SET finished_at = NOW(), outcome = 'timeout', "
        "error_class = 'orphan', closed_by = 'boot_change' "
        "WHERE node_id = $1 AND finished_at IS NULL",
        node_key,
    )
    detail = {
        "trigger": trigger,
        "episodes_closed": int(eps.split()[-1]),
        "runs_closed": int(runs.split()[-1]),
    }
    await conn.execute(
        "UPDATE gateway_ops_markers SET detail = $3::jsonb WHERE node_id = $1 AND marker_seq = $2",
        node_key,
        marker,
        json.dumps(detail),
    )
    _stats["boot_changes"] += 1
    logger.info(
        "ops pull: node %s boot change %s -> %s (%s): closed %d episodes, %d runs",
        node_key,
        prior,
        new,
        trigger,
        detail["episodes_closed"],
        detail["runs_closed"],
    )
    return True


async def _open_episode(
    conn,
    node_key: str,
    ident: tuple[str, str, str, str],
    reason: str,
    started_at: datetime,
    until_ms: int | None,
    code: str | None,
    boot_id: str | None,
    source: str,
) -> None:
    """Open an episode; the partial unique index is the arbiter, so a
    concurrent open of the same identity refreshes instead of raising."""
    await conn.execute(
        "INSERT INTO cool_episodes (node_id, target_kind, target_id, provider_id, "
        "model_id, reason, started_at, last_until_ms, last_error_code, boot_id, meta) "
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11::jsonb) "
        "ON CONFLICT (node_id, target_kind, target_id, model_id) "
        "WHERE ended_at IS NULL DO UPDATE SET "
        "last_until_ms = EXCLUDED.last_until_ms, "
        "last_error_code = EXCLUDED.last_error_code",
        node_key,
        ident[0],
        ident[1],
        ident[2],
        ident[3],
        reason,
        started_at,
        until_ms,
        code,
        boot_id,
        json.dumps({"source": source}),
    )


async def _apply_cool_edge(
    conn, node_key: str, boot_id: str, ts: datetime, payload: Any, touched: set
) -> None:
    """cool_edge (spec 4.2). Ignore when already closed; clear without
    start -> closed stub; reason change on start -> superseded."""
    if not isinstance(payload, dict):
        return
    action = payload.get("action")
    ident = _ident(payload.get("target"))
    if action not in ("start", "clear", "extend") or ident is None:
        logger.warning("ops pull: node %s dropped malformed cool_edge %r", node_key, action)
        return
    touched.add(_key(ident))
    reason = _str_or_none(payload.get("reason")) or "unclassified"
    until_ms = _int_or_none(payload.get("until_ms"))
    code = _str_or_none(payload.get("last_error_code"))
    cause = payload.get("cause")
    row = await conn.fetchrow(
        "SELECT id, reason, meta->>'source' AS source FROM cool_episodes "
        "WHERE node_id = $1 AND target_kind = $2 AND target_id = $3 AND model_id = $4 "
        "AND ended_at IS NULL FOR UPDATE",
        node_key,
        ident[0],
        ident[1],
        ident[3],
    )
    if action == "start":
        if row is not None and row["reason"] == reason:
            # Same cooling re-announced. A snapshot-seeded episode only
            # had an estimated start: the edge is the real one.
            if row["source"] == "snapshot_seed":
                await conn.execute(
                    "UPDATE cool_episodes SET started_at = $2, last_until_ms = $3, "
                    "last_error_code = $4, absent_polls = 0, "
                    'meta = meta || \'{"source": "edge_rebased"}\'::jsonb '
                    "WHERE id = $1 AND ended_at IS NULL",
                    row["id"],
                    ts,
                    until_ms,
                    code,
                )
            else:
                await conn.execute(
                    "UPDATE cool_episodes SET last_until_ms = $2, last_error_code = $3, "
                    "absent_polls = 0 WHERE id = $1 AND ended_at IS NULL",
                    row["id"],
                    until_ms,
                    code,
                )
            return
        if row is not None:
            # Auto-supersede even when the explicit clear was lost.
            await conn.execute(
                "UPDATE cool_episodes SET ended_at = $2, end_reason = 'superseded' "
                "WHERE id = $1 AND ended_at IS NULL",
                row["id"],
                ts,
            )
        await _open_episode(conn, node_key, ident, reason, ts, until_ms, code, boot_id, "edge")
    elif action == "extend":
        if row is None:
            # The start edge was lost (overflow): the cooling is real.
            await _open_episode(
                conn, node_key, ident, reason, ts, until_ms, code, boot_id, "edge_stub"
            )
        elif row["reason"] != reason:
            logger.warning(
                "ops pull: node %s cross-reason extend ignored (%s -> %s) for %s/%s",
                node_key,
                row["reason"],
                reason,
                ident[0],
                ident[1],
            )
        else:
            await conn.execute(
                "UPDATE cool_episodes SET last_until_ms = $2, last_error_code = $3, "
                "absent_polls = 0 WHERE id = $1 AND ended_at IS NULL",
                row["id"],
                until_ms,
                code,
            )
    else:  # clear
        end_reason = "expired" if cause == "expired" else "clear"
        if row is not None:
            await conn.execute(
                "UPDATE cool_episodes SET ended_at = $2, end_reason = $3 "
                "WHERE id = $1 AND ended_at IS NULL",
                row["id"],
                ts,
                end_reason,
            )
        else:
            # end without start -> stub, then close (one closed row).
            await conn.execute(
                "INSERT INTO cool_episodes (node_id, target_kind, target_id, provider_id, "
                "model_id, reason, started_at, last_until_ms, last_error_code, boot_id, "
                "ended_at, end_reason, meta) "
                "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $7, $11, "
                '\'{"source": "edge_stub"}\'::jsonb)',
                node_key,
                ident[0],
                ident[1],
                ident[2],
                ident[3],
                reason,
                ts,
                until_ms,
                code,
                boot_id,
                end_reason,
            )


async def _apply_task_run(conn, node_key: str, boot_id: str, ts: datetime, payload: Any) -> None:
    """task_run (spec 4.2): start inserts an unfinished row; a terminal
    phase closes it WHERE finished_at IS NULL (idempotent); a terminal
    with no start row writes a closed stub."""
    if not isinstance(payload, dict):
        return
    run_id = _str_or_none(payload.get("run_id"))
    name = _str_or_none(payload.get("name"))
    if run_id is None or name is None:
        logger.warning("ops pull: node %s dropped malformed task_run", node_key)
        return
    phase = str(payload.get("phase") or "").lower()
    outcome = _str_or_none(payload.get("outcome"))
    expected = _int_or_none(payload.get("expected_duration_ms"))
    interval = _int_or_none(payload.get("schedule_interval_ms"))
    duration = _int_or_none(payload.get("duration_ms"))
    if outcome is None and phase in _START_PHASES + ("",):
        await conn.execute(
            "INSERT INTO task_runs (node_id, run_id, name, boot_id, started_at, phase, "
            "expected_duration_ms, schedule_interval_ms) "
            "VALUES ($1, $2, $3, $4, $5, $6, $7, $8) "
            "ON CONFLICT (node_id, run_id) DO NOTHING",
            node_key,
            run_id,
            name,
            boot_id,
            ts,
            phase or "start",
            expected,
            interval,
        )
        return
    if outcome is None:
        return  # unknown non-terminal phase: stored as an event, no row change
    err_class = _str_or_none(payload.get("error_class"))
    err = payload.get("error")
    err = err[:ERROR_MAX_CHARS] if isinstance(err, str) and err else None
    tag = await conn.execute(
        "UPDATE task_runs SET finished_at = $3, phase = $4, outcome = $5, "
        "error_class = $6, error = $7, duration_ms = $8, "
        "expected_duration_ms = COALESCE($9, expected_duration_ms), "
        "schedule_interval_ms = COALESCE($10, schedule_interval_ms), closed_by = 'ring' "
        "WHERE node_id = $1 AND run_id = $2 AND finished_at IS NULL",
        node_key,
        run_id,
        ts,
        phase or "end",
        outcome,
        err_class,
        err,
        duration,
        expected,
        interval,
    )
    if int(tag.split()[-1]) == 0:
        # Either already closed (ignore) or never started (stub).
        started = ts - timedelta(milliseconds=duration) if duration else ts
        await conn.execute(
            "INSERT INTO task_runs (node_id, run_id, name, boot_id, started_at, "
            "finished_at, phase, outcome, error_class, error, duration_ms, "
            "expected_duration_ms, schedule_interval_ms, closed_by, meta) "
            "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, 'ring', "
            '\'{"source": "edge_stub"}\'::jsonb) '
            "ON CONFLICT (node_id, run_id) DO NOTHING",
            node_key,
            run_id,
            name,
            boot_id,
            started,
            ts,
            phase or "end",
            outcome,
            err_class,
            err,
            duration,
            expected,
            interval,
        )


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------


async def _get_json(client: httpx.AsyncClient, url: str, token: str | None):
    from . import nodes as nodes_mod

    # Streamed with a hard byte cap (H4): a hostile/compromised node must
    # not be able to make the dashboard buffer an unbounded body.
    async with client.stream("GET", url, headers=nodes_mod._auth_headers(token)) as resp:
        if resp.status_code in (404, 503):
            return resp.status_code, None
        if resp.status_code != 200:
            raise RuntimeError(f"http {resp.status_code}")
        body = await egress.read_body_capped(resp)
    try:
        return 200, json.loads(body)
    except ValueError as exc:
        raise RuntimeError("non-JSON response body") from exc


# ---------------------------------------------------------------------------
# Step 1: snapshot
# ---------------------------------------------------------------------------


async def _store_snapshot(
    conn, nid: int, node_key: str, stored_boot: str | None, snap: dict
) -> str | None:
    """Boot-change (once) + upsert of the live JSON, one transaction.
    Returns the node's ops_boot_id after the txn. A snapshot with an
    unknown schema_version is stored raw and NOT applied (no boot
    handling, ops_boot_id untouched)."""
    boot = _str_or_none(snap.get("boot_id"))
    usable = boot is not None and snap.get("schema_version") == SCHEMA_VERSION
    async with conn.transaction():
        await _set_timeout(conn)
        new_boot = stored_boot
        if usable:
            if stored_boot is not None and stored_boot != boot:
                await _boot_change(conn, node_key, stored_boot, boot, "health")
            new_boot = boot
        await conn.execute(
            "UPDATE gateway_nodes SET health_snapshot = $2::jsonb, "
            "health_pulled_at = NOW(), ops_boot_id = $3 WHERE id = $1",
            nid,
            json.dumps(snap),
            new_boot,
        )
    return new_boot


# ---------------------------------------------------------------------------
# Step 2: drain
# ---------------------------------------------------------------------------


async def _insert_and_apply(
    conn, node_key: str, boot_id: str, events: list[dict], touched: set
) -> tuple[int, int]:
    """Insert one page's events and apply the new ones. Returns
    (inserted, dropped). Caller owns the transaction."""
    inserted = dropped = 0
    for ev in events:
        idx = _int_or_none(ev.get("idx"))
        typ = _str_or_none(ev.get("type"))
        if idx is None or typ is None or ev.get("boot_id") not in (None, boot_id):
            dropped += 1
            continue
        ts = _parse_ts(ev.get("ts")) or datetime.now(UTC)
        sv = _int_or_none(ev.get("schema_version")) or 0
        payload = ev.get("payload")
        tag = await conn.execute(
            "INSERT INTO gateway_ops_events (node_id, boot_id, idx, ts, type, "
            "schema_version, payload) VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb) "
            "ON CONFLICT DO NOTHING",
            node_key,
            boot_id,
            idx,
            ts,
            typ,
            sv,
            json.dumps(payload if isinstance(payload, (dict, list)) else {}),
        )
        if int(tag.split()[-1]) == 0:
            continue  # replay: already stored AND applied, never re-apply
        inserted += 1
        if sv != SCHEMA_VERSION:
            continue  # unknown schema: store raw, skip apply
        if typ == "cool_edge":
            await _apply_cool_edge(conn, node_key, boot_id, ts, payload, touched)
        elif typ == "task_run":
            await _apply_task_run(conn, node_key, boot_id, ts, payload)
    return inserted, dropped


async def _drain(
    conn,
    client: httpx.AsyncClient,
    nid: int,
    node_key: str,
    name: str,
    stats_host: str,
    stats_port: int,
    token: str | None,
    boot: str,
) -> dict:
    """Drain the ring page by page. Raises on any failure (the caller
    flags ops_lagging; committed pages stay committed — their
    high-water advanced with them, so the next pull resumes after)."""
    from . import nodes as nodes_mod

    hw = await conn.fetchval(
        "SELECT high_water FROM gateway_ops_highwater WHERE node_id = $1 AND boot_id = $2",
        node_key,
        boot,
    )
    hw = int(hw or 0)
    deadline = time.monotonic() + DRAIN_DEADLINE_SEC
    out = {
        "caught_up": False,
        "boot": boot,
        "reset": False,
        "gap": False,
        "inserted": 0,
        "touched": set(),
        "next_idx": None,
    }
    first_boot: str | None = None
    last_oldest: int | None = None
    for _ in range(DRAIN_MAX_PAGES):
        if time.monotonic() > deadline:
            return out
        url = nodes_mod.stats_url(
            stats_host,
            stats_port,
            f"/stats/ops-events?boot_id={boot}&after_idx={hw}&limit={DRAIN_PAGE_LIMIT}",
        )
        status, page = await _get_json(client, url, token)
        if status != 200 or not isinstance(page, dict):
            raise RuntimeError(f"ops-events unavailable (http {status})")
        page_boot = _str_or_none(page.get("boot_id"))
        events = page.get("events")
        oldest = _int_or_none(page.get("oldest_idx"))
        if page_boot is None or not isinstance(events, list) or oldest is None:
            raise RuntimeError("ops-events page malformed")
        # Pages agree iff boot_id matches the first page AND oldest_idx
        # is non-decreasing (next_idx advancing is expected).
        if first_boot is None:
            first_boot = page_boot
        elif page_boot != first_boot:
            raise RuntimeError("ops-events boot changed mid-drain")
        if last_oldest is not None and oldest < last_oldest:
            raise RuntimeError("ops-events oldest_idx went backwards mid-drain")
        last_oldest = oldest
        reset = page.get("reset") is True or page_boot != boot
        gap = page.get("gap") is True and not reset
        idxs = [
            i
            for i in (_int_or_none(e.get("idx")) for e in events if isinstance(e, dict))
            if i is not None
        ]
        clean = [e for e in events if isinstance(e, dict)]
        async with conn.transaction():
            await _set_timeout(conn)
            if reset:
                # Same procedure as the health-detected boot change; the
                # marker key makes the second trigger a no-op.
                await _boot_change(conn, node_key, boot, page_boot, "ops_reset")
                await conn.execute(
                    "UPDATE gateway_nodes SET ops_boot_id = $2 WHERE id = $1",
                    nid,
                    page_boot,
                )
                boot, hw = page_boot, 0
                out["reset"] = True
                out["boot"] = boot
            if gap:
                await conn.execute(
                    "INSERT INTO gateway_ops_markers (node_id, reason, boot_id, detail) "
                    "VALUES ($1, 'overflow', $2, $3::jsonb)",
                    node_key,
                    boot,
                    json.dumps(
                        {
                            "after_idx": hw,
                            "oldest_idx": oldest,
                            "overflow_count": _int_or_none(page.get("overflow_count")),
                        }
                    ),
                )
                _stats["overflow_markers"] += 1
                out["gap"] = True
                # Recover: events below oldest_idx are gone for good.
                hw = max(hw, oldest - 1)
            fresh = [e for e in clean if (_int_or_none(e.get("idx")) or 0) > hw]
            inserted, dropped = await _insert_and_apply(conn, node_key, boot, fresh, out["touched"])
            new_hw = max([hw] + idxs)
            await conn.execute(
                "INSERT INTO gateway_ops_highwater (node_id, boot_id, high_water, updated_at) "
                "VALUES ($1, $2, $3, NOW()) "
                "ON CONFLICT (node_id, boot_id) DO UPDATE SET "
                "high_water = GREATEST(gateway_ops_highwater.high_water, EXCLUDED.high_water), "
                "updated_at = NOW()",
                node_key,
                boot,
                new_hw,
            )
        hw = new_hw
        out["inserted"] += inserted
        _stats["events_inserted"] += inserted
        if dropped:
            _stats["events_dropped"] += dropped
            logger.warning("ops pull: node %s dropped %d malformed events", name, dropped)
        next_idx = _int_or_none(page.get("next_idx"))
        out["next_idx"] = next_idx
        if (
            not clean
            or len(events) < DRAIN_PAGE_LIMIT
            or (next_idx is not None and hw >= next_idx - 1)
        ):
            out["caught_up"] = True
            return out
    return out  # page cap hit with backlog remaining: lagging


# ---------------------------------------------------------------------------
# Step 3/4: reconcile + reaper
# ---------------------------------------------------------------------------


async def _reconcile(conn, node_key: str, snap: dict, touched: set, boot: str) -> dict:
    """Seed / refresh / absence-close against cool_ids. Caller has
    already established: not lagging, cool_ids_overflow=false, snapshot
    schema ok, snapshot boot == drained boot, no ops reset this poll."""
    snap_ts = _parse_ts(snap.get("snapshot_ts")) or datetime.now(UTC)
    present: dict[tuple, tuple] = {}
    for t in snap.get("cool_ids") or []:
        ident = _ident(t)
        if ident is not None:
            present[_key(ident)] = ident
    detail: dict[tuple, dict] = {}
    for item in snap.get("cool") or []:
        if isinstance(item, dict):
            ident = _ident(item.get("target"))
            if ident is not None:
                detail[_key(ident)] = item
    counts = {"seeded": 0, "refreshed": 0, "closed": 0, "absent_marked": 0}
    async with conn.transaction():
        await _set_timeout(conn)
        open_rows = await conn.fetch(
            "SELECT id, target_kind, target_id, model_id, started_at, absent_polls "
            "FROM cool_episodes WHERE node_id = $1 AND ended_at IS NULL FOR UPDATE",
            node_key,
        )
        open_by = {(r["target_kind"], r["target_id"], r["model_id"]): r for r in open_rows}
        for k, ident in present.items():
            if k in touched:
                continue
            d = detail.get(k) or {}
            until_ms = _int_or_none(d.get("until_ms"))
            code = _str_or_none(d.get("last_error_code"))
            row = open_by.get(k)
            if row is not None:
                # Same identity open: refresh only (reason unchanged).
                await conn.execute(
                    "UPDATE cool_episodes SET last_until_ms = COALESCE($2, last_until_ms), "
                    "last_error_code = COALESCE($3, last_error_code), absent_polls = 0 "
                    "WHERE id = $1 AND ended_at IS NULL",
                    row["id"],
                    until_ms,
                    code,
                )
                counts["refreshed"] += 1
                continue
            # started_at ~ until - default cool window, never in the future.
            est = snap_ts
            if until_ms is not None:
                est = min(
                    snap_ts,
                    _ms_to_dt(until_ms - config.lb_cooldown_ms),
                )
            await _open_episode(
                conn,
                node_key,
                ident,
                _str_or_none(d.get("reason")) or "unclassified",
                est,
                until_ms,
                code,
                boot,
                "snapshot_seed",
            )
            counts["seeded"] += 1
        for k, row in open_by.items():
            if k in present or k in touched or row["started_at"] > snap_ts:
                continue
            n = int(row["absent_polls"]) + 1
            if n >= RECONCILE_ABSENT_POLLS:
                await conn.execute(
                    "UPDATE cool_episodes SET ended_at = NOW(), end_reason = 'reconcile', "
                    "absent_polls = $2 WHERE id = $1 AND ended_at IS NULL",
                    row["id"],
                    n,
                )
                counts["closed"] += 1
            else:
                await conn.execute(
                    "UPDATE cool_episodes SET absent_polls = $2 WHERE id = $1 AND ended_at IS NULL",
                    row["id"],
                    n,
                )
                counts["absent_marked"] += 1
    _stats["seeded"] += counts["seeded"]
    _stats["reconcile_closes"] += counts["closed"]
    return counts


async def _reap_orphans(conn, node_key: str) -> int:
    """Unfinished runs past expected_duration + grace with no terminal
    event in a fully caught-up ring are orphans (outcome 'timeout',
    error_class 'orphan')."""
    tag = await conn.execute(
        "UPDATE task_runs SET finished_at = NOW(), outcome = 'timeout', "
        "error_class = 'orphan', closed_by = 'reaper' "
        "WHERE node_id = $1 AND finished_at IS NULL AND started_at + "
        "make_interval(secs => (COALESCE(NULLIF(expected_duration_ms, 0), $2) + $3) / 1000.0) "
        "< NOW()",
        node_key,
        DEFAULT_RUN_BUDGET_MS,
        ORPHAN_GRACE_MS,
    )
    n = int(tag.split()[-1])
    _stats["reaped_runs"] += n
    return n


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------


async def pull_node(
    nid: int, name: str, stats_host: str, stats_port: int, token: str | None
) -> None:
    """One full ops pull for a node (steps 1-4). Never raises."""
    from . import nodes as nodes_mod
    from .task_runs_writer import record_run

    node_key = str(nid)
    _stats["pulls"] += 1
    try:
        # alerts_debug holds alert_control.paused while it drives run_once
        # against a seeded health_snapshot (O.4b / O.10g). Skip the pull so
        # we cannot overwrite that seed mid-drive. Must run inside the
        # outer try so _in_flight is always discarded.
        try:
            if await database.fetchval("SELECT paused FROM alert_control WHERE id = 1"):
                return
        except Exception:
            logger.debug("ops pull: paused check skipped", exc_info=True)
        async with record_run(
            "ops_pull",
            expected_duration_ms=int(DRAIN_DEADLINE_SEC * 1000),
            schedule_interval_ms=config.node_health_interval_sec * 1000,
        ) as run:
            try:
                async with database.pool().acquire() as conn:
                    got = await conn.fetchval(
                        "SELECT pg_try_advisory_lock($1, $2)", OPS_LOCK_CLASS, int(nid)
                    )
                    if not got:
                        _stats["lock_busy_skips"] += 1
                        logger.warning("ops pull skipped for %s: drain lock busy", name)
                        run.ok()  # busy skip is not a task failure
                        return
                    try:
                        await _pull_locked(
                            conn,
                            nodes_mod,
                            nid,
                            node_key,
                            name,
                            stats_host,
                            stats_port,
                            token,
                        )
                        run.ok()
                    finally:
                        try:
                            await conn.execute(
                                "SELECT pg_advisory_unlock($1, $2)",
                                OPS_LOCK_CLASS,
                                int(nid),
                            )
                        except Exception:
                            logger.exception("ops pull: advisory unlock failed for %s", name)
            except Exception as exc:
                run.error("internal", repr(exc))
                logger.exception("ops pull task failed for %s", name)
    finally:
        # Outer finally: record_run.__aenter__ can raise BaseException
        # (CancelledError) before the inner finally runs — never strand nid.
        _in_flight.discard(nid)


async def _pull_locked(
    conn,
    nodes_mod,
    nid: int,
    node_key: str,
    name: str,
    stats_host: str,
    stats_port: int,
    token: str | None,
) -> None:
    row = await conn.fetchrow("SELECT ops_boot_id FROM gateway_nodes WHERE id = $1", nid)
    if row is None:
        return  # node deleted mid-flight
    stored_boot: str | None = row["ops_boot_id"]
    # trust_env=False: same corporate-proxy trap as alert webhooks —
    # loopback / private stats hosts must not ride HTTP_PROXY.
    # H1: the host is re-resolved and classified immediately before the
    # request, and the client connects to the VALIDATED addresses (never
    # a second resolution), so a DNS flip cannot redirect this pull.
    client = egress.pinned_async_client(
        stats_host,
        timeout=HTTP_TIMEOUT_SEC,
        verify=nodes_mod._tls_verify(),
        trust_env=False,
    )
    if client is None:
        _stats["egress_rejected"] += 1
        logger.warning(
            "ops pull skipped for %s: stats_host %r failed the connect-time "
            "egress classification (metadata/non-routable or unresolvable)",
            name,
            egress.host_of(stats_host),
        )
        return
    async with client:
        # --- step 1: snapshot (independent try/except) ---
        snap: dict | None = None
        try:
            status, body = await _get_json(
                client, nodes_mod.stats_url(stats_host, stats_port, "/stats/health"), token
            )
            if status == 404:
                # Old beam / worker without the ops tail: no snapshot, no
                # drain, and nothing to flag as lagging.
                _stats["unsupported"] += 1
                return
            if status != 200:
                # Transient non-200 (e.g. 503) must NOT abort the drain —
                # contract: a failed snapshot never blocks step 2.
                raise RuntimeError(f"/stats/health unavailable (http {status})")
            if isinstance(body, dict):
                snap = body
                stored_boot = await _store_snapshot(conn, nid, node_key, stored_boot, snap)
        except Exception:
            snap = None
            _stats["snapshot_failures"] += 1
            logger.exception("ops pull: snapshot step failed for %s", name)

        # --- step 2: drain (independent try/except) ---
        drained: dict | None = None
        lagging = True
        if stored_boot is not None:
            try:
                drained = await _drain(
                    conn,
                    client,
                    nid,
                    node_key,
                    name,
                    stats_host,
                    stats_port,
                    token,
                    stored_boot,
                )
                lagging = not drained["caught_up"]
                stored_boot = drained["boot"]
            except Exception:
                _stats["drain_failures"] += 1
                logger.exception("ops pull: drain failed for %s; ops_lagging set", name)
        try:
            await conn.execute(
                "UPDATE gateway_nodes SET ops_lagging = $2 WHERE id = $1", nid, lagging
            )
        except Exception:
            logger.exception("ops pull: ops_lagging update failed for %s", name)

        if lagging or drained is None:
            return  # reconcile + reaper are gated on a fully drained ring

        # --- steps 3-4 ---
        try:
            snap_ok = (
                snap is not None
                and snap.get("schema_version") == SCHEMA_VERSION
                and snap.get("cool_ids_overflow") is False
                and isinstance(snap.get("cool_ids"), list)
                and snap.get("boot_id") == drained["boot"]
                and not drained["reset"]
            )
            if snap_ok:
                await _reconcile(conn, node_key, snap, drained["touched"], drained["boot"])
            async with conn.transaction():
                await _set_timeout(conn)
                await _reap_orphans(conn, node_key)
        except Exception:
            logger.exception("ops pull: reconcile/reaper failed for %s", name)


def spawn_ops_pull(row: Any, policy_on: bool) -> None:
    """Spawn one ops pull for a master node: strong-ref'd, single-flight
    per node, never awaited (the health loop cadence is unaffected)."""
    nid = int(row["id"])
    if nid in _in_flight:
        _stats["overlap_skips"] += 1
        logger.warning("ops pull skipped for %s: previous pull still running", row["name"])
        return
    token = egress.stats_token_for(
        row["stats_host"],
        row["stats_token_ciphertext"],
        config.stats_token,
        policy_on=policy_on,
    )
    if token is None:
        return  # policy flipped between poll and spawn: the global token stays home
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        logger.warning("ops pull spawn without a running loop; skipped")
        return
    _in_flight.add(nid)
    coro = pull_node(nid, row["name"], row["stats_host"], row["stats_port"], token)
    try:
        t = loop.create_task(coro)
    except Exception:
        _in_flight.discard(nid)
        coro.close()
        raise
    _tasks.add(t)
    t.add_done_callback(_tasks.discard)
