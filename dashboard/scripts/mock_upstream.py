#!/usr/bin/env python
"""Deterministic mock OpenAI-chat upstream for entitlement/failover E2E
(spec Part D). Behavior is keyed on the BEARER the gateway forwards
(the provider key under test):

  mock-key-a  -> 401 {"error":{"code":"InvalidAuthentication"}}
                                                    (key-level broken)
  mock-key-b  -> 200 always                       (healthy)
  mock-key-c  -> 400 ProductNotActivated body     (deny-shaped)
  mock-key-d  -> 429 Arrearage/balance class      (balance)
  mock-key-e  -> 503 always                       (provider 5xx)
  mock-key-f  -> 400 "no permission ... model"    (input-shape wording)
  mock-key-a2 / mock-key-c2 / mock-key-d2 -> class-paired duplicates of
                 a/c/d (observability-depth O.2 S4: a provider whose
                 only keys are a+a2 fails order-independently)
  sk-slow-*   -> 200 after an 8 s delay BEFORE THE FIRST BYTE
                 (scheduler-v2 TF-13.5/13.6 SLOW key — TTFB is the
                 health signal, so the delay must precede the first
                 response byte/event; a delay after the first chunk
                 would never trip the master TTFB EWMA). Applies to
                 unary (delay before body) AND streaming (delay before
                 the first SSE event, then the stream flows normally).
                 Delay override: JANUS_MOCK_SLOW_MS (default 8000).

Wire-compression fixture (W.1/W.1b, spec 2026-10-12-wire-compression
  section 4): a user message containing "wire-enc-fixture" selects
  deterministic BIG payloads (12 SSE chunk events ~740 B each /
  a ~2.8 KB unary body) so internal-hop messages cross the 256 B
  compression threshold; same key-error and sk-slow contracts apply.

Gate observability seams (test-only):

  GET  /v1/_inspect/last?path=<p> -> {"path", "entries"}: the last 8
                 requests recorded for <p>, newest first, each
                 {"headers", "path"} with lowercased header names.
                 Every request on every endpoint is recorded; per-path
                 rings mean probe traffic on other paths can neither
                 clobber nor crowd out an inspected entry within the
                 ring window.
  POST /alertsink                 -> append the parsed JSON body to the
                 bounded sink (cap 1000, oldest dropped), 200;
                 400 on an unparseable body (never 500 on garbage).
  GET  /alertsink/events          -> the captured JSON bodies (a list).
  POST /alertsink/clear           -> reset the sink.

Any other key -> 200. Run: ./.venv/Scripts/python.exe scripts/mock_upstream.py
"""

import asyncio
import os
from collections import deque

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

app = FastAPI()

SLOW_PREFIX = "sk-slow"
SLOW_SECONDS = float(os.environ.get("JANUS_MOCK_SLOW_MS", "8000")) / 1000.0

# Wire-compression W.1/W.1b fixture payloads (spec
# 2026-10-12-wire-compression section 4): a prompt marker selects
# deterministic BIG responses so worker->master chunks/done bodies
# cross the JANUS_WIRE_ENC_MIN_BYTES (256) threshold and actually
# compress (the corrupt seam skips identity payloads — the test must
# choose a big enough prompt). The filler is fixed text (byte-stable
# across runs — the W.1 enc-on/enc-off byte-identity diff and the
# W.1b2 truncation-prefix assertion pin exact bytes) and highly
# compressible (the ratio-counter sanity needs plain > zlib).
WIRE_ENC_MARKER = "wire-enc-fixture"
WIRE_ENC_EVENTS = 12  # SSE chunk events; >= 6 wire chunks guaranteed
WIRE_ENC_FILLER = ("janus-wire-enc-fixture-" * 32)[:704]

# U.1 upstream-gzip markers (spec 2026-10-12-wire-compression section 4):
# a user message containing "upstream-gz" serves the REAL captured gzip
# wire bytes with Content-Encoding: gzip; "upstream-gz-bad" serves the
# identity body labeled Content-Encoding: br (the D6 violation path);
# "upstream-gz-corrupt" serves corrupted gzip bytes. Fixture source:
# JANUS_MOCK_GZ_FIXTURE = path to <label>.wire_raw_gzip.b64 (+ sibling
# .control_identity.json), captured via the gateway repo's
# tools/capture_upstream_gzip_fixture.py — never invented bytes.
UPSTREAM_GZ_MARKER = "upstream-gz"
UPSTREAM_GZ_BAD_MARKER = "upstream-gz-bad"
UPSTREAM_GZ_CORRUPT_MARKER = "upstream-gz-corrupt"


