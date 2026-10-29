"""OpenAI Decisions probe owner (spec 2026-10-07 §4.3).

Dashboard server-side job that validates a Decisions provider end to
end with the STORED provider key: one guide ping predicate POSTed to
{base}/decisions on the lowest-id ENABLED listing. Budget (20/day),
cooldown (5 min) and single-flight are enforced TRANSACTIONALLY on the
provider_probe_state table (one atomic reserve; the HTTP call runs
outside any transaction — the pool command_timeout is 30 s but the
probe timeout is 60 s). The probe never writes agent usage_events:
its accounting lives in provider_probe_state + audit_events only.

Classifier (O2 gate — until the not-Decisions 404 body is pinned,
everything except 2xx-with-answers and 401/403 is inconclusive):

    HTTP 2xx + body.answers is a non-empty JSON array -> ok
        (refusal-only answers are ok; empty/missing answers -> inconclusive)
    HTTP 401/403                                        -> bad_key
    400/404/405/5xx/anything else/timeout/transport     -> inconclusive

Endpoints (mounted under /api/providers):
    POST /{provider_id}/decisions-probe  — run one probe (budgeted)
    GET  /{provider_id}/decisions-probe  — state: budget, cooldown, last result
"""

import time

import httpx
from fastapi import APIRouter, Depends, HTTPException

from . import audit, database, probe_urls
from .auth import require_auth
from .crypto import decrypt
from .decisions import DECISIONS_PROTOCOL

router = APIRouter()

# Spec-pinned probe constants (§4.3): not configurable on purpose.
DAILY_BUDGET = 20
COOLDOWN_SEC = 300
PROBE_TIMEOUT_SEC = 60.0

# Last outcome per provider, in-memory only (the durable record is the
# audit row; provider_probe_state persists budget/cooldown). Lost on
# dashboard restart — acceptable, the next probe re-establishes it.
_last_result: dict[int, dict] = {}


def _err(status: int, code: str, message: str) -> HTTPException:
    return HTTPException(status, detail={"error": {"code": code, "message": message}})


# ---------------------------------------------------------------------------
# Transactional budget/cooldown reserve on provider_probe_state
# ---------------------------------------------------------------------------


async def _reserve(provider_id: int) -> dict:
    """Atomically claim one probe slot.

    The single upsert encodes all three guards, so concurrent probes
    race on the row and exactly one wins: (a) day rollover resets the
    counter, (b) daily budget, (c) 5-min cooldown. in_flight has no
    explicit guard because reserving stamps last_probe_at=NOW(): a
    crashed probe (in_flight left TRUE) is un-stuck by the very same
    cooldown once it elapses.
    """
    row = await database.fetchrow(
        """
        INSERT INTO provider_probe_state
            (provider_id, day_utc, probes_today, last_probe_at, in_flight)
        VALUES ($1, (NOW() AT TIME ZONE 'utc')::date, 1, NOW(), TRUE)
        ON CONFLICT (provider_id) DO UPDATE SET
            probes_today = CASE
                WHEN provider_probe_state.day_utc = (NOW() AT TIME ZONE 'utc')::date
                THEN provider_probe_state.probes_today + 1
                ELSE 1 END,
            day_utc = (NOW() AT TIME ZONE 'utc')::date,
            last_probe_at = NOW(),
            in_flight = TRUE
        WHERE (provider_probe_state.day_utc IS NULL
               OR provider_probe_state.day_utc <> (NOW() AT TIME ZONE 'utc')::date
               OR provider_probe_state.probes_today < $2)
          AND (provider_probe_state.last_probe_at IS NULL
               OR NOW() - provider_probe_state.last_probe_at >= make_interval(secs => $3))
        RETURNING probes_today
        """,
        provider_id,
        DAILY_BUDGET,
        COOLDOWN_SEC,
    )
    if row is not None:
        return {"ok": True, "probes_today": row["probes_today"]}

    # Reserve refused — read the row to say WHY (best-effort message;
    # the reserve itself stays the source of truth).
    state = await database.fetchrow(
        "SELECT probes_today, day_utc, last_probe_at, in_flight "
        "FROM provider_probe_state WHERE provider_id = $1",
        provider_id,
    )
    if state is None:
        return {
            "ok": False,
            "code": "probe_refused",
            "message": "probe could not be reserved (retry)",
        }
    if (
        state["in_flight"]
        and state["last_probe_at"]
        and (time.time() - state["last_probe_at"].timestamp()) < PROBE_TIMEOUT_SEC + 5
    ):
        return {
            "ok": False,
            "code": "probe_in_flight",
            "message": "a Decisions probe is already running for this provider",
        }
    if state["last_probe_at"] and (time.time() - state["last_probe_at"].timestamp()) < COOLDOWN_SEC:
        retry = int(COOLDOWN_SEC - (time.time() - state["last_probe_at"].timestamp()))
        return {
            "ok": False,
            "code": "probe_cooldown",
            "message": f"probe cooldown active — retry in ~{retry}s (5 min between probes)",
        }
    same_day = state["day_utc"] is not None and str(state["day_utc"]) == time.strftime(
        "%Y-%m-%d", time.gmtime()
    )
    if same_day and state["probes_today"] >= DAILY_BUDGET:
        return {
            "ok": False,
            "code": "probe_budget_exhausted",
            "message": f"Decisions probe budget exhausted for today "
            f"({state['probes_today']}/{DAILY_BUDGET})",
        }
    return {"ok": False, "code": "probe_refused", "message": "probe could not be reserved (retry)"}


