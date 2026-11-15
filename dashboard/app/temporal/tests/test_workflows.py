"""Workflow unit tests with Temporal time-skipping test environment."""

from __future__ import annotations

import pytest
from temporalio import activity
from temporalio.testing import WorkflowEnvironment
from temporalio.worker import Worker

from app.temporal.workflows.geoip_mmdb import GeoIpMmdbRefreshWorkflow
from app.temporal.workflows.model_sync import ModelSyncWorkflow

pytestmark = pytest.mark.asyncio


@activity.defn(name="run_model_sync")
async def fake_model_sync(source: str = "scheduled") -> dict:
    return {"ok": True, "source": source, "models_added": 0, "errors": 0}


@activity.defn(name="refresh_mmdb")
async def fake_refresh_mmdb(source: str = "scheduled") -> dict:
    return {"ok": True, "source": source, "bytes": 1_000_000}


async def test_model_sync_workflow_runs_activity():
    async with await WorkflowEnvironment.start_time_skipping() as env:
        async with Worker(
            env.client,
            task_queue="test",
            workflows=[ModelSyncWorkflow],
            activities=[fake_model_sync],
        ):
            result = await env.client.execute_workflow(
                ModelSyncWorkflow.run,
                args=["scheduled"],
                id="model-sync-test",
                task_queue="test",
            )
            assert result["ok"] is True
            assert result["source"] == "scheduled"


async def test_geoip_mmdb_workflow_runs_activity():
    async with await WorkflowEnvironment.start_time_skipping() as env:
        async with Worker(
            env.client,
            task_queue="test",
            workflows=[GeoIpMmdbRefreshWorkflow],
            activities=[fake_refresh_mmdb],
        ):
            result = await env.client.execute_workflow(
                GeoIpMmdbRefreshWorkflow.run,
                args=["scheduled"],
                id="geoip-mmdb-test",
                task_queue="test",
            )
            assert result["ok"] is True
            assert result["bytes"] == 1_000_000
