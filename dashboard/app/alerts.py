"""Alert evaluator + webhook outbox (observability-depth Task 6 +
failure-observability Task 7).

Rules are evaluated once per health-poll cycle from in-memory node
snapshots plus DB rows (entitlements, probe budget, persisted health
snapshots, task_runs):

  1. node_unreachable      (scope=node, critical) — consecutive poll
     failures >= 3; exempt from for_cycles (3 strikes x 10s IS the
     persistence). Resolves only on a successful poll or scope removal.
  2. node_error_rate       (scope=node, warning) — counter deltas of
     /stats requests_total/requests_failed over the trailing deque of
     the last 6 snapshots (owned + pruned by the nodes.py hook); fires
     when dfailed/dtotal > JANUS_ALERT_ERROR_RATE_PCT with dtotal >=
     JANUS_ALERT_ERROR_RATE_MIN_TOTAL. Cold start (<2 snapshots) and
     counter decreases (node restart; the hook clears the deque) are
     skips, never resolves.
  3. generation_desync     (scope=fleet, warning) — max != min of the
     per-node generation across enabled healthy nodes. Fires during
     every rolling deploy by design; silencable via
     JANUS_ALERT_RULES_DISABLED.
  4. entitlement_mass_deny (scope=provider, warning) — deny+balance+
     broken rows / total >= 50% with total >= 3, from key_entitlements,
     enabled providers only. Zero rows = skip (no transition).
  5. probe_budget_exhausted(scope=provider, info) — today's
     probe_budget_counters.calls >= JANUS_PROBE_DAILY_CALLS, enabled
     providers only. Row absent or below cap = qualified clean.
  6. cool_mass             (scope=node name OR provider:{id}, warning) —
     ≥5 distinct cooling targets (provider not double-counted with its
     keys); overflow uses cool_count / cool_provider_counts. Stale
     snapshot → skip. cool_ids_overflow for M=3 consecutive polls
     auto-resolves firing cool_mass (escape).
  7. entity_error_rate     (scope=kind:id, warning) — entity in
     degraded_ids / rates degraded for for_cycles. Resolve via clear
     bands, absence (non-truncation), or rates_evicted. Stale → skip.
  8. task_consecutive_fail (scope=node_id/task, warning) — last K=3
     finished outcomes ∈ fail set; resolve on later ok. Gate on
     ops_lagging=false. Pruned history = no-data. Time honesty (Task
     21): when the newest finished run is older than the staleness
     threshold derived from the task's own schedule interval (2× the
     interval, floored at 5 min / 12 h fallback / 7 d cap), the same
     episode is reported STALE with its last-run timestamp instead of as
     a repeated failure — the gateway resets a task's timer on restart
     without running it, so a frozen failing counter otherwise repeats a
     false "failed 3×" forever. A stopped task is NEVER resolved away or
     dropped: it stays a breach, only the wording changes. Error
     class/component detail from task_runs is surfaced instead of a bare
     "error,error,error".
  9. key_daily_budget    (scope=key:{agent_key_id}, warning) — H8-D3:
     today's PRICED spend (query-time over usage_events x model_prices,
     unpriced models never estimated) >= api_keys.daily_cost_limit.
     Evaluated every cycle from SQL (the evidence is a monotone daily
     total, so for_cycles is 1 like node_unreachable); daily spend is
     cumulative ⇒ one fire per key per day; midnight's fresh (low)
     total is the qualified clean that resolves the episode. NO
     enforcement — WARN alert row + webhook only.
 10. worker_pool_loss   (scope=worker node name, warning) — a worker
     the capacity plane previously reported is absent from a FRESH
     /stats/sched scrape. Present = qualified clean; no fresh scrape
     (all sched caches frozen/errored) = no-data — master loss is
     node_unreachable's beat, not this rule's. Fires when the pool row
     vanishes (dist nodedown), which with default OS TCP keepalive can
     lag silent link death by ~2h (tune net.ipv4.tcp_keepalive_time).
     Absent >= 24h auto-resolves as "assumed decommissioned" so a
     deliberate worker removal does not alert forever.
 11. usage_writer_stall (scope=node, critical) — the gateway's usage
     writer is buffering rows without flushing them to usage_events.
     /stats usage_writer.buffered >= 25 for for_cycles consecutive
     polls (a healthy writer drains on the 1s tick, so steady state
     reads 0-2; >= 25 sustained means the ledger has stopped).
     usage_writer.alive = false is a breach outright (events drop at
     the cast). buffered < 5 = qualified clean. Missing usage_writer
     (older gateway image) = skip. This is the 2026-10-23 incident
     class: a stuck flush gate buffered silently for hours with zero
     logs — only restart-time terminate bursts ever wrote rows.
  Scope-vanish reconciliation (run_once): a firing state whose scope
  is no longer monitored (deleted or disabled node/provider)
  auto-resolves with detail "scope_removed".

Locked semantics (plan rev 24 FM-8 / episode semantics):

- Firing hysteresis: firing->resolved requires QUALIFIED clean evidence
  (per-rule semantics above); skips/no-data are no-transition outcomes.
- One fire + one resolve webhook per episode; no reminder re-fires.
  Rule 8 keeps one episode across a verdict-class flip (fresh failure ↔
  stale): the flip inserts an inert 'firing' event (delivered=TRUE, no
  next_retry_at ⇒ the outbox never picks it) so the alerts API — which
  renders the LATEST firing event's message — follows the new wording
  without a new fire, audit transition or webhook delivery. Task 26
  reuses that same inert write when the rendered MESSAGE content changes
  (e.g. the gateway starts classifying the failure: bad_json/provider),
  so the class detail reaches the operator instead of stopping at
  task_runs; an unchanged verdict still writes nothing.
- The post-resolve refire guard (JANUS_ALERT_REFIRE_COOLDOWN_SEC, 30 min
  default) is transition-level suppression: a breach inside the window
  creates NO new episode (streaks may accumulate; nothing is inserted);
  a fresh scope always fires.
- for_cycles breach persistence (global JANUS_ALERT_FOR_CYCLES=2, rule 1
  exempt): streaks live in module memory AND alert_state.cycles so a
  dashboard restart does not reset the persistence window.
- run_once acquires pg_advisory_xact_lock(90110013) at ENTRY: the
  alert_state read, the transition decisions and the upsert+insert all
  run inside that one transaction (two concurrent runs can no longer
  both read state=ok and double-fire).
- Pause is cross-process via the alert_control sentinel row (checked by
  the spawned evaluator each cycle BEFORE any 90110013 transaction; a
  pause older than 15 minutes is expired: logged + auto-cleared).
"""

import asyncio
import json
import logging
import re
import time
from datetime import UTC, datetime
from typing import Any

import httpx

from . import audit, database, spend
from .config import config

logger = logging.getLogger("janus.dashboard.alerts")

# Advisory xact lock serializing run_once across processes (the live
# evaluator and the alerts_debug driver). Distinct from the maintenance
# prune lock 90110012.
ADVISORY_LOCK_KEY = 90110013

EVAL_DEADLINE_SEC = 4.0  # overall monotonic budget per evaluation task
STATEMENT_TIMEOUT_MS = 2000  # per-statement inside run_once's transaction
PAUSE_EXPIRY_SEC = 900  # a pause older than 15 min auto-clears
HEARTBEAT_SEC = 3600  # alert_state.last_eval_at refresh cadence
SENDER_TICK_SEC = 2.0
MAX_ATTEMPTS = 8
PICK_LIMIT = 20
BACKOFF_CAP_SEC = 300

RULE_NODE_UNREACHABLE = "node_unreachable"
RULE_NODE_ERROR_RATE = "node_error_rate"
RULE_GENERATION_DESYNC = "generation_desync"
RULE_ENTITLEMENT_MASS_DENY = "entitlement_mass_deny"
RULE_PROBE_BUDGET_EXHAUSTED = "probe_budget_exhausted"
RULE_COOL_MASS = "cool_mass"
RULE_ENTITY_ERROR_RATE = "entity_error_rate"
RULE_TASK_CONSECUTIVE_FAIL = "task_consecutive_fail"
RULE_KEY_DAILY_BUDGET = "key_daily_budget"
RULE_WORKER_POOL_LOSS = "worker_pool_loss"
RULE_USAGE_WRITER_STALL = "usage_writer_stall"

RULE_SEVERITY = {
    RULE_NODE_UNREACHABLE: "critical",
    RULE_NODE_ERROR_RATE: "warning",
    RULE_GENERATION_DESYNC: "warning",
    RULE_ENTITLEMENT_MASS_DENY: "warning",
    RULE_PROBE_BUDGET_EXHAUSTED: "info",
    RULE_COOL_MASS: "warning",
    RULE_ENTITY_ERROR_RATE: "warning",
    RULE_TASK_CONSECUTIVE_FAIL: "warning",
    RULE_KEY_DAILY_BUDGET: "warning",
    RULE_WORKER_POOL_LOSS: "warning",
    RULE_USAGE_WRITER_STALL: "critical",
}
# Scope-kind per rule, for scope-vanish reconciliation. "fleet" scopes
# never vanish. cool_mass uses dual scopes (bare node name OR
# provider:{id}); entity/task use compound scopes — see _scope_exists.
RULE_SCOPE_KIND = {
    RULE_NODE_UNREACHABLE: "node",
    RULE_NODE_ERROR_RATE: "node",
    RULE_GENERATION_DESYNC: "fleet",
    RULE_ENTITLEMENT_MASS_DENY: "provider",
    RULE_PROBE_BUDGET_EXHAUSTED: "provider",
    RULE_COOL_MASS: "cool_mass",
    RULE_ENTITY_ERROR_RATE: "entity",
    RULE_TASK_CONSECUTIVE_FAIL: "task",
    RULE_KEY_DAILY_BUDGET: "agent_key",
    RULE_WORKER_POOL_LOSS: "worker",
    RULE_USAGE_WRITER_STALL: "node",
}
FLEET_SCOPE = "fleet"

