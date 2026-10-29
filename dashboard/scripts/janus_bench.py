#!/usr/bin/env python3
"""janus-bench — a standalone, black-box benchmark probe for a Janus gateway.

Completely independent of the gateway/dashboard system: no shared database,
no schema, no app imports, stdlib only. Drives the PUBLIC endpoint over
HTTPS like any third-party client, keeps its own JSONL history + rolling
report file, and logs anomalies with a greppable BENCH-ANOMALY prefix
(pair with `journalctl -t janus-bench -g BENCH-ANOMALY` or any log alerting).

Env knobs (all optional except the key):
  JANUS_BENCH_URL            base URL            (default http://127.0.0.1:8080)
  JANUS_BENCH_KEY            agent bearer key    (REQUIRED)
  JANUS_BENCH_MODELS         comma-separated     (default: the idle-plan models)
  JANUS_BENCH_INTERVAL_SEC   seconds per round   (default 600)
  JANUS_BENCH_TIMEOUT_SEC    per-request timeout (default 120)
  JANUS_BENCH_DAILY_TOKENS   UTC-day in+out cap  (default 2_000_000; 0 = uncapped)
  JANUS_BENCH_DATA_DIR       state directory     (default /var/lib/janus-bench,
                                                   falls back to ./bench-data)
"""

import http.client
import json
import os
import signal
import socket
import ssl
import statistics
import sys
import time
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

URL = os.environ.get("JANUS_BENCH_URL", "http://127.0.0.1:8080").rstrip("/")
KEY = os.environ.get("JANUS_BENCH_KEY", "")
MODELS = [m.strip() for m in os.environ.get(
    "JANUS_BENCH_MODELS",
    "MiniMax-M3.1-Flash,step-5-preview,mimo-v2.6-pro,mimo-v2.6-flash").split(",") if m.strip()]
INTERVAL = int(os.environ.get("JANUS_BENCH_INTERVAL_SEC", "600"))
TIMEOUT = int(os.environ.get("JANUS_BENCH_TIMEOUT_SEC", "120"))
DAILY_CAP = int(os.environ.get("JANUS_BENCH_DAILY_TOKENS", "2000000"))
# Vantage tag: which node this probe runs from (multi-node fleets).
TAG = os.environ.get("JANUS_BENCH_TAG") or os.uname().nodename

_DATA = Path(os.environ.get("JANUS_BENCH_DATA_DIR", "/var/lib/janus-bench"))
try:
    _DATA.mkdir(parents=True, exist_ok=True)
except OSError:
    _DATA = Path("./bench-data")
    _DATA.mkdir(parents=True, exist_ok=True)

_stop = False


MARATHON = "--marathon" in sys.argv
SOAK_HOURS = 0
for _a in sys.argv:
    if _a.startswith("--soak"):
        _v = _a.split("=", 1)[1] if "=" in _a else "4"
        SOAK_HOURS = max(1, int(_v) if _v.isdigit() else 4)



def _log(kind, msg):
    print(f"[{datetime.now(timezone.utc).isoformat(timespec='seconds')}] {kind} {msg}",
          flush=True)


def anomaly(msg):
    # Single greppable prefix: journald -t janus-bench -g BENCH-ANOMALY
    _log("BENCH-ANOMALY", msg)


# --- scenarios ------------------------------------------------------------
# Every round runs every (model x scenario): all subscribed models stay
# continuously exercised across the riskiest client shapes. responses-face
# streaming guards the cross-protocol translate path; the long and zh
# scenarios mirror real translation/long-context traffic.

_LONG_TEXT = ("The quick brown fox jumps over the lazy dog while the sun sets "
              "behind the distant mountains, and farmers return home after a "
              "long day of work in the golden fields. ") * 160

