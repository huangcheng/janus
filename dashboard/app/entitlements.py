"""Entitlement matrix engine (spec 2026-10-05, Part A).

Dashboard-owned, dashboard-written; the gateway reads the two tables via
the catalog carrier and never writes them. This module hosts:

- the probe runner (A.2): protocol-correct, budgeted, paced probes
  straight to the upstream (never via the gateway),
- the background job queue + healing loop (A.4),
- the conservative traffic refresher (A.3, PROMOTE-only in v1),
- the matrix read payload (A.5) and bind-time evidence,
- key/model lifecycle hooks (A.1).

Failure modes this module is written against (spec Part D is the test
plan; the invariants below are the ones code paths must preserve):

1.  False deny removes a good key from the pool (the WORSE failure) —
    deny needs explicit provider codes/wording; everything unclassifiable
    fails open to ok+input_shape. "no permission" / "unsupported
    operation" are input_shape, never deny.
2.  Stale evidence must never outrank fresh: every write is
    timestamp-guarded (ON CONFLICT ... WHERE excluded.checked_at > ...);
    unknown placeholders carry epoch 0 so any real evidence beats them.
3.  Two batches on one provider: pg_try_advisory_lock keyed on provider
    id is the single-flight mechanism (across replicas too).
4.  Probe storms: per-batch cap, per-provider daily cap with a reserved
    healing share (bootstrap <= 75%), 150 ms spacing, 2 keys in
    parallel, 30 s provider pause on rate-class 429, one generation bump
    per batch.
5.  Starvation loop: deny/balance keys get no traffic, so only the
    healing loop refreshes them — broken(>=22h) > balance > deny(>=22h)
    > ok(3d; 1h when input_shape-flagged unless escalated).
6.  Escalation circuit breaker: 3 consecutive input_shape re-probes set
    escalated=TRUE and the row leaves the hourly queue; traffic evidence
    re-admits it (any 200 promotes back to plain ok).
7.  Secret rotation: stale evidence of either polarity must not survive
    — wipe all rows, bump the generation (gateways drop the broken mark
    immediately), queue a re-probe bootstrap.
8.  Traffic evidence may only PROMOTE to ok in v1 (status-only 400
    cannot distinguish deny from input-shape).
9.  Crash/restart safety: daily budget counters live in Postgres, jobs
    are re-derivable (healing recomputes candidates every tick).
10. Missing-table tolerance on the READ side is a gateway concern; here
    the dashboard always creates the tables at boot (ensure_schema).
"""

import asyncio
import logging
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime

import asyncpg
import httpx

from . import audit, database, probe_urls
from .config import config
from .crypto import decrypt
from .entitlement_class import (
    EntitlementCodes,
    classify,
    extract_error_fields,
    load_codes,
    premark_match,
)

logger = logging.getLogger("janus.dashboard.entitlements")

KEY_ROW = "__key__"
# Consecutive input_shape re-probes before escalation (A.1 rule).
ESCALATE_AFTER = 3
# Status TTL windows at READ time (A.1): deny/broken 24h, balance 1h.
# Healing candidate age gates (A.4).
BROKEN_RETRY_HOURS = 22
DENY_RETRY_HOURS = 22
OK_STALE_DAYS = 3
INPUT_SHAPE_STALE_HOURS = 1
# 429 heuristic for the traffic refresher's balance canary (A.4).
REPEATED_429_THRESHOLD = 3
# Upper bound of candidates per healing job (the budget cap is the real
# limiter; this keeps one provider from monopolizing the queue).
HEAL_MAX_CANDIDATES = 400


def _now_iso() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# Budget (spec A.2 / A.4)
# ---------------------------------------------------------------------------


async def reserve_budget(provider_id: int, calls: int, healing: bool) -> bool:
    """Atomically reserve probe calls against the per-provider daily budget.

    `calls` is the total to add; the healing portion counts toward the
    reserved >=25% healing share. Non-healing triggers (manual, sync,
    bootstrap, secret rotation) are hard-capped at 75% of the daily
    budget so healing can always spend its share. Returns False when the
    relevant cap is exhausted (the caller must stop / truncate).

    Both caps are evaluated on the day's FIRST insert too (`INSERT ...
    SELECT ... WHERE`): a bare INSERT skipped them for exactly one call
    per provider per day (review M5), which still spent upstream budget
    when JANUS_PROBE_DAILY_CALLS=0.
    """
    daily = config.probe_daily_calls
    bootstrap_cap = daily * 3 // 4
    healing_n = calls if healing else 0
    row = await database.fetchrow(
        """
        INSERT INTO probe_budget_counters (provider, day, calls, healing_calls)
        SELECT $1::bigint, CURRENT_DATE, $2::bigint, $3::bigint
        WHERE $2::bigint <= $4::bigint
          AND ($2::bigint - $3::bigint) <= $5::bigint
        ON CONFLICT (provider, day) DO UPDATE SET
            calls = probe_budget_counters.calls + $2::bigint,
            healing_calls = probe_budget_counters.healing_calls + $3::bigint
        WHERE probe_budget_counters.calls + $2::bigint <= $4::bigint
          AND (probe_budget_counters.calls - probe_budget_counters.healing_calls)
              + ($2::bigint - $3::bigint) <= $5::bigint
        RETURNING calls
        """,
        provider_id,
        calls,
        healing_n,
        daily,
        bootstrap_cap,
    )
    return row is not None


async def budget_state(provider_id: int) -> dict:
    row = await database.fetchrow(
        "SELECT calls, healing_calls FROM probe_budget_counters "
        "WHERE provider = $1 AND day = CURRENT_DATE",
        provider_id,
    )
    return {
        "calls": row["calls"] if row else 0,
        "healing_calls": row["healing_calls"] if row else 0,
        "daily_limit": config.probe_daily_calls,
    }


# ---------------------------------------------------------------------------
# Timestamp-guarded writes (spec A.1)
# ---------------------------------------------------------------------------


