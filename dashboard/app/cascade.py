"""Cascade on provider / listing / model retirement (spec 2026-10-22).

Operator-approved semantics (docs/superpowers/specs/2026-10-22-cascade-and-affinity-design.md):

- Retiring a public model ALWAYS means ``models.enabled = 0`` — never a
  DELETE (D1). The name, its prices, its usage history and its bindings
  survive so re-binding is cheap (and reversible, D2).
- A public model is retired only when it has **no enabled route and no
  enabled listing** ("still routable elsewhere" guard, spec §2).
- Tier lists are pruned silently, with a journal entry and one audit line
  (D3) — today a stale tier member makes every later Router save fail
  ``400 not_bound`` (settings.py:354).
- Every change is journaled in ``config_cascade_events`` so
  :func:`restore_for_provider` can replay exactly what was turned off.

Invariants (spec §5):

1. Every helper runs inside the CALLER's transaction; nothing here opens
   one. The caller owns the single config-generation bump for the request,
   so a cascade never adds a second one (and a no-op cascade never bumps).
2. Tier rewrites take ``pg_try_advisory_xact_lock`` on
   ``auto_reorder.ADVISORY_XACT_KEY`` plus a row lock on the settings row,
   then clear the pending-proposal anchors. The lock is retried for ~2.4 s;
   if it is still held the tier rewrite is DEFERRED with a loud log rather
   than failing the request (the provider kill switch must not be gated by
   an auto-router tick) — the routes/models half still commits.
3. ``enabled`` is SMALLINT 0/1 on every gateway-owned table.
4. Nothing but the explicit cascade happens here: agent-key grants
   (``api_key_models``), entitlements, usage/prices and the name-keyed
   metadata maps are deliberately left alone (spec §2).
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Iterable, Sequence
from typing import Any

import asyncpg

from . import audit, auto_reorder, database

logger = logging.getLogger("janus.dashboard.cascade")

AUTO_ROUTER_KEY = "auto_router"
TIERS = ("fast", "big", "flagship")
_LOCK_ATTEMPTS = 16
_LOCK_SLEEP = 0.15
# The retry path is background, so it can afford to wait out a slow writer
# (the reorder tick holds the lock across its own scoring) — but not forever.
_RETRY_ATTEMPTS = 80
_RETRY_SLEEP = 0.25
_PENDING_RETRY_SEC = 15.0
_PENDING_BATCH = 25
# An unresolved intent is retried forever on purpose (nothing may be lost),
# but a row that stays blocked across this many attempts means the tier lock
# is effectively owned by someone else for minutes: say so loudly, once per
# block of attempts, so an operator can see a poisoned intent in the log
# instead of only in a metrics table nobody watches.
_PENDING_LOUD_ATTEMPTS = 20


class CascadeBusy(RuntimeError):
    """The auto-router holds the tiers lock past the retry budget.

    Raised by :func:`_lock_tiers` only; the tier helpers catch it and DEFER
    the rewrite instead of failing the request — ``disable_provider`` is the
    kill switch and must never be gated by an unrelated auto-router tick.
    A deferred prune is logged loudly, because the stale tier member is what
    makes the next Router save answer ``400 not_bound``.
    """


def _jload(value: Any) -> Any:
    """jsonb comes back as text unless a codec is registered."""
    if value is None or isinstance(value, (dict, list)):
        return value
    if isinstance(value, (bytes, bytearray)):
        value = value.decode()
    if isinstance(value, str):
        try:
            return json.loads(value)
        except (TypeError, ValueError):
            return None
    return None


async def _lock_tiers(
    tx: asyncpg.Connection,
    attempts: int = _LOCK_ATTEMPTS,
    sleep: float = _LOCK_SLEEP,
) -> dict[str, Any]:
    """Take the tiers advisory lock + row lock and return the live config.

    The lock holder is either the auto-reorder tick (sub-second write) or
    another operator action, so a bounded retry beats both a hard 409 on
    the first attempt and an unbounded wait inside a request. The retry path
    passes a longer budget: it is background work, not a request.
    """
    for attempt in range(attempts):
        got = await tx.fetchval(
            "SELECT pg_try_advisory_xact_lock($1)", auto_reorder.ADVISORY_XACT_KEY
        )
        if got:
            row = await tx.fetchrow(
                "SELECT value FROM settings WHERE key = $1 FOR UPDATE", AUTO_ROUTER_KEY
            )
            cfg = _jload(row["value"]) if row else None
            return cfg if isinstance(cfg, dict) else {}
        if attempt < attempts - 1:
            await asyncio.sleep(sleep)
    raise CascadeBusy("the auto-router is mid-write; retry in a moment")


async def _write_tiers(tx: asyncpg.Connection, cfg: dict[str, Any]) -> None:
    await tx.execute(
        "INSERT INTO settings (key, value) VALUES ($1, $2::jsonb) "
        "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
        AUTO_ROUTER_KEY,
        json.dumps(cfg, ensure_ascii=False),
    )
    # A pending auto proposal was scored against the old membership, and a
    # rejected-marker proposal could re-add a name we are removing.
    #
    # `last_manual_edit_at` is stamped for the same reason the human PUT
    # stamps it (auto_reorder.py human_commit:715): the D35 compensating
    # restore replays the pre-reject `before_tiers` verbatim, and it skips
    # only while that anchor is newer than the rejected commit. Clearing the
    # marker alone is NOT enough — a gateway-reported reject re-creates it
    # (auto_reorder._consume_reject_marker:793), which would resurrect a name
    # this cascade just pruned, straight into the 400 not_bound trap. As a
    # bonus the reorder loop then holds off for `manual_hold_sec`.
    await tx.execute(
        "UPDATE auto_router_state SET pending_tiers = NULL, pending_since = NULL, "
        "reject_marker = NULL, last_manual_edit_at = NOW() WHERE id = 1"
    )


async def _still_unroutable(tx: asyncpg.Connection, names: Sequence[str]) -> list[str]:
    """Requested names with no enabled route AND no enabled listing (spec §2).

    The same guard the retire decision uses, re-evaluated at retry time: a
    name that became routable again (route re-enabled, listing added back)
    must NOT be pruned by a stale intent.
    """
    wanted = sorted({n for n in names if n})
    if not wanted:
        return []
    rows = await tx.fetch(
        """
        SELECT n.name
          FROM unnest($1::text[]) AS n(name)
         WHERE NOT EXISTS (
                 SELECT 1 FROM models m
                  JOIN model_routes r ON r.model_id = m.id
                 WHERE m.name = n.name AND r.enabled = 1)
           AND NOT EXISTS (
                 SELECT 1 FROM provider_models pm
                  JOIN providers p ON p.id = pm.provider_id
                 WHERE pm.name = n.name AND pm.enabled = 1 AND p.enabled = 1)
        """,
        wanted,
    )
    return [r["name"] for r in rows]


async def _still_bound(tx: asyncpg.Connection, names: Sequence[str]) -> set[str]:
    """Requested names the Router save would accept (models + route enabled)."""
    wanted = sorted({n for n in names if n})
    if not wanted:
        return set()
    rows = await tx.fetch(
        """
        SELECT DISTINCT m.name
          FROM models m
          JOIN model_routes r ON r.model_id = m.id
         WHERE m.name = ANY($1::text[]) AND m.enabled = 1 AND r.enabled = 1
        """,
        wanted,
    )
    return {r["name"] for r in rows}


async def _pending_bind_event(tx: asyncpg.Connection, names: Sequence[str], event_id: int) -> None:
    """Attach the journal event to a deferred prune.

    The retry removes the member LATER, so the indices it removes are only
    known then — it needs the event id to write them back, otherwise the
    journal says "nothing was removed" and a later re-enable cannot replay the
    tier seat (spec §4).
    """
    wanted = sorted({n for n in names if n})
    if not wanted or not event_id:
        return
    owned = json.dumps({n: int(event_id) for n in wanted})
    await tx.execute(
        "UPDATE config_cascade_pending "
        "   SET event_id = COALESCE(event_id, $2), "
        "       payload = jsonb_set(payload, '{events}', "
        "                   COALESCE(payload->'events', '{}'::jsonb) || $3::jsonb) "
        " WHERE kind = 'prune' AND resolved_at IS NULL AND payload->'names' ?| $1::text[]",
        wanted,
        int(event_id),
        owned,
    )


async def _pending_add(
    tx: asyncpg.Connection,
    *,
    kind: str,
    payload: dict[str, Any],
    source_kind: str | None = None,
    provider_id: int | None = None,
    note: str | None = None,
) -> int | None:
    """Record a deferred tier operation INSIDE the caller's transaction.

    Committing with the route/model half is the whole point: a rolled-back
    mutation must not leave a dangling intent, and a committed one must never
    lose its tier surgery. Overlapping unresolved prunes coalesce (a repeated
    disable queues one intent, not N); identical unresolved restores do too.
    """
    if kind == "prune":
        names = sorted({n for n in (payload.get("names") or []) if n})
        if not names:
            return None
        row = await tx.fetchrow(
            "SELECT id, payload FROM config_cascade_pending "
            " WHERE kind = 'prune' AND resolved_at IS NULL "
            " ORDER BY id DESC LIMIT 1 FOR UPDATE"
        )
        if row is not None:
            have = _jload(row["payload"]) or {}
            merged = sorted(set(names) | {n for n in (have.get("names") or []) if n})
            # Keep the per-name event map: coalescing names from a SECOND
            # provider must not forget which journal event owns which name,
            # or the retry writes every removal onto one event and the other
            # provider's re-enable has no seat to replay.
            keep_events = have.get("events")
            payload_out: dict[str, Any] = {"names": merged}
            if isinstance(keep_events, dict) and keep_events:
                payload_out["events"] = keep_events
            await tx.execute(
                "UPDATE config_cascade_pending "
                "   SET payload = $2::jsonb, note = COALESCE($3, note) "
                " WHERE id = $1",
                row["id"],
                json.dumps(payload_out),
                note,
            )
            return int(row["id"])
        return int(
            await tx.fetchval(
                "INSERT INTO config_cascade_pending (kind, payload, source_kind, provider_id, note) "
                "VALUES ($1, $2::jsonb, $3, $4, $5) RETURNING id",
                kind,
                json.dumps({"names": names}),
                source_kind,
                provider_id,
                note,
            )
        )
    existing = await tx.fetchval(
        "SELECT id FROM config_cascade_pending "
        " WHERE kind = $1 AND resolved_at IS NULL AND payload = $2::jsonb LIMIT 1",
        kind,
        json.dumps(payload),
    )
    if existing is not None:
        return int(existing)
    return int(
        await tx.fetchval(
            "INSERT INTO config_cascade_pending (kind, payload, source_kind, provider_id, note) "
            "VALUES ($1, $2::jsonb, $3, $4, $5) RETURNING id",
            kind,
            json.dumps(payload),
            source_kind,
            provider_id,
            note,
        )
    )


async def _prune_cfg(
    tx: asyncpg.Connection, cfg: dict[str, Any], wanted: set[str]
) -> dict[str, list[dict]]:
    """Lock-free core: drop ``wanted`` from ``cfg``'s tiers and persist."""
    tiers = cfg.get("tiers")
    if not isinstance(tiers, dict):
        return {}
    removed: dict[str, list[dict]] = {}
    changed = False
    for tier in TIERS:
        arr = list(tiers.get(tier) or [])
        kept: list[Any] = []
        gone: list[dict] = []
        for index, name in enumerate(arr):
            if name in wanted:
                gone.append({"name": name, "index": index})
            else:
                kept.append(name)
        if gone:
            tiers[tier] = kept
            removed[tier] = gone
            changed = True
    if not changed:
        return {}
    cfg["tiers"] = tiers
    await _write_tiers(tx, cfg)
    return removed


