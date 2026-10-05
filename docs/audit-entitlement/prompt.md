# Role
Audit the attached Janus SPEC (target.md) only. Do not write code. Do not call tools.

Janus = an Erlang/OTP LLM gateway (data plane, Cowboy/gun, ETS catalog rebuilt atomically from shared Postgres via generation-poll hot reload) + a standalone Python FastAPI management dashboard (repo janus-dashboard) owning provider/model/key CRUD; the dashboard writes, the gateway reads via catalog bundles. usage_events (written per proxied request, has provider_key_id + upstream status, no error text today) records traffic. This SPEC adds: (A) per-(provider-key, model) entitlement matrix — dashboard probe runner + passive learning from usage rows; (B) shipping the matrix to gateways in the catalog bundle; (C) in-request key failover in the proxy (bounded retry across a provider's key pool on key-scoped upstream failures; deny-marked keys pre-filtered); (D) E2E test plan.

# Required output format
1. Verdict: GO / GO WITH FIXES / NO-GO — one sentence
2. Critical risks (probe cost & rate-limit blowback; deny-regex false positives vs input-shape 400s; failover latency vs Cowboy idle_timeout; retry storms; matrix/catalog reload races; balance-key starvation; key rotation staleness; streaming first-byte failover boundary)
3. Contradictions or stale claims
4. Missing requirements
5. Architecture/design notes (ETS rebuild atomicity vs per-request reads; per-attempt usage rows billing semantics; dashboard-vs-gateway write ownership; 429 dual meaning; attempt-budget accounting; knob delivery)
6. Top 5 concrete edits

Under 450 words. Be skeptical and specific. Audit ONLY what target.md says.
