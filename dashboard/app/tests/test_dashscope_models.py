"""Characterization: DashScope native catalog → sync listing shape."""

from __future__ import annotations

import httpx
import pytest

from app import dashscope_models


@pytest.mark.parametrize(
    "base,expect",
    [
        ("https://dashscope.aliyuncs.com/compatible-mode/v1", True),
        ("https://dashscope-intl.aliyuncs.com/compatible-mode/v1", True),
        ("https://coding.dashscope.aliyuncs.com/v1", True),
        ("https://ws123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1", True),
        ("https://ark.cn-beijing.volces.com/api/v3", False),
        ("https://api.openai.com/v1", False),
        ("", False),
    ],
)
def test_is_dashscope_base(base: str, expect: bool) -> None:
    assert dashscope_models.is_dashscope_base(base) is expect


def test_native_models_url_same_host() -> None:
    assert (
        dashscope_models.native_models_url("https://dashscope.aliyuncs.com/compatible-mode/v1")
        == "https://dashscope.aliyuncs.com/api/v1/models"
    )


def test_listing_item_from_native_maps_model_to_id() -> None:
    item = dashscope_models.listing_item_from_native(
        {
            "model": "qwen4-max",
            "name": "Qwen4-Max",
            "features": ["function-calling"],
            "model_info": {"context_window": 1_000_000},
        }
    )
    assert item is not None
    assert item["id"] == "qwen4-max"
    assert item["name"] == "Qwen4-Max"
    assert "model" not in item
    assert item["features"] == ["function-calling"]


def test_listing_item_from_native_rejects_blank() -> None:
    assert dashscope_models.listing_item_from_native({"model": "  "}) is None
    assert dashscope_models.listing_item_from_native({"name": "x"}) is None


@pytest.mark.asyncio
async def test_fetch_native_listings_paginates_and_dedupes(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(dashscope_models, "_PAGE_SIZE", 2)
    pages = {
        1: {
            "success": True,
            "output": {
                "total": 3,
                "page_no": 1,
                "page_size": 2,
                "models": [
                    {"model": "qwen4-max", "name": "Qwen4-Max"},
                    {"model": "qwen3.8-max", "name": "Qwen3.8-Max"},
                ],
            },
        },
        2: {
            "success": True,
            "output": {
                "total": 3,
                "page_no": 2,
                "page_size": 2,
                # Duplicate qwen4-max must not double-count.
                "models": [
                    {"model": "qwen4-max", "name": "dup"},
                    {"model": "qwen3.8-flash", "name": "Qwen3.8-Flash"},
                ],
            },
        },
    }

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/v1/models"
        assert request.url.params.get("page_size") == "2"
        page_no = int(request.url.params.get("page_no", "1"))
        return httpx.Response(200, json=pages[page_no])

    transport = httpx.MockTransport(handler)
    async with httpx.AsyncClient(transport=transport) as client:
        items = await dashscope_models.fetch_native_listings(
            client,
            "https://dashscope.aliyuncs.com/compatible-mode/v1",
            {"authorization": "Bearer x", "accept": "application/json"},
        )

    assert [i["id"] for i in items] == ["qwen4-max", "qwen3.8-max", "qwen3.8-flash"]


@pytest.mark.asyncio
async def test_fetch_native_listings_http_error() -> None:
    transport = httpx.MockTransport(lambda r: httpx.Response(401, json={"error": "no"}))
    async with httpx.AsyncClient(transport=transport) as client:
        with pytest.raises(RuntimeError, match="http_401"):
            await dashscope_models.fetch_native_listings(
                client,
                "https://dashscope.aliyuncs.com/compatible-mode/v1",
                {"authorization": "Bearer x"},
            )
