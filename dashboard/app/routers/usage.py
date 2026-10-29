"""Usage statistics endpoints.

Reads the `usage_events` rows written by gateway nodes (janus_usage).
The gateway only writes; all rollups live here in the management plane.

GET /api/usage/summary?range=24h|7d|30d — totals, series, 4 breakdowns,
writer health (from the node health monitor).
GET /api/usage/events?limit=50&key_id=&model_id= — recent drill-down.
GET /api/usage/timeline?request_ref=|trace_id= — per-attempt timeline of
one client request (the one read that sees non-terminal rows).

Spec E.3: aggregation counts terminal attempts ONLY — once the gateway
has shipped the failover usage columns, every request writes one row per
attempt and non-terminal rows are evidence, not billable traffic.
"""

import json
import re
import time

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Query

from .. import database, entitlements, nodes, spend
from ..auth import require_auth

router = APIRouter()

RANGES = {"24h": (23 * 3600, "hour"), "7d": (6 * 86400, "day"), "30d": (29 * 86400, "day")}

# Terminal-only accounting (E.3). Tolerant of a gateway that has not yet
# shipped the is_terminal column (pre-E.2 boot): without the column every
# row is legacy (= terminal by the backfill contract), so no filter is
# applied. NULL (mid-backfill legacy rows) counts as terminal.
_terminal_clause: str | None = None


async def terminal_clause() -> str:
    global _terminal_clause
    if _terminal_clause is None:
        exists = await database.fetchval(
            "SELECT 1 FROM information_schema.columns "
            "WHERE table_name = 'usage_events' AND column_name = 'is_terminal'"
        )
        if exists:
            _terminal_clause = " AND (ue.is_terminal IS NULL OR ue.is_terminal)"
        else:
            # usage_events is gateway-owned; never cache the negative —
            # the gateway may add the column while we run (ocr review).
            return ""
    return _terminal_clause


# Optional usage_events columns: request_id arrived with gateway migration
# 009, failover_reason/trace_id with 021; the dashboard can run against a
# pre-migration gateway DB (deploy order gates prod, local/dev DBs may lag),
# so the SELECT lists are built conditionally and the response fields return
# NULL when a column is absent — never a 500. Same probe convention as
# terminal_clause(): cache the positive, never the negative — the gateway
# may add the column while we run (ocr review).
_optional_selects: dict[str, str] = {}


async def ue_col_select(column: str) -> str:
    """SELECT fragment for an optional usage_events column (", ue.<column>"),
    empty when the column is absent."""
    frag = _optional_selects.get(column)
    if frag is None:
        exists = await database.fetchval(
            "SELECT 1 FROM information_schema.columns "
            "WHERE table_name = 'usage_events' AND column_name = $1",
            column,
        )
        if not exists:
            return ""
        frag = f", ue.{column}"
        _optional_selects[column] = frag
    return frag


def _err(status: int, code: str, message: str) -> HTTPException:
    return HTTPException(status, detail={"error": {"code": code, "message": message}})


def _window(range_key: str) -> tuple[int, int, str]:
    """(ts_from, ts_to, bucket) — ts_from is floored to the bucket
    boundary so a zero-filled series has exactly 24 / 7 / 30 buckets."""
    span, bucket = RANGES[range_key]
    now = int(time.time())
    step = 3600 if bucket == "hour" else 86400
    return now - span - ((now - span) % step), now, bucket


_BUCKET_EXPR = {
    "hour": "to_char(date_trunc('hour', to_timestamp(ts) AT TIME ZONE 'UTC'), 'YYYY-MM-DD\"T\"HH24:00')",
    "day": "to_char(date_trunc('day', to_timestamp(ts) AT TIME ZONE 'UTC'), 'YYYY-MM-DD\"T\"00:00')",
}


