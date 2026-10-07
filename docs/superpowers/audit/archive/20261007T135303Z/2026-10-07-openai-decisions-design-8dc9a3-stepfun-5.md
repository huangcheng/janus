---
model: stepfun/step-5-preview
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: stepfun-5
---

1. **Verdict:** GO WITH FIXES — the fail-closed routing and mirror-boundary discipline are strong, but fixture-dependent test gating, Decisions pricing/usage units, and metric-label verification lack the specificity required for a clean first ship.

2. **Critical risks**
- **Fixture dependency:** TF-D.1 and TF-D.6 are hard-blocked on plan task 0 (valid OpenAI key). The local E2E gate now has an unconditional external dependency; a deterministic cassette or replay path must be pinned in the spec, not deferred.
- **Usage semantics:** The spec forbids fabricating zeros but is silent on dashboard pricing and unit type for Decisions. Is it token-only, or does it need `units` like modalities? First-ship cost readouts will show nulls.
- **Auth UX:** Grant-by-name (D10) means a key authorized for `gpt-6-luna` sees the name in `/v1/models`, yet a wrong-face call returns 400 `protocol_requires_native`. Acceptable fail-closed behavior, but UX copy must explain why a listed model rejects a request.
- **Probe false positive:** §4.3 treats 400 as “Decisions validated the body,” but a generic 400 (bad JSON, upstream misconfig) is indistinguishable. The probe class is under-specified.

3. **Contradictions or stale claims**
- §2 claims the usage parse is “pinned null-safe,” yet §5.1 still requires post-capture assertion of exact field names in TF-D.6. “Pinned” and “TBD” conflict.
- §4.4 says `/v1/models` unions by public name, but §4.5 requires per-protocol candidate filtering. If the union entry hides protocol, the router needs a name→protocol→row resolution step (e.g., `pick_listing_route`) that the spec references but never describes for Decisions.

4. **Missing first-ship requirements**
- No dashboard Decisions pricing/unit definition.
- No explicit `protocol_requires_native` / `stream_not_supported` entries in the gateway error-code registry or dashboard error map (listed in §6 but not specified).
- No description of Decisions provider health/active-selection parity.
- No concrete metrics pre-ship check: “scrapes accepting unknown labels still work” is not a testable statement.

5. **Architecture/design notes**
- The dual filter (LB candidate set + dispatch reject) is excellent and cheap.
- Using `protocol_requires_native` instead of overloading `wrong_modality` preserves the modality gate contract.
- Dual provider rows for same-name chat+Decisions force the models union to carry protocol-aware routing metadata, not just a name set.

6. **Top 5 concrete edits**
1. Add an explicit Decisions usage pricing/unit column requirement (token-based, null-safe default) to §5.1 and the dashboard work list in §6.
2. Mark TF-D.1/TF-D.6 as blocked-on-task-0 or define the recorded cassette path in the spec.
3. Define the pre-ship metrics smoke as a concrete scrape asserting `endpoint="decisions"` and `protocol="openai_decisions"` label presence.
4. Sharpen the probe outcome class: require a Decisions-specific validation field in the 400 body (e.g., `questions`/`predicate`) to avoid false positives from generic 400s.
5. Explicitly describe `/v1/models` union route resolution (name→protocol→row) so same-name multi-face cannot silently route to the wrong protocol.
