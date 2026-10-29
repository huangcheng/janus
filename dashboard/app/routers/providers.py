"""Provider CRUD endpoints."""

import difflib
import json
import logging
import time

import asyncpg
import httpx
from fastapi import APIRouter, Depends, HTTPException, Request

from .. import (
    audit,
    cascade,
    database,
    decisions,
    egress,
    entitlements,
    nodes,
    probe_urls,
)
from ..auth import require_auth
from ..crypto import _active_key, encrypt

router = APIRouter()
logger = logging.getLogger("janus.dashboard.providers")

NAME_MAX = 200
WEIGHT_MAX = 10**6

# openai_decisions: native /v1/decisions passthrough (spec 2026-10-07).
# Writes are gated (app/decisions.enforce_write_gate) and grant-confirmed
# (D10) — see create_provider / enable_provider / add_provider_model.
PROTOCOLS = ["openai_chat", "anthropic_messages", "openai_responses", "openai_decisions"]


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


@router.get("")
async def list_providers(user: dict = Depends(require_auth)):
    # region_tag/affinity_node ship with gateway migration 015;
    # tolerate a not-yet-migrated gateway during rolling deploys.
    # allow_internal ships with gateway migration 017 (v2.2 Part C);
    # tolerate a not-yet-migrated gateway during rolling deploys.
    try:
        providers = await database.fetch(
            "SELECT id, name, base_url, protocol, enabled, region_tag, affinity_node, "
            "allow_internal FROM providers ORDER BY id"
        )
    except Exception:
        try:
            providers = await database.fetch(
                "SELECT id, name, base_url, protocol, enabled, region_tag, affinity_node "
                "FROM providers ORDER BY id"
            )
        except Exception:
            providers = await database.fetch(
                "SELECT id, name, base_url, protocol, enabled FROM providers ORDER BY id"
            )
    keys = await database.fetch(
        "SELECT id, provider_id, key_id, weight, enabled FROM provider_keys ORDER BY id"
    )
    # modality ships with migration 010; tolerate a not-yet-migrated
    # gateway during rolling deploys by degrading to the legacy select.
    try:
        models = await database.fetch(
            "SELECT id, provider_id, name, enabled, modality FROM provider_models ORDER BY id"
        )
    except Exception:
        models = await database.fetch(
            "SELECT id, provider_id, name, enabled FROM provider_models ORDER BY id"
        )
    keys_by_provider: dict[int, list[dict]] = {}
    for k in keys:
        keys_by_provider.setdefault(k["provider_id"], []).append(
            {
                "id": k["id"],
                # Display label only — the envelope key id plus row id; the
                # secret itself is never readable after encryption.
                "key_id": f"{k['key_id']}#{k['id']}",
                "weight": k["weight"],
                "enabled": bool(k["enabled"]),
            }
        )
    models_by_provider: dict[int, list[dict]] = {}
    for m in models:
        models_by_provider.setdefault(m["provider_id"], []).append(
            {
                "id": m["id"],
                "provider_id": m["provider_id"],
                "name": m["name"],
                "enabled": bool(m["enabled"]),
                "modality": m.get("modality") or "chat",
            }
        )
    return {
        "providers": [
            {
                "id": p["id"],
                "name": p["name"],
                "base_url": p["base_url"],
                "protocol": p["protocol"],
                "enabled": bool(p["enabled"]),
                "region_tag": p.get("region_tag"),
                "affinity_node": p.get("affinity_node"),
                "allow_internal": bool(p.get("allow_internal")),
                "keys": keys_by_provider.get(p["id"], []),
                "models": models_by_provider.get(p["id"], []),
            }
            for p in providers
        ]
    }


