---
model: alibaba/qwen3.8-max
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: qwen38-max
---

**Verdict:** GO WITH FIXES — unusually thorough spec, but four concrete gaps (failover send-boundary, body-cap scope, `/readyz` reachability, grant-confirm scope) must be pinned before code.

## Critical risks
1. **D15 "pre-send" is undefined.** Gun can report connect/early-send failures after partial transmission; failing over then risks **double billing**. Define: failover only on TCP/TLS *establishment* failure; any error after request start → no failover.
2. **`/readyz` write gate topology.** Spec doesn't say which listener serves `/readyz`. If it rides the :8090 admin listener (container-network-only on some hosts — see S.8 precedent), the dashboard cannot poll it and the write gate never opens. Specify :8080 and verify reachability on aliyun/jdcloud/tencent.
3. **D12 cap scope.** Shared preamble uses `?MAX_BODY`; unclear whether 10 MiB is Decisions-only or global. A global raise widens DoS surface on chat/responses/messages. Make it per-face.
4. **D10 confirm fires only at provider creation.** Adding a listing later to an existing Decisions provider whose name intersects `api_key_models` grants silently widens **billable** access. Trigger confirmation at any `openai_decisions` listing insert.
5. **Probe classifier guesses a body shape.** "404 model-not-found body" vs plain 404 has no fixture behind it — this is exactly the fixture-realism failure class in AGENTS.md. Pin a provisional discriminator pending D13.

## Contradictions / stale claims
- D13 ("production claims require live fixture") vs step 2 ("merge on guide replay only") is reconciled by the gate, but step 8's live TF-D.1 is a **paid upstream call in production** — state explicitly it is operator-run once, never scripted against prod (AGENTS.md: prod never mutated by tests).
- "Pass through `OpenAI-Organization`/`OpenAI-Project` if already implemented; else do not invent" is an undecided branch — audit the existing OpenAI faces and decide now.
- §10 claims "Guide fixture on disk" — verify the file actually landed before treating D11 as satisfiable.

## Missing first-ship requirements
- Probe listing selection rule (which listing when several exist).
- Client-facing guidance: with D15 no-retry, clients must retry on post-send errors — document it.
- Auto exclusion must be **per-route (protocol), not per-name**, else dual-face names vanish from janus-auto.
- Expect a `janus_usage_unmapped` flood until D13 pins field names; alert allowlist must ship in the same deploy.

## Architecture/design notes
- Single shared eligibility predicate for LB/dispatch/auto is right; keep it pure with table-driven eunit.
- Preamble "extract or copy": choose copy + TF-D assertion of no SSE deps — a shared module will accrue SSE/translate coupling over time.

## Top 5 concrete edits
1. §4.3: "pre-send = connect/TLS-establishment failure only; any error after request start never fails over."
2. §4.3/§6: `/readyz` on the agent listener (:8080); add an explicit rollout step verifying dashboard→gateway reachability on all three prod hosts.
3. §4.2/D12: 10 MiB cap applies to the Decisions face only; other faces keep existing `?MAX_BODY`.
4. §4.4: run grant-intersection confirmation on every listing insert under an `openai_decisions` provider, not just provider creation.
5. §4.3/§4.5: pin the provisional 404 model-not-found discriminator (e.g. `error.code == "model_not_found"`) pending D13, and spell per-route auto exclusion.
