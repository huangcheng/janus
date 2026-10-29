"""Auth endpoints: database-backed account (username/password + TOTP +
passkey), session check, and credential management.

Login state machine (SPA-facing):
  GET  /api/auth/status
       {configured, username?, has_password, has_totp, has_passkey}
  POST /api/auth/setup {username, password} -> {token}        (once)
  POST /api/auth/login {username, password, turnstile_token?}
       -> {token} | 401 {code: totp_required, challenge_token}
  POST /api/auth/login/totp {challenge_token, code} -> {token}
       (code = 6-digit TOTP, or a one-time recovery key)
  POST /api/auth/login/passkey/assertion/options
  POST /api/auth/login/passkey/verify

Management (full session required):
  POST   /api/auth/password {current, next}
  POST   /api/auth/totp/enable -> {secret, provisioning_uri} (unconfirmed)
  POST   /api/auth/totp/confirm {secret, code} -> {ok, codes: [...]}
       (persists TOTP and mints a fresh set of one-time recovery keys)
  POST   /api/auth/totp/qr {password} -> {secret, provisioning_uri}
       (re-scan an already-enabled account on a new device)
  POST   /api/auth/totp/disable {password} (also wipes recovery keys)
  GET    /api/auth/recovery -> {total, remaining}
  POST   /api/auth/recovery/regenerate {password} -> {codes: [...]}
  POST   /api/auth/passkey/register/options
  POST   /api/auth/passkey/register/verify
  GET    /api/auth/passkeys
  DELETE /api/auth/passkeys/{credential_id}
"""

import urllib.parse

from fastapi import APIRouter, Depends, HTTPException, Request

from .. import audit
from .. import passkey as pk
from ..auth import (
    CHALLENGE_TTL_SEC,
    RECOVERY_COUNT,
    _client_ip,
    create_token,
    generate_recovery_codes,
    get_account,
    hash_password,
    is_locked,
    normalize_recovery_input,
    record_auth_event,
    require_auth,
    totp_provisioning_uri,
    totp_secret_decrypt,
    totp_secret_encrypt,
    totp_verify_at,
    verify_password,
)
from ..config import config
from ..crypto import hash_recovery_code
from ..turnstile import verify_login_token

router = APIRouter()

# --- helpers -------------------------------------------------------------


def _err(status: int, code: str, message: str) -> HTTPException:
    return HTTPException(status, detail={"error": {"code": code, "message": message}})


def _invalid(message: str) -> HTTPException:
    return _err(400, "invalid", message)


async def _json(request: Request) -> dict:
    try:
        parsed = await request.json()
    except ValueError:
        raise _invalid("body must be a JSON object")
    if not isinstance(parsed, dict):
        raise _invalid("body must be a JSON object")
    return parsed


def _rp_id(request: Request) -> str:
    """WebAuthn RP ID = a registrable domain suffix of the host the SPA
    is served from. For public-origin / localhost / IP deployments the
    host itself is the correct default."""
    host = urllib.parse.urlparse(str(request.url)).hostname or "localhost"
    return host


def _allowed_origins_for(request: Request) -> set[str]:
    scheme = urllib.parse.urlparse(str(request.url)).scheme or "https"
    host_header = request.headers.get("host", "localhost")
    origins = {f"{scheme}://{host_header}"}
    # caddy serves https publicly; include both schemes for the same host
    # so a local http preview and prod https both work.
    host = urllib.parse.urlparse(str(request.url)).hostname or "localhost"
    origins.add(f"https://{host}")
    origins.add(f"http://{host}")
    return origins


async def _turnstile_ok(body: dict, request: Request) -> None:
    """Turnstile gate on the password step. Failures 403 and do NOT
    count toward lockout (bot traffic, not credential guessing)."""
    if not config.turnstile_secret:
        return
    raw = body.get("turnstile_token")
    if raw is None:
        raw = body.get("cf-turnstile-response")
    if not isinstance(raw, str):
        raise _err(403, "turnstile_failed", "human verification failed; refresh and try again")
    ok = await verify_login_token(raw, remoteip=_client_ip(request))
    if not ok:
        raise _err(403, "turnstile_failed", "human verification failed; refresh and try again")


