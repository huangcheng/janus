"""models.dev snapshot ingestion (Anthropic Models API parity, layer 3).

Provider catalogs are the precise source where they publish token limits;
many (dashscope, volcengine, minimax, mimo) publish none. models.dev is a
community-maintained per-provider dataset that fills those gaps. It is
joined by PROVIDER base_url, never by model name alone: resellers and
tuned endpoints (kimi coding, step_plan) carry their own limits on
models.dev, and a name-only join would silently apply an origin
provider's numbers to a tuned deployment.

Join rule (strict on purpose): same netloc AND the models.dev `api` path
is a prefix of our provider base_url path. A tuned endpoint whose path
diverges (or a regional ccTLD host) does NOT match — omission is safe,
the curated model_limits overlay covers those.

One reviewed exception (SIBLING_ALLOWLIST below): several hosts publish a
second models.dev entry for their coding-plan endpoint beside the main API,
and some of our listings only exist in the other entry of the SAME host.
Borrowing limits from a same-host sibling is safe — same host is the same
vendor's own catalog — while a name-only join to a different host stays
refused. Siblings only fill gaps: the strict match always wins for a name.

Precedence in the gateway catalog: model_limits > provider meta > this
snapshot. Fetch failures never fail a sync: the previous snapshot stays.
"""

import json
import logging
import time
from urllib.parse import urlparse

import httpx

from . import audit, database

logger = logging.getLogger("janus.dashboard.modelsdev")

MODELS_DEV_URL = "https://models.dev/api.json"
FETCH_TIMEOUT_SEC = 45

# Reviewed same-host sibling allowlist (measured against the live models.dev
# catalog; worth exactly 6 names today, see task-22). Keyed by host, values
# are the models.dev entry ids that may be borrowed from. An entry is only
# eligible when ALL hold: (a) its id is listed here for our provider's host,
# (b) its `api` netloc equals that host, (c) it carries at least one non-zero
# limit.context/limit.output. A sibling is an addition to the strict
# `_base_match` entry, never a replacement: the strict entry wins every name
# it has, and without a strict anchor nothing is borrowed.
SIBLING_ALLOWLIST: dict[str, tuple[str, ...]] = {
    # our zhipu base_url (/api/coding/paas/v4) and volcengine
    # (/api/v3) each match one entry on the host; the missing listing names
    # live in the other, same-host entry.
    "open.bigmodel.cn": ("zhipuai", "zhipuai-coding-plan"),
    "ark.cn-beijing.volces.com": ("volcengine", "volcengine-coding-plan"),
}

_etag: str | None = None
_cache: dict | None = None


def _base_match(md_api: str, base_url: str) -> bool:
    """True when md_api is the same host and a path prefix of base_url."""
    a, b = urlparse(md_api), urlparse(base_url)
    if a.netloc != b.netloc:
        return False
    ap, bp = a.path.rstrip("/"), b.path.rstrip("/")
    return bp == ap or bp.startswith(ap + "/")


async def fetch_catalog() -> tuple[dict | None, str]:
    """GET models.dev with ETag revalidation. Returns (catalog, note)."""
    global _etag, _cache
    headers = {"If-None-Match": _etag} if _etag else {}
    try:
        async with httpx.AsyncClient(timeout=FETCH_TIMEOUT_SEC, follow_redirects=True) as c:
            r = await c.get(MODELS_DEV_URL, headers=headers)
    except Exception as e:
        logger.warning("models.dev fetch failed: %s", e)
        return (_cache, "fetch_failed") if _cache else (None, "fetch_failed")
    if r.status_code == 304 and _cache is not None:
        return _cache, "not_modified"
    if r.status_code != 200:
        logger.warning("models.dev HTTP %s", r.status_code)
        note = f"http_{r.status_code}"
        return (_cache, note) if _cache else (None, note)
    try:
        body = r.json()
    except Exception:
        return (_cache, "bad_json") if _cache else (None, "bad_json")
    if not isinstance(body, dict):
        return (None, "bad_shape")
    _etag = r.headers.get("etag")
    _cache = body
    return body, "fresh"


def _limit_entry(model: dict) -> dict:
    lim = model.get("limit")
    if not isinstance(lim, dict):
        return {}
    out = {}
    ctx = lim.get("context")
    otx = lim.get("output")
    if isinstance(ctx, int) and not isinstance(ctx, bool) and ctx > 0:
        out["context_length"] = ctx
    if isinstance(otx, int) and not isinstance(otx, bool) and otx > 0:
        out["max_output_tokens"] = otx
    return out


def _host(url: str) -> str:
    """Netloc of a URL, empty string when it has none."""
    return urlparse(url).netloc


def _entry_has_limits(models: dict) -> bool:
    """True when the entry carries at least one non-zero limit (condition c)."""
    return any(_limit_entry(m) for m in models.values() if isinstance(m, dict))


