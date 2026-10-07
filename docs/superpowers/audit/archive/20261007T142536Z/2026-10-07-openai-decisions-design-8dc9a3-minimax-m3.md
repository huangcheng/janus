---
model: minimax-cn/MiniMax-M3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: minimax-m3
---

**Verdict:** GO WITH FIXES

**Critical risks**

1. **Probe bills Luna.** Cooldown ≥60s (§4.3) is too aggressive for a tier that bills per call. A provider failing probe repeatedly racks up real costs. Default must be operator-configurable, minimum ≥5 min, with a per-day probe cap.
2. **Grant intersection is a modal, not a block.** §4.4 "show confirmation that those keys can now make billable Decisions calls" — if the operator dismisses, existing keys still get billed silently. Either block on decline, or persist the operator's choice to the audit log with their identity.
3. **Pre-send failover can double-bill on client retry.** D15 acknowledges the risk but the spec never propagates OpenAI's `Idempotency-Key` header. Required for any tier billed to consumers.
4. **Probe classifier ambiguous on valid 200-bodies.** §1 lists `refusal` as a billable answer type; §4.3 says "OK: 200 + answers array". Empty `answers`, single `refusal`, `predicate`/`choice`/`score` — call out explicitly which count as OK vs inconclusive. As written, a probe returning `refusal` could be marked inconclusive and silently re-probed → bills again.
5. **Write gate is a deadlock trap.** Server-side readyz only — if all gateway nodes are briefly unhealthy (rolling rollout, DB hiccup), the dashboard cannot create Decisions providers. Cache last-known advertisement with TTL.

**Contradictions / stale claims**

- §6 step 2 ("merge on guide replay only when no key") vs step 8 ("prod launch = operator live TF-D.1 once") — make explicit that guide-only passes the merge gate but is not production-cert evidence; document the runbook.
- §4.5 precedence table lists `protocol_requires_native` before the cooling row, but the surrounding text says "grant-deny before face errors". Move grant-deny to the top explicitly.

**Missing first-ship**

- `Idempotency-Key` passthrough + "no retry" caller doc.
- Per-key or per-provider billing cap / circuit breaker.
- Hot-reload semantics: how does readyz advertisement update after a settings generation bump? Polling cadence?
- `OpenAI-Organization` / `OpenAI-Project` passthrough is delegated to "out of scope = do not invent" — but tier-billing endpoints commonly require it; without a default policy, expect spurious auth failures.

**Architecture / design notes**

- Good: single shared eligibility predicate (§4.5); protocol-eligibility before `wrong_modality` (D9); structural 200+answers probe gate.
- Bad: "extract or copy carefully" preamble — drift risk either way; pick extract and document the dependency direction.
- Bad: "Decisions-capable public names" list undefined; define as `provider.protocol == openai_decisions`.
- Bad: same-name dual-face ETS keys reference `SCHEMA_ETS_CONTRACT.md` — verify the contract supports per-provider same-name; if not, hidden footgun.
- Synthesis doc referenced but not provided; trusting that r1–r3 fixes are folded.

**Top 5 concrete edits**

1. Probe cooldown: operator-configurable, default ≥5 min; cap probes/day per provider.
2. Probe classifier: explicit 200-body matrix covering empty `answers`, `refusal`, `predicate`/`choice`/`score`.
3. `Idempotency-Key` header passthrough; document server-side no-retry.
4. Grant intersection: block on decline (or persist operator's choice with identity in audit log).
5. Write gate: cache last-known readyz advertisement with TTL to avoid deploy-deadlock.
