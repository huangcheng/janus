---
model: volcengine-ark/deepseek-v4-1-flash-260910
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: deepseek-v41-flash
---

**Verdict:** GO WITH FIXES — architecture is sound, but the "merge on guide replay" gate, client-side grant confirmation, and undefined pre/post-send boundary are ship-blockers as written.

**Critical risks**
- **Write gate opens before truth is known.** §4.3 opens `POST/PUT` as soon as *one* node advertises `openai_decisions`, while D11 lets merge land on guide replay and D13 only gates *claims*. So operators can create billable providers and hit mock-shaped semantics before any live pin. On a mixed fleet, that single node also routes calls that old nodes `no_route` — intermittent billing/failures, not a doc footnote.
- **Grant widening is client-side only.** D10/§4.4 "confirmation UI" is bypassable via API-direct listing creation, silently making existing `api_key_models` grants billable. Needs server-side acknowledgement/audit, not a modal.
- **Failover boundary is vague.** "Connect failure" vs DNS, TLS, mid-body write, and pooled-gun reuse is undefined. Ambiguity here = double-bill (D15's stated risk). Define the exact no-failover boundary and a hard upstream timeout (idle 300s = a 5-minute billed hang).
- **Probe anti-abuse is under-specified.** "cooldown ≥60 s" with no atomic lock means concurrent/duplicate probes bypass it. Classifier is fragile: any 400 = inconclusive forever, so a misconfigured listing is indistinguishable from non-Decisions.
- **Atom exhaustion.** "Atom/string normalize" reading DB protocol values into atoms needs `binary_to_existing_atom`/fixed map — dynamic `binary_to_atom` is a real DoS class.

**Contradictions / stale claims**
- §2 "until live pin — null-safe only" vs §5 "pre-ship: assert labels" is fine on mock, but O1 open means `janus_usage_unmapped` will fire in prod — call that out, don't imply parity.
- D9 ("wrong-face never emits `wrong_modality`") is only specified for the Decisions handler. A Decisions-only name called on chat face is undefined — likely still `wrong_modality`, contradicting the locked intent. TF-D.13 doesn't name which faces change.
- §4.3 "same policy as other OpenAI faces… else do not invent" — unresolved in a locked table.

**Missing first-ship**
- Idempotent migration for follower boot (CHECK DROP/ADD on every node).
- Chat/Responses/Anthropic handlers emitting `protocol_requires_native`.
- Rate/quota + response body cap for the new face.
- Server-side Router hard-block (UI-only is bypassable).
- `Accept: text/event-stream;q=0` naive-substring false reject.

**Architecture notes**
- Shared preamble extraction is right; add a compile-time assert that `janus_http_decisions` has zero translate/SSE deps.
- Reuse the single eligibility predicate everywhere, as stated — good.
- Dual-face same-name split matches ETS contract.

**Top 5 edits**
1. Gate write-gate opening on live-fixture verification (or explicit operator override with audit), not node advertisement alone.
2. Enforce grant widening server-side; log acknowledgement.
3. Define the exact pre/post-send failover boundary + upstream timeout.
4. Add atomic probe lock + refine 400 classification.
5. Specify `binary_to_existing_atom` and cross-face `protocol_requires_native`.
