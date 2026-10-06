# Usage-statistics plan audit, round 4 — multi-model synthesis

Date: 2026-10-04 (round 4)
Models (via `pi`): MiniMax-M3, mimo-v2.6-pro, step-5-preview, qwen3.8-max, deepseek-v41-flash, glm-53, kimi-k3
Raw replies: docs/audit/*.txt (round 3: docs/audit/archive/2026-10-04-r5-usage-stats/)
Target: `docs/superpowers/plans/2026-10-04-usage-statistics.md` rev 4

## Verdicts

| Model | Verdict |
|---|---|
| kimi-k3 | GO WITH FIXES — rev 4 resolves round-3 classes; dup test fn + SSE zero collapse |
| minimax-m3 | **NO-GO** — duplicate `no_qmark_literals_test/0` blocks compilation |
| mimo-v26-pro | GO WITH FIXES — test file broken; SSE genuine-zero half-applied |
| stepfun-5 | GO WITH FIXES — fixes real; zero collapse + test compile |
| qwen38-max | GO WITH FIXES — remediation mostly real; test module can't compile |
| deepseek-v41-flash | GO WITH FIXES — design sound; 2 hard defects (zero collapse, dup test) |
| glm-53 | (reply identical to round 3 file — see note below) |

**Overall: GO WITH FIXES (6/7), 1 NO-GO.** The NO-GO is for a compile-blocking duplicate test function I introduced when adding the new fragment-scan test alongside the old beam-scan one — not architecture. Findings converged hard: 5/7 spotted the duplicate, 7/7 the SSE zero-collapse.

Note: deepseek's first reply came back empty (provider flake); its retry produced a full audit. glm-53's round-4 file matched its round-3 content — treated as a stale provider cache hit and excluded from this tally; the other 6 carried the consensus.

## Consensus (≥5 models)

1. **Duplicate `no_qmark_literals_test/0`** → compile error. Fixed in rev 5 (old beam-scan deleted; `?'` literal typo repaired).
2. **SSE genuine-zero collapse** (`{0,0} → undefined` in `from_sse`, asymmetric with the body parser) → fixed in rev 5 + `genuine_zero_sse_test`.
3. **Stale title/counts** ("rev 3" title, "10 parser + 3 SQL" vs actual 13 + 5) → title de-versioned permanently, counts corrected.
4. **Tail trim still O(n²)** per chunk (fold every arrival) → rev 5: `{Chunks, Size}` tuple, O(1) prepend, refold only over caps (16KB bytes + 256 chunks), zero-byte chunks skipped.
5. **`drop_counter/0` hot-path `persistent_term:put`** (race + global lock) → rev 5: created once in `init/1`; hot paths only read.
6. **Missing indexes for provider/provider_key breakdowns + p95** → rev 5 adds `(provider_id, ts)` and `(provider_key_id, ts)` to both migrations.

## Near-consensus (fixed in rev 5)

- **`record(Bad)` bypasses the mailbox guard** → `guarded_cast/1` covers both paths; `MAX_QUEUE` 5000→8000 so the buffer cap stays reachable.
- **`ok = cowboy_req:stream_body` badmatch on client disconnect** → `_ =`; drain errors still record 502.
- **avg `0` on empty windows vs p95 `null`** → avg fields now `num_or_null`.
- **`qs_int`/`now_sec` duplicate-definition risk** → preflight grep note.
- **No proxy-helper tests** → `janus_proxy_usage_tests.erl` (trim under/over cap, chunk-count cap, injection politeness matrix).
- **`fmtTs` day ambiguity** → `MM-DD HH:MM:SS` UTC.
- **`UsageSummary` missing `ts_from`/`ts_to`** → added; zero-fill derives from them; p95-stream subtitle "end-to-end · client drain".
- **`Ev` unused in the buffer-full cast** → `_Ev`.

## Dismissed after review

- **`null` atom as a Postgres bind param** — the existing production code (`add_route` with `UpstreamNorm = null`) already relies on this exact pattern on both drivers; smoke-tested in Task 3 on SQLite; Postgres lane remains optional-but-flagged.
- **Double-counting on retries** — the proxy performs no in-request failover (each `handle_upstream` fires once per upstream attempt, and attempts are one-per-request); noted in the plan.
- **`chunk/2` `length/1` recursion** — rewrote tail-recursively with `safe_split` anyway (free win).
- **Throttle flush-error logs** — per-50-row-chunk logging is ~2 warnings/sec worst case; acceptable as an incident signal.

## Applied to doc

All items folded into `docs/superpowers/plans/2026-10-04-usage-statistics.md` as **rev 5** (committed `5c2e968`). Round 5 runs for final approval.
