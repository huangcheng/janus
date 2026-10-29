#!/usr/bin/env python3
"""Scriptable fake OpenAI-compatible SSE upstream for Janus live tests.

Speaks just enough of /v1/chat/completions to drive Janus's streaming
path, with the timing knob this verification needs: it can emit a few
events, then go SILENT for an arbitrary interval without closing the
connection. That is the exact condition the SSE keepalive exists to
survive and the inactivity ceiling exists to bound.

  --prelude-events N   content events before the silence (default 2)
  --silent-ms MS       how long to stall AFTER the prelude (default 4000)
  --tokens-per-event N pace of the prelude (default 2)

Prints a JSON summary line to stdout as it runs so the driver can
correlate timings.
"""
import argparse
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=18080)
    p.add_argument("--prelude-events", type=int, default=2)
    p.add_argument("--silent-ms", type=int, default=4000)
    p.add_argument("--never-resume", action="store_true")
    p.add_argument("--tokens-per-event", type=int, default=2)
    return p.parse_args()


ARGS = parse_args()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_a):
        pass

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        if length:
            self.rfile.read(length)
        started = time.time()
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "keep-alive")
        self.end_headers()

        def send(obj):
            payload = obj if isinstance(obj, str) else json.dumps(obj)
            self.wfile.write(f"data: {payload}\n\n".encode())
            self.wfile.flush()

        def chunk(delta, finish=None):
            return {
                "id": "chatcmpl-fake",
                "object": "chat.completion.chunk",
                "created": int(time.time()),
                "model": "fake-model",
                "choices": [
                    {"index": 0, "delta": delta, "finish_reason": finish}
                ],
            }

        send(chunk({"role": "assistant", "content": ""}))
        for i in range(ARGS.prelude_events):
            send(chunk({"content": "tok%d " % i * ARGS.tokens_per_event}))
            time.sleep(0.05)

        # The stall: connection stays OPEN, no bytes at all.
        silent_started = time.time()
        time.sleep(ARGS.silent_ms / 1000.0)
        if ARGS.never_resume:
            # Hold the connection open forever: the point is that the
            # GATEWAY must terminate, not the upstream.
            while True:
                time.sleep(1)

        send(chunk({"content": "resumed "}))
        send(chunk({}, finish="stop"))
        send({
            "id": "chatcmpl-fake",
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": "fake-model",
            "choices": [],
            "usage": {
                "prompt_tokens": 10,
                "completion_tokens": 10,
                "total_tokens": 20,
            },
        })
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

        sys.stdout.write(
            json.dumps(
                {
                    "event": "done",
                    "prelude_events": ARGS.prelude_events,
                    "silent_ms": ARGS.silent_ms,
                    "total_s": round(time.time() - started, 3),
                    "silence_started_s": round(silent_started - started, 3),
                }
            )
            + "\n"
        )
        sys.stdout.flush()


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    sys.stdout.write(
        json.dumps({"event": "listening", "port": ARGS.port, "silent_ms": ARGS.silent_ms})
        + "\n"
    )
    sys.stdout.flush()
    srv.serve_forever()
