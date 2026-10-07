---
model: zhipuai-coding-plan/glm-5.3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: glm-53
---

**Verdict:** GO WITH FIXES — a mature round-5 design with sound gating (D13 before code), but the stated pipeline order is internally impossible and three failure-path contracts are unspecified.

**Critical risks**

1. **Pipeline contradiction:** §4.2 orders `grant check` before `JSON parse`, but grants are keyed by model name (§4.4, `api_key_models`), which only exists after parsing. As written the pipeline cannot execute; implementers will silently reorder.
2. **D15 gap:** the dichotomy is connect-fail vs "any HTTP response or mid-body failure". Missing case: connect OK but upstream never responds (gun timeout, no status) — exactly the 60s+-to-first-byte scenario AGENTS.md documents. Failover-eligible or terminal? Client-facing status undefined.
3. **Shared-code regression:** D15 connect/post-send signaling and D16 preamble extraction touch live chat/responses/anthropic paths. No stated invariant or TF that non-Decisions failover semantics stay byte-identical.
4. **Write-gate fail mode:** if a node is unreachable from the dashboard at provider-create time, does the gate fail open or closed? Fail-closed wedges ops on network blips; fail-open defeats the gate.
5. **New `/readyz` on public :8080:** protocols array on the agent-facing listener is an unauthenticated capability disclosure; confirm acceptable.

**Contradictions / stale claims**

- D11 claims live replay gates merge/CI; the live fixture is absent (own self-review). CI gate is guide-excerpt only today — state the live half activates at D13.
- `providers.last_probe_at (or sibling table)` — unresolved either/or in an otherwise "locked" decisions table.

**Missing first-ship requirements**

- Probe listing-selection rule when a provider has multiple listings ("selected listing" undefined).
- Rollback story for the shared proxy refactor — old-beam protocol-row skip does not cover D15/D16 changes to shared paths.
- O1 usage keys pinned only "with D13", yet the cost UI, metrics allowlist, and redaction assert all depend on them; make the ship-blocker explicit.

**Architecture / design notes**

- Single shared eligibility predicate (LB + dispatch + auto) is right; TF-D.19 covers auto only — add a TF asserting all three consumers agree on dual-face names.
- Guide-excerpt eunit fixtures skirt the project's own fixture-realism rule; tolerable only because D13 gates implementation start. Keep excerpts verbatim-pasted, never retyped.

**Top 5 concrete edits**

1. Reorder §4.2: auth → body size (413) → JSON parse → grant (name from parsed body) → stream guard → pick; keep grant before stream errors per §4.5.
2. Add explicit D15 case: connect-OK-but-no-response → terminal, no repick, defined error code + client status; add TF-D.20.
3. Add invariant + regression TF: non-Decisions protocols retain exact current `failover_decide` behavior after the connect/post-send signal lands.
4. Specify gate semantics: unreachable node = blocked with per-node reason in UI and retry hint; define node-list membership (registered vs heartbeat).
5. Resolve probe storage to one schema and add a listing-selection rule (e.g., first enabled listing, or probe all).
