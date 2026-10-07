Synthesis output below — save as `F:\Janus\docs\superpowers\audit\2026-10-07-openai-decisions-design-8dc9a3-synthesis.md`.

---

# Synthesis — OpenAI Decisions API design spec (round 4)

**Stem:** `2026-10-07-openai-decisions-design-8dc9a3` · **Date:** 2026-10-07
**Target:** `2026-10-07-openai-decisions-design-8dc9a3-target.md` (source: `docs/superpowers/specs/2026-10-07-openai-decisions-design.md`)
**Panel (7/7 replied, quorum met, not degraded):** minimax-cn/MiniMax-M3 · mimo/mimo-v2.6-pro · stepfun/step-5-preview · alibaba/qwen3.8-max · volcengine-ark/deepseek-v4-1-flash-260910 · zhipuai-coding-plan/glm-5.3 · kimi-for-coding/k3
**Consensus threshold:** ≥ ceil(7 × 0.7) = **5** replies.

## 1. Verdicts

| Slug | Model | Verdict |
|---|---|---|
| minimax-m3 | minimax-cn/MiniMax-M3 | GO WITH FIXES |
| mimo-v26-pro | mimo/mimo-v2.6-pro | GO WITH FIXES — probe 404/405 ambiguity, "bytes sent" boundary, envelope parity |
| stepfun-5 | stepfun/step-5-preview | GO WITH FIXES — failover boundary, probe-billing controls, grant-escalation scope |
| qwen38-max | alibaba/qwen3.8-max | GO WITH FIXES — failover boundary, URL join, name-collision billing, write-gate |
| deepseek-v41-flash | volcengine-ark/deepseek-v4-1-flash-260910 | GO WITH FIXES — guide-replay gate, grant confirm, pre/post-send boundary |
| glm-53 | zhipuai-coding-plan/glm-5.3 | GO WITH FIXES — grant enforcement, precedence ordering, write-gate rollback trap |
| kimi-k3 | kimi-for-coding/k3 | GO WITH FIXES — auth-vs-413/precedence, "bytes sent", probe cooldown, readyz skew |

**Overall: GO WITH FIXES** — unanimous 7/7. No panel issued a clean GO; all fixes below are pre-implementation.

## 2. Consensus (≥5/7)

**W1 — Write gate (§4.3) is under-specified and contains failure traps. (7/7: all)**
Facets raised: "≥1 node advertises" vs all-nodes never stated (mimo, deepseek, kimi); rollback/kill-switch deadlock — with old beams fleet-wide nothing advertises, so `PUT enabled=0` is rejected exactly when needed (glm); transient all-unhealthy fleet deadlocks provider creation (minimax); TOCTOU — first write succeeds while most traffic still `no_route` (kimi); `/readyz` listener unspecified, and if it rides the container-network-only admin listener the dashboard can never poll it (qwen); advertisement must derive from the registered handler, not a hardcoded list (kimi); mixed old/new `/readyz` payloads need a regression (stepfun).

**W2 — Probe billing-abuse protection is insufficient as written. (5/7: minimax, mimo, stepfun, deepseek, kimi)**
≥60 s per-provider cooldown alone is: too frequent for a per-call-billed beta (minimax), has no per-day budget or audit trail (mimo), is bypassable via provider create/probe/delete cycles and is keyed per provider not per caller (stepfun, deepseek), and has no stated mechanism that survives a multi-process dashboard (kimi).

**W3 — The grant-widening guard (§4.4/D10) has a billing hole. (5/7: minimax, mimo, qwen, glm, kimi)**
Confirmation fires only at provider creation. Later listing adds or grant writes intersecting `api_key_models` silently enable **billable** Decisions calls. (The specific fix — trigger on every listing-add — is at 4/7, see near-consensus.)