# --- public (no session) ------------------------------------------------


@router.get("/status")
async def auth_status():
    acct = await get_account()
    from ..database import fetchval

    n_passkeys = 0
    try:
        n_passkeys = await fetchval("SELECT COUNT(*) FROM passkey_credentials") or 0
    except Exception:
        from ..auth import logger as _al

        _al.debug("passkey count failed on first boot", exc_info=True)
    if acct is None:
        return {"configured": False, "has_password": False, "has_totp": False, "has_passkey": False}
    return {
        "configured": True,
        "username": acct["username"],
        "has_password": acct["password_hash"] is not None,
        "has_totp": bool(acct["totp_enabled"]),
        "has_passkey": n_passkeys > 0,
    }


@router.post("/setup")
async def auth_setup(request: Request):
    """One-time account creation. Only valid when operator_account is
    empty — after that it 409s forever."""
    acct = await get_account()
    if acct is not None:
        raise _err(409, "already_configured", "the operator account already exists")
    body = await _json(request)
    username = body.get("username")
    password = body.get("password")
    if not isinstance(username, str) or not (3 <= len(username.strip()) <= 64):
        raise _invalid("username must be a string of 3..64 chars")
    if not isinstance(password, str) or len(password) < 8:
        raise _invalid("password must be a string of at least 8 chars")
    username = username.strip()

    from ..database import execute

    await execute(
        """
        INSERT INTO operator_account (id, username, password_hash)
        VALUES (1, $1, $2)
        ON CONFLICT (id) DO NOTHING
        """,
        username,
        hash_password(password),
    )
    audit.log("auth.setup", username, "operator account created")
    await record_auth_event("setup", True, _client_ip(request), username)
    token = create_token(username)
    return {"ok": True, "token": token, "username": username}


@router.post("/login")
async def auth_login(request: Request):
    """Password step. Full session when no TOTP; otherwise a 401 with
    a 5-minute scope=partial challenge token for the TOTP step."""
    body = await _json(request)
    await _turnstile_ok(body, request)
    username = body.get("username")
    password = body.get("password")
    if not isinstance(username, str) or not isinstance(password, str):
        raise _invalid("username and password must be strings")

    ip = _client_ip(request)
    if await is_locked(ip):
        await record_auth_event("lockout", False, ip, "login blocked (locked)")
        raise _err(429, "locked", "too many failed attempts; wait for the lockout to expire")

    acct = await get_account()
    if acct is None:
        raise _err(409, "setup_required", "no operator account — open /setup first")
    if (
        not hmac_str_eq(acct["username"], username.strip())
        or acct["password_hash"] is None
        or not verify_password(acct["password_hash"], password)
    ):
        await record_auth_event("login_password", False, ip, username[:32])
        audit.log("auth.login_failed", username[:32], "password step")
        raise _err(401, "invalid_credentials", "wrong username or password")

    if acct["totp_enabled"] and acct["totp_secret"]:
        challenge = create_token(acct["username"], scope="partial", ttl=CHALLENGE_TTL_SEC)
        await record_auth_event("login_password", True, ip, "totp step issued")
        raise _totp_required(challenge)

    await record_auth_event("login_password", True, ip, acct["username"])
    audit.log("auth.login", acct["username"], "password")
    token = create_token(acct["username"])
    return {"ok": True, "token": token, "username": acct["username"]}


def _totp_required(challenge_token: str) -> HTTPException:
    class _TotpError(HTTPException):
        def __init__(self):
            super().__init__(
                status_code=401,
                detail={
                    "error": {
                        "code": "totp_required",
                        "message": "enter your authenticator code",
                        "challenge_token": challenge_token,
                    },
                },
            )

    return _TotpError()


def hmac_str_eq(a: str, b: str) -> bool:
    import hmac as _hmac

    return _hmac.compare_digest(a.encode(), b.encode())


