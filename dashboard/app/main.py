"""Janus Dashboard — FastAPI application entry point."""

import json
import logging
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse

from . import (
    alerts,
    audit,
    auto_reorder,
    cascade,
    database,
    decisions_probe,
    entitlements,
    maintenance,
    nodes,
)
from .auth import require_auth
from .config import config
from .config_backup_export import dashboard_version
from .config_backup_schema import SchemaSelfCheckError, startup_schema_self_check
from .routers import (
    alerts as alerts_router,
)
from .routers import (
    auth,
    catalog,
    config_backup,
    failures,
    keys,
    models,
    provider_admin,
    providers,
    sync,
)
from .routers import (
    entitlements as entitlements_router,
)
from .routers import (
    logs as logs_router,
)
from .routers import (
    nodes as nodes_router,
)
from .routers import (
    ops_events as ops_events_router,
)
from .routers import (
    prices as prices_router,
)
from .routers import (
    settings as settings_router,
)
from .routers import (
    usage as usage_router,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("janus.dashboard")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup/shutdown lifecycle."""
    # Schema format assertion is annotation-only unless wired. A miss
    # would let export write documents restore cannot trust, so refuse
    # to boot (export_invalid) before any listener accepts traffic.
    try:
        startup_schema_self_check()
    except SchemaSelfCheckError as exc:
        logger.error(
            "config-backup schema self-check failed (%s); refusing to boot: %s",
            exc.code,
            exc,
        )
        raise
    logger.info(
        "config-backup exporter ready (dashboard_version=%s)",
        dashboard_version(),
    )
    if not config.is_configured:
        missing = [
            name
            for name, val in (
                ("JANUS_DB_PASSWORD", config.db_password),
                ("JANUS_DASHBOARD_PASSWORD", config.dashboard_password),
                ("JANUS_JWT_SECRET", config.jwt_secret),
                ("JANUS_SECRETS_KEY", config.secrets_key),
                ("JANUS_API_KEY_PEPPER", config.api_key_pepper),
            )
            if not val
        ]
        logger.warning(
            "dashboard not fully configured (missing %s); "
            "login will fail-closed, DB operations will error",
            ", ".join(missing) or "required env vars",
        )
    else:
        await database.init_pool()
        await nodes.start_monitor()
        await sync.start_sync_scheduler()
        await entitlements.start_background()
        await auto_reorder.start_background()
        await cascade.start_background()
        await alerts.start_sender()
        await maintenance.start_sweeper()
        if not config.stats_token:
            logger.warning(
                "JANUS_STATS_TOKEN unset; remote gateway /stats polls fail closed "
                "(loopback stats hosts still allowed)"
            )
        if config.alert_webhook_invalid:
            logger.warning(
                "JANUS_ALERT_WEBHOOK_URL is invalid (http(s) only, no userinfo) — "
                "treated as unset; alerting runs in record-only mode"
            )
        elif config.alert_webhook_configured:
            logger.info("alert webhook configured (host=%s)", config.alert_webhook_host)
        logger.info("dashboard started on %s:%s", config.host, config.port)
    if not config.trusted_proxy_list:
        # M7: behind the documented caddy deployment the direct peer is
        # the proxy for every operator, so the login lockout map has one
        # key — five wrong passwords lock out the whole team for
        # lockout_sec, repeatably.
        logger.warning(
            "JANUS_TRUSTED_PROXIES is unset; login lockout keys on the direct "
            "peer address. Behind a reverse proxy every operator shares one "
            "bucket, so five failed logins lock out everyone for %ss",
            config.lockout_sec,
        )
    yield
    await maintenance.stop_sweeper()
    await alerts.stop_sender()
    await cascade.stop_background()
    await auto_reorder.stop_background()
    await entitlements.stop_background()
    await sync.stop_sync_scheduler()
    await nodes.stop_monitor()
    await database.close_pool()
    logger.info("dashboard stopped")


app = FastAPI(
    title="Janus Dashboard",
    description="Management plane for Janus LLM gateway nodes",
    version="0.1.0",
    lifespan=lifespan,
)

# CORS for SPA dev server (vite proxy handles production)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000", "http://127.0.0.1:3000"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# --- Error shape: SPA expects {error: {code, message}} at the top level.
# FastAPI wraps HTTPException detail under "detail", so unwrap it here.


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    detail = exc.detail
    if isinstance(detail, dict) and "error" in detail:
        body = detail
    else:
        body = {"error": {"code": "error", "message": str(detail)}}
    # Preserve explicit response headers (e.g. the D34 reorder_busy
    # 409 carries Retry-After: 1).
    return JSONResponse(status_code=exc.status_code, content=body, headers=exc.headers)


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    return JSONResponse(
        status_code=422,
        content={"error": {"code": "invalid", "message": str(exc.errors()[:3])}},
    )


@app.exception_handler(json.JSONDecodeError)
async def bad_json_handler(request: Request, exc: json.JSONDecodeError):
    """A malformed/empty body is a client error, not a 500.

    `await request.json()` raises json.JSONDecodeError on an empty body, a
    truncated body, or `1,2,3`; without this it fell through to the catch-all
    and answered 500 (found by adversarial verification of PATCH
    /api/providers/{id}, which is one of several bare `request.json()` sites).
    """
    return JSONResponse(
        status_code=400,
        content={"error": {"code": "invalid_body", "message": "request body must be valid JSON"}},
    )


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    """Catch-all: keep the {error: {code, message}} contract on 500s.

    Starlette's default is a text/plain "Internal Server Error", which the
    SPA cannot parse as JSON. Log the traceback with a short correlation
    id server-side; the body carries only the id, never exception text.
    """
    correlation_id = uuid.uuid4().hex[:12]
    logger.error(
        "unhandled error [%s] %s %s",
        correlation_id,
        request.method,
        request.url.path,
        exc_info=exc,
    )
    return JSONResponse(
        status_code=500,
        content={
            "error": {
                "code": "internal",
                "message": f"internal error (ref: {correlation_id})",
            }
        },
    )


# API routes
app.include_router(auth.router, prefix="/api/auth", tags=["auth"])
app.include_router(providers.router, prefix="/api/providers", tags=["providers"])
# Decisions probe endpoints live under the same /api/providers prefix
# (POST/GET /{id}/decisions-probe); paths are literal-suffixed so they
# cannot shadow the providers router's int-typed {provider_id} routes.
app.include_router(decisions_probe.router, prefix="/api/providers", tags=["providers"])
app.include_router(provider_admin.keys_router, prefix="/api/provider-keys", tags=["providers"])
app.include_router(provider_admin.models_router, prefix="/api/provider-models", tags=["providers"])
app.include_router(models.router, prefix="/api/models", tags=["models"])
app.include_router(keys.router, prefix="/api/keys", tags=["keys"])
app.include_router(nodes_router.router, prefix="/api/nodes", tags=["nodes"])
app.include_router(sync.router, prefix="/api/sync", tags=["sync"])
app.include_router(catalog.router, prefix="/api/catalog", tags=["catalog"])
app.include_router(logs_router.router, prefix="/api/logs", tags=["logs"])
app.include_router(ops_events_router.router, prefix="/api/ops-events", tags=["logs"])
app.include_router(usage_router.router, prefix="/api/usage", tags=["usage"])
app.include_router(failures.router, prefix="/api/failures", tags=["failures"])
app.include_router(prices_router.router, prefix="/api/prices", tags=["prices"])
app.include_router(settings_router.router, prefix="/api/settings", tags=["settings"])
app.include_router(config_backup.router, prefix="/api/config", tags=["config"])
app.include_router(entitlements_router.router, prefix="/api/entitlements", tags=["entitlements"])
app.include_router(alerts_router.router, prefix="/api/alerts", tags=["alerts"])
app.include_router(maintenance.router, prefix="/api/maintenance", tags=["maintenance"])


@app.get("/api/health")
async def health():
    """Liveness probe."""
    return {"status": "ok", "service": "janus-dashboard"}


@app.get("/api/ready")
async def ready():
    """Readiness probe — DB connectivity check.

    503 on failure so a supervisor/LB can act; the body never carries the
    raw asyncpg text (host/port/user/schema names) to unauthenticated callers.
    """
    try:
        gen = await database.current_generation()
        return {"ready": True, "generation": gen}
    except Exception:
        logger.exception("readiness check failed")
        return JSONResponse(status_code=503, content={"ready": False})


# --- SPA-contract session routes (the SPA calls /api/session). ---


@app.get("/api/session")
async def session_check(user: dict = Depends(require_auth)):
    """GET /api/session — validate the current JWT."""
    return {"valid": True, "expires_at": user.get("exp")}


@app.delete("/api/session")
async def session_logout():
    """DELETE /api/session — JWT is stateless; the client discards the token."""
    audit.log("auth.logout")
    return {"ok": True}


@app.get("/api/audit")
async def audit_events(limit: int = 200, user: dict = Depends(require_auth)):
    """GET /api/audit?limit=200 — dashboard mutation trail, newest first."""
    return {"events": await audit.recent(limit)}


@app.get("/api/overview")
async def overview(user: dict = Depends(require_auth)):
    """GET /api/overview — alias of /api/catalog/overview (SPA contract)."""
    return await catalog.overview_payload()


# SPA catch-all: serve real files or index.html for client-side routing.
# Registered LAST so /api routes take precedence. Unknown /api/* paths
# MUST 404 as JSON — never fall through to index.html (the SPA would
# parse HTML as an empty JSON object and misreport success).
_spa_dir = Path(__file__).parent.parent / "spa" / "dist"
_spa_root = _spa_dir.resolve()
_index_html = _spa_dir / "index.html"

if _index_html.exists():

    @app.get("/{full_path:path}", include_in_schema=False)
    async def spa_catch_all(full_path: str):
        if full_path == "api" or full_path.startswith("api/"):
            return JSONResponse(
                status_code=404,
                content={
                    "error": {"code": "not_found", "message": f"no such endpoint: /{full_path}"}
                },
            )
        file_path = (_spa_dir / full_path).resolve()
        # Prevent path traversal: file must be under spa/dist. Compare path
        # components, not a bare string prefix (a sibling "dist-old" would
        # pass startswith).
        if file_path.is_file() and _spa_root in file_path.parents:
            # Hashed assets are immutable; everything else (rare) revalidates.
            return FileResponse(
                file_path,
                headers={
                    "Cache-Control": "public, max-age=31536000, immutable"
                    if full_path.startswith("assets/")
                    else "no-cache"
                },
            )
        # index.html must NEVER be cached heuristically — a stale shell
        # points at dead chunk hashes ("Failed to fetch dynamically
        # imported module") and keeps serving the old UI after deploys.
        return FileResponse(_index_html, headers={"Cache-Control": "no-cache"})
else:
    logger.warning("SPA not built (spa/dist missing); API-only mode")
