# Janus next-phase design spec audit — multi-model synthesis

Date: 2026-10-05 (round 2)
Models (via `pi`): MiniMax-M3, MiMo v2.6-pro, Step-5-preview, Qwen3.8-max, DeepSeek-v4.1-flash, GLM-5.3, Kimi k3
Raw replies: docs/audit/archive/2026-10-05-r2/*.txt

## Verdicts

| Model | Verdict |
|---|---|
| MiniMax-M3 | GO WITH FIXES (disconnect detect, 400 vs 502, CRLF) |
| MiMo v2.6-pro | GO WITH FIXES (usage order, SSE lexer, volume shadows compile) |
| Step-5-preview | GO WITH FIXES (Anthropic envelopes, ping, deploy halt vs schema) |
| Qwen3.8-max | GO WITH FIXES (thinking↔text, leftover cap, track vs HTTP) |
| DeepSeek-v4.1-flash | GO WITH FIXES (`skip` drops state, SSE headers, failed guard) |
| GLM-5.3 | GO WITH FIXES (`skip` vs state, envelopes, stop reasons) |
| Kimi k3 | GO WITH FIXES (failed double-count, vacuous generation wait, provider error) |

**Overall: GO WITH FIXES (7/7).** Round-1 tables were not enough; remaining contract holes applied in round 3.

## Consensus (≥5 models)

1. **Anthropic `message_start` full envelope + usage fields (5/7).** Applied.
2. **`translate_sse` must return St on every arm (5/7 counting skip-state).** `{ok, [], St}` only; no bare `skip`.
3. **Finish → usage → `[DONE]` order + delay Anthropic `message_delta` (5/7).** Applied.
4. **SSE lexer: CRLF, multi-line `data:`, comments, leftover cap (5/7).** 1 MiB cap.
5. **Failed increment at most once (5/7).** `janus_stats_failed` flag.
6. **Provider in-band error is 502, not 400 (5/7).** Split rows.
7. **Do not bind-mount repo root over `/app` (5/7).** Mount `apps`+`config` only; rebar3 in `/usr/local/bin`.

## Split opinions (not auto-applied as keepalive-from-scratch)

- **Active keepalive while OpenAI thinking is silent:** 3/7 wanted `: ping` even without provider ping. **Applied only forwarding of provider `ping`**, not a timer.
- **Code-only deploy must bump generation:** Kimi. **Applied alternative:** uptime_sec window instead of fake bump.

## Applied to doc

`docs/superpowers/specs/2026-10-05-next-phase-design.md` round 3.
