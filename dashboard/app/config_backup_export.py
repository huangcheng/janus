"""Assemble a v1 config-backup document (spec §5.2).

The catalog read is one REPEATABLE READ snapshot with a 30s statement
timeout and a 30s idle-in-transaction timeout. ``statement_timeout``
alone does not bound an abandoned idle transaction (C12). The
transaction is READ ONLY so this path cannot bump ``config_generation``.

Export never decrypts provider keys (C1). BYTEA leaves as standard
base64; SMALLINT 0/1 leaves as JSON booleans. Refusals raise
:class:`ExportError` and are not audited.
"""

import asyncio
import base64
import hashlib
import json
import logging
import os
import re
import socket
import subprocess
from datetime import UTC, datetime

import asyncpg
from jsonschema.exceptions import SchemaError

from .config import config
from .config_backup_canon import derive_key_ids, payload_sha256, sort_document_arrays
from .config_backup_migrations import full_config_affecting_migrations
from .config_backup_schema import load_schema
from .crypto import _active_key, encrypt

logger = logging.getLogger("janus.dashboard.config_backup")

_CANARY_PLAINTEXT = b"janus-config-backup-canary-v1"
_PEPPER_CANARY_SALT = b"janus-pepper-canary-v1"
_TIMEOUT_SQLSTATES = frozenset({"57014", "25P03"})
_SHA_RE = re.compile(r"[0-9a-fA-F]{4,40}")

_DASHBOARD_VERSION: str | None = None
_VALIDATOR = None


class ExportError(Exception):
    """Export refused before a body is sent. ``code`` is the HTTP error code."""

    def __init__(self, message: str, *, code: str = "export_invalid") -> None:
        super().__init__(message)
        self.code = code


def dashboard_version() -> str:
    """Image git SHA label, else ``git rev-parse --short HEAD``, else ``unknown``.

    Cached for the process. The lifespan calls this at startup so the
    git fallback does not run on the export request.
    """
    global _DASHBOARD_VERSION
    if _DASHBOARD_VERSION is None:
        _DASHBOARD_VERSION = _resolve_dashboard_version()
    return _DASHBOARD_VERSION


def attachment_filename(taken_at: str) -> str:
    """``janus-config-<yyyymmddTHHMMSSZ>.json`` with no colons (spec §5.2)."""
    if not isinstance(taken_at, str) or not taken_at.endswith("Z"):
        raise ExportError("taken_at is not a UTC timestamp")
    body = taken_at[:-1]
    if "." in body:
        body = body.split(".", 1)[0]
    # YYYY-MM-DDTHH:MM:SS
    if (
        len(body) != 19
        or body[4] != "-"
        or body[7] != "-"
        or body[10] != "T"
        or body[13] != ":"
        or body[16] != ":"
    ):
        raise ExportError("taken_at is not a UTC timestamp")
    stamp = body[:4] + body[5:7] + body[8:10] + "T" + body[11:13] + body[14:16] + body[17:19] + "Z"
    return f"janus-config-{stamp}.json"


def pepper_canary_hash(pepper: str) -> str:
    """SHA256(``janus-pepper-canary-v1`` || pepper), lowercase hex.

    Same bytes as ``scripts/lib/janus_backup_common.sh`` ``pepper_canary_hash``.
    """
    return hashlib.sha256(_PEPPER_CANARY_SALT + pepper.encode("utf-8")).hexdigest()


async def build_backup_document(conn) -> dict:
    """Read ``conn`` inside one REPEATABLE READ transaction and return the document.

    Schema load and the active keyring are checked before BEGIN so a
    cheap refusal does not hold a snapshot. Canary mint, hash, and
    schema self-check run after the snapshot is released; they do not
    read the database. Those steps are synchronous, so they run in a
    worker thread and do not stall the event loop.
    """
    validator = await asyncio.to_thread(_require_export_prerequisites)
    try:
        async with conn.transaction(isolation="repeatable_read", readonly=True):
            # Both bounds: a stuck statement and an idle open transaction
            # (the vacuum hazard C12 names).
            await conn.execute("SET LOCAL statement_timeout = '30s'")
            await conn.execute("SET LOCAL idle_in_transaction_session_timeout = '30s'")
            snapshot = await _read_snapshot(conn)
    except ExportError:
        raise
    except (asyncpg.PostgresError, TimeoutError) as exc:
        raise _from_db(exc) from exc
    return await asyncio.to_thread(_document_from_snapshot, snapshot, validator)