@router.post("/login/totp")
async def auth_login_totp(request: Request):
    """Second factor step: consume the challenge token + a 6-digit code
    (or a one-time recovery key)."""
    from ..auth import verify_token
    from ..database import execute, fetchrow, fetchval

    body = await _json(request)
    challenge_token = body.get("challenge_token")
    code = body.get("code")
    if not isinstance(challenge_token, str) or not isinstance(code, str):
        raise _invalid("challenge_token and code must be strings")

    ip = _client_ip(request)
    if await is_locked(ip):
        raise _err(429, "locked", "too many failed attempts; wait for the lockout to expire")

    import jwt as pyjwt

    try:
        payload = verify_token(challenge_token)
    except pyjwt.ExpiredSignatureError:
        raise _err(401, "challenge_expired", "the challenge expired; sign in again")
    except pyjwt.InvalidTokenError:
        raise _err(401, "invalid_challenge", "the challenge token is invalid")
    if payload.get("scope") != "partial":
        raise _err(401, "invalid_challenge", "not a challenge token")

    acct = await get_account()
    if acct is None or not acct["totp_enabled"] or not acct["totp_secret"]:
        raise _err(409, "totp_not_enabled", "TOTP is not enabled on this account")

    username = acct["username"]
    # 6 digits -> TOTP; anything else -> recovery key. Kept distinct from
    # normalize_recovery_input: that alphabet deliberately excludes 0/1/I/L,
    # which would corrupt TOTP codes containing those digits.
    raw = code.strip().replace(" ", "")
    if len(raw) == 6 and raw.isdigit():
        normalized = raw
    else:
        normalized = normalize_recovery_input(raw)

    async def _second_factor_fail(detail: str, message: str):
        await record_auth_event("login_totp", False, ip, f"{payload.get('sub', '')[:32]} {detail}")
        audit.log("auth.login_failed", payload.get("sub", "?"), f"totp step: {detail}")
        raise _err(401, "invalid_code", message)

    if len(normalized) == 6 and normalized.isdigit():
        secret = totp_secret_decrypt(acct["totp_secret"])
        step = totp_verify_at(secret, normalized, acct["totp_last_step"])
        if step is None:
            await _second_factor_fail("bad code", "wrong or replayed authenticator code")
        await execute(
            "UPDATE operator_account SET totp_last_step = $1, updated_at = NOW() WHERE id = 1",
            step,
        )
        await record_auth_event("login_totp", True, ip, username)
        audit.log("auth.login", username, "totp")
        token = create_token(username)
        return {"ok": True, "token": token, "username": username}

    # Not a 6-digit code: try it as a one-time recovery key. The atomic
    # UPDATE..WHERE used_at IS NULL both authenticates and consumes the
    # key, so concurrent attempts cannot spend it twice.
    row = await fetchrow(
        """
        UPDATE recovery_codes SET used_at = NOW()
        WHERE code_hash = $1 AND used_at IS NULL
        RETURNING code_hash
        """,
        hash_recovery_code(normalized),
    )
    if row is None:
        await _second_factor_fail("bad recovery key", "wrong or already-used recovery key")
    remaining = await fetchval("SELECT COUNT(*) FROM recovery_codes WHERE used_at IS NULL") or 0
    await record_auth_event("login_recovery", True, ip, f"{username} ({remaining} left)")
    audit.log("auth.login", username, f"recovery key ({remaining} left)")
    token = create_token(username)
    return {"ok": True, "token": token, "username": username, "recovery_remaining": remaining}


# --- passkey login (public) ---------------------------------------------


@router.post("/login/passkey/assertion/options")
async def passkey_assertion_options(request: Request):
    acct = await get_account()
    if acct is None:
        raise _err(409, "setup_required", "no operator account")
    from ..database import fetch

    creds = await fetch("SELECT credential_id, transports FROM passkey_credentials")
    if not creds:
        raise _err(409, "no_passkey", "no passkey is registered")
    pk.set_allowed_origins(_allowed_origins_for(request))
    challenge = pk.new_challenge("assert")
    return {
        "challenge": challenge,
        "rpId": _rp_id(request),
        "allowCredentials": [{"type": "public-key", "id": r["credential_id"]} for r in creds],
        "userVerification": "preferred",
        "timeout": pk.CHALLENGE_TTL_SEC * 1000,
    }


