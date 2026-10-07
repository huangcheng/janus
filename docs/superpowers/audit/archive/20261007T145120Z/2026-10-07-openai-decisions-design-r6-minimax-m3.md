---
model: minimax-cn/MiniMax-M3
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: minimax-m3
---

**Verdict:** GO WITH FIXES — cost units, the 60 s first-byte cliff, and probe refusal classification must be pinned before D13 / implementation.

### Critical risks

1. **First-byte cliff.** AGENTS declares upstreams may take 60 s+ to first byte; §4.2 sets a 60 s gun timeout. Anything at 60.5 s → `upstream_timeout`, no failover: a self-inflicted 5xx that masquerades as an OpenAI outage. Pick 120 s or document the loss budget.
2. **Refusals-as-OK probe.** §4.3 says 200 with `answers` containing only `refusal` entries is OK. A silently-revoked key that still 200s + refuses looks healthy. Add a refusal-ratio / model-presence rule and emit `decisions_probe_weak_total`.
3. **5xx burns budget forever.** §4.3 keeps 5xx inconclusive with no triage; combined with the 20/day cap, a degraded upstream can starve the budget indefinitely. Triage after N consecutive 5xx.
4. **Cost units undefined.** §5 "token-only null-safe"; Decisions bills per-decision / per-image, not tokens. `usage_events` has no real unit row; O1 cannot be pinned without a schema bump.
5. **Boot-snapshot `protocols`.** Captured at cowboy listener start → stale on hot code reload until restart. An emergency code-load that *removes* `openai_decisions` silently re-enables the dashboard write UI against a node that doesn't serve it. Resolve live from a supervisor child / ETS term refreshed by the handler registry.

### Contradictions / stale

- D15: "pre-send fail = connect error before request headers written" then places 60 s first-byte timeout under *terminal*. First-byte timeout is post-connect and post-request-send. Label is wrong; the rule (no failover post-send) is right.
- §1 "no /v1/models face hints" vs §4.5 names-across-protocols — pin a TF asserting the union listing carries no protocol field.

### Missing first-ship

- 4xx upstream passthrough vs envelope (only 429 named). Per-provider rate-limit / quota.
- Decisions unit + `usage_events` migration bump referenced from O1.
- Rollback of the write gate itself when `/readyz` is broken on a healthy node.
- Bulk or batch endpoint: explicit out, or just unmentioned?

### Architecture / design notes

- Path-join `{base}/decisions` assumes a clean base; codify trailing-slash trimmer.
- Model upstream id rewrite lives in the listing row; spec relies on it without naming the column.
- `protocol_requires_native` must use `map_size/1`, not `case M of #{}` — AGENTS lesson.

### Top 5 concrete edits

1. §4.2 — pick first-byte timeout (60 vs 120 s) and document the cliff.
2. §4.3 — probe refusal rule + 5xx-triage threshold + `decisions_probe_weak_total`.
3. §5 — Decisions unit + `usage_events` schema bump referenced from O1.
4. §4.3 write gate — `protocols` resolved live from a supervisor child, not a boot snapshot.
5. D11/D13 — pin guide-excerpt fixtures to a git SHA of the OpenAI doc so doc edits break replay loudly.