@router.post("", status_code=201)
async def create_provider(request: Request, user: dict = Depends(require_auth)):
    body = await request.json()
    name = _parse_name(body)
    base_url_raw = body.get("base_url", "")
    if not isinstance(base_url_raw, str):
        raise _err(400, "invalid", "base_url must be a string")
    base_url = base_url_raw.strip()
    protocol = body.get("protocol", "openai_chat")
    key = body.get("key")
    # Scheduler v2 (gateway migration 015) per-provider fields, set at
    # create time: legacy geo comparator + absolute affinity pin.
    region_tag = str(body.get("region_tag") or "").strip() or None
    affinity_node = str(body.get("affinity_node") or "").strip() or None

    if not base_url:
        raise _err(400, "invalid", "name and base_url required")
    if protocol not in PROTOCOLS:
        raise _err(400, "invalid_protocol", f"must be one of {PROTOCOLS}")
    if not (base_url.startswith(("http://", "https://"))):
        raise _err(400, "invalid_url", "base_url must start with http:// or https://")

    # 03b H1: store the base in the form the gateway requires — the version
    # segment belongs to base_url, because the data plane only joins a suffix.
    # A host-only Anthropic value would otherwise answer /messages (404).
    base_url = probe_urls.canonical_base(base_url, protocol)

    # v2.2 Part C: SSRF write-gate, ALWAYS-ON. reject_internal_base_url
    # classifies with is_internal_sockaddr (loopback, RFC1918,
    # link-local/cloud-metadata, ULA, 100.64/10, multicast, mapped v6,
    # NAT64; ANY internal record rejects; resolution failure rejects —
    # fail-closed F6). allow_internal is the audited break-glass
    # (operator role + confirm + reason) reserved for local mocks.
    allow_internal = body.get("allow_internal") is True
    if allow_internal:
        gate = egress.require_breakglass(request, "provider allow_internal")
        egress.require_confirmed(body, "allow_internal")
    else:
        gate = None
    reject_internal_base_url(base_url, allow_internal)

    # Decisions (spec 2026-10-07 D10 + D-write): confirm the billable
    # grant warning, then fail-closed readyz write gate (break-glass
    # ?force=1&role=…&reason=… is audited, inside the gate helper).
    if protocol == decisions.DECISIONS_PROTOCOL:
        decisions.require_confirm(body, "creating an openai_decisions provider")
        await decisions.enforce_write_gate(request, f"provider.create:{name}")

    # Optional initial key: written in the same transaction, so a failed
    # key write never leaves an orphaned provider behind.
    secret = ""
    weight = 1
    if key is not None:
        if not isinstance(key, dict):
            raise _err(400, "invalid", "key must be an object {secret, weight}")
        secret = str(key.get("secret", "")).strip()
        weight = _parse_weight(key.get("weight", 1))
        if not secret:
            raise _err(400, "invalid", "key.secret required when key is given")

    async def _insert(with_geo: bool, with_flag: bool) -> dict:
        async with database.transaction() as tx:
            if with_geo and with_flag:
                row = await tx.fetchrow(
                    "INSERT INTO providers (name, base_url, protocol, enabled, region_tag, "
                    "affinity_node, allow_internal) VALUES ($1, $2, $3, 1, $4, $5, $6) RETURNING id",
                    name,
                    base_url,
                    protocol,
                    region_tag,
                    affinity_node,
                    1 if allow_internal else 0,
                )
            elif with_geo:
                row = await tx.fetchrow(
                    "INSERT INTO providers (name, base_url, protocol, enabled, region_tag, affinity_node) "
                    "VALUES ($1, $2, $3, 1, $4, $5) RETURNING id",
                    name,
                    base_url,
                    protocol,
                    region_tag,
                    affinity_node,
                )
            else:
                row = await tx.fetchrow(
                    "INSERT INTO providers (name, base_url, protocol, enabled) "
                    "VALUES ($1, $2, $3, 1) RETURNING id",
                    name,
                    base_url,
                    protocol,
                )
            if secret:
                envelope = encrypt(secret.encode())
                key_id, _ = _active_key()
                await tx.execute(
                    "INSERT INTO provider_keys (provider_id, secret_ciphertext, key_id, weight, enabled) "
                    "VALUES ($1, $2, $3, $4, 1)",
                    row["id"],
                    envelope,
                    key_id,
                    weight,
                )
            # D2: a provider created under the name of a deleted one inherits
            # its journal — the Router bindings it lost are re-inserted
            # against the NEW id and the models it retired come back.
            restore_out = await cascade.restore_for_provider(
                tx, provider_id=row["id"], provider_name=name
            )
            gen = await database.bump_generation(tx)
            return {"row": row, "gen": gen, "restore": restore_out}

    try:
        out = await _insert(True, allow_internal)
    except Exception as e:
        if isinstance(e, asyncpg.UniqueViolationError):
            raise _err(409, "duplicate", "provider name exists") from e
        if isinstance(e, asyncpg.UndefinedColumnError):
            # Pre-015 gateway during a rolling deploy: create without
            # the geo columns (mirrors the pre-010 add_provider_model
            # fallback pattern). Pre-017 additionally lacks
            # allow_internal — degrade by dropping the flag ONLY when
            # it was not the thing standing between an internal URL
            # and the table (fail-closed otherwise).
            want_flag = allow_internal
            try:
                out = await _insert(False, want_flag)
            except Exception as e2:
                if isinstance(e2, asyncpg.UniqueViolationError):
                    raise _err(409, "duplicate", "provider name exists") from e2
                if isinstance(e2, asyncpg.UndefinedColumnError) and want_flag:
                    raise _err(
                        409,
                        "migration_pending",
                        "allow_internal needs gateway migration 017 (retry after the "
                        "gateway rolls); refusing to store an internal base_url unflagged",
                    ) from e2
                logger.exception("provider create fallback failed for name=%r", name)
                raise _err(500, "db_error", "could not create provider") from e2
        else:
            logger.exception("provider create failed for name=%r", name)
            raise _err(500, "db_error", "could not create provider") from e
    row, gen = out["row"], out["gen"]
    restored = out.get("restore") or {}
    cascade.nudge_if(restored)  # deferred tier surgery (spec §5.3)
    audit.log("provider.add", name, base_url + (" +key" if secret else ""))
    if restored.get("events"):
        audit.log("cascade_restore", f"provider:{row['id']}", json.dumps(restored))
    if allow_internal:
        audit.log(
            "provider.allow_internal",
            f"provider:{row['id']}",
            f"set at create role={gate['role']} reason={gate['reason']} base_url={base_url}",
        )
    if protocol == decisions.DECISIONS_PROTOCOL:
        # D10: audit who accepted the Decisions grant warning on create.
        audit.log(
            "decisions.grant_confirm",
            f"provider:{row['id']}",
            "create — operator accepted Decisions billable warning",
        )
    return {"id": row["id"], "name": name, "generation": gen, "restore": restored}


