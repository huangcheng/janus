"""Dashboard-facing Temporal client helpers (soft-fail when TEMPORAL_HOST unset)."""

from __future__ import annotations

import logging
import uuid
from datetime import timedelta
from typing import Any

from .settings import (
    geoip_mmdb_interval_sec,
    temporal_enabled,
    temporal_host,
    temporal_namespace,
    temporal_task_queue,
)

log = logging.getLogger("janus.dashboard.temporal.client")

MODEL_SYNC_SCHEDULE_ID = "model-sync"
MODEL_SYNC_WORKFLOW_ID = "model-sync-scheduled"
GEOIP_MMDB_SCHEDULE_ID = "geoip-mmdb"
GEOIP_MMDB_WORKFLOW_ID = "geoip-mmdb-scheduled"


async def _client():
    if not temporal_enabled():
        return None
    from temporalio.client import Client

    return await Client.connect(temporal_host(), namespace=temporal_namespace())


async def temporal_status() -> dict[str, Any]:
    if not temporal_enabled():
        return {"enabled": False}
    try:
        client = await _client()
        assert client is not None
        return {
            "enabled": True,
            "host": temporal_host(),
            "namespace": temporal_namespace(),
            "task_queue": temporal_task_queue(),
        }
    except Exception as e:  # noqa: BLE001
        return {"enabled": True, "error": str(e)}


def _dt(value: Any) -> str | None:
    if value is None:
        return None
    try:
        return value.isoformat().replace("+00:00", "Z")
    except Exception:  # noqa: BLE001
        return str(value)


def _workflow_summary(exec: Any) -> dict[str, Any]:
    status = getattr(exec, "status", None)
    status_name = getattr(status, "name", None) or (str(status) if status is not None else None)
    return {
        "workflow_id": getattr(exec, "id", None) or getattr(exec, "workflow_id", None),
        "run_id": getattr(exec, "run_id", None),
        "workflow_type": getattr(getattr(exec, "workflow_type", None), "name", None)
        or getattr(exec, "workflow_type", None),
        "task_queue": getattr(exec, "task_queue", None),
        "status": status_name,
        "start_time": _dt(getattr(exec, "start_time", None)),
        "close_time": _dt(getattr(exec, "close_time", None)),
        "execution_time": _dt(getattr(exec, "execution_time", None)),
        "history_length": getattr(exec, "history_length", None),
    }


async def list_workflows(
    *,
    query: str = "",
    page_size: int = 50,
) -> dict[str, Any]:
    client = await _client()
    if client is None:
        return {"enabled": False, "items": [], "next_page_token": None}
    q = (query or "").strip()
    if not q:
        q = f'TaskQueue = "{temporal_task_queue()}"'
    items: list[dict[str, Any]] = []
    next_token: str | None = None
    try:
        pager = client.list_workflows(query=q, page_size=min(max(page_size, 1), 100))
        async for exec in pager:
            items.append(_workflow_summary(exec))
            if len(items) >= page_size:
                break
        raw = getattr(pager, "next_page_token", None) or getattr(pager, "_next_page_token", None)
        if isinstance(raw, (bytes, bytearray)) and raw:
            import base64

            next_token = base64.urlsafe_b64encode(bytes(raw)).decode("ascii")
        elif isinstance(raw, str) and raw:
            next_token = raw
    except Exception as e:  # noqa: BLE001
        return {
            "enabled": True,
            "items": items,
            "next_page_token": None,
            "error": str(e),
            "query": q,
        }
    return {"enabled": True, "items": items, "next_page_token": next_token, "query": q}


async def describe_workflow(
    workflow_id: str,
    *,
    run_id: str | None = None,
    history_limit: int = 80,
) -> dict[str, Any]:
    client = await _client()
    if client is None:
        raise RuntimeError("TEMPORAL_HOST is not configured")
    handle = client.get_workflow_handle(workflow_id, run_id=run_id)
    desc = await handle.describe()
    summary = _workflow_summary(desc)
    query_status: str | None = None
    try:
        query_status = await handle.query("status")
        if query_status is not None:
            query_status = str(query_status)
    except Exception:  # noqa: BLE001
        query_status = None

    events: list[dict[str, Any]] = []
    try:
        count = 0
        async for event in handle.fetch_history_events():
            et = getattr(event, "event_type", None)
            events.append(
                {
                    "event_id": getattr(event, "event_id", None),
                    "event_type": getattr(et, "name", None) or str(et),
                    "event_time": _dt(getattr(event, "event_time", None)),
                }
            )
            count += 1
            if count >= history_limit:
                break
    except Exception as e:  # noqa: BLE001
        return {
            "enabled": True,
            "workflow": summary,
            "query_status": query_status,
            "events": events,
            "error": str(e),
        }

    failure: str | None = None
    close_status = summary.get("status")
    if close_status and "FAILED" in str(close_status).upper():
        failure = "Workflow failed — see history events"

    return {
        "enabled": True,
        "workflow": summary,
        "query_status": query_status,
        "events": events,
        "failure": failure,
    }


