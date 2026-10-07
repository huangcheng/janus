---
model: volcengine-ark/deepseek-v4-1-flash-260910
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: deepseek-v41-flash
---

**Verdict:** GO WITH FIXES — internally coherent, but it builds an entire protocol face on an upstream (path, schema, `gpt-6-luna`) the doc itself has not verified; make live-capture verification a pre-implementation blocker, not a production-only gate.

**Critical risks**
- Upstream unverified. Only O1 is open; endpoint, request/response schema, and model name are treated as settled. If the guide is wrong, D1–D15 and TF-D.* are wasted. D13 gates production claims, not code.
- D15 pre-send-only failover assumes the shared proxy can distinguish "bytes sent." Spec never says it can; if not, that's a proxy change missing from scope.
- Billing exposure: null usage + inline base64 images = billable calls with no cost accounting and no quota/budget guard. Probe cooldown is per-provider, not per-caller.
- Write gate "≥1 ready node advertises" opens too early: a Decisions provider can be created while old nodes still `no_route`, producing an intermittent failure window. Require all ready nodes (or route only to advertising nodes).
- Secret/log hygiene is addressed, but the committed guide-excerpt fixture is eunit-consumed; add an explicit redaction assertion in CI.

**Contradictions / stale claims**
- `?MAX_BODY` vs D12 hard 10 MiB — precedence unspecified.
- OpenAI-Organization/Project pass-through is conditional ("if already implemented; else do not invent") — unresolved, not a spec.
- §4.1 mixed-fleet divergence "accepted" contradicts D2 fail-closed intent absent a routing safeguard.
- §3 "extract or copy carefully" leaves preamble strategy undecided; copy invites drift, extract risks existing faces.

**Missing first-ship**
- Per-request upstream deadline (only probe ~10 s and idle 300 s given).
- 429 metric name; client-retry/idempotency double-bill policy.
- `questions[]`/input cardinality caps beyond body size.
- readyz `protocols` versioning for dashboard parsers.
- Migration CHECK rollback/forward-compat detail beyond "optional later."

**Architecture notes**
- Readyz capability advertisement and the single eligibility predicate are sound; fail-closed by protocol is right.
- Fourth face raises combinatorial surface; face-level authz is absent (grants are name-only).

**Top 5 concrete edits**
1. Add "live capture verified (path, model, schema)" as a pre-implementation gate; expand O1 accordingly.
2. Change write gate to require all ready nodes advertise, or filter routing to advertising nodes.
3. Pin `?MAX_BODY` vs 10 MiB precedence.
4. Scope the proxy "bytes sent" signal for D15, or downgrade the failover claim.
5. Pin the 429 metric name, idempotency/retry billing policy, and resolve the Organization/Project pass-through decision.
