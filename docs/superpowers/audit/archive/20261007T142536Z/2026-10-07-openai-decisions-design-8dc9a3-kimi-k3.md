---
model: kimi-for-coding/k3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: kimi-k3
---

**Verdict:** GO WITH FIXES — the spec is mature and internally consistent, but the readyz write-gate semantics, grant-confirm bypass, and probe-classifier fixture gap need pinning before implementation.

## Critical risks

1. **Write gate is TOCTOU-flaky.** "≥1 ready node advertises" + dashboard polling with unspecified cadence means the gate opens while old followers still `no_route` (spec accepts this) — but then the operator's *first write* can succeed while most traffic fails. Also "any" vs "all" is never stated. Advertisement source is ambiguous ("once beams support the face") — a hardcoded list risks advertising on a node that can't route.
2. **Grant-confirm only on provider creation** (§4.4). Adding a Decisions listing *later* to an existing provider silently widens billing for any key already granted that name — the exact risk D10 was written against.
3. **Probe cooldown (≥60 s/provider) has no stated mechanism.** Dashboard is multi-process (uvicorn workers); an in-memory cooldown won't hold. Needs a DB row (`last_probe_at`) with transactional guard.
4. **Probe 404 classifier is unfounded.** "404/405 without model-not-found ambiguity → not Decisions" requires parsing OpenAI error bodies the guide never shows. Only O1 (usage keys) is listed as open; this belongs there too.
5. **Precedence hole in §4.5:** name exists on *both* a disabled Decisions row and another protocol — table covers each case alone, not combined. `provider_disabled` vs `protocol_requires_native` is unpinned.

## Contradictions / stale claims

- D8 (no face knob) vs §6 step 9 "Feature kill: `enabled=0` providers" — that's per-provider disable, not a kill switch; an operator with many listings has no single off-ramp. Either own the wording or add the knob.
- §4.3 org/project passthrough "if already implemented; else out of scope" — undecided language in a "locked" spec; check the existing OpenAI face and state it.
- Dashboard rollback with Decisions rows in DB (old enum validators) is unaddressed.

## Missing first-ship requirements

- Probe-result metrics (`decisions_probe_total{outcome=…}`) — §5 covers traffic metrics only.
- Ops doc for mixed-fleet `no_route` window is promised (§4.1) but not in the §6 deliverables table.
- TF for the combined disabled+other-protocol precedence case.

## Architecture notes

Single shared eligibility predicate (§4.5) and preamble extraction (§3A) are the right calls. D15 (no post-send failover) correctly avoids double-billing; verify the shared proxy actually *has* a retry to suppress — if not, D15's "explicit suppression" is vacuous and should say so.

## Top 5 concrete edits

1. §4.3: make readyz advertisement derived from the registered handler, and define the write gate as "all serving gateway nodes advertise" (or explicitly accept any-node with a routed-traffic caveat).
2. §4.4: move the grant-intersection confirmation into the listing-add API path, not provider creation.
3. §4.3 probe: persist `last_probe_at` per provider in Postgres; enforce cooldown transactionally.
4. §9: add O2 "probe 404 body classifier" gated on the D13 live fixture.
5. §4.5: add the dual-row (disabled Decisions + other protocol) row to the precedence table and a matching TF-D.14.
