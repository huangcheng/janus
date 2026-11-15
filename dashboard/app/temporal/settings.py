"""Env for Temporal client + worker."""

from __future__ import annotations

import os

from . import NAMESPACE, TASK_QUEUE

# MaxMind GeoLite updates slowly; weekly is a sensible default.
_DEFAULT_GEOIP_INTERVAL_SEC = 7 * 24 * 3600


def temporal_host() -> str:
    return os.environ.get("TEMPORAL_HOST", "").strip()


def temporal_namespace() -> str:
    return os.environ.get("TEMPORAL_NAMESPACE", NAMESPACE).strip() or NAMESPACE


def temporal_task_queue() -> str:
    return os.environ.get("TEMPORAL_TASK_QUEUE", TASK_QUEUE).strip() or TASK_QUEUE


def temporal_enabled() -> bool:
    return bool(temporal_host())


def geoip_mmdb_interval_sec() -> int:
    raw = os.environ.get("JANUS_GEOIP_MMDB_INTERVAL_SEC", str(_DEFAULT_GEOIP_INTERVAL_SEC))
    try:
        return max(3600, int(raw))
    except ValueError:
        return _DEFAULT_GEOIP_INTERVAL_SEC
