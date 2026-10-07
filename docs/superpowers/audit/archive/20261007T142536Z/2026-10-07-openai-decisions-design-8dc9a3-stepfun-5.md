---
model: stepfun/step-5-preview
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: stepfun-5
---

Verdict: GO WITH FIXES

1. **Critical risks**
- **Probe cooldowns:** 60s per provider is bypassable via rapid provider create/probe/delete cycles; no rate limit keyed by upstream endpoints listed. Add per-account quota cap (e.g., 5/min) and circuit-break on repeated failures.
- **Probe billing:** "Successful 200 probe **bills** Luna" warning buried in UI copy; default probe body should use `<listing.upstream_model_id>` explicitly pinned to the cheapest beta model, never interactive operator free-text.
- **`x-request-id` propagation:** spec assumes client-supplied value passes through unchanged; if absent, must mint server-side and return header, else correlation breaks silently.
- **Failover vs. probe cooldown:** pre-send failover to another Decisions route could retry the same upstream key on a different route (if same provider key shared across rows), triggering double billing.

2. **Contradictions / stale claims**
- D11 says "fixture **replay** (guide excerpts → then live file when present)" but §2 still lists the live capture as D13-gated; clarify merge order and the exact eunit gate.
- §4.3 "shared path-join; test `/v1` + trailing slash" — but §4.1 says old beams skip unknown protocol; missing regression test for mixed old/new `/readyz` payloads causing dashboard write-gate false negatives during rollout.
- "No invented Decisions semantics" in §1 vs. §4.3 "pass upstream status/body verbatim" conflicts with Janus envelope parity listed in §4.2; scope of "verbatim" (headers? trailing chunks? 5xx body shape?) is ambiguous.

3. **Missing first-ship requirements**
- **Idempotency/cancel:** no `AbortController`/client-disconnect handling; with 300s idle and pre-send-only retry, disconnected probes/handlers leak cowboy processes.
- **Dashboard enum migration:** `openai_decisions` must be added to dashboard protocol dropdown/backfill for existing provider rows, else UI creates rows the gateway rejects.
- **Metrics cardinality guard:** `endpoint=decisions` label must be pinned; otherwise `path` or `model` labels could leak cardinality into Prometheus.

4. **Architecture/design notes**
- §4.5 "shared predicate" is ideal, but confirm LB candidate build and janus-auto exclusion call the *same* function; a filter duplicated later is the exact failure D9 prevents.
- Usage parsing: "one nesting level" is brittle; spec should define max scan depth (1) explicitly and a test for 2-level nesting to guard runtime blowup.

5. **Top 5 concrete edits**
1. Add explicit probe rate limiter (per API key + upstream endpoint) with 429 on spam; document it.
2. Pin probe `model` to the specific beta model id; disallow operator input for that field.
3. Clarify `x-request-id`: mint if absent, always return in response headers.
4. Add dashboard protocol enum migration SQL + backend validator in §6 rollout table.
5. Define "verbatim passthrough" contract precisely (status, body bytes, selected upstream headers) and add a fixture test.