async def _write_evidence(
    provider_key_id: int,
    model_name: str,
    status: str,
    http_status: int | None,
    error_code: str | None,
    source: str = "probe",
    event_ts: int | None = None,
) -> bool:
    """Upsert one evidence row, guarded by checked_at (newest wins).

    Returns True when a row was actually written (INSERT or guard-passing
    UPDATE). Probe rows stamp the DB clock (NOW()); traffic rows stamp
    the usage-event time (to_timestamp($ts)) — one DB clock arbitrates.
    Writes go through the pool: probe batches run 2 keys in parallel and
    a single asyncpg connection is not coroutine-safe.

    The input_shape escalation streak is computed against the prior row:
    3 consecutive ok+input_shape re-probes set escalated=TRUE (the row
    then leaves the hourly healing queue; any traffic 200 re-admits it).
    """
    streak = 0
    escalated = False
    # Only NON-premarked rows can escalate (A.1): premark writes carry no
    # http_status (zero upstream calls) and never enter the streak.
    if status == "ok" and error_code == "input_shape" and http_status is not None:
        prior = await database.fetchrow(
            "SELECT status, error_code, shape_streak FROM key_entitlements "
            "WHERE provider_key_id = $1 AND model_name = $2",
            provider_key_id,
            model_name,
        )
        if prior and prior["status"] == "ok" and prior["error_code"] == "input_shape":
            streak = (prior["shape_streak"] or 0) + 1
        else:
            streak = 1
        escalated = streak >= ESCALATE_AFTER

    checked_at = f"to_timestamp({int(event_ts)})" if event_ts is not None else "NOW()"
    tag = await database.execute(
        f"""
        INSERT INTO key_entitlements
            (provider_key_id, model_name, status, http_status, error_code,
             checked_at, source, escalated, shape_streak)
        VALUES ($1, $2, $3, $4, $5, {checked_at}, $6, $7, $8)
        ON CONFLICT (provider_key_id, model_name) DO UPDATE SET
            status = EXCLUDED.status,
            http_status = EXCLUDED.http_status,
            error_code = EXCLUDED.error_code,
            checked_at = EXCLUDED.checked_at,
            source = EXCLUDED.source,
            escalated = EXCLUDED.escalated,
            shape_streak = EXCLUDED.shape_streak
        WHERE EXCLUDED.checked_at > key_entitlements.checked_at
        """,
        provider_key_id,
        model_name,
        status,
        http_status,
        error_code,
        source,
        escalated,
        streak,
    )
    return tag != "INSERT 0 0"


async def _insert_unknown_placeholders(provider_key_id: int, provider_id: int) -> None:
    """Lazy `unknown` coverage rows (A.1): written when the probe runner
    first covers a key — never on key create. checked_at = epoch so any
    real evidence outranks the placeholder; ON CONFLICT DO NOTHING keeps
    existing evidence untouched."""
    await database.execute(
        """
        INSERT INTO key_entitlements (provider_key_id, model_name, status, checked_at, source)
        SELECT $1, pm.name, 'unknown', to_timestamp(0), 'probe'
        FROM provider_models pm WHERE pm.provider_id = $2
        ON CONFLICT (provider_key_id, model_name) DO NOTHING
        """,
        provider_key_id,
        provider_id,
    )


async def wipe_key_rows(conn: asyncpg.Connection, provider_key_id: int) -> int:
    """Delete ALL of a key's rows (secret rotation, A.1). Must run in the
    same transaction as the generation bump so gateways drop a stale
    broken mark immediately."""
    tag = await database.execute(
        "DELETE FROM key_entitlements WHERE provider_key_id = $1", provider_key_id
    )
    try:
        return int(tag.split()[-1])
    except (IndexError, ValueError):
        return 0


# ---------------------------------------------------------------------------
# Probe request shape (spec A.2)
# ---------------------------------------------------------------------------


@dataclass
class ProbeOutcome:
    kind: str  # ok | deny | balance | rate | input_shape | broken | error
    http_status: int | None
    error_code: str | None


def _probe_request(base_url: str, protocol: str, listing: str, secret: str):
    """Protocol-correct minimal request: max_tokens=1, one 'hi' user
    message, non-stream. Direct to the upstream, JSEC-decrypted key.

    The URL comes from probe_urls (review H1): the gateway joins the
    protocol suffix onto the stored base_url, so the version segment
    lives there. The helper normalises a legacy host-only base and makes
    an already-versioned base impossible to double-stack.
    """
    url = probe_urls.probe_url(base_url, protocol)
    if protocol == "anthropic_messages":
        headers = {
            "x-api-key": secret,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        }
        body = {
            "model": listing,
            "messages": [{"role": "user", "content": "hi"}],
            "max_tokens": 1,
            "stream": False,
        }
    elif protocol == "openai_responses":
        headers = {
            "authorization": f"Bearer {secret}",
            "content-type": "application/json",
        }
        body = {"model": listing, "input": "hi", "max_output_tokens": 1, "stream": False}
    elif protocol == "openai_decisions":
        # Native Decisions face: the gateway serves {base}/decisions and
        # forwards {model,input,questions} with the model rewritten
        # (janus_providers_openai.erl:174). Probing the chat path 404s
        # and classify() fail-opens that to fabricated ok evidence (H2).
        headers = {
            "authorization": f"Bearer {secret}",
            "content-type": "application/json",
        }
        body = {
            "model": listing,
            "input": "hi",
            "questions": [{"type": "predicate", "name": "ok", "instructions": "Is 2+2=4?"}],
        }
    else:  # openai_chat
        headers = {
            "authorization": f"Bearer {secret}",
            "content-type": "application/json",
        }
        body = {
            "model": listing,
            "messages": [{"role": "user", "content": "hi"}],
            "max_tokens": 1,
            "stream": False,
        }
    return url, headers, body


async def _probe_listing(
    client: httpx.AsyncClient,
    provider_name: str,
    base_url: str,
    protocol: str,
    listing: str,
    secret: str,
    codes: EntitlementCodes,
) -> ProbeOutcome:
    """One upstream probe call with the shared classifier. 5xx/transport
    errors retry once (same listing), then report 'error' (skip, leave
    prior state)."""
    url, headers, body = _probe_request(base_url, protocol, listing, secret)
    last_error: ProbeOutcome | None = None
    for _attempt in (1, 2):
        try:
            resp = await client.post(url, headers=headers, json=body)
        except Exception:
            last_error = ProbeOutcome("error", None, None)
            continue
        if 200 <= resp.status_code < 300:
            return ProbeOutcome("ok", resp.status_code, None)
        if resp.status_code in (401, 403):
            # Deny-first: a claimed code (e.g. DashScope
            # AccessDenied.Unpurchased) is MODEL-level evidence for this
            # listing; only unclaimed 401/403 are key-level deaths
            # (classify returns 'key' when no rule claims the code).
            code, message = extract_error_fields(_safe_json(resp))
            if classify(provider_name, resp.status_code, code, message, codes) == "deny":
                return ProbeOutcome("deny", resp.status_code, code)
            return ProbeOutcome("broken", resp.status_code, code)
        if resp.status_code >= 500:
            last_error = ProbeOutcome("error", resp.status_code, None)
            continue
        code, message = extract_error_fields(_safe_json(resp))
        if resp.status_code == 429:
            cls = classify(provider_name, resp.status_code, code, message, codes)
            return ProbeOutcome(cls if cls != "input_shape" else "rate", resp.status_code, code)
        cls = classify(provider_name, resp.status_code, code, message, codes)
        return ProbeOutcome(cls, resp.status_code, "input_shape" if cls == "input_shape" else code)
    return last_error or ProbeOutcome("error", None, None)


def _safe_json(resp: httpx.Response):
    try:
        return resp.json()
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Batch context + provider batch executor (spec A.2)
# ---------------------------------------------------------------------------


@dataclass
class _BatchState:
    provider_id: int
    provider_name: str
    healing: bool
    deadline_mono: float
    calls: int = 0  # upstream calls spent this batch
    rows_written: int = 0
    budget_exhausted: bool = False
    paused_until: float = 0.0  # monotonic; rate-class 429 backoff
    premarked: set = field(default_factory=set)

    def wall_expired(self) -> bool:
        return time.monotonic() > self.deadline_mono