async def refresh_snapshot() -> dict:
    """Fetch models.dev and rewrite the `models_dev` settings snapshot.

    Only names that exist as enabled listings are kept, so the settings
    row stays small (hundreds of entries, not the full 6 MB dataset).
    Returns a result dict for the sync report; never raises.
    """
    catalog, note = await fetch_catalog()
    if catalog is None:
        return {"changed": False, "models": 0, "note": note}

    providers = await database.fetch("SELECT id, name, base_url FROM providers WHERE enabled = 1")
    matched: dict[int, dict] = {}
    sibling_names: dict[int, set[str]] = {}
    sibling_report: dict[str, dict] = {}
    for p in providers:
        base_url = p["base_url"]
        host = _host(base_url)
        strict_id: str | None = None
        models: dict | None = None
        for entry_id, pentry in catalog.items():
            if not isinstance(pentry, dict):
                continue
            api = pentry.get("api")
            if isinstance(api, str) and _base_match(api, base_url):
                strict_id = entry_id
                entry_models = pentry.get("models")
                if isinstance(entry_models, dict):
                    models = dict(entry_models)
                break
        if models is None:
            # No strict anchor (no _base_match, or the entry has no models
            # map): the allowlist is an addition to it, never a replacement.
            if host in SIBLING_ALLOWLIST:
                sibling_report[p["name"]] = {
                    "host": host,
                    "strict_entry": strict_id,
                    "siblings_used": [],
                    "siblings_skipped": ["no_strict_match"],
                    "sibling_names": 0,
                }
            continue
        used: list[str] = []
        skipped: list[str] = []
        borrowed: set[str] = set()
        allowlist = SIBLING_ALLOWLIST.get(host, ())
        if not allowlist:
            skipped.append("host_not_allowlisted")
        for sib_id in allowlist:
            if sib_id == strict_id:
                continue
            sib = catalog.get(sib_id)
            if not isinstance(sib, dict):
                skipped.append(f"{sib_id}:missing")
                continue
            sib_api = sib.get("api")
            if not isinstance(sib_api, str) or _host(sib_api) != host:
                skipped.append(f"{sib_id}:netloc")
                continue
            sib_models = sib.get("models")
            if not isinstance(sib_models, dict) or not _entry_has_limits(sib_models):
                skipped.append(f"{sib_id}:no_limits")
                continue
            added = {n: m for n, m in sib_models.items() if n not in models}
            if added:
                models.update(added)
                borrowed.update(added)
                used.append(sib_id)
        matched[p["id"]] = models
        sibling_names[p["id"]] = borrowed
        sibling_report[p["name"]] = {
            "host": host,
            "strict_entry": strict_id,
            "siblings_used": used,
            "siblings_skipped": skipped,
            "sibling_names": len(borrowed),
        }

    if not matched:
        return {"changed": False, "models": 0, "note": note, "matched_providers": []}

    ids = tuple(matched)
    placeholders = ",".join(f"${i + 1}" for i in range(len(ids)))
    rows = await database.fetch(
        f"SELECT provider_id, name FROM provider_models WHERE enabled = 1 "
        f"AND provider_id IN ({placeholders})",
        *ids,
    )

    models_out: dict[str, dict] = {}
    strict_hits = 0
    sibling_hits = 0
    sibling_out_names: set[str] = set()
    for r in rows:
        pid, name = r["provider_id"], r["name"]
        entry = _limit_entry(matched[pid].get(name) or {})
        if not entry:
            continue
        models_out[name] = entry
        if name in sibling_names.get(pid, frozenset()):
            sibling_hits += 1
            sibling_out_names.add(name)
        else:
            strict_hits += 1

    logger.info(
        "models.dev snapshot: %d names (strict listings=%d, same-host siblings=%d %s) note=%s",
        len(models_out),
        strict_hits,
        sibling_hits,
        sorted(sibling_out_names),
        note,
    )

    counts = {
        "models": len(models_out),
        "strict_hits": strict_hits,
        "sibling_hits": sibling_hits,
        "sibling_names": sorted(sibling_out_names),
        "sibling_providers": sibling_report,
        "note": note,
        "matched_providers": sorted(matched),
    }
    snapshot = {
        "source": "models.dev",
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "note": note,
        "sibling_joins": {
            "strict_hits": strict_hits,
            "sibling_hits": sibling_hits,
            "names": sorted(sibling_out_names),
        },
        "models": models_out,
    }
    row = await database.fetchrow("SELECT value FROM settings WHERE key = 'models_dev'")
    if row and row["value"]:
        try:
            prev = json.loads(row["value"])
            if isinstance(prev, dict) and prev.get("models") == models_out:
                return {"changed": False, **counts}
        except Exception as e:
            logger.warning("models.dev snapshot compare failed: %s", e)
    await database.execute(
        "INSERT INTO settings (key, value) VALUES ('models_dev', $1) "
        "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
        json.dumps(snapshot, ensure_ascii=False),
    )
    await database.bump_generation()
    audit.log(
        "settings.models_dev",
        "sync",
        f"models={len(models_out)} strict={strict_hits} siblings={sibling_hits} note={note}",
    )
    return {"changed": True, **counts}
