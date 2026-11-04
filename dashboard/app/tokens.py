"""Management-plane API tokens (jm-…).

Verification for the MCP gate (and, later, third-party API access): a
hash lookup against the dashboard-owned api_tokens table. Revocation is
immediate — row state is read on every request, nothing is cached. The
verified identity is published on a ContextVar so the MCP bridge can
attribute tool calls without a second DB read.
"""

import asyncio
import contextvars
import logging
import time

from . import audit, database
from .crypto import hash_api_token

logger = logging.getLogger("janus.dashboard.tokens")

# Bound candidate BEFORE hashing: the gate sees attacker-controlled
# strings, and an unbounded HMAC input is a cheap CPU amplifier.
_MAX_TOKEN_LEN = 128

# Set by the MCP gate (auth_failure's jm- success branch) for the life of
# the request; read by the bridge to mint the attributed swap JWT.
current_identity: contextvars.ContextVar[dict | None] = contextvars.ContextVar(
    "janus_api_token_identity", default=None
)

# Use-recording throttle: one audit row AND one last_used_at write per
# token per window — a per-request UPDATE on the auth hot path would
# serialize every tool call on the same row lock for a display-only value.
_USE_AUDIT_WINDOW_SEC = 300.0
_last_use_audit: dict[int, float] = {}


def _record_use(token_id: int, label: str, prefix: str) -> bool:
    """Audit a gate pass (and refresh last_used_at) at most once per 5
    minutes per token, so neither the audit trail nor the hot path is
    spammed. Returns True when this call opened a new window."""
    now = time.monotonic()
    # Explicit missing-check: a 0.0 sentinel breaks on a freshly booted
    # host, where monotonic() legitimately starts below the window.
    last = _last_use_audit.get(token_id)
    if last is not None and now - last < _USE_AUDIT_WINDOW_SEC:
        return False
    # Prune dead entries (deleted tokens' ids) so the map cannot grow
    # unboundedly — the register_bridge_jti pattern.
    for k in [k for k, ts in _last_use_audit.items() if now - ts > _USE_AUDIT_WINDOW_SEC]:
        _last_use_audit.pop(k, None)
    _last_use_audit[token_id] = now
    # sub names the SAME principal the bridge mints (api-token:<id>, ids
    # are unique — labels are not, and free-form text must not masquerade
    # as other key=value fields; hence the repr).
    audit.log(
        "api_token.use",
        f"api_token:{token_id}",
        f"sub=api-token:{token_id} label={label!r} {prefix}…",
    )
    # Fire-and-forget best-effort (the audit.py precedent, strong refs
    # included): a DB hiccup here must never change an auth outcome.
    task = asyncio.ensure_future(
        database.execute("UPDATE api_tokens SET last_used_at = NOW() WHERE id = $1", token_id)
    )
    _use_tasks.add(task)
    task.add_done_callback(_finish_use)
    return True


async def verify_api_token(raw: str | None) -> dict | None:
    """Validate a jm- bearer against api_tokens. Returns the identity dict
    on success; None for anything else. Any DB failure reads as None
    (warn-logged, never a 500) — fail closed like the knob reader."""
    if not isinstance(raw, str) or not raw.startswith("jm-") or len(raw) > _MAX_TOKEN_LEN:
        return None
    try:
        prefix, digest = hash_api_token(raw)
        row = await database.fetchrow(
            "SELECT id, label, scope, enabled, expires_at FROM api_tokens " "WHERE token_hash = $1",
            digest,
        )
    except Exception:
        logger.warning("api_tokens verification read failed; rejecting", exc_info=True)
        return None
    if not row or row["enabled"] != 1:
        return None
    if row["expires_at"] is not None and row["expires_at"].timestamp() <= time.time():
        return None
    # 'full' is the only scope today; a restricted tier (a later feature,
    # a restore, a hand-inserted row) must NOT silently run every MCP
    # tool until its semantics are defined and enforced.
    if row["scope"] != "full":
        return None
    identity = {"token_id": row["id"], "label": row["label"], "scope": row["scope"]}
    _record_use(row["id"], row["label"], prefix)
    return identity


_use_tasks: set[asyncio.Task] = set()


def _finish_use(task: asyncio.Task) -> None:
    _use_tasks.discard(task)
    if task.cancelled():
        return
    exc = task.exception()
    if exc is not None:
        logger.debug("api_tokens last_used_at update failed: %s", exc)