async def _wait_pace(state: _BatchState, spacing_sec: float) -> None:
    """150 ms spacing between calls + provider-level 30 s pause on
    rate-class 429 (probes share rate pools with live traffic)."""
    now = time.monotonic()
    if state.paused_until > now:
        await asyncio.sleep(min(state.paused_until - now, 30.0))
    await asyncio.sleep(spacing_sec)


def _can_probe_more(state: _BatchState) -> bool:
    if state.calls >= config.probe_max_calls:
        return False
    return not (state.wall_expired() or state.budget_exhausted)


async def _ordered_listings(provider_id: int) -> list[str]:
    """Truncation priority (A.2): listings bound on the Router first,
    then the rest — each group alphabetical. The cap cuts the tail,
    never the bound set."""
    rows = await database.fetch(
        "SELECT name FROM provider_models WHERE provider_id = $1 ORDER BY name",
        provider_id,
    )
    names = [r["name"] for r in rows]
    bound_rows = await database.fetch(
        "SELECT DISTINCT COALESCE(mr.upstream_model_id, m.name) AS name "
        "FROM model_routes mr JOIN models m ON m.id = mr.model_id "
        "WHERE mr.provider_id = $1",
        provider_id,
    )
    bound = sorted({r["name"] for r in bound_rows if r["name"]})
    return bound + sorted(n for n in names if n not in set(bound))


def _confirmation_listing(state: _BatchState, listings: list[str], failed: str) -> str:
    """Pick the second observation used to confirm a key-level failure.

    Prefer any other probeable listing (premarked ones are written
    locally, never probed). A single-listing provider falls back to a
    retry of the same request — two consecutive 401/403 are the only
    evidence such a provider can offer.
    """
    for name in listings:
        if name != failed and name not in state.premarked:
            return name
    return failed


async def _confirm_key_broken(
    state: _BatchState,
    client: httpx.AsyncClient,
    key: asyncpg.Record,
    secret: str,
    codes: EntitlementCodes,
    base_url: str,
    protocol: str,
    listings: list[str],
    failed_listing: str,
) -> ProbeOutcome | None:
    """One more listing before benching a whole key (review M7).

    A model-scoped 403 (model not enabled on the account, region
    restriction, content policy) is indistinguishable from a revoked key
    on a single response. Returns the confirmation outcome; None means
    the batch could not fund the extra call, in which case the caller
    must NOT write the key-level broken row — never bench a key on one
    unconfirmed observation.
    """
    if not _can_probe_more(state):
        return None
    canary = _confirmation_listing(state, listings, failed_listing)
    if not await reserve_budget(state.provider_id, 1, state.healing):
        state.budget_exhausted = True
        return None
    state.calls += 1
    return await _probe_listing(
        client, state.provider_name, base_url, protocol, canary, secret, codes
    )


async def _probe_key_coverage(
    state: _BatchState,
    client: httpx.AsyncClient,
    key: asyncpg.Record,
    listings: list[str],
    codes: EntitlementCodes,
    base_url: str,
    protocol: str,
) -> dict:
    """Sequential probe of one key over the ordered listings."""
    counts = {"ok": 0, "deny": 0, "balance": 0, "skipped": 0, "premarked": 0}
    broken = False
    truncated = False
    key_id = key["id"]
    try:
        secret = decrypt(bytes(key["secret_ciphertext"])).decode()
    except Exception as e:  # pragma: no cover - corrupt envelope
        logger.warning("cannot decrypt key %s: %s", key_id, e)
        return {**counts, "broken": False, "truncated": True, "error": "decrypt_failed"}

    await _insert_unknown_placeholders(key_id, state.provider_id)

    for listing in listings:
        if not _can_probe_more(state):
            truncated = True
            break
        if listing in state.premarked:
            # Modality-family listing: mark ok+input_shape locally, zero
            # probe budget, never enters the hourly loop.
            if await _write_evidence(key_id, listing, "ok", None, "input_shape"):
                state.rows_written += 1
            counts["premarked"] += 1
            continue
        if not await reserve_budget(state.provider_id, 1, state.healing):
            state.budget_exhausted = True
            truncated = True
            break
        state.calls += 1
        outcome = await _probe_listing(
            client, state.provider_name, base_url, protocol, listing, secret, codes
        )
        if outcome.kind == "rate":
            # Rate-class 429: skip this model, pause the provider's probe
            # for 30 s, continue.
            state.paused_until = max(state.paused_until, time.monotonic() + 30.0)
            counts["skipped"] += 1
        elif outcome.kind == "broken":
            # 401/403: confirm with one more listing before benching the
            # whole key (review M7). A model-scoped 403 must not abort
            # coverage for every other listing of a healthy key.
            confirmation = await _confirm_key_broken(
                state,
                client,
                key,
                secret,
                codes,
                base_url,
                protocol,
                listings,
                listing,
            )
            if confirmation is not None and confirmation.kind == "broken":
                if await _write_evidence(
                    key_id, KEY_ROW, "broken", outcome.http_status, outcome.error_code
                ):
                    state.rows_written += 1
                audit.log(
                    "entitlement.key_broken",
                    f"{state.provider_name}:{key['key_id']}#{key_id}",
                    f"http={outcome.http_status} code={outcome.error_code} "
                    "confirmed_by=second_listing",
                )
                broken = True
                break
            if confirmation is None:
                # No budget/wall clock left for the second observation:
                # leave prior evidence untouched (never bench on one
                # unconfirmed 401/403).
                counts["skipped"] += 1
                truncated = True
                break
            if confirmation.kind == "rate":
                state.paused_until = max(state.paused_until, time.monotonic() + 30.0)
            # A live answer on another listing proves the key survived:
            # the 401/403 is listing-scoped, so record it as such and
            # keep covering the remaining listings.
            if await _write_evidence(
                key_id, listing, "deny", outcome.http_status, outcome.error_code
            ):
                state.rows_written += 1
            counts["deny"] += 1
            audit.log(
                "entitlement.key_broken_suppressed",
                f"{state.provider_name}:{key['key_id']}#{key_id}",
                f"listing={listing} http={outcome.http_status} "
                f"code={outcome.error_code} canary={confirmation.kind}",
            )
        elif outcome.kind == "error":
            # 5xx/timeout after its in-call retry: skip, leave prior state.
            counts["skipped"] += 1
        elif outcome.kind == "deny":
            if await _write_evidence(
                key_id, listing, "deny", outcome.http_status, outcome.error_code
            ):
                state.rows_written += 1
            counts["deny"] += 1
        elif outcome.kind == "balance":
            if await _write_evidence(
                key_id, listing, "balance", outcome.http_status, outcome.error_code
            ):
                state.rows_written += 1
            counts["balance"] += 1
        else:  # ok | input_shape (fail-open rows are ok+error_code=input_shape)
            err_code = "input_shape" if outcome.kind == "input_shape" else None
            if await _write_evidence(key_id, listing, "ok", outcome.http_status, err_code):
                state.rows_written += 1
            counts["ok"] += 1
        await _wait_pace(state, config.probe_spacing_ms / 1000.0)

    return {**counts, "broken": broken, "truncated": truncated}


