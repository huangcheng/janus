---
model: zhipuai-coding-plan/glm-5.3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: glm-53
---

**Verdict:** GO WITH FIXES — the face/isolation design is sound, but five spec-level pins (fixture scrubbing, empty-set error semantics, probe 400 handling, same-name catalog keying, body-cap vs images) must land before the plan is written.

**Critical risks**
1. **Fixture leaks secrets.** Task 0 captures request+response with a real operator key; nothing forbids storing `Authorization` headers or account ids in `apps/janus_http/test/fixtures/probes/openai_decisions.json`. Mandate scrubbing + gitleaks pass before commit.
2. **Empty-set error conflates two failures.** §4.5 pins empty LB set → `400 protocol_requires_native`. If the client face is *correct* but the only Decisions provider is `enabled=0`/unhealthy, the user gets "wrong protocol" — a misleading, unactionable error that also masks outages from metrics. Other faces presumably have a no-route error; reuse it for face-correct-but-unroutable.
3. **Probe treats any 400 as proof of Decisions.** A misconfigured `base_url` (other gateway, proxy) can return generic 400s. Require the 400 body to reference Decisions-validated fields (`questions`, `input`) before classifying OK; otherwise "unknown".
4. **Same-name dual-row keying unverified.** D6 allows `gpt-6-luna` on two provider rows, but the spec never checks whether `janus_catalog`/ETS keys listings by public name globally — if so, the second sync overwrites the first. Needs an explicit CHECK against `docs/SCHEMA_ETS_CONTRACT.md` before the plan.
5. **10MB cap vs base64 images.** §4.2 copies `?MAX_BODY = 10MB` while §2 allows inline base64 `input_image`; two images blow the cap. Pin a Decisions-specific limit or document it.

**Contradictions / stale claims**
- TF-D.1 permits "replay of captured fixture" while project rules require real upstream in the local gate. Pin which regime is authoritative for TF-D.1.
- §6 lists dashboard SPEC updates but no requirement to disambiguate Decisions-only names in *non-Router* model pickers (playground, grants UI); with no face tag (S2) they render as chat-callable. At minimum a plan item.

**Missing first-ship requirements**
- Retry/double-billing stance: non-stream POST — does Decisions participate in LB failover/retries? Retrying a billed decision doubles cost. Pin "no retry" or idempotency rule.
- Probe fallback hardcodes `gpt-6-luna` (public beta id) — spec should require operator listing name first, beta id only as documented fallback.

**Architecture/design notes**
- Passthrough rewriting only `model` is right; keep the `answers` presence check in tests (TF-D.1), not as a gateway-side 502 trigger — avoid growing handler validation beyond the §4.2 mirror boundary.
- Deriving Router hard-block from provider-row protocol (not listing tags) is correct; state that derivation explicitly so S2 isn't misread as "dashboard can't know."

**Top 5 concrete edits**
1. Task 0: add "strip Authorization/account ids from fixture; gitleaks must pass" as an acceptance criterion.
2. §4.5: split `protocol_requires_native` (face mismatch) from existing no-route error (face correct, no eligible route).
3. §4.3: tighten probe OK class — 400 must cite Decisions field names in the error body.
4. §4.4: add CHECK that catalog/ETS listing keys tolerate one public name across two provider rows.
5. §4.2: pin Decisions body limit (raise or document 10MB) and add no-retry/double-billing rule for the native path.
