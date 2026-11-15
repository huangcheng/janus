from __future__ import annotations

from temporalio import activity


@activity.defn(name="run_model_sync")
async def run_model_sync_activity(source: str = "scheduled") -> dict:
    from app.routers import sync as sync_mod

    return await sync_mod.run_model_sync(source)
