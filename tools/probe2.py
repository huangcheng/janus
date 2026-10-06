#!/usr/bin/env python
"""Probe round 2: stepfun model discovery + image gen; mimo TTS shape."""
import io, json, os, urllib.request

ENV = os.path.join(os.environ.get("TEMP", "."), "overnight_keys.env")
for line in io.open(ENV, encoding="utf-8"):
    if "=" in line:
        k, v = line.strip().split("=", 1)
        os.environ[k] = v

OUT = r"F:\Janus\apps\janus_http\test\fixtures\probes"
os.makedirs(OUT, exist_ok=True)

def call(url, key, body=None, method=None, headers=None, timeout=120, raw=False):
    data = json.dumps(body).encode() if body is not None else None
    h = {"authorization": "Bearer " + key}
    if body is not None: h["content-type"] = "application/json"
    if headers: h.update(headers)
    req = urllib.request.Request(url, method=method or ("POST" if body is not None else "GET"), data=data, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            payload = r.read()
            return r.status, dict(r.headers), (payload if raw else json.loads(payload) if payload else {})
    except urllib.error.HTTPError as e:
        payload = e.read()
        try: return e.code, dict(e.headers), json.loads(payload)
        except Exception: return e.code, dict(e.headers), payload[:400]
    except Exception as e:
        return 0, {}, str(e).encode()[:300]

def save(name, obj):
    with io.open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    print("saved", name)

sf = os.environ["stepfun_base"]; sfk = os.environ["stepfun_key"]
# models list
st, h, b = call(sf + "/models", sfk, None, method="GET", timeout=30)
names = [m.get("id") for m in b.get("data", [])] if isinstance(b, dict) else b
print("stepfun models:", st, names)
save("stepfun_models.json", {"status": st, "models": names})

# try image models
for model in ["step-1x-medium", "step-1x-turbo", "step-1v-8k", "step-1t-8k"]:
    st, h, b = call(sf + "/images/generations", sfk, {"model": model, "prompt": "a small red circle", "n": 1}, timeout=120)
    print(f"stepfun {model}: {st} {json.dumps(b, ensure_ascii=False)[:200]}")
    if st == 200:
        save(f"stepfun_image_{model}.json", {"status": st, "response": b}); break

# mimo TTS: assistant role carries the text
mm = os.environ["mimo_base"]; mk = os.environ["mimo_key"]
st, h, b = call(mm + "/chat/completions", mk, {
    "model": "mimo-v2.5-tts",
    "messages": [
        {"role": "user", "content": "read this aloud"},
        {"role": "assistant", "content": "你好，世界。"}
    ], "stream": False}, timeout=120)
body = b if isinstance(b, dict) else {}
print("mimo tts chat:", st, json.dumps(body, ensure_ascii=False)[:400])
save("mimo_tts_chat2.json", {"status": st, "response": body})

# maybe audio comes as base64 in message.audio
# also try stream variant shape quickly (headers only)
print("PROBE2 DONE")