async def _restore_cfg(
    tx: asyncpg.Connection, cfg: dict[str, Any], entries: dict[str, Any]
) -> bool:
    """Lock-free core: re-insert recorded members at their original index."""
    tiers = cfg.get("tiers")
    if not isinstance(tiers, dict):
        tiers = {}
    owner = {name: tier for tier in TIERS for name in (tiers.get(tier) or [])}
    changed = False
    for tier in TIERS:
        arr = list(tiers.get(tier) or [])
        for entry in sorted(entries.get(tier) or [], key=lambda e: e.get("index") or 0):
            name = (entry or {}).get("name")
            if not name or name in arr or owner.get(name):
                continue
            try:
                index = int(entry.get("index"))
            except (TypeError, ValueError):
                index = len(arr)
            arr.insert(max(0, min(index, len(arr))), name)
            owner[name] = tier
            changed = True
        tiers[tier] = arr
    if not changed:
        return False
    cfg["tiers"] = tiers
    await _write_tiers(tx, cfg)
    return True


async def _tier_prune(
    tx: asyncpg.Connection,
    names: Sequence[str],
    *,
    source_kind: str | None = None,
    provider_id: int | None = None,
) -> tuple[dict[str, list[dict]], list[str]]:
    """Drop ``names`` from every tier; return ({tier: removed}, deferred names).

    When the auto-router holds the lock past the retry budget the prune is
    DEFERRED: the intent is written to ``config_cascade_pending`` in this same
    transaction and applied by :func:`retry_pending` (immediately via
    :func:`nudge`, otherwise by the always-on loop). Returning the deferred
    names lets the endpoint say so instead of implying the tier is clean.
    """
    wanted = {n for n in names if n}
    if not wanted:
        return {}, []
    try:
        cfg = await _lock_tiers(tx)
    except CascadeBusy as exc:
        logger.warning(
            "cascade: tier prune DEFERRED for %s (%s) — queued as a durable "
            "intent, retried after this request commits",
            sorted(wanted),
            exc,
        )
        await _pending_add(
            tx,
            kind="prune",
            payload={"names": sorted(wanted)},
            source_kind=source_kind,
            provider_id=provider_id,
            note=f"deferred prune: {exc}",
        )
        return {}, sorted(wanted)
    return await _prune_cfg(tx, cfg, wanted), []


