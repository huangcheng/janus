"""Gateway node health monitoring background task.

Polls each enabled node's /stats and /stats/sched endpoints (egress-
policy token resolution from app.egress, 5s timeout) every
JANUS_NODE_HEALTH_INTERVAL_SEC seconds. /stats results live in
`_health`; last-good /stats/sched payloads are cached per gateway id
in `_sched` (workers/fleet + scraped_at + error).

v2.2 Part B: when the dash.egress_policy setting is ON, the global
JANUS_STATS_TOKEN is sent to loopback-literal stats origins ONLY; any
other origin without a per-node envelope is SKIPPED (no request made)
with a loud warning and the nodes_skipped_no_token_total counter. The
global token never leaves this box by dashboard action.

Log puller (observability-depth Task 7): after each node's SUCCESSFUL
/stats poll, one log pull is spawned as a strong-ref'd asyncio task
(single-flight per node, never awaited — the poll cadence is strictly
unaffected). The pull drains the node's /stats/logs ring (limit=2000 =
ring cap: one pull captures everything the ring holds) into the
dashboard-owned gateway_log_events table, deduped by a per-node
high-water mark with ON CONFLICT DO NOTHING as backstop. Persisted
visibility lags emission by at most one poll interval (~10s). Pull
failures bump counters + dashboard logs ONLY — they never touch
consecutive_failures and never feed alerting.

Ops puller (failure-observability Task 5): a second, independent
spawned pull per master node (app/ops_puller.py) fetches /stats/health
and drains /stats/ops-events into cool_episodes / task_runs /
gateway_ops_events; it never shares state or failure handling with the
log pull above.
"""

import asyncio
import json
import logging
import time
from collections import deque
from datetime import UTC, datetime
from typing import Any

from . import alerts, database, egress, ops_puller, probe_urls
from .config import config

logger = logging.getLogger("janus.dashboard.nodes")

_health: dict[int, dict[str, Any]] = {}
# Per-gateway last-good sched: workers, fleet, scraped_at (unix ms), error.
_sched: dict[int, dict[str, Any]] = {}
# Worker reachability probe (dashboard-side): the master's pool renders
# workers "up" from cached hellos and learns of a silent dist-link death
# only after the OS TCP keepalive timeout (~2h). A TCP connect to each
# worker's dist port from the dashboard gives a truthful reach state
# within one probe cycle; ok=False drives the "unreachable" pill.
_worker_reach: dict[str, dict[str, Any]] = {}
_worker_probe_task: asyncio.Task | None = None


def worker_reach_data() -> dict[str, dict[str, Any]]:
    """Latest dashboard-side TCP reach per worker node name."""
    return dict(_worker_reach)


# Alerting rule-2 input (observability-depth Task 6): per-node deque of
# the last 6 (checked_at, requests_total, requests_failed) snapshots,
# fed at the end of each poll cycle, cleared whenever a counter
# decreases (no window straddles a node restart) and pruned when a node
# leaves the enabled set.
_error_windows: dict[int, deque] = {}
_task: asyncio.Task | None = None


def health_data() -> dict[int, dict[str, Any]]:
    """Return the latest /stats health snapshot for all nodes."""
    return dict(_health)


def sched_data() -> dict[int, dict[str, Any]]:
    """Return the per-gateway /stats/sched cache (last-good + error)."""
    return dict(_sched)


def stats_url(stats_host: str, stats_port: int, path: str) -> str:
    """Build a node URL. stats_host may be a bare host (http + port) or a
    full origin with scheme (https://janus.example.cn) for nodes reached
    over the public internet behind a reverse proxy."""
    if stats_host.startswith(("http://", "https://")):
        return f"{stats_host.rstrip('/')}{path}"
    return f"http://{stats_host}:{stats_port}{path}"


def resolve_stats_token(ciphertext: str | None) -> str | None:
    """Legacy wrapper kept for callers outside the policy flow: returns
    the per-node token when the envelope decrypts, else the global one
    (policy OFF semantics). Policy-aware callers use
    egress.stats_token_for directly."""
    return egress.stats_token_for("", ciphertext, config.stats_token, policy_on=False)


def _tls_verify() -> bool | str:
    return probe_urls.tls_verify()


def _now_ms() -> int:
    return int(time.time() * 1000)


def _auth_headers(token: str | None) -> dict[str, str]:
    if token:
        return {"authorization": f"Bearer {token}"}
    return {}


