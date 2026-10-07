---
model: alibaba/qwen3.8-max
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: qwen38-max
---

**Verdict:** GO WITH FIXES — fail-closed routing design is sound, but Decisions listing discovery, probe classification, and fixture hygiene must be pinned before plan task 0.

**2. Critical risks**
- **Secrets:** task 0 commits captured request+response; no mandate to scrub `Authorization`/org headers from the fixture — gitleaks won't flag a key inside a JSON body field.
- **Secrets/ops:** D6 puts the same upstream API key in two provider rows; rotation must touch both, silent drift risk.
- **Failure mode:** during rolling deploy or rollback, old-beam nodes can load catalog rows with protocol `openai_decisions`; if `normalize_protocol/1` has no tolerant clause, catalog rebuild can crash. Unknown protocols must be skipped, not raised.
- **Auth UX:** D10 grants silently widen — adding a Decisions row later activates an already-granted name on the new face with no re-consent; fail-closed applies only while *no* eligible route exists.
- **Probe:** "400 JSON proving Decisions validated the body" is unfalsifiable as written — rate-limit, model-not-found, or any proxy 400 classifies as OK.

**3. Contradictions / stale claims**
- §2 says there is **no Decisions models-list API**, yet §4.4 relies on `GET {base}/models` sync to stamp listings. If Luna isn't in upstream `/v1/models`, a Decisions provider row has zero callable models and TF-D.1 is unreachable. Unresolved.
- §4.2 "Same envelope for `stream_not_supported` with that code" is ambiguous against §4.7's distinct code.
- Probe fallback to raw `gpt-6-luna` conflicts with §4.6's model-rewrite contract (upstream id may differ from listing name) → false "not Decisions".

**4. Missing first-ship requirements**
- Listing seeding path if `/models` omits Luna (operator-seeded static listing + TF asserting it exists).
- Fixture scrub checklist before commit.
- Acceptance criteria if usage is *permanently* absent — TF-D.6's "null OK" can mask forever-null token stats; define `usage_missing` alerting.
- Rollout invariant: unknown-protocol rows skipped by old beams.

**5. Architecture/design notes**
- No face knob is consistent with Chat/Responses/Messages; eligibility filtering is strictly stronger than a gate — fine.
- Define usage `outcome` for a 200 whose `answers[]` are all `refusal` (success vs distinct class) before TF-D.6 pins parsing.
- Beta wire churn: make captured-fixture replay the stable TF-D.1 gate, live Luna optional.

**6. Top 5 concrete edits**
1. §4.4: pin how Decisions listings get populated; add static-seed fallback + a TF asserting listing presence.
2. §2: require scrubbing auth headers/keys from `openai_decisions.json` pre-commit.
3. §4.3: classify probe OK via an error-body fingerprint pinned from task 0; drop the `gpt-6-luna` fallback; probe with the listing's upstream model name.
4. §4.2: table the two codes (`protocol_requires_native`, `stream_not_supported`) each with its pinned message; delete "with that code".
5. §8/§9: add "old beams skip unknown protocol rows" as a rollout invariant + regression assertion; record D10 grant-widening as an accepted risk.