_ZH_TEXT = ("Translate the following paragraphs into Chinese, keeping the "
            "tone natural:\n\n" +
            "Edge computing brings computation and data storage closer to the "
            "location where it is needed, improving response times and saving "
            "bandwidth.\n\n"
            "Observability is the ability to understand a system's internal "
            "state from its external outputs: logs, metrics and traces "
            "together tell the story.\n\n"
            "A gateway that fails closed protects its clients; a gateway that "
            "fails open protects its uptime. Knowing which one you built is "
            "the hard part.")


def _scenarios():
    return [
        ("chat_short", "chat", False,
         "In one short sentence, describe the sky.", 512),
        ("chat_stream", "chat", True,
         "In one short sentence, describe the sea.", 512),
        ("chat_long_stream", "chat", True,
         "Summarize the following text in two sentences:\n\n" + _LONG_TEXT, 96),
        ("zh_translate_stream", "chat", True, _ZH_TEXT, 1024),
        ("responses_stream", "responses", True,
         "In one short sentence, describe the wind.", 512),
        ("anthropic_short", "anthropic", False,
         "In one short sentence, describe the rain.", 512),
        ("anthropic_stream", "anthropic", True,
         "In one short sentence, describe the snow.", 512),
        ("anthropic_zh_stream", "anthropic", True, _ZH_TEXT, 1024),
    ]


# --- HTTP + SSE -----------------------------------------------------------

def _request(face, stream, body):
    """One request through the public endpoint. Returns the metric row."""
    u = urllib.parse.urlparse(URL)
    path = {"responses": "/v1/responses",
            "anthropic": "/v1/messages"}.get(face, "/v1/chat/completions")
    payload = dict(body)
    payload["stream"] = stream
    if stream and face in ("chat", "anthropic"):
        # Standard client behavior — and the honest test: if a client ASKS
        # for usage and the stream returns none, that is a real finding.
        payload["stream_options"] = {"include_usage": True}
    if face == "responses":
        payload["input"] = payload.pop("messages")[0]["content"]
        payload["max_output_tokens"] = payload.pop("max_tokens", 64)
    data = json.dumps(payload).encode()
    headers = {
        "Authorization": "Bearer " + KEY,
        "Content-Type": "application/json",
        "Accept": "text/event-stream" if stream else "application/json",
    }
    row = {"ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
           "vantage": TAG, "face": face, "stream": stream}
    t0 = time.monotonic()
    conn = None
    try:
        ctx = ssl.create_default_context()
        conn = (http.client.HTTPSConnection(u.hostname, u.port or 443, timeout=TIMEOUT, context=ctx)
                if u.scheme != "http"
                else http.client.HTTPConnection(u.hostname, u.port or 80, timeout=TIMEOUT))
        conn.request("POST", path, body=data, headers=headers)
        resp = conn.getresponse()
        row["status"] = resp.status
        row["rid"] = resp.getheader("x-request-id")
        if stream:
            # Incremental read: ttfb = first transport chunk; per-chunk
            # arrival times give the stall signal (max inter-chunk gap).
            arrivals = []
            buf = bytearray()
            while True:
                blob = resp.read(4096)
                if not blob:
                    break
                arrivals.append(time.monotonic())
                buf.extend(blob)
            if arrivals:
                row["ttfb_ms"] = round((arrivals[0] - t0) * 1000)
                gaps = [round((arrivals[i] - arrivals[i - 1]) * 1000)
                        for i in range(1, len(arrivals))]
                if gaps:
                    row["gap_max_ms"] = max(gaps)
                    row["gap_p95_ms"] = _percentile(gaps, 0.95)
            row["total_ms"] = round((time.monotonic() - t0) * 1000)
            if resp.status == 200:
                _parse_stream(row, bytes(buf))
            else:
                _parse_error(row, bytes(buf))
        else:
            raw = resp.read()
            row["ttfb_ms"] = row["total_ms"] = round((time.monotonic() - t0) * 1000)
            if resp.status == 200:
                _parse_json_body(row, raw, face)
            else:
                _parse_error(row, raw)
    except (socket.timeout, TimeoutError):
        row["status"] = 0
        row["err_code"] = "timeout"
        row["total_ms"] = round((time.monotonic() - t0) * 1000)
    except (OSError, http.client.HTTPException) as exc:
        row["status"] = 0
        row["err_code"] = "transport"
        row["err_msg"] = type(exc).__name__
        row["total_ms"] = round((time.monotonic() - t0) * 1000)
    finally:
        if conn:
            conn.close()
    return row


