"""Agent API key CRUD endpoints."""

import logging
import math
import time
from collections import defaultdict
from decimal import Decimal

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse

from .. import audit, database, decisions
from ..auth import _client_ip, require_auth
from ..crypto import _active_key, decrypt, encrypt, generate_agent_key, hash_agent_key

router = APIRouter()
logger = logging.getLogger("janus.dashboard.keys")

JANUS_AUTO = "janus-auto"

# Schema probe cache (positive and negative); never forever across mid-process mig.
_SCHEMA_PROBE_TTL_SEC = 60.0
_schema_probe_at: float | None = None
_schema_probe_ok: bool = False

# Reveal rate limit: 30/min per login session (JWT sub+jti; else client IP).
_REVEAL_LIMIT = 30
_REVEAL_WINDOW_SEC = 60.0
_reveal_hits: dict[str, list[float]] = defaultdict(list)

_REVEAL_HEADERS = {"Cache-Control": "no-store", "Pragma": "no-cache"}
_CREATE_HEADERS = {"Cache-Control": "no-store"}


def _err(
    status: int,
    code: str,
    message: str,
    *,
    headers: dict | None = None,
    **extra,
) -> HTTPException:
    body = {"error": {"code": code, "message": message}}
    if extra:
        body["error"].update(extra)
    return HTTPException(status, detail=body, headers=headers)


def _require_keyring() -> None:
    """Fail closed when JANUS_SECRETS_KEY has no usable write key."""
    try:
        _active_key()
    except Exception:
        raise _err(
            503,
            "keyring_unconfigured",
            "JANUS_SECRETS_KEY is not configured",
        )


async def _secret_column_ready() -> bool:
    """True when api_keys.secret_ciphertext exists. Cached TTL 60s."""
    global _schema_probe_at, _schema_probe_ok
    now = time.monotonic()
    if _schema_probe_at is not None and (now - _schema_probe_at) < _SCHEMA_PROBE_TTL_SEC:
        return _schema_probe_ok
    try:
        row = await database.fetchrow(
            """
            SELECT 1 AS ok
            FROM information_schema.columns
            WHERE table_schema = current_schema()
              AND table_name = 'api_keys'
              AND column_name = 'secret_ciphertext'
            """
        )
        ready = row is not None
    except Exception:
        ready = False
    _schema_probe_at = now
    _schema_probe_ok = ready
    return ready


def _check_reveal_rate(bucket: str) -> None:
    """In-memory 30/min. Limiter bugs → 503 limiter_unavailable (not a fake 429)."""
    try:
        now = time.monotonic()
        # Prune this bucket and drop empty peers so keys cannot grow unboundedly.
        stale = [
            k
            for k, ts in _reveal_hits.items()
            if k != bucket and not any(now - t < _REVEAL_WINDOW_SEC for t in ts)
        ]
        for k in stale:
            _reveal_hits.pop(k, None)
        hits = [t for t in _reveal_hits[bucket] if now - t < _REVEAL_WINDOW_SEC]
        if len(hits) >= _REVEAL_LIMIT:
            _reveal_hits[bucket] = hits
            raise _err(
                429,
                "rate_limited",
                "reveal rate limit exceeded; try again later",
                retry_after=60,
                headers={**_REVEAL_HEADERS, "Retry-After": "60"},
            )
        hits.append(now)
        _reveal_hits[bucket] = hits
    except HTTPException:
        raise
    except Exception:
        raise _err(
            503,
            "limiter_unavailable",
            "reveal rate limiter unavailable",
            headers=dict(_REVEAL_HEADERS),
        )


def _parse_reveal_key_id(raw: str) -> int | None:
    """Validated api_keys.id only; non-integer / non-positive → None (404)."""
    try:
        kid = int(raw)
    except (TypeError, ValueError):
        return None
    if kid < 1 or str(kid) != raw:
        return None
    return kid


