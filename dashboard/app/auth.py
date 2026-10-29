"""Operator authentication: database-backed single account with
password + TOTP + passkey, JWT sessions, DB-persisted lockout.

Contract (SPA-facing):
  GET  /api/auth/status   {configured, has_password, has_totp, has_passkey}
  POST /api/auth/setup    {username, password} -> {token}          (once)
  POST /api/auth/login    {username, password} -> {token}
                          | 401 {code: "totp_required", challenge_token}
  POST /api/auth/login/totp {challenge_token, code} -> {token}
  (passkey flows live in app/passkey.py)

JWT claims: sub = username (was the fixed "dashboard"), jti retained
(the keys reveal limiter buckets on it). A challenge token issued for
the TOTP step carries scope="partial" — require_auth rejects it for
everything except /api/auth/login/totp.

Lockout is counted in the auth_events table (same IP, window from
JANUS_LOGIN_LOCKOUT_SEC, threshold JANUS_LOGIN_MAX_FAILS), so it
survives restarts and is auditable. The old env-var shared password
(JANUS_DASHBOARD_PASSWORD) is no longer a login path — an account
must exist in operator_account (bootstrap via /api/auth/setup).
"""

import hmac
import logging
import secrets
import time

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from fastapi import Depends, HTTPException
from fastapi.security import HTTPBearer

from . import crypto
from .config import config

logger = logging.getLogger("janus.dashboard.auth")

_bearer = HTTPBearer(auto_error=False)

# argon2id, library defaults (t=3, m=64 MiB, p=4) — OWASP-aligned.
_password_hasher = PasswordHasher()

CHALLENGE_TTL_SEC = 300


def _client_ip(request) -> str:
    """Direct peer, or first non-trusted hop from X-Forwarded-For when
    JANUS_TRUSTED_PROXIES names them. Kept as the shared helper the
    keys reveal limiter and the auth router both use."""
    peer = request.client.host if request.client else "unknown"
    if not config.trusted_proxy_list:
        return peer
    forwarded = request.headers.get("x-forwarded-for", "")
    if not forwarded:
        return peer
    hops = [h.strip() for h in forwarded.split(",") if h.strip()]
    for hop in reversed(hops):
        if hop not in config.trusted_proxy_list:
            return hop
    return peer


async def record_auth_event(kind: str, success: bool, ip: str | None, detail: str = "") -> None:
    """Insert into auth_events (best-effort: auth must never 500 on the
    audit write; a failed insert only logs)."""
    from .database import execute

    try:
        await execute(
            "INSERT INTO auth_events (kind, success, ip, detail) VALUES ($1, $2, $3, $4)",
            kind,
            success,
            ip,
            detail,
        )
    except Exception:
        logger.warning("auth_events insert failed", exc_info=True)


async def is_locked(ip: str) -> bool:
    """True when this IP has >= max_login_fails failed attempts inside
    the lockout window (password/TOTP/passkey share one bucket)."""
    from .database import fetchval

    try:
        n = await fetchval(
            """
            SELECT COUNT(*) FROM auth_events
            WHERE success = FALSE
              AND ip = $1
              AND ts >= NOW() - make_interval(secs => $2)
            """,
            ip,
            config.lockout_sec,
        )
        return n is not None and n >= config.max_login_fails
    except Exception:
        return False


async def get_account() -> dict | None:
    """The single operator row, or None before /setup."""
    from .database import fetchrow

    return await fetchrow("SELECT * FROM operator_account WHERE id = 1")


def hash_password(password: str) -> str:
    return _password_hasher.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    try:
        return _password_hasher.verify(password_hash, password)
    except VerifyMismatchError:
        return False
    except Exception:  # malformed PHC string — treat as wrong password
        logger.warning("argon2 verify error on stored hash", exc_info=True)
        return False


# --- TOTP ---


def totp_provisioning_uri(secret: str, username: str) -> str:
    import pyotp

    return pyotp.TOTP(secret).provisioning_uri(name=username, issuer_name="Janus Dashboard")


