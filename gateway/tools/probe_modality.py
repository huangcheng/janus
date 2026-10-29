#!/usr/bin/env python
"""Overnight probe: verify provider modality endpoints with REAL keys
and record raw transcripts as corpus fixtures (spec C6 discipline:
real captures only). Writes to apps/janus_http/test/fixtures/probes/.
NEVER prints full keys; NEVER commits. Outputs land under the repo tree,
so the fixtures dir is listed in .gitignore (checked).
"""
import base64
import io
import json
import os
import struct
import urllib.request

ENV = os.path.join(os.environ.get("TEMP", "."), "overnight_keys.env")
for line in io.open(ENV, encoding="utf-8"):
    if "=" in line:
        k, v = line.strip().split("=", 1)
        os.environ[k] = v

OUT = r"F:\Janus\apps\janus_http\test\fixtures\probes"
os.makedirs(OUT, exist_ok=True)


def save(name, data):
    p = os.path.join(OUT, name)
    mode = "wb" if isinstance(data, bytes) else "w"
    with io.open(p, mode, **({} if mode == "wb" else {"encoding": "utf-8"})) as f:
        f.write(data)
    print("saved", name, len(data), "bytes")


def call(url, key, body=None, method=None, headers=None, timeout=60, raw=False):
    data = json.dumps(body).encode() if body is not None else None
    h = {"authorization": "Bearer " + key}
    if body is not None:
        h["content-type"] = "application/json"
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, method=method or ("POST" if body is not None else "GET"), data=data, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            payload = r.read()
            return r.status, dict(r.headers), (payload if raw else json.loads(payload) if payload else {})
    except urllib.error.HTTPError as e:
        payload = e.read()
        try:
            return e.code, dict(e.headers), json.loads(payload)
        except Exception:
            return e.code, dict(e.headers), payload[:500]
    except Exception as e:
        return 0, {}, str(e).encode()[:300]


def probe(name, url, key, body, **kw):
    st, hd, b = call(url, key, body, **kw)
    txt = json.dumps(b, ensure_ascii=False)[:400] if not isinstance(b, bytes) else repr(b)[:400]
    print(f"[{name}] status={st} body[:400]={txt}")
    save(name + ".json", json.dumps({"url": url, "status": st, "response": b if not isinstance(b, bytes) else b.decode('utf-8', 'replace')}, ensure_ascii=False, indent=1))
    return st, b


# 1) stepfun: does the Step Plan expose OpenAI-style images?
probe("stepfun_images", os.environ["stepfun_base"] + "/images/generations", os.environ["stepfun_key"],
      {"model": "step-5-preview", "prompt": "a red circle", "n": 1, "size": "512x512"}, timeout=30)

# 2) minimax T2I (token-plan key against the documented PAYG endpoint + .cn)
for base in ["https://api.minimax.cn/v1", "https://api.minimaxi.com/v1"]:
    probe("minimax_t2i_" + ("cn" if ".cn" in base else "i"), base + "/image_generation", os.environ["minimax_key"],
          {"model": "image-01", "prompt": "a small red circle on white background", "n": 1, "response_format": "url"}, timeout=120)

# 3) dashscope qwen-image via OpenAI-compatible images endpoint
probe("dashscope_images", "https://dashscope.aliyuncs.com/compatible-mode/v1/images/generations", os.environ["dashscope_key"],
      {"model": "qwen-image", "prompt": "a small red circle on white background", "n": 1, "size": "512*512"}, timeout=180)

# 4) mimo ASR: chat/completions with input_audio (0.5s 440Hz wav)
import math
sr = 16000
frames = b"".join(struct.pack("<h", int(3000 * math.sin(2 * math.pi * 440 * i / sr))) for i in range(sr // 2))
wav = b"RIFF" + struct.pack("<I", 36 + len(frames)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, sr, sr * 2, 2, 16) + b"data" + struct.pack("<I", len(frames)) + frames
b64 = base64.b64encode(wav).decode()
probe("mimo_asr", os.environ["mimo_base"] + "/chat/completions", os.environ["mimo_key"],
      {"model": "mimo-v2.5-asr", "messages": [{"role": "user", "content": [{"type": "input_audio", "input_audio": {"data": "data:audio/wav;base64," + b64}}]}],
       "extra_body": None, "stream": False}, timeout=120)

# 5) mimo TTS: probe both chat-shaped and OpenAI speech-shaped
probe("mimo_tts_chat", os.environ["mimo_base"] + "/chat/completions", os.environ["mimo_key"],
      {"model": "mimo-v2.5-tts", "messages": [{"role": "user", "content": "你好"}], "stream": False}, timeout=120)
st, hd, b = call(os.environ["mimo_base"] + "/audio/speech", os.environ["mimo_key"],
                 {"model": "mimo-v2.5-tts", "input": "你好", "voice": "default"}, raw=True, timeout=120)
print(f"[mimo_tts_speech] status={st} ctype={hd.get('Content-Type')} bytes={len(b) if isinstance(b, bytes) else '?'}")
if isinstance(b, bytes) and st == 200:
    save("mimo_tts_speech.bin", b[:4096])
else:
    save("mimo_tts_speech.json", json.dumps({"status": st, "headers": dict(hd), "body": (b.decode('utf-8', 'replace') if isinstance(b, bytes) else str(b))[:500]}))

# 6) mimo models list (discover TTS/ASR model names + maybe image)
probe("mimo_models", os.environ["mimo_base"] + "/models", os.environ["mimo_key"], None, method="GET", timeout=30)

print("PROBES DONE")
