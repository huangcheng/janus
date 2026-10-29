"""Catalog reload + overview endpoints."""

from fastapi import APIRouter, Depends

from .. import audit, database
from ..auth import require_auth
from ..nodes import health_data

router = APIRouter()


@router.post("/reload")
async def reload_catalog(user: dict = Depends(require_auth)):
    """POST /api/catalog/reload — bump generation + NOTIFY all gateways."""
    gen = await database.bump_generation()
    audit.log("catalog.reload", None, f"generation={gen}")
    return {"ok": True, "generation": gen}


async def overview_payload() -> dict:
    gen = await database.current_generation()
    providers = await database.fetch(
        "SELECT p.id, p.name, p.protocol, p.enabled, "
        "(SELECT COUNT(*) FROM provider_keys pk WHERE pk.provider_id = p.id) AS keys "
        "FROM providers p ORDER BY p.id"
    )
    counts = {
        "providers": await database.fetchval("SELECT COUNT(*) FROM providers") or 0,
        "listings": await database.fetchval("SELECT COUNT(*) FROM provider_models") or 0,
        "models": await database.fetchval("SELECT COUNT(*) FROM models") or 0,
        "routes": await database.fetchval("SELECT COUNT(*) FROM model_routes") or 0,
        "agent_keys": await database.fetchval("SELECT COUNT(*) FROM api_keys") or 0,
        "gateway_nodes": await database.fetchval(
            "SELECT COUNT(*) FROM gateway_nodes WHERE enabled = true"
        )
        or 0,
    }
    node_rows = await database.fetch("SELECT id FROM gateway_nodes WHERE enabled = true")
    health = health_data()
    if not node_rows:
        ready = False
    else:
        ready = True
        for n in node_rows:
            snap = health.get(n["id"]) or {}
            if snap.get("status") != "healthy" or snap.get("ready") is not True:
                ready = False
                break
    return {
        "generation": gen,
        # The management plane always talks to the shared Postgres.
        "backend": "postgres",
        "ready": ready,
        "counts": counts,
        "providers": [
            {
                "id": p["id"],
                "name": p["name"],
                "protocol": p["protocol"],
                "keys": p["keys"],
                "enabled": bool(p["enabled"]),
            }
            for p in providers
        ],
        "recent_audit": await audit.recent(5),
    }


@router.get("/overview")
async def overview(user: dict = Depends(require_auth)):
    """GET /api/catalog/overview — summary stats (alias: GET /api/overview)."""
    return await overview_payload()
