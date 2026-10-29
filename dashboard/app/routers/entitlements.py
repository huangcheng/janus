"""Entitlement matrix endpoints (spec 2026-10-05, Part A).

- GET  /api/entitlements?provider_id= — per-listing badge data (A.5)
- POST /api/entitlements/refresh      — run the traffic refresher (A.3)
- GET  /api/entitlements/codes        — classification rules (single source)
- POST /api/entitlements/codes        — add a rule (bumps generation,
                                        resets escalated rows, re-queues)
- DELETE /api/entitlements/codes/{id} — remove a rule (same propagation)

The probe endpoints live under /api/providers (see providers.py).
"""

import re

from fastapi import APIRouter, Depends, HTTPException, Request

from .. import audit, database, entitlements
from ..auth import require_auth
from ..entitlement_class import MAX_PATTERN_LEN, invalidate_codes_cache

router = APIRouter()


def _err(status: int, code: str, message: str) -> HTTPException:
    return HTTPException(status, detail={"error": {"code": code, "message": message}})


@router.get("")
async def get_entitlements(provider_id: int = 0, user: dict = Depends(require_auth)):
    """GET /api/entitlements?provider_id= — matrix badge data.

    Without provider_id: summaries for every provider (no listing rows).
    With provider_id: full per-listing rows for the matrix modal."""
    if provider_id:
        row = await database.fetchrow("SELECT id FROM providers WHERE id = $1", provider_id)
        if not row:
            raise _err(404, "not_found", "provider not found")
    payload = await entitlements.matrix_payload(provider_id or None)
    return payload


@router.post("/refresh")
async def refresh_entitlements(user: dict = Depends(require_auth)):
    """POST /api/entitlements/refresh — manual traffic-refresher run
    (v1: PROMOTE-only, 1h scan window, never demotes)."""
    result = await entitlements.refresh_from_traffic(force=True)
    audit.log(
        "entitlement.refresh",
        None,
        f"scanned={result['scanned']} promoted={result['promoted']} "
        f"canaries={len(result['balance_canaries'])}",
    )
    return result


@router.get("/codes")
async def list_codes(user: dict = Depends(require_auth)):
    """GET /api/entitlements/codes — the classification rule table."""
    rows = await database.fetch(
        "SELECT id, provider, match_status, code_keyword, outcome, key_scoped_balance, "
        "created_at FROM entitlement_codes ORDER BY provider, match_status, outcome, id"
    )
    return {
        "codes": [
            {
                "id": r["id"],
                "provider": r["provider"],
                "match_status": r["match_status"],
                "code_keyword": r["code_keyword"],
                "outcome": r["outcome"],
                "key_scoped_balance": bool(r["key_scoped_balance"]),
                "created_at": r["created_at"].isoformat(),
            }
            for r in rows
        ]
    }


OUTCOMES = ("deny", "balance", "rate", "input_shape", "premark_input_shape")


async def _codes_write_propagation(trigger: str) -> None:
    """Every codes-table write (spec A.2): bump the generation so gateways
    re-pull the carrier, RESET escalated on affected rows and re-queue
    them for re-probe (a retired premark may have hidden real evidence)."""
    async with database.transaction() as tx:
        await tx.execute(
            "UPDATE key_entitlements SET escalated = FALSE, shape_streak = 0 WHERE escalated"
        )
        gen = await database.bump_generation(tx)
    invalidate_codes_cache()
    # Re-probe the previously-escalated rows on the next healing tick.
    await entitlements.healing_tick()
    audit.log("entitlement.codes", None, f"{trigger} generation={gen}")


@router.post("/codes", status_code=201)
async def add_code(request: Request, user: dict = Depends(require_auth)):
    """POST /api/entitlements/codes — add one classification rule.

    Regex rows are validated at write time: must compile and fit the
    length cap. provider='' applies to every provider."""
    body = await request.json()
    provider = str(body.get("provider", "")).strip()
    match_status = str(body.get("match_status", "")).strip()
    keyword = str(body.get("code_keyword", "")).strip()
    outcome = str(body.get("outcome", "")).strip()
    key_scoped = bool(body.get("key_scoped_balance", False))

    if match_status not in ("exact", "regex"):
        raise _err(400, "invalid", "match_status must be 'exact' or 'regex'")
    if not keyword:
        raise _err(400, "invalid", "code_keyword required")
    if outcome not in OUTCOMES:
        raise _err(400, "invalid", f"outcome must be one of {OUTCOMES}")
    if provider:
        exists = await database.fetchrow("SELECT id FROM providers WHERE name = $1", provider)
        if not exists:
            raise _err(400, "invalid", f"unknown provider: {provider}")
    if match_status == "regex":
        if len(keyword) > MAX_PATTERN_LEN:
            raise _err(400, "invalid", f"regex longer than {MAX_PATTERN_LEN} chars")
        try:
            re.compile(keyword, re.IGNORECASE)
        except re.error as e:
            raise _err(400, "invalid_regex", f"pattern does not compile: {e}")

    row = await database.fetchrow(
        "INSERT INTO entitlement_codes (provider, match_status, code_keyword, outcome, "
        "key_scoped_balance) VALUES ($1, $2, $3, $4, $5) RETURNING id",
        provider,
        match_status,
        keyword,
        outcome,
        key_scoped,
    )
    await _codes_write_propagation(f"add id={row['id']}")
    return {"id": row["id"], "ok": True}


@router.delete("/codes/{code_id}")
async def delete_code(code_id: int, user: dict = Depends(require_auth)):
    """DELETE /api/entitlements/codes/{id} — remove one rule."""
    tag = await database.execute("DELETE FROM entitlement_codes WHERE id = $1", code_id)
    if tag == "DELETE 0":
        raise _err(404, "not_found", "code row not found")
    await _codes_write_propagation(f"delete id={code_id}")
    return {"ok": True}