async def _release(provider_id: int) -> None:
    """Clear the in-flight mark after the call (any outcome). Never
    raises into the response path."""
    try:
        await database.execute(
            "UPDATE provider_probe_state SET in_flight = FALSE WHERE provider_id = $1",
            provider_id,
        )
    except Exception:
        # Cooldown self-heals a stuck TRUE; losing this write is safe.
        audit.log(
            "decisions_probe",
            f"provider:{provider_id}",
            "release failed (in_flight stuck; cooldown will clear)",
        )


# ---------------------------------------------------------------------------
# Probe request + classifier
# ---------------------------------------------------------------------------


def probe_request(base_url: str, listing: str) -> tuple[str, dict, dict]:
    """Guide ping predicate, forward-path shape (§4.3): path-join
    {base}/decisions, model rewritten to the listing's upstream id."""
    url = base_url.rstrip("/") + "/decisions"
    headers = {"authorization": "", "content-type": "application/json"}
    body = {
        "model": listing,
        "input": "ping",
        "questions": [{"type": "predicate", "name": "ok", "instructions": "Is 2+2=4?"}],
    }
    return url, headers, body


def classify(http_status: int | None, body) -> str:
    """Probe outcome: ok | bad_key | inconclusive (O2 fail-safe)."""
    if http_status is None:
        return "inconclusive"  # timeout / transport error
    if http_status in (401, 403):
        return "bad_key"
    if 200 <= http_status < 300:
        answers = body.get("answers") if isinstance(body, dict) else None
        if isinstance(answers, list) and len(answers) > 0:
            return "ok"  # refusal-only answers are ok
        return "inconclusive"  # answers missing or empty
    return "inconclusive"  # 400/404/405/5xx/429/… until O2


async def _pick_listing(provider_id: int):
    """Lowest provider_models.id among ENABLED listings on the provider
    (spec §4.3 — deterministic, stable across probes)."""
    return await database.fetchrow(
        "SELECT id, name FROM provider_models "
        "WHERE provider_id = $1 AND enabled = 1 ORDER BY id LIMIT 1",
        provider_id,
    )


def _state_payload(provider_id: int, row, listing) -> dict:
    budget_used = 0
    cooldown = 0
    if row is not None:
        budget_used = row["probes_today"] or 0
        if row["last_probe_at"] is not None:
            cooldown = max(0, int(COOLDOWN_SEC - (time.time() - row["last_probe_at"].timestamp())))
    return {
        "provider_id": provider_id,
        "last_probe_at": row["last_probe_at"].isoformat() if row and row["last_probe_at"] else None,
        "probes_today": budget_used,
        "day_utc": str(row["day_utc"]) if row and row["day_utc"] else None,
        "in_flight": bool(row["in_flight"]) if row else False,
        "daily_limit": DAILY_BUDGET,
        "budget_remaining": max(0, DAILY_BUDGET - budget_used),
        "cooldown_remaining_sec": cooldown,
        "listing_pick": listing["name"] if listing else None,
        "last_result": _last_result.get(provider_id),
    }


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


