Synthesis complete. All 7 panel replies PASS, quorum met (7/7 ≥ 5), `degraded: false` — no DEGRADED label required. Verdicts below match the manifest exactly. Proposed home: `F:\Janus\docs\superpowers\audit\2026-10-07-openai-decisions-design-synthesis.md`

---

# Synthesis — OpenAI Decisions API Design Spec Audit

- **Date:** 2026-10-07
- **Target:** `2026-10-07-openai-decisions-design-target.md` (source: `docs/superpowers/specs/2026-10-07-openai-decisions-design.md`)
- **Panel (7):** minimax-cn/MiniMax-M3, mimo/mimo-v2.6-pro, stepfun/step-5-preview, alibaba/qwen3.8-max, volcengine-ark/deepseek-v4-1-flash-260910, zhipuai-coding-plan/glm-5.3, kimi-for-coding/k3
- **Consensus threshold:** ≥ ceil(7 × 0.7) = **5 of 7**

## Verdict table

| Slug | Verdict |
|---|---|
| minimax-m3 | GO WITH FIXES |
| mimo-v26-pro | GO WITH FIXES |
| stepfun-5 | GO WITH FIXES |
| qwen38-max | GO WITH FIXES |
| deepseek-v41-flash | GO WITH FIXES |
| glm-53 | GO WITH FIXES |
| kimi-k3 | GO WITH FIXES |

**Overall: GO WITH FIXES — unanimous (7/7).** Design framing (native passthrough, fail-closed, no polyfill, no translate matrix) is endorsed by every panelist; all fixes concern unpinned contracts, not direction.

## Consensus (≥ 5/7)

**C1 — Resolve O2 in-spec: one stable wrong-face error code (7/7).** Every reply demands deleting the "or reuse `translate_unsupported`" alternative and freezing one code before TF-D.2/D.3 can be gates. Panel default lands on **`protocol_requires_native`** (mimo, stepfun, glm, kimi explicit; none argue for reusing `translate_unsupported`). Error codes are client-visible API contract — not a plan-time decision.

**C2 — `prefer_proto` is the wrong mechanism; fail-closed needs a hard filter (7/7).** `prefer_proto` is a *streaming same-protocol bias*, not an eligibility filter (minimax, stepfun, qwen, deepseek, glm, kimi; mimo flags the pick-vs-candidate-set gap). Decisions never streams, so §4.5's "(stream or not)" language contradicts §4.7 and must be deleted. The guarantee must be a hard protocol-eligibility predicate in LB candidate-set construction / route-table assembly.

**C3 — Provider probe contract must be pinned (7/7).** "Minimal POST {base}/decisions" + "200 or documented error, pin later" is undefined. Required: which outcomes mean *reachable + auth OK* (200 / 401–403 with body / 400 validation — minimax, qwen), which mean *route missing* (404/405/connect-error — minimax), billing impact of a real Luna probe on every provider save (mimo, deepseek, glm), and a minimal-cost payload.

**C4 — Same-name multi-face listing semantics are unpinned — likeliest ship-day bug (6/7).** With O3's two provider rows both exposing `gpt-6-luna`: `/v1/models` dedup rule (minimax, stepfun, kimi), `pick_listing_route` resolution order in **both** client directions (glm, kimi; inverse direction unstated), and grant matching by listing id vs by name — name-matched grants silently authorize the wrong face (qwen, deepseek, stepfun).

**C5 — Reject site: `dispatch` before translate, plus LB candidate sets (6/7).** Hard-reject in `janus_http_proxy:dispatch` after classify is affirmed (minimax, mimo, stepfun, qwen, glm, kimi); 5 also require enforcement at `janus_lb` candidate-set construction so picker and handler can't diverge.

**C6 — janus-auto exclusion must be hard, both layers (5/7).** Gateway: filter at candidate-set build, not post-pick (mimo, qwen; deepseek demands a testable predicate). Dashboard: Router tier pickers must hard-block Decisions listings — delete the "**or warn**" alternative in §4.5 rule 4, which contradicts the "must never" rule two lines above (glm, deepseek). Split into two tasks: gateway filter + dashboard UI (minimax).

**C7 — CHECK-constraint migration needs sequencing + rollback (5/7).** Mid-rollout race: dashboard writes `openai_decisions` rows while follower gateways still carry the old CHECK → insert 500s; §9 doesn't sequence it (minimax, qwen). Rollback = disable providers (`enabled=0`), never reverse DDL (mimo, stepfun). Note catalog rebuild / generation bump (glm). Audit constraints beyond `providers`: `usage_events.protocol`, seed/dashboard validators (qwen).

**C8 — Usage parse must be additive + null-safe for permanently-absent output tokens (5/7).** Parser branch additive with null fallback (minimax), tolerate absent `output_tokens` without fabricating zeros that crash dashboards (stepfun), explicit invariant check for a protocol where output is *always* null (kimi), and a metric/log flag when a 200 carries no usage so unbilled rows are observable (glm; qwen affirms null-safe default).

## Near-consensus / objective gaps

**N1 — Live capture before plan (3/7 explicit, majority adjacent).** §2 claims facts "verified 2026-10-07" while O1 admits the usage schema is unpinned — both can't hold (deepseek, kimi, mimo). mimo/deepseek/kimi make a captured request/response fixture a **blocking gate before plan time**, written to `apps/janus_http/test/fixtures/probes/` — below threshold, but it is the #1 edit in three replies and matches the project's fixture-realism history.

