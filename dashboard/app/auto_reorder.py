"""Auto-router tier reorder loop + the two write entrypoints (reorder
spec docs/superpowers/specs/2026-10-11-geo-affinity-and-auto-tier-reorder-design.md
— RATIFIED r14, Task 2 / dashboard side).

Wiring (D1): ONE lifespan asyncio task on the dashboard's PRIMARY
Postgres DSN only — ``pg_is_in_recovery()`` replicas never tick, and
there is no SQLite mode to guard here (the dashboard is asyncpg-only);
``JANUS_REORDER_LOOP=0`` is the hard kill switch. Among replicas the
D10 lease elects the single ticking leader; the marker/stats polled
are the LEADER GATEWAY's (the master that owns the catalog and
re-validation — your-gateway.example.com in production, the local gw in e2e).

Two write entrypoints, one validator (D6):

- ``human_commit()`` (backing PUT /api/settings/auto-router): sets
  ``last_manual_edit_at`` + clears pending + clears the reject
  counters (D35 manual-PUT escape). Advisory-lock busy -> HTTP 409
  ``reorder_busy`` + Retry-After: 1 (D34, DASHBOARD-side check).
- ``system_reorder_commit()``: validates via the SHARED parity
  validator, CASes the settings jsonb, writes the audit row, bumps the
  generation — all in ONE xact under
  ``pg_try_advisory_xact_lock(90110011)`` with a D10 lease re-check —
  and NEVER touches ``last_manual_edit_at`` (D30). A CAS miss rolls
  back the whole xact including the pending clear (D14, ``cas_abort``).

Generic settings APIs never mutate tiers (TF-A.22): the tiers write
paths are exactly the two above; the knobs key
``auto_router_reorder`` carries only enabled/intervals/thresholds.
"""

import asyncio
import json
import logging
import os
import socket
import time
from datetime import UTC, datetime

import asyncpg
import httpx

from . import audit, database, egress, nodes, probe_urls
from . import auto_router_rules as rules
from .config import config

logger = logging.getLogger("janus.dashboard.reorder")

REORDER_KNOBS_KEY = "auto_router_reorder"  # settings key (D7)
AUTO_ROUTER_KEY = "auto_router"  # the tiers payload key
ATTEMPT_ROWS_VERSION = "018_usage_attempt_rows"  # TF-A.0b ledger row
ADVISORY_XACT_KEY = 90110011  # D6 xact lock
REJECT_TRIP = 2  # D35: two consecutive rejects

LOOP_ID = f"dash@{socket.gethostname()}#{os.getpid()}"

_loop_task: asyncio.Task | None = None
# D32 observability: skip_reason counters + last-tick bookkeeping are
# process-local (leader-surviving state lives in auto_router_state).
_SKIP: dict[str, int] = {}
_LAST_TICK: dict = {}
_STATS_CACHE: dict = {"at": 0.0, "data": None}
_SCHED_CACHE: dict = {"at": 0.0, "data": None}


class CasAbort(Exception):
    """D14: the settings row changed under the loop — the commit xact
    rolls back ENTIRELY (pending included); next tick recomputes."""


class ReorderBusy(Exception):
    """D34: the advisory lock is held (a system commit/restore is in
    flight) — the human PUT answers 409 reorder_busy."""


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------


def _skip(reason: str, **extra) -> dict:
    _SKIP[reason] = _SKIP.get(reason, 0) + 1
    out = {"skipped": reason, "at": datetime.now(UTC).isoformat()}
    out.update(extra)
    _LAST_TICK.clear()
    _LAST_TICK.update(out)
    return out


async def db_now() -> float:
    """D10: DB now() only — every time anchor in this module comes from
    the database clock."""
    return float(await database.fetchval("SELECT EXTRACT(EPOCH FROM NOW())"))


async def is_primary() -> bool | None:
    """True on a primary DSN, False on a replica, None when the check
    itself failed (both non-True => the loop must not run, D1)."""
    try:
        return await database.fetchval("SELECT NOT pg_is_in_recovery()")
    except Exception:
        logger.warning("reorder primary check failed", exc_info=True)
        return None


async def read_knobs() -> dict:
    """Read the D7 knob row (tolerant — bad values fall back to
    defaults; the PUT endpoint is the strict gate)."""
    raw = None
    try:
        row = await database.fetchrow(
            "SELECT value FROM settings WHERE key = $1", REORDER_KNOBS_KEY
        )
        if row:
            v = row["value"]
            raw = json.loads(v) if isinstance(v, (str, bytes)) else v
    except Exception:
        logger.warning("reorder knob read failed; using defaults", exc_info=True)
        raw = None
    return rules.normalize_knobs(raw)


async def read_auto_router() -> tuple[str | None, dict | None]:
    """(raw stored value string for the CAS, parsed config) — None when
    no row / unparseable JSON."""
    row = await database.fetchrow("SELECT value FROM settings WHERE key = $1", AUTO_ROUTER_KEY)
    if not row:
        return None, None
    raw = row["value"]
    try:
        cfg = json.loads(raw) if isinstance(raw, (str, bytes)) else dict(raw)
    except Exception:
        return raw, None
    return raw, cfg


def _jload(v):
    """Decode a jsonb column value asyncpg handed back as str."""
    if v is None:
        return None
    if isinstance(v, (str, bytes)):
        try:
            return json.loads(v)
        except Exception:
            return None
    return v


def _epoch(v) -> float | None:
    """Timestamp column -> epoch seconds."""
    if v is None:
        return None
    if isinstance(v, datetime):
        return v.timestamp()
    return None


# ---------------------------------------------------------------------------
# D10 lease + heartbeat
# ---------------------------------------------------------------------------


