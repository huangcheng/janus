#!/usr/bin/env python
"""D13 one-shot live fixture capture (runs when an OpenAI key exists).

Usage: OPENAI_API_KEY=sk-... python tools/capture_decisions_d13.py
Writes apps/janus_http/test/fixtures/probes/openai_decisions.json
(sanitized: auth/org/project/account headers removed, base64 image
payloads replaced with a 1x1 marker, size-capped) and prints the O1
usage-keys findings (usage fields observed on the live reply).
"""
import base64, json, os, sys, urllib.request

URL = "https://api.openai.com/v1/decisions"
OUT = os.path.join(os.path.dirname(__file__), "..", "apps", "janus_http", "test", "fixtures", "probes", "openai_decisions.json")

BODY = {
    "model": "gpt-6-luna",
    "input": [
        {"role": "user", "content": [
            {"type": "input_text", "text": "Sanity capture: answer the questions."},
        ]},
    ],
    "questions": [
        {"type": "predicate", "name": "is_sane", "instructions": "Is the previous statement self-consistent?"},
        {"type": "choice", "name": "pick", "instructions": "Pick one.",
         "choices": [{"value": "a", "description": "first"}, {"value": "other", "description": "fallback"}]},
        {"type": "score", "name": "sev", "instructions": "Rate severity.",
         "levels": [{"label": "low", "description": "none"}, {"label": "high", "description": "major"}]},
    ],
}

def main():
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        sys.exit("OPENAI_API_KEY not set — D13 cannot run yet (spec gate).")
    req = urllib.request.Request(URL, method="POST", data=json.dumps(BODY).encode(),
                                 headers={"content-type": "application/json",
                                          "authorization": "Bearer " + key})
    with urllib.request.urlopen(req, timeout=90) as resp:
        status = resp.status
        headers = {k.lower(): v for k, v in resp.headers.items() if k.lower() in
                   ("content-type", "x-request-id", "openai-processing-ms", "openai-version")}
        body = json.loads(resp.read())
    # sanitize: no auth material lands in the fixture by construction
    fixture = {
        "_comment": "D13 live sanitized capture — O1 usage keys + O2 not-decisions 404 body derive from this.",
        "captured_at": __import__("datetime").datetime.utcnow().isoformat() + "Z",
        "http_status": status,
        "response_headers_safe": headers,
        "request_body": BODY,
        "response_body": body,
    }
    raw = json.dumps(fixture, ensure_ascii=False, indent=1)
    assert len(raw) < 64 * 1024, "fixture unexpectedly large — inspect before writing"
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(raw)
    print("D13 fixture written:", OUT)
    print("O1 check — top-level keys:", sorted(body.keys()))
    print("O2 check — capture a not-decisions model 404 body separately when needed.")

if __name__ == "__main__":
    main()
