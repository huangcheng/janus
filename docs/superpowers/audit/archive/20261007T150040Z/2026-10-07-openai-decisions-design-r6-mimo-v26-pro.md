---
model: mimo/mimo-v2.6-pro
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: mimo-v26-pro
---

**Verdict:** GO WITH FIXES — the decision log is unusually rigorous (falsifiable D15, hard-gated O1/O2), but a few contracts are underspecified or self-contradictory before this is implementable.

**2. Critical risks**
- `in_flight` in `provider_probe_state` has no lifecycle spec: after dashboard crash mid-probe the flag sticks and (per cooldown logic) may block probes forever. Needs TTL/reset-on-boot + transactional acquire, and a test.
- D12 10 MiB full-body buffering × concurrency = memory DoS on the agent listener; no per-node concurrency bound stated.
- Write gate calls `GET :8080/readyz` with 3s timeout per node — sequential across N nodes this freezes the create UI; specify parallel fan-out and the registry-heartbeat skew case (node up, heartbeat stale → blocked, but is that the intent?).
- `x-request-id` "mint/echo" is ambiguous when a client supplies one — echo allows client-controlled correlation IDs in logs; pin the precedence.
- Probe job holds stored provider keys server-side; audit rows exclude keys/bodies (good), but job exception logging must also redact.

**3. Contradictions / stale claims**
- §4.2 "60 s to first byte (align AGENTS idle reality)" contradicts AGENTS.md: idle_timeout is 300s *because* upstreams may take 60s+ to first byte. 60s is tight against that very reality.
- D9 "AGENTS.md + existing TFs updated in same commit" — AGENTS.md lives in `Janus`, TFs in `janus-dashboard/docs`; cross-repo "same commit" is impossible. Say paired PRs.
- Rollback claim "old dashboard enum = existing rows display as unknown protocol read-only" is asserted, not derived: old validators/serializers may crash on unknown enum values. Prove it.
- Precedence row 3 (stream before no_route) means `stream:true` + unknown model leaks `stream_not_supported` instead of `no_route` — confirm intentional.

**4. Missing first-ship requirements**
- TF for break-glass override (role + reason + audit) and for probe budget exhaustion / stale `in_flight`.
- Downgrade test (old beams skip Decisions rows → Decisions-only names become `no_route` on all faces) is described in §6 but has no TF.
- Dashboard registry protocol: node inventory source and split-brain (two dashboards) unstated.

**5. Architecture notes**
- Eligibility-before-`wrong_modality` split (D9/D13) is sound and the `no_route`/`provider_disabled`/cooling partition is finally disjoint.
- D15 pre-send-only failover with byte-identical other-face regression is the right falsifiable shape.
- Unauthenticated `readyz` protocol advertisement is a fingerprinting surface; "accepted" is fine but log it as an ADR.

**6. Top 5 edits**
1. Pick the first-byte timeout value explicitly; drop the false "align AGENTS" justification.
2. Rewrite D9 as paired cross-repo PRs.
3. Spec `in_flight` lifecycle (TTL, boot reset, transactional acquire) + TFs for budget exhaustion and stale flag.
4. Add downgrade/rollback test rows (old dashboard rendering unknown enum; old beams + Decisions-only name).
5. Pin `x-request-id` precedence and state whether the handler validates `answers` shape on passthrough (recommend: no — native).
