---
model: zhipuai-coding-plan/glm-5.3
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: glm-53
---

**Verdict:** GO WITH FIXES — routing/precedence/failover are decision-complete; the gaps are one unspecified error contract and two unverified operational assumptions.

**Critical risks**

- **Mid-body failure envelope undefined.** D15 defines `upstream_timeout` for first-byte timeout only. A gun stream error *after* first byte is "terminal, no failover" — but no client-facing status/code is specified anywhere. Agents and TF-D.15 can't be written against an unspecified contract.
- **`GET :8080/readyz` unauthenticated.** :8080 is the public agent port. Per-node protocol enumeration is new recon surface; "same public health surface as healthz" is only true if healthz already exists there today — unverified. Prefer :8090 or a dashboard bearer token.
- **Write-gate vacuity.** "Every node ready" is vacuously true when the dashboard registry holds zero fresh heartbeats (fresh install, broken heartbeat feed). Gate silently passes unverified; require ≥1 fresh node.
- **D15 stale-pool race.** Request written to a pooled connection the peer already closed surfaces as a stream error → terminal → client error despite healthy alternates. Safe (no double-execution, correct for a billable API) but an availability regression; document + client retry guidance.
- **"Strip sensitive upstream headers" unpinned.** No list; and "mint/echo `x-request-id`" doesn't say the *upstream's* `x-request-id` is replaced — it must be, or correlation breaks.

**Contradictions / stale claims**

- AGENTS.md `wrong_modality` invariant disagrees with D9 until the same-commit update lands; two sources of truth in the interim — commit boundary must be exact.
- "No billable prod until O1" vs D13 capture and step-9 TF-D.1: state explicitly that D13 runs direct-to-OpenAI with the operator key (not via gateway), and that TF-D.1 is sequenced after O1.
- Precedence row 6 returns `provider_disabled` when the cause is *listing* disable — misleading name.

**Missing first-ship requirements**

- Dashboard heartbeat mechanism: if it doesn't exist, it's a hidden prerequisite needing its own migration + freshness metrics.
- `provider_probe_state` migration + probe scheduler restart semantics (in_flight recovery).
- Grant-confirm batching for bulk listing-add (D10 per-listing → N modal confirms).

**Architecture/design notes**

- 4 MiB response cap rests on guide excerpts + one future D13 sample; record observed max answer size in D13 before hard-coding.
- Probe picks lowest `provider_models.id` — silent target shift when listings change; fine, but log which listing was probed.

**Top 5 concrete edits**

1. §4.2/D15: add mid-body stream error row — exact status + code (e.g. 502 `upstream_stream_error`) with TF-D.15 assertion.
2. §4.3 write gate: block when registry has zero fresh heartbeats; specify that case's error reason.
3. §4.3 readyz: verify current :8080 exposure; if public, move to :8090 or token-gate; delete the unverified "same as healthz" claim.
4. §4.3 forward: enumerate stripped upstream headers; mandate replacing upstream `x-request-id`.
5. §7: extend TF-D.20 to the Responses SSE path (D16 touches shared preamble); declare D13 as gateway-bypass so the no-billable gate is unambiguous.
