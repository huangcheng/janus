---
model: alibaba/qwen3.8-max
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: qwen38-max
---

**Verdict:** GO WITH FIXES — round-3 spec is tight, but billing-retry semantics, an unmapped-usage blind spot, and a circular probe dependency must be pinned before implementation.

**2. Critical risks**
- **`no automatic retry` collides with LB failover.** §4.3 forbids retry (double-billing), but `janus_lb` failover semantics are unspecified for this face. Failover after request bytes left the gateway = double-billing; failover on connect-refused is safe. Silence here is the most likely shipped bug.
- **Grant widening is a billing risk, not an attempt risk.** D10 says adding a Decisions row widens faces a key "can attempt" — wrong: on the correct face calls *succeed and bill* under an existing name grant. The one-liner understates this.
- **Probe OK-path is circular.** A 400 "fingerprints Decisions" via an allowlist "finalized from live capture" — which is the ship gate and absent. Until then, a generic upstream 400 can produce a false OK; §8 names this failure mode without resolving it.
- **Usage present-but-unmapped is invisible.** `janus_usage_missing` fires only when `usage` is absent. If live `usage` uses unrecognized key names, rows silently go null-token with no metric — cost dashboards read zero without alarm.
- **Probe with empty inventory.** Probe model = listing's upstream name; behavior when the provider has no listings yet (pre-sync) is undefined.

**3. Contradictions / stale claims**
- §4.3 lists **405** as "not Decisions", but §7's eunit classifier list covers only 200/400/401/403/404/5xx — 405 missing.
- §4.3 write gate waits until "gateway generation/min-version advertises Decisions support", but nowhere defines what carries that advertisement (field, table, or API).

**4. Missing first-ship requirements**
- Explicit failover contract for native POST (pre-send vs post-send).
- Concrete signal the dashboard reads for the write gate.
- Post-deploy canary checklist: prod smoke is read-only and TF-D.1 never runs against production, so the first live prod call is operator-driven and unscripted.
- Error precedence among oversized-body (413), malformed JSON, and stream-guard when a body is both huge and `"stream": true` / non-JSON.

**5. Architecture/design notes**
- Face-as-protocol-eligibility over existing LB/catalog is the minimal-diff choice; D5′ precedence table correctly closes the empty-set cases.
- Old-beam `normalize_protocol` skip keeps rolling rollout crash-free; accept transient cross-node candidate-set divergence mid-rollout (worth one sentence in §4.1).
- No face knob (D8) is consistent; rollback via `enabled=0` suffices.

**6. Top 5 concrete edits**
1. §4.3: allow failover **only** on connection-establishment failure; any post-send failure returns upstream error verbatim, no second upstream attempt.
2. §2/§5: add `janus_usage_unmapped{protocol="openai_decisions"}` for 200-with-unrecognized-usage-keys.
3. §4.3: until live fixture exists, treat non-allowlisted 400 as `probe_inconclusive`, never OK.
4. §4.3: name the exact field/mechanism the dashboard write gate reads.
5. §4.4: reword grant copy to "enables billable Decisions calls" and add a dashboard confirmation when a new Decisions provider's names intersect existing grants. Also add 405 to §7's classifier list.
