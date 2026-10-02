#!/usr/bin/env python3
"""Probe seed provider keys. Prints status only; never full secrets."""
from __future__ import annotations

import json
import ssl
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
seed = json.loads((ROOT / "data" / "seed.providers.json").read_text(encoding="utf-8"))
ctx = ssl.create_default_context()

for p in seed["providers"]:
    for i, key in enumerate(p["keys"], 1):
        model = p["models"][0]
        url = p["base_url"].rstrip("/") + "/chat/completions"
        body = json.dumps(
            {
                "model": model,
                "messages": [{"role": "user", "content": "ping"}],
                "max_tokens": 8,
                "stream": False,
            }
        ).encode()
        req = urllib.request.Request(
            url,
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {key}",
                "Content-Type": "application/json",
            },
        )
        prefix = key[:8]
        try:
            with urllib.request.urlopen(req, timeout=45, context=ctx) as resp:
                raw = resp.read()[:140].decode("utf-8", "replace").replace("\n", " ")
                raw = raw.encode("ascii", "replace").decode("ascii")
                print(f"{p['name']}\tkey#{i}({prefix}..)\t{model}\tHTTP {resp.status}\t{raw}")
        except urllib.error.HTTPError as e:
            raw = e.read()[:140].decode("utf-8", "replace").replace("\n", " ")
            raw = raw.encode("ascii", "replace").decode("ascii")
            print(f"{p['name']}\tkey#{i}({prefix}..)\t{model}\tHTTP {e.code}\t{raw}")
        except Exception as e:  # noqa: BLE001
            msg = str(e).encode("ascii", "replace").decode("ascii")
            print(f"{p['name']}\tkey#{i}({prefix}..)\t{model}\tERR\t{type(e).__name__}: {msg}")
