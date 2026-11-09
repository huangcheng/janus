"""The dashboard's own `/metrics` surface (design item 30).

The gateway already exports Prometheus text; this is the same shape for the
DASHBOARD process, so one scrape config can cover both and an operator can ask
"is the poller healthy" without reading logs.

WHAT IS PUBLISHED
=================
Only what the dashboard actually owns and can answer without a database round
trip on the scrape path: the telemetry exporter's own queue and loss counters,
its last-error class, and process uptime. The dashboard's *business* metrics
(usage, failures, node health) are already computed from Postgres by the
routers the SPA calls — duplicating them here would put a query on the scrape
path and give a second, possibly-stale answer to the same question.

FORMAT
======
Prometheus text exposition, version 0.0.4, the same content type the gateway
serves. Hand-written rather than `prometheus_client`: this is a handful of
counter lines, and the repo does not add a dependency for a handful of lines.

A failure class is exported as a LABEL-BOUND gauge of 1 rather than as a
numeric code, because a code would be meaningless in a query while
`last_error{class="collector_http"} == 1` reads directly as "that is what broke".
"""

from __future__ import annotations

import logging
import time

from fastapi import APIRouter, Request
from fastapi.responses import PlainTextResponse

from .. import telemetry

router = APIRouter()
logger = logging.getLogger("janus.dashboard.metrics")

_STARTED = time.monotonic()

# Bounded, closed set: an unexpected class is counted under "other" so a novel
# failure cannot mint a new series.
_KNOWN_CLASSES = ("collector_http", "connect", "timeout", "other")


def _class_of(last_error: str | None) -> str | None:
    """Map the recorded error class onto the closed set above."""
    if last_error is None:
        return None
    if "collector http" in last_error:
        return "collector_http"
    if last_error in ("ConnectError", "ConnectTimeout"):
        return "connect"
    if last_error in ("ReadTimeout", "WriteTimeout", "PoolTimeout", "TimeoutException"):
        return "timeout"
    return "other"


def _lines() -> list[str]:
    st = telemetry.state()
    out: list[str] = []

    out.append("# HELP janus_dashboard_uptime_seconds Seconds since this process started.")
    out.append("# TYPE janus_dashboard_uptime_seconds gauge")
    out.append(f"janus_dashboard_uptime_seconds {time.monotonic() - _STARTED:.3f}")

    out.append(
        "# HELP janus_dashboard_telemetry_enabled Whether OTLP trace export is on (1) or off (0)."
    )
    out.append("# TYPE janus_dashboard_telemetry_enabled gauge")
    out.append(f"janus_dashboard_telemetry_enabled {1 if st is not None else 0}")

    if st is None:
        # No exporter: emit the abled state only. Fabricating zeros for the
        # rest would conflate "export is off" with "export is dropping
        # everything", which are different facts an operator must be able to
        # tell apart.
        return out

    out.append(
        "# HELP janus_dashboard_telemetry_spans_total Spans handed to the OTLP exporter, by result."
    )
    out.append("# TYPE janus_dashboard_telemetry_spans_total counter")
    out.append(f'janus_dashboard_telemetry_spans_total{{result="sent"}} {st.sent}')
    out.append(f'janus_dashboard_telemetry_spans_total{{result="failed"}} {st.failed}')
    out.append(f'janus_dashboard_telemetry_spans_total{{result="dropped_queue_full"}} {st.dropped}')

    out.append("# HELP janus_dashboard_telemetry_queue_depth Spans waiting in the exporter queue.")
    out.append("# TYPE janus_dashboard_telemetry_queue_depth gauge")
    out.append(f"janus_dashboard_telemetry_queue_depth {st.queued}")

    # One series per known class, all present, so a query does not have to
    # special-case an absent label when nothing is failing.
    cls = _class_of(st.last_error)
    out.append(
        "# HELP janus_dashboard_telemetry_last_error The exporter's last failure class (1 = current)."
    )
    out.append("# TYPE janus_dashboard_telemetry_last_error gauge")
    for name in _KNOWN_CLASSES:
        out.append(
            f'janus_dashboard_telemetry_last_error{{error_class="{name}"}} '
            f"{1 if (cls is not None and cls == name) else 0}"
        )
    return out


@router.get("/metrics", include_in_schema=False)
async def metrics(request: Request) -> PlainTextResponse:
    """Prometheus text exposition for this process.

    NO AUTH, like the gateway's admin plane: the endpoint is expected to be
    reachable only from the local collector (the same posture the gateway's
    `/metrics` has, where the admin listener binds a private address). If this
    service is ever exposed, put the endpoint behind the same reverse proxy as
    everything else rather than adding a bespoke token here — a second token
    mechanism is a second thing to rotate.

    A scrape must never fail because a counter could not be read: everything is
    wrapped, and a failure yields the uptime line alone plus a 200, because a
    prometheus scrape that errors discards the whole body including the series
    that did work.
    """
    try:
        body = "\n".join(_lines()) + "\n"
    except Exception:  # noqa: BLE001 - a scrape must never 500
        logger.exception("metrics render failed; serving the minimal set")
        body = (
            "# HELP janus_dashboard_uptime_seconds Seconds since this process started.\n"
            "# TYPE janus_dashboard_uptime_seconds gauge\n"
            f"janus_dashboard_uptime_seconds {time.monotonic() - _STARTED:.3f}\n"
        )
    return PlainTextResponse(body, media_type="text/plain; version=0.0.4; charset=utf-8")
