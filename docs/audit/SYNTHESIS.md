# Janus multi-protocol gateway plan audit — multi-model synthesis

Date: 2026-10-04
Models (via `pi`): MiniMax-M3, mimo-v2.6-pro, step-5-preview, qwen3.8-max, deepseek-v4-1-flash, glm-5.3, kimi-k3
Raw replies: docs/audit/*.txt (previous rounds: docs/audit/archive/)

## Verdicts

| Model | Verdict |
|---|---|
| minimax-m3 | GO WITH FIXES — harden x-api-key, tools, SSE, field-drop policy |
| mimo-v26-pro | GO WITH FIXES — under-specified lossy mappings / error envelopes / headers |
| stepfun-5 | GO WITH FIXES — exact enum match, Anthropic fields, error dialect, SSE cooldown |
| qwen38-max | GO WITH FIXES — translation contract + SSE ops + auto native-first |
| deepseek-v41-flash | GO WITH FIXES — field-level translate, error contracts, streaming failure |
| glm-53 | GO WITH FIXES — tool/field maps, streaming ops, error dialect, auth |
| kimi-k3 | GO WITH FIXES — max_tokens/tools/system/SSE/auth underspecified |

**Overall: GO WITH FIXES.** Architecture is accepted; ship blockers are contract-level (auth headers, field maps, client error envelopes, SSE lifecycle), not the native/translate split.

## Consensus (≥5 models)

1. **Auth header hygiene (7/7).** Client `x-api-key` / `Authorization` terminate at Janus as agent auth only; never forward to upstream. Anthropic adapter injects catalog credential + `anthropic-version`. Define precedence when both Bearer and `x-api-key` are present.
2. **Normative field-mapping table (7/7).** Especially: Anthropic-required `max_tokens` (inject default or 400), system → top-level `system`/`instructions`, `stop`↔`stop_sequences`, `finish_reason`↔`stop_reason` (incl. tool_calls↔tool_use), usage key remap. Unmapped → `translate_unsupported` 400, not silent drop.
3. **Per-client error envelopes (7/7).** Janus/local and re-shaped upstream errors must match client dialect (OpenAI `{error:{…}}` vs Anthropic `{type:"error",…}`). Translate-path 400s must not cool down providers.
4. **Native SSE lifecycle (7/7).** Spec mid-stream upstream failure after HTTP 200, client disconnect → cancel gun, cooldown triggers (status line and/or terminal SSE error events), Cowboy `stream_reply` + `text/event-stream`.
5. **Basic tools = concrete rules (6–7/7).** `arguments` JSON-string ↔ `input` object; stable id rewrite; tool_use↔tool_result pairing; `tool_choice` allowlist; parallel order preserved; malformed args → 400.
6. **Exact protocol enum + default (5–6/7).** Match is `openai_chat|openai_responses|anthropic_messages` only (chat ≠ responses); missing protocol defaults to `openai_chat`; unknown → 400/502, not crash.
7. **Auto-router native-first (5/7).** After tier pick, if provider protocol matches client, passthrough (incl. stream); translate only when mismatch — do not force chat-pivot when native is available.
8. **Responses statefulness (5/7).** Force `store: false` on translate/native gateway path as needed; 400 `previous_response_id` / `background` (and similar stateful fields).

## Split opinions (do not auto-apply)

- **messages↔responses path:** some prefer chat-pivot (smaller matrix); others prefer direct maps to avoid double loss. → **decision owner = user**
- **Auth when Bearer and x-api-key both set and disagree:** Bearer-wins vs 401. → **decision owner = user**
- **Vision/image in translate:** enumerate allowlist vs hard-400 all non-text. → **decision owner = user**
- **Multi-endpoint providers** (same base_url offering chat+responses): catalog today is one `protocol` per provider — models suggesting dual-native are out of scope unless schema changes. → **rejected vs ground truth** (single protocol column); keep one protocol per provider.
- **Model aliasing** (claude-* client name → openai_chat upstream id): only a minority raised; catalog already has `upstream_model_id` for rename. → **near-consensus reject as new feature**; rely on existing route `upstream_model_id`.

## Applied to doc

Consensus items folded into the Cursor plan (`multi-protocol_gateway_*.plan.md`) under new "Audit fixes (v1 contracts)" section. Splits left for user decision before implementation.
