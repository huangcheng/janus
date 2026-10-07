---
model: stepfun/step-5-preview
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: stepfun-5
---

**Verdict:** GO WITH FIXES — sound shape and gates, but one timeout contradicts production reality and several security/ops invariants are asserted rather than verified.

**Critical risks**
- **60 s first-byte timeout contradicts AGENTS.md**: idle_timeout is 300 s precisely because "upstreams may take 60s+ to first byte." D15 makes this timeout *terminal* (no failover), so a slow-but-valid provider becomes a hard `upstream_timeout`. This is the single most likely production false-failure.
- **Header policy under-specified**: D17 strips only `OpenAI-Organization/Project`. Silent on `Authorization` (presumably replaced, unstated), `OpenAI-Beta`, other `OpenAI-*`, and `x-request-id` echo (log injection via newlines). Spoofing risk is only closed for two headers.
- **Write-gate reachability assumption**: dashboard→`:8080/readyz` per-node HTTP channel is asserted, not proven. S.8 precedent (container-network-only hosts) means this may fail closed forever → no Decisions onboarding. "Same public health surface as healthz" is stale if no public healthz exists.
- **Old-beam safety**: TF-D.12 ("old normalize skip") cannot be back-ported to already-deployed beams. Actual safety rests entirely on the dashboard write gate (rows only after all nodes advertise) plus no direct DB writes. Say this explicitly; add ops no-manual-SQL note; verify `normalize_protocol` catch-all exists today.
- **10 MiB buffered bodies × unbounded concurrency** → Erlang process memory pressure. No in-flight bound stated.

**Contradictions / stale claims**
- "align AGENTS idle reality" vs 300 s reality (above).
- Rollout step 9 live TF-D.1 *is* billable prod traffic; doc must state O1 is pinned before step 9.
- `decisions_upstream_429_total` bespoke name — verify parity with existing per-face 429 metric conventions before inventing a new series.
- Probe 60 s timeout inherits the same misalignment.

**Missing first-ship**
- Global kill beyond per-provider `enabled=0` (or an explicit ops runbook entry).
- Concurrency/rate policy for the new face.
- Response-cap enforcement mechanics: streaming accumulator + drain-and-close on exceed (Content-Length may lie); TF-D.19 asserts outcome only.
- Ordering window: gateway CHECK allows `openai_decisions` at leader boot, but dashboard validators reject until step 7 — document what ops sees if a row somehow exists in the window (rollback note covers reverse case only).

**Architecture notes**
- readyz `protocols` snapshot at listener start is fine only because gates never hot-add faces — state this constraint.
- D15's shared-proxy edit touches all faces' failover; TF-D.8 + TF-D.15 cover it, and "byte-identical" is the right bar.

**Top 5 edits**
1. First-byte timeout 60 s → 300 s or per-protocol config `decisions.upstream_timeout_ms`; align probe timeout; fix §4.2/4.3/D15 wording.
2. New §4.3 subsection: explicit upstream-header whitelist (provider auth + content-type/length/host only; sanitize `x-request-id` to `[A-Za-z0-9-]`); amend D17.
3. Replace TF-D.12 premise with the true invariant: write-gate ordering + ops SQL prohibition; verify catch-all in current code.
4. Add gate D19 (or fold into D13): prove dashboard→`:8080` reachability and readyz auth model before implementation start.
5. Bound per-face in-flight requests (or document the cowboy-level limit) and specify stream-drain enforcement of the 4 MiB cap.
