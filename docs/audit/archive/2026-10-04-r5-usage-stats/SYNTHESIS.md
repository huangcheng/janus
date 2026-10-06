# Usage-statistics plan audit, round 3 — multi-model synthesis

Date: 2026-10-04 (round 3)
Models (via `pi`): MiniMax-M3, mimo-v2.6-pro, step-5-preview, qwen3.8-max, deepseek-v41-flash, glm-5.3, kimi-k3
Raw replies: docs/audit/*.txt (round 2: docs/audit/archive/2026-10-04-r4-usage-stats/)
Target: `docs/superpowers/plans/2026-10-04-usage-statistics.md` rev 3

## Verdicts

| Model | Verdict |
|---|---|
| minimax-m3 | GO WITH FIXES (upgraded from round-2 NO-GO) — structurally sound now |
| mimo-v26-pro | GO WITH FIXES — Task 7 filter code broken as written |
| stepfun-5 | GO WITH FIXES — verified injection/CL against repo; mailbox unbounded |
| qwen38-max | GO WITH FIXES — spine sound; 4 code-level defects ship broken |
| deepseek-v41-flash | GO WITH FIXES — filters dead, reads crash on DB error |
| glm-53 | GO WITH FIXES — fixes inlined credibly; filter bug + vacuous test |
| kimi-k3 | GO WITH FIXES — round-1/2 credibly resolved; 2 functional defects |

**Overall: GO WITH FIXES (7/7).** The round-2 structural objection (addendum vs task bodies) is resolved — minimax explicitly upgraded from NO-GO. Findings are now code-level and localized; no architectural objections remain. stepfun independently verified the repo claims (migration numbering, FK parents in 001, adapter re-encodes body → Content-Length consistent).

## Consensus (≥5 models)

1. **Task 7 `maps:filter` misuse (4–7/7).** Predicate returns non-boolean → crash/no-op; keys/values never match `recent_filters`. Drill-down is dead code. → **rev 4: explicit fold building `#{key_id => Int}`, 400 on unparseable input.**
2. **Read path badmatch → 500 (6/7).** `{ok, Rows} = q(...)` in all rollups. → **rev 4: every read function is total; DB error logs + returns empty aggregate/null.**
3. **`no_qmark_literals_test` vacuous (7/7).** Asserts only a file attribute exists. → **rev 4: real scan over all emitted SQL fragments + `build_insert`/`chunk` eunit.**
4. **Genuine `{0,0}` usage collapses to "unreported" (4/7).** → **rev 4: `has_known_key/1` — a usage object with any recognized key is a real report.**
5. **Task 4 Step 5 hedged expectation (5/7).** → **rev 4: definitive — NULL concat yields NULL in both dialects; `(deleted)` label by design.**

## Near-consensus (fixed in rev 4)

- **avg latency not split by stream** (scope promise) → `avg_latency_ms` (non-stream) + `avg_stream_ms`; `unreported` counts successes only.
- **Writer mailbox unbounded under stalled DB** → `record/1` checks `message_queue_len`, drops with an atomics counter surfaced in `writer.dropped`; drop logs throttled (1st + every 1000th); supervisor shutdown 5000→15000 for the terminate flush.
- **`capture_usage_chunk` O(n²) tail rebuild** → bounded newest-first chunk list (16KB cap), single `iolist_to_binary` at stream end.
- **Oversized terminal SSE events (`response.completed` > 16KB)** → regex `"usage":{…}` fallback extractor (one nesting level) + eunit.
- **`ceil/1` float worry** → `erlang:ceil/1` (integer) documented.
- **`stats/0` hangs/couples reader to writer** → 1s timeout + `alive` flag; API adds `ts_from`/`ts_to`; page gets zero-filled buckets and a "writer down" badge.
- **`protocol` atom whitelist** (arbitrary atoms would pass to SQL) → whitelist in `proto_bin`.
- **`thoas:encode` iodata** → `iolist_to_binary/1` wrap.
- **Status column doc** → unified (upstream status; 502 mid-stream/upstream failure; 503 provider_disabled; 500 gateway crash).
- **`usage_inject_include_usage` undocumented** → ops note added to page/API docs task.

## Dismissed after review

- **`release_route_inflight` missing in stream ok branch** (kimi): the original code also doesn't release there (inflight is released by the LB success note); plan preserves original behavior — not a regression.
- **Per-chunk-delta under-reporting, head/tail seam decode-skip, breakdown unbounded rows, no p95 latency index, Postgres lane optional** — documented v1 caveats, accepted in self-review.

## Applied to doc

All items folded into `docs/superpowers/plans/2026-10-04-usage-statistics.md` as **rev 4** (inline, committed `b51a599`). Proceeding to round 4 for final approval.
