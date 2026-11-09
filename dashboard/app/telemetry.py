"""The dashboard's own telemetry: trace context and a non-blocking exporter.

WHY THIS EXISTS (design §11.1)
==============================
The dashboard is the sole config writer and owns no gateway tables, so its
telemetry is strictly additive. Instrumenting its FastAPI request surface would
be cheap and nearly worthless — one operator. The value is in the POLL LOOPS,
the dashboard's only real backend work: they are what makes the dashboard a
trace PARTICIPANT rather than a passive viewer. Once a poll carries a
`traceparent`, the gateway's spans join the same trace and one view shows the
dashboard asking, the gateway answering, and the provider call inside it.

DESIGN CONSTRAINTS THIS CODE OBEYS (§11.2)
==========================================
* **Span creation must never be awaited.** The poll loops are latency-coupled
  by explicit comment; a synchronous export inside them would break the cadence
  the whole failure-observability system depends on. Everything here is
  fire-and-forget through a bounded queue drained by its own task.
* **The exporter must not share the DB pool or hold a transaction.** It does
  not touch the database at all.
* **Its egress posture is a recorded decision**, not silence — see
  `app/telemetry_egress.py`. The endpoint is boot configuration.
* **A flush on shutdown**, so a deploy does not lose the last batch.

WHY NOT THE OFFICIAL SDK
========================
The design names the OpenTelemetry SDK's lifecycle hooks. This implementation
is dependency-free instead, and the trade is recorded here rather than left
implicit: the repo forbids adding a dependency for what a bounded amount of
code can do, and the SDK would pull a transitive tree (`opentelemetry-sdk`,
`-semantic-conventions`, an OTLP exporter plus protobuf or an HTTP codec) for
one signal on one process. What is actually needed is small and fully specified
by the wire format: mint a trace id, propagate a `traceparent`, time a span,
POST OTLP/HTTP-JSON. That is what this module does.

The observable CONTRACT is the spec's, not the SDK's: CLIENT spans on the poll
endpoints with the required attributes, one trace per cycle, propagation to the
gateway, and a `/metrics` surface. If the SDK is ever adopted, `current()` /
`record_span()` are the only seams that change.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import secrets
import time
from collections.abc import Iterator
from typing import Any

from .telemetry_egress import exporter_egress_posture

logger = logging.getLogger(__name__)

# Bounded on purpose. A dead collector must cost a dropped batch, never an
# unbounded queue that grows until the poll loops are starved of memory.
MAX_QUEUE = 512
MAX_BATCH = 128
FLUSH_INTERVAL_SEC = 2.0
HTTP_TIMEOUT_SEC = 5.0

# OTel SpanKind: 2 = SERVER, 3 = CLIENT. The poller only makes CLIENT calls.
SPAN_KIND_CLIENT = 3

_state: "TelemetryState | None" = None


def _trace_id() -> str:
    """A W3C trace id: 16 random bytes, lowercase hex, never all zeros."""
    while True:
        tid = secrets.token_hex(16)
        if tid != "00" * 16:
            return tid


def _span_id() -> str:
    """A W3C span id: 8 random bytes, lowercase hex, never all zeros."""
    while True:
        sid = secrets.token_hex(8)
        if sid != "00" * 8:
            return sid


class Span:
    """One finished-or-in-flight span, in the shape the OTLP encoder wants.

    Deliberately a plain object rather than a context manager hierarchy: the
    poller's spans do not nest, so a parent id is always the cycle's, and a
    stack would be machinery with no user.
    """

    __slots__ = (
        "trace_id",
        "span_id",
        "parent_id",
        "name",
        "kind",
        "start_ns",
        "end_ns",
        "attrs",
        "status",
    )

    def __init__(self, *, trace_id: str, parent_id: str | None, name: str, kind: int) -> None:
        self.trace_id = trace_id
        self.span_id = _span_id()
        self.parent_id = parent_id
        self.name = name
        self.kind = kind
        self.start_ns = time.time_ns()
        self.end_ns: int | None = None
        self.attrs: dict[str, Any] = {}
        self.status: int | None = None

    def set(self, key: str, value: Any) -> None:
        """Attach an attribute. Values are encoded by `_encode_attr`."""
        self.attrs[key] = value

    def finish(self, status_code: int | None = None) -> None:
        """Close the span. Idempotent: a double-close keeps the first time."""
        if self.end_ns is None:
            self.end_ns = time.time_ns()
        if status_code is not None:
            self.status = status_code
            self.set("http.response.status_code", status_code)

    def as_otlp(self) -> dict[str, Any]:
        span: dict[str, Any] = {
            "traceId": self.trace_id,
            "spanId": self.span_id,
            "name": self.name,
            "kind": self.kind,
            "startTimeUnixNano": str(self.start_ns),
            "endTimeUnixNano": str(self.end_ns if self.end_ns is not None else time.time_ns()),
            "attributes": [_encode_attr(k, v) for k, v in sorted(self.attrs.items())],
        }
        if self.parent_id:
            span["parentSpanId"] = self.parent_id
        # OTLP status: 2 = ERROR only for a real failure. An unset status is
        # correct for a successful span; writing 0 explicitly is noise.
        if self.status is not None and self.status >= 500:
            span["status"] = {"code": 2}
        return span


class Trace:
    """One poll cycle's trace: the parent every CLIENT span in it hangs off."""

    __slots__ = ("trace_id", "root_span_id")

    def __init__(self) -> None:
        self.trace_id = _trace_id()
        self.root_span_id = _span_id()

    def client_span(self, name: str) -> Span:
        return Span(
            trace_id=self.trace_id,
            parent_id=self.root_span_id,
            name=name,
            kind=SPAN_KIND_CLIENT,
        )

    def traceparent(self) -> str:
        """The W3C header the gateway accepts, so its spans join this trace.

        Sampled flag is 01: the dashboard only mints a trace when it intends to
        record it, and a downstream service that sees 00 would drop the very
        spans this exists to collect.
        """
        return f"00-{self.trace_id}-{self.root_span_id}-01"


