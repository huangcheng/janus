from __future__ import annotations

from datetime import timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy

with workflow.unsafe.imports_passed_through():
    from app.temporal.activities import geoip_mmdb as geo_acts


@workflow.defn(name="GeoIpMmdbRefreshWorkflow")
class GeoIpMmdbRefreshWorkflow:
    @workflow.run
    async def run(self, source: str = "scheduled") -> dict:
        return await workflow.execute_activity(
            geo_acts.refresh_mmdb_activity,
            source,
            start_to_close_timeout=timedelta(minutes=30),
            retry_policy=RetryPolicy(maximum_attempts=2),
        )