**N2 — Closed-enum compatibility (4/7).** Concrete label values for `endpoint=decisions` / `protocol=openai_decisions`, where the closed enum lives (classify → metrics → dashboard SPEC/TEST-FLOWS), a pre-ship compatibility check (stepfun: "existing dashboards likely assume exactly four endpoints"), and admin error-map rendering for the new 400 codes (glm, kimi, mimo).

**N3 — Listing sync source (2/7 explicit).** §2 says there is *no* Decisions models-list API; §4.4 says listings "sync into `provider_models`" without naming the mechanism (reuse `/v1/models` sync stamped by provider-row protocol vs operator-entered). glm: this is "the mechanism that makes D3 real."

**N4 — Single-model objective gaps (1 each).** Stream-reject site unspecified (`janus_http_decisions` pre-dispatch vs `dispatch` vs `pick_listing_route`; precedent `stream_pair_untranslatable`) — stepfun. TF-D.7 "unit **or** e2e" violates AGENTS.md's E2E-only rule — qwen. TF numbering should follow TEST-FLOWS' TF-N convention — kimi. Concrete `MAX_BODY` value, explicit multipart rejection, upstream timeout budget, `x-request-id` propagation, degenerate 1-route LB behavior, and a regression flow proving the LB change leaves existing three-face picks unchanged — minimax/mimo/deepseek/kimi/glm respectively.

## Split opinions (not auto-applied — decision owner: **user**)

**S1 — Feature knob `decisions.enabled` (2/7).** stepfun-5 and qwen38-max: project convention gives every new face a default-off, 503-when-off knob (`decisions_disabled`), mirroring modality gates. The other five do not require it. Ground truth: AGENTS.md's documented knobs gate *modality* endpoints; whether a fourth *agent face* gets one is an operator call.

**S2 — O3 resolution.** Accept one-protocol-per-row and explicitly document the operational cost (key duplication, double-counted usage attribution, copy-provider UX) — minimax, mimo, glm, kimi lean this way; vs introduce a per-endpoint capability flag / catalog `face` tag — deepseek, mimo float it. All agree the current fiat needs documented consequences; they differ on whether the schema should change.

**S3 — Error precedence vs existing `wrong_modality` (1/7).** qwen38-max: a chat client naming a Decisions listing may hit the pre-existing local `wrong_modality` reject before any new code fires; spec never pins which code wins.

## Ground-truth notes

- Fixture path proposed by minimax/kimi (`apps/janus_http/test/fixtures/probes/`) matches the real convention documented in AGENTS.md — capture work should land there.
- AGENTS.md confirms the existing `wrong_modality` local reject and the `stream_pair_untranslatable` precedent (cited by qwen38-max, stepfun-5) — the new error code must be reconciled against both.
- AGENTS.md confirms the knob pattern (settings → persistent_term, default off, 503, gate asserts both regimes) — context for S1.
- stepfun-5 flags a premise to verify: whether `prefer_proto` actually exists in LB today; if absent, §4.5's "inherits" is new work, not reuse.
- Manifest cross-check: all 7 verdict strings match the attached replies; `quorum_met: true`, `degraded: false`.

## Top concrete edits (proposed, not applied)

1. **§4.5 rule 3:** replace "Prefer filtering…" with a hard LB contract — "MUST exclude `openai_decisions` routes from non-Decisions candidate sets (and vice versa) at candidate-set construction; empty eligible set → 400." Name enforcement sites: `janus_http_proxy:dispatch` + `janus_lb`. Delete the "(stream or not)" sentence.
2. **Resolve O2:** commit to `protocol_requires_native` (one code, one message, both directions); delete the `translate_unsupported` alternative; rewrite TF-D.2/D.3 to assert exactly that code (remove "(or no_route)"); register the code in the error registry and dashboard admin error map.
3. **§4.7 / stream reject:** pin the guard to `janus_http_decisions` handler pre-dispatch; state `stream_not_supported` as a new registry entry.
4. **§4.3 + §5.3 probe contract:** `POST {base}/decisions`, minimal body; success = 200 or 4xx-with-auth-proof (401/403 = bad key, 400 = reachable); failure = 404/405/connect-error; state billing impact + minimal-cost payload.
5. **§4.4 multi-face listing contract:** pin the sync source (stamp existing models sync with provider-row protocol), `/v1/models` dedup (one entry per name), `pick_listing_route` resolution order for both directions, and grant matching by listing id, not name.
6. **§4.5 rule 4:** split janus-auto exclusion into gateway candidate-set filter + dashboard Router hard-block; delete "or warn."
7. **Migration/rollout clauses:** sequence gateway CHECK migration before dashboard writes `openai_decisions` rows; note catalog rebuild/generation bump; rollback = disable providers; list every constraint touched (`providers`, `usage_events.protocol`, seed + dashboard validators).
8. **§5.1:** parser branch additive + null-safe for permanently-absent `output_tokens`; require a metric/log flag when a 200 carries no usage.
9. **§2/§9:** reconcile "verified 2026-10-07" with O1 — make live capture of a Luna request/response into `apps/janus_http/test/fixtures/probes/openai_decisions.json` the first plan task; pin O1 from it; gate TF-D.1/D.6 on the fixture.
10. **§5.2:** enumerate closed-enum additions (`endpoint=decisions`, `protocol=openai_decisions`) with all update sites (classify, metrics, dashboard SPEC/TEST-FLOWS) and a pre-ship compatibility check; fix TF-D.7 to E2E-only.
