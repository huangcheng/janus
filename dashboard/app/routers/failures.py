"""Model-call failure visibility endpoints.

One view over the two places a failed call can land:

- ``upstream``: terminal ``usage_events`` rows with ``status >= 400`` — calls
  that reached a provider pick and failed there (provider 4xx/5xx, transport
  errors, worker loss). ``error_code`` / ``failover_reason`` /
  ``requested_model`` ride gateway migrations 008/021/025; the column probes
  degrade to NULL on a pre-migration DB, never a 500.
- ``reject``: pre-pick rejections the gateway deliberately never writes to
  ``usage_events`` (agent-key quota 429, no_route 404, wrong_modality 400,
  janus-auto adjudication 404 — the provider_id pin in janus_http_proxy).
  Those exist only as ``janus_agent_reject`` OTP log lines, which the nodes
  poller drains into ``gateway_log_events`` — so reject history is bounded
  by the log-ring drain, unlike usage accounting.

Read-only; both tables are written elsewhere (gateway / nodes poller).
"""

from fastapi import APIRouter, Depends

from .. import database
from ..auth import require_auth
from .usage import RANGES, _err, _window, terminal_clause, ue_col_select

router = APIRouter()

# The OTP logger field that marks a pre-pick rejection line
# (janus_http_preamble / reply_err in the gateway).
_REJECT_WHAT = "janus_agent_reject"

# Per-source GROUP BY cap for the breakdown — failures are few and clustered,
# 50 distinct (code, model, provider) shapes per source is plenty.
_GROUP_LIMIT = 50


@router.get("/summary")
async def failure_summary(range: str = "24h", user: dict = Depends(require_auth)):
    if range not in RANGES:
        raise _err(400, "bad_range", "range must be 24h | 7d | 30d")
    frm, to, _bucket = _window(range)
    code_expr = "ue.error_code" if await ue_col_select("error_code") else "NULL::text"
    reason_expr = "ue.failover_reason" if await ue_col_select("failover_reason") else "NULL::text"
    up_rows = await database.fetch(
        f"SELECT {code_expr} AS code, {reason_expr} AS reason, "
        "m.name AS model, p.name AS provider, COUNT(*) AS n, MAX(ue.ts) AS last_ts "
        "FROM usage_events ue "
        "LEFT JOIN models m ON m.id = ue.model_id "
        "LEFT JOIN providers p ON p.id = ue.provider_id "
        f"WHERE ue.ts >= $1 AND ue.ts < $2 AND ue.status >= 400{await terminal_clause()} "
        f"GROUP BY 1, 2, 3, 4 ORDER BY n DESC, last_ts DESC LIMIT {_GROUP_LIMIT}",
        frm,
        to,
    )
    rej_rows = await database.fetch(
        "SELECT le.fields->>'code' AS code, le.fields->>'model' AS model, "
        "COUNT(*) AS n, EXTRACT(EPOCH FROM MAX(le.ts))::bigint AS last_ts "
        "FROM gateway_log_events le "
        "WHERE le.fields->>'what' = $1 AND le.ts >= to_timestamp($2) AND le.ts < to_timestamp($3) "
        f"GROUP BY 1, 2 ORDER BY n DESC, last_ts DESC LIMIT {_GROUP_LIMIT}",
        _REJECT_WHAT,
        frm,
        to,
    )
    by_error = [
        {
            "kind": "upstream",
            "code": r["code"],
            "reason": r["reason"],
            "model": r["model"],
            "provider": r["provider"],
            "count": r["n"],
            "last_ts": r["last_ts"],
        }
        for r in up_rows
    ] + [
        {
            "kind": "reject",
            "code": r["code"],
            "reason": None,
            "model": r["model"],
            "provider": None,
            "count": r["n"],
            "last_ts": r["last_ts"],
        }
        for r in rej_rows
    ]
    by_error.sort(key=lambda g: (-g["count"], -g["last_ts"]))
    # Totals come from real COUNTs, not the (capped) group lists.
    upstream_n = await database.fetchval(
        "SELECT COUNT(*) FROM usage_events ue "
        f"WHERE ue.ts >= $1 AND ue.ts < $2 AND ue.status >= 400{await terminal_clause()}",
        frm,
        to,
    )
    rejects_n = await database.fetchval(
        "SELECT COUNT(*) FROM gateway_log_events le "
        "WHERE le.fields->>'what' = $1 AND le.ts >= to_timestamp($2) AND le.ts < to_timestamp($3)",
        _REJECT_WHAT,
        frm,
        to,
    )
    upstream_n = upstream_n or 0
    rejects_n = rejects_n or 0
    return {
        "range": range,
        "ts_from": frm,
        "ts_to": to,
        "totals": {
            "failures": upstream_n + rejects_n,
            "upstream": upstream_n,
            "rejects": rejects_n,
        },
        "by_error": by_error,
    }