def _iter_sse(raw):
    """Yield (event_name, data) per SSE frame. The event type may ride
    the `event:` line (anthropic frames), the data JSON `type` field
    (OpenAI frames), or both — callers check both."""
    for part in raw.split(b"\n\n"):
        name = None
        for line in part.split(b"\n"):
            if line.startswith(b"event:"):
                name = line[6:].strip().decode("utf-8", "replace")
            elif line.startswith(b"data:"):
                yield name, line[5:].strip()
                name = None


def _parse_stream(row, raw):
    deltas = 0
    usage = None
    for event_name, data in _iter_sse(raw):
        if not data or data == b"[DONE]":
            continue
        try:
            ev = json.loads(data)
        except json.JSONDecodeError:
            continue
        etype = event_name or ev.get("type") or ""
        if etype == "response.output_text.delta":
            deltas += 1
        elif "choices" in ev and ev["choices"]:
            d = ev["choices"][0].get("delta", {}) or {}
            if d.get("content") or d.get("reasoning_content"):
                deltas += 1
            if ev.get("usage"):
                usage = ev["usage"]
        # Usage may ride a frame with EMPTY choices (the OpenAI usage
        # chunk) — check it on every frame, never only inside delta arms.
        if isinstance(ev.get("usage"), dict) and ev["usage"]:
            u = ev["usage"]
            if u.get("prompt_tokens") is not None or u.get("input_tokens") is not None:
                usage = dict(usage or {}, input_tokens=u.get("prompt_tokens", u.get("input_tokens")))
            if u.get("completion_tokens") is not None or u.get("output_tokens") is not None:
                usage = dict(usage or {}, output_tokens=u.get("completion_tokens", u.get("output_tokens")))
        if etype == "content_block_delta":
            d = ev.get("delta") or {}
            if d.get("text"):
                deltas += 1
            elif d.get("thinking"):
                deltas += 1
                row["thinking"] = True
        if etype == "message_start":
            u = (ev.get("message") or {}).get("usage")
            if u:
                usage = dict(usage or {}, input_tokens=u.get("input_tokens"))
        if etype == "message_delta":
            u = ev.get("usage") or {}
            if u.get("output_tokens") is not None:
                usage = dict(usage or {}, output_tokens=u.get("output_tokens"))
            if ev.get("stop_reason"):
                row["incomplete_reason"] = ev["stop_reason"]
        if etype in ("response.completed", "response.incomplete"):
            u = (ev.get("response") or {}).get("usage")
            if u:
                usage = u
            if etype == "response.incomplete":
                row["incomplete_reason"] = ((ev.get("response") or {})
                                             .get("incomplete_details") or {}).get("reason")
    row["chunks"] = deltas
    if usage:
        row["in_toks"] = usage.get("input_tokens") or usage.get("prompt_tokens")
        row["out_toks"] = usage.get("output_tokens") or usage.get("completion_tokens")


def _parse_json_body(row, raw, face):
    try:
        body = json.loads(raw)
    except json.JSONDecodeError:
        row["err_code"] = "bad_json"
        return
    if face == "responses":
        u = body.get("usage") or {}
        row["in_toks"] = u.get("input_tokens")
        row["out_toks"] = u.get("output_tokens")
        out = body.get("output") or []
        row["chunks"] = sum(1 for o in out if o.get("type") == "message")
    elif face == "anthropic":
        u = body.get("usage") or {}
        row["in_toks"] = u.get("input_tokens")
        row["out_toks"] = u.get("output_tokens")
        row["chunks"] = sum(1 for c in body.get("content") or []
                            if c.get("type") == "text")
        if body.get("stop_reason") == "max_tokens":
            row["incomplete_reason"] = "max_output_tokens"
    else:
        u = body.get("usage") or {}
        row["in_toks"] = u.get("prompt_tokens")
        row["out_toks"] = u.get("completion_tokens")
        row["chunks"] = len(body.get("choices") or [])


