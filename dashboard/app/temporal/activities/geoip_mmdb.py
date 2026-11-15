from __future__ import annotations

from temporalio import activity


@activity.defn(name="refresh_mmdb")
async def refresh_mmdb_activity(source: str = "scheduled") -> dict:
    from app import maintenance

    try:
        result = await maintenance.refresh_mmdb()
    except maintenance.MmdbRefreshError as e:
        raise RuntimeError(f"{e.code}: {e.message}") from e
    result["source"] = source
    return result