@router.get("/events")
async def failure_events(
    range: str = "24h",
    kind: str = "",
    limit: int = 50,
    offset: int = 0,
    user: dict = Depends(require_auth),
):
    if range not in RANGES:
        raise _err(400, "bad_range", "range must be 24h | 7d | 30d")
    if kind not in ("", "upstream", "reject"):
        raise _err(400, "bad_filter", "kind must be upstream | reject | empty")
    if limit < 1 or limit > 200:
        raise _err(400, "bad_limit", "limit must be 1..200")
    if offset < 0:
        raise _err(400, "bad_offset", "offset must be >= 0")
    frm, to, _bucket = _window(range)
    # Each source contributes the full offset+limit newest rows; the merged
    # stream is then sliced — correct for a newest-first union, and failure
    # volumes keep the over-fetch cheap.
    fetch_n = offset + limit
    upstream: list[dict] = []
    rejects: list[dict] = []
    up_total = rej_total = 0
    if kind in ("", "upstream"):
        upstream, up_total = await _upstream_events(frm, to, fetch_n)
    if kind in ("", "reject"):
        rejects, rej_total = await _reject_events(frm, to, fetch_n)
    merged = sorted((*upstream, *rejects), key=lambda e: e["ts"], reverse=True)
    return {
        "total": up_total + rej_total,
        "limit": limit,
        "offset": offset,
        "events": merged[offset : offset + limit],
    }


async def _upstream_events(frm: int, to: int, limit: int) -> tuple[list[dict], int]:
    code = await ue_col_select("error_code")
    reason = await ue_col_select("failover_reason")
    requested = await ue_col_select("requested_model")
    rid = await ue_col_select("request_id")
    rref = await ue_col_select("request_ref")
    detail = await ue_col_select("error_detail")
    rows = await database.fetch(
        "SELECT ue.ts, ue.status, ak.prefix, m.name AS model, p.name AS provider"
        f"{code}{reason}{requested}{rid}{rref}{detail} "
        "FROM usage_events ue "
        "LEFT JOIN api_keys ak ON ak.id = ue.agent_key_id "
        "LEFT JOIN models m ON m.id = ue.model_id "
        "LEFT JOIN providers p ON p.id = ue.provider_id "
        f"WHERE ue.ts >= $1 AND ue.ts < $2 AND ue.status >= 400{await terminal_clause()} "
        "ORDER BY ue.ts DESC, ue.id DESC LIMIT $3",
        frm,
        to,
        limit,
    )
    total = await database.fetchval(
        "SELECT COUNT(*) FROM usage_events ue "
        f"WHERE ue.ts >= $1 AND ue.ts < $2 AND ue.status >= 400{await terminal_clause()}",
        frm,
        to,
    )
    return [
        {
            "ts": r["ts"],
            "kind": "upstream",
            "status": r["status"],
            "code": r["error_code"] if code else None,
            "reason": r["failover_reason"] if reason else None,
            "model": r["model"],
            "requested_model": r["requested_model"] if requested else None,
            "provider": r["provider"],
            "key_prefix": r["prefix"],
            "node": None,
            "request_id": r["request_id"] if rid else None,
            "request_ref": r["request_ref"] if rref else None,
            # The reply's own sentence (gateway migration 027): what the
            # provider actually SAID, clamped to 512B at the writer.
            "detail": r["error_detail"] if detail else None,
        }
        for r in rows
    ], total or 0


async def _reject_events(frm: int, to: int, limit: int) -> tuple[list[dict], int]:
    where = (
        "FROM gateway_log_events le "
        "WHERE le.fields->>'what' = $1 AND le.ts >= to_timestamp($2) AND le.ts < to_timestamp($3)"
    )
    rows = await database.fetch(
        "SELECT EXTRACT(EPOCH FROM le.ts)::bigint AS ts, le.node, le.fields "
        f"{where} ORDER BY le.ts DESC, le.id DESC LIMIT $4",
        _REJECT_WHAT,
        frm,
        to,
        limit,
    )
    total = await database.fetchval(f"SELECT COUNT(*) {where}", _REJECT_WHAT, frm, to)
    events = []
    for r in rows:
        # Older log lines may lack keys (or fields entirely); never let a
        # shape change 500 the page.
        fields = r["fields"] if isinstance(r["fields"], dict) else {}
        events.append(
            {
                "ts": r["ts"],
                "kind": "reject",
                "status": fields.get("status"),
                "code": fields.get("code"),
                "reason": None,
                "model": fields.get("model"),
                "requested_model": None,
                "provider": None,
                "key_prefix": None,
                "node": r["node"],
                "request_id": fields.get("request_id"),
                "request_ref": None,
            }
        )
    return events, total or 0