def _reveal_audit(
    target_id: int | str,
    outcome: str,
    *,
    prefix: str | None = None,
    sub: str | None = None,
) -> None:
    """Audit every reveal attempt; never plaintext. not_found has no prefix."""
    parts: list[str] = []
    if sub:
        parts.append(f"sub={sub}")
    if outcome != "not_found" and prefix is not None:
        parts.append(f"{prefix}…")
    parts.append(f"outcome={outcome}")
    audit.log("agent_key.reveal", f"agent_key:{target_id}", " ".join(parts))


def _as_bool(val) -> bool:
    """Coerce Postgres bool / SQLite 0/1 to JSON bool."""
    return bool(val)


def _parse_limit(body: dict, field: str):
    """Optional positive int, or null/omit = unlimited. Rejects 0 and negatives."""
    if field not in body:
        return None  # omit on create → SQL NULL
    val = body[field]
    if val is None:
        return None
    if isinstance(val, bool) or not isinstance(val, int) or val < 1:
        raise _err(400, "invalid", f"{field} must be a positive integer or null")
    return val


COMMENT_MAX = 500


def _parse_comment(body: dict, *, required_key: bool = False):
    """Optional free-text note. Trim; empty/`null` → SQL NULL. Max 500 chars."""
    if "comment" not in body:
        if required_key:
            raise _err(400, "invalid", "comment is required")
        return None  # omit on create → SQL NULL
    val = body["comment"]
    if val is None:
        return None
    if not isinstance(val, str):
        raise _err(400, "invalid", "comment must be a string or null")
    trimmed = val.strip()
    if not trimmed:
        return None
    if len(trimmed) > COMMENT_MAX:
        raise _err(
            400,
            "invalid",
            f"comment must be at most {COMMENT_MAX} characters",
        )
    return trimmed


async def _set_comment_if_changed(tx, key_id: int, old_comment, new_comment) -> bool:
    """Persist comment when it differs from the locked row. Returns True if written."""
    if old_comment == new_comment:
        return False
    await tx.execute(
        "UPDATE api_keys SET comment = $2 WHERE id = $1",
        key_id,
        new_comment,
    )
    return True


def _audit_comment(key_id: int, prefix: str, comment) -> None:
    audit.log(
        "agent_key.comment",
        f"agent_key:{key_id}",
        f"{prefix}… comment={comment!r}",
    )


def _normalize_model_names(raw) -> list[str]:
    """Non-empty strings only; reject janus-auto; dedupe + sort ascending."""
    if not isinstance(raw, list):
        raise _err(400, "invalid", "model_names must be a list")
    out: list[str] = []
    seen: set[str] = set()
    for name in raw:
        if not isinstance(name, str) or not name.strip():
            raise _err(
                400,
                "invalid",
                f"model_names entries must be non-empty strings, got {name!r}",
            )
        n = name.strip()
        if n == JANUS_AUTO:
            raise _err(
                400,
                "invalid",
                "janus-auto is only available to unrestricted keys; "
                "remove it from the grant list or choose All models",
            )
        if n not in seen:
            seen.add(n)
            out.append(n)
    out.sort()
    return out


async def _names_from_legacy_ids(model_ids: list[int]) -> list[str]:
    """Compat: resolve model_ids body to names (pre-name-grant clients)."""
    if not model_ids:
        return []
    placeholders = ", ".join(f"${i + 1}" for i in range(len(model_ids)))
    rows = await database.fetch(
        f"SELECT id, name FROM models WHERE id IN ({placeholders})", *model_ids
    )
    by_id = {r["id"]: r["name"] for r in rows}
    if len(by_id) != len(set(model_ids)):
        raise _err(400, "invalid", "one or more model_ids do not exist")
    names = [by_id[i] for i in model_ids if i in by_id]
    return _normalize_model_names(names)