**W4 — D11/D13/§6 step 2/8 gate interplay must be reworded. (5/7: minimax, mimo, stepfun, qwen, deepseek)**
Guide-replay must be stated as satisfying the **merge** gate only, not production certification; O1 needs an owner + deadline; step 8's live TF-D.1 is a **paid production call** — operator-run once, never scripted (AGENTS.md: production never mutated by tests); until D13 pins usage field names, `janus_usage_unmapped` on billable traffic needs an alert/allowlist shipping in the same deploy.

## 3. Near-consensus / objective gaps

**Near-consensus (4/7):**
- Grant-intersection confirmation must run on **every listing-add/grant-write** under an `openai_decisions` provider, not just provider creation (mimo, qwen, glm, kimi).
- Probe **404/405 disambiguation is unfounded** until the D13 fixture pins OpenAI error-body shapes (mimo, qwen, glm, kimi). Remedy splits — see §4.
- §4.2/§4.5 **precedence table has uncovered combinations**: stream:true + ungranted key (mimo); chat/responses face naming a Decisions-only listing (glm); disabled Decisions row + other-protocol row for the same name (kimi); explicit grant-deny-first wording (minimax — but see ground truth §5).
- **`OpenAI-Organization`/`OpenAI-Project` pass-through is an undecided branch** ("if already implemented; else do not invent") in a spec marked locked — audit existing faces and decide (minimax, qwen, deepseek, kimi).

**Near-consensus (3/7):**
- **D15 "pre-send" must be defined**: failover only on TCP/TLS-establishment failure; never after request bytes start (mimo, qwen, deepseek). deepseek adds: verify the shared proxy can even signal "bytes sent" — if not, that is a missing scope item. kimi adds: verify the shared proxy actually has a retry to suppress; if not, D15's suppression clause is vacuous and should say so. (6/7 engage with D15 billing edges overall; the asks differ.)

**Objective gaps (1–2 replies, uncontested):**
- `?MAX_BODY` vs D12 10 MiB precedence/scope — pin per-face (qwen, deepseek).
- 429 passthrough: metric name + `Retry-After` policy (glm, deepseek).
- Dashboard protocol-enum migration/backfill and rollback-with-Decisions-rows story (stepfun, kimi).
- Probe `model` field must equal the exact forward-path rewrite target (glm); listing-selection rule when several exist (qwen).
- `x-request-id`: mint if absent, always return (stepfun).
- "Verbatim passthrough" contract (status/body/which headers) + fixture test (stepfun; mimo wants it noted in ops copy).
- Metrics cardinality: pin `endpoint=decisions` label set (stepfun).
- Per-request upstream deadline beyond probe 10 s / idle 300 s (deepseek).
- Client-disconnect handling under 300 s idle (stepfun).
- Probe-outcome metrics (kimi); readyz `protocols` versioning (deepseek); readyz update cadence after generation bumps (minimax); CI redaction assertion for committed fixtures (deepseek); auto-exclusion must be **per-route (protocol), not per-name**, else dual-face names vanish from janus-auto (qwen); §4.6 idle-timeout sentence duplicates a global AGENTS invariant — cut it (glm).
- Probe 200-body classifier matrix: empty `answers`, `refusal`, predicate/choice/score outcomes (minimax).

## 4. Split opinions — do not auto-apply (decision owner: user)

1. **Preamble strategy (§3):** extract a shared module (minimax, kimi) vs copy + TF assertion of no SSE/translate deps (qwen). deepseek notes copy invites drift, extract risks existing faces; demands a decision either way.
2. **Write-gate strength:** require **all** serving nodes advertise (mimo, deepseek, kimi) vs accept any-node with a documented mixed-fleet caveat. Orthogonal mitigations to pick among: disable-only-PUT exemption (glm), TTL-cached last-known advertisement (minimax), listener pinning to :8080 (qwen).
3. **D13 gate placement:** keep production-only gate with clarified merge wording (majority) vs promote live capture to a **pre-implementation** blocker (deepseek dissent).
4. **Probe 404 remedy:** default all 404/405 to *inconclusive* until D13 (mimo, glm, kimi) vs pin a provisional discriminator now, e.g. `error.code == "model_not_found"` (qwen).
5. **Probe cooldown design:** operator-configurable ≥5 min + per-day cap (minimax) vs short cooldown + per-day budget/audit (mimo) vs per-key/per-upstream-endpoint rate limiter returning 429 (stepfun).
6. **`Idempotency-Key` passthrough** (minimax only, 1/7) and client-retry-after-post-send-error documentation (qwen, deepseek adjacent).