def reject_internal_base_url(base_url: str, allow_internal: bool) -> None:
    """v2.2 Part C SSRF write-gate. is_internal_sockaddr classifies the
    resolved sockaddrs (ANY internal record rejects; resolution failure
    rejects — fail-closed F6: an operator can retry, a flaky resolver
    must not open the gate). allow_internal is the audited break-glass
    that skips classification entirely — it is the documented residual
    trust boundary (a fully compromised dashboard sets its own flag;
    gateway-side connect-time enforcement is Part H).

    Residual (F5, documented for the runbook): write-time gating cannot
    bind the gateway's later connect-time resolution — a public host
    re-resolving internal at call time (DNS rebinding) stays open.
    """
    if allow_internal:
        return
    verdict = egress.is_internal_sockaddr(base_url)
    if verdict is None:
        raise _err(
            400,
            "invalid_url",
            "base_url host does not resolve (fail-closed) — retry, or use the "
            "audited allow_internal break-glass for local mocks",
        )
    if verdict:
        raise _err(
            400,
            "invalid_url",
            "base_url resolves to an internal address (loopback/RFC1918/link-local/"
            "cloud-metadata/ULA/CGNAT/multicast) — allow_internal break-glass "
            "(?role=&reason= + confirmed) is for local mocks only",
        )


@router.post("/test-key")
async def test_provider_key(request: Request, user: dict = Depends(require_auth)):
    """Probe a vendor's model list with a not-yet-stored key.

    Read-only against the DB. The secret is used for one upstream request
    and is never logged, audited, or echoed back. v2.2 Part C: the dial
    URL passes the same internal-address gate as stored writes (a probe
    endpoint must not become the SSRF side door); there is no flag path
    here — test a stored flagged provider through its listing instead.

    Deliberate SPA contract: every probe outcome is HTTP 200 with
    {ok: bool, error: <code>, detail: <text>} — this endpoint does not use
    the {error: {code, message}} envelope (the Test-key card switches on
    ``error``).
    """
    body = await request.json()
    base_url = str(body.get("base_url", "")).strip()
    protocol = str(body.get("protocol", ""))
    secret = str(body.get("secret", "")).strip()

    if not (base_url.startswith(("http://", "https://"))):
        raise _err(400, "invalid_url", "base_url must start with http:// or https://")
    if protocol not in PROTOCOLS:
        raise _err(400, "invalid_protocol", f"must be one of {PROTOCOLS}")
    if not secret:
        raise _err(400, "invalid", "secret required")
    reject_internal_base_url(base_url, allow_internal=False)

    # 03b H1/H2: the probe URL and its TLS policy come from probe_urls, the
    # single source of truth shared with entitlement probes and model sync.
    # This used to hard-code /v1/models for Anthropic and /models otherwise —
    # the third of three mutually exclusive conventions in this repo, and the
    # one that disagreed with the gateway, which never inserts a version
    # segment of its own.
    url, headers = probe_urls.models_request(base_url, protocol, secret)
    verify = probe_urls.tls_verify()
    try:
        async with httpx.AsyncClient(timeout=10.0, verify=verify) as client:
            resp = await client.get(url, headers=headers)
    except Exception as e:
        return {"ok": False, "error": "unreachable", "detail": type(e).__name__}

    if resp.status_code in (401, 403):
        return {"ok": False, "error": "invalid_key", "detail": f"HTTP {resp.status_code}"}
    if resp.status_code in (404, 405):
        return {
            "ok": False,
            "error": "unverifiable",
            "detail": f"endpoint serves no model list (HTTP {resp.status_code})",
        }
    if resp.status_code != 200:
        return {"ok": False, "error": "upstream_error", "detail": f"HTTP {resp.status_code}"}
    try:
        data = resp.json()
        count = len(data.get("data", [])) if isinstance(data, dict) else 0
    except Exception:
        return {"ok": False, "error": "unverifiable", "detail": "non-JSON response"}
    return {"ok": True, "models": count}