def _normalize_model_ids_legacy(raw) -> list[int]:
    if not isinstance(raw, list):
        raise _err(400, "invalid", "model_ids must be a list")
    out: list[int] = []
    seen: set[int] = set()
    for mid in raw:
        if isinstance(mid, bool) or not isinstance(mid, int) or mid < 1:
            raise _err(
                400,
                "invalid",
                f"model_ids entries must be positive integers, got {mid!r}",
            )
        if mid not in seen:
            seen.add(mid)
            out.append(mid)
    out.sort()
    return out


async def _parse_grant_body(body: dict, *, required: bool) -> list[str]:
    """Prefer model_names; fall back to model_ids for one-release compat."""
    if "model_names" in body and body["model_names"] is not None:
        return _normalize_model_names(body["model_names"])
    if "model_ids" in body and body["model_ids"] is not None:
        return await _names_from_legacy_ids(_normalize_model_ids_legacy(body["model_ids"]))
    if required:
        raise _err(400, "invalid", "model_names is required")
    return []


async def _require_names_grantable(
    names: list[str],
    conn=None,
    *,
    grandfather: set[str] | None = None,
) -> None:
    """Each name must appear in models or provider_models (any enabled state).

    ``grandfather`` = names already on this key (PATCH). Orphan grants stay
    re-saveable after a listing/Router row vanishes (design §4.4).
    """
    if not names:
        return
    placeholders = ", ".join(f"${i + 1}" for i in range(len(names)))
    # Reuse $1..$n in both IN clauses (Postgres allows repeated params).
    sql = f"""
        SELECT name FROM (
            SELECT name FROM models WHERE name IN ({placeholders})
            UNION
            SELECT name FROM provider_models WHERE name IN ({placeholders})
        ) t
    """
    if conn is None:
        rows = await database.fetch(sql, *names)
    else:
        rows = await conn.fetch(sql, *names)
    found = {r["name"] for r in rows}
    allowed = found | (grandfather or set())
    missing = [n for n in names if n not in allowed]
    if missing:
        raise _err(
            400,
            "invalid",
            f"unknown model name(s): {', '.join(missing)}",
        )


async def _current_grants(conn, key_id: int) -> list[str]:
    rows = await conn.fetch(
        "SELECT model_name FROM api_key_models WHERE api_key_id = $1 ORDER BY model_name",
        key_id,
    )
    return [r["model_name"] for r in rows]


def _scope_summary(names: list[str]) -> str:
    return "all models" if not names else f"{len(names)} model(s)"


def _decisions_confirmed(body: dict) -> bool:
    return body.get("decisions_confirmed") is True


@router.get("/grantable-models")
async def grantable_models(user: dict = Depends(require_auth)):
    """Distinct public names for the restrict picker (excludes
    janus-auto), each tagged with its source: `bound` (a models-table
    public name) or `listing` (a synced provider listing only). A name
    present in BOTH reports `bound` (DISTINCT ON keeps it).

    ``providers`` lists every provider that exposes the name via a
    listing and/or a Router binding — display-only; grants stay by name.
    """
    rows = await database.fetch(
        """
        WITH name_src AS (
            SELECT DISTINCT ON (name) name, source FROM (
                SELECT name, 'bound'::text AS source FROM models WHERE name <> $1
                UNION ALL
                SELECT name, 'listing'::text AS source FROM provider_models
                WHERE name <> $1
            ) t
            ORDER BY name, source
        ),
        prov AS (
            SELECT name, array_agg(DISTINCT pname ORDER BY pname) AS providers
            FROM (
                SELECT pm.name AS name, p.name AS pname
                FROM provider_models pm
                JOIN providers p ON p.id = pm.provider_id
                WHERE pm.name <> $1
                UNION
                SELECT m.name AS name, p.name AS pname
                FROM models m
                JOIN model_routes mr ON mr.model_id = m.id
                JOIN providers p ON p.id = mr.provider_id
                WHERE m.name <> $1
            ) u
            GROUP BY name
        )
        SELECT n.name, n.source, COALESCE(pr.providers, '{}'::text[]) AS providers
        FROM name_src n
        LEFT JOIN prov pr ON pr.name = n.name
        ORDER BY n.name
        """,
        JANUS_AUTO,
    )
    return {
        "models": [
            {
                "name": r["name"],
                "source": r["source"],
                "providers": list(r["providers"] or []),
            }
            for r in rows
        ]
    }


