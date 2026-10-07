---
model: stepfun/step-5-preview
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: stepfun-5
---

Verdict: GO WITH FIXES — the core architecture is sound and D15’s terminal retry rule is falsifiable, but the write-gate readiness probe lacks a positive-path regression, and the shared-preamble extraction under D16 is the most likely source of silent cross-face breakage.

## 1. Critical risks

- **Write-gate false negative**: §4.3/§6 gates provider creation on *every* node returning `openai_decisions` from `GET :8080/readyz` within 3 s. A node stuck in `starting`/handover during a rolling restart would block the operator from creating the giveaway listing, with only the audited break-glass override as escape. This is a genuine operational deadlock risk.
- **D16 shared-preamble extraction**: the spec explicitly moves shared code in this change ("in this change"). A cowboy-listener start ordering bug (protocol list built before handler module registers, or a stale listener across a hot reload) makes `/readyz` silently omit `openai_decisions`, causing #1 above with no error. TF-D.16 tests only failure branches, never the positive path.
- **Probe budget starvation**: §4.3’s `20/day` budget is not explicitly per-provider vs. global. If global, a SaaS register with 10 Decisions providers exhausts health checks in ~2 days; if per-provider with shared `day_utc`, a `2026-13-01` style UTC-key bug resets all counters.
- **4 MiB cap too tight for documented shapes**: §3 admits "Input may be text and/or inline base64 images." A 4 MiB response cap (~4M chars) cannot hold three inline-base64 answers plus refusals; TFs D.19 will pass but real multimodal calls will 413.
- **`in_flight` orphan on restart**: if a probe times out at 60 s and the dashboard process restarts before clearing `provider_probe_state.in_flight`, the provider is locked out of all future probes until manual row surgery; the spec gives no TTL sweep.

## 2. Contradictions / stale claims

- §1 non-goal "per-face grants" vs. §4.4 "Grant confirm…every listing-add": the listing-add confirm explicitly fires across face boundaries ("candidate may fire when Decisions listing added even if chat already granted"). This is a dual-face name collision surfacing as a UX confirm storm, contradicting the stated non-goal that per-face grants are out of scope.

## 3. Missing first-ship requirements

- **D13 fixture re-shape dependency**: §7 asserts "Replay fixture → 200 + answers array" (TF-D.1) but the fixture (`openai_decisions.json`) does not exist until rollout step 2 (D13). The merge/CI gate (D11) gates only on guide excerpts. The plan is therefore **unmergeable until D13 exists**, which is not called out as a hard prerequisite for the merge commit.

## 4. Architecture / design notes

- The precedence table (§4.5) is genuinely disjoint and well-ordered. Keep case 5 (`protocol_requires_native`) strictly separate from the legacy `wrong_modality` (TF-D.13), but document the message fill (`<F>`/`<P>`) in the fixture-replay eunit, not only in TF-D.2, because client prompts usually print that string verbatim.
- `D15` cleanly moves the "post-Send retry" cut into shared-proxy `failover_decide` (good), but the spec should assert the terminal classification happens **before** `failover_decide` is ever called, not simply that retries are absent.

## 5. Top 5 concrete edits

1. **TF-D.16 positive path**: add `/readyz` mock with fresh heartbeat + advertised protocol → assert provider-create succeeds.
2. **Pin probe budget**: explicitly `probes_today`/`provider_id` unique; alert when any provider hits 19; document `in_flight` sweep (e.g., clear if `last_probe_at < now-5m`).
3. **Raise/justify 4 MiB cap**: document the largest D13 inline-base64 answer; if guides imply >4 MiB, cap at 8 MiB or make it configurable.
4. **Make fixture D13 a merge gate**, not just an implementation-start gate, or explicitly annotate the merge commit as blocked on a separate D13 landing.
5. **Tighten §4.4 dual-face confirm**: instead of firing on every listing-add regardless of existing grants, only fire when no prior Decisions grant exists for that name/model — removes the contradiction with the "per-face grants" non-goal.
