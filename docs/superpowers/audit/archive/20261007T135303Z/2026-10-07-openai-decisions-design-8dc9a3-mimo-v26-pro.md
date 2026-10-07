---
model: mimo/mimo-v2.6-pro
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: mimo-v26-pro
---

**Verdict:** GO WITH FIXES — the fail-closed routing is sound, but the models-sync stamping rule contradicts D2 and the error/stream contract is ambiguous.

**Critical risks**
1. **§4.4 sync poisoning (worst).** A Decisions row pointing at `api.openai.com/v1` syncs `GET {base}/models` and stamps *every* listing `openai_decisions`. Chat models become "Decisions-eligible"; TF-D calls then hit `/decisions` upstream and 404/400 — or worse, a non-Luna model gets billed. D2 fail-closed is defeated at the catalog layer, and no TF covers sync at all.
2. **Same-name two-rows collision.** D6 creates it, §8.7 lists it, but no TF asserts a chat call on `gpt-6-luna` picks the chat row, never the Decisions row. The eligibility filter is the only guard and is untested for the collision case.
3. **Grant-by-name billing exposure (auth UX).** D10 means granting `gpt-6-luna` to an agent silently authorizes the Decisions face, whose pricing is input-oriented and may bill on probe/400-validation paths. Operators cannot scope a key to chat-only.
4. **Error conflation / oracle.** Empty candidate set → 400 `protocol_requires_native` conflates "wrong face" with "unknown/denied model". Pin the precedence: unknown name → model-not-found (match other faces' code/status), else `protocol_requires_native`.
5. **Fixture gate.** All parser/usage correctness rests on a capture blocked on an operator key; "usage optional" is guide-derived and may be wrong (`prompt_tokens` vs `input_tokens`). Keep parsers stubbed and TF-D.6 unfalsifiable until capture.

**Contradictions / stale claims**
- §4.2 "Same envelope for `stream_not_supported` **with that code**" reads as code `protocol_requires_native` for streaming too, contradicting §4.7's `stream_not_supported`. Pin two codes, one envelope shape.
- §5.1 `usage_missing` is never added to the §5.2 enum table (metric label or log?).
- §2 "usage optional" vs §5.1 "assert exact field names" — fine only if capture lands.

**Missing first-ship requirements**
- Dashboard write gate: prove *all* nodes run post-migration beams (rolling deploy; followers lag). "Migrate all nodes first" needs an enforceable version/capability check.
- Decisions sync policy (allow-list of Decisions-native listings).
- Long-judgment timeout pinning; 300s idle may cut non-stream judging.
- Image `input` vs 10MB `MAX_BODY` interplay.

**Architecture/design notes**
- Mirror boundary (§4.2) is exemplary. Consider surfacing protocol in `/v1/models` entries later so SDKs know callable faces.

**Top 5 edits**
1. Rewrite §4.4: Decisions rows sync only Decisions-native listings (explicit allow-list), plus TF-D.9 for sync output.
2. Add TF-D.10: same-name chat+Decisions rows route per-face correctly.
3. Split the error table: `stream_not_supported` and `protocol_requires_native` as distinct codes; define unknown-model precedence.
4. Add an all-nodes-version gate before dashboard Decisions writes; document rollback trigger.
5. Add `usage_missing` to §5.2 and pin timeout + body-limit behavior for image input.