@router.get("")
async def list_keys(user: dict = Depends(require_auth)):
    # Explicit columns only — never SELECT * / never return ciphertext or key.
    # Before mig 024, omit the column rather than 500 (has_secret=false).
    secret_ready = await _secret_column_ready()
    if secret_ready:
        keys = await database.fetch(
            "SELECT id, prefix, enabled, created_at, rpm_limit, tpm_limit, "
            "daily_token_limit, comment, "
            "(secret_ciphertext IS NOT NULL) AS has_secret "
            "FROM api_keys ORDER BY id"
        )
    else:
        keys = await database.fetch(
            "SELECT id, prefix, enabled, created_at, rpm_limit, tpm_limit, "
            "daily_token_limit, comment "
            "FROM api_keys ORDER BY id"
        )
    grants = await database.fetch(
        "SELECT api_key_id, model_name FROM api_key_models ORDER BY api_key_id, model_name"
    )

    grants_by_key: dict[int, list[str]] = {}
    for g in grants:
        grants_by_key.setdefault(g["api_key_id"], []).append(g["model_name"])

    out = []
    for k in keys:
        names = grants_by_key.get(k["id"], [])
        out.append(
            {
                "id": k["id"],
                "prefix": k["prefix"],
                "enabled": bool(k["enabled"]),
                "created_at": str(k["created_at"]),
                # No grants = unrestricted: the gateway authenticates the key
                # and allows every model (deployer decision).
                "model_names": names if names else "all",
                "rpm_limit": k.get("rpm_limit"),
                "tpm_limit": k.get("tpm_limit"),
                "daily_token_limit": k.get("daily_token_limit"),
                "comment": k.get("comment"),
                "has_secret": _as_bool(k.get("has_secret")) if secret_ready else False,
            }
        )
    return {"keys": out}