def totp_verify_at(secret: str, code: str, last_step: int | None) -> int | None:
    """Verify a 6-digit TOTP code; returns the accepted time step
    (for replay protection), or None on mismatch/replay.

    Adjacent steps are accepted for clock drift; a code from a step
    already consumed (<= last_step) is rejected — the same code can
    never buy two logins. NOTE: pyotp's TOTP.at() takes a UNIX
    TIMESTAMP (seconds), not a step index."""
    import pyotp

    totp = pyotp.TOTP(secret)
    now = time.time()
    for offset in (0, -1, 1):
        step = int(now // 30) + offset
        if last_step is not None and step <= last_step:
            continue
        if hmac.compare_digest(totp.at(now + offset * 30), code):
            return step
    return None


def totp_secret_decrypt(stored_hex: str) -> str:
    return crypto.decrypt(bytes.fromhex(stored_hex)).decode()


def totp_secret_encrypt(secret: str) -> str:
    return crypto.encrypt(secret.encode()).hex()


# --- Recovery codes (one-time TOTP fallback) ---

# Crockford-ish alphabet: no 0/O/1/I/L, so codes survive being read aloud
# over the phone or re-typed from a printout.
RECOVERY_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
RECOVERY_COUNT = 10
RECOVERY_RAW_LEN = 16  # displayed as 4 groups of 4


def generate_recovery_codes() -> list[dict]:
    """RECOVERY_COUNT fresh codes: [{code: "XXXX-...", hash: "<sha256>"}].
    Only the hash is ever persisted; the display form exists for the
    one-time reveal in the confirm/regenerate responses."""
    import secrets

    from .crypto import hash_recovery_code

    codes = []
    for _ in range(RECOVERY_COUNT):
        raw = "".join(secrets.choice(RECOVERY_ALPHABET) for _ in range(RECOVERY_RAW_LEN))
        display = "-".join(raw[i : i + 4] for i in range(0, RECOVERY_RAW_LEN, 4))
        codes.append({"code": display, "hash": hash_recovery_code(raw)})
    return codes


def normalize_recovery_input(raw: str) -> str:
    """Uppercase and drop everything outside the alphabet — dashes, spaces,
    and typos like lowercase letters; hashing operates on the bare value."""
    return "".join(ch for ch in raw.upper() if ch in RECOVERY_ALPHABET)


# --- JWT ---


def create_token(sub: str, scope: str | None = None, ttl: int | None = None) -> str:
    """Create a JWT. Full sessions: sub=username, no scope. The TOTP
    challenge token: sub=username, scope=partial, 5-minute TTL."""
    if not config.jwt_secret:
        raise HTTPException(
            status_code=503,
            detail={"error": {"code": "misconfigured", "message": "JANUS_JWT_SECRET is not set"}},
        )
    now = int(time.time())
    payload = {
        "sub": sub,
        # Per-session id: the reveal rate limiter buckets on it, so one
        # session cannot exhaust another session's budget (L6).
        "jti": secrets.token_urlsafe(12),
        "iat": now,
        "exp": now + (ttl if ttl is not None else config.session_ttl_sec),
    }
    if scope is not None:
        payload["scope"] = scope
    return jwt.encode(payload, config.jwt_secret, algorithm="HS256")


def verify_token(token: str) -> dict:
    """Verify a JWT; raises jwt.InvalidTokenError on failure."""
    if not config.jwt_secret:
        raise jwt.InvalidTokenError("jwt secret unset")
    return jwt.decode(token, config.jwt_secret, algorithms=["HS256"])


async def require_auth(
    credentials: object = Depends(_bearer),
) -> dict:
    if credentials is None:
        raise HTTPException(
            status_code=401,
            detail={"error": {"code": "unauthorized", "message": "missing bearer token"}},
        )
    token = credentials.credentials
    try:
        payload = verify_token(token)
    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=401,
            detail={"error": {"code": "token_expired", "message": "session expired"}},
        )
    except jwt.InvalidTokenError:
        raise HTTPException(
            status_code=401,
            detail={"error": {"code": "unauthorized", "message": "invalid token"}},
        )
    if payload.get("scope") == "partial":
        # Challenge tokens are good for exactly one endpoint.
        raise HTTPException(
            status_code=401,
            detail={
                "error": {
                    "code": "unauthorized",
                    "message": "challenge token is not a session",
                }
            },
        )
    return payload