async def try_acquire_lease(ttl_sec: float) -> bool:
    """Atomic D10 lease claim: steal only when expired (or already
    ours). WHERE-clause arbitration means two replicas never both hold
    it."""
    row = await database.fetchrow(
        """
        UPDATE auto_router_state
        SET lease_owner = $1, lease_until = NOW() + make_interval(secs => $2::double precision)
        WHERE id = 1
          AND (lease_until IS NULL OR lease_until < NOW() OR lease_owner = $1)
        RETURNING lease_until
        """,
        LOOP_ID,
        float(ttl_sec),
    )
    return row is not None


async def _heartbeat_loop(ttl_sec: float, stop: asyncio.Event) -> None:
    """D10: heartbeat every min(15, ttl/3) DURING long ticks. The
    owner-guarded UPDATE can never resurrect a stolen lease."""
    period = rules.heartbeat_sec(ttl_sec)
    while not stop.is_set():
        try:
            await asyncio.wait_for(stop.wait(), timeout=period)
        except TimeoutError:
            pass
        if stop.is_set():
            return
        try:
            await database.execute(
                """
                UPDATE auto_router_state
                SET lease_until = NOW() + make_interval(secs => $1::double precision)
                WHERE id = 1 AND lease_owner = $2
                """,
                float(ttl_sec),
                LOOP_ID,
            )
        except Exception:
            logger.warning("reorder lease heartbeat failed", exc_info=True)


# ---------------------------------------------------------------------------
# Leader-gateway /stats poll (D1 pre-write mirror + D35 marker + D32
# mismatch-gauge passthrough)
# ---------------------------------------------------------------------------


def _pick_leader_node(rows):
    if config.reorder_leader_node:
        for r in rows:
            if r["name"] == config.reorder_leader_node:
                return r
    return rows[0] if rows else None


async def _node_get(path: str, cache: dict, max_age: float = 5.0) -> dict | None:
    now = time.time()
    if cache["data"] is not None and now - cache["at"] < max_age:
        return cache["data"]
    data = None
    try:
        rows = await database.fetch(
            "SELECT id, name, stats_host, stats_port, stats_token_ciphertext "
            "FROM gateway_nodes WHERE enabled = true ORDER BY id"
        )
        node = _pick_leader_node(rows)
        if node is not None:
            policy_on = await egress.egress_policy_on()
            token = egress.stats_token_for(
                node["stats_host"],
                node["stats_token_ciphertext"],
                config.stats_token,
                policy_on=policy_on,
            )
            if token is None:
                egress.note_skipped_no_token(node["name"], node["stats_host"])
            else:
                url = nodes.stats_url(node["stats_host"], node["stats_port"], path)
                headers = {"authorization": f"Bearer {token}"} if token else {}
                verify = probe_urls.tls_verify()
                async with httpx.AsyncClient(timeout=5.0, verify=verify) as client:
                    resp = await client.get(url, headers=headers)
                    if resp.status_code == 200:
                        data = resp.json()
    except Exception:
        logger.warning("reorder leader %s poll failed", path, exc_info=True)
        data = None
    cache.update(at=now, data=data)
    return data


async def leader_stats() -> dict | None:
    """/stats of the LEADER gateway: ``usage_attempt_rows`` (the D8
    pre-write mirror), ``reorder_enabled_refused_total`` and the D35
    ``reorder_reject`` marker when the gateway exposes one."""
    return await _node_get("/stats", _STATS_CACHE)


async def leader_sched() -> dict | None:
    """/stats/sched of the leader gateway — geo mismatch gauges
    passthrough for the state surface (D32/D4 observability)."""
    return await _node_get("/stats/sched", _SCHED_CACHE, max_age=15.0)


# ---------------------------------------------------------------------------
# §2 scorer — the SQL shape
# ---------------------------------------------------------------------------

_SCORE_SQL = """
SELECT m.name AS name,
       COUNT(*) AS terminal_count,
       COUNT(*) FILTER (
           WHERE ue.status BETWEEN 200 AND 299
             AND (ue.outcome IS NULL OR ue.outcome IN ('ok', 'success'))
       ) AS success_count,
       COUNT(*) FILTER (
           WHERE ue.status BETWEEN 200 AND 299
             AND (ue.outcome IS NULL OR ue.outcome IN ('ok', 'success'))
             AND ue.latency_ms IS NOT NULL
       ) AS p95_samples,
       PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY ue.latency_ms) FILTER (
           WHERE ue.status BETWEEN 200 AND 299
             AND (ue.outcome IS NULL OR ue.outcome IN ('ok', 'success'))
             AND ue.latency_ms IS NOT NULL
       ) AS p95_ms
FROM usage_events ue
JOIN models m ON m.id = ue.model_id
WHERE ue.ts >= $1
  AND ue.ts >= $2
  AND ue.outcome IS DISTINCT FROM 'cancelled'
  AND m.name = ANY($3)
GROUP BY m.name
"""


async def score_names(
    names: list[str], window_start: float, watermark: float, q_timeout: float
) -> dict:
    """One SQL pass per tick: terminal/success/p95-sample counts and the
    p95 via ``percentile_cont`` IN SQL (§2). ``window_start`` is the
    window edge; ``watermark`` is the 018 ledger applied_at (D36 — only
    rows at/after it count, so a mixed cluster's legacy rows cannot
    bias terminal_count). Cancelled rows are excluded here; the
    TF-A.0b writer pin means no-provider_id rows never exist (no
    either/or filter). Raises on query error/timeout (D33: the caller
    skips the tick)."""
    conn = await database.pool().acquire()
    try:
        rows = await conn.fetch(_SCORE_SQL, window_start, watermark, names, timeout=q_timeout)
    finally:
        await database.pool().release(conn)
    return {r["name"]: dict(r) for r in rows}