@router.post("/login/passkey/verify")
async def passkey_verify(request: Request):
    body = await _json(request)
    ip = _client_ip(request)
    if await is_locked(ip):
        raise _err(429, "locked", "too many failed attempts")

    required = ("id", "response")
    if any(k not in body for k in required):
        raise _invalid("expected {id, response}")
    resp = body.get("response") or {}
    try:
        expected = pk.consume_challenge("assert", str(body.get("challenge") or ""))
    except pk.PasskeyError as exc:
        raise _err(401, exc.code, exc.message)

    from ..database import execute, fetchrow

    row = await fetchrow(
        "SELECT * FROM passkey_credentials WHERE credential_id = $1", str(body["id"])
    )
    if row is None:
        await record_auth_event("login_passkey", False, ip, "unknown credential")
        raise _err(401, "unknown_credential", "this passkey is not registered")

    try:
        new_count = pk.verify_assertion(
            credential_id_b64=str(body["id"]),
            client_data_b64=str(resp.get("clientDataJSON") or ""),
            authdata_b64=str(resp.get("authenticatorData") or ""),
            signature_b64=str(resp.get("signature") or ""),
            expected_challenge=expected,
            expected_rp_id=_rp_id(request),
            stored_public_key_hex=row["public_key"],
            stored_sign_count=int(row["sign_count"]),
        )
    except pk.PasskeyError as exc:
        await record_auth_event("login_passkey", False, ip, exc.code)
        audit.log("auth.login_failed", row["name"], f"passkey: {exc.code}")
        raise _err(401, exc.code, exc.message)

    await execute(
        "UPDATE passkey_credentials SET sign_count = $1, last_used_at = NOW() WHERE credential_id = $2",
        new_count,
        row["credential_id"],
    )
    acct = await get_account()
    username = acct["username"] if acct else "operator"
    await record_auth_event("login_passkey", True, ip, username)
    audit.log("auth.login", username, f"passkey {row['name']}")
    token = create_token(username)
    return {"ok": True, "token": token, "username": username}


# --- management (session required) ----------------------------------------


@router.post("/password")
async def change_password(request: Request, user: dict = Depends(require_auth)):
    body = await _json(request)
    current = body.get("current")
    nxt = body.get("next")
    if not isinstance(current, str) or not isinstance(nxt, str):
        raise _invalid("current and next must be strings")
    if len(nxt) < 8:
        raise _invalid("new password must be at least 8 chars")
    acct = await get_account()
    if acct is None or acct["password_hash"] is None:
        raise _err(409, "no_password", "this account has no password set")
    if not verify_password(acct["password_hash"], current):
        raise _err(401, "invalid_credentials", "current password is wrong")
    from ..database import execute

    await execute(
        "UPDATE operator_account SET password_hash = $1, updated_at = NOW() WHERE id = 1",
        hash_password(nxt),
    )
    audit.log("auth.password_changed", user.get("sub", "?"), "password rotated")
    return {"ok": True}


@router.post("/totp/enable")
async def totp_enable(user: dict = Depends(require_auth)):
    """Generate (do NOT store) a secret + provisioning URI. The secret
    is only persisted by /totp/confirm after a successful code."""
    import pyotp

    acct = await get_account()
    if acct is None:
        raise _err(409, "setup_required", "no operator account")
    if acct["totp_enabled"]:
        raise _err(409, "totp_enabled", "TOTP is already enabled")
    secret = pyotp.random_base32()
    return {
        "secret": secret,
        "provisioning_uri": totp_provisioning_uri(secret, acct["username"]),
    }


