"""Restore preflight, dry-run plan, and locked apply (spec §5.3–§5.4).

Dry-run reads one REPEATABLE READ snapshot and returns a plan. It takes
no advisory locks and writes nothing, including audit rows.

``apply=1`` reuses that unlocked preflight, then (after the decisions
probe has released every pool connection) checks out one connection,
takes the C12 session try-locks, and writes inside REPEATABLE READ.
Session advisory locks need a direct Postgres connection. A
transaction-mode pooler drops them silently. The dashboard pool is
already direct; the apply path must stay that way.
"""

import asyncio
import base64
import json
import logging
import socket
import struct
from dataclasses import dataclass, field
from datetime import datetime

import asyncpg
from fastapi import HTTPException, Request
from jsonschema.exceptions import SchemaError

from . import database, decisions
from .auto_reorder import ADVISORY_XACT_KEY
from .auto_router_rules import TIERS, validate_tiers_master_parity
from .config import config
from .config_backup_canon import derive_key_ids, payload_sha256, sort_document_arrays
from .config_backup_export import pepper_canary_hash
from .config_backup_migrations import required_migrations_for
from .config_backup_schema import load_schema
from .crypto import MAGIC, _keyring, decrypt

logger = logging.getLogger("janus.dashboard.config_backup")

_CANARY_PLAINTEXT = b"janus-config-backup-canary-v1"
_WARNING_CAP = 20
_SCHEMA_ERROR_CAP = 8
_QUERY_PARAMS = frozenset({"mode", "apply", "confirm", "allow_foreign_keys"})
_CONFIRM_MEMBERS = ("apply", "replace", "allow_foreign_keys")
_CONFIRM_OK = frozenset(_CONFIRM_MEMBERS)
_MODES = frozenset({"merge", "replace"})
_FLAG_VALUES = frozenset({"0", "1"})
_SECTIONS = (
    "providers",
    "provider_keys",
    "listings",
    "models",
    "routes",
    "agent_keys",
    "grants",
    "auto_router",
    "auto_router_reorder",
)
_TIMEOUT_SQLSTATES = frozenset({"57014", "25P03"})
# Serialization failure, unique violation, deadlock. A concurrent
# non-restore writer surfaces as one of these under REPEATABLE READ.
_CONFLICT_SQLSTATES = frozenset({"40001", "23505", "40P01"})
# C12 restore session lock. 90110011 is auto_reorder.ADVISORY_XACT_KEY
# (shared lock space with the reorder loop's transaction lock).
RESTORE_ADVISORY_LOCK = 90110015
_APPLY_COMMAND_TIMEOUT = 120
_NAME_GRANTS = "022_api_key_model_names"
_VALIDATOR = None

# PUT /api/settings/auto-router integer floors (C7 reuses that contract).
_ROUTER_INT_MIN = {
    "fast_ctx_tokens": 1,
    "big_ctx_tokens": 1,
    "max_ctx_tokens": 1,
    "judge_timeout_ms": 100,
    "cache_ttl_sec": 1,
}


class RestoreError(Exception):
    """Preflight refusal. ``status``/``code`` become ``{error:{code,message}}``."""

    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code


@dataclass(frozen=True)
class RestoreQuery:
    mode: str
    apply: bool
    allow_foreign_keys: bool
    confirm: frozenset[str]


@dataclass
class _Counts:
    insert: int = 0
    update: int = 0
    explicit: int = 0
    cascade: int = 0
    unchanged: int = 0

    def as_dict(self) -> dict:
        return {
            "insert": self.insert,
            "update": self.update,
            "delete": {"explicit": self.explicit, "cascade": self.cascade},
            "unchanged": self.unchanged,
        }

    def writes(self) -> bool:
        return bool(self.insert or self.update or self.explicit or self.cascade)


@dataclass
class Plan:
    mode: str
    sections: dict
    warnings: list[str]
    generation: int
    would_noop: bool
    # Snapshot the plan was built from. Apply reads it; dry-run ignores it.
    # Default None so a plan built without a catalog fails the apply guard
    # instead of raising AttributeError.
    catalog: "_Catalog | None" = None

    def to_response(self) -> dict:
        body = {
            "mode": self.mode,
            "apply": False,
            "sections": self.sections,
            "warnings": self.warnings,
            "generation": self.generation,
        }
        if self.would_noop:
            body["would_noop"] = True
        return body

    def to_apply_response(self, *, generation: int | None, source_config_generation: int) -> dict:
        """Executed plan. ``noop`` is present only when true; ``generation``
        is the post-bump value and is absent on a no-op (C5)."""
        body = {
            "mode": self.mode,
            "apply": True,
            "sections": self.sections,
            "warnings": self.warnings,
            "source_config_generation": source_config_generation,
        }
        if generation is None:
            body["noop"] = True
        else:
            body["generation"] = generation
        return body


@dataclass
class _Catalog:
    generation: int
    migrations: list[str]
    providers: list[dict]
    models: list[dict]
    routes: list[dict]
    agent_keys: list[dict]
    auto_router: dict | None
    auto_router_reorder: dict | None
    lead_warnings: list[str] = field(default_factory=list)


def parse_query(request: Request) -> RestoreQuery:
    """Query contract (§5.3). Validity always; requiredness only when apply=1.

    Parse failures (unknown, duplicate, empty, irrelevant) are
    ``mode_invalid`` and win over a missing required ``confirm`` member.
    """
    seen: set[str] = set()
    for key, _value in request.query_params.multi_items():
        if key in seen:
            raise RestoreError(400, "mode_invalid", f"duplicate query parameter: {key}")
        seen.add(key)
        if key not in _QUERY_PARAMS:
            raise RestoreError(400, "mode_invalid", f"unknown query parameter: {key}")

    mode = request.query_params.get("mode", "merge")
    if mode not in _MODES:
        raise RestoreError(400, "mode_invalid", "mode must be merge or replace")

    apply = _flag_param(request, "apply")
    allow_foreign_keys = _flag_param(request, "allow_foreign_keys")
    confirm = _parse_confirm(request, mode, allow_foreign_keys)
    if apply:
        _require_confirm(confirm, mode, allow_foreign_keys)
    return RestoreQuery(
        mode=mode,
        apply=apply,
        allow_foreign_keys=allow_foreign_keys,
        confirm=frozenset(confirm),
    )


def _flag_param(request: Request, name: str) -> bool:
    raw = request.query_params.get(name)
    if raw is None:
        return False
    if raw not in _FLAG_VALUES:
        raise RestoreError(400, "mode_invalid", f"{name} must be 0 or 1")
    return raw == "1"


def _parse_confirm(request: Request, mode: str, allow_foreign_keys: bool) -> list[str]:
    raw = request.query_params.get("confirm")
    if raw is None:
        return []
    members = raw.split(",")
    if any(member == "" for member in members):
        raise RestoreError(400, "mode_invalid", "confirm has an empty member")
    if len(members) != len(set(members)):
        raise RestoreError(400, "mode_invalid", "confirm has a duplicate member")
    unknown = [member for member in members if member not in _CONFIRM_OK]
    if unknown:
        raise RestoreError(400, "mode_invalid", f"unknown confirm member: {unknown[0]}")
    if "replace" in members and mode != "replace":
        raise RestoreError(
            400,
            "mode_invalid",
            "confirm member replace is irrelevant when mode is merge",
        )
    if "allow_foreign_keys" in members and not allow_foreign_keys:
        raise RestoreError(
            400,
            "mode_invalid",
            "confirm member allow_foreign_keys is irrelevant without the flag",
        )
    return members


def _require_confirm(members: list[str], mode: str, allow_foreign_keys: bool) -> None:
    required = ["apply"]
    if mode == "replace":
        required.append("replace")
    if allow_foreign_keys:
        required.append("allow_foreign_keys")
    for member in required:
        if member not in members:
            raise RestoreError(409, "confirm_required", f"missing confirm member: {member}")


async def read_body_capped(request: Request, max_bytes: int) -> bytes:
    """Stream the body and refuse at cap+1. Drain the rest so the client
    gets ``payload_too_large`` rather than a connection reset."""
    if max_bytes < 1:
        raise RestoreError(413, "payload_too_large", "body exceeds 0 bytes")
    buf = bytearray()
    over = False
    async for chunk in request.stream():
        if over:
            continue
        # Refuse before retaining cap+1. The chunk itself is whatever
        # the server already read; it is not copied into the buffer.
        if len(buf) + len(chunk) > max_bytes:
            over = True
            buf.clear()
            continue
        buf.extend(chunk)
    if over:
        raise RestoreError(
            413,
            "payload_too_large",
            f"body exceeds {max_bytes} bytes",
        )
    return bytes(buf)


def parse_document(body: bytes) -> dict:
    """Unparseable bytes are ``invalid_json``. A JSON value that is not
    an object falls through to schema validation."""
    try:
        doc = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise RestoreError(400, "invalid_json", "request body is not valid JSON") from exc
    if not isinstance(doc, dict):
        raise RestoreError(400, "schema_invalid", "document must be a JSON object")
    return doc


async def preflight(
    doc: dict,
    *,
    snapshot_conn,
    mode: str,
    allow_foreign_keys: bool,
    reuse_trial_decrypt: bool = False,
    in_transaction: bool = False,
) -> Plan:
    """Pipeline through semantics.

    The dry-run snapshot transaction closes before trial-decrypt. The
    decisions gate is not called here: ``evaluate_write_gate`` acquires
    its own pool connection, so the caller must release ``snapshot_conn``
    and then call ``decisions_gate`` (same order as §5.4, without holding
    a snapshot or lock connection across the probe).

    Apply sets ``in_transaction`` so the catalog read joins the locked
    write transaction instead of opening a second one, and
    ``reuse_trial_decrypt`` so the hold stays write-only. Keyring
    membership is re-checked; envelopes are not decrypted again.
    """
    if mode not in _MODES:
        raise RestoreError(400, "mode_invalid", "mode must be merge or replace")
    _version_gate(doc)
    await asyncio.to_thread(_schema_gate, doc)
    await asyncio.to_thread(_integrity_gate, doc)
    # base_url reachability gate runs before the snapshot is held and
    # before any mutation (review 03c H2). DNS resolution is blocking, so
    # it is off-loop; _upsert_providers repeats it per written row.
    await asyncio.to_thread(_ssrf_gate, doc)
    if in_transaction:
        catalog = await _load_catalog(
            snapshot_conn, doc, mode=mode, allow_foreign_keys=allow_foreign_keys
        )
    else:
        catalog = await _read_snapshot(
            snapshot_conn, doc, mode=mode, allow_foreign_keys=allow_foreign_keys
        )
    extra = await asyncio.to_thread(
        _crypto_gate,
        doc,
        mode=mode,
        allow_foreign_keys=allow_foreign_keys,
        reuse_trial_decrypt=reuse_trial_decrypt,
    )
    return _build_plan(
        doc,
        catalog,
        mode=mode,
        allow_foreign_keys=allow_foreign_keys,
        extra_warnings=extra,
    )


def _version_gate(doc: dict) -> None:
    """C11: bools are excluded first (``isinstance(True, int)`` is true).
    Numeric ``> 1`` (including ``1.5``) is ``unsupported_version``. ``1``
    and integral ``1.0`` proceed. Anything else falls through to schema."""
    value = doc.get("version")
    if isinstance(value, bool):
        return
    if isinstance(value, (int, float)) and value > 1:
        raise RestoreError(
            422,
            "unsupported_version",
            f"document version {value} is not supported; this restore accepts version 1",
        )


