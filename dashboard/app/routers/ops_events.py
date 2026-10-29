"""GET /api/ops-events — persisted gateway ops events (failure observability).

Reads the dashboard-owned gateway_ops_events table (cool_edge /
task_run ring events drained by app/ops_puller.py) plus the boot-change
/ overflow markers, newest first. Never a pass-through to the gateway
ring and never mixed into /api/logs (the OTP log stream): the SPA Logs
page toggles between the two sources, it does not merge them.

Filters (all optional, ANDed): node (gateway name or numeric id), type
(cool_edge|task_run), boot_id, since / until (ISO-8601, on event ts),
target_kind, target_id, provider_id (cool_edge payload.target.*), task
(task_run payload.name), outcome (task_run payload.outcome), limit
(1..2000, default 200). Markers (boot_change/overflow gaps) for the same
node/time window ride along unless markers=false.
"""

from typing import Any

from fastapi import APIRouter, Depends, HTTPException

from .. import database
from ..alerts import jsonb_value
from ..auth import require_auth
from ..ops_puller import _parse_ts

router = APIRouter()

_TYPES = ("cool_edge", "task_run")
_KINDS = ("provider_key", "provider", "route")


def _invalid(message: str) -> HTTPException:
    return HTTPException(400, detail={"error": {"code": "invalid", "message": message}})


@router.get("")
async def list_ops_events(
    node: str = "",
    type: str = "",
    boot_id: str = "",
    since: str = "",
    until: str = "",
    target_kind: str = "",
    target_id: str = "",
    provider_id: str = "",
    task: str = "",
    outcome: str = "",
    limit: int = 200,
    markers: bool = True,
    user: dict = Depends(require_auth),
):
    """Newest-first persisted ops events + markers. See module doc."""
    type = type.strip()
    if type and type not in _TYPES:
        raise _invalid(f"type must be one of {', '.join(_TYPES)}")
    target_kind = target_kind.strip()
    if target_kind and target_kind not in _KINDS:
        raise _invalid(f"target_kind must be one of {', '.join(_KINDS)}")
    since_ts = until_ts = None
    if since.strip():
        since_ts = _parse_ts(since.strip())
        if since_ts is None:
            raise _invalid("since must be an ISO-8601 timestamp")
    if until.strip():
        until_ts = _parse_ts(until.strip())
        if until_ts is None:
            raise _invalid("until must be an ISO-8601 timestamp")
    cap = max(1, min(limit, 2000))

    node_id: str | None = None
    node = node.strip()
    if node:
        row = await database.fetchrow(
            "SELECT id FROM gateway_nodes WHERE name = $1 OR id::text = $1", node
        )
        if row is None:
            return {"events": [], "markers": []}
        node_id = str(row["id"])

    where: list[str] = []
    args: list[Any] = []

    def add(clause: str, value: Any) -> None:
        args.append(value)
        where.append(clause.replace("?", f"${len(args)}"))

    if node_id is not None:
        add("e.node_id = ?", node_id)
    if type:
        add("e.type = ?", type)
    if boot_id.strip():
        add("e.boot_id = ?", boot_id.strip())
    if since_ts is not None:
        add("e.ts >= ?", since_ts)
    if until_ts is not None:
        add("e.ts <= ?", until_ts)
    if target_kind:
        add("e.payload->'target'->>'kind' = ?", target_kind)
    if target_id.strip():
        add("e.payload->'target'->>'id' = ?", target_id.strip())
    if provider_id.strip():
        add("e.payload->'target'->>'provider_id' = ?", provider_id.strip())
    if task.strip():
        add("e.payload->>'name' = ?", task.strip())
    if outcome.strip():
        add("e.payload->>'outcome' = ?", outcome.strip())
    args.append(cap)
    sql = (
        "SELECT e.node_id, n.name AS node, e.boot_id, e.idx, e.ts, e.type, "
        "e.schema_version, e.payload FROM gateway_ops_events e "
        "LEFT JOIN gateway_nodes n ON n.id::text = e.node_id "
        + ("WHERE " + " AND ".join(where) + " " if where else "")
        + f"ORDER BY e.ts DESC, e.idx DESC LIMIT ${len(args)}"
    )
    rows = await database.fetch(sql, *args)
    events = [
        {
            "node_id": r["node_id"],
            "node": r["node"],
            "boot_id": r["boot_id"],
            "idx": r["idx"],
            "ts": r["ts"].isoformat(),
            "type": r["type"],
            "schema_version": r["schema_version"],
            "payload": jsonb_value(r["payload"]) or {},
        }
        for r in rows
    ]

    out_markers: list[dict[str, Any]] = []
    if markers:
        m_where: list[str] = []
        m_args: list[Any] = []

        def madd(clause: str, value: Any) -> None:
            m_args.append(value)
            m_where.append(clause.replace("?", f"${len(m_args)}"))

        if node_id is not None:
            madd("m.node_id = ?", node_id)
        if since_ts is not None:
            madd("m.ts >= ?", since_ts)
        if until_ts is not None:
            madd("m.ts <= ?", until_ts)
        if boot_id.strip():
            madd("(m.boot_id = ? OR m.prior_boot_id = ?)", boot_id.strip())
        m_args.append(min(cap, 200))
        msql = (
            "SELECT m.node_id, n.name AS node, m.marker_seq, m.ts, m.reason, "
            "m.prior_boot_id, m.boot_id, m.detail FROM gateway_ops_markers m "
            "LEFT JOIN gateway_nodes n ON n.id::text = m.node_id "
            + ("WHERE " + " AND ".join(m_where) + " " if m_where else "")
            + f"ORDER BY m.ts DESC, m.marker_seq DESC LIMIT ${len(m_args)}"
        )
        for r in await database.fetch(msql, *m_args):
            out_markers.append(
                {
                    "node_id": r["node_id"],
                    "node": r["node"],
                    "marker_seq": r["marker_seq"],
                    "ts": r["ts"].isoformat(),
                    "reason": r["reason"],
                    "prior_boot_id": r["prior_boot_id"],
                    "boot_id": r["boot_id"],
                    "detail": jsonb_value(r["detail"]) or {},
                }
            )
    return {"events": events, "markers": out_markers}
