# Janus next-phase design spec audit — multi-model synthesis

Date: 2026-10-05 (round 1)
Models (via `pi`): MiniMax-M3, MiMo v2.6-pro, Step-5-preview, Qwen3.8-max, DeepSeek-v4.1-flash, GLM-5.3, Kimi k3
Raw replies: docs/audit/archive/2026-10-05-r1/*.txt

## Verdicts

| Model | Verdict |
|---|---|
| MiniMax-M3 | GO WITH FIXES (CRLF, generation wait, error frames, tools) |
| MiMo v2.6-pro | GO WITH FIXES (SSE contract, counters, image command) |
| Step-5-preview | GO WITH FIXES (SSE unpinned, usage placement, docker recipes) |
| Qwen3.8-max | GO WITH FIXES (usage inject, mid-stream, tools state machine) |
| DeepSeek-v4.1-flash | GO WITH FIXES (mapping table, total vs failed, volume) |
| GLM-5.3 | GO WITH FIXES (event mapping, crash accounting, `[DONE]`) |
| Kimi k3 | GO WITH FIXES (SSE table, bump points, stage naming) |

**Overall: GO WITH FIXES (7/7).** No NO-GO. Spec was not implementable as written; consensus edits applied before round 2.

## Consensus (≥5 models)

1. **Bidirectional SSE event-mapping table (7/7).** Added §4.1.3 including ping skip, envelopes, thinking, stop↔finish, `[DONE]` vs `message_stop` by **client** protocol.
2. **Mid-stream error frames + exactly one terminal (7/7).** §4.1.4 table; HTTP stays 200 after headers; `finalize_sse/3`; gun cancel on disconnect.
3. **`translate_sse` is a stateful fold (6/7).** `#sse_st{}` + `translate_sse/4`; diagram name unified.
4. **`include_usage` / usage merge (6/7).** Inject on OpenAI upstream; merge Anthropic `message_start`+`message_delta`; synthesize Chat terminal usage chunk.
5. **Docker command contradicted named volume (7/7).** Exact `docker run` with `-v janus-ebin-otp27:/app/_build`; no `rebar3 get-deps`; unify stage `test` vs AGENTS.md `build`.
6. **Counter funnel (7/7).** Client-call unit; total at `do_proxy` enter; failed via `track` ≥400 + crash `after`; 401/invalid JSON excluded; `failed <= total`; 404 unknown-model counts both; janus-auto = 1; atomics created at app start.
7. **Deploy wait numbers (6/7).** 2s poll, 300s deadline, two consecutive equal generations, halt (no skip, no rollback).

## Split opinions (do not auto-apply)

- **Streaming tools in Phase 1:** MiniMax suggested a mapping table *or* drop; Qwen/DeepSeek/GLM/Kimi said non-stream ≠ stream. **Owner = this revision:** drop streaming tools from Phase 1 A (400 before upstream). Full tool SSE is a future spec.
- **256 KB backpressure buffer:** MiniMax + Qwen only. **Kept out** of Phase 1 (Cowboy/gun as today + cancel on disconnect).
- **Thinking `signature` for Anthropic clients:** MiMo only. **Documented unsupported** in Phase 1.
- **Skip-after-N dead follower vs halt:** MiniMax skip vs Kimi halt. **Halt** (do not skip).
- **Keepalive during thinking gaps:** MiMo only. **Accepted idle_timeout risk.**
- **OTP-versioned volume name:** Qwen. **Applied** (`janus-ebin-otp27`) as cheap.

## Applied to doc

See `docs/superpowers/specs/2026-10-05-next-phase-design.md` (round 2 snapshot in `docs/audit/target.md` after archive).