def _load_gz_fixture():
    import base64
    import os

    path = os.environ.get("JANUS_MOCK_GZ_FIXTURE", "")
    if not path:
        return None
    try:
        with open(path, "rb") as f:
            wire = base64.b64decode(f.read().strip())
        with open(path.replace(".wire_raw_gzip.b64", ".control_identity.json"), "rb") as f:
            control = f.read()
        return {"wire": wire, "control": control}
    except OSError:
        return None


UPSTREAM_GZ_FIXTURE = _load_gz_fixture()


def _wire_enc_fixture(body) -> bool:
    """True when the LAST user message carries the marker (string
    content only — the harness runner sends plain strings)."""
    for m in reversed(body.get("messages") or []):
        if isinstance(m, dict) and m.get("role") == "user":
            c = m.get("content")
            return isinstance(c, str) and WIRE_ENC_MARKER in c
    return False


def _upstream_gz_marker(body):
    """-> None | "gz" | "bad" | "corrupt" from the LAST user message."""
    for m in reversed(body.get("messages") or []):
        if isinstance(m, dict) and m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, str):
                if UPSTREAM_GZ_CORRUPT_MARKER in c:
                    return "corrupt"
                if UPSTREAM_GZ_BAD_MARKER in c:
                    return "bad"
                if UPSTREAM_GZ_MARKER in c:
                    return "gz"
            return None
    return None


def _wire_enc_chunk_payload(i: int) -> dict:
    return {
        "id": "chatcmpl-mock-wire-enc",
        "object": "chat.completion.chunk",
        "model": "mock-model",
        "choices": [
            {"index": 0, "delta": {"content": f"{WIRE_ENC_FILLER}-{i:03d}"}, "finish_reason": None}
        ],
    }


def _wire_enc_stop_payload() -> dict:
    return {
        "id": "chatcmpl-mock-wire-enc",
        "object": "chat.completion.chunk",
        "model": "mock-model",
        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
    }


def _is_slow(key: str) -> bool:
    return key.startswith(SLOW_PREFIX)


DENY_BODY = {"error": {"code": "ProductNotActivated", "message": "product not activated"}}
BALANCE_BODY = {"code": "Arrearage", "message": "balance is insufficient"}
SHAPE_BODY = {"error": {"code": "NoPermission", "message": "no permission to access this model"}}
# Pinned 401 shape (observability-depth O.2): the gateway threads the
# provider-native error.code onto usage rows, so the code must be
# deterministic — the -c/-d body precedent, applied to -a.
AUTH_BODY = {"error": {"code": "InvalidAuthentication"}}

# Per-bearer-key error behavior table (key -> (status, body)). The *2
# entries are class-paired duplicates for the gate's terminal-failure
# scenario: with a+a2 as a provider's only keys, every attempt fails
# with the SAME class regardless of pick order.
KEY_BEHAVIORS = {
    "mock-key-a": (401, AUTH_BODY),
    "mock-key-a2": (401, AUTH_BODY),
    "mock-key-c": (400, DENY_BODY),
    "mock-key-c2": (400, DENY_BODY),
    "mock-key-d": (429, BALANCE_BODY),
    "mock-key-d2": (429, BALANCE_BODY),
    "mock-key-e": (503, {"error": {"message": "upstream busy"}}),
    "mock-key-f": (400, SHAPE_BODY),
}

# Inspect ring: path -> deque of {"headers", "path"} (last 8, oldest
# evicted first). Header names are stored lowercased (HTTP header
# casing is not significant) so gate assertions can match directly.
INSPECT_RING_DEPTH = 8
_inspect_rings = {}

# Alert webhook sink (the gate exports JANUS_ALERT_WEBHOOK_URL pointing
# here). Bounded; oldest events dropped past the cap.
ALERT_SINK_CAP = 1000
_alert_events = deque(maxlen=ALERT_SINK_CAP)


@app.middleware("http")
async def _record_request(request: Request, call_next):
    """Record EVERY request (all endpoints) into its per-path ring."""
    path = request.url.path
    ring = _inspect_rings.setdefault(path, deque(maxlen=INSPECT_RING_DEPTH))
    ring.append({"headers": {k.lower(): v for k, v in request.headers.items()}, "path": path})
    return await call_next(request)


@app.get("/v1/_inspect/last")
async def inspect_last(path: str = ""):
    """Newest-first ring entries for the given path (empty list when
    the path was never seen — a missing ring is not an error)."""
    if not path:
        return JSONResponse({"error": {"message": "path query parameter required"}}, 400)
    ring = _inspect_rings.get(path)
    return {"path": path, "entries": list(ring)[::-1] if ring else []}


@app.post("/alertsink")
async def alertsink_ingest(request: Request):
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": {"message": "invalid JSON body"}}, 400)
    _alert_events.append(body)
    return {"ok": True}


@app.get("/alertsink/events")
async def alertsink_events():
    return list(_alert_events)


