#!/usr/bin/env python
"""Probe round 3: stepfun step-image-edit-2 + stepaudio shapes."""
import io, json, os, urllib.request

ENV = os.path.join(os.environ.get("TEMP", "."), "overnight_keys.env")
for line in io.open(ENV, encoding="utf-8"):
    if "=" in line:
        k, v = line.strip().split("=", 1)
        os.environ[k] = v
OUT = r"F:\Janus\apps\janus_http\test\fixtures\probes"

def call(url, key, body=None, method=None, headers=None, timeout=120):
    data = json.dumps(body).encode() if body is not None else None
    h = {"authorization": "Bearer " + key}
    if body is not None: h["content-type"] = "application/json"
    if headers: h.update(headers)
    req = urllib.request.Request(url, method=method or ("POST" if body is not None else "GET"), data=data, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()
    except Exception as e:
        return 0, {}, str(e).encode()[:300]

def save(name, obj):
    with io.open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    print("saved", name)

sf = os.environ["stepfun_base"]; sfk = os.environ["stepfun_key"]

# image edit model on generations
st, h, raw = call(sf + "/images/generations", sfk, {"model": "step-image-edit-2", "prompt": "a small red circle on white background", "n": 1})
print("step-image-edit-2 gens:", st, raw[:300])
save("stepfun_image_edit.json", {"status": st, "response": raw.decode("utf-8", "replace")[:2000]})

# stepaudio tts (chat shape)
st, h, raw = call(sf + "/chat/completions", sfk, {
    "model": "stepaudio-2.5-tts",
    "messages": [{"role": "user", "content": "你好，世界。"}], "stream": False})
print("stepaudio tts:", st, raw[:300])
save("stepfun_audio_tts.json", {"status": st, "response": raw.decode("utf-8", "replace")[:4000]})

# stepaudio asr (chat shape with input_audio)
import base64, struct, math
sr = 16000
frames = b"".join(struct.pack("<h", int(3000 * math.sin(2 * math.pi * 440 * i / sr))) for i in range(sr // 2))
wav = b"RIFF" + struct.pack("<I", 36 + len(frames)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, sr, sr * 2, 2, 16) + b"data" + struct.pack("<I", len(frames)) + frames
st, h, raw = call(sf + "/chat/completions", sfk, {
    "model": "stepaudio-2.5-asr",
    "messages": [{"role": "user", "content": [{"type": "input_audio", "input_audio": {"data": "data:audio/wav;base64," + base64.b64encode(wav).decode()}}]}],
    "stream": False})
print("stepaudio asr:", st, raw[:300])
save("stepfun_audio_asr.json", {"status": st, "response": raw.decode("utf-8", "replace")[:4000]})
print("PROBE3 DONE")