async def start_model_sync(*, source: str = "manual", wait: bool = True) -> dict[str, Any]:
    """Start ModelSyncWorkflow. When wait=True, return the activity result dict."""
    client = await _client()
    if client is None:
        raise RuntimeError("TEMPORAL_HOST is not configured")
    from .workflows.model_sync import ModelSyncWorkflow

    wid = f"model-sync:{source}:{uuid.uuid4().hex[:12]}"
    handle = await client.start_workflow(
        ModelSyncWorkflow.run,
        args=[source],
        id=wid,
        task_queue=temporal_task_queue(),
    )
    if not wait:
        return {"workflow_id": wid, "run_id": handle.result_run_id}
    result = await handle.result()
    if isinstance(result, dict):
        result = {**result, "workflow_id": wid}
    return result if isinstance(result, dict) else {"workflow_id": wid, "result": result}


async def start_geoip_mmdb_refresh(*, source: str = "manual", wait: bool = True) -> dict[str, Any]:
    """Start GeoIpMmdbRefreshWorkflow (optional wait for result)."""
    client = await _client()
    if client is None:
        raise RuntimeError("TEMPORAL_HOST is not configured")
    from .workflows.geoip_mmdb import GeoIpMmdbRefreshWorkflow

    wid = f"geoip-mmdb:{source}:{uuid.uuid4().hex[:12]}"
    handle = await client.start_workflow(
        GeoIpMmdbRefreshWorkflow.run,
        args=[source],
        id=wid,
        task_queue=temporal_task_queue(),
    )
    if not wait:
        return {"workflow_id": wid, "run_id": handle.result_run_id}
    result = await handle.result()
    if isinstance(result, dict):
        result = {**result, "workflow_id": wid}
    return result if isinstance(result, dict) else {"workflow_id": wid, "result": result}


async def _read_model_sync_interval_sec() -> int:
    """Prefer settings.model_sync; fall back to env/default."""
    from app import database
    from app.config import config

    try:
        row = await database.fetchrow("SELECT value FROM settings WHERE key = $1", "model_sync")
    except Exception:  # noqa: BLE001
        return int(config.sync_interval_sec)
    value = (row or {}).get("value") if row else None
    if isinstance(value, str):
        import json

        try:
            value = json.loads(value)
        except ValueError:
            value = None
    if isinstance(value, dict) and isinstance(value.get("interval_sec"), int):
        return int(value["interval_sec"])
    return int(config.sync_interval_sec)


async def ensure_model_sync_schedule(*, interval_sec: int | None = None) -> None:
    """Create or update the model-sync Schedule; pause/delete when interval <= 0."""
    client = await _client()
    if client is None:
        return
    from temporalio.client import (
        Schedule,
        ScheduleActionStartWorkflow,
        ScheduleIntervalSpec,
        ScheduleSpec,
        ScheduleState,
        ScheduleUpdate,
        ScheduleUpdateInput,
    )

    from .workflows.model_sync import ModelSyncWorkflow

    sec = interval_sec if interval_sec is not None else await _read_model_sync_interval_sec()
    schedule_id = MODEL_SYNC_SCHEDULE_ID

    if sec <= 0:
        try:
            handle = client.get_schedule_handle(schedule_id)
            await handle.delete()
            log.info("deleted Temporal schedule %s (manual-only interval)", schedule_id)
        except Exception:  # noqa: BLE001
            log.debug("model-sync schedule delete skipped", exc_info=True)
        return

    action = ScheduleActionStartWorkflow(
        ModelSyncWorkflow.run,
        args=["scheduled"],
        id=MODEL_SYNC_WORKFLOW_ID,
        task_queue=temporal_task_queue(),
    )
    spec = ScheduleSpec(intervals=[ScheduleIntervalSpec(every=timedelta(seconds=sec))])
    schedule = Schedule(action=action, spec=spec, state=ScheduleState(paused=False))

    try:
        await client.create_schedule(schedule_id, schedule, trigger_immediately=True)
        log.info("created Temporal schedule %s every=%ss (triggered)", schedule_id, sec)
        return
    except Exception:  # noqa: BLE001 — already exists
        log.debug("model-sync schedule create race; updating", exc_info=True)

    handle = client.get_schedule_handle(schedule_id)

    async def _updater(_input: ScheduleUpdateInput) -> ScheduleUpdate:
        return ScheduleUpdate(schedule=schedule)

    try:
        await handle.update(_updater)
        log.info("updated Temporal schedule %s every=%ss", schedule_id, sec)
    except Exception:  # noqa: BLE001
        log.warning("model-sync schedule update failed", exc_info=True)
    await _trigger_if_never_ran(handle, schedule_id)


