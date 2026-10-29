#!/usr/bin/env python
"""H6-D1 gateway performance baseline (spec: Janus repo
docs/superpowers/specs/2026-10-15-maturity-hardening.md, section H6).

Drives modest load against the LOCAL e2e stack's data plane and records
latency baselines for the four hot surfaces:

  healthz            GET  /healthz                (framework floor)
  models_list        GET  /v1/models              (agent auth + catalog)
  chat_unary         POST /v1/chat/completions    (full proxy hop, tiny reply)
  chat_stream_ttfb   POST ... stream=true         (time to FIRST body byte)
  chat_stream_total  POST ... stream=true         (first byte to EOF)

All chat traffic routes to the deterministic loopback mock upstream
(scripts/mock_upstream.py; bearer mock-key-b = always-instant 200) —
ZERO billable traffic, ZERO production access (H6-D1).

PREREQUISITE — a running local stack (docker janus-pg/janus-gw/janus-judge
+ dashboard on :8091 + scripts/mock_upstream.py on :8099):

    docker start janus-pg janus-gw janus-judge; run uvicorn app.main:app --port 8091;
    python scripts/mock_upstream.py   # keep in foreground

Gateway :8080, dashboard :8091, mock :8099 (JANUS_MOCK_PORT honored for
the mock, mirroring the e2e harness). The tool is self-seeding and
idempotent: it logs into the dashboard, mints an EPHEMERAL agent key
(deleted again on exit), ensures a dedicated `mock-bench` provider whose
ONLY key is mock-key-b (healthy — no failover variance from the gate's
mock-failover key set) plus a `mock-bench-model` binding, and waits for
the 2s catalog poll before measuring. Provider/model are left in place
for the next run; only the agent key is always cleaned up.

Output: one JSON artifact — printed to stdout AND written to --out:

    {ts, hw_class, platform, machine, cpu, python,
     stack: {gw, dash, mock_port, gw_version}, params: {...},
     targets: {<name>: {median_ms, p95_ms, reqs, ok, errors,
                        mean_ms, min_ms, max_ms, rps}}}

Each request opens a FRESH connection (no keep-alive): the baseline is
comparative (same tool on both sides of a diff), and connect cost is
part of the front-door surface being baselined.

This tool NEVER gates (H6-D2): it records numbers, it does not judge
them. Compare two artifacts with tools/bench_diff.py.
"""

import argparse
import asyncio
import http.client
import json
import math
import os
import platform
import statistics
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from datetime import UTC, datetime

DEFAULT_GW = "http://127.0.0.1:8080"
DEFAULT_DASH = "http://127.0.0.1:8091"
DEFAULT_MOCK_PORT = 8099

BENCH_PROVIDER = "mock-bench"
BENCH_MODEL = "mock-bench-model"
BENCH_KEY_SECRET = "mock-key-b"  # mock upstream contract: always 200, instant

# v2.2 Part C break-glass pair for loopback mock providers — the exact
# flags historical harness runs sent; kept for compatibility.
MOCK_ALLOW_INTERNAL = {
    "allow_internal": True,
    "allow_internal_confirmed": True,
}
MOCK_GATE_Q = "?role=e2e-local-mock&reason=local+mock+upstream+is+loopback"

CHAT_BODY = {
    "model": BENCH_MODEL,
    "messages": [{"role": "user", "content": "Reply with exactly: ok"}],
    "max_tokens": 16,
}


def log(msg):
    """Progress goes to stderr — stdout stays pure JSON."""
    print(msg, file=sys.stderr, flush=True)


def die(msg):
    log(f"ERROR: {msg}")
    sys.exit(2)


def load_env(path):
    """Read the dashboard .env next to this repo (same parser as the
    harness's load_local_env)."""
    env = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k] = v
    return env


# --------------------------------------------------------------------------
# Control plane (dashboard API + stack checks) — sequential, low volume.
# A no-proxy opener: system HTTP proxies must never sit between the
# bench and 127.0.0.1 (same class of gotcha the e2e harness documents).
# --------------------------------------------------------------------------

