---
model: mimo/mimo-v2.6-pro
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: mimo-v26-pro
---

**Verdict:** GO WITH FIXES — decisions and failure semantics are tightly pinned, but upstream auth handling, the 60 s first-byte timeout, and unbounded body buffering must be resolved before D13.

**Critical risks**
- Upstream auth never stated: §4.3 says strip OpenAI-Org/Project, rewrite `model`, mint `x-request-id` — but not that client `Authorization` is replaced with the stored provider key. If forwarded, clients can ride provider credentials and spoof orgs; also strip `Cookie`/`X-Api-Key`.
- D12 buffers the full 10 MiB body before upstream connect: unbounded concurrent buffers = memory DoS. No concurrency cap or 503 path defined.
- "mint/echo `x-request-id`" — echoing a client value into logs is log-injection; sanitize or always mint.
- "strip sensitive upstream headers" on error passthrough is undefined; define a forward allowlist (e.g. `Retry-After` only).
- Write gate: one node restarting (heartbeat >60 s) blocks all provider creates; break-glass must be operable while the dashboard is degraded.

**Contradictions / stale claims**
- §4.2's 60 s first-byte timeout contradicts AGENTS.md's rationale for `idle_timeout=300_000` ("upstreams may take 60s+ to first byte").
- `decisions_probe_total` is in gateway metrics namespace, but the probe is a dashboard server-side job — where is it incremented/exposed? (`:8090 /metrics` is gateway-owned.)
- Precedence rows 5 vs 6 overlap: name with disabled Decisions routes *and* enabled chat routes — "exists only on other protocol" or "face-correct all disabled"?
- Rollout step 9 (live TF-D.1) is billable prod traffic; the gate forbids it until O1 is pinned — state the ordering explicitly.

**Missing first-ship requirements**
- 405 code name and 413 `request_too_large` absent from the error table.
- D10 grant-acceptance audit and break-glass audit: no table/schema named.
- No TF for chunked-oversize rejection (§4.2 step 2) or "client key never forwarded".
- `{base}/decisions` path-join: trailing-slash and `/v1`-suffix behavior unpinned.

**Architecture notes**
- Pipeline order (auth→body→parse→grant→stream→eligibility) matches §4.5; good.
- `janus-auto` → `protocol_requires_native` is an addendum outside rows 1–8; make it an explicit row so replay tests cover it.
- D15's pre-send-only failover is honest but weakens resilience vs. other faces; acceptable since regressions are gated.

**Top 5 edits**
1. Add to §4.3: "replace client `Authorization` with stored provider key; strip `Cookie`/`X-Api-Key`."
2. Reconcile the 60 s first-byte timeout with the 300 s idle_timeout rationale, or justify the per-endpoint exception.
3. Cap concurrent buffered bodies (bound + reject), or document the limit and rejection code.
4. Complete the error table (405/413) + upstream-header allowlist; add the `janus-auto` precedence row.
5. Pin where `decisions_probe_total` lives, and name audit storage for D10/break-glass.
