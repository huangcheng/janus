"""Per-key and per-listing management for providers.

Weight tuning, enable/disable, secret rotation, and removal of individual
upstream keys, plus enable/disable/delete of inventory listings. Mounted at
/api/provider-keys and /api/provider-models.
"""

import json

from fastapi import APIRouter, Depends, HTTPException, Request

from .. import audit, cascade, database, entitlements
from ..auth import require_auth
from ..crypto import _active_key, encrypt

keys_router = APIRouter()
models_router = APIRouter()


def _err(status: int, code: str, message: str) -> HTTPException:
    return HTTPException(status, detail={"error": {"code": code, "message": message}})


async def _key_owner(key_id: int) -> str | None:
    row = await database.fetchrow(
        "SELECT p.name FROM provider_keys pk JOIN providers p ON p.id = pk.provider_id "
        "WHERE pk.id = $1",
        key_id,
    )
    return row["name"] if row else None


@keys_router.post("/{key_id}/secret")
async def rotate_key_secret(key_id: int, request: Request, user: dict = Depends(require_auth)):
    """POST /api/provider-keys/{id}/secret — replace the stored credential.

    Spec A.1 key lifecycle: a new secret may belong to a different
    account, so ALL of the key's entitlement rows (both polarities,
    including the __key__ broken mark) are deleted IN THE SAME TRANSACTION
    as the generation bump — gateways drop the stale broken mark
    immediately. A re-probe bootstrap is queued; while it waits the key
    is row-less = unknown = eligible, and request-time 401 on it fails
    over as usual. Weight-only updates touch nothing.
    """
    body = await request.json()
    secret = str(body.get("secret", "")).strip()
    if not secret:
        raise _err(400, "invalid", "secret required")
    row = await database.fetchrow(
        "SELECT pk.id, pk.provider_id, p.name AS provider FROM provider_keys pk "
        "JOIN providers p ON p.id = pk.provider_id WHERE pk.id = $1",
        key_id,
    )
    if not row:
        raise _err(404, "not_found", "key not found")

    envelope = encrypt(secret.encode())
    envelope_kid, _ = _active_key()
    async with database.transaction() as tx:
        await tx.execute(
            "UPDATE provider_keys SET secret_ciphertext = $1, key_id = $2 WHERE id = $3",
            envelope,
            envelope_kid,
            key_id,
        )
        wiped = await entitlements.wipe_key_rows(tx, key_id)
        gen = await database.bump_generation(tx)
    entitlements.on_secret_updated(row["provider_id"], key_id)
    audit.log(
        "provider_key.secret",
        f"{row['provider']}:key:{key_id}",
        f"entitlement rows wiped={wiped} re-probe queued generation={gen}",
    )
    return {"ok": True, "generation": gen, "entitlement_rows_wiped": wiped}


@keys_router.post("/{key_id}/weight")
async def set_key_weight(key_id: int, request: Request, user: dict = Depends(require_auth)):
    body = await request.json()
    weight = body.get("weight")
    if isinstance(weight, bool) or not isinstance(weight, int) or not (1 <= weight <= 10**6):
        raise _err(400, "invalid", "weight must be an integer between 1 and 1000000")
    owner = await _key_owner(key_id)
    if not owner:
        raise _err(404, "not_found", "key not found")
    async with database.transaction() as tx:
        await tx.execute("UPDATE provider_keys SET weight = $1 WHERE id = $2", weight, key_id)
        gen = await database.bump_generation(tx)
    audit.log("provider_key.weight", f"{owner}:key:{key_id}", f"weight={weight}")
    return {"ok": True, "generation": gen}


@keys_router.post("/{key_id}/enable")
async def enable_key(key_id: int, user: dict = Depends(require_auth)):
    owner = await _key_owner(key_id)
    if not owner:
        raise _err(404, "not_found", "key not found")
    async with database.transaction() as tx:
        await tx.execute("UPDATE provider_keys SET enabled = 1 WHERE id = $1", key_id)
        gen = await database.bump_generation(tx)
    audit.log("provider_key.enable", f"{owner}:key:{key_id}")
    return {"ok": True, "generation": gen}


@keys_router.post("/{key_id}/disable")
async def disable_key(key_id: int, user: dict = Depends(require_auth)):
    owner = await _key_owner(key_id)
    if not owner:
        raise _err(404, "not_found", "key not found")
    async with database.transaction() as tx:
        await tx.execute("UPDATE provider_keys SET enabled = 0 WHERE id = $1", key_id)
        gen = await database.bump_generation(tx)
    audit.log("provider_key.disable", f"{owner}:key:{key_id}")
    return {"ok": True, "generation": gen}