async def _probe_single_row(
    state: _BatchState,
    client: httpx.AsyncClient,
    key: asyncpg.Record,
    listing: str,
    secret: str,
    codes: EntitlementCodes,
    base_url: str,
    protocol: str,
) -> ProbeOutcome:
    """Healing-loop probe of one (key, listing) pair."""
    if not await reserve_budget(state.provider_id, 1, state.healing):
        state.budget_exhausted = True
        return ProbeOutcome("error", None, "budget_exhausted")
    state.calls += 1
    outcome = await _probe_listing(
        client, state.provider_name, base_url, protocol, listing, secret, codes
    )
    if outcome.kind == "rate":
        state.paused_until = max(state.paused_until, time.monotonic() + 30.0)
    elif outcome.kind == "broken":
        if await _write_evidence(
            key["id"], KEY_ROW, "broken", outcome.http_status, outcome.error_code
        ):
            state.rows_written += 1
        audit.log(
            "entitlement.key_broken",
            f"{state.provider_name}:{key['key_id']}#{key['id']}",
            f"http={outcome.http_status} code={outcome.error_code} trigger=healing",
        )
    elif outcome.kind == "deny":
        if await _write_evidence(
            key["id"], listing, "deny", outcome.http_status, outcome.error_code
        ):
            state.rows_written += 1
    elif outcome.kind == "balance":
        if await _write_evidence(
            key["id"], listing, "balance", outcome.http_status, outcome.error_code
        ):
            state.rows_written += 1
    elif outcome.kind in ("ok", "input_shape"):
        err_code = "input_shape" if outcome.kind == "input_shape" else None
        if await _write_evidence(key["id"], listing, "ok", outcome.http_status, err_code):
            state.rows_written += 1
    await _wait_pace(state, config.probe_spacing_ms / 1000.0)
    return outcome


async def _apply_balance_canary(
    state: _BatchState,
    client: httpx.AsyncClient,
    key: asyncpg.Record,
    secret: str,
    codes: EntitlementCodes,
    base_url: str,
    protocol: str,
) -> None:
    """Key-scoped balance canary (A.4): when the provider's balance is
    account state, ONE probe updates ALL of that key's balance rows."""
    row = await database.fetchrow(
        "SELECT model_name FROM key_entitlements "
        "WHERE provider_key_id = $1 AND status = 'balance' ORDER BY model_name LIMIT 1",
        key["id"],
    )
    if not row:
        return
    outcome = await _probe_single_row(
        state, client, key, row["model_name"], secret, codes, base_url, protocol
    )
    if outcome.kind == "ok":
        # Topped up: every balance row of this key returns to the pool.
        tag = await database.execute(
            """
            UPDATE key_entitlements SET
                status = 'ok', http_status = 200, error_code = NULL,
                checked_at = NOW(), source = 'probe', escalated = FALSE, shape_streak = 0
            WHERE provider_key_id = $1 AND status = 'balance' AND NOW() > checked_at
            """,
            key["id"],
        )
        state.rows_written += _updated_count(tag)
    elif outcome.kind == "balance":
        # Still dry: refresh the evidence window only.
        await database.execute(
            "UPDATE key_entitlements SET checked_at = NOW() "
            "WHERE provider_key_id = $1 AND status = 'balance' AND NOW() > checked_at",
            key["id"],
        )
    # deny / broken already wrote their own single-row evidence above.


def _updated_count(tag: str) -> int:
    try:
        return int(tag.split()[-1])
    except (IndexError, ValueError):
        return 0


async def _heal_broken_key(
    state: _BatchState,
    client: httpx.AsyncClient,
    key: asyncpg.Record,
    secret: str,
    codes: EntitlementCodes,
    base_url: str,
    protocol: str,
    listings: list[str],
) -> bool:
    """Re-check a key whose __key__ row is broken (>= 22h). One canary
    call: 2xx deletes the broken mark and queues a full re-probe; 401/403
    refreshes the evidence window; anything else waits for the next tick."""
    canary = listings[0] if listings else KEY_ROW
    outcome = await _probe_single_row(state, client, key, canary, secret, codes, base_url, protocol)
    if outcome.kind == "ok":
        await database.execute(
            "DELETE FROM key_entitlements WHERE provider_key_id = $1 AND model_name = $2",
            key["id"],
            KEY_ROW,
        )
        state.rows_written += 1
        enqueue(Job(provider_id=state.provider_id, key_ids=[key["id"]], trigger="bootstrap"))
        return True
    if outcome.kind == "broken":
        await database.execute(
            "UPDATE key_entitlements SET checked_at = NOW() "
            "WHERE provider_key_id = $1 AND model_name = $2 AND NOW() > checked_at",
            key["id"],
            KEY_ROW,
        )
    return False


@dataclass
class Job:
    provider_id: int
    key_ids: list[int] | None = None  # None = all enabled keys
    rows: list[tuple[int, str]] | None = None  # healing candidates (key, listing)
    broken_keys: list[int] = field(default_factory=list)
    balance_canary_keys: list[int] = field(default_factory=list)
    trigger: str = "manual"  # manual | bootstrap | healing


_running: set[int] = set()
_last_batch: dict[int, dict] = {}
_queue: asyncio.Queue[Job] = asyncio.Queue()
_worker_task: asyncio.Task | None = None
_heal_task: asyncio.Task | None = None


def enqueue(job: Job) -> None:
    """Non-blocking enqueue (A.4: same pacing rules apply to queued work)."""
    _queue.put_nowait(job)


def probe_status() -> dict:
    """Async-probe status for GET /api/entitlements (A.5).

    ``last_batches`` is whitelisted to the four fields the SPA consumes:
    the raw execute_batch result also carries per-key envelopes and DB
    ids, which are not part of the read contract (review L3).
    """
    return {
        "running_providers": sorted(_running),
        "queued_jobs": _queue.qsize(),
        "last_batches": {
            str(pid): {
                "ran_at": info.get("ran_at"),
                "trigger": info.get("trigger"),
                "calls": info.get("calls"),
                "truncated": info.get("truncated"),
            }
            for pid, info in sorted(_last_batch.items())
        },
    }


