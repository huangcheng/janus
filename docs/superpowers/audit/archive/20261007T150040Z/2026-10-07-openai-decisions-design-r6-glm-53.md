---
model: zhipuai-coding-plan/glm-5.3
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: glm-53
---

**Verdict:** GO WITH FIXES — the core design is sound and falsifiable, but the write gate depends on unspecified infrastructure and one terminal error path has no client-facing contract.

**Critical risks**
1. **Write gate heartbeat registry is not a deliverable anywhere.** §4.3 requires "dashboard registry (heartbeat freshness ≤60 s)" — who produces heartbeats, on what endpoint/cadence, is unspecified. The gate's sole input may not exist at ship time.
2. **D15 "body stream error" (terminal) has no error code.** §4.2 defines exactly four codes; HTTP status → verbatim, timeout → `upstream_timeout`, but mid-body stream failure maps to nothing. Client contract undefined for a first-class case.
3. **gun pooled connections:** failover can effectively only fire on fresh-connect failure; a reused-connection reset after headers-written is terminal. Correct anti-double-billing choice, but unstated — an implementer will "fix" it into a retry.
4. **§4.5 rows 6–7 are not disjoint as claimed:** routes partially disabled + partially cooling match neither "all disabled" nor "all cooling/no key".
5. **No client-side cost control:** probe has 20/day budget; billable `/v1/decisions` client traffic has no rate/budget mechanism mentioned at all.

**Contradictions / stale claims**
- "Disjoint precedence" header vs the row-6/7 mixed-case fall-through.
- 4 MiB upstream cap vs "status+body verbatim" for errors — unclear whether cap applies to error bodies.
- Dashboard→`:8080/readyz` reachability repeats the known S.8 container-network issue; leader-deploy verify (rollout step 5) covers only the leader, not follower topology.

**Missing first-ship requirements**
- Heartbeat registry spec (producer, endpoint, cadence, persistence).
- Error envelope + TF for body-stream-error terminal case.
- Base-URL trailing-slash normalization for `{base}/decisions` (eunit lists "path-join" but the edge is unstated).
- Statement on whether verbatim upstream error bodies are clamped by the 4 MiB cap.

**Architecture / design notes**
- D15's pre-send/post-send split is the right billing-safety invariant; document the reused-connection corollary explicitly.
- Probe classifier (refusal-only 200 = OK, empty = inconclusive, 401/403 = bad key, rest inconclusive until O2) is appropriately conservative.
- Write-gate TOCTOU (node passes readyz then dies) is acceptably covered by per-node D2 fail-closed.

**Top 5 concrete edits**
1. Add a §4.3 sub-section: heartbeat registry producer/endpoint/cadence as an explicit deliverable, or drop freshness and gate on readyz alone.
2. Add `upstream_stream_error` (or reuse `upstream_timeout`-style envelope) to the §4.2 table + a TF-D row.
3. Rewrite §4.5 rows 6–7 to a total order, e.g. "any disabled route present → `provider_disabled`, else cooling/no-key errors".
4. One sentence in D15: "reused-connection reset after request write is terminal; failover applies only to fresh-connect setup failures."
5. State that the 4 MiB cap clamps upstream error bodies too (or exempts them explicitly).