def _resolve_dashboard_version() -> str:
    labeled = os.environ.get("JANUS_GIT_SHA", "").strip()
    if labeled and labeled != "unknown":
        return labeled
    sha = _git_short_head()
    if sha:
        return sha
    return "unknown"


def _git_short_head() -> str | None:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    sha = proc.stdout.strip()
    if proc.returncode != 0 or not _SHA_RE.fullmatch(sha):
        return None
    return sha


def _require_export_prerequisites():
    try:
        _active_key()
    except ValueError as exc:
        raise ExportError("no active keyring; canary cannot be minted") from exc
    return _load_validator()


def _load_validator():
    """Return the process-cached validator. Load failures stay off the client."""
    global _VALIDATOR
    if _VALIDATOR is not None:
        return _VALIDATOR
    try:
        validator = load_schema()
    except (OSError, ValueError, SchemaError) as exc:
        logger.warning(
            "config-backup schema failed to load",
            exc_info=(type(exc), exc, exc.__traceback__),
        )
        raise ExportError("config-backup schema failed to load") from exc
    schema_id = validator.schema.get("$id")
    if not isinstance(schema_id, str) or not schema_id:
        raise ExportError("config-backup schema is missing $id")
    _VALIDATOR = validator
    return validator


def _is_timeout(exc: BaseException) -> bool:
    if isinstance(exc, TimeoutError):
        return True
    return getattr(exc, "sqlstate", None) in _TIMEOUT_SQLSTATES


def _from_db(exc: BaseException) -> ExportError:
    if _is_timeout(exc):
        return ExportError(
            "export snapshot exceeded its 30s bound",
            code="snapshot_timeout",
        )
    logger.warning(
        "config backup export read failed",
        exc_info=(type(exc), exc, exc.__traceback__),
    )
    sqlstate = getattr(exc, "sqlstate", None)
    if sqlstate == "42703":
        return ExportError("source schema is missing a column the exporter reads")
    if sqlstate == "42P01":
        return ExportError("source schema is missing a table the exporter reads")
    return ExportError("export failed while reading the catalog")


def _taken_at() -> str:
    moment = datetime.now(UTC).replace(microsecond=0)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def _flag(value: object, field: str) -> bool:
    """SMALLINT 0/1 → JSON boolean (C6). ``bool`` is an ``int`` subclass, so it is rejected."""
    if isinstance(value, bool) or not isinstance(value, int) or value not in (0, 1):
        raise ExportError(f"{field} is not a 0/1 flag")
    return value == 1