@app.post("/alertsink/clear")
async def alertsink_clear():
    _alert_events.clear()
    return {"ok": True}


@app.get("/v1/models")
async def models():
    return {"object": "list", "data": [{"id": "mock-model", "object": "model", "owned_by": "mock"}]}


@app.post("/v1/responses")
async def responses(request: Request):
    """Minimal native OpenAI-Responses endpoint: any key -> a tiny SSE
    stream (the gateway passes native streams through untouched; E.5
    only asserts routing, not payload fidelity). sk-slow-* keys delay
    before the FIRST event (TTFB contract, same as chat)."""
    import json

    auth = request.headers.get("authorization", "")
    slow = _is_slow(auth.removeprefix("Bearer ").strip())

    async def gen():
        nl = chr(10)
        if slow:
            await asyncio.sleep(SLOW_SECONDS)
        for ev, payload in (
            ("response.created", {"type": "response.created"}),
            ("response.output_text.delta", {"type": "response.output_text.delta", "delta": "ok"}),
            ("response.completed", {"type": "response.completed"}),
        ):
            yield "event: " + ev + nl + "data: " + json.dumps(payload) + nl + nl

    return StreamingResponse(gen(), media_type="text/event-stream")


@app.post("/v1/decisions")
async def decisions(request: Request):
    """Canonical Decisions endpoint for the TF-D gate steps: validates
    the guide shape minimally, echoes one answer per question by name
    (predicate/choice/score synthesized deterministically; refusal when
    the question name starts with 'refuse_')."""

    body = await request.json()
    qs = body.get("questions") or []
    if not isinstance(qs, list) or not qs:
        return JSONResponse(
            {"error": {"message": "questions required", "type": "invalid_request_error"}}, 400
        )
    answers = []
    for q in qs:
        name = q.get("name", "?")
        if name.startswith("refuse_"):
            answers.append({"type": "refusal", "name": name})
        elif q.get("type") == "choice":
            ch = (q.get("choices") or [{"value": "other"}])[0]
            answers.append(
                {
                    "type": "choice",
                    "name": name,
                    "choice": ch.get("value", "other"),
                    "probabilities": [
                        {"value": c.get("value"), "probability": 0.5 if c is ch else 0.1}
                        for c in (q.get("choices") or [])
                    ],
                    "confidence": 0.9,
                }
            )
        elif q.get("type") == "score":
            levels = q.get("levels") or [{"label": "low"}, {"label": "high"}]
            answers.append(
                {
                    "type": "score",
                    "name": name,
                    "score": 0.5,
                    "probabilities": [
                        {
                            "value": i,
                            "label": lv.get("label"),
                            "probability": round(1.0 / len(levels), 2),
                        }
                        for i, lv in enumerate(levels)
                    ],
                    "confidence": 0.8,
                }
            )
        else:
            answers.append({"type": "predicate", "name": name, "probability": 0.9})
    return {"answers": answers}


@app.post("/v1/videos")
async def videos(request: Request):
    """Canonical video endpoint, sync-SSE mode (the M.8+ gate steps
    ride the real gateway against this): response.created -> progress ->
    completed with a small url."""
    import json as _json

    from fastapi.responses import StreamingResponse

    async def gen():
        nl = chr(10)
        for ev, payload in (
            ("response.created", {"type": "response.created"}),
            ("progress", {"type": "progress", "stage": "processing"}),
            (
                "response.completed",
                {
                    "type": "response.completed",
                    "response": {
                        "id": "resp-mock-video",
                        "status": "completed",
                        "usage": {"input_tokens": 5, "output_tokens": 1},
                        "output": [{"type": "video", "url": "https://mock.invalid/v.mp4"}],
                    },
                },
            ),
        ):
            yield "event: " + ev + nl + "data: " + _json.dumps(payload) + nl + nl

    return StreamingResponse(gen(), media_type="text/event-stream")


@app.post("/v1/images/generations")
async def images(request: Request):
    """Canonical OpenAI images reply (deterministic, free) — the M.7
    gate step drives a passthrough provider through the REAL gateway
    against this."""

    body = await request.json()
    n = int(body.get("n", 1) or 1)
    return {
        "created": 1791300000,
        "data": [
            {"url": f"https://mock.invalid/img-{i}.png", "revised_prompt": "mock"} for i in range(n)
        ],
    }