# Spec §8: cool mass threshold / overflow-escape polls; task fail streak;
# stale = N missed health polls (10s cadence).
COOL_MASS_N = 5
COOL_OVERFLOW_ESCAPE_M = 3
TASK_FAIL_K = 3
TASK_FAIL_OUTCOMES = frozenset({"error", "timeout", "crash", "orphan", "internal"})
# Rule 8 staleness (Task 21 — signal quality). The threshold is derived
# from the task's own schedule interval: 2× the interval, floored so a
# fast task cannot flip on a momentary gap, capped so an absurd interval
# cannot disable the check, and with a fallback for rows that carry no
# interval at all. Interval is read per run (the gateway stamps
# schedule_interval_ms on every terminal task_runs row).
TASK_STALE_INTERVAL_MULT = 2
TASK_STALE_FLOOR_SEC = 300  # 5 min: never call a task stale before this
TASK_STALE_FALLBACK_SEC = 12 * 3600  # no interval on any of the last K runs
TASK_STALE_MAX_SEC = 7 * 24 * 3600  # 7 d: cap, so huge intervals still alert
TASK_ERROR_MAX_CHARS = 160  # error text surfaced in the alert message
TASK_VARIANT_FRESH = "fresh_failure"  # last K failed AND still being retried
TASK_VARIANT_STALE = "stale"  # last K failed but the task stopped running
WORKER_DECOMMISSION_SEC = 24 * 3600
SNAPSHOT_STALE_SEC = 30  # 3 missed polls × 10s
# Rule 11: a healthy writer drains its buffer on the 1s tick (steady
# state reads 0-2), so a sustained reading far above that means the
# flush path has stalled; < 5 (in-flight burst between ticks) is clean.
USAGE_STALL_BUFFERED_ROWS = 25
USAGE_STALL_CLEAN_ROWS = 5
CLEAR_RATIO = 0.35
DEADBAND_RATIO = 0.5

# One evaluation result: (rule, scope, severity, breached, message, detail).
# breached is True (breach), False (qualified clean) or None (skip —
# no-transition under firing hysteresis).
EvalResult = tuple[str, str, str, bool | None, str, dict | None]

# Consecutive-breach streaks per (rule, scope) — module-level, mutated by
# run_once. Seeded from alert_state.cycles at the start of each run so a
# dashboard restart does not erase for_cycles persistence (spec §7).
_streaks: dict[tuple[str, str], int] = {}
# cool_ids_overflow consecutive-poll counters (node name → count); M
# consecutive overflows auto-resolve firing cool_mass for that node.
_overflow_streaks: dict[str, int] = {}
# Rule 7: consecutive polls where a previously-degraded entity is absent
# (non-truncation) or listed in rates_evicted.
_absent_streaks: dict[tuple[str, str], int] = {}
_evicted_streaks: dict[tuple[str, str], int] = {}
# Rule 10: wall-clock last-present and first-absent stamps per worker
# node name (module memory; run_once re-arms both from firing state
# after a dashboard restart).
_worker_seen: dict[str, float] = {}
_worker_absent_since: dict[str, float] = {}
# asyncio keeps only weak refs to tasks; hold ours or a GC cycle could
# drop a running evaluation/sender task.
_tasks: set[asyncio.Task] = set()
_eval_in_flight = False
_pause_observed = False
_stats = {"overlap_skips": 0, "paused_skips": 0, "deadline_exceeded": 0}


# ---------------------------------------------------------------------------
# Pure rule evaluation (Step 2/3)
# ---------------------------------------------------------------------------


def _for_cycles(rule: str) -> int:
    # node_unreachable is exempt: 3 strikes x 10s IS the persistence.
    # key_daily_budget is exempt for the same reason in reverse: its
    # evidence is a monotone SQL daily total, not a transient signal —
    # a single read is already qualified (H8-D3).
    if rule in (RULE_NODE_UNREACHABLE, RULE_KEY_DAILY_BUDGET):
        return 1
    return max(1, config.alert_for_cycles)


def _eval_node_unreachable(snapshots: dict, db_rows: dict) -> list[EvalResult]:
    out: list[EvalResult] = []
    for node in snapshots.get("nodes") or []:
        name = node.get("name")
        if not name:
            continue
        failures = node.get("consecutive_failures") or 0
        status = node.get("status")
        if failures >= 3:
            out.append(
                (
                    RULE_NODE_UNREACHABLE,
                    name,
                    RULE_SEVERITY[RULE_NODE_UNREACHABLE],
                    True,
                    f"node {name} unreachable ({failures} consecutive poll failures)",
                    {"consecutive_failures": failures},
                )
            )
        elif status == "healthy":
            # Successful poll — the ONLY in-band resolve evidence.
            out.append(
                (
                    RULE_NODE_UNREACHABLE,
                    name,
                    RULE_SEVERITY[RULE_NODE_UNREACHABLE],
                    False,
                    f"node {name} reachable",
                    None,
                )
            )
        else:
            # unreachable <3 strikes / unhealthy / stale_no_token: skip.
            out.append(
                (
                    RULE_NODE_UNREACHABLE,
                    name,
                    RULE_SEVERITY[RULE_NODE_UNREACHABLE],
                    None,
                    f"node {name} status {status}",
                    None,
                )
            )
    return out


def _eval_node_error_rate(snapshots: dict, db_rows: dict) -> list[EvalResult]:
    out: list[EvalResult] = []
    min_total = config.alert_error_rate_min_total
    pct = config.alert_error_rate_pct
    for name, window in (snapshots.get("windows") or {}).items():
        points = [w for w in window if isinstance(w, (list, tuple)) and len(w) >= 3]
        if len(points) < 2:
            # Cold start: no delta exists yet — skip, never resolve.
            out.append(
                (
                    RULE_NODE_ERROR_RATE,
                    name,
                    RULE_SEVERITY[RULE_NODE_ERROR_RATE],
                    None,
                    f"node {name} cold start ({len(points)} snapshot)",
                    None,
                )
            )
            continue
        _, first_total, first_failed = points[0]
        _, last_total, last_failed = points[-1]
        d_total = last_total - first_total
        d_failed = last_failed - first_failed
        if d_total < 0 or d_failed < 0:
            # Counter decrease (node restart). The hook clears the deque
            # on decrease, so this is belt-and-braces: never let a window
            # straddle a restart.
            out.append(
                (
                    RULE_NODE_ERROR_RATE,
                    name,
                    RULE_SEVERITY[RULE_NODE_ERROR_RATE],
                    None,
                    f"node {name} counter reset",
                    None,
                )
            )
            continue
        ratio = (d_failed / d_total) if d_total > 0 else 0.0
        if d_total >= min_total and ratio * 100.0 > pct:
            out.append(
                (
                    RULE_NODE_ERROR_RATE,
                    name,
                    RULE_SEVERITY[RULE_NODE_ERROR_RATE],
                    True,
                    f"node {name} error rate {ratio:.0%} over the trailing window "
                    f"({d_failed}/{d_total} failed)",
                    {"delta_total": d_total, "delta_failed": d_failed, "ratio": round(ratio, 4)},
                )
            )
        else:
            # Valid deltas present and below threshold = qualified clean.
            out.append(
                (
                    RULE_NODE_ERROR_RATE,
                    name,
                    RULE_SEVERITY[RULE_NODE_ERROR_RATE],
                    False,
                    f"node {name} error rate {ratio:.0%}",
                    None,
                )
            )
    return out


def _eval_generation_desync(snapshots: dict, db_rows: dict) -> list[EvalResult]:
    generations: dict[str, int] = {}
    for node in snapshots.get("nodes") or []:
        if node.get("status") != "healthy":
            continue
        gen = node.get("generation")
        if isinstance(gen, (int, float)):
            generations[node.get("name") or "?"] = int(gen)
    if not generations:
        return [
            (
                RULE_GENERATION_DESYNC,
                FLEET_SCOPE,
                RULE_SEVERITY[RULE_GENERATION_DESYNC],
                None,
                "no healthy node generation data",
                None,
            )
        ]
    values = list(generations.values())
    if max(values) != min(values):
        return [
            (
                RULE_GENERATION_DESYNC,
                FLEET_SCOPE,
                RULE_SEVERITY[RULE_GENERATION_DESYNC],
                True,
                f"fleet config generation desync: min={min(values)} max={max(values)} "
                f"across {len(values)} nodes",
                {"generations": generations},
            )
        ]
    return [
        (
            RULE_GENERATION_DESYNC,
            FLEET_SCOPE,
            RULE_SEVERITY[RULE_GENERATION_DESYNC],
            False,
            f"fleet generation aligned at {values[0]}",
            None,
        )
    ]


def _eval_entitlement_mass_deny(snapshots: dict, db_rows: dict) -> list[EvalResult]:
    out: list[EvalResult] = []
    for provider, counts in (db_rows.get("entitlements") or {}).items():
        total = int(counts.get("total") or 0)
        if total < 1:
            # Zero rows = skip (no transition).
            out.append(
                (
                    RULE_ENTITLEMENT_MASS_DENY,
                    provider,
                    RULE_SEVERITY[RULE_ENTITLEMENT_MASS_DENY],
                    None,
                    f"provider {provider} has no entitlement rows",
                    None,
                )
            )
            continue
        bad = (
            int(counts.get("deny", 0))
            + int(counts.get("balance", 0))
            + int(counts.get("broken", 0))
        )
        share = bad / total
        if total >= 3 and share >= 0.5:
            top = max(("deny", "balance", "broken"), key=lambda k: counts.get(k, 0))
            hint = {
                "balance": "likely out of funds",
                "deny": "provider entitlements likely missing",
                "broken": "keys failing authentication",
            }[top]
            out.append(
                (
                    RULE_ENTITLEMENT_MASS_DENY,
                    provider,
                    RULE_SEVERITY[RULE_ENTITLEMENT_MASS_DENY],
                    True,
                    f"{bad}/{total} keys {top} — {hint}",
                    {
                        "deny": counts.get("deny", 0),
                        "balance": counts.get("balance", 0),
                        "broken": counts.get("broken", 0),
                        "total": total,
                    },
                )
            )
        else:
            # Rows present AND deny-share < 50% = qualified clean.
            out.append(
                (
                    RULE_ENTITLEMENT_MASS_DENY,
                    provider,
                    RULE_SEVERITY[RULE_ENTITLEMENT_MASS_DENY],
                    False,
                    f"provider {provider} deny share {share:.0%} ({bad}/{total})",
                    None,
                )
            )
    return out


def _eval_probe_budget_exhausted(snapshots: dict, db_rows: dict) -> list[EvalResult]:
    out: list[EvalResult] = []
    budgets = db_rows.get("budgets") or {}
    cap = config.probe_daily_calls
    for provider in db_rows.get("providers") or []:
        calls = budgets.get(provider)
        if calls is not None and calls >= cap:
            out.append(
                (
                    RULE_PROBE_BUDGET_EXHAUSTED,
                    provider,
                    RULE_SEVERITY[RULE_PROBE_BUDGET_EXHAUSTED],
                    True,
                    f"provider {provider} daily probe budget exhausted ({calls}/{cap} calls)",
                    {"calls": calls, "daily_limit": cap},
                )
            )
        else:
            # Row absent OR calls below cap = qualified clean.
            out.append(
                (
                    RULE_PROBE_BUDGET_EXHAUSTED,
                    provider,
                    RULE_SEVERITY[RULE_PROBE_BUDGET_EXHAUSTED],
                    False,
                    f"provider {provider} probe budget {calls or 0}/{cap}",
                    None,
                )
            )
    return out


