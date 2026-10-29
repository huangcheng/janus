"""Log stream endpoints: gateway log tails, persisted by default.

GET /api/logs — DEFAULT (source=db) reads the dashboard-owned
gateway_log_events table, written by the nodes.py puller after each
node's successful health poll; persisted visibility lags emission by at
most one poll interval (~10s). ?source=live keeps the original
pass-through: merge each enabled gateway node's /stats/logs (the
in-memory ring maintained by janus_log_tail on the gateway) into one
newest-first stream. Both modes share the event shape the SPA LogEvent
type expects: {idx, ts, level, fields, node}.

The egress-policy synthesized log_fetch_failed / no-token events exist
ONLY in live mode — DB mode's node-down visibility is the
node_unreachable alert (the puller logs + counts, never feeds alerts).
"""

import asyncio
import logging
from typing import Any

import httpx
from fastapi import APIRouter, Depends, HTTPException

from .. import database, egress
from ..alerts import jsonb_value
from ..auth import require_auth
from ..config import config
from ..nodes import _parse_log_ts, _tls_verify, stats_url

logger = logging.getLogger("janus.dashboard.logs")

router = APIRouter()

_LEVELS = ["none", "debug", "info", "notice", "warning", "error"]


def _level_at_least(level: str, floor: str) -> bool:
    try:
        return _LEVELS.index(level.lower()) >= _LEVELS.index(floor)
    except ValueError:
        return True


def _normalize_floor(level: str) -> str:
    """Normalize the requested floor to a _LEVELS member or "" (no
    filter). "info" is the SPA's default filter — a no-op (the ring
    holds level >= info anyway). "warn" is the Erlang-era alias for
    "warning" — mapped so the SPA's 'Warn and above' actually filters.
    Unknown floors fail open (no filter), matching _level_at_least."""
    floor = level.strip().lower()
    if floor in ("", "info"):
        return ""
    if floor == "warn":
        return "warning"
    return floor if floor in _LEVELS else ""


@router.get("")
async def stream_logs(
    limit: int = 300,
    level: str = "",
    node: str = "",
    since: str = "",
    source: str = "",
    user: dict = Depends(require_auth),
):
    """GET /api/logs?limit=300&level=warning&node=aliyun&since=… — newest
    first. Default reads gateway_log_events; ?source=live merges the
    nodes' in-memory rings (today's pass-through behavior)."""
    if source == "live":
        return await _live_logs(limit, level, node)
    if source not in ("", "db"):
        raise HTTPException(
            400,
            detail={"error": {"code": "invalid", "message": "source must be 'db' or 'live'"}},
        )

    cap = max(1, min(limit, 2000))
    where: list[str] = []
    args: list[Any] = []
    node = node.strip()
    if node:
        args.append(node)
        where.append(f"node = ${len(args)}")
    floor = _normalize_floor(level)
    if floor:
        # Exclude only KNOWN levels below the floor: unknown levels
        # (critical/alert/emergency) pass, exactly matching live mode's
        # fail-open _level_at_least.
        below = _LEVELS[: _LEVELS.index(floor)]
        args.append(below)
        where.append(f"NOT (level = ANY(${len(args)}))")
    since = since.strip()
    if since:
        ts = _parse_log_ts(since)
        if ts is None:
            raise HTTPException(
                400,
                detail={
                    "error": {"code": "invalid", "message": "since must be an ISO-8601 timestamp"}
                },
            )
        args.append(ts)
        where.append(f"ts >= ${len(args)}")
    args.append(cap)
    sql = (
        "SELECT node, idx, ts, level, fields FROM gateway_log_events "
        + ("WHERE " + " AND ".join(where) + " " if where else "")
        + f"ORDER BY ts DESC, id DESC LIMIT ${len(args)}"
    )
    rows = await database.fetch(sql, *args)
    return {
        "events": [
            {
                "idx": r["idx"],
                "ts": r["ts"].isoformat() if r["ts"] is not None else "",
                "level": r["level"],
                "fields": jsonb_value(r["fields"]) or {},
                "node": r["node"],
            }
            for r in rows
        ]
    }


async def _live_logs(limit: int, level: str, node: str = "") -> dict:
    """The original pass-through (source=live): merge every enabled
    node's /stats/logs ring into one newest-first stream.

    v2.2 Part B: this endpoint is a config.stats_token READER — every
    node's token is resolved through egress.stats_token_for
    (loopback-literal origins keep the global fallback; every other
    origin needs a per-node envelope or the node is skipped with a
    counter bump)."""
    floor = _normalize_floor(level)

    rows = await database.fetch(
        "SELECT id, name, stats_host, stats_port, stats_token_ciphertext "
        "FROM gateway_nodes WHERE enabled = true"
    )
    policy_on = await egress.egress_policy_on()

    async def fetch_node(node_row: dict) -> list[dict]:
        token = egress.stats_token_for(
            node_row["stats_host"],
            node_row["stats_token_ciphertext"],
            config.stats_token,
            policy_on=policy_on,
        )
        if token is None:
            egress.note_skipped_no_token(node_row["name"], node_row["stats_host"])
            return [
                {
                    "idx": 0,
                    "ts": "",
                    "level": "warning",
                    "fields": {
                        "what": "log_fetch_skipped_no_token",
                        "node": node_row["name"],
                        "reason": "egress policy: no per-node token for a non-loopback stats origin",
                    },
                }
            ]
        headers = {}
        if token:
            headers["authorization"] = f"Bearer {token}"
        url = stats_url(
            node_row["stats_host"],
            node_row["stats_port"],
            f"/stats/logs?limit={max(1, min(limit, 2000))}",
        )
        try:
            async with httpx.AsyncClient(timeout=5.0, verify=_tls_verify()) as client:
                resp = await client.get(url, headers=headers)
                resp.raise_for_status()
                data = resp.json()
        except Exception as e:
            logger.warning("log fetch failed for %s: %s", node_row["name"], e)
            return [
                {
                    "idx": 0,
                    "ts": "",
                    "level": "error",
                    "fields": {
                        "what": "log_fetch_failed",
                        "node": node_row["name"],
                        "reason": str(e),
                    },
                }
            ]
        events = data.get("events", [])
        for ev in events:
            ev.setdefault("node", node_row["name"])
        return events

    results = await asyncio.gather(*(fetch_node(r) for r in rows))
    merged = [ev for node_events in results for ev in node_events]
    if floor:
        merged = [ev for ev in merged if _level_at_least(str(ev.get("level", "")), floor)]
    node = node.strip()
    if node:
        merged = [ev for ev in merged if ev.get("node") == node]
    merged.sort(key=lambda ev: str(ev.get("ts", "")), reverse=True)
    return {"events": merged[: max(1, min(limit, 2000))]}