@router.post("/totp/confirm")
async def totp_confirm(request: Request, user: dict = Depends(require_auth)):
    body = await _json(request)
    secret = body.get("secret")
    code = body.get("code")
    if not isinstance(secret, str) or not isinstance(code, str):
        raise _invalid("secret and code must be strings")
    if totp_verify_at(secret, code.strip(), None) is None:
        raise _err(401, "invalid_code", "wrong authenticator code")

    from ..database import pool

    codes = generate_recovery_codes()
    async with pool().acquire() as conn, conn.transaction():
        await conn.execute(
            """
                UPDATE operator_account
                SET totp_secret = $1, totp_enabled = TRUE, totp_last_step = NULL,
                    updated_at = NOW()
                WHERE id = 1
                """,
            totp_secret_encrypt(secret),
        )
        await conn.execute("DELETE FROM recovery_codes")
        for c in codes:
            await conn.execute("INSERT INTO recovery_codes (code_hash) VALUES ($1)", c["hash"])
    audit.log("auth.totp_enabled", user.get("sub", "?"), "TOTP confirmed; recovery keys minted")
    return {"ok": True, "codes": [c["code"] for c in codes]}


@router.post("/totp/qr")
async def totp_qr(request: Request, user: dict = Depends(require_auth)):
    """Reveal the stored secret for re-scan (new phone). Password-gated:
    the secret alone drains the second factor."""
    body = await _json(request)
    password = body.get("password")
    if not isinstance(password, str):
        raise _invalid("password must be a string")
    acct = await get_account()
    if acct is None or not acct["totp_enabled"] or not acct["totp_secret"]:
        raise _err(409, "totp_not_enabled", "TOTP is not enabled")
    if acct["password_hash"] is not None and not verify_password(acct["password_hash"], password):
        await record_auth_event("totp_qr", False, _client_ip(request), user.get("sub", "?"))
        raise _err(401, "invalid_credentials", "wrong password")
    secret = totp_secret_decrypt(acct["totp_secret"])
    return {"secret": secret, "provisioning_uri": totp_provisioning_uri(secret, acct["username"])}


@router.post("/totp/disable")
async def totp_disable(request: Request, user: dict = Depends(require_auth)):
    body = await _json(request)
    password = body.get("password")
    if not isinstance(password, str):
        raise _invalid("password must be a string")
    acct = await get_account()
    if acct is None or not acct["totp_enabled"]:
        raise _err(409, "totp_not_enabled", "TOTP is not enabled")
    if acct["password_hash"] is not None and not verify_password(acct["password_hash"], password):
        await record_auth_event("totp_disable", False, _client_ip(request), user.get("sub", "?"))
        raise _err(401, "invalid_credentials", "wrong password")
    from ..database import execute

    await execute(
        """
        UPDATE operator_account
        SET totp_enabled = FALSE, totp_secret = NULL, totp_last_step = NULL, updated_at = NOW()
        WHERE id = 1
        """
    )
    # Without TOTP there is nothing to fall back from — the keys die with it.
    await execute("DELETE FROM recovery_codes")
    audit.log("auth.totp_disabled", user.get("sub", "?"), "TOTP disabled; recovery keys wiped")
    return {"ok": True}


@router.get("/recovery")
async def recovery_status(user: dict = Depends(require_auth)):
    from ..database import fetchrow

    row = await fetchrow(
        "SELECT COUNT(*) FILTER (WHERE used_at IS NULL) AS remaining, COUNT(*) AS total FROM recovery_codes"
    )
    remaining = int(row["remaining"] or 0) if row else 0
    total = int(row["total"] or 0) if row else 0
    return {"total": total or RECOVERY_COUNT, "remaining": remaining}


@router.post("/recovery/regenerate")
async def recovery_regenerate(request: Request, user: dict = Depends(require_auth)):
    """Replace the whole set. Password-gated: regeneration invalidates
    every saved key, which is exactly what an attacker wants."""
    body = await _json(request)
    password = body.get("password")
    if not isinstance(password, str):
        raise _invalid("password must be a string")
    acct = await get_account()
    if acct is None or not acct["totp_enabled"]:
        raise _err(409, "totp_not_enabled", "enable two-factor first — recovery keys backfill it")
    if acct["password_hash"] is not None and not verify_password(acct["password_hash"], password):
        await record_auth_event(
            "recovery_regenerate", False, _client_ip(request), user.get("sub", "?")
        )
        raise _err(401, "invalid_credentials", "wrong password")

    from ..database import pool

    codes = generate_recovery_codes()
    async with pool().acquire() as conn, conn.transaction():
        await conn.execute("DELETE FROM recovery_codes")
        for c in codes:
            await conn.execute("INSERT INTO recovery_codes (code_hash) VALUES ($1)", c["hash"])
    audit.log("auth.recovery_regenerated", user.get("sub", "?"), f"{RECOVERY_COUNT} new keys")
    return {"ok": True, "codes": [c["code"] for c in codes]}