@router.post("", status_code=201)
async def create_key(request: Request, user: dict = Depends(require_auth)):
    body = await request.json()
    # omit / null / missing → unrestricted (empty list)
    if "model_names" not in body and "model_ids" not in body:
        model_names: list[str] = []
    elif body.get("model_names") is None and body.get("model_ids") is None:
        model_names = []
    else:
        model_names = await _parse_grant_body(body, required=False)

    intersecting: list[dict] = []
    if model_names:
        await _require_names_grantable(model_names)
        intersecting = await decisions.intersecting_decisions_models(model_names)
        if intersecting and not _decisions_confirmed(body):
            names = ", ".join(f"{m['name']} ({m['via']})" for m in intersecting)
            raise _err(
                409,
                "decisions_confirm_required",
                f"granted models reach openai_decisions providers: {names}. "
                f"Decisions calls are billed per decision upstream and are NOT "
                f"covered by chat token grants — send decisions_confirmed=true",
            )

    rpm_limit = _parse_limit(body, "rpm_limit")
    tpm_limit = _parse_limit(body, "tpm_limit")
    daily_token_limit = _parse_limit(body, "daily_token_limit")
    comment = _parse_comment(body)

    # Create order: keyring → schema probe → encrypt → single INSERT.
    _require_keyring()
    if not await _secret_column_ready():
        raise _err(
            503,
            "schema_not_ready",
            "api_keys.secret_ciphertext column is not available",
        )

    raw_key = None
    prefix = None
    key_hash = None
    key_id = None
    gen = None
    last_err = None
    for _ in range(8):
        raw_key = generate_agent_key()
        prefix, key_hash = hash_agent_key(raw_key)
        try:
            ciphertext = encrypt(raw_key.encode())
        except Exception as e:
            # No row, no plaintext in the error body.
            raise _err(503, "encrypt_failed", "could not encrypt agent key") from e
        try:
            async with database.transaction() as tx:
                row = await tx.fetchrow(
                    "INSERT INTO api_keys (prefix, key_hash, enabled, rpm_limit, tpm_limit, "
                    "daily_token_limit, comment, secret_ciphertext) "
                    "VALUES ($1, $2, 1, $3, $4, $5, $6, $7) RETURNING id",
                    prefix,
                    key_hash,
                    rpm_limit,
                    tpm_limit,
                    daily_token_limit,
                    comment,
                    ciphertext,
                )
                key_id = row["id"]
                for name in model_names:
                    await tx.execute(
                        "INSERT INTO api_key_models (api_key_id, model_name) VALUES ($1, $2)",
                        key_id,
                        name,
                    )
                gen = await database.bump_generation(tx)
            last_err = None
            break
        except Exception as e:
            last_err = e
            # Retry only a genuine api_keys.prefix collision. Any other
            # unique violation (e.g. the api_key_models grant key) is not
            # fixed by a new prefix and must not burn the retry budget.
            if isinstance(e, asyncpg.UniqueViolationError) and (
                getattr(e, "constraint_name", None) or ""
            ).endswith("api_keys_prefix_uidx"):
                continue
            # Prefix collision / DB error after encrypt: no plaintext in body.
            logger.exception("agent key create failed for prefix=%s", prefix)
            raise _err(500, "db_error", "could not create agent key") from e
    if last_err is not None:
        raise _err(500, "db_error", "could not allocate a unique agent key prefix")

    scope = _scope_summary(model_names)
    note = f" comment={comment!r}" if comment else ""
    audit.log("agent_key.create", f"agent_key:{key_id}", f"{prefix}… {scope}{note}")
    if intersecting:
        names = ", ".join(f"{m['name']} ({m['via']})" for m in intersecting)
        audit.log(
            "decisions.grant_confirm",
            f"agent_key:{key_id}",
            f"grant-write {names} — operator accepted Decisions billable warning",
        )

    return JSONResponse(
        status_code=201,
        headers=dict(_CREATE_HEADERS),
        content={
            "key": raw_key,
            "prefix": prefix,
            "id": key_id,
            "model_names": model_names if model_names else "all",
            "rpm_limit": rpm_limit,
            "tpm_limit": tpm_limit,
            "daily_token_limit": daily_token_limit,
            "comment": comment,
            "has_secret": True,
            "generation": gen,
        },
    )


