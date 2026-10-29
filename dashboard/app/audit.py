"""Audit trail for dashboard mutations.

Persisted to Postgres (audit_events table, created by ensure_schema) so
history survives dashboard restarts and deploys; an in-memory ring
mirrors the newest events as a read fallback when the DB is unavailable.
Every mutating endpoint calls log().

Persistence is best-effort, not transactional with the mutation: a DB
hiccup can drop a row (the ring still holds it until restart), so treat
the "every mutation is audited" invariant as intended, not guaranteed.
"""

import asyncio
import itertools
import logging
import threading
import time
from collections import deque

logger = logging.getLogger("janus.dashboard.audit")

_MAX_EVENTS = 1000
_events: deque[dict] = deque(maxlen=_MAX_EVENTS)
_counter = itertools.count(1)
_lock = threading.Lock()
# asyncio keeps only weak refs to tasks; hold ours or a GC cycle could
# drop a pending audit write.
_persist_tasks: set[asyncio.Task] = set()


def log(action: str, target: str | None = None, detail: str | None = None) -> None:
    """Record a dashboard mutation (actor is always the console user).

    Never raises and never blocks the caller: the DB write is scheduled
    on the running loop (fire-and-forget); without a loop (tests, sync
    contexts) the event only lands in the in-memory ring.
    """
    event = {
        "id": next(_counter),
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime()),
        "actor": "console",
        "action": action,
        "target": target,
        "detail": detail,
    }
    with _lock:
        _events.appendleft(event)
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return
    t = loop.create_task(_persist(event))
    _persist_tasks.add(t)
    t.add_done_callback(_persist_tasks.discard)


async def _persist(event: dict) -> None:
    try:
        from datetime import datetime

        from . import database

        await database.execute(
            "INSERT INTO audit_events (ts, actor, action, target, detail) "
            "VALUES ($1, $2, $3, $4, $5)",
            datetime.fromisoformat(event["ts"]),
            event["actor"],
            event["action"],
            event["target"],
            event["detail"],
        )
    except Exception:
        # The mutation already succeeded; losing its audit row to a DB
        # hiccup must not surface to the user. The in-memory ring still
        # holds it until the next restart.
        logger.warning("audit persist failed for %s", event.get("action"), exc_info=True)


async def flush() -> None:
    """Await every scheduled persist task.

    For short-lived processes (the alerts_debug driver): a fire-and-forget
    persist that is still pending when the DB pool closes loses the row to
    "pool is closing" — call this before database.close_pool(). The
    long-lived dashboard never needs it (the loop outlives every task).
    """
    while True:
        pending = [t for t in _persist_tasks if not t.done()]
        if not pending:
            return
        await asyncio.gather(*pending, return_exceptions=True)


async def recent(limit: int = 200) -> list[dict]:
    """Newest-first audit trail. DB is the source of truth; the
    in-memory ring serves reads only when the DB query fails."""
    limit = max(0, min(limit, 2000))
    try:
        from . import database

        rows = await database.fetch(
            "SELECT ts, actor, action, target, detail FROM audit_events "
            "ORDER BY ts DESC, id DESC LIMIT $1",
            limit,
        )
        return [dict(r) for r in rows]
    except Exception:
        logger.warning("audit read fell back to in-memory ring", exc_info=True)
        with _lock:
            return list(_events)[:limit]