async def execute_batch(job: Job) -> dict:
    """Run one provider batch under the per-provider advisory lock.

    Covers both full-coverage jobs (manual / bootstrap) and healing jobs
    (broken canaries, balance canaries, per-row re-probes in priority
    order). ONE generation bump per batch, only when evidence rows were
    written; one audit event per batch plus one per broken key.
    """
    provider = await database.fetchrow(
        "SELECT id, name, base_url, protocol FROM providers WHERE id = $1",
        job.provider_id,
    )
    if not provider:
        return {"skipped": "provider_missing"}

    keys = await database.fetch(
        "SELECT id, key_id, secret_ciphertext FROM provider_keys "
        "WHERE provider_id = $1 AND enabled = 1 ORDER BY id",
        job.provider_id,
    )
    if job.key_ids is not None:
        wanted = set(job.key_ids)
        keys = [k for k in keys if k["id"] in wanted]
    if not keys:
        return {"skipped": "no_keys"}

    codes = await load_codes()
    listings = await _ordered_listings(job.provider_id)
    premarked = {name for name in listings if premark_match(provider["name"], name, codes)}

    lock_conn = await database.pool().acquire()
    lock_key = f"janus_entitlement_probe:{job.provider_id}"
    try:
        locked = await lock_conn.fetchval("SELECT pg_try_advisory_lock(hashtext($1))", lock_key)
        if not locked:
            return {"skipped": "lock_busy"}

        _running.add(job.provider_id)
        state = _BatchState(
            provider_id=job.provider_id,
            provider_name=provider["name"],
            healing=job.trigger == "healing",
            deadline_mono=time.monotonic() + config.probe_wall_sec,
            premarked=premarked,
        )
        verify = probe_urls.tls_verify()
        per_key: dict[str, dict] = {}
        async with httpx.AsyncClient(timeout=config.probe_timeout_sec, verify=verify) as client:
            if job.rows is not None:
                await _run_healing_job(state, client, job, keys, codes, provider, listings)
            else:
                # Full coverage: 2 keys in parallel per provider, each key
                # sequential over the ordered listings.
                sem = asyncio.Semaphore(2)

                async def run_key(key: asyncpg.Record) -> None:
                    async with sem:
                        per_key[f"{key['key_id']}#{key['id']}"] = await _probe_key_coverage(
                            state,
                            client,
                            key,
                            listings,
                            codes,
                            provider["base_url"],
                            provider["protocol"],
                        )

                await asyncio.gather(*(run_key(k) for k in keys))

        result = {
            "provider": provider["name"],
            "trigger": job.trigger,
            "calls": state.calls,
            "rows_written": state.rows_written,
            "keys": per_key,
            "truncated": state.budget_exhausted
            or state.calls >= config.probe_max_calls
            or state.wall_expired(),
            "budget_exhausted": state.budget_exhausted,
            "ran_at": _now_iso(),
        }
        if state.rows_written > 0:
            await database.bump_generation()
        total = {
            s: sum(k.get(s, 0) for k in per_key.values())
            for s in ("ok", "deny", "balance", "skipped")
        }
        audit.log(
            "entitlement.probe",
            provider["name"],
            f"trigger={job.trigger} calls={state.calls} rows={state.rows_written} "
            f"ok={total['ok']} deny={total['deny']} balance={total['balance']} "
            f"skipped={total['skipped']} truncated={result['truncated']}",
        )
        _last_batch[job.provider_id] = result
        return result
    finally:
        _running.discard(job.provider_id)
        try:
            await lock_conn.execute("SELECT pg_advisory_unlock(hashtext($1))", lock_key)
        except Exception:
            logger.exception("advisory unlock failed for provider %s", job.provider_id)
        await database.pool().release(lock_conn)


async def _run_healing_job(
    state: _BatchState,
    client: httpx.AsyncClient,
    job: Job,
    keys: list[asyncpg.Record],
    codes: EntitlementCodes,
    provider: asyncpg.Record,
    listings: list[str],
) -> None:
    """Healing batch: broken canaries first, then balance (key-scoped
    canary where flagged, else per-row), then deny, then ok — budget and
    wall-clock caps cut the tail in that priority order."""
    by_id = {k["id"]: k for k in keys}
    secrets: dict[int, str] = {}
    for kid in (
        set(job.broken_keys) | set(job.balance_canary_keys) | {kid for kid, _ in (job.rows or [])}
    ):
        key = by_id.get(kid)
        if key is None:
            continue
        try:
            secrets[kid] = decrypt(bytes(key["secret_ciphertext"])).decode()
        except Exception:  # noqa: S112 — undecryptable secret, key cannot be probed
            continue

    base_url, protocol = provider["base_url"], provider["protocol"]

    for kid in job.broken_keys:
        if not _can_probe_more(state) or kid not in secrets:
            continue
        await _heal_broken_key(
            state, client, by_id[kid], secrets[kid], codes, base_url, protocol, listings
        )

    for kid in job.balance_canary_keys:
        if not _can_probe_more(state) or kid not in secrets:
            continue
        await _apply_balance_canary(
            state, client, by_id[kid], secrets[kid], codes, base_url, protocol
        )

    for kid, listing in job.rows or []:
        if not _can_probe_more(state):
            break
        if listing == KEY_ROW or listing in state.premarked:
            continue
        if kid not in secrets:
            continue
        await _probe_single_row(
            state, client, by_id[kid], listing, secrets[kid], codes, base_url, protocol
        )


# ---------------------------------------------------------------------------
# Background worker + healing loop (spec A.4)
# ---------------------------------------------------------------------------


async def _worker_loop() -> None:
    while True:
        job = await _queue.get()
        try:
            await execute_batch(job)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("entitlement job failed (provider %s)", job.provider_id)
        finally:
            _queue.task_done()


async def start_background() -> None:
    global _worker_task, _heal_task
    if _worker_task is None or _worker_task.done():
        _worker_task = asyncio.create_task(_worker_loop())
    if _heal_task is None or _heal_task.done():
        _heal_task = asyncio.create_task(_healing_loop())
        logger.info(
            "entitlement healing loop started (interval=%ss)",
            config.entitlement_healing_interval_sec,
        )


async def stop_background() -> None:
    global _worker_task, _heal_task
    for task in (_heal_task, _worker_task):
        if task is not None:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
    _heal_task = None
    _worker_task = None


async def _healing_loop() -> None:
    interval = config.entitlement_healing_interval_sec
    if interval <= 0:
        return
    while True:
        await asyncio.sleep(interval)
        try:
            await refresh_from_traffic()
            # Synthetic probing is operator-switchable: with
            # JANUS_ENTITLEMENT_SYNTHETIC_PROBES=0 the tick keeps the
            # usage-driven promote-only refresh but makes no provider
            # calls; demotion then rests entirely on the gateway LB's
            # runtime cooldowns (real-traffic learning).
            if config.entitlement_synthetic_probes:
                await healing_tick()
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("healing tick failed")


async def healing_tick() -> dict:
    """Compute healing candidates and enqueue one job per provider.

    Instrumented as dashboard-native task_runs (failure-obs priority-2)."""
    from .task_runs_writer import record_run

    async with record_run(
        "entitlement_heal",
        expected_duration_ms=120_000,
        schedule_interval_ms=max(config.entitlement_healing_interval_sec, 0) * 1000,
    ) as run:
        try:
            out = await _healing_tick_body()
            run.ok()
            return out
        except Exception as exc:
            run.error("internal", repr(exc))
            raise


