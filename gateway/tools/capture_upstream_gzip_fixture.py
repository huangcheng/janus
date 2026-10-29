#!/usr/bin/env python
"""U.1 fixture capture (spec 2026-10-12-wire-compression): real gzip'd
provider responses. Sends Accept-Encoding: gzip on a unary request via
urllib (which does NOT auto-decompress — the read is the raw RFC 1952
body), saves the raw wire bytes + headers + the identity-body control
for parsed-equivalence. Keys from the operator temp env, never
committed. Output: apps/janus_http/test/fixtures/probes/upstream_gzip/.
"""
import io, json, os, sys, urllib.request

ENV = os.path.join(os.environ.get("TEMP", "."), "overnight_keys.env")
if os.path.exists(ENV):
    for line in io.open(ENV, encoding="utf-8"):
        if "=" in line:
            k, v = line.strip().split("=", 1)
            os.environ[k] = v

OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "apps", "janus_http", "test", "fixtures", "probes", "upstream_gzip",
)
os.makedirs(OUT, exist_ok=True)

PROVIDERS = [
    ("minimax_base", "minimax_key", "MiniMax-M2.7", "minimax-m2.7"),
    ("stepfun_base", "stepfun_key", "step-3.7-flash", "stepfun-3.7-flash"),
    ("mimo_base", "mimo_key", "mimo-v2.6-pro", "mimo-v2.6-pro"),
]


def call(url, key, model, accept_encoding):
    body = json.dumps(
        {"model": model, "messages": [{"role": "user", "content": "Say hello in one short sentence."}]}
    ).encode()
    h = {"authorization": "Bearer " + key, "content-type": "application/json"}
    if accept_encoding:
        h["accept-encoding"] = accept_encoding
    req = urllib.request.Request(url, method="POST", data=body, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def main():
    saved = 0
    for base_k, key_k, model, label in PROVIDERS:
        if base_k not in os.environ or key_k not in os.environ:
            continue
        url = os.environ[base_k].rstrip("/") + "/chat/completions"
        key = os.environ[key_k]
        st, hdr, raw_gz = call(url, key, model, "gzip")
        _st2, _hdr2, raw_plain = call(url, key, model, None)
        ce = hdr.get("Content-Encoding", hdr.get("content-encoding", ""))
        rec = {
            "label": label,
            "model": model,
            "status": st,
            "content_encoding": ce,
            "headers": {k: v for k, v in hdr.items()},
            "gzip_is_real": ce == "gzip" and raw_gz[:2] == b"\x1f\x8b",
            "note": "wire_raw_gzip.b64 holds the exact RFC 1952 bytes; control_identity.json the plain body",
        }
        if rec["gzip_is_real"]:
            import base64

            with io.open(os.path.join(OUT, label + ".json"), "w", encoding="utf-8") as f:
                json.dump(rec, f, ensure_ascii=False, indent=1)
            with io.open(os.path.join(OUT, label + ".wire_raw_gzip.b64"), "w") as f:
                f.write(base64.b64encode(raw_gz).decode())
            with io.open(os.path.join(OUT, label + ".control_identity.json"), "wb") as f:
                f.write(raw_plain)
            saved += 1
            print(label, "-> gzip", len(raw_gz), "B vs plain", len(raw_plain), "B")
        else:
            print(label, "-> no gzip (CE=%r, magic=%r)" % (ce, raw_gz[:2]))
    print("saved", saved, "real gzip fixtures to", OUT)
    return 0 if saved else 1


if __name__ == "__main__":
    sys.exit(main())