async def _decisions_provider_or_404(provider_id: int):
    provider = await database.fetchrow(
        "SELECT id, name, base_url, protocol FROM providers WHERE id = $1", provider_id
    )
    if not provider:
        raise _err(404, "not_found", "provider not found")
    if provider["protocol"] != DECISIONS_PROTOCOL:
        raise _err(400, "wrong_protocol", "provider is not an openai_decisions provider")
    return provider


@router.post("/{provider_id}/decisions-probe")
async def run_decisions_probe(provider_id: int, user: dict = Depends(require_auth)):
    """POST /api/providers/{id}/decisions-probe — one budgeted Decisions
    probe with the stored provider key (billable upstream call). Does
    not touch usage_events; audited without keys or bodies."""
    provider = await _decisions_provider_or_404(provider_id)
    key = await database.fetchrow(
        "SELECT id, key_id, secret_ciphertext FROM provider_keys "
        "WHERE provider_id = $1 AND enabled = 1 ORDER BY id LIMIT 1",
        provider_id,
    )
    if not key:
        raise _err(400, "no_keys", "provider has no enabled key to probe with")
    listing = await _pick_listing(provider_id)
    if not listing:
        raise _err(400, "no_listings", "provider has no enabled listing to probe with")

    reserve = await _reserve(provider_id)
    if not reserve["ok"]:
        raise _err(429, reserve["code"], reserve["message"])

    try:
        try:
            secret = decrypt(bytes(key["secret_ciphertext"])).decode()
        except Exception as e:
            raise _err(500, "decrypt_failed", f"cannot decrypt key: {e}")

        url, headers, body = probe_request(provider["base_url"], listing["name"])
        headers["authorization"] = f"Bearer {secret}"
        verify = probe_urls.tls_verify()
        started = time.monotonic()
        http_status: int | None = None
        parsed = None
        try:
            async with httpx.AsyncClient(timeout=PROBE_TIMEOUT_SEC, verify=verify) as client:
                resp = await client.post(url, headers=headers, json=body)
            http_status = resp.status_code
            try:
                parsed = resp.json()
            except Exception:
                parsed = None
        except Exception:
            http_status, parsed = None, None
        latency_ms = int((time.monotonic() - started) * 1000)
    finally:
        await _release(provider_id)

    outcome = classify(http_status, parsed)
    result = {
        "outcome": outcome,
        "http_status": http_status,
        "latency_ms": latency_ms,
        "listing": listing["name"],
        "ran_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    _last_result[provider_id] = result

    # Audit row: outcome + accounting only — never the key or the body.
    audit.log(
        "decisions_probe",
        f"{provider['name']}:{provider_id}",
        f"outcome={outcome} http={http_status} listing={listing['name']} "
        f"latency_ms={latency_ms} probes_today={reserve['probes_today']}/{DAILY_BUDGET}",
    )

    state = await database.fetchrow(
        "SELECT last_probe_at, probes_today, day_utc, in_flight "
        "FROM provider_probe_state WHERE provider_id = $1",
        provider_id,
    )
    return {"result": result, "state": _state_payload(provider_id, state, listing)}


@router.get("/{provider_id}/decisions-probe")
async def decisions_probe_state(provider_id: int, user: dict = Depends(require_auth)):
    """GET /api/providers/{id}/decisions-probe — budget/cooldown state,
    the listing the next probe would use, and the last in-memory result."""
    await _decisions_provider_or_404(provider_id)  # 404 guard
    row = await database.fetchrow(
        "SELECT last_probe_at, probes_today, day_utc, in_flight "
        "FROM provider_probe_state WHERE provider_id = $1",
        provider_id,
    )
    listing = await _pick_listing(provider_id)
    return _state_payload(provider_id, row, listing)
