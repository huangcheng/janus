---
model: stepfun/step-5-preview
target: 2026-10-07-openai-decisions-design-target.md
slug: stepfun-5
---

**Verdict:** NO-GO — the spec adds `openai_decisions`, a single-vendor beta face, which directly violates the locked AGENTS.md invariant "standard protocols only" (operator decision 2026-10-07) and reopens the exact provider-dialect category declared frozen after the minimax exception.

**1. Critical risks**
- **Policy:** a design spec cannot unilaterally unfreeze the dialect category; requires explicit operator amendment first, or the whole approach dies at plan review.
- **Listing ambiguity:** §2 admits one model id on multiple endpoints; O3 forces duplicate provider rows per base_url. Sync overlap, `api_key_models` binding, and `/v1/models` dedupe rules are unspecified → a chat binding could silently resolve to a Decisions listing.
- **Naming/code collisions:** `protocol_requires_native` and `stream_not_supported` are new client-visible codes with no error-enum/doc surface named, and TF-D.2 collides with the existing local `wrong_modality` reject (AGENTS.md) — codes never reconciled.
- **Auth/probe:** §5.3 "documented OpenAI error that proves auth + route reachability" is unpinnable as written; probe accept-set must be exact.

**2. Contradictions / stale claims**
- §11 ticks "Migration / dashboard enum" though the migration only exists at rollout step 3.
- D3 rationale ("one catalog") contradicts current `wrong_modality` behavior; spec never says which wins.
- TF-D.7 "unit or e2e" violates testing rule 1 (eunit first, pure helpers only).

**3. Missing first-ship requirements**
- `usage_events` token-column nullability unverified; "record null tokens" may break inserts.
- No eunit-first fixture plan for the `janus_usage_parse` change (O1 deferred but unpinned).
- No request/question-count caps; no docs/README task in §6's paired-change table.

**4. Architecture notes**
Approach A is the least-bad engineering choice but maximizes blast radius (enum, migration, LB bias, auto exclusion) for one beta model. If the operator amends policy, ship the entire face behind a default-off knob (`decisions.enabled`, 503 when off) per the repo's containment pattern, not unconditional.

**5. Top 5 concrete edits**
1. Add "Prerequisite: operator policy amendment" citing AGENTS.md; gate the face default-off like `modality.*`.
2. Resolve O2 now: pick one error code, list it in a single error contract, align TF-D.2 with `wrong_modality`.
3. Specify route-pick rule "client face must match provider face; bindings never resolve cross-face" plus `/v1/models` dedupe.
4. Verify token-column nullability; add "usage absent" to §8 and an eunit-first `janus_usage_parse` fixture plan.
5. Untick §11 migration item; rewrite TF-D.7 as a pure-selection eunit; add docs/error-code tasks to §6.
