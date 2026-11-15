"""Janus Temporal control-plane worker (dashboard-side periodic jobs).

Next migrate (scaffold only): entitlement healing — see
``app.entitlements._healing_loop``.
"""

from __future__ import annotations

TASK_QUEUE = "janus-control"
NAMESPACE = "default"

__all__ = ["TASK_QUEUE", "NAMESPACE"]
