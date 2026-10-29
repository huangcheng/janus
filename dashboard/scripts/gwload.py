"""Gateway concurrency load tester (stdlib only, real public entry).

Companion to janus_bench.py: where the bench checks correctness and
latency from many vantages sequentially, this one drives CONCURRENT
keep-alive clients (the ab/hey model) to find the gateway plane's
throughput ceiling and the full-path behavior under parallel streams.

Env (same conventions as janus_bench.py):
  JANUS_BENCH_URL   base URL, default http://127.0.0.1:8080
  JANUS_BENCH_KEY   agent API key (required — refuses to start without)

Usage:
  python3 gwload.py <models|chat> <total_requests> <concurrency>

  models  GET  /v1/models          — gateway plane only (no upstream
                                     cost): accept/auth/catalog RPS.
  chat    POST /v1/chat/completions — full path (master -> worker ->
                                     upstream), small generation; set
                                     the model via GWLOAD_MODEL.

Run it from a SERVER vantage: a home box behind a TUN proxy (or one
that just hammered the cloud edge into CC cleansing) serializes
connections and measures the client, not the gateway.
"""

import http.client
import json
import os
import ssl
import sys
import threading
import time
import urllib.parse
from collections import Counter

URL = os.environ.get("JANUS_BENCH_URL", "http://127.0.0.1:8080").rstrip("/")
KEY = os.environ.get("JANUS_BENCH_KEY", "")
if not KEY:
    print("JANUS_BENCH_KEY not set — refusing to start")
    sys.exit(1)
MODEL = os.environ.get("GWLOAD_MODEL", "MiniMax-M3.1-Flash")

CTX = ssl.create_default_context()
HOST = urllib.parse.urlparse(URL).hostname
PORT = urllib.parse.urlparse(URL).port or 443

BODY = json.dumps(
    {
        "model": MODEL,
        "messages": [{"role": "user", "content": "hi"}],
        "max_tokens": 8,
    }
).encode()


def worker(mode, n_each, latencies, statuses, errors, lock):
    conn = http.client.HTTPSConnection(HOST, PORT, timeout=90, context=CTX)
    for _ in range(n_each):
        t0 = time.monotonic()
        try:
            if mode == "models":
                conn.request("GET", "/v1/models", headers={"Authorization": "Bearer " + KEY})
            else:
                conn.request(
                    "POST",
                    "/v1/chat/completions",
                    body=BODY,
                    headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"},
                )
            resp = conn.getresponse()
            resp.read()
            with lock:
                statuses[resp.status] += 1
                latencies.append((time.monotonic() - t0) * 1000)
        except (TimeoutError, OSError, http.client.HTTPException) as e:
            with lock:
                errors[type(e).__name__] += 1
                latencies.append((time.monotonic() - t0) * 1000)
    conn.close()


def pct(v, q):
    v = sorted(v)
    return round(v[min(len(v) - 1, int(len(v) * q))], 1)


def main():
    mode, total, conc = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    latencies, statuses, errors = [], Counter(), Counter()
    lock = threading.Lock()
    n_each, rem = divmod(total, conc)
    threads = []
    t0 = time.monotonic()
    for i in range(conc):
        k = n_each + (1 if i < rem else 0)
        if k:
            t = threading.Thread(target=worker, args=(mode, k, latencies, statuses, errors, lock))
            t.start()
            threads.append(t)
    for t in threads:
        t.join()
    dur = time.monotonic() - t0
    ok = statuses.get(200, 0)
    print(
        f"mode={mode} n={total} c={conc}  duration={dur:.1f}s  "
        f"RPS={total / dur:.1f}  ok={ok}/{total}"
    )
    print(f"  status: {dict(statuses)}  errors: {dict(errors)}")
    if latencies:
        print(
            f"  latency ms: p50={pct(latencies, 0.5)} p90={pct(latencies, 0.9)} "
            f"p95={pct(latencies, 0.95)} p99={pct(latencies, 0.99)} "
            f"max={max(latencies):.0f}"
        )


if __name__ == "__main__":
    main()
