---
model: stepfun/step-5-preview
target: 2026-10-07-openai-decisions-design-target.md
slug: stepfun-5
---

Verdict: GO WITH FIXES

**Critical risks**

1. **Ambiguous model identity under O3.** One-protocol-per-provider-row lets two providers expose the same `model_name`. The spec never states whether `provider_models` keys on `(provider_id, model_name)` or whether `/v1/models` deduplicates. TF-D.2/D.3 assume clean rejection but not ambiguity resolution when a chat client names `gpt-6-luna` and the only route is Decisions.
2. **Metrics enum breakage.** Adding `endpoint=decisions` / `protocol=openai_decisions` violates the "closed enums only" rule silently; existing dashboards or assertions likely assume exactly four endpoints. Needs an explicit compatibility check.
3. **Stream-reject site unspecified.** The spec bans `stream:true` but does not say whether the guard is in `janus_http_decisions` pre-dispatch, in `dispatch`, or in `pick_listing_route`. Existing `stream_pair_untranslatable` sets a precedent; choose one or error shapes diverge.

**Contradictions / stale claims**

- §4.5 says Decisions inherits `prefer_proto` for "all Decisions client requests (stream or not)"; §4.7 bans streaming entirely. Delete the streaming-bias language or it becomes dead code.
- O2 allows either `protocol_requires_native` or reuse of `translate_unsupported`, yet TF-D.2/D.3 assert specific strings. Freeze one code; unmapped assertions make E2E brittle.
- Spec asserts `prefer_proto` "already" exists in LB. Verify; if absent, this is new work, not inheritance.

**Missing first-ship requirements**

- **Feature knob.** Every new face in this project gets an operator-gated, default-off setting (AGENTS.md). Decisions has none. Add `decisions.enabled` → 503 `decisions_disabled` when off, or explicitly justify bypassing the pattern.
- **Migration rollback.** Removing `openai_decisions` from the `protocol` CHECK fails once rows exist. Document rollback = disable providers, not reverse DDL.
- **Usage shape.** Decisions is input-only per §2. Spec must state `janus_usage_parse` tolerates absent `output_tokens` without fabricating zeros or nulls that crash dashboards.

**Architecture/design notes**

- Passthrough is correct. Centralize the face-mismatch reject in `dispatch` right after classify so picker and handler agree, rather than scattering checks.
- Keep probe protocol-aware; the dashboard already branches by protocol, so no new probe abstraction is warranted.
- Keep upstream path construction via the shared `base_url` normalizer (§O4); do not add Decisions-specific URL logic.

**Top 5 concrete edits**

1. Pin stream rejection to `janus_http_decisions` handler pre-dispatch; remove §4.5 streaming-bias sentence.
2. Freeze O2 to `protocol_requires_native`; update TF assertions and remove the `translate_unsupported` alternative.
3. Add a `decisions.enabled` knob section (persistent_term, default off, 503 when disabled) mirroring modality gating.
4. Add a model-surface contract note: `provider_models` unique on `(provider_id, model_name)`; `/v1/models` emits a deduplicated union; route picker resolves protocol from provider row, never model id alone.
5. Add migration rollback and metrics-compatibility clauses: rollback via `enabled=0`; verify dashboard endpoint enums tolerate new labels before ship.