def _snapshot_age_sec(snap: dict | None) -> float | None:
    if not isinstance(snap, dict):
        return None
    raw = snap.get("snapshot_ts")
    if not isinstance(raw, str) or not raw:
        return None
    text = raw[:-1] + "+00:00" if raw.endswith("Z") else raw
    try:
        ts = datetime.fromisoformat(text)
    except ValueError:
        return None
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=UTC)
    return (datetime.now(UTC) - ts).total_seconds()


def _is_stale(snap: dict | None) -> bool:
    age = _snapshot_age_sec(snap)
    return age is None or age > SNAPSHOT_STALE_SEC


def _entity_scope(entity: dict) -> str | None:
    kind = entity.get("kind")
    eid = entity.get("id")
    if not kind or eid is None or eid == "":
        return None
    return f"{kind}:{eid}"


def _cool_mass_count(snap: dict) -> int:
    """Distinct cooling targets toward cool_mass, without double-counting
    a provider with its own provider_keys (spec §7 rule 6)."""
    if snap.get("cool_ids_overflow"):
        return int(snap.get("cool_count") or 0)
    ids = snap.get("cool_ids") or []
    if not isinstance(ids, list):
        ids = []
    provider_cooling = {
        str(t.get("id"))
        for t in ids
        if isinstance(t, dict) and t.get("kind") == "provider" and t.get("id") is not None
    }
    n = 0
    for t in ids:
        if not isinstance(t, dict):
            continue
        kind = t.get("kind")
        if kind not in ("provider_key", "provider", "route"):
            continue
        if kind == "provider_key" and str(t.get("provider_id") or "") in provider_cooling:
            continue
        n += 1
    return n


def _provider_hits_from_snap(snap: dict) -> dict[str, int]:
    """Per-provider cooling counts from one health snapshot."""
    hits: dict[str, int] = {}
    if snap.get("cool_ids_overflow"):
        for pc in snap.get("cool_provider_counts") or []:
            if not isinstance(pc, dict):
                continue
            pid = pc.get("provider_id")
            if pid is None or pid == "":
                continue
            keys = int(pc.get("keys_cooling") or 0)
            prov = 1 if pc.get("provider_cooling") else 0
            hits[str(pid)] = keys + prov
        return hits
    for t in snap.get("cool_ids") or []:
        if not isinstance(t, dict):
            continue
        pid = t.get("provider_id") or (t.get("id") if t.get("kind") == "provider" else None)
        if pid is None or pid == "":
            continue
        hits[str(pid)] = hits.get(str(pid), 0) + 1
    return hits


def _eval_cool_mass(snapshots: dict, db_rows: dict) -> list[EvalResult]:
    """Rule 6: mass cooling on a master node and/or per provider.

    Provider scopes are aggregated across all master snapshots so a
    shared `provider:{id}` key never receives conflicting EvalResults
    in one cycle (OCR High on 226de45).
    """
    out: list[EvalResult] = []
    sev = RULE_SEVERITY[RULE_COOL_MASS]
    # pid -> (max_count, example_node)
    provider_agg: dict[str, tuple[int, str]] = {}
    live_names: set[str] = set()

    for row in db_rows.get("failures") or []:
        name = row.get("name")
        if not name:
            continue
        live_names.add(name)
        snap = row.get("snapshot")
        if not isinstance(snap, dict):
            out.append(
                (
                    RULE_COOL_MASS,
                    name,
                    sev,
                    None,
                    f"node {name} has no failure snapshot",
                    None,
                )
            )
            continue
        if _is_stale(snap):
            out.append(
                (
                    RULE_COOL_MASS,
                    name,
                    sev,
                    None,
                    f"node {name} failure snapshot stale",
                    None,
                )
            )
            continue

        overflow = bool(snap.get("cool_ids_overflow"))
        if overflow:
            _overflow_streaks[name] = _overflow_streaks.get(name, 0) + 1
        else:
            _overflow_streaks[name] = 0
        if _overflow_streaks.get(name, 0) >= COOL_OVERFLOW_ESCAPE_M:
            out.append(
                (
                    RULE_COOL_MASS,
                    name,
                    sev,
                    False,
                    f"node {name} cool_ids_overflow escape ({COOL_OVERFLOW_ESCAPE_M} polls)",
                    {"cool_ids_overflow": True, "escape": True},
                )
            )
            continue

        count = _cool_mass_count(snap)
        if count >= COOL_MASS_N:
            out.append(
                (
                    RULE_COOL_MASS,
                    name,
                    sev,
                    True,
                    f"node {name} cool mass ({count} targets cooling)",
                    {"cool_count": count, "cool_ids_overflow": overflow},
                )
            )
        else:
            out.append(
                (
                    RULE_COOL_MASS,
                    name,
                    sev,
                    False,
                    f"node {name} cool mass {count}/{COOL_MASS_N}",
                    {"cool_count": count},
                )
            )

        for pid, n in _provider_hits_from_snap(snap).items():
            prev = provider_agg.get(pid)
            if prev is None or n > prev[0]:
                provider_agg[pid] = (n, name)

    for pid, (n, node_name) in provider_agg.items():
        scope = f"provider:{pid}"
        if n >= COOL_MASS_N:
            out.append(
                (
                    RULE_COOL_MASS,
                    scope,
                    sev,
                    True,
                    f"provider {pid} cool mass ({n} targets, peak on {node_name})",
                    {"provider_id": pid, "count": n, "node": node_name},
                )
            )
        else:
            out.append(
                (
                    RULE_COOL_MASS,
                    scope,
                    sev,
                    False,
                    f"provider {pid} cool mass {n}/{COOL_MASS_N}",
                    {"provider_id": pid, "count": n, "node": node_name},
                )
            )

    # Drop overflow streaks for nodes that left the enabled set.
    for stale_name in list(_overflow_streaks.keys()):
        if stale_name not in live_names:
            _overflow_streaks.pop(stale_name, None)
    return out


def _eval_entity_error_rate(snapshots: dict, db_rows: dict) -> list[EvalResult]:
    """Rule 7: rate-degraded entities from persisted health snapshots."""
    out: list[EvalResult] = []
    sev = RULE_SEVERITY[RULE_ENTITY_ERROR_RATE]
    m = max(1, config.alert_for_cycles)
    # Collect every entity we have evidence about this cycle so we can
    # resolve previously-firing scopes that went clean/absent/evicted.
    touched: set[str] = set()

    for row in db_rows.get("failures") or []:
        name = row.get("name") or "?"
        snap = row.get("snapshot")
        if not isinstance(snap, dict) or _is_stale(snap):
            continue
        degraded_set: set[str] = set()
        for ent in snap.get("degraded_ids") or []:
            if isinstance(ent, dict):
                sc = _entity_scope(ent)
                if sc:
                    degraded_set.add(sc)
        rates_by_scope: dict[str, dict] = {}
        for r in snap.get("rates") or []:
            if not isinstance(r, dict):
                continue
            ent = r.get("entity") if isinstance(r.get("entity"), dict) else {}
            sc = _entity_scope(ent)
            if not sc:
                continue
            # Prefer 5m window when present.
            prev = rates_by_scope.get(sc)
            if prev is None or r.get("window") == "5m":
                rates_by_scope[sc] = r
        evicted_set: set[str] = set()
        for ent in snap.get("rates_evicted") or []:
            if isinstance(ent, dict):
                sc = _entity_scope(ent)
                if sc:
                    evicted_set.add(sc)

        for sc in degraded_set:
            touched.add(sc)
            _absent_streaks.pop((RULE_ENTITY_ERROR_RATE, sc), None)
            _evicted_streaks.pop((RULE_ENTITY_ERROR_RATE, sc), None)
            out.append(
                (
                    RULE_ENTITY_ERROR_RATE,
                    sc,
                    sev,
                    True,
                    f"entity {sc} rate-degraded on {name}",
                    {"node": name, "degraded": True},
                )
            )

        for sc, r in rates_by_scope.items():
            if sc in degraded_set:
                continue
            touched.add(sc)
            ratio = r.get("failure_ratio")
            try:
                ratio_f = float(ratio) if ratio is not None else None
            except (TypeError, ValueError):
                ratio_f = None
            degraded = bool(r.get("degraded"))
            if ratio_f is not None and ratio_f < CLEAR_RATIO:
                _absent_streaks.pop((RULE_ENTITY_ERROR_RATE, sc), None)
                out.append(
                    (
                        RULE_ENTITY_ERROR_RATE,
                        sc,
                        sev,
                        False,
                        f"entity {sc} ratio {ratio_f:.0%} < clear band",
                        {"node": name, "ratio": ratio_f},
                    )
                )
            elif (not degraded) and ratio_f is not None and ratio_f < DEADBAND_RATIO:
                _absent_streaks.pop((RULE_ENTITY_ERROR_RATE, sc), None)
                out.append(
                    (
                        RULE_ENTITY_ERROR_RATE,
                        sc,
                        sev,
                        False,
                        f"entity {sc} left degraded band (ratio {ratio_f:.0%})",
                        {"node": name, "ratio": ratio_f},
                    )
                )
            else:
                out.append(
                    (
                        RULE_ENTITY_ERROR_RATE,
                        sc,
                        sev,
                        None,
                        f"entity {sc} present but not clear",
                        None,
                    )
                )

        for sc in evicted_set:
            touched.add(sc)
            key = (RULE_ENTITY_ERROR_RATE, sc)
            _evicted_streaks[key] = _evicted_streaks.get(key, 0) + 1
            if _evicted_streaks[key] >= m:
                out.append(
                    (
                        RULE_ENTITY_ERROR_RATE,
                        sc,
                        sev,
                        False,
                        f"entity {sc} evicted_idle",
                        {"node": name, "reason": "evicted_idle"},
                    )
                )
            else:
                out.append(
                    (
                        RULE_ENTITY_ERROR_RATE,
                        sc,
                        sev,
                        None,
                        f"entity {sc} evicted ({_evicted_streaks[key]}/{m})",
                        None,
                    )
                )

    # Global absent pass: any entity_error_rate streak key not touched
    # and rates not truncated on ALL nodes this cycle → bump absent.
    any_truncated = any(
        bool(
            (r.get("snapshot") or {}).get("rates_truncated")
            or (r.get("snapshot") or {}).get("degraded_ids_overflow")
        )
        for r in (db_rows.get("failures") or [])
        if isinstance(r.get("snapshot"), dict) and not _is_stale(r.get("snapshot"))
    )
    if not any_truncated:
        for key, streak in list(_streaks.items()):
            rule, sc = key
            if rule != RULE_ENTITY_ERROR_RATE:
                continue
            if sc in touched:
                _absent_streaks.pop(key, None)
                continue
            _absent_streaks[key] = _absent_streaks.get(key, 0) + 1
            if _absent_streaks[key] >= m:
                out.append(
                    (
                        RULE_ENTITY_ERROR_RATE,
                        sc,
                        sev,
                        False,
                        f"entity {sc} absent {m} polls",
                        {"reason": "absent"},
                    )
                )
            else:
                out.append(
                    (
                        RULE_ENTITY_ERROR_RATE,
                        sc,
                        sev,
                        None,
                        f"entity {sc} absent ({_absent_streaks[key]}/{m})",
                        None,
                    )
                )
    return out