async def _tier_restore(
    tx: asyncpg.Connection,
    removed: Any,
    *,
    source_kind: str | None = None,
    provider_id: int | None = None,
) -> tuple[bool, bool]:
    """Re-insert recorded members at their original index; (changed, deferred)."""
    entries = _jload(removed)
    if not isinstance(entries, dict) or not entries:
        return False, False
    try:
        cfg = await _lock_tiers(tx)
    except CascadeBusy as exc:
        logger.warning("cascade: tier restore DEFERRED (%s) — queued as a durable intent", exc)
        await _pending_add(
            tx,
            kind="restore",
            payload={"tiers": entries},
            source_kind=source_kind,
            provider_id=provider_id,
            note=f"deferred restore: {exc}",
        )
        return False, True
    return await _restore_cfg(tx, cfg, entries), False


async def _journal(
    tx: asyncpg.Connection,
    *,
    actor: str,
    source_kind: str,
    provider_id: int | None = None,
    provider_name: str | None = None,
    model_id: int | None = None,
    routes: Iterable[dict] = (),
    models: Iterable[int] = (),
    tiers: dict[str, Any] | None = None,
) -> int:
    return await tx.fetchval(
        """
        INSERT INTO config_cascade_events
            (actor, source_kind, source_provider_id, source_provider_name,
             source_model_id, routes, models, tiers)
        VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7::jsonb, $8::jsonb)
        RETURNING id
        """,
        actor,
        source_kind,
        provider_id,
        provider_name,
        model_id,
        json.dumps(list(routes), ensure_ascii=False),
        json.dumps(list(models), ensure_ascii=False),
        json.dumps(tiers or {}, ensure_ascii=False),
    )