@router.post("/passkey/register/options")
async def passkey_register_options(request: Request, user: dict = Depends(require_auth)):
    acct = await get_account()
    if acct is None:
        raise _err(409, "setup_required", "no operator account")
    pk.set_allowed_origins(_allowed_origins_for(request))
    challenge = pk.new_challenge("create")
    return {
        "challenge": challenge,
        "rp": {"name": "Janus Dashboard", "id": _rp_id(request)},
        "user": {
            "id": pk.b64url_encode(b"janus-operator"),
            "name": acct["username"],
            "displayName": acct["username"],
        },
        "pubKeyCredParams": [
            {"type": "public-key", "alg": -7},
            {"type": "public-key", "alg": -257},
        ],
        "authenticatorSelection": {
            "residentKey": "preferred",
            "userVerification": "preferred",
        },
        "timeout": pk.CHALLENGE_TTL_SEC * 1000,
        "attestation": "none",
    }


@router.post("/passkey/register/verify")
async def passkey_register_verify(request: Request, user: dict = Depends(require_auth)):
    body = await _json(request)
    name = body.get("name")
    challenge = body.get("challenge")
    resp = body.get("response")
    if not isinstance(name, str) or not (1 <= len(name.strip()) <= 64):
        raise _invalid("name must be a string of 1..64 chars")
    if not isinstance(challenge, str) or not isinstance(resp, dict):
        raise _invalid("expected {name, challenge, response}")
    try:
        expected = pk.consume_challenge("create", challenge)
        cred_id, pub_hex = pk.verify_registration(
            client_data_b64=str(resp.get("clientDataJSON") or ""),
            attestation_b64=str(resp.get("attestationObject") or ""),
            expected_challenge=expected,
            expected_rp_id=_rp_id(request),
        )
    except pk.PasskeyError as exc:
        audit.log("auth.passkey_register_failed", user.get("sub", "?"), exc.code)
        raise _err(400, exc.code, exc.message)

    transports = body.get("transports")
    from ..database import execute

    await execute(
        """
        INSERT INTO passkey_credentials (credential_id, public_key, transports, name)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (credential_id) DO UPDATE
          SET public_key = EXCLUDED.public_key, name = EXCLUDED.name
        """,
        cred_id,
        pub_hex,
        ",".join(transports) if isinstance(transports, list) else None,
        name.strip(),
    )
    audit.log("auth.passkey_registered", user.get("sub", "?"), name.strip())
    return {"ok": True, "credential_id": cred_id}


@router.get("/passkeys")
async def list_passkeys(user: dict = Depends(require_auth)):
    from ..database import fetch

    rows = await fetch(
        """
        SELECT credential_id, name, transports, created_at, last_used_at, sign_count
        FROM passkey_credentials ORDER BY created_at DESC
        """
    )
    return {
        "passkeys": [
            {
                "credential_id": r["credential_id"],
                "name": r["name"],
                "transports": r["transports"].split(",") if r["transports"] else [],
                "created_at": r["created_at"],
                "last_used_at": r["last_used_at"],
                "sign_count": r["sign_count"],
            }
            for r in rows
        ]
    }


@router.delete("/passkeys/{credential_id}")
async def delete_passkey(credential_id: str, user: dict = Depends(require_auth)):
    from ..database import execute

    n = await execute("DELETE FROM passkey_credentials WHERE credential_id = $1", credential_id)
    audit.log("auth.passkey_deleted", user.get("sub", "?"), credential_id[:24])
    return {"ok": True, "deleted": n}


# --- legacy session contract ---------------------------------------------


@router.post("/logout")
async def logout():
    """JWT is stateless; the client discards its token."""
    return {"ok": True}


@router.get("/session")
async def session(user: dict = Depends(require_auth)):
    return {"valid": True, "expires_at": user.get("exp"), "username": user.get("sub")}
