"""Dashboard-native task_runs writer (failure-observability §4.3 / §5).

The ops-event drain is the single writer for gateway-sourced rows.
This module is the allowed second writer for dashboard-native jobs
(`node_id='dashboard'`): retention prune, alert tick self-health, etc.

Usage::

    async with record_run("retention_prune") as run:
        ...
        run.ok()          # or run.error(class, text) / leave for crash
"""

from __future__ import annotations

import logging
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import UTC, datetime

from . import database

logger = logging.getLogger("janus.dashboard.task_runs_writer")

NODE_ID = "dashboard"


class _Run:
    def __init__(self, run_id: str, name: str, started: datetime):
        self.run_id = run_id
        self.name = name
        self.started = started
        self._closed = False
        self.outcome: str | None = None
        self.error_class: str | None = None
        self.error: str | None = None

    def ok(self) -> None:
        self.outcome = "ok"

    def error(self, error_class: str = "internal", error: str = "") -> None:
        self.outcome = "error"
        self.error_class = error_class
        self.error = (error or "")[:1024]


@asynccontextmanager
async def record_run(
    name: str,
    *,
    expected_duration_ms: int | None = None,
    schedule_interval_ms: int | None = None,
) -> AsyncIterator[_Run]:
    """Open a task_runs row, yield a handle, close on exit."""
    run_id = str(uuid.uuid4())
    started = datetime.now(UTC)
    run = _Run(run_id, name, started)
    try:
        await database.execute(
            "INSERT INTO task_runs (node_id, run_id, name, started_at, phase, "
            "expected_duration_ms, schedule_interval_ms, meta) "
            "VALUES ($1, $2, $3, $4, 'running', $5, $6, '{}'::jsonb)",
            NODE_ID,
            run_id,
            name,
            started,
            expected_duration_ms,
            schedule_interval_ms,
        )
    except Exception:
        logger.exception("task_runs open failed for %s; continuing without row", name)
        yield run
        return
    try:
        yield run
        if run.outcome is None:
            run.outcome = "ok"
    except BaseException as exc:
        # Always record the crash (even if the body called ok()/error()
        # before raising). CancelledError is a BaseException since 3.8.
        run.outcome = "crash"
        run.error_class = run.error_class or "crash"
        run.error = run.error or repr(exc)[:1024]
        raise
    finally:
        # No `return` in finally: it would swallow the exception re-raised
        # by the handler above (and emit a SyntaxWarning on CPython).
        if not run._closed:
            run._closed = True
            if run.outcome is None:
                run.outcome = "error"
                run.error_class = run.error_class or "internal"
            finished = datetime.now(UTC)
            duration = int((finished - started).total_seconds() * 1000)
            try:
                await database.execute(
                    "UPDATE task_runs SET finished_at = $3, phase = 'done', outcome = $4, "
                    "error_class = $5, error = $6, duration_ms = $7, closed_by = 'writer' "
                    "WHERE node_id = $1 AND run_id = $2 AND finished_at IS NULL",
                    NODE_ID,
                    run_id,
                    finished,
                    run.outcome,
                    run.error_class,
                    run.error,
                    duration,
                )
            except Exception:
                logger.exception("task_runs close failed for %s/%s", name, run_id)
