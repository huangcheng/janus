%%% @doc Master-side worker pool (spec §3.4 / §6; scheduler v2 rev 10 +
%%% v2.1 hardening — `2026-10-11-scheduler-v2.1-hardening.md` Parts
%%% A.1-A.3 / B.1-B.2).
%%%
%%% Tracks hello'd workers, drain → sticky transitions, and selection.
%%% Pure state helpers are exported for eunit; the gen_server owns
%%% timers, `monitor_nodes`, and sticky persistence in
%%% `worker_sticky_drained`.
%%%
%%% Scheduler v2 (`docs/superpowers/plans/2026-10-10-scheduler-v2.md`):
%%% the READ PATH moved off the gen_server — {@link pick/1} runs in the
%%% CALLER's process against heir'd public ETS tables while the
%%% gen_server remains the sole writer:
%%%
%%% <ul>
%%% <li>`sched_snapshot` — single row `{candidates, [{Node, Meta}]}`
%%%   republished atomically (dirty-flush <= 250 ms / 30 s tick).</li>
%%% <li>`sched_reserve` — the ONE live reservation counter; the pinned
%%%   increment form is `ets:update_counter(sched_reserve, Node, {2, 1},
%%%   {Node, 0})` (4-tuple UpdateOp forms are FORBIDDEN — they wrap).</li>
%%% <li>`sched_workers` — live drain flags `{Node, Draining}` (a MISSING
%%%   row reads drained — the safe direction).</li>
%%% <li>`sched_rtt` — passive RTT cells, TTL 10 min,
%%%   `{{Node, ProviderId}, RttMs, Source, SampledAtMono, ExpiresAtMono,
%%%   Ewma, SampleCount}` — the EWMA is maintained INCREMENTALLY at each
%%%   {rtt,...} arrival (v2.1 B.2: alpha 0.25, seed-at-first).</li>
%%% <li>`sched_tracked` — `JobRef => {Node, ReservedAtMono, ProviderId,
%%%   Internal}` (v2.1 B.1): the tracked-job set is CALLER-WRITTEN
%%%   (pick's winner inserts directly; {@link release/1} is the
%%%   caller-side `ets:take` + conditional decrement). Probes insert
%%%   rows with `Internal => true` and never decrement.</li>
%%% <li>`sched_suspect` — `JobRef => Node` (worker-capacity-override
%%%   spec Part 2): the set of reservations whose owning job is KNOWN
%%%   DEAD (a timeout path called `mark_dead/1` but kept the slot, spec
%%%   Part 0.11). The load figure is `reserve - suspect`; the admission
%%%   counter stays raw `?RESERVE`. Keyed by JobRef (not Node) so the
%%%   SINGLE owner `take_and_maybe_decrement/1` atomically frees both a
%%%   slot and its suspect contribution in one take. Heir'd — a master
%%%   restart cold-clears it (accepted, documented).</li>
%%% </ul>
%%%
%%% v2.1 A.2 inflight single-source: the member `inflight` map (the v1
%%% sort hint) is REMOVED — the reserve counter is the ONLY live count.
%%% `pick/1` reads `sched_reserve` LIVE per candidate for the inflight
%%% sort component (FRESHER than v2's flush-bounded hint); the
%%% snapshot's `inflight` field is display-only. Drain-idle arming
%%% evaluates on every sched_tick AND every dirty-flush republish (the
%%% `{touched, Node}` completion poke marks dirty): draining AND the
%%% node's NON-INTERNAL tracked set empty AND reserve == 0.
%%%
%%% Probe machinery (Task B2, spec Part 0.2/0.8): the 30 s tick
%%% self-casts `{sched, 2, {probe, JobSpec}}` (pool-internal) when
%%% `JANUS_SCHED_PROBE=1`; `dispatch_probe/2` sends a NORMAL pinned job
%%% carrying the additive `internal => true` map key straight to the
%%% target worker's `janus_worker_dispatch` (no pick, no reserve
%%% counter). Ack-miss/send-fail aborts — never local fallback.
%%%
%%% Selection is PURE (`select_v2/2`); pick emits the metrics from its
%%% Decisions. Counters are owner-local in `sched_counters` (tolerant
%%% bump pattern) and surfaced via {@link sched_stats/0}.
%%%
%%% Wire compression (spec 2026-10-12-wire-compression F1/D10/D11):
%%% the pool advertises `wire_enc => [zlib]` in every hello ack while
%%% the master env gate is on (`wire_enc_ack/1`), runs the D11 boot
%%% self-check, and owns the codec's counters table (decode on the
%%% master is TAG-DRIVEN, so the counters exist env-off too). D9
%%% (Task C): worker-side codec counters ride the `{sched, 2,
%%% {load, Node, Info}}` cast (additive `wire_enc` key — old workers
%%% never send it, old masters drop it); `do_load` stores the LATEST
%%% normalized snapshot per node and `sched_stats/0` aggregates
%%% master-local + relayed (`aggregate_wire_enc/2`).
-module(janus_worker_pool).
-behaviour(gen_server).

-export([
    start_link/0,
    pick/1,
    pick_sync/1,
    available/0,
    undrain/1,
    geo_refresh/1,
    pool_ping/0,
    note_inflight/2,
    release/1,
    note_dispatch_local/1,
    drain_idle_ms/0,
    %% Scheduler v2 surfaces (spec Part C).
    knobs/0,
    rtt_enabled/0,
    health_enabled/0,
    sched_stats/0,
    sched_snapshot_gen/0
]).

