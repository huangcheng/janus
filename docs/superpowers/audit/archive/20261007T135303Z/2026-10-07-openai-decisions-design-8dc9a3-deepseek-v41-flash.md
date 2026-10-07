---
model: volcengine-ark/deepseek-v4-1-flash-260910
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: deepseek-v41-flash
---

**Verdict:** GO WITH FIXES — the passthrough architecture is sound, but the entire upstream wire contract is unverified and several pinned details (usage field names, models-list face visibility, probe classification) must not ship before the plan-task-0 capture.

**Critical risks**
- No live fixture. `gpt-6-luna`, `questions[]`, and `answers[]` predicate/choice/score/refusal shapes are guide-only. §2/§5.1 already pin `input_tokens`/`output_tokens` names — premature and in tension with "never fabricate." Pin only null-safe behavior; defer field names to capture.
- `/v1/models` union hides face: a chat client sees a Decisions-only name (D3) and gets 400 `protocol_requires_native` with no discoverable reason. No protocol/face hint is emitted — real client UX bug.
- Probe accepts any 400 as "OK." A gateway/proxy 400 masquerades as provider validation, so misconfiguration passes the entitlement UI. Require a provider-specific error signature.
- Probe key sourcing: §2 used an environment `OPENAI_API_KEY`. Probe must use the stored provider-row key, with key and base64-image body redaction from logs.
- `usage_missing` (§2/§5.1) is absent from the §5.2 closed-enum table; metric name and owner undefined.

**Contradictions / stale claims**
- §10 O1 "deferred to task 0" vs §2/§5.1 pinning usage field names.
- §7 TF-D.1 "live Luna or replay of captured fixture" is unrunnable now; §9 step 4 migrates before capture is consumed.
- §5.2 "pre-ship check unknown labels" is a plan item presented as a spec guarantee.

**Missing first-ship requirements**
- Entitlement ordering: is name-grant checked before or after face eligibility? A name that later gains a second face silently widens a key's reach — document/lock.
- Required-field validation for `input`/`questions[]` and inline data-URL image enforcement (gateway vs upstream).
- Probe timeout, retry/idempotency, and explicit billing notice on 200.
- Audit/retention note for Decisions payloads.

**Architecture notes**
- Fourth face on `janus_http_proxy` is correct; LB filter + dispatch reject is proper belt-and-braces.
- Shared `protocol_requires_native` both directions is fine; keep one body shape.
- No face knob is consistent with Chat/Responses/Messages.

**Top 5 edits**
1. Defer usage field-name pinning to capture; ship null-safe only.
2. Emit a face/protocol hint in `/v1/models` (or document client disambiguation).
3. Tighten probe: provider-specific 400 signature, timeout, key/body redaction, stored-key source.
4. Add `usage_missing` to §5.2 with a metric name.
5. Specify entitlement-vs-eligibility order and the second-face privilege risk.