@router.patch("/{key_id}/models")
async def update_key_models(key_id: int, request: Request, user: dict = Depends(require_auth)):
    """Full-replace agent-key model allowlist (empty = unrestricted).

    Optional ``comment`` in the same body updates the operator note in the
    same transaction (avoids a partial models-ok / comment-fail save).
    """
    body = await request.json()
    if "model_names" not in body and "model_ids" not in body:
        raise _err(400, "invalid", "model_names is required")
    if body.get("model_names") is None and body.get("model_ids") is None:
        raise _err(400, "invalid", "model_names must be a list")
    new_names = await _parse_grant_body(body, required=True)
    comment_in_body = "comment" in body
    comment = _parse_comment(body) if comment_in_body else None

    intersecting: list[dict] = []
    old_names: list[str] = []
    prefix = ""
    changed = False
    comment_changed = False
    out_comment = None
    secret_ready = await _secret_column_ready()
    has_secret = False
    gen = 0
    # D10 before the locked tx — pool read, not a second conn under FOR UPDATE.
    intersecting_pre: list[dict] = []
    if new_names:
        intersecting_pre = await decisions.intersecting_decisions_models(new_names)
    async with database.transaction() as tx:
        if secret_ready:
            key = await tx.fetchrow(
                "SELECT id, prefix, comment, "
                "(secret_ciphertext IS NOT NULL) AS has_secret "
                "FROM api_keys WHERE id = $1 FOR UPDATE",
                key_id,
            )
        else:
            key = await tx.fetchrow(
                "SELECT id, prefix, comment FROM api_keys WHERE id = $1 FOR UPDATE",
                key_id,
            )
        if key is None:
            raise _err(404, "not_found", "key not found")
        prefix = key["prefix"]
        out_comment = key.get("comment")
        has_secret = _as_bool(key.get("has_secret")) if secret_ready else False
        old_names = await _current_grants(tx, key_id)

        if new_names:
            await _require_names_grantable(new_names, tx, grandfather=set(old_names))

        # Clear path: scoped → unrestricted needs explicit confirm.
        if not new_names and old_names and body.get("confirm_unrestricted") is not True:
            raise _err(
                409,
                "confirm_unrestricted_required",
                "clearing grants makes this key unrestricted; send confirm_unrestricted=true",
            )

        changed = old_names != new_names
        if changed and new_names:
            intersecting = intersecting_pre
            if intersecting and not _decisions_confirmed(body):
                names = ", ".join(f"{m['name']} ({m['via']})" for m in intersecting)
                raise _err(
                    409,
                    "decisions_confirm_required",
                    f"granted models reach openai_decisions providers: {names}. "
                    f"Decisions calls are billed per decision upstream and are NOT "
                    f"covered by chat token grants — send decisions_confirmed=true",
                )

        if comment_in_body:
            comment_changed = await _set_comment_if_changed(tx, key_id, key.get("comment"), comment)
            out_comment = comment

        if not changed:
            gen = await database.current_generation()
        else:
            await tx.execute("DELETE FROM api_key_models WHERE api_key_id = $1", key_id)
            for name in new_names:
                await tx.execute(
                    "INSERT INTO api_key_models (api_key_id, model_name) VALUES ($1, $2)",
                    key_id,
                    name,
                )
            gen = await database.bump_generation(tx)

    if changed:
        audit.log(
            "agent_key.models",
            f"agent_key:{key_id}",
            f"{prefix}… {_scope_summary(old_names)} → {_scope_summary(new_names)}",
        )
        if intersecting:
            inames = ", ".join(f"{m['name']} ({m['via']})" for m in intersecting)
            audit.log(
                "decisions.grant_confirm",
                f"agent_key:{key_id}",
                f"grant-write {inames} — operator accepted Decisions billable warning",
            )
    if comment_changed:
        _audit_comment(key_id, prefix, comment)

    return {
        "id": key_id,
        "model_names": new_names if new_names else "all",
        "generation": gen,
        "comment": out_comment,
        "has_secret": has_secret,
    }


@router.patch("/{key_id}")
async def update_key(key_id: int, request: Request, user: dict = Depends(require_auth)):
    """Update operator metadata (comment). Does not bump catalog generation."""
    body = await request.json()
    comment = _parse_comment(body, required_key=True)
    comment_changed = False
    prefix = ""
    secret_ready = await _secret_column_ready()
    has_secret = False
    async with database.transaction() as tx:
        if secret_ready:
            row = await tx.fetchrow(
                "SELECT id, prefix, comment, "
                "(secret_ciphertext IS NOT NULL) AS has_secret "
                "FROM api_keys WHERE id = $1 FOR UPDATE",
                key_id,
            )
        else:
            row = await tx.fetchrow(
                "SELECT id, prefix, comment FROM api_keys WHERE id = $1 FOR UPDATE",
                key_id,
            )
        if row is None:
            raise _err(404, "not_found", "key not found")
        prefix = row["prefix"]
        has_secret = _as_bool(row.get("has_secret")) if secret_ready else False
        comment_changed = await _set_comment_if_changed(tx, key_id, row.get("comment"), comment)
    if comment_changed:
        _audit_comment(key_id, prefix, comment)
    return {"id": key_id, "comment": comment, "has_secret": has_secret}


