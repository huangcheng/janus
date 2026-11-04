"""Management-plane API token CRUD (jm-…).

Modeled on the agent-keys surface (routers/keys.py): opaque secret shown
once at creation (and via the rate-limited reveal), HMAC hash for
verification, enable/disable plus hard delete, prefix-only audit. These
tokens authenticate the MCP mount today; third-party API acceptance is
a future feature riding the scope column. Dashboard-only rows — no
generation bump, ever.
"""

import logging

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse

from .. import audit, database
from ..auth import _client_ip, require_auth
from ..crypto import _active_key, decrypt, encrypt, generate_api_token, hash_api_token
from ..reveal_limit import (
    CREATE_HEADERS,
    REVEAL_HEADERS,
    check_reveal_rate,
)

router = APIRouter()
logger = logging.getLogger("janus.dashboard.tokens_api")

_TTL_CUSTOM_MAX = 3650  # days; 0 = never expires
_LABEL_MAX = 120


def _err(status: int, code: str, message: str, *, headers: dict | None = None) -> HTTPException:
    return HTTPException(
        status, detail={"error": {"code": code, "message": message}}, headers=headers
    )


def _require_keyring() -> None:
    """Fail closed when JANUS_SECRETS_KEY has no usable write key."""
    try:
        _active_key()
    except Exception:
        raise _err(503, "keyring_unconfigured", "JANUS_SECRETS_KEY is not configured")


def _parse_ttl_days(value) -> int:
    # The whole value space is "0 (never) or 1..N days" — presets are an
    # SPA affordance, not a separate server-side rule.
    if isinstance(value, bool) or not isinstance(value, int):
        raise _err(400, "invalid", "ttl must be an integer number of days (0 = never)")
    if value == 0 or 1 <= value <= _TTL_CUSTOM_MAX:
        return value
    raise _err(400, "invalid", f"ttl must be 0 (never) or 1..{_TTL_CUSTOM_MAX} days")


@router.get("")
async def list_tokens(user: dict = Depends(require_auth)):
    rows = await database.fetch(
        "SELECT id, label, prefix, scope, enabled, created_at, expires_at, last_used_at "
        "FROM api_tokens ORDER BY id"
    )
    return {
        "tokens": [
            {
                "id": r["id"],
                "label": r["label"],
                "prefix": r["prefix"],
                "scope": r["scope"],
                # SMALLINT 0/1 → JSON bool (house convention; the SPA
                # StateBadge and toggle logic consume a bool).
                "enabled": bool(r["enabled"]),
                "created_at": r["created_at"].isoformat() if r["created_at"] else None,
                "expires_at": r["expires_at"].isoformat() if r["expires_at"] else None,
                "last_used_at": r["last_used_at"].isoformat() if r["last_used_at"] else None,
            }
            for r in rows
        ]
    }


@router.post("", status_code=201)
async def create_token(request: Request, user: dict = Depends(require_auth)):
    try:
        body = await request.json()
    except ValueError:
        body = None
    if not isinstance(body, dict):
        raise _err(400, "invalid", "JSON object body required")
    label = body.get("label")
    if not isinstance(label, str) or not (1 <= len(label.strip()) <= _LABEL_MAX):
        raise _err(400, "invalid", f"label must be a string of 1..{_LABEL_MAX} chars")
    label = label.strip()
    ttl_days = _parse_ttl_days(body.get("ttl_days", 0))
    scope = body.get("scope", "full")
    if scope != "full":
        raise _err(400, "invalid", "scope must be 'full' (tiers are a future feature)")

    _require_keyring()

    # Parameterized end to end: the day count rides a bound parameter, not
    # an f-string fragment. The $6 placeholder only exists when there is a
    # TTL, so the argument list is built per-branch.
    if ttl_days:
        expires_sql = "NOW() + ($6::int * INTERVAL '1 day')"
    else:
        expires_sql = "NULL"
    for _ in range(8):
        raw = generate_api_token()
        prefix, digest = hash_api_token(raw)
        try:
            envelope = encrypt(raw.encode())
        except Exception as e:
            # No row exists yet; the raw token appears in neither the body
            # nor the log (prefix only) — the agent-key precedent.
            logger.exception("api token create encrypt failed for prefix=%s", prefix)
            raise _err(503, "encrypt_failed", "token encryption failed") from e
        args: tuple = (label, prefix, digest, envelope, scope)
        if ttl_days:
            args = (*args, ttl_days)
        try:
            row = await database.fetchrow(
                f"""
                INSERT INTO api_tokens (label, prefix, token_hash, secret_ciphertext, scope, expires_at)
                VALUES ($1, $2, $3, $4, $5, {expires_sql})
                RETURNING id, created_at, expires_at
                """,
                *args,
            )
        except asyncpg.UniqueViolationError as e:
            constraint = getattr(e, "constraint_name", None) or ""
            if constraint.endswith("api_tokens_prefix_uidx"):
                continue  # 5-char prefix collision — regenerate
            logger.exception("api token insert failed for prefix=%s", prefix)
            raise _err(500, "db_error", "insert failed") from e
        except Exception as e:
            logger.exception("api token insert failed for prefix=%s", prefix)
            raise _err(500, "db_error", "insert failed") from e
        audit.log(
            "api_token.create",
            f"api_token:{row['id']}",
            f"{prefix}… ttl=" + (f"{ttl_days}d" if ttl_days else "never"),
        )
        return JSONResponse(
            status_code=201,
            headers=CREATE_HEADERS,
            content={
                "id": row["id"],
                "label": label,
                "prefix": prefix,
                "scope": scope,
                "created_at": row["created_at"].isoformat(),
                "expires_at": row["expires_at"].isoformat() if row["expires_at"] else None,
                # The raw token appears exactly once, here.
                "token": raw,
            },
        )
    raise _err(500, "db_error", "could not generate a unique token prefix")


