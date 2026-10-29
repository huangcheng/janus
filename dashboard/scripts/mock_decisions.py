#!/usr/bin/env python
"""Loopback OpenAI Decisions / Aliyun System One mock for local Janus smokes.

Serves both path shapes the gateway may call:
  POST /v1/decisions   (OpenAI Decisions)
  POST /v1/systemone   (Aliyun MaaS / DashScope Decision models)
  POST /decisions      (base_url already ends with /v1 → join may omit extra /v1)
  POST /systemone

Body contract (System One):
  { "model", "state": {...}, "questions": { "<id>": { "type":"choice", ... } } }

Response:
  { "id", "model", "answers": { "<id>": { "choice": "<label>" } }, "usage": {...} }

Tier pick: if state.user_prefix contains "hard" → flagship; "simple" → fast; else big.
Any other Bearer than mock-decisions-key → 401.

Run:
  ./.venv/Scripts/python.exe scripts/mock_decisions.py
  # or: python scripts/mock_decisions.py  (port via MOCK_DECISIONS_PORT, default 8098)
"""

from __future__ import annotations

import os
import uuid

import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

app = FastAPI(title="mock-decisions")
EXPECTED = os.environ.get("MOCK_DECISIONS_KEY", "mock-decisions-key")


def _pick_tier(state: dict) -> str:
    user = str((state or {}).get("user_prefix") or "").lower()
    if "hard" in user or "flagship" in user:
        return "flagship"
    if "simple" in user or "fast" in user:
        return "fast"
    return "big"


def _answer(body: dict) -> dict:
    model = body.get("model") or "decision-model-preview"
    state = body.get("state") if isinstance(body.get("state"), dict) else {}
    questions = body.get("questions") if isinstance(body.get("questions"), dict) else {}
    tier = _pick_tier(state)
    answers: dict = {}
    for qid, q in questions.items():
        if not isinstance(q, dict):
            continue
        if q.get("type") == "choice":
            criteria = q.get("criteria") if isinstance(q.get("criteria"), dict) else {}
            # Prefer a configured label; fall back to tier / first key.
            choice = tier if tier in criteria or not criteria else next(iter(criteria))
            if tier in criteria:
                choice = tier
            answers[qid] = {"choice": choice}
        else:
            answers[qid] = {"text": "ok"}
    if not answers:
        answers["tier"] = {"choice": tier}
    return {
        "id": f"dec_{uuid.uuid4().hex[:12]}",
        "model": model,
        "answers": answers,
        "usage": {"input_tokens": 12, "output_tokens": 1, "total_tokens": 13},
    }


async def _handle(request: Request) -> JSONResponse:
    auth = request.headers.get("authorization") or ""
    if auth != f"Bearer {EXPECTED}":
        return JSONResponse(
            {"error": {"code": "invalid_api_key", "message": "bad key"}},
            status_code=401,
        )
    try:
        body = await request.json()
    except Exception:
        return JSONResponse(
            {"error": {"code": "invalid_json", "message": "body must be JSON"}},
            status_code=400,
        )
    if not isinstance(body, dict):
        return JSONResponse(
            {"error": {"code": "invalid_json", "message": "body must be object"}},
            status_code=400,
        )
    return JSONResponse(_answer(body))


for path in ("/v1/decisions", "/v1/systemone", "/decisions", "/systemone"):
    app.add_api_route(path, _handle, methods=["POST"])


@app.get("/healthz")
def healthz():
    return {"ok": True}


if __name__ == "__main__":
    port = int(os.environ.get("MOCK_DECISIONS_PORT", "8098"))
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="info")
