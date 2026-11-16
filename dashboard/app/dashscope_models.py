"""DashScope / Bailian native model catalog for inventory sync.

The OpenAI-compatible ``GET {compatible-mode}/v1/models`` list is a lagging
subset of what the same key can actually call. Brand-new ids (observed:
``qwen4-max`` on 2026-11-16) appear on the native Model Studio list
(``GET {host}/api/v1/models``, paginated) and accept chat on the compatible
base, but never show up in the OpenAI-shaped catalog — so a sync that only
reads ``/models`` silently misses callable inventory.

This module is control-plane only: it does not change the gateway's
OpenAI-shaped data-plane contract. Non-DashScope providers are untouched.
"""

from __future__ import annotations

import json
import logging
from urllib.parse import urlparse

logger = logging.getLogger("janus.dashboard.dashscope_models")

# Cap pages so a broken total cannot loop forever (100 × 50 = 5000 ids).
_PAGE_SIZE = 100
_MAX_PAGES = 50


def is_dashscope_base(base_url: str) -> bool:
    """True when the provider base is a DashScope / Model Studio host."""
    host = (urlparse(base_url or "").netloc or "").lower()
    if not host:
        return False
    if host.endswith(".maas.aliyuncs.com") or host == "maas.aliyuncs.com":
        return True
    # dashscope.aliyuncs.com, dashscope-intl / -us, coding.dashscope…, etc.
    return "dashscope" in host and host.endswith(".aliyuncs.com")


def native_models_url(base_url: str) -> str:
    """``https://{same-host}/api/v1/models`` for the stored compatible base."""
    parsed = urlparse((base_url or "").strip())
    if not parsed.scheme or not parsed.netloc:
        return ""
    return f"{parsed.scheme}://{parsed.netloc}/api/v1/models"


def listing_item_from_native(model: dict) -> dict | None:
    """Map a native catalog row onto the OpenAI-shaped listing item sync upserts.

    Identity moves from ``model`` → ``id``; every other field is kept under its
    own name so ``normalize_meta`` can capture context / pricing / features.
    """
    if not isinstance(model, dict):
        return None
    mid = model.get("model")
    if not isinstance(mid, str) or not mid.strip():
        return None
    item = {k: v for k, v in model.items() if k != "model"}
    item["id"] = mid.strip()
    return item


async def fetch_native_listings(
    client: httpx.AsyncClient,
    base_url: str,
    headers: dict,
) -> list[dict]:
    """Paginate the native catalog into OpenAI-shaped listing dicts.

    Raises on transport / HTTP / shape failure so the caller can fall back to
    the OpenAI-compatible ``/models`` list.
    """
    root = native_models_url(base_url)
    if not root:
        raise ValueError("dashscope base_url has no host")

    items: list[dict] = []
    seen: set[str] = set()
    page_no = 1
    total: int | None = None

    while page_no <= _MAX_PAGES:
        async with client.stream(
            "GET",
            root,
            headers=headers,
            params={"page_no": page_no, "page_size": _PAGE_SIZE},
        ) as resp:
            if resp.status_code != 200:
                raise RuntimeError(f"http_{resp.status_code}")
            from . import egress

            raw = await egress.read_body_capped(resp)
        try:
            data = json.loads(raw)
        except Exception as e:
            raise RuntimeError("native_list_bad_json") from e
        if not isinstance(data, dict) or data.get("success") is not True:
            raise RuntimeError("native_list_unsuccessful")
        output = data.get("output")
        if not isinstance(output, dict):
            raise RuntimeError("native_list_bad_output")
        if total is None:
            raw_total = output.get("total")
            total = int(raw_total) if isinstance(raw_total, (int, float)) else 0
        models = output.get("models")
        if not isinstance(models, list):
            raise RuntimeError("native_list_bad_models")
        if not models:
            break
        for row in models:
            item = listing_item_from_native(row)
            if item is None:
                continue
            name = item["id"]
            if name in seen:
                continue
            seen.add(name)
            items.append(item)
        if total is not None and len(items) >= total:
            break
        if len(models) < _PAGE_SIZE:
            break
        page_no += 1

    logger.info(
        "dashscope native catalog: host=%s pages=%s seen=%s total=%s",
        urlparse(base_url).netloc,
        page_no,
        len(items),
        total,
    )
    return items
