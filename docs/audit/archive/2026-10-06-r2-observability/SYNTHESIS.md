# Observability plan audit, round 2 — multi-model synthesis

Date: 2026-10-06 (round 2)
Models (via `pi`): MiniMax-M3, mimo-v26-pro, step-5-preview, qwen3.8-max, glm-5.3, kimi-k3
Raw replies: docs/audit/*.txt (round 1: docs/audit/archive/2026-10-06-r1-observability/)
Target: `docs/superpowers/plans/2026-10-06-observability-metrics-request-ids.md` rev 2

## Verdicts

| Model | Verdict |
|---|---|
| kimi-k3 | GO WITH FIXES — contracted dropped-counter series never renders; stale tid after restart |
| minimax-m3 | GO WITH FIXES — dropped counter silently dropped; re:run test syntax error |
| mimo-v26-pro | GO WITH FIXES — tid lifecycle contradicts the plan's own key fact |
| stepfun-5 | GO WITH FIXES — hist renderer returns only _count (comma sequence) |
| qwen38-max | GO WITH FIXES — TYPE info invalid under text/0.0.4; buckets not zero-filled |
| glm-53 | GO WITH FIXES — renderer fails its own eunit; drops a locked series |
| deepseek-v41-flash | — (empty reply, 4th consecutive provider failure — excluded) |

**Overall: GO WITH FIXES (6/6).** Round-1 items confirmed resolved by all. Round-2 findings cluster on my rev-2 rewrite itself: the renderer's hardcoded family list (drops `usage_writer_dropped_total` despite it being in the naming contract), a comma-sequence returning only `_count` per histogram series, and the PT-cached tid dying with the app master on restart.

## Consensus (≥4 models) — fixed in rev 3

1. **Hardcoded renderer family list (6/6).** → Registry-driven rendering (`?FAMILIES` name → {type, help}); counter families derived from rows; unregistered families still render (no silent drops); `x_total` test-cruft removed.
2. **Histogram series body returned only `_count`** (comma sequence bug) → single concatenated iolist.
3. **Buckets not zero-filled** → canonical ladder emitted (13 bounds + +Inf) with zero fill; exact-output test.
4. **Stale tid after app restart** → `ets:whereis(?TABLE)` per bump (no PT lifecycle trap); `init/0` idempotent on `ets:info`; `snapshot/0` guarded.
5. **`# TYPE ... info` invalid under text/0.0.4** → build_info is `untyped`.
6. **Task 4 handler self-contradicting code** (unused `LbGauges`, double `janus_lb:stats/0`) → rewritten: one call, LB counters through the renderer as `lb_stat`, 405 on non-GET, `safe/2` logs failures, pre-coding verification step for every scrape-time source.
7. **Gate gaps** → asserts gauges non-zero on the seeded stack + `usage_writer_dropped_total` presence + content-type substring + notes metrics bump synchronously (only the usage row needs the poll).

## Near-consensus (fixed in rev 3)

- `observe/3` guard crash before try → whole-body try/catch + `max(0.0, Seconds)` + total `to_bin/1`; `re:run` options typo in the request-id test; escape strips NUL.
- Auth-reject `request_id` field timing (lands in Task 6) noted explicitly.
- Deploy order: gateway (migration 005) before dashboard read-path change.
- 404/unrouted paths documented (no handler → no id, uncounted).
- `upstream_requests_total` semantics (terminal outcomes per provider, failover attempts excluded) moved into the HELP text.

## Dismissed after review

- **`render_hist_series` reverse-order claim** (minimax in round 1 re: trim code) — n/a here; the comma-sequence bug was the real one.
- **`statistics(wall_clock)` side effects** — the total element is what we read; harmless.

## Applied to doc

All items folded into the plan as **rev 3** (inline). Round 3 runs next.