@router.post("/{provider_id}/disable")
async def disable_provider(provider_id: int, user: dict = Depends(require_auth)):
    async with database.transaction() as tx:
        row = await tx.fetchrow("SELECT id, name FROM providers WHERE id = $1", provider_id)
        if row is None:
            raise _err(404, "not_found", "provider not found")
        await tx.execute("UPDATE providers SET enabled = 0 WHERE id = $1", provider_id)
        # Cascade (spec 2026-10-22 §2): the provider's Router bindings go off,
        # every model that loses its last route/listing is retired, and its
        # janus-auto tier memberships are pruned — in the same transaction.
        # Without this the gateway answers 503 provider_disabled while
        # /api/models still advertises the binding.
        cascade_out = await cascade.provider_retire(
            tx, provider_id=provider_id, provider_name=row["name"], mode="disable"
        )
        gen = await database.bump_generation(tx)
    cascade.nudge_if(cascade_out)  # deferred tier surgery (spec §5.3)
    audit.log("provider.disable", f"provider:{provider_id}", json.dumps(cascade_out))
    return {"ok": True, "generation": gen, "cascade": cascade_out}


@router.post("/{provider_id}/enable")
async def enable_provider(provider_id: int, request: Request, user: dict = Depends(require_auth)):
    provider = await database.fetchrow(
        "SELECT id, name, protocol FROM providers WHERE id = $1", provider_id
    )
    if not provider:
        raise _err(404, "not_found", "provider not found")
    # Re-enabling a Decisions provider re-runs the write gate (fail
    # closed). Disabling is never gated — it is the kill switch.
    if provider["protocol"] == decisions.DECISIONS_PROTOCOL:
        await decisions.enforce_write_gate(
            request, f"provider.enable:{provider_id}:{provider['name']}"
        )
    async with database.transaction() as tx:
        result = await tx.execute("UPDATE providers SET enabled = 1 WHERE id = $1", provider_id)
        if result == "UPDATE 0":
            raise _err(404, "not_found", "provider not found")
        # D2: re-enabling replays the cascade journal — the routes this
        # provider lost go back on, the models it retired come back, and the
        # tier memberships return at their original index. Idempotent: rows
        # the operator already touched by hand are left alone.
        restore_out = await cascade.restore_for_provider(
            tx, provider_id=provider_id, provider_name=provider["name"]
        )
        gen = await database.bump_generation(tx)
    cascade.nudge_if(restore_out)  # deferred tier surgery (spec §5.3)
    audit.log("provider.enable", f"provider:{provider_id}", json.dumps(restore_out))
    return {"ok": True, "generation": gen, "restore": restore_out}


def _live_worker_nodes() -> list[str]:
    """Erlang long names from FRESH sched caches (a frozen cache is no data).

    Fresh-only on purpose: a pin must not be accepted for a node that has
    left the fleet, and must not be rejected just because one gateway's poll
    is stale.
    """
    names: set[str] = set()
    for sched in nodes.sched_data().values():
        if sched.get("error") is not None or not sched.get("scraped_at"):
            continue
        for worker in sched.get("workers") or []:
            name = worker.get("node") if isinstance(worker, dict) else None
            if isinstance(name, str) and name:
                names.add(name)
    return sorted(names)


def _match_worker_node(raw: str, live: list[str]) -> tuple[str | None, list[str]]:
    """Resolve a pin to exactly ONE live worker.

    Returns ``(canonical_name, hits)``; ``(None, hits)`` when nothing matched
    (empty hits) or when a bare host is shared by several Erlang node names
    (hits > 1) — silently picking the first sorted candidate would pin a
    provider to an arbitrary one of them.
    """
    if raw in live:
        return raw, [raw]
    hits = [candidate for candidate in live if candidate.split("@", 1)[-1] == raw]
    if len(hits) == 1:
        return hits[0], hits
    return None, hits


