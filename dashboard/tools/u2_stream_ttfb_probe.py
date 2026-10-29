#!/usr/bin/env python
"""U.2 live probe (spec 2026-10-12-wire-compression section 4): stream
TTFB, gzip-asked vs identity, per provider — the gate for
JANUS_UPSTREAM_ENC_STREAM. Providers that never gzip SSE report
identity (STREAM is then inert for them); the risk case is a provider
THAT gzips SSE with flush buffering — detected as a gzip-TTFB far above
identity-TTFB. Keys from the operator temp env, never committed."""

import json
import os
import time
import urllib.request

ENV = os.path.join(os.environ.get("TEMP", "."), "overnight_keys.env")
if os.path.exists(ENV):
    with open(ENV, encoding="utf-8") as envf:
        for line in envf:
            if "=" in line:
                k, v = line.strip().split("=", 1)
                os.environ[k] = v

PROMPT = "Count from one to five slowly."
RUNS = 3


def ttfb(url, key, model, accept_gzip, timeout=60):
    body = json.dumps(
        {
            "model": model,
            "stream": True,
            "max_tokens": 64,
            "messages": [{"role": "user", "content": PROMPT}],
        }
    ).encode()
    h = {"authorization": "Bearer " + key, "content-type": "application/json"}
    if accept_gzip:
        h["accept-encoding"] = "gzip"
    req = urllib.request.Request(url, method="POST", data=body, headers=h)
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            first = r.read(1)
            t = time.monotonic() - t0
            ce = r.headers.get("content-encoding", "")
            n = len(first + r.read(64))
            return {"t": round(t, 3), "ce": ce, "ok": bool(first) and n > 0}
    except Exception as e:
        return {"t": None, "ce": "", "ok": False, "err": repr(e)[:120]}


def main():
    rows = []
    for base_k, key_k, model, label in [
        ("minimax_base", "minimax_key", "MiniMax-M2.7", "minimax"),
        ("stepfun_base", "stepfun_key", "step-3.7-flash", "stepfun"),
        ("mimo_base", "mimo_key", "mimo-v2.6-pro", "mimo"),
    ]:
        if base_k not in os.environ or key_k not in os.environ:
            continue
        url = os.environ[base_k].rstrip("/") + "/chat/completions"
        key = os.environ[key_k]
        gz, idn = [], []
        for _ in range(RUNS):
            idn.append(ttfb(url, key, model, False))
            gz.append(ttfb(url, key, model, True))
        gz_ok = [r for r in gz if r["ok"]]
        id_ok = [r for r in idn if r["ok"]]
        ces = sorted({r["ce"] for r in gz if r["ok"]})
        row = {
            "label": label,
            "identity_ttfb_avg": round(sum(r["t"] for r in id_ok) / len(id_ok), 3)
            if id_ok
            else None,
            "gzip_ttfb_avg": round(sum(r["t"] for r in gz_ok) / len(gz_ok), 3) if gz_ok else None,
            "gzip_content_encoding": ces,
            "serves_gzip_sse": "gzip" in ces,
        }
        if row["serves_gzip_sse"] and row["gzip_ttfb_avg"] and row["identity_ttfb_avg"]:
            row["ttfb_ratio"] = round(row["gzip_ttfb_avg"] / row["identity_ttfb_avg"], 2)
        rows.append(row)
        print(json.dumps(row))
    out = os.path.join(os.environ.get("TEMP", "/tmp"), "u2_stream_ttfb.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"runs": RUNS, "rows": rows}, f, indent=1)
    print("saved", out)


if __name__ == "__main__":
    main()
