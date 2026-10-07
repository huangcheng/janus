---
model: mimo/mimo-v2.6-pro
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: mimo-v26-pro
---

**Verdict:** GO WITH FIXES — the design is thorough and fail-closed, but an internal pipeline-order contradiction and two unbounded contracts (failover signaling, write-gate node liveness) must be fixed before implementation.

**2. Critical risks**
- **Pipeline order is unsatisfiable as written.** §4.2: "auth → grant check → body size → JSON parse" — but grants are by model *name*, which lives in the body. You cannot run the grant check before parsing. As written, either grant checks use a pre-parse hack or 413/JSON errors silently precede/bypass grant semantics.
- **D15 "teach the proxy to distinguish connect-fail vs post-send"** is an unbounded refactor of `failover_decide` shared by *all* protocols. Gun's error signals don't cleanly delineate "bytes started"; a subtle misclassification silently re-enables post-send failover (double-billed requests) or disables connect-failover for chat.
- **Write gate outage coupling:** if the dashboard's node list is stale or one `:8080/readyz` is unreachable, provider creation is bricked with no documented override. No timeout budget, no force flag, no stale-node policy.
- **Probe false-OK:** "refusal-only 200 → OK" can classify a non-Decisions endpoint that returns a generic refusal as healthy; O2 defers the body classifier, so budget-daily probes may be wasted billable calls.
- **Verbatim upstream error forwarding** may leak upstream bodies (org/account identifiers) to agent clients.
- **Usage unmapped (O1)** on billable traffic = silent cost under-reporting in the dashboard UI.

**3. Contradictions / stale claims**
- §4.2 pipeline vs §4.5 "Grant deny … before stream/face errors" — order can't hold without parsing first (above).
- Chat client naming a Decisions-only listing now gets `protocol_requires_native`, *not* `wrong_modality` — a behavior change to existing faces with no regression TF listed for the current chat path.
- Self-review still has "Live fixture on disk" unchecked while §7 claims production-green framing; fine, but keep D13 a hard gate.

**4. Missing first-ship requirements**
- Regression TF for Responses auth/body/request-id behavior after the D16 preamble extraction (the highest-blast-radius change).
- Write-gate: unreachable-node policy, timeout, audited operator override.
- Probe/grant-confirm audit-log schema and retention.
- `readyz` on `:8080` — auth/leak assessment (agent-facing port now exposes fleet protocol inventory).
- Hard gate: no billable prod traffic until O1 usage keys are pinned (not merely "with D13").

**5. Architecture notes**
Approach A (fourth face, no polyfill) is right; D9/D2 fail-closed ordering and per-route auto exclusion are sound. Kill-switch exemption to the write gate is correct.

**6. Top 5 edits**
1. Reorder pipeline to: auth → body size → parse → grant → stream guard; state exact precedence of 413 vs grant deny.
2. Specify the connect-vs-post-send signal contract (gun message mapping) + a TF-D.15 sub-assert that *other* protocols' failover is unchanged.
3. Add write-gate liveness policy (timeout, stale list, audited force-override) and TF-D.16 case for unreachable node.
4. Tighten probe OK: require `answers` schema shape, not refusal-only; gate billable traffic on O1.
5. Add regression TF: existing chat/Responses error codes unchanged except the documented Decisions-name case.
