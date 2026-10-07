---
model: mimo/mimo-v2.6-pro
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: mimo-v26-pro
---

**Verdict:** GO WITH FIXES — the design is unusually disciplined, but the probe cooldown/budget has no schema decision and D6's "one protocol per row" sits ambiguously beside the dual-face precedence cases.

**2. Critical risks**
- **Probe storage undecided** ("`providers.last_probe_at` (or sibling table)"): cooldown + per-day budget + audit log need a committed migration, yet the §6 gateway table lists only "CHECK migration, seed". Unmigrated state = budget enforced in memory, lost on restart, or ad-hoc columns added late.
- **Write-gate liveness race**: gate = "every *ready* node advertises". A flapping old node rejoins the ready set and silently blocks all provider create/enable; conversely a briefly-unready node hides a gap. Need a staleness bound on the node list and an explicit operator-visible reason string ("node X lacks openai_decisions").
- **D15 failure attribution**: "if not already signaled" is a scope landmine — gun distinguishes connect-fail (`gun_error`/`{error, closed}` pre-`gun_up`) from post-send only via message ordering. Also define the mid-body case: you forward status+body verbatim, but what does the client get if upstream dies mid-body after 200? Partial body + abrupt close needs a stated behavior.
- **Probe billability vs classification**: only 200s bill, but 20 probes/day against a non-Decisions endpoint burn budget and audit noise while staying "inconclusive" forever. O2 deferral is fine; cap consecutive-inconclusive days is not specified.

**3. Contradictions / stale claims**
- D6 "one protocol per provider row" vs §4.5/TF-D.14/D.19 "dual-face names", "other-protocol same-name". Presumably name-level across rows, but §4.5's auto-exclusion wording ("per-route protocol, not per-name") must be mirrored in D6 or readers will ship per-name logic.
- "exact message" table gives two codes for one UX (`protocol_requires_native` for both wrong-face directions) — intentional per D9, but then "no_route" for unknown names vs 400 for cross-face is an auth-UX cliff; document the discriminating signal for clients.

**4. Missing first-ship requirements**
- Probe cooldown/budget migration + table shape (see above).
- Responses-side regression TF after the D16 preamble extraction (shared helper must not alter Responses auth/body/request-id behavior).
- Rollback story mid-§6: what happens to already-created Decisions providers if a gateway rolls back (rows skip, log — stated in §4.1, but no TF asserts it).
- Grant-confirmation audit record storage/retention.

**5. Architecture notes**
- `readyz` protocols from handler presence is the right signal (config-drift-proof), but presence ≠ correctness; pair with one boot-time self-assert.
- Nested usage "one level" + null-safe metrics is a sane bridge; keep `unmapped` alerting gated to billable traffic as written.

**6. Top 5 edits**
1. Commit the probe cooldown/budget schema + migration to §6.
2. Resolve D6 vs dual-face wording explicitly (name-level dual-face allowed).
3. Specify mid-body upstream failure behavior under D15.
4. Add Responses regression TF to §7 for D16 extraction.
5. Add consecutive-inconclusive probe backoff + operator-visible write-gate deny reason.
