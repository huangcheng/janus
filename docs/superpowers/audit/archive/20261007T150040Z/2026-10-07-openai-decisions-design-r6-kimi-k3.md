---
model: kimi-for-coding/k3
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: kimi-k3
---

**Verdict:** GO WITH FIXES — the spec is thorough and internally consistent on the big items (precedence, D15, write gate), but several falsifiable-behavior gaps (missing `model`, keepalive reuse, probe lock recovery, response-cap mechanics) must be pinned before implementation.

**Critical risks**
- **D15 + gun keepalive:** "before any request byte is written" is ambiguous for reused pooled connections. A dead keepalive conn discovered on write may mean the server *did* receive bytes → double-billing/duplicate side effects. Spec never says whether failover-eligible attempts must use fresh connections.
- **Probe `in_flight` lock:** crash between set/clear wedges the provider's probe forever (only reset path unstated). No TTL/owner-revival.
- **Missing/invalid `model` field:** pipeline step 4 grants "by `model` from body" but absence, wrong JSON type, or empty string has no error code or precedence row — implementers will guess.
- **4 MiB upstream cap:** enforcement mechanics unspecified (mid-body abort? connection teardown? partial discard? metric?). Gun will happily stream past it.
- **Write gate on `:8080/readyz`:** unauthenticated protocol disclosure is "accepted," but the source of truth ("handler modules registered") is vague — readyz must reflect the *compiled* protocol set, or old-beam false-positives break the gate's purpose.

**Contradictions / stale claims**
- TF-D.6 says "null until O1; then exact keys," but O1 is pinned at D13 (rollout step 2, before implementation) — the "null" phase only exists in dev; say so or drop the interim state.
- §3 "One nesting level allowed" for usage extraction is undefined (nesting of what?).
- Rollout step 9 (live TF-D.1) is billable; gate it explicitly on O1-pinned, not implied.

**Missing first-ship requirements**
- `Allow: POST` on 405; behavior for chunked bodies with no Content-Length (cap still enforced?).
- Which upstream headers are "sensitive" (strip list must be named).
- Probe budget across dashboard restarts/replicas (who owns the job; day rollover race on `day_utc`).
- No concurrency/backpressure note on Decisions face (10 MiB buffered bodies × N = memory).

**Architecture notes**
- Fresh-conn-per-attempt for failover eligibility is the only clean way to make D15 falsifiable; state it.
- Write-gate ordering race (dashboard live before gateways advertise) is handled by rollout order, but rollback path (old dashboard + new gateways) leaves gate absent — acceptable, note it.
- Eunit list should state write-first ordering per repo rules.

**Top 5 concrete edits**
1. Add error + precedence row for missing/wrong-type `model`.
2. D15: mandate fresh gun connection per failover-eligible attempt; reused-conn write failure = terminal.
3. Probe: `in_flight` TTL (e.g., 10 min) + single-owner job claim; reset on boot.
4. Pin 4 MiB cap mechanics (mid-stream abort, close, metric `decisions_upstream_oversize_total`) and enumerate stripped upstream headers.
5. Define `/readyz` `protocols` as compiled-in list, not registry; add `Allow` header and chunked-body rule to D12.
