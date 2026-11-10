#!/usr/bin/env python3
"""Verification for the dashboard's telemetry (design §11.1 / items 28 and 30).

Asserts the contract the dashboard has to keep to be a trace PARTICIPANT
rather than a passive viewer:

  * a poll request carries a W3C `traceparent` that matches the cycle's trace,
    so the gateway's spans join it instead of starting a new one;
  * the CLIENT span carries the required attributes and is exported as an
    OTLP/HTTP-JSON body on `/v1/traces`;
  * the span hangs off the cycle root, so one cycle is one trace;
  * a trace id can never be all zeros (W3C forbids it);
  * `/metrics` reports the exporter's real state and does NOT fabricate zeros
    when export is off.

Run from the dashboard directory:
    .venv/bin/python scripts/verification_telemetry.py
Exit 0 on success, 1 on any failure.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import httpx  # noqa: E402

from app import ops_puller, telemetry  # noqa: E402
from app.routers import metrics as metrics_router  # noqa: E402

failures: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f": {detail}"))
    if not ok:
        failures.append(name)


async def poll_request_carries_traceparent() -> None:
    """The whole point of instrumenting the poller."""
    captured: dict[str, object] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["headers"] = dict(request.headers)
        return httpx.Response(200, json={"boot_id": "b1"})

    trace = telemetry.Trace()
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as inner:
        await ops_puller._get_json(inner, "http://node1:8090/stats/health", "tok", trace)
    headers = captured.get("headers") or {}
    tp = headers.get("traceparent") if isinstance(headers, dict) else None
    check("poll request carries a traceparent", tp is not None, repr(tp))
    check("traceparent matches the cycle trace", tp == trace.traceparent(), repr(tp))
    check("traceparent version is 00", str(tp).startswith("00-"), repr(tp))
    check("traceparent is marked sampled", str(tp).endswith("-01"), repr(tp))
    check(
        "authorization survives the traceparent merge",
        isinstance(headers, dict) and headers.get("authorization") == "Bearer tok",
        repr(headers),
    )


async def poll_records_spans_on_success_and_failure() -> None:
    """The span must be RECORDED whether the poll succeeds or fails.

    This is the regression that shipped once already: the success path
    `return`ed from inside the fetch's `try`, so an `else` clause that closed
    and queued the span never ran, and every successful poll exported nothing.
    """

    def make_wrapper(response_factory):  # noqa: ANN001, ANN202
        def handler(request: httpx.Request) -> httpx.Response:
            return response_factory(request)

        return handler

    recorded: list[telemetry.Span] = []
    original = telemetry.record_span
    telemetry.record_span = recorded.append  # type: ignore[assignment]
    try:
        # --- success ---
        handler = make_wrapper(lambda _r: httpx.Response(200, json={"boot_id": "b1"}))
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as inner:
            await ops_puller._get_json(
                inner, "http://node1:8090/stats/health", None, telemetry.Trace()
            )
        check("a successful poll records its span", len(recorded) == 1, str(len(recorded)))
        if recorded:
            check("successful span has an end time", recorded[0].end_ns is not None)
            check(
                "successful span is not marked ERROR",
                recorded[0].as_otlp().get("status") is None,
                repr(recorded[0].as_otlp().get("status")),
            )

        # --- 404 is a supported answer, and still a recorded span ---
        recorded.clear()
        handler = make_wrapper(lambda _r: httpx.Response(404))
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as inner:
            await ops_puller._get_json(
                inner, "http://node1:8090/stats/sched", None, telemetry.Trace()
            )
        check("a 404 poll records its span", len(recorded) == 1, str(len(recorded)))
        if recorded:
            # The poller ACCEPTS 404/503 (supported-but-absent endpoint) as a
            # successful poll and closes the span with error=False: the span
            # status must agree with the task-runs view, not contradict it.
            check(
                "an accepted 404 poll span is not ERROR",
                recorded[0].as_otlp().get("status") is None,
                repr(recorded[0].as_otlp().get("status")),
            )
            # And the DERIVED rule still holds for a plain 4xx the poller
            # does not accept: >= 400 is this side's failed request.
            probe = telemetry.Span(trace_id="00" * 16, parent_id=None, name="p", kind=3)
            probe.finish(401)
            check(
                "an unaccepted 4xx client span is ERROR",
                probe.as_otlp().get("status", {}).get("code") == 2,
                repr(probe.as_otlp().get("status")),
            )

        # --- failure ---
        recorded.clear()
        handler = make_wrapper(lambda _r: httpx.Response(500))
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as inner:
            try:
                await ops_puller._get_json(
                    inner, "http://node1:8090/stats/logs", None, telemetry.Trace()
                )
            except RuntimeError:
                pass
        check("a failed poll records its span", len(recorded) == 1, str(len(recorded)))
        if recorded:
            attrs = {x["key"]: x["value"] for x in recorded[0].as_otlp()["attributes"]}
            check("failed span carries error.type", "error.type" in attrs, repr(sorted(attrs)))
            check(
                "failed span sets ERROR status",
                recorded[0].as_otlp().get("status", {}).get("code") == 2,
                repr(recorded[0].as_otlp().get("status")),
            )
    finally:
        telemetry.record_span = original  # type: ignore[assignment]


async def span_shape_and_export() -> None:
    """One cycle = one trace, with every CLIENT span under the root."""
    trace = telemetry.Trace()
    a = trace.client_span("GET /stats/health")
    a.set("http.request.method", "GET")
    a.set("server.address", "node1")
    a.finish(200)
    b = trace.client_span("GET /stats/sched")
    b.finish(200)

    root_otlp = trace.root_span_id
    check("CLIENT spans share the cycle trace", a.trace_id == b.trace_id == trace.trace_id)
    check("CLIENT spans hang off the cycle root", a.parent_id == b.parent_id == root_otlp)

    # The root the traceparent advertises must be a span that IS recorded —
    # otherwise every child in a backend hangs off a nonexistent parent
    # (the phantom-parent defect, on the poller's leg).
    root = trace.root_span("ops pull")
    check("root span owns the advertised id", root.span_id == trace.root_span_id)
    check("root span is parentless", root.parent_id is None)
    root.finish()
    check("root span encodes as INTERNAL (1)", root.as_otlp()["kind"] == 1)
    check(
        "span ids are 16 hex",
        len(a.span_id) == 16 and all(c in "0123456789abcdef" for c in a.span_id),
    )
    check("trace ids are 32 hex", len(trace.trace_id) == 32)
    check("trace id is never all zeros", trace.trace_id != "00" * 16)

    otlp = a.as_otlp()
    check("kind is CLIENT (3)", otlp.get("kind") == 3, repr(otlp.get("kind")))
    check("timestamps are decimal strings", isinstance(otlp["startTimeUnixNano"], str))
    attrs = {x["key"]: x["value"] for x in otlp["attributes"]}
    check("http.request.method present", "http.request.method" in attrs)
    check("server.address present", "server.address" in attrs)
    check("http.response.status_code present", "http.response.status_code" in attrs)
    check("status is not ERROR on 200", "status" not in otlp, repr(otlp.get("status")))

    # OTLP encodes ints as DECIMAL STRINGS; a JSON number is silently rounded
    # by every JS consumer, which is the bug this asserts against.
    status_attr = attrs.get("http.response.status_code", {})
    check("status code encoded as intValue string", "intValue" in status_attr, repr(status_attr))

    # And the body actually reaches a collector. A REAL local HTTP server,
    # not a mock: `_post` does `import httpx` inside the function, so patching
    # an attribute on the module object is invisible to it — and a real socket
    # proves the wire format end to end, which a mock cannot.
    #
    # `TelemetryState` takes the FULL URL (exporter spec: a per-signal
    # endpoint is used as-is); constructing it with the suffixed form here
    # also pins that the exporter never re-appends a path of its own.
    got: list[dict] = []
    with _collector(got) as endpoint:
        st = telemetry.TelemetryState(f"{endpoint}/v1/traces")
        await st._post([a])
        await asyncio.sleep(0.05)

    check("export reached the collector", len(got) == 1, f"{len(got)} posts")
    if got:
        check("export posts to /v1/traces", got[0]["path"] == "/v1/traces", got[0]["path"])
        body = got[0]["body"]
        rs = body.get("resourceSpans")
        check("body has resourceSpans", bool(rs))
        if rs:
            res = {x["key"]: list(x["value"].values())[0] for x in rs[0]["resource"]["attributes"]}
            check(
                "resource names the dashboard",
                res.get("service.name") == "janus-dashboard",
                repr(res),
            )
            check(
                "resource marks the dashboard role", res.get("janus.role") == "dashboard", repr(res)
            )
            spans = rs[0]["scopeSpans"][0]["spans"]
            check("one span in the batch", len(spans) == 1, str(len(spans)))
            if spans:
                sent = spans[0]
                check("wire span keeps the trace id", sent["traceId"] == trace.trace_id)
                check("wire span keeps the parent", sent.get("parentSpanId") == trace.root_span_id)


@contextlib.contextmanager
def _collector(sink: list[dict]):
    """A real OTLP collector on an ephemeral port, for one test."""
    import threading
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802
            n = int(self.headers.get("content-length", 0))
            raw = self.rfile.read(n)
            sink.append({"path": self.path, "body": json.loads(raw)})
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b"{}")

        def log_message(self, *a):  # noqa: ANN002
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        server.shutdown()
        thread.join(timeout=5)


def metrics_endpoint() -> None:
    """`/metrics` must report the truth, including when export is off."""
    lines = metrics_router._lines()
    text = "\n".join(lines)
    check("metrics has uptime", "janus_dashboard_uptime_seconds" in text)
    check("metrics has the enabled gauge", "janus_dashboard_telemetry_enabled" in text)
    # With no exporter running there must be NO fabricated exporter counters:
    # "export is off" and "export is dropping everything" are different facts.
    check(
        "export off fabricates no counters",
        "janus_dashboard_telemetry_spans_total" not in text,
        "counters present while export is off",
    )
    check(
        "error class maps collector http",
        metrics_router._class_of("collector http 500") == "collector_http",
    )
    check("error class maps connect", metrics_router._class_of("ConnectError") == "connect")
    check("error class maps nothing to None", metrics_router._class_of(None) is None)


async def main() -> int:
    await poll_request_carries_traceparent()
    await poll_records_spans_on_success_and_failure()
    await span_shape_and_export()
    metrics_endpoint()
    print()
    if failures:
        print(f"{len(failures)} failed: {failures}")
        return 1
    print("all dashboard telemetry checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