def _as_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _clean_text(value: Any) -> str | None:
    """Collapse whitespace and bound one task_runs text field."""
    if value is None:
        return None
    text = " ".join(str(value).split())
    return text[:TASK_ERROR_MAX_CHARS] if text else None


def _parse_ts(value: Any) -> datetime | None:
    """task_runs timestamps arrive as datetime (asyncpg) or ISO strings
    (synthetic cycles); anything else is unusable for a time claim."""
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=UTC)
    if isinstance(value, str):
        try:
            # Python >= 3.11 (repo floor, 3.12 image) parses the trailing
            # "Z" from task_runs' ISO timestamps natively.
            return datetime.fromisoformat(value)
        except ValueError:
            return None
    return None


def _fmt_ts(ts: datetime | None) -> str:
    return ts.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ") if ts else "unknown"


def _fmt_age(sec: int) -> str:
    if sec >= 86400:
        return f"{sec // 86400}d{sec % 86400 // 3600}h"
    if sec >= 3600:
        return f"{sec // 3600}h{sec % 3600 // 60}m"
    if sec >= 60:
        return f"{sec // 60}m"
    return f"{sec}s"


def _fmt_cadence(sec: int | None) -> str:
    if not sec or sec <= 0:
        return "unknown"
    if sec % 3600 == 0:
        return f"{sec // 3600}h"
    if sec % 60 == 0:
        return f"{sec // 60}m"
    return f"{sec}s"


def _run_view(item: Any) -> dict:
    """Normalize one task_runs input row. The evaluator's DB read supplies
    dicts; a synthetic driver may still pass bare outcome strings."""
    if isinstance(item, dict):
        return {
            "outcome": str(item.get("outcome") or ""),
            "finished_at": item.get("finished_at"),
            "error_class": item.get("error_class"),
            "error": item.get("error"),
            "interval_ms": item.get("interval_ms"),
            "meta": item.get("meta"),
        }
    return {
        "outcome": str(item),
        "finished_at": None,
        "error_class": None,
        "error": None,
        "interval_ms": None,
        "meta": None,
    }


_TASK_META_HINT_KEYS = frozenset({"detail", "error", "summary", "message", "reason", "component"})


def _task_meta_hint(meta: Any) -> str | None:
    """Best-effort per-component hint from task_runs.meta (gateway-owned
    jsonb). Only failure-describing keys are used, so the dashboard
    writer's bookkeeping marker ({"source": "edge_stub"}) never becomes a
    hint and a fresh failure without detail keeps its exact old wording."""
    if not isinstance(meta, dict):
        return None
    for key, value in meta.items():
        k = str(key).lower()
        if not (k in _TASK_META_HINT_KEYS or "provider" in k or "fail" in k or "component" in k):
            continue
        text = _clean_text(value if isinstance(value, str) else json.dumps(value, default=str))
        if text:
            return text
    return None


# The gateway renders its op error as an Erlang term string (its own
# format_error/1, capped at 1024 chars, before ops_puller stores it in
# task_runs.error). Task 28 measured the REAL rendering on prod — format_error
# uses ~0P, so keys/values are spaced and binaries are wrapped:
#   {sync_errors,1,8,[#{host => <<"https://voyahgpt-gateway.voyah.cn/api/gateway/v1">>,
#     class => <<"bad_json">>, detail => {bad_json,unexpected_end_of_input},
#     provider_id => 4, provider => <<"voyah">>}]}
# A raw dump like that tells the operator nothing, so the patterns below pull
# out the counts and the first failing provider, unwrapping the rendered
# terms. Both are best-effort: any unexpected shape falls back to the
# "class: error" wording, so an unparseable string can never break an
# evaluation cycle. (The durable fix is a structured field from the gateway
# rather than parsing a rendered term — see the task-28 report.)
_SYNC_ERRORS_RE = re.compile(r"\{sync_errors\s*,\s*(\d+)\s*,\s*(\d+)\s*,")
# The gateway renders its failure map with ~0P, so keys and values arrive
# spaced (`host => …`) and binaries wrapped (`<<"voyah">>`). Match a bare key
# name only: `(?![\w])` keeps `provider` from matching inside `provider_id`,
# which the real map lists *before* `provider`.
_SYNC_FIELD_RE = re.compile(r"(?<![\w])(provider|host|class)(?![\w])\s*=>\s*([^,}\]]+)")
_SYNC_BINARY_RE = re.compile(r'^<<\s*"(.*)"\s*>>$')
_SYNC_ORIGIN_RE = re.compile(r"^(https?://[^/]+)")


def _sync_value(raw: str) -> str:
    """Unwrap one rendered Erlang term: `<<"bin">>`, `'atom'`, `"string"`,
    a plain atom or an integer. A malformed or truncated wrapper (the gateway
    caps its error string at 1024 chars) is trimmed rather than dropped."""
    value = (raw or "").strip()
    match = _SYNC_BINARY_RE.match(value)
    if match:
        value = match.group(1)
    elif value.startswith("<<"):
        value = value[2:]
        if value[:1] in ('"', "'"):
            value = value[1:]
        value = value.rstrip(">").rstrip("'\"")
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        value = value[1:-1]
    return value.replace('\\"', '"').replace("\\\\", "\\").strip()


def _sync_errors_hint(err: str, cls: str | None) -> str | None:
    """Readable wording for a gateway sync_errors error, or None when the
    string is not that shape (the caller then keeps the raw wording)."""
    try:
        match = _SYNC_ERRORS_RE.search(err or "")
        if not match:
            return None
        failed, total = int(match.group(1)), int(match.group(2))
        if failed <= 0 or total <= 0 or failed > total:
            return None
        fields: dict[str, str] = {}
        for key, value in _SYNC_FIELD_RE.findall(err):
            cleaned = _sync_value(value)
            if cleaned and key not in fields:
                fields[key] = cleaned
        provider = fields.get("provider")
        host = fields.get("host")
        if host:
            # Prod hosts carry a long path (/api/gateway/v1); the origin is
            # what identifies the endpoint, and it keeps the counts visible
            # inside the 160-char bound.
            origin = _SYNC_ORIGIN_RE.match(host)
            host = (origin.group(1) if origin else host)[:80]
        # error_class is a real column, so prefer it over the rendered text;
        # the parsed class is only a fallback for rows where it is empty.
        lead = cls or fields.get("class")
        if provider and host and lead:
            head: str = f"{lead}: {provider} ({host})"
        elif lead:
            head = f"{lead}: {provider or host}" if (provider or host) else str(lead)
        else:
            head = provider or host or ""
        counts = f"{failed} of {total} providers failed"
        return _clean_text(f"{head} — {counts}" if head else counts)
    except Exception:
        logger.debug("sync_errors hint parse failed", exc_info=True)
        return None


def _task_error_hint(recent: list[dict]) -> str | None:
    """Error class/component of the newest failing run (falling back to
    older ones in the K window). The gateway's task_runs carries
    error_class + error (and task-20 puts the failing provider detail
    there), so the alert states WHAT failed instead of a bare
    "error,error,error". A gateway sync_errors string is rendered into
    class/provider/counts (Task 26) rather than shown as an Erlang dump.

    The hint is parsed from the RAW error (Task 28): `_clean_text` bounds the
    text at TASK_ERROR_MAX_CHARS, and in the real 195-char sync_errors string
    that cut lands before `provider =>`, which is why prod rendered host-only.
    The display bound still applies to the rendered hint and to the fallback.
    """
    for run in recent:
        cls = _clean_text(run.get("error_class"))
        raw_err = run.get("error")
        rendered = _sync_errors_hint("" if raw_err is None else str(raw_err), cls)
        if rendered:
            return rendered
        err = _clean_text(raw_err)
        if cls and err:
            return f"{cls}: {err}"
        if err or cls:
            return err or cls
        meta_hint = _task_meta_hint(run.get("meta"))
        if meta_hint:
            return meta_hint
    return None


def _task_stale_after_sec(interval_ms: Any) -> int:
    """Derive the staleness threshold from the task's own cadence."""
    ms = _as_int(interval_ms)
    if not ms or ms <= 0:
        return TASK_STALE_FALLBACK_SEC
    derived = TASK_STALE_INTERVAL_MULT * ms // 1000
    return int(min(max(derived, TASK_STALE_FLOOR_SEC), TASK_STALE_MAX_SEC))


