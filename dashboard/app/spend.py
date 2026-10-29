"""Query-time cost reporting (spec 2026-10-15-maturity-hardening H8).

DISPLAY-ONLY first ship (H8-D4: no scheduler/auto-tier signal, no
cost-based routing, no automatic price sync — those are named
non-goals). Everything here computes and reports; nothing enforces.

Facts this module is built on (read-verified against the gateway
migrations and the usage router):

- usage_events.model_id is an FK to models.id (NOT a name) — the price
  join resolves the name through `models` first, then matches
  model_prices BY NAME.
- usage rows may have a NULL model_id (direct unbound-listing calls) or
  a model row that carries no model_prices entry. Both aggregate into
  the `unpriced` bucket: token totals only, cost NEVER estimated
  (H8-D2).
- Token columns are NULL when the upstream did not report usage;
  COALESCE(...,0) treats those as zero tokens.
- Spend counts TERMINAL attempts only, like every other usage
  aggregate (spec E.3); the is_terminal filter is tolerant of a
  pre-E.2 gateway (probe convention: cache the positive, never the
  negative — the gateway may add the column while we run).

Cross-currency note (first-ship limitation, deliberate): prices carry a
per-model currency; aggregates sum the numeric cost across currencies
and expose the distinct `currencies` involved so a mixed sum is always
VISIBLE, never silent. The operator keeps one currency per fleet in
practice (default CNY).
"""

import logging
from datetime import UTC, datetime
from decimal import ROUND_HALF_UP, Decimal

from . import database

logger = logging.getLogger("janus.dashboard.spend")

MTOK = Decimal(1_000_000)
_COST_Q = Decimal("0.000001")  # sub-micro-cent noise floor for display

# group_by -> (dimension id expr, dimension join, dimension name expr).
# key: INNER JOIN — revoked/hard-deleted agent keys drop out of the
# spend table exactly like the usage Per-key card. model/day: no join
# needed (model via the LEFT JOIN below; day from ue.ts).
GROUPS: dict[str, tuple[str, str, str]] = {
    "key": (
        "ue.agent_key_id",
        "INNER JOIN api_keys ak ON ak.id = ue.agent_key_id",
        "ak.prefix",
    ),
    "model": (
        "ue.model_id",
        "",
        "COALESCE(m.name, '(direct)')",
    ),
    "day": (
        "to_char(date_trunc('day', to_timestamp(ue.ts) AT TIME ZONE 'UTC'), "
        "'YYYY-MM-DD\"T\"00:00')",
        "",
        "to_char(date_trunc('day', to_timestamp(ue.ts) AT TIME ZONE 'UTC'), "
        "'YYYY-MM-DD\"T\"00:00')",
    ),
}

# Tolerant is_terminal filter — same idiom as the usage router (E.3):
# NULL counts as terminal (legacy / mid-backfill rows).
_term_clause: str | None = None


async def terminal_clause() -> str:
    global _term_clause
    if _term_clause is None:
        exists = await database.fetchval(
            "SELECT 1 FROM information_schema.columns "
            "WHERE table_name = 'usage_events' AND column_name = 'is_terminal'"
        )
        if exists:
            _term_clause = " AND (ue.is_terminal IS NULL OR ue.is_terminal)"
        else:
            # usage_events is gateway-owned; never cache the negative.
            return ""
    return _term_clause


def _cost(micro: Decimal | int | None) -> float | None:
    """micro (tokens x per-Mtok price) -> cost, or None when no priced
    component. Rounded half-up to 6dp for display; JSON floats carry
    that precision losslessly at these magnitudes."""
    if micro is None:
        return None
    return float((Decimal(micro) / MTOK).quantize(_COST_Q, rounding=ROUND_HALF_UP))