@keys_router.delete("/{key_id}")
async def delete_key(key_id: int, user: dict = Depends(require_auth)):
    owner = await _key_owner(key_id)
    if not owner:
        raise _err(404, "not_found", "key not found")
    async with database.transaction() as tx:
        await tx.execute("DELETE FROM provider_keys WHERE id = $1", key_id)
        gen = await database.bump_generation(tx)
    audit.log("provider_key.delete", f"{owner}:key:{key_id}")
    return {"ok": True, "generation": gen}


async def _listing_owner(listing_id: int) -> tuple[int, str, str] | None:
    """(provider_id, provider name, listing name) for a listing row."""
    row = await database.fetchrow(
        "SELECT pm.provider_id, p.name AS provider, pm.name AS model "
        "FROM provider_models pm "
        "JOIN providers p ON p.id = pm.provider_id WHERE pm.id = $1",
        listing_id,
    )
    return (row["provider_id"], row["provider"], row["model"]) if row else None


@models_router.post("/{listing_id}/enable")
async def enable_listing(listing_id: int, user: dict = Depends(require_auth)):
    owner = await _listing_owner(listing_id)
    if not owner:
        raise _err(404, "not_found", "listing not found")
    async with database.transaction() as tx:
        await tx.execute("UPDATE provider_models SET enabled = 1 WHERE id = $1", listing_id)
        # D2: re-enabling a listing brings back the bindings the cascade took
        # off for it. restore_for_provider refuses while the provider itself
        # is disabled, so this can never re-enable a route into a 503.
        restore_out = await cascade.restore_for_provider(
            tx, provider_id=owner[0], provider_name=owner[1]
        )
        gen = await database.bump_generation(tx)
    cascade.nudge_if(restore_out)  # deferred tier surgery (spec §5.3)
    audit.log("provider_model.enable", f"{owner[1]}:{owner[2]}", json.dumps(restore_out))
    return {"ok": True, "generation": gen, "restore": restore_out}


@models_router.post("/{listing_id}/disable")
async def disable_listing(listing_id: int, user: dict = Depends(require_auth)):
    owner = await _listing_owner(listing_id)
    if not owner:
        raise _err(404, "not_found", "listing not found")
    async with database.transaction() as tx:
        await tx.execute("UPDATE provider_models SET enabled = 0 WHERE id = $1", listing_id)
        # Defence in depth, not a workaround: the gateway now honours a
        # listing's own enabled flag on bound routes too
        # (janus_catalog:listing_enabled/2 + janus_lb, gateway e2ac786f), so
        # retiring the routes here keeps the Router honest — no binding left
        # pointing at a listing the operator turned off — and bridges the
        # ~2 s window before a gateway hot-reload sees the new flag.
        cascade_out = await cascade.listing_retire(
            tx, provider_id=owner[0], listing_name=owner[2], mode="disable"
        )
        gen = await database.bump_generation(tx)
    cascade.nudge_if(cascade_out)  # deferred tier surgery (spec §5.3)
    audit.log("provider_model.disable", f"{owner[1]}:{owner[2]}", json.dumps(cascade_out))
    return {"ok": True, "generation": gen, "cascade": cascade_out}


@models_router.delete("/{listing_id}")
async def delete_listing(listing_id: int, user: dict = Depends(require_auth)):
    """Remove an inventory listing (this path did not exist before).

    Cascade first and then the row: listing_retire excludes the listing that
    caused it, so it works whether the row is still present or already gone.
    """
    owner = await _listing_owner(listing_id)
    if not owner:
        raise _err(404, "not_found", "listing not found")
    async with database.transaction() as tx:
        cascade_out = await cascade.listing_retire(
            tx, provider_id=owner[0], listing_name=owner[2], mode="delete"
        )
        await tx.execute("DELETE FROM provider_models WHERE id = $1", listing_id)
        gen = await database.bump_generation(tx)
    cascade.nudge_if(cascade_out)  # deferred tier surgery (spec §5.3)
    audit.log("provider_model.delete", f"{owner[1]}:{owner[2]}", json.dumps(cascade_out))
    return {"ok": True, "generation": gen, "cascade": cascade_out}