@router.patch("/{provider_id}")
async def patch_provider(provider_id: int, request: Request, user: dict = Depends(require_auth)):
    """PATCH /api/providers/{id} — the affinity pin and the soft region tag.

    ``affinity_node`` is enforced by the gateway as an ABSOLUTE tier-2 pin:
    the pinned node becomes the only candidate, outranking health and geo,
    with the capacity soft cap bypassed. It is fail-open, so a miss silently
    falls through to another node — which is why the name is validated
    against the LIVE worker set here (an unresolvable name becomes
    ``undefined`` in the gateway and quietly unpins the provider,
    janus_http_worker_client.erl:175-182). Nothing ever auto-sets a pin.

    ``region_tag`` is only a soft preference for the geo narrowing and is
    never validated against the fleet (it is a comparator, not a node).
    """
    body = await request.json()
    if not isinstance(body, dict):
        raise _err(400, "invalid", "body must be a JSON object")
    unknown = sorted(set(body) - {"affinity_node", "region_tag"})
    if unknown:
        raise _err(400, "invalid", f"unsupported field(s): {', '.join(unknown)}")
    if not body:
        raise _err(400, "invalid", "nothing to update")

    provider = await database.fetchrow("SELECT id, name FROM providers WHERE id = $1", provider_id)
    if not provider:
        raise _err(404, "not_found", "provider not found")

    assignments: list[str] = []
    params: list[object] = [provider_id]
    detail: dict[str, object] = {}

    if "affinity_node" in body:
        raw = body["affinity_node"]
        if raw is None or (isinstance(raw, str) and not raw.strip()):
            assignments.append("affinity_node = NULL")
            detail["affinity_node"] = None
        elif not isinstance(raw, str):
            raise _err(400, "invalid", "affinity_node must be a string or null")
        else:
            wanted = raw.strip()
            live = _live_worker_nodes()
            node, hits = _match_worker_node(wanted, live)
            if node is None:
                if len(hits) > 1:
                    raise _err(
                        400,
                        "ambiguous_node",
                        f"{wanted!r} matches {len(hits)} workers "
                        f"({', '.join(hits)}) — pin the full Erlang name.",
                    )
                near = difflib.get_close_matches(wanted, live, n=3)
                hint = f" Did you mean {', '.join(near)}?" if near else ""
                raise _err(
                    400,
                    "unknown_node",
                    f"{wanted!r} is not in the live worker pool ({len(live)} worker(s))."
                    f"{hint} The gateway would silently ignore an unresolvable pin, so "
                    "it is refused here.",
                )
            params.append(node)
            assignments.append(f"affinity_node = ${len(params)}")
            detail["affinity_node"] = node

    if "region_tag" in body:
        raw = body["region_tag"]
        if raw is None or (isinstance(raw, str) and not raw.strip()):
            assignments.append("region_tag = NULL")
            detail["region_tag"] = None
        elif not isinstance(raw, str):
            raise _err(400, "invalid", "region_tag must be a string or null")
        elif len(raw.strip()) > 64:
            raise _err(400, "invalid", "region_tag must be 64 characters or fewer")
        else:
            params.append(raw.strip())
            assignments.append(f"region_tag = ${len(params)}")
            detail["region_tag"] = raw.strip()

    try:
        async with database.transaction() as tx:
            await tx.execute(
                f"UPDATE providers SET {', '.join(assignments)} WHERE id = $1", *params
            )
            gen = await database.bump_generation(tx)
    except asyncpg.UndefinedColumnError as exc:
        # Pre-015 gateway during a rolling deploy.
        raise _err(
            409,
            "migration_pending",
            "affinity needs gateway migration 015 (retry after the gateway rolls)",
        ) from exc
    audit.log("provider.patch", f"provider:{provider_id}", json.dumps(detail))
    return {"ok": True, "generation": gen, **detail}


