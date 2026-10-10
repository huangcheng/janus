# Scheduler v2.1 pi-audit — SYNTHESIS (2026-10-11)

Panel: minimax-m3, mimo-v26-pro, stepfun-5, qwen38-max,
deepseek-v41-flash, glm-53, kimi-k3. 9 rounds on
docs/superpowers/plans/2026-10-11-scheduler-v2.1-hardening.md
(rev 1 -> rev 5 FINAL RATIFIED, 388 -> 870 lines).

## Trajectory

- r1: 7/7 GWF — real catches: B.2 EWMA unimplementable on a
  single last-arrival-wins row; reconcile must filter Internal
  probe rows; schema_version bump contradiction; 6-model
  consensus on build provenance (prod image from uncommitted
  code); unary fallback contradicted its own gate step.
- r2: 7/7 GWF — sort-hint staleness REGRESSION (the one real
  find: post-B.1 the snapshot inflight loses its refresh source)
  → live reserve read at pick; dirty-flush trigger lost →
  {touched} poke; A.3 aggregation undefined; git status vs diff.
- r3: 7/7 GWF — mostly fold-execution drift (several folds
  landed in preamble only).
- r4: 7/7 GWF — F4 rewrite never executed (found only in C.1);
  C.2 worker render path; B.2 sort-cell ambiguity.
- r5: 7/7 GWF — admission primitive sequence; render enumeration
  drift; worker /metrics crash risk; 13.8 SIGTERM grace chain.
- r6: 2 GO + 4 GWF — first GOs; NODEDOWN Internal gate, C.4 ENV
  bake (labels invisible to runtime — qwen), worker guard.
- r7: "none blocking"/"not blockers" language; C-section order
  fold-execution miss; live-node negative clamp (qwen).
- r8: 4 GO + 2 GWF("none blocking") — counter triggers, knobs_off
  per-boot, silent-loss deferral, label drift.
- r9 RATIFICATION: kimi "ratify; nothing blocks implementation",
  minimax "shippable", glm GO, others one-sentence pins (folded:
  sched_rtt public caller read, 13.7 dispatch barrier, nodedown
  delete window named, reconcile max(0), insert-throws
  interleaving eunit).

## Resolution

rev 5 FINAL — RATIFIED; Part G ticked. deepseek recorded 5
consecutive context-limit infra-fails (empty outputs at spec
sizes; alive on short prompts) — documented per fleet-saga
precedent in the round NOTE files.

## Load-bearing audit wins

1. B.2 incremental EWMA (round-1 text was a silent no-op).
2. Internal=false filter everywhere reserve meets tracked.
3. Live reserve read at pick (staleness regression caught r2).
4. C.4 git status --porcelain + ENV bake (the incident's exact
   recurrence path closed twice over).
5. Worker-node /metrics guard (a dead-name crash exactly during
   dist storms).
6. Admission primitive = the atomic counter op itself.
7. 13.7 dispatch barrier (flaky assert caught before it shipped).
8. The nodedown delete window and take-vs-reconcile undercount
   both NAMED as accepted softness (shape, not just size).
