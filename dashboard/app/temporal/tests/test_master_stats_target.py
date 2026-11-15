"""_master_stats_target live-probes when the nodes health cache is cold."""

from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from app.maintenance import MmdbRefreshError, _master_stats_target

pytestmark = pytest.mark.asyncio


async def test_live_probe_finds_master_when_cache_empty():
    row = {
        "id": 1,
        "name": "aliyun",
        "stats_host": "janus",
        "stats_port": 8090,
        "stats_token_ciphertext": None,
        "enabled": True,
    }
    with (
        patch("app.maintenance.database.fetch", AsyncMock(return_value=[row])),
        patch("app.maintenance.egress.egress_policy_on", AsyncMock(return_value=False)),
        patch("app.maintenance.egress.stats_token_for", return_value="tok"),
        patch("app.nodes._health", {}, create=True),
        patch(
            "app.nodes.poll_node",
            AsyncMock(return_value={"status": "healthy", "role": "master"}),
        ) as poll,
    ):
        host, port, token = await _master_stats_target()
    assert (host, port, token) == ("janus", 8090, "tok")
    poll.assert_awaited_once()


async def test_no_master_when_probe_not_master():
    row = {
        "id": 1,
        "name": "worker-a",
        "stats_host": "w1",
        "stats_port": 8090,
        "stats_token_ciphertext": None,
        "enabled": True,
    }
    with (
        patch("app.maintenance.database.fetch", AsyncMock(return_value=[row])),
        patch("app.maintenance.egress.egress_policy_on", AsyncMock(return_value=False)),
        patch("app.maintenance.egress.stats_token_for", return_value=None),
        patch("app.nodes._health", {}, create=True),
        patch(
            "app.nodes.poll_node",
            AsyncMock(return_value={"status": "healthy", "role": "worker"}),
        ),
    ):
        with pytest.raises(MmdbRefreshError) as ei:
            await _master_stats_target()
    assert ei.value.code == "no_master"