async def attempt_rows_watermark() -> float | None:
    """The TF-A.0b warm-up watermark: migration 018's ledger applied_at
    (D36). None => 018 not applied => no row can count (dry_run only)
    and the knob-side ingest guard is refusing enabled=true anyway."""
    row = await database.fetchrow(
        "SELECT EXTRACT(EPOCH FROM applied_at) AS wm FROM schema_migrations WHERE version = $1",
        ATTEMPT_ROWS_VERSION,
    )
    if row and row["wm"] is not None:
        return float(row["wm"])
    return None


# ---------------------------------------------------------------------------
# The tick
# ---------------------------------------------------------------------------


async def tick_once(trigger: str = "loop") -> dict:
    """One reorder tick. Every skip path bumps its D32 skip_reason
    counter and returns a small dict (the API tick endpoint surfaces the
    same result)."""
    _SKIP["ticks"] = _SKIP.get("ticks", 0) + 1
    knobs = await read_knobs()
    if not knobs["enabled"]:
        return _skip("disabled")
    # D1: primary DSN only — a replica or an unreadable DB never ticks.
    primary = await is_primary()
    if primary is not True:
        return _skip("not_primary")
    now = await db_now()
    st = await database.fetchrow("SELECT * FROM auto_router_state WHERE id = 1")
    if st is None:
        return _skip("no_state_row")
    # D26: quarantine gates tick evaluation AND commit.
    q_until = _epoch(st["reject_quarantined_until"])
    if q_until is not None and now < q_until:
        return _skip("quarantined", quarantine_until=st["reject_quarantined_until"].isoformat())
    ttl = rules.lease_ttl_sec(knobs["interval_sec"])
    if not await try_acquire_lease(ttl):
        return _skip("lease_not_held")
    # D35 marker poll BEFORE anything else: consumed-once regardless of
    # manual hold / newer commits (D26), and a compensating restore may
    # run through the system entrypoint (never sets last_manual_edit_at).
    stats = await leader_stats()
    marker_result = await poll_reject_marker(stats, knobs)
    st = await database.fetchrow("SELECT * FROM auto_router_state WHERE id = 1")
    # D30 manual hold: system writes (and scoring that would feed them)
    # wait out the hold; the marker machinery above already ran.
    hold_from = _epoch(st["last_manual_edit_at"])
    if hold_from is not None and now < hold_from + knobs["manual_hold_sec"]:
        return _skip("manual_hold", marker=marker_result)
    stop = asyncio.Event()
    hb = asyncio.create_task(_heartbeat_loop(ttl, stop))
    try:
        result = await _score_and_maybe_write(knobs, now, ttl, stats, marker_result)
    finally:
        stop.set()
        hb.cancel()
        try:
            await hb
        except asyncio.CancelledError:
            pass
    # Surface the D35 marker outcome on every post-marker skip path so
    # a restore that ran is never hidden behind a dwell/no-candidate skip.
    if marker_result and isinstance(result, dict):
        result.setdefault("marker", marker_result)
        _LAST_TICK.update({"marker": marker_result})
    return result


async def _score_and_maybe_write(
    knobs: dict, now: float, ttl: float, stats: dict | None, marker_result
) -> dict:
    raw, cfg = await read_auto_router()
    if cfg is None:
        return _skip("no_auto_router_cfg")
    tiers = cfg.get("tiers") if isinstance(cfg.get("tiers"), dict) else {}
    names = sorted({n for t in rules.TIERS for n in (tiers.get(t) or []) if isinstance(n, str)})
    watermark = await attempt_rows_watermark()
    agg: dict = {}
    if names and watermark is not None:
        try:
            agg = await score_names(
                names,
                now - knobs["window_sec"],
                watermark,
                rules.query_timeout_sec(ttl),
            )
        except (TimeoutError, asyncpg.PostgresError, OSError) as e:
            # D33: query error/timeout -> skip tick, no write.
            logger.warning("reorder scoring query failed (%s); tick skipped", type(e).__name__)
            return _skip("query_error")
    present: set = set()
    if names:
        present = {
            r["name"]
            for r in await database.fetch("SELECT name FROM models WHERE name = ANY($1)", names)
        }
    views = rules.build_views(names, agg, present, knobs)
    explore = _jload(
        (await database.fetchrow("SELECT explore_cooldown FROM auto_router_state WHERE id = 1"))[
            "explore_cooldown"
        ]
    )
    explore_until = float(explore.get("until") or 0.0) if isinstance(explore, dict) else 0.0
    candidate, actions, scored_any = rules.compute_candidate(
        tiers, views, knobs, now, explore_until
    )
    scores_payload = {t: {n: views.get(n) for n in (tiers.get(t) or [])} for t in rules.TIERS}
    if candidate is None:
        return _skip("no_candidate")
    # D36 warm-up: no scored member anywhere => dry_run only.
    dry_run = knobs["dry_run"] or not scored_any
    new_cfg = dict(cfg)
    new_cfg["tiers"] = candidate
    # D27 pending accumulation / dwell — LEASE-HELD only, under the
    # advisory lock (a stale leader cannot reset pending_since and
    # starve commits).
    async with database.transaction() as tx:
        if not await tx.fetchval("SELECT pg_try_advisory_xact_lock($1)", ADVISORY_XACT_KEY):
            return _skip("lock_busy")
        st = await tx.fetchrow(
            "SELECT pending_tiers, pending_since, last_auto_write_at, "
            "lease_owner, lease_until FROM auto_router_state WHERE id = 1"
        )
        owner_ok = await tx.fetchval(
            "SELECT lease_owner = $1 AND lease_until >= NOW() FROM auto_router_state WHERE id = 1",
            LOOP_ID,
        )
        if owner_ok is not True:
            return _skip("lease_lost")
        cand_json = rules.canonical(candidate)
        pend = _jload(st["pending_tiers"])
        decision = rules.pending_dwell_decision(
            pend,
            _epoch(st["pending_since"]),
            candidate,
            now,
            knobs["interval_sec"],
            _epoch(st["last_auto_write_at"]),
            knobs["window_sec"],
        )
        if decision["pending_changed"]:
            await tx.execute(
                "UPDATE auto_router_state SET pending_tiers = $1::jsonb, "
                "pending_since = NOW() WHERE id = 1",
                cand_json,
            )
            _SKIP["pending_updates"] = _SKIP.get("pending_updates", 0) + 1
        dwell_ok = decision["dwell_ok"]
        cooldown_ok = decision["cooldown_ok"]
    if not dwell_ok:
        return _skip("dwell", pending=candidate)
    if not cooldown_ok:
        return _skip("cooldown", pending=candidate)
    return await system_reorder_commit(
        before_cfg=cfg,
        after_cfg=new_cfg,
        expected_raw=raw,
        scores={**scores_payload, "actions": actions},
        dry_run=dry_run,
        kind="commit",
        explore_sec=(
            rules.explore_cooldown_sec(knobs["interval_sec"])
            if any(a["rule"] == "E" for a in actions)
            else None
        ),
        stats=stats,
    )


