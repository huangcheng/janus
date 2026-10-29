"""Canonical JSON for config-backup documents (spec §5.1 / C3 / C11).

The integrity hash is SHA-256 over this process's canonical JSON of the
document with ``integrity``, ``$schema``, and ``host`` removed. Object
keys are sorted; array order is significant and is fixed by
``sort_document_arrays`` before hashing. Tier arrays are the one
exception: they are order-sensitive payload and are never sorted.
"""

import copy
import hashlib
import json

# Top-level members excluded from payload_sha256. Nested values are
# covered; only these exact keys are dropped.
_HASH_EXCLUDED = frozenset({"$schema", "host", "integrity"})


def canonical_bytes(doc: dict) -> bytes:
    """UTF-8 canonical JSON of ``doc`` minus hash-excluded top-level keys.

    ``sort_keys=True``, ``separators=(",", ":")``, ``ensure_ascii=False``
    — the same spelling ``app.auto_router_rules.canonical`` uses. Does
    not sort arrays; call ``sort_document_arrays`` first when the hash
    must match an export.
    """
    body = {key: value for key, value in doc.items() if key not in _HASH_EXCLUDED}
    return json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def payload_sha256(doc: dict) -> str:
    """Lowercase hex SHA-256 of :func:`canonical_bytes`."""
    return hashlib.sha256(canonical_bytes(doc)).hexdigest()


def _str_field(item: object, field: str) -> str:
    if isinstance(item, dict):
        value = item.get(field)
        if isinstance(value, str):
            return value
    return ""


def _sorted_by(rows: object, *fields: str) -> object:
    if not isinstance(rows, list):
        return rows
    return sorted(rows, key=lambda row: tuple(_str_field(row, field) for field in fields))


def _sorted_strings(rows: object) -> object:
    if not isinstance(rows, list):
        return rows
    return sorted(rows, key=lambda item: item if isinstance(item, str) else "")


def _sort_strings_in(container: dict, key: str) -> None:
    if isinstance(container.get(key), list):
        container[key] = _sorted_strings(container[key])


def _sort_objects_in(container: dict, key: str, *fields: str) -> None:
    if isinstance(container.get(key), list):
        container[key] = _sorted_by(container[key], *fields)


def sort_document_arrays(doc: dict) -> dict:
    """Return a deep copy with C3 arrays sorted.

    Sorted: providers by name, keys by ciphertext, listings by name,
    routes by (model, provider), agent keys by key_hash, model names,
    router models by name, key_ids, schema_migrations, and markers.
    ``auto_router.tiers.*`` is left in its existing order. Absent arrays
    stay absent.
    """
    out = copy.deepcopy(doc)

    source = out.get("source")
    if isinstance(source, dict):
        _sort_strings_in(source, "schema_migrations")

    crypto = out.get("crypto")
    if isinstance(crypto, dict):
        encryption = crypto.get("provider_key_encryption")
        if isinstance(encryption, dict):
            _sort_strings_in(encryption, "key_ids")

    providers = out.get("providers")
    if isinstance(providers, list):
        for provider in providers:
            if not isinstance(provider, dict):
                continue
            _sort_objects_in(provider, "keys", "secret_ciphertext_b64")
            _sort_objects_in(provider, "listings", "name")
        out["providers"] = _sorted_by(providers, "name")

    agent_keys = out.get("agent_keys")
    if isinstance(agent_keys, list):
        for agent_key in agent_keys:
            if isinstance(agent_key, dict):
                _sort_strings_in(agent_key, "model_names")
        out["agent_keys"] = _sorted_by(agent_keys, "key_hash_b64")

    router = out.get("router")
    if isinstance(router, dict):
        _sort_objects_in(router, "models", "name")
        _sort_objects_in(router, "routes", "model", "provider")
        auto_router = router.get("auto_router")
        if isinstance(auto_router, dict):
            _sort_strings_in(auto_router, "markers")
            # tiers are order-sensitive; do not sort them.

    return out


def derive_key_ids(doc: dict) -> list[str]:
    """Sorted unique ``providers[].keys[].key_id`` strings."""
    found: set[str] = set()
    providers = doc.get("providers")
    if not isinstance(providers, list):
        return []
    for provider in providers:
        if not isinstance(provider, dict):
            continue
        keys = provider.get("keys")
        if not isinstance(keys, list):
            continue
        for key in keys:
            if not isinstance(key, dict):
                continue
            key_id = key.get("key_id")
            if isinstance(key_id, str):
                found.add(key_id)
    return sorted(found)
