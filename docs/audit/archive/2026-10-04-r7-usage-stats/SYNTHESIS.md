# Usage-statistics plan audit, round 5 — multi-model synthesis

Date: 2026-10-04 (round 5)
Models (via `pi`): MiniMax-M3, mimo-v26-pro, step-5-preview, qwen38-max, glm-5.3, kimi-k3
Raw replies: docs/audit/*.txt (round 4: docs/audit/archive/2026-10-04-r6-usage-stats/)
Target: `docs/superpowers/plans/2026-10-04-usage-statistics.md` rev 5

## Verdicts

| Model | Verdict |
|---|---|
| kimi-k3 | GO WITH FIXES — round-4 credibly resolved; avg claim vs code + small defects |
| minimax-m3 | **NO-GO** — `proc_lib:spawn/1` + trim reverse-order claim + avg regression |
| mimo-v26-pro | GO WITH FIXES — two real code bugs + stale self-claims |
| stepfun-5 | GO WITH FIXES — disconnect loses the row; log flood; stale claims |
| qwen38-max | GO WITH FIXES — hot-path defects; trim not O(1) past cap |
| glm-53 | GO WITH FIXES — five small defects, none blocking |
| deepseek-v41-flash | — (reply lost: provider returned empty 3× running; excluded) |

**Overall: GO WITH FIXES (5/6), 1 NO-GO.** The NO-GO's headline item (`proc_lib:spawn/1` doesn't exist) is contested — `proc_lib:spawn/1` is a real export — but rev 6 switches to `erlang:spawn/1` anyway to end the debate. Its second item (trim reverse-order) was re-traced and is **wrong**: the fold over newest-first input with prepend yields oldest-first, and the final `lists:reverse` restores newest-first exactly as the test expects. The avg-null-on-empty regression it also flagged was real (claimed in rev 5's history but never coded).

## Consensus (≥4 models)

1. **avg null-on-empty claimed but not coded** (5/6) → rev 6: COALESCE dropped on both AVG columns, `num_or_null`, error branch returns null, SPA types `number | null`.
2. **Stale test counts / step numbering** (4/6) → "All 13 tests", Task 6 renumbered, E2E asserts non-null FK ids.
3. **`maybe_trim` chunk-cap keeps stale Size** (3/6) → recomputed after `lists:sublist`.
4. **Disconnect can still lose the row** (`ok = stream_body(fin)` before `track`) (2–3/6) → rev 6: `track`/`note_*` hoisted above the fin frame, `_ =` on the fin call too.
5. **Writer-down drops invisible / mailbox-full log flood** (3/6) → drops counted in atomics; warning throttled to 1st + every 1000th.

## Near-consensus (fixed in rev 6)

- **Filter ids < 1 clamped to 1** (glm) → rejected with 400.
- **Zero-fill bucket misalignment** (kimi) → `usage_window` floors `ts_from` to the bucket boundary.
- **`key_id_of` badmatch without `id`** (minimax) → fallback clause; **`is_map(Agent)` guard** (qwen).
- **p95 `is_integer(Count)` guard too strict for driver-returned binaries** (mimo) → relaxed via `num/1`.
- **`(stream, latency_ms)` index for the p95 sort** (3/6) → added to both migrations.
- **Kill switch undocumented** (mimo, qwen) → Task 9 Step 2b (local.env.example + DASHBOARD.md).
- **`openai_responses` injection question** (minimax) → documented: not needed (dialect always terminates with `response.completed` carrying usage).
- **502 conflates client-abort with upstream failure** (glm) → documented in the migration status comment + page note.

## Dismissed after review

- **`proc_lib:spawn/1` doesn't exist** (minimax) — it does exist (proc_lib exports spawn/1); switched to `erlang:spawn/1` regardless, worker body wrapped in try/catch.
- **Trim reverse-order bug** (minimax) — re-traced; implementation and test agree (newest-first in, newest-first out).
- **Regex fallback skipped when any line decodes** (kimi, glm, qwen) — pathological overlap case; documented caveat.
- **Cache-token separate columns** (qwen) — folded into prompt_tokens by design; documented.
- **Injection default true changes wire behavior** (qwen) — intended feature behavior; now operator-documented with a kill switch.

## Applied to doc

All items folded into `docs/superpowers/plans/2026-10-04-usage-statistics.md` as **rev 6** (committed `705b5ce`). Round 6 runs for final approval.