# ---------------------------------------------------------------------------
# D6(b) system entrypoint — the ONLY system tiers write path
# ---------------------------------------------------------------------------


async def system_reorder_commit(
    *,
    before_cfg: dict,
    after_cfg: dict,
    expected_raw: str,
    scores: dict,
    dry_run: bool = False,
    kind: str = "commit",
    explore_sec: float | None = None,
    stats: dict | None = None,
) -> dict:
    """Validate (shared parity validator), then in ONE xact under
    ``pg_try_advisory_xact_lock(90110011)`` with the D10 dual lease
    assert: CAS the settings jsonb, write the audit row, clear pending,
    bump the generation. NEVER touches ``last_manual_edit_at`` (D30).
    A CAS miss raises CasAbort OUT of the xact — Postgres rolls back
    everything including the pending clear (D14) and the generation is
    never bumped on a miss."""
    # Shared validator (D6 single-source): what we write must survive
    # the master's re-validation rules bit-for-bit.
    parity = rules.validate_tiers_master_parity(after_cfg.get("tiers"))
    if rules.canonical(parity) != rules.canonical(after_cfg.get("tiers")):
        logger.warning("reorder candidate failed the master-parity validator; not written")
        return _skip("validator_reject")
    # D8 pre-write mirror: no commit (restore included) while the
    # leader gateway does not advertise the TF-A.0b capability.
    if not dry_run:
        if stats is None:
            stats = await leader_stats()
        if not (stats or {}).get("usage_attempt_rows"):
            return _skip("attempt_rows_absent")
    new_raw = json.dumps(after_cfg, ensure_ascii=False)
    try:
        async with database.transaction() as tx:
            if not await tx.fetchval("SELECT pg_try_advisory_xact_lock($1)", ADVISORY_XACT_KEY):
                return _skip("lock_busy")
            # D10 dual assert INSIDE the commit xact: a stale scorer
            # whose heartbeat stalled cannot commit after a lease steal.
            owner_ok = await tx.fetchval(
                "SELECT lease_owner = $1 AND lease_until >= NOW() "
                "FROM auto_router_state WHERE id = 1",
                LOOP_ID,
            )
            if owner_ok is not True:
                return _skip("lease_lost")
            now_ep = float(await tx.fetchval("SELECT EXTRACT(EPOCH FROM NOW())"))
            if dry_run:
                # D32: compute + audit WITHOUT the CAS (and without the
                # gen bump / cooldown anchors — a dry run is not a write).
                await tx.execute(
                    """
                    INSERT INTO auto_router_audit
                        (actor, before_tiers, after_tiers, scores, kind)
                    VALUES ('system', $1::jsonb, $2::jsonb, $3::jsonb, 'dry_run')
                    """,
                    rules.canonical(before_cfg.get("tiers")),
                    rules.canonical(after_cfg["tiers"]),
                    rules.canonical({**scores, "dry_run": True, "at_epoch": now_ep}),
                )
                await tx.execute(
                    "UPDATE auto_router_state SET pending_tiers = NULL, "
                    "pending_since = NULL WHERE id = 1"
                )
                _SKIP["dry_run_audits"] = _SKIP.get("dry_run_audits", 0) + 1
                _LAST_TICK.update({"dry_run": True})
                return {"dry_run": True, "after_tiers": after_cfg["tiers"]}
            # D14 CAS: value must still be EXACTLY what we scored from.
            tag = await tx.execute(
                "UPDATE settings SET value = $1::jsonb, updated_at = NOW() "
                "WHERE key = $2 AND value = $3::jsonb",
                new_raw,
                AUTO_ROUTER_KEY,
                expected_raw,
            )
            if tag.split()[-1] != "1":
                raise CasAbort()
            gen = await database.bump_generation(tx)
            # D26 forward-commit reset carries its UNDO ledger entry:
            # the pre-reset count rides the audit row so a master reject
            # of THIS commit can restore the count the reset zeroed (a
            # commit the master rejects is not a "successful" forward
            # commit — else every reject is neutralized before the
            # quarantine trips, the exact failure D26 forbids).
            prev_rejects = 0
            if kind == "commit":
                prev_rejects = (
                    await tx.fetchval(
                        "SELECT consecutive_rejects FROM auto_router_state WHERE id = 1"
                    )
                ) or 0
            await tx.execute(
                """
                INSERT INTO auto_router_audit
                    (actor, before_tiers, after_tiers, scores, kind)
                VALUES ('system', $1::jsonb, $2::jsonb, $3::jsonb, $4)
                """,
                rules.canonical(before_cfg.get("tiers")),
                rules.canonical(after_cfg["tiers"]),
                rules.canonical(
                    {
                        **scores,
                        "gen": gen,
                        "at_epoch": now_ep,
                        **(
                            {"consecutive_rejects_before": prev_rejects} if kind == "commit" else {}
                        ),
                    }
                ),
                kind,
            )
            state_sql = (
                "UPDATE auto_router_state SET pending_tiers = NULL, "
                "pending_since = NULL, last_auto_write_at = NOW()"
            )
            state_args: list = []
            if kind == "commit":
                # D26: consecutive_rejects resets ONLY on a successful
                # FORWARD commit — never on restore, never on restart.
                state_sql += ", consecutive_rejects = 0"
            if explore_sec is not None:
                state_sql += ", explore_cooldown = $1::jsonb"
                state_args.append(rules.canonical({"until": now_ep + explore_sec}))
            state_sql += " WHERE id = 1"
            await tx.execute(state_sql, *state_args)
    except CasAbort:
        _SKIP["cas_abort"] = _SKIP.get("cas_abort", 0) + 1
        logger.warning(
            "cas_abort: auto_router settings changed under the reorder loop; "
            "xact rolled back (pending intact), next tick recomputes the candidate"
        )
        _LAST_TICK.update({"cas_abort": True})
        return {"skipped": "cas_abort"}
    audit.log(
        "reorder.system_commit" if kind == "commit" else "reorder.restore",
        AUTO_ROUTER_KEY,
        f"gen={gen} kind={kind} dry_run=False",
    )
    _LAST_TICK.clear()
    _LAST_TICK.update({"committed": kind, "gen": gen})
    return {"committed": kind, "gen": gen, "after_tiers": after_cfg["tiers"]}


