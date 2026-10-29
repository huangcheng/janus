#!/usr/bin/env python
"""Capture REAL tool-call SSE transcripts through the LOCAL gateway
(dashscope qwen3.8 chat + kimi anthropic) as translation-corpus
fixtures. Also retry stepfun image once."""
import io, json, os, urllib.request

DASH = "http://127.0.0.1:8091"
GW = "http://127.0.0.1:8080"
OUT = r"F:\Janus\apps\janus_http\test\fixtures\sse"
os.makedirs(OUT, exist_ok=True)

# local dashboard admin password from .env
env = {}
for line in io.open(r"F:\Janus-dashboard\.env", encoding="utf-8"):
    if "=" in line and not line.startswith("#"):
        k, v = line.strip().split("=", 1)
        env[k] = v

def req(url, method="GET", body=None, token=None, timeout=180):
    data = json.dumps(body).encode() if body is not None else None
    h = {}
    if body is not None: h["content-type"] = "application/json"
    if token: h["authorization"] = "Bearer " + token
    r = urllib.request.Request(url, method=method, data=data, headers=h)
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        payload = resp.read()
        if not payload:
            return resp.status, {}
        try:
            return resp.status, json.loads(payload)
        except Exception:
            return resp.status, payload

# login + fresh agent key
_, b = req(DASH + "/api/auth/login", "POST", {"password": env["JANUS_DASHBOARD_PASSWORD"]})
jwt = b["token"]
_, mk = req(DASH + "/api/keys", "POST", {"name": "fixture-capture", "daily_budget": 0}, token=jwt) if False else (None, None)
# keys API shape may differ; reuse: create via /api/keys
st, mk = req(DASH + "/api/keys", "POST", {"name": "fixture-capture"}, token=jwt)
ak = mk.get("key") or mk.get("secret") or mk.get("token")
print("agent key created:", bool(ak))
import time
time.sleep(4)  # catalog poll before first use
if not ak:
    # fall back to listing
    st, kl = req(DASH + "/api/keys", token=jwt)
    print("keys list:", st, json.dumps(kl)[:200])

TOOLS = [
    {"type": "function", "function": {"name": "get_weather", "description": "Get weather for a city",
     "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}
]

def stream_capture(name, url, body):
    r = urllib.request.Request(url, method="POST", data=json.dumps(body).encode(),
                               headers={"content-type": "application/json", "authorization": "Bearer " + ak})
    with urllib.request.urlopen(r, timeout=180) as resp:
        raw = resp.read()
    with io.open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        f.write(raw.decode("utf-8", "replace"))
    print("captured", name, len(raw), "bytes, head:", raw[:120])

# 1) chat tools stream (dashscope qwen3.8)
stream_capture("dashscope-qwen3.8-tools-chat.sse", GW + "/v1/chat/completions", {
    "model": "qwen3.8-max", "stream": True, "max_tokens": 300,
    "tools": TOOLS,
    "messages": [{"role": "user", "content": "What's the weather in Beijing? Use the tool."}]})

# 2) anthropic tools stream (kimi)
stream_capture("kimi-anthropic-tools.sse", GW + "/v1/messages", {
    "model": "kimi-for-coding", "stream": True, "max_tokens": 300,
    "tools": [{"name": "get_weather", "description": "Get weather for a city",
               "input_schema": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}],
    "messages": [{"role": "user", "content": "What's the weather in Beijing? Use the tool."}]})

print("CAPTURE DONE")
