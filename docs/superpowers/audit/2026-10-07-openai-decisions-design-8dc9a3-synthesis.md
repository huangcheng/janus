# Synthesis — OpenAI Decisions API Design Spec (round 5)

**Date:** 2026-10-07
**Target:** `2026-10-07-openai-decisions-design-8dc9a3-target.md` (source: `docs/superpowers/specs/2026-10-07-openai-decisions-design.md`)
**Panel (7/7 PASS):** minimax-cn/MiniMax-M3, mimo/mimo-v2.6-pro, stepfun/step-5-preview, alibaba/qwen3.8-max, volcengine-ark/deepseek-v4-1-flash-260910, zhipuai-coding-plan/glm-5.3, kimi-for-coding/k3
**Arbiter:** alibaba/qwen3.8-max · **Quorum:** met (7 ≥ 5) · **Degraded:** no · **Consensus threshold:** ≥ ceil(7×0.7) = **5/7**

## 1. Verdict table

| Slug | Verdict |
|------|---------|
| minimax-m3 | GO WITH FIXES |
| mimo-v26-pro | GO WITH FIXES |
| stepfun-5 | GO WITH FIXES |
| qwen38-max | GO WITH FIXES |
| deepseek-v41-flash | GO WITH FIXES |
| glm-53 | GO WITH FIXES |
| kimi-k3 | GO WITH FIXES |
| **Overall** | **GO WITH FIXES** (unanimous 7/7; fixes in §4 below gate implementation start) |

## 2. Consensus (≥ 5/7)

**C1 — D15 failover contract is unfalsifiable and touches shared proxy code (7/7).**
"TCP/TLS establishment failure" names no gun-level signal. All seven flag that connect-fail vs post-send is not cleanly signaled today (pooled/HTTP2 reuse, write-fail on stale conn), that misclassification means double-billing or lost failover, and that the change lands in `failover_decide` shared by all faces. 4/7 additionally demand an explicit invariant + regression TF that chat/Responses/Anthropic failover stays byte-identical. glm adds a missing case: connect-OK-but-no-response (the documented 60s-to-first-byte world) is neither classified nor given a client-facing status.

**C2 — Write gate has no failure semantics (7/7).**
Every reply flags: unreachable/down/flapping node in the dashboard's node list, stale list, dashboard→`:8080` firewall-blocked on some cloud → fail-closed bricks provider creation forever; no timeout, no TTL, no audited override, no reconciliation. kimi adds TOCTOU (node rolls back between check and first request). deepseek: reachability is verified at step 8, after dashboard deploy — too late.

**C3 — Probe contracts are still open in a "locked" spec (7/7).**
Converging demands: pick one storage schema (kill "`last_probe_at` (or sibling table)"); define listing-selection rule for multi-listing providers; pin execution owner and whether probes write `usage_events`; audit log must exclude keys/response bodies; refusal-only 200 → OK can false-positive a generic refusal (mimo, deepseek) — require `answers` array shape; show budget remaining; justify/configure the ~10 s timeout against the 60s-first-byte reality; concurrency-lock test.

**C4 — Remaining either/or hedges must be pinned before implementation (5/7: minimax, stepfun, qwen, deepseek, glm).**
`last_probe_at` vs sibling table, `upstream_requests_total` vs dedicated 429 counter ("as appropriate"), O1 usage keys, O2 classifier. First-ship schema and label-set choices cannot stay open; §7's "TF-D.1…D.13 as before" must be enumerated (413/405/Retry-After/429 cases).

## 3. Near-consensus / objective gaps (below 5/7)

**Objective gaps — logical contradictions, apply regardless of vote count:**

- **G1 (2/7, mimo + glm): §4.2 pipeline is unsatisfiable.** Grant check is ordered before JSON parse, but grants are keyed by model name, which exists only in the parsed body. As written the pipeline cannot execute; implementers will silently reorder. Both converge on: auth → body size (413) → parse → grant → stream guard → pick, keeping grant before stream/face errors per §4.5.
- **G2 (2/7, qwen + deepseek): CHECK migration vs old-beam tolerance.** §6's protocol CHECK constraint rejects unknown-protocol rows at the DB layer, which directly defeats §4.1's "old beams skip unknown protocol rows" story. Pick one.
- **G3 (2/7, qwen + deepseek): §4.1 "route only to nodes that can serve" has no mechanism.** Catalog is per-node ETS; there is no inbound cross-node routing — mixed-fleet behavior is external-LB luck. Rewrite as rollout behavior + exact agent-visible error during the mixed window; also, old-beam skip behavior is untested (a `case` without catch-all crashes).