async def _healing_tick_body() -> dict:
    """Compute healing candidates and enqueue one job per provider.

    Priority (A.2/A.4): broken(>=22h) > balance > deny(>=22h) > ok
    (3d; 1h when input_shape-flagged unless escalated). Premarked
    listings never re-enter the loop (the premark match is re-evaluated
    against the CURRENT codes rows, so a codes edit retires or re-admits
    listings without a probe). The daily budget's reserved healing share
    keeps these runnable even after a heavy bootstrap."""
    codes = await load_codes()
    providers = await database.fetch("SELECT id, name FROM providers ORDER BY id")
    enqueued: dict[str, int] = {}

    for p in providers:
        pid, name = p["id"], p["name"]
        listing_rows = await database.fetch(
            "SELECT name FROM provider_models WHERE provider_id = $1", pid
        )
        premarked = {r["name"] for r in listing_rows if premark_match(name, r["name"], codes)}

        broken_keys = [
            r["provider_key_id"]
            for r in await database.fetch(
                """
            SELECT DISTINCT ke.provider_key_id FROM key_entitlements ke
            JOIN provider_keys pk ON pk.id = ke.provider_key_id
            WHERE pk.provider_id = $1 AND ke.model_name = $2 AND ke.status = 'broken'
              AND ke.checked_at <= NOW() - ($3 || ' hours')::interval
            """,
                pid,
                KEY_ROW,
                str(BROKEN_RETRY_HOURS),
            )
        ]

        if name in codes.key_scoped_balance:
            # Balance is account state: ONE canary per key updates all of
            # that key's balance rows.
            balance_canaries = [
                r["provider_key_id"]
                for r in await database.fetch(
                    """
                SELECT DISTINCT ke.provider_key_id FROM key_entitlements ke
                JOIN provider_keys pk ON pk.id = ke.provider_key_id
                WHERE pk.provider_id = $1 AND ke.status = 'balance'
                """,
                    pid,
                )
            ]
            balance_rows: list[tuple[int, str]] = []
        else:
            balance_canaries = []
            balance_rows = [
                (r["provider_key_id"], r["model_name"])
                for r in await database.fetch(
                    """
                SELECT ke.provider_key_id, ke.model_name FROM key_entitlements ke
                JOIN provider_keys pk ON pk.id = ke.provider_key_id
                WHERE pk.provider_id = $1 AND ke.status = 'balance'
                ORDER BY ke.checked_at ASC
                """,
                    pid,
                )
            ]

        deny_rows = [
            (r["provider_key_id"], r["model_name"])
            for r in await database.fetch(
                """
            SELECT ke.provider_key_id, ke.model_name FROM key_entitlements ke
            JOIN provider_keys pk ON pk.id = ke.provider_key_id
            WHERE pk.provider_id = $1 AND ke.status = 'deny'
              AND ke.checked_at <= NOW() - ($2 || ' hours')::interval
            ORDER BY ke.checked_at ASC
            """,
                pid,
                str(DENY_RETRY_HOURS),
            )
        ]
        ok_rows = [
            (r["provider_key_id"], r["model_name"])
            for r in await database.fetch(
                """
            SELECT ke.provider_key_id, ke.model_name FROM key_entitlements ke
            JOIN provider_keys pk ON pk.id = ke.provider_key_id
            WHERE pk.provider_id = $1 AND ke.status = 'ok' AND (
                (ke.error_code IS DISTINCT FROM 'input_shape'
                 AND ke.checked_at <= NOW() - ($2 || ' days')::interval)
                OR (ke.error_code = 'input_shape' AND ke.escalated = FALSE
                    AND ke.checked_at <= NOW() - ($3 || ' hours')::interval)
            )
            ORDER BY ke.checked_at ASC
            """,
                pid,
                str(OK_STALE_DAYS),
                str(INPUT_SHAPE_STALE_HOURS),
            )
        ]

        candidates = (
            [(kid, mn) for kid, mn in balance_rows if mn not in premarked]
            + [(kid, mn) for kid, mn in deny_rows if mn not in premarked]
            + [(kid, mn) for kid, mn in ok_rows if mn not in premarked]
        )[: max(0, HEAL_MAX_CANDIDATES - len(broken_keys))]

        if broken_keys or balance_canaries or candidates:
            enqueue(
                Job(
                    provider_id=pid,
                    rows=candidates,
                    broken_keys=broken_keys,
                    balance_canary_keys=balance_canaries,
                    trigger="healing",
                )
            )
            enqueued[name] = len(broken_keys) + len(balance_canaries) + len(candidates)

    return {"enqueued": enqueued}


# ---------------------------------------------------------------------------
# Traffic refresher (spec A.3 — v1 PROMOTE-only)
# ---------------------------------------------------------------------------

_refresh_lock = asyncio.Lock()
_last_refresh: dict | None = None
_last_refresh_at: float = 0.0


async def _promote_traffic_rows(pairs: list[tuple[int, str, int]]) -> int:
    """Batch the PROMOTE-only traffic writes into one round-trip (M3).

    Same semantics as one ``_write_evidence(..., source="traffic")`` per
    pair: status ok/200, newest-event wins under the checked_at guard,
    escalated/shape_streak reset. The DISTINCT ON in the caller
    guarantees one row per (key, listing), so ON CONFLICT cannot touch
    the same row twice in one statement.
    """
    if not pairs:
        return 0
    tag = await database.execute(
        """
        INSERT INTO key_entitlements
            (provider_key_id, model_name, status, http_status, error_code,
             checked_at, source, escalated, shape_streak)
        SELECT u.key_id, u.listing, 'ok', 200, NULL,
               to_timestamp(u.ts::double precision), 'traffic', FALSE, 0
        FROM unnest($1::bigint[], $2::text[], $3::bigint[])
             AS u(key_id, listing, ts)
        ON CONFLICT (provider_key_id, model_name) DO UPDATE SET
            status = 'ok',
            http_status = 200,
            error_code = NULL,
            checked_at = EXCLUDED.checked_at,
            source = 'traffic',
            escalated = FALSE,
            shape_streak = 0
        WHERE EXCLUDED.checked_at > key_entitlements.checked_at
        """,
        [pair[0] for pair in pairs],
        [pair[1] for pair in pairs],
        [pair[2] for pair in pairs],
    )
    return _updated_count(tag)