def _integer(value: object, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ExportError(f"{field} is not an integer")
    return value


def _quota(value: object, field: str) -> int | None:
    if value is None:
        return None
    return _integer(value, field)


def _text(value: object, field: str) -> str:
    if isinstance(value, str):
        return value
    raise ExportError(f"{field} is not text")


def _optional_text(value: object, field: str) -> str | None:
    if value is None:
        return None
    return _text(value, field)


def _b64(value: object, field: str) -> str:
    """Standard padded base64 (RFC 4648), not url-safe."""
    if isinstance(value, memoryview):
        value = value.tobytes()
    elif isinstance(value, bytearray):
        value = bytes(value)
    if not isinstance(value, bytes) or not value:
        raise ExportError(f"{field} is not bytea")
    return base64.b64encode(value).decode("ascii")


def _created_at(value: object) -> str:
    if not isinstance(value, datetime):
        raise ExportError("api_keys.created_at is not a timestamp")
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    else:
        value = value.astimezone(UTC)
    return value.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _json_value(raw: object, field: str) -> object:
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode()
    if isinstance(raw, str):
        try:
            return json.loads(raw)
        except ValueError as exc:
            raise ExportError(f"{field} is not valid JSON") from exc
    if isinstance(raw, dict):
        # Round-trip so a driver-decoded object becomes plain JSON types
        # (and so a non-JSON value fails closed instead of reaching the hash).
        try:
            return json.loads(json.dumps(raw))
        except (TypeError, ValueError) as exc:
            raise ExportError(f"{field} is not valid JSON") from exc
    raise ExportError(f"{field} is not valid JSON")


def _settings_object(raw: object, field: str) -> dict | None:
    if raw is None:
        return None
    parsed = _json_value(raw, field)
    if parsed is None:
        return None
    if isinstance(parsed, dict):
        return parsed
    raise ExportError(f"{field} is not a JSON object")


def _host_label() -> str | None:
    try:
        label = socket.gethostname().strip()
    except OSError:
        return None
    return label or None


async def _read_snapshot(conn) -> dict:
    taken_at = _taken_at()
    try:
        migration_rows = await conn.fetch("SELECT version FROM schema_migrations")
    except asyncpg.UndefinedTableError as exc:
        missing = ", ".join(sorted(full_config_affecting_migrations()))
        raise ExportError(f"source missing config-affecting migrations: {missing}") from exc
    applied = sorted(row["version"] for row in migration_rows if isinstance(row["version"], str))
    missing_versions = sorted(full_config_affecting_migrations() - set(applied))
    if not applied or missing_versions:
        listed = missing_versions or sorted(full_config_affecting_migrations())
        raise ExportError("source missing config-affecting migrations: " + ", ".join(listed))

    generation = await conn.fetchval("SELECT config_generation FROM config_meta WHERE id = 1")
    if generation is None:
        raise ExportError("source config_meta row is missing")

    providers = await conn.fetch(
        "SELECT id, name, base_url, protocol, enabled, region_tag, "
        "affinity_node, allow_internal FROM providers ORDER BY id"
    )
    key_rows = await conn.fetch(
        "SELECT provider_id, key_id, weight, enabled, secret_ciphertext "
        "FROM provider_keys ORDER BY id"
    )
    listing_rows = await conn.fetch(
        "SELECT provider_id, name, enabled, modality FROM provider_models ORDER BY id"
    )
    agent_rows = await conn.fetch(
        "SELECT id, prefix, key_hash, enabled, created_at, "
        "rpm_limit, tpm_limit, daily_token_limit "
        "FROM api_keys ORDER BY id"
    )
    grant_rows = await conn.fetch(
        "SELECT api_key_id, model_name FROM api_key_models ORDER BY api_key_id, model_name"
    )
    model_rows = await conn.fetch("SELECT id, name, enabled FROM models ORDER BY id")
    route_rows = await conn.fetch(
        "SELECT m.name AS model_name, p.name AS provider_name, "
        "mr.upstream_model_id, mr.weight, mr.priority, mr.enabled "
        "FROM model_routes mr "
        "JOIN models m ON m.id = mr.model_id "
        "JOIN providers p ON p.id = mr.provider_id "
        "ORDER BY m.name, p.name"
    )
    setting_rows = await conn.fetch(
        "SELECT key, value FROM settings WHERE key IN ('auto_router', 'auto_router_reorder')"
    )

    keys_by: dict[int, list[dict]] = {}
    for row in key_rows:
        keys_by.setdefault(row["provider_id"], []).append(
            {
                "key_id": _text(row["key_id"], "provider_keys.key_id"),
                "weight": _integer(row["weight"], "provider_keys.weight"),
                "enabled": _flag(row["enabled"], "provider_keys.enabled"),
                "secret_ciphertext_b64": _b64(
                    row["secret_ciphertext"], "provider_keys.secret_ciphertext"
                ),
            }
        )
    listings_by: dict[int, list[dict]] = {}
    for row in listing_rows:
        listings_by.setdefault(row["provider_id"], []).append(
            {
                "name": _text(row["name"], "provider_models.name"),
                "enabled": _flag(row["enabled"], "provider_models.enabled"),
                "modality": _text(row["modality"], "provider_models.modality"),
            }
        )
    provider_docs = [
        {
            "name": _text(row["name"], "providers.name"),
            "base_url": _text(row["base_url"], "providers.base_url"),
            "protocol": _text(row["protocol"], "providers.protocol"),
            "enabled": _flag(row["enabled"], "providers.enabled"),
            "region_tag": _optional_text(row["region_tag"], "providers.region_tag"),
            "affinity_node": _optional_text(row["affinity_node"], "providers.affinity_node"),
            "allow_internal": _flag(row["allow_internal"], "providers.allow_internal"),
            "keys": keys_by.get(row["id"], []),
            "listings": listings_by.get(row["id"], []),
        }
        for row in providers
    ]

    grants: dict[int, list[str]] = {}
    for row in grant_rows:
        grants.setdefault(row["api_key_id"], []).append(
            _text(row["model_name"], "api_key_models.model_name")
        )
    agent_keys = [
        {
            "prefix": _text(row["prefix"], "api_keys.prefix"),
            "key_hash_b64": _b64(row["key_hash"], "api_keys.key_hash"),
            "enabled": _flag(row["enabled"], "api_keys.enabled"),
            "created_at": _created_at(row["created_at"]),
            "rpm_limit": _quota(row["rpm_limit"], "api_keys.rpm_limit"),
            "tpm_limit": _quota(row["tpm_limit"], "api_keys.tpm_limit"),
            "daily_token_limit": _quota(row["daily_token_limit"], "api_keys.daily_token_limit"),
            "model_names": grants.get(row["id"], []),
        }
        for row in agent_rows
    ]
    models = [
        {
            "name": _text(row["name"], "models.name"),
            "enabled": _flag(row["enabled"], "models.enabled"),
        }
        for row in model_rows
    ]
    routes = [
        {
            "model": _text(row["model_name"], "model_routes.model"),
            "provider": _text(row["provider_name"], "model_routes.provider"),
            "upstream_model_id": _optional_text(
                row["upstream_model_id"], "model_routes.upstream_model_id"
            ),
            "weight": _integer(row["weight"], "model_routes.weight"),
            "priority": _integer(row["priority"], "model_routes.priority"),
            "enabled": _flag(row["enabled"], "model_routes.enabled"),
        }
        for row in route_rows
    ]
    settings = {
        row["key"]: _settings_object(row["value"], f"settings.{row['key']}") for row in setting_rows
    }
    return {
        "taken_at": taken_at,
        "generation": _integer(generation, "config_generation"),
        "migrations": applied,
        "providers": provider_docs,
        "agent_keys": agent_keys,
        "models": models,
        "routes": routes,
        "auto_router": settings.get("auto_router"),
        "auto_router_reorder": settings.get("auto_router_reorder"),
    }


def _document_from_snapshot(snapshot: dict, validator) -> dict:
    try:
        key_id, _key = _active_key()
        canary = base64.b64encode(encrypt(_CANARY_PLAINTEXT)).decode("ascii")
    except ValueError as exc:
        raise ExportError("no active keyring; canary cannot be minted") from exc
    document = {
        "$schema": validator.schema["$id"],
        "version": 1,
        "kind": "janus-config-backup",
        "taken_at": snapshot["taken_at"],
        "source": {
            "config_generation": snapshot["generation"],
            "schema_migrations": list(snapshot["migrations"]),
            "dashboard_version": dashboard_version(),
        },
        "crypto": {
            "provider_key_encryption": {
                "scheme": "JSEC-1",
                "ciphertext_encoding": "base64",
                "key_ids": [],
                "canary": canary,
                "canary_key_id": key_id,
            },
            "agent_key_hash": {
                "scheme": "HMAC-SHA256",
                "hash_encoding": "base64",
                "pepper_canary_hash": pepper_canary_hash(config.api_key_pepper),
            },
        },
        "providers": snapshot["providers"],
        "agent_keys": snapshot["agent_keys"],
        "router": {
            "models": snapshot["models"],
            "routes": snapshot["routes"],
            # Verbatim settings objects. Null means the row was never
            # stored — do not substitute the page defaults. Tier arrays
            # stay in stored order; sort_document_arrays sorts markers.
            "auto_router": snapshot["auto_router"],
            "auto_router_reorder": snapshot["auto_router_reorder"],
        },
    }
    host = _host_label()
    if host is not None:
        document["host"] = host
    document["crypto"]["provider_key_encryption"]["key_ids"] = derive_key_ids(document)
    document = sort_document_arrays(document)
    document["integrity"] = {"payload_sha256": payload_sha256(document)}
    _validate(validator, document)
    return document


def _validate(validator, document: dict) -> None:
    errors = list(validator.iter_errors(document))
    if not errors:
        return
    err = min(errors, key=lambda item: [str(part) for part in item.absolute_path])
    loc = ".".join(str(part) for part in err.absolute_path) or "$"
    # Validator keyword only — the message echoes the instance, which
    # may be ciphertext.
    raise ExportError(
        f"schema self-check failed at {loc} ({err.validator}); {len(errors)} error(s)"
    )