def _parse_error(row, raw):
    try:
        body = json.loads(raw)
        err = body.get("error", {}) if isinstance(body, dict) else {}
        row["err_code"] = str(err.get("code"))[:64]
        row["err_msg"] = str(err.get("message"))[:160]
    except Exception:
        row["err_msg"] = raw[:160].decode("utf-8", "replace")



# --- marathon: complex long tasks + persistent connections ----------------
#
# One-shot mode (--marathon): long generations that hold streams open for
# minutes, a big-context+long-output run, keep-alive connection REUSE, and
# the idle-timeout boundary (just under / just over the documented 300s).
# Findings land in the same JSONL with marathon_* scenario names.

MARATHON_TASK = (
    "Write a complete, production-quality LRU cache in Python: the class "
    "with get/put/delete/len, an OrderedDict-backed O(1) implementation, "
    "thread-safety notes, and a thorough unittest suite covering eviction "
    "order, capacity edges, and delete-miss. Code plus tests, no prose."
)
MARATHON_LONG = _LONG_TEXT * 3


def _conn():
    u = urllib.parse.urlparse(URL)
    ctx = ssl.create_default_context()
    return http.client.HTTPSConnection(u.hostname, u.port or 443, timeout=900, context=ctx)


def _post(conn, path, payload, timeout_s):
    conn.timeout = timeout_s
    t0 = time.monotonic()
    conn.request("POST", path, body=json.dumps(payload).encode(), headers={
        "Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    resp = conn.getresponse()
    raw = resp.read()
    return {"status": resp.status, "rid": resp.getheader("x-request-id"),
            "ms": round((time.monotonic() - t0) * 1000), "raw": raw}


def marathon_stream(model, name, prompt, max_tokens):
    """One long streaming request; timing + stall analysis."""
    u = urllib.parse.urlparse(URL)
    ctx = ssl.create_default_context()
    conn = http.client.HTTPSConnection(u.hostname, u.port or 443, timeout=900, context=ctx)
    row = {"ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
           "model": model, "scenario": name, "face": "chat", "stream": True}
    t0 = time.monotonic()
    try:
        conn.request("POST", "/v1/chat/completions", body=json.dumps({
            "model": model, "stream": True,
            "stream_options": {"include_usage": True},
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens}).encode(),
            headers={"Authorization": "Bearer " + KEY,
                     "Content-Type": "application/json"})
        resp = conn.getresponse()
        row["status"] = resp.status
        row["rid"] = resp.getheader("x-request-id")
        arrivals, buf = [], bytearray()
        while True:
            blob = resp.read(4096)
            if not blob:
                break
            arrivals.append(time.monotonic())
            buf.extend(blob)
        row["ttfb_ms"] = round((arrivals[0] - t0) * 1000) if arrivals else None
        row["total_ms"] = round((time.monotonic() - t0) * 1000)
        gaps = [round((arrivals[i] - arrivals[i - 1]) * 1000) for i in range(1, len(arrivals))]
        if gaps:
            row["gap_max_ms"] = max(gaps)
            row["gap_p95_ms"] = _percentile(gaps, 0.95)
        _parse_stream(row, bytes(buf))
    except (OSError, http.client.HTTPException, socket.timeout) as exc:
        row["status"] = 0
        row["err_code"] = "transport"
        row["err_msg"] = type(exc).__name__
        row["total_ms"] = round((time.monotonic() - t0) * 1000)
    finally:
        conn.close()
    _append(row)
    return row


def marathon_keepalive(model):
    """REUSE one TCP connection for sequential requests; then probe the
    idle boundary (under and over the documented 300s gateway timeout)."""
    rows = []
    conn = _conn()
    try:
        for i in range(10):
            r = _post(conn, "/v1/chat/completions", {
                "model": model, "max_tokens": 32,
                "messages": [{"role": "user", "content": "Say the number %d." % i}]}, 120)
            row = {"ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                   "model": model, "scenario": "marathon_keepalive_reuse",
                   "face": "chat", "stream": False}
            row.update({k: v for k, v in r.items() if k != "raw"})
            _append(row)
            rows.append(row)
            time.sleep(0.5)
    except (OSError, http.client.HTTPException) as exc:
        rows.append({"scenario": "marathon_keepalive_reuse", "status": 0,
                     "err_code": "transport", "err_msg": type(exc).__name__})
    finally:
        conn.close()

    for idle in (290, 320):
        conn = _conn()
        label = "marathon_keepalive_idle_%ds" % idle
        try:
            _post(conn, "/v1/chat/completions", {
                "model": model, "max_tokens": 8,
                "messages": [{"role": "user", "content": "warm"}]}, 60)
            time.sleep(idle)
            r = _post(conn, "/v1/chat/completions", {
                "model": model, "max_tokens": 8,
                "messages": [{"role": "user", "content": "still here?"}]}, 120)
            row = {"ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                   "model": model, "scenario": label, "face": "chat", "stream": False,
                   "idle_sec": idle}
            row.update({k: v for k, v in r.items() if k != "raw"})
        except (OSError, http.client.HTTPException) as exc:
            row = {"ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                   "model": model, "scenario": label, "status": 0, "idle_sec": idle,
                   "err_code": "transport", "err_msg": type(exc).__name__}
        finally:
            conn.close()
        _append(row)
        rows.append(row)
    return rows


def run_marathon():
    _log("BENCH", "marathon start")
    for model in MODELS:
        r1 = marathon_stream(model, "marathon_longgen_stream", MARATHON_TASK, 4096)
        _log("BENCH", "longgen %s: %s %sms chunks=%s gap_max=%sms" % (
            model, r1.get("status"), r1.get("total_ms"), r1.get("chunks"), r1.get("gap_max_ms")))
        if r1.get("gap_max_ms", 0) > 10000:
            anomaly("%s/marathon_longgen_stream stall %sms rid=%s" % (
                model, r1["gap_max_ms"], r1.get("rid")))
        if r1.get("status") == 200 and not r1.get("out_toks"):
            anomaly("%s/marathon_longgen_stream 200 without usage rid=%s" % (model, r1.get("rid")))
        time.sleep(2)
        r2 = marathon_stream(model, "marathon_bigctx_stream",
                             "Produce a detailed structured outline of the following text:\n\n"
                             + MARATHON_LONG, 2048)
        _log("BENCH", "bigctx %s: %s %sms in=%s out=%s" % (
            model, r2.get("status"), r2.get("total_ms"), r2.get("in_toks"), r2.get("out_toks")))
        time.sleep(2)
    for row in marathon_keepalive(MODELS[0]):
        sc = row.get("scenario", "")
        if sc.endswith("idle_290s") and row.get("status") != 200:
            anomaly("keepalive idle 290s failed (under the 300s floor): %s %s" % (
                row.get("err_code"), row.get("err_msg")))
        if sc.endswith("idle_320s"):
            _log("BENCH", "idle 320s boundary: status=%s err=%s (expected close at 300s)" % (
                row.get("status"), row.get("err_code")))
    reuse_ok = sum(1 for r in _day_rows()
                   if r.get("scenario") == "marathon_keepalive_reuse" and r.get("status") == 200)
    _log("BENCH", "keepalive reuse requests ok: %d/10" % reuse_ok)
    _log("BENCH", "marathon done")



# --- soak: multi-hour sustained load + one long-lived connection -------
#
# Hours-scale endurance: short-test classes never surface leaks or slow
# drift. The soak keeps a modest continuous load rotating across models,
# holds ONE keep-alive connection for the whole run (reconnects are the
# headline metric), and samples the gateway BEAM's RSS + fd count hourly
# when the probe runs on the gateway host. Same JSONL, scenario soak_*.

SOAK_PACE_SEC = float(os.environ.get("JANUS_SOAK_PACE_SEC", "8"))


def _proc_rss_fds(pid):
    try:
        with open(f"/proc/{pid}/status") as f:
            rss = next(l for l in f if l.startswith("VmRSS:")).split()[1]
        fds = len(os.listdir(f"/proc/{pid}/fd"))
        return {"rss_kb": int(rss), "fds": fds}
    except Exception:
        return None


def _service_pid(unit):
    try:
        out = os.popen(f"systemctl show {unit} -p MainPID --value").read().strip()
        if out.isdigit() and int(out) > 0:
            return int(out)
    except Exception:
        pass
    # Type=exec + wrapper-fork units can leave MainPID=0 — fall back to
    # the listener (master agent :8080, worker dist :25672).
    port = "8080" if unit == "janus-gw" else "25672"
    try:
        out = os.popen(f"ss -tlnp 'sport = :{port}'").read()
        m = re.search(r"pid=(\d+)", out)
        return int(m.group(1)) if m else None
    except Exception:
        return None


def soak_resources():
    """Gateway BEAM resource sample (only meaningful on the gateway host)."""
    sample = {}
    for unit in ("janus-gw", "janus-gw-local"):
        pid = _service_pid(unit)
        if pid:
            m = _proc_rss_fds(pid)
            if m:
                sample[unit] = m
    return sample


def run_soak(hours):
    deadline = time.monotonic() + hours * 3600
    conn = _conn()
    reconnects = 0
    n = 0
    hour_mark = time.monotonic() + 3600
    base_res = soak_resources()
    _log("BENCH", f"soak start: {hours}h pace={SOAK_PACE_SEC}s models={MODELS} "
                  f"base_res={base_res}")
    while time.monotonic() < deadline and not _stop:
        model = MODELS[n % len(MODELS)]
        if DAILY_CAP and _tokens_today(_day_rows()) >= DAILY_CAP:
            _log("BENCH", "soak: daily cap reached — pausing 10 min")
            time.sleep(600)
            continue
        row = {"ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
               "model": model, "scenario": "soak_reuse", "face": "chat",
               "stream": False}
        t0 = time.monotonic()
        try:
            r = _post(conn, "/v1/chat/completions", {
                "model": model, "max_tokens": 64,
                "messages": [{"role": "user", "content": f"Reply with one sentence about hour {n // 450 + 1} of a soak test."}]},
                120)
            row.update({k: v for k, v in r.items() if k != "raw"})
            if r.get("status") == 200:
                try:
                    body = json.loads(r["raw"])
                    u = body.get("usage") or {}
                    row["in_toks"] = u.get("prompt_tokens")
                    row["out_toks"] = u.get("completion_tokens")
                except Exception:
                    pass
        except (OSError, http.client.HTTPException) as exc:
            reconnects += 1
            row.update({"status": 0, "err_code": "transport",
                        "err_msg": type(exc).__name__})
            anomaly(f"soak reconnect #{reconnects} after {type(exc).__name__} "
                    f"at request {n}")
            try:
                conn.close()
            except Exception:
                pass
            conn = _conn()
        row["total_ms"] = row.get("ms")
        row["ttfb_ms"] = row.get("ms")
        row["reconnects"] = reconnects
        _append(row)
        _check_row(row, _day_rows())
        n += 1
        if time.monotonic() >= hour_mark:
            res = soak_resources()
            _log("BENCH", f"soak hour {(hours * 3600 - (deadline - time.monotonic())) // 3600 + 1}: "
                          f"requests={n} reconnects={reconnects} res={res}")
            hour_mark = time.monotonic() + 3600
        for _ in range(int(SOAK_PACE_SEC)):
            if _stop:
                break
            time.sleep(1)
    try:
        conn.close()
    except Exception:
        pass
    end_res = soak_resources()
    rows = [r for r in _day_rows() if r.get("scenario") == "soak_reuse"]
    oks = [r for r in rows if r.get("status") == 200]
    tt = sorted(r["ttfb_ms"] for r in oks if r.get("ttfb_ms"))
    summary = {
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "hours": hours, "requests": len(rows), "ok": len(oks),
        "reconnects": reconnects,
        "ttfb_p50_ms": _percentile(tt, 0.5), "ttfb_p95_ms": _percentile(tt, 0.95),
        "resources_start": base_res, "resources_end": end_res,
    }
    tmp = _DATA / "soak_summary.json.tmp"
    tmp.write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    tmp.replace(_DATA / "soak_summary.json")
    _log("BENCH", f"soak done: {json.dumps(summary, ensure_ascii=False)}")
    for unit in end_res:
        if unit in base_res:
            d_rss = end_res[unit]["rss_kb"] - base_res[unit]["rss_kb"]
            d_fds = end_res[unit]["fds"] - base_res[unit]["fds"]
            if d_rss > 200 * 1024:
                anomaly(f"soak: {unit} RSS grew {d_rss // 1024}MB over {hours}h (leak?)")
            if d_fds > 200:
                anomaly(f"soak: {unit} fd count grew {d_fds} over {hours}h (leak?)")


# --- history + baselines --------------------------------------------------

def _day_rows(now=None):
    day = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%d")
    f = _DATA / f"bench-{day}.jsonl"
    rows = []
    if f.exists():
        for line in f.read_text().splitlines():
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows


def _append(row):
    day = row["ts"][:10]
    with (_DATA / f"bench-{day}.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def _percentile(vals, q):
    if not vals:
        return None
    vals = sorted(vals)
    k = max(0, min(len(vals) - 1, int(round(q * (len(vals) - 1)))))
    return vals[k]


def _write_report(rows24):
    by = {}
    for r in rows24:
        k = (r.get("model"), r.get("scenario"))
        by.setdefault(k, []).append(r)
    out = {"generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
           "vantage": TAG, "window_h": 24, "series": []}
    for (model, scen), rs in sorted(by.items(), key=lambda kv: str(kv[0])):
        oks = [r for r in rs if r.get("status") == 200]
        ttfbs = [r["ttfb_ms"] for r in oks if r.get("ttfb_ms")]
        gaps = [g for r in oks for g in [r.get("gap_max_ms")] if g]
        out["series"].append({
            "model": model, "scenario": scen, "n": len(rs),
            "err_rate": round(1 - len(oks) / len(rs), 3) if rs else None,
            "ttfb_p50_ms": _percentile(ttfbs, 0.50),
            "ttfb_p95_ms": _percentile(ttfbs, 0.95),
            "gap_max_seen_ms": max(gaps) if gaps else None,
            "last_status": rs[-1].get("status"),
            "last_rid": rs[-1].get("rid"),
        })
    tmp = _DATA / "report.json.tmp"
    tmp.write_text(json.dumps(out, ensure_ascii=False, indent=1))
    tmp.replace(_DATA / "report.json")


def _baseline(rows24, model, scenario):
    """Relative anomaly thresholds need >=20 clean samples of history."""
    vals = [r["ttfb_ms"] for r in rows24
            if r.get("model") == model and r.get("scenario") == scenario
            and r.get("status") == 200 and r.get("ttfb_ms")]
    if len(vals) < 20:
        return None
    mu = statistics.fmean(vals)
    sd = statistics.pstdev(vals) or 1
    return mu + 3 * sd


def _check_row(row, rows24):
    tag = f"{row.get('model')}/{row.get('scenario')}"
    if row.get("status") != 200:
        anomaly(f"{tag} status={row.get('status')} code={row.get('err_code')} "
                f"msg={row.get('err_msg')} rid={row.get('rid')}")
        return
    base = _baseline(rows24, row.get("model"), row.get("scenario"))
    limit = max(15000, (base or 0) * 2)
    if row.get("ttfb_ms", 0) > limit:
        anomaly(f"{tag} ttfb {row['ttfb_ms']}ms exceeds "
                f"{'baseline x2 (' + str(int(base)) + 'ms)' if base else '15s floor'} "
                f"rid={row.get('rid')}")
    if (row.get("stream") and row.get("chunks", 0) == 0
            and row.get("incomplete_reason") != "max_output_tokens"):
        anomaly(f"{tag} 200 but zero stream deltas rid={row.get('rid')}")
    if row.get("incomplete_reason"):
        anomaly(f"{tag} incomplete: {row['incomplete_reason']} "
                f"(budget starved before output) rid={row.get('rid')}")
    if row.get("gap_max_ms", 0) > 5000:
        anomaly(f"{tag} stream stall: max inter-chunk gap {row['gap_max_ms']}ms "
                f"rid={row.get('rid')}")
    if not row.get("out_toks"):
        anomaly(f"{tag} 200 but no output tokens reported rid={row.get('rid')}")
    elif (row.get("in_toks") == 0 and row.get("status") == 200
          and row.get("face") == "chat"):
        anomaly(f"{tag} usage reports prompt_tokens=0 (translate input gap) "
                f"rid={row.get('rid')}")


# --- rounds ---------------------------------------------------------------

def _tokens_today(rows):
    return sum((r.get("in_toks") or 0) + (r.get("out_toks") or 0) for r in rows)


def run_round():
    rows24 = _day_rows()
    spent = _tokens_today(rows24)
    if DAILY_CAP and spent >= DAILY_CAP:
        _log("BENCH", f"daily token cap reached ({spent}/{DAILY_CAP}) — sleeping")
        return
    round_rows = []
    for model in MODELS:
        for name, face, stream, prompt, max_tokens in _scenarios():
            if _stop:
                break
            body = {"model": model,
                    "messages": [{"role": "user", "content": prompt}],
                    "max_tokens": max_tokens}
            row = _request(face, stream, body)
            row["model"] = model
            row["scenario"] = name
            _append(row)
            round_rows.append(row)
            _check_row(row, rows24 + round_rows)
            time.sleep(2)  # gentle pacing; this is a watchdog, not a load test
    _write_report((_day_rows()))  # includes today's file only
    oks = [r for r in round_rows if r.get("status") == 200]
    tt = [r["ttfb_ms"] for r in oks if r.get("ttfb_ms")]
    _log("BENCH", f"round done: {len(oks)}/{len(round_rows)} ok "
                  f"ttfb p50 {_percentile(tt, 0.5)}ms p95 {_percentile(tt, 0.95)}ms "
                  f"spent_today={_tokens_today(_day_rows())}")


def main():
    if not KEY:
        _log("BENCH", "JANUS_BENCH_KEY not set — refusing to start")
        sys.exit(1)
    global _stop

    def _sig(_s, _f):
        global _stop
        _stop = True

    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)
    if MARATHON:
        run_marathon()
        return
    if SOAK_HOURS:
        run_soak(SOAK_HOURS)
        return
    _log("BENCH", f"start: {URL} models={MODELS} interval={INTERVAL}s "
                  f"data={_DATA} daily_cap={DAILY_CAP}")
    while not _stop:
        try:
            run_round()
        except Exception as exc:  # never die on a bad round
            _log("BENCH", f"round crashed: {type(exc).__name__}: {exc}")
        for _ in range(INTERVAL):
            if _stop:
                break
            time.sleep(1)
    _log("BENCH", "stopped")


if __name__ == "__main__":
    main()