async def compute_spend(frm: int, to: int, group_by: str) -> dict:
    """H8-D2: per-key / per-model / per-day spend over [frm, to), priced
    portion computed in SQL at query time, plus the never-estimated
    `unpriced` bucket and the failover-window badge data."""
    dim, join, name_expr = GROUPS[group_by]
    term = await terminal_clause()
    # Inner select: one row per (dimension, model, priced) with exact
    # Decimal math — tokens * per-Mtok price in "micro-cost" units,
    # divided by 1e6 once at the end (no intermediate float).
    rows = await database.fetch(
        f"""
        SELECT d AS id, n AS name,
               (mp.model_name IS NOT NULL) AS priced,
               mp.currency AS currency,
               SUM(pin) AS prompt_tokens, SUM(pout) AS completion_tokens,
               SUM(CASE WHEN mp.model_name IS NOT NULL
                        THEN pin * mp.input_per_mtok + pout * mp.output_per_mtok
                   END) AS micro_cost
        FROM (
            SELECT {dim} AS d, {name_expr} AS n, m.name AS model_name,
                   COALESCE(ue.prompt_tokens, 0) AS pin,
                   COALESCE(ue.completion_tokens, 0) AS pout
            FROM usage_events ue
            {join}
            LEFT JOIN models m ON m.id = ue.model_id
            WHERE ue.ts >= $1 AND ue.ts < $2{term}
        ) t
        LEFT JOIN model_prices mp ON mp.model_name = t.model_name
        GROUP BY d, n, t.model_name, priced, mp.currency,
                 mp.input_per_mtok, mp.output_per_mtok
        """,
        frm,
        to,
    )
    # Roll up per dimension value: cost = priced portion only; unpriced
    # tokens ride along per row so the table can show what cost excludes.
    dims: dict[str, dict] = {}
    unpriced_in = unpriced_out = 0
    for r in rows:
        priced = bool(r["priced"])
        pin, pout = int(r["prompt_tokens"]), int(r["completion_tokens"])
        dkey = str(r["id"])
        d = dims.setdefault(
            dkey,
            {
                "id": r["id"],
                "name": r["name"],
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "micro_cost": Decimal(0),
                "currencies": set(),
                "unpriced_prompt_tokens": 0,
                "unpriced_completion_tokens": 0,
                "priced": False,
            },
        )
        d["prompt_tokens"] += pin
        d["completion_tokens"] += pout
        if priced and r["micro_cost"] is not None:
            d["micro_cost"] += Decimal(r["micro_cost"])
            d["currencies"].add(r["currency"] or "")
            d["priced"] = True
        else:
            d["unpriced_prompt_tokens"] += pin
            d["unpriced_completion_tokens"] += pout
            unpriced_in += pin
            unpriced_out += pout
    # Distinct unpriced model count (bucket metadata) — one extra cheap
    # query keeps GROUP BY above simple; only when there is any traffic.
    unpriced_model_count = 0
    if unpriced_in or unpriced_out:
        unpriced_model_count = int(
            await database.fetchval(
                f"""
            SELECT COUNT(DISTINCT m.name)
            FROM usage_events ue
            LEFT JOIN models m ON m.id = ue.model_id
            WHERE ue.ts >= $1 AND ue.ts < $2{term}
              AND (m.name IS NULL OR NOT EXISTS (
                   SELECT 1 FROM model_prices mp WHERE mp.model_name = m.name))
            """,
                frm,
                to,
            )
            or 0
        )
    # Order: priced spend desc, then tokens desc, null-cost rows last.
    out_rows = []
    for d in dims.values():
        currencies = sorted(c for c in d["currencies"] if c)
        out_rows.append(
            {
                "id": d["id"],
                "name": d["name"],
                "prompt_tokens": d["prompt_tokens"],
                "completion_tokens": d["completion_tokens"],
                "cost": _cost(d["micro_cost"]) if d["priced"] else None,
                "currency": currencies[0]
                if len(currencies) == 1
                else ("mixed" if currencies else None),
                "unpriced_prompt_tokens": d["unpriced_prompt_tokens"],
                "unpriced_completion_tokens": d["unpriced_completion_tokens"],
            }
        )
    out_rows.sort(
        key=lambda r: (
            r["cost"] is None,
            -(r["cost"] or 0.0),
            -(r["prompt_tokens"] + r["completion_tokens"]),
        )
    )
    currencies = sorted(
        {r["currency"] for r in out_rows if r["currency"] and r["currency"] != "mixed"}
    )
    return {
        "from": frm,
        "to": to,
        "group_by": group_by,
        "rows": out_rows,
        "unpriced": {
            "prompt_tokens": unpriced_in,
            "completion_tokens": unpriced_out,
            "models": unpriced_model_count,
        },
        "currencies": currencies,
        "failover_windows": await failover_windows(frm, to),
    }