async def _judge_name(tx: asyncpg.Connection) -> str | None:
    """The configured judge model, if any (spec §2: never silently surgery it)."""
    row = await tx.fetchrow("SELECT value FROM settings WHERE key = $1", AUTO_ROUTER_KEY)
    if not row:
        return None
    cfg = _jload(row["value"])
    judge = cfg.get("judge_model") if isinstance(cfg, dict) else None
    return judge if isinstance(judge, str) and judge.strip() else None


async def _retire_locked(
    tx: asyncpg.Connection,
    model_ids: Sequence[int],
    *,
    exclude_provider_id: int | None = None,
    exclude_listing: tuple[int, str] | None = None,
    source_kind: str | None = None,
    provider_id: int | None = None,
) -> tuple[list[dict], dict[str, list[dict]], list[str]]:
    """Disable the models that lost their last route/listing, prune tiers.

    The listing arm requires an ENABLED provider AND ignores the listing that
    caused this cascade: a disabled provider keeps its listings enabled, and a
    listing that is being retired is still enabled at this point, so counting
    either would make the cascade a no-op — the exact stale-binding case this
    exists to fix. Exclusions are explicit so the outcome does not depend on
    whether the caller flipped the flag before or after calling us.
    """
    if not model_ids:
        return [], {}, []
    params: list[Any] = [list(model_ids)]
    clauses = ["pm.enabled = 1", "p.enabled = 1"]
    if exclude_provider_id is not None:
        params.append(exclude_provider_id)
        clauses.append(f"pm.provider_id <> ${len(params)}")
    if exclude_listing is not None:
        params.extend([exclude_listing[0], exclude_listing[1]])
        clauses.append(f"NOT (pm.provider_id = ${len(params) - 1} AND pm.name = ${len(params)})")
    listing_where = " AND ".join(clauses)
    rows = await tx.fetch(
        f"""
        SELECT m.id, m.name, m.enabled,
               EXISTS (SELECT 1 FROM model_routes r
                        WHERE r.model_id = m.id AND r.enabled = 1) AS has_route,
               EXISTS (SELECT 1 FROM provider_models pm
                         JOIN providers p ON p.id = pm.provider_id
                        WHERE pm.name = m.name AND {listing_where}) AS has_listing
          FROM models m
         WHERE m.id = ANY($1::bigint[])
        """,
        *params,
    )
    # Only rows this call actually flips: an already-retired model belongs to
    # the event that retired it (a second disable would otherwise journal a
    # duplicate event, re-report it in `models_retired`, and make one restore
    # replay two events for one retire).
    retired = [
        {"id": r["id"], "name": r["name"]}
        for r in rows
        if not r["has_route"] and not r["has_listing"] and r["enabled"] == 1
    ]
    if not retired:
        return [], {}, []
    await tx.execute(
        "UPDATE models SET enabled = 0 WHERE id = ANY($1::bigint[]) AND enabled = 1",
        [r["id"] for r in retired],
    )
    names = [r["name"] for r in retired]
    # Spec §2: if the retired name is the configured judge, leave the judge
    # setting alone (we never touch it) but say so loudly instead of letting
    # it dangle unnoticed.
    judge = await _judge_name(tx)
    if judge and judge in names:
        audit.log(
            "cascade_judge_warning",
            AUTO_ROUTER_KEY,
            json.dumps({"retired": judge, "note": "judge_model is now unbound; left in place"}),
        )
    removed, deferred = await _tier_prune(
        tx, names, source_kind=source_kind, provider_id=provider_id
    )
    return retired, removed, deferred


async def provider_retire(
    tx: asyncpg.Connection,
    *,
    provider_id: int,
    provider_name: str | None,
    mode: str,
    actor: str = "console",
) -> dict[str, Any]:
    """Cascade a provider disable/delete: routes off (or gone), then models.

    Called BEFORE the endpoint deletes the provider row, so the route
    snapshot still exists for the journal (a delete removes the rows).
    """
    if mode not in ("disable", "delete"):
        raise ValueError("mode must be 'disable' or 'delete'")
    snapshot = [
        dict(r)
        for r in await tx.fetch(
            "SELECT model_id, provider_id, upstream_model_id, weight, priority, enabled "
            "FROM model_routes WHERE provider_id = $1 ORDER BY model_id",
            provider_id,
        )
    ]
    model_ids = sorted({r["model_id"] for r in snapshot})
    if mode == "disable":
        tag = await tx.execute(
            "UPDATE model_routes SET enabled = 0 WHERE provider_id = $1 AND enabled = 1",
            provider_id,
        )
        changed = int(tag.split()[-1])
    else:
        await tx.execute("DELETE FROM model_routes WHERE provider_id = $1", provider_id)
        changed = len(snapshot)
    retired, removed, deferred = await _retire_locked(
        tx,
        model_ids,
        exclude_provider_id=provider_id,
        source_kind=f"provider_{mode}",
        provider_id=provider_id,
    )
    # Nothing moved (the provider was already disabled and its routes already
    # off): the earlier, still-unrestored event owns this state, so a second
    # journal row would only make one restore replay two events for one change.
    if not changed and not retired and not removed and not deferred:
        return {
            "routes": 0,
            "models_retired": [],
            "tiers_removed": {},
            "deferred": [],
            "journaled": False,
        }
    event_id = await _journal(
        tx,
        actor=actor,
        source_kind=f"provider_{mode}",
        provider_id=provider_id,
        provider_name=provider_name,
        routes=snapshot,
        models=[r["id"] for r in retired],
        tiers=removed,
    )
    if deferred:
        await _pending_bind_event(tx, deferred, event_id or 0)
    return {
        "routes": changed,
        "models_retired": [r["name"] for r in retired],
        "tiers_removed": removed,
        "deferred": deferred,
        "journaled": True,
    }


