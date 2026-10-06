# Janus next-phase design spec audit — multi-model synthesis

Date: 2026-10-05 (round 3)
Models (via `pi`): MiniMax-M3, MiMo v2.6-pro, Step-5-preview, Qwen3.8-max, DeepSeek-v4.1-flash, GLM-5.3, Kimi k3
Raw replies: docs/audit/archive/2026-10-05-r3/*.txt

## Verdicts

| Model | Verdict |
|---|---|
| MiniMax-M3 | GO WITH FIXES (include_usage, janus-auto, volume) |
| MiMo v2.6-pro | GO WITH FIXES (disconnect frames, 400 vs 502, n>1) |
| Step-5-preview | GO WITH FIXES (usage authority, volume, code-only) |
| Qwen3.8-max | GO WITH FIXES (keepalive split, recorded status, tools 400) |
| DeepSeek-v4.1-flash | GO WITH FIXES (sse_events error, EOF, uptime_sec) |
| GLM-5.3 | GO WITH FIXES (sse_events type, after overcount, SPEC passthrough) |
| Kimi k3 | GO WITH FIXES (usage authority, HEX_MIRROR, --code-only) |

**Overall: GO WITH FIXES (7/7).** Residue applied into the spec for round 4; §10 lists closed items so they are not re-opened.

## Consensus (≥5 models)

1. **`sse_events` must have an error return (5/7).** Applied: `{error, leftover_cap}`.
2. **Drain EOF without a client terminal → `finalize_sse(normal)` (5/7).** Applied.
3. **Provider-origin tools after 200 are 502 (5/7).** Applied.
4. **janus-auto inner `do_proxy` must not re-bump total (5/7).** Applied: preset `janus_stats_counted`.
5. **Named volume invalidation + do not mount repo root (6/7).** Applied: `volume rm` + HEX_MIRROR.
6. **Usage row vs client SSE chunk: one authority (5/7).** Applied: row = `capture_usage_chunk`; SSE display from `#sse_st{}`.
7. **`--code-only` vs generation wait (5/7).** Applied: `uptime_sec` window; `uptime_sec` already on `/stats`.
8. **`n>1` cannot be pre-200 on the response (5/7).** Applied: request `n` in 4.1.1; response `n>1` mid-stream.

## Split opinions (do not auto-apply)

- **Gateway keepalive timer (~15s):** Qwen + GLM (~2/7). Keep provider-ping forward only.
- **Split client-abort from `requests_failed`:** GLM + Qwen. Keep disconnect as recorded 502.
- **Hold 200 until first decoded frame:** MiMo. Keep 200 then in-band error.

## Applied to doc

`docs/superpowers/specs/2026-10-05-next-phase-design.md` (round 4 snapshot).
