"""Token-limit coverage / compaction readiness for every name the dashboard knows.

READ-ONLY report: no writes, no audit row, no ``config_generation`` bump. It answers
"which names are compaction-ready, what is missing, and which layer supplied each value".

It mirrors the gateway catalog's limit plumbing (``../janus``,
``apps/janus_core/src/janus_catalog.erl``) so the numbers match what the gateway
actually advertises — the gateway's ``/v1/models`` stays authoritative:

* ``flatten_limits/1`` + ``promote_nested/2`` (:513-546): a nested map held under
  ``limit`` or ``token_limits`` is promoted to the top-level spellings
  (``context``/``context_length``/``context_window`` → the window keys,
  ``max_input_token_length`` → ``max_input_tokens``,
  ``output``/``max_output_tokens``/``max_output_token_length`` → ``max_output_tokens``),
  positive ints only; a real top-level key always wins over its promoted twin.
* ``merge_meta/2`` (:487-512) via ``provider_meta/2`` (:352-357) — the **listing** layer:
  fold each enabled listing's flattened keys with **MAX** per key (positive ints), then
  ``canonical_ctx/1`` (:662) / ``canonical_out/1`` pick the dimension value in canonical
  precedence. ``provider_meta/2`` filters listing ``enabled`` + map meta only — provider
  enablement is deliberately NOT part of it.
* ``route_limits/2`` (:599-620) + ``routed_limits/1`` (:577-585) + ``group_min/2`` (:636-647)
  — the **route_min** layer: only routes with ``enabled=1``, a non-null
  ``upstream_model_id``, an enabled provider and that provider's enabled listing row (map
  meta) contribute; per route take the group-min over ``ctx_limit_keys()``/``out_limit_keys()``,
  then the min across routes, emitted through ``canonical_limit_fields/2`` (:587-597) as the
  canonical ``context_length`` / ``max_output_tokens`` keys. A route without an explicit
  ``upstream_model_id`` contributes nothing.
* ``limit_fields/1`` (:445-453) — the **curated** layer (``settings.model_limits``) and the
  **snapshot** layer (``settings.models_dev``) keep only
  ``{context_length, context_window, max_output_tokens}`` positive ints. Both
  window spellings stay readable here because other writers may leave either
  behind, but curation stores ONE canonical slot: ``context_length`` — the key
  ``canonical_ctx/1`` prefers and the one the gateway actually emits on
  ``/v1/models`` (a curated ``context_window`` with no ``context_length`` is not
  honoured by the data plane; see ``app/routers/settings.py:_canonical_window``).
* Effective precedence ``curated > route_min > listing > snapshot``, matching the final
  right-biased merge ``maps:merge(maps:merge(snapshot_entry, Meta), curated_entry)``
  (:336-343) where ``Meta`` already carries ``attach_routed_limits/1`` (:363-397).

The two rules AMENDMENT 2 froze against the gateway's actual behaviour are both implemented here
and proved live:

1. the listing layer aggregates with MAX per key (``merge_meta/2``), not min-per-key;
2. the route ``group_min/2`` reads the 4-key groups (``ctx_limit_keys``/``out_limit_keys``
   include ``max_input_token_length``/``max_output_token_length``) while listing/curated/
   snapshot use the 3-key canonical picks (``canonicalize/3``, :699-708).

The earlier AMENDMENT 1 wording (min per key everywhere, the 4-key spellings ignored) does not
match the gateway and is superseded. The curated and snapshot layers stay 3-key only
(``limit_fields/1``).

Layer values in ``layers`` are that layer's own per-dimension value, never the effective one.
``window_only``/``output_only`` are numerically identical to ``missing_output``/``missing_window``
under these status rules; they are emitted literally because the response contract freezes them.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping, Sequence
from typing import Any

SOURCE = "dashboard"
NOTE = (
    "computed from curated limits + listing metadata + route bindings + models.dev "
    "snapshot; the gateway's /v1/models is authoritative"
)

# Key sets, mirroring janus_catalog. Window/output group keys drive the route group-min;
# the canonical tuples drive every dimension pick.
WINDOW_CANONICAL: tuple[str, ...] = ("context_length", "context_window", "max_input_tokens")
OUTPUT_CANONICAL: tuple[str, ...] = ("max_output_tokens", "max_completion_tokens", "max_tokens")
WINDOW_GROUP: tuple[str, ...] = (*WINDOW_CANONICAL, "max_input_token_length")
OUTPUT_GROUP: tuple[str, ...] = (*OUTPUT_CANONICAL, "max_output_token_length")

# promote_nested/2: nested spelling -> top-level spelling.
PROMOTE: dict[str, str] = {
    "context": "context_length",
    "context_length": "context_length",
    "context_window": "context_window",
    "max_input_token_length": "max_input_tokens",
    "output": "max_output_tokens",
    "max_output_tokens": "max_output_tokens",
    "max_output_token_length": "max_output_tokens",
}
NESTED_HOLDERS: tuple[str, ...] = ("limit", "token_limits")

# limit_fields/1: the only keys curated limits and the models.dev snapshot may carry.
LIMIT_FIELDS: tuple[str, ...] = ("context_length", "context_window", "max_output_tokens")

LAYER_ORDER: tuple[str, ...] = ("curated", "route_min", "listing", "snapshot")


def pos_int(value: Any) -> int | None:
    """Positive integer or None — rejects bool, float, str and <= 0."""
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        return None
    return value


def as_dict(raw: Any) -> dict:
    """Tolerant JSONB/meta reader: dict passes through, str/bytes decode, junk -> {}."""
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, (str, bytes)):
        import json

        try:
            decoded = json.loads(raw)
        except Exception:
            return {}
        return decoded if isinstance(decoded, dict) else {}
    return {}


def flatten_limits(meta: Mapping[str, Any]) -> dict:
    """Mirror of flatten_limits/1 + promote_nested/2: promote nested limit maps.

    ``token_limits`` is folded after ``limit``, so it wins on a promoted-key collision;
    either way an explicit top-level key wins over its promoted twin.
    """
    promoted: dict[str, int] = {}
    for holder in NESTED_HOLDERS:
        nested = meta.get(holder)
        if not isinstance(nested, dict):
            continue
        for src, dst in PROMOTE.items():
            value = pos_int(nested.get(src))
            if value is not None:
                promoted[dst] = value
    return {**promoted, **dict(meta)}


def group_min(flat: Mapping[str, Any], keys: Sequence[str]) -> int | None:
    """Mirror of group_min/2: min over the keys of one dimension group."""
    found = [v for v in (pos_int(flat.get(k)) for k in keys) if v is not None]
    return min(found) if found else None


def canonical_pick(flat: Mapping[str, Any], keys: Sequence[str]) -> int | None:
    """Mirror of canonicalize/3 + first_known/2: first present key in precedence order."""
    for key in keys:
        value = pos_int(flat.get(key))
        if value is not None:
            return value
    return None


def merge_max(acc: dict, flat: Mapping[str, Any]) -> dict:
    """Mirror of merge_meta/2's numeric rule: MAX per key (positive ints only)."""
    merged = dict(acc)
    for key, raw in flat.items():
        value = pos_int(raw)
        if value is None:
            continue
        prev = merged.get(key)
        if isinstance(prev, int) and not isinstance(prev, bool) and prev >= value:
            continue
        merged[key] = value
    return merged