def _validator():
    global _VALIDATOR
    if _VALIDATOR is not None:
        return _VALIDATOR
    try:
        _VALIDATOR = load_schema()
    except (OSError, json.JSONDecodeError, SchemaError) as exc:
        logger.warning(
            "config-backup schema failed to load",
            exc_info=(type(exc), exc, exc.__traceback__),
        )
        raise RestoreError(500, "apply_failed", "restore preflight failed") from exc
    return _VALIDATOR


def _schema_gate(doc: dict) -> None:
    errors = sorted(
        _validator().iter_errors(doc),
        key=lambda err: [str(part) for part in err.absolute_path],
    )
    if not errors:
        return
    listed = []
    for err in errors[:_SCHEMA_ERROR_CAP]:
        loc = ".".join(str(part) for part in err.absolute_path) or "$"
        # Keyword only. ``err.message`` echoes the instance, which may
        # be ciphertext.
        listed.append(f"{loc} ({err.validator})")
    message = "schema validation failed: " + "; ".join(listed)
    extra = len(errors) - len(listed)
    if extra:
        message += f"; …and {extra} more"
    raise RestoreError(400, "schema_invalid", message)


def _integrity_gate(doc: dict) -> None:
    claimed = (
        doc.get("integrity", {}).get("payload_sha256")
        if isinstance(doc.get("integrity"), dict)
        else None
    )
    actual = payload_sha256(sort_document_arrays(doc))
    if claimed != actual:
        raise RestoreError(
            422,
            "integrity_mismatch",
            "payload_sha256 does not match the canonical document "
            f"(claimed {claimed}, recomputed {actual})",
        )


async def _read_snapshot(conn, doc: dict, *, mode: str, allow_foreign_keys: bool) -> _Catalog:
    try:
        async with conn.transaction(isolation="repeatable_read", readonly=True):
            await conn.execute("SET LOCAL statement_timeout = '30s'")
            await conn.execute("SET LOCAL idle_in_transaction_session_timeout = '30s'")
            return await _load_catalog(conn, doc, mode=mode, allow_foreign_keys=allow_foreign_keys)
    except RestoreError:
        raise
    except (asyncpg.PostgresError, TimeoutError) as exc:
        raise _from_db(exc) from exc


async def _load_catalog(conn, doc: dict, *, mode: str, allow_foreign_keys: bool) -> _Catalog:
    """Catalog read on the caller's transaction (dry-run snapshot or apply)."""
    applied = await _applied_migrations(conn)
    _migration_gate(doc, applied, mode=mode, allow_foreign_keys=allow_foreign_keys)
    catalog = await _fetch_catalog(conn, applied)
    catalog.generation = await _generation(conn)
    catalog.lead_warnings = _ahead_warnings(doc, applied)
    return catalog


async def _applied_migrations(conn) -> list[str]:
    try:
        rows = await conn.fetch("SELECT version FROM schema_migrations")
    except asyncpg.UndefinedTableError as exc:
        raise RestoreError(
            409,
            "migration_pending",
            "target is missing migrations: schema_migrations",
        ) from exc
    return sorted(row["version"] for row in rows if isinstance(row["version"], str))


def _sections_written(doc: dict, *, allow_foreign_keys: bool) -> set[str]:
    sections = {
        "providers",
        "provider_keys",
        "listings",
        "models",
        "routes",
        "agent_keys",
        "grants",
    }
    router = doc.get("router") if isinstance(doc.get("router"), dict) else {}
    if isinstance(router.get("auto_router"), dict):
        sections.add("auto_router")
    if isinstance(router.get("auto_router_reorder"), dict):
        sections.add("auto_router_reorder")
    if allow_foreign_keys:
        sections -= {"agent_keys", "grants"}
    return sections


def _migration_gate(doc: dict, applied: list[str], *, mode: str, allow_foreign_keys: bool) -> None:
    required = required_migrations_for(
        doc,
        mode=mode,
        allow_foreign_keys=allow_foreign_keys,
        sections_written=_sections_written(doc, allow_foreign_keys=allow_foreign_keys),
    )
    missing = sorted(required - set(applied))
    if missing:
        raise RestoreError(
            409,
            "migration_pending",
            "target is missing migrations: " + ", ".join(missing),
        )


def _ahead_warnings(doc: dict, applied: list[str]) -> list[str]:
    source = doc.get("source") if isinstance(doc.get("source"), dict) else {}
    listed = source.get("schema_migrations")
    if not isinstance(listed, list):
        return []
    ahead = sorted(set(applied) - {item for item in listed if isinstance(item, str)})
    if not ahead:
        return []
    return ["target schema is ahead of the file (routine in a rolling fleet): " + ", ".join(ahead)]


async def _generation(conn) -> int:
    try:
        value = await conn.fetchval("SELECT config_generation FROM config_meta WHERE id = 1")
    except asyncpg.UndefinedTableError as exc:
        raise RestoreError(
            409, "migration_pending", "target is missing migrations: 001_init"
        ) from exc
    if isinstance(value, bool) or not isinstance(value, int):
        logger.error("config_meta.config_generation missing or not an integer")
        raise RestoreError(500, "apply_failed", "restore preflight failed")
    return value


async def _fetch_catalog(conn, applied: list[str]) -> _Catalog:
    applied_set = set(applied)
    try:
        provider_rows = await conn.fetch(_provider_sql(applied_set))
        key_rows = await conn.fetch(
            "SELECT id, provider_id, key_id, weight, enabled, secret_ciphertext "
            "FROM provider_keys ORDER BY id"
        )
        listing_rows = await conn.fetch(_listing_sql(applied_set))
        model_rows = await conn.fetch("SELECT id, name, enabled FROM models ORDER BY id")
        route_rows = await conn.fetch(
            "SELECT mr.model_id, mr.provider_id, m.name AS model_name, "
            "p.name AS provider_name, mr.upstream_model_id, mr.weight, "
            "mr.priority, mr.enabled "
            "FROM model_routes mr "
            "JOIN models m ON m.id = mr.model_id "
            "JOIN providers p ON p.id = mr.provider_id "
            "ORDER BY m.name, p.name"
        )
        agent_rows = await conn.fetch(_agent_sql(applied_set))
        grant_rows = await conn.fetch(_grant_sql(applied_set))
        setting_rows = await conn.fetch(
            "SELECT key, value FROM settings WHERE key IN ('auto_router', 'auto_router_reorder')"
        )
    except asyncpg.UndefinedTableError as exc:
        raise RestoreError(
            409,
            "migration_pending",
            "target is missing a catalog table required to build the plan",
        ) from exc
    except asyncpg.UndefinedColumnError as exc:
        raise RestoreError(
            409,
            "migration_pending",
            "target is missing a catalog column required to build the plan",
        ) from exc

    keys_by: dict[int, list[dict]] = {}
    for row in key_rows:
        keys_by.setdefault(row["provider_id"], []).append(
            {
                "id": row["id"],
                "key_id": row["key_id"],
                "weight": row["weight"],
                "enabled": _db_flag(row["enabled"], "provider_keys.enabled"),
                "secret": _db_bytes(row["secret_ciphertext"], "provider_keys.secret_ciphertext"),
            }
        )
    listings_by: dict[int, list[dict]] = {}
    for row in listing_rows:
        listings_by.setdefault(row["provider_id"], []).append(
            {
                "id": row["id"],
                "name": row["name"],
                "enabled": _db_flag(row["enabled"], "provider_models.enabled"),
                "modality": row["modality"],
            }
        )
    providers = [
        {
            "id": row["id"],
            "name": row["name"],
            "base_url": row["base_url"],
            "protocol": row["protocol"],
            "enabled": _db_flag(row["enabled"], "providers.enabled"),
            "region_tag": row["region_tag"],
            "affinity_node": row["affinity_node"],
            "allow_internal": _db_flag(row["allow_internal"], "providers.allow_internal"),
            "keys": keys_by.get(row["id"], []),
            "listings": listings_by.get(row["id"], []),
        }
        for row in provider_rows
    ]
    grants: dict[int, set[str]] = {}
    for row in grant_rows:
        name = row["model_name"]
        if isinstance(name, str):
            grants.setdefault(row["api_key_id"], set()).add(name)
    agent_keys = [
        {
            "id": row["id"],
            "prefix": row["prefix"],
            "key_hash": _db_bytes(row["key_hash"], "api_keys.key_hash"),
            "enabled": _db_flag(row["enabled"], "api_keys.enabled"),
            "rpm_limit": row["rpm_limit"],
            "tpm_limit": row["tpm_limit"],
            "daily_token_limit": row["daily_token_limit"],
            "model_names": grants.get(row["id"], set()),
        }
        for row in agent_rows
    ]
    models = [
        {
            "id": row["id"],
            "name": row["name"],
            "enabled": _db_flag(row["enabled"], "models.enabled"),
        }
        for row in model_rows
    ]
    routes = [
        {
            "model_id": row["model_id"],
            "provider_id": row["provider_id"],
            "model": row["model_name"],
            "provider": row["provider_name"],
            "upstream_model_id": row["upstream_model_id"],
            "weight": row["weight"],
            "priority": row["priority"],
            "enabled": _db_flag(row["enabled"], "model_routes.enabled"),
        }
        for row in route_rows
    ]
    settings: dict[str, dict | None] = {}
    for row in setting_rows:
        settings[row["key"]] = _settings_object(row["value"], row["key"])
    return _Catalog(
        generation=0,
        migrations=applied,
        providers=providers,
        models=models,
        routes=routes,
        agent_keys=agent_keys,
        auto_router=settings.get("auto_router"),
        auto_router_reorder=settings.get("auto_router_reorder"),
    )


def _provider_sql(applied: set[str]) -> str:
    # Column-adding migrations are selected only when applied. Snippets
    # are literals; nothing from the document is interpolated.
    region = "region_tag" if "015_worker_affinity" in applied else "NULL::text"
    affinity = "affinity_node" if "015_worker_affinity" in applied else "NULL::text"
    allow = "allow_internal" if "017_allow_internal" in applied else "0::smallint"
    return (
        "SELECT id, name, base_url, protocol, enabled, "
        f"{region} AS region_tag, {affinity} AS affinity_node, "
        f"{allow} AS allow_internal FROM providers ORDER BY id"
    )


def _listing_sql(applied: set[str]) -> str:
    modality = "modality" if "010_modality" in applied else "'chat'::text"
    return (
        "SELECT id, provider_id, name, enabled, "
        f"{modality} AS modality FROM provider_models ORDER BY id"
    )


def _agent_sql(applied: set[str]) -> str:
    if "014_api_key_quotas" in applied:
        quotas = "rpm_limit, tpm_limit, daily_token_limit"
    else:
        quotas = (
            "NULL::integer AS rpm_limit, NULL::integer AS tpm_limit, "
            "NULL::integer AS daily_token_limit"
        )
    return f"SELECT id, prefix, key_hash, enabled, {quotas} FROM api_keys ORDER BY id"


def _grant_sql(applied: set[str]) -> str:
    if "022_api_key_model_names" in applied:
        return "SELECT api_key_id, model_name FROM api_key_models"
    return (
        "SELECT akm.api_key_id, m.name AS model_name "
        "FROM api_key_models akm JOIN models m ON m.id = akm.model_id"
    )


def _db_flag(value: object, field: str) -> bool:
    if isinstance(value, bool) or not isinstance(value, int) or value not in (0, 1):
        logger.error("catalog flag %s is not 0/1", field)
        raise RestoreError(500, "apply_failed", "restore preflight failed")
    return value == 1