async def _totals(frm: int, to: int) -> dict:
    row = await database.fetchrow(
        "SELECT COUNT(*) AS requests, "
        "COALESCE(SUM(ue.prompt_tokens), 0) AS pin, "
        "COALESCE(SUM(ue.completion_tokens), 0) AS pout, "
        "COALESCE(SUM(CASE WHEN ue.status >= 400 THEN 1 ELSE 0 END), 0) AS errors, "
        "AVG(CASE WHEN ue.stream = 0 THEN ue.latency_ms END) AS avg_ns, "
        "AVG(CASE WHEN ue.stream = 1 THEN ue.latency_ms END) AS avg_s, "
        "COALESCE(SUM(CASE WHEN ue.prompt_tokens IS NULL AND ue.completion_tokens IS NULL "
        "AND ue.status < 400 THEN 1 ELSE 0 END), 0) AS unreported "
        f"FROM usage_events ue WHERE ue.ts >= $1 AND ue.ts < $2{await terminal_clause()}",
        frm,
        to,
    )
    return {
        "requests": row["requests"],
        "prompt_tokens": row["pin"],
        "completion_tokens": row["pout"],
        "errors": row["errors"],
        "unreported": row["unreported"],
        "avg_latency_ms": _round_or_none(row["avg_ns"]),
        "avg_stream_ms": _round_or_none(row["avg_s"]),
        "p95_latency_ms": await _p95(frm, to, 0),
        "p95_stream_ms": await _p95(frm, to, 1),
    }


def _round_or_none(v) -> int | None:
    return None if v is None else round(float(v))


async def _p95(frm: int, to: int, stream_flag: int) -> int | None:
    v = await database.fetchval(
        "SELECT percentile_disc(0.95) WITHIN GROUP (ORDER BY ue.latency_ms) "
        "FROM usage_events ue WHERE ue.ts >= $1 AND ue.ts < $2 "
        f"AND ue.latency_ms IS NOT NULL AND ue.stream = $3{await terminal_clause()}",
        frm,
        to,
        stream_flag,
    )
    return None if v is None else int(v)


async def _series(frm: int, to: int, bucket: str) -> list[dict]:
    rows = await database.fetch(
        f"SELECT {_BUCKET_EXPR[bucket]} AS b, COUNT(*) AS r, "
        "COALESCE(SUM(ue.prompt_tokens), 0) AS p, COALESCE(SUM(ue.completion_tokens), 0) AS c "
        f"FROM usage_events ue WHERE ue.ts >= $1 AND ue.ts < $2{await terminal_clause()} "
        "GROUP BY b ORDER BY b",
        frm,
        to,
    )
    return [
        {"bucket": r["b"], "requests": r["r"], "prompt_tokens": r["p"], "completion_tokens": r["c"]}
        for r in rows
    ]


_BREAKDOWNS = {
    # INNER JOIN: revoked/hard-deleted agent keys drop out of the Per-key
    # card (usage rows remain in totals/series). Other dims keep LEFT JOIN
    # so "(deleted)" / "(direct)" orphans stay visible for ops.
    "by_key": ("ue.agent_key_id", "INNER JOIN api_keys ak ON ak.id = ue.agent_key_id", "ak.prefix"),
    "by_model": ("ue.model_id", "LEFT JOIN models m ON m.id = ue.model_id", "m.name"),
    "by_provider": (
        "ue.provider_id",
        "LEFT JOIN providers p ON p.id = ue.provider_id",
        "p.name",
    ),
    "by_provider_key": (
        "ue.provider_key_id",
        "LEFT JOIN provider_keys pk ON pk.id = ue.provider_key_id "
        "LEFT JOIN providers pp ON pp.id = pk.provider_id",
        "COALESCE(pp.name, 'unknown') || ' #' || ue.provider_key_id",
    ),
}


async def _breakdown(dim: str, frm: int, to: int) -> list[dict]:
    col, join, name_expr = _BREAKDOWNS[dim]
    rows = await database.fetch(
        f"SELECT {col} AS id, {name_expr} AS name, COUNT(*) AS r, "
        "COALESCE(SUM(ue.prompt_tokens), 0) AS p, COALESCE(SUM(ue.completion_tokens), 0) AS c, "
        "MAX(ue.ts) AS last_ts "
        f"FROM usage_events ue {join} "
        f"WHERE ue.ts >= $1 AND ue.ts < $2{await terminal_clause()} "
        f"GROUP BY {col}, {name_expr} ORDER BY r DESC",
        frm,
        to,
    )
    label = "(direct)" if dim == "by_model" else "(deleted)"
    return [
        {
            "id": r["id"],
            "name": r["name"] if r["name"] is not None else label,
            "requests": r["r"],
            "prompt_tokens": r["p"],
            "completion_tokens": r["c"],
            "last_ts": r["last_ts"],
        }
        for r in rows
    ]


