# Scheduler v2 pi-audit — SYNTHESIS (2026-10-10)

Panel: minimax-m3, mimo-v26-pro, stepfun-5, qwen38-max,
deepseek-v41-flash, glm-53, kimi-k3. 9 rounds on
docs/superpowers/plans/2026-10-10-scheduler-v2.md
(rev 1 -> rev 10 FINAL, 284 -> 1553 lines).

## Trajectory

- r1: 6 GO WITH FIXES + 1 NO-GO (minimax: mmdb hand-rolled reader
  gamble, probe budget scope, geo-cache TTL). Folded: locus hex dep
  unconditional, capacity default infinity, health-before-geo,
  rtt_map-in-snapshot, master-issued probes + cluster cap, worker
  geo env-only, /stats/sched pinned surface.
- r2: 7/7 GWF — exposed the rev-2 capacity fold's own contradiction
  (tier-3 filter vs 13.5 local fallback) and select_v2 purity break.
- r3: 7/7 GWF — demotion self-inclusive median mathematically inert
  at N=2 (3 models), both update_counter shapes invalid (5-tuple
  wraps), counters inside the pure function. Folded: exclude-self
  threshold, ONE pinned counter form, {Order, Decisions}.
- r4: 7/7 GWF — probe/reserve contradiction, geo-known probe targets
  unrunnable, sched_rtt no source field, ack-miss over-release,
  owner-restart tracked-set loss. Folded: dispatch_probe/2 structural
  exemption, Source+SampledAtMono, purge age, adopt reset.
- r5: 7/7 GWF — A.3 stale seam (edit miss), EWMA seed unpinned
  (0-seed makes 13.6 fail deterministically), purge/late-done double
  decrement. Folded: seed-at-first-sample, release-iff-tracked,
  three-seam internal exclusion, health_ewma_ms surface.
- r6: 6/6 GWF + deepseek infra-fail #1 (empty output; context size).
  All naming/pin level. Folded: probe envelope direction, freshness
  counts probe rows, infinity guard, cold re-hello, 4-tuple tracked
  map, JSON naming rule.
- r7: 6/6 GWF + infra-fail #2 — but revealed rev-8's own edit drift
  (folds declared in header, never landed in body: badarg rationale,
  JSON skip enum, missing-row, exhaustion rule, gen-advance) + one
  real mechanism hole (probe recognition — probes never enter the
  tracked set) + one vacuous mechanism (SampledAtMono compare).
- r8: 6/6 GWF — confirmed the drift list; glm: "implementation-
  ready; the pi-audit GO box can be ticked once these folds land".
- r9 CONFIRMATION: 5/5 GWF + 1 GO WITH MINOR RESIDUALS + infra-fail
  #3. Every model: zero architecture/math/testability objections;
  all folds verified IN THE BODY. Residuals = one-sentence wording
  (E.6c stale compare echo, geo_disabled observable-event semantics,
  TEST_HOSTS existence-check exemption, Internal=>never-incremented
  invariant, `drained` reason label, two-worker topology pin,
  settle/completion barriers, self-cast tolerance wording).

## Resolution

rev 10 — FINAL folds all r9 residuals (16/16 grep-verified) and
ticks Part G. Verdict: RATIFIED. deepseek's 3 empty outputs are
context-limit artifacts (model alive on short prompts; worked at
r1-r6 sizes), documented in the r7/r8/r9 NOTE files.

## Load-bearing audit wins (would have been implementation bugs)

1. locus dep instead of a hand-rolled mmdb parser (NO-GO core).
2. capacity default infinity (default=1 silently broke v1 parity).
3. exclude-self demotion threshold (self-median never fires at N=2).
4. the single pinned ets:update_counter/4 form (both draft forms
   were invalid; the 5-tuple wraps and pins the counter forever).
5. EWMA seed-at-first-sample (0-seed arithmetic fails gate 13.6).
6. dispatch_probe/2 structural counter exemption + Internal=>
   never-incremented invariant (probe recognition was unexecutable
   as drafted).
7. ack-miss never releases (over-admission + negative counters).
8. is_number demotion guard (atom>number term-order trap).
9. Test-order rule for the done/error map-shape verification.
10. Two-worker topology + settle/completion barriers make 13.3/13.6
    falsifiable rather than vacuous.
