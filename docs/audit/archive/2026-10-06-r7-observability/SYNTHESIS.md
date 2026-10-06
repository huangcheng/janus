# Observability plan audit, round 7 — multi-model synthesis

Date: 2026-10-06 (round 7)
Models (via `pi`): MiniMax-M3, mimo-v26-pro, step-5-preview, qwen3.8-max, deepseek-v4-pro, glm-5.3, kimi-k3
Raw replies: docs/audit/*.txt (round 6: docs/audit/archive/2026-10-06-r6-observability/)
Target: `docs/superpowers/plans/2026-10-06-observability-metrics-request-ids.md` rev 7

## Verdicts

| Model | Verdict |
|---|---|
| kimi-k3 | GO WITH FIXES — sum fixture contradicts [short] float semantics; duplicate macro block |
| minimax-m3 | GO WITH FIXES — shape-test position typo; duplicate define; transaction verify |
| mimo-v26-pro | GO WITH FIXES — duplicate define/comment (epp rejects macro redefinition); 005 leftover |
| stepfun-5 | GO WITH FIXES — factual leftovers (005, position 19, commit-list); ladder dual-source |
| qwen38-max | GO WITH FIXES — handler shape reads outside try; 005 leftover; to_bin catch-all missing |
| deepseek-v4-pro | GO WITH FIXES — duplicate define; 005 leftover; commit-list contradiction; to_bin not total |
| glm-53 | GO WITH FIXES — mixed fixture isn't production-shaped; encode_unsigned/2 misuse badargs |

**Overall: GO WITH FIXES (7/7).** No structural or correctness concerns remain. The panel fully converged on a small set of mechanical leftovers from my own splice edits: the duplicated `-define(TABLE)`/comment block, the 005→009 renumber's missed instance, the shape-test arithmetic (status is 8/24, not 19), and the fallback's `encode_unsigned/2` misuse (its second arg is endianness, not pad size — glm's catch would badarg the fallback).

## Fixed in rev 8

- Duplicate `-define(TABLE)` + duplicated comment block deleted; ladder single-sourced (`buckets/0` derives from `?BUCKETS_DESC`).
- Task 7 deploy-order note: 009.
- Shape-test positions: `status` 8 (row 1) / 24 (row 2), `request_id` 16/32; Task 6 commit list no longer references the nonexistent `janus_usage_sql_tests.erl`.
- `generate/0` fallback pads via `<<I:64/big>>` (16 hex chars, both branches).
- `to_bin/1` catch-all (`<<"unknown">>`) + error-tuple guard on the unicode path; renderer's `to_bin` delegates to the registry's (one coercion implementation).
- Handler `maps:get`/`maps:to_list` moved inside the render try.
- Gate: 4b pins the client-dialect label set on translate paths; promtool presence verified at gate-image build; quiescent `_sum`/`+Inf` consistency line.
- Mixed-snapshot fixture rewritten production-shaped (one 30s observation → suffix ladder, sum 30.0 — unambiguous under `[short]`).

## Dismissed after review

- **minimax's token-rotation ordering** — covered by the rev-6 ops note (update scrape token file, then restart the node, one at a time).
- **kimi's `statistics(wall_clock)` concern** — the gauge reads element 1 only; the SinceLastCall element has no other consumer (grep-verified at implementation per the pre-coding step).

## Applied to doc

All items folded into `docs/superpowers/plans/2026-10-06-observability-metrics-request-ids.md` as **rev 8** (committed `0ae8c57`). Round 8 runs for final approval.
