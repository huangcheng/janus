# Role
Audit the attached Janus usage-statistics implementation plan only. Do not write code. Do not call tools.

Janus = Erlang AI gateway (Cowboy data plane :8080, ETS catalog, node-local LB, provider adapters via gun; dashboard plane :8090 serving a JSON API + React SPA). The plan adds per-request token-usage statistics: capture in the proxy (non-stream + SSE streaming via `stream_options.include_usage` injection and a bounded head/tail parse), a buffered `janus_usage` gen_server writer, a `usage_events` table (SQLite + Postgres dialect migrations), rollup queries (totals/p95/series/breakdowns), `/api/usage/*` endpoints, and a Usage page in the SPA.

This is revision 2. A previous 7-model audit flagged: silent buffer loss on flush error, first-chunk-only SSE head capture, Anthropic `message_start` usage nesting, unbatched retention sweep, p95 dialect divergence, stream/non-stream latency mixing, UTC bucket drift, missing provider-key breakdown, keep-alive process-dictionary leaks, and `include_usage` politeness. The plan now contains an "Audit fixes (v1 contracts)" section (A1–A10) intended to resolve these. Verify whether the fixes actually resolve them — and hunt for new issues the fixes introduce.

# Required output format
1. Verdict: GO / GO WITH FIXES / NO-GO — one sentence
2. Critical risks (SSE usage fidelity, dual-DB dialect SQL, data-plane hot-path cost, migration safety, retention/sweep, gen_server buffer failure modes, identity/FK correctness, latency/p95 accuracy)
3. Contradictions or stale claims (incl. fix-section vs task-section mismatches)
4. Missing first-ship requirements
5. Architecture/design notes (buffered writer, proxy hook via process dictionary, parser, rollup SQL, page)
6. Top 5 concrete edits

Under 450 words. Be skeptical and specific.