# The failover_events table is CLUSTER-SIDE and written by the (future,
# H3) promote script into the promoted DB — the dashboard cannot read
# the operator-side topology file (spec H3-D3/H8-D2 r5). Until H3 ships
# the table does not exist: that reads as "no windows" (H8-D2 r6: an
# unbounded presence must not badge forever — windows are time-filtered
# to the queried range, overlapping [ts - rpo, ts]). The range filter
# runs in SQL and the cap keeps the NEWEST rows, so old promote events
# can never hide recent windows (review M2).
DEFAULT_RPO_WINDOW_SEC = 30
_FAILOVER_FETCH_CAP = 500  # one row per promote; a cap, not a filter

# H3 may shape failover_events.ts BIGINT (epoch) or TIMESTAMPTZ. The
# Python reader tolerates both; the SQL range predicate must match the
# column type, so probe the catalog once per read (the table is created
# by future work — never cache the negative).
_EPOCH_TS_TYPES = frozenset(
    {"bigint", "integer", "smallint", "numeric", "double precision", "real"}
)
_TIMESTAMP_TS_TYPES = frozenset({"timestamp with time zone", "timestamp without time zone", "date"})


def _epoch(raw) -> int | None:
    """ts column may land as epoch int/float (gateway BIGINT convention)
    or as a datetime if H3 shapes the column TIMESTAMPTZ — normalize."""
    if raw is None:
        return None
    if isinstance(raw, datetime):
        if raw.tzinfo is None:
            raw = raw.replace(tzinfo=UTC)
        return int(raw.timestamp())
    if isinstance(raw, (int, float)):
        return int(raw)
    return None


async def _failover_table_present() -> bool:
    """False while H3 has not shipped the cluster-side table.

    Probed separately from the ts kind because "table absent" and "table
    present, ts type unknown" need different handling: the first must not
    query at all. Re-probed on every call — the table appears after
    dashboard boot, so the negative is never cached.
    """
    try:
        return bool(
            await database.fetchval(
                "SELECT 1 FROM information_schema.tables "
                "WHERE table_name = 'failover_events' LIMIT 1"
            )
        )
    except Exception:
        return False


async def _failover_ts_kind() -> bool | None:
    """True = epoch-number ts, False = timestamp ts, None = unknown.

    Returns None when the table/column does not exist yet (H3 not
    shipped): the caller keeps the "no windows" contract. Re-probed on
    every call because the table appears (and the column type may be
    chosen) after dashboard boot.
    """
    try:
        data_type = await database.fetchval(
            "SELECT data_type FROM information_schema.columns "
            "WHERE table_name = 'failover_events' AND column_name = 'ts'"
        )
    except Exception:
        return None
    if not isinstance(data_type, str):
        return None
    kind = data_type.lower()
    if kind in _EPOCH_TS_TYPES:
        return True
    if kind in _TIMESTAMP_TS_TYPES:
        return False
    return None


