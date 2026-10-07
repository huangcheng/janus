---
model: zhipuai-coding-plan/glm-5.3
target: 2026-10-07-openai-decisions-design-target.md
slug: glm-53
---

**Verdict:** GO WITH FIXES — the fail-closed native-passthrough design is sound and consistent with Janus invariants, but the listing-sync mechanism is undefined and several acceptances are ambiguous.

**Critical risks**

1. **Listing sync is hand-waved (§4.4 vs §2).** §2 states there is *no* Decisions models list API, yet §4.4 says "listings sync into `provider_models`". Sync source is unspecified: reuse `GET /v1/models` stamped by provider-row protocol, or operator-entered listings? This is the mechanism that makes D3 real; it must be pinned before plan.
2. **Shared LB behavior change (§4.5).** `prefer_proto` today is documented as *streaming* same-protocol bias; extending it to all Decisions requests alters shared routing code. Spec presents it as free inheritance — it needs regression flows proving chat/responses/anthropic picks are byte-identical before/after.
3. **Same-name multi-face resolution.** Invariant says unbound listings are directly callable via `pick_listing_route`. When `gpt-6-luna` exists on two faces, resolution order (client-proto first, then 400) is only implied by rule 3; the inverse case (Decisions client, dual-face name) isn't stated at all.
4. **Probe spends real money (§5.3).** Entitlement probe = live `POST /decisions` with Luna → billed input tokens on every provider save/test. Needs a minimal-cost payload and a save-time guard, or the cost will surprise operators.
5. **Silent unbilled traffic (§5.1).** "Null if usage absent" on a 200 means unbilled rows with no signal. Require a metric/log flag when tokens are absent.

**Contradictions / stale claims**

- TF-D.2 accepts "`protocol_requires_native` **or** no_route" — an acceptance test with two acceptable outcomes isn't a gate. Same ambiguity in §4.5 rule 2.
- O3's "one protocol per provider row" is decided by fiat but never checked against the existing dashboard preset UX (operators expect one OpenAI row).
- Router exclusion "exclude **or warn**" (§4.5.4) — warn-only violates the "janus-auto must never" hard rule two lines earlier.

**Missing first-ship requirements**

- Dashboard error rendering for the new 400 codes (SPEC/TEST-FLOWS are named; the admin error map isn't).
- Catalog rebuild / generation-bump note for the CHECK-constraint migration (ETS rebuild path).
- Probe payload definition and cost guard (risk 4).

**Architecture notes**

Approach A is correct; reject-in-`dispatch` pre-translate is the right layer. The pure predicates (normalize, reject, classify) fit the eunit-first exception with production-shaped binaries.

**Top 5 concrete edits**

1. Add a §4.4 subsection defining the Decisions listing-sync source; pick one mechanism.
2. Resolve O2 in-spec: `protocol_requires_native`; rewrite TF-D.2/D.3 to assert exactly one code.
3. Add a regression flow (TF-D.8) asserting existing three-face routing unchanged by the `prefer_proto` extension.
4. Specify dual-face name resolution order for both client directions (rules 2+3 made symmetric).
5. Router tier pickers: hard-block Decisions listings, delete "or warn".