async def refresh_from_traffic(force: bool = False) -> dict:
    """Promote-only traffic learning: usage events with status 200 turn
    their (key, listing) row into plain ok (checked_at = event ts,
    escalated reset — traffic evidence re-admits escalated rows).

    NEVER demotes in v1: status-only 400/429 cannot distinguish deny from
    input-shape (the exact bug this spec exists to fix). The only 429 use
    is the status-only canary heuristic: repeated 429s on a key whose
    rows are all ok enqueue a key-scoped balance canary PROBE — never a
    demotion.

    Scan window: last 1h of usage events, watermark-guarded by the
    checked_at upsert rule (old events never outrank fresher evidence).
    Only the newest event per (key, listing) is materialised and the
    writes go out as one statement (review M3).
    """
    global _last_refresh, _last_refresh_at
    async with _refresh_lock:
        cutoff = int(time.time()) - 3600
        rows = await database.fetch(
            """
            SELECT DISTINCT ON (ue.provider_key_id,
                                 COALESCE(mr.upstream_model_id, m.name))
                   ue.provider_key_id, ue.ts,
                   COALESCE(mr.upstream_model_id, m.name) AS listing,
                   COUNT(*) OVER () AS scanned
            FROM usage_events ue
            LEFT JOIN models m ON m.id = ue.model_id
            LEFT JOIN model_routes mr
                   ON mr.model_id = ue.model_id AND mr.provider_id = ue.provider_id
            WHERE ue.ts >= $1 AND ue.status = 200
              AND ue.provider_key_id IS NOT NULL AND ue.model_id IS NOT NULL
              AND COALESCE(mr.upstream_model_id, m.name) IS NOT NULL
            ORDER BY ue.provider_key_id, COALESCE(mr.upstream_model_id, m.name),
                     ue.ts DESC
            """,
            cutoff,
        )
        scanned = int(rows[0]["scanned"]) if rows else 0
        pairs = [(r["provider_key_id"], r["listing"], int(r["ts"])) for r in rows]
        promoted = await _promote_traffic_rows(pairs)

        canaries = await _balance_canary_heuristic(cutoff)
        _last_refresh = {
            "ran_at": _now_iso(),
            "scanned": scanned,
            "promoted": promoted,
            "balance_canaries": canaries,
        }
        _last_refresh_at = time.time()
        return _last_refresh


async def refresh_opportunistic() -> None:
    """Throttled refresh after usage polling (A.3 trigger) — at most one
    run per minute; the healing loop also runs it every 15 min."""
    if time.time() - _last_refresh_at < 60.0:
        return
    try:
        await refresh_from_traffic()
    except Exception:
        logger.exception("opportunistic entitlement refresh failed")


async def _balance_canary_heuristic(cutoff: int) -> list[int]:
    """Repeated 429s on a key whose matrix rows are all ok -> enqueue a
    key-scoped balance canary probe (safe: triggers a PROBE, never a
    demotion; gated on the provider's key_scoped_balance flag).

    Provider name and the "no bad row" test ride the aggregate (review
    M4): a fleet-wide 429 storm is this heuristic's worst case, so it
    must not cost two extra queries per surviving key.
    """
    codes = await load_codes()
    rows = await database.fetch(
        """
        SELECT ue.provider_id, ue.provider_key_id, p.name AS provider_name
        FROM usage_events ue
        JOIN providers p ON p.id = ue.provider_id
        WHERE ue.ts >= $1 AND ue.status = 429
          AND ue.provider_key_id IS NOT NULL
        GROUP BY ue.provider_id, ue.provider_key_id, p.name
        HAVING COUNT(*) >= $2
           AND NOT EXISTS (
               SELECT 1 FROM key_entitlements ke
               WHERE ke.provider_key_id = ue.provider_key_id
                 AND ke.status IN ('deny', 'balance', 'broken')
           )
        """,
        cutoff,
        REPEATED_429_THRESHOLD,
    )
    canaries: list[int] = []
    for r in rows:
        if r["provider_name"] not in codes.key_scoped_balance:
            continue
        # Matrix all-ok (or row-less): the 429s are unexplained.
        enqueue(
            Job(
                provider_id=r["provider_id"],
                balance_canary_keys=[r["provider_key_id"]],
                trigger="healing",
            )
        )
        canaries.append(r["provider_key_id"])
    return canaries


def last_refresh() -> dict | None:
    return _last_refresh


# ---------------------------------------------------------------------------
# Matrix read payload + bind-time evidence (spec A.5)
# ---------------------------------------------------------------------------


async def matrix_payload(provider_id: int | None = None) -> dict:
    """Per-listing badge data for the SPA (A.5): ok N/K, partial n/K
    (amber), deny 0/K (grey), no badge (unknown). A listing deny-marked
    for EVERY key is flagged stale_listing (likely renamed/removed
    upstream — nudge a re-sync instead of debugging fail-open churn).

    Statuses are TTL-downgraded at read time (A.1): deny/broken expire
    after 24h, balance after 1h; expired rows read as unknown. ok never
    expires consumer-side (absence = eligible); its staleness governs
    the dashboard healing loop only."""
    where = "WHERE pk.provider_id = $1" if provider_id is not None else ""
    args = (provider_id,) if provider_id is not None else ()
    fresh_rows = await database.fetch(
        f"""
        SELECT pk.provider_id, pk.id AS key_id,
               ke.model_name, ke.status, ke.error_code, ke.checked_at, ke.escalated,
               CASE WHEN ke.status IN ('deny','broken','balance') THEN (
                    (ke.status IN ('deny','broken')
                      AND ke.checked_at > NOW() - INTERVAL '24 hours')
                 OR (ke.status = 'balance'
                      AND ke.checked_at > NOW() - INTERVAL '1 hour')
               ) ELSE TRUE END AS is_fresh
        FROM key_entitlements ke
        JOIN provider_keys pk ON pk.id = ke.provider_key_id
        {where}
        """,
        *args,
    )

    providers = await database.fetch(
        "SELECT id, name FROM providers"
        + (" WHERE id = $1" if provider_id is not None else "")
        + " ORDER BY id",
        *args,
    )
    listing_counts = await database.fetch(
        "SELECT provider_id, COUNT(*) AS n FROM provider_models"
        + (" WHERE provider_id = $1" if provider_id is not None else "")
        + " GROUP BY provider_id",
        *args,
    )
    total_listings = {r["provider_id"]: r["n"] for r in listing_counts}
    key_counts = await database.fetch(
        "SELECT provider_id, COUNT(*) AS n FROM provider_keys"
        + (" WHERE provider_id = $1" if provider_id is not None else "")
        + " GROUP BY provider_id",
        *args,
    )
    keys_per_provider = {r["provider_id"]: r["n"] for r in key_counts}

    # key labels + per-key tallies
    key_rows = await database.fetch(
        "SELECT pk.id, pk.key_id AS envelope_kid, pk.provider_id "
        "FROM provider_keys pk"
        + (" WHERE pk.provider_id = $1" if provider_id is not None else "")
        + " ORDER BY pk.id",
        *args,
    )

    # tallies: (provider_id, key_id) -> counts ; (provider_id, listing) -> counts
    key_tally: dict[tuple[int, int], dict] = {}
    # per-listing cells for the SPA matrix modal: {(pid, listing) -> {key_id: cell}}
    cells: dict[tuple[int, str], dict[int, dict]] = {}
    listing_tally: dict[tuple[int, str], dict] = {}
    for r in fresh_rows:
        eff = r["status"] if r["is_fresh"] else "unknown"
        kt = key_tally.setdefault(
            (r["provider_id"], r["key_id"]),
            {
                "ok": 0,
                "deny": 0,
                "balance": 0,
                "unknown": 0,
                "input_shape": 0,
                "broken": False,
                "escalated": 0,
                "checked_at": None,
            },
        )
        lt = listing_tally.setdefault(
            (r["provider_id"], r["model_name"]),
            {"ok": 0, "deny": 0, "balance": 0, "unknown": 0},
        )
        if r["model_name"] == KEY_ROW:
            if eff == "broken":
                kt["broken"] = True
                kt["checked_at"] = r["checked_at"].isoformat()
            continue
        cells.setdefault((r["provider_id"], r["model_name"]), {})[r["key_id"]] = {
            "status": eff,
            "error_code": r["error_code"],
            "escalated": bool(r["escalated"]),
            "checked_at": r["checked_at"].isoformat(),
        }
        kt[eff] = kt.get(eff, 0) + 1
        if eff == "ok" and r["error_code"] == "input_shape":
            kt["input_shape"] += 1
        if r["escalated"]:
            kt["escalated"] += 1
        lt[eff] = lt.get(eff, 0) + 1
        if (
            r["checked_at"]
            and (kt["checked_at"] is None or r["checked_at"].isoformat() > kt["checked_at"])
            and eff != "unknown"
        ):
            kt["checked_at"] = r["checked_at"].isoformat()

    out_providers = []
    include_cells = provider_id is not None
    for p in providers:
        pid, name = p["id"], p["name"]
        keys_out = []
        for kr in key_rows:
            if kr["provider_id"] != pid:
                continue
            tally = key_tally.get((pid, kr["id"]), {})
            keys_out.append(
                {
                    "provider_key_id": kr["id"],
                    "label": f"{kr['envelope_kid']}#{kr['id']}",
                    "ok": tally.get("ok", 0),
                    "deny": tally.get("deny", 0),
                    "balance": tally.get("balance", 0),
                    "unknown": tally.get("unknown", 0),
                    "input_shape": tally.get("input_shape", 0),
                    "broken": tally.get("broken", False),
                    "escalated": tally.get("escalated", 0),
                    "total": total_listings.get(pid, 0),
                    "last_checked_at": tally.get("checked_at"),
                }
            )
        listings_out = []
        if include_cells:
            for (lpid, listing), tally in listing_tally.items():
                if lpid != pid:
                    continue
                k_total = keys_per_provider.get(pid, 0)
                ok, deny = tally["ok"], tally["deny"]
                if k_total > 0 and deny == k_total:
                    badge, stale = "deny", True
                elif deny > 0:
                    badge, stale = "partial", False
                elif ok == k_total and ok > 0:
                    badge, stale = "ok", False
                else:
                    badge, stale = None, False
                listings_out.append(
                    {
                        "model_name": listing,
                        "ok": ok,
                        "deny": deny,
                        "balance": tally["balance"],
                        "unknown": tally["unknown"],
                        "keys": k_total,
                        "badge": badge,
                        "stale_listing": stale,
                        "by_key": {
                            str(kid): cell for kid, cell in cells.get((pid, listing), {}).items()
                        },
                    }
                )
            listings_out.sort(key=lambda x: x["model_name"])
        budget = await budget_state(pid)
        out_providers.append(
            {
                "provider_id": pid,
                "provider": name,
                "keys": keys_out,
                "listings": listings_out,
                "budget": budget,
            }
        )
    return {"providers": out_providers, "probe": probe_status(), "refresh": last_refresh()}


