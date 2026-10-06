# Janus next-phase design spec audit — multi-model synthesis

Date: 2026-10-05 (round 4)
Models (via `pi`): MiniMax-M3, MiMo v2.6-pro, Step-5-preview, Qwen3.8-max, DeepSeek-v4.1-flash, GLM-5.3, Kimi k3
Raw replies: docs/audit/archive/2026-10-05-r4/*.txt

## Verdicts

| Model | Verdict |
|---|---|
| MiniMax-M3 | GO WITH FIXES (404 vs missing-model, late input_tokens, empty-diff wait) |
| MiMo v2.6-pro | GO WITH FIXES (finalize flush, idle inactivity, leftover constant) |
| Step-5-preview | GO WITH FIXES (janus-auto failed, no-role message_start) |
| Qwen3.8-max | GO WITH FIXES (message_start guarantee, include_usage 400-only) |
| DeepSeek-v4.1-flash | GO WITH FIXES (error origin, janus-auto failed, max_tokens) |
| GLM-5.3 | GO WITH FIXES (Chat→Anthropic input_tokens, usage-on-any-chunk, leftover owner) |
| Kimi k3 | GO WITH FIXES (`./rebar3` PATH, finalize flush, 400 vs 502 row) |

**Overall: GO WITH FIXES (7/7).** New holes applied for round 5.

## Consensus / near-consensus applied

1. Post-200 `translate_unsupported` = 502; 400 = `n>1` only.
2. `finalize_sse(normal)` flushes pending stop/usage then terminator.
3. Chat→Anthropic `message_start` on first chunk; role optional.
4. janus-auto inner calls do not bump failed; failed = client-visible.
5. `rebar3` on PATH; leftover one 1 MiB constant; usage on any Chat chunk.
6. `include_usage` retry 400 once; `max_tokens` default 4096.
7. Empty config diff skips generation wait.

## Split (not applied)

- Gateway keepalive timer: still no.
- Separate abort counter: still no (disconnect = 502).
