---
model: stepfun/step-5-preview
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: stepfun-5
---

Verdict: GO WITH FIXES — rounds 1–3 are largely folded, but the pre/post-send failover boundary, probe-billing controls, and grant-escalation scope are under-specified enough to bite in code.

## Critical risks
- **Failover boundary (D15) is undecidable at gun's API.** "Connect failure" vs "bytes sent" has no clean hook; gun fires one async op. DNS-ok/TCP-r efused, TLS-handshake fail, and connect-then-write-fail all sit in the undefined middle and invite the exact double-bill D15 forbids.
- **Probe cooldown "≥60s stored" has no location.** If gen_server memory, it resets on restart, and a read-check-then-mark race lets two concurrent probes bill Luna repeatedly — defeating the stated purpose.
- **Grant widening (D10) confirm fires only at provider-create.** Adding a listing later, binding an existing key, or editing grants can all silently make a name billable. Grant match basis (`name` vs `upstream_model_id`) is undefined → accidental collisions.
- **Shared preamble `?MAX_BODY` vs 10 MiB (D12)** not reconciled — which wins?

## Contradictions / stale claims
- §4.3 "no retry" vs "may fail over on connect failure" reads as retry-by-reroute; needs one pre/post-send definition.
- D13 (production needs live capture) vs merge on guide replay (D11) is acceptable, but then usage fields ship permanently null (O1) — ensure cost UI never renders null as $0.
- Probe is not stated to pass through the usage writer → billable probes become invisible in `usage_events`.

## Missing first-ship
- Persisted, concurrency-safe probe cooldown; probe recorded as a usage event (close the billing blind hole).
- 2xx-non-200 / empty-body handling for verbatim passthrough (only 200+`answers` = OK).
- Confirm the guide fixture path actually matches eunit includes; add SCHEMA_ETS_CONTRACT.md to the doc-sync list.

## Architecture / design notes
- Extract a real `ensure_json_request/3` used by all faces rather than copy; the no-SSE/translate TF invariant is correct.
- Register `janus_usage_missing/unmapped{protocol}` counters before first traffic; keep label cardinality PII-free.

## Top 5 concrete edits
1. Rewrite §4.3 with an explicit driver-state table: failover only pre-ESTABLISHED, everything after request send returns the upstream error; eunit asserts "post-send error ⇒ exactly one upstream request."
2. Make probe cooldown a DB/persistent_term CAS with stored `last_probe_at`; serialize concurrent probes; log probe as usage.
3. Extend grant-intersection confirm to listing-add, key-bind, and grant-edit; pin grant key = display `name`.
4. Pass the decisions 10 MiB limit explicitly into the shared preamble; eunit 10MiB+1 ⇒ 413 `request_too_large`.
5. Move the `Accept: text/event-stream` guard before JSON parse (header-only), drop "treat 400," and state 2xx≠200/empty as verbatim pass-through.