%% Pure state machine (eunit — no net/DB).
-export([
    new_pool/1,
    apply_hello/3,
    apply_drain/2,
    apply_nodedown/2,
    apply_undrain/2,
    apply_drain_idle/2,
    select/2,
    available/1,
    is_sticky/2,
    is_draining/2,
    is_member/2,
    %% Geo-affinity ingest seam (2026-10-11 spec D4 — eunit).
    normalize_hello_meta/2,
    %% Wire-enc advertisement seam (2026-10-12 spec F1/D10 — eunit:
    %% the master's half of the mixed-version matrix).
    wire_enc_ack/1,
    %% Wire-enc relay pure seams (2026-10-12 spec D9 — eunit:
    %% snapshot normalization + master-local/relayed aggregation).
    normalize_wire_enc/1,
    aggregate_wire_enc/2
]).

%% Pure scheduler v2 (eunit — no ETS writes, no counters, no time).
-export([
    select_v2/2,
    ewma_step/2,
    observed_ewma/1,
    demote_ms/2,
    median/1,
    clamp_rtt/1,
    report_divergent/2,
    advance_divergence/4,
    %% Geo-affinity pure seams (spec 2026-10-11 D4/D15/D18).
    effective_geo/4,
    %% Capacity override precedence (worker-capacity-override spec Part 1):
    %% the PURE 3-arity form, so override-wins / bad-value-fallback /
    %% absent-entry are assertable without a running config server.
    effective_capacity/3,
    %% Suspect-adjusted load (worker-capacity-override spec Part 2): the
    %% clamp is the invariant worth pinning.
    suspect_adjusted/2,
    mismatch_step/4
]).

%% Probe machinery (spec Part 0.2/0.8 — Task B2).
-export([
    probe_enabled/0,
    probe_force/0,
    probe_candidates/0,
    dispatch_probe/2,
    build_probe_job/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(DRAIN_IDLE_MS, 30_000).
-define(VSN, 1).

%% Scheduler v2 tables (spec Part 0.5): heir'd, public, pool-owned.
%% v2.1 B.1: sched_tracked (caller-written) joins the set; sched_rtt
%% stays public+read_concurrency (B.2 live sort reads the cell Ewma).
-define(SNAPSHOT, sched_snapshot).
-define(RESERVE, sched_reserve).
-define(WORKERS, sched_workers).
-define(RTT, sched_rtt).
-define(TRACKED, sched_tracked).
-define(COUNTERS, sched_counters).
%% Reservation-integrity suspect table (worker-capacity-override spec Part 2):
%% keyed by JobRef so take_and_maybe_decrement/1 (the single owner) can
%% atomically clear a job's suspect contribution when freeing its reservation.
%% Heir'd like sched_tracked — a master restart cold-clears it (accepted).
-define(SUSPECT, sched_suspect).
%% Per-node suspect total, kept alongside ?SUSPECT so the load figure is
%% an O(1) read (see suspect_count/1).
-define(SUSPECT_COUNT, sched_suspect_count).

%% Knob flags: boot-time env read ONCE into persistent_term (spec Part
%% C — restart to change). GEO/PROBE knobs live in `janus_geo`.
-define(PT_KNOBS, {janus_worker_pool, sched_knobs}).

-define(FLUSH_MS, 250).
-define(TICK_MS, 30_000).
-define(RTT_TTL_MS, 600_000).
-define(RTT_MAX_MS, 600_000).
-define(PURGE_AGE_MS, 600_000).
-define(EWMA_ALPHA, 0.25).
-define(EWMA_MIN_SAMPLES, 3).
-define(DEMOTE_FLOOR_MS, 5000).
-define(DEMOTE_FACTOR, 3).
%% Probes (spec Part 0.2/0.8): cadence per (worker, provider) >= 60 s
%% with +-20 % jitter; cluster-wide cap over a rolling 1 h window.
-define(PROBE_CADENCE_MS, 60_000).
-define(PROBE_HOUR_MS, 3_600_000).
-define(PROBE_MAX_HOURLY_DEFAULT, 10).
%% Injection seam for probe PROVIDER candidates (eunit / future ops):
%% rows {ProviderId, CandidateMap}; empty in production => the catalog
%% path runs. NOT heir'd — injection is ephemeral by design.
-define(PROBE_CAND, sched_probe_candidates).
-define(DIVERGENCE_RATIO, 3.0).
-define(DIVERGENCE_FLOOR_MS, 100).
-define(DIVERGENCE_WINDOW_MS, 120_000).
%% Boot-path adopt backoff: ~2 s total (10 tries x 50 ms per table;
%% janus_geo precedent). The heir may not yet have processed the old
%% owner's `{'ETS-TRANSFER'}` when the new owner asks.
-define(ADOPT_RETRIES, 10).
-define(ADOPT_RETRY_MS, 50).
%% Geo-affinity (spec 2026-10-11): edge-trigger state on the MASTER —
%% persistent_term keyed by node (`last_geo_source`), nodedown-cleaned.
%% A master VM restart clears PT, so the first mismatch after restart
%% bumps the counter again (reset-duplicate — documented, accepted).
-define(PT_LAST_GEO_SOURCE, {janus_worker_pool, last_geo_source}).

-type geo_source() :: env | gw_echo | metadata | third_echo | unset.

-type decisions() :: #{
    geo_source => region_tag | auto | none,
    demoted => [node()],
    %% Affinity pin outcome (spec 2026-10-22 §6, additive): `honoured'
    %% — the declared pin reached its node; `miss' — a pin was DECLARED
    %% and silently fell through to the tiers (fail-open, D4); `none' —
    %% no pin declared. `affinity_pin' is the declared label (binary)
    %% when one was declared, `undefined' otherwise.
    affinity => honoured | miss | none,
    affinity_pin => binary() | undefined
}.

-record(state, {
    pool :: map(),
    timers = #{} :: #{node() => reference()},
    %% Scheduler v2 (pool gen_server state — dies with the owner, an
    %% accepted cold reset per spec Part 0.5). v2.1 B.1: the tracked-job
    %% set lives in the public `sched_tracked` table (caller-written);
    %% the gen_server reads it, never mirrors it.
    %% Node => {Ewma, SampleCount} — TTFB health EWMA.
    ewma = #{} :: map(),
    %% Node => divergence window state (advisory load mismatch).
    divergence = #{} :: map(),
    %% Node => last advisory load report (ops display only).
    load = #{} :: map(),
    %% Probe machinery (spec Part 0.2/0.8 — pool state, cleared on
    %% nodedown / owner restart):
    %% Node => JobRef — the in-flight probe map (the spec-pinned shape:
    %% structurally <= 1 probe in flight per worker).
    probe_inflight = #{} :: #{node() => binary()},
    %% JobRef => {Node, ProviderId, SentAtMono, Acked} — dispatch
    %% details for the ack/done/error/abort handlers.
    probe_sent = #{} :: #{binary() => {node(), term(), integer(), boolean()}},
    %% {Node, ProviderId} => SentAtMono — last-probed timestamps (the
    %% cadence + least-recently-probed source; never-probed pairs sort
    %% as OLDEST via key absence).
    probe_last = #{} :: map(),
    %% Issued-probe send timestamps (newest first) — the rolling 1 h
    %% cluster-wide cap window.
    probe_issued = [] :: [integer()],
    %% v2.1 C.4 knob-off guard: fires ONCE per pool lifetime (boot-
    %% scoped — reconnect storms must not inflate it) at the FIRST
    %% worker admission while geo/health/rtt are ALL off.
    knobs_off_warned = false :: boolean(),
    dirty = false :: boolean(),
    flush_tref = undefined :: reference() | undefined,
    tick_tref = undefined :: reference() | undefined,
    %% Node => ExcessCount seen at the PREVIOUS tick — reconcile
    %% decrements only excess that PERSISTS across two consecutive
    %% ticks (a pick's counter increment lands before its {track}
    %% cast; a same-tick excess is an in-flight register, not drift
    %% — spec Part 0.11 "older than one flush interval", ocr).
    excess_seen = #{} :: #{node() => pos_integer()},
    %% Wire-enc relay (spec 2026-10-12 D9, Task C): Node => LATEST
    %% normalized codec-counters snapshot from that worker's load cast
    %% (monotonic counters — latest-wins, NEVER summed across arrivals;
    %% a worker VM restart resets ITS table and the next snapshot
    %% replaces the stale one). nodedown clears the node; an owner
    %% restart cold-clears the whole map (workers re-relay on the next
    %% 30 s tick — the accepted counters-table death class). Appended
    %% last so the gen_server's field order stays append-only.
    wire_enc_relay = #{} :: map(),
    %% Nodedown log coalescing + identity-flap detection (2026-10-25
    %% incident: two co-located processes claiming one node name
    %% flooded 23 MB of nodedown logs in 20 min and rotated away the
    %% trigger evidence): Node => {Count, WindowStartMs, Suppressed,
    %% LastWarnMs} over a 10 s monotonic window. See note_nodedown/2.
    flap = #{} :: #{node() => {non_neg_integer(), integer(), non_neg_integer(), integer()}}
}).

%%%===================================================================
%%% Public API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Scheduler v2 pick (spec Part C): runs in the CALLER's process —
%% one ETS snapshot read, pure `select_v2/2`, then a lock-free
%% reservation loop. NEVER a gen_server call on the dispatch path.
%%
%% v1-compatible return shape `{ok, Node} | empty`: every local-fallback
%% outcome (empty pool, drained candidates, capacity exhaustion) is
%% counted under `sched_dispatch_local_total{reason}` HERE and surfaced
%% as `empty`, so v1 callers (`janus_http_worker_client:safe_pick/1`
%% treats `empty` => local execution) stay source-compatible.
-spec pick(map()) -> {ok, node()} | empty.
pick(Opts) when is_map(Opts) ->
    try
        case ets:lookup(?SNAPSHOT, candidates) of
            [{candidates, Snapshot}] when is_list(Snapshot) ->
                pick_dispatch(Snapshot, Opts);
            [{candidates, _}] ->
                local_fallback(empty_pool);
            [] ->
                local_fallback(empty_pool)
        end
    catch
        Class:Reason:_Stack ->
            %% Missing table (worker node / pool down) or an unexpected
            %% fault: a pick never fails the request — the master
            %% executes locally. Faults are counted SEPARATELY from an
            %% idle fleet so tier bugs stay visible (ocr review):
            %% badarg = the expected missing-table window; anything
            %% else is an internal pick fault worth an error log.
            case Class of
                error -> ok;
                _ -> ok
            end,
            _ =
                case Class of
                    error ->
                        case Reason of
                            badarg -> ok;
                            _ -> bump(pick_fault), log_pick_fault(Class, Reason)
                        end;
                    _ ->
                        bump(pick_fault), log_pick_fault(Class, Reason)
                end,
            local_fallback(empty_pool)
    end.

%% @doc v1 gen_server selection over live pool state (`select/2`
%% semantics). Kept for tests; `pick/1` no longer round-trips the
%% gen_server.
-spec pick_sync(map()) -> {ok, node()} | empty.
pick_sync(Opts) when is_map(Opts) ->
    gen_server:call(?SERVER, {pick_sync, Opts}).

%% Assemble pick opts: knob flags from persistent_term (boot-time),
%% per-request affinity_node/region_tag/provider_id/job_ref ride the
%% Opts argument as today (spec Part C — opts split).
pick_dispatch(Snapshot, Opts) ->
    Knobs = knobs(),
    GeoOn = janus_geo:geo_enabled(),
    %% Soft-disable refuse counter: desired on but effective off (no mmdb).
    case maps:get(geo_desired, Knobs, false) andalso not GeoOn of
        true -> _ = janus_sched_knobs:bump_geo_refused();
        false -> ok
    end,
    PickOpts = Opts#{
        geo_enabled => GeoOn,
        rtt_enabled => maps:get(rtt, Knobs, false),
        health_enabled => maps:get(health, Knobs, false),
        provider_geo =>
            case GeoOn of
                true -> janus_geo:provider_geo(maps:get(provider_id, Opts, undefined));
                false -> unknown
            end
    },
    %% v2.1 A.2/B.2: the two live-read sort components are rewritten per
    %% candidate IN THE CALLER — inflight from sched_reserve (A.2: the
    %% snapshot's inflight is display-only; this read is FRESHER than
    %% v2's flush-bounded hint) and the provider RTT cell's Ewma from
    %% sched_rtt (B.2). One extra ETS read per candidate; everything
    %% else (capacity, draining, geo, health) stays snapshot-bounded.
    {Order, Decisions} = select_v2(live_snapshot(Snapshot, PickOpts), PickOpts),
    emit_pick_metrics(Decisions),
    case Order of
        [] when Snapshot =:= [] ->
            %% Snapshot published but empty (idle fleet at boot).
            local_fallback(empty_pool);
        [] ->
            %% Candidates exist but none dispatchable at snapshot view.
            local_fallback(drained);
        _ ->
            JobRef = job_ref(maps:get(job_ref, Opts, undefined)),
            reserve_loop(Order, Snapshot, PickOpts, JobRef, undefined)
    end.

%% Per-candidate live override of the sort inputs (A.2/B.2). The PURE
%% `select_v2/2` input contract is unchanged — candidates still carry
%% an `inflight` integer and an `rtt_map`; PICK supplies them live.
live_snapshot(Snapshot, PickOpts) ->
    case maps:get(rtt_enabled, PickOpts, false) of
        true ->
            ProviderId = maps:get(provider_id, PickOpts, undefined),
            [
                {Node, M#{
                    inflight => reserve_count_live(Node),
                    rtt_map => rtt_cell_live(Node, ProviderId)
                }}
             || {Node, M} <- Snapshot
            ];
        false ->
            [{Node, M#{inflight => reserve_count_live(Node)}} || {Node, M} <- Snapshot]
    end.

%% Live reservation count (A.2): public table, read_concurrency —
%% caller-side, tolerant of the missing-table window.
%% Live reservation count for the SORT path (A.2): reserve minus
%% suspect so a node recovering from a dist hiccup is not demoted for
%% work that is already dead (worker-capacity-override spec Part 2).
%% Has exactly ONE caller (live_snapshot/2); delegates to the shared
%% helper so the subtraction cannot drift from the dashboard's.
reserve_count_live(Node) ->
    suspect_reserve_count(Node).

%% Live per-provider RTT cell (B.2 SORT KEY): reads the {Node,
%% ProviderId} row's Ewma when unexpired. NO cell (never sampled, or
%% expired) yields an EMPTY map, which sort_tier/2 reads as UNMEASURED
%% and keys on the fleet minimum (see its COLD-START note) — not on
%% `infinity`, which used to rank a fresh node last forever.
rtt_cell_live(Node, ProviderId) ->
    Now = now_mono(),
    try
        case ets:lookup(?RTT, {Node, ProviderId}) of
            [{_Key, _Ms, _Source, _SampledAt, ExpiresAt, Ewma, _Count}] when
                ExpiresAt > Now, is_number(Ewma)
            ->
                #{ProviderId => Ewma};
            _ ->
                #{}
        end
    catch
        _:_ -> #{}
    end.

%% @doc Reserve loop (spec Part C step 3 + v2.1 B.1): per candidate in
%% order — live drain re-check from `sched_workers` (MISSING row =
%% drained => refuse, the safe direction), ADMISSION PRIMITIVE
%% (increment FIRST with the ONE pinned form, compare the RETURNED
%% count to capacity — the atomic counter op IS the admission decision;
%% never read-check-then-increment), capacity comparison SKIPPED
%% entirely when capacity =:= infinity and for affinity-pinned picks
%% (soft cap). Overflow rolls back with the pinned decrement form — the
%% rollback touches NO tracked row (nothing was inserted for the losing
%% candidate) — and tries the next candidate. FIRST success inserts
%% the tracked row DIRECTLY into `sched_tracked` (v2.1 B.1: caller-side,
%% no {track} cast) and returns; list exhausted => local fallback with
%% the FIRST non-ok outcome in iteration order.
reserve_loop([], _Snapshot, _Opts, _JobRef, FirstReason) ->
    local_fallback(first_reason(FirstReason, drained));
reserve_loop([Node | Rest], Snapshot, Opts, JobRef, FirstReason) ->
    Pinned = maps:get(affinity_node, Opts, undefined) =:= Node,
    %% Known-doomed skip (worker-capacity-override spec Part 2): the sort
    %% ranks a suspect-laden node as LEAST loaded (reserve - suspect) while
    %% admission compares the RAW counter, so without this guard every pick
    %% would select that node, increment, fail, roll back and bump
    %% capacity_exhausted — repeatedly, on the hot path, for a node that is
    %% actually idle. Skipping before the increment keeps the counter clean
    %% (an attempted-and-rolled-back pick is NOT an exhaustion signal).
    %% `?RESERVE` is still the number compared; this only avoids trying a
    %% candidate that is already known to fail.
    Doomed =
        case Pinned of
            true ->
                false;
            false ->
                case candidate_capacity(Node, Snapshot) of
                    infinity -> false;
                    Cap -> suspect_reserve_count(Node) >= Cap
                end
        end,
    case not Doomed andalso live_draining(Node) =:= false of
        true ->
            Count = ets:update_counter(?RESERVE, Node, {2, 1}, {Node, 0}),
            Capacity = candidate_capacity(Node, Snapshot),
            OverCapacity = not Pinned andalso Capacity =/= infinity andalso Count > Capacity,
            case OverCapacity of
                false ->
                    %% dispatch_worker_total{node, provider} (spec Part
                    %% C): counted ONLY when the pick carries provider
                    %% context — pick callers without provider_id
                    %% (generic picks) are skipped rather than counted
                    %% under a noisy `"<node>/"` key; only the http
                    %% client passes provider_id today.
                    ok = maybe_bump_dispatch_worker(Node, maps:get(provider_id, Opts, undefined)),
                    %% v2.1 B.1 WRITE ORDER (pinned): the increment is
                    %% already done above; the tracked insert follows in
                    %% the SAME caller process. If the insert itself
                    %% throws (boot/adopt race, system_limit) the
                    %% reservation stands UNTRACKED and the two-tick
                    %% reconcile reclaims the excess — the same heal as
                    %% a crashed caller (spec B.1 / F1).
                    try
                        true = ets:insert(
                            ?TRACKED,
                            {JobRef, {Node, now_mono(), maps:get(provider_id, Opts, undefined), false}}
                        )
                    catch
                        _:_ -> ok
                    end,
                    {ok, Node};
                true ->
                    %% Rollback decrement form (the 4-tuple UpdateOp is
                    %% FORBIDDEN — SetValue semantics wrap and pin).
                    _ = ets:update_counter(?RESERVE, Node, {2, -1}, {Node, 0}),
                    ok = bump(capacity_exhausted),
                    reserve_loop(Rest, Snapshot, Opts, JobRef, first_reason(FirstReason, capacity))
            end;
        false ->
            Reason =
                case Pinned of
                    true -> drained_pin;
                    false -> drained
                end,
            reserve_loop(Rest, Snapshot, Opts, JobRef, first_reason(FirstReason, Reason))
    end.

%% Live drain re-check: `{Node, false}` reads dispatchable; a missing
%% row or `{Node, true}` reads drained (missing = refuse, spec Part C).
live_draining(Node) ->
    case ets:lookup(?WORKERS, Node) of
        [{Node, false}] -> false;
        _ -> true
    end.

candidate_capacity(Node, Snapshot) when is_list(Snapshot) ->
    case lists:keyfind(Node, 1, Snapshot) of
        {Node, #{capacity := Capacity}} -> Capacity;
        _ -> infinity
    end.

first_reason(undefined, Reason) ->
    Reason;
first_reason(First, _Reason) ->
    First.

job_ref(undefined) ->
    %% The caller has no JobRef at pick time today (Task C passes one);
    %% generate a master-side unique reference (spec Part 0.11).
    crypto:strong_rand_bytes(16);
job_ref(Ref) ->
    Ref.

%% Metrics from Decisions (spec Part B — pick emits, never the pure
%% function): geo source ONCE per pick; health demote ONCE per node
%% ACTUALLY excluded (never-shed-all suppression emits nothing);
%% affinity outcome ONCE per pick (spec 2026-10-22 §6 / D4).
%%
%% `affinity_total' partitions every pick exactly once
%% (honoured|miss|none — the picks total: `geo_match_total' is the same
%% partition, so no separate total counter is introduced). A miss ALSO
%% bumps `affinity_miss_total{pin}' — the declared pin label. That
%% label is BOUNDED: a provider row holds at most one `affinity_node',
%% so the distinct-label cardinality is bounded by the providers-table
%% cardinality (9 rows in prod, none pinned today), never by traffic.
%% The pin label (not the provider id) is used because it names the
%% offending value for the §7.6 typo case; a provider label is equally
%% bounded and could be added later if a per-provider join is wanted.
%% Emission happens on the production pick path (`pick/1' ->
%% `pick_dispatch/2' -> here); the legacy `pick_sync/1' v1 path emits
%% no pick metrics at all (unchanged).
emit_pick_metrics(#{
    geo_source := Source,
    demoted := Demoted,
    affinity := Affinity,
    affinity_pin := Pin
}) ->
    ok = bump({geo_match, Source}),
    ok = bump({affinity, Affinity}),
    case Affinity of
        miss when is_binary(Pin) -> ok = bump({affinity_miss, Pin});
        _ -> ok
    end,
    lists:foreach(fun(_Node) -> ok = bump(health_demote) end, Demoted).

%% dispatch_worker_total{node, provider}: skipped when the pick carries
%% no provider context (see reserve_loop).
maybe_bump_dispatch_worker(_Node, undefined) ->
    ok;
maybe_bump_dispatch_worker(Node, ProviderId) ->
    ok = bump({dispatch_worker, Node, ProviderId}).

local_fallback(Reason) ->
    ok = bump({dispatch_local, Reason}),
    empty.

log_pick_fault(Class, Reason) ->
    logger:error(#{
        what => janus_worker_pool_pick_fault,
        class => Class,
        reason => Reason
    }),
    ok.

%% @doc Hot knob flags (maintenance hot-knobs spec): resolve settings
%% → env → default on each read. `probe_force` stays boot-only (env).
%% GEO effective state lives in `janus_geo:geo_enabled/0` (desired ∧
%% mmdb); the /stats/sched view merges it (see {@link sched_stats/0}).
-spec knobs() -> map().
knobs() ->
    {Vals, _Src} = janus_sched_knobs:cached_sched(),
    Force = maps:get(probe_force, pt_read(?PT_KNOBS, #{}), false),
    #{
        rtt => maps:get(rtt, Vals, false),
        health => maps:get(health, Vals, false),
        probe => maps:get(probe, Vals, false),
        probe_max_hourly => maps:get(probe_max_hourly, Vals, ?PROBE_MAX_HOURLY_DEFAULT),
        probe_force => Force =:= true,
        unary_fallback => maps:get(unary_fallback, Vals, false),
        geo_desired => maps:get(geo, Vals, false)
    }.

-spec rtt_enabled() -> boolean().
rtt_enabled() ->
    maps:get(rtt, knobs(), false).

-spec health_enabled() -> boolean().
health_enabled() ->
    maps:get(health, knobs(), false).

%% @doc Probes are MONEY (spec Part 0.8): OFF by default; the knob also
%% gates the `{sched, 2, {probe, _}}` cast clause itself so a stray
%% external cast can never spend the budget with the knob off.
-spec probe_enabled() -> boolean().
probe_enabled() ->
    maps:get(probe, knobs(), false).

%% @doc Test-only `JANUS_SCHED_PROBE_FORCE`: bypasses cadence AND the
%% fresh/unexpired-row skip — never the hourly cap, the dispatchable x
%% enabled eligibility, or the `sched_v` filter (spec Part 0.2). Loud
%% warning at boot; never in prod.
-spec probe_force() -> boolean().
probe_force() ->
    maps:get(probe_force, knobs(), false).

probe_max_hourly() ->
    maps:get(probe_max_hourly, knobs(), ?PROBE_MAX_HOURLY_DEFAULT).

%% @doc All scheduler counters (owner-local `sched_counters` ETS —
%% `janus_metrics` lives in the janus_http app, unreachable from
%% janus_core without inverting the dependency; janus_geo's tolerant
%% local-counter precedent). Keys mirror the spec metric names minus
%% the `sched_` prefix; labeled metrics use `{Name, Label}` keys
%% (`fleet_worker_report_mismatch` keeps its full name).
%%
%% Task B2: the map ALSO carries the non-counter /stats/sched sources —
%% `knobs` (knob view incl. `geo_enabled`), `health_ewma` (the raw
%% DISPLAY value from sample 1, spec A.4), `rtt_rows` and
%% `reserve_rows` (raw public-table reads) — so the /stats/sched
%% handler is one call and the JSON assembly stays pure. Served by a
%% gen_server call for an atomic state view; falls back to a
%% degraded ETS-only assembly when the pool is down (tables are
%% public; health_ewma reads empty).
-spec sched_stats() -> map().
sched_stats() ->
    try
        gen_server:call(?SERVER, sched_stats, 1000)
    catch
        _:_ ->
            degraded_sched_stats()
    end.

degraded_sched_stats() ->
    Counters =
        try
            maps:from_list(ets:tab2list(?COUNTERS))
        catch
            _:_ -> #{}
        end,
    Counters#{
        %% Pool down: the relay state AND the codec counters table
        %% died with their owner (no heir — the accepted cold class;
        %% workers re-relay and the decode side re-counts from zero
        %% after the restart). The key stays present (hoisted OUT of
        %% the try — janus_wire_enc:counters/0 is itself
        %% exception-safe) so the shape is additive on every return
        %% path: the JSON layer renders the full zeroed enum, never a
        %% missing section.
        wire_enc => aggregate_wire_enc(janus_wire_enc:counters(), #{})
    }.

%% @doc Public read of the snapshot generation counter: BOTH flush
%% paths (dirty-flush and the 30 s tick) advance it (spec Part C).
-spec sched_snapshot_gen() -> non_neg_integer().
sched_snapshot_gen() ->
    try
        ets:lookup_element(?COUNTERS, snapshot_gen, 2, 0)
    catch
        _:_ -> 0
    end.

-spec available() -> non_neg_integer().
available() ->
    gen_server:call(?SERVER, available).

-spec undrain(node()) -> ok.
undrain(Node) when is_atom(Node) ->
    gen_server:call(?SERVER, {undrain, Node}).

%% Operator-initiated worker geo re-discovery (fleet command
%% worker_geo_refresh; runs on the MASTER). Membership-checked against
%% the live sched view, then a fire-and-forget dist message to the
%% target's janus_worker_dispatch — the discovery chain runs there
%% (probes are the worker's own egress) and the refreshed entry rides
%% the next hello (immediate: the worker re-hellos when the run lands).
%% Active liveness check over the dist mesh (fleet command pool_ping):
%% net_adm:ping every sched worker. Instant on live links (the dist
%% connection already exists); a dead node attempts a fresh connect and
%% reads pang. Returns pong/pang per node as binaries for the JSON wire.
-spec pool_ping() -> #{binary() => binary()}.
pool_ping() ->
    Nodes = [N || #{node := N} <- maps:get(workers, sched_stats(), [])],
    Acc = maps:from_list([
        begin
            R = net_adm:ping(N),
            {atom_to_binary(N, utf8),
             case R of pong -> <<"pong">>; pang -> <<"pang">> end}
        end
     || N <- Nodes
    ]),
    Acc.

-spec geo_refresh(node()) -> {ok, requested} | {error, unknown_worker}.
geo_refresh(Node) when is_atom(Node), Node =/= node() ->
    Members = [N || #{node := N} <- maps:get(workers, sched_stats(), [])],
    case lists:member(Node, Members) of
        true ->
            {janus_worker_dispatch, Node} ! geo_refresh_now,
            {ok, requested};
        false ->
            {error, unknown_worker}
    end.

-spec note_inflight(node(), 1 | -1) -> ok.
note_inflight(Node, Delta) when is_atom(Node), (Delta =:= 1 orelse Delta =:= -1) ->
    gen_server:cast(?SERVER, {note_inflight, Node, Delta}).

%% @doc v2.1 B.1 CALLER-SIDE release: `ets:take` the tracked row, then
%% — iff a row was taken AND `Internal =:= false` — the pinned-form
%% decrement `{2,-1},{Node,0}` (the insert-default makes the decrement
%% badarg-IMPOSSIBLE even when nodedown deleted the reserve row: a
%% transient -1 clamped by the tick; the session NEVER crashes on
%% bookkeeping). take() owns the decrement: a double release is a
%% no-op (idempotent), a post-purge release finds nothing. Finally the
%% COMPLETION POKE `{sched, 2, {touched, Node}}` marks the snapshot
%% dirty so the <= 250 ms flush re-evaluates drain-idle arming (A.2).
%% Runs in the CALLER's process — the BOOKKEEPING never enters the
%% gen_server mailbox. The one cheap call below is an ORDERING
%% BARRIER, not bookkeeping: the session's earlier {rtt,...}/
%% {ttfb,...} casts ride the same sender-to-receiver FIFO as this
%% call, so draining it guarantees the ingest handlers still see the
%% tracked row (v2's "rtt always precedes its release" FIFO note —
%% v2.1's take is immediate, the casts are not; without the barrier
%% the health/rtt feeds would be silently lost whenever the pool is
%% merely busy). A dead/stuck pool proceeds (its casts were dropped
%% with it; the tables are public — the decrement stays correct).
%%
%% Worker-capacity-override spec Part 2: release also clears any
%% suspect entry (via take_and_maybe_decrement/1) — the SINGLE-OWNER
%% rule prevents double-decrement of the suspect counter.
-spec release(binary()) -> ok.
release(JobRef) when is_binary(JobRef) ->
    %% Barrier timeout = the pool was too busy to drain the FIFO in
    %% 5 s: the earlier {rtt,...}/{ttfb,...} casts may land after
    %% this take and be dropped — COUNTED, never silent (ocr).
    try gen_server:call(?SERVER, available, 5000) of
        _Available ->
            ok
    catch
        _:_ ->
            %% Barrier timeout/death: the earlier {rtt,...}/{ttfb,...}
            %% casts may land after this take and be dropped —
            %% COUNTED, never silent (ocr review).
            _ = bump(release_barrier_timeout)
    end,
    case take_and_maybe_decrement(JobRef) of
        {taken, Node, _Decremented} ->
            _ = (catch gen_server:cast(?SERVER, {sched, 2, {touched, Node}})),
            ok;
        none ->
            ok
    end.

%% @doc Client-side dispatch-local reason emission (Task C, spec Part
%% C): pick counts its OWN local-fallback reasons; `send_fail` and
%% `ack_miss` happen AFTER pick returned, so `janus_http_worker_client`
%% reports them here (`sched_dispatch_local_total{reason}`).
-spec note_dispatch_local(atom()) -> ok.
note_dispatch_local(Reason) when is_atom(Reason) ->
    ok = bump({dispatch_local, Reason}).

-spec drain_idle_ms() -> pos_integer().
drain_idle_ms() ->
    %% BINDING: 30 s (spec A.2 — unchanged); env seam overridable for
    %% TESTS ONLY (janus_worker_dispatch keepalive/load seam precedent)
    %% so arming eunit need not sleep a real 30 s window. Clamped
    %% >= 1 ms: a 0 would send_after(0) and void the grace window
    %% (pos_integer contract; ocr review).
    max(1, env_pos_int(os:getenv("JANUS_DRAIN_IDLE_MS"), ?DRAIN_IDLE_MS)).

%%%===================================================================
%%% Pure pool (BINDING interfaces for eunit)
%%%===================================================================

-spec new_pool([node()]) -> map().
new_pool(StickyNodes) when is_list(StickyNodes) ->
    Sticky = maps:from_list([{N, true} || N <- StickyNodes, is_atom(N)]),
    #{members => #{}, sticky => Sticky}.

-spec apply_hello(map(), node(), map()) ->
    {ack | {nack, drained | vsn | role}, map()}.
apply_hello(Pool, Node, Meta) when is_map(Pool), is_atom(Node), is_map(Meta) ->
    %% N10 / signal-fleet exclusion: only role=worker may enter the pool.
    case maps:get(role, Meta, undefined) of
        worker ->
            case maps:get(vsn, Meta, undefined) of
                ?VSN ->
                    case maps:is_key(Node, maps:get(sticky, Pool)) of
                        true ->
                            {{nack, drained}, Pool};
                        false ->
                            Region = maps:get(region, Meta, undefined),
                            %% Additive hello ingestion (spec Part 0.10): old
                            %% shapes admit with defaults (capacity=infinity,
                            %% sched_v=1, git_sha=<<"unknown">>) — the pure
                            %% function never sees raw wire garbage. The geo
                            %% egress keys (2026-10-11 D4) are stored RAW here;
                            %% the EFFECTIVE geo_region/geo_source (precedence,
                            %% age-check, mmdb mapping) is computed at ingest
                            %% time by maybe_ingest_geo/2 (do_hello).
                            Base0 = #{
                                region => Region,
                                capacity => maps:get(capacity, Meta, infinity),
                                sched_v => maps:get(sched_v, Meta, 1),
                                git_sha => maps:get(git_sha, Meta, <<"unknown">>)
                            },
                            Base = maps:merge(Base0, egress_fields(Meta)),
                            Members0 = maps:get(members, Pool),
                            case maps:find(Node, Members0) of
                                {ok, #{draining := true} = M} ->
                                    %% Ack but stay draining (not re-activated).
                                    %% A repeat (keepalive) hello refreshes
                                    %% region/capacity/sched_v/git_sha/egress
                                    %% WITHOUT resetting drain state (idempotent
                                    %% admit, spec Part 0.5; the v1 `inflight`
                                    %% field is GONE — v2.1 A.2 single-source).
                                    %% The effective geo fields survive the
                                    %% refresh (they are recomputed right after).
                                    Members1 =
                                        Members0#{Node => maps:merge(M, Base)},
                                    {ack, Pool#{members => Members1}};
                                {ok, M} ->
                                    Members1 =
                                        Members0#{Node => maps:merge(M, Base)},
                                    {ack, Pool#{members => Members1}};
                                error ->
                                    Member = maps:merge(
                                        #{draining => false}, Base
                                    ),
                                    {ack, Pool#{members => Members0#{Node => Member}}}
                            end
                    end;
                _ ->
                    {{nack, vsn}, Pool}
            end;
        _ ->
            {{nack, role}, Pool}
    end.

%% Raw egress hello keys kept on the member (geo-affinity D4): the
%% winning layer's ip/region + source + fetched_at, plus the worker's
%% gw-echo health counters (display-only). Absent keys default to
%% undefined/0 — an old worker's row reads legacy env-class.
egress_fields(Meta) when is_map(Meta) ->
    #{
        egress_ip => hello_bin(maps:get(egress_ip, Meta, undefined)),
        egress_region => hello_bin(maps:get(egress_region, Meta, undefined)),
        egress_source => hello_bin(maps:get(egress_source, Meta, undefined)),
        egress_fetched_at => hello_pos_int(maps:get(egress_fetched_at, Meta, undefined)),
        echo_ok_total => hello_pos_int(maps:get(echo_ok_total, Meta, undefined)),
        echo_fail_total => hello_pos_int(maps:get(echo_fail_total, Meta, undefined))
    }.

hello_bin(B) when is_binary(B), B =/= <<>> -> B;
hello_bin(_) -> undefined.

hello_pos_int(N) when is_integer(N), N >= 0 -> N;
hello_pos_int(_) -> 0.

%% v2.1 A.2: the drain-idle ARMING decision no longer rides the pure
%% transition (the inflight hint is gone; the conjunct reads
%% sched_reserve + sched_tracked LIVE in the gen_server — tick and
%% dirty-flush evaluation). The pure transition only flags the member
%% draining; returns whether the member EXISTED (for the workers row).
-spec apply_drain(map(), node()) -> {map(), boolean()}.
apply_drain(Pool, Node) when is_map(Pool), is_atom(Node) ->
    Members0 = maps:get(members, Pool),
    case maps:find(Node, Members0) of
        {ok, #{draining := true}} ->
            {Pool, false};
        {ok, M} ->
            Members1 = Members0#{Node => M#{draining => true}},
            {Pool#{members => Members1}, true};
        error ->
            {Pool, false}
    end.

-spec apply_nodedown(map(), node()) -> map().
apply_nodedown(Pool, Node) when is_map(Pool), is_atom(Node) ->
    Members0 = maps:get(members, Pool),
    %% Draining nodedown is NOT sticky (spec §3.4).
    Pool#{members => maps:remove(Node, Members0)}.

-spec apply_undrain(map(), node()) -> map().
apply_undrain(Pool, Node) when is_map(Pool), is_atom(Node) ->
    %% Clear sticky and drop any mid-drain member so the next hello
    %% creates a fresh non-draining entry (not "ack but stay draining").
    Sticky0 = maps:get(sticky, Pool),
    Members0 = maps:get(members, Pool),
    Pool#{
        sticky => maps:remove(Node, Sticky0),
        members => maps:remove(Node, Members0)
    }.

%% Pure drain-idle TRANSITION (draining member -> removed + sticky).
%% v2.1 A.2: the live conjunct (non-Internal tracked empty AND
%% reserve == 0) is evaluated by the gen_server BEFORE calling this —
%% both at ARMING (tick / dirty-flush) and again at FIRE time.
-spec apply_drain_idle(map(), node()) -> {map(), boolean()}.
apply_drain_idle(Pool, Node) when is_map(Pool), is_atom(Node) ->
    Members0 = maps:get(members, Pool),
    case maps:find(Node, Members0) of
        {ok, #{draining := true}} ->
            Sticky1 = maps:put(Node, true, maps:get(sticky, Pool)),
            {
                Pool#{
                    members => maps:remove(Node, Members0),
                    sticky => Sticky1
                },
                true
            };
        _ ->
            {Pool, false}
    end.

%% v1 selection over candidate pairs `[{Node, Meta}]` — the SAME input
%% shape as select_v2's knobs-off subset (`inflight`, `region`,
%% `draining`; v2.1 A.2: the CALLER supplies inflight — pick_sync reads
%% it live from sched_reserve, eunit fixtures inject it directly). The
%% v1 semantics (affinity pin -> region narrowing -> (inflight, name))
%% are restated for the equivalence eunit.
-spec select([{node(), map()}], map()) -> {ok, node()} | empty.
select(Candidates, Opts) when is_list(Candidates), is_map(Opts) ->
    case dispatchable(Candidates) of
        [] ->
            empty;
        Dispatchable ->
            AffinityNode = maps:get(affinity_node, Opts, undefined),
            RegionTag = maps:get(region_tag, Opts, undefined),
            Matched =
                case AffinityNode of
                    N when is_atom(N) ->
                        case lists:keyfind(N, 1, Dispatchable) of
                            {N, _} = Hit -> [Hit];
                            false -> []
                        end;
                    _ ->
                        []
                end,
            Chosen =
                case Matched of
                    [_ | _] ->
                        Matched;
                    [] when RegionTag =/= undefined, RegionTag =/= <<>> ->
                        case
                            [
                                {N, M}
                             || {N, M} <- Dispatchable,
                                maps:get(region, M, undefined) =:= RegionTag
                            ]
                        of
                            [] -> Dispatchable;
                            RegionHits -> RegionHits
                        end;
                    [] ->
                        Dispatchable
                end,
            least_inflight(Chosen)
    end.

-spec available(map()) -> non_neg_integer().
available(#{members := Members}) when is_map(Members) ->
    length([{N} || {N, #{draining := false}} <- maps:to_list(Members)]);
available(_) ->
    0.

-spec is_sticky(map(), node()) -> boolean().
is_sticky(Pool, Node) ->
    maps:is_key(Node, maps:get(sticky, Pool)).

-spec is_draining(map(), node()) -> boolean().
is_draining(Pool, Node) ->
    case maps:find(Node, maps:get(members, Pool)) of
        {ok, #{draining := D}} -> D;
        error -> false
    end.

-spec is_member(map(), node()) -> boolean().
is_member(Pool, Node) ->
    maps:is_key(Node, maps:get(members, Pool)).

%% Dispatchable filter over `[{Node, Meta}]` candidate pairs (works for
%% both the v1 select input and pool member pairs — both carry
%% `draining`).
dispatchable(Candidates) ->
    [
        {N, M}
     || {N, #{draining := false} = M} <- Candidates
    ].

least_inflight(Candidates) ->
    Sorted = lists:sort(
        fun({N1, #{inflight := I1}}, {N2, #{inflight := I2}}) ->
            {I1, N1} =< {I2, N2}
        end,
        Candidates
    ),
    case Sorted of
        [{N, _} | _] -> {ok, N};
        [] -> empty
    end.

%%%===================================================================
%%% Pure scheduler v2 (spec Part B — no ETS, no counters, no time)
%%%===================================================================

%% @doc Scheduler v2 selection. Input: candidate snapshot
%% `[{Node, Meta}]` where Meta carries `inflight, capacity, draining,
%% geo_region, rtt_map, observed_ewma_ms | unknown, demote_ms` (all
%% precomputed by the snapshot builder — TTL expiry already happened
%% there). Opts carry the per-request values (`provider_id,
%% affinity_node, region_tag`) and the knob flags (`geo_enabled,
%% rtt_enabled, health_enabled`).
%%
%% Output: `{Order, Decisions}` — Order is the FULL ordered node list
%% (pick iterates it for reservation; no re-selection on rollback);
%% Decisions is a plain map from which PICK emits the metrics.
%% Deterministic: identical `(snapshot, opts)` => identical output.
%%
%% Opts also carry the DECLARED pin label (`affinity_node_raw`, binary;
%% set by janus_http_worker_client from the provider row) so the
%% observability half can tell a pin MISS from "no pin": a typo'd name
%% that `binary_to_existing_atom` cannot resolve arrives as
%% `affinity_node => undefined` plus a non-empty `affinity_node_raw`
%% (§7.6 — the typo must not alias an unpinned provider). This function
%% reads the label only; it never bumps a counter.
-spec select_v2([{node(), map()}], map()) -> {[node()], decisions()}.
select_v2(Snapshot, Opts) when is_list(Snapshot), is_map(Opts) ->
    Candidates = dispatchable_snapshot(Snapshot),
    Affinity = maps:get(affinity_node, Opts, undefined),
    case Affinity of
        Node when is_atom(Node), Node =/= undefined ->
            case lists:keyfind(Node, 1, Candidates) of
                {Node, _} ->
                    %% Tier 2 — affinity pin is ABSOLUTE (operator
                    %% intent): that node only, ignoring health/geo
                    %% tiers; geo_source := none (no undefined emit).
                    %% The reserve loop still increments its counter
                    %% but never refuses it (soft cap).
                    {[Node], #{
                        geo_source => none,
                        demoted => [],
                        affinity => honoured,
                        affinity_pin => affinity_label(Opts, Node)
                    }};
                false ->
                    %% Pinned node absent/draining => continue down the
                    %% tiers (v1 affinity-miss path) — fail-open stays;
                    %% the miss is REPORTED, never refused.
                    affinity_decisions(Candidates, Opts, miss)
            end;
        _ ->
            %% Unresolvable declared pin (typo / atom not in this VM)
            %% reads `undefined` here but still MISSES with a label;
            %% a truly unpinned provider emits `none`.
            case pin_declared(Opts) of
                true -> affinity_decisions(Candidates, Opts, miss);
                false -> affinity_decisions(Candidates, Opts, none)
            end
    end.

%% Tag the tier result with the affinity outcome. `tiers/2' returns
%% `{Order, Decisions}', so the tag lands INSIDE the decisions map —
%% the Order list (and therefore every pick semantic) is untouched.
affinity_decisions(Candidates, Opts, Outcome) ->
    {Order, Decisions} = tiers(Candidates, Opts),
    Pin =
        case Outcome of
            miss -> declared_pin(Opts);
            none -> undefined
        end,
    {Order, Decisions#{affinity => Outcome, affinity_pin => Pin}}.

%% A pin is DECLARED when the provider row carried a non-empty
%% `affinity_node` — even when it could not become an atom.
pin_declared(Opts) ->
    declared_pin(Opts) =/= undefined.

declared_pin(Opts) ->
    case maps:get(affinity_node_raw, Opts, undefined) of
        Raw when is_binary(Raw), Raw =/= <<>> -> Raw;
        _ -> undefined
    end.

%% Label for the honoured case: the declared label when there is one,
%% else the resolved atom (a direct-v1 caller that passes only
%% `affinity_node` still gets a bounded label).
affinity_label(Opts, Node) ->
    case declared_pin(Opts) of
        undefined -> atom_to_binary(Node, utf8);
        Pin -> Pin
    end.

tiers(Candidates, Opts) ->
    {Healthy, Demoted} = health_tier(Candidates, Opts),
    {Narrowed, GeoSource} = geo_tier(Healthy, Opts),
    Order = sort_tier(Narrowed, Opts),
    {Order, #{geo_source => GeoSource, demoted => Demoted}}.

%% Tier 1 — dispatchable (snapshot view; the live re-check happens at
%% reservation).
dispatchable_snapshot(Snapshot) ->
    [{N, M} || {N, #{draining := false} = M} <- Snapshot, is_atom(N)].

%% Tier 3 — health demotion (BEFORE geo — pathology outranks
%% preference; gated by health_enabled). Exclude iff
%% `is_number(E) andalso E > demote_ms` — the atom-vs-number ordering
%% trap (`unknown > 5000` is TRUE in term order) is closed by the
%% guard; `demote_ms = infinity` (single-worker fleet / no other
%% measured candidate) never trips (`number > infinity` is simply
%% `false`, never an error). Never-shed-all: suppression emits NOTHING
%% into Decisions.demoted (only ACTUAL exclusions are listed).
health_tier(Candidates, Opts) ->
    case maps:get(health_enabled, Opts, false) of
        true ->
            Sick = [N || {N, M} <- Candidates, demoted_by_health(M)],
            Keep = [C || {N, _} = C <- Candidates, not lists:member(N, Sick)],
            case Keep of
                [] -> {Candidates, []};
                _ -> {Keep, Sick}
            end;
        false ->
            {Candidates, []}
    end.

demoted_by_health(M) when is_map(M) ->
    E = maps:get(observed_ewma_ms, M, unknown),
    D = maps:get(demote_ms, M, infinity),
    is_number(E) andalso E > D.

%% Tier 4 — geo preference (narrowing, NOT exclusion). The legacy
%% region_tag comparator is UNGATED v1 behavior; only the auto
%% comparator is gated by geo_enabled. The tier applies ONLY when the
%% comparator is known AND the candidate's geo_region is known AND
%% they are EQUAL (unknown-vs-unknown never matches — explicit guard).
%% ANY matching candidates => keep only them; else keep all with
%% source `none` (a pick partition: pinned / no-comparator / no-match).
geo_tier(Candidates, Opts) ->
    case geo_comparator(Opts) of
        {undefined, none} ->
            {Candidates, none};
        {Tag, Source} when is_binary(Tag) ->
            Hits = [
                C
             || {_, M} = C <- Candidates,
                known_tag(maps:get(geo_region, M, undefined)) andalso
                    maps:get(geo_region, M, undefined) =:= Tag
            ],
            case Hits of
                [] -> {Candidates, none};
                _ -> {Hits, Source}
            end
    end.

geo_comparator(Opts) ->
    RegionTag = maps:get(region_tag, Opts, undefined),
    case known_tag(RegionTag) of
        true ->
            {RegionTag, region_tag};
        false ->
            case maps:get(geo_enabled, Opts, false) of
                true ->
                    ProviderGeo = maps:get(provider_geo, Opts, unknown),
                    case known_tag(ProviderGeo) of
                        true -> {ProviderGeo, auto};
                        false -> {undefined, none}
                    end;
                false ->
                    {undefined, none}
            end
    end.

known_tag(B) when is_binary(B), B =/= <<>> ->
    true;
known_tag(_) ->
    false.

%% Tier 5 — sort by `{rtt_key, inflight, name}`.
%%
%% rtt_key is `rtt_map[provider_id]` for a MEASURED node. An UNMEASURED
%% node keys on the FASTEST measured value, deliberately not the median.
%%
%% COLD-START (2026-10-30): an unmeasured node used to key on `infinity`,
%% so it sorted after every measured node and never received the request
%% that would have produced its first sample — a freshly added worker sat
%% at dispatched=0 until unrelated load pushed the fleet into
%% `capacity_exhausted`.
%%
%% The median is NOT enough to fix that: rtt_key is the PRIMARY sort
%% element, so a median-keyed node still ranks behind every node faster
%% than the median at ANY inflight (a single fast node with spare
%% capacity keeps taking all traffic). Keying it on the fleet minimum
%% instead makes it jointly-fastest, so `inflight` decides and it gets
%% load — and therefore its first samples — immediately. The optimism is
%% self-correcting: once real samples land, the node keys on its true
%% value.
%%
%% `rtt_enabled = false` skips the computation entirely and keys every
%% candidate on `infinity`, which reduces the sort to exactly v1's
%% `(inflight, name)`.
sort_tier(Candidates, Opts) ->
    RttOn = maps:get(rtt_enabled, Opts, false) =:= true,
    ProviderId = maps:get(provider_id, Opts, undefined),
    %% With the knob OFF the rtt element is dropped ENTIRELY rather than
    %% set to a shared sentinel: rtt_map is populated from the ?RTT
    %% table regardless of the knob (passive writes are not gated), so
    %% "fall back to infinity" would still let a measured candidate key
    %% on its real rtt and the sort would NOT reduce to v1. The key is
    %% therefore built in two shapes.
    Keyed =
        case RttOn of
            false ->
                [{sort_key_plain(M, N), N} || {N, M} <- Candidates];
            true ->
                Fallback = optimism_key(Candidates, ProviderId),
                [{sort_key_rtt(ProviderId, Fallback, M, N), N} || {N, M} <- Candidates]
        end,
    [N || {_Key, N} <- lists:sort(Keyed)].

rtt_key(ProviderId, M) ->
    maps:get(ProviderId, maps:get(rtt_map, M, #{}), undefined).

%% The cold-start key handed to candidates that are unmeasured but CAN
%% still be measured: the fastest value anyone reports, so a fresh node
%% is treated as possibly-fastest rather than assumed slowest.
%%
%% Only sampling-capable members are considered, and only they receive
%% it — a member that will never report rtt_ms (sched_v < 2, or samples
%% dropped by clamp_rtt/1) must not hold the lead forever. With no
%% capable candidate the fallback is `infinity`, which for an
%% all-old-version fleet is the pre-change behaviour.
optimism_key(Candidates, ProviderId) ->
    case [
        R
     || {_N, M} <- Candidates,
        maps:get(can_sample, M, true),
        R <- [rtt_key(ProviderId, M)],
        is_number(R)
    ] of
        [] -> infinity;
        Known -> lists:min(Known)
    end.

%% v1 shape: (inflight, name).
sort_key_plain(M, N) ->
    {maps:get(inflight, M, 0), N}.

sort_key_rtt(ProviderId, Fallback, M, N) ->
    RttKey =
        case rtt_key(ProviderId, M) of
            R when is_number(R) ->
                R;
            _ ->
                %% An unmeasured node that can never be measured gets no
                %% optimism: it ranks last, exactly as before, instead
                %% of leading the order forever.
                case maps:get(can_sample, M, true) of
                    true -> Fallback;
                    false -> infinity
                end
        end,
    {RttKey, maps:get(inflight, M, 0), N}.

%%%===================================================================
%%% Pure scheduler v2 math (spec A.3/A.4/0.3 — eunit seams)
%%%===================================================================

%% @doc EWMA step (alpha 0.25, SEEDS AT THE FIRST SAMPLE — `E1 = x1`;
%% seeded-at-0 would make three identical 8000 ms samples read 4625 ms
%% < the 5000 demotion floor, spec A.4).
-spec ewma_step(none | {number(), non_neg_integer()}, number()) ->
    {number(), non_neg_integer()}.
ewma_step(none, X) when is_number(X) ->
    {X, 1};
ewma_step({E, Count}, X) when is_number(E), is_number(X) ->
    {E + ?EWMA_ALPHA * (X - E), Count + 1}.

%% @doc Selection admission: the EWMA value enters the snapshot only
%% at >= 3 samples (`unknown` below — rendered structurally so the
%% is_number health guard excludes naturally; new workers are never
%% demoted). The /stats DISPLAY gauge shows the raw value from sample
%% 1 (B2).
-spec observed_ewma(none | {number(), non_neg_integer()}) -> number() | unknown.
observed_ewma({E, Count}) when Count >= ?EWMA_MIN_SAMPLES, is_number(E) ->
    E;
observed_ewma(_) ->
    unknown.

%% @doc Per-candidate EXCLUDE-SELF demotion threshold (spec A.4):
%% `max(5000, 3 x median(observed EWMAs of the OTHER candidates having
%% >= 3 samples))`, requiring >= 1 other measured candidate (else
%% infinity — tier inert; single-worker fleets are health-inert by
%% design). Precomputed into each candidate's snapshot Meta by the
%% builder => pick-time determinism.
-spec demote_ms(node(), map()) -> number() | infinity.
demote_ms(Node, Ewma) when is_map(Ewma) ->
    Others = [
        E
     || {N, {E, Count}} <- maps:to_list(Ewma),
        N =/= Node,
        Count >= ?EWMA_MIN_SAMPLES,
        is_number(E)
    ],
    case Others of
        [] ->
            infinity;
        _ ->
            max(?DEMOTE_FLOOR_MS, ?DEMOTE_FACTOR * median(Others))
    end.

%% @doc Statistics-median semantics (even N averages the two middles),
%% written out — no stdlib ambiguity (spec A.4).
-spec median([number()]) -> number().
median(Values) when is_list(Values), Values =/= [] ->
    Sorted = lists:sort(Values),
    N = length(Sorted),
    case N band 1 of
        1 -> lists:nth((N + 1) div 2, Sorted);
        0 -> (lists:nth(N div 2, Sorted) + lists:nth(N div 2 + 1, Sorted)) / 2
    end.

%% @doc RTT clamp (spec Part 0.3, applied at MASTER ingest): numeric
%% `0 =< x =< 600000` accepted (integer or float, stored as float — an
%% integer 0 lands as 0.0); `x > 600000` CLAMPED DOWN (not dropped);
%% negative / non-finite dropped (counted by the caller under
%% `sched_rtt_dropped_total{reason}`).
-spec clamp_rtt(term()) -> {ok, float()} | {drop, negative | non_finite}.
clamp_rtt(X) when is_number(X), X < 0 ->
    {drop, negative};
clamp_rtt(X) when is_number(X), X > ?RTT_MAX_MS ->
    {ok, ?RTT_MAX_MS * 1.0};
clamp_rtt(X) when is_number(X) ->
    {ok, float(X)};
clamp_rtt(_NonFinite) ->
    {drop, non_finite}.

%% @doc Advisory divergence predicate (spec Part 0.3): both sides
%% >= 100 ms and the ratio between them > 3 (either direction — the
%% worker reports upstream-only while the master observes TTFB, so the
%% comparison is a signal, NEVER a selector).
-spec report_divergent(term(), term()) -> boolean().
report_divergent(Reported, Observed) when
    is_number(Reported),
    is_number(Observed),
    Reported >= ?DIVERGENCE_FLOOR_MS,
    Observed >= ?DIVERGENCE_FLOOR_MS
->
    max(Reported, Observed) / min(Reported, Observed) > ?DIVERGENCE_RATIO;
report_divergent(_Reported, _Observed) ->
    false.

%% @doc Divergence window state machine (pure, time-parameterized): a
%% window opens at the first divergent report and fires ONCE per
%% sustained `WindowMs` (then re-arms — sustained divergence keeps
%% counting); a non-divergent report clears it (nodedown clears it in
%% `do_nodedown`).
-spec advance_divergence(none | map(), boolean(), integer(), pos_integer()) ->
    {boolean(), none | map()}.
advance_divergence(_Old, false, _Now, _WindowMs) ->
    {false, none};
advance_divergence(none, true, Now, _WindowMs) ->
    {false, #{since => Now}};
advance_divergence(#{since := Since}, true, Now, WindowMs) when Now - Since >= WindowMs ->
    {true, #{since => Now}};
advance_divergence(Window, true, _Now, _WindowMs) ->
    {false, Window}.

%%%===================================================================
%%% Geo-affinity pure logic (spec 2026-10-11 D4/D15/D18 — eunit seams)
%%%===================================================================

%% Effective member geo from the ingested hello fields. Precedence is
%% the WORKER's chain outcome (the winning layer rides the hello — the
%% default chain order IS the precedence); the master only maps:
%%   - gw_echo / third_echo: egress_ip -> resolver (mmdb on the
%%     master; out-of-vocab => `other`). Resolver `unknown` keeps
%%     geo_source but yields NO region (the layer outranks env — an
%%     env fallback here would silently undo the ranking).
%%   - metadata / env: egress_region verbatim (metadata is vocab-mapped
%%     and env out-of-vocab-warned worker-side already).
%%   - legacy hellos (region key only, no egress keys): env-class.
%%   - STALE rows (older than the retain window): the entry reads
%%     absent — a stale IP never sticks (D18) — degrading to the
%%     legacy env-class view exactly like an egress-less hello.
%%     `unset` when no layer at all (v1 behavior, D17).
%% ResolveIp :: fun((binary()) -> {ok, binary()} | unknown).
-spec effective_geo(map(), integer(), pos_integer(), fun()) ->
    {binary() | undefined, geo_source()}.
effective_geo(Member, NowSec, RetainSec, ResolveIp) when
    is_map(Member), is_integer(NowSec), is_integer(RetainSec), RetainSec >= 1, is_function(ResolveIp, 1)
->
    EnvRegion = norm_geo_bin(maps:get(region, Member, undefined)),
    Source = source_atom(maps:get(egress_source, Member, undefined)),
    FetchedAt = maps:get(egress_fetched_at, Member, undefined),
    Fresh = is_integer(FetchedAt) andalso janus_worker_geo:fresh(FetchedAt, NowSec, RetainSec),
    case Source of
        undefined ->
            env_class(EnvRegion);
        _ when not Fresh ->
            env_class(EnvRegion);
        gw_echo ->
            ip_class(Source, maps:get(egress_ip, Member, undefined), ResolveIp);
        third_echo ->
            ip_class(Source, maps:get(egress_ip, Member, undefined), ResolveIp);
        metadata ->
            region_class(Source, maps:get(egress_region, Member, undefined));
        env ->
            region_class(env, maps:get(egress_region, Member, undefined));
        _Other ->
            env_class(EnvRegion)
    end.

env_class(EnvRegion) when is_binary(EnvRegion) ->
    {EnvRegion, env};
env_class(_) ->
    {undefined, unset}.

ip_class(Source, IpBin, ResolveIp) when is_binary(IpBin), IpBin =/= <<>> ->
    case ResolveIp(IpBin) of
        {ok, TagBin} when is_binary(TagBin), TagBin =/= <<>> -> {TagBin, Source};
        _ -> {undefined, Source}
    end;
ip_class(Source, _BadIp, _ResolveIp) ->
    {undefined, Source}.

region_class(Source, RegionBin) when is_binary(RegionBin), RegionBin =/= <<>> ->
    {RegionBin, Source};
region_class(Source, _BadRegion) ->
    {undefined, Source}.

norm_geo_bin(B) when is_binary(B), B =/= <<>> -> B;
norm_geo_bin(_) -> undefined.

source_atom(<<"gw_echo">>) -> gw_echo;
source_atom(<<"metadata">>) -> metadata;
source_atom(<<"env">>) -> env;
source_atom(<<"third_echo">>) -> third_echo;
source_atom(_) -> undefined.

%% Edge-triggered mismatch state machine (spec D4, r10 pin): fires per
%% (node, source-pair) — the second layer is always the env region the
%% hello also carries. Mismatch = the winning layer is NOT env AND both
%% regions are known AND they differ. Bump ONLY on TRANSITION into
%% mismatch (previous state agreed, single-layer, or a DIFFERENT
%% source pair); steady disagreement keeps the gauge set and never
%% floods the counter. State lives in PT keyed by node (survives worker
%% restarts; master VM restart clears it — documented reset-duplicate).
%% Returns {Bump, Gauge, NewState}.
-spec mismatch_step(
    none | {geo_source(), boolean()},
    geo_source(),
    binary() | undefined,
    binary() | undefined
) -> {boolean(), boolean(), {geo_source(), boolean()}}.
mismatch_step(Prev, Source, GeoRegion, EnvRegion) ->
    Mis =
        Source =/= env andalso
            is_binary(GeoRegion) andalso is_binary(EnvRegion) andalso
            GeoRegion =/= EnvRegion,
    {PrevSource, PrevMis} =
        case Prev of
            {S, M} when is_atom(S), is_boolean(M) -> {S, M};
            none -> {undefined, false}
        end,
    Bump = Mis andalso (not PrevMis orelse PrevSource =/= Source),
    {Bump, Mis, {Source, Mis}}.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    ok = boot_knobs(),
    case boot_wire_enc() of
        {stop, _} = Stop ->
            Stop;
        ok ->
            Adopted = ensure_sched_tables(),
            Sticky = load_sticky(),
            _ = maybe_monitor_nodes(),
            %% Immediate post-adopt reconcile (spec Part 0.5): resets already
            %% applied on adopt; empty at a cold boot.
            State0 = reconcile(now_mono(), #state{pool = new_pool(Sticky)}),
            %% Initial publication: an idle fleet publishes {candidates, []};
            %% pick then lands in the empty_pool local-fallback path.
            State1 = republish(State0),
            logger:info(#{
                what => janus_worker_pool_started,
                sticky_count => length(Sticky),
                adopted_tables => Adopted,
                knobs => knobs()
            }),
            {ok, arm_tick(State1)}
    end.

%% Wire compression boot wiring (spec 2026-10-12-wire-compression
%% D10/D11, master side): delegates to the SHARED
%% `janus_wire_enc:boot/1` (ocr review dedup — master and worker stay
%% in lockstep) with the master's role gate: JANUS_WIRE_ENC (D11's
%% JANUS_UPSTREAM_ENC disjunct lands with PR2 as
%% `WireEnabled orelse UpstreamEnabled`). A default-OFF node never
%% refuses boot; a master that ADVERTISES must know its inflate works
%% at boot — an early inflate-fail after nodeup would otherwise
%% masquerade as a worker bug in logs (D11 rationale).
-spec boot_wire_enc() -> ok | {stop, term()}.
boot_wire_enc() ->
    %% PR2 disjunct (D11): the master also decodes upstream gzip on the
    %% local-fallback path — JANUS_UPSTREAM_ENC gates the self-check
    %% even when the internal-hop knob is off.
    Upstream = janus_wire_enc:upstream_enc_enabled(),
    janus_wire_enc:boot(
        maps:get(enabled, janus_wire_enc:env_config(), false) orelse Upstream
    ).

handle_call({pick_sync, Opts}, _From, #state{pool = Pool} = State) ->
    %% v1 gen_server selection over live state (kept for tests). v2.1
    %% A.2: member.inflight is GONE — the candidate list is built with
    %% a LIVE reserve read per node (the same source pick/1 uses).
    {reply, select(v1_candidates(Pool), Opts), State};
handle_call(available, _From, #state{pool = Pool} = State) ->
    {reply, available(Pool), State};
handle_call(sched_stats, _From, State) ->
    %% Atomic /stats/sched source view (see sched_stats/0): counters +
    %% knobs + display EWMA + raw public-table rows.
    {reply, sched_stats_map(State), State};
handle_call({undrain, Node}, _From, #state{pool = Pool} = State) ->
    ok = sticky_delete(Node),
    Pool1 = apply_undrain(Pool, Node),
    %% Member dropped: remove the live drain row — a missing row
    %% refuses picks until the node re-hellos.
    _ = ets:delete(?WORKERS, Node),
    State1 = cancel_timer(Node, State#state{pool = Pool1}),
    {reply, ok, mark_dirty(State1)};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({note_inflight, Node, _Delta}, State) ->
    %% v2.1 A.2: COUNTED NO-OP — the master-side dual-track accounting
    %% is retired (the reserve counter is the ONE live count; the cast
    %% is master-internal and belt-and-braces only: an old beam's stray
    %% cast bumps the deprecation counter, never state).
    ok = bump(note_inflight_deprecated),
    _ = Node,
    {noreply, State};
%% -- Scheduler v2 `{sched, 2, _}` casts (spec Part 0.11 / A.3 / A.4).
%% Sent via gen_server:cast => an older master's catch-all below drops
%% and counts them (delivery-class tolerance, spec Part 0.10). --
%% v2.1 B.1: {track,...} and {release,...} are GONE (caller-side ETS
%% writes in pick/release; an old beam's stragglers fall to the
%% counting catch-all below — pool + master sessions restart together).
handle_cast({sched, 2, {touched, Node}}, State) when is_atom(Node) ->
    %% v2.1 B.1 COMPLETION POKE: caller-side ETS writes mark nothing
    %% dirty — the release path casts this after take+decrement so the
    %% <= 250 ms dirty-flush re-evaluates drain-idle arming (A.2). One
    %% message per job COMPLETION (v2's release-cast rate; the PICK hot
    %% path stays mailbox-free); fully quiet nodes are tick-bounded.
    {noreply, mark_dirty(State)};
handle_cast({sched, 2, {ttfb, JobRef, ElapsedMs}}, State) ->
    %% Health feed (spec A.4): successful NON-INTERNAL completions only
    %% (the caller filters; the tracked Internal flag is re-checked
    %% defensively — probes never feed the health EWMA). Pinned-path
    %% completions feed it exactly like unpinned ones (real jobs).
    %% v2.1 B.1: the tracked row is read from `sched_tracked` (the
    %% gen_server state no longer mirrors it).
    case tracked_row(JobRef) of
        {Node, _At, _ProviderId, false} when is_number(ElapsedMs) ->
            Ewma1 = maps:put(
                Node,
                ewma_step(maps:get(Node, State#state.ewma, none), ElapsedMs),
                State#state.ewma
            ),
            {noreply, mark_dirty(State#state{ewma = Ewma1})};
        _ ->
            {noreply, State}
    end;
handle_cast({sched, 2, {rtt, JobRef, RttMs}}, State) ->
    %% Canonical PASSIVE writer (the done/error rtt_ms piggyback, spec
    %% A.3): last-arrival-wins bounded by the 10-min TTL, EWMA stepped
    %% INCREMENTALLY (v2.1 B.2). Internal (probe) and post-purge jobs
    %% are SKIPPED at ingest (seam 2, spec E.6) — never written, never
    %% counted.
    case tracked_row(JobRef) of
        {Node, _At, ProviderId, false} ->
            ok = write_passive_rtt(Node, ProviderId, RttMs);
        _ ->
            ok
    end,
    {noreply, mark_dirty(State)};
handle_cast({sched, 2, {load, Node, Info}}, State) when is_atom(Node) ->
    %% Advisory load (spec Part 0.3): ops display + divergence window
    %% only — NEVER a selection input.
    {noreply, do_load(Node, Info, State)};
handle_cast({sched, 2, {probe, _JobSpec}}, State) ->
    %% Pool-INTERNAL probe trigger (spec Part 0.2): the 30 s tick
    %% self-casts this; consumed here behind dispatch_probe/2. The knob
    %% is re-checked (probes are money — a stray external cast with the
    %% knob off is a silent no-op, never a spend).
    case probe_enabled() of
        true -> {noreply, do_probe(State)};
        false -> {noreply, State}
    end;
handle_cast({sched, 2, {suspect, JobRef}}, State) ->
    %% Worker-capacity-override spec Part 2: a timeout arm already
    %% called mark_dead/1 and flushed the job. The pool resolves the
    %% node from the tracked row it still holds — the reservation
    %% stays, but the load figure now excludes it (reserve - suspect).
    %% A cast for an already-released purged row (no tracked row,
    %% or the inactivity arm's pre-released path) is a safe no-op:
    %% no tracked row → no node → nothing to mark.
    case tracked_row(JobRef) of
        {Node, _At, _ProviderId, false} ->
            %% Internal rows (probes) never reach the suspect path —
            %% they never hold a reservation. Only non-Internal rows.
            New = ets:insert_new(?SUSPECT, {JobRef, Node}),
            New andalso bump_suspect(Node),
            %% Re-validate: a concurrent caller-side release (release/1 ->
            %% take_and_maybe_decrement/1) can take the tracked row between
            %% the lookup above and this insert. That release already ran
            %% clear_suspect/1 and found nothing, so the entry just written
            %% would be an orphan — it would suppress this node's load
            %% figure with no reservation behind it until the next
            %% reconcile tick, and no take path would ever clear it.
            case ets:member(?TRACKED, JobRef) of
                true -> ok;
                false -> clear_suspect(JobRef)
            end,
            ok = bump(suspect_mark);
        _ ->
            ok
    end,
    %% Mark dirty: the suspect count changed the load figure visible
    %% in the snapshot and dashboard — republish within 250 ms.
    {noreply, mark_dirty(State)};
handle_cast({sched, 2, capacity_changed}, State) ->
    %% worker-capacity-override spec Part 1 ("Read path"): a settings
    %% write publishes `{janus, worker_capacity_cfg}` then pokes the
    %% pool so `build_snapshot/1` republishes on the <= 250 ms
    %% dirty-flush instead of waiting for the 30 s tick or an
    %% unrelated worker event. The pool re-reads PT at republish
    %% time, so no state field is needed.
    {noreply, mark_dirty(State)};
handle_cast({sched, 2, Unknown}, State) ->
    %% Unknown `{sched, 2, _}` inner tag (a newer worker's load/probe
    %% cast against this master): dropped + counted.
    ok = bump({sched_unknown, inner_tag(Unknown)}),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sched_flush, State) ->
    %% Dirty-flush path: republish at most every FLUSH_MS. v2.1 A.2:
    %% EVERY republish re-evaluates drain-idle arming (the {touched}
    %% poke marks dirty after a COMPLETION — the <= 250 ms bound;
    %% fully quiet nodes are tick-bounded, 30 s).
    case State#state.dirty of
        true -> {noreply, eval_drain_idle(republish(State#state{dirty = false}))};
        false -> {noreply, State}
    end;
handle_info(sched_tick, State) ->
    %% 30 s periodic tick (spec Part C): republishes UNCONDITIONALLY
    %% (TTL expiry + reserve reconciliation are real on an idle fleet)
    %% and runs maintenance. BOTH flush paths advance snapshot_gen.
    %% Probe eligibility is evaluated when the probe knob is on (spec
    %% Part 0.2): the tick self-casts {sched, 2, {probe, JobSpec}} —
    %% a POOL-INTERNAL trigger consumed by the handle_cast clause
    %% behind dispatch_probe/2 (the message class exists exactly as
    %% pinned; an old pool would drop+count it via the catch-all).
    State1 = reconcile(now_mono(), State),
    State2 = eval_drain_idle(republish(maybe_kick_probe(State1))),
    {noreply, arm_tick(State2)};
handle_info({janus_job_ack, JobRef, WorkerSessionPid}, State) when is_pid(WorkerSessionPid) ->
    %% Probe ack (the pool is the master session ONLY for internal
    %% probes; agent jobs ack to their own session processes). The ack
    %% deadline timer keeps running — {probe_ack_timeout, JobRef}
    %% re-validates the Acked flag, so no timer bookkeeping is needed.
    {noreply, probe_ack(JobRef, State)};
handle_info({probe_ack_timeout, JobRef}, State) ->
    %% Ack-miss ABORT (spec Part 0.2): defensive cancel to the worker
    %% dispatch, tracked entry removed WITHOUT decrement (the Internal
    %% skip — probes never incremented), in-flight cleared,
    %% probe_skip{send_fail}. NO local fallback for internal jobs — a
    %% master-side probe execution measures nothing.
    case maps:find(JobRef, State#state.probe_sent) of
        {ok, {Node, _ProviderId, _SentAt, false}} ->
            ok = probe_cancel(Node, JobRef),
            ok = bump({probe_skip, send_fail}),
            logger:warning(#{
                what => janus_sched_probe_ack_timeout,
                node => Node,
                job_ref => binary:encode_hex(JobRef)
            }),
            {noreply, probe_clear(JobRef, Node, State)};
        _ ->
            %% Acked in time, already completed, or post-abort: no-op.
            {noreply, State}
    end;
handle_info({janus_done, JobRef, _DoneFields}, State) ->
    %% Probe completion (internal jobs report like any job — spec
    %% A.3). RTT = master-measured elapsed since dispatch send (a
    %% cold-start stand-in; Task C adds the worker-measured value via
    %% the load cast). probe_total{provider} counts the ATTEMPTED
    %% probe that completed.
    case maps:find(JobRef, State#state.probe_sent) of
        {ok, {Node, ProviderId, SentAt, _Acked}} ->
            Elapsed = max(0, now_mono() - SentAt),
            ok = write_probe_rtt(Node, ProviderId, Elapsed),
            ok = bump({probe, ProviderId}),
            {noreply, mark_dirty(probe_clear(JobRef, Node, State))};
        error ->
            %% Not a probe (agent jobs never report to the pool) or a
            %% post-abort late done: dropped.
            {noreply, State}
    end;
handle_info({janus_error, JobRef, _Err}, State) ->
    %% Probe error completion: clear maps, count the attempted probe,
    %% NO rtt row (spec Part 0.2 — an errored probe wrote nothing).
    case maps:find(JobRef, State#state.probe_sent) of
        {ok, {Node, ProviderId, _SentAt, _Acked}} ->
            ok = bump({probe, ProviderId}),
            {noreply, probe_clear(JobRef, Node, State)};
        error ->
            {noreply, State}
    end;
handle_info({'ETS-TRANSFER', Tab, _FromPid, _GiftData}, State) ->
    %% Always delivered by janus_ets_heir:adopt/1 (OTP semantics); the
    %% authoritative hand-back was the adopt reply.
    logger:debug(#{what => janus_worker_pool_ets_transfer, table => Tab}),
    {noreply, State};
handle_info({janus_worker_hello, From, Node, Meta}, State) when is_pid(From), is_atom(Node) ->
    {noreply, do_hello(From, Node, Meta, State)};
handle_info({janus_worker_drain, Node}, State) when is_atom(Node) ->
    {noreply, do_drain(Node, State)};
handle_info({drain_idle, Node}, State) when is_atom(Node) ->
    {noreply, do_drain_idle(Node, State)};
handle_info({nodedown, Node}, State) ->
    {noreply, do_nodedown(Node, State)};
handle_info({nodedown, Node, _Info}, State) ->
    {noreply, do_nodedown(Node, State)};
handle_info({nodeup, _Node}, State) ->
    {noreply, State};
handle_info({nodeup, _Node, _Info}, State) ->
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal — gen_server actions
%%%===================================================================

do_hello(From, Node, Meta, #state{pool = Pool} = State) ->
    {Verdict, Pool1} = apply_hello(Pool, Node, normalize_hello_meta(Node, Meta)),
    case Verdict of
        ack ->
            %% The ack/nack identify the MASTER (node()) — the worker's
            %% receive guard matches them against its own master_node.
            %% Sending the WORKER's node here (the pre-2026-10-11 shape)
            %% never matched in a real cluster: the worker stayed in the
            %% 1 s hello retry loop forever (keepalive/load cadence and
            %% the geo discovery piggyback never armed; single-node eunit
            %% masked it — both names coincide there). Caught by the
            %% geo-affinity mw gate (G.14).
            %%
            %% Wire compression (spec 2026-10-12-wire-compression F1/
            %% D10): the ack advertises `wire_enc => [zlib]` ONLY while
            %% the master's own JANUS_WIRE_ENC gate is on (boot-
            %% snapshotted). Env off => plain /1 ack (old shape — old
            %% workers unaffected, new workers stay identity).
            From ! wire_enc_ack(node()),
            %% Maintain the live drain-flag row (spec Part 0.6): a
            %% draining member keeps its true flag ("ack but stay
            %% draining"); a fresh admit writes `false`.
            _ = ets:insert(?WORKERS, {Node, is_draining(Pool1, Node)}),
            Pool2 = maybe_ingest_geo(Node, Pool1),
            %% A hello is the node being stably back — clear its flap
            %% window so a LATER isolated nodedown logs as a first.
            mark_dirty(maybe_knobs_off_guard(State#state{
                pool = Pool2,
                flap = maps:remove(Node, State#state.flap)
            }));
        {nack, Reason} ->
            case janus_worker_wire:hello_nack(node(), Reason) of
                {ok, Nack} ->
                    From ! Nack;
                {error, WireErr} ->
                    logger:error(#{
                        what => janus_worker_pool_hello_nack_failed,
                        node => Node,
                        reason => Reason,
                        wire => WireErr
                    })
            end,
            State#state{pool = Pool1}
    end.

%% Wire compression advertisement (F1/D10): gated on the master's own
%% env (role-aware: the master gates the ack, the worker gates the
%% compression — both sides on for compressed traffic).
wire_enc_ack(MasterNode) ->
    case maps:get(enabled, janus_wire_enc:env_config(), false) of
        true -> janus_worker_wire:hello_ack(MasterNode, #{wire_enc => [zlib]});
        false -> janus_worker_wire:hello_ack(MasterNode)
    end.

%% Geo-affinity ingest (spec 2026-10-11 D4/D15/D18 — MASTER side).
%% Computes the member's EFFECTIVE geo_region/geo_source from the raw
%% hello egress keys (age-checked against the retain window; IP-bearing
%% winners resolve through janus_geo's mmdb on THIS node) and runs the
%% edge-triggered geo_mismatch state machine. Runs ONLY while the
%% worker-geo overlay knob was requested at boot (JANUS_SCHED_WORKER_GEO,
%% default OFF — knob-off ingest keeps the v1 legacy region view).
maybe_ingest_geo(Node, #{members := Members} = Pool) ->
    %% Gate: the scheduling knob OR the member already carrying egress
    %% data (a manual worker_geo_refresh reports fresh egress fields the
    %% operator expects to SEE — geo_source/geo_region are display fields
    %% here; selection behavior stays gated on its own knob in select_v2).
    case maps:find(Node, Members) of
        {ok, Member} when is_map(Member) ->
            case worker_geo_on() orelse has_egress(Member) of
                false ->
                    Pool;
                true ->
                    NowSec = erlang:system_time(second),
                    {GeoRegion, GeoSource} = effective_geo(
                        Member, NowSec, janus_worker_geo:retain_sec(), fun geo_resolver/1
                    ),
                    {Bump, Mis, NewPair} = mismatch_step(
                        last_geo_state(Node),
                        GeoSource,
                        GeoRegion,
                        norm_geo_bin(maps:get(region, Member, undefined))
                    ),
                    ok = store_last_geo_state(Node, NewPair),
                    case Bump of
                        true ->
                            logger:warning(#{
                                what => janus_geo_mismatch,
                                node => Node,
                                geo_source => GeoSource,
                                geo_region => GeoRegion,
                                env_region => maps:get(region, Member, undefined)
                            }),
                            ok = bump({geo_mismatch, Node});
                        false ->
                            ok
                    end,
                    Pool#{
                        members => Members#{
                            Node => Member#{
                                geo_region => GeoRegion,
                                geo_source => GeoSource,
                                geo_mismatch => Mis,
                                egress_fetched_at => maps:get(
                                    egress_fetched_at, Member, undefined
                                )
                            }
                        }
                    }
            end;
        _ ->
            Pool
    end;
maybe_ingest_geo(_Node, Pool) ->
    Pool.

%% A member reports egress data when any raw egress key is present with
%% a value (a manual worker_geo_refresh stores them even with the
%% scheduling knob off).
has_egress(Member) ->
    lists:any(
        fun(K) -> maps:get(K, Member, undefined) =/= undefined end,
        [egress_source, egress_region, egress_ip]
    ).

geo_resolver(IpBin) ->
    try
        janus_geo:resolve_ip(IpBin)
    catch
        _:_ -> unknown
    end.

worker_geo_on() ->
    try
        janus_geo:worker_geo_requested()
    catch
        _:_ -> false
    end.

%% Edge-trigger state (PT keyed by node — survives worker restarts;
%% nodedown-cleaned below; master VM restart clears it: the first
%% mismatch after restart bumps once more, the documented duplicate).
last_geo_state(Node) ->
    try
        case persistent_term:get(?PT_LAST_GEO_SOURCE, #{}) of
            #{Node := {S, M}} when is_atom(S), is_boolean(M) -> {S, M};
            _ -> none
        end
    catch
        _:_ -> none
    end.

store_last_geo_state(Node, Pair) ->
    try
        Map0 = persistent_term:get(?PT_LAST_GEO_SOURCE, #{}),
        persistent_term:put(?PT_LAST_GEO_SOURCE, Map0#{Node => Pair}),
        ok
    catch
        _:_ -> ok
    end.

forget_geo_state(Node) ->
    try
        Map0 = persistent_term:get(?PT_LAST_GEO_SOURCE, #{}),
        persistent_term:put(?PT_LAST_GEO_SOURCE, maps:remove(Node, Map0)),
        ok
    catch
        _:_ -> ok
    end.

%% v2.1 C.4 knob-off blindness guard (evaluation finding #1): at the
%% FIRST worker admission PER POOL LIFETIME (boot-scoped — the
%% `knobs_off_warned` flag survives reconnect storms and keepalive
%% hellos, so the counter is never inflated) while geo/health/rtt are
%% ALL off, log ONE warning (`scheduler_knobs_all_off`) and bump
%% `knobs_off` — surfaced in /stats/sched AND /metrics. The evaluation
%% shipped blind selection enabled-off with the WORST worker winning
%% by name order; this makes that state loud instead of silent.
maybe_knobs_off_guard(#state{knobs_off_warned = true} = State) ->
    State;
maybe_knobs_off_guard(#state{knobs_off_warned = false} = State) ->
    Knobs = knobs(),
    %% geo "requested but still loading" is NOT off — an explicit
    %% JANUS_GEO=1 boot keeps geo_enabled=false until the async
    %% mmdb load lands; treating that window as off would latch
    %% knobs_off=1 permanently (ocr review).
    AllOff =
        not geo_enabled_safe() andalso not geo_requested_safe() andalso
            not maps:get(health, Knobs, false) andalso
            not maps:get(rtt, Knobs, false),
    case AllOff of
        true ->
            logger:warning(#{
                what => scheduler_knobs_all_off,
                note =>
                    <<"geo/health/rtt are ALL off — selection is "
                      "least-inflight + name order (v1). See the v2.1 "
                      "runbook (skills/fleet-node-ops) for the enablement "
                      "order.">>
            }),
            ok = bump(knobs_off),
            State#state{knobs_off_warned = true};
        false ->
            State
    end.

do_drain(Node, #state{pool = Pool} = State) ->
    {Pool1, WasMember} = apply_drain(Pool, Node),
    State1 =
        case WasMember of
            true ->
                _ = ets:insert(?WORKERS, {Node, is_draining(Pool1, Node)}),
                %% The dirty-flush (<= 250 ms) evaluates drain-idle
                %% arming (v2.1 A.2) — an idle node arms there.
                mark_dirty(State#state{pool = Pool1});
            false ->
                State#state{pool = Pool1}
        end,
    State1.

do_drain_idle(Node, #state{pool = Pool} = State0) ->
    State = forget_timer(Node, State0),
    %% v2.1 A.2 FIRE-TIME re-check: the conjunct must STILL hold — a
    %% job reserved during the idle window (a caller-side ETS write the
    %% pool never saw) must not be killed by the sticky transition.
    case is_draining(Pool, Node) andalso node_drain_idle_ready(Node) of
        true ->
            {Pool1, BecameSticky} = apply_drain_idle(Pool, Node),
            case BecameSticky of
                true ->
                    ok = sticky_insert(Node),
                    %% Member removed (sticky): drop the live drain row so the
                    %% node refuses picks until undrain + re-hello.
                    _ = ets:delete(?WORKERS, Node),
                    logger:info(#{what => janus_worker_pool_sticky, node => Node}),
                    mark_dirty(State#state{pool = Pool1});
                false ->
                    State#state{pool = Pool1}
            end;
        false ->
            State
    end.

do_nodedown(Node, #state{pool = Pool} = State) ->
    Pool1 = apply_nodedown(Pool, Node),
    %% Clear ALL scheduler state for the node (spec Part 0.4 + v2.1 B.1):
    %% pool records + sched_workers row + sched_tracked rows (keyed by
    %% JobRef — `ets:select` the node's JobRefs then per-key take via
    %% the shared helper: each taken row applies the SAME release
    %% conjunct — a probe row decrements nothing, a concurrent caller
    %% release finds nothing, no double-decrement) + reserve row +
    %% rtt rows + divergence window + probe-cadence state and the probe
    %% in-flight map. NAMED WINDOW: a pick incrementing between the
    %% take loop and the delete loses its fresh increment
    %% (under-admit-by-1 until that job completes — the same accepted
    %% class as take-vs-reconcile). Tracked entries for a dead node
    %% never complete — removing them makes late releases no-ops (the
    %% counter row is gone; the insert-default recreates {Node, -1} at
    %% worst — the tick clamps). Health-EWMA state is NOT cleared here
    %% (the spec clear-list keeps it; owner restart clears it).
    _ = [take_and_maybe_decrement(JobRef) || JobRef <- node_tracked_refs(Node)],
    _ = ets:delete(?WORKERS, Node),
    _ = ets:delete(?RESERVE, Node),
    ok = delete_rtt_rows(Node),
    ok = forget_geo_state(Node),
    State1 = cancel_timer(
        Node,
        mark_dirty(State#state{
            pool = Pool1,
            divergence = maps:remove(Node, State#state.divergence),
            load = maps:remove(Node, State#state.load),
            probe_inflight = maps:remove(Node, State#state.probe_inflight),
            probe_sent = maps:filter(
                fun(_JobRef, {N, _, _, _}) -> N =/= Node end, State#state.probe_sent
            ),
            probe_last = maps:filter(
                fun({N, _ProviderId}, _At) -> N =/= Node end, State#state.probe_last
            ),
            %% D9 Task C: the dead worker's relayed counters leave the
            %% aggregate with the stale snapshot — drop the node (its
            %% counters died with the VM anyway; re-hello + the next
            %% load cast rebuild the snapshot from zero).
            wire_enc_relay = maps:remove(Node, State#state.wire_enc_relay)
        })
    ),
    note_nodedown(Node, State1).

%% Nodedown log coalescing + identity-flap warning (see #state.flap).
%% The FIRST nodedown in a 10 s window logs as before (nothing hides a
%% real event); repeats inside the window are counted silently and
%% summarized when the window rolls; >= 8 in one window additionally
%% warns once per 30 s — that warning means a second process is
%% claiming the node name (duplicate bare/docker deployment on its
%% host) or dist is flapping.
-define(NODEDOWN_WINDOW_MS, 10_000).
-define(NODEDOWN_FLAP_THRESHOLD, 8).
-define(FLAP_WARN_INTERVAL_MS, 30_000).

note_nodedown(Node, #state{flap = Flap} = State) ->
    Now = erlang:monotonic_time(millisecond),
    {C0, W0, S0, LW} = maps:get(Node, Flap, {0, 0, 0, 0}),
    {C1, W1, S1} =
        case Now - W0 < ?NODEDOWN_WINDOW_MS of
            true ->
                {C0 + 1, W0, S0 + 1};
            false ->
                case S0 of
                    N when N > 0 ->
                        logger:info(#{
                            what => janus_worker_pool_nodedown_suppressed,
                            node => Node,
                            count => N
                        });
                    0 ->
                        ok
                end,
                {1, Now, 0}
        end,
    case C1 of
        1 -> logger:info(#{what => janus_worker_pool_nodedown, node => Node});
        _ -> ok
    end,
    LW1 =
        case
            C1 >= ?NODEDOWN_FLAP_THRESHOLD andalso
                (LW =:= 0 orelse Now - LW >= ?FLAP_WARN_INTERVAL_MS)
        of
            true ->
                logger:warning(#{
                    what => janus_worker_identity_flap,
                    node => Node,
                    window_count => C1,
                    hint =>
                        <<"a second process may be claiming this node name "
                          "(duplicate bare/docker deployment on its host) or dist is flapping">>
                }),
                Now;
            false ->
                LW
        end,
    State#state{flap = Flap#{Node => {C1, W1, S1, LW1}}}.

normalize_hello_meta(Node, Meta) when is_map(Meta) ->
    #{
        role => maps:get(role, Meta, undefined),
        vsn => maps:get(vsn, Meta, undefined),
        region => maps:get(region, Meta, undefined),
        capacity => normalize_capacity(Node, maps:get(capacity, Meta, undefined)),
        sched_v => normalize_sched_v(maps:get(sched_v, Meta, undefined)),
        %% v2.1 A.3/C.3 build provenance: the worker's hello-reported
        %% image SHA (additive key; old hellos default <<"unknown">>).
        git_sha => normalize_git_sha(maps:get(git_sha, Meta, undefined)),
        %% Geo-affinity additive keys (2026-10-11 D4): the winning
        %% egress layer rides the hello; garbage normalizes away
        %% (undefined / 0) exactly like capacity/sched_v. The source is
        %% ENUM-VALIDATED — an unknown source atom never becomes a
        %% member layer.
        egress_ip => normalize_geo_bin(maps:get(egress_ip, Meta, undefined)),
        egress_region => normalize_geo_bin(maps:get(egress_region, Meta, undefined)),
        egress_source => normalize_geo_source(maps:get(egress_source, Meta, undefined)),
        egress_fetched_at => normalize_pos_int(maps:get(egress_fetched_at, Meta, undefined)),
        echo_ok_total => normalize_pos_int(maps:get(echo_ok_total, Meta, undefined)),
        echo_fail_total => normalize_pos_int(maps:get(echo_fail_total, Meta, undefined))
    };
normalize_hello_meta(_Node, _) ->
    #{
        role => undefined,
        vsn => undefined,
        region => undefined,
        capacity => infinity,
        sched_v => 1,
        git_sha => <<"unknown">>,
        egress_ip => undefined,
        egress_region => undefined,
        egress_source => undefined,
        egress_fetched_at => 0,
        echo_ok_total => 0,
        echo_fail_total => 0
    }.

normalize_geo_bin(B) when is_binary(B), B =/= <<>> ->
    B;
normalize_geo_bin(_) ->
    undefined.

%% The egress-source enum (D23-adjacent): only the four chain layers.
normalize_geo_source(<<"gw_echo">>) -> <<"gw_echo">>;
normalize_geo_source(<<"metadata">>) -> <<"metadata">>;
normalize_geo_source(<<"env">>) -> <<"env">>;
normalize_geo_source(<<"third_echo">>) -> <<"third_echo">>;
normalize_geo_source(_) -> undefined.

normalize_pos_int(N) when is_integer(N), N >= 0 ->
    N;
normalize_pos_int(_) ->
    0.

%% Explicit capacity clamped >= 1 (spec A.5); unset => infinity (v1
%% semantics); non-integer garbage => 1 + warning.
normalize_capacity(_Node, undefined) ->
    infinity;
normalize_capacity(_Node, X) when is_integer(X), X >= 1 ->
    X;
normalize_capacity(Node, X) when is_integer(X) ->
    logger:warning(#{what => janus_worker_pool_capacity_clamped, node => Node, capacity => X}),
    1;
normalize_capacity(Node, X) ->
    logger:warning(#{what => janus_worker_pool_capacity_garbage, node => Node, capacity => X}),
    1.

normalize_sched_v(V) when is_integer(V), V >= 1 ->
    V;
normalize_sched_v(_) ->
    1.

%% git_sha rides hello as a non-empty binary (the wire constructor's
%% additive filter enforces that shape); anything else -> <<"unknown">>
%% (never empty — a missing build-arg stamps the literal, spec C.3).
normalize_git_sha(S) when is_binary(S), S =/= <<>> ->
    S;
normalize_git_sha(_) ->
    <<"unknown">>.

%% v2.1 A.2 drain-idle ARMING: evaluated on EVERY sched_tick AND every
%% dirty-flush republish (the {touched,...} poke marks dirty after a
%% COMPLETION). Conjunct per draining member: non-Internal tracked set
%% EMPTY (a lost probe row does NOT stall sticky — it lingers until
%% purge with no reserve impact) AND reserve == 0. A downward reconcile
%% heal cannot false-arm (the emptiness conjunct requires the jobs
%% gone). Arms ONLY when no timer is armed — flushes recur every
%% <= 250 ms while ANY node is dirty; resetting a running idle clock
%% each flush would starve the transition forever. The FIRE-time
%% re-check (do_drain_idle) protects against a job reserved during the
%% window.
eval_drain_idle(#state{pool = #{members := Members}} = State) ->
    Draining = [N || {N, #{draining := true}} <- maps:to_list(Members)],
    lists:foldl(
        fun(Node, Acc) ->
            case maps:is_key(Node, Acc#state.timers) of
                true ->
                    Acc;
                false ->
                    case node_drain_idle_ready(Node) of
                        true -> arm_idle_timer(Node, Acc);
                        false -> Acc
                    end
            end
        end,
        State,
        Draining
    ).

%% The live conjunct (v2.1 A.2): draining is checked by the CALLER.
node_drain_idle_ready(Node) ->
    noninternal_tracked_empty(Node) andalso reserve_count(Node) =:= 0.

%% NON-INTERNAL tracked emptiness: probes are tracked but never
%% reserved — counting them would stall sticky for up to the 10-min
%% purge (spec rev 3 fold).
noninternal_tracked_empty(Node) ->
    try
        ets:select(?TRACKED, [{{'$1', {Node, '_', '_', false}}, [], ['$1']}]) =:= []
    catch
        _:_ -> false
    end.

arm_idle_timer(Node, State) ->
    State1 = cancel_timer(Node, State),
    TRef = erlang:send_after(drain_idle_ms(), self(), {drain_idle, Node}),
    State1#state{timers = maps:put(Node, TRef, State1#state.timers)}.

cancel_timer(Node, #state{timers = Timers} = State) ->
    case maps:take(Node, Timers) of
        {TRef, Timers1} ->
            _ = erlang:cancel_timer(TRef),
            %% Drain any already-delivered message.
            receive
                {drain_idle, Node} -> ok
            after 0 ->
                ok
            end,
            State#state{timers = Timers1};
        error ->
            State
    end.

forget_timer(Node, #state{timers = Timers} = State) ->
    State#state{timers = maps:remove(Node, Timers)}.

maybe_monitor_nodes() ->
    case net_kernel:monitor_nodes(true) of
        ok ->
            ok;
        {error, Reason} ->
            logger:warning(#{what => janus_worker_pool_monitor_nodes, reason => Reason}),
            ok
    end.

%%%===================================================================
%%% Scheduler v2 — tables, knobs, timers
%%%===================================================================

%% Boot: only probe_force stays env-once (test-only). Other sched knobs
%% resolve hot via janus_sched_knobs (settings → env → default).
boot_knobs() ->
    Force = env_truthy(os:getenv("JANUS_SCHED_PROBE_FORCE")),
    case Force of
        true ->
            logger:warning(#{
                what => janus_sched_probe_force_enabled,
                note =>
                    <<"JANUS_SCHED_PROBE_FORCE bypasses probe cadence and the fresh-skip; it NEVER bypasses the hourly cap or target eligibility. Test-only; never enable in production.">>
            });
        false ->
            ok
    end,
    persistent_term:put(?PT_KNOBS, #{probe_force => Force}),
    %% Boot re-resolves the sched knobs from the CURRENT env (merge fix:
    %% cached_sched publishes only on absence, so a leaked
    %% ?PT_SCHED_RESOLVED from a previous boot would pin stale knobs —
    %% boot semantics are env-wins until the next settings distribute
    %% republishes; also restores live-cell isolation in eunit).
    ok = janus_sched_knobs:publish_resolved(),
    ok.

env_pos_int(false, Default) ->
    Default;
env_pos_int("", Default) ->
    Default;
env_pos_int(Val, Default) when is_list(Val) ->
    try
        max(0, list_to_integer(Val))
    catch
        _:_ ->
            logger:warning(#{
                what => janus_worker_pool_probe_cap_garbage,
                value => Val,
                default => Default
            }),
            Default
    end;
env_pos_int(_, Default) ->
    Default.

%% Heir'd scheduler tables (spec Part 0.5): adopt from the heir with
%% backoff retry (the heir may not yet have processed the old owner's
%% transfer), else create with the heir set. ON ADOPT (v2.1 B.1 F2):
%% the SHARED reset helper clears sched_reserve AND sched_tracked (the
%% caller-written tables — surviving rows are orphans of the dead
%% owner's generation; running jobs uncounted until they complete);
%% prune sched_workers rows for nodes absent from pool records — at
%% init that is ALL rows (a COLD RESET: every worker must re-hello
%% post-adopt, spec Part 0.5). The immediate reconcile in init/1 then
%% also deletes ALL sched_rtt rows (no pool records yet — a cold RTT
%% reset in the accepted class). Returns the adopted tags.
ensure_sched_tables() ->
    Heir = heir_with_retry(),
    Opts = [set, public, named_table, {read_concurrency, true}],
    Results = [
        adopt_or_create(?SNAPSHOT, Opts, Heir),
        adopt_or_create(?RESERVE, Opts ++ [{write_concurrency, true}], Heir),
        adopt_or_create(?WORKERS, Opts, Heir),
        adopt_or_create(?RTT, Opts, Heir),
        adopt_or_create(?TRACKED, Opts ++ [{write_concurrency, true}], Heir),
        %% write_concurrency: the suspect table is written from the pool
        %% gen_server AND taken from caller-side release paths.
        adopt_or_create(?SUSPECT, Opts ++ [{write_concurrency, true}], Heir),
        adopt_or_create(?SUSPECT_COUNT, Opts ++ [{write_concurrency, true}], Heir)
    ],
    %% Owner-local counters (tolerant bump pattern, janus_geo
    %% precedent): they died with the previous owner; the name is free.
    _ = ets:new(?COUNTERS, [set, public, named_table]),
    %% Probe-candidate injection seam (Task B2): plain public table,
    %% NOT heir'd — injection is ephemeral (eunit / future ops tooling);
    %% empty in production => probe_candidates/0 reads the catalog.
    _ = ets:new(?PROBE_CAND, [set, public, named_table]),
    Adopted = [Tag || {adopted, Tag} <- Results],
    case Adopted of
        [] ->
            ok;
        _ ->
            ok = reset_adopted_tables(),
            logger:info(#{what => janus_worker_pool_tables_adopted, tables => Adopted})
    end,
    Adopted.

%% v2.1 B.1 F2: ONE shared adopt-reset so the table set cannot drift —
%% a fresh owner generation starts both caller-written tables cold.
reset_adopted_tables() ->
    _ = ets:delete_all_objects(?RESERVE),
    _ = ets:delete_all_objects(?TRACKED),
    _ = ets:delete_all_objects(?SUSPECT),
    %% sched_rtt resets here too: an adopted table may carry
    %% pre-v2.1 5-tuple rows that no prune/TTL path matches —
    %% the reset makes boot actually cold for this table (ocr).
    _ = (catch ets:delete_all_objects(?RTT)),
    ok.

heir_with_retry() ->
    heir_with_retry(20).

heir_with_retry(0) ->
    erlang:error({heir_not_running, ?MODULE});
heir_with_retry(N) ->
    try
        janus_ets_heir:heir_for(?SNAPSHOT)
    catch
        _:_ ->
            timer:sleep(100),
            heir_with_retry(N - 1)
    end.

adopt_or_create(Tag, Opts, Heir) ->
    case table_exists(Tag) of
        false ->
            %% COLD BOOT: the named table does not exist at all — the
            %% adopt-retry loop below exists ONLY for the
            %% adopt-after-death race (the heir may not yet have
            %% processed the dead owner's {'ETS-TRANSFER'}); on a cold
            %% boot its 10 x 50 ms burn per table is pure start latency
            %% that can push init past the supervisor's start timeout.
            _ = ets:new(Tag, Opts ++ [{heir, Heir, {Tag, self()}}]),
            {created, Tag};
        true ->
            case adopt_retry(Tag, ?ADOPT_RETRIES) of
                {ok, _Tab} ->
                    {adopted, Tag};
                not_held ->
                    %% Existed a moment ago (heir-held) but the adopt
                    %% never landed — the heir died under us (its death
                    %% destroyed the held tables): create cold.
                    _ = ets:new(Tag, Opts ++ [{heir, Heir, {Tag, self()}}]),
                    {created, Tag}
            end
    end.

%% A named table the heir is holding still answers ets:info (public);
%% a nonexistent one answers undefined.
table_exists(Tag) ->
    ets:info(Tag) =/= undefined.

adopt_retry(_Tag, 0) ->
    not_held;
adopt_retry(Tag, N) when N > 0 ->
    case janus_ets_heir:adopt(Tag) of
        {ok, Tab} ->
            {ok, Tab};
        not_held ->
            timer:sleep(?ADOPT_RETRY_MS),
            adopt_retry(Tag, N - 1);
        {error, give_away_failed} ->
            timer:sleep(?ADOPT_RETRY_MS),
            adopt_retry(Tag, N - 1)
    end.

%% Dirty flag on every state mutation (spec Part C): the flush timer
%% republishes at most every FLUSH_MS.
mark_dirty(#state{dirty = true} = State) ->
    State;
mark_dirty(#state{dirty = false} = State) ->
    TRef = erlang:send_after(?FLUSH_MS, self(), sched_flush),
    State#state{dirty = true, flush_tref = TRef}.

arm_tick(#state{tick_tref = Old} = State) ->
    _ = cancel_timer_if_ref(Old),
    TRef = erlang:send_after(?TICK_MS, self(), sched_tick),
    State#state{tick_tref = TRef}.

cancel_timer_if_ref(undefined) ->
    false;
cancel_timer_if_ref(TRef) when is_reference(TRef) ->
    erlang:cancel_timer(TRef).

%% Publish the built snapshot atomically (single row, full list swap)
%% and advance snapshot_gen — BOTH flush paths land here.
republish(State) ->
    _ = ets:insert(?SNAPSHOT, {candidates, build_snapshot(State)}),
    ok = bump(snapshot_gen),
    State.

%%%===================================================================
%%% Scheduler v2 — snapshot builder (spec Part C)
%%%===================================================================

%% Shared read-path capacity resolution (worker-capacity-override spec
%% Part 1 "Read path"): settings override > the capacity the worker
%% declared in its hello > infinity. BOTH capacity emitters call this
%% (`build_snapshot/1` — the number `reserve_loop/5` enforces — and the
%% member branch of `workers_view/6` — the dashboard cell the operator
%% edits), or the override appears broken exactly where it is watched.
%%
%% The two maps are keyed differently BY DESIGN: the member map's key is
%% the node ATOM, the settings map's key is the node's long-name BINARY,
%% so the lookup converts.
%%
%% The read path never refuses: an override entry that is not a positive
%% integer is ignored (one warning per node per distinct value) and the
%% declared value applies — a malformed settings row must not take a node
%% out of rotation. Absent entry = the normal deployment.
%%
%% The sticky-drained branch of `workers_view/6` deliberately does NOT
%% call this: it hardcodes `capacity => infinity` because a sticky node
%% takes no new work, so an override there is meaningless.
-spec effective_capacity(node(), map()) -> pos_integer() | infinity.
effective_capacity(Node, M) ->
    effective_capacity(Node, maps:get(capacity, M, infinity), janus_config:worker_capacity_overrides()).

%% Pure seam (eunit): the precedence rule governs admission for every
%% node, so it is separable from the persistent_term read.
-spec effective_capacity(node(), pos_integer() | infinity, map()) -> pos_integer() | infinity.
effective_capacity(Node, Declared, Overrides) when is_map(Overrides) ->
    case maps:find(atom_to_binary(Node, utf8), Overrides) of
        {ok, N} when is_integer(N), N >= 1 ->
            N;
        {ok, Bad} ->
            warn_capacity_override(Node, Bad),
            Declared;
        error ->
            Declared
    end.

%% An override whose name matches no live member is otherwise SILENTLY
%% inert: a typo, or a worker that has not hello'd yet, leaves the
%% operator believing a ceiling is applied. The spec puts member matching
%% at read time precisely so this can be reported here; warn once per
%% distinct unreferenced name, since this runs on every republish.
-spec warn_unused_capacity_overrides([node()]) -> ok.
warn_unused_capacity_overrides(LiveNodes) ->
    Live = [atom_to_binary(N, utf8) || N <- LiveNodes],
    maps:foreach(
        fun(Name, _Val) ->
            case lists:member(Name, Live) of
                true -> ok;
                false -> warn_once({capacity_override_unused, Name}, fun() ->
                    logger:warning(#{
                        what => janus_worker_pool_capacity_override_unused,
                        node => Name,
                        hint => <<"no live worker carries this name; the override is inert">>
                    })
                end)
            end
        end,
        janus_config:worker_capacity_overrides()
    ).

%% One warning per node per distinct value (janus_catalog's warn_once
%% shape): this runs on EVERY snapshot republish (<= 250 ms dirty-flush /
%% 30 s tick) and every `sched_stats` call, so an undeduped warning would
%% flood the log for one malformed row. Keying on the VALUE re-arms the
%% warning whenever the resolved value changes, so a row that is fixed and
%% later broken differently speaks again — the case an operator needs.
%% Bounded by fleet size, not by the free-form settings content.
warn_capacity_override(Node, Bad) ->
    warn_once({capacity_override, Node, Bad}, fun() ->
        logger:warning(#{
            what => janus_worker_pool_capacity_override_bad,
            node => Node,
            override => Bad,
            hint => <<"not a positive integer; declared capacity applies">>
        })
    end).

warn_once(Key, Fun) ->
    case get({janus_worker_pool_warned, Key}) of
        undefined ->
            put({janus_worker_pool_warned, Key}, true),
            Fun();
        _ ->
            ok
    end.

%% Joins pool worker records + unexpired sched_rtt cells + EWMA state;
%% precomputes per-candidate demote_ms (exclude-self, spec A.4).
%% Provider geo is NOT in the worker-keyed snapshot — it lives in the
%% persistent_term map read lock-free by pick.
%% v2.1 A.2: the `inflight` field is DISPLAY-only — the builder copies
%% the reserve count into the view; the SORT reads sched_reserve LIVE
%% at pick time. v2.1 B.2: rtt_map carries the per-provider EWMA (the
%% ONE canonical number — raw RttMs rides the row for display only).
build_snapshot(#state{pool = #{members := Members}, ewma = Ewma}) ->
    Now = now_mono(),
    RttByNode = rtt_by_node(Now),
    %% Report overrides that name no live member (typo / not-yet-hello'd).
    %% Rides the republish so the once-per-name warning lands without a
    %% second settings subscriber.
    ok = warn_unused_capacity_overrides(maps:keys(Members)),
    [
        {Node, #{
            inflight => reserve_count(Node),
            %% The ENFORCED ceiling: `candidate_capacity/2` reads this
            %% field and `reserve_loop/5` compares the reserve count
            %% against it (worker-capacity-override spec Part 1).
            capacity => effective_capacity(Node, M),
            draining => maps:get(draining, M, false),
            %% Geo-affinity D15: the EFFECTIVE geo (worker-geo overlay
            %% precedence, age-checked) feeds the EXISTING narrowing
            %% tier; members without an effective geo fall back to the
            %% legacy env-class region (v1 behavior).
            geo_region => member_geo_region(M),
            rtt_map => maps:get(Node, RttByNode, #{}),
            %% Sampling capability: a worker advertising sched_v < 2
            %% never reports rtt_ms, so it can never acquire an ?RTT
            %% cell. sort_tier/2 must not grant it the cold-start
            %% optimism, or it would lead the order forever.
            can_sample => maps:get(sched_v, M, 1) >= 2,
            observed_ewma_ms => observed_ewma(maps:get(Node, Ewma, none)),
            demote_ms => demote_ms(Node, Ewma)
        }}
     || {Node, M} <- maps:to_list(Members)
    ].

%% Effective member geo for the snapshot: when the worker-geo overlay
%% computed a geo_source, its geo_region IS the answer (even undefined
%% — a gw_echo winner the mmdb cannot map must NOT silently fall back
%% to the env region: the layer ranking would be undone); without a
%% computed geo_source (knob off / legacy worker) the env-class region
%% remains the v1 view.
member_geo_region(M) when is_map(M) ->
    case maps:is_key(geo_source, M) of
        true ->
            case maps:get(geo_region, M, undefined) of
                B when is_binary(B), B =/= <<>> -> B;
                _ -> undefined
            end;
        false ->
            maps:get(region, M, undefined)
    end;
member_geo_region(_) ->
    undefined.

rtt_by_node(Now) ->
    lists:foldl(
        fun
            ({{Node, ProviderId}, _Ms, _Source, _SampledAt, ExpiresAt, Ewma, _Count}, Acc) when
                ExpiresAt > Now, is_number(Ewma)
            ->
                maps:update_with(Node, fun(Rm) -> Rm#{ProviderId => Ewma} end, #{ProviderId => Ewma}, Acc);
            (_Row, Acc) ->
                %% Expired rows are absent from rtt_map (TTL enforced
                %% at build time, spec Part 0.4).
                Acc
        end,
        #{},
        sched_rtt_rows()
    ).

sched_rtt_rows() ->
    try
        ets:tab2list(?RTT)
    catch
        _:_ -> []
    end.

%%%===================================================================
%%% Scheduler v2.1 — shared tracked/reserve bookkeeping (B.1)
%%%===================================================================

%% SHARED take-and-maybe-decrement spine — release / nodedown / purge
%% (and probe clear) all go through this ONE helper so the Internal
%% gate cannot drift (spec B.1). Atomically `ets:take` the tracked row;
%% iff a row was taken AND `Internal =:= false`, apply the pinned
%% decrement `ets:update_counter(?RESERVE, Node, {2, -1}, {Node, 0})`.
%% Wrapped in try: a badarg at table-shutdown (dead pool, mid-adopt)
%% skips the decrement and NEVER double-applies.
%%
%% Worker-capacity-override spec Part 2 (SINGLE-OWNER rule): this
%% helper is the ONE place a reservation slot is freed, so it is also
%% the ONE place the suspect contribution for that slot is freed — a
%% taken row also `ets:take`s its ?SUSPECT entry (keyed by JobRef), so
%% a slot can never be freed without its suspect component going with
%% it (the purge-suspect double-decrement the reviews flagged).
take_and_maybe_decrement(JobRef) ->
    %% The try scopes the TAKE only: a taken row must be reported
    %% as taken even when the decrement throws (table torn down
    %% mid-adopt) — callers key bookkeeping (touched poke, probe
    %% cleanup) off {taken,_}; the reserve over-count is healed
    %% by the two-tick reconcile either way (ocr review).
    Taken =
        try ets:take(?TRACKED, JobRef) of
            Rows -> Rows
        catch
            _:_ -> not_available
        end,
    case Taken of
        [{JobRef, {Node, _ReservedAt, _ProviderId, false}}] ->
            %% Clear the suspect entry FIRST (or in the same breath as
            %% the decrement): if this job was marked suspect, its load
            %% exclusion must die with the slot. `ets:take/2` is a no-op
            %% when the row is absent (never suspect).
            _ = clear_suspect(JobRef),
            Decr =
                try
                    _ = ets:update_counter(?RESERVE, Node, {2, -1}, {Node, 0}),
                    true
                catch
                    _:_ -> false
                end,
            {taken, Node, Decr};
        [{JobRef, {Node, _ReservedAt, _ProviderId, true}}] ->
            %% Probes never hold a reservation and never get marked
            %% suspect; clearing is still harmless and keeps the
            %% single-owner rule uniform.
            _ = clear_suspect(JobRef),
            {taken, Node, false};
        [] ->
            none;
        not_available ->
            none
    end.

%% Tracked row read for the {ttfb,...}/{rtt,...} handlers: the row
%% shape `{Node, ReservedAtMono, ProviderId, Internal}` or `none`.
tracked_row(JobRef) ->
    try
        case ets:lookup(?TRACKED, JobRef) of
            [{JobRef, Row}] -> Row;
            [] -> none
        end
    catch
        _:_ -> none
    end.

tracked_rows() ->
    try
        ets:tab2list(?TRACKED)
    catch
        _:_ -> []
    end.

%% NODEDOWN spine: sched_tracked is keyed by JobRef (no take-by-node) —
%% select the node's JobRefs; the per-key takes above own the
%% decrements and arbitrate against concurrent releases.
node_tracked_refs(Node) ->
    try
        ets:select(?TRACKED, [{{'$1', {Node, '_', '_', '_'}}, [], ['$1']}])
    catch
        _:_ -> []
    end.

%% v1 candidate list for pick_sync (A.2: member.inflight is GONE — the
%% live reserve counter is the inflight source).
v1_candidates(#{members := Members}) ->
    [
        {Node, #{
            inflight => reserve_count(Node),
            region => maps:get(region, M, undefined),
            draining => maps:get(draining, M, false)
        }}
     || {Node, M} <- maps:to_list(Members)
    ];
v1_candidates(_) ->
    [].

%%%===================================================================
%%% Scheduler v2 — {sched, 2, _} ingestion (advisory load, passive rtt)
%%%===================================================================

%% Advisory load cast (spec Part 0.3): store for ops display and run
%% the divergence window against the master-observed EWMA. The load
%% cast keeps its own suppression rule worker-side; a steady-state
%% lying worker may never send (documented starvation of the mismatch
%% counter — accepted v1).
do_load(Node, Info, #state{ewma = Ewma, divergence = Div, load = Load, wire_enc_relay = Relay} = State) when
    is_map(Info)
->
    Reported = maps:get(ewma_upstream_ms, Info, undefined),
    Observed = observed_ewma(maps:get(Node, Ewma, none)),
    Divergent = report_divergent(Reported, Observed),
    {Fired, Window1} = advance_divergence(
        maps:get(Node, Div, none), Divergent, now_mono(), ?DIVERGENCE_WINDOW_MS
    ),
    case Fired of
        true -> ok = bump(fleet_worker_report_mismatch);
        false -> ok
    end,
    Div1 =
        case Window1 of
            none -> maps:remove(Node, Div);
            _ -> Div#{Node => Window1}
        end,
    State#state{
        load = Load#{Node => #{
            inflight_self => maps:get(inflight_self, Info, undefined),
            ewma_upstream_ms => Reported,
            mem_self => maps:get(mem_self, Info, undefined)
        }},
        divergence = Div1,
        %% D9 Task C: store the relayed codec-counters snapshot,
        %% LATEST-WINS and normalized (fixed-enum family — a lying
        %% worker cannot grow unbounded label sets through master
        %% state). Old workers (no `wire_enc` key) store an empty
        %% snapshot — additive, never a crash.
        wire_enc_relay = Relay#{Node => normalize_wire_enc(maps:get(wire_enc, Info, undefined))}
    };
do_load(_Node, _Info, State) ->
    State.

%%%===================================================================
%%% Wire-enc relay pure seams (spec 2026-10-12-wire-compression D9)
%%%===================================================================

%% Normalize one codec-counters snapshot (relayed from a worker OR the
%% master's own local read): keep ONLY the fixed-enum D9 family with
%% non-negative integer values — the family is bounded by construction
%% (`{Metric, {Dir, Enc}}` keys mirror the counters-table shape), so a
%% lying/garbage relay can neither crash the master's state nor grow
%% unbounded label sets. Unknown keys, negatives, and non-integers are
%% dropped (not logged — this is the hello-normalizer class, and the
%% load cast's ewma keys are already unvalidated advisory).
-spec normalize_wire_enc(term()) -> map().
normalize_wire_enc(Map) when is_map(Map) ->
    maps:filter(
        fun(K, V) -> is_wire_enc_key(K) andalso is_integer(V) andalso V >= 0 end,
        Map
    );
normalize_wire_enc(_) ->
    #{}.

%% The D9 bounded-label family (chunks never carries `plain` — that is
%% a bytes-only SUPPLEMENTARY bucket; time/fail totals are label-free).
is_wire_enc_key({wire_enc_chunks_total, {Dir, Enc}}) ->
    wire_enc_dir(Dir) andalso lists:member(Enc, [identity, zlib]);
is_wire_enc_key({wire_enc_bytes_total, {Dir, Enc}}) ->
    wire_enc_dir(Dir) andalso lists:member(Enc, [identity, zlib, plain]);
is_wire_enc_key(wire_enc_deflate_time_us_total) -> true;
is_wire_enc_key(wire_enc_inflate_time_us_total) -> true;
is_wire_enc_key(wire_enc_inflate_fail_total) -> true;
is_wire_enc_key(wire_enc_bad_config_total) -> true;
%% PR2 (spec D9/F5): label-free ops signal for unsolicited stream gzip.
is_wire_enc_key({upstream_enc_unsolicited_total, {in, gzip}}) -> true;
is_wire_enc_key(_) -> false.

wire_enc_dir(out) -> true;
wire_enc_dir(in) -> true;
wire_enc_dir(_) -> false.

%% Pure D9 aggregation: the master's LOCAL codec counters (its decode
%% side — tag-driven, so the table exists env-off) summed key-wise with
%% the LATEST relayed snapshot per worker. Latest-wins happened at
%% ingest; this is a plain per-key sum across nodes + local. The
%% identity|zlib buckets stay a PARTITION of wire bytes (each side
%% bumps exactly one bucket per message); `plain` sums separately and
%% is never added into them (the JSON/prometheus layers keep the
%% families distinct too).
-spec aggregate_wire_enc(map(), map()) -> map().
aggregate_wire_enc(Local, RelayByNode) ->
    Snapshots =
        [normalize_wire_enc(Local)] ++
            [normalize_wire_enc(S) || {_Node, S} <- maps:to_list(RelayByNode)],
    lists:foldl(
        fun(M, Acc) -> maps:merge_with(fun(_K, A, B) -> A + B end, Acc, M) end,
        #{},
        Snapshots
    ).

%% Passive sched_rtt write: clamp at MASTER ingest (spec A.3); row
%% shape (v2.1 B.2) `{{Node, ProviderId}, RttMs, Source, SampledAtMono,
%% ExpiresAtMono, Ewma, SampleCount}`; LAST-ARRIVAL-WINS for the RAW
%% RttMs field (handler serialization makes the message being handled
%% the newest — no stamp compare exists) while the EWMA steps
%% INCREMENTALLY (`E' = 0.75*E + 0.25*x`, seed-at-first — the
%% health-EWMA pattern; one canonical number for sort/gauge/display).
%% A row that TTL-expired (or never existed) RE-SEEDS — expiry drops
%% the row and its EWMA whole (documented B.2 bias).
write_passive_rtt(Node, ProviderId, RttMs) ->
    case clamp_rtt(RttMs) of
        {ok, Ms} ->
            Now = now_mono(),
            {Ewma, Count} = rtt_ewma_cell(Node, ProviderId, Ms, Now),
            _ = ets:insert(
                ?RTT, {{Node, ProviderId}, Ms, passive, Now, Now + ?RTT_TTL_MS, Ewma, Count}
            ),
            ok;
        {drop, Reason} ->
            ok = bump({rtt_dropped, Reason})
    end.

%% The incremental EWMA step's read of the current cell. Old-shape
%% 5-tuple rows (pre-v2.1 beam generation) have no cell to continue —
%% the lookup pattern simply misses and the write RE-SEEDS; the table
%% is TTL-10-min ephemeral and any pool restart cold-prunes it (the
%% reconcile at init deletes all rows — no member records yet), so
%% boot-cold is the accepted migration: NO row rewrite is performed.
rtt_ewma_cell(Node, ProviderId, Ms, Now) ->
    try
        case ets:lookup(?RTT, {Node, ProviderId}) of
            [{_Key, _OldMs, _Source, _SampledAt, ExpiresAt, E, Count}] when
                ExpiresAt > Now, is_number(E), is_integer(Count), Count >= 1
            ->
                ewma_step({E, Count}, Ms);
            _ ->
                ewma_step(none, Ms)
        end
    catch
        _:_ ->
            ewma_step(none, Ms)
    end.

delete_rtt_rows(Node) ->
    _ = [
        ets:delete(?RTT, Key)
     || {{N, _ProviderId} = Key, _Ms, _Source, _SampledAt, _ExpiresAt, _Ewma, _Count} <- sched_rtt_rows(),
        N =:= Node
    ],
    ok.

%%%===================================================================
%%% Scheduler v2 — probe machinery (spec Part 0.2/0.8, Task B2)
%%%===================================================================

%% Tick -> self-cast seam: {sched, 2, {probe, JobSpec}} is
%% POOL-INTERNAL (spec rev 7) — consumed by the handle_cast clause
%% behind do_probe; what crosses to the worker is a NORMAL pinned job
%% carrying `internal => true` (the worker sees no new message type).
maybe_kick_probe(State) ->
    case probe_enabled() of
        true ->
            _ = gen_server:cast(self(), {sched, 2, {probe, #{}}}),
            State;
        false ->
            State
    end.

%% The eligibility cascade (spec Part 0.2). Skip reasons are evaluated
%% in a FIXED order and the FIRST disqualifying condition is counted:
%% cap (FIRST — FORCE never bypasses it) -> drained (no dispatchable
%% worker) -> cadence (all targets in flight / no due pair) -> fresh
%% (an unexpired sched_rtt row exists, passive OR probe — skipped by
%% FORCE) -> send_fail (job build/send failure or ack miss). An
%% all-old-version fleet (no sched_v >= 2 member) is a SILENT no-op:
%% old workers are not targets, and the skip enum has no reason for
%% version exclusion. An empty provider set is likewise silent — there
%% is no (worker, provider) pair to probe.
do_probe(#state{} = State) ->
    Now = now_mono(),
    {Capped, Window} = probe_cap(Now, State),
    case Capped of
        true ->
            ok = bump({probe_skip, cap}),
            State;
        false ->
            do_probe_targets(probe_candidates(), Window, Now, State)
    end.

%% Rolling 1 h issued-probe window vs JANUS_SCHED_PROBE_MAX_HOURLY.
%% Returns {Capped, Window} with expired stamps pruned (the caller
%% re-stores the pruned window on issue).
probe_cap(Now, #state{probe_issued = Issued}) ->
    Window = [T || T <- Issued, Now - T < ?PROBE_HOUR_MS],
    {length(Window) >= probe_max_hourly(), Window}.

do_probe_targets([], _Window, _Now, State) ->
    State;
do_probe_targets(Providers, Window, Now, #state{pool = #{members := Members}} = State) ->
    {Targets, AnyDispatchable} = probe_worker_targets(Members),
    case {Targets, AnyDispatchable} of
        {[], false} ->
            ok = bump({probe_skip, drained}),
            State;
        {[], true} ->
            %% Members exist but none carries sched_v >= 2: old workers
            %% are NOT probe targets (spec Part 0.2) — silent.
            State;
        {_, _} ->
            do_probe_pairs(Providers, Window, Now, Targets, State)
    end.

%% Dispatchable x sched_v >= 2 targets (pick's primitives minus the
%% counter, spec Part 0.2): member not draining, LIVE sched_workers row
%% reads dispatchable (missing row = drained = refuse), hello carried
%% the additive sched_v => 2 marker (unupgraded workers return no
%% data — probing them would re-probe to cap-exhaustion).
probe_worker_targets(Members) ->
    lists:foldl(
        fun({Node, M}, {Targets, Any}) ->
            MemberOk = maps:get(draining, M, false) =:= false,
            case MemberOk andalso live_draining(Node) =:= false of
                true ->
                    case maps:get(sched_v, M, 1) >= 2 of
                        true -> {[Node | Targets], true};
                        false -> {Targets, true}
                    end;
                false ->
                    {Targets, Any}
            end
        end,
        {[], false},
        maps:to_list(Members)
    ).

do_probe_pairs(Providers, Window, Now, Targets, #state{probe_inflight = Inflight} = State) ->
    %% In-flight workers are EXCLUDED from targets (counted under
    %% cadence when they were the only candidates).
    Free = [N || N <- Targets, not maps:is_key(N, Inflight)],
    Pairs = lists:usort([{N, P} || N <- Free, #{provider_id := P} <- Providers]),
    %% FORCE bypasses cadence AND the fresh/unexpired-row skip —
    %% never the cap (checked first) or eligibility above (spec 0.2).
    Due =
        case probe_force() of
            true -> Pairs;
            false -> [Pair || Pair <- Pairs, probe_cadence_due(Pair, Now, State)]
        end,
    case Due of
        [] ->
            ok = bump({probe_skip, cadence}),
            State;
        _ ->
            Eligible =
                case probe_force() of
                    true -> Due;
                    false -> [Pair || Pair <- Due, not rtt_row_fresh(Pair, Now)]
                end,
            case Eligible of
                [] ->
                    ok = bump({probe_skip, fresh}),
                    State;
                _ ->
                    Pair = least_recently_probed(Eligible, State),
                    dispatch_probe_flow(Pair, Providers, Window, State)
            end
    end.

%% Cadence per (worker, provider) >= 60 s with +-20 % jitter. The
%% jitter factor is phash2-derived from {Node, ProviderId, hour-bucket}
%% — STABLE within an hour and per pair (deterministic evaluation,
%% unlike a per-call rand), spread across pairs (spec Part 0.2).
probe_cadence_due({Node, ProviderId}, Now, #state{probe_last = Last}) ->
    case maps:find({Node, ProviderId}, Last) of
        {ok, At} ->
            Now - At >= cadence_threshold(Node, ProviderId, At);
        error ->
            %% Never probed: always due (and sorts as OLDEST below).
            true
    end.

cadence_threshold(Node, ProviderId, LastAt) ->
    Bucket = LastAt div ?PROBE_HOUR_MS,
    Factor = 0.8 + 0.4 * (erlang:phash2({Node, ProviderId, Bucket}, 1000) / 1000.0),
    round(?PROBE_CADENCE_MS * Factor).

%% Freshness predicate (spec Part 0.2, one statement): an unexpired
%% sched_rtt row exists — BOTH passive AND probe rows count; the 10-min
%% TTL is the bound.
rtt_row_fresh({Node, ProviderId}, Now) ->
    try
        case ets:lookup(?RTT, {Node, ProviderId}) of
            [{_Key, _Ms, _Source, _SampledAt, ExpiresAt, _Ewma, _Count}] -> ExpiresAt > Now;
            [] -> false
        end
    catch
        _:_ -> false
    end.

%% Least-recently-probed pair; never-probed pairs sort as OLDEST
%% (timestamp 0). Stable: the pair list is usorted before the
%% timestamp sort, so ties keep term order.
least_recently_probed(Pairs, #state{probe_last = Last}) ->
    Sorted = lists:sort(
        fun(A, B) -> maps:get(A, Last, 0) =< maps:get(B, Last, 0) end,
        Pairs
    ),
    hd(Sorted).

dispatch_probe_flow({Node, ProviderId}, Providers, Window, State) ->
    Candidate = hd([C || #{provider_id := P} = C <- Providers, P =:= ProviderId]),
    case build_probe_job(Candidate) of
        {error, Reason} ->
            logger:warning(#{
                what => janus_sched_probe_build_failed,
                node => Node,
                provider => ProviderId,
                reason => Reason
            }),
            ok = bump({probe_skip, send_fail}),
            %% Stamp the pair as ATTEMPTED (probe_last, NOT
            %% probe_issued — no spend): a failing pair that never
            %% advances its cadence would be re-selected every tick
            %% and starve every other pair (ocr review).
            State#state{
                probe_last = (State#state.probe_last)#{{Node, ProviderId} => now_mono()}
            };
        {ok, Fields} ->
            case dispatch_probe(Node, Fields) of
                {error, Reason} ->
                    logger:warning(#{
                        what => janus_sched_probe_send_failed,
                        node => Node,
                        provider => ProviderId,
                        reason => Reason
                    }),
                    ok = bump({probe_skip, send_fail}),
                    %% Attempted, not issued — see the build-fail stamp.
                    State#state{
                        probe_last = (State#state.probe_last)#{{Node, ProviderId} => now_mono()}
                    };
                {ok, JobRef} ->
                    probe_issue(JobRef, Node, ProviderId, Window, State)
            end
    end.

%% @doc Direct pinned send of ONE internal probe job to `Node`'s
%% `janus_worker_dispatch` (spec Part 0.2): pick is NOT used, the
%% reserve counter is NEVER touched (the exemption is structural).
%% Runs in the POOL process on the live path — `self()` is the master
%% session that receives ack/done/error. The additive `internal => true`
%% rides the Fields map (extra keys pass wire validation untouched;
%% old-worker decode builds from known keys only, spec Part 0.10 —
%% janus_worker_wire is NOT modified). Safe to call from any process
%% in eunit — completions then route to the caller.
-spec dispatch_probe(node(), map()) -> {ok, binary()} | {error, term()}.
dispatch_probe(Node, Fields) when is_atom(Node), is_map(Fields) ->
    JobRef = crypto:strong_rand_bytes(16),
    case janus_worker_wire:job(JobRef, self(), Fields#{internal => true}) of
        {ok, JobMsg} ->
            try
                {janus_worker_dispatch, Node} ! JobMsg,
                {ok, JobRef}
            catch
                _:_ -> {error, send_failed}
            end;
        {error, _} = Err ->
            Err
    end.

%% Register the issued probe: the SAME tracked-row shape as pick's
%% winners but Internal => true and NO counter increment (v2.1 B.1:
%% the row is inserted DIRECTLY into sched_tracked — pool process, no
%% {track} cast); in-flight map, cadence stamp, cap window; ack
%% deadline timer (the timeout handler re-validates the Acked flag —
%% no timer ref bookkeeping).
probe_issue(JobRef, Node, ProviderId, Window, State) ->
    SentAt = now_mono(),
    _TRef = erlang:send_after(
        janus_worker_wire:ack_deadline_ms(), self(), {probe_ack_timeout, JobRef}
    ),
    _ = try
        true = ets:insert(?TRACKED, {JobRef, {Node, SentAt, ProviderId, true}})
    catch
        _:_ -> ok
    end,
    Inflight = (State#state.probe_inflight)#{Node => JobRef},
    ProbeSent = (State#state.probe_sent)#{JobRef => {Node, ProviderId, SentAt, false}},
    ProbeLast = (State#state.probe_last)#{{Node, ProviderId} => SentAt},
    State#state{
        probe_inflight = Inflight,
        probe_sent = ProbeSent,
        probe_last = ProbeLast,
        probe_issued = [SentAt | Window]
    }.

probe_ack(JobRef, #state{probe_sent = Sent} = State) ->
    case Sent of
        #{JobRef := {Node, ProviderId, SentAt, false}} ->
            State#state{probe_sent = Sent#{JobRef => {Node, ProviderId, SentAt, true}}};
        _ ->
            %% Unknown / late / duplicate ack: no-op.
            State
    end.

%% Clear ALL probe bookkeeping for JobRef: the tracked entry is
%% REMOVED through the SHARED take-and-maybe-decrement spine (Internal
%% => never decremented — the SAME gate as release/nodedown/purge, so
%% the conjunct cannot drift), the in-flight slot and dispatch details
%% go with it.
probe_clear(JobRef, Node, State) ->
    _ = take_and_maybe_decrement(JobRef),
    State#state{
        probe_inflight = maps:remove(Node, State#state.probe_inflight),
        probe_sent = maps:remove(JobRef, State#state.probe_sent)
    }.

%% Defensive ack-miss cancel to the worker dispatch (the job may be
%% queued but unacked — same shape as janus_http_worker_client's
%% cancel_dispatch).
probe_cancel(Node, JobRef) ->
    try
        {janus_worker_dispatch, Node} ! janus_worker_wire:cancel(JobRef),
        ok
    catch
        _:_ -> ok
    end.

%% Probe-source sched_rtt write: COLD-START FILL ONLY (spec A.3) —
%% written iff NO unexpired row exists (passive rows win; the master
%% side measures elapsed since dispatch send until Task C's
%% worker-measured value arrives via the load cast). Clamp applies at
%% ingest exactly like passive writes; the EWMA seeds at first sample
%% (the cold-start gate means no unexpired cell exists to continue).
write_probe_rtt(Node, ProviderId, ElapsedMs) ->
    case rtt_row_fresh({Node, ProviderId}, now_mono()) of
        true ->
            ok;
        false ->
            case clamp_rtt(ElapsedMs) of
                {ok, Ms} ->
                    Now = now_mono(),
                    {Ewma, Count} = rtt_ewma_cell(Node, ProviderId, Ms, Now),
                    _ = ets:insert(
                        ?RTT, {{Node, ProviderId}, Ms, probe, Now, Now + ?RTT_TTL_MS, Ewma, Count}
                    ),
                    ok;
                {drop, Reason} ->
                    ok = bump({rtt_dropped, Reason})
            end
    end.

%%%===================================================================
%%% Scheduler v2 — probe candidates (catalog source + injection seam)
%%%===================================================================

%% @doc Probe target PROVIDER candidates (spec Part 0.2):
%% catalog-known AND ENABLED providers. The ETS injection seam
%% (?PROBE_CAND) wins when non-empty — janus_catalog may not be
%% running (eunit, workers), and tests inject pre-resolved candidates
%% instead of mocking the catalog. Deterministic order (sorted by
%% provider id).
-spec probe_candidates() -> [map()].
probe_candidates() ->
    case injected_probe_candidates() of
        [] ->
            catalog_probe_candidates();
        Rows ->
            [Cand || {_Id, Cand} <- Rows]
    end.

injected_probe_candidates() ->
    try
        lists:sort(ets:tab2list(?PROBE_CAND))
    catch
        _:_ -> []
    end.

%% Defensive catalog read (no catalog published => [] — the cascade
%% then no-ops). Candidate shape:
%% #{provider_id, base_url, protocol, listing, secret_ref} — the
%% minimal entitlement-probe inputs: base_url + protocol + first
%% (name-sorted) enabled CHAT listing + first enabled key (the
%% entitlement-probe catalog key pick: enabled keys ordered by id —
%% same source the dashboard probe uses; spending rides the SEPARATE
%% additive JANUS_SCHED_PROBE_MAX_HOURLY budget, never the dashboard's
%% probe_budget_counters).
catalog_probe_candidates() ->
    case catch janus_catalog:get() of
        #{catalog := #{providers := Tid} = Tabs} ->
            try
                [
                    Cand
                 || {Id, Meta} <- lists:sort(ets:tab2list(Tid)),
                    is_map(Meta),
                    maps:get(enabled, Meta, false) =:= true,
                    Cand <- [catalog_probe_candidate(Id, Meta, Tabs)],
                    Cand =/= skip
                ]
            catch
                _:_ -> []
            end;
        _ ->
            []
    end.

catalog_probe_candidate(Id, Meta, Tabs) ->
    case to_bin(maps:get(base_url, Meta, undefined)) of
        undefined ->
            skip;
        Base ->
            Listing = first_chat_listing(Id, Tabs),
            Key = first_enabled_key(Id),
            case {Listing, Key} of
                {undefined, _} ->
                    skip;
                {_, undefined} ->
                    skip;
                _ ->
                    #{
                        provider_id => Id,
                        base_url => Base,
                        protocol => maps:get(protocol, Meta, undefined),
                        listing => Listing,
                        secret_ref => maps:get(secret_ref, Key, undefined)
                    }
            end
    end.

first_chat_listing(Id, Tabs) ->
    case maps:get(listings_by_name, Tabs, undefined) of
        undefined ->
            undefined;
        Tid ->
            try
                Names = lists:sort([
                    Name
                 || {Name, Entries} <- ets:tab2list(Tid),
                    is_list(Entries),
                    lists:any(
                        fun(E) ->
                            is_map(E) andalso
                                maps:get(provider_id, E, undefined) =:= Id andalso
                                maps:get(enabled, E, false) =:= true andalso
                                maps:get(modality, E, <<"chat">>) =:= <<"chat">>
                        end,
                        Entries)
                ]),
                case Names of
                    [] -> undefined;
                    [N | _] -> N
                end
            catch
                _:_ -> undefined
            end
    end.

first_enabled_key(Id) ->
    case [K || #{enabled := true} = K <- janus_catalog:provider_keys(Id)] of
        [K | _] -> K;
        [] -> undefined
    end.

to_bin(B) when is_binary(B), B =/= <<>> -> B;
to_bin(L) when is_list(L), L =/= [] -> list_to_binary(L);
to_bin(_) -> undefined.

%% @doc The minimal entitlement-probe job shape (1 token, one "hi"
%% user message, non-stream — the SAME shape the dashboard's
%% entitlement probe sends, `entitlements._probe_request`): builds the
%% wire Fields map for a probe job. Protocol-correct headers/body per
%% provider protocol; unknown protocols fall back to the openai_chat
%% shape (same default as the dashboard probe). Key pick =
%% entitlement-probe catalog pick (first enabled key, above).
-spec build_probe_job(map()) -> {ok, map()} | {error, term()}.
build_probe_job(#{
    base_url := Base,
    protocol := Protocol,
    listing := Model,
    secret_ref := SecretRef
}) ->
    case probe_secret(SecretRef) of
        {error, _} = Err ->
            Err;
        {ok, Secret} ->
            BaseTrimmed = trim_slashes(Base),
            {Path, Headers, Body} = probe_request_shape(protocol_bin(Protocol), Model, Secret),
            {ok, #{
                url => <<BaseTrimmed/binary, Path/binary>>,
                method => post,
                headers => Headers,
                body => thoas:encode(Body),
                stream => false,
                timeout_ms => janus_worker_wire:non_stream_timeout_ms(),
                protocol_meta => #{}
            }}
    end;
build_probe_job(_) ->
    {error, bad_candidate}.

probe_secret({_, Cipher}) when is_binary(Cipher) ->
    try
        janus_secrets:decrypt(Cipher)
    catch
        _:_ -> {error, decrypt_failed}
    end;
probe_secret(Cipher) when is_binary(Cipher) ->
    try
        janus_secrets:decrypt(Cipher)
    catch
        _:_ -> {error, decrypt_failed}
    end;
probe_secret(_) ->
    {error, bad_secret_ref}.

%% Protocol normalizer: catalog rows carry driver-decoded TEXT
%% binaries (epgsql/esqlite); tolerate atoms too (injection seam).
protocol_bin(P) when is_binary(P) -> P;
protocol_bin(P) when is_atom(P) -> atom_to_binary(P, utf8);
protocol_bin(_) -> <<>>.

%% (base_url, protocol, listing, secret) -> {path, headers, body}.
%% Mirrors the dashboard entitlement probe exactly (max_tokens=1, one
%% "hi" user message, non-stream). Task 3 exclusion: pool-issued probes
%% carry no master trace context (no client request exists here) — the
%% executing worker session mints a fresh trace per job and injects the
%% traceparent itself (janus_worker_session).
probe_request_shape(<<"anthropic_messages">>, Model, Secret) ->
    {
        %% The version segment is part of the catalog base_url
        %% (same join as janus_providers_anthropic) — a hard-coded
        %% /v1 would double-stack .../v1/v1/messages (ocr review).
        <<"/messages">>,
        [
            {<<"x-api-key">>, Secret},
            {<<"anthropic-version">>, <<"2023-06-01">>},
            {<<"content-type">>, <<"application/json">>}
        ],
        #{
            <<"model">> => Model,
            <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
            <<"max_tokens">> => 1,
            <<"stream">> => false
        }
    };
probe_request_shape(<<"openai_responses">>, Model, Secret) ->
    {
        <<"/responses">>,
        [
            {<<"authorization">>, <<"Bearer ", Secret/binary>>},
            {<<"content-type">>, <<"application/json">>}
        ],
        #{<<"model">> => Model, <<"input">> => <<"hi">>, <<"max_output_tokens">> => 1, <<"stream">> => false}
    };
probe_request_shape(_OpenaiChatDefault, Model, Secret) ->
    {
        <<"/chat/completions">>,
        [
            {<<"authorization">>, <<"Bearer ", Secret/binary>>},
            {<<"content-type">>, <<"application/json">>}
        ],
        #{
            <<"model">> => Model,
            <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
            <<"max_tokens">> => 1,
            <<"stream">> => false
        }
    }.

trim_slashes(Bin) when is_binary(Bin) ->
    trim_slashes(Bin, byte_size(Bin)).

trim_slashes(Bin, 0) ->
    Bin;
trim_slashes(Bin, S) ->
    case binary:part(Bin, S - 1, 1) of
        <<"/">> -> trim_slashes(binary:part(Bin, 0, S - 1));
        _ -> Bin
    end.

%%%===================================================================
%%% Scheduler v2 — /stats/sched source assembly
%%%===================================================================

%% Full /stats/sched source view served by the sched_stats call:
%% counters + knob view (geo merged) + display EWMA + raw table rows +
%% the v2.1 A.3 WORKERS ARRAY (the same single F7 snapshot — one
%% gen_server call, no torn joins). The JSON rendering itself is pure
%% and lives in the handler (janus_gateway_stats:sched_json/1).
sched_stats_map(#state{pool = Pool, ewma = Ewma, wire_enc_relay = Relay, load = Load}) ->
    Counters =
        try
            maps:from_list(ets:tab2list(?COUNTERS))
        catch
            _:_ -> #{}
        end,
    {Vals, Src} = janus_sched_knobs:cached_sched(),
    {SyncSec, SyncSrc} = janus_sched_knobs:resolve_model_sync_interval(),
    Health = maps:get(health, Vals, false),
    Rtt = maps:get(rtt, Vals, false),
    Knobs = #{
        rtt => Rtt,
        health => Health,
        probe => maps:get(probe, Vals, false),
        probe_max_hourly => maps:get(probe_max_hourly, Vals, ?PROBE_MAX_HOURLY_DEFAULT),
        probe_force => maps:get(probe_force, pt_read(?PT_KNOBS, #{}), false) =:= true,
        unary_fallback => maps:get(unary_fallback, Vals, false),
        geo_desired => maps:get(geo, Vals, false),
        geo_enabled => geo_enabled_safe(),
        rtt_enabled => Rtt,
        health_enabled => Health,
        model_sync_interval_sec => SyncSec,
        knobs_source => Src#{model_sync_interval_sec => SyncSrc},
        mmdb_present => janus_sched_knobs:mmdb_present(),
        fleet_desired =>
            case janus_sched_knobs:resolve_fleet_desired() of
                null -> null;
                {B, _} -> B
            end,
        fleet_effective => janus_sched_knobs:fleet_effective(),
        sched_geo_refused_total => janus_sched_knobs:geo_refused_total(),
        worker_geo_enabled => worker_geo_on()
    },
    Counters#{
        knobs => Knobs,
        health_ewma => maps:from_list([
            {Node, E}
         || {Node, {E, _Count}} <- maps:to_list(Ewma),
            is_number(E)
        ]),
        rtt_rows => sched_rtt_rows(),
        reserve_rows => reserve_tab(),
        workers => workers_view(Pool, Ewma, Counters, health_enabled(), Load),
        %% D9 (Task C): the aggregated wire-enc view — master-local
        %% decode counters + the latest relayed worker snapshots. Both
        %% /stats/sched (`wire_enc` section) and the prometheus family
        %% consume THIS one view (the same single-snapshot discipline
        %% as the rest of sched_stats).
        wire_enc => aggregate_wire_enc(janus_wire_enc:counters(), Relay)
    }.

%% v2.1 A.3: the repo-side workers view — field-for-field the
%% production surface the operator already watches (node, status,
%% sticky, capacity, region, sched_v, draining, inflight, dispatchable,
%% dispatched_total, health_ewma_ms, rtt_ms_avg, rtt_sample_count,
%% would_demote, git_sha). `inflight` is the LIVE reserve sample;
%% `dispatched_total` sums {dispatch_worker, Node, _};
%% `rtt_ms_avg`/`rtt_sample_count` aggregate the node's UNEXPIRED
%% per-provider EWMA cells (B.2 — DISPLAY-ONLY, never a sort input;
%% ALL expired => null / 0, never 0-valued ms); `would_demote` is null
%% when the EWMA is unknown or health is off. Deterministic order
%% (sorted by node) so the JSON is stable.
%%
%% `capacity` is the EFFECTIVE ceiling (override-resolved, the same
%% number the scheduler enforces); `declared_capacity` is the ADDITIVE
%% raw member-map value so an operator editing the cell can see what
%% the override displaced. The sticky branch below carries neither —
%% it hardcodes infinity.
workers_view(#{members := Members} = Pool, Ewma, Counters, HealthOn, Load) ->
    Now = now_mono(),
    %% Deterministic order (sorted by node) so the JSON is stable; the
    %% members map is keyed by node — already unique.
    lists:sort(
        fun(A, B) -> maps:get(node, A) =< maps:get(node, B) end,
        [
            begin
                RawE =
                    case maps:get(Node, Ewma, none) of
                        {E, _C} when is_number(E) -> E;
                        _ -> unknown
                    end,
                {Avg, SampleCount} = node_rtt_summary(Node, Now),
                FetchedAt = maps:get(egress_fetched_at, M, 0),
                #{
                    node => Node,
                    status => up,
                    sticky => maps:is_key(Node, maps:get(sticky, Pool, #{})),
                    %% Same resolution the snapshot enforces, so the
                    %% cell being edited cannot disagree with the
                    %% scheduler (worker-capacity-override spec Part 1
                    %% "Read path").
                    capacity => effective_capacity(Node, M),
                    %% ADDITIVE: the member map's raw declared value,
                    %% so the UI can show "declared 48, overridden to
                    %% 24" instead of a single unexplained number.
                    %% Equals `capacity` when no override applies.
                    declared_capacity => maps:get(capacity, M, infinity),
                    region => maps:get(region, M, undefined),
                    sched_v => maps:get(sched_v, M, 1),
                    draining => maps:get(draining, M, false),
                    %% The dashboard cell shows REAL work: reserve minus
                    %% suspect, clamped at 0 — the number an operator
                    %% tunes against (spec Part 2). NOT reserve_count/1:
                    %% that function is ALSO used by reconcile_counters/2
                    %% and node_drain_idle_ready/1, which must keep the
                    %% raw counter.
                    inflight => suspect_reserve_count(Node),
                    %% Capacity observability (2026-10-28): the
                    %% worker's latest self-reported beam split
                    %% (total/processes/binary/ets, MB) — null until
                    %% its first load report lands.
                    mem_mb =>
                        case maps:get(Node, Load, undefined) of
                            #{mem_self := Mem} when is_map(Mem) -> Mem;
                            _ -> null
                        end,
                    dispatchable => maps:get(draining, M, false) =:= false,
                    dispatched_total => dispatched_total(Counters, Node),
                    health_ewma_ms => RawE,
                    rtt_ms_avg => Avg,
                    rtt_sample_count => SampleCount,
                    would_demote => would_demote(HealthOn, RawE, demote_ms(Node, Ewma)),
                    git_sha => maps:get(git_sha, M, <<"unknown">>),
                    %% Geo-affinity additive fields (spec 2026-10-11):
                    %% effective overlay geo + mismatch gauge + the
                    %% worker's gw-echo health counters.
                    geo_source => maps:get(geo_source, M, unset),
                    %% The OVERLAY's effective region (null when the
                    %% overlay never ran — the legacy env-class region
                    %% stays visible in `region`, same as v1).
                    geo_region => maps:get(geo_region, M, undefined),
                    geo_mismatch => maps:get(geo_mismatch, M, false) =:= true,
                    egress_fetched_at =>
                        case is_integer(FetchedAt) andalso FetchedAt > 0 of
                            true -> FetchedAt;
                            false -> null
                        end,
                    echo_ok_total => maps:get(echo_ok_total, M, 0),
                    echo_fail_total => maps:get(echo_fail_total, M, 0)
                }
            end
         || {Node, M} <- maps:to_list(Members)
        ]
        ++
        %% Sticky-drained nodes are NOT members (drain-idle removed
        %% them) — surface them too or the `sticky` field can never
        %% be true and operators lose drained-node visibility
        %% (ocr review). Not dispatchable, no live member fields.
        [
            #{
                node => Node,
                status => sticky,
                sticky => true,
                capacity => infinity,
                region => undefined,
                sched_v => 1,
                draining => true,
                inflight => 0,
                dispatchable => false,
                dispatched_total => 0,
                health_ewma_ms => unknown,
                rtt_ms_avg => null,
                rtt_sample_count => 0,
                would_demote => null,
                git_sha => <<"unknown">>,
                geo_source => unset,
                geo_region => null,
                geo_mismatch => false,
                egress_fetched_at => null,
                echo_ok_total => 0,
                echo_fail_total => 0
            }
         || Node <- maps:keys(maps:get(sticky, Pool, #{}))
        ]
    );
workers_view(_, _, _, _, _) ->
    [].

%% Per-node aggregation of the UNEXPIRED per-provider EWMA cells (B.2):
%% arithmetic mean + summed SampleCounts; {null, 0} when none (ALL
%% expired or never sampled — never 0 ms).
node_rtt_summary(Node, Now) ->
    Cells = [
        {Ewma, Count}
     || {{N, _ProviderId}, _Ms, _Source, _SampledAt, ExpiresAt, Ewma, Count} <- sched_rtt_rows(),
        N =:= Node,
        ExpiresAt > Now,
        is_number(Ewma),
        is_integer(Count)
    ],
    case Cells of
        [] ->
            {null, 0};
        _ ->
            Es = [E || {E, _} <- Cells],
            {lists:sum(Es) / length(Es), lists:sum([C || {_, C} <- Cells])}
    end.

dispatched_total(Counters, Node) ->
    lists:sum([
        V
     || {{dispatch_worker, N, _ProviderId}, V} <- maps:to_list(Counters),
        N =:= Node,
        is_integer(V)
    ]).

%% `would_demote` (A.3): health on AND is_number(E) and E > demote_ms —
%% null when unknown/off. demote_ms = infinity (no other measured
%% candidate) never trips: a number is never > infinity in term order,
%% so the comparison itself yields false — only the EWMA's
%% number-ness is guarded (a boolean FALSE, not null: the spec's
%% null-vs-boolean transition distinguishes unknown-EWMA from
%% known-healthy).
would_demote(true, E, DemoteMs) when is_number(E) ->
    E > DemoteMs;
would_demote(_, _, _) ->
    null.

geo_enabled_safe() ->
    try
        janus_geo:geo_enabled()
    catch
        _:_ -> false
    end.


geo_requested_safe() ->
    try
        janus_geo:geo_requested()
    catch
        _:_ -> false
    end.
%%%===================================================================
%%% Scheduler v2 — reconcile / purge (30 s tick, spec Part 0.11)
%%%===================================================================

reconcile(Now, State) ->
    State1 = purge_tracked(Now, State),
    NewExcess = reconcile_counters(tracked_rows(), State#state.excess_seen),
    %% Worker-capacity-override spec Part 2: suspect ⊆ tracked must
    %% hold — a suspect entry whose tracked row is gone (concurrent
    %% release / nodedown between the take and this tick) is drift.
    %% Purge already freed both in take_and_maybe_decrement/1; this
    %% prunes any residue so the load figure cannot stay suppressed.
    ok = reconcile_suspect(),
    prune_absent_nodes(State1#state.pool),
    State1#state{excess_seen = NewExcess}.

%% Suspect counter heal (Part 2): the suspect table is keyed by JobRef
%% and must stay a SUBSET of the tracked table — a suspect entry is
%% only meaningful while its reservation slot still exists. Any suspect
%% JobRef no longer in sched_tracked is stale (its slot was freed by a
%% path that ran before the suspect cast landed, or by nodedown) and is
%% removed. This is the suspect counterpart of reconcile_counters/2's
%% reserve heal — without it a stale entry would suppress the load
%% figure until the next master restart.
reconcile_suspect() ->
    try
        Tracked = sets:from_list([J || {J, _} <- tracked_rows()], [{version, 2}]),
        Stale = [J || {J, _} <- ets:tab2list(?SUSPECT), not sets:is_element(J, Tracked)],
        lists:foreach(fun(J) -> _ = ets:take(?SUSPECT, J) end, Stale),
        ok
    catch
        _:_ -> ok
    end.

%% Purge tracked entries older than PURGE_AGE_MS measured from
%% ReservedAtMono (silently-lost jobs can no longer pin a capacity slot
%% until nodedown) — v2.1 B.1: the per-key `ets:take` spine (NEVER
%% delete-then-decrement: take() owns the decrement, so a concurrent
%% release finds nothing — no double-decrement). NAMED: a job
%% legitimately in flight > 10 min is purged (its slot freed early —
%% the v2 long-stream accepted class; the later release no-ops and the
%% node over-admits by that one job until it completes). Probes are
%% reaped too — without decrement (Internal) and without a
%% reserve_purged count (they never held a slot); a purged probe's
%% in-flight slot IS released (its completion may never arrive; without
%% this the node would stay probe-blocked until nodedown). No skip
%% counter — the launch succeeded; send_fail counts launch failures.
purge_tracked(Now, State) ->
    Expired = [
        JobRef
     || {JobRef, {_Node, ReservedAt, _ProviderId, _Internal}} <- tracked_rows(),
        Now - ReservedAt >= ?PURGE_AGE_MS
    ],
    lists:foldl(
        fun(JobRef, Acc) ->
            case take_and_maybe_decrement(JobRef) of
                {taken, _Node, true} ->
                    %% reserve_purged counts actual RESERVATION slots
                    %% freed — Internal (probe) entries never held one.
                    ok = bump(reserve_purged),
                    Acc;
                {taken, Node, false} ->
                    Acc#state{
                        probe_inflight = maps:remove(Node, Acc#state.probe_inflight),
                        probe_sent = maps:remove(JobRef, Acc#state.probe_sent)
                    };
                none ->
                    %% A concurrent release/nodedown took it first:
                    %% the decrement was theirs.
                    Acc
            end
        end,
        State,
        Expired
    ).

%% Counter vs tracked-set reconcile: decrement the EXCESS only,
%% comparing reserve against the node's NON-INTERNAL tracked rows
%% (`Internal =:= false` — probe rows are tracked but never reserved;
%% counting them would manufacture permanent drift), idempotent; the
%% raw delta is CLAMPED with max(0, reserve - |non-internal|) — a
%% purge/take gap can make it negative and reconcile NEVER mutates
%% tracked, NEVER increments (a take-vs-reconcile heal landing between
%% a caller's take and decrement can UNDERCOUNT — it persists until
%% those jobs complete: the accepted v2.1 softness, named). Negatives
%% are fixed by corrective writes (ets:update_counter cannot clamp —
%% decrement, read, fix if < 0; non-atomic, healed by the tick, spec
%% Part 0.6) for ALL nodes; zero-row deletion is scoped to nodes
%% ABSENT from pool records (prune_absent_nodes — never races a live
%% pick's insert-default).
reconcile_counters(Tracked, PrevExcess) ->
    Expected = expected_by_node(Tracked),
    Nodes = lists:usort(maps:keys(Expected) ++ reserve_nodes()),
    %% mapfoldl returns {MappedList, Acc} — the ACC (per-node excess
    %% map) is what the next tick consumes as PrevExcess.
    {_Mapped, NewExcess} = lists:mapfoldl(
        fun(Node, Seen) ->
            Want = maps:get(Node, Expected, 0),
            Actual = reserve_count(Node),
            Excess = max(0, Actual - Want),
            %% Only decrement excess that ALSO existed at the previous
            %% tick — a fresh excess is (almost always) a pick whose
            %% increment beat its tracked INSERT; the insert lands
            %% within milliseconds and clears itself before the next
            %% tick. Persisting excess is genuine drift (lost insert
            %% / dead caller) and is reclaimed here.
            Persisted = min(Excess, maps:get(Node, PrevExcess, 0)),
            lists:foreach(
                fun(_) ->
                    _ = ets:update_counter(?RESERVE, Node, {2, -1}, {Node, 0})
                end,
                lists:seq(1, Persisted)
            ),
            case reserve_count(Node) < 0 of
                true ->
                    %% Corrective clamp: a release racing nodedown can
                    %% re-create {Node, -1} via the insert-default —
                    %% without the clamp the -1 would persist and
                    %% over-admit by one slot.
                    _ = ets:insert(?RESERVE, {Node, 0});
                false ->
                    ok
            end,
            case Excess of
                E when E > 0 -> {E, Seen#{Node => E}};
                _ -> {Excess, maps:remove(Node, Seen)}
            end
        end,
        #{},
        Nodes
    ),
    NewExcess.

%% Expected reserve per node from the ETS tracked rows — NON-INTERNAL
%% rows only (the reconcile comparison filter, v2.1 B.1).
expected_by_node(Tracked) ->
    lists:foldl(
        fun({_JobRef, {Node, _At, _ProviderId, false}}, Acc) ->
            maps:update_with(Node, fun(C) -> C + 1 end, 1, Acc);
            (_, Acc) ->
                Acc
        end,
        #{},
        Tracked
    ).

reserve_count(Node) ->
    try
        ets:lookup_element(?RESERVE, Node, 2, 0)
    catch
        _:_ -> 0
    end.

%% Worker-capacity-override spec Part 2: per-node suspect count — the
%% number of reservations whose owning job is known dead (marked
%% suspect by a timeout arm). The load figure is reserve - suspect.
%% Keyed by JobRef (not Node) so clear_suspect/1 takes atomically;
%% per-node aggregation uses ets:select_count/2 on the small table.
%% Per-node suspect total, O(1): the ?SUSPECT table stays keyed by JobRef
%% (so clear_suspect/1 is a single atomic take), and this counter is
%% bumped/decremented in the same two places. A select_count/2 traversal
%% here would run on EVERY workers_view call and every pick (through
%% reserve_count_live/1) — a full scan of a table that grows with the
%% timeout rate, precisely on the hot path.
suspect_count(Node) ->
    try
        ets:lookup_element(?SUSPECT_COUNT, Node, 2, 0)
    catch
        _:_ -> 0
    end.

bump_suspect(Node) ->
    _ = ets:update_counter(?SUSPECT_COUNT, Node, {2, 1}, {Node, 0}),
    ok.

drop_suspect(Node) ->
    %% Decrement floor at 0: a purge and a release racing on the same job
    %% must not drive the per-node figure negative and silently over-admit.
    try
        case ets:update_counter(?SUSPECT_COUNT, Node, {2, -1, 0, 0}, {Node, 0}) of
            _ -> ok
        end
    catch
        _:_ -> ok
    end.

%% Clear a job's suspect entry atomically (single-owner rule): called
%% from take_and_maybe_decrement/1 only, so a slot can never be freed
%% without its suspect contribution going with it.
clear_suspect(JobRef) ->
    %% Only the winner of the take may decrement: a job cleared twice (purge
    %% racing a release) must not subtract twice from the per-node total.
    try ets:take(?SUSPECT, JobRef) of
        [{JobRef, Node}] -> drop_suspect(Node);
        _ -> ok
    catch
        _:_ -> ok
    end.

%% Worker-capacity-override spec Part 2: the LOAD FIGURE for sort and
%% display — reserve minus suspect, clamped at 0. Do NOT put this
%% subtraction inside reserve_count/1: that function is ALSO used by
%% reconcile_counters/2 and node_drain_idle_ready/1, which must keep
%% reading the raw counter.
suspect_reserve_count(Node) ->
    suspect_adjusted(reserve_count(Node), suspect_count(Node)).

%% Pure seam (worker-capacity-override spec Part 2): reserve minus suspect,
%% clamped at 0. The clamp is load-bearing — purify and release can race on
%% the same job, and a negative load figure would rank a node as
%% least-loaded while it is at capacity.
-spec suspect_adjusted(non_neg_integer(), non_neg_integer()) -> non_neg_integer().
suspect_adjusted(Reserve, Suspect) when is_integer(Reserve), is_integer(Suspect) ->
    max(0, Reserve - Suspect).

reserve_nodes() ->
    try
        [N || {N, _} <- ets:tab2list(?RESERVE)]
    catch
        _:_ -> []
    end.

%% Delete sched_reserve AND sched_rtt rows (plus stale sched_workers
%% rows) for nodes absent from pool records (spec Part 0.5/0.11 +
%% v2.1 B.1's zero-row deletion scoping — nodes ABSENT from pool
%% records only, never a live pick's insert-default) — immediately
%% post-adopt that is ALL rows.
prune_absent_nodes(#{members := Members}) ->
    Keep = fun(Node) -> maps:is_key(Node, Members) end,
    _ = [ets:delete(?RESERVE, N) || {N, _} <- reserve_tab(), not Keep(N)],
    _ = [ets:delete(?WORKERS, N) || {N, _} <- workers_tab(), not Keep(N)],
    _ = [
        ets:delete(?RTT, Key)
     || {{N, _ProviderId} = Key, _Ms, _Source, _SampledAt, _ExpiresAt, _Ewma, _Count} <- sched_rtt_rows(),
        not Keep(N)
    ],
    ok.

reserve_tab() ->
    try
        ets:tab2list(?RESERVE)
    catch
        _:_ -> []
    end.

workers_tab() ->
    try
        ets:tab2list(?WORKERS)
    catch
        _:_ -> []
    end.

%% Unknown {sched, 2, _} inner tags (newer-version tolerance): bound
%% label for the drop counter.
inner_tag({Tag, _, _}) when is_atom(Tag) ->
    Tag;
inner_tag({Tag, _}) when is_atom(Tag) ->
    Tag;
inner_tag(Tag) when is_atom(Tag) ->
    Tag;
inner_tag(_) ->
    other.

%%%===================================================================
%%% Scheduler v2 — counters (owner-local ETS, tolerant bump pattern)
%%%===================================================================

bump(Key) ->
    try
        _ = ets:update_counter(?COUNTERS, Key, 1, {Key, 0}),
        ok
    catch
        _:_ -> ok
    end.

pt_read(Key, Default) ->
    try
        persistent_term:get(Key)
    catch
        error:badarg -> Default
    end.

env_truthy(false) ->
    false;
env_truthy("") ->
    false;
env_truthy(Val) when is_list(Val) ->
    lists:member(string:lowercase(Val), ["1", "true", "yes", "on"]);
env_truthy(_) ->
    false.

now_mono() ->
    erlang:monotonic_time(millisecond).

%%%===================================================================
%%% Sticky persistence (worker_sticky_drained)
%%%===================================================================

load_sticky() ->
    case q(<<"SELECT node_name FROM worker_sticky_drained">>, []) of
        {ok, Rows} ->
            lists:filtermap(
                fun(R) ->
                    case row_node(R) of
                        {ok, Node} ->
                            {true, Node};
                        {error, Bad} ->
                            logger:error(#{
                                what => janus_worker_pool_sticky_bad_row,
                                row => Bad
                            }),
                            false
                    end
                end,
                Rows
            );
        {error, Reason} ->
            %% Empty sticky on failure would re-admit drained workers —
            %% refuse boot and let the supervisor retry (spec §3.4).
            logger:error(#{what => janus_worker_pool_sticky_load_failed, reason => Reason}),
            error({sticky_load_failed, Reason})
    end.

sticky_insert(Node) ->
    Name = node_name_bin(Node),
    case
        q(
            <<
                "INSERT INTO worker_sticky_drained (node_name) VALUES (?) "
                "ON CONFLICT (node_name) DO NOTHING"
            >>,
            [Name]
        )
    of
        {ok, _} ->
            ok;
        {error, Reason} ->
            logger:warning(#{
                what => janus_worker_pool_sticky_insert_failed,
                node => Node,
                reason => Reason
            }),
            ok
    end.

sticky_delete(Node) ->
    Name = node_name_bin(Node),
    case q(<<"DELETE FROM worker_sticky_drained WHERE node_name = ?">>, [Name]) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            logger:warning(#{
                what => janus_worker_pool_sticky_delete_failed,
                node => Node,
                reason => Reason
            }),
            ok
    end.

node_name_bin(Node) when is_atom(Node) ->
    atom_to_binary(Node, utf8).

row_node([Name]) ->
    row_node(Name);
row_node({Name}) ->
    row_node(Name);
row_node(Name) when is_atom(Name) ->
    {ok, Name};
row_node(Name) when is_binary(Name) ->
    parse_node_name(Name);
row_node(Name) when is_list(Name) ->
    parse_node_name(list_to_binary(Name));
row_node(Other) ->
    {error, Other}.

%% Bound atom creation: Erlang long names look like name@host; reject
%% empty / oversized / @-less TEXT before binary_to_atom.
parse_node_name(Bin) when is_binary(Bin) ->
    Size = byte_size(Bin),
    case Size > 0 andalso Size =< 255 andalso binary:match(Bin, <<"@">>) =/= nomatch of
        true ->
            {ok, binary_to_atom(Bin, utf8)};
        false ->
            {error, Bin}
    end.

q(Sql, Params) ->
    try
        case janus_db_conn:backend() of
            postgres -> janus_db_conn:query(rewrite_pg(Sql), Params);
            _ -> janus_db_conn:query(Sql, Params)
        end
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

rewrite_pg(Sql) ->
    rewrite_pg(Sql, 1).

rewrite_pg(<<"?", Rest/binary>>, N) ->
    <<"$", (integer_to_binary(N))/binary, (rewrite_pg(Rest, N + 1))/binary>>;
rewrite_pg(<<C, Rest/binary>>, N) ->
    <<C, (rewrite_pg(Rest, N))/binary>>;
rewrite_pg(<<>>, _N) ->
    <<>>.
