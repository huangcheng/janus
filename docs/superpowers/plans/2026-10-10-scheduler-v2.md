# Scheduler v2 — geo-aware, health-aware worker selection — SPEC (rev 10 — FINAL)

> **For implementers:** single source of truth once ratified. All
> comments, commits, docs in English. Status: RATIFIED — round-9
> confirmation returned 5/5 GO WITH FIXES + 1 GO WITH MINOR
> RESIDUALS (deepseek: 3rd consecutive context-limit infra-fail,
> documented) with ZERO architecture/math/testability objections
> across all rounds; the remaining one-sentence residuals are
> folded below and grep-verified. Part G is ticked.
>
> **Rev 9 folds round 8** (6/6 GO WITH FIXES + 1 infra-fail
> [deepseek, empty again]; zero architecture/math/testability
> objections — glm: "implementation-ready... the pi-audit GO box
> can be ticked once these folds are applied"):
> - **Landed the drifted folds** (grep-verified this time):
>   corrected `> infinity` rationale in the BODY (total order —
>   `false`, never badarg; the skip is explicit intent), missing
>   `sched_workers` row => drained (refuse), exhaustion-reason
>   rule (first non-ok outcome in iteration order), BOTH flush
>   paths advance `snapshot_gen`, `probe_skip` five reasons in
>   metric AND JSON, `dispatch_worker_total` JSON keys
>   `"<node>/<provider>"`.
> - **Probe/internal recognition mechanism CLOSED** (the one real
>   gap): `dispatch_probe/2` registers probes in the tracked set
>   via the SAME `{track, ...}` cast with `Internal => true` and
>   NO counter increment — the track cast is decoupled from the
>   counter. Done handler recognizes internal completions by the
>   tracked entry's `Internal` flag (seams 1+2 work); release,
>   purge, AND the reconcile's excess math SKIP the decrement for
>   `Internal` entries (counter-neutrality preserved); the
>   in-flight map clears by JobRef. Tracked-map shape is the
>   4-tuple `JobRef => {Node, ReservedAtMono, ProviderId,
>   Internal}` EVERYWHERE. Non-probe internal jobs (none in v1)
>   would ride the normal pick path — the flag is real now, not
>   forward-looking.
> - **`SampledAtMono` compare dropped as vacuous** (master ingest
>   stamps make compare-before-overwrite a no-op — the handler
>   being processed is always newest): true semantics pinned =
>   LAST-ARRIVAL-WINS bounded by the 10-min TTL; the probe
>   cold-start existence gate and handler serialization are the
>   real protections; no cross-node comparison exists (all stamps
>   master-side; the Part 0.9 vestige is deleted).
> - **Register-cast wording**: on the WINNING candidate only
>   (after the capacity check — overflow candidates roll back
>   without registering).
> - **Demotion gate rendered structurally**: the snapshot builder
>   sets `observed_ewma_ms := unknown` below 3 samples (the
>   is_number guard then excludes naturally); the
>   `/stats/sched` `health_ewma_ms` gauge shows the DISPLAY value
>   from sample 1 (selection ignores it until >= 3).
> - **Heir adopt race**: the boot-path adopt request RETRIES with
>   backoff (the heir may not yet have processed the old owner's
>   `{'ETS-TRANSFER'}`); tables resolve by the stable `TableTag`.
> - **`sched_v => 2` added to the 0.10 hello enumeration**; the
>   stale "upgraded master probing a still-old worker" sentence
>   deleted (impossible under the marker gate); mixed-version
>   orphan window documented (v2 master + OLD workers +
>   pool-owner-only crash => old workers have no keepalive =>
>   fleet dark until worker restart — narrow, accepted; deploys
>   restart the whole node); `FORCE` never bypasses the
>   `sched_v` filter.
> - **Small pins**: `rtt_dropped_total` JSON expands to
>   `{"negative": int, "non_finite": int}`; `JobRef` = a
>   master-created unique reference (created per dispatch, stable
>   across the wire); probes use the entitlement-probe catalog
>   key pick under the separate additive budget; the 60 s
>   keepalive is a plain hello (NO load payload — the load cast
>   keeps its suppression rule and its documented starvation
>   limitation); 13.4b gains a bounded <= 35 s poll; the gate
>   intro states "the harness restarts stacks between steps —
>   counters start at 0"; the drain-at-build vs drain-at-recheck
>   asymmetry acknowledged (bounded by <= 250 ms staleness);
>   `geo_disabled_total` Part C carries the explicit-only
>   condition; 0.1's corrupt-file path and A.1's async load are
>   conditioned on explicit request; the async locus load result
>   is named the ONE sanctioned runtime writer of `geo_enabled`
>   PT; immediate post-adopt reconcile deletes ALL `sched_rtt`
>   rows (no pool records yet — a cold reset in the accepted
>   class, stated); "consumed by the pool's `handle_cast`
>   clause" wording; G3 "capacity weights" -> "capacity limits";
>   13.6's all-workers-slow variant pinned as a GATE assertion
>   (`health_demote_total` delta = 0 while jobs still dispatch).
> - **Eunit additions landed in Part E** (grep-verified): adopt ->
>   keepalive re-hello -> snapshot rebuilt -> pick dispatches
>   again; five probe-skip reasons each incremented; pinned-path
>   completion updates `observed_ewma_ms`; `internal` job-map-key
>   tolerance on old job-decode clauses; probe done-with-`rtt_ms`
>   skipped via the tracked `Internal` flag (the REACHABLE path).
>
> **Rev 8 folds round 7** (6/6 GO WITH FIXES + 1 infra-fail
> [deepseek: empty output at this target size, model alive on a
> short prompt — context-limit artifact, not a content objection];
> ALL findings one-sentence pins — "none touch architecture or
> math", "implementation-ready"):
> - **Part 0.2 target rule re-flowed to ONE statement** (5/6
>   flagged the surviving "PASSIVE" lead-in): "least-recently-
>   probed (worker, provider) among dispatchable workers ×
>   catalog-known-AND-ENABLED providers whose freshness predicate
>   is 'no unexpired `sched_rtt` row' (BOTH passive AND probe rows
>   count; the 10-min TTL is the bound)". In-flight workers are
>   excluded from targets (counted under `cadence`).
> - **Probe machinery pinned end-to-end**: issuance = the pool's
>   30 s tick self-casts `{sched, 2, {probe, JobSpec}}` (consumed
>   by `dispatch_probe/2`'s handle clause; old-pool catch-all
>   drops+counts — same `{sched, 2, _}` tolerance); eligibility =
>   pick's primitives minus the counter (live `sched_workers`
>   re-check + catalog enabled-flag); send-fail/ack-miss ⇒ ABORT +
>   clear in-flight + `probe_skip{send_fail}` + **NO local
>   fallback for internal jobs, ever**; workers whose hello lacks
>   the additive `sched_v => 2` marker are NOT probe targets
>   (kills the masters-first cap-drain window); the in-flight map
>   is named in the Part 0.5 clear-list.
> - **`sched_probe_skip_total{reason}` enum finalized**:
>   `cap|cadence|fresh|drained|send_fail`; the JSON key carries
>   ALL five.
> - **Tracked-set register seam named** (the one beyond-rename
>   item): pick's reserve loop, after a successful counter
>   increment, casts `{sched, 2, {track, JobRef, Node,
>   ProviderId, ReservedAtMono, Internal}}` to the pool BEFORE the
>   upstream send (done causally follows dispatch ⇒
>   register-before-done; lost registers backstopped by the
>   purge); release hooks cast `{sched, 2, {release, JobRef}}`;
>   the done handler ingests `rtt_ms` THEN releases (post-purge
>   done drops the sample). Master-side internal recognition =
>   the tracked entry's `Internal` flag (no wire change).
> - **Post-adopt re-hello trigger named**: workers run a periodic
>   keepalive hello (60 s, idempotent admit, piggybacks the load
>   cast) AND monitor the pool pid — owner death ⇒ immediate
>   re-hello. Eunit 4 extended: adopt → re-hello → snapshot
>   rebuilt → pick dispatches again.
> - **`SampledAtMono` = MASTER ingest stamp** (arrival order; no
>   cross-node clocks — Part 0.9 amended: durations + master
>   ingest stamps; cross-node stamp comparison only orders the
>   display cap, best-effort). The latest-wins claim is softened
>   to what the mechanism delivers: **best-effort latest-wins
>   under serialized pool handlers** (out-of-order-delivery
>   protection, not cross-writer atomicity).
> - **`Result > infinity` rationale corrected** (3 models caught
>   the false badarg claim): Erlang `>` is total-ordered —
>   `number > infinity` is simply `false`, never an error; the
>   skip exists so intent is explicit (a silently-always-false
>   comparison would mean "infinity never trips" for the wrong
>   reason). Rollback decrement form pinned:
>   `ets:update_counter(sched_reserve, Node, {2, -1}, {Node, 0})`.
> - **"Measured" predicate pinned**: a candidate is *measured*
>   iff ≥ 3 samples (the admission threshold); the exclude-self
>   median uses only measured candidates.
> - **`sched_geo_disabled_total` fires only when geo was
>   EXPLICITLY requested (knob=1 or TEST_HOSTS) and then
>   disabled** — silent when never enabled (no default-boot
>   noise).
> - **Gate step pins**: 13.6 verification pick uses a THIRD mock
>   provider WITHOUT `affinity_node`; other traffic quiesced
>   during the window; exactly 3 slow + 3 fast jobs; delta
>   assertions (Δfast=1, Δvictim=0 on the unpinned job); the
>   driver is the same MSYS-safe Python driver as 13.5;
>   `sched_dispatch_worker_total` gains a `{provider}` label
>   (cardinality still bounded — node × provider), making
>   per-provider assertions expressible; per-step fresh-stack
>   baselines stated (the harness restarts stacks between steps);
>   13.4b sets `JANUS_SCHED_PROBE_MAX_HOURLY=100` headroom; BOTH
>   flush paths (dirty-flush and tick) advance `snapshot_gen`.
> - **Small seams**: missing `sched_workers` row ⇒ treated as
>   drained (refuse — safe direction); the 30 s reconcile deletes
>   `sched_reserve` AND `sched_rtt` rows for nodes absent from
>   pool records (TTL still bounds); TEST_HOSTS override is
>   consulted BEFORE DNS/mmdb (named seam in A.1); the gauge cap
>   REMOVES evicted label sets from the registry (not just stops
>   writing); Part D lists the TEST-FLOWS.md update;
>   `geo_match_total{none}` documented as a pick partition
>   (pinned / no-comparator / no-match); the `rtt_ms` piggyback is
>   worker-side and UNGATED by `JANUS_SCHED_RTT` (master-side
>   knob); error completions DO write passive `rtt_ms` rows (raw
>   per-job upstream duration — the EWMA feeds still exclude
>   errors); exhaustion-reason rule pinned (first non-ok outcome
>   in iteration order; drained-pinned ⇒ `drained_pin`); rollback
>   wording rests on knob-off inertness (heir-persisted tables may
>   hold stale rows; knob-off makes them unread); "normal pinned
>   job" reworded to "a normal job dispatched directly to that
>   worker"; the async locus load result is the ONE sanctioned
>   runtime writer of the `geo_enabled` PT key; `geo_cache`
>   negatives carry `last_attempt_mono` distinct from
>   `resolved_at` (the ≤1/15-min guard field); probe-skip eunit
>   enumerates all five reasons; pinned-path completions DO feed
>   the health EWMA (eunit case); internal jobs bypass Slice-Q
>   spend accounting at the same named filter; `internal`-key
>   tolerance on old job-decode clauses eunit'd (0.10 sentence
>   added).
>
> **Rev 7 folds round 6** (7/7 GO WITH FIXES; residuals fully at
> naming/pin level — no architecture or math defects):
> - **Probe envelope DIRECTION reconciled**: `{sched, 2, {probe,
>   JobSpec}}` is POOL-INTERNAL (the master-side trigger consumed
>   by `dispatch_probe/2`'s own logic); what crosses to the worker
>   is a NORMAL pinned job carrying `internal => true` — the
>   worker sees NO new message type (old-worker safety holds).
> - **Probe freshness counts PROBE rows too**: predicate = "no
>   unexpired row (passive OR probe)" — a never-passively-sampled
>   pair no longer re-probes until the cap is spent. `FORCE`
>   bypasses cadence AND the fresh/unexpired-row skip — never the
>   hourly cap or dispatchable×enabled eligibility (pinned).
> - **`Result > infinity` guard**: the reserve loop SKIPS the
>   capacity comparison entirely when `capacity =:= infinity`
>   (an atom-vs-number guard comparison would badarg).
> - **Adopt = cold re-hello**: at init the new owner has NO pool
>   records, so the prune removes ALL `sched_workers` rows —
>   every worker must RE-HELLO post-adopt (dist connections
>   survive; sticky sessions re-hello). The post-adopt
>   over-admission window is relabeled "windowed until in-flight
>   drain" (new picks see counter 0 while old streams run).
> - **Tracked map extended**: `JobRef => {Node, ReservedAtMono,
>   ProviderId}` — makes the piggyback's `{{Node, ProviderId},
>   ...}` row key executable (where ProviderId comes from).
> - **Naming rule restored**: `sched_health_ewma_ms` and
>   `sched_reserve_inflight` gauges added to the metrics list
>   (JSON keys `health_ewma_ms`/`reserve_inflight` now have
>   sources); `sched_rtt_ms` gauge capped to the SAME 64-entry
>   SampledAtMono budget as the JSON (no unbounded registry).
> - **Pinned-path Decisions**: the affinity-pin path emits
>   `geo_source := none` (no undefined emit).
> - **`sched_rtt` write guard**: write-time latest-wins (compare
>   `SampledAtMono` before overwrite — closes the concurrent
>   piggyback-vs-cold-start race); clamp locus pinned at MASTER
>   ingest.
> - **13.6 relational assertion**: `victim_ewma > max(5000,
>   3×fast_ewma)` via the two `/stats/sched` gauges (host-speed
>   robust; the absolute < 2600 bound dropped); poisoning jobs run
>   CONCURRENTLY, budget widened to ≥ 45 s; the slow key's
>   before-first-byte delay is pinned as the mock's CONTRACT
>   (actual harness behavior, not prose).
> - **13.2 deterministic snapshot_gen**: drive one dispatch then
>   poll with a bounded ≤ 35 s wait (dirty-flush ≤ 250 ms or the
>   30 s tick — both qualify).
> - **13.4 asserts rtt_ms presence with the RTT knob OFF**
>   (rows are written regardless — stronger than asserting under
>   the knob); 13.4b says "catalog-known AND ENABLED".
> - **Stale lines fixed**: Part C tracked-set shape, Part C
>   `sched_geo_disabled_total` "once per disable event (boot or
>   async load failure)", the "mid-run re-pinning" example
>   (13.6 pins ONCE at poisoning start via catalog hot-reload).
> - **Eunit additions**: internal done-with-`rtt_ms` skipped at
>   master ingest (seam 1, explicit); clamp-down > 600000 case;
>   geo_disabled per-event increment; probe_skip{drained} reason
>   added; load-cast suppression vs the 2-min divergence window
>   starvation DOCUMENTED (accepted v1 limitation); probe
>   in-flight map dies with pool state (owner restart note);
>   pinned-path completions DO feed the health EWMA (real jobs);
>   non-streaming specialist bias operator note (2 sentences);
>   geo_cache re-resolve enforced by a per-host monotonic
>   timestamp guard; cost floor tied to sched_rtt being ETS-only.
>
> **Rev 6 folds round 5** (7/7 GO WITH FIXES; all residuals
> mechanical — the top item was one stale A.3 sentence):
> - **A.3 stale seam fixed** (5/7 flagged): probes dispatch via
>   `dispatch_probe/2` — the leftover "affinity-pin path" wording
>   is deleted everywhere.
> - **Probe completion contamination closed at THREE seams**:
>   internal (probe) job completions are excluded from (1) the
>   master's canonical `rtt_ms` passive ingest, (2) the master
>   TTFB health feed, and (3) the worker's own passive EWMA. The
>   `internal` flag rides the job map to the worker. Eunit covers
>   all three with production-shaped maps.
> - **EWMA SEED pinned — seeds at the FIRST sample** (`E1 = x1`;
>   seeded-at-0, three 8000 ms samples with α = 0.25 yield
>   4625 ms < the 5000 floor ⇒ 13.6 would fail deterministically).
>   Eunit: three identical 8000 ms samples ⇒ EWMA = 8000.
> - **Purge vs late-done idempotency**: release decrements IFF the
>   job is still in the tracked set — a post-purge `done` is a
>   NO-OP (no double decrement, no negative). Tracked entries
>   carry `ReservedAtMono` (map `JobRef => {Node, ReservedAtMono}`)
>   making the 10-min purge age executable. Long-lived active
>   streams purged at 10 min free their slot early — inherent to
>   age-based purge of unverifiable jobs, bounded over-admission
>   (same accepted class as ack-miss), documented.
> - **Probe-target rule finalized**: catalog-known AND ENABLED
>   providers; never-probed (worker, provider) pairs sort as
>   OLDEST; single freshness predicate = "no unexpired passive
>   row" (the 5-min figure is deleted — the 10-min row TTL is the
>   freshness bound; `sched_probe_skip_total{fresh}` covers
>   unexpired rows). `dispatch_probe/2` performs its OWN
>   draining/dispatchable eligibility check (it bypasses the
>   reserve loop's live re-check) and tracks in-flight probes in
>   pool state (`{Node => JobRef}`, cleared on probe done/error/
>   nodedown). Probe envelope pinned: `{sched, 2, {probe,
>   JobSpec}}` via cast.
> - **`sched_rtt` rows write regardless of `JANUS_SCHED_RTT`**
>   (the knob gates the SORT KEY only — otherwise 13.4b's target
>   rule starves after the first probe). Row shape keyed
>   `{{Node, ProviderId}, RttMs, Source, SampledAtMono,
>   ExpiresAtMono}` (composite key; single row, latest
>   SampledAtMono wins). `/stats/sched` `rtt_ms` and the gauge
>   drop expired rows at READ time (not only the 30 s tick).
> - **13.6 assertion surface added**: `/stats/sched` gains
>   `health_ewma_ms` (per-node map) — the step asserts
>   victim_ewma > 5000 (the floor binds) AND fast_ewma < 2600
>   (3×2600 = 7800 < 8000; the earlier "< 2.67 s" bound produced
>   8.01 s > 8 s — decorative and wrong; the 5000 floor is the
>   binding constraint, stated as such).
> - **Clamp overflow disposition**: `x > 600000` is CLAMPED DOWN
>   to 600000 (not dropped — only negative/non-finite drop).
> - **Opts sentence split**: KNOB FLAGS are boot-time
>   persistent_term; `affinity_node`/`provider_id`/`region_tag`
>   are PER-REQUEST from the catalog (13.6's mid-run re-pinning
>   works via catalog hot-reload).
> - **JSON/metric naming rule pinned**: JSON keys = metric names
>   minus the `sched_` prefix (`fleet_worker_report_mismatch_
>   total` keeps its full name). `sched_geo_disabled_total`
>   increments ONCE PER DISABLE EVENT (boot-time or async locus
>   load failure); selection ≡ v1 until the locus load succeeds.
> - **Adopt-reset mechanism pinned**: `ets:delete_all_objects`
>   on `sched_reserve` (single choice). Owner-restart also
>   clears health-EWMA state, divergence windows, and probe
>   cadence (pool state; accepted cold reset — the new-worker
>   never-demoted rule makes it safe).
> - **`other` is ALWAYS in the vocabulary** (auto-appended after a
>   `JANUS_SCHED_REGIONS` override — it is the fallback for
>   resolved-outside-vocab countries). `reserve_inflight`:
>   absent node = 0. `rtt_ms_other` is ALWAYS present in the JSON
>   (`{"count":0,"max_ms":0.0}` when no overflow). Worker passive
>   RTT EWMA also feeds on successful completions only (symmetric
>   with health). Part D step 4 reworded: declaring a region
>   NARROWS matching traffic to that worker — declare all workers
>   in a region (or keep capacity tight) before enabling. 13.6
>   harness step gets an explicit ≥ 30 s wall-clock budget with a
>   fail-loud timeout.
>
> **Rev 5 folds round 4** (7/7 GO WITH FIXES; residuals were
> mechanical/seam-naming — five real contradictions closed):
> - **Probe dispatch seam named**: probes go through a DEDICATED
>   `janus_worker_pool:dispatch_probe/2` (direct pinned send) that
>   BYPASSES pick's reserve loop entirely — no increment, no
>   decrement, no ambiguity with "pinned picks increment". The
>   "probes ride the affinity-pin path / normal dispatch" wording
>   is deleted. `JANUS_SCHED_PROBE_FORCE` bypasses cadence/
>   staleness ONLY, never target eligibility.
> - **Probe target rule de-geo'd** (4/7 flagged: "geo-known
>   providers" made 13.4b unrunnable with geo off — RTT has no
>   geo dependency): targets = dispatchable workers ×
>   CATALOG-KNOWN providers with absent/expired RTT.
> - **`sched_rtt` row gains `Source` + `SampledAtMono`**:
>   `{Node, ProviderId, RttMs, Source :: passive|probe,
>   SampledAtMono, ExpiresAtMono}`. Single-writer pin: the
>   done/error `rtt_ms` piggyback is the canonical PASSIVE writer;
>   load-cast probe results write PROBE-source rows ONLY as
>   cold-start fill when no unexpired passive row exists. The
>   64-entry `/stats/sched` cap and the `sched_rtt_ms` gauge key
>   off `SampledAtMono`.
> - **Ack-miss fully specified**: ack-miss ⇒ master executes
>   locally (v1 behavior, `dispatch_local_total{ack_miss}`) AND
>   the reservation stays PENDING (worker may still execute —
>   duplicate execution is inherited v1 ack-miss behavior, out of
>   scope). Pending entries have a PURGE AGE (10 min, aligned with
>   the RTT TTL): older ⇒ removed + decremented once +
>   `sched_reserve_purged_total` — a silently-lost job can no
>   longer pin a capacity slot until nodedown.
> - **Owner-restart adoption policy**: the tracked-job map is pool
>   state and dies with the owner while heir'd counters survive —
>   on adopt the pool RESETS `sched_reserve` to zero, prunes
>   `sched_workers`/`sched_reserve` rows for nodes absent from
>   pool records, and reconciles immediately. Bounded transient
>   over-admission after an owner restart (running jobs uncounted
>   until they finish) is accepted and documented.
> - **Clamp mechanism pinned**: `ets:update_counter` cannot clamp
>   — negative guards are corrective writes (decrement → read →
>   fix if < 0; non-atomic, healed by the 30 s tick). A racing
>   rollback can re-insert a nodedown-deleted row via the Default
>   tuple; the corrective write also zeroes such orphans. Probe
>   skip visibility: `sched_probe_skip_total{reason=cap|cadence|
>   fresh}` (issued-only stays `sched_probe_total`).
> - **13.6 made deterministic**: BOTH providers pinned during
>   poisoning (slow → victim, fast → healthy worker) — sample
>   accumulation is routing-deterministic; the slow key delays
>   BEFORE FIRST BYTE (TTFB is the health signal — a
>   delay-after-first-byte mock would never trip it); fast-key
>   TTFB < 2.67 s asserted (so 3×fast < 8000 < victim EWMA). The
>   all-slow variant is reworded to its true meaning: NO demotion
>   fires (min-EWMA survivor invariant — the minimum-EWMA
>   candidate can provably never exceed 3× the others' median);
>   never-shed-all remains a defensive guard eunit-tested
>   synthetically, not via the gate.
> - **Error completions excluded from the health EWMA** (demotion
>   is latency sickness; error sickness belongs to the LB/failover
>   layer): TTFB EWMA feeds on SUCCESSFUL completions only; master
>   TTFB α = 0.25 (was unpinned); majority-slow blind spot
>   documented (N=3 with two slow workers: each slow worker's
>   exclude-self median includes the other slow ⇒ nobody demoted —
>   the min-EWMA survivor invariant, a safety property).
> - **`{sched, 2, _}` delivery class pinned**: sent via
>   `gen_server:cast` ⇒ old-master tolerance is the pool's
>   `handle_cast` catch-all (VERIFIED at implementation + eunit
>   the exact delivery path, not just the shape).
> - **Pinned + live-drained outcome labeled**: pinned candidate
>   drained at reserve time ⇒ skip ⇒ list exhausted ⇒ local
>   fallback with the NEW reason label `drained_pin`.
> - **`/stats/sched` surface hardened**: `"schema_version": 1`
>   added; JSON key unified to `fleet_worker_report_mismatch_
>   total`; `rtt_ms` overflow aggregate pinned as
>   `rtt_ms_other = {"count": int, "max_ms": float}`.
> - **Metric semantics per-pick**: `sched_geo_match_total`
>   increments ONCE per pick with that pick's source;
>   `sched_health_demote_total` increments once per node ACTUALLY
>   EXCLUDED (`Decisions.demoted` lists only real exclusions —
>   never-shed-all suppression emits nothing).
> - **`sched_geo_disabled_total` increments ONCE at boot** (not
>   per-request). `JANUS_SCHED_REGIONS` REPLACES the default
>   vocabulary wholesale (the `cn` example is legal); worker
>   regions validate against rule targets ∪ region_tag values.
>   The PT provider-geo map is REBUILT from catalog build output
>   (never merged) — provider removals are automatic.
> - **Misc**: the forbidden counter form renamed correctly (the
>   4-tuple UpdateOp `{Pos, Incr, Threshold, SetValue}` — SetValue
>   wrap trap); the tuple-fallback hedge reworded as a test-order
>   statement (verify BEFORE writing the piggyback; switch to the
>   new-cast fallback if tuples are found — never merge shape
>   changes blind); clamp accepts numeric 0 ≤ x ≤ 600000 (integer
>   or float, stored as float — an integer 0 lands); NOTICE/
>   attribution added to the rollout checklist; the usage-filter
>   seam is pinned to the map-shaped job at the usage-record
>   build (record contingency: pattern-match a default field —
>   verified at implementation, eunit production shapes); 13.3a's
>   `none` case gets a known comparator that matches nothing
>   (provider `region_tag=eu`, workers cn-east/us).
>
> **Rev 4 folds round 3** (7/7 GO WITH FIXES; three real defects
> closed — demotion math, counter API, purity):
> - **Demotion threshold is EXCLUDE-SELF and per-candidate**
>   (the self-inclusive median was mathematically inert at N=2 —
>   flagged by 3/7): `demote_ms_i = max(5000, 3 × median(observed
>   EWMAs of the OTHER measured candidates))`, requiring ≥ 1 other
>   measured candidate (else infinity). Works for any fleet ≥ 2;
>   single-worker fleets are health-inert by design. Precomputed
>   per candidate into the snapshot. Gate 13.6 runs on the EXISTING
>   2-node harness: slow key pinned to 8 s (> 5000 floor), victim
>   poisoned via `affinity_node` (3 jobs ⇒ 3 TTFB samples),
>   unpinned picks then assert the fast worker wins.
> - **`ets:update_counter` form fixed everywhere** — both rev-3
>   examples were invalid, and the 5-tuple Threshold/SetValue form
>   WRAPS (silently pins the counter) instead of refusing. The ONE
>   pinned form: `ets:update_counter(sched_reserve, Node, {2, 1},
>   {Node, 0})` (4-arity, Default tuple `{Node, 0}`, position 2
>   the counter). Stale examples deleted.
> - **Purity restored**: `select_v2` returns `{Order, Decisions}`
>   (Decisions carries geo source + demoted list); `pick` emits
>   `sched_geo_match_total` / `sched_health_demote_total`. No
>   counter writes inside the pure function.
> - **Live drain re-check reads a NAMED table**: new pool-owned
>   `sched_workers` ETS (public, heir'd) with rows
>   `{Node, Draining}` maintained on hello/drain/undrain/nodedown.
>   The check-then-reserve TOCTOU is bounded and cooperative —
>   DOCUMENTED as bounded, not claimed closed.
> - **Ack-miss no longer releases the reservation** (send-fail
>   only): an ack miss means late, not absent — releasing while
>   the worker executes over-admits and later `done` decrements
>   into negatives. Ack-miss reservations stay PENDING until
>   done/error or the 30 s reconcile; decrements are idempotent
>   and clamped ≥ 0; transient over-admission is bounded and
>   documented.
> - **Probe jobs never touch the reserve counter at all** (no
>   increment, no decrement — consistent exemption); probes ride
>   the affinity-pin path to the target worker; probe-target rule
>   pinned (least-recently-probed (worker, provider) among
>   dispatchable × geo-known providers with absent/expired RTT;
>   hourly cap checked first).
> - **Heir mechanics made real**: a tiny `janus_ets_heir`
>   gen_server (janus_core supervisor child) receives
>   `{'ETS-TRANSFER'}` (supervisors silently drop info messages —
>   a supervisor heir would LOSE the tables) and gives them back
>   on the pool's boot-path adopt request. Pool init: table alive
>   ⇒ adopt via heir; else create with heir. Tables `public`.
>   Heir list now covers ALL five: `sched_snapshot`,
>   `sched_reserve`, `sched_workers`, `geo_cache`, `sched_rtt`.
> - **RTT clamp aligned with the gate**: `0 =< x ≤ 600000`
>   (drops negative/non-finite only — exactly-0.0 samples LAND);
>   13.4 asserts presence with value ≥ 0.0; new
>   `sched_rtt_dropped_total` counter for clamp drops.
> - **`capacity` added to snapshot Meta** (the reserve loop reads
>   it there).
> - **`/stats/sched` grows `reserve_inflight` (per-node map)** —
>   the drain-to-zero assertions in 13.4/13.5 now have a surface;
>   `rtt_ms` map CAPPED at 64 most-recent entries (`_other`
>   aggregate for overflow) to bound the pinned surface; gauge
>   source pinned = latest `sched_rtt` sample per (node, provider)
>   (fed by the rtt_ms piggyback + probes; the load-cast EWMA is
>   advisory display only).
> - **`geo_cache` negative entries get bounded re-resolve** (≤ 1
>   per host per 15 min, async — no 30-day stale-unknown window).
> - **EWMA eunits split** (worker-RTT α=0.25 vs master-TTFB feed,
>   single-chunk fallback); `{sched, 2, {load, _}}` cast-shape
>   eunit added; ETS-TRANSFER adopt-cycle eunit added.
> - **Vocab-warning source pinned**: region_tag values from the
>   PT provider map (`janus_catalog`); 13.3a's second worker uses
>   region `us` (in-vocab — clean gate logs).
> - **Reconcile owner named**: pool gen_server state
>   (`JobRef => Node` map) is the tracked-job set; the 250 ms
>   dirty-flush timer is pool-owned. Internal-flag seam named:
>   job field `internal` (default false) + `janus_usage` insert
>   filter `not maps:get(internal, Job, false)`.
> - **Deploy notes**: mmdb refresh rotation (refresh failure ⇒
>   old DB keeps serving; alert only on load failure); upgraded
>   master probing still-old workers executes fine (probe jobs
>   are normal job shapes; reports just lack `rtt_ms` until the
>   worker upgrades). Harness env wiring enumerated in Part E.
> - Sort-tier numbering unified (the "tier-6" wording in fold
>   headers corrected to "sort tier").
>
> **Rev 3 folds round 2**: capacity single-owner in pick's reserve
> loop; pinned picks never capacity-refused; live drain re-check;
> legacy region_tag ungated; load-vs-RTT wording split; done/error
> are maps (additive keys, tuple-fallback named); is_number demotion
> guard; GEO_TEST_HOSTS satisfies explicit-1 boot check; TTFB-EWMA
> health (per-worker global); probe samples never enter passive EWMA;
> separate additive probe budget; deploy order masters → workers +
> mmdb-before-env; locus async load + rebar.lock volume rule;
> other-vs-unknown; v1-equivalence scoped to the pure function; env
> boot-time only.
>
> **Rev 2 folds round 1** (6 GO WITH FIXES, 1 NO-GO): locus dep
> unconditional; capacity default `infinity`; health-before-geo;
> snapshot carries per-candidate `rtt_map`; 30 s republish tick;
> default-off forces `rtt_key := infinity`; unknown-vs-unknown
> no-match; probes master-issued with cluster cap + internal flag;
> worker geo = `JANUS_WORKER_REGION` env only; DNS async;
> `/stats/sched` pinned surface; reservation = inflight source of
> truth.

**Base.** The shipped master/worker architecture on main
(`janus_worker_pool:select/2` — affinity pin → region tag →
least-inflight + name tiebreak; `janus_http_worker_client` dispatch
seam; `e2e_mw_local.sh` dual-node harness TF-13).

**Goal.** Upgrade worker selection from "operator-pinned region tags +
blind least-inflight" to a CDN-like, health-aware scheduler:

- **G1 geo**: provider geography resolved automatically (GeoIP, no
  manual region_tag); workers declare geography; selection prefers
  same-geo workers, then lowest measured RTT.
- **G2 health**: slow workers get demoted from master-observed
  outcomes, no operator action; a dead/sick worker never stays
  preferred.
- **G3 scale-safety**: selection read-path moves off the gen_server
  (ETS snapshot + lock-free reservation); per-worker capacity
  limits arrive with hello.

**Non-goals.** No auto-affinity learning. No fairness quotas per
agent key / provider (future work — explicit operator request
required). No consistent-hashing ring in v1. No changes to the LB
(provider/key choice), the dist bring-up, or video master-locality.
Existing wire shapes change ONLY by additive optional map keys on
done/error (maps in the shipped protocol — verified, eunit both
shapes) plus NEW `{sched, 2, _}` inner-tagged casts (dropped+counted
by old masters). No new knobs on the dashboard settings page in v1.

---

## Part 0 — Failure modes first (project rule)

1. **GeoIP DB missing / corrupt / resolution fails** —
   `JANUS_MMDB_PATH` unset or file absent with `JANUS_SCHED_GEO`
   unset ⇒ geo simply never enabled — SILENT (no log spam, no
   counter: the default boot must be no-behavior-change). The
   counter and loud log fire ONLY when geo was EXPLICITLY
   requested (`JANUS_SCHED_GEO=1` or TEST_HOSTS set) and then
   disabled. `JANUS_SCHED_GEO=1` explicit with
   file ABSENT ⇒ boot REFUSES (existence check is cheap; operator
   asked for geo). File present but corrupt (and geo explicitly
   requested) ⇒ locus loads ASYNC and
   fails ⇒ auto-off + counter + CRITICAL log (no synchronous
   60 MB parse in the boot path; a stale-but-loadable DB keeps
   serving — refresh failure is not an outage; alert only on load
   failure). A NON-EMPTY `JANUS_SCHED_GEO_TEST_HOSTS` satisfies the
   explicit-1 check AND exempts the boot-refusal existence
   check (test seam counts as geo data; loud log) — gate 13.3b
   boots without an mmdb. Per-host DNS failure / private IP / parse
   failure ⇒ `geo_region = unknown`; unknown matches NOTHING;
   selection degrades to v1. Geo never blocks dispatch.
2. **RTT probe storms** — active probes are NEVER per-request, and
   are issued ONLY by the master (workers cannot self-initiate).
   Cluster-wide cap `JANUS_SCHED_PROBE_MAX_HOURLY` (default 10)
   across ALL workers × providers, checked by the issuer BEFORE
   picking a target; cadence per (worker × provider) ≥ 60 s with
   ±20 % jitter; ≤ 1 probe in flight per worker — in-flight
   workers are EXCLUDED from targets (counted under `cadence`;
   in-flight tracked in pool state `{Node => JobRef}`, cleared on
   probe done/error/nodedown and on send-fail/ack-miss abort).
   TARGET RULE (one statement): the least-recently-probed
   (worker, provider) pair among dispatchable workers ×
   catalog-known AND ENABLED providers whose freshness predicate
   is "no unexpired `sched_rtt` row" — BOTH passive AND probe
   rows count (the 10-min TTL is the bound); never-probed pairs
   sort as OLDEST; geo is NOT a precondition. Workers whose hello
   lacks the additive `sched_v => 2` marker are NOT probe targets
   (kills the masters-first cap-drain window — an unupgraded
   worker returns no data, so it would re-probe to
   cap-exhaustion). Cadence state (last-probe timestamps) and
   the in-flight probe map live in the pool gen_server, cleared
   on nodedown (and on owner restart — pool state; the in-flight
   map is named in the Part 0.5 clear-list). Issuance: the
   pool's 30 s tick evaluates eligibility and self-casts
   `{sched, 2, {probe, JobSpec}}` — a POOL-INTERNAL trigger
   consumed by the pool's `handle_cast` clause behind
   `dispatch_probe/2` (a self-cast never crosses versions —
   the `{sched, 2, _}` catch-all tolerance is what handles
   worker→master load casts from newer workers on an old
   master); what crosses to the worker
   is a normal job dispatched directly to that worker carrying
   `internal => true` — the worker sees NO new message type.
   Probes BYPASS pick's reserve loop entirely (no increment, no
   decrement) and `dispatch_probe/2` performs its OWN
   eligibility check with pick's primitives minus the counter
   (live `sched_workers` draining re-check + catalog
   enabled-flag). Probe send-fail OR ack-miss ⇒ ABORT + clear
   the in-flight entry (the tracked entry is released WITHOUT
   decrement — the Internal skip) + `probe_skip{send_fail}` —
   NO local
   fallback for internal jobs, ever (a master-side probe
   execution measures nothing). Probe KEY selection: the
   entitlement-probe catalog key pick (same source as the
   minimal job shape), spending under the SEPARATE additive
   budget. Passive samples come free from
   real jobs. Test-only `JANUS_SCHED_PROBE_FORCE=1` bypasses
   cadence AND the fresh/unexpired-row skip — never the hourly
   cap or the dispatchable × enabled eligibility (loud log;
   never in prod). Skips are visible:
   `sched_probe_skip_total{reason=cap|cadence|fresh|drained|send_fail}`.
3. **Lying/misreporting workers** — self-reported LOAD
   (`inflight_self`, `ewma_upstream_ms`) is ADVISORY ONLY and
   never a selection input (worker reports upstream-only; master
   observes TTFB — incomparable, so the comparison is a signal,
   never a selector). Divergence > 3× for > 2 min with both sides
   ≥ 100 ms ⇒ `fleet_worker_report_mismatch_total`. Window state
   in the pool gen_server, cleared on nodedown. DOCUMENTED
   LIMITATION: the load cast is suppressed unless probes ran or
   the EWMA moved > 20 % — a steady-state lying worker may never
   send, starving the mismatch counter (accepted v1; the counter
   is a signal, not a safety mechanism). Worker-measured
   RTT IS the sort-tier input by design (worker owns the network
   path; like-for-like worker-to-worker); a lying worker's
   influence is bounded by the `rtt_ms` clamp (numeric
   0 ≤ x ≤ 600000, integer or float, stored as float — an
   integer 0 lands; x > 600000 CLAMPED DOWN to 600000;
   negative/non-finite dropped +
   `sched_rtt_dropped_total{reason=negative|non_finite}`) and
   by RTT being preference-only.
4. **Stale RTT / geo state after partition** — every RTT sample has
   a TTL (10 min), enforced by the snapshot builder (expired ⇒
   absent from `rtt_map`) plus the 30 s periodic republish tick.
   Worker geo is pinned at hello; nodedown clears ALL its state
   (pool records + `sched_workers` row + reserve row + rtt rows +
   divergence window + probe-cadence state).
5. **ETS ownership & restart window** — `sched_snapshot`,
   `sched_reserve`, `sched_workers`, `geo_cache`, `sched_rtt` are
   pool-owned, `public`, with heir = `janus_ets_heir` (a tiny
   janus_core supervisor child gen_server; supervisors silently
   drop `{'ETS-TRANSFER'}` so a supervisor heir would LOSE the
   tables; the heir carries stable GiftData
   `{TableTag :: atom(), Owner :: pid()}` so adoption is
   identifier-stable across recreates). Pool init: table alive
   (heir holds it) ⇒ boot-path adopt request to the heir
   (`ets:give_away` back; the request RETRIES with backoff —
   the heir may not yet have processed the old owner's
   `{'ETS-TRANSFER'}`; tables resolve by the stable `TableTag`);
   else `ets:new` with heir set. ON ADOPT
   the pool RESETS `sched_reserve` via
   `ets:delete_all_objects` (single pinned mechanism), prunes
   `sched_workers` rows for nodes absent from pool records — at
   init the new owner has NO records, so ALL rows are pruned and
   every worker must RE-HELLO post-adopt (a COLD RESET; the
   TRIGGERS: every worker runs a periodic keepalive hello —
   60 s, idempotent admit, a PLAIN hello with NO load payload
   (the load cast keeps its own suppression rule) — AND
   monitors the pool pid, so owner death ⇒ immediate
   re-hello; dist connections survive) — and reconciles
   immediately. The tracked-job map died with the old
   owner, so surviving counters are orphans; the over-admission
   window is "windowed until in-flight drain" (new picks see
   counter 0 while old streams run out) and is accepted. The
   30 s reconcile also deletes `sched_reserve` AND `sched_rtt`
   rows for nodes absent from pool records — immediately
   post-adopt that is ALL `sched_rtt` rows (no pool records
   yet): a cold RTT reset in the accepted class, stated plainly
   (post-re-hello rows refill; the TTL bounds any window). Health-EWMA state,
   divergence windows, probe-cadence state, AND the probe
   in-flight map are pool state (not heir'd) and are cleared on
   owner restart — an accepted cold reset (the
   never-demote-without-samples rule makes it safe). The snapshot
   itself is a single row (`{candidates, BuiltList}`) inserted
   atomically; readers do one `ets:lookup` and iterate a plain
   list. Missing table ⇒ `badarg` ⇒ no candidates; missing row ⇒
   `[]` — both land in the existing local-fallback path.
6. **Lock-free pick race (two picks, one capacity-1 worker)** —
   capacity is enforced ONLY in pick's reserve loop. The ONE
   pinned counter form: `ets:update_counter(sched_reserve, Node,
   {2, 1}, {Node, 0})` (4-arity; Default tuple `{Node, 0}`;
   position 2 the counter; insert-default ⇒ no badarg on first
   pick after hello; the 4-tuple UpdateOp
   `{Pos, Incr, Threshold, SetValue}` form is FORBIDDEN — its
   SetValue semantics wrap and silently pin the counter). When
   `capacity = := infinity` the capacity comparison is SKIPPED
   entirely: Erlang `>` is total-ordered, so
   `number > infinity` would silently be `false` — meaningless,
   never an error; the skip makes intent explicit. Result
   > capacity ⇒ rollback (decrement) and try the next candidate IN
   SORTED ORDER; list exhausted ⇒ LOCAL FALLBACK
   (`reason=capacity`) — a pick never fails the request; worst
   case the master executes locally (the ultimate never-shed-all).
   Affinity-pinned picks increment but are NEVER rolled back (soft
   cap on the pinned node); a pinned candidate found DRAINED at
   the live re-check ⇒ skip ⇒ exhaustion ⇒ local fallback with
   the distinct reason `drained_pin`. Before reserving, the loop
   re-checks the node's LIVE draining flag from `sched_workers`
   (`{Node, Draining}` rows, maintained on hello/drain/undrain/
   nodedown) — check-then-reserve TOCTOU is bounded and
   cooperative (a drain racing a pick admits at most one job,
   which the existing drain semantics already tolerate);
   documented as BOUNDED, not closed. Asymmetry acknowledged:
   a node draining at SNAPSHOT build falls through the tiers
   (replaced by others), while a node draining at the LIVE
   re-check yields `drained_pin`/skip — the divergence is
   bounded by the ≤ 250 ms flush staleness.
   `ets:update_counter` cannot
   clamp: a rollback racing a nodedown delete can re-insert the
   row via the Default tuple and drive it negative — negative
   guards are CORRECTIVE WRITES (decrement → read → fix if < 0;
   non-atomic, healed by the 30 s tick).
7. **Capacity misconfiguration** — explicit capacity clamped ≥ 1 at
   hello-admission (non-integer garbage ⇒ clamped to 1 + warning
   log); unset ⇒ `infinity` (v1 semantics). Running jobs are never
   killed. Probe jobs never touch the reserve counter (dispatched
   via `dispatch_probe/2`, outside the reserve loop — the
   exemption is structural, not a flag inside pick).
8. **Probe spending real provider money** — probes use the minimal
   entitlement-probe job shape (1 token), are master-issued, OFF by
   default (`JANUS_SCHED_PROBE=1`), capped cluster-wide hourly
   (Part 0.2) as a SEPARATE additive sub-budget that never starves
   the existing entitlement-probe budget. Probe jobs carry
   `internal => true` on the job record (field `internal`, default
   false); the `janus_usage` insert filter skips internal-flagged
   jobs at the map-shaped job → usage-record build
   (`not maps:get(internal, Job, false)`; if the seam is
   record-shaped, pattern-match a defaulted field instead —
   verified at implementation, eunit with production shapes);
   gate 13.4b asserts the usage row-count delta is zero for the
   probe window; only `sched_probe_total` counts them.
9. **Clock skew** — RTT values are durations measured by the
   worker locally (monotonic); the master stores them as-is.
   `SampledAtMono` is a MASTER ingest stamp (arrival order — no
   cross-node clocks, and ALL stamps are master-side, so no
   cross-node comparison exists anywhere).
10. **Mixed versions during rolling deploy** — new hello fields
    (`capacity`, `geo_region`, `sched_v`) are OPTIONAL map keys;
    old workers hello without them ⇒ capacity=infinity,
    geo=unknown, sched_v=1 (not probe targets, Part 0.2). Old master
    ignores extra keys — VERIFIED against the shipped hello
    decoder (`janus_worker_pool` admit path builds its record from
    known keys only) + eunit with old/new hello shapes. done/error
    are MAPS in the shipped protocol — `rtt_ms` is one more
    OPTIONAL key; old-master clauses match maps on existing keys,
    so both old and new messages match. TEST ORDER: verify the
    shipped clauses match maps BEFORE writing the piggyback; if
    (unexpectedly) tuples are found, switch to the NEW
    `{sched, 2, {rtt, _}}` cast fallback BEFORE merging — never a
    shape change of an existing message. `{sched, 2, _}` messages
    are sent via `gen_server:cast` ⇒ old-master tolerance is the
    pool's `handle_cast` catch-all (VERIFIED at implementation +
    eunit the exact DELIVERY path, not just the shape; the
    `{load, _}` form covered explicitly). Region binaries compared
    as binaries (no atom creation). DEPLOY ORDER: masters first,
    then workers. DOCUMENTED ORPHAN WINDOW: a v2 master +
    still-OLD workers + pool-owner-only crash ⇒ adopt prunes
    all `sched_workers` rows and old workers (no keepalive)
    never re-hello ⇒ the fleet stays local-fallback until a
    worker restart — narrow (deploys restart the whole node),
    accepted. An upgraded
    worker reporting to a still-old master is dropped+counted
    (window emptied by the ordering). Old WORKERS tolerate the
    additive `internal` job-map key (job decode builds from
    known keys — same verification + eunit as the hello keys).
11. **Reservation lifecycle & leak** — a winning reserve (ONLY
    the winning candidate — overflow candidates roll back
    without registering) registers the job: pick's reserve loop
    casts
    `{sched, 2, {track, JobRef, Node, ProviderId, ReservedAtMono,
    Internal}}` to the pool AFTER the capacity check and BEFORE
    the upstream send (done causally follows dispatch ⇒
    register-before-done holds; a lost register is backstopped
    by the purge — the reconcile treats counter-excess older
    than one flush interval as drift). INVARIANT:
    `Internal ⇒ never incremented` — any future internal job
    MUST dispatch via a counter-exempt path (the decrement-skip
    is keyed on Internal; a pick-path internal job would leak a
    slot healed only by nodedown). PROBES register the SAME
    way: `dispatch_probe/2` casts the identical track tuple with
    `Internal => true` and NO counter increment (the track cast
    is decoupled from the counter) — so the done handler
    recognizes internal completions by the tracked entry's
    `Internal` flag, and RELEASE, PURGE, AND the reconcile's
    excess math SKIP the decrement for `Internal` entries
    (counter-neutrality preserved end-to-end; the in-flight map
    clears by JobRef). JobRef = a master-created unique
    reference (one per dispatch, stable across the wire).
    Reservation is released on
    done/error/`worker_lost` AND ON SEND-FAIL ONLY (release
    hooks cast `{sched, 2, {release, JobRef}}`; rollback
    decrement form pinned as
    `ets:update_counter(sched_reserve, Node, {2, -1},
    {Node, 0})`), and the release decrements IFF the job is
    still in the tracked set
    (`JobRef => {Node, ReservedAtMono, ProviderId, Internal}` —
    the ProviderId makes the piggyback's `{{Node, ProviderId},
    ...}` row key executable) — a post-purge `done`
    is a NO-OP (idempotent; no double decrement, no negative).
    The done handler INGESTS `rtt_ms` FIRST, then releases (a
    post-purge done has no tracked entry ⇒ drops the sample AND
    the release is a no-op). Ack-miss ⇒ the master executes
    locally (v1 behavior;
    `dispatch_local_total{ack_miss}` counts the local execution)
    AND the reservation stays PENDING — an ack miss means late,
    not absent: the worker may still execute, duplicate execution
    is the inherited v1 ack-miss behavior (out of scope here), and
    releasing while the worker executes would over-admit and drive
    the counter negative when `done` lands. Pending entries have a
    PURGE AGE (10 min, aligned with the RTT TTL, measured from
    `ReservedAtMono`): older ⇒ removed from the tracked set +
    decremented once + `sched_reserve_purged_total` — a
    silently-lost job can no longer pin a capacity slot until
    nodedown. A long-lived ACTIVE stream purged at 10 min frees
    its slot early (bounded transient over-admission, same
    accepted class as ack-miss — age-based purge cannot
    distinguish lost from long-running; the window closes when
    the job ends). The reconcile (30 s tick) compares the counter
    against the tracked-job set: decrement the EXCESS only;
    decrements are idempotent; negatives are fixed by corrective
    writes (Part 0.6 — never negative for long). Nodedown deletes
    the row outright.
12. **Drain vs reservation** — drain blocks NEW reservations (live
    re-check in the reserve loop, Part 0.6); running jobs drain
    undisturbed.

## Part 0.1 — Invariants

- **Selection is pure**: given `(snapshot, opts)`,
  `select_v2/2` returns `{Order, Decisions}` deterministically —
  no network, no DB, no ETS writes, no counters (pick emits the
  metrics from Decisions). The gen_server owns timers, monitors,
  reservation reconciliation, and snapshot publication. No
  `os:time()` inside `select_v2` — TTL filtering is done by the
  builder (expired ⇒ absent). The reservation LOOP lives in
  `pick/1` (impure by design, tiny, eunit-tested live).
- **Default config is v1 for the pure function**: all knobs off ⇒
  tiers inert (legacy region_tag stays ACTIVE — it is v1 behavior)
  ⇒ sort `(inflight, name)` ⇒ `select_v2(default_opts, S)` is
  IDENTICAL to v1 `select/2` on the same fixtures (eunit-asserted
  ordered-list equality, region-tagged fixtures included). The
  read path SAMPLES state (≤ 250 ms dirty-flush / 30 s tick
  staleness) instead of serializing — under concurrent dispatch
  ordering may transiently differ, bounded by the flush interval;
  the rollout/rollback claims rest on pure-function equivalence +
  knob-off.
- **Every level degrades to today's behavior**: no geo data ⇒ tier
  inert; no RTT ⇒ key = infinity; no observed samples ⇒ no
  demotion (single-worker fleets health-inert by design); capacity
  unset ⇒ unlimited; capacity exhausted ⇒ local execution (the
  request never fails). The final tiebreak remains
  `(inflight, name)`.
- **Local fallback unchanged**: empty pool / send failure / ack
  miss / capacity exhausted ⇒ master executes locally (existing
  seam). Reservation made for a send-failed dispatch attempt is
  released before falling back.
- **No DB writes from the data plane**: geo/RTT/load state lives in
  ETS only, TTL-bounded. The mmdb file is accessed read-only by
  `locus` (random-access, its own cache) — nothing copied into
  ETS wholesale. No Postgres migrations in this spec.
- **Cost floor**: with default config (passive-only, probes off,
  geo off), scheduler v2 performs ZERO additional upstream calls
  vs v1.
- **Orthogonality**: capacity bounds concurrent jobs; the per-job
  credit window bounds stream backpressure; Slice-Q per-node
  quotas bound per-node spend — all three coexist, none subsumes
  another.

---

## Part A — Data model & sources

### A.1 Provider geography (G1)

- `janus_geo`: new janus_core module wrapping the **`locus` hex
  dependency** (pure-Erlang mmdb reader; no NIF; Alpine/OTP-27
  compatible — validated at implementation start; a rebar.lock
  change requires image rebuild + `janus-ebin-otp27` volume
  recreation per AGENTS build rules).
  `resolve_host(HostBin) -> {ok, RegionBin} | unknown` = DNS
  resolve (timeout 3 s) → mmdb lookup → region-tag mapping. **No
  hand-rolled mmdb parser** — parsing correctness is locus's
  contract. Our eunit covers the wrapper (mapping, cache, TTL,
  failure modes) with injected lookups PLUS one RECORDED
  locus-return fixture (real GeoLite2-City subdivision map shapes
  captured once by a `tools/` script, committed under
  `apps/janus_core/test/fixtures/`) so field-shape drift at the
  locus→janus_geo boundary is caught.
- **DB logistics (licensing/CI/image)**: GeoLite2-City is CC BY
  4.0 — attribution required (repo `NOTICE` file). The mmdb is NOT
  in git and NOT in the image (60 MB; CI stays offline). It is a
  master-only RUNTIME file at `JANUS_MMDB_PATH`, placed/refreshed
  by the deploy script from the MaxMind account (license key never
  committed) BEFORE `JANUS_SCHED_GEO=1` is flipped; refresh
  rotation: a failed refresh leaves the old DB serving (stale geo
  is acceptable; only load failure alerts). Workers need NO mmdb.
  CI/eunit never touch a real DB. locus loads ASYNC at boot —
  only when geo was explicitly requested.
- **Mapping**: mmdb country ISO code + subdivision name → region
  tag. Fixed default vocabulary:
  `cn-east, cn-north, cn-south, cn-southwest, apac, us, eu, other`.
  `JANUS_SCHED_REGIONS` REPLACES the default vocabulary WHOLESALE
  (operator full control — a `cn` rule is legal) with ORDERED
  rules `CC[:SUBDIVISION]=tag` (first match wins; bare `CC`
  fallback; e.g. `CN:Shanghai=cn-east;CN:Beijing=cn-north;CN=cn`).
  Parse errors ⇒ rule skipped + warning (never crash); no rules
  parsed ⇒ default set. `other` is ALWAYS in the vocabulary
  (auto-appended after an override — it is the fallback for
  resolved-outside-vocab countries). A resolved country outside
  the vocab ⇒ `other`
  (a KNOWN tag — it CAN match a worker declaring
  `other`); lookup failure stays `unknown` (never matches).
  Worker-region validation compares against rule targets ∪
  region_tag values (Part A.2 typo aid).
- **Test seam**: `JANUS_SCHED_GEO_TEST_HOSTS` entries are
  consulted BEFORE DNS/mmdb (exact-host match ⇒ the injected
  region; the async fill never overrides an injected entry).
- **Population — ASYNC, never blocking catalog build**:
  `janus_catalog:build` publishes providers with
  `geo_region = unknown` immediately and kicks
  `janus_geo:resolve_async` per DISTINCT base_url host (capped
  concurrency; DNS timeout 3 s). Results fill `geo_cache`
  (persistent ETS with heir, host → {region, resolved_at_mono,
  last_attempt_mono} — the negative re-resolve guard field,
  distinct from `resolved_at`, enforces ≤ 1 per host per 15 min;
  TTL 30 d positive / 1 h negative on the same async path: no
  30-day stale-unknown window) and update the
  persistent_term provider-geo map (`provider_id → geo`, read
  lock-free by pick). A generation bump mid-fill re-checks
  generation before writing. The PT provider-geo map is REBUILT
  from catalog build output on every generation (never merged) —
  provider removals are automatic. First fill is
  eventually-consistent; selection starts v1-equivalent and
  tightens as geo lands. Manual flush reuses the
  `janus_catalog:flush` path + clears `geo_cache` + re-resolves.

### A.2 Worker geography (G1)

- Worker geo comes ONLY from `JANUS_WORKER_REGION` env
  (operator-declared, e.g. `cn-east`), carried in hello as the
  `geo_region` binary. **Auto egress-IP discovery is DROPPED from
  v1** (dead in docker/NAT; needs mmdb on workers + an external
  echo call — new failure mode, no docker-testable benefit;
  recorded in Part F). Unset ⇒ `geo_region = unknown` ⇒ the worker
  participates in everything except geo preference.
- Hello meta merge is defensive: unknown fields dropped on old
  masters (verified Part 0.10), missing on new ⇒ defaults
  (capacity=infinity, geo=unknown). Region binaries compared as
  binaries. Typo aid: a hello whose `geo_region` is non-empty and
  ∉ current vocab AND ∉ any configured `region_tag` (source of
  truth: region_tag values in the PT provider map,
  `janus_catalog`) logs a master warning (matching stays
  exact-binary — never fuzzy).

### A.3 RTT (G1)

- Per (worker, provider) on the WORKER: passive EWMA from REAL job
  upstream latencies (α = 0.25; seeds at the FIRST sample —
  `E1 = x1`; the worker session already measures per-job upstream
  duration; successful completions only, symmetric with health).
  **Probe samples NEVER enter the passive EWMA** (1-token shape ≠
  real jobs): internal completions are skipped at the worker.
- Active probes (`JANUS_SCHED_PROBE=1`): MASTER decides and issues
  (Part 0.2/0.8) — dispatched to the target worker via
  `janus_worker_pool:dispatch_probe/2` (direct pinned send;
  reserve-counter exemption is STRUCTURAL, Part 0.2); the worker
  executes and reports like any job — EXCEPT that internal
  completions are excluded at all three data seams: no `rtt_ms`
  piggyback ingest, no master TTFB health feed, no worker passive
  EWMA (the `internal` flag rides the job map to the worker;
  probe results return via the load cast).
- **Report channel — additive map keys only**: `done`/`error`
  maps gain an OPTIONAL `rtt_ms` float key per completion (the
  RAW per-job upstream duration — error completions DO write
  passive rows; the EWMA feeds still exclude errors; the
  piggyback is worker-side and UNGATED by `JANUS_SCHED_RTT`,
  which is a master-side sort knob; clamped per Part 0.3;
  old-master tolerance verified per Part 0.10). A 30 s
  coalesced `{sched, 2, {load, Info}}` cast carries
  `{inflight_self, ewma_upstream_ms}` and probe results, sent ONLY
  when active probes ran or the passive EWMA moved > 20 % since
  the last report (storm-bounded).
- Master stores into `sched_rtt` ETS (heir'd; rows written
  REGARDLESS of `JANUS_SCHED_RTT` — the knob gates the sort key
  only): rows keyed `{{Node, ProviderId}, RttMs, Source ::
  passive|probe, SampledAtMono, ExpiresAtMono}` TTL 10 min
  (composite key; single row, latest SampledAtMono wins);
  nodedown deletes the node's rows. SINGLE-WRITER PIN: the
  done/error `rtt_ms` piggyback is the canonical PASSIVE writer;
  load-cast probe results write PROBE-source rows ONLY as
  cold-start fill when no unexpired row exists (freshness
  predicate per Part 0.2). HONEST semantics: with
  `SampledAtMono` a MASTER ingest stamp and all writes
  serialized in the pool's handlers, a compare-before-overwrite
  would be a no-op (the message being handled is always
  newest) — the true rule is LAST-ARRIVAL-WINS bounded by the
  10-min TTL; the probe cold-start existence gate and handler
  serialization are the real protections (a probe result
  arriving after a passive row landed is discarded by the
  existence gate, wasting a paid probe, documented). The clamp
  applies at MASTER ingest. The
  `/stats/sched` `rtt_ms` gauge reads the LATEST sample per
  (node, provider) — recency keyed by `SampledAtMono`, which also
  orders the 64-entry cap; expired rows are dropped at READ time
  (not only the 30 s tick); the load-cast EWMA is advisory display
  only.

### A.4 Worker health (G2)

- **Selection uses ONLY master-observed data**: per-worker EWMA
  (α = 0.25, SEEDS AT THE FIRST SAMPLE — `E1 = x1`; seeded-at-0
  would make three 8000 ms samples read 4625 ms < the 5000 floor)
  over **time-to-first-chunk** (master-measured: dispatch-ack →
  first forwarded chunk; single-chunk/non-streaming jobs fall back
  to full duration — the mixed-mode bias is accepted and
  documented: streaming workers report per-chunk TTFB while
  non-streaming specialists report full duration, so a
  non-streaming specialist can be demoted unfairly at equal
  real health — per-modality health is deferred to Part F; if
  you run non-streaming specialists, keep health OFF or expect
  the bias). Pin-path completions DO feed the EWMA (pinned
  picks are real jobs). ERROR completions AND INTERNAL (probe)
  completions are EXCLUDED from the health EWMA (demotion is
  latency sickness on real jobs; error sickness belongs to the
  existing LB cool/failover layer) — the feed is successful
  non-internal completions only. Workload-independent vs token
  count, like-for-like across workers. The EWMA VALUE is
  seeded at sample 1 (`E1 = x1`) but is ADMITTED to selection
  only at ≥ 3 samples — rendered STRUCTURALLY: the snapshot
  builder sets `observed_ewma_ms := unknown` below 3 samples
  (the is_number guard then excludes naturally; new workers are
  never demoted — no data, no verdict). The `/stats/sched`
  `health_ewma_ms` gauge shows the DISPLAY value from sample 1
  (selection ignores it until ≥ 3). Scope is per-worker GLOBAL (a worker slow on
  one provider is demoted for all; per-provider split deferred to
  Part F). Majority-slow blind spot DOCUMENTED: at N=3 with two
  slow workers, each slow worker's exclude-self median includes
  the other slow ⇒ nobody demotes — the min-EWMA survivor
  invariant (the minimum-EWMA candidate can provably never exceed
  3× the others' median), a safety property, not a defect.
  Owner-restart note: EWMA state is pool state (not heir'd) —
  accepted cold reset (the never-demote-without-samples rule
  makes it safe).
- **Self-reported load is advisory-only** (Part 0.3): ops metrics,
  capacity cross-check, mismatch counter. It NEVER enters
  selection.
- **Demotion threshold — EXCLUDE-SELF, per candidate,
  precomputed**: a candidate is MEASURED iff it has ≥ 3 samples
  (the admission threshold — the median side uses only measured
  candidates). For candidate i,
  `demote_ms_i = max(5000, 3 × median(observed EWMAs of the OTHER
  measured candidates))`, requiring ≥ 1 other measured candidate
  (else `infinity` — tier inert). Median = statistics-median
  semantics (even N averages the two middles — written out, no
  stdlib ambiguity). The rev-3 self-inclusive median was
  mathematically inert at N=2 (3×(a+b)/2 > max always) —
  exclude-self works for any fleet ≥ 2 and keeps the 2-node
  harness sufficient. Precomputed into each candidate's snapshot
  Meta ⇒ pick-time determinism. The demotion predicate is
  `is_number(E) andalso E > demote_ms_i` — the atom-vs-number
  ordering trap (`unknown > 5000` is TRUE in Erlang term order)
  is closed by the guard.

### A.5 Worker capacity (G3)

- Hello field `capacity` (unset ⇒ `infinity`; explicit clamped ≥ 1,
  non-integer garbage ⇒ 1 + warning). Env `JANUS_WORKER_CAPACITY`
  sets it. The snapshot Meta carries `capacity` for the reserve
  loop; enforcement is ONLY the live counter (Part 0.6).
- **Capacity bounds concurrent JOBS** (probe/internal jobs are
  exempt — structural, `dispatch_probe/2`); the credit window
  bounds backpressure; Slice-Q bounds spend (Part 0.1
  orthogonality).

---

## Part B — Selection v2 (`select_v2/2`, pure)

Input: candidate snapshot `[{Node, Meta}]` where Meta includes
`inflight (sort-hint sample), capacity, draining, geo_region,
rtt_map :: #{ProviderId => MsFloat}, observed_ewma_ms | unknown,
demote_ms (per-candidate, precomputed)`. Opts include
`provider_id, provider_geo, affinity_node, region_tag, geo_enabled,
rtt_enabled, health_enabled`. **No capacity tier and no live
counters in `select_v2`** — capacity is enforced solely by pick's
reserve loop (Part 0.6).

Output: `{Order, Decisions}` — `Order` the full ordered node list
(pick iterates it for reservation; no re-selection on rollback),
`Decisions` a plain map (`#{geo_source => region_tag|auto|none,
demoted => [Node, ...]}`) from which PICK emits the metrics. No
counter writes here.

Ordered filter/sort — **all tiers strictly narrow or re-rank, never
widen beyond today's fallback set**:

1. `dispatchable`: `draining =:= false` (snapshot view; the live
   re-check happens at reservation).
2. Affinity pin — ABSOLUTE (operator intent): pinned node present
   and dispatchable ⇒ that node ONLY, ignoring health/geo tiers
   (`Decisions.geo_source := none` on this path — no undefined
   emit; the reserve loop still increments its counter but never
   refuses it — soft cap, Part 0.6). Pinned node absent/draining ⇒
   continue down the tiers (v1 affinity-miss path).
3. Health demotion (BEFORE geo — pathology outranks preference;
   gated by `health_enabled`): exclude candidates with
   `is_number(observed_ewma_ms) andalso observed_ewma_ms >
   demote_ms` — unless that would empty the set (never-shed-all;
   mirroring degraded_filter). `Decisions.demoted` lists ONLY
   actually-excluded nodes (never-shed-all suppression emits
   nothing); pick emits `sched_health_demote_total` once per
   listed node per pick.
   NOTE: with health ON, demotion outranks legacy region_tag — a
   deliberate v2 difference from v1 (which ranked region_tag above
   load); default-off preserves v1 exactly.
4. Geo preference (narrowing, not exclusion; the legacy region_tag
   sub-tier is UNGATED v1 behavior, only the auto-geo comparator
   is gated by `geo_enabled`): if the provider's legacy
   `region_tag` is SET, it is the comparator (source=
   `region_tag`) — ALWAYS active, knob-independent. Else, with
   `geo_enabled`, the comparator is `provider_geo` from the
   persistent_term map (source=`auto`). The tier applies ONLY when
   the comparator is known AND the candidate's `geo_region` is
   known AND they are EQUAL (unknown-vs-unknown does NOT match —
   explicit guard). If ANY matching candidates exist, keep only
   them; else keep all (source=`none` in Decisions; pick emits
   `sched_geo_match_total` once per pick with that source).
5. Sort by `{rtt_key, inflight, name}`: `rtt_key` =
   `rtt_map[provider_id]` or `infinity` when absent (unknown sorts
   LAST — the `infinity` atom orders after all floats in Erlang
   term order; no tuple sentinel). **When `rtt_enabled = false`
   (default), `rtt_key := infinity` for ALL candidates** ⇒ sort is
   exactly v1's `(inflight, name)`.

Determinism: identical `(snapshot, opts)` ⇒ identical output. No
time in the pure function — TTL expiry happened in the builder;
`demote_ms` is precomputed; sort keys are values; metrics are
emitted by pick from Decisions.

## Part C — Read-path, snapshot & reservation (G3)

- `janus_worker_pool` gen_server remains the writer (hello/drain/
  undrain/nodedown + rtt/load ingest + reservation
  reconciliation). On every state mutation it sets a dirty flag; a
  pool-owned flush timer republishes at most every 250 ms. A
  **30 s periodic tick** republishes UNCONDITIONALLY (TTL expiry +
  reserve reconciliation are real on an idle fleet). BOTH flush
  paths — dirty-flush and tick — advance `sched_snapshot_gen`.
  Published row:
  `ets:insert(sched_snapshot, {candidates, BuiltList})` — one
  row, full list, atomic swap.
- Builder joins: pool worker records + `sched_rtt` rows per
  candidate (expired filtered) + observed-EWMA state; precomputes
  per-candidate `demote_ms`. Provider geo is NOT in the
  worker-keyed snapshot — it lives in the persistent_term map
  (`provider_id → geo`) maintained by the async fill (A.1), read
  lock-free by pick.
- Readers: `janus_worker_pool:pick/1` =
  1. one `ets:lookup(sched_snapshot, candidates)` (missing
     table/row ⇒ local fallback, `reason=empty_pool`),
  2. `select_v2(Snapshot, Opts)` — pure ordering + Decisions;
     pick emits `sched_geo_match_total` /
     `sched_health_demote_total` from Decisions,
  3. reserve loop: for each candidate in order — live draining
     re-check from `sched_workers` (a MISSING row is treated as
     drained — refuse, the safe direction), then
     `ets:update_counter(sched_reserve, Node, {2, 1}, {Node, 0})`;
     `> capacity` (explicit only — when `capacity =:= infinity`
     the comparison is SKIPPED entirely: Erlang `>` is
     total-ordered, so `number > infinity` would silently be
     `false` — meaningless, never an error; the skip makes
     intent explicit; pinned picks skip this refusal)
     ⇒ rollback + `sched_capacity_exhausted_total` + next
     candidate; the FIRST success registers the track cast
     (Part 0.11) and returns `{ok, Node}`; list exhausted
     ⇒ local fallback with `reason` = the FIRST non-ok outcome
     seen in iteration order (a drained PINNED candidate ⇒
     `drained_pin` regardless of later candidates; pure capacity
     refusals ⇒ `capacity`; drain-skips of unpinned candidates
     label the exhaustion too). Probes do NOT
     enter this loop (`dispatch_probe/2`, Part 0.2 — they
     register with `Internal => true` and no increment,
     Part 0.11).
  The gen_server call path REMAINS as `pick_sync/1` for tests.
- **Reservation IS the inflight source of truth**: live counter in
  `sched_reserve`; snapshot inflight is a sample copied at build
  time (sort hint only). Release on done/error/`worker_lost`/
  send-fail ONLY (ack-miss stays pending — Part 0.11); the 30 s
  tick reconciles against the tracked-job set (pool gen_server
  state, `JobRef => {Node, ReservedAtMono, ProviderId,
  Internal}`; `Internal` entries are SKIPPED by the excess
  math) — decrement the excess only,
  idempotent, clamped ≥ 0 (bounded transient over-admission);
  nodedown deletes the row. Release hooks live in
  `janus_http_worker_client` (send-fail path) and the pool's
  job-lifecycle handlers (done/error/worker_lost) — named seams.
- Opts are split: KNOB FLAGS (geo/rtt/health/probe enabled) come
  from persistent_term set at BOOT (env-only; restart to
  change — no hot-reload surface in v1, with ONE sanctioned
  runtime exception: the async locus load result writes
  `geo_enabled` when it succeeds or fails after an explicit
  request); `affinity_node`, `provider_id`,
  and `region_tag` are PER-REQUEST values from the catalog (13.6
  pins both providers ONCE at poisoning start via the catalog
  hot-reload seam — there is no mid-run re-pin in the gate);
  provider geo per A.1. Never a gen_server call on the pick
  path.
- Metrics (prometheus registry; label cardinality bounded by node
  and provider lists):
  `sched_geo_match_total{source=region_tag|auto|none}` (once per
  pick, that pick's source; a pick PARTITION — `{none}`
  conflates pinned / no-comparator / no-match by design),
  `sched_dispatch_worker_total{node, provider}`,
  `sched_dispatch_local_total{reason=empty_pool|capacity|drained|drained_pin|send_fail|ack_miss}`,
  `sched_capacity_exhausted_total`, `sched_health_demote_total`
  (once per actually-excluded node per pick),
  `sched_probe_total{provider}`, `sched_probe_skip_total{reason=
  cap|cadence|fresh|drained|send_fail}`, `sched_rtt_ms` GAUGE (labels
  `{node, provider}`; reads the latest unexpired `sched_rtt`
  sample by `SampledAtMono`, CAPPED to the same 64-entry budget
  as the JSON surface — evicted label sets are REMOVED from the
  registry, not merely unwritten — the registry never grows
  unbounded),
  `sched_rtt_dropped_total{reason=negative|non_finite}`,
  `sched_reserve_purged_total`, `sched_snapshot_gen`,
  `sched_health_ewma_ms` GAUGE (labels `{node}`),
  `sched_reserve_inflight` GAUGE (labels `{node}`),
  `sched_geo_disabled_total` (fires ONCE on the OBSERVABLE
  disable event — the async locus load failure auto-off; a
  refused boot never starts the node, so that path is
  CRITICAL-log-only; ONLY when geo was EXPLICITLY requested —
  silent on default boots),
  `fleet_worker_report_mismatch_total`. COST-FLOOR NOTE: the
  cost floor holds precisely because `sched_rtt`/EWMA state is
  ETS-only and fed by passive piggyback — no extra upstream
  calls.
- Read-only JSON on :8090 — **`/stats/sched`** is THE pinned
  assertion surface (no log scraping anywhere). NAMING RULE:
  JSON keys = prometheus metric names minus the `sched_` prefix
  (`fleet_worker_report_mismatch_total` keeps its full name).
  Exact keys:
  `{"schema_version": 1, "geo_enabled": bool, "rtt_enabled": bool,
  "health_enabled": bool, "probe_enabled": bool, "snapshot_gen":
  int, "geo_match_total": {"region_tag": int, "auto": int,
  "none": int}, "dispatch_worker_total":
  {"<node>/<provider>": int, ...},
  "dispatch_local_total": {"empty_pool": int, "capacity": int,
  "drained": int, "drained_pin": int, "send_fail": int,
  "ack_miss": int},
  "capacity_exhausted_total": int, "health_demote_total": int,
  "probe_total": {"<provider>": int, ...}, "probe_skip_total":
  {"cap": int, "cadence": int, "fresh": int, "drained": int,
  "send_fail": int}, "rtt_ms":
  {"<node>/<provider>": float, ...} CAPPED at the 64 entries most
  recent by SampledAtMono (expired dropped at read time) with the
  overflow aggregate ALWAYS PRESENT as
  `rtt_ms_other = {"count": int, "max_ms": float}`
  (`{"count":0,"max_ms":0.0}` when no overflow),
  "rtt_dropped_total": {"negative": int,
  "non_finite": int}, "reserve_purged_total": int,
  "reserve_inflight": {"<node>": int, ...} (absent node = 0),
  "health_ewma_ms": {"<node>": float, ...}, "geo_disabled_total":
  int (once per disable event — boot or async load failure),
  "fleet_worker_report_mismatch_total": int}`.

## Part D — Ops & rollout

- Env (all default-off / no-behavior-change; BOOT-time only):
  `JANUS_SCHED_GEO=0|1`, `JANUS_SCHED_RTT=0|1`,
  `JANUS_SCHED_HEALTH=0|1`, `JANUS_SCHED_PROBE=0|1`,
  `JANUS_SCHED_PROBE_MAX_HOURLY` (default 10, cluster-wide),
  `JANUS_SCHED_REGIONS` (mapping rules), `JANUS_MMDB_PATH`
  (master-only runtime file), `JANUS_WORKER_REGION`,
  `JANUS_WORKER_CAPACITY`.
  Test-only (loud log; gate scripts only):
  `JANUS_SCHED_GEO_TEST_HOSTS`, `JANUS_SCHED_PROBE_FORCE`.
  All documented in `skills/fleet-node-ops/SKILL.md`.
- Rollout (order matters): 1) masters first, then workers; 2)
  place the mmdb BEFORE flipping `JANUS_SCHED_GEO=1` (explicit-1 +
  missing file refuses boot) and verify the repo `NOTICE`
  (GeoLite2 CC BY 4.0 attribution) ships in the release; 3) ship
  with geo/rtt/health/probe OFF — selection ≡ v1 (eunit + gate
  13.2); 4) enable `JANUS_WORKER_REGION` carefully: a declared
  region NARROWS all matching providers' traffic to that worker —
  declare every worker in a region (or keep capacity tight)
  BEFORE enabling, or the first declared worker takes a load
  spike; 5) probes stay off until the operator opts in
  (money). Deploy smoke asserts geo state on `/stats/sched` when
  =1.
- Rollback — provable: rollback rests on KNOB-OFF INERTNESS
  (heir-persisted tables may carry stale rows; with the knobs
  off nothing reads them): env off + restart ⇒ v1 selection
  (pure-function eunit asserts the equivalence the rollback
  claims). Internal (probe) jobs bypass Slice-Q per-node spend
  accounting at the same named `internal` filter as usage.
  This spec's gate steps land in
  `../janus-dashboard/docs/TEST-FLOWS.md` (the gate grows with
  that file — AGENTS rule).
- Build: `locus` enters `rebar.lock` ⇒ rebuild the test image and
  RECREATE the `janus-ebin-otp27` volume (stale-beam rule).

## Part E — Testing

Eunit (FIRST, pure, production shapes — JSON-decoded binaries,
map messages, recorded floats; stateful pieces boot the REAL pool
gen_server — `janus_usage` precedent, no reinvented mocks):

1. `janus_geo` wrapper with injected lookups + the RECORDED
   locus-return fixture (real subdivision map shapes): host→region
   mapping, `JANUS_SCHED_REGIONS` parse errors (skip+warn),
   private-IP/not-found ⇒ unknown, `other` vs `unknown`
   semantics, TTL expiry (time-parameterized), negative-entry
   bounded re-resolve, async fill ordering, PT provider-geo map
   updates.
2. `select_v2` tier matrix: affinity > health > geo > sort;
   affinity absolute (bypasses demotion/narrowing); health before
   geo (sick same-geo worker shed, healthy cross-geo kept);
   never-shed-all at health; unknown-vs-unknown geo NO-match
   (explicit case); `other` CAN match `other`; new-worker (<3
   samples) never demoted; `unknown` atom never demoted
   (is_number guard); single-worker fleet ⇒ demote_ms infinity;
   2-worker exclude-self threshold fires (slow > max(5000,
   3×fast) demoted); unknown-rtt sorts last;
   `rtt_enabled=false` ⇒ `(inflight, name)`; region_tag set +
   knobs off ≡ v1 (legacy ungated); determinism (same snapshot
   twice); Decisions content (geo source, demoted list) without
   counter writes.
3. **v1-equivalence**: `select_v2(default_opts, S) ≡ select/2(S)`
   on identical fixtures INCLUDING region-tagged providers
   (ordered-list equality) — the rollout/rollback claim,
   executable.
4. Reserve loop (live pool): concurrent picks on capacity-1
   worker ⇒ exactly one reserve wins, loser rolls back to next/
   local; insert-default (fresh node no badarg); pinned pick
   never refused; `sched_workers` live drain re-check refuses
   post-snapshot drains (TOCTOU boundedness documented); drained
   pinned candidate ⇒ `drained_pin` local fallback; send-fail
   releases, ack-miss stays pending until done/purge; purge-age
   removal decrements once + `sched_reserve_purged_total` AND a
   post-purge `done` is a NO-OP (no double decrement); probe
   dispatch (`dispatch_probe/2`) never touches the counter
   (counter-neutrality asserted — probes register with
   `Internal => true` and NO increment; release/purge/reconcile
   skip the decrement) and ALL FIVE skip reasons are each
   incremented (cap/cadence/fresh/drained/send_fail — send-fail
   aborts, clears in-flight, NEVER falls back locally); a
   probe's done-with-`rtt_ms` is SKIPPED at ingest via the
   tracked `Internal` flag (the REACHABLE path);
   post-adopt recovery: adopt → keepalive re-hello → snapshot
   rebuilt → pick dispatches again; unpinned live-drain skip
   labels exhaustion `drained` (eunit case); reconcile corrects
   injected
   drift (corrective write fixes negatives, bounded softness);
   `sched_snapshot_gen` advances on republish; ETS-TRANSFER
   adopt cycle (kill owner ⇒ heir holds ⇒ new owner adopts —
   tables survive; adopt RESETS the reserve counters via
   `ets:delete_all_objects` and prunes orphan rows per Part 0.5).
5. Divergence rule (advisory): pure time-parameterized 3×/2-min
   window, ≥ 100 ms floor, reset on nodedown.
6. Snapshot builder: mutation ⇒ dirty-flag republish; 30 s tick
   republishes with no mutation; expired RTT absent from
   `rtt_map`; SEAM SPLIT — (a) the worker's passive EWMA skips
   internal jobs, (b) an internal job's `done` carrying `rtt_ms`
   is SKIPPED at master ingest (no passive `sched_rtt` write),
   (c) probe cold-start fill writes ONLY under the existence
   gate (no unexpired row); a later-arriving passive row
   overwrites it (last-arrival-wins per A.3 — no stamp compare
   exists); `rtt_ms` clamp drops negative/non-finite (counted
   by `sched_rtt_dropped_total{reason=negative|non_finite}`),
   KEEPS 0.0, and CLAMPS DOWN > 600000 (clamp-down does NOT
   increment the dropped counter); `sched_geo_disabled_total`
   increments once per disable event, ONLY when geo was
   explicitly requested (explicit-boot and async-failure cases;
   silent on default boots).
7. Mixed-version: old-shape hello (no new keys) admits with
   defaults; new hello keys ignored by old-shape admit clauses;
   `done`/`error` without/with `rtt_ms` both match shipped-shape
   clauses; a `{sched, 2, {load, _}}` message sent via
   `gen_server:cast` is dropped+counted by the old `handle_cast`
   catch-all (DELIVERY path covered, not just the shape);
   usage-filter seam with production-shaped jobs (map and, if
   applicable, record contingency); `internal` job-map-key
   tolerance on old job-decode clauses (with/without the key
   both decode).
8. EWMA pure-math, SPLIT: (a) worker passive-RTT EWMA α = 0.25
   over synthetic upstream latencies, SEED AT FIRST SAMPLE;
   (b) master TTFB EWMA (α = 0.25, seed at first sample) feed —
   dispatch-ack → first chunk, single-chunk fallback path, ERROR
   and INTERNAL (probe) completions excluded (recognized via the
   tracked `Internal` flag); an affinity-PINNED completion
   updates `observed_ewma_ms` exactly like an unpinned one
   (pinned picks are real jobs). Both: three identical 8000 ms
   samples ⇒ EWMA = 8000 (the seed rule — seeded-at-0 would read
   4625 and break 13.6's arithmetic); production-shaped maps
   throughout.

Gate (e2e_mw_local.sh extensions — TF-13.2–13.6). The harness
RESTARTS STACKS BETWEEN STEPS — all counters start at 0, so
per-step reads are fresh baselines. TOPOLOGY: 13.3a/13.3b/13.6
need TWO WORKER services (the harness grows a second
`janus-worker-2` compose service with its own join flow); the
other steps run on master + 1 worker. Harness wiring:
the script threads per-worker env
(`JANUS_WORKER_REGION`, `JANUS_WORKER_CAPACITY` via compose
environment) and master knobs (`JANUS_SCHED_*`) per step; the mock
gains a SLOW key `sk-slow...` delaying the response 8 s (> the
5000 ms demotion floor — magnitude derived from the formula).
All assertions against `/stats/sched` + `/metrics`, never logs:

- **13.2 single-node regression**: existing 13.pool unchanged;
  PLUS `pick` empty-pool ⇒ local fallback (regression guard) and
  `snapshot_gen` present/advancing on `/stats/sched` — the step
  drives ONE dispatch then polls with a bounded ≤ 35 s wait
  (dirty-flush ≤ 250 ms or the 30 s tick both qualify; no
  unbounded polling).
- **13.3a legacy geo (region_tag)**: two workers
  (`JANUS_WORKER_REGION=cn-east` / `us` — in-vocab, clean logs);
  provider `region_tag=cn-east` (mock) ⇒ the cn-east worker wins
  the job; `geo_match_total{region_tag}` ≥ 1; a provider with
  `region_tag=eu` (known comparator matching no worker) yields
  `geo_match_total{none}` while the job still dispatches.
- **13.3b auto-geo**: `JANUS_SCHED_GEO=1` + test-only
  `JANUS_SCHED_GEO_TEST_HOSTS=<mockhost>=cn-east` (satisfies the
  boot check AND exempts the existence refusal, loud log); the
  provider has NO legacy `region_tag` (else tier 4's comparator
  is the tag and `auto` never fires). SETTLE BARRIER: drive
  jobs until `geo_match_total{auto}` ≥ 1 (the async geo fill
  publishes `unknown` first), then assert the ranking ⇒
  `geo_match_total{auto}` ≥ 1 AND the
  cn-east worker wins over us
  (`dispatch_worker_total{cn-east, provider}` ≥ 1 and
  `{us, provider}` = 0 — expressible thanks to the provider
  label, on fresh per-step counters).
- **13.4 multi-node dispatch + RTT**: worker joins; ≥ 3 jobs
  through master to the mock (503-key → error path, 200-key →
  done path): `dispatch_worker_total{node=worker}` ≥ 3;
  `reserve_inflight{worker}` returns to 0 (bounded ≤ 35 s poll
  after completions); the `rtt_ms` entry
  for `<worker>/<provider>` is PRESENT with the RTT knob OFF
  (rows are written regardless of `JANUS_SCHED_RTT` — the knob
  gates the sort key only; asserting under knob-off is the
  stronger proof; value ≥ 0.0 — sub-ms mock latency may round to
  zero; presence is the assertion).
- **13.4b probes (forced, geo-independent)**:
  `JANUS_SCHED_PROBE=1` + `JANUS_SCHED_PROBE_FORCE=1` +
  `JANUS_SCHED_PROBE_MAX_HOURLY=100` headroom for retries (geo
  stays OFF — the target rule is catalog-known AND ENABLED
  providers, Part 0.2; FORCE bypasses cadence and the fresh-skip
  but still consumes the cap; FORCE never bypasses the
  `sched_v` filter either)
  ⇒ `probe_total` ≥ 1 within the step, asserted with the same
  bounded ≤ 45 s poll pattern (the 30 s tick + probe RTT, with
  CI-load slack); usage row-count delta over
  the probe window = 0 (probe invisible in accounting).
- **13.5 capacity**: worker `JANUS_WORKER_CAPACITY=1`; two
  CONCURRENT slow-key jobs (Python driver, MSYS-safe): both 200;
  `dispatch_worker_total` = 1 for the pair;
  `dispatch_local_total{capacity}` ≥ 1;
  `capacity_exhausted_total` ≥ 1; `reserve_inflight` drains to 0.
- **13.6 health (deterministic on the 2-node harness)**:
  `JANUS_SCHED_HEALTH=1`. The mock's SLOW key delays 8 s BEFORE
  FIRST BYTE (TTFB is the health signal — a delay after the first
  chunk would never trip it); assertions run against the NEW
  `/stats/sched` `health_ewma_ms` surface with a RELATIONAL
  assertion (host-speed robust): `victim_ewma > max(5000,
  3×fast_ewma)` — on the standard mock (fast sub-second TTFB)
  this reads victim ≈ 8000 > 5000 = the binding constraint.
  Poisoning jobs run CONCURRENTLY (three in-flight slow-key
  requests — same MSYS-safe Python driver as 13.5), budget
  ≥ 45 s, and ALL OTHER harness traffic is QUIESCED during the
  window (any stray fast job landing on the victim dilutes its
  EWMA). The slow key's before-first-byte
  delay is the MOCK'S CONTRACT (the harness implements it, not
  prose). Poisoning phase:
  BOTH providers pinned (`affinity_node`) — the slow provider to
  the VICTIM worker (EXACTLY 3 slow-key jobs ⇒ 3 TTFB samples of
  ~8 s on the victim; EWMA seeds at the first sample so three
  8 s samples read 8 s), the fast provider to the HEALTHY worker
  (EXACTLY 3 fast jobs ⇒ 3 samples) — sample accumulation is
  routing-deterministic, not least-inflight-dependent. Then the
  verification pick (COMPLETION BARRIER first: all 3+3
  poisoning responses landed — the 3 victim TTFB samples exist
  before the pick fires): a THIRD mock provider WITHOUT
  `affinity_node` takes one job (unpinned by construction — no
  mid-run re-pinning needed): victim demoted (its exclude-self
  threshold = max(5000, 3×fast) < 8 s) ⇒ `health_demote_total`
  ≥ 1 AND the fast worker wins (DELTA assertions on the fresh
  counters: Δ`dispatch_worker_total{fast, third-provider}` = 1,
  Δ`{victim, third-provider}` = 0). All-workers-slow variant (both providers on the slow key) is
  a GATE assertion: Δ`health_demote_total` = 0 while jobs still
  dispatch — the min-EWMA survivor invariant (see A.4) observed
  live; never-shed-all itself stays a SYNTHETIC eunit case
  (tier matrix), unreachable by construction here. Gate runtime cost: ~3 × 8 s slow jobs — the harness
  step carries an explicit ≥ 45 s wall-clock budget with a
  fail-loud timeout (no silent hang).

Browser: the dashboard Nodes page renders unchanged; `/stats/fleet`
JSON valid for existing polling (additive keys only);
`/stats/sched` reachable read-only. Real clicks: login → Nodes →
healthy master row; Providers knob row unchanged.

## Part F — Explicitly deferred (recorded, not built)

Fairness quotas per agent key/provider; consistent-hashing ring;
auto-affinity learning; worker auto egress-IP geo discovery;
per-provider health split (v1 is per-worker global); TTFB-only
health (v1 accepts the single-chunk mixed-mode bias); dashboard UI
for geo/health (v1 metrics-only); geo-aware failover ordering;
per-agent geo/RTT visibility.

## Part G — Self-review checklist

- [x] Every failure mode has a degradation path to v1 behavior
- [x] Cost floor: default config adds zero upstream calls
- [x] Selection pure (counters emitted by pick from Decisions);
      capacity enforced in ONE place with a single pinned
      `update_counter` form; atom-ordering trap closed
- [x] Demotion math executable at N=2 (exclude-self threshold) —
      gate 13.6 runs on the existing 2-node harness
- [x] Mixed-version safety VERIFIED (named files + eunit), deploy
      order pinned (masters → workers; mmdb before env)
- [x] Capacity semantics single-specified across Part 0/B/C/
      metrics/gate 13.5; ack-miss over-release closed
- [x] Heir mechanics real (janus_ets_heir adopt cycle; all five
      tables covered)
- [x] Probes structurally outside the reserve loop
      (`dispatch_probe/2`); ack-miss pending + purge-age; adopt
      resets orphan counters
- [x] Tests enumerated: eunit-first (live pool where stateful) +
      gate steps 13.2–13.6, every step asserts a named key on the
      pinned `/stats/sched` surface (incl. `reserve_inflight`,
      `schema_version`)
- [x] Default config eunit-proven v1 (region-tagged fixtures
      included — legacy tier ungated)
- [x] pi-audit GO — rounds 1-9 archived under docs/audit/
      archive/2026-10-10-r{1..9}; rev 10 folds the round-9
      one-sentence residuals; deepseek recorded 3x context-limit
      infra-fails (documented per NOTE files); all other models:
      GO WITH FIXES with zero architecture/math/testability
      objections since round 3
