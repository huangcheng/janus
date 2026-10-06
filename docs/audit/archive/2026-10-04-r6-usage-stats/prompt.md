# Role
Audit the attached Janus usage-statistics implementation plan only. Do not write code. Do not call tools.

Janus = Erlang AI gateway (Cowboy data plane :8080, ETS catalog, node-local LB, provider adapters via gun; dashboard plane :8090 serving a JSON API + React SPA). The plan adds per-request token-usage statistics: capture in the proxy (non-stream + SSE streaming via `stream_options.include_usage` injection and a bounded head/tail parse), a buffered `janus_usage` gen_server writer, a `usage_events` table (SQLite + Postgres dialect migrations), rollup queries (totals/p95 split by stream/series/4 breakdowns), `/api/usage/*` endpoints, and a Usage page in the SPA.

This is revision 4. Three prior 7-model audit rounds flagged issues; every fix is INLINED in the task bodies (no addendum). Round 3 found: dead event filters (maps:filter misuse), badmatch-crashing read paths, a vacuous `?`-literal guard test, genuine-zero usage collapsing to unreported, unguarded writer mailbox, O(n²) SSE tail copies, oversized terminal SSE events (>16KB), and a missing avg-latency stream split — all addressed in rev 4 (explicit filter fold with 400s, total read functions, real SQL scans + insert eunit, has_known_key, queue-length back-pressure with atomics counter, bounded chunk-list tail, regex usage fallback, avg/p95 split by stream, zero-filled chart buckets). Verify resolution quality and hunt for remaining or newly introduced defects. If the plan is shippable as written, say GO.

# Required output format
1. Verdict: GO / GO WITH FIXES / NO-GO — one sentence
2. Critical risks (SSE usage fidelity, dual-DB dialect SQL, data-plane hot-path cost, migration safety, retention/sweep, gen_server buffer failure modes, identity/FK correctness, latency/p95 accuracy)
3. Contradictions or stale claims
4. Missing first-ship requirements
5. Architecture/design notes (buffered writer, proxy hook via process dictionary, parser, rollup SQL, page)
6. Top 5 concrete edits

Under 450 words. Be skeptical and specific.
