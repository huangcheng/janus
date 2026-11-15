"""Operator Temporal control-plane endpoints (status + workflow list/detail)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query

from ..auth import require_auth

router = APIRouter()


@router.get("/status")
async def temporal_control_status(user: dict = Depends(require_auth)):
    """Temporal connectivity for the Workflows console."""
    try:
        from ..temporal.client import temporal_status

        return await temporal_status()
    except Exception as e:  # noqa: BLE001
        return {"enabled": False, "error": str(e)}


@router.get("/workflows")
async def temporal_list_workflows(
    user: dict = Depends(require_auth),
    query: str = "",
    page_size: int = Query(50, ge=1, le=100),
):
    """List control-plane workflows (Visibility query; defaults to Janus task queue)."""
    try:
        from ..temporal.client import list_workflows

        return await list_workflows(query=query, page_size=page_size)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(
            503,
            detail={
                "error": {
                    "code": "temporal_unavailable",
                    "message": f"temporal unavailable: {e}",
                }
            },
        ) from e


@router.get("/workflows/{workflow_id}")
async def temporal_describe_workflow(
    workflow_id: str,
    user: dict = Depends(require_auth),
    run_id: str = "",
    history_limit: int = Query(80, ge=1, le=200),
):
    """Describe one workflow and return a truncated history for the drawer."""
    try:
        from ..temporal.client import describe_workflow

        return await describe_workflow(
            workflow_id,
            run_id=run_id or None,
            history_limit=history_limit,
        )
    except RuntimeError as e:
        raise HTTPException(
            503,
            detail={"error": {"code": "temporal_unavailable", "message": str(e)}},
        ) from e
    except Exception as e:  # noqa: BLE001
        raise HTTPException(
            503,
            detail={
                "error": {
                    "code": "temporal_unavailable",
                    "message": f"temporal unavailable: {e}",
                }
            },
        ) from e
