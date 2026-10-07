---
model: volcengine-ark/deepseek-v4-1-flash-260910
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: deepseek-v41-flash
---

**Verdict:** GO WITH FIXES — the design is disciplined, but D15's shared-proxy change and D9's break of an existing invariant are under-specified for a billable face.

**Critical risks**
- D15: "TCP/TLS establishment failure" has no defined signal. Gun connection pools/HTTP2 reuse blur connect-fail vs write-fail; a stale pooled conn failing on write could be misread as connect-fail and repick after bytes started — double billing. This proxy change is shared by every face; TF scope must cover chat/responses/anthropic, not just Decisions.
- Write gate: dashboard→agent `:8080/readyz` may be unreachable cross-cloud (agent API is often internal-only). A single unreachable node blocks all enables, there is no override, and reachability is verified only at step 8 — after the dashboard deploy.
- Old beams: "skip unknown protocol rows (log)" is untested; a `case` without a catch-all crashes, and LB "route only to nodes that can serve" has no mechanism. Mixed fleet may `no_route` or crash.
- Probe: trigger (manual vs auto), budget config location, and audit-log retention are unspecified. "200 + refusal-only = OK" can misclassify a generic 200 error body.

**Contradictions / stale claims**
- D9 breaks the AGENTS.md invariant "chat-family call naming a non-chat listing → `wrong_modality`" by substituting `protocol_requires_native`; existing eunit/TF expectations are not listed for update.
- Probe body pins `input`/`questions` pre-D13 while usage keys (O1) are D13-gated — inconsistent gating.
- §4.5 "provider_disabled or no_route per existing rules" is nondeterministic in a spec claiming deterministic precedence.

**Missing first-ship**
- Rate limit / abuse control on a billable face with no knob (D8).
- Confirmation no lower global MAX_BODY (Cowboy/proxy) negates D12's 10 MiB.
- Migration details: CHECK vs enum, existing protocol values, seed idempotency.
- readyz `protocols` backward compatibility for existing consumers.

**Architecture notes**
- D16 preamble extraction risks Responses; TF-D.18 only asserts knob invariance — add a Responses regression.
- `decisions_upstream_429_total` "as appropriate" needs a defined label set.
- Grant-confirm copy is per-name; dual-face names may re-prompt on unrelated grant writes.

**Top 5 concrete edits**
1. Define D15's exact gun signal and add cross-face proxy regression TFs.
2. Reconcile D9 with `wrong_modality`; update invariant doc + tests in one commit.
3. Move probe body field names into D13/O1.
4. Give the write gate a cached-advertisement TTL + operator override; verify `:8080` exposure at step 5, not 8.
5. Specify old-beam unknown-protocol handling and LB capability routing with a test.
