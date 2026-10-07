---
model: volcengine-ark/deepseek-v4-1-flash-260910
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: deepseek-v41-flash
---

**Verdict:** GO WITH FIXES — the pipeline and precedence are unusually well specified, but it bundles two shared-code refactors with a new face and leaves probe billability and `in_flight` recovery undefined.

**Critical risks**
- **Probe is billable but ungated.** §4.3 probe calls the upstream with the stored key; §Gates say "no billable prod traffic until O1 pinned from D13." A create-time probe *is* prod traffic. Either exempt probe explicitly or block it under O1 — today it contradicts the gate.
- **Two shared refactors ride a new feature.** D15 rewrites shared `failover_decide` and D16 extracts the shared preamble, both "in this change," guarded only by TF-D.15/TF-D.20. A new face should not carry byte-identical-failover risk for chat/Responses/Anthropic. Sequence separately.
- **Probe table has no race/recovery contract.** `provider_probe_state` has `in_flight` but no unique constraint, no expiry, no crash-clear. Concurrent creates can double-probe; a crashed job can wedge it. Cooldown "transactional" is asserted, not specified.
- **`<F>`/`<P>` face tokens undefined.** `protocol_requires_native` message interpolates faces, but no canonical face identifiers are pinned. TF-D.2/D.3 assert "message has faces" without a literal.
- **Break-glass override** is the only thing keeping a partitioned fleet usable; "role + reason" is thin for bypassing fail-closed. Require expiry + alert.

**Contradictions / stale claims**
- §4.1 "CHECK does not reject reads" vs §4.5 #6 `provider_disabled`; old-beam rollback silently drops the row while grants dangle — rollback section never cleans grants.
- D13 fixture "size cap" is asserted but never numbered, unlike D12's 10 MiB.
- §4.3 says all 404/405 → inconclusive until O2, so a wrong-path provider never reads as bad; write gate can still enable it.

**Missing first-ship requirements**
- No runtime kill-switch TF (only write-gate disable).
- No alert thresholds for `decisions_upstream_429_total`.
- No request/response schema for `/v1/decisions` beyond "guide shapes."
- No `readyz` semantics after handler hot-reload (captured at listener start → stale).

**Architecture notes**
- Distributed all-nodes-readyz gate is correct fail-closed but fragile; 3 s per node under a slow follower blocks all writes.
- Redaction is strong (logs = id/model/status/latency; base64 never logged) — keep it.
- Precedence table is genuinely disjoint; ship it as the normative test oracle.

**Top 5 edits**
1. State whether probe traffic is billable; gate or exempt under O1.
2. Split D15/D16 into their own commits with independent regression gates.
3. Pin literal face/protocol tokens for `protocol_requires_native`.
4. Add `provider_probe_state` unique key + `in_flight` expiry/recovery.
5. Add kill-switch TF and `readyz` post-hot-reload behavior.
