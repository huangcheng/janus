"""GET /api/config/backup and POST /api/config/restore (spec §5.2–§5.4)."""

import json
import logging

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response

from .. import audit, database
from ..auth import require_auth
from ..config import config
from ..config_backup_export import ExportError, attachment_filename, build_backup_document
from ..config_backup_restore import (
    RestoreError,
    RestoreQuery,
    apply_restore,
    audit_apply_attempt,
    decisions_gate,
    parse_document,
    parse_query,
    preflight,
    read_body_capped,
)

logger = logging.getLogger("janus.dashboard.config_backup")

router = APIRouter()
_AUTH = Depends(require_auth)


def _error(status: int, code: str, message: str) -> HTTPException:
    return HTTPException(status, detail={"error": {"code": code, "message": message}})


@router.get("/backup")
async def export_backup(user: dict = _AUTH):
    """Download one config-backup document. Authenticated, not throttled."""
    try:
        async with database.pool().acquire() as conn:
            document = await build_backup_document(conn)
        body = json.dumps(
            document,
            ensure_ascii=False,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
        filename = attachment_filename(document["taken_at"])
    except ExportError as exc:
        # Refusals are not audited (spec §5.2). The log line is server-side.
        logger.warning("config backup export refused (%s): %s", exc.code, exc)
        raise _error(500, exc.code, str(exc)) from exc
    except Exception as exc:
        # The client contract is {error:{code,message}}. An uncaught
        # error would not use that shape, and the message must not
        # carry SQL or row data.
        logger.exception("config backup export failed")
        raise _error(500, "export_invalid", "export failed") from exc

    limit = config.config_backup_max_bytes
    over_cap = len(body) > limit
    headers = {
        "Content-Disposition": f'attachment; filename="{filename}"',
        "Cache-Control": "no-store",
    }
    detail = f"bytes={len(body)} limit={limit}"
    if over_cap:
        headers["X-Janus-Backup-Warning"] = f"over-cap; limit={limit}"
        detail += "; over-cap; restore will 413 until the cap is raised and the dashboard restarted"
        logger.warning(
            "config backup export exceeds cap: bytes=%d limit=%d",
            len(body),
            limit,
        )
    audit.log("config_backup.export", document["integrity"]["payload_sha256"], detail)
    return Response(content=body, media_type="application/json", headers=headers)


def _apply_requested(request: Request, query: RestoreQuery | None) -> bool:
    if query is not None:
        return query.apply
    return request.query_params.get("apply") == "1"


def _attempt_flags(request: Request, query: RestoreQuery | None) -> tuple[str | None, bool]:
    if query is not None:
        return query.mode, query.allow_foreign_keys
    mode = request.query_params.get("mode", "merge")
    if mode not in ("merge", "replace"):
        mode = None
    return mode, request.query_params.get("allow_foreign_keys") == "1"


@router.post("/restore")
async def restore_config(request: Request, user: dict = _AUTH):
    """Dry-run plan, or a locked apply when ``apply=1``.

    Query-contract failures and the body cap happen before any snapshot.
    A dry-run takes no advisory locks and is not audited. The snapshot
    connection is released before the decisions probe, and apply acquires
    its lock connection only after that probe returns.
    """
    query: RestoreQuery | None = None
    doc = None
    try:
        query = parse_query(request)
        body = await read_body_capped(request, config.config_backup_max_bytes)
        doc = parse_document(body)
        async with database.pool().acquire() as conn:
            plan = await preflight(
                doc,
                snapshot_conn=conn,
                mode=query.mode,
                allow_foreign_keys=query.allow_foreign_keys,
            )
        # Snapshot SELECTs are finished and this connection is checked
        # back in before the probe. evaluate_write_gate acquires another
        # pool connection; holding this one across that call deadlocks
        # the pool when every slot is waiting on the probe.
        await decisions_gate(doc)
        if not query.apply:
            return plan.to_response()
        return await apply_restore(
            doc, mode=query.mode, allow_foreign_keys=query.allow_foreign_keys
        )
    except RestoreError as exc:
        logger.warning("config restore refused (%s): %s", exc.code, exc)
        if _apply_requested(request, query):
            mode, allow_foreign_keys = _attempt_flags(request, query)
            await audit_apply_attempt(doc, exc, mode=mode, allow_foreign_keys=allow_foreign_keys)
        raise _error(exc.status, exc.code, str(exc)) from exc
    except Exception as exc:
        logger.exception("config restore failed")
        if _apply_requested(request, query):
            mode, allow_foreign_keys = _attempt_flags(request, query)
            await audit_apply_attempt(
                doc,
                RestoreError(500, "apply_failed", "restore apply failed"),
                mode=mode,
                allow_foreign_keys=allow_foreign_keys,
            )
            raise _error(500, "apply_failed", "restore apply failed") from exc
        raise _error(500, "apply_failed", "restore preflight failed") from exc