async def _resolution_rows(frm: int, to: int) -> list[dict]:
    """Virtual->real resolution accounting (requested_model, migration
    025): terminal rows only, and ONLY the configured auto-router
    virtual name — direct calls to real models (e.g. the judge model's
    own traffic) are not resolutions; a deleted models row (LEFT JOIN
    NULL) must not manufacture one either. Pre-025 gateways lack the
    column: degrade to [] (mixed-version fleets during a rolling
    deploy), never a 500."""
    row = await database.fetchrow("SELECT value FROM settings WHERE key = 'auto_router'")
    virtual = "janus-auto"
    if row:
        try:
            cfg = json.loads(row["value"])
            if isinstance(cfg, dict) and isinstance(cfg.get("model"), str) and cfg["model"].strip():
                virtual = cfg["model"].strip()
        except (json.JSONDecodeError, TypeError):
            pass
    try:
        rows = await database.fetch(
            "SELECT ue.requested_model AS requested, m.name AS resolved, COUNT(*) AS r, "
            "COALESCE(SUM(ue.prompt_tokens), 0) AS p, COALESCE(SUM(ue.completion_tokens), 0) AS c, "
            "MAX(ue.ts) AS last_ts "
            "FROM usage_events ue LEFT JOIN models m ON m.id = ue.model_id "
            f"WHERE ue.ts >= $1 AND ue.ts < $2 AND ue.requested_model = $3{await terminal_clause()} "
            "GROUP BY 1, 2 ORDER BY r DESC",
            frm,
            to,
            virtual,
        )
    except asyncpg.UndefinedColumnError:
        return []
    return [
        {
            "requested": r["requested"],
            "resolved": r["resolved"] if r["resolved"] is not None else "(deleted)",
            "requests": r["r"],
            "prompt_tokens": r["p"],
            "completion_tokens": r["c"],
            "last_ts": r["last_ts"],
        }
        for r in rows
    ]


def _writer() -> dict | None:
    """Writer health from the first node that reported it."""
    for h in nodes.health_data().values():
        w = h.get("usage_writer")
        if w:
            return w
    return None


@router.get("/summary")
async def summary(range: str = "24h", user: dict = Depends(require_auth)):
    if range not in RANGES:
        raise _err(400, "bad_range", "range must be one of 24h | 7d | 30d")
    frm, to, bucket = _window(range)
    # A.3 trigger: opportunistic (throttled) entitlement refresh after
    # usage polling — promote-only, fire-and-forget, never blocks the read.
    import asyncio as _aio

    _aio.get_running_loop().create_task(entitlements.refresh_opportunistic())
    return {
        "range": range,
        "ts_from": frm,
        "ts_to": to,
        "totals": await _totals(frm, to),
        "series": await _series(frm, to, bucket),
        "by_key": await _breakdown("by_key", frm, to),
        "by_model": await _breakdown("by_model", frm, to),
        "by_provider": await _breakdown("by_provider", frm, to),
        "by_provider_key": await _breakdown("by_provider_key", frm, to),
        "by_resolution": await _resolution_rows(frm, to),
        "writer": _writer(),
    }


@router.get("/spend")
async def spend_report(
    from_: int = Query(0, alias="from"),
    to: int = Query(0, alias="to"),
    group_by: str = "key",
    user: dict = Depends(require_auth),
):
    """H8 (spec 2026-10-15-maturity-hardening H8-D2): query-time cost
    report over usage_events joined to model_prices by model name.
    group_by = key | model | day; models without a price row aggregate
    into the `unpriced` bucket (token totals, never estimated) and the
    response carries cluster-side failover windows for the gap badge.
    Display-only — no enforcement reads this path."""
    if group_by not in spend.GROUPS:
        raise _err(400, "bad_group", "group_by must be one of key | model | day")
    now = int(time.time())
    if to <= 0:
        to = now
    if from_ <= 0:
        from_ = to - 86400
    if from_ >= to:
        raise _err(400, "bad_range", "from must be before to (unix seconds)")
    if to - from_ > 366 * 86400:
        raise _err(400, "bad_range", "range must be at most 366 days")
    return await spend.compute_spend(from_, to, group_by)