async def listing_retire(
    tx: asyncpg.Connection,
    *,
    provider_id: int,
    listing_name: str,
    mode: str,
    actor: str = "console",
) -> dict[str, Any]:
    """Cascade a listing (provider_models) disable/delete onto its routes.

    Defence in depth: the gateway also refuses a route whose listing is
    explicitly disabled (``janus_catalog:listing_enabled/2`` + ``janus_lb``,
    gateway e2ac786f), but retiring the routes here keeps the Router honest
    (no binding pointing at a listing the operator turned off) and bridges the
    ~2 s window before a gateway hot-reload sees the new flag.
    """
    if mode not in ("disable", "delete"):
        raise ValueError("mode must be 'disable' or 'delete'")
    snapshot = [
        dict(r)
        for r in await tx.fetch(
            """
            SELECT mr.model_id, mr.provider_id, mr.upstream_model_id,
                   mr.weight, mr.priority, mr.enabled
              FROM model_routes mr
              JOIN models m ON m.id = mr.model_id
             WHERE mr.provider_id = $1
               AND COALESCE(mr.upstream_model_id, m.name) = $2
             ORDER BY mr.model_id
            """,
            provider_id,
            listing_name,
        )
    ]
    model_ids = sorted({r["model_id"] for r in snapshot})
    changed = len(snapshot)
    for row in snapshot:
        if mode == "disable":
            tag = await tx.execute(
                "UPDATE model_routes SET enabled = 0 "
                "WHERE model_id = $1 AND provider_id = $2 AND enabled = 1",
                row["model_id"],
                row["provider_id"],
            )
            if tag.endswith(" 0"):
                changed -= 1
        else:
            await tx.execute(
                "DELETE FROM model_routes WHERE model_id = $1 AND provider_id = $2",
                row["model_id"],
                row["provider_id"],
            )
    retired, removed, deferred = await _retire_locked(
        tx,
        model_ids,
        exclude_listing=(provider_id, listing_name),
        source_kind=f"listing_{mode}",
        provider_id=provider_id,
    )
    # An already-fully-retired listing (repeat disable) owns its state in the
    # earlier, still-unrestored event: a second row would only make one
    # restore replay two events for one change.
    if not changed and not retired and not removed and not deferred:
        return {
            "routes": 0,
            "models_retired": [],
            "tiers_removed": {},
            "deferred": [],
            "journaled": False,
        }
    event_id = await _journal(
        tx,
        actor=actor,
        source_kind=f"listing_{mode}",
        provider_id=provider_id,
        model_id=None,
        routes=snapshot,
        models=[r["id"] for r in retired],
        tiers=removed,
    )
    if deferred:
        await _pending_bind_event(tx, deferred, event_id or 0)
    return {
        "routes": changed,
        "models_retired": [r["name"] for r in retired],
        "tiers_removed": removed,
        "deferred": deferred,
        "journaled": True,
    }


async def model_retire(
    tx: asyncpg.Connection,
    *,
    model_id: int,
    model_name: str,
    mode: str,
    actor: str = "console",
) -> dict[str, Any]:
    """Cascade a model disable/delete: its tier membership goes away.

    The caller has already flipped or deleted the row; this prunes the
    name from the tier lists and journals the removal so a later
    re-binding can bring the membership back.
    """
    if mode not in ("disable", "delete"):
        raise ValueError("mode must be 'disable' or 'delete'")
    removed, deferred = await _tier_prune(
        tx, [model_name], source_kind=f"model_{mode}", provider_id=None
    )
    # Journaled even when no tier member was pruned: this row IS the record
    # that lets a later route add re-enable the model (revive_for_route keys
    # off an unrestored event referencing it), so dropping it here would
    # break the documented "rebind and it is alive again" path.
    event_id = await _journal(
        tx,
        actor=actor,
        source_kind=f"model_{mode}",
        model_id=model_id,
        models=[model_id] if mode == "disable" else [],
        tiers=removed,
    )
    if deferred:
        await _pending_bind_event(tx, deferred, event_id or 0)
    return {"tiers_removed": removed, "deferred": deferred}


