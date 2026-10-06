# Role
Audit the attached Janus usage-statistics implementation plan only. Do not write code. Do not call tools.

Janus = Erlang AI gateway (Cowboy data plane :8080, ETS catalog, node-local LB, provider adapters via gun; dashboard plane :8090 serving a JSON API + React SPA). The plan adds per-request token-usage statistics: capture in the proxy (non-stream + SSE streaming via `stream_options.include_usage` injection and a bounded head/tail parse), a buffered `janus_usage` gen_server writer, a `usage_events` table (SQLite + Postgres dialect migrations), rollup queries (totals/p95/series/breakdowns), `/api/usage/*` endpoints, and a Usage page in the SPA.

# Required output format
1. Verdict: GO / GO WITH FIXES / NO-GO — one sentence
2. Critical risks (SSE usage fidelity, dual-DB dialect SQL, data-plane hot-path cost, migration safety, retention/sweep, gen_server buffer failure modes, identity/FK correctness, latency/p95 accuracy)
3. Contradictions or stale claims
4. Missing first-ship requirements
5. Architecture/design notes (buffered writer, proxy hook via process dictionary, parser, rollup SQL, page)
6. Top 5 concrete edits

Under 450 words. Be skeptical and specific.