async def bind_evidence(provider_id: int, listing_name: str) -> dict:
    """Bind-time validation evidence (A.5): fresh ok/deny counts across
    the provider's keys for one listing. Missing rows count as unknown
    (eligible), never deny."""
    rows = await database.fetch(
        """
        SELECT ke.status,
               CASE WHEN ke.status IN ('deny','broken','balance') THEN (
                    (ke.status IN ('deny','broken')
                      AND ke.checked_at > NOW() - INTERVAL '24 hours')
                 OR (ke.status = 'balance'
                      AND ke.checked_at > NOW() - INTERVAL '1 hour')
               ) ELSE TRUE END AS is_fresh
        FROM key_entitlements ke
        JOIN provider_keys pk ON pk.id = ke.provider_key_id
        WHERE pk.provider_id = $1 AND ke.model_name = $2
        """,
        provider_id,
        listing_name,
    )
    total_keys = (
        await database.fetchval(
            "SELECT COUNT(*) FROM provider_keys WHERE provider_id = $1", provider_id
        )
        or 0
    )
    ok = sum(1 for r in rows if r["is_fresh"] and r["status"] == "ok")
    deny = sum(1 for r in rows if r["is_fresh"] and r["status"] == "deny")
    return {
        "keys": total_keys,
        "ok": ok,
        "deny": deny,
        "all_deny": total_keys > 0 and deny == total_keys and deny > 0,
    }


# ---------------------------------------------------------------------------
# Lifecycle hooks (spec A.1 / A.4)
# ---------------------------------------------------------------------------


def on_key_created(provider_id: int) -> None:
    """Key insert: lazy — nothing is written until the first probe covers
    the key (no row = unknown = eligible)."""
    return


def on_secret_updated(provider_id: int, key_id: int) -> None:
    """Secret update: rows were wiped transactionally by the endpoint;
    queue the re-probe bootstrap. Row-less = unknown = eligible while the
    bootstrap waits."""
    enqueue(Job(provider_id=provider_id, key_ids=[key_id], trigger="bootstrap"))


async def on_model_sync(provider_id: int, listing_names: set[str]) -> dict:
    """After /api/models/sync (A.4): drop rows for listings that vanished
    upstream (their evidence is about a model that no longer exists),
    bump the generation when rows were dropped, and enqueue a bootstrap
    for keys that still miss rows for the new catalog."""
    if not listing_names:
        return {"dropped": 0, "bootstrapped_keys": 0}
    names = list(listing_names)
    placeholders = ", ".join(f"${i + 3}" for i in range(len(names)))
    dropped = 0
    async with database.transaction() as tx:
        tag = await tx.execute(
            f"DELETE FROM key_entitlements WHERE provider_key_id IN "
            f"(SELECT id FROM provider_keys WHERE provider_id = $1) "
            f"AND model_name <> $2 AND model_name NOT IN ({placeholders})",
            provider_id,
            KEY_ROW,
            *names,
        )
        dropped = _updated_count(tag)
        if dropped:
            await database.bump_generation(tx)

    # Keys missing evidence for any listing (no row or still-unknown
    # placeholder) get a bootstrap enqueue.
    keys = await database.fetch("SELECT id FROM provider_keys WHERE provider_id = $1", provider_id)
    bootstrapped = 0
    for k in keys:
        missing = await database.fetchval(
            """
            SELECT COUNT(*) FROM provider_models pm
            LEFT JOIN key_entitlements ke
                   ON ke.provider_key_id = $1 AND ke.model_name = pm.name
            WHERE pm.provider_id = $2 AND (ke.provider_key_id IS NULL OR ke.status = 'unknown')
            """,
            k["id"],
            provider_id,
        )
        if missing:
            enqueue(Job(provider_id=provider_id, key_ids=[k["id"]], trigger="bootstrap"))
            bootstrapped += 1
    return {"dropped": dropped, "bootstrapped_keys": bootstrapped}