async def ensure_geoip_mmdb_schedule(*, interval_sec: int | None = None) -> None:
    """Create or update the geoip-mmdb Schedule when MaxMind creds exist."""
    client = await _client()
    if client is None:
        return

    from app import maintenance

    if not await maintenance.maxmind_configured():
        try:
            handle = client.get_schedule_handle(GEOIP_MMDB_SCHEDULE_ID)
            await handle.delete()
            log.info(
                "deleted Temporal schedule %s (MaxMind unconfigured)",
                GEOIP_MMDB_SCHEDULE_ID,
            )
        except Exception:  # noqa: BLE001
            log.debug("geoip-mmdb schedule delete skipped", exc_info=True)
        return

    from temporalio.client import (
        Schedule,
        ScheduleActionStartWorkflow,
        ScheduleIntervalSpec,
        ScheduleSpec,
        ScheduleState,
        ScheduleUpdate,
        ScheduleUpdateInput,
    )

    from .workflows.geoip_mmdb import GeoIpMmdbRefreshWorkflow

    sec = interval_sec if interval_sec is not None else geoip_mmdb_interval_sec()
    schedule_id = GEOIP_MMDB_SCHEDULE_ID
    action = ScheduleActionStartWorkflow(
        GeoIpMmdbRefreshWorkflow.run,
        args=["scheduled"],
        id=GEOIP_MMDB_WORKFLOW_ID,
        task_queue=temporal_task_queue(),
    )
    spec = ScheduleSpec(intervals=[ScheduleIntervalSpec(every=timedelta(seconds=sec))])
    schedule = Schedule(action=action, spec=spec, state=ScheduleState(paused=False))

    try:
        await client.create_schedule(schedule_id, schedule, trigger_immediately=True)
        log.info("created Temporal schedule %s every=%ss (triggered)", schedule_id, sec)
        return
    except Exception:  # noqa: BLE001
        log.debug("geoip-mmdb schedule create race; updating", exc_info=True)

    handle = client.get_schedule_handle(schedule_id)

    async def _updater(_input: ScheduleUpdateInput) -> ScheduleUpdate:
        return ScheduleUpdate(schedule=schedule)

    try:
        await handle.update(_updater)
        log.info("updated Temporal schedule %s every=%ss", schedule_id, sec)
    except Exception:  # noqa: BLE001
        log.warning("geoip-mmdb schedule update failed", exc_info=True)
    await _trigger_if_never_ran(handle, schedule_id)


async def _trigger_if_never_ran(handle: Any, schedule_id: str) -> None:
    """Fire once when a Schedule exists but has never produced an action.

    Fresh installs otherwise sit empty until the first interval elapses
    (e.g. 6h for model-sync), which makes the Workflows page look broken.
    """
    try:
        desc = await handle.describe()
        if int(getattr(desc.info, "num_actions", 0) or 0) > 0:
            return
        await handle.trigger()
        log.info("triggered Temporal schedule %s (never ran)", schedule_id)
    except Exception:  # noqa: BLE001
        log.debug("schedule trigger skipped for %s", schedule_id, exc_info=True)


async def ensure_all_schedules() -> None:
    """Idempotent schedule ensure for dashboard lifespan / worker boot."""
    await ensure_model_sync_schedule()
    await ensure_geoip_mmdb_schedule()
