"""Model price CRUD (spec 2026-10-15-maturity-hardening H8-D1).

Operator-entered per-Mtok prices for spend reporting (H8-D2) — a
dashboard-only table the gateway never reads, so writes do NOT bump the
config generation. Display-only first ship (H8-D4): no automatic price
sync from providers, ever. Every mutation is audit-logged like the
other console writes.
"""

import re
from decimal import Decimal, InvalidOperation

from fastapi import APIRouter, Depends, HTTPException, Request

from .. import audit, database
from ..auth import require_auth

router = APIRouter()

NAME_MAX = 200
_CURRENCY_RE = re.compile(r"^[A-Z]{3}$")
DEFAULT_CURRENCY = "CNY"


def _err(status: int, code: str, message: str) -> HTTPException:
    return HTTPException(status, detail={"error": {"code": code, "message": message}})


def _price_field(body: dict, field: str) -> Decimal:
    """Non-negative finite number -> Decimal (bool rejected)."""
    if field not in body:
        raise _err(400, "invalid", f"{field} is required")
    val = body[field]
    if isinstance(val, bool) or not isinstance(val, (int, float, str)):
        raise _err(400, "invalid", f"{field} must be a non-negative number")
    try:
        d = Decimal(str(val))
    except InvalidOperation:
        raise _err(400, "invalid", f"{field} must be a non-negative number")
    if not d.is_finite() or d < 0:
        raise _err(400, "invalid", f"{field} must be a non-negative number")
    return d


def _currency(body: dict) -> str:
    cur = body.get("currency", DEFAULT_CURRENCY)
    if cur is None:
        cur = DEFAULT_CURRENCY
    if not isinstance(cur, str) or not _CURRENCY_RE.fullmatch(cur.strip()):
        raise _err(400, "invalid", "currency must be a 3-letter ISO code (e.g. CNY, USD)")
    return cur.strip()


def _row(r) -> dict:
    return {
        "model_name": r["model_name"],
        "input_per_mtok": float(r["input_per_mtok"]),
        "output_per_mtok": float(r["output_per_mtok"]),
        "currency": r["currency"],
        "updated_at": str(r["updated_at"]),
    }


@router.get("")
async def list_prices(user: dict = Depends(require_auth)):
    rows = await database.fetch(
        "SELECT model_name, input_per_mtok, output_per_mtok, currency, updated_at "
        "FROM model_prices ORDER BY model_name"
    )
    return {"prices": [_row(r) for r in rows]}


@router.put("/{model_name}")
async def put_price(model_name: str, request: Request, user: dict = Depends(require_auth)):
    name = model_name.strip()
    if not name or len(name) > NAME_MAX:
        raise _err(400, "invalid", f"model_name must be 1..{NAME_MAX} characters")
    body = await request.json()
    if not isinstance(body, dict):
        raise _err(400, "invalid", "body must be a JSON object")
    unknown = set(body) - {"input_per_mtok", "output_per_mtok", "currency"}
    if unknown:
        raise _err(400, "unknown_fields", f"unknown fields: {sorted(unknown)}")
    # Both prices required: a half-priced row would silently make spend
    # incomplete; a missing side is a delete, not a zero.
    input_price = _price_field(body, "input_per_mtok")
    output_price = _price_field(body, "output_per_mtok")
    currency = _currency(body)
    row = await database.fetchrow(
        """
        INSERT INTO model_prices (model_name, input_per_mtok, output_per_mtok, currency, updated_at)
        VALUES ($1, $2, $3, $4, NOW())
        ON CONFLICT (model_name) DO UPDATE SET
            input_per_mtok = EXCLUDED.input_per_mtok,
            output_per_mtok = EXCLUDED.output_per_mtok,
            currency = EXCLUDED.currency,
            updated_at = NOW()
        RETURNING model_name, input_per_mtok, output_per_mtok, currency, updated_at
        """,
        name,
        input_price,
        output_price,
        currency,
    )
    audit.log(
        "price.set",
        f"model:{name}",
        f"in={input_price}/Mt out={output_price}/Mt {currency}",
    )
    return _row(row)


@router.delete("/{model_name}")
async def delete_price(model_name: str, user: dict = Depends(require_auth)):
    name = model_name.strip()
    tag = await database.execute("DELETE FROM model_prices WHERE model_name = $1", name)
    if tag.endswith(" 0"):
        raise _err(404, "not_found", "no price row for this model")
    audit.log("price.delete", f"model:{name}")
    return {"ok": True}
