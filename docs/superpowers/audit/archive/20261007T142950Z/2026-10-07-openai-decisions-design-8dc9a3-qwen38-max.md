---
model: alibaba/qwen3.8-max
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: qwen38-max
---

**Verdict:** GO WITH FIXES — coherent design with correct D13 gating, but the §4.2 pipeline contradicts its own precedence table, and the readyz write gate has an operational lockout path that must be closed before implementation.

**Critical risks**
- §4.2 pipeline: `auth → grant check → 413 → JSON parse`. Grant check needs the parsed `model`, so it cannot precede JSON parse; §4.5 additionally requires grant-deny before stream errors. An implementer will pick one order and TFs will encode the other.
- Write-gate lockout: creation requires **every** node in the dashboard's node list to advertise on `:8080/readyz`. A transient dashboard→gateway network failure, a stale node-list entry, or a mid-restart node blocks all Decisions provider creation indefinitely, with no override. The kill-switch exemption only covers disable.
- `/readyz` semantics undefined: does it exist on :8080 today (admin endpoints live on :8090)? Does it return 200 before catalog load/migration finish? A half-booted node could pass the gate.
- D15 "TCP/TLS establishment failure" is ambiguous about DNS resolution and cert-verify failures; without an explicit gun-error classification list, the connect-vs-post-send signal will be guessed.
- 10 MiB bodies × unbounded concurrency — no memory/backpressure note.

**Contradictions or stale claims**
- §4.2 pipeline vs §4.5 precedence (above).
- AGENTS.md states chat calls naming non-chat listings get `wrong_modality`; D9 carves Decisions out, but no TF covers the **chat-client side** naming a Decisions-only listing (TF-D.14 only covers Decisions-face precedence).
- §4.3 "upstream_requests_total / decisions_upstream_429_total **as appropriate**" conflicts with §5's label scheme — pick one.

**Missing first-ship requirements**
- readyz contract: 200-only-when-ready; old-node 404 must read as "not advertised", not crash the gate.
- Dashboard-side storage migrations for grant-confirmation audit ("who accepted") and probe audit log — referenced in §4.3/§4.4 but absent from the §6 table.
- Node-unreachable-vs-old distinction plus a documented ops bypass for the write gate.
- TF: chat client → Decisions-only name → `protocol_requires_native`, never `wrong_modality`.
- D13 redaction: strip URL query strings/userinfo too, not just headers.

**Architecture/design notes**
- D16 is right, but the preamble extraction needs a TF asserting the Responses face behaves byte-identically on existing fixtures pre/post, else an untested refactor rides along.
- "Protocols from routes, not hardcoded strings" still hardcodes a route→protocol map; colocate it with route registration so they can't drift.
- Refusal-only 200 = probe OK is pragmatic; log a body hash for the deferred O2 classifier.

**Top 5 concrete edits**
1. Reorder §4.2: auth → 413 → JSON parse → grant → stream guard → proxy pick; make §4.5 cite that exact order.
2. Add a readyz contract section (existence on :8080, ready-only 200, 404 = not advertised) plus node-list staleness handling/bypass policy.
3. Extend D15 to explicitly classify DNS and TLS-verify failures as connect-fail; enumerate the gun error shapes.
4. Add dashboard audit-storage migrations (grant confirm + probe log) to the §6 table.
5. Add the two missing TFs: chat-side wrong-face message, and Responses-face regression diff for D16.
