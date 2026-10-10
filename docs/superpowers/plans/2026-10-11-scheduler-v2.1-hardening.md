# Scheduler v2.1 — production hardening & throughput — SPEC (rev 5 — FINAL, RATIFIED)

> **For implementers:** single source of truth once ratified. All
> comments, commits, docs in English. Status: RATIFIED — 9 audit
> rounds; round 8 = 4 GO + 2 GWF("none blocking"), round 9 = all
> verdicts "ratify"/"shippable"/"nothing blocks" with wording-
> level items only (folded, plus the five post-round-9
> implementation pins). Part G is ticked. Full history:
> docs/audit/archive/2026-10-11-v21-r{1..9} + SYNTHESIS.md.
>
> **Rev 4 folds round 6** (2 GO / 4 GWF; all one-sentence):
> - NODEDOWN decrement gate named: per-key take applies the SAME
>   release conjunct — decrement only for `Internal =:= false`
>   taken rows, pinned `{2,-1},{Node,0}` form, then
>   `ets:delete(sched_reserve, Node)`; release/nodedown/purge
>   share ONE helper so the gate cannot drift.
> - Admission rollback pinned: the rollback uses the same
>   `{2,-1},{Node,0}` form and touches NO tracked row (nothing
>   was inserted for the losing candidate).
> - C.4 runtime visibility fixed (qwen — real catch): Docker
>   image LABELS are invisible to the running container — the
>   Dockerfile also bakes `ENV JANUS_GIT_SHA=${JANUS_GIT_SHA}`
>   so the env→persistent_term chain actually populates.
> - Worker-node safety (stepfun — real catch): /stats/sched and
>   /metrics GUARD the pool read (whereis/process check) — no
>   call into a dead name; on a worker the pool series are
>   simply absent, never a crash (dist storms are exactly when
>   this telemetry must survive).
> - F7 scope tightened: the single-snapshot rule governs POOL
>   series; the dist counters are a separate per-node local read
>   (two reads per scrape, stated).
> - 13.7 timing wording corrected: the <30 s bound rides the
>   docker-KILL RST (hard death); the tick floor at ticktime 30
>   is 30–45 s and covers only SILENT loss — the step asserts
>   the kill path; silent-loss testing is out of gate scope.
> - A.3/B.2 unified: all-expired reads `rtt_ms_avg` null
>   (never 0); the stale header phrase "sort falls back" is
>   gone (the fallback is B.2's per-provider rule).
> - E race eunit added: release-after-nodedown creates a
>   transient -1 via the insert-default (tick clamps; bounded,
>   observable); A.2 eunit asserts sticky STILL arms while a
>   lost probe row lingers (benign — probes don't reserve).
> - Runbook G: the v2.1 softness DIRECTION flip noted (v2
>   residue = stranded capacity; the take-vs-reconcile race =
>   transient over-admission until completion) — a different
>   failure SHAPE, not just size.
> - Part C sections renumbered into reading order (C.1, C.2,
>   C.3, C.4).
>
> **Rev 3 folds round 2** (7/7 GO WITH FIXES; findings fully
> mechanical — one real regression caught):
> - **Sort-hint staleness regression FIXED (qwen — the one real
>   find)**: post-B.1 the snapshot `inflight` loses its refresh
>   source (reserve writes are caller-side). `pick/1` now reads
>   `sched_reserve` LIVE for the inflight sort component (public,
>   read_concurrency — caller-side, one extra ETS read per
>   candidate); the snapshot's inflight field stays for
>   DISPLAY/health only. The knobs-off least-inflight behavior is
>   therefore FRESHER than v2 (was flush-bounded), not staler.
> - **Dirty-flush trigger re-pinned** (kimi/glm): releases send a
>   cheap completion-path poke cast `{sched, 2, {touched, Node}}`
>   that marks the snapshot dirty — one message per job
>   COMPLETION (the same rate as v2's release cast; the PICK hot
>   path stays mailbox-free). Fully quiet nodes remain
>   tick-bounded (30 s) — stated honestly; the ≤ 250 ms flush
>   bound applies after completions.
> - **A.3 `rtt_ms_avg` defined**: per node = arithmetic mean of
>   the node's unexpired per-provider EWMA cells (B.2);
>   `rtt_sample_count` = sum of SampleCounts; ALL rows expired ⇒
>   null / 0 and the sort falls back to `infinity` (v2 rule).
>   The stale "mean of raw rows" parenthetical is deleted.
> - **C.4 dirty-tree guard**: `git status --porcelain` (the
>   incident tree passed `git diff --quiet` — UNTRACKED files were
>   the leak); missing build-arg stamps `unknown` (never empty);
>   per-worker `git_sha` added to the A.3 field list + fixture.
> - **B.1 race pins**: the release decrement uses the pinned
>   insert-default form (`{2,-1}, {Node,0}`) so a nodedown row
>   delete CANNOT badarg the session (transient -1 → tick clamp +
>   zero-row cleanup; zero-row deletion scoped to nodes ABSENT
>   from pool records so it never races a pick's insert-default).
>   NODEDOWN on sched_tracked (keyed by JobRef, no take-by-node):
>   `ets:select` then per-key `ets:take` (take owns the decrement;
>   a concurrent release finds nothing). PURGE uses the same
>   per-key take spine. The take-vs-reconcile double-decrement is
>   named: undercount persists until the job completes (accepted
>   softness; reconcile never increments).
> - **Drain-idle emptiness conjunct narrows to NON-INTERNAL
>   tracked empty** (deepseek/minimax): a lost probe row can no
>   longer stall sticky for 10 min (it lingers until purge with
>   no reserve impact).
> - **13.7 implementability pins**: w1 pinning via `affinity_node`
>   (the gate's existing mechanism); the unary phase uses the
>   SLOW key (a fast job would finish pre-kill); the knob flips
>   via a SEPARATE stack boot (env is boot-time); the evicted
>   worker DISAPPEARS from the workers array (assert absence +
>   workers_available drop, not a phantom row); 13.7/13.8 run
>   with `JANUS_NET_TICKTIME=30` on every node (Part D exercised
>   by the gate; the <30 s nodedown bound assumes RST-or-tick
>   detection — both satisfied at ticktime 30).
> - **C.1**: rtt gauge reads the row Ewma DIRECTLY (the 64-window
>   belongs to the JSON rtt_ms map only); counter caps are
>   per-family (`dispatch_worker_total{node,provider}` cap 256 —
>   fleet-bounded anyway); `sched_note_inflight_deprecated_total`
>   rendered.
> - **C.2 per-node surfacing** (qwen/minimax): every node renders
>   its OWN `janus_sched_dist_*` counters on its own /stats/sched
>   (local read, no wire; dist storms are exactly when the worker
>   side matters) — no cross-node aggregation. The fallback
>   deliverable stated NOW: expect NO unbusy message; events
>   count + last-busy age is the deliverable, upgraded only if
>   OTP 27 verification finds an unbusy notification.
> - **Part E**: the pre-byte predicate lives in the master
>   session's process dictionary (`janus_worker_forwarded`,
>   set on the first forwarded chunk/done, read at fallback time,
>   dies with the session); the `janus_error` exclusion is
>   RESTATED in the body; the capacity bypass on mass worker
>   loss (release-then-local never re-reserves) is documented as
>   the accepted availability-over-discipline trade of the knob.
> - **13.4 rest-state assertion written into Part F** (was only a
>   fold note); a capacity-N concurrent-pick-vs-release eunit and
>   a drain-idle-arming eunit (tick path + lost-probe case) added
>   to E's enumeration; G notes RTT sorting is now EWMA-smoothed
>   (deliberate order change vs v2 when the knob is ON); B.2
>   documents the seed-at-first cold-outlier bias (~4 samples)
>   and TTL-expiry re-seeding.
> - Part I stale "schema_version 2" line FIXED (stays 1); F4
>  rewritten to the counter/gauge split (was stale v2 eviction
>   text).
>
> **Rev 2 folds round 1** (7/7 GO WITH FIXES; every fold named):
> - **B.2 rewritten — incremental EWMA.** The round-1 text was
>   unimplementable (sched_rtt is ONE row per {Node,Provider},
>   last-arrival-wins: "EWMA over unexpired samples" had no history
>   and nondeterministic fold order). The EWMA is now maintained
>   INCREMENTALLY at each {rtt,...} cast (α = 0.25,
>   seed-at-first-sample — the health-EWMA pattern), stored in the
>   row itself; snapshot/sort//stats/sched//metrics all read ONE
>   canonical number (rtt_ms_avg and the gauge are the EWMA — no
>   mean-vs-EWMA split).
> - **B.1 reconcile/purge filter `Internal =:= false`** (3 models):
>   probe rows are tracked but never reserved — counting them
>   manufactures permanent drift. Reconcile compares reserve vs
>   NON-INTERNAL tracked rows only; purge still reaps all rows.
>   Nodedown = `ets:take` the node's tracked rows + decrement per
>   non-Internal row (blanket delete would double-decrement against
>   concurrent caller releases).
> - **B.1 write order + form restated**: reserve bump FIRST (the
>   pinned `ets:update_counter/4` form — 5-tuple UpdateOp still
>   FORBIDDEN), tracked insert only on success; release =
>   `ets:take` then pinned-form decrement. CONCURRENCY NOTE (round-1
>   misconception corrected): the reserve increment is ALREADY
>   caller-side in v2 and capacity exactly-one-wins comes from the
>   counter's own atomicity + insert-default (the v2 concurrent
>   capacity-1 eunit proves it) — B.1 moves ONLY the tracked
>   insert/release out of the mailbox; `pick/1` stays caller-side,
>   unchanged. `sched_reserve` gains `{write_concurrency, true}`;
>   the tick deletes zero/negative-clamped rows (transient
>   negatives still healed by the existing corrective write).
> - **Drain-idle re-armed without the lost event** (3 models):
>   caller-side decrements mean the gen_server no longer sees "hit
>   zero". Arming now evaluates on EVERY sched_tick AND every
>   dirty-flush republish (≤ 250 ms): node draining AND the node's
>   tracked set empty (any kind — a LOST probe delays sticky until
>   its purge; documented) AND reserve == 0. DRAIN_IDLE_MS
>   semantics unchanged.
> - **schema_version stays 1** (3 models): every JSON change is
>   additive; a bump would break the pinned consumers for no gain.
> - **/metrics cardinality rules split** (3 models): COUNTER label
>   sets are NEVER evicted (eviction breaks monotonicity/rate) —
>   beyond the cap the counter REJECTS new label sets into an
>   overflow accumulator; GAUGES render deterministically (EWMA
>   recency-64 window, no eviction flapping beyond the natural TTL
>   churn — documented).
> - **Part E × Part F contradiction resolved** (stepfun): 13.7 is
>   SPLIT — stream-kill phase (clean abort; fallback forbidden)
>   AND unary-kill phase (fallback counter with the knob on).
>   Part E scope pinned: chat-family jobs ONLY (chat_completions +
>   responses — image/TTS/ASR/video excluded: double-billing a
>   generation is a different order of cost); fires ONLY on worker
>   session `{'DOWN'}` (worker_lost) BEFORE any forwarded byte,
>   where "pre-byte" = no chunk forwarded AND no done/error emitted
>   for the JobRef (ONE predicate); never on send-fail (already
>   local), never `janus_error` completions, never twice.
> - **Build provenance** (6 models): the prod image was built from
>   an uncommitted tree — new Part C.4 stamps the git SHA (build
>   arg → persistent_term → /stats/sched additive key + image
>   label) and deploy_prod.sh REFUSES a dirty tree.
> - **C.2 scoped**: system_monitor is node-global single-slot —
>   verified exclusive at implementation (grep for other callers);
>   master AND worker run the monitor but only the MASTER's
>   counters surface in sched_stats/0 (no new dist messages — the
>   "no new wire" invariant means gateway-role messages; local
>   telemetry is per-node).
> - **the knob-off guard (C.4 after renumbering) fires at FIRST worker admission** (not boot — admission
>   is async) AND surfaces in /stats/sched, not only /metrics.
> - **Chaos numeric bounds pinned** (4 models): 13.7 — stream
>   abort < 30 s; nodedown evict < 30 s (the NODEDOWN path clears
>   reserve/tracked, NOT the purge — 10-min purge is the
>   last-resort); re-hello recovery ≤ 70 s (keepalive 60 s +
>   retry; the worker's pool-pid monitor → hello loop →
>   `net_kernel:connect_node/1` retry ALREADY EXISTS — Task C);
>   two-worker topology pinned with a w2 `dispatch_worker` delta;
>   13.8 — in-flight client failure < 20 s (docker-restart
>   SIGTERM/SIGKILL grace chain), post-restart counters asserted
>   ABSOLUTE ≥ 1 (they reset at restart).
> - **A.2 wording fixed**: the note_inflight handler ships as a
>   counted no-op, full stop (the old-beam justification dropped);
>   the {release,...} cast removal is same-node (pool + master
>   session restart together); Part I reworded — select_v2's
>   input contract is unchanged, only BUILDER fixtures update, and
>   the knobs-off ordering equivalence is still asserted.
> - **JobRef collision across adopt**: JobRefs are
>   crypto:strong_rand_bytes(16) — 128-bit random, birthday
>   collision ≈ 0; a stale release from the dead owner `ets:take`s
>   nothing (no-op). Stated.
> - **Rest-state gate invariant** (stepfun): the 13.4 step gains
>   "every reserve_inflight == 0 after traffic drains" — the next
>   residue incident is a FAIL, not a mystery.
> - **Pool mailbox gauge** (glm): `janus_sched_pool_message_queue_
>   len` in /metrics — the direct B.1 success signal; the
>   implementation commit records a before/after measurement.
> - **vm.args idempotency + cluster symmetry** (3 models): REPLACE
>   any pre-existing net_ticktime/zdbbl lines (never append
>   duplicates); net_ticktime changes must land on ALL nodes in
>   one deploy window (asymmetric ticktime flaps dist) — runbook
>   G.5.
> - Residual unknown noted: the idle-inflight residue root cause
>   is UNPROVEN (dual-track leak vs concurrent user traffic); A.2
>   makes it moot operationally and the rest-state invariant makes
>   any recurrence visible.
>
> Base: scheduler v2 (rev 10 FINAL, RATIFIED — shipped 2026-10-10)
> running in production as a 3-node cluster (aliyun master + local
> worker, jdcloud + tencent workers; single entry via the master).
> The 2026-10-10 production evaluation
> (`%TEMP%/janus-perf-report-20261010.md`, summarized in Part 0.2)
> drives every item here.

**Goal.** Turn the evaluation's findings into code: correctness
fixes observed live, the throughput ceiling (single serialized pool
mailbox), observability gaps that made diagnosis harder than it
should have been, network-layer tuning hooks, one opt-in recovery
policy, and chaos gate coverage for the failure modes production
will eventually hit.

**Non-goals.** No change to tier ORDER or the selection algorithm's
shape (affinity → health → geo → sort stays exactly as ratified in
v2; EWMA/demote math untouched except where a part says so). No
per-provider health split, Master HA, or multi-region entry —
recorded in Part H (deferred; per-provider health is the natural
v2.2). No DB migrations. No new wire messages (all four nodes ship
together; mixed-version tolerance rules from v2 Part 0.10 continue
to hold — this spec only REMOVES a master-side internal call,
  ADDS the additive `git_sha` hello key (v2 Part 0.10 tolerance),
  and ADDS optional vm.args lines — all safe under rolling deploy).
---

## Part 0 — Evidence, failure modes, invariants

### 0.1 Production evidence (2026-10-10, 3-node cluster)

1. **Blind selection shipped enabled-off** (by design): all knobs
   false ⇒ v1 `least-inflight + name order`; name order
   `'106…' < '117…' < 'janus-worker…'` biased traffic to the
   WORST worker (historical TTFB EWMA 48 s) while the fastest
   local worker got none. Ops enablement is Part G; the code-side
   gap is that nothing SURFACES "knobs off + slow workers" —
   fixed by Part C.
2. **`sched_v` displayed as 1 in production** while the deployed
   code sends `sched_v => 2`
   (janus_worker_dispatch:hello_opts/1 → janus_worker_wire:hello/3
   → pool normalize). The production /stats/sched renders a
   `workers` array that DOES NOT EXIST in main
   (`would_demote`/`dispatched_total`/`rtt_ms_avg` appear in no
   repo module): **the production image (sha256:9d036ffc…) was
   built from a tree with extra uncommitted code.** Two
   consequences: (a) the repo must gain a workers view of at
   least equal fidelity (Part A.3) so the next deploy-from-main
   does not REMOVE observability the operator already uses;
   (b) the sched_v=1 display is a bug in that unreleased view or
   in the ingest chain — Part A.1 pins the truth with eunit so
   whatever view ships reads 2.
3. **Idle inflight residue**: tencent showed `inflight: 3` at rest
   after all benchmark traffic completed. Root cause unknown —
   candidate leaks: the v1 `note_inflight` master-side accounting
   racing the v2 reserve counter (dual-track), or genuine user
   traffic concurrent with the measurement. Part A.2 collapses the
   dual-track into ONE source of truth with self-healing, making
   residue impossible to confuse with capacity.
4. **Provider-side latency dominates** (8-token requests 1.1–5.3 s;
   raw worker→provider RTT 70–230 ms): the gateway relay overhead
   is <150 ms. No item here tries to fix provider latency; items
   make the gateway's share smaller and its behavior under
   provider slowness smarter (health demotion once enabled).

### 0.2 Failure modes to guard (project rule — first)

- **F1 Caller-side ETS writes corrupt bookkeeping** (Part B moves
  track/release into caller processes): a crashed caller between
  the reserve increment and the tracked insert leaves counter >
  tracked — v2's TWO-TICK reconcile guard already heals this;
  B.1 must keep that guard working against the ETS tracked set
  (reconcile reads the ETS snapshot, not gen_server state).
- **F2 Heir adopt of the tracked table after pool restart**: an
  adopted sched_tracked may contain entries whose jobs died with
  the old owner — adopt RESETS it like sched_reserve (same cold
  class; running jobs uncounted until they finish).
- **F3 system_monitor busy_dist_port message storm**: a saturated
  dist port can transition busy/unbusy rapidly; the monitor
  process must count transitions with a bounded-rate logger and
  never let monitor messages pile into a mailbox (monitored
  process = a dedicated gen_server that only counts).
- **F4 /metrics cardinality (split by kind, C.1's rule)**:
  COUNTER label sets are NEVER evicted (eviction breaks
  monotonicity/rate) — per-family caps with reject-new-into-
  overflow accumulators; GAUGES render deterministically (the rtt
  gauge reads the row Ewma directly; the 64-recency window
  governs only the JSON rtt_ms map).
- **F5 Unary local fallback double-billing** (Part E): the master
  cannot know whether a dead worker already paid the upstream.
  The knob defaults OFF, counts every use
  (`dispatch_local{unary_fallback}`), never fires for streams,
  never fires after ANY byte reached the client, never retries a
  second time, and is documented as an explicit cost/latency
  trade for the operator to opt into.
- **F6 vm.args knob misrender breaks boot** (Part D): the
  entrypoint renders extra lines into vm.args BEFORE exec; a
  malformed env value must be dropped with a warning and boot
  must proceed with OTP defaults — never an unbootable node.
  Values are validated as integers with bounded ranges
  (ticktime 10–120 s; zdbbl 128–65536 KB).
- **F7 Workers view reads torn state**: the workers array joins
  pool members, ETS tables, and EWMA state across a gen_server
  call — it must take the SAME single sched_stats/0 snapshot the
  JSON endpoint uses (the rule governs POOL series; the C.2 dist
  counters are by-design a separate per-node local read).

### 0.3 Invariants

- **Selection semantics unchanged**: default knobs off ⇒ the
  PURE `select_v2` contract is v1 bit-for-bit (the equivalence
  eunit keeps passing). RUNTIME ordering reads the reserve
  counter live — fresher than v2's flush-bounded hint by design
  (A.2); the invariant is scoped to the pure function, not
  runtime traces.
- **Request never fails because of bookkeeping**: every Part B
  change degrades to "counter slightly off until the tick heals"
  (the accepted v2 softness class) — never to a refused dispatch.
- **One source of truth for inflight**: after A.2 the reserve
  counter is the ONLY live count; the pool member `inflight` map
  (v1 sort hint) is REMOVED. The SORT reads `sched_reserve` LIVE
  at pick time (caller-side, public, read_concurrency — fresher
  than v2's flush-bounded hint); the snapshot's inflight field is
  display/health-only.
- **Mixed-version rolling safety**: removing the master-side
  `note_inflight` cast is safe (it is master→master; workers
  never send it). New vm.args lines are inert to old code. New
  /metrics content is additive. The workers view is additive
  JSON. Masters-first deploy order still applies.
- **Cost floor**: no item adds upstream calls; probes remain
  default-off and untouched.

---

## Part A — Correctness & reconciliation

### A.1 `sched_v` truth pin

- Eunit (live pool): hello with `#{sched_v => 2}` → member record
  carries 2 → whatever surface displays sched_v (pool
  `sched_stats/0` workers entry) returns 2. Old-shape hello
  (no key) → 1. This pins the ingest chain; the display bug in
  the unreleased prod view cannot survive repo-side once A.3
  lands with this test.
- No wire change (v2 Part 0.10 already additive).

### A.2 Inflight single-source unification

- DELETE the master-side `note_inflight/2` cast usage from
  `janus_http_worker_client` (both call sites around dispatch).
  The pool keeps the `note_inflight` handler as a counted no-op
  (`sched_note_inflight_deprecated_total`, no state mutation) —
  belt-and-braces only; the cast is master-internal (pool + master
  session restart together on upgrade; VERIFY at implementation
  with a grep that no worker-side caller exists).
- `select_v2` sort hint: `pick/1` reads `sched_reserve` LIVE,
  per candidate, for the inflight sort component (caller-side;
  public table with read_concurrency — FRESHER than v2's
  flush-bounded hint; one extra ETS read per candidate). The
  snapshot's `inflight` field is DISPLAY/health-only (the builder
  still copies reserve counts into it for the view). The PURE
  `select_v2` input contract is unchanged (candidates carry an
  `inflight` integer — pick supplies it live); the fixtures and
  the knobs-off ordering equivalence stay.
- Drain-idle arming (`inflight hits 0 while draining`): v1 armed
  the sticky timer off member.inflight; after unification the
  decrements are caller-side ETS writes the gen_server never
  sees. Arming now evaluates on EVERY sched_tick AND every
  dirty-flush republish after a COMPLETION (the {touched,...} poke
  cast, B.1 — ≤ 250 ms post-completion; fully quiet nodes are
  tick-bounded, 30 s): node draining AND the node's NON-INTERNAL
  tracked set EMPTY (a lost probe row no longer stalls sticky —
  it lingers until purge with no reserve impact) AND reserve == 0.
  A downward reconcile heal cannot false-arm (the emptiness
  conjunct requires the jobs gone). Keep DRAIN_IDLE_MS = 30 s
  unchanged.
- Residue impossibility: reserve decrements live on
  done/error/worker_lost/send-fail + two-tick reconcile + purge
  (v2 rules) — with note_inflight gone there is no second writer
  to drift. eunit: drain-idle arming via the tick path AND via
  the {touched,...} poke (draining ∧ non-Internal tracked empty ∧
  reserve == 0), including the lost-probe-does-NOT-stall case.

### A.3 Production reconciliation: repo-side workers view

- `janus_worker_pool:sched_stats/0` grows a `workers` array (the
  single F7 snapshot): per member —
  `node, status(up), sticky, capacity, region, sched_v, draining,
  inflight (reserve sample), dispatchable, dispatched_total
  ({dispatch_worker, Node, _} sum), health_ewma_ms (raw display
  value), rtt_ms_avg (per node = arithmetic mean of the node's
  unexpired per-provider EWMA cells per B.2 — DISPLAY-ONLY,
  never a sort input; ALL expired => null (never 0); the sort's
  per-provider fallback is B.2's rule),
  rtt_sample_count (sum of the cells' SampleCounts; 0 when none),
  would_demote (health on AND is_number(E) and E > demote_ms —
  null when unknown), git_sha (the worker's hello-reported image
  SHA — mixed-image fleets visible)`.
- `/stats/sched` renders it (additive key; schema_version STAYS
  1 — every change here is additive). The field set deliberately
  MATCHES the production view the operator already watches,
  field-by-field: node, status, sticky, capacity, region, sched_v,
  draining, inflight, dispatchable, dispatched_total,
  health_ewma_ms, rtt_ms_avg, rtt_sample_count, would_demote,
  git_sha — deploy-from-main is observability-neutral-or-better,
  and each field is asserted by an eunit fixture. ONE canonical
  RTT family: the per-{node,provider} EWMA cell (B.2) feeds the
  sort key and the /metrics gauge verbatim; the per-NODE
  `rtt_ms_avg` is the arithmetic mean of the node's unexpired
  cells (display-only aggregation, never used for sorting;
  all-expired => null, never 0); `rtt_sample_count` is the
  cells' SampleCount sum.
- Eunit: fixtures drive hello + ttfb + rtt and assert the array
  end-to-end (including sched_v => 2 per A.1 and would_demote
  null-vs-boolean transitions).

---

## Part B — Throughput

### B.1 Pool bookkeeping off the gen_server mailbox

- New heir'd public table `sched_tracked`:
  `JobRef(binary) => {Node, ReservedAtMono, ProviderId, Internal}`,
  `{write_concurrency, true}`, `{read_concurrency, true}`.
  `sched_reserve` gains `{write_concurrency, true}` (same
  protected/public options as v2 otherwise).
- WRITE ORDER (pinned): the winning pick bumps `sched_reserve`
  FIRST with the ONE pinned form
  `ets:update_counter(sched_reserve, Node, {2, 1}, {Node, 0})`
  (the 4-tuple UpdateOp `{Pos, Incr, Threshold, SetValue}` stays
  FORBIDDEN — it wraps; the insert-default means the increment
  itself never fails). ADMISSION PRIMITIVE (pinned sequence):
  increment FIRST, compare the RETURNED count to capacity,
  roll back and try the next candidate when over — the atomic
  counter op IS the admission decision (never read-check-then-
  increment, which would race); capacity exactly-one-wins
  follows. The ROLLBACK uses the same pinned `{2,-1},{Node,0}`
  form and touches NO tracked row (nothing was inserted for the
  losing candidate). On winning: insert the tracked row; release is `ets:take/2`
  then, iff the taken row exists AND `Internal =:= false`, the
  pinned-form decrement
  `ets:update_counter(sched_reserve, Node, {2, -1}, {Node, 0})` —
  the INSERT-DEFAULT makes the decrement badarg-IMPOSSIBLE even
  when nodedown deleted the row (a transient -1 clamped by the
  tick; the session NEVER crashes on bookkeeping). take() owns
  the decrement: double release is a no-op (idempotent). If the
  tracked INSERT itself throws (boot/adopt race, system_limit):
  the reservation stands untracked and the two-tick reconcile
  reclaims the excess — the same heal as a crashed caller (named;
  eunit asserts the EXACT interleaving: increment succeeds,
  insert throws, two ticks heal — not just generic drift).
- COMPLETION POKE: the release path also casts
  `{sched, 2, {touched, Node}}` to the pool — the dirty-flush
  trigger after B.1 (caller-side ETS writes mark nothing dirty);
  the handler marks the snapshot dirty. One message per job
  COMPLETION (v2's release-cast rate; the PICK hot path stays
  mailbox-free); a fully quiet node is tick-bounded (30 s) — the
  stated bound. CONCURRENCY (round-1 misconception corrected):
  the reserve increment is ALREADY caller-side in v2 — capacity
  exactly-one-wins comes from the counter's own atomicity +
  insert-default (the v2 concurrent capacity-1 eunit proves it).
  B.1 moves ONLY the tracked insert/release out of the mailbox;
  `pick/1` itself is unchanged. Probes insert the same row shape
  with `Internal => true` and never decrement.
- The gen_server keeps: sched_tick (reconcile/purge/snapshot,
  drain-idle arming per A.2), probes, {ttfb,...}/{rtt,...}/{load,...}
  casts (post-completion, not latency-path), hello/drain/nodedown,
  /stats/sched.
- RECONCILE (two-tick guard, unchanged healing rule) now compares
  reserve vs the node's NON-INTERNAL tracked rows (`Internal =:=
  false` — probe rows are tracked but never reserved; counting
  them would manufacture permanent drift). Reconcile NEVER mutates
  tracked; it only decrements persisting reserve excess — always
  `max(0, reserve - |non-internal tracked|)` (a purge/take gap
  can make the raw delta negative; never decrement below the
  floor). The release helper wraps its take in a try (a badarg
  at table-shutdown skips the decrement — never double-applies).
  The
  take-vs-reconcile race (a heal landing between a caller's take
  and decrement) can UNDERCOUNT — reconcile never increments, so
  the undercount persists until those jobs complete (accepted
  softness, named; over-admission bounded by the race window and
  the two-tick guard) — eunit'd with the bound asserted.
- PURGE (10 min) reaps ALL expired rows (probes included — without
  decrement for Internal rows; reserve_purged counts only real
  reservations, the v2 rule).
- NODEDOWN: `sched_tracked` is keyed by JobRef (no take-by-node):
  `ets:select` the node's JobRefs then per-key `ets:take` — each
  taken row applies the SAME release conjunct (decrement only
  when `Internal =:= false`, pinned `{2,-1},{Node,0}` form; a
  taken probe row decrements nothing; a concurrent caller
  release finds nothing — no double-decrement), then
  `ets:delete(sched_reserve, Node)`. NAMED WINDOW: a pick
  incrementing between the take loop and the delete loses its
  fresh increment (under-admit-by-1 until that job completes) —
  the same accepted class as take-vs-reconcile, now named. Release / nodedown / purge
  share ONE take-and-maybe-decrement helper so the gate cannot
  drift between them.
- PURGE uses the same per-key `ets:take` spine as release/nodedown
  (never delete-then-decrement). NAMED: a job legitimately in
  flight > 10 min is purged (its slot freed early — the v2
  long-stream accepted class; the later release no-ops and the
  node over-admits by that one job until it completes).
- The tick's corrective write CLAMPS negative rows to 0 for ALL
  nodes (a release racing nodedown re-creates `{Node,-1}` via the
  insert-default on a re-hello'd LIVE node — the clamp heals it
  same-tick; without it the -1 would persist and over-admit by
  one slot), and deletes zero rows ONLY for nodes ABSENT from
  pool records (never races a live pick's insert-default).
- F1/F2: adopt RESETS sched_tracked IN THE SAME shared helper as
  the other resets (one code path, cannot drift). JobRefs are
  crypto:strong_rand_bytes(16) — a stale release from a dead
  owner `ets:take`s nothing (no-op); 128-bit birthday collision
  across adopt generations ≈ 0, stated.
- eunit (live pool, ported from v2 E.4): concurrent picks on
  capacity-1 exactly one wins; a capacity-N concurrent-pick-vs-
  release race fixture; release idempotence; probe neutrality
  (Internal row release = no decrement); post-purge done no-op;
  drift correction across two ticks against the ETS set with the
  undercount bound asserted; adopt cycle resets the tracked
  table; nodedown clears both tables via select+take (a release
  RACING nodedown's take creates a transient -1 via the
  insert-default — tick clamps; bounded, observable); sticky
  STILL arms while a lost probe row lingers (probes don't
  reserve — benign, asserted so a future reader doesn't mistake
  it for a stall). The knobs-off ordering equivalence is still
  asserted (select_v2's input contract unchanged; the live-read
  pick path gets its own ordering eunit — reserve counts written
  between two picks must flip the order exactly as the counts
  dictate).

### B.2 RTT sort key → incremental EWMA

- REV 2 (round-1 text was unimplementable: one row per
  {Node,Provider} last-arrival-wins has no sample history to fold
  and table iteration order is undefined). The {rtt,...} cast
  handler maintains the EWMA INCREMENTALLY at arrival (the
  health-EWMA pattern): the row becomes
  `{{Node, ProviderId}, RttMs, Source, SampledAtMono, ExpiresAtMono,
  Ewma, SampleCount}` — Ewma updated `E' = 0.75*E + 0.25*x`
  (seed-at-first-sample: E1 = x1), SampleCount += 1.
  last-arrival-wins stays for the RAW RttMs field; Ewma/SampleCount
  ride the same single row (no schema proliferation).
- SORT KEY (pinned): a pick targeting provider P reads the
  {Node, P} cell's Ewma LIVE, caller-side — `sched_rtt` is
  public with read_concurrency for this read (a private table
  would badarg the hot path); a node with NO cell for P (never
  sampled or expired) sorts as `infinity` (the v2 unknown-last
  rule). The
  /metrics gauge reads the same cell Ewma. /stats/sched's
  per-NODE `rtt_ms_avg` is the A.3 display mean — NOT the sort
  input. Determinism is inherent (incremental update, no fold
  order).
- DOCUMENTED BIASES: seed-at-first-sample lets one cold outlier
  bias ~4 samples (acceptable — RTT is preference-only); TTL
  expiry drops the row and its EWMA whole (re-seeds on the next
  sample). eunit: single-sample behavior identical to today
  (E1 = x1); two-sample ordering (an outlier raw sample must not
  flip the sort when the EWMA says otherwise); TTL expiry drops
  the row whole; a node whose rows ALL expire reads rtt_ms_avg
  null / count 0 (display); the per-provider sort cell is simply
  absent — B.2's unknown-last rule, unchanged).

---

## Part C — Observability

### C.1 sched_* → /metrics (prometheus text)

- janus_http renders (reading `janus_worker_pool:sched_stats/0`
  ONCE per scrape — the same single snapshot as /stats/sched;
  F7's single-snapshot rule governs POOL series; the dist
  counters are a separate per-node local read (two reads per
  scrape, stated). BOTH endpoints GUARD the pool read
  (whereis/process check — no call into a dead name; on a
  worker the pool series are absent, never a crash): counters `janus_sched_geo_match_total`,
  `janus_sched_dispatch_local_total`,
  `janus_sched_capacity_exhausted_total`,
  `janus_sched_health_demote_total`, `janus_sched_probe_total`,
  `janus_sched_probe_skip_total`, `janus_sched_rtt_dropped_total`,
  `janus_sched_reserve_purged_total`,
  `janus_sched_dispatch_worker_total{node,provider}`, gauges
  `janus_sched_snapshot_gen`, `janus_sched_workers_available`,
  `janus_sched_health_ewma_ms{node}`,
  `janus_sched_rtt_ms{node,provider}` (reads the row Ewma
  DIRECTLY per B.2 — no windowing on the gauge), 
  `janus_sched_pool_message_queue_len` (process_info of
  the pool gen_server — the direct B.1 success signal),
  `janus_sched_note_inflight_deprecated_total`
  (trigger: the deprecated no-op handler firing; the v2 clamp
  semantics carry over unchanged for rtt_dropped — negative/
  non-finite samples at ingest — and probe_skip's five v2 Part 0.2
  reasons; dispatch_local renders as ONE counter with the reason
  as a label, enum-bounded by F4),
  `janus_sched_dist_busy_events_total` (+ busy-ms/age per the
  C.2 verification), `janus_sched_knobs_off_total`, and the
  knob flags as 0/1 gauges. WORKER NODES: pool-derived series
  are absent on workers (sched_stats/0 is master-only) — the
  renderer omits them without crashing; the dist counters
  render everywhere (the C.2 local read).
- CARDINALITY RULES (F4, split by kind): COUNTER label sets are
  NEVER evicted — eviction breaks monotonicity/rate(); caps are
  PER-FAMILY with reject-new-into-overflow accumulators
  (`dispatch_worker_total{node,provider}` cap 256 — a 4-node ×
  20-provider fleet fits; beyond it, attribution falls into the
  label-free overflow counter — documented trade). GAUGES render
  deterministically (the rtt gauge reads the row Ewma — no gauge
  windowing; the 64-recency window governs only the v2
  /stats/sched `rtt_ms` MAP, whose schema is unchanged from
  v2).
- Text format via the existing metrics renderer module (read it;
  match its escaping/label conventions exactly).

### C.2 busy_dist_port telemetry

- New janus_core gen_server `janus_dist_monitor` (supervisor
  child; master AND worker run it — dist is symmetric — and EACH
  node renders its OWN `janus_sched_dist_*` counters on its own
  /stats/sched (local read, no aggregation; dist storms are
  exactly when the worker side matters): NO new dist messages;
  the "no new wire" invariant governs gateway-role messages,
  local telemetry is per-node). system_monitor is
  node-global single-slot — VERIFY exclusivity at implementation
  (grep for other system_monitor callers; document in the module
  header).
  `erlang:system_monitor(self(), [busy_dist_port])`; on
  `{monitor, Pid, busy_dist_port, Port}` it counts transitions
  (`janus_sched_dist_busy_events_total`, label-free) and stamps
  `last_busy_at_mono`. VERIFY AT IMPLEMENTATION (OTP 27 docs)
  whether an unbusy transition message exists; if yes, also
  accumulate `janus_sched_dist_busy_ms_total`; if no, the events
  counter + last-busy age is the deliverable (state which in the
  module doc). Re-arm system_monitor after every message (it
  persists, but the call is idempotent-cheap and guards a
  cleared monitor). F3: no logging per event (rate-limited
  warning only: first event per hour).
- SURFACING PATH: workers serve the :8090 read-only admin
  listener (existing v1 behavior — only the :8080 agent API is
  master-only), so the per-node surface exists where the counters
  live. `sched_stats/0` is master-only (workers run no pool) —
  the /stats/sched handler merges
  `janus_dist_monitor:stats/0` DIRECTLY (a per-node local read
  that works on master AND worker), and C.1 renders the dist
  counters from that same local read (never through the pool).

### C.3 Build provenance (6-model round-1 consensus)

- The Docker build stamps the git SHA (`--build-arg JANUS_GIT_SHA`
  → image label `org.opencontainers.image.revision` AND a baked
  `ENV JANUS_GIT_SHA=${JANUS_GIT_SHA}` — image LABELS are
  invisible to the running container, the ENV is what feeds
  boot → persistent_term; a MISSING build-arg stamps the literal
  `unknown` — never empty). `/stats/sched` exposes it as the
  additive key `git_sha` (schema_version stays 1); a WORKER also
  reports its SHA in hello meta (additive key, ignored by old
  masters) surfacing per-worker in the A.3 array (mixed-image
  fleets visible). `deploy_prod.sh` REFUSES to build from a dirty
  tree via `git status --porcelain` (EMPTY output required — the
  incident tree passed `git diff --quiet` because the extra code
  was UNTRACKED) — uncommitted-code images become structurally
  impossible. EMERGENCY ESCAPE: `JANUS_DEPLOY_ALLOW_DIRTY=1`
  documents a deliberate override (logged loudly, never
  silent).
- eunit: the stamp surfaces end-to-end when injected.

### C.4 Knob-off blindness guard (evaluation finding #1)

- At the FIRST worker admission PER POOL LIFETIME (boot-scoped —
  reconnect storms must not inflate it) with geo/health/rtt ALL
  off, the pool logs ONE warning (`scheduler_knobs_all_off`) and
  bumps
  `janus_sched_knobs_off_total` — surfaced in /stats/sched (not
  only /metrics: prod scrapes nothing yet) AND /metrics. Gate
  step asserts the counter on the default-off stack.

---

## Part D — Network / VM tuning hooks

- docker-entrypoint renders optional vm.args lines from env,
  validated per F6: `JANUS_NET_TICKTIME` (seconds 10–120 →
  `-kernel net_ticktime N`), `JANUS_ZDBBL` (KB 128–65536 →
  `+zdbbl N`). Rendering is IDEMPOTENT: any pre-existing
  net_ticktime/+zdbbl lines are REPLACED (never appended — no
  duplicate flags across container restarts). Unset/invalid ⇒
  dropped + warning, OTP defaults (documented in the entrypoint
  header). No code reads these; they are boot-time only.
  CLUSTER SYMMETRY: net_ticktime changes land on ALL nodes in
  ONE deploy window — asymmetric ticktime flaps dist connections
  (runbook G.5).
- Recommended production values (Part G runbook): ticktime 30,
  zdbbl 8192. NOT hardcoded anywhere.

---

## Part E — Recovery policy: unary worker_lost local fallback

- Env `JANUS_SCHED_UNARY_FALLBACK` (default 0). When ON, in
  `janus_http_worker_client`: a NON-STREAM, CHAT-FAMILY job
  (chat_completions + responses ONLY — image/TTS/ASR/video are
  excluded: double-billing a generation is a different order of
  cost) that fails with the worker session's `{'DOWN'}` 
  (worker_lost — NOT a timeout class, NOT send-fail which already
  falls back locally) may execute the local `LocalFun` ONCE.
  "Pre-byte" is ONE predicate: no chunk forwarded AND no
  done/error emitted for the JobRef — implemented as the master
  session's process-dictionary flag `janus_worker_forwarded`
  (set on the first forwarded chunk OR done/error emit; read at
  fallback time; it dies with the session — no adopt concern).
  Bytes buffered at the WORKER but not yet forwarded are still
  "pre-byte" to the client — that window IS the documented
  double-billing risk (the upstream call may have produced
  them).
  Order: release the reservation FIRST (eunit asserts the release
  precedes LocalFun), then run LocalFun, count
  `dispatch_local{unary_fallback}` (a VALUE addition to the
  reason enum — not a schema change, consistent with
  schema_version 1), and never re-dispatch to a worker for that
  call; a local failure propagates. NEVER on `janus_error`
  completions (the upstream ANSWERED — the provider-failover
  layer owns those). CAPACITY BYPASS DOCUMENTED: release-then-
  local never re-reserves, so mass worker loss admits unbounded
  local execution — the knob's deliberate
  availability-over-discipline trade (local fallback is the
  terminal sink anyway).
- The double-billing risk is the operator's accepted trade
  (F5); the runbook states it in one sentence next to the knob.
- eunit: fallback fires exactly once, only pre-byte, only
  worker_lost, only when the knob is on; gate: kill-the-worker
  step (13.7) asserts the counter when the knob is on and the
  clean abort when off.

---

## Part F — Chaos gate steps (e2e_mw_local.sh)

- **13.4 amendment (rest-state invariant)**: after the existing
  dispatch/RTT assertions and a bounded drain wait, EVERY
  `reserve_inflight` entry must be 0 — the next residue incident
  is a FAIL, not a mystery (v2.1 evidence finding #3).
- **13.7 worker loss, TWO phases, TWO-worker topology pinned**
  (w1 victim, w2 survivor — pinned to w1 via the provider's
  `affinity_node`, the gate's existing mechanism; the master runs
  WITHOUT its local worker for this step group so survivors/drops
  are unambiguous; `JANUS_NET_TICKTIME=30` on every node — Part D
  exercised, the <30 s nodedown bound assumes RST-or-tick
  detection: the <30 s bound rides the docker-KILL RST (hard
  death — socket close reaches the monitor immediately); the
  tick floor at ticktime 30 is 30–45 s and covers only SILENT
  loss — silent-loss testing is OUT of gate scope):
  - STREAM phase: stream job through w1; while streaming,
    `docker kill` w1 → the client stream terminates with an
    error in < 30 s (curl exit non-zero or truncated SSE with a
    terminal error — the pinned client-visible contract for
    mid-stream worker loss); nodedown evicts w1 < 30 s and the
    NODEDOWN path clears its reserve/tracked rows (the evicted
    worker DISAPPEARS from the workers array — assert its
    ABSENCE and the workers_available drop, not a phantom row;
    the 10-min purge is last-resort, never the asserted path);
    the NEXT request dispatches to w2 (assert
    dispatch_worker{w2, _} delta ≥ 1). Unary-fallback is NOT
    asserted here (streams are F5-forbidden).
  - UNARY phase (knob ON, separate stack boot — env is
    boot-time): a SLOW-KEY unary chat job through w1 (a fast job
    would complete before the kill lands — 13.8's slow-key
    pattern); DISPATCH BARRIER: poll
    `dispatch_worker{w1, _}` delta ≥ 1 BEFORE the kill (a kill
    landing pre-dispatch sends the job to w2/local and the
    fallback assert flakes); kill w1 before first byte →
    `dispatch_local{unary_fallback}` ≥ 1 and the client got a
    200. Knob OFF variant: clean worker_lost error, counter 0.
  - RECOVERY: w1 restarts → re-hello ≤ 70 s (the existing
    pool-pid monitor → hello loop → net_kernel:connect_node/1
    retry — Task C machinery, named), workers_available back to
    2. All assertions on /stats/sched with explicit poll bounds;
    no log scraping.
- **13.8 master restart under load**: 2 workers up, slow-key
  unary job in flight through a worker, `docker restart` the
  master → the in-flight CLIENT request fails fast (< 20 s:
  docker restart sends SIGTERM (10 s default grace, then SIGKILL)
  — the dying beam closes every socket either way, and a hanging
  shutdown is cut by the SIGKILL; NOT "no cowboy hang": the 300 s
  idle_timeout is deliberate and untouched),
  then master
  recovery: workers re-hello ≤ 70 s (keepalive + monitor), the
  adopt path resets counters, a follow-up job dispatches to a
  worker (dispatch_worker_total ABSOLUTE ≥ 1 post-restart — the
  counters reset at restart, deltas across it are meaningless).
  Assert on /stats/sched + /healthz.
- Both steps are OPT-IN via `--steps 13.7,13.8` (chaos is slow;
  the default gate set stays fast). TEST-FLOWS.md entries follow
  the existing format; the harness `--teardown` must reclaim
  killed containers.

---

## Part G — Ops runbook (skills/fleet-node-ops/SKILL.md)

- "Enabling scheduler v2 in production" section, in order:
  1. masters first: `JANUS_SCHED_HEALTH=1`, `JANUS_SCHED_RTT=1`
     (no mmdb needed); restart; watch /stats/sched
     (`health_ewma_ms` populating, `would_demote` flipping) for
     ~30 min.
  2. workers: `JANUS_WORKER_CAPACITY=32` (starting value);
     watch `capacity_exhausted`/`dispatch_local{capacity}`.
     NOTE: with v2.1 the RTT sort key is EWMA-smoothed — enabling
     RTT after this ship changes ordering vs v2 (deliberate).
  3. Optional geo: place mmdb at `JANUS_MMDB_PATH` on masters,
     then `JANUS_SCHED_GEO=1` (explicit-1 without the file
     REFUSES boot — the v2 rule).
  4. Optional probes: `JANUS_SCHED_PROBE=1` with
     `JANUS_SCHED_PROBE_MAX_HOURLY` headroom.
  5. VM knobs from Part D (ticktime 30, zdbbl 8192): BOTH take
     effect on the NEXT restart, and net_ticktime must land on
     ALL nodes in the SAME deploy window (asymmetric ticktime
     flaps dist connections).
  6. The unary-fallback knob (Part E) documented with its
     double-billing trade.
  7. SOFTNESS DIRECTION NOTE: v2's residue class was stranded
     capacity (over-count); v2.1's take-vs-reconcile race is
     transient over-admission (under-count) until the job
     completes — a different failure SHAPE, not just size.
- Also: prod image reconciliation note — after this spec ships,
  deploy-from-main REPLACES the unreleased workers view with the
  A.3 view (field-compatible).

## Part H — Explicitly deferred

Per-provider health split (v2.2 candidate — the evaluation's
biggest algorithmic lever once single-worker EWMA is trusted);
Master HA (advisory-lock election); multi-region entry / regional
masters; network-partition chaos (beyond container kill);
SILENT dist loss (no RST — the 30–45 s ticktime floor; 13.7
asserts the kill/RST path only, by decision); prometheus
dashboards; auto-sizing of capacity from EWMA.

## Part I — Self-review checklist

- [ ] Every failure mode (F1–F7) has a named guard
- [ ] select_v2 input contract unchanged; builder fixtures
      updated; knobs-off ordering equivalence still asserted
- [ ] Bookkeeping moves keep the two-tick/purge healing story
- [ ] All new observability is additive (JSON schema_version
      STAYS 1; /metrics additive; the unary_fallback reason is a
      value addition, not a schema change)
- [ ] Chaos steps fail fast and reclaim containers
- [ ] No new upstream calls; probes untouched
- [ ] Tests enumerated: eunit per item + gate 13.7/13.8 opt-in
- [x] pi-audit GO — rounds 1-9 archived under
      docs/audit/archive/2026-10-11-v21-r{1..9}; round 8 = 4 GO
      + 2 GWF("none blocking"); round 9 = every verdict
      "ratify"/"shippable"/"nothing blocks" with only label-drift
      and definitional items remaining (folded); the final
      implementation-visible pins (sched_rtt public read, 13.7
      dispatch barrier, nodedown delete window named,
      reconcile max(0), insert-throws interleaving eunit) folded
      post-round-9; deepseek recorded 5 consecutive
      context-limit infra-fails (documented per precedent)
