"""Model and route CRUD endpoints."""

import json
import logging

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Request

from .. import audit, cascade, database, entitlements
from ..auth import require_auth
from . import sync as sync_router

router = APIRouter()
logger = logging.getLogger("janus.dashboard.models")

NAME_MAX = 200
WEIGHT_MAX = 10**6
PRIORITY_MAX = 10**6


def _err(status: int, code: str, message: str) -> HTTPException:
    return HTTPException(status, detail={"error": {"code": code, "message": message}})


def _parse_name(body: dict) -> str:
    raw = body.get("name", "")
    if not isinstance(raw, str):
        raise _err(400, "invalid", "name must be a string")
    name = raw.strip()
    if not name:
        raise _err(400, "invalid", "name required")
    if len(name) > NAME_MAX:
        raise _err(400, "invalid", f"name must be at most {NAME_MAX} characters")
    return name


def _parse_weight(value) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not (1 <= value <= WEIGHT_MAX):
        raise _err(400, "invalid", f"weight must be an integer between 1 and {WEIGHT_MAX}")
    return value


def _parse_priority(value) -> int:
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or not (-PRIORITY_MAX <= value <= PRIORITY_MAX)
    ):
        raise _err(
            400,
            "invalid",
            f"priority must be an integer between -{PRIORITY_MAX} and {PRIORITY_MAX}",
        )
    return value


@router.get("")
async def list_models(user: dict = Depends(require_auth)):
    models = await database.fetch("SELECT id, name, enabled FROM models ORDER BY id")
    routes = await database.fetch(
        "SELECT mr.model_id, mr.provider_id, mr.upstream_model_id, mr.weight, "
        "mr.priority, mr.enabled, p.name AS provider_name "
        "FROM model_routes mr LEFT JOIN providers p ON p.id = mr.provider_id "
        "ORDER BY mr.model_id, mr.priority, mr.provider_id"
    )
    routes_by_model: dict[int, list[dict]] = {}
    for r in routes:
        rr = dict(r)
        rr["enabled"] = bool(rr["enabled"])
        routes_by_model.setdefault(rr["model_id"], []).append(rr)

    return {
        "models": [
            {
                "id": m["id"],
                "name": m["name"],
                "enabled": bool(m["enabled"]),
                "routes": routes_by_model.get(m["id"], []),
            }
            for m in models
        ]
    }


@router.post("", status_code=201)
async def create_model(request: Request, user: dict = Depends(require_auth)):
    body = await request.json()
    name = _parse_name(body)

    try:
        async with database.transaction() as tx:
            row = await tx.fetchrow(
                "INSERT INTO models (name, enabled) VALUES ($1, 1) RETURNING id",
                name,
            )
            gen = await database.bump_generation(tx)
    except Exception as e:
        if isinstance(e, asyncpg.UniqueViolationError):
            raise _err(409, "duplicate", "model name exists") from e
        logger.exception("model create failed for name=%r", name)
        raise _err(500, "db_error", "could not create model") from e
    audit.log("model.add", name)
    return {"id": row["id"], "name": name, "generation": gen}


@router.post("/sync")
async def models_sync(user: dict = Depends(require_auth)):
    """POST /api/models/sync — alias of /api/sync (SPA contract)."""
    return await sync_router.sync_now(user)


@router.delete("/{model_id}")
async def delete_model(model_id: int, user: dict = Depends(require_auth)):
    """DELETE /api/models/{id} — remove a public model + its routes.

    Name-based agent-key grants (`api_key_models.model_name`) are NOT
    stripped: the same name may still be an unbound provider listing.
    Operators edit key access separately. The SPA only offers delete on
    unbound models; bound ones must be unbound first.
    """
    model = await database.fetchrow("SELECT id, name FROM models WHERE id = $1", model_id)
    if not model:
        raise _err(404, "not_found", "model not found")

    async with database.transaction() as tx:
        locked = await tx.fetchrow("SELECT id, name FROM models WHERE id = $1 FOR UPDATE", model_id)
        if locked is None:
            raise _err(404, "not_found", "model not found")
        await tx.execute("DELETE FROM model_routes WHERE model_id = $1", model_id)
        # Cascade (spec 2026-10-22 §2): the name leaves every janus-auto tier
        # list. Journaled, so binding the name again can bring its tier
        # membership back at its original position.
        cascade_out = await cascade.model_retire(
            tx, model_id=model_id, model_name=locked["name"], mode="delete"
        )
        await tx.execute("DELETE FROM models WHERE id = $1", model_id)
        gen = await database.bump_generation(tx)

    cascade.nudge_if(cascade_out)  # deferred tier surgery (spec §5.3)
    audit.log("model.delete", model["name"], json.dumps(cascade_out))
    return {"ok": True, "generation": gen, "cascade": cascade_out}