@router.get("/events")
async def events(
    limit: int = 50,
    offset: int = 0,
    key_id: int = 0,
    model_id: int = 0,
    provider_id: int = 0,
    status: str = "",
    user: dict = Depends(require_auth),
):
    if limit < 1 or limit > 200:
        raise _err(400, "bad_limit", "limit must be 1..200")
    if offset < 0:
        raise _err(400, "bad_offset", "offset must be >= 0")
    if status not in ("", "ok", "error"):
        raise _err(400, "bad_filter", "status must be ok | error | empty")
    where, params = ["1=1"], []
    if status == "ok":
        where.append("ue.status < 400")
    elif status == "error":
        where.append("ue.status >= 400")
    if provider_id:
        if provider_id < 1:
            raise _err(400, "bad_filter", "provider_id must be a positive integer")
        params.append(provider_id)
        where.append(f"ue.provider_id = ${len(params)}")
    if key_id:
        if key_id < 1:
            raise _err(400, "bad_filter", "key_id must be a positive integer")
        params.append(key_id)
        where.append(f"ue.agent_key_id = ${len(params)}")
    if model_id:
        if model_id < 1:
            raise _err(400, "bad_filter", "model_id must be a positive integer")
        params.append(model_id)
        where.append(f"ue.model_id = ${len(params)}")

    rid = await ue_col_select("request_id")
    rref = await ue_col_select("request_ref")
    tid = await ue_col_select("trace_id")
    # Migration-010 columns; degrade to the legacy select on a
    # not-yet-migrated gateway (rolling deploy window).
    try:
        rows = await database.fetch(
            "SELECT ue.ts, ak.prefix, m.name AS model, p.name AS provider, ue.protocol, "
            "ue.stream, ue.status, ue.prompt_tokens, ue.completion_tokens, ue.latency_ms, "
            f"ue.modality, ue.units, ue.outcome, ue.cache_read_input_tokens{rid}{rref}{tid} "
            "FROM usage_events ue "
            "LEFT JOIN api_keys ak ON ak.id = ue.agent_key_id "
            "LEFT JOIN models m ON m.id = ue.model_id "
            "LEFT JOIN providers p ON p.id = ue.provider_id "
            f"WHERE {' AND '.join(where)}{await terminal_clause()} "
            f"ORDER BY ue.ts DESC, ue.id DESC LIMIT ${len(params) + 1} OFFSET ${len(params) + 2}",
            *params,
            limit,
            offset,
        )
    except Exception:
        rows = await database.fetch(
            "SELECT ue.ts, ak.prefix, m.name AS model, p.name AS provider, ue.protocol, "
            f"ue.stream, ue.status, ue.prompt_tokens, ue.completion_tokens, ue.latency_ms{rid}{rref}{tid} "
            "FROM usage_events ue "
            "LEFT JOIN api_keys ak ON ak.id = ue.agent_key_id "
            "LEFT JOIN models m ON m.id = ue.model_id "
            "LEFT JOIN providers p ON p.id = ue.provider_id "
            f"WHERE {' AND '.join(where)}{await terminal_clause()} "
            f"ORDER BY ue.ts DESC, ue.id DESC LIMIT ${len(params) + 1} OFFSET ${len(params) + 2}",
            *params,
            limit,
            offset,
        )
    # total under the SAME filters for the pagination control
    total = await database.fetchval(
        "SELECT COUNT(*) FROM usage_events ue "
        f"WHERE {' AND '.join(where)}{await terminal_clause()}",
        *params,
    )
    return {
        "total": total or 0,
        "limit": limit,
        "offset": offset,
        "events": [
            {
                "ts": r["ts"],
                "key_prefix": r["prefix"],
                "model": r["model"],
                "provider": r["provider"],
                "protocol": r["protocol"],
                "stream": r["stream"],
                "status": r["status"],
                "prompt_tokens": r["prompt_tokens"],
                "completion_tokens": r["completion_tokens"],
                "latency_ms": r["latency_ms"],
                "modality": r.get("modality") or "chat",
                "units": r.get("units"),
                "outcome": r.get("outcome"),
                "cache_read_input_tokens": r.get("cache_read_input_tokens"),
                "request_id": r["request_id"] if rid else None,
                "request_ref": r["request_ref"] if rref else None,
                "trace_id": r["trace_id"] if tid else None,
            }
            for r in rows
        ],
    }


_REF_RE = re.compile(r"[0-9a-fA-F]{32}")  # the OTP mint emits UPPERCASE hex
_TRACE_RE = re.compile(r"[0-9a-f]{32}")  # W3C trace-id: strictly lowercase


