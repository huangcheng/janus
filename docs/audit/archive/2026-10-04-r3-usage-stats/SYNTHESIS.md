# Usage-statistics plan audit — multi-model synthesis

Date: 2026-10-04
Models (via `pi`): MiniMax-M3, mimo-v2.6-pro, step-5-preview, qwen3.8-max, deepseek-v4-1-flash, glm-5.3, kimi-k3
Raw replies: docs/audit/*.txt (previous rounds: docs/audit/archive/)
Target: `docs/superpowers/plans/2026-10-04-usage-statistics.md` (snapshot: docs/audit/target.md)

## Verdicts

| Model | Verdict |
|---|---|
| minimax-m3 | GO WITH FIXES — Anthropic-SSE parser bug, unbounded buffer, sweep locks |
| mimo-v26-pro | GO WITH FIXES — head capture, writer crash-safety, latency semantics |
| stepfun-5 | GO WITH FIXES — per-row autocommit, stream wall-time "latency", SQL bugs |
| qwen38-max | GO WITH FIXES — Task 3 doesn't compile as written, pdict leak, silent drops |
| deepseek-v41-flash | GO WITH FIXES — protocol gating, per-row writes, unbounded buffer |
| glm-53 | GO WITH FIXES — SQLite p95 broken as written, buffer/abort contradictions |
| kimi-k3 | GO WITH FIXES — injection/Content-Length worries, flush silent loss |

**Overall: GO WITH FIXES (7/7).** Architecture endorsed by all (pure parser + buffered writer + dialect-branched rollups + pdict scratch). Ship blockers are writer failure-safety, SSE capture correctness, and SQL portability — all contract-level, none structural.

## Consensus (≥5 models)

1. **Writer failure-safety (7/7).** Flush clears the buffer even when inserts fail → silent data loss (contradicts the plan's self-review). `maps:get` without defaults crashes the server on a malformed event. `length/1` per cast is O(n). Fix: defaults everywhere + catch-all cast + validate in `record/1`; multi-row batched INSERT in one statement; buffer cap (drop-oldest) with dropped-counter + `logger:warning`; `trap_exit` so `terminate/2` flushes; integer `buf_size` in state.
2. **SSE head capture (6/7).** "First ~4KB" is implemented as first-chunk-only → Anthropic `message_start` input tokens lost when split or delayed. Accumulate head across chunks until 4KB.
3. **Latency semantics (6/7).** Measured span is proxy-entry→terminal = full stream drain for SSE (incl. client backpressure); p95 mixes stream/non-stream populations. Add a `stream` column to migration 004 **now** (retrofit = second migration); document the column as end-to-end proxy duration; p95 may split later.
4. **p95 portability/accuracy (7/7 raised).** PG `percentile_cont` interpolates, SQLite nearest-rank OFFSET diverges; SQLite subquery-in-OFFSET is unverified/fragile; empty window returns 0 instead of null; epgsql may decode `numeric` as binary. Fix: nearest-rank on both (PG `percentile_disc`), SQLite as two queries (count, then parameterized OFFSET), `null` on empty, `num/1` handles binaries.
5. **Batched retention sweep (5/7).** One unbounded 30-day DELETE locks SQLite/Postgres. Loop `DELETE ... WHERE id IN (SELECT id ... LIMIT N)` chunks.
6. **UTC bucket alignment (5/7).** SQLite `strftime` is UTC, PG `date_trunc` uses session TZ, SPA slices labels as-if local. Standardize UTC on both backends (`AT TIME ZONE 'UTC'`) and mark UTC in the UI.
7. **Tests beyond the pure parser (6/7).** Only the parser is TDD'd while dialect SQL and the proxy hook are the riskiest parts. Add: multi-row INSERT builder eunit, dialect bucket-expr eunit, and an E2E cross-protocol + streaming row check (already Task 9 — strengthen it).

## Near-consensus (4/7 — fix anyway)

- **Protocol gating confusion.** Injection/parse appear keyed on `ClientProto` while bytes are provider-dialect. (Review: on the native path `ClientProto == ProviderProto` by construction and translate paths force non-stream, so behavior is correct today — but the plan never states that invariant. State it in code comments; keep the parser dialect-agnostic; note the trap.)
- **`ORDER BY 5` sorts by completion tokens, not requests** — change to requests (column 3).
- **Provider-key breakdown.** `provider_key_id` is stored but never surfaced, while the agreed scope explicitly includes it. Add a `by_provider_key` rollup (join `provider_keys`+`providers` for labels) to the API and page.
- **Stream-error status.** Mid-stream failure records the already-sent 200; record 502 on drain error so error stats aren't polluted.
- **`include_usage` injection politeness.** Honor a client-set `stream_options` (don't override explicit values); add an app-env kill switch (`usage_inject_include_usage`, default on); document that strict upstreams may 400.
- **Drain callback process assumption.** Verify once (the existing `cowboy_req:stream_body` callback already relies on it); erase `janus_usage_ctx/head/tail` at `handle/5` entry to prevent keep-alive cross-request leaks.
- **SQLite `PRAGMA foreign_keys`** — verify `janus_db_conn` enables it, else `ON DELETE SET NULL` is inert (then document instead of relying on it).

## Split opinions (do not auto-apply)

- **Denormalized name snapshots** (`key_prefix`/`model_name` copies) vs `ON DELETE SET NULL` + "(deleted)" labels. Minimax wants snapshots; others accept SET NULL. → **decision: SET NULL for v1** (cheap, revisit if history matters).
- **Flush inside the writer gen_server vs supervised task** (mailbox stall under slow DB). → **v1: in-process multi-row single-statement flush** (fast enough); revisit if Postgres latency proves it.
- **`request_id` correlation + TTFT column** (qwen38-max) vs end-to-end duration only. → **follow-up**, not first-ship.
- **Read-side caching of 24h totals** (deepseek) vs query-on-load. → **v1 uncached**; tables are small under 30-day retention.
- **Content-Length after body re-encode** (kimi, qwen): reviewed — the provider adapter re-encodes the upstream body from the request map and sets its own headers, so no length bug exists; the plan's `Body2` re-encode is redundant and will be dropped from the code.

## Applied to doc

All consensus + near-consensus items are folded into `docs/superpowers/plans/2026-10-04-usage-statistics.md` under a new **"Audit fixes (v1 contracts)"** section that replaces the affected task steps wholesale (migration columns, parser nesting, writer flush/failure-safety, p95/bucket SQL, proxy entry/exit hygiene, injection gating, provider-key breakdown, page UTC notes, Task 9 hot-start and E2E checks). Splits documented there with their decisions.