def _task_stale_verdict(
    recent: list[dict], finished: datetime | None, open_started: Any, now: datetime
) -> dict[str, Any] | None:
    """Staleness verdict for a failing task, or None while it is still
    being retried. Newest run wins; the threshold comes from the newest
    schedule_interval_ms in the window. No trustworthy timestamp means no
    stale claim (a missing time must not invent one)."""
    interval_ms = next(
        (r.get("interval_ms") for r in recent if _as_int(r.get("interval_ms"))), None
    )
    stale_after = _task_stale_after_sec(interval_ms)
    if finished is None:
        return None
    age = (now - finished).total_seconds()
    if age <= stale_after:
        return None
    # An in-flight run started inside the window means the task IS running
    # now, so an old newest-finished row alone is not "stopped".
    opened = _parse_ts(open_started)
    if opened is not None and (now - opened).total_seconds() <= stale_after:
        return None
    return {
        "last_run_at": _fmt_ts(finished),
        "finished": finished,
        "age": _fmt_age(int(age)),
        "age_sec": int(age),
        "stale_after_sec": stale_after,
        "interval_ms": _as_int(interval_ms),
        "cadence": _fmt_cadence(_as_int(interval_ms) // 1000 if _as_int(interval_ms) else None),
    }


def _eval_task_consecutive_fail(snapshots: dict, db_rows: dict) -> list[EvalResult]:
    """Rule 8: last K finished task outcomes are all failures.

    Task 21 — time honesty: a failing streak whose newest finished run is
    older than the task's staleness threshold is reported STALE with the
    last-run timestamp, never as a repeated failure and never resolved
    away. Error class/component detail from task_runs is surfaced.
    """
    out: list[EvalResult] = []
    sev = RULE_SEVERITY[RULE_TASK_CONSECUTIVE_FAIL]
    lagging_nodes = {
        str(r.get("node_id")) for r in (db_rows.get("failures") or []) if r.get("ops_lagging")
    }
    runs = db_rows.get("task_runs") or {}
    opens = db_rows.get("task_open") or {}
    now = datetime.now(UTC)
    # runs: {(node_id, name): [run dicts, ...]} newest first
    for (node_id, name), items in runs.items():
        scope = f"{node_id}/{name}"
        if node_id in lagging_nodes:
            out.append(
                (
                    RULE_TASK_CONSECUTIVE_FAIL,
                    scope,
                    sev,
                    None,
                    f"task {name} on {node_id} skipped (ops_lagging)",
                    None,
                )
            )
            continue
        recent = [_run_view(i) for i in items[:TASK_FAIL_K]]
        if len(recent) < TASK_FAIL_K:
            out.append(
                (
                    RULE_TASK_CONSECUTIVE_FAIL,
                    scope,
                    sev,
                    None,
                    f"task {name} on {node_id} no-data ({len(recent)}/{TASK_FAIL_K})",
                    None,
                )
            )
            continue
        last_k = [r["outcome"] for r in recent]
        finished = _parse_ts(recent[0].get("finished_at"))
        opened = _parse_ts(opens.get((node_id, name)))
        if all(o in TASK_FAIL_OUTCOMES for o in last_k):
            stale = _task_stale_verdict(recent, finished, opened, now)
            hint = _task_error_hint(recent)
            suffix = f" — {hint}" if hint else ""
            detail: dict[str, Any] = {
                "variant": TASK_VARIANT_STALE if stale else TASK_VARIANT_FRESH,
                "outcomes": last_k,
            }
            if finished is not None:
                detail["last_run_at"] = _fmt_ts(finished)
            if opened is not None:
                # A run is in flight (or hung): never hide it, it is what
                # separates "retrying now" from "the subsystem is dead".
                detail["open_run_started_at"] = _fmt_ts(opened)
            for field in ("error_class", "error"):
                if recent[0].get(field):
                    detail[field] = _clean_text(recent[0][field])
            if stale is not None:
                detail.update(
                    {
                        "age_sec": stale["age_sec"],
                        "stale_after_sec": stale["stale_after_sec"],
                        "schedule_interval_ms": stale["interval_ms"],
                    }
                )
                out.append(
                    (
                        RULE_TASK_CONSECUTIVE_FAIL,
                        scope,
                        sev,
                        True,
                        f"task {name} on {node_id} stale: no run since "
                        f"{stale['last_run_at']} (age {stale['age']}; cadence "
                        f"{stale['cadence']}) — last {TASK_FAIL_K} outcomes: "
                        f"{','.join(last_k)}{suffix}",
                        detail,
                    )
                )
            else:
                out.append(
                    (
                        RULE_TASK_CONSECUTIVE_FAIL,
                        scope,
                        sev,
                        True,
                        f"task {name} on {node_id} failed {TASK_FAIL_K}× "
                        f"({','.join(last_k)}){suffix}",
                        detail,
                    )
                )
        elif last_k[0] == "ok":
            out.append(
                (
                    RULE_TASK_CONSECUTIVE_FAIL,
                    scope,
                    sev,
                    False,
                    f"task {name} on {node_id} recovered (ok)",
                    {"outcomes": last_k},
                )
            )
        else:
            out.append(
                (
                    RULE_TASK_CONSECUTIVE_FAIL,
                    scope,
                    sev,
                    None,
                    f"task {name} on {node_id} mixed outcomes",
                    {"outcomes": last_k},
                )
            )
    return out


def _eval_key_daily_budget(snapshots: dict, db_rows: dict) -> list[EvalResult]:
    """Rule 9 (H8-D3): today's PRICED spend of an agent key crossed its
    daily_cost_limit. WARN only — display/alert, never enforcement.
    Today's total is monotone, so one fire per key per day; the fresh
    low total after midnight is the qualified clean that resolves."""
    out: list[EvalResult] = []
    sev = RULE_SEVERITY[RULE_KEY_DAILY_BUDGET]
    day = datetime.now(UTC).date().isoformat()
    for scope, b in (db_rows.get("key_budgets") or {}).items():
        spend_v = b["spend"]
        limit = b["limit"]
        cur = "/".join(b.get("currencies") or []) or "n/a"
        unpriced = int(b.get("unpriced_tokens") or 0)
        if spend_v >= limit:
            out.append(
                (
                    RULE_KEY_DAILY_BUDGET,
                    scope,
                    sev,
                    True,
                    f"agent key {b['prefix']}… priced spend {spend_v:.2f} ({cur}) today "
                    f">= daily cost limit {limit:.2f}"
                    + (f" ({unpriced} unpriced tokens excluded)" if unpriced else ""),
                    {
                        "day": day,
                        "spend": str(spend_v),
                        "limit": str(limit),
                        "currencies": b.get("currencies") or [],
                        "unpriced_tokens": unpriced,
                    },
                )
            )
        else:
            out.append(
                (
                    RULE_KEY_DAILY_BUDGET,
                    scope,
                    sev,
                    False,
                    f"agent key {b['prefix']}… priced spend {spend_v:.2f} / {limit:.2f} today",
                    None,
                )
            )
    return out


def _eval_worker_pool_loss(snapshots: dict, db_rows: dict) -> list[EvalResult]:
    """Rule 10: a worker the capacity plane previously reported is gone
    from a FRESH /stats/sched scrape.

    snapshots["workers"] is None when no sched cache is fresh (all
    errored / frozen): no-data for every tracked worker — a scrape
    outage must neither fire nor resolve. Presence is the qualified
    clean; absence breaches (for_cycles rides the engine streak). Absent
    >= WORKER_DECOMMISSION_SEC resolves as "assumed decommissioned" and
    stops tracking, so a deliberate removal alerts once and ages out."""
    out: list[EvalResult] = []
    workers = snapshots.get("workers")
    if workers is None:
        return out
    sev = RULE_SEVERITY[RULE_WORKER_POOL_LOSS]
    now = time.time()
    present = {w for w in workers if isinstance(w, str) and w}
    for name in sorted(present):
        _worker_seen[name] = now
        _worker_absent_since.pop(name, None)
        out.append(
            (RULE_WORKER_POOL_LOSS, name, sev, False, f"worker {name} in the capacity plane", None)
        )
    for name in sorted(set(_worker_seen) - present):
        absent_since = _worker_absent_since.setdefault(name, now)
        absent_sec = int(now - absent_since)
        if absent_sec >= WORKER_DECOMMISSION_SEC:
            del _worker_seen[name]
            del _worker_absent_since[name]
            out.append(
                (
                    RULE_WORKER_POOL_LOSS,
                    name,
                    sev,
                    False,
                    f"worker {name} absent {absent_sec // 3600}h — assumed decommissioned",
                    {"absent_sec": absent_sec},
                )
            )
        else:
            out.append(
                (
                    RULE_WORKER_POOL_LOSS,
                    name,
                    sev,
                    True,
                    f"worker {name} left the capacity plane (absent {absent_sec}s)",
                    {"absent_sec": absent_sec},
                )
            )
    return out


def _eval_usage_writer_stall(snapshots: dict, db_rows: dict) -> list[EvalResult]:
    """Rule 11: the gateway's usage writer buffers rows without flushing.

    A healthy writer drains on its 1s tick, so usage_writer.buffered
    reads 0-2 in steady state. >= USAGE_STALL_BUFFERED_ROWS for
    for_cycles consecutive polls means the flush path is stuck and the
    ledger is silently falling behind (2026-10-23 incident class: the
    retry gate never opened, rows only landed in restart-time terminate
    bursts). alive=false is a breach outright — the writer process is
    down and every event is dropped at the cast. Unhealthy nodes are
    skipped (node_unreachable's beat); a missing usage_writer block
    (older gateway image) is a skip, never a fire or resolve."""
    out: list[EvalResult] = []
    for node in snapshots.get("nodes") or []:
        if node.get("status") != "healthy":
            continue
        name = node.get("name") or "?"
        writer = node.get("usage_writer")
        if not isinstance(writer, dict):
            # Version skew: /stats predates the usage_writer surface.
            out.append(
                (
                    RULE_USAGE_WRITER_STALL,
                    name,
                    RULE_SEVERITY[RULE_USAGE_WRITER_STALL],
                    None,
                    f"node {name} reports no usage_writer stats",
                    None,
                )
            )
            continue
        alive = writer.get("alive")
        buffered = writer.get("buffered")
        dropped = writer.get("dropped")
        detail = {
            "buffered": buffered if isinstance(buffered, int) else None,
            "dropped": dropped if isinstance(dropped, int) else None,
            "alive": alive,
        }
        if alive is False:
            out.append(
                (
                    RULE_USAGE_WRITER_STALL,
                    name,
                    RULE_SEVERITY[RULE_USAGE_WRITER_STALL],
                    True,
                    f"node {name} usage writer is not running — usage events are "
                    f"being dropped (dropped={dropped})",
                    detail,
                )
            )
            continue
        if not isinstance(buffered, int):
            out.append(
                (
                    RULE_USAGE_WRITER_STALL,
                    name,
                    RULE_SEVERITY[RULE_USAGE_WRITER_STALL],
                    None,
                    f"node {name} usage_writer.buffered missing",
                    None,
                )
            )
            continue
        if buffered >= USAGE_STALL_BUFFERED_ROWS:
            out.append(
                (
                    RULE_USAGE_WRITER_STALL,
                    name,
                    RULE_SEVERITY[RULE_USAGE_WRITER_STALL],
                    True,
                    f"node {name} usage writer stalled: {buffered} rows buffered "
                    f"(dropped={dropped}) — usage_events is not receiving rows",
                    detail,
                )
            )
        elif buffered < USAGE_STALL_CLEAN_ROWS:
            out.append(
                (
                    RULE_USAGE_WRITER_STALL,
                    name,
                    RULE_SEVERITY[RULE_USAGE_WRITER_STALL],
                    False,
                    f"node {name} usage writer draining (buffered={buffered})",
                    None,
                )
            )
        else:
            # 5..24: in-flight burst territory — no transition either way.
            out.append(
                (
                    RULE_USAGE_WRITER_STALL,
                    name,
                    RULE_SEVERITY[RULE_USAGE_WRITER_STALL],
                    None,
                    f"node {name} usage writer burst (buffered={buffered})",
                    None,
                )
            )
    return out


_EVALUATORS = {
    RULE_NODE_UNREACHABLE: _eval_node_unreachable,
    RULE_NODE_ERROR_RATE: _eval_node_error_rate,
    RULE_GENERATION_DESYNC: _eval_generation_desync,
    RULE_ENTITLEMENT_MASS_DENY: _eval_entitlement_mass_deny,
    RULE_PROBE_BUDGET_EXHAUSTED: _eval_probe_budget_exhausted,
    RULE_COOL_MASS: _eval_cool_mass,
    RULE_ENTITY_ERROR_RATE: _eval_entity_error_rate,
    RULE_TASK_CONSECUTIVE_FAIL: _eval_task_consecutive_fail,
    RULE_KEY_DAILY_BUDGET: _eval_key_daily_budget,
    RULE_WORKER_POOL_LOSS: _eval_worker_pool_loss,
    RULE_USAGE_WRITER_STALL: _eval_usage_writer_stall,
}


def evaluate(snapshots: dict, db_rows: dict) -> list[EvalResult]:
    """Pure evaluation of every enabled rule against snapshots + db_rows.

    Returns the FULL evaluated (rule, scope) set so run_once's
    scope-vanish reconciliation is unambiguous. The
    JANUS_ALERT_RULES_DISABLED filter lives here so the spawned evaluator
    and run_once behave identically. A rule that raises is logged and
    skipped.
    """
    disabled = config.alert_rules_disabled_set
    results: list[EvalResult] = []
    for rule, fn in _EVALUATORS.items():
        if rule in disabled:
            continue
        try:
            results.extend(fn(snapshots, db_rows))
        except Exception:
            logger.exception("alert rule %s raised; skipped this cycle", rule)
    return results


# ---------------------------------------------------------------------------
# Transition path (Step 3)
# ---------------------------------------------------------------------------


async def _read_db_rows() -> dict:
    """Inputs for rules 4–8 plus the monitored (enabled) scope lists for
    reconciliation: rules 4/5 evaluate enabled providers only (evaluation
    scope matches reconciliation scope), and a disabled scope is
    unmonitored and can never recover, so it is treated as vanished.

    Rules 6–8 read persisted gateway_nodes.health_snapshot / ops_lagging
    and task_runs (never the live ETS ring)."""
    entitlements: dict[str, dict[str, int]] = {}
    rows = await database.fetch(
        "SELECT p.name AS provider, ke.status, COUNT(*) AS n "
        "FROM key_entitlements ke "
        "JOIN provider_keys pk ON pk.id = ke.provider_key_id "
        "JOIN providers p ON p.id = pk.provider_id "
        "WHERE p.enabled = 1 "
        "GROUP BY p.name, ke.status"
    )
    for r in rows:
        e = entitlements.setdefault(
            r["provider"], {"deny": 0, "balance": 0, "broken": 0, "total": 0}
        )
        n = int(r["n"])
        if r["status"] in ("deny", "balance", "broken"):
            e[r["status"]] += n
        e["total"] += n
    budgets = {
        r["provider"]: int(r["calls"])
        for r in await database.fetch(
            "SELECT p.name AS provider, pbc.calls FROM probe_budget_counters pbc "
            "JOIN providers p ON p.id = pbc.provider "
            "WHERE pbc.day = CURRENT_DATE AND p.enabled = 1"
        )
    }
    providers = [
        r["name"] for r in await database.fetch("SELECT name FROM providers WHERE enabled = 1")
    ]
    node_rows = await database.fetch(
        "SELECT id, name, health_snapshot, health_pulled_at, ops_lagging "
        "FROM gateway_nodes WHERE enabled = true"
    )
    nodes = [r["name"] for r in node_rows]
    node_ids = {str(r["id"]) for r in node_rows}
    failures: list[dict[str, Any]] = []
    for r in node_rows:
        snap = jsonb_value(r["health_snapshot"])
        failures.append(
            {
                "name": r["name"],
                "node_id": str(r["id"]),
                "ops_lagging": bool(r["ops_lagging"]),
                "snapshot": snap if isinstance(snap, dict) else None,
                "health_pulled_at": r["health_pulled_at"],
            }
        )
    task_runs: dict[tuple[str, str], list[dict]] = {}
    task_open: dict[tuple[str, str], Any] = {}
    try:
        tr_rows = await database.fetch(
            "SELECT node_id, name, outcome, finished_at, error_class, error, "
            "       schedule_interval_ms, meta FROM ("
            "  SELECT node_id, name, outcome, finished_at, error_class, error, "
            "         schedule_interval_ms, meta, "
            "         ROW_NUMBER() OVER ("
            "           PARTITION BY node_id, name ORDER BY finished_at DESC"
            "         ) AS rn "
            "  FROM task_runs WHERE finished_at IS NOT NULL AND outcome IS NOT NULL"
            ") t WHERE rn <= $1 ORDER BY node_id, name, rn",
            TASK_FAIL_K,
        )
        for r in tr_rows:
            key = (str(r["node_id"]), str(r["name"]))
            task_runs.setdefault(key, []).append(
                {
                    "outcome": str(r["outcome"]),
                    "finished_at": r["finished_at"],
                    "error_class": r["error_class"],
                    "error": r["error"],
                    "interval_ms": r["schedule_interval_ms"],
                    "meta": jsonb_value(r["meta"]),
                }
            )
        # Rule 8 staleness input: an OPEN run means the task is running
        # right now, so an old newest-finished row alone is not evidence
        # that it stopped (an open run older than the threshold is itself
        # hung and does NOT suppress the stale verdict).
        open_rows = await database.fetch(
            "SELECT node_id, name, MAX(started_at) AS started_at FROM task_runs "
            "WHERE finished_at IS NULL GROUP BY node_id, name"
        )
        for r in open_rows:
            task_open[(str(r["node_id"]), str(r["name"]))] = r["started_at"]
    except Exception:
        # Table may be mid-migration on a fresh boot; skip rule 8 inputs.
        logger.exception("task_runs read for alerts failed; rule 8 no-data")
    # Rule 9 input (H8-D3): today's priced spend per limited agent key.
    # spend.key_daily_budgets already degrades errors to {} (= no-data
    # skip, never a false resolve) — same convention as task_runs.
    key_budgets: dict[str, dict] = {}
    try:
        key_budgets = await spend.key_daily_budgets()
    except Exception:
        logger.exception("key daily budget read for alerts failed; rule 9 no-data")
    return {
        "entitlements": entitlements,
        "budgets": budgets,
        "providers": providers,
        "nodes": nodes,
        "node_ids": node_ids,
        "failures": failures,
        "task_runs": task_runs,
        "task_open": task_open,
        "key_budgets": key_budgets,
        "budget_scopes": set(key_budgets),
    }


def _deadline_exceeded(deadline: float) -> bool:
    return time.monotonic() > deadline


def _scope_exists(rule: str, scope: str, db_rows: dict) -> bool:
    """Whether a firing scope is still monitored (else auto-resolve)."""
    kind = RULE_SCOPE_KIND.get(rule)
    node_names = set(db_rows.get("nodes") or [])
    provider_names = set(db_rows.get("providers") or [])
    node_ids = set(db_rows.get("node_ids") or [])
    if kind == "node":
        return scope in node_names
    if kind == "provider":
        return scope in provider_names
    if kind == "cool_mass":
        if scope.startswith("provider:"):
            # Provider id scopes are not matched to catalog names; keep
            # firing until a qualified clean / overflow escape.
            return True
        return scope in node_names
    if kind == "task":
        node_id = scope.split("/", 1)[0] if "/" in scope else ""
        return node_id in node_ids
    if kind == "agent_key":
        # Rule 9: a firing budget alert auto-resolves when the key is
        # deleted or its daily_cost_limit is removed (both mean the
        # scope is no longer monitored).
        return scope in set(db_rows.get("budget_scopes") or ())
    if kind == "entity":
        # Entities are not registry rows; vanish only with the node set
        # emptying (no masters left to observe rates).
        return bool(node_names)
    if kind == "worker":
        # Rule 10: workers are fleet members, not registry rows — they
        # resolve only via reappearance-clean or the 24h decommission
        # resolve the rule itself emits.
        return True
    # fleet / unknown: never vanish
    return True


async def run_once(snapshots: dict, deadline: float | None = None) -> dict:
    """One full transition pass: evaluate -> state upsert -> event insert.

    This is the single entry point the spawned evaluator task and the
    alerts_debug CLI driver both call. The advisory xact lock wraps the
    alert_state read + transition decision + writes, so two concurrent
    runs (any two processes) cannot double-fire an episode.

    Snapshot shape (the nodes.py hook builds this; the O.4b driver passes
    synthetic ones):
        {"nodes": [{"name": str, "status": "healthy"|"unreachable"|...,
                    "consecutive_failures": int,
                    "generation": int|None,
                    "requests_total": int|None,
                    "requests_failed": int|None,
                    "usage_writer": {"alive": bool, "buffered": int,
                                     "dropped": int}|None}, ...],
         "windows": {node_name: [[checked_at, requests_total,
                                  requests_failed], ...]},
         "workers": [worker node name, ...] | None}

    workers is None when no /stats/sched scrape is fresh this cycle —
    rule 10 no-data (a frozen cache is not presence evidence).
    """
    summary: dict[str, Any] = {
        "evaluated": 0,
        "fired": [],
        "resolved": [],
        "suppressed": [],
        "scope_resolved": [],
        "message_refreshed": [],
        "deadline_exceeded": False,
    }
    try:
        db_rows = await _read_db_rows()
    except Exception:
        logger.exception("alert evaluation aborted: db_rows read failed")
        return summary
    results = evaluate(snapshots, db_rows)
    summary["evaluated"] = len(results)

    delivered_at_insert = not config.alert_webhook_configured
    async with database.transaction() as tx:
        await tx.execute(f"SET LOCAL statement_timeout = '{STATEMENT_TIMEOUT_MS}'")
        await tx.execute("SELECT pg_advisory_xact_lock($1)", ADVISORY_LOCK_KEY)
        # The evaluation budget starts only now: the db_rows read and the
        # advisory-lock wait must not consume it, or a slow DB/lock wait
        # would leave no window and every rule would be skipped.
        if deadline is None:
            deadline = time.monotonic() + EVAL_DEADLINE_SEC
        states: dict[tuple[str, str], dict] = {
            (r["rule"], r["scope"]): dict(r)
            for r in await tx.fetch(
                "SELECT rule, scope, state, cycles, first_fired_at, last_eval_at FROM alert_state"
            )
        }
        # Seed in-memory streaks from persisted cycles so a dashboard
        # restart does not erase for_cycles (spec §7 / Task 7).
        for key, srow in states.items():
            if key in _streaks:
                continue
            cycles = int(srow.get("cycles") or 0)
            if cycles > 0:
                _streaks[key] = cycles
        # Rule 10 restart re-arm: keep a firing worker episode
        # evaluating (absence timing restarts now — conservative).
        for (rule, scope), srow in states.items():
            if rule == RULE_WORKER_POOL_LOSS and srow.get("state") == "firing":
                _worker_seen.setdefault(scope, 0.0)
                _worker_absent_since.setdefault(scope, time.time())

        for rule, scope, severity, breached, message, detail in results:
            if _deadline_exceeded(deadline):
                summary["deadline_exceeded"] = True
                _stats["deadline_exceeded"] += 1
                logger.warning("alert evaluation deadline exceeded; remaining rules skipped")
                break
            key = (rule, scope)
            row = states.get(key)
            state = row["state"] if row else "ok"
            transitioned = False

            if breached is True:
                streak = _streaks.get(key, 0) + 1
                _streaks[key] = streak
                if state != "firing" and streak >= _for_cycles(rule):
                    # Post-resolve refire guard: transition-level
                    # suppression inside the cooldown window (the rule/
                    # scope index feeds this read).
                    recent = await tx.fetchval(
                        "SELECT 1 FROM alert_events WHERE rule = $1 AND scope = $2 "
                        "AND state = 'resolved' "
                        "AND ts > NOW() - ($3 || ' seconds')::interval LIMIT 1",
                        rule,
                        scope,
                        str(config.alert_refire_cooldown_sec),
                    )
                    if recent:
                        summary["suppressed"].append({"rule": rule, "scope": scope})
                        logger.info(
                            "alert %s/%s breach suppressed by post-resolve refire guard",
                            rule,
                            scope,
                        )
                    else:
                        event_id = await tx.fetchval(
                            "INSERT INTO alert_events "
                            "(rule, scope, severity, state, message, detail, "
                            " delivered, next_retry_at) "
                            "VALUES ($1, $2, $3, 'firing', $4, $5::jsonb, $6, "
                            "        CASE WHEN $6 THEN NULL ELSE NOW() END) "
                            "RETURNING id",
                            rule,
                            scope,
                            severity,
                            message,
                            json.dumps(detail) if detail is not None else None,
                            delivered_at_insert,
                        )
                        await tx.execute(
                            "INSERT INTO alert_state "
                            "(rule, scope, state, cycles, first_fired_at, last_eval_at) "
                            "VALUES ($1, $2, 'firing', $3, NOW(), NOW()) "
                            "ON CONFLICT (rule, scope) DO UPDATE SET "
                            "state = 'firing', cycles = $3, first_fired_at = NOW(), "
                            "last_eval_at = NOW()",
                            rule,
                            scope,
                            streak,
                        )
                        transitioned = True
                        states[key] = {**(row or {}), "state": "firing", "cycles": streak}
                        summary["fired"].append(
                            {"rule": rule, "scope": scope, "event_id": event_id}
                        )
                        logger.warning("ALERT firing: %s/%s — %s", rule, scope, message)
                elif state != "firing":
                    # Persist partial breach streak across restarts.
                    await tx.execute(
                        "INSERT INTO alert_state "
                        "(rule, scope, state, cycles, last_eval_at) "
                        "VALUES ($1, $2, 'ok', $3, NOW()) "
                        "ON CONFLICT (rule, scope) DO UPDATE SET "
                        "cycles = $3, last_eval_at = NOW()",
                        rule,
                        scope,
                        streak,
                    )
                    states[key] = {**(row or {}), "state": "ok", "cycles": streak}
                    transitioned = True
                elif rule == RULE_TASK_CONSECUTIVE_FAIL:
                    # Already firing rule 8: the verdict class can flip
                    # (fresh failure ↔ stale) while the episode stands, and
                    # the alerts API renders the latest FIRING event's
                    # message — refresh it so the visible alert never keeps
                    # asserting a failure the task is no longer making.
                    await _refresh_firing_message(tx, key, severity, message, detail, summary)
            elif breached is False:
                _streaks.pop(key, None)
                _absent_streaks.pop(key, None)
                _evicted_streaks.pop(key, None)
                if state == "firing":
                    event_id = await tx.fetchval(
                        "INSERT INTO alert_events "
                        "(rule, scope, severity, state, message, detail, "
                        " delivered, next_retry_at) "
                        "VALUES ($1, $2, $3, 'resolved', $4, NULL, $5, "
                        "        CASE WHEN $5 THEN NULL ELSE NOW() END) "
                        "RETURNING id",
                        rule,
                        scope,
                        severity,
                        f"resolved: {message}",
                        delivered_at_insert,
                    )
                    await tx.execute(
                        "INSERT INTO alert_state "
                        "(rule, scope, state, cycles, first_fired_at, last_eval_at) "
                        "VALUES ($1, $2, 'ok', 0, NULL, NOW()) "
                        "ON CONFLICT (rule, scope) DO UPDATE SET "
                        "state = 'ok', cycles = 0, first_fired_at = NULL, "
                        "last_eval_at = NOW()",
                        rule,
                        scope,
                    )
                    transitioned = True
                    states[key] = {**(row or {}), "state": "ok", "cycles": 0}
                    summary["resolved"].append({"rule": rule, "scope": scope, "event_id": event_id})
                    logger.warning("ALERT resolved: %s/%s — %s", rule, scope, message)
                elif row is not None and int(row.get("cycles") or 0) > 0:
                    await tx.execute(
                        "UPDATE alert_state SET cycles = 0, last_eval_at = NOW() "
                        "WHERE rule = $1 AND scope = $2",
                        rule,
                        scope,
                    )
                    states[key] = {**(row or {}), "cycles": 0}
                    transitioned = True
            # breached is None (skip): no transition, streak untouched.

            if not transitioned:
                await _heartbeat(tx, states, key, row)

        # Scope-vanish reconciliation — a firing state whose scope no
        # longer exists auto-resolves. Dead-scope rows persist as
        # resolved history (bounded by scopes ever seen; not pruned).
        for (rule, scope), row in list(states.items()):
            if _deadline_exceeded(deadline):
                summary["deadline_exceeded"] = True
                logger.warning("alert evaluation deadline exceeded; reconciliation truncated")
                break
            if row.get("state") != "firing":
                continue
            if _scope_exists(rule, scope, db_rows):
                continue
            event_id = await tx.fetchval(
                "INSERT INTO alert_events "
                "(rule, scope, severity, state, message, detail, "
                " delivered, next_retry_at) "
                "VALUES ($1, $2, $3, 'resolved', $4, "
                "        '\"scope_removed\"'::jsonb, $5, "
                "        CASE WHEN $5 THEN NULL ELSE NOW() END) "
                "RETURNING id",
                rule,
                scope,
                RULE_SEVERITY.get(rule, "warning"),
                f"scope removed: {scope}",
                delivered_at_insert,
            )
            await tx.execute(
                "UPDATE alert_state SET state = 'ok', cycles = 0, "
                "first_fired_at = NULL, last_eval_at = NOW() "
                "WHERE rule = $1 AND scope = $2",
                rule,
                scope,
            )
            _streaks.pop((rule, scope), None)
            summary["scope_resolved"].append({"rule": rule, "scope": scope, "event_id": event_id})
            logger.warning("ALERT resolved (scope_removed): %s/%s", rule, scope)

    # One audit row per committed transition. This runs AFTER the 90110013
    # transaction so an audited row can never describe a rolled-back
    # transition; the try/except inside _audit_transition keeps an audit
    # failure from rolling back the transition it describes.
    for from_state, to_state, entries, reason in (
        ("ok", "firing", summary["fired"], None),
        ("firing", "resolved", summary["resolved"], None),
        ("firing", "resolved", summary["scope_resolved"], "scope_removed"),
    ):
        for t in entries:
            _audit_transition(t["rule"], t["scope"], from_state, to_state, t["event_id"], reason)

    return summary


def _audit_transition(
    rule: str,
    scope: str,
    from_state: str,
    to_state: str,
    event_id: Any,
    reason: str | None = None,
) -> None:
    """audit.log one alert state transition (plan: alert transitions are
    audited mutations). Best-effort by contract — log and continue on any
    failure, never surface to the evaluator."""
    detail: dict[str, Any] = {"from": from_state, "to": to_state, "event_id": event_id}
    if reason is not None:
        detail["reason"] = reason
    try:
        audit.log("alert.transition", f"{rule}/{scope}", json.dumps(detail))
    except Exception:
        logger.exception("audit log failed for alert transition %s/%s", rule, scope)


# The stale wording embeds the run age ("(age 45s; cadence 6h)"), which
# changes on every cycle; everything else in a rule-8 message is content.
# Comparing verbatim would turn the refresh into a per-tick row writer.
_AGE_FRAGMENT_RE = re.compile(r"\bage [0-9][0-9a-z]*")


def _visible_message(message: Any) -> str:
    """Operator-visible message with the tick-derived age normalized away."""
    return _AGE_FRAGMENT_RE.sub("age ?", str(message or ""))


def _firing_variant(message: Any, detail: Any) -> str:
    """Verdict class of a firing event: the explicit detail.variant when
    the row carries one, else inferred from the message (rows written
    before the Task 21 distinction existed)."""
    decoded = jsonb_value(detail)
    if isinstance(decoded, dict) and decoded.get("variant") in (
        TASK_VARIANT_FRESH,
        TASK_VARIANT_STALE,
    ):
        return str(decoded["variant"])
    return TASK_VARIANT_STALE if " stale:" in f" {message or ''}" else TASK_VARIANT_FRESH


async def _refresh_firing_message(
    tx: Any,
    key: tuple[str, str],
    severity: str,
    message: str,
    detail: dict | None,
    summary: dict,
) -> None:
    """Keep a firing rule-8 episode's VISIBLE message in step with what the
    rule currently renders — without a new fire, transition or webhook.

    The alerts API serves the message of the latest FIRING event, so a
    sustained breach would otherwise keep showing stale wording: "failed 3×"
    long after the task stopped being retried, or a bare
    "(error,error,error)" after the gateway started classifying the failure
    (Task 26 — the class/provider detail reached task_runs but never the
    operator). A refresh writes one row when either the verdict VARIANT
    flips (fresh ↔ stale, Task 21) or the rendered MESSAGE content changes.

    Strictly idempotent: the evaluator ticks every cycle, so an unchanged
    verdict must write nothing. The comparison drops the age fragment (the
    only tick-derived part) and the stored row is inert — delivered=TRUE and
    no next_retry_at, so the outbox query (delivered=FALSE) never picks it —
    while first_fired_at stays untouched and no transition is audited.
    """
    rule, scope = key
    variant = (detail or {}).get("variant")
    if variant not in (TASK_VARIANT_FRESH, TASK_VARIANT_STALE):
        return
    rows = await tx.fetch(
        "SELECT message, detail FROM alert_events "
        "WHERE rule = $1 AND scope = $2 AND state = 'firing' "
        "ORDER BY id DESC LIMIT 1",
        rule,
        scope,
    )
    if rows:
        prev_message = rows[0]["message"]
        variant_flip = _firing_variant(prev_message, rows[0]["detail"]) != variant
        content_change = _visible_message(prev_message) != _visible_message(message)
        if not variant_flip and not content_change:
            return
        reason = "variant" if variant_flip else "content"
    else:
        reason = "first"
    event_id = await tx.fetchval(
        "INSERT INTO alert_events "
        "(rule, scope, severity, state, message, detail, delivered, next_retry_at) "
        "VALUES ($1, $2, $3, 'firing', $4, $5::jsonb, TRUE, NULL) RETURNING id",
        rule,
        scope,
        severity,
        message,
        json.dumps(detail) if detail is not None else None,
    )
    summary["message_refreshed"].append(
        {"rule": rule, "scope": scope, "event_id": event_id, "variant": variant, "reason": reason}
    )
    logger.warning(
        "ALERT message refreshed: %s/%s (%s, %s) — %s", rule, scope, variant, reason, message
    )


async def _heartbeat(
    tx: Any, states: dict[tuple[str, str], dict], key: tuple[str, str], row: dict | None
) -> None:
    """alert_state is upserted on transitions and at most hourly per row
    (heartbeat), not every cycle. A first-seen (rule, scope) gets an ok
    row so last_eval_at reflects evaluator liveness for every evaluated
    pair."""
    rule, scope = key
    if row is None:
        await tx.execute(
            "INSERT INTO alert_state (rule, scope, state, cycles, last_eval_at) "
            "VALUES ($1, $2, 'ok', 0, NOW()) ON CONFLICT (rule, scope) DO NOTHING",
            rule,
            scope,
        )
        states[key] = {"state": "ok", "last_eval_at": datetime.now(UTC)}
        return
    await tx.execute(
        "UPDATE alert_state SET last_eval_at = NOW() "
        "WHERE rule = $1 AND scope = $2 "
        "AND last_eval_at < NOW() - ($3 || ' seconds')::interval",
        rule,
        scope,
        str(HEARTBEAT_SEC),
    )


# ---------------------------------------------------------------------------
# Cross-process pause sentinel + spawned evaluator (Step 3)
# ---------------------------------------------------------------------------


async def _sentinel_paused() -> bool:
    """Check the alert_control singleton (missing row = unpaused).

    A pause older than PAUSE_EXPIRY_SEC is treated as expired (logged +
    auto-cleared): a SIGKILLed debug driver can never mute alerting
    indefinitely.
    """
    global _pause_observed
    row = await database.fetchrow("SELECT paused, paused_at FROM alert_control WHERE id = 1")
    paused = bool(row["paused"]) if row else False
    if not paused:
        if _pause_observed:
            logger.info("alert evaluation resumed (pause sentinel cleared)")
            _pause_observed = False
        return False
    paused_at = row["paused_at"]
    if paused_at is not None:
        age = (datetime.now(UTC) - paused_at).total_seconds()
        if age > PAUSE_EXPIRY_SEC:
            await database.execute(
                "UPDATE alert_control SET paused = FALSE, paused_at = NULL WHERE id = 1"
            )
            logger.warning(
                "alert pause sentinel expired (age %.0fs > %ss) — auto-cleared",
                age,
                PAUSE_EXPIRY_SEC,
            )
            _pause_observed = False
            return False
    if not _pause_observed:
        logger.warning("alert evaluation PAUSED via alert_control sentinel")
        _pause_observed = True
    _stats["paused_skips"] += 1
    logger.info("alert evaluation cycle skipped (paused)")
    return True


async def _evaluation_task(snapshots: dict) -> None:
    """Per-cycle evaluator body: sentinel check BEFORE any 90110013
    transaction, then run_once under an overall monotonic deadline."""
    global _eval_in_flight
    from .task_runs_writer import record_run

    try:
        async with record_run(
            "alert_tick",
            expected_duration_ms=int(EVAL_DEADLINE_SEC * 1000),
            schedule_interval_ms=config.node_health_interval_sec * 1000,
        ) as run:
            try:
                if await _sentinel_paused():
                    run.ok()
                    return
            except Exception:
                # A broken sentinel must never mute alerting: fail open.
                logger.exception("alert pause sentinel check failed; evaluating anyway")
            try:
                await run_once(snapshots)
                run.ok()
            except Exception as exc:
                run.error("internal", repr(exc))
                logger.exception("alert evaluation task failed")
    except Exception:
        logger.exception("alert evaluation task failed")
    finally:
        _eval_in_flight = False


def spawn_evaluation(snapshots: dict) -> None:
    """Spawn one evaluation as a strong-ref'd task. Single-flight: a
    spawn while the previous evaluation still runs is skipped (counted +
    logged) — the health loop never awaits, so the poll cadence is
    strictly unaffected."""
    global _eval_in_flight
    if _eval_in_flight:
        _stats["overlap_skips"] += 1
        logger.warning("alert evaluation skipped: previous cycle still running")
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        logger.warning("alert evaluation spawn without a running loop; skipped")
        return
    _eval_in_flight = True
    coro = _evaluation_task(snapshots)
    try:
        t = loop.create_task(coro)
    except Exception:
        # create_task raising (e.g. loop shutdown) must not strand the
        # in-flight flag — every later evaluation would be silently
        # skipped. The health-loop caller logs the re-raise.
        _eval_in_flight = False
        coro.close()  # never scheduled — suppress "never awaited"
        raise
    _tasks.add(t)
    t.add_done_callback(_tasks.discard)


# ---------------------------------------------------------------------------
# Webhook outbox sender (Step 4)
# ---------------------------------------------------------------------------

_sender_task: asyncio.Task | None = None


def jsonb_value(raw: Any) -> Any:
    """asyncpg returns JSONB as str or decoded depending on codec; accept both."""
    if isinstance(raw, (str, bytes)):
        try:
            return json.loads(raw)
        except Exception:
            return raw
    return raw


async def _deliver_one(client: httpx.AsyncClient, row: Any) -> None:
    payload = {
        "version": 1,
        "event_id": row["id"],
        "rule": row["rule"],
        "scope": row["scope"],
        "severity": row["severity"],
        "state": row["state"],
        "message": row["message"],
        "detail": jsonb_value(row["detail"]),
        "ts": row["ts"].isoformat() if row["ts"] is not None else None,
    }
    ok = False
    try:
        resp = await client.post(config.alert_webhook_url, json=payload)
        ok = 200 <= resp.status_code < 300
        if not ok:
            logger.warning("alert webhook POST event %s got http %s", row["id"], resp.status_code)
    except Exception as exc:
        logger.warning("alert webhook POST event %s failed: %s", row["id"], exc)
    if ok:
        await database.execute(
            "UPDATE alert_events SET delivered = TRUE, attempts = attempts + 1, "
            "next_retry_at = NULL WHERE id = $1",
            row["id"],
        )
    else:
        backoff = min(2 ** (row["attempts"] + 1) * 2, BACKOFF_CAP_SEC)
        await database.execute(
            "UPDATE alert_events SET attempts = attempts + 1, "
            "next_retry_at = NOW() + ($2 || ' seconds')::interval WHERE id = $1",
            row["id"],
            str(backoff),
        )


async def _sender_tick() -> None:
    if not config.alert_webhook_configured:
        return  # record-only mode: rows insert delivered=true; sender idles
    # Retirement is pre-POST (NULL-safe concat): attempts >= 8 rows are
    # marked failed_permanent and never sent again. A delivery racing to
    # 8 cannot be re-picked (the pick pins attempts < 8).
    await database.execute(
        "UPDATE alert_events "
        "SET detail = COALESCE(detail,'{}'::jsonb) || "
        '\'{"delivery":"failed_permanent"}\'::jsonb '
        "WHERE delivered = FALSE AND attempts >= $1",
        MAX_ATTEMPTS,
    )
    rows = await database.fetch(
        "SELECT id, ts, rule, scope, severity, state, message, detail, attempts "
        "FROM alert_events "
        "WHERE delivered = FALSE AND attempts < $1 "
        "AND (next_retry_at IS NULL OR next_retry_at <= NOW()) "
        "ORDER BY id LIMIT $2",
        MAX_ATTEMPTS,
        PICK_LIMIT,
    )
    if not rows:
        return
    # trust_env=False: corporate HTTP_PROXY must not swallow loopback
    # alertsink / internal webhook hosts (O.4c–d flake on Windows e2e).
    async with httpx.AsyncClient(timeout=5.0, trust_env=False) as client:
        for row in rows:
            try:
                await _deliver_one(client, row)
            except Exception:
                logger.exception("alert delivery update failed for event %s", row["id"])


async def _sender_loop() -> None:
    while True:
        try:
            await _sender_tick()
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("alert sender tick failed")
        await asyncio.sleep(SENDER_TICK_SEC)


async def start_sender() -> None:
    """Start the webhook outbox sender (2s tick, lifespan-managed)."""
    global _sender_task
    if _sender_task is None or _sender_task.done():
        _sender_task = asyncio.create_task(_sender_loop())
        logger.info(
            "alert webhook sender started (mode=%s)",
            f"webhook host={config.alert_webhook_host}"
            if config.alert_webhook_configured
            else "record-only",
        )


async def stop_sender() -> None:
    global _sender_task
    if _sender_task is not None:
        _sender_task.cancel()
        try:
            await _sender_task
        except asyncio.CancelledError:
            pass
        _sender_task = None
        logger.info("alert webhook sender stopped")


def stats() -> dict:
    """Module counters for diagnostics."""
    return dict(_stats)