@router.get("/timeline")
async def timeline(
    request_ref: str = "",
    trace_id: str = "",
    user: dict = Depends(require_auth),
):
    if bool(request_ref) == bool(trace_id):
        raise _err(400, "bad_request", "exactly one of request_ref or trace_id is required")
    # 021 columns are probe-conditional: omitted from the SQL entirely on a
    # pre-021 DB (the response fields then return NULL — never a 500).
    freason = await ue_col_select("failover_reason")
    tid = await ue_col_select("trace_id")
    rid = await ue_col_select("request_id")
    if trace_id:
        if not _TRACE_RE.fullmatch(trace_id):
            raise _err(400, "bad_request", "trace_id must be 32 lowercase hex characters")
        if not tid:
            raise _err(
                400,
                "trace_id_unavailable",
                "trace_id requires gateway migration 021 on usage_events — "
                "query by request_ref instead",
            )
        # Two-step: a trace-id may span several client requests (clients can
        # reuse one), so the most recent TERMINAL row wins. is_terminal is
        # BOOLEAN NOT NULL since 008 — older than 021, always present here.
        # An in-flight request has no terminal row yet and 404s, same as the
        # attempts-without-terminal case below.
        ref = await database.fetchval(
            "SELECT request_ref FROM usage_events "
            "WHERE trace_id = $1 AND is_terminal ORDER BY ts DESC LIMIT 1",
            trace_id,
        )
        # A NULL request_ref (legacy row) resolves like a miss.
        if not ref:
            raise _err(
                404,
                "timeline_not_found",
                "no terminal usage row for this trace_id (unknown or still in flight)",
            )
    else:
        if not _REF_RE.fullmatch(request_ref):
            raise _err(400, "bad_request", "request_ref must be 32 hex characters")
        ref = request_ref

    # The timeline is the ONE read that must see non-terminal attempt rows —
    # they ARE the failover evidence — so it deliberately does not apply
    # terminal_clause(). Every aggregate above stays terminal-only.
    # upper($1): param-side case normalization (the mint is uppercase);
    # the column side stays bare, so usage_events_request_ref_idx still applies.
    rows = await database.fetch(
        "SELECT ue.ts, ue.attempt, ue.is_terminal, ue.status, ue.error_code"
        f"{freason}, ue.latency_ms, ue.protocol, ue.stream"
        f"{tid}{rid}, ue.request_ref, "
        "m.name AS model, p.name AS provider, ue.provider_key_id, "
        "ak.prefix AS key_prefix "
        "FROM usage_events ue "
        "LEFT JOIN providers p ON p.id = ue.provider_id "
        "LEFT JOIN models m ON m.id = ue.model_id "
        "LEFT JOIN api_keys ak ON ak.id = ue.agent_key_id "
        "WHERE ue.request_ref = upper($1) ORDER BY ue.attempt, ue.id LIMIT 50",
        ref,
    )
    if not rows:
        raise _err(404, "timeline_not_found", "no usage rows for this request_ref")
    terminal = next((r for r in rows if r["is_terminal"]), None)
    if terminal is None:
        raise _err(
            404,
            "timeline_not_found",
            "request is still in flight (attempt rows exist, no terminal row yet)",
        )
    return {
        "request": {
            "request_ref": terminal["request_ref"],
            "trace_id": terminal["trace_id"] if tid else None,
            "model": terminal["model"],
            "key_prefix": terminal["key_prefix"],
            "terminal_status": terminal["status"],
            # The terminal row's latency is the request's end-to-end total;
            # non-terminal attempt rows record latency_ms = 0.
            "total_latency_ms": terminal["latency_ms"],
            "attempts": len(rows),
        },
        "attempts": [
            {
                "ts": r["ts"],
                "attempt": r["attempt"],
                "is_terminal": r["is_terminal"],
                "status": r["status"],
                "error_code": r["error_code"],
                "failover_reason": r["failover_reason"] if freason else None,
                "latency_ms": r["latency_ms"],
                "protocol": r["protocol"],
                "stream": r["stream"],
                "trace_id": r["trace_id"] if tid else None,
                "request_id": r["request_id"] if rid else None,
                "model": r["model"],
                "provider": r["provider"],
                "provider_key_id": r["provider_key_id"],
                "key_prefix": r["key_prefix"],
            }
            for r in rows
        ],
    }
