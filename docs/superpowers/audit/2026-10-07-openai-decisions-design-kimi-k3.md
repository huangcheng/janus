---
model: kimi-for-coding/k3
target: 2026-10-07-openai-decisions-design-target.md
slug: kimi-k3
---

**Verdict:** GO WITH FIXES — the fail-closed design is sound, but the spec pins almost nothing against a live Decisions response, leaving auth, usage, and probe contracts to be invented at plan time.

## Critical risks

- **Auth/probe contract unverified (O1, §5.3):** The spec repeatedly defers to "pin against a live `gpt-6-luna` call," yet TF-D.1, entitlements, and the provider probe all depend on response shapes (`usage` fields, error envelopes, `answers[]` structure) that are asserted, not captured. Janus's own history (binary-vs-atom keys, SMALLINT booleans) is exactly what live-capture-first prevents. Rule 1 of AGENTS.md allows eunit-first only with production-shaped fixtures — there are none yet. First task of the plan must be a probe/capture script writing to `apps/janus_http/test/fixtures/probes/`, not a rollout step 5 afterthought.
- **Failover failure mode #1 is underspecified:** "prefer filtering Decisions routes when *any* same-face route exists" — LB currently filters by binding/model name, not by protocol. This requires LB to become protocol-aware for *all* faces, not just Decisions. That's a broader change than "inherits prefer_proto" implies, and TF-D.2's parenthetical "(or no_route if no chat route)" admits the behavior is unresolved: 400 vs 404 must be one deterministic answer.
- **O3 dual-protocol provider:** "one protocol per provider row" forces operators to create two provider rows with the same OpenAI key/base_url. That's fine, but the spec is silent on whether the same *listing name* (e.g. a Luna model that also serves chat) from two providers creates catalog ambiguity in `pick_listing_route` and `/v1/models` dedup. Name collisions across faces are the likeliest ship-day bug.
- **Usage parse for a zero-output endpoint:** `janus_usage` aggregation and cost reporting may assume output tokens exist; a protocol where output is always absent/null should get an explicit invariant check, not just "null-safe parse."

## Contradictions / stale claims

- §2 claims upstream facts "verified 2026-10-07" (pricing: no output-token charge) while O1 admits the usage schema is unpinned — both can't be verified.
- §4.5 offers `protocol_requires_native` "or reuse `translate_unsupported`" — pick one in the spec; O2 punts a wire-visible error string to the plan. Error codes are API contracts clients will match on.
- §7 lists "TF-D.1..7" while AGENTS.md/TEST-FLOWS use the TF-N numbering convention; "names illustrative" invites drift.

## Missing first-ship requirements

- No decision on `api_key_models` grant UX for a listing that exists on two faces (dashboard binding picker showing duplicate names).
- No rate-limit/retry stance for a face whose only upstream is one OpenAI beta model (single provider = LB degenerate case; does LB handle a 1-route catalog gracefully?).
- No admin `/stats`/`/metrics` dashboard expectation beyond label strings — SPEC.md sync deferred.

## Architecture notes

- Approach A is right; B/C rejection reasoning is solid. The hard-reject-in-`dispatch` placement (before translate) correctly keeps `janus_protocol_translate` untouched.
- Excluding Decisions from janus-auto at *both* gateway and dashboard layers is good defense-in-depth.

## Top 5 concrete edits

1. Make "capture live Luna request/response fixtures into `fixtures/probes/`" the **first** plan task; gate TF-D.1/D.6 on real fixtures.
2. Resolve O2 in-spec: commit to `protocol_requires_native`, delete the `translate_unsupported` alternative.
3. Specify listing-name collision semantics across faces (two provider rows, same model name): catalog dedup rule + `/v1/models` output + `pick_listing_route` tiebreak.
4. Rewrite §4.5 rule 3 as a precise LB contract: "candidate routes filtered by `provider.protocol =:= client_proto` when the filtered set is non-empty; else 400."
5. Fix TF numbering to match TEST-FLOWS.md convention and add a TF asserting usage aggregation tolerates permanently-null output tokens.
