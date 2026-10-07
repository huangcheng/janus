---
model: alibaba/qwen3.8-max
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: qwen38-max
---

**Verdict:** GO WITH FIXES — the spec is unusually mature, but the write-gate reachability fallback, the CHECK-vs-unknown-protocol contradiction, and shared-proxy D15 regression scope must be closed before implementation start.

**Critical risks**
1. Write gate depends on dashboard→`:8080/readyz` on every cloud. If any firewall/container network blocks it (known pattern: stats_host is container-network-only on some clouds), fail-closed means Decisions providers can never be created there. No fallback (TTL-cached readyz / audited operator override).
2. D15 mutates the shared proxy failover path for all protocols; the only regression TFs listed are Decisions-specific. Chat/Responses failover could silently change.
3. Probe listing-selection rule is unspecified for providers with multiple listings; cooldown storage ("`last_probe_at` or sibling table") is still open — a first-ship schema choice cannot stay open.
4. 10 MiB ceiling: size check sits before JSON parse but must handle chunked bodies without Content-Length; buffering × concurrency is a real memory risk. Pin reject-before-read semantics.
5. D13 redaction covers request headers but not response bodies, which can echo org/account/project info back into a committed fixture.

**Contradictions or stale claims**
1. §4.1 "route only to nodes that can serve" — Janus has no inbound cross-node routing; catalog is per-node ETS and external DNS/LB picks the node. Mixed-fleet behavior is external-LB luck, not a designed property.
2. §6 "CHECK migration" conflicts with §4.1 "old beams skip unknown protocol rows": a CHECK constraint on protocol rejects future protocol rows at the DB layer before old-beam tolerance ever applies. Pick one.
3. §7 "local-green = D11 replay" still replays guide-excerpts even though D13 mandates the live fixture before implementation start; CI should replay the sanitized live capture.

**Missing first-ship requirements**
- Decisions upstream request/response timeout (gun request timeout, not just connect); large inline-image calls can exceed defaults.
- Rollback procedure for gateway rollback after `openai_decisions` provider rows exist.
- Explicit precedence row for `janus-auto` named on `/v1/decisions`.
- Audit-log destination for probe calls.

**Architecture/design notes**
- readyz `protocols` "derived from registered cowboy routes" is not actually introspectable post-boot; specify handler-module presence.
- Hard 400 on `Accept: text/event-stream` alone will break SDKs that always send it; gate primarily on body `"stream": true`.
- Grant confirm on every intersecting write invites click-through fatigue; scope it to writes that newly add Decisions coverage.

**Top 5 concrete edits**
1. Add write-gate fallback (cached readyz + audited override) and pin the protocols derivation mechanism.
2. Replace §4.1 routing claim with external-LB rollout behavior + exact agent-visible error during the mixed window.
3. Drop the CHECK constraint or document per-protocol migration flow; reconcile with §4.1.
4. Add a TF asserting D15 leaves chat/Responses failover unchanged; pin the gun request timeout for Decisions.
5. Resolve probe schema/listing selection now; narrow the stream guard to body `stream:true`.
