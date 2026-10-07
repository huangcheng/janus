---
model: mimo/mimo-v2.6-pro
target: 2026-10-07-openai-decisions-design-target.md
slug: mimo-v26-pro
---

**Verdict:** GO WITH FIXES — the fail-closed posture and dual-repo awareness are sound, but the wrong-face 400 contract conflicts with the existing `/v1/models` semantics and the usage/metrics enums are under-specified for a closed-label pipeline.

**Critical risks**
- §4.5 rule 2 vs D3 collision: a model that exists only as Decisions is callable by name from `/v1/models`, but every other face returns 400 — with two competing codes (`protocol_requires_native` vs `no_route`, TF-D.2 hedges both). Clients will retry across faces; pick one code, one message, and document it as the stable contract.
- `janus_http_decisions` "mirror `janus_http_responses`" invites copying Responses-specific machinery (SSE, translate dispatch hooks) that Decisions must not inherit. State the mirror boundary explicitly.
- Provider key probe posts to `{base}/decisions` with real model ids; a probe that mutates/bills (Decisions is input-token-priced) runs on test-key click. Specify a minimal body and whether probe cost is acceptable.
- O3's "second provider row, same base_url/key" duplicates credentials and usage attribution; entitlements and per-provider metrics will double-count the same upstream account.

**Contradictions / stale claims**
- §5.1 says "reuse `janus_usage_parse`… `input_tokens`/`output_tokens` or OpenAI's fields once pinned" — but §9 step 5 wants real Luna E2E and O1 is deferred. Acceptance can't be green with unpinned schema; capture must move before the plan.
- §4.5 rule 3 ("filter Decisions routes out when any same-face route exists") vs §8 failure mode 1 (`prefer_proto` widening) — the filter rule is stated for pick logic, not for LB candidate-set construction, so the exact widening point is still open.
- §2 claims "no separate Decisions models list API" yet §5.3 probes `/decisions`; if OpenAI has no Decisions-native auth error distinct from chat, "proves auth + route reachability" is unverifiable as written.

**Missing first-ship requirements**
- Concrete label values for `requests_total` endpoint/protocol enums and where the closed enum lives (classify + dashboards + SPEC).
- Rollback story for the CHECK-constraint migration (old gateway rows with `openai_decisions` after downgrade).
- Auth UX: what error body/key the client sees on wrong-face 400 (agent keys are shared across faces).
- Timeout/idle settings for the non-stream Decisions POST (Cowboy 300s idle already; upstream budget unspecified).

**Architecture notes**
- Rejecting in `dispatch` before translate is right; also enforce in `janus_lb` candidate sets, not only at pick time.
- Consider tagging Decisions listings in the catalog (`face`) instead of inferring from `providers.protocol` (see O3).

**Top 5 edits**
1. Pin O1 via a live `gpt-6-luna` capture before plan; make TF-D.6 assert exact fields.
2. Standardize wrong-face error: one code (`protocol_requires_native`), one message, applied in both directions.
3. Move janus-auto + wrong-face filtering into `janus_lb` candidate-set construction; add eunit for that predicate.
4. Define metric label enum values and update SPEC/TEST-FLOWS in the same change.
5. Resolve O3 with an explicit trade-off (credential duplication vs schema change) or accept per-provider key rows with shared `base_url`.
