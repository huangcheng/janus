---
model: kimi-for-coding/k3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: kimi-k3
---

**Verdict:** GO WITH FIXES — the design is thorough and the fail-closed posture is sound, but the probe contract is under-specified, one precedence case is missing, and the release-order claim contradicts the repo's boot-migration model.

## Critical risks

- **Probe contract is a hole.** §4.3 never defines the probe request body. The fingerprint heuristic ("400 mentioning `questions`/`input`") is circular if the probe's own body contains those fields and upstream echoes them; "allowlist finalized from live capture" means shipping a probe whose OK/Bad classification is TBD. A generic OpenAI 400 (`invalid_request_error`) could false-OK.
- **Chicken-and-egg:** probe uses "the listing's upstream model name, no `gpt-6-luna` fallback" — but a fresh Decisions provider has no listings until sync/manual add. Probe behavior with zero listings is undefined.
- **Grant vs face precedence missing.** D5′ covers no_route/disabled/cooling/wrong-face, but not the case where the key *lacks a grant* for the name. Does grant-deny (403-class) or `protocol_requires_native` win? This determines whether face rejection leaks grant state.
- **Probe billing abuse:** 200-probes bill, no rate limit / cooldown specified; probe runs on provider save.

## Contradictions / stale claims

- **Release order vs repo invariant.** §4.3 step 1 demands "gateway CHECK on all nodes" *before* new beams, but the repo invariant is migrations run automatically at gateway boot via `janus_db_conn` init, with aliyun as migration leader. As written, deploy_prod.sh cannot satisfy this ordering; either restate as "leader migrates at boot, followers roll after" or change the deploy flow.
- D11 ("replay is authoritative regime") vs D13 ("live fixture is ship gate") is consistent in intent but worded confusingly — say "replay gates merge, live gates production claims."

## Missing first-ship requirements

- Which upstream errors pass through raw vs get wrapped in the `janus_error` envelope (passthrough of arbitrary upstream 4xx/5xx bodies breaks envelope uniformity — needs one line).
- Mixed-fleet window behavior: old beams skip the Decisions row, so the same client call returns `no_route` on old nodes and `protocol_requires_native` on new ones. Acceptable, but must be documented for rollout debugging.
- Write-gate mechanism: "generation/min-version advertises Decisions support" — no existing advertisement channel is named; say which.
- Migration number/file names (next after 012) and owner of the scrape/alert allowlist audit.

## Architecture notes

The LB candidate-set filter + dispatch second line is the right belt-and-suspenders. `no-retry` on native POST (double-billing) is correct and correctly scoped. Name-union `/v1/models` without face hints will advertise names chat clients can't call — accepted by D3/D9, but expect user confusion tickets.

## Top 5 concrete edits

1. Define the exact probe request body and a provisional fingerprint allowlist now; mark it to be confirmed against live capture.
2. Add grant-deny vs `protocol_requires_native` precedence to the D5′ table.
3. Restate release order to match boot-time migration + leader-first rollout.
4. Specify probe behavior with zero listings (skip + UI state).
5. One line: upstream non-2xx bodies pass through verbatim (or are wrapped) — pick one; document mixed-fleet `no_route` vs 400 divergence.