async def _maybe_mark_restored(
    tx: asyncpg.Connection,
    event_id: int,
    routes: Sequence[dict],
    model_ids: Sequence[int],
    actor: str,
) -> bool:
    """Mark an event restored once every recorded row is live again."""
    if not model_ids:
        await tx.execute(
            "UPDATE config_cascade_events SET restored_at = NOW(), restore_actor = $2 "
            "WHERE id = $1 AND restored_at IS NULL",
            event_id,
            actor,
        )
        return True
    pending_routes = await tx.fetchval(
        """
        SELECT EXISTS (
            SELECT 1 FROM model_routes r
             WHERE r.model_id = ANY($1::bigint[]) AND r.enabled = 0
        )
        """,
        list(model_ids),
    )
    pending_models = await tx.fetchval(
        "SELECT EXISTS (SELECT 1 FROM models m WHERE m.id = ANY($1::bigint[]) AND m.enabled = 0)",
        list(model_ids),
    )
    if pending_routes or pending_models:
        return False
    await tx.execute(
        "UPDATE config_cascade_events SET restored_at = NOW(), restore_actor = $2 "
        "WHERE id = $1 AND restored_at IS NULL",
        event_id,
        actor,
    )
    return True


async def restore_for_provider(
    tx: asyncpg.Connection,
    *,
    provider_id: int,
    provider_name: str | None = None,
    actor: str = "console",
) -> dict[str, Any]:
    """Replay the journal for a provider that is enabled (or re-created).

    ``provider_id`` is the provider that should own the routes now — for a
    re-create that is the NEW row, which is why routes are re-inserted
    rather than only re-enabled (a delete removed them).
    """
    enabled = await tx.fetchval("SELECT enabled FROM providers WHERE id = $1", provider_id)
    if not enabled:
        # A disabled provider must never get its routes back — that is exactly
        # the 503 provider_disabled state this cascade removes. Its own enable
        # replays the journal later.
        return {"events": 0, "skipped": "provider_disabled"}
    events = await tx.fetch(
        """
        SELECT id, routes, models, tiers FROM config_cascade_events
         WHERE restored_at IS NULL
           AND (source_provider_id = $1 OR ($2::text IS NOT NULL AND source_provider_name = $2))
         ORDER BY id
        """,
        provider_id,
        provider_name,
    )
    restored = 0
    deferred = False
    for ev in events:
        routes = _jload(ev["routes"]) or []
        model_ids = [r.get("model_id") for r in routes if r.get("model_id")]
        touched_tiers = False
        for route in routes:
            model_id = route.get("model_id")
            if model_id is None:
                continue
            if not await tx.fetchval("SELECT 1 FROM models WHERE id = $1", model_id):
                continue
            await tx.execute(
                """
                INSERT INTO model_routes
                    (model_id, provider_id, upstream_model_id, weight, priority, enabled)
                VALUES ($1, $2, $3, $4, $5, 1)
                ON CONFLICT (model_id, provider_id) DO UPDATE SET enabled = 1
                """,
                model_id,
                provider_id,
                route.get("upstream_model_id"),
                route.get("weight") or 1,
                route.get("priority") or 0,
            )
        if model_ids:
            await tx.execute(
                """
                UPDATE models SET enabled = 1
                 WHERE id = ANY($1::bigint[]) AND enabled = 0
                   AND EXISTS (SELECT 1 FROM model_routes r
                                WHERE r.model_id = models.id AND r.enabled = 1)
                """,
                model_ids,
            )
        touched_tiers, deferred_restore = await _tier_restore(
            tx, ev["tiers"], source_kind=f"restore:{ev['id']}", provider_id=provider_id
        )
        deferred = deferred or deferred_restore
        await _maybe_mark_restored(tx, ev["id"], routes, model_ids, actor)
        restored += 1
        if touched_tiers:
            logger.info("cascade restore: tiers re-inserted for provider %s", provider_id)
    if restored:
        audit.log(
            "cascade_restore",
            f"provider:{provider_id}",
            json.dumps({"events": restored, "provider_name": provider_name}),
        )
    return {"events": restored, "deferred": deferred}


async def revive_for_route(
    tx: asyncpg.Connection, *, model_id: int, actor: str = "console"
) -> dict[str, Any]:
    """A new enabled route revives a model the cascade retired (D2)."""
    events = await tx.fetch(
        """
        SELECT id, routes, models, tiers FROM config_cascade_events
         WHERE restored_at IS NULL AND models @> $1::jsonb
         ORDER BY id
        """,
        json.dumps([model_id]),
    )
    if not events:
        return {"revived": False}
    if not await tx.fetchval(
        "SELECT 1 FROM model_routes WHERE model_id = $1 AND enabled = 1 LIMIT 1", model_id
    ):
        return {"revived": False}
    revived = await tx.fetchval(
        "UPDATE models SET enabled = 1 WHERE id = $1 AND enabled = 0 RETURNING 1", model_id
    )
    deferred = False
    for ev in events:
        # Tier membership only: the event is deliberately NOT marked restored
        # here. A route add revives the MODEL, but a provider_delete event
        # still owes its deleted routes to a future re-create — marking it
        # restored would silently drop that replay.
        _, deferred_restore = await _tier_restore(
            tx, ev["tiers"], source_kind=f"revive:{ev['id']}", provider_id=None
        )
        deferred = deferred or deferred_restore
    if revived:
        audit.log("cascade_revive", f"model:{model_id}", json.dumps({"events": len(events)}))
    return {"revived": bool(revived), "events": len(events), "deferred": deferred}