def _parse_token_id(raw) -> int | None:
    try:
        tid = int(raw)
    except (TypeError, ValueError):
        return None
    return tid if tid >= 1 else None


def _reveal_audit(
    target: str, outcome: str, *, sub: str | None = None, prefix: str | None = None
) -> None:
    parts = [f"sub={sub}"] if sub else []
    if prefix:
        parts.append(f"{prefix}…")
    parts.append(outcome)
    audit.log("api_token.reveal", target, " ".join(parts))


@router.get("/{token_id}/secret")
async def reveal_token(token_id: str, request: Request, user: dict = Depends(require_auth)):
    # token_id is str on purpose: a non-numeric path gets the house 404
    # shape, not FastAPI's 422 (the keys.py reveal contract).
    sub = user.get("sub")
    bucket = (
        f"sub:{sub}:{user.get('jti')}"
        if user.get("jti")
        else (f"sub:{sub}" if sub else f"ip:{_client_ip(request)}")
    )
    # Every attempt is audited — throttled and limiter-broken reveals are
    # the most security-relevant events, and the keys.py twin logs them
    # (with the attempted id, so a 429 still names its target).
    try:
        check_reveal_rate(bucket)
    except HTTPException as e:
        attempted = _parse_token_id(token_id)
        _reveal_audit(
            f"api_token:{attempted}" if attempted is not None else "api_token:?",
            e.detail["error"]["code"],
            sub=sub,
        )
        raise
    tid = _parse_token_id(token_id)
    if tid is None:
        _reveal_audit("api_token:?", "not_found", sub=sub)
        raise _err(404, "not_found", "token not found", headers=dict(REVEAL_HEADERS))
    row = await database.fetchrow(
        "SELECT prefix, secret_ciphertext FROM api_tokens WHERE id = $1", tid
    )
    if not row:
        _reveal_audit(f"api_token:{tid}", "not_found", sub=sub)
        raise _err(404, "not_found", "token not found", headers=dict(REVEAL_HEADERS))
    if row["secret_ciphertext"] is None:
        _reveal_audit(f"api_token:{tid}", "secret_unavailable", sub=sub, prefix=row["prefix"])
        raise _err(
            409,
            "secret_unavailable",
            "token was created without a recoverable secret",
            headers=dict(REVEAL_HEADERS),
        )
    # Keyring check OUTSIDE the decrypt try: it raises HTTPException, which
    # the except below would rebrand as a 500 — but audited like the rest.
    try:
        _require_keyring()
    except HTTPException:
        _reveal_audit(f"api_token:{tid}", "keyring_unconfigured", sub=sub, prefix=row["prefix"])
        raise
    try:
        raw = decrypt(row["secret_ciphertext"]).decode()
    except Exception:
        logger.exception("api token reveal decrypt failed for id=%s", tid)
        _reveal_audit(f"api_token:{tid}", "decrypt_failed", sub=sub, prefix=row["prefix"])
        raise _err(
            500,
            "decrypt_failed",
            "token secret could not be decrypted",
            headers=dict(REVEAL_HEADERS),
        )
    _reveal_audit(f"api_token:{tid}", "ok", sub=sub, prefix=row["prefix"])
    return JSONResponse(headers=REVEAL_HEADERS, content={"token": raw})


@router.post("/{token_id}/disable")
async def disable_token(token_id: int, user: dict = Depends(require_auth)):
    result = await database.execute("UPDATE api_tokens SET enabled = 0 WHERE id = $1", token_id)
    if result == "UPDATE 0":
        raise _err(404, "not_found", "token not found")
    audit.log("api_token.disable", f"api_token:{token_id}")
    return {"ok": True}


@router.post("/{token_id}/enable")
async def enable_token(token_id: int, user: dict = Depends(require_auth)):
    result = await database.execute("UPDATE api_tokens SET enabled = 1 WHERE id = $1", token_id)
    if result == "UPDATE 0":
        raise _err(404, "not_found", "token not found")
    audit.log("api_token.enable", f"api_token:{token_id}")
    return {"ok": True}


@router.delete("/{token_id}")
async def delete_token(token_id: int, user: dict = Depends(require_auth)):
    result = await database.execute("DELETE FROM api_tokens WHERE id = $1", token_id)
    if result == "DELETE 0":
        raise _err(404, "not_found", "token not found")
    audit.log("api_token.delete", f"api_token:{token_id}")
    return {"ok": True}