def _db_bytes(value: object, field: str) -> bytes:
    if isinstance(value, memoryview):
        value = value.tobytes()
    elif isinstance(value, bytearray):
        value = bytes(value)
    if not isinstance(value, bytes):
        logger.error("catalog bytea %s is not bytes", field)
        raise RestoreError(500, "apply_failed", "restore preflight failed")
    return value


def _settings_object(raw: object, key: str) -> dict | None:
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode()
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError as exc:
            logger.error("settings.%s is not valid JSON", key)
            raise RestoreError(500, "apply_failed", "restore preflight failed") from exc
    if raw is None:
        return None
    if isinstance(raw, dict):
        try:
            parsed = json.loads(json.dumps(raw))
        except (TypeError, ValueError) as exc:
            logger.error("settings.%s is not JSON-safe", key)
            raise RestoreError(500, "apply_failed", "restore preflight failed") from exc
        if isinstance(parsed, dict):
            return parsed
    logger.error("settings.%s is not a JSON object", key)
    raise RestoreError(500, "apply_failed", "restore preflight failed")


def _from_db(exc: BaseException) -> RestoreError:
    sqlstate = getattr(exc, "sqlstate", None)
    if isinstance(exc, TimeoutError) or sqlstate in _TIMEOUT_SQLSTATES:
        return RestoreError(
            500,
            "snapshot_timeout",
            "restore snapshot exceeded its 30s bound",
        )
    logger.warning(
        "config restore snapshot read failed",
        exc_info=(type(exc), exc, exc.__traceback__),
    )
    return RestoreError(500, "apply_failed", "restore preflight failed")


def _crypto_gate(
    doc: dict,
    *,
    mode: str,
    allow_foreign_keys: bool,
    reuse_trial_decrypt: bool = False,
) -> list[str]:
    warnings: list[str] = []
    _key_id_set_gate(doc)
    warnings.extend(_canary_warning(doc))
    if reuse_trial_decrypt:
        # Lock hold stays write-only. Membership is O(kids); a kid that
        # left the ring since the outer trial is keyring_mismatch.
        _keyring_membership(doc)
    else:
        _trial_decrypt(doc)
    warnings.extend(_duplicate_ciphertext(doc))
    warnings.extend(_pepper_gate(doc, mode=mode, allow_foreign_keys=allow_foreign_keys))
    return warnings


def _keyring_membership(doc: dict) -> None:
    ring = set(_keyring())
    missing = [kid for kid in derive_key_ids(doc) if kid not in ring]
    if missing:
        raise RestoreError(
            422,
            "keyring_mismatch",
            "keyring is missing key ids: " + ", ".join(missing),
        )


def _key_id_set_gate(doc: dict) -> None:
    crypto = doc["crypto"]["provider_key_encryption"]
    declared = set(crypto.get("key_ids") or [])
    derived = set(derive_key_ids(doc))
    if not declared and not derived:
        return
    if declared != derived:
        raise RestoreError(
            400,
            "schema_invalid",
            "crypto.provider_key_encryption.key_ids "
            f"{sorted(declared)} does not match derived key ids {sorted(derived)}",
        )


def _canary_warning(doc: dict) -> list[str]:
    crypto = doc["crypto"]["provider_key_encryption"]
    canary_key_id = crypto.get("canary_key_id")
    derived = ", ".join(derive_key_ids(doc)) or "(none)"
    copy = (
        f"canary check failed for canary_key_id={canary_key_id} "
        f"(envelope key ids: {derived}); active-key rotation is routine"
    )
    try:
        raw = _b64_bytes(crypto.get("canary"))
        embedded = _envelope_key_id(raw)
        if embedded != canary_key_id:
            return [copy]
        plain = decrypt(raw)
    except Exception:
        logger.warning("config restore canary did not decrypt (warning only)")
        return [copy]
    if plain != _CANARY_PLAINTEXT:
        return [copy]
    return []


def _trial_decrypt(doc: dict) -> None:
    for provider in doc["providers"]:
        name = provider.get("name")
        seen: set[bytes] = set()
        for key in provider.get("keys") or []:
            declared = key.get("key_id")
            try:
                raw = _b64_bytes(key.get("secret_ciphertext_b64"))
            except RestoreError as exc:
                raise RestoreError(
                    422,
                    "keyring_mismatch",
                    f"provider {name} key ciphertext is not decodable",
                ) from exc
            if raw in seen:
                continue
            seen.add(raw)
            try:
                embedded = _envelope_key_id(raw)
            except (ValueError, UnicodeError, struct.error) as exc:
                raise RestoreError(
                    422,
                    "keyring_mismatch",
                    f"provider {name} key is not a JSEC envelope",
                ) from exc
            if embedded != declared:
                raise RestoreError(
                    422,
                    "keyring_mismatch",
                    f"provider {name} key_id {declared} does not match "
                    f"the envelope key id {embedded}",
                )
            try:
                decrypt(raw)
            except Exception as exc:
                raise RestoreError(
                    422,
                    "keyring_mismatch",
                    f"provider {name} key could not be trial-decrypted",
                ) from exc


def _duplicate_ciphertext(doc: dict) -> list[str]:
    warnings: list[str] = []
    owners: dict[bytes, str] = {}
    warned: set[tuple[str, str]] = set()
    for provider in doc["providers"]:
        name = provider["name"]
        seen: set[bytes] = set()
        for key in provider["keys"]:
            raw = _b64_bytes(key["secret_ciphertext_b64"])
            if raw in seen:
                raise RestoreError(
                    422,
                    "duplicate_secret",
                    f"duplicate provider-key ciphertext within provider {name}",
                )
            seen.add(raw)
            other = owners.get(raw)
            if other is None:
                owners[raw] = name
                continue
            if other == name:
                continue
            pair = tuple(sorted((other, name)))
            if pair in warned:
                continue
            warned.add(pair)
            warnings.append(
                f"provider-key ciphertext is shared by providers {pair[0]} and {pair[1]}"
            )
    return warnings


def _ssrf_base_url_gate(base_url: str, allow_internal: bool) -> None:
    """Reachability gate for one restored provider ``base_url``.

    Restore is a first-class ``base_url`` write path, so it must pass the
    same ALWAYS-ON write gate as POST/PUT /api/providers: internal /
    loopback / cloud-metadata addresses are rejected fail-closed unless
    the row carries the audited ``allow_internal`` break-glass (review
    03c H2). The helper lives in the providers router; import it lazily
    so this service module does not depend on router import order and a
    refused restore surfaces as the module's own error code, not a raw
    HTTPException from a router helper.
    """
    from .routers.providers import reject_internal_base_url

    try:
        reject_internal_base_url(base_url, allow_internal)
    except HTTPException as exc:
        detail = exc.detail if isinstance(exc.detail, dict) else {}
        error = detail.get("error") if isinstance(detail, dict) else None
        code = error.get("code") if isinstance(error, dict) else None
        message = error.get("message") if isinstance(error, dict) else None
        raise RestoreError(
            exc.status_code,
            code if isinstance(code, str) and code else "invalid_url",
            message if isinstance(message, str) and message else "base_url rejected",
        ) from exc


def _ssrf_gate(doc: dict) -> None:
    """Run the base_url gate over every provider the document carries.

    Called from preflight (both the dry run and the apply transaction,
    before any mutation) and again per written row in
    ``_upsert_providers``. ``allow_internal`` rows skip classification —
    that flag is the documented audited break-glass.
    """
    for provider in doc.get("providers") or []:
        if not isinstance(provider, dict):
            continue
        base_url = provider.get("base_url")
        if not isinstance(base_url, str) or not base_url:
            continue  # the schema gate already refused this
        _ssrf_base_url_gate(base_url, bool(provider.get("allow_internal")))


def _pepper_gate(doc: dict, *, mode: str, allow_foreign_keys: bool) -> list[str]:
    if allow_foreign_keys:
        return []
    agent_keys = doc.get("agent_keys") or []
    if not agent_keys and mode != "replace":
        # Merge with an empty section writes nothing and deletes nothing.
        return []
    # A replace deletes every api_keys row that is not in the file, so an
    # empty agent_keys array deletes EVERY key. The pepper canary is the
    # only proof that the document came from an environment sharing this
    # deployment's JANUS_API_KEY_PEPPER; verifying it matters most in
    # exactly that maximal-blast-radius case, so it is a refusal, not a
    # warning (review M1).
    actual = doc["crypto"]["agent_key_hash"]["pepper_canary_hash"]
    expected = pepper_canary_hash(config.api_key_pepper)
    if not isinstance(actual, str) or actual != expected:
        scope = (
            "an empty agent_keys array under mode=replace deletes every agent key"
            if not agent_keys
            else "the file's agent keys were hashed with a different pepper"
        )
        raise RestoreError(
            422,
            "pepper_mismatch",
            f"pepper canary does not match this environment — {scope}; "
            "use allow_foreign_keys=1 to leave the existing keys untouched",
        )
    return []


def _b64_bytes(value: object) -> bytes:
    if not isinstance(value, str) or not value:
        raise RestoreError(400, "schema_invalid", "a base64 field is empty")
    pad = "=" * ((4 - len(value) % 4) % 4)
    try:
        return base64.b64decode(value + pad, validate=True)
    except Exception as exc:
        raise RestoreError(400, "schema_invalid", "a base64 field is not decodable") from exc


def _envelope_key_id(envelope: bytes) -> str:
    """Embedded JSEC key id. Same layout ``crypto.decrypt`` reads.

    A kid that is not valid text, or a header ``struct`` cannot unpack,
    is a corrupt envelope. Callers map ``ValueError`` to
    ``keyring_mismatch``. ``UnicodeDecodeError`` is raised as
    ``ValueError`` here so it cannot escape that mapping.
    """
    try:
        if len(envelope) < 7 or envelope[:4] != MAGIC:
            raise ValueError("not a JSEC envelope")
        kid_len = struct.unpack(">H", envelope[5:7])[0]
        start = 7
        end = start + kid_len
        if kid_len < 1 or end > len(envelope):
            raise ValueError("truncated JSEC envelope")
        return envelope[start:end].decode()
    except UnicodeError as exc:
        raise ValueError("JSEC key id is not valid text") from exc
    except struct.error as exc:
        raise ValueError("truncated JSEC envelope") from exc


def _build_plan(
    doc: dict,
    catalog: _Catalog,
    *,
    mode: str,
    allow_foreign_keys: bool,
    extra_warnings: list[str],
) -> Plan:
    _duplicate_names(doc)
    post = _post_world(doc, catalog, mode=mode, allow_foreign_keys=allow_foreign_keys)
    _route_closure(doc, post)
    _surface_closure(doc, catalog, post)
    warnings = list(catalog.lead_warnings)
    warnings.extend(
        _document_warnings(doc, catalog, mode=mode, allow_foreign_keys=allow_foreign_keys)
    )
    warnings.extend(extra_warnings)
    sections = {name: _Counts() for name in _SECTIONS}
    warnings.extend(
        _tally(
            doc,
            catalog,
            post,
            sections,
            mode=mode,
            allow_foreign_keys=allow_foreign_keys,
        )
    )
    capped = _cap_warnings(warnings)
    noop = not any(counts.writes() for counts in sections.values())
    return Plan(
        mode=mode,
        sections={name: sections[name].as_dict() for name in _SECTIONS},
        warnings=capped,
        generation=catalog.generation,
        would_noop=noop,
        catalog=catalog,
    )


