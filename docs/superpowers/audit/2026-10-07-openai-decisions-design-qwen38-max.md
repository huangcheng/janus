---
model: alibaba/qwen3.8-max
target: 2026-10-07-openai-decisions-design-target.md
slug: qwen38-max
---

1. **Verdict:** GO WITH FIXES — sound passthrough design, but fail-closed guarantees leak through LB wording, entitlement semantics are undefined, and the project's default-off knob convention is skipped.

2. **Critical risks**
- **Grant leakage:** `/v1/models` + callability are gated by `api_key_models`. With O3's two provider rows sharing model id `gpt-6-luna`, a grant matched **by name** silently authorizes the Decisions face when only chat was intended. Define grant matching (listing id, not name) explicitly.
- **LB leak:** §4.5 rule 3 says "*prefer* filtering Decisions routes out of Chat picks". Prefer is not fail-closed; under scoring/fallback a chat body can reach upstream `/decisions`. Must be a hard eligibility filter (proto match), not `prefer_proto` bias reuse — Decisions never streams, so the streaming-bias knob is the wrong mechanism.
- **Auto-router:** defense-in-depth skip is right; ensure exclusion happens at candidate-set build, not post-pick, or a Luna-only catalog yields empty-pick errors instead of clean 400s.
- **Migration order:** dashboard (shared Postgres) writes `openai_decisions` rows as soon as it deploys; follower gateways still carry the old CHECK → insert 500s mid-rollout. Failure mode 6 names this but rollout §9 doesn't sequence it.

3. **Contradictions / stale claims**
- TF-D.2 asserts an error code while O2 is unresolved, and its "(or no_route)" alternate makes the assertion unfalsifiable — pin before plan.
- Existing invariant: "chat-family call naming a non-chat listing is rejected locally (`wrong_modality`)". A Decisions listing named from chat hits **that** path first; spec never reconciles error precedence with `protocol_requires_native`.
- §4.3 probe ("minimal POST {base}/decisions") vs §5.3 ("success = HTTP 200 or… pin later"): a minimal payload almost certainly returns 400 validation, and a valid 200 probe costs a Luna call per provider save. Decide: 401/403 = bad auth, 400 = reachable.
- TF-D.7 offers "unit or e2e"; AGENTS.md mandates E2E only.

4. **Missing first-ship requirements**
- No feature knob. Project convention: all knobs default off via settings→persistent_term, 503 when off, gate asserts both regimes. Add `decisions.enabled` → 503 `decisions_disabled`, mirroring modality gates.
- CHECK-constraint audit beyond `providers`: `usage_events.protocol`, router bindings, seed validators, dashboard validators.
- Dashboard UX for O3's duplicate-provider workaround (copy-provider action) and Router-tier warning copy.

5. **Architecture/design notes**
- Approach A is right; keep `openai_decisions` out of `janus_protocol_translate` clause space entirely — reject in dispatch as spec says. Null-safe usage parse (O1) is the correct default given input-only pricing.

6. **Top 5 concrete edits**
1. §4.5 rule 3: replace "Prefer filtering" with "MUST exclude `openai_decisions` routes from non-Decisions route eligibility".
2. Add knob `decisions.enabled` (default off, 503 when off) + gate flows asserting both regimes.
3. Pin error precedence: `wrong_modality` vs new `protocol_requires_native`, one code per direction; resolve O2 before TF-D.2/D.3 text is finalized.
4. Define `api_key_models` semantics for duplicate ids across protocol rows; TF-D.4 must assert granted and denied cases per face.
5. §5.3: fix probe success criteria (4xx-with-auth-proof = reachable), list the CHECK constraints touched in §4.3, and sequence migration-before-dashboard-writes in §9.
