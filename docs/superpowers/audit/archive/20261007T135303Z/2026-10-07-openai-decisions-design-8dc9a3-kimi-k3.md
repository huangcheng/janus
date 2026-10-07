---
model: kimi-for-coding/k3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: kimi-k3
---

1. **Verdict:** GO WITH FIXES — the shape is sound, but first ship must stay blocked on a sanitized live fixture, explicit dual-repo deploy ordering, and tightened error/probe/body contracts.

2. Critical risks
- **Fixture/secrets:** task 0 capture can leak `Authorization`, org/project headers, request ids, or billing-identifying response headers into a committed probe; require redaction rules and a scrubbed fixture before parser work. Beta shape may differ from guide; no inferred fields.
- **Migration/deploy ordering:** dashboard must not be able to write `openai_decisions` before all gateways run the CHECK migration; add a dashboard guard keyed to gateway/catalog generation or minimum compatible version. SQLite CHECK change likely needs table rebuild, not “add value”.
- **Probe classification:** treating any 400 JSON as “Decisions validated” is unsafe; 400 can mean closed beta, bad model, quota, policy, or malformed base64. Require an allowlist of OpenAI error codes or captured proof. 403 must split bad key vs no Luna/beta access.
- **Grant-by-name auth UX:** D10 can expose a name in `/v1/models` while every route for the caller’s face fails with 400; decide whether `/v1/models` is name-union or face-eligibility filtered, and document the leak/UX tradeoff.
- **Request body:** inline base64 images plus 10 MiB `?MAX_BODY` may be too small; define 413 behavior and whether Decisions gets a higher limit.
- **Non-idempotent POST:** state retry policy explicitly; safest is no automatic retry.

3. Contradictions / stale claims
- §4.2 “Same envelope for `stream_not_supported` with that code” conflicts with TF-D.5 expecting code `stream_not_supported`; keep codes distinct, same envelope only.
- TF-D.4 “granted name appears / denied omits” is underspecified against D10 when the same name exists on chat and Decisions rows.
- “usage optional” is fine, but TF-D.6 must say exact assertion is fixture-derived, not guide-derived.
- Env `OPENAI_API_KEY` invalid conflicts with prod-secret posture; specify capture key source and handling.

4. Missing first-ship requirements
- Hard gate: no implementation beyond stubs until fixture exists and eunit compares fragmented/whole only where relevant.
- Pin exact wrong-face and stream message strings in spec, not “at implementation”.
- Dashboard server-side Router validation, not only picker hard-block.
- Exact metric names/label allowlists and dashboard alert compatibility check.
- Path-join contract tests for `/v1` bases, trailing slashes, and no `/v1/v1`.
- Passthrough rules for unknown request fields, response headers, status codes, and request-id echo.

5. Architecture/design notes
Approach A is correct; LB eligibility as primary with dispatch as second line is the right fail-closed layering. Keeping Decisions out of translate/auto/polyfill preserves the pure-gateway invariant. One-protocol-per-row is acceptable v1 but will pressure duplicate key UX; leave room for later capability metadata without adding face tags now.

6. Top 5 concrete edits
1. Add fixture redaction checklist and make capture a blocking release gate.
2. Resolve stream-code wording: `protocol_requires_native` for wrong face; `stream_not_supported` for `"stream": true` boolean only.
3. Add dashboard write/deploy guard until gateway migration generation is present; document SQLite CHECK rebuild.
4. Define probe OK as 200 or captured/allowlisted validation 400; split 401/403/quota/beta classes.
5. Decide and test body limit/413 for base64 image inputs plus no-retry policy.