_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def api(url, method="GET", body=None, token=None, timeout=30):
    """Dashboard/control-plane call -> (status, decoded-json-or-raw)."""
    headers = {}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["content-type"] = "application/json"
    if token:
        headers["authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, method=method, data=data, headers=headers)
    try:
        with _OPENER.open(req, timeout=timeout) as resp:
            payload = resp.read()
            try:
                return resp.status, (json.loads(payload) if payload else {})
            except ValueError:
                return resp.status, payload
    except urllib.error.HTTPError as e:
        payload = e.read()
        try:
            return e.code, json.loads(payload)
        except Exception:
            return e.code, payload


def probe(url, timeout=3):
    try:
        with _OPENER.open(urllib.request.Request(url), timeout=timeout) as r:
            return r.status
    except Exception:
        return None


def ensure_stack(dash, gw, mock_port):
    """Preflight + seed. Returns (jwt, agent_key, key_id)."""
    if probe(f"{gw}/healthz") != 200:
        die(
            f"gateway {gw}/healthz not answering — boot the local stack first: "
            "docker janus-pg/janus-gw/janus-judge containers up"
        )
    if probe(f"http://127.0.0.1:{mock_port}/v1/models") != 200:
        die(
            f"mock upstream 127.0.0.1:{mock_port} not answering — scripts/mock_upstream.py "
            f"boots it in step 5b (JANUS_MOCK_PORT honored)"
        )

    env = load_env(os.path.join(os.path.dirname(__file__), "..", ".env"))
    password = env.get("JANUS_DASHBOARD_PASSWORD")
    if not password:
        die("JANUS_DASHBOARD_PASSWORD missing from ../.env (dashboard login)")

    s, b = api(f"{dash}/api/auth/login", "POST", {"password": password})
    jwt = b.get("token", "") if isinstance(b, dict) else ""
    if s != 200 or len(jwt) < 20:
        die(f"dashboard login failed (status={s})")
    log("dashboard login ok")

    # ephemeral agent key — never a shared key (harness step 0.3 pattern)
    s, b = api(f"{dash}/api/keys", "POST", {}, token=jwt)
    ak = b.get("key", "") if isinstance(b, dict) else ""
    key_id = b.get("id") if isinstance(b, dict) else None
    if s != 201 or not ak.startswith("sk-"):
        die(f"agent key mint failed (status={s} body={b})")
    log(f"ephemeral agent key minted (id={key_id})")

    try:
        seed_bench_model(dash, jwt, mock_port)
        wait_catalog(gw, ak)
    except Exception:
        cleanup_key(dash, jwt, key_id)
        raise
    return jwt, ak, key_id


def seed_bench_model(dash, jwt, mock_port):
    """Idempotent upsert of the dedicated bench provider + bound model.

    Provider carries mock-key-b ONLY: the gate's `mock-failover` provider
    mixes 401/429 keys (RR failover noise); the baseline must measure a
    deterministic healthy path. base_url uses host.docker.internal (the
    gateway container's view of the host loopback mock) — same as the
    harness's mock_provider_setup.
    """
    _, ps = api(f"{dash}/api/providers", token=jwt)
    prov = next((p for p in ps.get("providers", []) if p["name"] == BENCH_PROVIDER), None)
    if prov is None:
        s, b = api(
            f"{dash}/api/providers{MOCK_GATE_Q}",
            "POST",
            {
                "name": BENCH_PROVIDER,
                "base_url": f"http://host.docker.internal:{mock_port}/v1",
                "protocol": "openai_chat",
                **MOCK_ALLOW_INTERNAL,
            },
            token=jwt,
        )
        pid = b.get("id") if isinstance(b, dict) else None
        if not pid:
            die(f"bench provider create failed (status={s} body={b})")
        log(f"provider {BENCH_PROVIDER} created (id={pid})")
    else:
        pid = prov["id"]
        if not prov.get("enabled", True):
            api(f"{dash}/api/providers/{pid}/enable", "POST", {}, token=jwt)
        log(f"provider {BENCH_PROVIDER} reused (id={pid})")

    # one key row (mock-key-b) — the list response embeds key rows; the
    # secret itself is never readable after encryption, so ">=1 enabled
    # key" means a previous bench run already seeded it.
    keys = [k for k in prov.get("keys", []) if k.get("enabled")] if prov else []
    if prov is None or not keys:
        s, b = api(
            f"{dash}/api/providers/{pid}/keys",
            "POST",
            {"secret": BENCH_KEY_SECRET, "weight": 1},
            token=jwt,
        )
        if s != 201:
            die(f"bench provider key add failed (status={s} body={b})")
        log(f"provider key {BENCH_KEY_SECRET} added")

    # public model bound to the bench provider (no listing sync needed —
    # the harness registers routes directly for exactly this reason)
    api(f"{dash}/api/models", "POST", {"name": BENCH_MODEL}, token=jwt)
    _, ms = api(f"{dash}/api/models", token=jwt)
    mid = next((m["id"] for m in ms.get("models", []) if m["name"] == BENCH_MODEL), None)
    if not mid:
        die(f"bench model {BENCH_MODEL} not found after upsert")
    routes = next(
        (m.get("routes", []) for m in ms.get("models", []) if m["name"] == BENCH_MODEL), []
    )
    if not any(r.get("provider_id") == pid for r in routes):
        s, b = api(f"{dash}/api/models/{mid}/routes", "POST", {"provider_id": pid}, token=jwt)
        if s not in (200, 201):
            die(f"bench model route add failed (status={s} body={b})")
        log(f"model {BENCH_MODEL} (id={mid}) routed to {BENCH_PROVIDER}")


def wait_catalog(gw, ak, budget_s=30):
    """The gateway picks new keys/models up on its 2s catalog poll —
    wait until BOTH are live instead of racing it (harness step 0.3b)."""
    deadline = time.monotonic() + budget_s
    while time.monotonic() < deadline:
        s, b = api(f"{gw}/v1/models", token=ak)
        if s == 200 and isinstance(b, dict):
            ids = [m.get("id") for m in b.get("data", [])]
            if BENCH_MODEL in ids:
                log("catalog poll: agent key + bench model live")
                return
        time.sleep(1)
    die(f"{BENCH_MODEL} did not appear in /v1/models within {budget_s}s (catalog poll stuck?)")


def cleanup_key(dash, jwt, key_id):
    if key_id is None:
        return
    try:
        api(f"{dash}/api/keys/{key_id}", "DELETE", token=jwt)
        log(f"ephemeral agent key deleted (id={key_id})")
    except Exception as e:  # best effort — a stale key is harmless locally
        log(f"WARN: key cleanup failed: {e}")


# --------------------------------------------------------------------------
# Data plane — one http.client request per call over a fresh connection.
# --------------------------------------------------------------------------


def http_call(host, port, method, path, body=None, token=None, timeout=30):
    """-> (status, total_s, ttfb_s|None, error|None).

    ttfb_s is the time to the FIRST BODY byte (headers alone are not a
    stream TTFB — the mock's sk-slow contract exists precisely because
    first-byte is the health signal). None when the call errored before
    any body byte.
    """
    t0 = time.perf_counter()
    ttfb = None
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        headers = {"accept": "application/json, text/event-stream"}
        payload = None
        if body is not None:
            payload = json.dumps(body).encode()
            headers["content-type"] = "application/json"
        if token:
            headers["authorization"] = f"Bearer {token}"
        conn.request(method, path, body=payload, headers=headers)
        resp = conn.getresponse()
        first = resp.read(1)
        if first:
            ttfb = time.perf_counter() - t0
        resp.read()  # drain to EOF (the [DONE] of the SSE stream)
        total = time.perf_counter() - t0
        err = None if resp.status == 200 else f"http_{resp.status}"
        return resp.status, total, ttfb, err
    except Exception as e:  # recorded, never crashes the run
        return None, time.perf_counter() - t0, ttfb, f"{type(e).__name__}: {e}"
    finally:
        conn.close()


def make_targets(host, port, ak):
    """name -> callable returning (status, total_s, ttfb_s|None, err)."""
    stream_body = dict(CHAT_BODY, stream=True)

    def healthz():
        return http_call(host, port, "GET", "/healthz")

    def models_list():
        return http_call(host, port, "GET", "/v1/models", token=ak)

    def chat_unary():
        return http_call(host, port, "POST", "/v1/chat/completions", body=CHAT_BODY, token=ak)

    def chat_stream():
        return http_call(host, port, "POST", "/v1/chat/completions", body=stream_body, token=ak)

    return [
        ("healthz", healthz, False),
        ("models_list", models_list, False),
        ("chat_unary", chat_unary, False),
        ("chat_stream", chat_stream, True),
    ]


# --------------------------------------------------------------------------
# Load driver
# --------------------------------------------------------------------------


async def drive(fn, workers, n):
    """Run n calls spread over `workers` concurrent workers; returns the
    list of raw results. Concurrency is capped on purpose — the box also
    runs docker (H6 context: modest load, medians not max throughput)."""
    results = []
    per = max(1, n // workers)
    plan = [per] * workers
    plan[-1] += n - per * workers  # remainder onto the last worker

    async def worker(count):
        for _ in range(count):
            results.append(await asyncio.to_thread(fn))

    await asyncio.gather(*(worker(c) for c in plan if c > 0))
    return results


def percentile(sorted_vals, p):
    """Nearest-rank percentile on an ascending-sorted list."""
    if not sorted_vals:
        return None
    idx = max(0, math.ceil(p * len(sorted_vals)) - 1)
    return sorted_vals[idx]


def series_stats(seconds, wall_s):
    vals = sorted(seconds)
    if not vals:
        return {
            "median_ms": None,
            "p95_ms": None,
            "mean_ms": None,
            "min_ms": None,
            "max_ms": None,
            "ok": 0,
            "rps": 0.0,
        }
    return {
        "median_ms": round(statistics.median(vals) * 1000, 3),
        "p95_ms": round(percentile(vals, 0.95) * 1000, 3),
        "mean_ms": round(statistics.fmean(vals) * 1000, 3),
        "min_ms": round(vals[0] * 1000, 3),
        "max_ms": round(vals[-1] * 1000, 3),
        "ok": len(vals),
        "rps": round(len(vals) / wall_s, 3) if wall_s > 0 else None,
    }


async def bench_target(name, fn, stream, workers, reqs, warmup):
    log(f"[{name}] warmup {warmup} ...")
    await drive(fn, workers, warmup)
    log(f"[{name}] measuring {reqs} reqs over {workers} workers ...")
    t0 = time.perf_counter()
    raw = await drive(fn, workers, reqs)
    wall = time.perf_counter() - t0

    ok_total = [r[1] for r in raw if r[3] is None]
    errors = [r[3] for r in raw if r[3] is not None]
    out = {"reqs": reqs, "errors": len(errors)}
    if errors:
        out["error_kinds"] = dict(Counter(errors))
    out.update(series_stats(ok_total, wall))

    if stream:
        ok_ttfb = [r[2] for r in raw if r[3] is None and r[2] is not None]
        ttfb_stats = series_stats(ok_ttfb, wall)
        ttfb_stats["reqs"] = reqs
        ttfb_stats["errors"] = len(errors)
        if errors:
            ttfb_stats["error_kinds"] = out["error_kinds"]
        return {f"{name}_ttfb": ttfb_stats, f"{name}_total": out}
    return {name: out}


async def run_bench(args, ak):
    host = args.gw.split("//", 1)[-1].rstrip("/")
    if ":" in host:
        host, port_s = host.split(":", 1)
        port = int(port_s)
    else:
        port = 80
    targets = make_targets(host, port, ak)
    results = {}
    for name, fn, stream in targets:
        results.update(await bench_target(name, fn, stream, args.workers, args.reqs, args.warmup))
    return results


def hw_context(hw_class):
    return {
        "ts": datetime.now(UTC).isoformat(timespec="seconds"),
        "hw_class": hw_class,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "cpu": {
            "count": os.cpu_count(),
            "processor": platform.processor() or None,
        },
        "python": platform.python_version(),
    }


def main():
    ap = argparse.ArgumentParser(
        description="H6-D1 local gateway perf baseline (never gates; see tools/baselines/README.md)"
    )
    ap.add_argument("--gw", default=os.environ.get("JANUS_BENCH_GW", DEFAULT_GW))
    ap.add_argument("--dash", default=os.environ.get("JANUS_BENCH_DASH", DEFAULT_DASH))
    ap.add_argument(
        "--mock-port", type=int, default=int(os.environ.get("JANUS_MOCK_PORT", DEFAULT_MOCK_PORT))
    )
    ap.add_argument(
        "--workers", type=int, default=8, help="concurrent workers (default 8 — modest on purpose)"
    )
    ap.add_argument(
        "--reqs", type=int, default=200, help="measured requests per target (default 200)"
    )
    ap.add_argument(
        "--warmup", type=int, default=20, help="warmup requests per target (default 20)"
    )
    ap.add_argument(
        "--class",
        dest="hw_class",
        default="dev",
        help="hardware class label for the artifact (e.g. win-dev, runner)",
    )
    ap.add_argument("--out", help="also write the JSON artifact here")
    args = ap.parse_args()

    jwt, ak, key_id = ensure_stack(args.dash, args.gw, args.mock_port)
    try:
        targets = asyncio.run(run_bench(args, ak))
    finally:
        cleanup_key(args.dash, jwt, key_id)

    artifact = hw_context(args.hw_class)
    artifact["stack"] = {
        "gw": args.gw,
        "dash": args.dash,
        "mock_port": args.mock_port,
        "mock_key": BENCH_KEY_SECRET,
        "provider": BENCH_PROVIDER,
        "model": BENCH_MODEL,
        "fresh_connection_per_request": True,
    }
    artifact["params"] = {
        "workers": args.workers,
        "reqs": args.reqs,
        "warmup": args.warmup,
    }
    artifact["targets"] = targets

    text = json.dumps(artifact, indent=1)
    print(text)
    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
        log(f"artifact written to {args.out}")


if __name__ == "__main__":
    main()