# ---------------------------------------------------------------------------
# Deferred tier surgery: the durable retry (spec §5.3, closing the residual)
# ---------------------------------------------------------------------------
#
# A request must never block on the tiers lock (the provider disable is the
# kill switch), and it must never lose the tier half either. The intent is
# therefore committed with the caller's transaction and applied here, where
# waiting is free. Every intent is RE-VALIDATED before it is applied, so a
# stale queue entry can only ever be a no-op:
#
#   * prune  -> only names that are still unroutable (no enabled route and no
#               enabled listing) are stripped; a name the operator re-bound in
#               the meantime resolves as `stale` and keeps its seat.
#   * restore-> only names that are currently bound (models.enabled=1 AND an
#               enabled route) are re-inserted; anything else resolves `stale`.

_wake: asyncio.Event | None = None
_pending_task: asyncio.Task | None = None


def nudge() -> None:
    """Ask the retry loop to run now (called after a deferred request commits).

    A no-op when the loop is not running (tests, scripts): the durable row is
    the contract, the nudge is only latency.
    """
    if _wake is not None:
        _wake.set()


def nudge_if(result: dict[str, Any] | None) -> None:
    """Nudge the retry loop when a cascade result reports deferred surgery.

    Called by the routers AFTER their transaction commits: retrying inside the
    transaction could not see the uncommitted intent row anyway.
    """
    if isinstance(result, dict) and result.get("deferred"):
        nudge()


def _group_by_event(
    removed: dict[str, list[dict]], payload: dict[str, Any], fallback: int | None
) -> list[tuple[int | None, dict[str, list[dict]]]]:
    """Split a coalesced removal by the journal event that owns each name.

    A single pending row may carry names from several providers, each with its
    own event. Writing one provider's indices onto another provider's event
    leaves the first event empty, so its eventual re-enable replays the
    routes/model but silently loses the tier seat.
    """
    events = payload.get("events")
    events = events if isinstance(events, dict) else {}
    grouped: dict[int | None, dict[str, list[dict]]] = {}
    for tier, entries in removed.items():
        for entry in entries:
            owner = events.get((entry or {}).get("name"))
            try:
                owner = int(owner) if owner is not None else fallback
            except (TypeError, ValueError):
                owner = fallback
            grouped.setdefault(owner, {}).setdefault(tier, []).append(entry)
    return list(grouped.items())


async def _record_removed(
    tx: asyncpg.Connection, event_id: int | None, removed: dict[str, list[dict]]
) -> None:
    """Write what the retry removed back onto the journal event (spec §4).

    Merged, not replaced: one event can lose one member inline (recorded at
    retire time) and another only when the retry runs.
    """
    if not event_id or not removed:
        return
    row = await tx.fetchrow(
        "SELECT tiers, restored_at FROM config_cascade_events WHERE id = $1 FOR UPDATE", event_id
    )
    if row is None or row["restored_at"] is not None:
        return
    have = _jload(row["tiers"]) if row["tiers"] is not None else {}
    have = have if isinstance(have, dict) else {}
    for tier, entries in removed.items():
        merged = list(have.get(tier) or [])
        known = {(e or {}).get("name") for e in merged}
        merged.extend(e for e in entries if (e or {}).get("name") not in known)
        have[tier] = merged
    await tx.execute(
        "UPDATE config_cascade_events SET tiers = $2::jsonb WHERE id = $1",
        event_id,
        json.dumps(have),
    )


async def _resolve(
    tx: asyncpg.Connection, pending_id: int, resolution: str, attempts_delta: int = 1
) -> bool:
    """Mark a pending row resolved; the CAS makes a double apply impossible."""
    tag = await tx.execute(
        "UPDATE config_cascade_pending "
        "   SET resolved_at = NOW(), resolution = $2, "
        "       attempts = attempts + $3, last_try_at = NOW() "
        " WHERE id = $1 AND resolved_at IS NULL",
        pending_id,
        resolution,
        attempts_delta,
    )
    return not tag.endswith(" 0")