class TelemetryState:
    """The exporter: a bounded queue plus a draining task.

    Everything is non-blocking. `submit` appends and returns; the drain task
    owns the HTTP call. A collector that is slow, dead or misconfigured costs
    dropped spans and one throttled log line, never a delayed poll.
    """

    def __init__(self, endpoint: str) -> None:
        self._endpoint = endpoint.rstrip("/")
        self._queue: list[Span] = []
        self._task: asyncio.Task[None] | None = None
        self._dropped = 0
        self._sent = 0
        self._failed = 0
        self._last_error: str | None = None
        self._last_log = 0.0

    # ---------------------------------------------------------------- state
    @property
    def dropped(self) -> int:
        return self._dropped

    @property
    def sent(self) -> int:
        return self._sent

    @property
    def failed(self) -> int:
        return self._failed

    @property
    def last_error(self) -> str | None:
        return self._last_error

    @property
    def queued(self) -> int:
        return len(self._queue)

    def submit(self, span: Span) -> None:
        """Queue a finished span. Never raises, never blocks."""
        try:
            if len(self._queue) >= MAX_QUEUE:
                # Drop the OLDEST: the newest spans describe the cycle an
                # operator is looking at.
                self._queue.pop(0)
                self._dropped += 1
            self._queue.append(span)
        except Exception:  # noqa: BLE001 - telemetry must never break a poll
            pass

    # ------------------------------------------------------------- lifecycle
    def start(self) -> None:
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._drain_loop())

    async def stop(self) -> None:
        """Stop the loop and flush what is queued, so a deploy keeps the tail."""
        if self._task is not None:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._task
            self._task = None
        await self._flush()

    async def _drain_loop(self) -> None:
        while True:
            await asyncio.sleep(FLUSH_INTERVAL_SEC)
            await self._flush()

    async def _flush(self) -> None:
        if not self._queue:
            return
        batch = self._queue[:MAX_BATCH]
        del self._queue[:MAX_BATCH]
        try:
            await self._post(batch)
            self._sent += len(batch)
            self._last_error = None
        except Exception as exc:  # noqa: BLE001
            self._failed += len(batch)
            # The MESSAGE, not just the type: `RuntimeError` covers both a
            # rejected status and a broken connection, and the /metrics
            # classifier needs the status to distinguish them.
            self._last_error = f"{type(exc).__name__}: {exc}"
            self._warn(f"telemetry export failed: {exc}")

    def _warn(self, message: str) -> None:
        """Throttled: a dead collector must not fill the log disk."""
        now = time.monotonic()
        if now - self._last_log >= 60.0:
            self._last_log = now
            logger.warning("%s (further failures suppressed for 60s)", message)

    async def _post(self, spans: list[Span]) -> None:
        import httpx

        body = {
            "resourceSpans": [
                {
                    "resource": {"attributes": _resource_attributes()},
                    "scopeSpans": [
                        {
                            "scope": {"name": "janus-dashboard", "version": _version()},
                            "spans": [s.as_otlp() for s in spans],
                        }
                    ],
                }
            ]
        }
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT_SEC, trust_env=False) as client:
            resp = await client.post(
                f"{self._endpoint}/v1/traces",
                content=json.dumps(body).encode(),
                headers={"content-type": "application/json"},
            )
            # Reading the body is what surfaces a connection error under
            # httpx; the status is all this needs.
            _ = resp.content
            if not 200 <= resp.status_code < 300:
                raise RuntimeError(f"collector http {resp.status_code}")