@router.patch("/{key_id}/limits")
async def update_key_limits(key_id: int, request: Request, user: dict = Depends(require_auth)):
    """Set rpm_limit / tpm_limit / daily_token_limit / daily_cost_limit
    (null = unlimited). daily_cost_limit is the H8-D3 display-only daily
    priced-spend budget (WARN alert, never enforced); the gateway does
    not read it."""
    body = await request.json()
    limit_fields = ("rpm_limit", "tpm_limit", "daily_token_limit", "daily_cost_limit")
    if not any(k in body for k in limit_fields):
        raise _err(400, "invalid", "no limit fields in body")
    unknown = set(body) - set(limit_fields)
    if unknown:
        raise _err(400, "invalid", f"unknown fields: {sorted(unknown)}")
    # Load current so omitted fields are unchanged.
    row = await database.fetchrow(
        "SELECT rpm_limit, tpm_limit, daily_token_limit, daily_cost_limit "
        "FROM api_keys WHERE id = $1",
        key_id,
    )
    if row is None:
        raise _err(404, "not_found", "key not found")
    rpm = _parse_limit(body, "rpm_limit") if "rpm_limit" in body else row["rpm_limit"]
    tpm = _parse_limit(body, "tpm_limit") if "tpm_limit" in body else row["tpm_limit"]
    daily = (
        _parse_limit(body, "daily_token_limit")
        if "daily_token_limit" in body
        else row["daily_token_limit"]
    )
    # H8-D3: numeric (not token) budget — Decimal in, null = none.
    # JSON numbers only (str bodies would smuggle NaN/Inf spellings).
    if "daily_cost_limit" in body:
        val = body["daily_cost_limit"]
        if val is None:
            cost = None
        elif (
            isinstance(val, bool)
            or not isinstance(val, (int, float))
            or not math.isfinite(val)
            or val < 0
        ):
            raise _err(400, "invalid", "daily_cost_limit must be a non-negative number or null")
        else:
            cost = Decimal(str(val))
    else:
        cost = row["daily_cost_limit"]
    async with database.transaction() as tx:
        result = await tx.execute(
            "UPDATE api_keys SET rpm_limit = $2, tpm_limit = $3, daily_token_limit = $4, "
            "daily_cost_limit = $5 WHERE id = $1",
            key_id,
            rpm,
            tpm,
            daily,
            cost,
        )
        if result == "UPDATE 0":
            raise _err(404, "not_found", "key not found")
        gen = await database.bump_generation(tx)
    audit.log(
        "agent_key.limits",
        f"agent_key:{key_id}",
        f"rpm={rpm} tpm={tpm} daily={daily} daily_cost={cost}",
    )
    return {
        "ok": True,
        "generation": gen,
        "rpm_limit": rpm,
        "tpm_limit": tpm,
        "daily_token_limit": daily,
        "daily_cost_limit": float(cost) if cost is not None else None,
    }