@router.post("/{model_id}/disable")
async def disable_model(model_id: int, user: dict = Depends(require_auth)):
    async with database.transaction() as tx:
        row = await tx.fetchrow("SELECT id, name FROM models WHERE id = $1", model_id)
        if row is None:
            raise _err(404, "not_found", "model not found")
        await tx.execute("UPDATE models SET enabled = 0 WHERE id = $1", model_id)
        # Cascade: a disabled model keeps its bindings but must not stay in a
        # janus-auto tier list (the gateway would keep selecting the name).
        cascade_out = await cascade.model_retire(
            tx, model_id=model_id, model_name=row["name"], mode="disable"
        )
        gen = await database.bump_generation(tx)
    cascade.nudge_if(cascade_out)  # deferred tier surgery (spec §5.3)
    audit.log("model.disable", f"model:{model_id}", json.dumps(cascade_out))
    return {"ok": True, "generation": gen, "cascade": cascade_out}


@router.post("/{model_id}/enable")
async def enable_model(model_id: int, user: dict = Depends(require_auth)):
    async with database.transaction() as tx:
        result = await tx.execute("UPDATE models SET enabled = 1 WHERE id = $1", model_id)
        if result == "UPDATE 0":
            raise _err(404, "not_found", "model not found")
        # D2: enabling a model the cascade retired puts it back into the tier
        # list it was pruned from — but only if it is bound again (a tier
        # member without an enabled route would just be skipped at read time).
        revive_out = await cascade.revive_for_route(tx, model_id=model_id)
        gen = await database.bump_generation(tx)
    cascade.nudge_if(revive_out)  # deferred tier surgery (spec §5.3)
    audit.log("model.enable", f"model:{model_id}", json.dumps(revive_out))
    return {"ok": True, "generation": gen, "restore": revive_out}


@router.post("/{model_id}/routes", status_code=201)
async def add_route(model_id: int, request: Request, user: dict = Depends(require_auth)):
    """POST /api/models/{id}/routes — bind a provider onto a model.

    Bind-time entitlement validation (spec A.5): the route targets the
    listing named by upstream_model_id (or the model's own name when
    unset). deny on EVERY key of the provider -> 400 entitlement_denied
    with the matrix evidence; partial coverage binds but the response
    carries a warnings field the SPA shows.
    """
    body = await request.json()
    provider_id = body.get("provider_id")
    upstream = body.get("upstream_model_id") or None
    weight = _parse_weight(body.get("weight", 1))
    priority = _parse_priority(body.get("priority", 0))

    if isinstance(provider_id, bool) or not isinstance(provider_id, int) or provider_id < 1:
        raise _err(400, "invalid", "provider_id required")
    if upstream is not None and not isinstance(upstream, str):
        raise _err(400, "invalid", "upstream_model_id must be a string or null")

    model = await database.fetchrow("SELECT id, name FROM models WHERE id = $1", model_id)
    provider = await database.fetchrow("SELECT id, name FROM providers WHERE id = $1", provider_id)
    if not model:
        raise _err(404, "not_found", "model not found")
    if not provider:
        raise _err(404, "not_found", "provider not found")

    listing = upstream or model["name"]
    evidence = await entitlements.bind_evidence(provider_id, listing)
    if evidence["all_deny"]:
        raise _err(
            400,
            "entitlement_denied",
            f"model '{listing}' is deny-marked on {evidence['deny']}/{evidence['keys']} "
            f"keys of provider '{provider['name']}' (matrix evidence; re-probe or "
            f"pick another listing)",
        )
    warnings: list[str] = []
    if evidence["deny"] > 0:
        warnings.append(
            f"model ok on {evidence['ok']}/{evidence['keys']} keys for provider {provider['name']}"
        )

    async with database.transaction() as tx:
        # DO UPDATE, not DO NOTHING: re-adding an existing (possibly
        # disabled) binding must apply the requested weight/priority and
        # re-enable it instead of silently reporting success for a no-op.
        await tx.execute(
            "INSERT INTO model_routes (model_id, provider_id, upstream_model_id, weight, priority, enabled) "
            "VALUES ($1, $2, $3, $4, $5, 1) "
            "ON CONFLICT (model_id, provider_id) DO UPDATE SET "
            "upstream_model_id = EXCLUDED.upstream_model_id, "
            "weight = EXCLUDED.weight, priority = EXCLUDED.priority, enabled = 1",
            model_id,
            provider_id,
            upstream,
            weight,
            priority,
        )
        # D2: binding a model the cascade retired revives it (row enabled +
        # tier membership back) — this is the "re-add the provider, then
        # rebind" path.
        revive_out = await cascade.revive_for_route(tx, model_id=model_id)
        gen = await database.bump_generation(tx)
    cascade.nudge_if(revive_out)  # deferred tier surgery (spec §5.3)
    audit.log(
        "route.add",
        f"model:{model_id}->provider:{provider_id}",
        f"listing={listing} ok={evidence['ok']}/{evidence['keys']}",
    )
    return {"ok": True, "generation": gen, "warnings": warnings, "restore": revive_out}


