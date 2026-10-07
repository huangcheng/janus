---
model: minimax-cn/MiniMax-M3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: minimax-m3
---

**Verdict:** GO WITH FIXES — design is close to shippable, but the D15 failover contract and O1/O2 pin-or-block question are not falsifiable as written, and the precedence table is ambiguous in two rows.

**Critical risks**
- D15 ("connect-only failover for `openai_decisions`") names no gun signal. The proxy change is unfalsifiable without naming connect-fail tuples (`gun_response` `{conn_error,_,_}` / `{tls_error,_,_}` vs `{http_error,_,_}` / `{stream_error,_,_}`). Today gun errors funnel into one branch; teaching the proxy is non-trivial scope.
- O1/O2 remain open past "implementation start". Usage field names and the 404/405 "not Decisions" classifier gate test fixtures. If D13 slips, the design ships with no usage mapping and a "deferred to D13" probe heuristic — both quietly user-visible (cost null, false-positive connectivity).
- Write-gate wedging: dashboard node list is a snapshot. A newly added node that hasn't started `:8080/readyz` blocks `enabled=1` forever. No reconciliation path described.
- Header policy silent on client-supplied `OpenAI-Organization` / `OpenAI-Project`. D non-goal says "do not invent" — but does the proxy strip or forward? Forward = cross-account spoofing.
- Grant-confirm UX unspecified. Default-on → rubber-stamp; default-off → friction. Audit integrity stakes.

**Contradictions / stale claims**
- §4.5: "only disabled Decisions + other protocol exists → `protocol_requires_native`" and the next row "Disabled Decisions + no other protocol → `provider_disabled`/`no_route`" overlap when both protocols are disabled. Disambiguate.
- "r1–r4 GO WITH FIXES folded" — no diff markers; reviewer cannot tell what changed this round.
- §6 says "Router hard-block" but D14 is "manual listings only". Define the surface.
- D6 (one protocol per row) vs §4.5 "dual-face names" — dual-face must come from Router multi-binding, not provider rows. State it.

**Missing first-ship requirements**
- Sanitization tool + fixture script (not just policy). Owner, path, CI cadence.
- Idempotency-key dedupe on retries (Decisions supports it).
- Mixed-fleet operator doc as a shipped artifact, not a "required" note.
- Listing-add confirm copy + default + audit viewer for "who accepted".
- Negative TF: chat client naming Decisions-only listing never emits `wrong_modality`.

**Architecture / design notes**
- D16 shared preamble implies a Responses refactor. Either pin it in this PR or stage it explicitly.
- 10 MiB body ceiling pre-grant check (per §4.2 order): document that giant malformed bodies still pay the grant lookup.
- 20/day probe budget + 5 min cooldown → peak ~20/provider/day, not unbounded. UI should show "X remaining today", not just a cooldown clock.
- "Per-route protocol" needs a definition of "route" (listing? provider-row?) inside the auto router.

**Top 5 concrete edits**
1. In D15, enumerate the exact gun error tuples that constitute "connect-fail" and write a negative TF (asserts HTTP 200 response → no second upstream, even when retry-budget remains).
2. Promote O1/O2 to hard blockers: pin field names / classifier heuristic now, or move D13 ahead of code-start (not just ahead of prod claims).
3. Rewrite §4.5 into disjoint rows: name only on disabled Decisions + other protocol exists → `provider_disabled` (not `protocol_requires_native`); name only on chat + Decisions live → `protocol_requires_native`; both protocols disabled → `provider_disabled`.
4. Add explicit header policy: strip `OpenAI-Organization`, `OpenAI-Project`, and any `OpenAI-*` header the client supplies to a Decisions call. Document why.
5. Specify write-gate reconciliation: dashboard polls each known gateway `:8080/readyz` on a heartbeat; a node missing heartbeat for N seconds is excluded from the gate, not counted against it. Ship the heartbeat cadence in §6.
