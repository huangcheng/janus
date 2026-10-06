# Role
Audit the attached Janus observability implementation plan only. Do not write code. Do not call tools.

Janus = Erlang AI gateway (Cowboy data plane :8080 agent API; admin plane :8090 with token-authed read-only /stats; ETS catalog; node-local LB; usage writer gen_server; multi-node prod behind Caddy). The plan adds: (a) GET /metrics on the admin plane in Prometheus text format — labeled counters/histograms in a public ETS table bumped at terminal request paths, gauges computed at scrape; (b) end-to-end client request ids — sanitize inbound x-request-id or generate req_<hex>, echo on every response incl. streams/errors, add to request logs, store on usage_events (migration 005); (c) E2E gate steps + Grafana dashboard + scrape example.

# Required output format
1. Verdict: GO / GO WITH FIXES / NO-GO — one sentence
2. Critical risks (label cardinality, hot-path counter cost, exposition format correctness, auth reuse, histogram bucket sanity, request-id injection/hygiene, migration + dual-dialect, multi-node scrape model)
3. Contradictions or stale claims
4. Missing first-ship requirements
5. Architecture/design notes (ETS registry, renderer purity, hook placement, header echo mechanics)
6. Top 5 concrete edits

Under 450 words. Be skeptical and specific.