async def failover_windows(frm: int, to: int) -> list[dict]:
    """Failover windows overlapping [frm, to). Any read error (missing
    table, unexpected shape) is an empty list — the badge degrades to
    absent, never a 500 on the spend endpoint."""
    try:
        if not await _failover_table_present():
            # H3 has not shipped the table yet. Return "no windows" without
            # issuing the read: probing for a missing relation still logs a
            # Postgres ERROR per call, which the usage page's poll turned
            # into a continuous error stream on every fleet DB.
            return []
        kind = await _failover_ts_kind()
        if kind is True:
            rows = await database.fetch(
                "SELECT ts, COALESCE(rpo_window_sec, $1) AS rpo_window_sec "
                "FROM failover_events "
                "WHERE ts >= $2 AND ts - COALESCE(rpo_window_sec, $1) <= $3 "
                "ORDER BY ts DESC LIMIT $4",
                DEFAULT_RPO_WINDOW_SEC,
                frm,
                to,
                _FAILOVER_FETCH_CAP,
            )
        elif kind is False:
            rows = await database.fetch(
                "SELECT ts, COALESCE(rpo_window_sec, $1) AS rpo_window_sec "
                "FROM failover_events "
                "WHERE ts >= to_timestamp($2::double precision) "
                "  AND ts - make_interval(secs => COALESCE(rpo_window_sec, $1)) "
                "      <= to_timestamp($3::double precision) "
                "ORDER BY ts DESC LIMIT $4",
                DEFAULT_RPO_WINDOW_SEC,
                float(frm),
                float(to),
                _FAILOVER_FETCH_CAP,
            )
        else:
            # Table shape unknown: keep the read-side "no windows"
            # contract and bound the scan, newest first.
            rows = await database.fetch(
                "SELECT ts, COALESCE(rpo_window_sec, $1) AS rpo_window_sec "
                "FROM failover_events ORDER BY ts DESC LIMIT $2",
                DEFAULT_RPO_WINDOW_SEC,
                _FAILOVER_FETCH_CAP,
            )
    except Exception:
        return []
    out = []
    for r in rows:
        ts = _epoch(r["ts"])
        if ts is None:
            continue
        try:
            rpo = int(r["rpo_window_sec"] or DEFAULT_RPO_WINDOW_SEC)
        except (TypeError, ValueError):
            rpo = DEFAULT_RPO_WINDOW_SEC
        # Lost-usage window is [ts - rpo, ts]; keep overlaps only (the
        # SQL predicate already did this where the type was known).
        if ts >= frm and ts - rpo <= to:
            out.append({"ts": ts, "rpo_window_sec": rpo})
    return out


async def key_daily_budgets() -> dict[str, dict]:
    """H8-D3 input: priced spend for TODAY (UTC) of every agent key
    carrying a daily_cost_limit. Spend counts PRICED models only —
    never estimated; the unpriced token total rides along so the alert
    detail shows what the number excludes. Errors read as "no data"
    (rule no-data is a skip, never a false resolve/fire).

    A key whose priced traffic spans more than one currency is skipped
    (no-data) instead of comparing a cross-currency sum against the
    single-currency limit: the sum would fire or miss on a number that
    means nothing (review M6). Same "no data" contract as a read error.
    """
    term = await terminal_clause()
    try:
        rows = await database.fetch(
            f"""
            SELECT ak.id, ak.prefix, ak.daily_cost_limit,
                   COALESCE(SUM(CASE WHEN mp.model_name IS NOT NULL
                        THEN COALESCE(ue.prompt_tokens, 0) * mp.input_per_mtok
                           + COALESCE(ue.completion_tokens, 0) * mp.output_per_mtok
                       END), 0) AS micro_spend,
                   COALESCE(SUM(CASE WHEN mp.model_name IS NULL
                        THEN COALESCE(ue.prompt_tokens, 0)
                           + COALESCE(ue.completion_tokens, 0)
                       END), 0) AS unpriced_tokens,
                   COALESCE(string_agg(DISTINCT mp.currency, '/')
                            FILTER (WHERE mp.model_name IS NOT NULL), '') AS currencies
            FROM api_keys ak
            LEFT JOIN usage_events ue ON ue.agent_key_id = ak.id
                AND ue.ts >= EXTRACT(EPOCH FROM
                    date_trunc('day', NOW() AT TIME ZONE 'utc'))::bigint{term}
            LEFT JOIN models m ON m.id = ue.model_id
            LEFT JOIN model_prices mp ON mp.model_name = m.name
            WHERE ak.daily_cost_limit IS NOT NULL
            GROUP BY ak.id, ak.prefix, ak.daily_cost_limit
            """
        )
    except Exception:
        logger.exception("key daily budget read failed; rule no-data")
        return {}
    budgets: dict[str, dict] = {}
    for r in rows:
        currencies = [c for c in (r["currencies"] or "").split("/") if c]
        if len(currencies) > 1:
            logger.warning(
                "key daily budget rule skipped for key id=%s: priced models "
                "span currencies %s (cross-currency sum is not comparable to "
                "one daily limit)",
                r["id"],
                sorted(currencies),
            )
            continue
        budgets[f"key:{r['id']}"] = {
            "key_id": r["id"],
            "prefix": r["prefix"],
            "spend": Decimal(r["micro_spend"]) / MTOK,
            "limit": Decimal(r["daily_cost_limit"]),
            "unpriced_tokens": int(r["unpriced_tokens"]),
            "currencies": currencies,
        }
    return budgets