@router.get("/{key_id}/secret")
async def reveal_key_secret(key_id: str, request: Request, user: dict = Depends(require_auth)):
    """Reveal recoverable agent-key plaintext (JSEC decrypt).

    Check order: auth → rate limit → schema probe → load row → decrypt.
    Disabled keys are revealable; hard-deleted keys 404. Never caches.
    """
    sub = user.get("sub") if isinstance(user.get("sub"), str) else None
    # create_token mints a per-session jti, so the limiter budget is per
    # login session rather than one global "sub:dashboard" bucket. Tokens
    # issued before jti existed fall back to the shared sub bucket.
    jti = user.get("jti") if isinstance(user.get("jti"), str) else None
    if sub and jti:
        bucket = f"sub:{sub}:{jti}"
    elif sub:
        bucket = f"sub:{sub}"
    else:
        bucket = f"ip:{_client_ip(request)}"

    # Rate limit before parsing so invalid paths still share the bucket.
    try:
        _check_reveal_rate(bucket)
    except HTTPException as exc:
        detail = exc.detail if isinstance(exc.detail, dict) else {}
        code = (detail.get("error") or {}).get("code", "limiter_unavailable")
        parsed = _parse_reveal_key_id(key_id)
        _reveal_audit(
            parsed if parsed is not None else "invalid",
            code,
            sub=sub,
        )
        raise

    if not await _secret_column_ready():
        parsed = _parse_reveal_key_id(key_id)
        _reveal_audit(
            parsed if parsed is not None else "invalid",
            "schema_not_ready",
            sub=sub,
        )
        raise _err(
            503,
            "schema_not_ready",
            "api_keys.secret_ciphertext column is not available",
            headers=dict(_REVEAL_HEADERS),
        )

    kid = _parse_reveal_key_id(key_id)
    if kid is None:
        _reveal_audit("invalid", "not_found", sub=sub)
        raise _err(404, "not_found", "key not found", headers=dict(_REVEAL_HEADERS))

    row = await database.fetchrow(
        "SELECT id, prefix, secret_ciphertext FROM api_keys WHERE id = $1",
        kid,
    )
    if row is None:
        _reveal_audit(kid, "not_found", sub=sub)
        raise _err(404, "not_found", "key not found", headers=dict(_REVEAL_HEADERS))

    prefix = row["prefix"]
    ciphertext = row["secret_ciphertext"]
    if ciphertext is None:
        _reveal_audit(kid, "secret_unavailable", prefix=prefix, sub=sub)
        raise _err(
            409,
            "secret_unavailable",
            "key secret is not recoverable; revoke and create a new key",
            headers=dict(_REVEAL_HEADERS),
        )

    try:
        _require_keyring()
    except HTTPException:
        _reveal_audit(kid, "keyring_unconfigured", prefix=prefix, sub=sub)
        raise _err(
            503,
            "keyring_unconfigured",
            "JANUS_SECRETS_KEY is not configured",
            headers=dict(_REVEAL_HEADERS),
        )

    try:
        plaintext = decrypt(bytes(ciphertext)).decode()
    except Exception:
        # Generic client body; server log may include envelope kid.
        logger.exception("agent key reveal decrypt failed for id=%s", kid)
        _reveal_audit(kid, "decrypt_failed", prefix=prefix, sub=sub)
        raise _err(
            500,
            "decrypt_failed",
            "could not decrypt agent key",
            headers=dict(_REVEAL_HEADERS),
        )

    _reveal_audit(kid, "ok", prefix=prefix, sub=sub)
    return JSONResponse(
        content={"key": plaintext},
        headers=dict(_REVEAL_HEADERS),
    )


@router.post("/{key_id}/disable")
async def disable_key(key_id: int, user: dict = Depends(require_auth)):
    async with database.transaction() as tx:
        result = await tx.execute("UPDATE api_keys SET enabled = 0 WHERE id = $1", key_id)
        if result == "UPDATE 0":
            raise _err(404, "not_found", "key not found")
        gen = await database.bump_generation(tx)
    audit.log("agent_key.disable", f"agent_key:{key_id}")
    return {"ok": True, "generation": gen}


@router.post("/{key_id}/enable")
async def enable_key(key_id: int, user: dict = Depends(require_auth)):
    async with database.transaction() as tx:
        result = await tx.execute("UPDATE api_keys SET enabled = 1 WHERE id = $1", key_id)
        if result == "UPDATE 0":
            raise _err(404, "not_found", "key not found")
        gen = await database.bump_generation(tx)
    audit.log("agent_key.enable", f"agent_key:{key_id}")
    return {"ok": True, "generation": gen}


@router.delete("/{key_id}")
async def delete_key(key_id: int, user: dict = Depends(require_auth)):
    async with database.transaction() as tx:
        await tx.execute("DELETE FROM api_key_models WHERE api_key_id = $1", key_id)
        result = await tx.execute("DELETE FROM api_keys WHERE id = $1", key_id)
        if result == "DELETE 0":
            raise _err(404, "not_found", "key not found")
        gen = await database.bump_generation(tx)
    audit.log("agent_key.delete", f"agent_key:{key_id}")
    return {"ok": True, "generation": gen}