def _duplicate_names(doc: dict) -> None:
    _require_unique((p["name"] for p in doc["providers"]), "duplicate provider name: ")
    router = doc["router"]
    _require_unique((m["name"] for m in router["models"]), "duplicate model name: ")
    slots: set[tuple[str, str]] = set()
    for route in router["routes"]:
        slot = (route["model"], route["provider"])
        if slot in slots:
            raise RestoreError(
                422,
                "duplicate_name",
                f"duplicate route slot: {slot[0]}/{slot[1]}",
            )
        slots.add(slot)
    for provider in doc["providers"]:
        _require_unique(
            (item["name"] for item in provider["listings"]),
            f"duplicate listing name on provider {provider['name']}: ",
        )
    hashes: set[bytes] = set()
    for agent in doc["agent_keys"]:
        digest = _b64_bytes(agent["key_hash_b64"])
        if digest in hashes:
            raise RestoreError(422, "duplicate_name", "duplicate agent key hash")
        hashes.add(digest)
        names = agent.get("model_names") or []
        if len(names) != len(set(names)):
            raise RestoreError(422, "duplicate_name", "duplicate grant on one agent key")


def _require_unique(values, prefix: str) -> None:
    seen: set[str] = set()
    for value in values:
        if value in seen:
            raise RestoreError(422, "duplicate_name", prefix + str(value))
        seen.add(value)


def _post_world(doc: dict, catalog: _Catalog, *, mode: str, allow_foreign_keys: bool) -> dict:
    file_providers = {p["name"]: p for p in doc["providers"]}
    db_providers = {p["name"]: p for p in catalog.providers}
    file_models = {m["name"]: m for m in doc["router"]["models"]}
    db_models = {m["name"]: m for m in catalog.models}
    file_routes = {(r["model"], r["provider"]): r for r in doc["router"]["routes"]}
    db_routes = {(r["model"], r["provider"]): r for r in catalog.routes}
    if mode == "replace":
        providers = file_providers
        models = file_models
        routes = file_routes
    else:
        providers = {**db_providers, **file_providers}
        models = {**db_models, **file_models}
        routes = {**db_routes, **file_routes}
    if allow_foreign_keys:
        agent_keys = {k["key_hash"]: k for k in catalog.agent_keys}
    elif mode == "replace":
        agent_keys = {_agent_hash(k): k for k in doc["agent_keys"]}
    else:
        agent_keys = {k["key_hash"]: k for k in catalog.agent_keys}
        agent_keys.update({_agent_hash(k): k for k in doc["agent_keys"]})
    return {
        "mode": mode,
        "retained_auto_router": catalog.auto_router,
        "providers": providers,
        "models": models,
        "routes": routes,
        "agent_keys": agent_keys,
        "db_providers": db_providers,
        "db_models": db_models,
        "db_routes": db_routes,
        "file_providers": file_providers,
        "file_models": file_models,
        "file_routes": file_routes,
    }


def _agent_hash(row: dict) -> bytes:
    return _b64_bytes(row["key_hash_b64"])


def _route_closure(doc: dict, post: dict) -> None:
    virtual = _virtual_name(doc, post)
    for model in doc["router"]["models"]:
        if model["name"] == virtual:
            raise RestoreError(
                422,
                "broken_reference",
                f"model {virtual} is the virtual auto-router model",
            )
    for route in doc["router"]["routes"]:
        if route["model"] == virtual:
            raise RestoreError(
                422,
                "broken_reference",
                f"route {route['model']}/{route['provider']} names the virtual auto-router model",
            )
        if route["model"] not in post["models"] or route["provider"] not in post["providers"]:
            raise RestoreError(
                422,
                "broken_reference",
                f"route {route['model']}/{route['provider']} references a model or "
                "provider that will not exist after restore",
            )


def _virtual_name(doc: dict, post: dict | None = None, catalog: _Catalog | None = None) -> str:
    router = doc.get("router") if isinstance(doc.get("router"), dict) else {}
    file_cfg = router.get("auto_router") if isinstance(router.get("auto_router"), dict) else None
    if file_cfg and isinstance(file_cfg.get("model"), str) and file_cfg["model"].strip():
        return file_cfg["model"].strip()
    retained = None
    if catalog is not None:
        retained = catalog.auto_router
    elif post is not None:
        retained = post.get("retained_auto_router")
    if isinstance(retained, dict):
        model = retained.get("model")
        if isinstance(model, str) and model.strip():
            return model.strip()
    return "janus-auto"


def _surface_closure(doc: dict, catalog: _Catalog, post: dict) -> None:
    """C7: tiers ⊆ post-write bound names, mutual exclusivity, D6, judge
    on the agent-visible surface. Orphan grants are warnings, not refusals."""
    virtual = _virtual_name(doc, post)
    bound = _bound_names(post)
    listings = _listing_names(post)
    surface = bound | listings
    cfg = _projected_auto_router(doc, catalog)
    if cfg is not None:
        _validate_projected_router(cfg, bound, surface, virtual)
    # File grants are checked later as warnings. A retained tier that
    # names a model replace deletes fails here in both modes.


def _bound_names(post: dict) -> set[str]:
    bound: set[str] = set()
    for (model, provider), route in post["routes"].items():
        if not route.get("enabled"):
            continue
        if provider not in post["providers"]:
            continue
        model_row = post["models"].get(model)
        if not model_row or not model_row.get("enabled"):
            continue
        bound.add(model)
    return bound


def _listing_names(post: dict) -> set[str]:
    names: set[str] = set()
    for provider_name, provider in post["providers"].items():
        for listing in _post_listings(provider_name, provider, post):
            name = listing.get("name")
            if isinstance(name, str):
                names.add(name)
    return names


def _post_listings(provider_name: str, provider: dict, post: dict) -> list[dict]:
    file_provider = post["file_providers"].get(provider_name)
    db_provider = post["db_providers"].get(provider_name)
    file_rows = file_provider["listings"] if file_provider else []
    db_rows = db_provider["listings"] if db_provider else []
    if provider is file_provider and provider_name not in post["db_providers"]:
        return list(file_rows)
    if provider is file_provider and _is_replace(post):
        return list(file_rows)
    # Merge: file rows override by name, DB rows remain.
    by_name = {row["name"]: row for row in db_rows}
    by_name.update({row["name"]: row for row in file_rows})
    if _is_replace(post):
        return list(file_rows)
    return list(by_name.values())


def _is_replace(post: dict) -> bool:
    return post.get("mode") == "replace"


def _projected_auto_router(doc: dict, catalog: _Catalog) -> dict | None:
    router = doc["router"]
    file_cfg = router.get("auto_router")
    if isinstance(file_cfg, dict):
        return file_cfg
    return catalog.auto_router


def _validate_projected_router(cfg: dict, bound: set[str], surface: set[str], virtual: str) -> None:
    if not isinstance(cfg, dict):
        raise RestoreError(422, "tiers_invalid", "post-write auto-router config is not an object")
    model = cfg.get("model")
    if not isinstance(model, str) or not model.strip():
        raise RestoreError(422, "tiers_invalid", "auto-router model must be a non-empty string")
    judge = cfg.get("judge_model")
    if judge is not None and (not isinstance(judge, str) or not judge.strip()):
        raise RestoreError(422, "tiers_invalid", "judge_model must be a model name or null")
    if isinstance(judge, str) and judge.strip() not in surface:
        raise RestoreError(
            422,
            "tiers_invalid",
            f"judge_model not in the post-write catalog: {judge.strip()}",
        )
    tiers = cfg.get("tiers")
    if not isinstance(tiers, dict):
        raise RestoreError(422, "tiers_invalid", "auto-router tiers must be an object")
    unknown = set(tiers) - set(TIERS)
    if unknown:
        raise RestoreError(422, "tiers_invalid", f"unknown auto-router tiers: {sorted(unknown)}")
    seen: dict[str, str] = {}
    flat: list[str] = []
    for tier in TIERS:
        names = tiers.get(tier, [])
        if not isinstance(names, list) or not all(isinstance(n, str) and n.strip() for n in names):
            raise RestoreError(422, "tiers_invalid", f"tiers.{tier} must be a list of model names")
        for name in names:
            stripped = name.strip()
            if stripped == virtual or stripped == "janus-auto":
                raise RestoreError(
                    422,
                    "tiers_invalid",
                    f"tier member {stripped} is the virtual auto-router model",
                )
            if stripped in seen:
                raise RestoreError(
                    422,
                    "tiers_invalid",
                    f"tier member {stripped} appears in more than one tier",
                )
            seen[stripped] = tier
            flat.append(stripped)
    missing = sorted({name for name in flat if name not in bound})
    if missing:
        raise RestoreError(
            422,
            "tiers_invalid",
            "tier members must be bound on the post-write router: " + ", ".join(missing),
        )
    normalized = validate_tiers_master_parity(tiers, model.strip())
    for tier in TIERS:
        raw = [name for name in tiers.get(tier, []) if isinstance(name, str) and name != ""]
        if normalized.get(tier) != raw:
            raise RestoreError(
                422,
                "tiers_invalid",
                "auto-router tiers fail the master-parity validator",
            )
    default_tier = cfg.get("default_tier")
    if default_tier not in TIERS:
        raise RestoreError(422, "tiers_invalid", "default_tier must be fast, big, or flagship")
    for field_name, minimum in _ROUTER_INT_MIN.items():
        value = cfg.get(field_name)
        if field_name == "max_ctx_tokens" and value is None:
            continue
        if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
            raise RestoreError(
                422,
                "tiers_invalid",
                f"{field_name} must be an integer >= {minimum}",
            )


def _document_warnings(
    doc: dict, catalog: _Catalog, *, mode: str, allow_foreign_keys: bool
) -> list[str]:
    warnings: list[str] = []
    source = doc.get("source") if isinstance(doc.get("source"), dict) else {}
    file_gen = source.get("config_generation")
    if (
        isinstance(file_gen, int)
        and not isinstance(file_gen, bool)
        and file_gen < catalog.generation
    ):
        warnings.append(
            f"source.config_generation {file_gen} lags target generation "
            f"{catalog.generation}; a later replace can delete intervening edits"
        )
    warnings.extend(_env_warning(doc, catalog))
    if mode == "replace":
        if doc["providers"] == []:
            warnings.append(
                "replace of empty providers deletes every provider, provider key, "
                "and listing in scope"
            )
        if doc["router"]["models"] == []:
            warnings.append("replace of empty models deletes every bound model in scope")
        if doc["router"]["routes"] == []:
            warnings.append("replace of empty routes deletes every route in scope")
        if doc["agent_keys"] == [] and not allow_foreign_keys:
            warnings.append("replace of empty agent_keys deletes every agent key in scope")
    if allow_foreign_keys:
        warnings.append(
            "agent_keys section skipped because allow_foreign_keys=1; existing keys "
            "are left untouched and the pepper is not checked"
        )
    return warnings


