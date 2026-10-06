# Usage-statistics plan audit, round 2 — multi-model synthesis

Date: 2026-10-04 (round 2)
Models (via `pi`): MiniMax-M3, mimo-v2.6-pro, step-5-preview, qwen3.8-max, deepseek-v41-flash, glm-5.3, kimi-k3
Raw replies: docs/audit/*.txt (round 1: docs/audit/archive/2026-10-04-r3-usage-stats/)
Target: `docs/superpowers/plans/2026-10-04-usage-statistics.md` rev 2 (snapshot: docs/audit/target.md)

## Verdicts

| Model | Verdict |
|---|---|
| kimi-k3 | GO WITH FIXES — v1 holes closed; `'?'` literal × rewrite_pg + stream never read |
| mimo-v26-pro | GO WITH FIXES — fixes real, but compile gaps + stale task bodies remain |
| stepfun-5 | GO WITH FIXES — migration divergence is blocking; Postgres never executed |
| qwen38-max | GO WITH FIXES — ~8/10 findings resolved; 3 new defects ship broken |
| deepseek-v41-flash | GO WITH FIXES — directionally right; task bodies reintroduce every defect |
| glm-53 | GO WITH FIXES — latency fix cosmetic; SPA types lag; failure semantics misdocumented |
| minimax-m3 | **NO-GO** — fix section sits beside task bodies; contradictions ship by default |

**Overall: GO WITH FIXES (6/7), one NO-GO on plan structure.** Round-1 findings are genuinely resolved on paper; round 2's dominant finding (7/7) is that the A1–A10 addendum must replace the task bodies, not sit beside them. Resolution: plan rewritten as **rev 3 with all fixes inlined** — the tasks are now the single source of truth.

## Round-2 issues and their resolution in rev 3

### Consensus (≥5 models)

1. **Fix-vs-task divergence (7/7).** Task bodies retained the pre-fix code (migration DDL, `ORDER BY 5`, `percentile_cont`, first-chunk head, `LIMIT ?`, `recent/1`, 3-card grid, missing `by_provider_key` in SPA types). → **Rev 3 inlines everything; the addendum is deleted.**
2. **`stream` recorded but never read (5/7).** p95 still mixed populations. → Rev 3: `totals` returns `p95_latency_ms` (non-stream) **and** `p95_stream_ms`, plus an `unreported` count; page shows both with honest labels.
3. **`dropped` counter invisible (5/7).** → Rev 3: `janus_usage:stats/0` exposed as `writer: {buffered, dropped}` in `/api/usage/summary`; warning badge on the page when `dropped > 0`.
4. **p95 offset off-by-one (4–5/7).** `trunc(N*0.95)-1` ≠ nearest-rank. → Rev 3 uses `ceil(0.95*N)-1` on SQLite and `percentile_disc` on Postgres (both nearest-rank), `null` on empty.
5. **Sweep affected-rows contract (4–5/7).** `janus_db_conn:query` returns `{ok, Rows}`, not counts. → Rev 3 loops on `SELECT COUNT(*)` as the primary mechanism, batches of 5000, spawned off the gen_server so casts never block.
6. **NULL-token semantics defeated (3–6/7).** `track/3` defaulted tokens to 0. → Rev 3 defaults to `null`; 0 only when explicitly reported.

### Real new bugs introduced by rev 2's fixes (all fixed in rev 3)

- **`'?'` literal in provider-key `NameExpr`** collides with `rewrite_pg` (kimi, qwen) → literal removed; eunit asserts no usage SQL embeds `?`.
- **A3 omitted `handle_call/3` / `code_change/3`** (mimo) → restored in rev 3.
- **`bool_int/1` undefined** (minimax, qwen) → defined in the proxy.
- **`protocol` atom → TEXT param** breaks epgsql (kimi, qwen) → `atom_to_binary` in `build_insert`.
- **Drop-oldest label vs drop-newest behavior** (kimi, glm, qwen) → docstring corrected (drop-newest when full).
- **`recent/2` appends `AND` with no `WHERE`** (qwen) → `WHERE 1=1` base.
- **Provider-key name NULL-propagates in Postgres** (glm) → `COALESCE(pp.name, 'unknown')`.
- **`record(#{})` inserts a junk status-0 row** (mimo, qwen) → `record/1` validates integer `status`, malformed events are dropped+counted.
- **`q/2` not exception-safe** (qwen, stepfun) → try/catch → `{error, Reason}`; writer survives driver exits.
- **Anthropic cache tokens undercount prompt** (qwen) → `cache_creation_input_tokens` + `cache_read_input_tokens` added to prompt when present.
- **30d range == retention boundary** (mimo) → retention is 31 days (1-day margin).
- **`fmtTs` used local hours while charts say UTC** (qwen) → all page times render UTC.

### Noted, accepted for v1 (documented in rev 3 self-review)

- Postgres lane stays optional (no dev PG instance); dialect SQL is shape-tested via eunit + code review. `percentile_disc` decode (`numeric` as binary) handled by `num/1`.
- Mailbox is unbounded only under a permanently stalled DB; `writer.dropped` surfaces it.
- Anthropic-compatible providers emitting per-chunk (non-cumulative) token deltas would be under-reported; Anthropic proper is cumulative.
- Tail window cutting mid-`data:` line: partial lines fail decode and are skipped; the ~200-byte terminal usage event is effectively always intact within 16KB.
- `no_route` / auth rejects are not counted (no upstream interaction to measure).

## Applied to doc

`docs/superpowers/plans/2026-10-04-usage-statistics.md` rewritten as **rev 3**: all fixes inline, addendum deleted, self-review updated. Round-3 audit is optional — recommend proceeding to implementation (Task 1), since round 2's structural objection is resolved by construction.
