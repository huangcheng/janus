---
model: stepfun/step-5-preview
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: stepfun-5
---

Verdict: GO WITH FIXES — the plan is mostly sound but has a timeout contradiction, a missing `Content-Type` gate, and a probe crash-recovery gap that must be resolved before implementation.

Critical risks
- **Probe billing:** probes make real upstream calls with stored keys; first-ship must confirm they are free or tagged, else unbudgeted spend.
- **`provider_probe_state.in_flight`:** no reclaim on dashboard crash; a stuck `true` permanently blocks probes.
- **Timeout claim:** "align AGENTS idle reality" contradicts `idle_timeout=300_000`; 60s is first-byte only.
- **`Content-Type`:** no `application/json` check before the 10 MiB read; wastes resources and risks confusing `invalid_json` vs 415 errors.

Contradictions / stale claims
- "same as prior" ping body is undefined; not implementable.
- §4.5 lacks the Decisions-client → modality-only-model error (`wrong_modality` per AGENTS.md or `protocol_requires_native`).

Missing first-ship requirements
- 415 `content_type_required` before JSON parse.
- Probe skip when a provider has zero enabled listings.
- `in_flight` TTL reclaim.
- `provider_probe_state` migration file path per repo layout.

Architecture/design notes
- Auth-then-body order is fine; keep 413 pre-upstream.
- `readyz` write-gate is solid; ensure rollout docs require listener restart after code drop so `protocols` is accurate.

Top 5 concrete edits
1. In §3/§4.2, replace "align AGENTS idle reality" with explicit "60s first-byte; idle stays 300s".
2. Add step 2.5: reject non-`application/json` with 415 before JSON parse.
3. Probe: if no enabled listings, skip and do not report inconclusive.
4. Probe state: add `started_at` / TTL so `in_flight` clears if the job dies.
5. Add rule: Decisions client calling a modality-only listing → `wrong_modality` (align with AGENTS.md).
