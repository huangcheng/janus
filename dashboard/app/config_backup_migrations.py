"""Which gateway migrations a config backup may read or write (C13 / §5.4.3).

Version strings are ``schema_migrations.version`` values: the migration
filename stem (``001_init``), which is what ``janus_db_postgres`` inserts.
The spec's ``001/003/…`` list is that set. Export requires every version
named here. Restore requires the subset for sections actually written.

Section ids (the keys of :data:`CONFIG_AFFECTING_MIGRATIONS`), after
skip resolution:

* ``providers`` / ``provider_keys`` / ``listings`` / ``models`` / ``routes``
* ``agent_keys`` — omitted entirely when ``allow_foreign_keys`` is set
* ``grants`` — explicit grant compare/write/replace-converge (022).
  FK-only cascades (whole-key or whole-model deletes) do not list this.
* ``auto_router`` / ``auto_router_reorder`` — omitted when the singleton
  is null (v1 never resets settings)

``base`` applies to a replace delete-all (empty payload, table still
touched). ``on_content`` applies when the payload carries rows. Column
migrations (010/014/015/017) are unconditional on column *values* once
rows are written, and are not required for delete-only. 013 is required
only when a written provider uses ``openai_decisions``. Writing agent-key
rows always touches quotas and name-based grants.
"""

CONFIG_AFFECTING_MIGRATIONS: dict[str, dict[str, tuple[str, ...]]] = {
    "providers": {
        "base": ("001_init",),
        "on_content": ("015_worker_affinity", "017_allow_internal"),
        "when_openai_decisions": ("013_decisions_protocol",),
    },
    "provider_keys": {
        "base": ("001_init",),
    },
    "listings": {
        "base": ("003_provider_models",),
        "on_content": ("010_modality",),
    },
    "models": {
        "base": ("001_init",),
    },
    "routes": {
        "base": ("001_init",),
    },
    "agent_keys": {
        "base": ("001_init",),
        # 022: a non-empty agent_keys write read-compares grants. Delete-all
        # of keys does not (pre-022 CASCADE), so 022 is on_content only.
        "on_content": ("014_api_key_quotas", "022_api_key_model_names"),
    },
    "grants": {
        "base": (),
        "on_content": ("022_api_key_model_names",),
    },
    "auto_router": {
        # Null singletons are skipped, never deleted. No delete-only base.
        "base": (),
        "on_content": ("006_settings", "020_auto_router_state"),
    },
    "auto_router_reorder": {
        "base": (),
        "on_content": ("006_settings",),
    },
}

_MODES = frozenset({"merge", "replace"})
_SKIPPED_WHEN_FOREIGN_KEYS = frozenset({"agent_keys", "grants"})


def full_config_affecting_migrations() -> frozenset[str]:
    """Every version the exporter must see on the source (§5.2)."""
    versions: set[str] = set()
    for rules in CONFIG_AFFECTING_MIGRATIONS.values():
        for value in rules.values():
            versions.update(value)
    return frozenset(versions)


def _as_list(value: object) -> list:
    return value if isinstance(value, list) else []


def _router(doc: dict) -> dict:
    router = doc.get("router")
    return router if isinstance(router, dict) else {}


def _providers(doc: dict) -> list:
    return _as_list(doc.get("providers"))


def _section_has_content(doc: dict, section: str) -> bool:
    if section == "providers":
        return bool(_providers(doc))
    if section == "provider_keys":
        return any(_as_list(p.get("keys")) for p in _providers(doc) if isinstance(p, dict))
    if section == "listings":
        return any(_as_list(p.get("listings")) for p in _providers(doc) if isinstance(p, dict))
    if section == "models":
        return bool(_as_list(_router(doc).get("models")))
    if section == "routes":
        return bool(_as_list(_router(doc).get("routes")))
    if section in ("agent_keys", "grants"):
        # Grant compare runs for every agent-key row, including model_names [].
        return bool(_as_list(doc.get("agent_keys")))
    if section == "auto_router":
        return isinstance(_router(doc).get("auto_router"), dict)
    if section == "auto_router_reorder":
        return isinstance(_router(doc).get("auto_router_reorder"), dict)
    return False


def _has_openai_decisions(doc: dict) -> bool:
    return any(
        isinstance(provider, dict) and provider.get("protocol") == "openai_decisions"
        for provider in _providers(doc)
    )


def required_migrations_for(
    doc: dict,
    *,
    mode: str,
    allow_foreign_keys: bool,
    sections_written,
) -> set[str]:
    """Migrations the target must already have applied for this restore.

    ``sections_written`` is the post-skip set (null settings omitted;
    ``allow_foreign_keys`` should already have dropped agent keys). The
    flag is applied again here so a caller that lists the skipped
    section still does not gate 014/022. Merge of an empty section is
    not a write. Replace of an empty section needs ``base`` only.
    """
    if mode not in _MODES:
        raise ValueError(f"mode must be 'merge' or 'replace', got {mode!r}")
    if not isinstance(doc, dict):
        raise TypeError("doc must be a dict")

    written = set(sections_written)
    unknown = written - CONFIG_AFFECTING_MIGRATIONS.keys()
    if unknown:
        raise ValueError(f"unknown config-backup sections: {sorted(unknown)}")
    if allow_foreign_keys:
        written -= _SKIPPED_WHEN_FOREIGN_KEYS

    required: set[str] = set()
    for section in written:
        rules = CONFIG_AFFECTING_MIGRATIONS[section]
        has_content = _section_has_content(doc, section)
        if not has_content and mode != "replace":
            continue
        required.update(rules.get("base", ()))
        if not has_content:
            continue
        required.update(rules.get("on_content", ()))
        if section == "providers" and _has_openai_decisions(doc):
            required.update(rules.get("when_openai_decisions", ()))
    return required