**Near-consensus (3–4/7):**

- **N1 (4/7, minimax, mimo, deepseek, glm): O1/O2 must be hard gates.** No billable production traffic until O1 usage keys are pinned from D13; deepseek notes inconsistent gating — probe body fields are pinned pre-D13 while usage keys are D13-gated.
- **N2 (4/7, minimax, mimo, deepseek, kimi): D9 breaks the documented `wrong_modality` invariant** (see Ground truth). Needs AGENTS.md/test-expectation updates in one commit, and `protocol_requires_native` must name client face + required face since it now fires on both faces with opposite remediation.
- **N3 (4/7, mimo, deepseek, glm, minimax): D16 preamble extraction risks Responses.** Either land the Responses refactor in this change with a regression TF (auth/body/request-id unchanged) or stage it explicitly.
- **N4 (3/7, minimax, stepfun, deepseek): §4.5 precedence rows overlap/are nondeterministic.** Disabled-Decisions+other-protocol row collides with the next row; "`provider_disabled` **or** `no_route`" is not deterministic. Rewrite as disjoint rows.
- **N5 (3/7, kimi, glm, qwen): D11/D13 conflation.** State explicitly: guide-excerpt replay gates merge/CI now; live-capture replay activates at D13 and gates production claims.
- **N6 (3–4/7, stepfun, qwen, glm, kimi): unbounded upstream read / missing request timeout.** `?MAX_BODY` bounds the request only; a misbehaving upstream response is read without cap; no gun request timeout for Decisions; 10 MiB buffering × concurrency needs reject-before-read semantics for chunked bodies.
- **N7 (3/7, qwen, glm, kimi): rollback story absent** — gateway rollback with `openai_decisions` rows present, shared-proxy refactor rollback, dashboard enum-migration rollback.
- **N8 (3/7, minimax, qwen, deepseek): grant-confirm UX** — default, click-fatigue, re-prompting on unrelated writes to dual-face names, audit viewer for "who accepted".
- **N9 (3/7, glm, stepfun, mimo): `/readyz` on agent-facing :8080** — unauthenticated capability disclosure of fleet protocol inventory; confirm acceptability, confirm the endpoint exists, pin derivation mechanism (qwen: registered routes aren't introspectable post-boot — use handler-module presence).

## 4. Split opinions — decision owner: user (do not auto-apply)

| Topic | Panelist(s) | Claim |
|-------|-------------|-------|
| Strip client-supplied `OpenAI-*` headers on the Decisions face | minimax | Forwarding = cross-account spoofing; spec is silent (non-goal says "do not invent", not "strip") |
| Verbatim upstream error forwarding | mimo | May leak upstream org/account identifiers to agent clients |
| Stream guard on `Accept: text/event-stream` | qwen | Hard 400 breaks SDKs that always send it; gate primarily on body `"stream": true` |
| Dashboard↔gateway grant matcher parity | stepfun | Wildcard semantics must be identical both sides; divergence is a security hole |
| Idempotency-key dedupe on retries | minimax | Decisions supports it; spec silent |
| Rate limit / abuse control | deepseek | Billable face with no enable knob (D8) and no rate limiting |
| Alert allowlist race | kimi | Allowlist "ships same deploy" can still race; gate the alert on a flag |

## 5. Ground-truth notes (verified local facts cited)

- **deepseek-v41-flash** cites the AGENTS.md invariant *"a chat-family call naming a non-chat listing is rejected locally (`wrong_modality`)"* — **verified**: AGENTS.md architecture invariants state exactly this. D9's substitution of `protocol_requires_native` is therefore a real, documented-invariant break, not a hypothetical.
- **qwen38-max** cites the container-network-only reachability pattern — consistent with AGENTS.md's S.8 note (`stats_host` container-network-only on some clouds), which makes the write-gate's dashboard→`:8080` dependency a known-broken path, not a theoretical one. Also correctly notes catalog is per-node ETS with no inbound cross-node routing (matches AGENTS.md layout).
- **glm-53, kimi-k3** cite the Cowboy `idle_timeout => 300_000` / upstream-60s+-to-first-byte facts — **verified** in AGENTS.md; both use them legitimately (glm: D15's missing no-response case; kimi: the 10 s probe timeout may under-shoot healthy-but-slow providers).
- qwen's claim that cowboy route tables are not introspectable post-boot is a framework-level assertion — plausible, but verify at implementation time rather than treating as settled.

## 6. Top concrete edits for the live doc

1. **§4.2 — reorder the pipeline** (objective fix G1): auth → body size (413; body fully read with the 10 MiB cap **before** any upstream connect) → JSON parse → grant check (name from parsed body) → stream guard → proxy pick. Keep grant-before-stream-errors (§4.5); state exact precedence of 413 vs grant deny.
2. **D15 — make it falsifiable:** enumerate the exact gun-level signals that constitute connect-fail (pre-request-bytes TCP/TLS failure) vs terminal (any HTTP status received, mid-body failure, **connect-OK-but-no-response timeout** — define its client-facing error code). Add the invariant: failover behavior for chat/Responses/Anthropic is unchanged; add cross-protocol regression TFs plus a Decisions TF asserting no second upstream after any HTTP response even with retry budget remaining. Pin the buffered-body-before-connect invariant that makes the split clean.
3. **Write gate — define failure semantics:** node-list membership (registry/heartbeat), per-node check timeout, unreachable node = blocked-with-reason (fail closed) + stale-node TTL + audited operator override; define "ready" freshness; state the per-request D2 fail-closed backstop for TOCTOU. Move dashboard→`:8080/readyz` reachability verification to step 5 (leader deploy), not step 8. Extend TF-D.16 with the unreachable-node case.
4. **Probe — pin everything:** execution owner (reuse existing gateway probe infra), listing-selection rule, one storage schema (transactional cooldown table with unique constraint + in-flight lock test), audit log excludes request bodies/keys/response bodies, per-probe cost estimate + "N remaining today" UI, refusal-only 200 requires `answers` array shape to count as OK (or stays inconclusive — decide), timeout configurable with justification vs 60s-first-byte.
5. **Promote O1/O2 to hard gates:** no billable production traffic until O1 usage keys are pinned from the D13 capture; pin probe request-body field names under the same D13 gate (fixes the current inconsistent gating); keep O2 classifier deferred with all 400/404/405 → inconclusive until then.
6. **D9 reconciliation:** update the AGENTS.md `wrong_modality` invariant text and enumerate existing eunit/TF expectations to change in the same commit; make the `protocol_requires_native` message name both the client face and required face; add a regression TF that existing chat/Responses error codes are unchanged except the documented Decisions-name case.
7. **§4.5 — disjoint, deterministic rows:** name exists but all eligible-face routes disabled → `provider_disabled`; name absent after filter → `no_route` (delete the "or"); name only on other protocol(s) → `protocol_requires_native`; add an explicit row for `janus-auto` named on `/v1/decisions`; add TF-D.14 variants and the chat-client→Decisions-only-name negative TF (never `wrong_modality`).
8. **Kill the hedges (C4):** choose `last_probe_at` vs sibling table now; define the `decisions_upstream_429_total` label set (drop "as appropriate"); enumerate TF-D.1…D.13 explicitly incl. 413/405/`Retry-After`/429; make the mixed-fleet ops note a shipped artifact stating the exact agent-visible error during the rollout window (fixes G3's wording too).
9. **Forward-path bounds:** upstream response byte cap (e.g., 32 MiB) with a new `upstream_response_too_large` error row in §4.2; pin the gun request timeout for Decisions; specify reject-before-read semantics for chunked/no-Content-Length request bodies.
10. **Split D11 wording:** guide-excerpt replay = merge/CI gate now; sanitized live-capture replay activates at D13 and gates production claims. Reconcile §7 ("local-green = D11 replay") accordingly.
11. **D16 staging:** either include the Responses preamble refactor in this change with a Responses regression TF (auth/body/request-id behavior unchanged), or stage it explicitly with its own TF entry.
12. **readyz decisions:** confirm `/readyz` exists on :8080 today; accept or mitigate unauthenticated protocol-inventory disclosure; pin `protocols` derivation as handler-module/route presence captured at boot; note backward compatibility for existing readyz consumers.

**Gate summary:** Overall **GO WITH FIXES**. Edits 1–12 should be folded into a round-6 target before implementation start; edit 1 and items G1–G3 are textual contradictions requiring no judgment. Split items in §4 await your call.