def _env_warning(doc: dict, catalog: _Catalog) -> list[str]:
    """Host mismatch, or env-local fields that do not match this fleet.

    A same-host export keeps ``host`` and the local base URL; that is not
    a cross-fleet retarget miss, so it stays quiet. Stripping ``host``
    (C10, before a document is shared) is cross-host evidence. On that
    evidence, ``base_url`` drift warns even when ``region_tag`` and
    ``affinity_node`` are both null, and a provider this catalog does
    not have yet warns too: its base_url was not checked against this
    fleet (fresh-env insert).
    """
    try:
        local = socket.gethostname().strip()
    except OSError:
        local = ""
    host = doc.get("host")
    host_text = host.strip() if isinstance(host, str) else ""
    if host_text and host_text != local:
        return [
            f"document host {host_text!r} does not match this host {local!r}; "
            "base_url, region_tag, and affinity_node are environment-local "
            "and may still point at the source fleet"
        ]
    if host_text:
        return []
    db_by_name = {p["name"]: p for p in catalog.providers}
    drifted: list[str] = []
    for provider in doc["providers"]:
        current = db_by_name.get(provider["name"])
        if current is None or _env_local_differs(provider, current):
            drifted.append(provider["name"])
    if not drifted:
        return []
    listed = ", ".join(sorted(set(drifted))[:8])
    return [
        "base_url, region_tag, or affinity_node look un-retargeted from "
        f"another fleet on providers: {listed}"
    ]


def _env_local_differs(provider: dict, current: dict) -> bool:
    """True when base_url, region_tag, or affinity_node disagree.

    Null region and affinity are valid and common. A base_url change
    alone is still env-local drift (C10 / §5.3).
    """
    return (
        provider.get("base_url") != current.get("base_url")
        or provider.get("region_tag") != current.get("region_tag")
        or provider.get("affinity_node") != current.get("affinity_node")
    )


def _tally(
    doc: dict,
    catalog: _Catalog,
    post: dict,
    sections: dict[str, _Counts],
    *,
    mode: str,
    allow_foreign_keys: bool,
) -> list[str]:
    post["mode"] = mode
    warnings: list[str] = []
    _tally_providers(doc, catalog, post, sections, mode=mode, warnings=warnings)
    _tally_models(doc, catalog, sections, mode=mode)
    _tally_routes(post, sections, mode=mode, warnings=warnings)
    warnings.extend(
        _tally_agent_keys(
            doc,
            catalog,
            post,
            sections,
            mode=mode,
            allow_foreign_keys=allow_foreign_keys,
        )
    )
    _tally_settings(doc, catalog, sections)
    return warnings


def _tally_providers(doc, catalog, post, sections, *, mode: str, warnings: list[str]) -> None:
    file_by = post["file_providers"]
    db_by = post["db_providers"]
    providers = sections["providers"]
    keys = sections["provider_keys"]
    listings = sections["listings"]
    for name, row in file_by.items():
        current = db_by.get(name)
        if current is None:
            providers.insert += 1
        elif _provider_equal(row, current):
            providers.unchanged += 1
        else:
            providers.update += 1
        _tally_children(name, row, current, keys, listings, mode=mode, warnings=warnings)
    if mode == "merge":
        for name, current in db_by.items():
            if name in file_by:
                continue
            providers.unchanged += 1
            keys.unchanged += len(current["keys"])
            listings.unchanged += len(current["listings"])
            _weight_warning(name, current["keys"], warnings)
        return
    for name, current in db_by.items():
        if name in file_by:
            continue
        providers.explicit += 1
        keys.cascade += len(current["keys"])
        listings.cascade += len(current["listings"])


def _provider_equal(file_row: dict, db_row: dict) -> bool:
    return (
        file_row["base_url"] == db_row["base_url"]
        and file_row["protocol"] == db_row["protocol"]
        and file_row["enabled"] == db_row["enabled"]
        and file_row["region_tag"] == db_row["region_tag"]
        and file_row["affinity_node"] == db_row["affinity_node"]
        and file_row["allow_internal"] == db_row["allow_internal"]
    )


def _tally_children(
    name, file_row, db_row, keys, listings, *, mode: str, warnings: list[str]
) -> None:
    file_keys = {_b64_bytes(k["secret_ciphertext_b64"]): k for k in file_row["keys"]}
    db_keys = {k["secret"]: k for k in (db_row["keys"] if db_row else [])}
    post_keys = []
    for secret, row in file_keys.items():
        current = db_keys.get(secret)
        if current is None:
            keys.insert += 1
            post_keys.append(row)
        elif _key_equal(row, current):
            keys.unchanged += 1
            post_keys.append(row)
        else:
            keys.update += 1
            post_keys.append(row)
    if mode == "merge":
        for secret, current in db_keys.items():
            if secret in file_keys:
                continue
            keys.unchanged += 1
            post_keys.append(current)
    else:
        for secret in db_keys:
            if secret not in file_keys:
                keys.explicit += 1
    _weight_warning(name, post_keys, warnings)

    file_listings = {item["name"]: item for item in file_row["listings"]}
    db_listings = {item["name"]: item for item in (db_row["listings"] if db_row else [])}
    for listing_name, row in file_listings.items():
        current = db_listings.get(listing_name)
        if current is None:
            listings.insert += 1
        elif row["enabled"] == current["enabled"] and row["modality"] == current["modality"]:
            listings.unchanged += 1
        else:
            listings.update += 1
    if mode == "merge":
        for listing_name in db_listings:
            if listing_name not in file_listings:
                listings.unchanged += 1
    else:
        for listing_name in db_listings:
            if listing_name not in file_listings:
                listings.explicit += 1


def _key_equal(file_row: dict, db_row: dict) -> bool:
    return (
        file_row["key_id"] == db_row["key_id"]
        and file_row["weight"] == db_row["weight"]
        and file_row["enabled"] == db_row["enabled"]
    )


def _weight_warning(name: str, rows: list[dict], warnings: list[str]) -> None:
    if not rows:
        return
    if any(row.get("weight") == 0 for row in rows):
        warnings.append(f"provider {name} has a weight-0 key")
    total = 0
    for row in rows:
        weight = row.get("weight")
        if isinstance(weight, int) and not isinstance(weight, bool):
            total += weight
    if total == 0:
        warnings.append(f"provider {name} key weights sum to 0")


def _tally_models(doc, catalog, sections, *, mode: str) -> None:
    counts = sections["models"]
    file_by = {m["name"]: m for m in doc["router"]["models"]}
    db_by = {m["name"]: m for m in catalog.models}
    for name, row in file_by.items():
        current = db_by.get(name)
        if current is None:
            counts.insert += 1
        elif row["enabled"] == current["enabled"]:
            counts.unchanged += 1
        else:
            counts.update += 1
    if mode == "merge":
        counts.unchanged += sum(1 for name in db_by if name not in file_by)
        return
    counts.explicit += sum(1 for name in db_by if name not in file_by)


def _tally_routes(post, sections, *, mode: str, warnings: list[str]) -> None:
    counts = sections["routes"]
    file_by = post["file_routes"]
    db_by = post["db_routes"]
    listings_by = _listings_by_provider(post)
    for slot, row in file_by.items():
        current = db_by.get(slot)
        if current is None:
            counts.insert += 1
        elif _route_equal(row, current):
            counts.unchanged += 1
        else:
            counts.update += 1
            if not _upstream_equivalent(row, current):
                warnings.append(
                    f"route {slot[0]}/{slot[1]} upstream_model_id differs from the target"
                )
        upstream = _effective_upstream(row)
        provider_listings = listings_by.get(slot[1], set())
        if upstream not in provider_listings:
            warnings.append(
                f"route {slot[0]}/{slot[1]} upstream {upstream!r} is not in "
                "the provider's post-write listings"
            )
    if mode == "merge":
        counts.unchanged += sum(1 for slot in db_by if slot not in file_by)
        return
    for slot, row in db_by.items():
        if slot in file_by:
            continue
        model_survives = slot[0] in post["models"]
        provider_survives = slot[1] in post["providers"]
        if model_survives and provider_survives:
            counts.explicit += 1
        else:
            counts.cascade += 1


def _listings_by_provider(post: dict) -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for name in post["providers"]:
        out[name] = {
            item["name"]
            for item in _post_listings(name, post["providers"][name], post)
            if isinstance(item.get("name"), str)
        }
    return out


def _effective_upstream(row: dict) -> str:
    upstream = row.get("upstream_model_id")
    if isinstance(upstream, str) and upstream:
        return upstream
    return row["model"]


def _upstream_equivalent(file_row: dict, db_row: dict) -> bool:
    return _effective_upstream(file_row) == _effective_upstream(db_row)


def _route_equal(file_row: dict, db_row: dict) -> bool:
    return (
        _upstream_equivalent(file_row, db_row)
        and file_row["weight"] == db_row["weight"]
        and file_row["priority"] == db_row["priority"]
        and file_row["enabled"] == db_row["enabled"]
    )


def _tally_agent_keys(
    doc,
    catalog,
    post,
    sections,
    *,
    mode: str,
    allow_foreign_keys: bool,
) -> list[str]:
    warnings: list[str] = []
    counts = sections["agent_keys"]
    grants = sections["grants"]
    file_by = {_agent_hash(k): k for k in doc["agent_keys"]}
    db_by = {k["key_hash"]: k for k in catalog.agent_keys}
    deleted_models = set(post["db_models"]) - set(post["models"])
    surface = set(post["models"]) | _listing_names(post)
    narrowed: list[str] = []

    if allow_foreign_keys:
        counts.unchanged = len(db_by)
    else:
        for digest, row in file_by.items():
            current = db_by.get(digest)
            if current is None:
                counts.insert += 1
            elif _agent_equal(row, current):
                counts.unchanged += 1
            else:
                counts.update += 1
        if mode == "merge":
            counts.unchanged += sum(1 for digest in db_by if digest not in file_by)
        else:
            counts.explicit += sum(1 for digest in db_by if digest not in file_by)

    surviving = set(post["agent_keys"])
    for digest, current in db_by.items():
        if digest not in surviving:
            grants.cascade += len(current["model_names"])
            continue
        desired = _desired_grants(
            current,
            None if allow_foreign_keys else file_by.get(digest),
            deleted_models=deleted_models,
            mode=mode,
            allow_foreign_keys=allow_foreign_keys,
            warnings=warnings,
        )
        _count_grants(
            grants,
            set(current["model_names"]),
            desired,
            deleted_models,
        )
        if (set(current["model_names"]) - desired) & deleted_models:
            prefix = _post_prefix(digest, file_by, current, allow_foreign_keys)
            if prefix:
                narrowed.append(prefix)
        _orphan_warning(digest, desired, surface, file_by, current, warnings)

    if not allow_foreign_keys:
        for digest, row in file_by.items():
            if digest in db_by:
                continue
            desired = set(row.get("model_names") or [])
            grants.insert += len(desired)
            _orphan_warning(digest, desired, surface, file_by, None, warnings)

    if narrowed:
        listed = ", ".join(sorted(set(narrowed))[:20])
        warnings.append("replace deletes models that narrow grants on surviving keys: " + listed)
    return warnings


def _count_grants(
    grants: _Counts, db_grants: set[str], desired: set[str], deleted_models: set[str]
) -> None:
    grants.insert += len(desired - db_grants)
    grants.unchanged += len(desired & db_grants)
    for name in db_grants - desired:
        if name in deleted_models:
            grants.cascade += 1
        else:
            grants.explicit += 1


_AGENT_QUOTA_FIELDS = ("rpm_limit", "tpm_limit", "daily_token_limit")


def _agent_equal(file_row: dict, db_row: dict) -> bool:
    """C14 compare. An absent quota field preserves the DB value.

    Present ``null`` is a real write (unlimited) and is compared.
    ``dict.get`` would turn an omission into ``None`` and count a
    preserve as an update.
    """
    if file_row["prefix"] != db_row["prefix"] or file_row["enabled"] != db_row["enabled"]:
        return False
    for name in _AGENT_QUOTA_FIELDS:
        if name not in file_row:
            continue
        if file_row[name] != db_row[name]:
            return False
    return True