# ---------------------------------------------------------------------------
# D6(a) human entrypoint — backing PUT /api/settings/auto-router
# ---------------------------------------------------------------------------


def _tier_exclusivity_problems(tiers: dict) -> list[str]:
    """Tier members are mutually exclusive across fast/big/flagship.

    The gateway tolerates a duplicate cross-tier member (it normalises
    with a warning), so a persisted duplicate silently changes
    cost/quality tiering — whichever tier the judge returns wins. The
    restore path already refuses this; the human write path must too
    (review 02d H1). Returns [] when every member has exactly one tier.
    """
    owner: dict[str, str] = {}
    problems: list[str] = []
    for tier in rules.TIERS:
        for name in tiers.get(tier) or []:
            previous = owner.get(name)
            if previous == tier:
                problems.append(f"tier member {name} appears more than once in tier {tier}")
            elif previous is not None:
                problems.append(
                    f"tier member {name} appears in more than one tier ({previous}, {tier})"
                )
            else:
                owner[name] = tier
    return problems


async def human_commit(cfg: dict) -> dict:
    """The human tiers write: takes the advisory lock FIRST (D34 busy
    => ReorderBusy => router answers 409 reorder_busy Retry-After 1),
    validates through the SHARED parity validator, writes the settings
    row + bumps the generation, writes the audit row (actor='human'),
    and stamps the D30/D35 anchors: last_manual_edit_at=NOW(), pending
    cleared, consecutive_rejects + reject_quarantined_until cleared
    (any manual write is the operator escape from a quarantine)."""
    parity = rules.validate_tiers_master_parity(cfg.get("tiers"))
    if rules.canonical(parity) != rules.canonical(cfg.get("tiers")):
        raise ValueError("tiers failed the master-parity validator")
    problems = _tier_exclusivity_problems(parity)
    if problems:
        # ValueError is the entrypoint's contract: the settings router
        # maps it to 400 {error:{code:"invalid_tiers",message}}.
        raise ValueError(
            "; ".join(problems) + " — tiers are mutually exclusive (fast > big > flagship)"
        )
    payload = json.dumps(cfg, ensure_ascii=False)
    async with database.transaction() as tx:
        if not await tx.fetchval("SELECT pg_try_advisory_xact_lock($1)", ADVISORY_XACT_KEY):
            raise ReorderBusy()
        prev = await tx.fetchrow("SELECT value FROM settings WHERE key = $1", AUTO_ROUTER_KEY)
        before_tiers = None
        if prev:
            prev_cfg = _jload(prev["value"])
            if isinstance(prev_cfg, dict):
                before_tiers = prev_cfg.get("tiers")
        await tx.execute(
            "INSERT INTO settings (key, value) VALUES ($1, $2::jsonb) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, "
            "updated_at = NOW()",
            AUTO_ROUTER_KEY,
            payload,
        )
        gen = await database.bump_generation(tx)
        await tx.execute(
            """
            INSERT INTO auto_router_audit
                (actor, before_tiers, after_tiers, scores, kind)
            VALUES ('human', $1::jsonb, $2::jsonb, NULL, 'commit')
            """,
            rules.canonical(before_tiers) if before_tiers is not None else None,
            rules.canonical(cfg.get("tiers")),
        )
        await tx.execute(
            """
            UPDATE auto_router_state SET
                last_manual_edit_at = NOW(),
                pending_tiers = NULL,
                pending_since = NULL,
                consecutive_rejects = 0,
                reject_quarantined_until = NULL
            WHERE id = 1
            """
        )
    return {"generation": gen}


# ---------------------------------------------------------------------------
# D35 reject/restore machinery
# ---------------------------------------------------------------------------


def _marker_at(marker: dict) -> float | None:
    at = marker.get("at")
    if isinstance(at, (int, float)) and not isinstance(at, bool):
        return float(at)
    if isinstance(at, str):
        try:
            return datetime.fromisoformat(at).timestamp()
        except ValueError:
            return None
    return None