@router.post("/{provider_id}/allow-internal")
async def set_allow_internal(
    provider_id: int, request: Request, user: dict = Depends(require_auth)
):
    """v2.2 Part C: set or clear the audited internal-base_url escape
    flag. ADMIN-GATED both directions (operator role + confirm +
    reason — the Decisions break-glass machinery): a plain session
    cannot self-authorize an internal base_url. Audits carry actor,
    role/reason, and before/after. Degrades gracefully on a missing
    column (pre-017 rolling deploy): 409 migration_pending."""
    body = await request.json()
    want = body.get("allow_internal")
    if not isinstance(want, bool):
        raise _err(400, "invalid", "body must carry {allow_internal: boolean}")
    gate = egress.require_breakglass(request, "provider allow_internal")
    egress.require_confirmed(body, "allow_internal")
    provider = await database.fetchrow(
        "SELECT id, name, base_url FROM providers WHERE id = $1", provider_id
    )
    if not provider:
        raise _err(404, "not_found", "provider not found")
    row = await database.fetchrow("SELECT allow_internal FROM providers WHERE id = $1", provider_id)
    before = bool(row["allow_internal"]) if row and row["allow_internal"] is not None else False
    try:
        await database.execute(
            "UPDATE providers SET allow_internal = $1 WHERE id = $2",
            1 if want else 0,
            provider_id,
        )
    except Exception as e:
        if isinstance(e, asyncpg.UndefinedColumnError):
            raise _err(
                409,
                "migration_pending",
                "allow_internal needs gateway migration 017 (retry after the gateway rolls)",
            ) from e
        logger.exception("provider allow_internal update failed for id=%s", provider_id)
        raise _err(500, "db_error", "could not update provider") from e
    if want and not before:
        audit.log(
            "provider.allow_internal",
            f"provider:{provider_id}",
            f"role={gate['role']} reason={gate['reason']} before=0 after=1 "
            f"name={provider['name']} base_url={provider['base_url']}",
        )
    elif before and not want:
        audit.log(
            "provider.allow_internal_cleared",
            f"provider:{provider_id}",
            f"role={gate['role']} reason={gate['reason']} before=1 after=0 "
            f"name={provider['name']} base_url={provider['base_url']}",
        )
    return {"ok": True, "allow_internal": want}


@router.delete("/{provider_id}")
async def delete_provider(provider_id: int, user: dict = Depends(require_auth)):
    async with database.transaction() as tx:
        row = await tx.fetchrow("SELECT id, name FROM providers WHERE id = $1", provider_id)
        if row is None:
            raise _err(404, "not_found", "provider not found")
        # Cascade FIRST: it snapshots the routes into the journal while they
        # still exist (a delete would take them with it), retires the models
        # that lose their last route/listing, and prunes their tier
        # memberships. Re-creating a provider with the same name replays it.
        cascade_out = await cascade.provider_retire(
            tx, provider_id=provider_id, provider_name=row["name"], mode="delete"
        )
        # provider_models / provider_keys / model_routes cascade via FK or
        # explicit deletes; providers row last.
        await tx.execute("DELETE FROM provider_models WHERE provider_id = $1", provider_id)
        await tx.execute("DELETE FROM provider_keys WHERE provider_id = $1", provider_id)
        await tx.execute("DELETE FROM model_routes WHERE provider_id = $1", provider_id)
        await tx.execute("DELETE FROM providers WHERE id = $1", provider_id)
        gen = await database.bump_generation(tx)
    cascade.nudge_if(cascade_out)  # deferred tier surgery (spec §5.3)
    audit.log("provider.delete", f"provider:{provider_id}", json.dumps(cascade_out))
    return {"ok": True, "generation": gen, "cascade": cascade_out}


@router.post("/{provider_id}/keys", status_code=201)
async def add_provider_key(provider_id: int, request: Request, user: dict = Depends(require_auth)):
    body = await request.json()
    secret = body.get("secret", "")
    weight = _parse_weight(body.get("weight", 1))

    if not isinstance(secret, str) or not secret:
        raise _err(400, "invalid", "secret required")

    provider = await database.fetchrow("SELECT id FROM providers WHERE id = $1", provider_id)
    if not provider:
        raise _err(404, "not_found", "provider not found")

    envelope = encrypt(secret.encode())
    key_id, _ = _active_key()

    async with database.transaction() as tx:
        row = await tx.fetchrow(
            "INSERT INTO provider_keys (provider_id, secret_ciphertext, key_id, weight, enabled) "
            "VALUES ($1, $2, $3, $4, 1) RETURNING id",
            provider_id,
            envelope,
            key_id,
            weight,
        )
        gen = await database.bump_generation(tx)
    audit.log("provider_key.add", f"provider:{provider_id}", f"weight={weight}")
    return {"id": row["id"], "generation": gen}


MODALITIES = {"chat", "image", "tts", "asr", "video", "computer", "embedding"}


