"""Cloudflare Turnstile Siteverify for dashboard login.

Canonical check: success === true, expected action, hostname allowlist.
Fail closed on network errors, non-2xx, or malformed responses.
Never call Siteverify from the browser — only from this module.
"""

from __future__ import annotations

import logging
from typing import Any

import httpx

from .config import config

logger = logging.getLogger("janus.dashboard.turnstile")

SITEVERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify"
EXPECTED_ACTION = "login"
_MAX_TOKEN_LEN = 2048


def token_looks_plausible(token: object) -> bool:
    """Reject empty / oversized / non-string tokens before hitting Cloudflare."""
    return isinstance(token, str) and 0 < len(token) <= _MAX_TOKEN_LEN


async def verify_login_token(token: str, remoteip: str | None = None) -> bool:
    """Siteverify a login Turnstile token. Returns True only on full pass.

    Caller must only invoke this when ``config.turnstile_secret`` is set.
    An empty hostname allowlist fails closed (misconfiguration).
    """
    secret = config.turnstile_secret
    hostnames = config.turnstile_hostnames
    if not secret or not hostnames:
        logger.warning("turnstile enabled but secret or TURNSTILE_HOSTNAMES unset")
        return False
    if not token_looks_plausible(token):
        return False

    data: dict[str, str] = {
        "secret": secret,
        "response": token,
    }
    if remoteip and remoteip != "unknown":
        data["remoteip"] = remoteip

    try:
        async with httpx.AsyncClient(timeout=10.0, trust_env=False) as client:
            resp = await client.post(SITEVERIFY_URL, data=data)
        if resp.status_code < 200 or resp.status_code >= 300:
            logger.warning("turnstile siteverify HTTP %s", resp.status_code)
            return False
        result: Any = resp.json()
    except Exception:
        logger.warning("turnstile siteverify failed", exc_info=True)
        return False

    if not isinstance(result, dict):
        return False
    if result.get("success") is not True:
        return False
    if result.get("action") != EXPECTED_ACTION:
        return False
    hostname = result.get("hostname")
    return isinstance(hostname, str) and hostname in hostnames