async def poll_reject_marker(stats: dict | None, knobs: dict) -> dict | None:
    """Leader tick leg: the marker is the auto_router_state side-table
    row (authoritative — what the master's re-validation writes; marker
    writes never bump the generation and never distribute), with the
    /stats ``reorder_reject`` exposure as a bridge when the gateway
    only publishes there. Consumed-once: nulled when READ, whether the
    restore runs or is skipped."""
    st = await database.fetchrow("SELECT reject_marker FROM auto_router_state WHERE id = 1")
    marker = _jload(st["reject_marker"]) if st else None
    from_stats = False
    if not isinstance(marker, dict):
        cand = (stats or {}).get("reorder_reject")
        if isinstance(cand, dict):
            marker = cand
            from_stats = True
    if not isinstance(marker, dict):
        return None
    # A tombstone carrying the SAME identity means this /stats marker
    # was already consumed — a no-op poll.
    if from_stats and isinstance(st, dict):
        cur = _jload(st["reject_marker"]) if st else None
        if isinstance(cur, dict) and "consumed_at" in cur:
            identity = {k: cur.get(k) for k in ("gen", "tiers_sha", "reason")}
            if identity == {k: marker.get(k) for k in ("gen", "tiers_sha", "reason")}:
                return None
    return await _consume_reject_marker(marker, knobs, from_stats, stats)


async def _consume_reject_marker(
    marker: dict, knobs: dict, from_stats: bool, stats: dict | None = None
) -> dict:
    async with database.transaction() as tx:
        if not await tx.fetchval("SELECT pg_try_advisory_xact_lock($1)", ADVISORY_XACT_KEY):
            return {"skipped": "lock_busy"}
        row = await tx.fetchrow("SELECT reject_marker FROM auto_router_state WHERE id = 1")
        cur = _jload(row["reject_marker"]) if row else None
        if not isinstance(cur, dict):
            if not from_stats:
                # Vanished between the outer read and this xact: another
                # replica consumed it — nothing to do.
                return {"consumed": False}
            # /stats-only marker: the /stats exposure is read-only and
            # keeps returning the SAME dict every poll — claim +
            # null-in-one-xact re-reads it forever (re-bumping the
            # counters and re-running the restore each tick; ocr
            # medium). De-duplicate by IDENTITY: claim the row to a
            # distinct CONSUMED shape ({..., consumed_at}) instead of
            # nulling — a later poll matching an already-consumed
            # identity is a no-op.
            claimed = await tx.fetchrow(
                "UPDATE auto_router_state SET reject_marker = $1::jsonb "
                "WHERE id = 1 AND reject_marker IS NULL RETURNING reject_marker",
                rules.canonical(marker),
            )
            if claimed is None:
                # Someone else consumed first (or the row holds a newer
                # marker) — nothing to do for THIS identity.
                return {"consumed": False}
            cur = marker
        elif rules.canonical(cur) != rules.canonical(marker):
            # The side-table row is authoritative (newer than the
            # /stats copy) — handle THAT one.
            marker = cur
        # D26: consumed-once. The DB-sourced row is cleared (the
        # master writes a fresh one on the next reject). For a
        # /stats-sourced identity we leave a TOMBSTONE (consumed_at
        # + the original marker) so the read-only /stats copy can
        # never re-trigger (ocr medium).
        tombstone = dict(marker)
        tombstone["consumed_at"] = int(await db_now())
        await tx.execute(
            "UPDATE auto_router_state SET reject_marker = $1::jsonb WHERE id = 1",
            rules.canonical(tombstone) if from_stats else None,
        )
    _SKIP["reorder_reject_total"] = _SKIP.get("reorder_reject_total", 0) + 1
    marker_brief = {k: marker.get(k) for k in ("gen", "tiers_sha", "reason")}
    logger.error("REORDER REJECT detected on the master: %s (alert)", marker_brief)
    audit.log("reorder.reject_detected", AUTO_ROUTER_KEY, str(marker_brief))
    # A restore that is ITSELF rejected must not increment the cycle
    # counter (compensation failures alert, never quarantine): detect
    # by tiers_sha matching the latest restore row's after_tiers.
    last_restore = await database.fetchrow(
        "SELECT after_tiers, at FROM auto_router_audit WHERE kind = 'restore' "
        "ORDER BY id DESC LIMIT 1"
    )
    if last_restore is not None and marker.get("tiers_sha"):
        after = _jload(last_restore["after_tiers"])
        if isinstance(after, dict) and rules.tiers_sha(after) == marker["tiers_sha"]:
            logger.error(
                "reorder restore rejected again (compensation failure) — "
                "alert only, consecutive_rejects NOT incremented"
            )
            audit.log("reorder.restore_rejected", AUTO_ROUTER_KEY, f"marker={marker_brief}")
            return {"consumed": True, "restore": "skipped_restore_reject"}
    # Forward reject: increment the RAW consecutive count (D35 —
    # structural causes yielding different candidates still trip it).
    # When the rejected write IS the latest commit row (the standard
    # case), that commit's D26 reset already zeroed the count — use the
    # pre-reset value the commit row recorded, so two rejects with only
    # rejected writes between them still trip the quarantine.
    latest_commit = await database.fetchrow(
        "SELECT after_tiers, scores FROM auto_router_audit "
        "WHERE kind = 'commit' ORDER BY id DESC LIMIT 1"
    )
    count_override = None
    if latest_commit is not None and marker.get("tiers_sha"):
        after = _jload(latest_commit["after_tiers"])
        if isinstance(after, dict) and rules.tiers_sha(after) == marker["tiers_sha"]:
            sc = _jload(latest_commit["scores"])
            if isinstance(sc, dict) and isinstance(sc.get("consecutive_rejects_before"), int):
                count_override = sc["consecutive_rejects_before"] + 1
    quarantined = False
    async with database.transaction() as tx:
        if count_override is not None:
            n = await tx.fetchval(
                "UPDATE auto_router_state SET consecutive_rejects = $1 "
                "WHERE id = 1 RETURNING consecutive_rejects",
                count_override,
            )
        else:
            n = await tx.fetchval(
                """
                UPDATE auto_router_state SET consecutive_rejects = consecutive_rejects + 1
                WHERE id = 1 RETURNING consecutive_rejects
                """
            )
        if (n or 0) >= REJECT_TRIP:
            await tx.execute(
                "UPDATE auto_router_state SET reject_quarantined_until = "
                "NOW() + make_interval(secs => $1::double precision) WHERE id = 1",
                float(rules.quarantine_sec(knobs["interval_sec"])),
            )
            quarantined = True
    if quarantined:
        logger.error(
            "reorder quarantined after %d consecutive master rejects "
            "(10x interval); operator escape = human PUT /auto-router",
            REJECT_TRIP,
        )
        audit.log("reorder.quarantined", AUTO_ROUTER_KEY, f"consecutive_rejects={REJECT_TRIP}")
    return await _maybe_restore(marker, knobs, marker_brief, stats)