@router.post("/{provider_id}/models", status_code=201)
async def add_provider_model(
    provider_id: int, request: Request, user: dict = Depends(require_auth)
):
    """Add an inventory listing to a provider (not agent-facing until bound)."""
    body = await request.json()
    name = _parse_name(body)
    modality = body.get("modality", "chat") or "chat"
    if not isinstance(modality, str) or modality not in MODALITIES:
        raise _err(400, "invalid", f"modality must be one of {sorted(MODALITIES)}")
    provider = await database.fetchrow(
        "SELECT id, name, protocol FROM providers WHERE id = $1", provider_id
    )
    if not provider:
        raise _err(404, "not_found", "provider not found")
    # D14: Decisions providers take MANUAL listings only (no sync —
    # sync skips them); every listing-add re-fires the D10 confirm.
    if provider["protocol"] == decisions.DECISIONS_PROTOCOL:
        decisions.require_confirm(
            body, f"adding listing '{name}' on openai_decisions provider '{provider['name']}'"
        )
    try:
        async with database.transaction() as tx:
            row = await tx.fetchrow(
                "INSERT INTO provider_models (provider_id, name, enabled, modality) "
                "VALUES ($1, $2, 1, $3) RETURNING id",
                provider_id,
                name,
                modality,
            )
            gen = await database.bump_generation(tx)
    except Exception as e:
        if isinstance(e, asyncpg.UndefinedColumnError):
            # Pre-010 gateway (rolling deploy): modality column absent —
            # retry in a FRESH transaction (the aborted one is unusable).
            try:
                async with database.transaction() as tx:
                    row = await tx.fetchrow(
                        "INSERT INTO provider_models (provider_id, name, enabled) "
                        "VALUES ($1, $2, 1) RETURNING id",
                        provider_id,
                        name,
                    )
                    gen = await database.bump_generation(tx)
            except Exception as e2:
                if isinstance(e2, asyncpg.UniqueViolationError):
                    raise _err(409, "duplicate", "listing already exists for this provider") from e2
                logger.exception(
                    "provider_model add fallback failed for provider=%s name=%r",
                    provider_id,
                    name,
                )
                raise _err(500, "db_error", "could not add listing") from e2
            audit.log(
                "provider_model.add", f"provider:{provider_id}", f"{name} (pre-modality-schema)"
            )
            if provider["protocol"] == decisions.DECISIONS_PROTOCOL:
                audit.log(
                    "decisions.grant_confirm",
                    f"provider:{provider_id}",
                    f"listing-add {name} — operator accepted Decisions billable warning",
                )
            return {"id": row["id"], "name": name, "generation": gen}
        if isinstance(e, asyncpg.UniqueViolationError):
            raise _err(409, "duplicate", "listing already exists for this provider") from e
        logger.exception("provider_model add failed for provider=%s name=%r", provider_id, name)
        raise _err(500, "db_error", "could not add listing") from e
    audit.log("provider_model.add", f"provider:{provider_id}", name)
    if provider["protocol"] == decisions.DECISIONS_PROTOCOL:
        # D10: EVERY listing-add on a Decisions provider confirms + audits
        # (dual-face names may re-fire the warning even with chat granted).
        audit.log(
            "decisions.grant_confirm",
            f"provider:{provider_id}",
            f"listing-add {name} — operator accepted Decisions billable warning",
        )
    return {"id": row["id"], "name": name, "generation": gen}


def _test_snippet(protocol: str, body) -> str:
    """Pull the assistant text out of a 2xx upstream body (any shape,
    never raises). Empty string when nothing recognizable."""
    try:
        if protocol == "anthropic_messages":
            parts = body.get("content") or []
            return "".join(p.get("text", "") for p in parts if isinstance(p, dict))
        if protocol == "openai_responses":
            out = body.get("output_text")
            if isinstance(out, str):
                return out
            parts = body.get("output") or []
            return "".join(
                c.get("text", "")
                for o in parts
                if isinstance(o, dict)
                for c in (o.get("content") or [])
                if isinstance(c, dict)
            )
        choices = body.get("choices") or []
        msg = choices[0].get("message") if choices else None
        if isinstance(msg, dict) and isinstance(msg.get("content"), str):
            return msg["content"]
        return str(choices[0].get("text", "")) if choices else ""
    except Exception:
        return ""