def limit_fields(entry: Mapping[str, Any]) -> dict:
    """Mirror of limit_fields/1 for curated + snapshot entries."""
    return {k: v for k in LIMIT_FIELDS if (v := pos_int(entry.get(k))) is not None}


def universe_names(
    *,
    models: Iterable[Mapping[str, Any]],
    listings: Iterable[Mapping[str, Any]],
    curated: Mapping[str, Any],
) -> set[str]:
    """The catalog universe the coverage view reports and curation may write to.

    ``models`` rows ∪ current ``model_limits`` keys ∪ enabled listing names —
    the single definition of "a name the dashboard knows". ``build_coverage``
    seeds its name map from this same helper, and the curation endpoints use it
    to reject typos, so a curated name can never exist outside the reported set.
    """
    names: set[str] = set()
    for row in models:
        name = row.get("name")
        if isinstance(name, str) and name:
            names.add(name)
    names.update(k for k in as_dict(curated) if isinstance(k, str) and k)
    for row in listings:
        if not row.get("enabled"):
            continue
        name = row.get("name")
        if isinstance(name, str) and name:
            names.add(name)
    return names


def _dimension_pair(window: int | None, output: int | None) -> dict:
    return {"window": window, "output": output}


def build_coverage(
    *,
    models: Iterable[Mapping[str, Any]],
    routes: Iterable[Mapping[str, Any]],
    listings: Iterable[Mapping[str, Any]],
    providers: Iterable[Mapping[str, Any]],
    curated: Mapping[str, Any],
    snapshot: Mapping[str, Any],
    tiers: Mapping[str, Any],
) -> dict:
    """Compose the frozen coverage response from prepared rows.

    Rows are the dashboard's own tables: ``models`` (id, name), ``routes``
    (model_id, provider_id, upstream_model_id, enabled), ``listings``
    (provider_id, name, enabled, meta), ``providers`` (id, name, enabled);
    ``curated`` is ``settings.model_limits``, ``snapshot`` the ``models`` map of
    ``settings.models_dev``, ``tiers`` the ``tiers`` map of ``settings.auto_router``.
    """
    provider_enabled = {p["id"]: bool(p.get("enabled")) for p in providers}
    provider_name = {p["id"]: p["name"] for p in providers}

    # listings indexed by name; only rows the layers can use (enabled + map meta).
    by_name: dict[str, list[dict]] = {}
    for row in listings:
        meta = as_dict(row.get("meta"))
        if not meta:
            continue
        by_name.setdefault(row["name"], []).append(
            {
                "provider_id": row["provider_id"],
                "name": row["name"],
                "enabled": bool(row.get("enabled")),
                "meta": meta,
            }
        )
    listing_index = {
        (row["provider_id"], row["name"]): row for rowlist in by_name.values() for row in rowlist
    }

    routes_by_model: dict[int, list[Mapping[str, Any]]] = {}
    for route in routes:
        routes_by_model.setdefault(route["model_id"], []).append(route)

    curated_map = {k: as_dict(v) for k, v in as_dict(curated).items()}
    snapshot_map = {k: as_dict(v) for k, v in as_dict(as_dict(snapshot).get("models")).items()}

    # tier membership from settings.auto_router
    tier_of: dict[str, list[str]] = {}
    for tier, members in as_dict(tiers).items():
        if not isinstance(members, list):
            continue
        for member in members:
            if isinstance(member, str) and member.strip():
                tier_of.setdefault(member.strip(), []).append(tier)

    names: dict[str, dict] = {
        name: {"model_id": None, "bound": False}
        for name in universe_names(models=models, listings=listings, curated=curated_map)
    }
    for row in models:
        name = row["name"]
        if name not in names:
            continue
        names[name]["model_id"] = row["id"]
        names[name]["bound"] = any(
            bool(r.get("enabled")) for r in routes_by_model.get(row["id"], [])
        )

    entries: list[dict] = []
    for name in sorted(names):
        info = names[name]
        model_id = info["model_id"]
        providers_seen: set[str] = set()

        # --- curated (limit_fields/1) ---
        curated_dims = _dimension_pair(
            canonical_pick(limit_fields(curated_map.get(name) or {}), WINDOW_CANONICAL),
            canonical_pick(limit_fields(curated_map.get(name) or {}), OUTPUT_CANONICAL),
        )

        # --- listing layer: MAX per key across this name's enabled listings (merge_meta/2) ---
        listing_acc: dict = {}
        for row in by_name.get(name, []):
            if not row["enabled"]:
                continue
            listing_acc = merge_max(listing_acc, flatten_limits(row["meta"]))
            providers_seen.add(provider_name.get(row["provider_id"], str(row["provider_id"])))
        listing_dims = _dimension_pair(
            canonical_pick(listing_acc, WINDOW_CANONICAL),
            canonical_pick(listing_acc, OUTPUT_CANONICAL),
        )

        # --- route_min layer: per-route group-min, then min across routes ---
        route_window: int | None = None
        route_output: int | None = None
        if model_id is not None:
            for route in routes_by_model.get(model_id, []):
                if not route.get("enabled"):
                    continue
                upstream = route.get("upstream_model_id")
                if not isinstance(upstream, str) or not upstream.strip():
                    continue
                pid = route["provider_id"]
                if not provider_enabled.get(pid):
                    continue
                listing = listing_index.get((pid, upstream))
                if listing is None or not listing["enabled"]:
                    continue
                flat = flatten_limits(listing["meta"])
                providers_seen.add(provider_name.get(pid, str(pid)))
                window = group_min(flat, WINDOW_GROUP)
                output = group_min(flat, OUTPUT_GROUP)
                if window is not None:
                    route_window = window if route_window is None else min(route_window, window)
                if output is not None:
                    route_output = output if route_output is None else min(route_output, output)
        route_dims = _dimension_pair(route_window, route_output)

        # --- snapshot layer (limit_fields/1 like curated) ---
        snapshot_dims = _dimension_pair(
            canonical_pick(limit_fields(snapshot_map.get(name) or {}), WINDOW_CANONICAL),
            canonical_pick(limit_fields(snapshot_map.get(name) or {}), OUTPUT_CANONICAL),
        )

        layers = {
            "curated": curated_dims,
            "route_min": route_dims,
            "listing": listing_dims,
            "snapshot": snapshot_dims,
        }
        source = {"window": None, "output": None}
        effective = {"window": None, "output": None}
        for layer in LAYER_ORDER:
            for dim in ("window", "output"):
                if effective[dim] is None and layers[layer][dim] is not None:
                    effective[dim] = layers[layer][dim]
                    source[dim] = layer

        if effective["window"] is None and effective["output"] is None:
            status = "missing_both"
        elif effective["window"] is None:
            status = "missing_window"
        elif effective["output"] is None:
            status = "missing_output"
        else:
            status = "ready"

        entries.append(
            {
                "name": name,
                "bound": bool(info["bound"]),
                "tiers": sorted(tier_of.get(name, [])),
                "window": effective["window"],
                "output": effective["output"],
                "status": status,
                "source": source,
                "layers": layers,
                "providers": sorted(providers_seen),
            }
        )

    summary = {
        "names": len(entries),
        "ready": sum(1 for e in entries if e["status"] == "ready"),
        "missing_window": sum(1 for e in entries if e["status"] == "missing_window"),
        "missing_output": sum(1 for e in entries if e["status"] == "missing_output"),
        "missing_both": sum(1 for e in entries if e["status"] == "missing_both"),
        "curated": sum(
            1
            for e in entries
            if e["layers"]["curated"]["window"] is not None
            or e["layers"]["curated"]["output"] is not None
        ),
        "bound": sum(1 for e in entries if e["bound"]),
        "window_only": sum(1 for e in entries if e["window"] is not None and e["output"] is None),
        "output_only": sum(1 for e in entries if e["output"] is not None and e["window"] is None),
    }
    return {"source": SOURCE, "note": NOTE, "summary": summary, "entries": entries}
