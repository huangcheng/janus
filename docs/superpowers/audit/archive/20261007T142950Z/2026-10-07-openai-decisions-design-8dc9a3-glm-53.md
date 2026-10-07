---
model: zhipuai-coding-plan/glm-5.3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: glm-53
---

**Verdict:** GO WITH FIXES — architecture is sound and round-5 hardened, but one internal contradiction (pipeline order), an underspecified D15 error contract, and unbounded write-gate/stale-node failure modes must be fixed before implementation.

**Critical risks**
- **D15 retrofit:** "teaching the proxy to distinguish connect-fail vs post-send if not already signaled" — the shared gun adapter likely conflates these today. Touching its error taxonomy risks silently changing failover for the existing chat/Anthropic faces. No regression TF for existing protocols is listed, only TF-D.15.
- **Write-gate deadlock:** gate requires *every* node in the dashboard's list to advertise. A stale/decommissioned node blocks all Decisions provider writes indefinitely; no override, no auto-forget, no behavior defined for nodes whose `/readyz` lacks a `protocols` field (treat as not-advertising?).
- **`/readyz` on :8080 is the internet-facing agent port.** Unauthenticated protocol/topology disclosure; spec never states binding/auth posture (contrast the `stats_host` container-network pattern).
- **Probe ambiguity:** "one-shot" names no listing-selection rule for multi-listing providers (probe result varies by listing); "Inconclusive: **all** 400/404/405" reads as any-vs-all ambiguity; no concurrency guard for two admins probing inside the cooldown transaction.

**Contradictions / stale claims**
- §4.2 pipeline: `auth → grant check → body size → JSON parse` is impossible — grants are by model *name* (D10), which requires the parsed body. §4.5's own table is fine; the pipeline line is wrong.
- D15 prose "never after request bytes start" (whose bytes?) vs the precise "connect-only, no HTTP status" rule — keep only the latter.
- "mid-body failure → return to client" for a non-stream POST: no client-facing status is defined (bodiless 502? partial JSON?).

**Missing first-ship requirements**
- Non-2xx/mid-response client error mapping for the native path.
- Write-gate failure UX (which nodes, error code) and stale-node escape hatch.
- `usage_events` semantics: Decisions `units` value (tokens? calls? unused) — §5 says "token-only null-safe" but never pins the column.
- Probe egress origin (dashboard-direct vs via gateway) and where its API keys live.

**Architecture/design notes**
- Deriving readyz protocols from registered routes (not a string list) is right; snapshot at boot.
- Implement D15 as a protocol-keyed clause in `failover_decide` keeping chat behavior byte-identical; assert with TFs on both faces.
- Precedence table should be exercised by an exhaustive eunit over the predicate, not just TF spot-checks.

**Top 5 concrete edits**
1. Fix §4.2 order to: auth → body size → JSON parse → grant → stream guard → pick.
2. Specify the gun error contract for D15 (`connect_failed` vs `{status,…}` vs mid-body) + regression TFs asserting chat/Anthropic failover unchanged.
3. Define write-gate handling of missing `protocols` fields, a stale-node override (N failed readyz checks → auto-forget), and gate-failure error UX.
4. State `/readyz` binding/auth decision and rationale in §4.3.
5. Probe: pin listing selection (probe per listing), replace "all 400/404/405" with "any of", add cooldown row-lock/concurrency note.
