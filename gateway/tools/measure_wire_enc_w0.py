#!/usr/bin/env python
"""W.0 wire-compression measurement gate (spec 2026-10-12-wire-compression).

Measures, over REAL provider traffic (keys from the operator temp env
file, never committed):
  - dist-chunk size distribution as the gateway would relay it
    (per SSE event = one chunk; gun data frames are coarser, so
    per-event is the conservative small-chunk case)
  - per-message zlib level-1 ratio for each chunk (RFC 1950 wrapper —
    exactly what janus_wire_enc emits: one independent complete zlib
    stream per message)
  - threshold sweep at 128/256/512/1024 bytes
  - deflate CPU cost per message (us) at level 1
  - the unary done-body size (non-stream response) for MAX_INFLATE
    sizing
Output: JSON artifact + printed summary. Run before any prod enable;
the enable commit references the artifact (spec §4/§5).
"""
import io, json, os, sys, time, zlib, urllib.request

ENV = os.path.join(os.environ.get("TEMP", "."), "overnight_keys.env")
if os.path.exists(ENV):
    for line in io.open(ENV, encoding="utf-8"):
        if "=" in line:
            k, v = line.strip().split("=", 1)
            os.environ[k] = v

OUT_DIR = sys.argv[1] if len(sys.argv) > 1 else "."
LEVEL = int(os.environ.get("W0_LEVEL", "1"))


def stream_sse(url, key, body, timeout=180):
    """Yield raw SSE event byte strings as they arrive off the wire."""
    req = urllib.request.Request(
        url,
        method="POST",
        data=json.dumps(body).encode(),
        headers={
            "authorization": "Bearer " + key,
            "content-type": "application/json",
            "accept": "text/event-stream",
        },
    )
    buf = b""
    events = []
    with urllib.request.urlopen(req, timeout=timeout) as r:
        while True:
            b = r.read(4096)
            if not b:
                break
            buf += b
            while b"\n\n" in buf:
                ev, buf = buf.split(b"\n\n", 1)
                events.append(ev + b"\n\n")
    if buf:
        events.append(buf)
    return events


def unary(url, key, body, timeout=180):
    req = urllib.request.Request(
        url,
        method="POST",
        data=json.dumps(body).encode(),
        headers={"authorization": "Bearer " + key, "content-type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def measure(chunks, label):
    """Per-message zlib stats over a chunk list."""
    sizes = [len(c) for c in chunks]
    plain = wire = 0
    times = []
    ratios = []
    for c in chunks:
        t0 = time.perf_counter_ns()
        z = zlib.compress(c, LEVEL)
        times.append((time.perf_counter_ns() - t0) / 1000.0)
        if len(z) < len(c):  # never-expands rule
            plain += len(c)
            wire += len(z)
            ratios.append(len(z) / len(c))
    def bucket(n):
        return (
            "lt128" if n < 128 else "128-255" if n < 256 else "256-1023"
            if n < 1024 else "1024-4095" if n < 4096 else "ge4096"
        )
    hist = {}
    for n in sizes:
        hist[bucket(n)] = hist.get(bucket(n), 0) + 1
    sweep = {}
    for thr in (128, 256, 512, 1024):
        p = w = 0
        for c in chunks:
            if len(c) < thr:
                p += len(c)
                w += len(c)
                continue
            z = zlib.compress(c, LEVEL)
            p += len(c)
            w += min(len(z), len(c))
        sweep[thr] = {"plain": p, "wire": w, "ratio": round(w / p, 3) if p else None}
    return {
        "label": label,
        "count": len(chunks),
        "size_hist": hist,
        "size_min": min(sizes) if sizes else 0,
        "size_max": max(sizes) if sizes else 0,
        "size_p50": sorted(sizes)[len(sizes) // 2] if sizes else 0,
        "compressed_msgs": len(ratios),
        "compressed_ratio_avg": round(sum(ratios) / len(ratios), 3) if ratios else None,
        "aggregate_ratio": round(wire / plain, 3) if plain else None,
        "deflate_us_avg": round(sum(times) / len(times), 1) if times else 0,
        "deflate_us_p95": round(sorted(times)[int(len(times) * 0.95)] if times else 0, 1),
        "threshold_sweep": sweep,
    }


def main():
    results = []
    # Every provider present in the temp env is measured; each entry is
    # (env_base, env_key, model, label).
    providers = []
    for base_k, key_k, model, label in [
        ("minimax_base", "minimax_key", "MiniMax-M2.7", "minimax-m2.7"),
        ("stepfun_base", "stepfun_key", "step-3.7-flash", "stepfun-3.7-flash"),
        ("mimo_base", "mimo_key", "mimo-v2.6-pro", "mimo-v2.6-pro"),
    ]:
        if base_k in os.environ and key_k in os.environ:
            providers.append((os.environ[base_k], os.environ[key_k], model, label))
    if not providers:
        print("no provider keys in temp env — nothing to measure")
        return 1
    prompt = "Write a vivid 300-word story about a lighthouse keeper."
    for base, key, model, label in providers:
        url = base.rstrip("/") + "/chat/completions"
        try:
            events = stream_sse(
                url, key, {"model": model, "messages": [{"role": "user", "content": prompt}], "stream": True}
            )
            if events:
                results.append(measure(events, label + "/stream"))
            body = unary(
                url, key, {"model": model, "messages": [{"role": "user", "content": prompt}]}
            )
            results.append(
                {
                    "label": label + "/unary-done-body",
                    "done_body_bytes": len(body),
                    "done_body_zlib": len(zlib.compress(body, LEVEL)),
                }
            )
        except Exception as e:
            results.append({"label": label, "error": repr(e)[:300]})
    max_done = max(
        (r["done_body_bytes"] for r in results if "done_body_bytes" in r), default=0
    )
    summary = {
        "level": LEVEL,
        "results": results,
        "observed_max_done_body": max_done,
        "max_inflate_recommendation": max(8 * 1024 * 1024, 4 * max_done),
    }
    out = os.path.join(OUT_DIR, "wire_enc_w0_artifact.json")
    with io.open(out, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=1)
    print(json.dumps(summary, indent=1))
    print("saved", out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
