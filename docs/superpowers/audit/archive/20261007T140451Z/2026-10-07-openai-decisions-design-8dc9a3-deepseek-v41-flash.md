---
model: volcengine-ark/deepseek-v4-1-flash-260910
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: deepseek-v41-flash
---

**Verdict:** GO WITH FIXES — the face/error/precedence design is sound, but listing discovery can poison the chat catalog and two ship-gate mechanisms are deferred past the point of usefulness.

**Critical risks**
- **Sync poisoning (highest).** §4.4 step 1 stamps *every* inventory row with the provider-row protocol. OpenAI `GET /models` returns the full chat catalog and (per §2) has no Decisions-only list. One `openai_decisions` provider therefore stamps all `gpt-*` names as Decisions, contradicting D6, §4.4 step 3, and failure mode "sync poisoning chat listings as Decisions." Manual-add (step 2) cannot undo an auto-stamp.
- **Probe 400-fingerprint allowlist is deferred to live capture**, yet it is the only guard against false-OK on a generic 400. The classifier eunit tests against guide excerpts, but the allowlist isn't pinned, so production probe behavior is undefined at GO time.
- **`wrong_modality` vs `protocol_requires_native` ordering unspecified.** AGENTS.md says chat-family calls naming a non-chat listing are locally rejected `wrong_modality`; §4.5/D9 demand `protocol_requires_native`. Nothing states the protocol-eligibility filter runs first.
- **No-retry is asserted, not implemented.** If retry lives in the shared proxy path, "no automatic retry" needs an explicit `openai_decisions` suppression (no idempotency key); otherwise double-billing.
- **Fixture redaction only strips headers.** Inline base64 images (the only image mode) carry payload/PII gitleaks won't catch; sanitization must strip/replace body image bytes.

**Contradictions / stale**
- Release order (1) CHECK before (2) beams is impossible: migrations ship in the beams, so the "old beams tolerate unknown protocol" window is the same deploy.
- D11 ("replay authoritative") vs §2 ("live fixture required for production-green TF-D.1/D.6") — which gates GO?
- §4.4 step 1 (auto-stamp) vs step 3 (no auto-stamp).

**Missing first-ship**
- Dashboard write-gate mechanism: "generation/min-version advertises support" has no named endpoint; the "operator confirms" escape hatch voids fail-closed.
- 10 MiB cap justification for multiple inline base64 images (~7.5 MiB decoded) — Decisions is image-heavy; concurrency memory unaddressed.
- Per-key cost/quota guard for a billed beta endpoint; upstream response-size bound for a non-stream call.

**Architecture notes**
Fourth-face approach and empty/miss precedence table are correct and consistent with existing faces. Grant-widening risk is acceptable. Keep `/v1/models` hint-free.

**Top 5 edits**
1. For `openai_decisions` providers, never auto-stamp synced ids — require operator-curated listings/allowlist.
2. Pin a multi-signal 400 fingerprint now (error code + `questions`/`input`), tighten from live capture; add generic-400 → `probe_inconclusive` negative test.
3. Specify protocol-eligibility filter precedes `wrong_modality`; add TF-D assert.
4. Name the dashboard version endpoint; drop the manual write-gate override.
5. Add explicit retry suppression + base64 body redaction to §4.3/§2.