def _desired_grants(
    current: dict | None,
    file_row: dict | None,
    *,
    deleted_models: set[str],
    mode: str,
    allow_foreign_keys: bool,
    warnings: list[str],
) -> set[str]:
    db_grants = set(current["model_names"]) if current else set()
    # Section skipped, or a merge keep of a key the file does not mention.
    # Model deletes still drop that key's grants (cascade). File-specified
    # names are not in this branch, so nothing here is an orphan keep.
    if allow_foreign_keys or file_row is None:
        return db_grants - deleted_models
    file_grants = set(file_row.get("model_names") or [])
    if current is None:
        return file_grants
    if mode == "merge":
        if not db_grants:
            if file_grants:
                warnings.append(
                    f"agent key {current['prefix']} is unrestricted; "
                    "merge will not add grants that would narrow it"
                )
            return set()
        return (db_grants - deleted_models) | file_grants
    return file_grants


def _post_prefix(digest, file_by, current, allow_foreign_keys: bool) -> str:
    if not allow_foreign_keys and digest in file_by:
        prefix = file_by[digest].get("prefix")
        if isinstance(prefix, str):
            return prefix
    prefix = current.get("prefix") if current else ""
    return prefix if isinstance(prefix, str) else ""


def _orphan_warning(digest, desired, surface, file_by, current, warnings) -> None:
    orphans = sorted(name for name in desired if name not in surface)
    if not orphans:
        return
    prefix = current.get("prefix") if current else None
    if digest in file_by and isinstance(file_by[digest].get("prefix"), str):
        prefix = file_by[digest]["prefix"]
    label = prefix or "agent key"
    shown = ", ".join(orphans[:8])
    warnings.append(f"agent key {label} has orphan grants not on the post-write surface: {shown}")


def _tally_settings(doc, catalog, sections) -> None:
    router = doc["router"]
    _tally_singleton(
        sections["auto_router"],
        router.get("auto_router"),
        catalog.auto_router,
        markers=True,
    )
    _tally_singleton(
        sections["auto_router_reorder"],
        router.get("auto_router_reorder"),
        catalog.auto_router_reorder,
        markers=False,
    )


def _tally_singleton(counts: _Counts, file_value, db_value, *, markers: bool) -> None:
    if not isinstance(file_value, dict):
        if isinstance(db_value, dict):
            counts.unchanged += 1
        return
    if not isinstance(db_value, dict):
        counts.insert += 1
        return
    if _settings_equal(file_value, db_value, markers=markers):
        counts.unchanged += 1
    else:
        counts.update += 1


def _settings_equal(file_value: dict, db_value: dict, *, markers: bool) -> bool:
    left = dict(file_value)
    right = dict(db_value)
    if markers:
        if isinstance(left.get("markers"), list):
            left["markers"] = sorted(left["markers"])
        if isinstance(right.get("markers"), list):
            right["markers"] = sorted(right["markers"])
    return left == right


def _cap_warnings(warnings: list[str]) -> list[str]:
    deduped: list[str] = []
    seen: set[str] = set()
    for item in warnings:
        if item in seen:
            continue
        seen.add(item)
        deduped.append(item)
    if len(deduped) <= _WARNING_CAP:
        return deduped
    extra = len(deduped) - _WARNING_CAP
    return deduped[:_WARNING_CAP] + [f"…and {extra} more"]


async def decisions_gate(doc: dict) -> None:
    """C8. Call only after the snapshot connection is checked back in.

    ``evaluate_write_gate`` takes its own pool connection (the same
    pattern as the providers router, which probes before it writes).
    Dry-run is not audited, and the restore query contract rejects
    ``force`` / ``role`` / ``reason``, so this does not call
    ``enforce_write_gate`` (that helper audits and honors break-glass)."""
    providers = doc.get("providers") or []
    if not any(
        isinstance(provider, dict) and provider.get("protocol") == "openai_decisions"
        for provider in providers
    ):
        return
    result = await decisions.evaluate_write_gate()
    if result["ok"]:
        return
    blocked = "; ".join(
        f"{verdict['node']}: {verdict['reason']}"
        for verdict in result["nodes"]
        if not verdict["ok"]
    )
    raise RestoreError(
        409,
        "decisions_gate_closed",
        "openai_decisions write gate failed (fail closed): " + blocked,
    )


def _payload_needs_router_lock(doc: dict, mode: str) -> bool:
    """C12 lock scope from the payload alone, before BEGIN.

    Replace always takes 90110011 (deletes can strand tiers). A merge
    takes it only when the document writes the auto_router singleton.
    An auto_router_reorder-only write does not.
    """
    if mode == "replace":
        return True
    router = doc.get("router")
    return isinstance(router, dict) and isinstance(router.get("auto_router"), dict)


class _ApplyConn:
    """Pooled checkout whose queries use the apply budget.

    asyncpg 0.32 has no connection-level command-timeout setter. Each
    ``execute`` / ``fetch*`` takes ``timeout``, and the pool default is
    30s, which is shorter than the 120s server statement timeout. A slow
    write would be cancelled client-side while the transaction was still
    open. This wrapper supplies the apply budget on those calls and
    leaves the pooled connection's default alone.
    """

    def __init__(self, conn) -> None:
        self._conn = conn
        self._timeout = float(_APPLY_COMMAND_TIMEOUT)

    def __getattr__(self, name):
        return getattr(self._conn, name)

    def _timeout_of(self, timeout):
        return self._timeout if timeout is None else timeout

    async def execute(self, query, *args, timeout=None):
        return await self._conn.execute(query, *args, timeout=self._timeout_of(timeout))

    async def fetch(self, query, *args, timeout=None, record_class=None):
        return await self._conn.fetch(
            query, *args, timeout=self._timeout_of(timeout), record_class=record_class
        )

    async def fetchrow(self, query, *args, timeout=None, record_class=None):
        return await self._conn.fetchrow(
            query, *args, timeout=self._timeout_of(timeout), record_class=record_class
        )

    async def fetchval(self, query, *args, column=0, timeout=None):
        return await self._conn.fetchval(
            query, *args, column=column, timeout=self._timeout_of(timeout)
        )


async def _close_quietly(conn) -> None:
    try:
        if not conn.is_closed():
            await conn.close()
    except Exception:
        # Close is the last resort after unlock failed. Any error here
        # must not replace the caller's restore result.
        logger.error("config restore connection close failed")


async def _unlock_or_close(conn) -> None:
    """Release session locks before check-in. A failed unlock closes the
    connection so the pool cannot reuse an unknown lock state (C12)."""
    if conn.is_closed():
        return
    try:
        await conn.execute("SELECT pg_advisory_unlock_all()")
    except Exception as exc:
        # Unknown lock state must not return to the pool. The exception
        # type is not predictable (driver, timeout, connection drop).
        logger.error(
            "config restore advisory unlock failed type=%s; closing connection",
            type(exc).__name__,
        )
        await _close_quietly(conn)


async def _lock_for_apply(conn, doc: dict, mode: str) -> None:
    """Try-locks outside any transaction. 90110011 first when the payload
    needs it, then 90110015. A busy second lock releases the first."""
    keys = [RESTORE_ADVISORY_LOCK]
    if _payload_needs_router_lock(doc, mode):
        keys.insert(0, ADVISORY_XACT_KEY)
    held: list[int] = []
    for key in keys:
        try:
            got = await conn.fetchval("SELECT pg_try_advisory_lock($1)", key)
        except Exception as exc:
            logger.error(
                "config restore lock acquire failed key=%s type=%s",
                key,
                type(exc).__name__,
            )
            await _close_quietly(conn)
            raise RestoreError(500, "apply_failed", "restore apply failed") from exc
        if got:
            held.append(key)
            continue
        for previous in held:
            try:
                await conn.execute("SELECT pg_advisory_unlock($1)", previous)
            except Exception as exc:
                logger.error(
                    "config restore predecessor unlock failed key=%s type=%s",
                    previous,
                    type(exc).__name__,
                )
                await _close_quietly(conn)
                raise RestoreError(500, "apply_failed", "restore apply failed") from exc
        raise RestoreError(409, "restore_busy", f"advisory lock {key} is held")


def _map_apply_error(exc: BaseException) -> RestoreError:
    sqlstate = getattr(exc, "sqlstate", None)
    if sqlstate in _CONFLICT_SQLSTATES:
        logger.warning("config restore conflict sqlstate=%s", sqlstate)
        return RestoreError(
            409,
            "restore_conflict",
            "restore conflicted with a concurrent writer; retry",
        )
    if isinstance(exc, asyncpg.PostgresError):
        logger.error("config restore apply failed sqlstate=%s", sqlstate)
    else:
        logger.error("config restore apply failed type=%s", type(exc).__name__)
    return RestoreError(500, "apply_failed", "restore apply failed")


def _source_config_generation(doc: dict) -> int:
    source = doc.get("source")
    if not isinstance(source, dict):
        return 0
    value = source.get("config_generation")
    if isinstance(value, bool) or not isinstance(value, int):
        return 0
    return value


def _claimed_hash(doc: dict | None) -> str | None:
    if not isinstance(doc, dict):
        return None
    integrity = doc.get("integrity")
    if isinstance(integrity, dict) and isinstance(integrity.get("payload_sha256"), str):
        return integrity["payload_sha256"]
    return None