def _encode_attr(key: str, value: Any) -> dict[str, Any]:
    """One OTLP attribute. Typed wrappers, because OTLP has no bare JSON."""
    if isinstance(value, bool):
        return {"key": key, "value": {"boolValue": value}}
    if isinstance(value, int):
        return {"key": key, "value": {"intValue": str(value)}}
    if isinstance(value, float):
        return {"key": key, "value": {"doubleValue": value}}
    return {"key": key, "value": {"stringValue": str(value)}}


def _resource_attributes() -> list[dict[str, Any]]:
    """The dashboard's Resource: same attribute names as the gateway's, so both
    appear as one service family in a backend rather than two strangers."""
    attrs: dict[str, Any] = {
        "service.name": os.environ.get("OTEL_SERVICE_NAME", "janus-dashboard"),
        "service.namespace": "janus",
        "service.version": _version(),
        "janus.role": "dashboard",
        "telemetry.sdk.name": "janus",
        "telemetry.sdk.language": "python",
        "telemetry.sdk.version": _version(),
    }
    # An explicit alias keeps the dashboard distinguishable from the gateways
    # when several run; same variable name the gateway uses.
    alias = os.environ.get("JANUS_NODE_ALIAS")
    if alias:
        attrs["janus.node.alias"] = alias
    return [_encode_attr(k, v) for k, v in sorted(attrs.items())]


def _version() -> str:
    try:
        from .config_backup_export import dashboard_version

        return dashboard_version()
    except Exception:  # noqa: BLE001
        return "0.0.0"


# -------------------------------------------------------------------- public
def enabled() -> bool:
    """Telemetry is on when an endpoint is configured, matching the gateway's
    precedence: the environment decides, and no endpoint means no telemetry."""
    return bool(os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "").strip())


def start() -> None:
    """Boot the exporter and log which egress posture it runs under."""
    global _state
    if not enabled():
        return
    if _state is not None:
        return
    _state = TelemetryState(os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"])
    _state.start()
    logger.info("telemetry export enabled (posture: %s)", exporter_egress_posture())


async def stop() -> None:
    global _state
    if _state is None:
        return
    await _state.stop()
    _state = None
    logger.info("telemetry export stopped")


def state() -> TelemetryState | None:
    return _state


@contextlib.contextmanager
def current(trace: Trace | None = None) -> Iterator[Trace]:
    """The trace for the work inside this block.

    A poll cycle opens one and passes it down, so every CLIENT span in the cycle
    shares a trace id and hangs off the cycle's root. Opening a fresh one is the
    default, so a caller that forgets to thread it still produces a coherent
    trace instead of an empty id.
    """
    yield trace if trace is not None else Trace()


def record_span(span: Span) -> None:
    """Hand a finished span to the exporter. A no-op when export is off."""
    if _state is not None:
        _state.submit(span)
