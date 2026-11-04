"""Janus MCP server — a Streamable HTTP surface over the dashboard's own API.

The dashboard is the management plane; this package exposes it to AI agents
over MCP (mounted at /mcp by app.main). Every tool lands on an existing,
audited REST endpoint — this layer adds discovery and gating, never a second
write path.

Gating (both checks run before any MCP protocol bytes are served):
  1. the dash.mcp settings knob — default OFF, dashboard-only (gateways
     never consume it), read per request, and fail-closed: off, missing,
     or DB-unreachable all read as off and answer 404 in the house error
     shape, exactly as if no MCP server existed;
  2. the operator bearer token — verified with auth.verify_token; partial
     (TOTP challenge) scopes are rejected like everywhere else.
"""

import json
import logging

import jwt
from fastapi.responses import JSONResponse
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

from .. import database
from . import api, tools
from ..auth import verify_token

logger = logging.getLogger("janus.dashboard.mcp")

MCP_KNOB_KEY = "dash.mcp"

# Transport options are CONSTRUCTOR parameters in mcp 1.x (verified against
# 1.30.0; streamable_http_app() takes none). stateless_http: no session
# affinity behind the reverse proxy; json_response: no SSE on the POST
# response path. The SDK's DNS-rebinding guard is disabled because it 421s
# behind the reverse proxy — the bearer gate below is the boundary.
mcp = FastMCP(
    "janus-dashboard",
    stateless_http=True,
    json_response=True,
    streamable_http_path="/",
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)

tools.register_all(mcp)


async def mcp_enabled() -> bool:
    """The dash.mcp knob. Fails closed: any read or parse problem is off."""
    try:
        row = await database.fetchrow("SELECT value FROM settings WHERE key = $1", MCP_KNOB_KEY)
    except Exception:
        # Fail-closed, but never silent: an operator seeing /mcp 404 must be
        # able to tell knob-off from a broken DB read in the logs.
        logger.warning("dash.mcp knob read failed; treating MCP as disabled", exc_info=True)
        return False
    if not row:
        return False
    try:
        # Match the house readers (_parse_stored_json et al.): decode only
        # str/bytes — a registered JSONB codec hands back a dict directly.
        raw = row["value"]
        value = json.loads(raw) if isinstance(raw, (str, bytes)) else raw
    except (TypeError, ValueError):
        logger.warning("dash.mcp value is not valid JSON; treating MCP as disabled")
        return False
    return isinstance(value, dict) and value.get("enabled") is True


def _error(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": {"code": code, "message": message}})


def auth_failure(authorization: str | None) -> JSONResponse | None:
    """Bearer check shared by the mount and the bare-/mcp route. Mirrors
    auth.require_auth's outcomes without its FastAPI dependency plumbing."""
    # Case-insensitive scheme, like FastAPI's HTTPBearer on the REST side —
    # the same header must not pass /api/* and fail /mcp/.
    if not authorization or authorization[:7].lower() != "bearer ":
        return _error(401, "unauthorized", "missing bearer token")
    try:
        payload = verify_token(authorization[7:])
    except jwt.ExpiredSignatureError:
        return _error(401, "token_expired", "session expired")
    except jwt.InvalidTokenError:
        return _error(401, "unauthorized", "invalid token")
    if payload.get("scope") == "partial":
        return _error(401, "unauthorized", "challenge token is not a session")
    return None


async def gate() -> JSONResponse | None:
    """Knob half of the gate (the auth half needs the header). Returns a
    response to answer with, or None when the request may pass."""
    if not await mcp_enabled():
        return _error(404, "not_found", "no such endpoint: /mcp")
    return None


class _GatedMcpApp:
    """ASGI wrapper: knob (404, fail closed) then bearer (401) in front of
    the SDK's Streamable HTTP app."""

    def __init__(self, app):
        self._app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self._app(scope, receive, send)
            return
        denied = await gate()
        if denied is None:
            header = None
            for key, value in scope.get("headers") or []:
                if key == b"authorization":
                    header = value.decode("latin-1")
                    break
            denied = auth_failure(header)
        if denied is not None:
            await denied(scope, receive, send)
            return
        await self._app(scope, receive, send)


def bind(app) -> None:
    """Give the REST bridge the FastAPI app (call from app.main after the
    app object exists; app.mcp never imports app.main — that would be a
    circular import)."""
    api.bind(app)


def gated_app():
    """The mountable app. Calling streamable_http_app() also creates the
    session manager, which app.main's lifespan must run."""
    return _GatedMcpApp(mcp.streamable_http_app())