def _audit_detail(
    *,
    mode: str | None,
    allow_foreign_keys: bool,
    sections,
    generation: int | None,
    error: str | None,
    message: str | None,
    claimed: str | None,
    recomputed: str | None,
) -> str:
    """One audit row. replace / allow_foreign_keys are their own lines."""
    lines = [
        f"mode={mode or ''}",
        "actor=console",
        f"allow_foreign_keys={1 if allow_foreign_keys else 0}",
    ]
    if mode == "replace":
        lines.append("replace actor=console")
    if allow_foreign_keys:
        lines.append("allow_foreign_keys actor=console")
    if error:
        lines.append(f"error={error}")
    if message:
        lines.append(f"message={message}")
    if generation is not None:
        lines.append(f"generation={generation}")
    elif error is None:
        lines.append("noop=true")
    if sections is not None:
        lines.append(
            "sections="
            + json.dumps(sections, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        )
    if claimed is not None:
        lines.append(f"claimed_payload_sha256={claimed}")
    if recomputed is not None:
        lines.append(f"recomputed_payload_sha256={recomputed}")
    return "\n".join(lines)


async def _insert_audit_rows(conn, rows: list[tuple[str, str | None, str]]) -> None:
    for action, target, detail in rows:
        await conn.execute(
            "INSERT INTO audit_events (actor, action, target, detail) "
            "VALUES ('console', $1, $2, $3)",
            action,
            target,
            detail,
        )


async def _audit_in_savepoint(conn, rows: list[tuple[str, str | None, str]]) -> bool:
    """True when the savepoint landed. Failure rolls back only the audit."""
    try:
        async with conn.transaction():
            await _insert_audit_rows(conn, rows)
        return True
    except Exception as exc:
        # Audit must not abort a committed restore (C4). The driver error
        # class varies; the savepoint rollback is the whole point.
        logger.error("config restore audit savepoint failed type=%s", type(exc).__name__)
        return False


async def _audit_best_effort(rows: list[tuple[str, str | None, str]]) -> None:
    try:
        async with database.pool().acquire() as conn, conn.transaction():
            await _insert_audit_rows(conn, rows)
    except Exception as exc:
        logger.error("config restore audit write failed type=%s", type(exc).__name__)


async def audit_apply_attempt(
    doc: dict | None,
    exc: RestoreError,
    *,
    mode: str | None,
    allow_foreign_keys: bool,
) -> None:
    """Best-effort refusal/abort audit. Caller runs this only after unlock."""
    claimed = _claimed_hash(doc)
    recomputed = None
    if exc.code == "integrity_mismatch" and isinstance(doc, dict):
        try:
            recomputed = payload_sha256(sort_document_arrays(doc))
        except (TypeError, ValueError):
            logger.error("config restore audit could not recompute payload_sha256")
    detail = _audit_detail(
        mode=mode,
        allow_foreign_keys=allow_foreign_keys,
        sections=None,
        generation=None,
        error=exc.code,
        message=str(exc),
        claimed=claimed if exc.code == "integrity_mismatch" else None,
        recomputed=recomputed,
    )
    await _audit_best_effort([("config_backup.restore", claimed, detail)])


async def apply_restore(doc: dict, *, mode: str, allow_foreign_keys: bool) -> dict:
    """Locked apply. The caller must already have run ``decisions_gate``
    with no pool connection held — the probe acquires its own."""
    fallback: list[tuple[str, str | None, str]] | None = None
    response: dict | None = None
    async with database.pool().acquire() as raw:
        conn = _ApplyConn(raw)
        try:
            await _lock_for_apply(conn, doc, mode)
            try:
                async with conn.transaction(isolation="repeatable_read"):
                    await conn.execute("SET LOCAL statement_timeout = '120s'")
                    await conn.execute("SET LOCAL idle_in_transaction_session_timeout = '120s'")
                    plan = await preflight(
                        doc,
                        snapshot_conn=conn,
                        mode=mode,
                        allow_foreign_keys=allow_foreign_keys,
                        reuse_trial_decrypt=True,
                        in_transaction=True,
                    )
                    if plan.catalog is None:
                        raise RestoreError(500, "apply_failed", "restore apply failed")
                    generation, breakglass = await _apply_writes(
                        conn,
                        doc,
                        plan.catalog,
                        mode=mode,
                        allow_foreign_keys=allow_foreign_keys,
                    )
                    if plan.would_noop == (generation is not None):
                        logger.error(
                            "restore apply noop mismatch plan_would_noop=%s bumped=%s",
                            plan.would_noop,
                            generation is not None,
                        )
                    response = plan.to_apply_response(
                        generation=generation,
                        source_config_generation=_source_config_generation(doc),
                    )
                    rows = _success_audit_rows(
                        doc,
                        plan,
                        mode=mode,
                        allow_foreign_keys=allow_foreign_keys,
                        generation=generation,
                        breakglass=breakglass,
                    )
                    if not await _audit_in_savepoint(conn, rows):
                        fallback = rows
            except RestoreError:
                raise
            except Exception as exc:
                raise _map_apply_error(exc) from exc
        finally:
            await _unlock_or_close(conn)
    if fallback:
        await _audit_best_effort(fallback)
    if response is None:
        raise RestoreError(500, "apply_failed", "restore apply failed")
    return response


def _success_audit_rows(
    doc: dict,
    plan: Plan,
    *,
    mode: str,
    allow_foreign_keys: bool,
    generation: int | None,
    breakglass: list[tuple[str, str]],
) -> list[tuple[str, str | None, str]]:
    detail = _audit_detail(
        mode=mode,
        allow_foreign_keys=allow_foreign_keys,
        sections=plan.sections,
        generation=generation,
        error=None,
        message=None,
        claimed=None,
        recomputed=None,
    )
    rows = [("config_backup.restore", _claimed_hash(doc), detail)]
    for target, line in breakglass:
        rows.append(("provider.allow_internal", target, line))
    return rows


_DELETE_TABLES = frozenset({"models", "provider_models", "provider_keys", "providers", "api_keys"})


async def _delete_ids(conn, table: str, ids: list[int]) -> None:
    if table not in _DELETE_TABLES:
        raise RestoreError(500, "apply_failed", "restore apply failed")
    await conn.execute(f"DELETE FROM {table} WHERE id = ANY($1::bigint[])", ids)


async def _delete_route_pairs(conn, pairs: list[tuple[int, int]]) -> None:
    await conn.execute(
        "DELETE FROM model_routes mr "
        "USING unnest($1::bigint[], $2::bigint[]) AS d(model_id, provider_id) "
        "WHERE mr.model_id = d.model_id AND mr.provider_id = d.provider_id",
        [pair[0] for pair in pairs],
        [pair[1] for pair in pairs],
    )


async def _replace_deletes(
    conn, doc: dict, catalog: _Catalog, post: dict, *, allow_foreign_keys: bool
) -> bool:
    """Snapshot ids only. A row inserted after this transaction's snapshot
    is not in the list, so it survives (C9)."""
    dirty = False
    file_slots = set(post["file_routes"])
    pairs = [
        (route["model_id"], route["provider_id"])
        for route in catalog.routes
        if (route["model"], route["provider"]) not in file_slots
    ]
    if pairs:
        await _delete_route_pairs(conn, pairs)
        dirty = True
    model_ids = [row["id"] for row in catalog.models if row["name"] not in post["file_models"]]
    if model_ids:
        await _delete_ids(conn, "models", model_ids)
        dirty = True
    listing_ids: list[int] = []
    key_ids: list[int] = []
    for provider in catalog.providers:
        file_provider = post["file_providers"].get(provider["name"])
        file_listing_names = (
            {item["name"] for item in file_provider["listings"]} if file_provider else set()
        )
        file_secrets = (
            {_b64_bytes(item["secret_ciphertext_b64"]) for item in file_provider["keys"]}
            if file_provider
            else set()
        )
        for listing in provider["listings"]:
            if listing["name"] not in file_listing_names:
                listing_ids.append(listing["id"])
        for key in provider["keys"]:
            if key["secret"] not in file_secrets:
                key_ids.append(key["id"])
    if listing_ids:
        await _delete_ids(conn, "provider_models", listing_ids)
        dirty = True
    if key_ids:
        await _delete_ids(conn, "provider_keys", key_ids)
        dirty = True
    provider_ids = [
        row["id"] for row in catalog.providers if row["name"] not in post["file_providers"]
    ]
    if provider_ids:
        await _delete_ids(conn, "providers", provider_ids)
        dirty = True
    if not allow_foreign_keys:
        file_hashes = {_agent_hash(row) for row in doc["agent_keys"]}
        gone = [row["id"] for row in catalog.agent_keys if row["key_hash"] not in file_hashes]
        if gone:
            await conn.execute(
                "DELETE FROM api_key_models WHERE api_key_id = ANY($1::bigint[])",
                gone,
            )
            await _delete_ids(conn, "api_keys", gone)
            dirty = True
    return dirty


async def _apply_writes(
    conn,
    doc: dict,
    catalog: _Catalog,
    *,
    mode: str,
    allow_foreign_keys: bool,
) -> tuple[int | None, list[tuple[str, str]]]:
    post = _post_world(doc, catalog, mode=mode, allow_foreign_keys=allow_foreign_keys)
    dirty = False
    breakglass: list[tuple[str, str]] = []
    if mode == "replace":
        dirty = await _replace_deletes(
            conn, doc, catalog, post, allow_foreign_keys=allow_foreign_keys
        )
    provider_ids = {row["name"]: row["id"] for row in catalog.providers}
    model_ids = {row["name"]: row["id"] for row in catalog.models}
    wrote, more = await _upsert_providers(conn, post, provider_ids)
    dirty = dirty or wrote
    breakglass.extend(more)
    # Await before combining with ``dirty``. ``dirty or await ...`` skips
    # every later section once an earlier one wrote, so a new provider
    # never received its keys, listings, routes, grants, or settings.
    dirty = await _upsert_provider_keys(conn, post, provider_ids) or dirty
    dirty = await _upsert_listings(conn, post, provider_ids) or dirty
    dirty = await _upsert_models(conn, doc, catalog, model_ids) or dirty
    dirty = await _upsert_routes(conn, post, provider_ids, model_ids) or dirty
    agent_ids = {row["key_hash"]: row["id"] for row in catalog.agent_keys}
    if not allow_foreign_keys:
        dirty = await _upsert_agent_keys(conn, doc, catalog, agent_ids) or dirty
    dirty = (
        await _sync_grants(
            conn,
            doc,
            catalog,
            post,
            agent_ids,
            mode=mode,
            allow_foreign_keys=allow_foreign_keys,
        )
        or dirty
    )
    dirty = await _write_settings(conn, doc, catalog) or dirty
    await _duplicate_scan(conn)
    if not dirty:
        return None, breakglass
    generation = await database.bump_generation(conn)
    if isinstance(generation, bool) or not isinstance(generation, int):
        logger.error("config_meta bump returned no generation")
        raise RestoreError(500, "apply_failed", "restore apply failed")
    return generation, breakglass


async def _upsert_providers(
    conn, post: dict, provider_ids: dict[str, int]
) -> tuple[bool, list[tuple[str, str]]]:
    dirty = False
    breakglass: list[tuple[str, str]] = []
    for name, row in post["file_providers"].items():
        current = post["db_providers"].get(name)
        if current is not None and _provider_equal(row, current):
            continue
        # SSRF write gate at the write itself (review 03c H2): the dry
        # run/preflight already refused an internal base, but every
        # base_url mutation must pass the same gate as POST/PUT
        # /api/providers — including a later direct caller. Blocking
        # DNS, hence off-loop; allow_internal skips the classification.
        await asyncio.to_thread(_ssrf_base_url_gate, row["base_url"], bool(row["allow_internal"]))
        enabled = 1 if row["enabled"] else 0
        allow = 1 if row["allow_internal"] else 0
        if current is None:
            inserted = await conn.fetchrow(
                "INSERT INTO providers ("
                "name, base_url, protocol, enabled, region_tag, affinity_node, allow_internal"
                ") VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id",
                name,
                row["base_url"],
                row["protocol"],
                enabled,
                row["region_tag"],
                row["affinity_node"],
                allow,
            )
            pid = inserted["id"]
            provider_ids[name] = pid
        else:
            pid = current["id"]
            await conn.execute(
                "UPDATE providers SET base_url = $2, protocol = $3, enabled = $4, "
                "region_tag = $5, affinity_node = $6, allow_internal = $7 WHERE id = $1",
                pid,
                row["base_url"],
                row["protocol"],
                enabled,
                row["region_tag"],
                row["affinity_node"],
                allow,
            )
        dirty = True
        if row["allow_internal"]:
            # Audit EVERY break-glass write, not only a 0->1 transition:
            # a restored allow_internal=1 row is exactly the bypass the
            # SSRF gate is meant to leave visible (review 03c H2). An
            # insert has no prior row (before=0).
            before = 0 if current is None else (1 if current["allow_internal"] else 0)
            breakglass.append(
                (
                    f"provider:{pid}",
                    (
                        f"actor=console before={before} after=1 "
                        f"name={name} base_url={row['base_url']} via=config_backup.restore"
                    ),
                )
            )
    return dirty, breakglass


async def _upsert_provider_keys(conn, post: dict, provider_ids: dict[str, int]) -> bool:
    dirty = False
    for name, row in post["file_providers"].items():
        pid = provider_ids.get(name)
        if pid is None:
            logger.error("restore provider %s has no id", name)
            raise RestoreError(500, "apply_failed", "restore apply failed")
        current = post["db_providers"].get(name)
        db_by = {key["secret"]: key for key in (current["keys"] if current else [])}
        for key in row["keys"]:
            secret = _b64_bytes(key["secret_ciphertext_b64"])
            match = db_by.get(secret)
            enabled = 1 if key["enabled"] else 0
            if match is None:
                await conn.execute(
                    "INSERT INTO provider_keys ("
                    "provider_id, secret_ciphertext, key_id, weight, enabled"
                    ") VALUES ($1, $2, $3, $4, $5)",
                    pid,
                    secret,
                    key["key_id"],
                    key["weight"],
                    enabled,
                )
                dirty = True
            elif not _key_equal(key, match):
                await conn.execute(
                    "UPDATE provider_keys SET key_id = $2, weight = $3, enabled = $4 WHERE id = $1",
                    match["id"],
                    key["key_id"],
                    key["weight"],
                    enabled,
                )
                dirty = True
    return dirty


async def _upsert_listings(conn, post: dict, provider_ids: dict[str, int]) -> bool:
    dirty = False
    for name, row in post["file_providers"].items():
        pid = provider_ids.get(name)
        if pid is None:
            logger.error("restore provider %s has no id", name)
            raise RestoreError(500, "apply_failed", "restore apply failed")
        current = post["db_providers"].get(name)
        db_by = {item["name"]: item for item in (current["listings"] if current else [])}
        for listing in row["listings"]:
            match = db_by.get(listing["name"])
            enabled = 1 if listing["enabled"] else 0
            if match is None:
                await conn.execute(
                    "INSERT INTO provider_models (provider_id, name, enabled, modality) "
                    "VALUES ($1, $2, $3, $4)",
                    pid,
                    listing["name"],
                    enabled,
                    listing["modality"],
                )
                dirty = True
            elif listing["enabled"] != match["enabled"] or listing["modality"] != match["modality"]:
                await conn.execute(
                    "UPDATE provider_models SET enabled = $2, modality = $3 WHERE id = $1",
                    match["id"],
                    enabled,
                    listing["modality"],
                )
                dirty = True
    return dirty


async def _upsert_models(conn, doc: dict, catalog: _Catalog, model_ids: dict[str, int]) -> bool:
    dirty = False
    db_by = {row["name"]: row for row in catalog.models}
    for row in doc["router"]["models"]:
        current = db_by.get(row["name"])
        enabled = 1 if row["enabled"] else 0
        if current is None:
            inserted = await conn.fetchrow(
                "INSERT INTO models (name, enabled) VALUES ($1, $2) RETURNING id",
                row["name"],
                enabled,
            )
            model_ids[row["name"]] = inserted["id"]
            dirty = True
        elif row["enabled"] != current["enabled"]:
            await conn.execute(
                "UPDATE models SET enabled = $2 WHERE id = $1",
                current["id"],
                enabled,
            )
            dirty = True
    return dirty


def _stored_upstream(row: dict):
    upstream = row.get("upstream_model_id")
    if isinstance(upstream, str) and upstream:
        return upstream
    return None


async def _upsert_routes(
    conn, post: dict, provider_ids: dict[str, int], model_ids: dict[str, int]
) -> bool:
    dirty = False
    for (model, provider), row in post["file_routes"].items():
        current = post["db_routes"].get((model, provider))
        if current is not None and _route_equal(row, current):
            continue
        mid = model_ids.get(model)
        pid = provider_ids.get(provider)
        if mid is None or pid is None:
            logger.error("restore route %s/%s has no id after upsert", model, provider)
            raise RestoreError(500, "apply_failed", "restore apply failed")
        enabled = 1 if row["enabled"] else 0
        upstream = _stored_upstream(row)
        if current is None:
            await conn.execute(
                "INSERT INTO model_routes ("
                "model_id, provider_id, upstream_model_id, weight, priority, enabled"
                ") VALUES ($1, $2, $3, $4, $5, $6)",
                mid,
                pid,
                upstream,
                row["weight"],
                row["priority"],
                enabled,
            )
        else:
            await conn.execute(
                "UPDATE model_routes SET upstream_model_id = $3, weight = $4, "
                "priority = $5, enabled = $6 WHERE model_id = $1 AND provider_id = $2",
                mid,
                pid,
                upstream,
                row["weight"],
                row["priority"],
                enabled,
            )
        dirty = True
    return dirty


def _quota(row: dict, name: str):
    if name not in row:
        return None
    return row[name]


def _inserted_created_at(row: dict) -> datetime | None:
    if "created_at" not in row or row["created_at"] is None:
        return None
    raw = row["created_at"]
    if not isinstance(raw, str) or raw == "":
        return None
    text = raw[:-1] + "+00:00" if raw.endswith("Z") else raw
    try:
        return datetime.fromisoformat(text)
    except ValueError as exc:
        logger.error("agent key created_at is not RFC3339")
        raise RestoreError(500, "apply_failed", "restore apply failed") from exc


async def _update_agent_key(conn, key_id: int, row: dict, enabled: int) -> None:
    sets = ["prefix = $2", "enabled = $3"]
    args: list = [key_id, row["prefix"], enabled]
    for name in _AGENT_QUOTA_FIELDS:
        if name not in row:
            continue
        args.append(row[name])
        sets.append(f"{name} = ${len(args)}")
    await conn.execute(f"UPDATE api_keys SET {', '.join(sets)} WHERE id = $1", *args)


async def _upsert_agent_keys(
    conn, doc: dict, catalog: _Catalog, agent_ids: dict[bytes, int]
) -> bool:
    dirty = False
    db_by = {row["key_hash"]: row for row in catalog.agent_keys}
    for row in doc["agent_keys"]:
        digest = _agent_hash(row)
        current = db_by.get(digest)
        enabled = 1 if row["enabled"] else 0
        if current is None:
            created = _inserted_created_at(row)
            quotas = [_quota(row, name) for name in _AGENT_QUOTA_FIELDS]
            if created is None:
                inserted = await conn.fetchrow(
                    "INSERT INTO api_keys ("
                    "prefix, key_hash, enabled, rpm_limit, tpm_limit, daily_token_limit"
                    ") VALUES ($1, $2, $3, $4, $5, $6) RETURNING id",
                    row["prefix"],
                    digest,
                    enabled,
                    *quotas,
                )
            else:
                inserted = await conn.fetchrow(
                    "INSERT INTO api_keys ("
                    "prefix, key_hash, enabled, rpm_limit, tpm_limit, "
                    "daily_token_limit, created_at"
                    ") VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id",
                    row["prefix"],
                    digest,
                    enabled,
                    *quotas,
                    created,
                )
            agent_ids[digest] = inserted["id"]
            dirty = True
            continue
        if _agent_equal(row, current):
            continue
        await _update_agent_key(conn, current["id"], row, enabled)
        dirty = True
    return dirty


async def _sync_grants(
    conn,
    doc: dict,
    catalog: _Catalog,
    post: dict,
    agent_ids: dict[bytes, int],
    *,
    mode: str,
    allow_foreign_keys: bool,
) -> bool:
    """Name-based grant diff. Pre-022 targets skip this: model and key
    deletes cascade through the model_id foreign key."""
    if _NAME_GRANTS not in set(catalog.migrations):
        return False
    dirty = False
    file_by = {} if allow_foreign_keys else {_agent_hash(row): row for row in doc["agent_keys"]}
    db_by = {row["key_hash"]: row for row in catalog.agent_keys}
    deleted_models = set(post["db_models"]) - set(post["models"])
    discarded: list[str] = []
    for digest, current in db_by.items():
        if digest not in post["agent_keys"]:
            continue
        desired = _desired_grants(
            current,
            None if allow_foreign_keys else file_by.get(digest),
            deleted_models=deleted_models,
            mode=mode,
            allow_foreign_keys=allow_foreign_keys,
            warnings=discarded,
        )
        db_grants = set(current["model_names"])
        key_id = agent_ids[digest]
        for name in sorted(db_grants - desired):
            await conn.execute(
                "DELETE FROM api_key_models WHERE api_key_id = $1 AND model_name = $2",
                key_id,
                name,
            )
            dirty = True
        for name in sorted(desired - db_grants):
            await conn.execute(
                "INSERT INTO api_key_models (api_key_id, model_name) VALUES ($1, $2)",
                key_id,
                name,
            )
            dirty = True
    if allow_foreign_keys:
        return dirty
    for digest, row in file_by.items():
        if digest in db_by:
            continue
        key_id = agent_ids[digest]
        names = list(row.get("model_names") or [])
        for name in names:
            await conn.execute(
                "INSERT INTO api_key_models (api_key_id, model_name) VALUES ($1, $2)",
                key_id,
                name,
            )
            dirty = True
    return dirty


def _singleton_changed(file_value, db_value, *, markers: bool) -> bool:
    if not isinstance(file_value, dict):
        return False
    if not isinstance(db_value, dict):
        return True
    return not _settings_equal(file_value, db_value, markers=markers)


def _tiers_changed(file_value, db_value) -> bool:
    """Order-sensitive. Judge, markers, and reorder knobs do not hold."""
    if not isinstance(file_value, dict):
        return False
    file_tiers = file_value.get("tiers")
    if not isinstance(file_tiers, dict):
        return False
    db_tiers = db_value.get("tiers") if isinstance(db_value, dict) else None
    if not isinstance(db_tiers, dict):
        return True
    for tier in TIERS:
        if list(file_tiers.get(tier) or []) != list(db_tiers.get(tier) or []):
            return True
    return False


async def _upsert_setting(conn, key: str, value: dict) -> None:
    await conn.execute(
        "INSERT INTO settings (key, value) VALUES ($1, $2::jsonb) "
        "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
        key,
        json.dumps(value, ensure_ascii=False),
    )


async def _write_settings(conn, doc: dict, catalog: _Catalog) -> bool:
    dirty = False
    router = doc["router"]
    file_router = router.get("auto_router")
    if _singleton_changed(file_router, catalog.auto_router, markers=True):
        await _upsert_setting(conn, "auto_router", file_router)
        dirty = True
    file_reorder = router.get("auto_router_reorder")
    if _singleton_changed(file_reorder, catalog.auto_router_reorder, markers=False):
        await _upsert_setting(conn, "auto_router_reorder", file_reorder)
        dirty = True
    if _tiers_changed(file_router, catalog.auto_router):
        await conn.execute(
            """
            INSERT INTO auto_router_state (
                id, pending_tiers, lease_owner, lease_until, last_manual_edit_at
            ) VALUES (1, NULL, NULL, NULL, NOW())
            ON CONFLICT (id) DO UPDATE SET
                pending_tiers = NULL,
                lease_owner = NULL,
                lease_until = NULL,
                last_manual_edit_at = NOW()
            """
        )
        dirty = True
    return dirty


async def _duplicate_scan(conn) -> None:
    found = await conn.fetchval(
        """
        SELECT 1 WHERE EXISTS (
            SELECT 1 FROM providers GROUP BY name HAVING COUNT(*) > 1
        ) OR EXISTS (
            SELECT 1 FROM models GROUP BY name HAVING COUNT(*) > 1
        ) OR EXISTS (
            SELECT 1 FROM model_routes
            GROUP BY model_id, provider_id HAVING COUNT(*) > 1
        )
        """
    )
    if found is not None:
        raise RestoreError(
            409,
            "restore_conflict",
            "post-write duplicate scan found a duplicate provider, model, or route",
        )