@app.post("/v1/chat/completions")
async def chat(request: Request):
    import json as _json

    auth = request.headers.get("authorization", "")
    key = auth.removeprefix("Bearer ").strip()
    slow = _is_slow(key)
    body = {}
    try:
        body = await request.json()
    except Exception:
        body = {}
    # Error-key contract FIRST: real upstreams return the 4xx/5xx
    # HTTP status even for stream requests — a stream branch ahead of
    # these checks would hand back a 200 SSE for mock-key-e (ocr).
    hit = KEY_BEHAVIORS.get(key)
    if hit is not None:
        status, err_body = hit
        return JSONResponse(err_body, status)
    gz = _upstream_gz_marker(body)
    if gz is not None and UPSTREAM_GZ_FIXTURE is not None:
        # U.1 (spec 2026-10-12-wire-compression section 4): REAL
        # captured gzip wire bytes, served unary with the honest
        # Content-Encoding — the gateway must decode-then-parse. "bad"
        # mislabels the identity control as br (D6 violation); "corrupt"
        # flips a mid-body byte inside the gzip wire.
        from fastapi.responses import Response as _Resp

        wire = bytearray(UPSTREAM_GZ_FIXTURE["wire"])
        if gz == "corrupt":
            wire[len(wire) // 2] ^= 0xFF
        if gz == "bad":
            return _Resp(
                UPSTREAM_GZ_FIXTURE["control"],
                status_code=200,
                headers={"content-encoding": "br"},
            )
        return _Resp(bytes(wire), status_code=200, headers={"content-encoding": "gzip"})
    if _wire_enc_fixture(body):
        # W.1/W.1b fixture: deterministic BIG payloads (see module
        # head). Stream shape mirrors the default branch (slow keys
        # keep the delay-before-first-event TTFB contract); unary is a
        # multi-KB compressible body.
        if body.get("stream"):

            async def gen():
                nl = chr(10)
                if slow:
                    await asyncio.sleep(SLOW_SECONDS)
                yield (
                    "event: message_start"
                    + nl
                    + "data: "
                    + _json.dumps({"role": "assistant"})
                    + nl
                    + nl
                )
                for i in range(WIRE_ENC_EVENTS):
                    yield (
                        "event: chat.completion.chunk"
                        + nl
                        + "data: "
                        + _json.dumps(_wire_enc_chunk_payload(i))
                        + nl
                        + nl
                    )
                yield (
                    "event: chat.completion.chunk"
                    + nl
                    + "data: "
                    + _json.dumps(_wire_enc_stop_payload())
                    + nl
                    + nl
                )
                yield "data: [DONE]" + nl + nl

            return StreamingResponse(gen(), media_type="text/event-stream")
        if slow:
            await asyncio.sleep(SLOW_SECONDS)
        return {
            "id": "chatcmpl-mock-wire-enc",
            "object": "chat.completion",
            "model": "mock-model",
            "choices": [
                {
                    "index": 0,
                    "finish_reason": "stop",
                    "message": {"role": "assistant", "content": WIRE_ENC_FILLER * 4},
                }
            ],
            "usage": {"prompt_tokens": 3, "completion_tokens": 1},
        }
    if body.get("stream"):
        # OpenAI-shaped SSE. The SLOW contract holds for streams too:
        # the delay lands BEFORE the first event, then the stream
        # flows normally (TTFB semantics).
        async def gen():
            nl = chr(10)
            if slow:
                await asyncio.sleep(SLOW_SECONDS)
            for ev, payload in (
                ("message_start", {"role": "assistant"}),
                (
                    "chat.completion.chunk",
                    {
                        "id": "chatcmpl-mock",
                        "object": "chat.completion.chunk",
                        "model": "mock-model",
                        "choices": [
                            {
                                "index": 0,
                                "delta": {"role": "assistant", "content": "ok"},
                                "finish_reason": None,
                            }
                        ],
                    },
                ),
                (
                    "chat.completion.chunk",
                    {
                        "id": "chatcmpl-mock",
                        "object": "chat.completion.chunk",
                        "model": "mock-model",
                        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                    },
                ),
            ):
                yield "event: " + ev + nl + "data: " + _json.dumps(payload) + nl + nl
            yield "data: [DONE]" + nl + nl

        return StreamingResponse(gen(), media_type="text/event-stream")
    if slow:
        # Unary slow: the whole delay precedes the response body.
        await asyncio.sleep(SLOW_SECONDS)
    return {
        "id": "chatcmpl-mock",
        "object": "chat.completion",
        "model": "mock-model",
        "choices": [
            {"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": "ok"}}
        ],
        "usage": {"prompt_tokens": 3, "completion_tokens": 1},
    }


if __name__ == "__main__":
    import uvicorn

    # Linux CI runners: gateway CONTAINERS reach the mock via the
    # docker bridge (host-gateway) — loopback-only binding refuses them
    # (Docker Desktop on Windows/mac proxies loopback; Linux does not).
    host = os.environ.get("JANUS_MOCK_HOST", "127.0.0.1")
    uvicorn.run(
        app, host=host, port=int(os.environ.get("JANUS_MOCK_PORT", "8099")), log_level="warning"
    )
