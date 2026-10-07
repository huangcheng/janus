---
model: volcengine-ark/deepseek-v4-1-flash-260910
target: 2026-10-07-openai-decisions-design-target.md
slug: deepseek-v41-flash
---

Verdict: GO WITH FIXES — the reuse of existing auth/LB/usage plumbing is sound, but the upstream premise is uncaptured and several first-ship contracts are undefined.

**Critical risks**
- **Premise unverified.** The doc asserts facts "verified 2026-10-07" yet O1 concedes no live usage capture exists. `/v1/decisions`, `gpt-6-luna`, input-only pricing, base64-only images — none are backed by bytes in the repo. If any is wrong, the protocol atom, migration CHECK, handler, and dashboard enum are all rework. Gate code on a captured request/response fixture.
- **Listing→protocol mapping missing.** §4.4 assumes `provider_models` rows know a listing is Decisions-capable, but sync source is never specified (OpenAI `/v1/models` doesn't expose endpoint capability). Same id across faces (D3) worsens this. Rules §4.5.2/3 cannot be enforced without it.
- **Probe contract.** "POST {base}/decisions" as a key probe implies a real, likely billed call needing valid `questions[]`; a 400 may or may not prove auth. Undefined → false entitlements.
- **Error-code ambiguity (O2)** blocks TF-D.2/D.3; precedence of `protocol_requires_native` vs `translate_unsupported` vs `no_route` is unspecified.

**Contradictions / stale claims**
- §4.5 invokes `prefer_proto` (a *streaming* same-protocol bias) for "all Decisions requests, stream or not," then §4.7 forbids streaming. Mechanism mismatch.
- §4.3 "path chosen by gateway when forwarding" vs the concrete `{base_url}/decisions` + O4 trailing-slash rule; the `/v1` join is unpinned.
- §4.4 "may be bound or called by listing name" vs D3's grant-gated visibility — unbound direct call vs `api_key_models` grant unreconciled.

**Missing first-ship requirements**
- Concrete `MAX_BODY` value; upstream `x-request-id` propagation.
- Dashboard cost config for the input-only price (spec pushes cost dashboard-side but never scopes it).
- Router/auto exclusion is only "warn" on the management side; gateway skip is asserted without a testable predicate.

**Architecture notes**
- Face A over a modality path is correct; fail-closed over polyfill is correct. But O3's "one protocol per provider row" forces duplicate rows for one OpenAI key — document that operational cost or introduce a per-endpoint capability flag.

**Top 5 concrete edits**
1. Add a blocking gate: live-capture `/v1/decisions` bytes; pin O1/O2 from them; remove "verified" until then.
2. Pin one error code + status and its precedence, and add it to classify/metrics enums.
3. Define how catalog tags a listing as Decisions-capable (sync source, multi-face handling).
4. Resolve O3 now, including probe/entitlement duplication impact.
5. Specify probe semantics (non-billable or documented minimal call), `MAX_BODY`, and request-id propagation.