## 5. Ground-truth notes (verified local facts)

- **glm is right about rollout order.** AGENTS.md documents `deploy_prod.sh` as "rebuild → run local gate → rolling rollout"; the target's §6 lists "Local e2e green" as step 8 **after** the gateway deploys (steps 4–6). Reorder.
- **qwen's :8090 concern is grounded.** AGENTS.md records S.8 skipping `/metrics` when `stats_host` is container-network-only; a `/readyz` on the admin listener would be unreachable from the dashboard on those hosts. Pin the agent listener (:8080).
- **qwen/glm cite AGENTS.md correctly:** production is never mutated by tests (step 8 must be operator-run once), and the fixture-realism rule backs the 404-body-classifier concern.
- **glm:** AGENTS.md already mandates `idle_timeout => 300_000` on all Cowboy listeners; §4.6's sentence is redundant.
- **Correction to minimax:** the §4.5 table already lists grant-deny as the **first** (highest-precedence) row; the real ordering hole is mimo's — §4.2's stream guard can fire before the grant check.
- **kimi's uvicorn multi-worker claim** is plausible but not verifiable from the provided docs; a DB-backed `last_probe_at` is the safe choice regardless of worker count.

## 6. Top concrete edits for the live doc (`docs/superpowers/specs/2026-10-07-openai-decisions-design.md`)

1. **§4.3 write gate:** require **all** serving gateway nodes to advertise `openai_decisions` before opening (or explicitly accept any-node + document the mixed-fleet `no_route` window); derive advertisement from the registered handler; serve `/readyz` on the agent listener (:8080); add a rollout step verifying dashboard→gateway `/readyz` reachability on aliyun/jdcloud/tencent; **exempt disable-only mutations** (`enabled=0`) so the rollback kill switch works.
2. **§4.4 grants:** trigger the intersection confirmation on **every** listing-add and grant-write under `openai_decisions` providers, not only provider creation; persist operator identity + accept/decline in the audit log.
3. **§4.3 probe:** until D13, classify **all 404/405 as inconclusive** (add as O2 in §9); enforce cooldown transactionally via DB-persisted `last_probe_at`; add per-day probe budget + audit of probe invocations; pin probe `model` to the exact forward-path rewrite target.
4. **§4.3/D15:** define pre-send = **TCP/TLS-establishment failure only**; never fail over after request bytes start; confirm the shared proxy exposes that signal (scope the change if not) and state whether a retry exists to suppress; add a regression assertion for it.
5. **§4.2/§4.5 precedence:** reorder so auth + grant-deny precede the stream guard; add rows for stream:true + ungranted key, disabled-Decisions-row + other-protocol same-name, and a chat/responses face naming a Decisions-only listing; add matching TF-D.14.
6. **§2/§6/§9:** state guide-replay satisfies **merge** (D11) only; D13 live fixture is required before production claims; name an owner + deadline for O1; step 8's live TF-D.1 is operator-run once, never scripted; ship a `janus_usage_unmapped > 0` alert + metrics allowlist in the same deploy.
7. **§4.3:** resolve the `OpenAI-Organization`/`OpenAI-Project` branch — audit existing OpenAI faces and state the decision.
8. **§4.2/D12:** state the 10 MiB cap is Decisions-face-only and pin its precedence vs the shared `?MAX_BODY`.
9. **§6:** move "Local e2e green" **before** the aliyun deploy step (matches `deploy_prod.sh`); add the dashboard protocol-enum migration + validator + rollback note to the dashboard column.
10. **§4.5:** state janus-auto exclusion is **per-route (protocol), not per-name**, so dual-face names remain usable by the auto-router.