async def retry_pending(limit: int = _PENDING_BATCH) -> dict[str, int]:
    """Apply deferred tier surgery. Idempotent, re-validating, CAS-resolved."""
    rows = await database.fetch(
        "SELECT id, kind, payload, event_id, attempts FROM config_cascade_pending "
        " WHERE resolved_at IS NULL ORDER BY id LIMIT $1",
        limit,
    )
    counts = {"checked": len(rows), "applied": 0, "stale": 0, "busy": 0, "skipped": 0}
    for row in rows:
        pending_id = int(row["id"])
        kind = row["kind"]
        payload = _jload(row["payload"]) or {}
        try:
            async with database.transaction() as tx:
                # The advisory lock serializes retriers AND re-checking the row
                # under FOR UPDATE makes a second retrier that read the same
                # snapshot bail out instead of applying it twice.
                try:
                    cfg = await _lock_tiers(tx, _RETRY_ATTEMPTS, _RETRY_SLEEP)
                except CascadeBusy as exc:
                    await tx.execute(
                        "UPDATE config_cascade_pending "
                        "   SET attempts = attempts + 1, last_try_at = NOW(), note = $2 "
                        " WHERE id = $1 AND resolved_at IS NULL",
                        pending_id,
                        f"retry still busy: {exc}",
                    )
                    counts["busy"] += 1
                    tries = int(row["attempts"] or 0) + 1
                    if tries >= _PENDING_LOUD_ATTEMPTS and tries % _PENDING_LOUD_ATTEMPTS == 0:
                        logger.warning(
                            "cascade pending %s (%s) still blocked after %s attempts — the tier "
                            "lock has stayed busy since it was queued; the intent is kept and "
                            "retried (nothing is lost), but tiers stay inconsistent until it "
                            "applies: %s",
                            pending_id,
                            kind,
                            tries,
                            ", ".join(sorted(n for n in (payload.get("names") or []) if n))[:200]
                            or "-",
                        )
                    continue
                # Re-read the WHOLE row under FOR UPDATE, not just resolved_at:
                # while this pass was waiting for the lock another request may
                # have coalesced more names into the payload (a retrier that
                # kept its initial snapshot would apply the old name list,
                # resolve the row, and silently drop the names added since).
                fresh = await tx.fetchrow(
                    "SELECT resolved_at, kind, payload, event_id FROM config_cascade_pending "
                    " WHERE id = $1 FOR UPDATE",
                    pending_id,
                )
                if fresh is None or fresh["resolved_at"] is not None:
                    counts["skipped"] += 1
                    continue
                kind = fresh["kind"]
                payload = _jload(fresh["payload"]) or {}
                event_id = fresh["event_id"]
                if kind == "prune":
                    names = sorted({n for n in (payload.get("names") or []) if n})
                    still = await _still_unroutable(tx, names)
                    removed = await _prune_cfg(tx, cfg, set(still)) if still else {}
                    if removed:
                        for owner, mapping in _group_by_event(removed, payload, event_id):
                            await _record_removed(tx, owner, mapping)
                        await database.bump_generation(tx)
                        counts["applied"] += 1
                        resolution = "applied"
                    else:
                        counts["stale"] += 1
                        resolution = "stale"
                    detail = {
                        "kind": "prune",
                        "names": names,
                        "pruned": sorted({e["name"] for v in removed.values() for e in v}),
                        "event_id": event_id,
                        "resolution": resolution,
                    }
                elif kind == "restore":
                    entries = payload.get("tiers") or {}
                    wanted = sorted(
                        {
                            entry.get("name")
                            for tier in TIERS
                            for entry in (entries.get(tier) or [])
                            if isinstance(entry, dict) and entry.get("name")
                        }
                    )
                    bound = await _still_bound(tx, wanted) if wanted else set()
                    filtered = {
                        tier: [
                            entry
                            for entry in (entries.get(tier) or [])
                            if isinstance(entry, dict) and entry.get("name") in bound
                        ]
                        for tier in TIERS
                    }
                    changed = await _restore_cfg(tx, cfg, filtered) if bound else False
                    if changed:
                        await database.bump_generation(tx)
                        counts["applied"] += 1
                        resolution = "applied"
                    else:
                        counts["stale"] += 1
                        resolution = "stale"
                    detail = {
                        "kind": "restore",
                        "restored": sorted(bound) if changed else [],
                        "resolution": resolution,
                    }
                else:
                    counts["skipped"] += 1
                    await _resolve(tx, pending_id, "unknown_kind")
                    audit.log(
                        "cascade.pending_unknown",
                        AUTO_ROUTER_KEY,
                        json.dumps({"id": pending_id, "kind": kind}),
                    )
                    continue
                await _resolve(tx, pending_id, resolution)
                audit.log("cascade.pending_" + resolution, AUTO_ROUTER_KEY, json.dumps(detail))
                logger.info("cascade pending %s -> %s: %s", pending_id, resolution, detail)
        except asyncio.CancelledError:
            raise
        except Exception:
            # One bad row must not stop the others; it stays unresolved.
            logger.exception("cascade pending retry failed for id %s", pending_id)
            counts["busy"] += 1
    return counts


async def _retry_loop() -> None:
    global _wake
    _wake = asyncio.Event()
    while True:
        try:
            counts = await retry_pending()
            if counts["applied"] or counts["stale"] or counts["busy"]:
                logger.info("cascade pending retry: %s", counts)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("cascade pending retry loop failed")
        try:
            await asyncio.wait_for(_wake.wait(), timeout=_PENDING_RETRY_SEC)
        except TimeoutError:
            pass
        _wake.clear()


async def start_background() -> None:
    """Always-on retry: the durable backstop, independent of the reorder knob."""
    global _pending_task
    if _pending_task is None or _pending_task.done():
        _pending_task = asyncio.create_task(_retry_loop())
        logger.info("cascade pending-retry loop started (every %.0fs)", _PENDING_RETRY_SEC)


async def stop_background() -> None:
    global _pending_task
    if _pending_task is not None:
        _pending_task.cancel()
        try:
            await _pending_task
        except asyncio.CancelledError:
            pass
        _pending_task = None