@router.post("/{provider_id}/models/{listing_id}/test")
async def test_provider_listing(
    provider_id: int, listing_id: int, user: dict = Depends(require_auth)
):
    """POST /api/providers/{id}/models/{listing_id}/test — one-shot
    reachability test for a single listing: protocol-correct minimal
    request (max_tokens=1 'hi') straight to the upstream with the first
    enabled key. Side-effect free — no matrix writes, no generation bump,
    no audit (read-only check that spends one completion token)."""
    provider = await database.fetchrow(
        "SELECT id, name, base_url, protocol FROM providers WHERE id = $1",
        provider_id,
    )
    if not provider:
        raise _err(404, "not_found", "provider not found")
    listing = await database.fetchrow(
        "SELECT id, name FROM provider_models WHERE id = $1 AND provider_id = $2",
        listing_id,
        provider_id,
    )
    if not listing:
        raise _err(404, "not_found", "listing not found for this provider")
    key = await database.fetchrow(
        "SELECT id, key_id, secret_ciphertext FROM provider_keys "
        "WHERE provider_id = $1 AND enabled = 1 ORDER BY id LIMIT 1",
        provider_id,
    )
    if not key:
        raise _err(400, "no_keys", "provider has no enabled key to test with")

    try:
        secret = entitlements.decrypt(bytes(key["secret_ciphertext"])).decode()
    except Exception as e:
        logger.exception("provider key decrypt failed for key id=%s", key["id"])
        raise _err(500, "decrypt_failed", "could not decrypt provider key") from e
    key_label = f"{key['key_id']}#{key['id']}"  # same label the keys drawer shows

    url, headers, body = entitlements._probe_request(
        provider["base_url"], provider["protocol"], listing["name"], secret
    )
    codes = await entitlements.load_codes()
    verify = probe_urls.tls_verify()
    started = time.monotonic()
    try:
        async with httpx.AsyncClient(timeout=20.0, verify=verify) as client:
            resp = await client.post(url, headers=headers, json=body)
    except httpx.TimeoutException:
        return {
            "ok": False,
            "kind": "error",
            "http_status": None,
            "latency_ms": int((time.monotonic() - started) * 1000),
            "key_label": key_label,
            "listing": listing["name"],
            "error_code": "timeout",
            "error_message": "upstream did not answer in 20s",
            "snippet": "",
        }
    except Exception as e:
        return {
            "ok": False,
            "kind": "error",
            "http_status": None,
            "latency_ms": int((time.monotonic() - started) * 1000),
            "key_label": key_label,
            "listing": listing["name"],
            "error_code": "transport",
            "error_message": str(e)[:200],
            "snippet": "",
        }

    latency_ms = int((time.monotonic() - started) * 1000)
    payload = {"latency_ms": latency_ms, "key_label": key_label, "listing": listing["name"]}
    if 200 <= resp.status_code < 300:
        snippet = _test_snippet(provider["protocol"], entitlements._safe_json(resp))
        return {
            **payload,
            "ok": True,
            "kind": "ok",
            "http_status": resp.status_code,
            "error_code": None,
            "error_message": None,
            "snippet": snippet[:120],
        }
    code, message = entitlements.extract_error_fields(entitlements._safe_json(resp))
    message = (message or "")[:200]
    if resp.status_code in (401, 403):
        kind = "broken"
    elif resp.status_code >= 500:
        kind = "error"
    else:
        kind = entitlements.classify(provider["name"], resp.status_code, code, message, codes)
    return {
        **payload,
        "ok": False,
        "kind": kind,
        "http_status": resp.status_code,
        "error_code": code,
        "error_message": message,
        "snippet": "",
    }


@router.post("/{provider_id}/keys/{key_id}/probe")
async def probe_provider_key(provider_id: int, key_id: int, user: dict = Depends(require_auth)):
    """POST /api/providers/{id}/keys/{key_id}/probe — SYNCHRONOUS single-key
    entitlement probe (spec A.2, bounded ~2-4 min). Single-flight per
    provider via the Postgres advisory lock: 409 when a batch is running.
    Probes spend real money — every batch is audited."""
    provider = await database.fetchrow("SELECT id, name FROM providers WHERE id = $1", provider_id)
    if not provider:
        raise _err(404, "not_found", "provider not found")
    key = await database.fetchrow(
        "SELECT id, provider_id FROM provider_keys WHERE id = $1 AND provider_id = $2",
        key_id,
        provider_id,
    )
    if not key:
        raise _err(404, "not_found", "key not found for this provider")

    result = await entitlements.execute_batch(
        entitlements.Job(provider_id=provider_id, key_ids=[key_id], trigger="manual")
    )
    if result.get("skipped") == "lock_busy":
        raise _err(
            409,
            "probe_in_progress",
            "another entitlement probe holds this provider's lock — retry shortly",
        )
    if result.get("skipped") == "no_keys":
        raise _err(404, "not_found", "key not found or disabled")
    return result


@router.post("/{provider_id}/probe", status_code=202)
async def probe_provider(provider_id: int, user: dict = Depends(require_auth)):
    """POST /api/providers/{id}/probe — ASYNC provider-wide entitlement
    probe (spec A.2): validate, enqueue, return 202 {queued}. The SPA
    polls GET /api/entitlements until the batch lands."""
    provider = await database.fetchrow("SELECT id, name FROM providers WHERE id = $1", provider_id)
    if not provider:
        raise _err(404, "not_found", "provider not found")
    keys = await database.fetchval(
        "SELECT COUNT(*) FROM provider_keys WHERE provider_id = $1 AND enabled = 1",
        provider_id,
    )
    if not keys:
        raise _err(400, "no_keys", "provider has no enabled keys to probe")
    entitlements.enqueue(entitlements.Job(provider_id=provider_id, trigger="manual"))
    return {"queued": True, "provider": provider["name"], "keys": keys}