async def _maybe_restore(
    marker: dict, knobs: dict, marker_brief: dict, stats: dict | None = None
) -> dict:
    """Compensating restore: source = the LATEST kind='commit' audit
    row's before_tiers (never a reject row; dry_run rows are a separate
    kind so they cannot masquerade). Skips (with an alert, never
    silently) when a manual PUT or a newer commit landed since the
    rejected write — a stale compensation must never undo newer
    writes. Runs through the SYSTEM entrypoint (never sets
    last_manual_edit_at)."""
    at = _marker_at(marker)
    if at is None:
        logger.error("reorder marker carries no usable 'at'; restore skipped")
        return {"restore": "skipped_bad_marker"}
    st = await database.fetchrow("SELECT last_manual_edit_at FROM auto_router_state WHERE id = 1")
    manual_at = _epoch(st["last_manual_edit_at"]) if st else None
    if manual_at is not None and manual_at > at:
        logger.error("reorder restore skipped: manual PUT newer than the reject")
        audit.log("reorder.restore_skipped", AUTO_ROUTER_KEY, "reason=manual_put_newer")
        return {"restore": "skipped_manual_put"}
    latest = await database.fetchrow(
        "SELECT at, actor, before_tiers, after_tiers FROM auto_router_audit "
        "WHERE kind = 'commit' ORDER BY id DESC LIMIT 1"
    )
    if latest is None:
        # Single-commit / no-commit clusters: nothing earlier to restore.
        logger.error("reorder restore no-op: no kind=commit audit row (alert)")
        audit.log("reorder.restore_skipped", AUTO_ROUTER_KEY, "reason=no_commit_row")
        return {"restore": "skipped_no_commit_row"}
    after = _jload(latest["after_tiers"])
    if not (
        marker.get("tiers_sha")
        and isinstance(after, dict)
        and rules.tiers_sha(after) == marker["tiers_sha"]
    ):
        # The latest commit is NOT the rejected write — a newer
        # successful commit landed; compensating would undo it.
        logger.error("reorder restore skipped: newer commit than the rejected write")
        audit.log("reorder.restore_skipped", AUTO_ROUTER_KEY, "reason=newer_commit")
        return {"restore": "skipped_newer_commit"}
    # An OPERATOR membership change newer than the rejected commit makes
    # `before_tiers` stale: replaying it would resurrect a name the operator
    # deliberately removed (the cascade journal is the durable record of that
    # surgery) and hand the next Router save a 400 not_bound. The
    # last_manual_edit_at anchor above is NOT sufficient — it is compared
    # against the MARKER's `at`, so a reject that reaches us after the
    # cascade (poll_reject_marker re-imports a still-exposed reject whenever
    # the side-table row is NULL) wins and commits the resurrection.
    cascade_at = await database.fetchval(
        "SELECT max(at) FROM config_cascade_events WHERE at > $1", latest["at"]
    )
    if cascade_at is not None:
        logger.error(
            "reorder restore skipped: cascade at %s is newer than the rejected commit %s",
            cascade_at,
            latest["at"],
        )
        audit.log("reorder.restore_skipped", AUTO_ROUTER_KEY, "reason=cascade_newer")
        return {"restore": "skipped_cascade_newer"}
    source = _jload(latest["before_tiers"])
    if not isinstance(source, dict):
        logger.error("reorder restore no-op: commit row lacks before_tiers")
        audit.log("reorder.restore_skipped", AUTO_ROUTER_KEY, "reason=no_before_tiers")
        return {"restore": "skipped_no_before_tiers"}
    raw, cfg = await read_auto_router()
    if cfg is None:
        return {"restore": "skipped_no_cfg"}
    current = cfg.get("tiers") if isinstance(cfg.get("tiers"), dict) else {}
    if rules.canonical(current) == rules.canonical(source):
        return {"restore": "noop_already_restored"}
    # Belt-and-braces (adversarial item D): never write a tier member that is
    # not currently bound. A stale `before_tiers` can survive when a commit row
    # lands after the cascade — reachable via the deferred-prune state, where
    # the tier keeps an unbound name while its model is disabled. The
    # config-restore path refuses exactly this with 422 tiers_invalid; here we
    # skip the compensation, which cannot re-break anything: the member the
    # gateway rejected is already gone.
    wanted = {
        item if isinstance(item, str) else item.get("name")
        for value in source.values()
        if isinstance(value, list)
        for item in value
    } - {None, ""}
    if wanted:
        bound = {
            r["name"]
            for r in await database.fetch(
                "SELECT DISTINCT m.name FROM models m WHERE m.enabled = 1 "
                "AND EXISTS (SELECT 1 FROM model_routes r "
                "WHERE r.model_id = m.id AND r.enabled = 1)"
            )
        }
        unbound = sorted(wanted - bound)
        if unbound:
            logger.error("reorder restore skipped: unbound tier members %s", unbound)
            audit.log(
                "reorder.restore_skipped",
                AUTO_ROUTER_KEY,
                f"reason=unbound_member members={','.join(unbound)}",
            )
            return {"restore": "skipped_unbound_member", "unbound": unbound}
    new_cfg = dict(cfg)
    new_cfg["tiers"] = source
    result = await system_reorder_commit(
        before_cfg=cfg,
        after_cfg=new_cfg,
        expected_raw=raw,
        scores={"restore": {"marker": marker_brief}},
        dry_run=False,
        kind="restore",
        stats=stats,
    )
    if result.get("committed") == "restore":
        logger.error("reorder restore committed (before-tiers restored, gen %s)", result.get("gen"))
    return result