@router.post("/{model_id}/routes/{provider_id}/disable")
async def disable_route(model_id: int, provider_id: int, user: dict = Depends(require_auth)):
    async with database.transaction() as tx:
        result = await tx.execute(
            "UPDATE model_routes SET enabled = 0 WHERE model_id = $1 AND provider_id = $2",
            model_id,
            provider_id,
        )
        if result == "UPDATE 0":
            raise _err(404, "not_found", "route not found")
        gen = await database.bump_generation(tx)
    audit.log("route.disable", f"model:{model_id}->provider:{provider_id}")
    return {"ok": True, "generation": gen}


@router.post("/{model_id}/routes/{provider_id}/enable")
async def enable_route(model_id: int, provider_id: int, user: dict = Depends(require_auth)):
    async with database.transaction() as tx:
        result = await tx.execute(
            "UPDATE model_routes SET enabled = 1 WHERE model_id = $1 AND provider_id = $2",
            model_id,
            provider_id,
        )
        if result == "UPDATE 0":
            raise _err(404, "not_found", "route not found")
        # Same revival contract as route add: an enabled binding is what makes
        # a cascade-retired model live again.
        revive_out = await cascade.revive_for_route(tx, model_id=model_id)
        gen = await database.bump_generation(tx)
    cascade.nudge_if(revive_out)  # deferred tier surgery (spec §5.3)
    audit.log("route.enable", f"model:{model_id}->provider:{provider_id}", json.dumps(revive_out))
    return {"ok": True, "generation": gen, "restore": revive_out}


@router.delete("/{model_id}/routes/{provider_id}")
async def delete_route(model_id: int, provider_id: int, user: dict = Depends(require_auth)):
    async with database.transaction() as tx:
        result = await tx.execute(
            "DELETE FROM model_routes WHERE model_id = $1 AND provider_id = $2",
            model_id,
            provider_id,
        )
        if result == "DELETE 0":
            raise _err(404, "not_found", "route not found")
        gen = await database.bump_generation(tx)
    audit.log("route.delete", f"model:{model_id}->provider:{provider_id}")
    return {"ok": True, "generation": gen}


@router.post("/{model_id}/routes/{provider_id}/rebalance")
async def rebalance_route(
    model_id: int, provider_id: int, request: Request, user: dict = Depends(require_auth)
):
    """Persist weight/priority for a binding and bump catalog generation."""
    body = await request.json()
    sets = []
    args = []
    if "weight" in body:
        args.append(_parse_weight(body["weight"]))
        sets.append(f"weight = ${len(args)}")
    if "priority" in body:
        args.append(_parse_priority(body["priority"]))
        sets.append(f"priority = ${len(args)}")
    if not sets:
        raise _err(400, "invalid", "weight or priority required")
    args.extend([model_id, provider_id])
    sql = (
        f"UPDATE model_routes SET {', '.join(sets)} "
        f"WHERE model_id = ${len(args) - 1} AND provider_id = ${len(args)}"
    )
    async with database.transaction() as tx:
        result = await tx.execute(sql, *args)
        if result == "UPDATE 0":
            raise _err(404, "not_found", "route not found")
        gen = await database.bump_generation(tx)
    audit.log("route.rebalance", f"model:{model_id}->provider:{provider_id}")
    return {"ok": True, "generation": gen}
