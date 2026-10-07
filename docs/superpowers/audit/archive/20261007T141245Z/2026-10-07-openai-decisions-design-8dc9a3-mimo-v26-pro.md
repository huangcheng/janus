---
model: mimo/mimo-v2.6-pro
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: mimo-v26-pro
---

**Verdict:** GO WITH FIXES — the design is unusually disciplined, but the probe classifier's 404/405 ambiguity, the "bytes sent" failover boundary, and error-envelope parity are underspecified enough to burn a billing cycle or break clients on day one.

**Critical risks**
- Probe billing abuse: cooldown ≥60 s per provider is unenforceable if dashboard replicas >1; also unspecified which listing is probed on multi-listing providers (billing target unclear).
- Failover boundary (D15): "request bytes sent" needs a concrete contract in `janus_providers` (gun partial send, connect-then-write failure). Without it, shared-proxy retry leaks through and double-bills; TF-D.8 regression doesn't assert single-bill.
- Two error shapes on one face: local `{"error":{...}}` envelope vs verbatim upstream bodies vs 413 "keeps existing `request_too_large` shape" — clients must parse three dialects; spec never states the 413 JSON.
- Grant widening (D10): confirmation UI is soft — a shared listing name silently becomes billable on Decisions from any key holder.

**Contradictions / stale claims**
- Probe classifier: 404 appears in both "Not Decisions" and "Inconclusive" rows; the disambiguation ("model-not-found body") has no rule and can't be pinned before the live fixture (O1 open). 405 as "not Decisions" misclassifies a base_url path-join bug.
- §4.2 "parity with other Janus local rejects; 413 keeps existing shape" — either it's parity or it isn't; unresolved.
- §4.3 OpenAI-Organization/Project: "same policy … if already implemented; else out of scope" is a deferred decision, not a rule.
- §4.1 mixed fleet "accepted" while §4.5 promises `protocol_requires_native` for wrong-face names — old nodes return `no_route` for the same call; agent-visible behavior diverges.

**Missing first-ship**
- Metrics for probe outcomes and pre-send failover events (no counter named).
- Rollback story when new gateway boots (CHECK added) but dashboard write gate can't open (no node advertises) — operators are locked out with no escape valve.
- Decision on `usage` unknown-token-key mapping drift post-live-pin (O1) — who re-verifies TF-D.6.

**Architecture notes**
- Single shared eligibility predicate is the right call; enforce it with an eunit that all three call sites import the same function.
- Fixture-first (D11) merge is acceptable only because D13 gates *claims*, not shipping — say so in ops copy so nobody claims beta support early.

**Top 5 edits**
1. Fix probe classifier: exact 404 body-shape sniff rule; classify 405 as Inconclusive, not "not Decisions".
2. Write the "bytes sent" boundary as a provider-adapter contract + TF asserting zero post-send retry and single usage row on failure.
3. State the exact `request_too_large` JSON and reconcile with the `{"error":…}}` envelope; assert in TF-D.5/413.
4. Make grant-widening confirmation blocking (or per-face grant) — D10 as written is a billing foot-gun.
5. Decide Organization/Project propagation now; pin probe listing selection (e.g. lowest-cost ready listing) in §4.3.