def _normalize_sched_body(data: Any) -> tuple[list[Any], Any]:
    """Tolerate missing workers/fleet on old beams → [] / null."""
    if not isinstance(data, dict):
        return [], None
    workers = data.get("workers")
    if not isinstance(workers, list):
        workers = []
    fleet = data.get("fleet")
    if fleet is not None and not isinstance(fleet, dict):
        fleet = None
    return workers, fleet


async def poll_node(
    node_id: int, stats_host: str, stats_port: int, token: str | None = None
) -> dict[str, Any]:
    """Poll a single node's /stats endpoint with the token the CALLER
    resolved through the egress policy (egress.stats_token_for). A None
    token is sent as no Authorization header (loopback dev case)."""
    url = stats_url(stats_host, stats_port, "/stats")
    # Request-time SSRF gate + DNS pin (H1): the client connects only to
    # the addresses classified right now, never to a second resolution.
    client = egress.pinned_async_client(stats_host, timeout=5.0, verify=_tls_verify())
    if client is None:
        return {
            "status": "unreachable",
            "checked_at": time.time(),
            "error": "egress: stats_host failed the connect-time classification",
        }
    try:
        async with client, client.stream("GET", url, headers=_auth_headers(token)) as resp:
            if resp.status_code == 200:
                # Capped read (H4): never buffer an unbounded body.
                data = json.loads(await egress.read_body_capped(resp))
                return {"status": "healthy", "checked_at": time.time(), **data}
            return {
                "status": "unhealthy",
                "checked_at": time.time(),
                "http_status": resp.status_code,
            }
    except Exception as e:
        return {"status": "unreachable", "checked_at": time.time(), "error": str(e)}


