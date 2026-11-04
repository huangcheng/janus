"""Internal REST bridge for MCP tools.

Every tool call rides the app's own audited API surface via an in-process
ASGI transport — the MCP layer adds discovery and gating, never a second
write path. The FastAPI app reference is injected at mount time (main.py
imports this package, so importing app.main from here would be circular).
"""

from typing import Any

import httpx

_app: Any = None
_client: httpx.AsyncClient | None = None


def bind(app: Any) -> None:
    """Capture the FastAPI app. The client is built lazily so create/close
    stay symmetric across repeated lifespan cycles (in-process restarts,
    test contexts) — close() releases it, the next call rebuilds it."""
    global _app
    _app = app


def client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        if _app is None:
            raise RuntimeError("mcp.api.bind(app) was never called")
        _client = httpx.AsyncClient(
            # raise_app_exceptions=False: Starlette's ServerErrorMiddleware
            # re-raises after emitting the 500 envelope — re-raising here
            # would surface raw exception text to the tool instead of the
            # house {error:{code,message}} body with its correlation id.
            transport=httpx.ASGITransport(app=_app, raise_app_exceptions=False),
            base_url="http://janus-internal",
            # The ASGI transport does not run the app's lifespan; the app is
            # already running under uvicorn when tools execute. 120s: the
            # fleet tools loop rows with a 30s per-row timeout — two dead
            # rows already eat 60s, and a degraded fleet is exactly when
            # they get called.
            timeout=120.0,
        )
    return _client


async def close() -> None:
    """Release the shared client; the next call rebuilds it from the bound
    app. Called from the app lifespan shutdown."""
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None


async def call_api(
    method: str,
    path: str,
    token: str,
    params: dict[str, Any] | None = None,
    json_body: dict[str, Any] | None = None,
) -> tuple[int, Any]:
    """Call the dashboard's own REST API. Returns (status, parsed-body):
    JSON when the response parses, the raw text otherwise (some endpoints,
    e.g. node metrics, answer text/plain). Never raises for HTTP errors or
    transport timeouts — the caller maps the status/body itself, so the
    system's own words (or a synthesized house-shaped error) ride through
    to the agent."""
    try:
        resp = await client().request(
            method,
            path,
            params=params,
            json=json_body,
            headers={"authorization": f"Bearer {token}"},
        )
    except httpx.TimeoutException as e:
        return 504, {
            "error": {"code": "upstream_timeout", "message": f"{type(e).__name__}: {method} {path}"}
        }
    except httpx.HTTPError as e:
        return 502, {
            "error": {
                "code": "internal_transport",
                "message": f"{type(e).__name__}: {method} {path}",
            }
        }
    try:
        return resp.status_code, resp.json()
    except ValueError:
        return resp.status_code, resp.text
