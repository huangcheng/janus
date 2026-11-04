"""Shared secret-reveal rate limiter.

One sliding-window budget for EVERY reveal surface (agent keys, API
tokens) — a per-router copy would double the budget, letting a caller
spend 30/min on each surface. Hoisted verbatim from routers/keys.py; the
429 keeps keys' wire shape (retry_after extra + Retry-After header).
"""

import logging
import time
from collections import defaultdict, deque

from fastapi import HTTPException

logger = logging.getLogger("janus.dashboard.reveal_limit")

# Reveal rate limit: 30/min per login session (JWT sub+jti; else client IP).
REVEAL_LIMIT = 30
REVEAL_WINDOW_SEC = 60.0

REVEAL_HEADERS = {"Cache-Control": "no-store", "Pragma": "no-cache"}
CREATE_HEADERS = {"Cache-Control": "no-store"}

_hits: dict[str, deque[float]] = defaultdict(deque)


def err(
    status: int,
    code: str,
    message: str,
    *,
    headers: dict | None = None,
    **extra,
) -> HTTPException:
    """House-error raiser (keys.py's _err twin — the limiter must not
    import it back from the router: keys.py imports this module)."""
    body = {"error": {"code": code, "message": message}}
    if extra:
        body["error"].update(extra)
    return HTTPException(status, detail=body, headers=headers)


def check_reveal_rate(bucket: str) -> None:
    """In-memory 30/min. Limiter bugs → 503 limiter_unavailable (not a fake 429)."""
    try:
        now = time.monotonic()
        # Prune this bucket and drop empty peers so the dict cannot grow unboundedly.
        stale = [
            k
            for k, ts in _hits.items()
            if k != bucket and not any(now - t < REVEAL_WINDOW_SEC for t in ts)
        ]
        for k in stale:
            _hits.pop(k, None)
        hits = [t for t in _hits[bucket] if now - t < REVEAL_WINDOW_SEC]
        if len(hits) >= REVEAL_LIMIT:
            _hits[bucket] = deque(hits)
            # Both the body extra and the header derive from the window
            # constant, so a window change cannot leave them drifting.
            retry = int(REVEAL_WINDOW_SEC)
            raise err(
                429,
                "rate_limited",
                "reveal rate limit exceeded; try again later",
                retry_after=retry,
                headers={**REVEAL_HEADERS, "Retry-After": str(retry)},
            )
        hits.append(now)
        _hits[bucket] = deque(hits)
    except HTTPException:
        raise
    except Exception as e:
        # Never a fake 429 — but never a silent rebrand either: the real
        # defect stays diagnosable in the log.
        logger.exception("reveal limiter failed")
        raise err(
            503,
            "limiter_unavailable",
            "reveal rate limiter unavailable",
            headers=dict(REVEAL_HEADERS),
        ) from e