async def poll_sched(stats_host: str, stats_port: int, token: str | None = None) -> dict[str, Any]:
    """Poll /stats/sched. Returns {ok, workers, fleet} or {ok: False, error}.

    Token must already be resolved by the caller through egress policy;
    None means no Authorization header (loopback / policy-off empty).
    """
    url = stats_url(stats_host, stats_port, "/stats/sched")
    client = egress.pinned_async_client(stats_host, timeout=5.0, verify=_tls_verify())
    if client is None:
        return {"ok": False, "error": "egress: stats_host failed the connect-time classification"}
    try:
        async with client, client.stream("GET", url, headers=_auth_headers(token)) as resp:
            if resp.status_code == 200:
                data = json.loads(await egress.read_body_capped(resp))
                workers, fleet = _normalize_sched_body(data)
                return {"ok": True, "workers": workers, "fleet": fleet, "body": data}
            return {"ok": False, "error": f"http {resp.status_code}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


async def poll_node_pair(
    node_id: int, stats_host: str, stats_port: int, token: str | None = None
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Parallel /stats + /stats/sched scrape for one gateway (5s each)."""
    health, sched = await asyncio.gather(
        poll_node(node_id, stats_host, stats_port, token),
        poll_sched(stats_host, stats_port, token),
    )
    return health, sched


def _apply_sched_result(nid: int, sched: dict[str, Any]) -> None:
    """Refresh or freeze the per-gateway sched cache (contract #8)."""
    prev = _sched.get(nid) or {}
    if sched.get("ok"):
        body = sched.get("body") if isinstance(sched.get("body"), dict) else {}
        _sched[nid] = {
            "workers": sched.get("workers") or [],
            "fleet": sched.get("fleet"),
            # The sched body omits `fleet` when the gateway's advisory
            # ring is off; fleet_effective tells the UI which case it is.
            "fleet_effective": body.get("fleet_effective"),
            "scraped_at": _now_ms(),
            "error": None,
        }
        return
    # Failure: keep last-good workers/fleet; freeze scraped_at; set error.
    _sched[nid] = {
        "workers": prev.get("workers") or [],
        "fleet": prev.get("fleet"),
        "fleet_effective": prev.get("fleet_effective"),
        "scraped_at": prev.get("scraped_at"),
        "error": str(sched.get("error") or "sched scrape failed"),
    }


def success_rate(health: dict[str, Any] | None) -> float | None:
    """(total-failed)/total when total>0 and failed<=total; else null."""
    if not health:
        return None
    total = health.get("requests_total")
    failed = health.get("requests_failed")
    if not isinstance(total, (int, float)) or not isinstance(failed, (int, float)):
        return None
    if total > 0 and failed <= total:
        return (total - failed) / total
    return None


_FAILURE_PASSTHROUGH = (
    "cool",
    "cool_count",
    "cool_ids_overflow",
    "cool_provider_counts",
    "rates",
    "rates_truncated",
    "degraded_ids",
    "degraded_ids_overflow",
    "rates_evicted",
    "rates_evicted_overflow",
    "tasks",
    "ops_ring",
)


def _iso(dt: Any) -> str | None:
    return dt.isoformat() if isinstance(dt, datetime) else None


def failure_view(r: Any) -> dict[str, Any] | None:
    """Live failure-observability block for one node row, from the
    PERSISTED snapshot (gateway_nodes.health_snapshot, written by the
    ops puller), so it survives dashboard restarts. None until the
    first snapshot lands. cool_ids (up to 2000 identities) is reconcile
    input, not UI detail — omitted here; cool_count carries the size.
    Staleness: snapshot_age_sec is measured from the GATEWAY's
    snapshot_ts (not dashboard pulled_at alone), pulled_age_sec from
    the dashboard's last successful pull."""
    snap = alerts.jsonb_value(r.get("health_snapshot"))
    if not isinstance(snap, dict):
        return None
    pulled = r.get("health_pulled_at")
    snap_ts = snap.get("snapshot_ts")
    now = datetime.now(UTC)
    out: dict[str, Any] = {
        "boot_id": snap.get("boot_id"),
        "schema_version": snap.get("schema_version"),
        "snapshot_ts": snap_ts,
        "pulled_at": _iso(pulled),
        "pulled_age_sec": (now - pulled).total_seconds() if isinstance(pulled, datetime) else None,
        "snapshot_age_sec": None,
        "ops_lagging": bool(r.get("ops_lagging")),
        "ops_boot_id": r.get("ops_boot_id"),
    }
    parsed = ops_puller._parse_ts(snap_ts)
    if parsed is not None:
        out["snapshot_age_sec"] = (now - parsed).total_seconds()
    if snap.get("schema_version") != ops_puller.SCHEMA_VERSION:
        out["unsupported_schema"] = True
        return out
    for k in _FAILURE_PASSTHROUGH:
        if k in snap:
            out[k] = snap[k]
    return out


async def assemble_nodes_payload(
    rows: list[Any],
) -> dict[str, Any]:
    """Build GET /api/nodes body from DB rows + in-memory caches.

    Merge rules (contracts #7–#9):
    - via = gateway name; one worker row per (via, node); never merge numerics
    - fleet from cached sched with highest members; tie-break lowest gateway id
    - no successful cache → fleet null, workers [], scraped_at null
    """
    health = health_data()
    sched = sched_data()
    enabled_ids = {int(r["id"]) for r in rows if r["enabled"]}
    # Operator remarks per worker (dashboard-owned table; workers are
    # sched-scraped, not rows, so notes key on the Erlang long name).
    try:
        _notes = await database.fetch("SELECT node, note FROM worker_notes")
        _worker_notes = {r["node"]: r["note"] for r in _notes}
    except Exception:
        _worker_notes = {}
    name_by_id = {int(r["id"]): r["name"] for r in rows}

    nodes_out: list[dict[str, Any]] = []
    for r in rows:
        nid = int(r["id"])
        enabled = bool(r["enabled"])
        h = health.get(nid) if enabled else None
        s = (sched.get(nid) or {}) if enabled else {}
        nodes_out.append(
            {
                "id": nid,
                "name": r["name"],
                "data_host": r["data_host"],
                "data_port": r["data_port"],
                "stats_host": r["stats_host"],
                "stats_port": r["stats_port"],
                "enabled": enabled,
                "created_at": str(r["created_at"]),
                "stats_token_set": r["stats_token_ciphertext"] is not None,
                "health": h,
                "success_rate": success_rate(h) if enabled else None,
                "sched_error": s.get("error") if enabled else None,
                "sched_scraped_at": s.get("scraped_at") if enabled else None,
                # Master health: live cool / rates / tasks (+ staleness,
                # ops_lagging). None for workers / disabled / pre-snapshot.
                "failure": failure_view(r) if enabled else None,
                # Operator-set build sha (commit short id). Surfaces #8
                # fleet version skew — when two rows ship different shas,
                # the SPA flags the row.
                "build_sha": r["build_sha"],
            }
        )

    workers: list[dict[str, Any]] = []
    fleet_candidates: list[tuple[int, int, dict[str, Any]]] = []
    scraped_ats: list[int] = []
    # fleet_effective from the freshest successful cache — it is fleet-wide
    # config, so any gateway's value answers "is the advisory ring off?".
    fleet_effective: bool | None = None
    freshest: int | None = None

    for nid in enabled_ids:
        s = sched.get(nid) or {}
        scraped = s.get("scraped_at")
        if scraped is None:
            continue
        scraped_ats.append(int(scraped))
        if freshest is None or int(scraped) > freshest:
            freshest = int(scraped)
            fe = s.get("fleet_effective")
            fleet_effective = fe if isinstance(fe, bool) else None
        via = name_by_id.get(nid, str(nid))
        for w in s.get("workers") or []:
            if isinstance(w, dict):
                workers.append(
                    {
                        **w,
                        "via": via,
                        "reach": _worker_reach.get(w.get("node")),
                        "note": _worker_notes.get(w.get("node"), ""),
                    }
                )
        fl = s.get("fleet")
        if isinstance(fl, dict):
            members = fl.get("members", 0)
            if not isinstance(members, int):
                members = 0
            fleet_candidates.append((members, nid, fl))

    if not scraped_ats:
        return {
            "nodes": nodes_out,
            "workers": [],
            "fleet": None,
            "fleet_effective": None,
            "scraped_at": None,
        }

    fleet: dict[str, Any] | None = None
    if fleet_candidates:
        # Highest members; tie-break lowest gateway id. Never sum fleets.
        fleet_candidates.sort(key=lambda t: (-t[0], t[1]))
        fleet = fleet_candidates[0][2]

    return {
        "nodes": nodes_out,
        "workers": workers,
        "fleet": fleet,
        "fleet_effective": fleet_effective,
        "scraped_at": max(scraped_ats),
    }


def _feed_error_window(nid: int, health: dict[str, Any]) -> None:
    """Append one /stats counter sample to the node's rule-2 window.

    Only successful polls feed the window; a counter decrease (node
    restart) clears the deque and starts a fresh baseline, so no window
    ever straddles a restart."""
    if health.get("status") != "healthy":
        return
    total = health.get("requests_total")
    failed = health.get("requests_failed")
    if not isinstance(total, (int, float)) or not isinstance(failed, (int, float)):
        return
    window = _error_windows.setdefault(nid, deque(maxlen=6))
    if window and (total < window[-1][1] or failed < window[-1][2]):
        window.clear()
    window.append((health.get("checked_at") or time.time(), int(total), int(failed)))


def _alert_snapshots(rows: list[Any], consecutive_failures: dict[int, int]) -> dict:
    """Build the evaluator snapshot for this cycle: per-node status,
    failure streak, generation and counters, plus the rule-2 windows
    keyed by node name (the alert scope)."""
    nodes_out: list[dict[str, Any]] = []
    windows: dict[str, list] = {}
    for row in rows:
        nid = int(row["id"])
        h = _health.get(nid)
        if h is None:
            continue
        name = row["name"]
        nodes_out.append(
            {
                "name": name,
                "status": h.get("status"),
                "consecutive_failures": consecutive_failures.get(nid, 0),
                "generation": h.get("generation"),
                "requests_total": h.get("requests_total"),
                "requests_failed": h.get("requests_failed"),
                # Rule 11 (usage_writer_stall): the /stats writer block,
                # passed through verbatim; absent on older gateways.
                "usage_writer": h.get("usage_writer"),
            }
        )
        window = _error_windows.get(nid)
        if window:
            windows[name] = list(window)
    # Rule 10 input: worker names from FRESH sched caches only (a frozen
    # cache keeps last-good workers and must read as no-data, not as
    # presence). None = no fresh scrape this cycle. The caller's rows are
    # already enabled-filtered (WHERE enabled = true) — every id here is
    # monitored this cycle.
    fresh = [s for s in _sched.values() if s.get("error") is None and s.get("scraped_at")]
    workers = None
    if fresh:
        workers = sorted(
            {
                w.get("node")
                for s in fresh
                for w in (s.get("workers") or [])
                if isinstance(w, dict) and isinstance(w.get("node"), str)
            }
        )
    return {"nodes": nodes_out, "windows": windows, "workers": workers}


# ---------------------------------------------------------------------------
# Gateway log puller (observability-depth Task 7)
# ---------------------------------------------------------------------------

LOG_PULL_LIMIT = 2000  # ring cap: one pull captures everything the ring holds
LOG_PULL_HTTP_TIMEOUT_SEC = 3.0
LOG_PULL_DEADLINE_SEC = 4.0  # overall monotonic budget per pull task
_log_pull_tasks: set[asyncio.Task] = set()
_log_pull_in_flight: set[int] = set()
# High-water state per node id: the max idx durably inserted for the
# node's CURRENT boot, and the started_at that boot carried. Both reset
# when the node leaves the enabled set.
_log_high_water: dict[int, int] = {}
_log_started_at: dict[int, Any] = {}
_log_pull_stats = {
    "fetch_failures": 0,
    "insert_failures": 0,
    "overlap_skips": 0,
    "deadline_exceeded": 0,
    "events_dropped": 0,
    "events_inserted": 0,
    "restarts_detected": 0,
}


def log_pull_stats() -> dict:
    """Module counters for diagnostics."""
    return dict(_log_pull_stats)


def _parse_log_ts(raw: Any) -> datetime | None:
    """Parse the gateway's RFC3339 event ts; None = drop the event.

    janus_log_tail_h emits integer 0 when the logger meta carried no
    time — unparseable here, so the event is dropped (counted + logged
    by the caller)."""
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


async def _log_pull_task(
    nid: int,
    name: str,
    stats_host: str,
    stats_port: int,
    token: str | None,
    started_at: Any,
) -> None:
    """One log-ring pull for a node. Locked order per node per batch:

    (1) compute the batch's observed max idx; (2) restart check —
    observed max < current mark OR the node's started_at changed ⇒ the
    node restarted ⇒ reset the mark to -1 (NOT 0: survives whether the
    gateway's idx starts at 0 or 1; uptime_sec is NOT a trigger — it
    increases every poll); (3) only then skip events with idx <= mark;
    (4) insert survivors in one executemany with ON CONFLICT DO NOTHING
    (backstop); (5) advance the mark to the observed max ONLY when the
    insert succeeded — a failed/timed-out batch is re-pulled next
    cycle, never silently dropped. An empty batch skips both the
    restart check and the mark advance (max([]) can never spuriously
    reset the mark).

    The ~4s monotonic budget is checked BETWEEN phases: 3s GET + 2s
    insert can exceed it, so the deadline lands between fetch and
    insert; single-flight makes overlap impossible regardless. The
    insert runs under the same 2s statement timeout + try/except as the
    alert evaluator — a Postgres stall counts and logs, never stretches
    the poll cycle.
    """
    deadline = time.monotonic() + LOG_PULL_DEADLINE_SEC
    try:
        url = stats_url(stats_host, stats_port, f"/stats/logs?limit={LOG_PULL_LIMIT}")
        try:
            # H1/H4: connect-time classification + DNS pin, and a capped
            # streamed read (a hostile node cannot balloon this process).
            client = egress.pinned_async_client(
                stats_host, timeout=LOG_PULL_HTTP_TIMEOUT_SEC, verify=_tls_verify()
            )
            if client is None:
                raise RuntimeError("egress: stats_host failed the connect-time classification")
            async with client, client.stream("GET", url, headers=_auth_headers(token)) as resp:
                if resp.status_code != 200:
                    raise RuntimeError(f"http {resp.status_code}")
                data = json.loads(await egress.read_body_capped(resp))
        except Exception as exc:
            # Timeout = drop + count, same as an insert failure: the
            # mark stays, so the batch is re-pulled next cycle.
            _log_pull_stats["fetch_failures"] += 1
            logger.warning("log pull fetch failed for %s: %s", name, exc)
            return
        if time.monotonic() > deadline:
            _log_pull_stats["deadline_exceeded"] += 1
            logger.warning(
                "log pull for %s exceeded its %ss budget after fetch; batch dropped",
                name,
                LOG_PULL_DEADLINE_SEC,
            )
            return
        events = data.get("events") if isinstance(data, dict) else None
        if not isinstance(events, list):
            events = []
        parsed: list[tuple] = []
        dropped = 0
        for ev in events:
            if not isinstance(ev, dict):
                dropped += 1
                continue
            idx = ev.get("idx")
            ts = _parse_log_ts(ev.get("ts"))
            if not isinstance(idx, int) or isinstance(idx, bool) or ts is None:
                dropped += 1
                continue
            fields = ev.get("fields")
            try:
                fields_json = json.dumps(fields) if isinstance(fields, (dict, list)) else "{}"
            except (TypeError, ValueError):
                # One unserializable fields payload must not poison the
                # whole batch: a raised dump leaves the mark unadvanced,
                # so the same batch would fail identically every cycle —
                # permanent log-visibility loss for the node.
                dropped += 1
                continue
            parsed.append((name, idx, ts, str(ev.get("level") or "info"), fields_json))
        if dropped:
            _log_pull_stats["events_dropped"] += dropped
            logger.warning(
                "log pull for %s dropped %d events with missing/unparseable "
                "ts/idx or unserializable fields",
                name,
                dropped,
            )
        if not parsed:
            return
        observed_max = max(p[1] for p in parsed)
        mark = _log_high_water.get(nid, -1)
        # started_at arrives as unix seconds; the fallback snapshot on
        # old beams encodes `undefined` (a string) — only a real number
        # participates in the restart check.
        started_known = isinstance(started_at, (int, float)) and not isinstance(started_at, bool)
        prev_started = _log_started_at.get(nid)
        if observed_max < mark or (
            started_known and prev_started is not None and started_at != prev_started
        ):
            _log_pull_stats["restarts_detected"] += 1
            logger.info(
                "log pull: node %s restarted (observed_max=%s mark=%s "
                "started_at=%s prev=%s) — high-water mark reset",
                name,
                observed_max,
                mark,
                started_at,
                prev_started,
            )
            mark = -1
        if started_known:
            _log_started_at[nid] = started_at
        survivors = [p for p in parsed if p[1] > mark]
        if survivors:
            try:
                async with database.transaction() as tx:
                    await tx.execute(
                        f"SET LOCAL statement_timeout = '{alerts.STATEMENT_TIMEOUT_MS}'"
                    )
                    await tx.executemany(
                        "INSERT INTO gateway_log_events (node, idx, ts, level, fields) "
                        "VALUES ($1, $2, $3, $4, $5::jsonb) ON CONFLICT DO NOTHING",
                        survivors,
                    )
            except Exception:
                _log_pull_stats["insert_failures"] += 1
                logger.exception(
                    "log pull insert failed for %s (%d events); mark NOT advanced",
                    name,
                    len(survivors),
                )
                return
            _log_pull_stats["events_inserted"] += len(survivors)
        _log_high_water[nid] = observed_max
    except Exception:
        logger.exception("log pull task failed for %s", name)
    finally:
        _log_pull_in_flight.discard(nid)


def spawn_log_pull(row: Any, health: dict[str, Any], policy_on: bool) -> None:
    """Spawn one log pull for a node as a strong-ref'd task. Single-
    flight per node: a spawn while the node's previous pull still runs
    is skipped (counted + dashboard-logged), so the locked high-water
    sequence can never be raced. The health loop never awaits pulls, so
    the poll cadence is strictly unaffected."""
    nid = int(row["id"])
    if nid in _log_pull_in_flight:
        _log_pull_stats["overlap_skips"] += 1
        logger.warning("log pull skipped for %s: previous pull still running", row["name"])
        return
    token = egress.stats_token_for(
        row["stats_host"],
        row["stats_token_ciphertext"],
        config.stats_token,
        policy_on=policy_on,
    )
    if token is None:
        # The health poll just succeeded with a token, so this is only
        # reachable via a policy flip between poll and spawn — the
        # global token must still not leave the box.
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        logger.warning("log pull spawn without a running loop; skipped")
        return
    _log_pull_in_flight.add(nid)
    coro = _log_pull_task(
        nid,
        row["name"],
        row["stats_host"],
        row["stats_port"],
        token,
        health.get("started_at"),
    )
    try:
        t = loop.create_task(coro)
    except Exception:
        # create_task raising (e.g. loop shutdown) must not strand nid
        # in the in-flight set — every later pull for the node would be
        # silently skipped. The health-loop caller logs the re-raise.
        _log_pull_in_flight.discard(nid)
        coro.close()  # never scheduled — suppress "never awaited"
        raise
    _log_pull_tasks.add(t)
    t.add_done_callback(_log_pull_tasks.discard)


async def _health_loop() -> None:
    """Background loop: poll all enabled nodes periodically."""
    interval = config.node_health_interval_sec
    consecutive_failures: dict[int, int] = {}

    while True:
        try:
            policy_on = await egress.egress_policy_on()
            rows = await database.fetch(
                "SELECT id, name, stats_host, stats_port, stats_token_ciphertext "
                "FROM gateway_nodes WHERE enabled = true"
            )
            results: list[tuple[Any, Any]] = []
            for row in rows:
                token = egress.stats_token_for(
                    row["stats_host"],
                    row["stats_token_ciphertext"],
                    config.stats_token,
                    policy_on=policy_on,
                )
                if token is None:
                    # Part B/F3: non-loopback-literal origin without a
                    # per-node envelope — poll SKIPPED, never the global
                    # token. Loud warning + counter; node shows stale.
                    egress.note_skipped_no_token(row["name"], row["stats_host"])
                    health = {
                        "status": "stale_no_token",
                        "checked_at": time.time(),
                        "error": (
                            "stats poll skipped by egress policy — no per-node token "
                            "(register one before enabling dash.egress_policy)"
                        ),
                    }
                    sched = {"ok": False, "error": "skipped by egress policy"}
                    results.append((row, (health, sched)))
                    continue
                try:
                    pair = await poll_node_pair(
                        row["id"], row["stats_host"], row["stats_port"], token
                    )
                except Exception as exc:
                    pair = exc
                results.append((row, pair))

            for row, result in results:
                nid = row["id"]
                if isinstance(result, Exception):
                    health = {
                        "status": "unreachable",
                        "checked_at": time.time(),
                        "error": str(result),
                    }
                    sched = {"ok": False, "error": str(result)}
                else:
                    health, sched = result

                if health.get("status") == "unreachable":
                    consecutive_failures[nid] = consecutive_failures.get(nid, 0) + 1
                    if consecutive_failures[nid] >= 3:
                        health["status"] = "unreachable"
                else:
                    consecutive_failures.pop(nid, None)

                _health[nid] = health
                _apply_sched_result(nid, sched)
                _feed_error_window(nid, health)
                # Log pull hook (Task 7): after each node's successful
                # /stats poll, drain its log ring — spawned, single-
                # flight per node, never awaited.
                if health.get("status") == "healthy":
                    try:
                        spawn_log_pull(row, health, policy_on)
                    except Exception:
                        logger.exception("log pull spawn failed")
                    # Failure-observability ops pull: masters only
                    # (workers expose no ops tail — spec 2; an unknown
                    # role is tried, 404/503 is a counted no-op). Its own
                    # try/except: independent of the log pull above.
                    if str(health.get("role") or "").lower() != "worker":
                        try:
                            ops_puller.spawn_ops_pull(row, policy_on)
                        except Exception:
                            logger.exception("ops pull spawn failed")

            # Drop caches for nodes no longer enabled so disabled rows
            # do not keep stale health/sched forever.
            live = {int(row["id"]) for row in rows}
            for nid in list(_health.keys()):
                if nid not in live:
                    _health.pop(nid, None)
                    _sched.pop(nid, None)
                    consecutive_failures.pop(nid, None)
                    _error_windows.pop(nid, None)
                    _log_high_water.pop(nid, None)
                    _log_started_at.pop(nid, None)
                    ops_puller.forget_node(nid)

            # Alerting hook (Task 6): spawn the evaluator as a task —
            # single-flight, strong-ref'd, never awaited, so the 10s
            # poll cadence is strictly unaffected.
            try:
                alerts.spawn_evaluation(_alert_snapshots(rows, consecutive_failures))
            except Exception:
                logger.exception("alert evaluation spawn failed")

        except Exception:
            logger.exception("health poll cycle failed")

        await asyncio.sleep(interval)


async def _worker_probe_loop() -> None:
    """Worker liveness for the Nodes page.

    PRIMARY: the master's dist mesh — fleet command pool_ping
    (net_adm:ping over the gateway's LIVE Erlang links). Domestic
    carriers drop non-standard ports to unregistered (未备案) IPs, so a
    direct TCP connect from the dashboard host is filtered on some
    datacenter pairs while the dist link is always reachable.

    FALLBACK: direct TCP connects to each worker's dist port (the
    pre-pool_ping behavior), used when the command is unavailable
    (version skew) or errors — the probe stays functional across a
    partial rollout.
    """
    while True:
        try:
            # Resolve the egress policy ONCE per cycle, like every
            # sibling stats reader (health poller, log/ops pullers,
            # maintenance reload): with dash.egress_policy ON the
            # global JANUS_STATS_TOKEN must never leave this box by
            # dashboard action — a hardcoded policy_on=False here sent
            # the fleet-wide admin bearer off-box every probe cycle
            # (security-audit run-1).
            policy_on = await egress.egress_policy_on()
            rows = []
            try:
                rows = await database.fetch(
                    "SELECT id, name, stats_host, stats_port, stats_token_ciphertext FROM gateway_nodes WHERE enabled"
                )
            except Exception:
                logger.debug("probe loop: gateway rows fetch failed", exc_info=True)

            results: dict[str, dict[str, Any]] = {}
            used_dist = False
            for row in rows:
                token = egress.stats_token_for(
                    row["stats_host"],
                    row["stats_token_ciphertext"],
                    config.stats_token,
                    policy_on=policy_on,
                )
                if not token:
                    egress.note_skipped_no_token(f'node:{row["id"]}', row["stats_host"])
                    continue
                try:
                    url = stats_url(row["stats_host"], row["stats_port"], "/stats/fleet/command")
                    # The fleet command pings EVERY registered worker
                    # before answering; one slow dist tail (observed
                    # 2026-10-27: a 13s-RTT worker link) makes the whole
                    # command exceed 8s, the probe then falls back to
                    # direct TCP — which cloud security groups drop for
                    # locked-down workers and the Nodes page flaps
                    # "up · no probe". Give the command room to finish.
                    client = egress.pinned_async_client(
                        row["stats_host"], timeout=30.0, verify=_tls_verify()
                    )
                    if client is None:
                        continue
                    async with client as c:
                        resp = await c.post(
                            url,
                            json={"command": "pool_ping"},
                            headers={"authorization": f"Bearer {token}"},
                        )
                        if resp.status_code != 200:
                            continue
                        data = resp.json()
                    # results maps the EXECUTING node's long name (the
                    # master) to its {ok => {worker => pong}} — the name
                    # is deployment-specific, never hardcode it.
                    inner = next(
                        (v for v in (data.get("results") or {}).values() if isinstance(v, dict)),
                        {},
                    )
                    pings = inner.get("ok") if isinstance(inner, dict) else None
                    if not isinstance(pings, dict) or not pings:
                        continue
                    for name, verdict in pings.items():
                        results[name] = {
                            "ok": verdict == "pong",
                            "checked_at": time.time(),
                            "error": None if verdict == "pong" else "dist ping: pang",
                            "via": "dist",
                        }
                    used_dist = True
                    break
                except Exception:
                    logger.debug("probe loop: pool_ping failed", exc_info=True)
                    continue

            if not used_dist:
                # Fallback: direct TCP (pre-pool_ping behavior)
                names = sorted(
                    {
                        w.get("node")
                        for s in _sched.values()
                        if s.get("error") is None and s.get("scraped_at")
                        for w in (s.get("workers") or [])
                        if isinstance(w, dict) and isinstance(w.get("node"), str)
                    }
                )
                for name in names:
                    host = name.split("@", 1)[1] if "@" in name else ""
                    if not host:
                        results[name] = {
                            "ok": None,
                            "checked_at": time.time(),
                            "error": "bad node name",
                        }
                        continue
                    try:
                        _r, _w = await asyncio.wait_for(
                            asyncio.open_connection(host, config.worker_probe_port),
                            timeout=config.worker_probe_timeout_sec,
                        )
                        _w.close()
                        results[name] = {
                            "ok": True,
                            "checked_at": time.time(),
                            "error": None,
                            "via": "tcp",
                        }
                    except Exception as e:
                        results[name] = {
                            "ok": False,
                            "checked_at": time.time(),
                            "error": str(e),
                            "via": "tcp",
                        }

            _worker_reach.update(results)
            for name in list(_worker_reach):
                if name not in results:
                    _worker_reach.pop(name, None)

        except Exception:
            logger.exception("worker probe cycle failed")

        await asyncio.sleep(config.worker_probe_interval_sec)


async def start_monitor() -> None:
    """Start the background health monitor + worker reach probe."""
    global _task, _worker_probe_task
    if _task is None or _task.done():
        _task = asyncio.create_task(_health_loop())
        logger.info("node health monitor started (interval=%ss)", config.node_health_interval_sec)
    if _worker_probe_task is None or _worker_probe_task.done():
        _worker_probe_task = asyncio.create_task(_worker_probe_loop())
        logger.info(
            "worker reach probe started (interval=%ss, port=%s)",
            config.worker_probe_interval_sec,
            config.worker_probe_port,
        )


async def stop_monitor() -> None:
    """Stop the background health monitor + worker reach probe."""
    global _task, _worker_probe_task
    if _task is not None:
        _task.cancel()
        try:
            await _task
        except asyncio.CancelledError:
            pass
        _task = None
        logger.info("node health monitor stopped")
    if _worker_probe_task is not None:
        _worker_probe_task.cancel()
        try:
            await _worker_probe_task
        except asyncio.CancelledError:
            pass
        _worker_probe_task = None
        logger.info("worker reach probe stopped")
