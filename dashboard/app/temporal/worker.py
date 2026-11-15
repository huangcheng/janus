"""Temporal worker entrypoint: ``janus-worker`` / ``python -m app.temporal.worker``."""

from __future__ import annotations

import asyncio
import logging
import sys

from temporalio.worker import Worker

from app import database
from app.temporal.activities import geoip_mmdb as geo_acts
from app.temporal.activities import model_sync as sync_acts
from app.temporal.client import ensure_all_schedules
from app.temporal.settings import temporal_host, temporal_namespace, temporal_task_queue
from app.temporal.telemetry import connect_client
from app.temporal.workflows.geoip_mmdb import GeoIpMmdbRefreshWorkflow
from app.temporal.workflows.model_sync import ModelSyncWorkflow

log = logging.getLogger("janus.dashboard.temporal.worker")


async def run() -> None:
    host = temporal_host()
    if not host:
        log.error("TEMPORAL_HOST is required")
        sys.exit(2)
    await database.init_pool()
    client = await connect_client(
        host=host,
        namespace=temporal_namespace(),
        service_name="janus-worker",
    )
    try:
        await ensure_all_schedules()
    except Exception:  # noqa: BLE001
        log.warning("schedule ensure at worker boot failed; continuing", exc_info=True)
    worker = Worker(
        client,
        task_queue=temporal_task_queue(),
        workflows=[ModelSyncWorkflow, GeoIpMmdbRefreshWorkflow],
        activities=[
            sync_acts.run_model_sync_activity,
            geo_acts.refresh_mmdb_activity,
        ],
    )
    log.info(
        "janus-worker listening queue=%s namespace=%s host=%s",
        temporal_task_queue(),
        temporal_namespace(),
        host,
    )
    try:
        await worker.run()
    finally:
        await database.close_pool()


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    )
    asyncio.run(run())


if __name__ == "__main__":
    main()