# ---------------------------------------------------------------------------
# State surface (D32) — GET /api/settings/auto-router/reorder-state
# ---------------------------------------------------------------------------


async def reorder_state_payload() -> dict:
    knobs = await read_knobs()
    st = await database.fetchrow("SELECT * FROM auto_router_state WHERE id = 1")
    _raw, cfg = await read_auto_router()
    stats = await leader_stats()
    sched = await leader_sched()
    watermark = None
    try:
        watermark = await attempt_rows_watermark()
    except Exception:
        watermark = None
    pending = _jload(st["pending_tiers"]) if st else None
    explore = _jload(st["explore_cooldown"]) if st else None
    audit_rows = await database.fetch(
        "SELECT id, at, actor, kind, before_tiers, after_tiers "
        "FROM auto_router_audit ORDER BY id DESC LIMIT 10"
    )
    now = await db_now()
    payload = {
        "loop": {
            "active": _loop_task is not None and not _loop_task.done(),
            "loop_id": LOOP_ID,
            "kill_switch": not config.reorder_loop_enabled,
            "skip_reasons": dict(sorted(_SKIP.items())),
            "last_tick": dict(_LAST_TICK),
        },
        "knobs": knobs,
        "enabled": knobs["enabled"],
        "dry_run": knobs["dry_run"],
        "tiers": (cfg or {}).get("tiers"),
        "auto_router_source": "db" if cfg is not None else "default",
        "pending": None,
        "explore_cooldown": explore,
        "lease": None,
        "quarantine": None,
        "reject_marker_pending": _jload(st["reject_marker"]) if st else None,
        "last_auto_write_at": st["last_auto_write_at"].isoformat()
        if st and st["last_auto_write_at"]
        else None,
        "last_manual_edit_at": st["last_manual_edit_at"].isoformat()
        if st and st["last_manual_edit_at"]
        else None,
        "warmup": {
            "attempt_rows_version": ATTEMPT_ROWS_VERSION,
            "watermark_at": watermark,
            # D36: until the watermark exists no member can be scored.
            "capable": watermark is not None,
        },
        "gateway": {
            "polled": stats is not None,
            "usage_attempt_rows": (stats or {}).get("usage_attempt_rows"),
            "reorder_enabled_refused_total": (stats or {}).get("reorder_enabled_refused_total"),
            # D32 geo mismatch gauges passthrough (/stats/sched).
            "geo_mismatch": (sched or {}).get("geo_mismatch"),
        },
        "audit_recent": [
            {
                "id": r["id"],
                "at": r["at"].isoformat(),
                "actor": r["actor"],
                "kind": r["kind"],
                "before_tiers": _jload(r["before_tiers"]),
                "after_tiers": _jload(r["after_tiers"]),
            }
            for r in audit_rows
        ],
    }
    if st is not None:
        since = _epoch(st["pending_since"])
        payload["pending"] = {
            "tiers": pending,
            "since": st["pending_since"].isoformat() if st["pending_since"] else None,
            "age_sec": round(now - since, 1) if since is not None else None,
        }
        payload["lease"] = {
            "owner": st["lease_owner"],
            "until": st["lease_until"].isoformat() if st["lease_until"] else None,
            "held_by_this_leader": st["lease_owner"] == LOOP_ID,
        }
        payload["quarantine"] = {
            "consecutive_rejects": st["consecutive_rejects"],
            "until": st["reject_quarantined_until"].isoformat()
            if st["reject_quarantined_until"]
            else None,
        }
    return payload


# ---------------------------------------------------------------------------
# Lifespan wiring (mirrors nodes/entitlements start/stop conventions)
# ---------------------------------------------------------------------------


async def _loop() -> None:
    while True:
        try:
            knobs = await read_knobs()
        except Exception:
            knobs = None
        interval = (knobs or {}).get("interval_sec", rules.KNOB_DEFAULTS["interval_sec"])
        await asyncio.sleep(interval)
        try:
            result = await tick_once(trigger="loop")
            logger.info("reorder tick: %s", result)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("reorder tick crashed")


async def start_background() -> None:
    global _loop_task
    if not config.reorder_loop_enabled:
        logger.info("reorder loop NOT started (JANUS_REORDER_LOOP=0 kill switch, A.29)")
        return
    if _loop_task is None or _loop_task.done():
        _loop_task = asyncio.create_task(_loop())
        logger.info("auto-router reorder loop started (id=%s)", LOOP_ID)


async def stop_background() -> None:
    global _loop_task
    if _loop_task is not None:
        _loop_task.cancel()
        try:
            await _loop_task
        except asyncio.CancelledError:
            pass
    _loop_task = None
