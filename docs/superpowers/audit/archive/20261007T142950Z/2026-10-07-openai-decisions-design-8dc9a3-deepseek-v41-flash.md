---
model: volcengine-ark/deepseek-v4-1-flash-260910
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: deepseek-v41-flash
---

**Verdict:** GO WITH FIXES — the fail-closed posture is sound, but the request pipeline order is self-contradictory and several referenced error codes are undefined.

**Critical risks**
- §4.2 pipeline `auth → grant check → body size → JSON parse` is impossible: the grant check needs the model name, which only exists after body parse. Reorder to auth → size → parse → stream guard → grant/eligibility → pick, or state the grant name comes from a header.
- §4.2 table defines only two codes; `blocked_no_listing` (§4.3), `provider_disabled`, `no_route`, `wrong_modality`, `request_too_large` are referenced but have no exact message. Error-contract drift.
- Write gate fails closed unless **every** ready node advertises `openai_decisions` over `GET :8080/readyz`. One unreachable/degraded node blocks all Decisions provider management fleet-wide — availability footgun. Define timeout/cached-advertisement/retry.
- `readyz.protocols` is assumed to exist. AGENTS.md documents only `:8090 /stats`+`/metrics`; confirm `:8080/readyz` and the field name or this is a stale premise.
- D15 proxy change ("distinguish connect-fail vs post-send if not already signaled") touches the shared `failover_decide` path for **all** protocols. Scope it and add cross-protocol regressions, not just TF-D.15.

**Contradictions / stale claims**
- Chat naming a Decisions-only listing now returns `protocol_requires_native`, but AGENTS.md says chat naming a non-chat listing is rejected locally with `wrong_modality`. Amend the invariant or keep `wrong_modality` on the chat face.
- Precedence row "Disabled Decisions + no other protocol" offers two outcomes (`provider_disabled` or `no_route`) — not deterministic.
- Probe `questions[].type: "predicate"` is unverified against the guide; if wrong, every probe is inconclusive (O2 hides this until D13).

**Missing first-ship**
- Audit-log sink for probe calls; `MAX_BODY=10 MiB` vs Cowboy body-limit config and any shared constant collision; `x-request-id` collision with existing handling; `agent_host` discovery/firewall for dashboard→:8080; response-size cap.

**Architecture notes**
- D16 helper extraction risks the Responses path; TF-D.18 (translate-knob invariant) is the right guard — keep it blocking.
- Name-only `/v1/models` visibility with no protocol hint (D3) plus `protocol_requires_native` is confusing UX; reconsider a face hint despite D3.

**Top 5 edits**
1. Fix/justify the pipeline order.
2. Complete the error table.
3. Make the precedence row single-valued.
4. Scope the connect-fail refactor + all-protocol regressions.
5. Define write-gate behavior when a node is unreachable.
