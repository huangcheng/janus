%%% @doc Master-side worker pool (spec §3.4 / §6; scheduler v2 rev 10).
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
%%% <li>`sched_rtt` — passive RTT samples, TTL 10 min,
%%%   last-arrival-wins.</li>
%%% </ul>
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
-module(janus_worker_pool).
-behaviour(gen_server).

-export([
    start_link/0,
    pick/1,
    pick_sync/1,
    available/0,
    undrain/1,
    note_inflight/2,
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
    apply_inflight/3,
    apply_drain_idle/2,
    select/2,
    available/1,
    is_sticky/2,
    is_draining/2,
    is_member/2,
    inflight/2
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
    advance_divergence/4
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
-define(SNAPSHOT, sched_snapshot).
-define(RESERVE, sched_reserve).
-define(WORKERS, sched_workers).
-define(RTT, sched_rtt).
-define(COUNTERS, sched_counters).

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

-type decisions() :: #{
    geo_source => region_tag | auto | none,
    demoted => [node()]
}.

-record(state, {
    pool :: map(),
    timers = #{} :: #{node() => reference()},
    %% Scheduler v2 (pool gen_server state — dies with the owner, an
    %% accepted cold reset per spec Part 0.5):
    %% JobRef => {Node, ReservedAtMono, ProviderId, Internal} — the
    %% tracked-job set (Internal entries never touch the counter).
    tracked = #{} :: map(),
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
    dirty = false :: boolean(),
    flush_tref = undefined :: reference() | undefined,
    tick_tref = undefined :: reference() | undefined,
    %% Node => ExcessCount seen at the PREVIOUS tick — reconcile
    %% decrements only excess that PERSISTS across two consecutive
    %% ticks (a pick's counter increment lands before its {track}
    %% cast; a same-tick excess is an in-flight register, not drift
    %% — spec Part 0.11 "older than one flush interval", ocr).
    excess_seen = #{} :: #{node() => pos_integer()}
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
    {Order, Decisions} = select_v2(Snapshot, PickOpts),
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

%% @doc Reserve loop (spec Part C step 3): per candidate in order —
%% live drain re-check from `sched_workers` (MISSING row = drained =>
%% refuse, the safe direction), counter increment (the ONE pinned
%% form), capacity comparison SKIPPED entirely when capacity =:=
%% infinity and for affinity-pinned picks (soft cap). Overflow rolls
%% back with the pinned decrement form and tries the next candidate.
%% FIRST success registers the track cast (before the upstream send —
%% register-before-done, spec Part 0.11) and returns; list exhausted =>
%% local fallback with the FIRST non-ok outcome in iteration order.
reserve_loop([], _Snapshot, _Opts, _JobRef, FirstReason) ->
    local_fallback(first_reason(FirstReason, drained));
reserve_loop([Node | Rest], Snapshot, Opts, JobRef, FirstReason) ->
    Pinned = maps:get(affinity_node, Opts, undefined) =:= Node,
    case live_draining(Node) of
        false ->
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
                    _ = gen_server:cast(?SERVER, {sched, 2, {track, JobRef, Node,
                        maps:get(provider_id, Opts, undefined), now_mono(), false}}),
                    {ok, Node};
                true ->
                    %% Rollback decrement form (the 4-tuple UpdateOp is
                    %% FORBIDDEN — SetValue semantics wrap and pin).
                    _ = ets:update_counter(?RESERVE, Node, {2, -1}, {Node, 0}),
                    ok = bump(capacity_exhausted),
                    reserve_loop(Rest, Snapshot, Opts, JobRef, first_reason(FirstReason, capacity))
            end;
        true ->
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
%% ACTUALLY excluded (never-shed-all suppression emits nothing).
emit_pick_metrics(#{geo_source := Source, demoted := Demoted}) ->
    ok = bump({geo_match, Source}),
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

%% @doc Boot knob flags (spec Part C/D): `#{rtt => boolean(), health =>
%% boolean(), probe => boolean(), probe_max_hourly => non_neg_integer(),
%% probe_force => boolean()}`. Read once at boot into persistent_term.
%% GEO lives in `janus_geo` (its own PT key); the /stats/sched view
%% merges `geo_enabled` in (see {@link sched_stats/0}).
-spec knobs() -> map().
knobs() ->
    pt_read(?PT_KNOBS, #{
        rtt => false,
        health => false,
        probe => false,
        probe_max_hourly => ?PROBE_MAX_HOURLY_DEFAULT,
        probe_force => false
    }).

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
    try
        maps:from_list(ets:tab2list(?COUNTERS))
    catch
        _:_ -> #{}
    end.

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

-spec note_inflight(node(), 1 | -1) -> ok.
note_inflight(Node, Delta) when is_atom(Node), (Delta =:= 1 orelse Delta =:= -1) ->
    gen_server:cast(?SERVER, {note_inflight, Node, Delta}).

%% @doc Client-side dispatch-local reason emission (Task C, spec Part
%% C): pick counts its OWN local-fallback reasons; `send_fail` and
%% `ack_miss` happen AFTER pick returned, so `janus_http_worker_client`
%% reports them here (`sched_dispatch_local_total{reason}`).
-spec note_dispatch_local(atom()) -> ok.
note_dispatch_local(Reason) when is_atom(Reason) ->
    ok = bump({dispatch_local, Reason}).

-spec drain_idle_ms() -> pos_integer().
drain_idle_ms() ->
    ?DRAIN_IDLE_MS.

%%%===================================================================
%%% Pure pool (BINDING interfaces for eunit)
%%%===================================================================

-spec new_pool([node()]) -> map().
new_pool(StickyNodes) when is_list(StickyNodes) ->
    Sticky = maps:from_list([{N, true} || N <- StickyNodes, is_atom(N)]),
    #{members => #{}, sticky => Sticky}.

-spec apply_hello(map(), node(), map()) ->
    {ack | {nack, drained | vsn}, map()}.
apply_hello(Pool, Node, Meta) when is_map(Pool), is_atom(Node), is_map(Meta) ->
    case maps:get(vsn, Meta, undefined) of
        ?VSN ->
            case maps:is_key(Node, maps:get(sticky, Pool)) of
                true ->
                    {{nack, drained}, Pool};
                false ->
                    Region = maps:get(region, Meta, undefined),
                    %% Additive hello ingestion (spec Part 0.10): old
                    %% shapes admit with defaults (capacity=infinity,
                    %% sched_v=1) — the pure function never sees raw
                    %% wire garbage.
                    Capacity = maps:get(capacity, Meta, infinity),
                    SchedV = maps:get(sched_v, Meta, 1),
                    Members0 = maps:get(members, Pool),
                    case maps:find(Node, Members0) of
                        {ok, #{draining := true} = M} ->
                            %% Ack but stay draining (not re-activated).
                            %% A repeat (keepalive) hello refreshes
                            %% region/capacity/sched_v WITHOUT resetting
                            %% inflight (idempotent admit, spec Part 0.5).
                            Members1 = Members0#{
                                Node => M#{region => Region, capacity => Capacity, sched_v => SchedV}
                            },
                            {ack, Pool#{members => Members1}};
                        {ok, M} ->
                            Members1 = Members0#{
                                Node => M#{region => Region, capacity => Capacity, sched_v => SchedV}
                            },
                            {ack, Pool#{members => Members1}};
                        error ->
                            Member = #{
                                region => Region,
                                inflight => 0,
                                draining => false,
                                capacity => Capacity,
                                sched_v => SchedV
                            },
                            {ack, Pool#{members => Members0#{Node => Member}}}
                    end
            end;
        _ ->
            {{nack, vsn}, Pool}
    end.

-spec apply_drain(map(), node()) -> {map(), boolean()}.
apply_drain(Pool, Node) when is_map(Pool), is_atom(Node) ->
    Members0 = maps:get(members, Pool),
    case maps:find(Node, Members0) of
        {ok, #{draining := true}} ->
            {Pool, false};
        {ok, #{inflight := In} = M} ->
            Members1 = Members0#{Node => M#{draining => true}},
            {Pool#{members => Members1}, In =:= 0};
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

-spec apply_inflight(map(), node(), 1 | -1) -> {map(), boolean()}.
apply_inflight(Pool, Node, Delta) when
    is_map(Pool), is_atom(Node), (Delta =:= 1 orelse Delta =:= -1)
->
    Members0 = maps:get(members, Pool),
    case maps:find(Node, Members0) of
        {ok, #{inflight := In0, draining := Draining} = M} ->
            In1 = max(0, In0 + Delta),
            Members1 = Members0#{Node => M#{inflight => In1}},
            StartIdle = Draining andalso In1 =:= 0 andalso In0 =/= 0,
            {Pool#{members => Members1}, StartIdle};
        error ->
            {Pool, false}
    end.

-spec apply_drain_idle(map(), node()) -> {map(), boolean()}.
apply_drain_idle(Pool, Node) when is_map(Pool), is_atom(Node) ->
    Members0 = maps:get(members, Pool),
    case maps:find(Node, Members0) of
        {ok, #{draining := true, inflight := 0}} ->
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

-spec select(map(), map()) -> {ok, node()} | empty.
select(Pool, Opts) when is_map(Pool), is_map(Opts) ->
    Candidates = dispatchable(Pool),
    case Candidates of
        [] ->
            empty;
        _ ->
            AffinityNode = maps:get(affinity_node, Opts, undefined),
            RegionTag = maps:get(region_tag, Opts, undefined),
            Matched =
                case AffinityNode of
                    N when is_atom(N) ->
                        case lists:keyfind(N, 1, Candidates) of
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
                             || {N, M} <- Candidates,
                                maps:get(region, M, undefined) =:= RegionTag
                            ]
                        of
                            [] -> Candidates;
                            RegionHits -> RegionHits
                        end;
                    [] ->
                        Candidates
                end,
            least_inflight(Chosen)
    end.

-spec available(map()) -> non_neg_integer().
available(Pool) when is_map(Pool) ->
    length(dispatchable(Pool)).

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

-spec inflight(map(), node()) -> non_neg_integer().
inflight(Pool, Node) ->
    case maps:find(Node, maps:get(members, Pool)) of
        {ok, #{inflight := N}} -> N;
        error -> 0
    end.

dispatchable(#{members := Members}) ->
    [
        {N, M}
     || {N, #{draining := false} = M} <- maps:to_list(Members)
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
                    {[Node], #{geo_source => none, demoted => []}};
                false ->
                    %% Pinned node absent/draining => continue down the
                    %% tiers (v1 affinity-miss path).
                    tiers(Candidates, Opts)
            end;
        _ ->
            tiers(Candidates, Opts)
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

%% Tier 5 — sort by `{rtt_key, inflight, name}`: rtt_key =
%% `rtt_map[provider_id]` or `infinity` when absent — the atom sorts
%% after all floats in Erlang term order (unknown-rtt sorts LAST, no
%% tuple sentinel). `rtt_enabled = false` forces `rtt_key := infinity`
%% for ALL candidates => exactly v1's `(inflight, name)`.
sort_tier(Candidates, Opts) ->
    RttOn = maps:get(rtt_enabled, Opts, false) =:= true,
    ProviderId = maps:get(provider_id, Opts, undefined),
    SortKey = fun({N, M}) ->
        RttKey =
            case RttOn of
                true ->
                    maps:get(ProviderId, maps:get(rtt_map, M, #{}), infinity);
                false ->
                    infinity
            end,
        {RttKey, maps:get(inflight, M, 0), N}
    end,
    Sorted = lists:sort(fun(A, B) -> SortKey(A) =< SortKey(B) end, Candidates),
    [N || {N, _} <- Sorted].

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
%%% gen_server
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    ok = boot_knobs(),
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
    {ok, arm_tick(State1)}.

handle_call({pick_sync, Opts}, _From, #state{pool = Pool} = State) ->
    {reply, select(Pool, Opts), State};
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

handle_cast({note_inflight, Node, Delta}, State) ->
    {noreply, mark_dirty(do_inflight(Node, Delta, State))};
%% -- Scheduler v2 `{sched, 2, _}` casts (spec Part 0.11 / A.3 / A.4).
%% Sent via gen_server:cast => an older master's catch-all below drops
%% and counts them (delivery-class tolerance, spec Part 0.10). --
handle_cast({sched, 2, {track, JobRef, Node, ProviderId, ReservedAtMono, Internal}}, State) when
    is_atom(Node), is_boolean(Internal)
->
    %% Reservation registered by the WINNING candidate only (pick
    %% increments the counter itself; probes arrive here with
    %% Internal=true and NO prior increment — the track cast is
    %% decoupled from the counter, spec rev 9). NO counter bump here.
    Tracked = maps:put(JobRef, {Node, ReservedAtMono, ProviderId, Internal}, State#state.tracked),
    {noreply, State#state{tracked = Tracked}};
handle_cast({sched, 2, {release, JobRef}}, State) ->
    case maps:take(JobRef, State#state.tracked) of
        {{Node, _At, _ProviderId, false}, Tracked1} ->
            %% Release decrements IFF still tracked AND NOT Internal
            %% (probes are never decremented — Internal => never
            %% incremented). A post-purge / unknown release is a NO-OP
            %% (idempotent, no negative).
            _ = ets:update_counter(?RESERVE, Node, {2, -1}, {Node, 0}),
            {noreply, State#state{tracked = Tracked1}};
        {{_Node, _At, _ProviderId, true}, Tracked1} ->
            {noreply, State#state{tracked = Tracked1}};
        error ->
            {noreply, State}
    end;
handle_cast({sched, 2, {ttfb, JobRef, ElapsedMs}}, State) ->
    %% Health feed (spec A.4): successful NON-INTERNAL completions only
    %% (the caller filters; the tracked Internal flag is re-checked
    %% defensively — probes never feed the health EWMA). Pinned-path
    %% completions feed it exactly like unpinned ones (real jobs).
    case maps:find(JobRef, State#state.tracked) of
        {ok, {Node, _At, _ProviderId, false}} when is_number(ElapsedMs) ->
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
    %% A.3): last-arrival-wins bounded by the 10-min TTL. Internal
    %% (probe) and post-purge jobs are SKIPPED at ingest (seam 2, spec
    %% E.6) — never written, never counted.
    case maps:find(JobRef, State#state.tracked) of
        {ok, {Node, _At, ProviderId, false}} ->
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
handle_cast({sched, 2, Unknown}, State) ->
    %% Unknown `{sched, 2, _}` inner tag (a newer worker's load/probe
    %% cast against this master): dropped + counted.
    ok = bump({sched_unknown, inner_tag(Unknown)}),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sched_flush, State) ->
    %% Dirty-flush path: republish at most every FLUSH_MS.
    case State#state.dirty of
        true -> {noreply, republish(State#state{dirty = false})};
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
    State2 = maybe_kick_probe(republish(State1)),
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
            From ! janus_worker_wire:hello_ack(Node),
            %% Maintain the live drain-flag row (spec Part 0.6): a
            %% draining member keeps its true flag ("ack but stay
            %% draining"); a fresh admit writes `false`.
            _ = ets:insert(?WORKERS, {Node, is_draining(Pool1, Node)}),
            mark_dirty(State#state{pool = Pool1});
        {nack, Reason} ->
            case janus_worker_wire:hello_nack(Node, Reason) of
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

do_drain(Node, #state{pool = Pool} = State) ->
    {Pool1, StartIdle} = apply_drain(Pool, Node),
    State1 =
        case is_member(Pool1, Node) of
            true ->
                _ = ets:insert(?WORKERS, {Node, is_draining(Pool1, Node)}),
                mark_dirty(State#state{pool = Pool1});
            false ->
                State#state{pool = Pool1}
        end,
    maybe_arm_idle(Node, StartIdle, State1).

do_inflight(Node, Delta, #state{pool = Pool} = State) ->
    {Pool1, StartIdle} = apply_inflight(Pool, Node, Delta),
    %% Snapshot carries the inflight sample — every change is dirty.
    State1 = mark_dirty(State#state{pool = Pool1}),
    case StartIdle of
        true ->
            maybe_arm_idle(Node, true, State1);
        false ->
            %% Inflight rose while draining — cancel pending idle clock.
            case inflight(Pool1, Node) > 0 of
                true -> cancel_timer(Node, State1);
                false -> State1
            end
    end.

do_drain_idle(Node, #state{pool = Pool} = State0) ->
    State = forget_timer(Node, State0),
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
    end.

do_nodedown(Node, #state{pool = Pool} = State) ->
    Pool1 = apply_nodedown(Pool, Node),
    %% Clear ALL scheduler state for the node (spec Part 0.4): pool
    %% records + sched_workers row + reserve row + rtt rows +
    %% divergence window + probe-cadence state and the probe in-flight
    %% map (Part 0.2/0.5 clear-list). Tracked entries for a dead node
    %% never complete — removing them makes late releases no-ops (the
    %% counter row is gone; no decrement, no Default-tuple
    %% resurrection). Health-EWMA state is NOT cleared here (the spec
    %% clear-list keeps it; owner restart clears it — pool state).
    _ = ets:delete(?WORKERS, Node),
    _ = ets:delete(?RESERVE, Node),
    ok = delete_rtt_rows(Node),
    Tracked1 = maps:filter(fun(_JobRef, {N, _, _, _}) -> N =/= Node end, State#state.tracked),
    logger:info(#{what => janus_worker_pool_nodedown, node => Node}),
    cancel_timer(
        Node,
        mark_dirty(State#state{
            pool = Pool1,
            tracked = Tracked1,
            divergence = maps:remove(Node, State#state.divergence),
            load = maps:remove(Node, State#state.load),
            probe_inflight = maps:remove(Node, State#state.probe_inflight),
            probe_sent = maps:filter(
                fun(_JobRef, {N, _, _, _}) -> N =/= Node end, State#state.probe_sent
            ),
            probe_last = maps:filter(
                fun({N, _ProviderId}, _At) -> N =/= Node end, State#state.probe_last
            )
        })
    ).

normalize_hello_meta(Node, Meta) when is_map(Meta) ->
    #{
        role => maps:get(role, Meta, undefined),
        vsn => maps:get(vsn, Meta, undefined),
        region => maps:get(region, Meta, undefined),
        capacity => normalize_capacity(Node, maps:get(capacity, Meta, undefined)),
        sched_v => normalize_sched_v(maps:get(sched_v, Meta, undefined))
    };
normalize_hello_meta(_Node, _) ->
    #{role => undefined, vsn => undefined, region => undefined, capacity => infinity, sched_v => 1}.

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

maybe_arm_idle(_Node, false, State) ->
    State;
maybe_arm_idle(Node, true, State) ->
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

%% Boot knob flags (env read ONCE; restart to change — spec Part C/D).
%% GEO belongs to janus_geo; probe knobs (Task B2):
%% JANUS_SCHED_PROBE (default off), JANUS_SCHED_PROBE_MAX_HOURLY
%% (default 10, cluster-wide), test-only JANUS_SCHED_PROBE_FORCE
%% (loud warning — never in prod).
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
    persistent_term:put(?PT_KNOBS, #{
        rtt => env_truthy(os:getenv("JANUS_SCHED_RTT")),
        health => env_truthy(os:getenv("JANUS_SCHED_HEALTH")),
        probe => env_truthy(os:getenv("JANUS_SCHED_PROBE")),
        probe_max_hourly => env_pos_int(
            os:getenv("JANUS_SCHED_PROBE_MAX_HOURLY"), ?PROBE_MAX_HOURLY_DEFAULT
        ),
        probe_force => Force
    }),
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
%% transfer), else create with the heir set. ON ADOPT: reset
%% sched_reserve via delete_all_objects (the tracked map died with the
%% old owner so surviving counters are orphans — the pinned single
%% mechanism); prune sched_workers rows for nodes absent from pool
%% records — at init that is ALL rows (a COLD RESET: every worker must
%% re-hello post-adopt, spec Part 0.5). The immediate reconcile in
%% init/1 then also deletes ALL sched_rtt rows (no pool records yet —
%% a cold RTT reset in the accepted class). Returns the adopted tags.
ensure_sched_tables() ->
    Heir = heir_with_retry(),
    Opts = [set, public, named_table, {read_concurrency, true}],
    Results = [
        adopt_or_create(?SNAPSHOT, Opts, Heir),
        adopt_or_create(?RESERVE, Opts ++ [{write_concurrency, true}], Heir),
        adopt_or_create(?WORKERS, Opts, Heir),
        adopt_or_create(?RTT, Opts, Heir)
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
            _ = ets:delete_all_objects(?RESERVE),
            logger:info(#{what => janus_worker_pool_tables_adopted, tables => Adopted})
    end,
    Adopted.

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
    case adopt_retry(Tag, ?ADOPT_RETRIES) of
        {ok, _Tab} ->
            {adopted, Tag};
        not_held ->
            _ = ets:new(Tag, Opts ++ [{heir, Heir, {Tag, self()}}]),
            {created, Tag}
    end.

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

%% Joins pool worker records + unexpired sched_rtt rows + EWMA state;
%% precomputes per-candidate demote_ms (exclude-self, spec A.4).
%% Provider geo is NOT in the worker-keyed snapshot — it lives in the
%% persistent_term map read lock-free by pick.
build_snapshot(#state{pool = #{members := Members}, ewma = Ewma}) ->
    Now = now_mono(),
    RttByNode = rtt_by_node(Now),
    [
        {Node, #{
            inflight => maps:get(inflight, M, 0),
            capacity => maps:get(capacity, M, infinity),
            draining => maps:get(draining, M, false),
            geo_region => maps:get(region, M, undefined),
            rtt_map => maps:get(Node, RttByNode, #{}),
            observed_ewma_ms => observed_ewma(maps:get(Node, Ewma, none)),
            demote_ms => demote_ms(Node, Ewma)
        }}
     || {Node, M} <- maps:to_list(Members)
    ].

rtt_by_node(Now) ->
    lists:foldl(
        fun
            ({{Node, ProviderId}, Ms, _Source, _SampledAt, ExpiresAt}, Acc) when
                ExpiresAt > Now, is_number(Ms)
            ->
                maps:update_with(Node, fun(Rm) -> Rm#{ProviderId => Ms} end, #{ProviderId => Ms}, Acc);
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
%%% Scheduler v2 — {sched, 2, _} ingestion (advisory load, passive rtt)
%%%===================================================================

%% Advisory load cast (spec Part 0.3): store for ops display and run
%% the divergence window against the master-observed EWMA. The load
%% cast keeps its own suppression rule worker-side; a steady-state
%% lying worker may never send (documented starvation of the mismatch
%% counter — accepted v1).
do_load(Node, Info, #state{ewma = Ewma, divergence = Div, load = Load} = State) when
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
            ewma_upstream_ms => Reported
        }},
        divergence = Div1
    };
do_load(_Node, _Info, State) ->
    State.

%% Passive sched_rtt write: clamp at MASTER ingest (spec A.3); row
%% shape {{Node, ProviderId}, RttMs, Source, SampledAtMono,
%% ExpiresAtMono}; LAST-ARRIVAL-WINS (handler serialization makes the
%% message being handled the newest — no stamp compare exists).
write_passive_rtt(Node, ProviderId, RttMs) ->
    case clamp_rtt(RttMs) of
        {ok, Ms} ->
            Now = now_mono(),
            _ = ets:insert(?RTT, {{Node, ProviderId}, Ms, passive, Now, Now + ?RTT_TTL_MS}),
            ok;
        {drop, Reason} ->
            ok = bump({rtt_dropped, Reason})
    end.

delete_rtt_rows(Node) ->
    _ = [
        ets:delete(?RTT, Key)
     || {{N, _ProviderId} = Key, _Ms, _Source, _SampledAt, _ExpiresAt} <- sched_rtt_rows(),
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
            [{_Key, _Ms, _Source, _SampledAt, ExpiresAt}] -> ExpiresAt > Now;
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

%% Register the issued probe: the SAME {track, ...} tuple shape as
%% pick's winners but Internal => true and NO counter increment (the
%% track cast is decoupled from the counter, spec rev 9); in-flight
%% map, cadence stamp, cap window; ack deadline timer (the timeout
%% handler re-validates the Acked flag — no timer ref bookkeeping).
probe_issue(JobRef, Node, ProviderId, Window, State) ->
    SentAt = now_mono(),
    _TRef = erlang:send_after(
        janus_worker_wire:ack_deadline_ms(), self(), {probe_ack_timeout, JobRef}
    ),
    Tracked = (State#state.tracked)#{JobRef => {Node, SentAt, ProviderId, true}},
    Inflight = (State#state.probe_inflight)#{Node => JobRef},
    ProbeSent = (State#state.probe_sent)#{JobRef => {Node, ProviderId, SentAt, false}},
    ProbeLast = (State#state.probe_last)#{{Node, ProviderId} => SentAt},
    State#state{
        tracked = Tracked,
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
%% REMOVED without decrement (Internal => never incremented), the
%% in-flight slot and dispatch details go with it.
probe_clear(JobRef, Node, State) ->
    State#state{
        tracked = maps:remove(JobRef, State#state.tracked),
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
%% ingest exactly like passive writes.
write_probe_rtt(Node, ProviderId, ElapsedMs) ->
    case rtt_row_fresh({Node, ProviderId}, now_mono()) of
        true ->
            ok;
        false ->
            case clamp_rtt(ElapsedMs) of
                {ok, Ms} ->
                    Now = now_mono(),
                    _ = ets:insert(?RTT, {{Node, ProviderId}, Ms, probe, Now, Now + ?RTT_TTL_MS}),
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
%% "hi" user message, non-stream).
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
%% counters + knob view (geo merged) + display EWMA + raw table rows.
%% The JSON rendering itself is pure and lives in the handler
%% (janus_gateway_stats:sched_json/1).
sched_stats_map(#state{ewma = Ewma}) ->
    Counters =
        try
            maps:from_list(ets:tab2list(?COUNTERS))
        catch
            _:_ -> #{}
        end,
    Knobs = (knobs())#{
        geo_enabled => geo_enabled_safe(),
        rtt_enabled => rtt_enabled(),
        health_enabled => health_enabled()
    },
    Counters#{
        knobs => Knobs,
        health_ewma => maps:from_list([
            {Node, E}
         || {Node, {E, _Count}} <- maps:to_list(Ewma),
            is_number(E)
        ]),
        rtt_rows => sched_rtt_rows(),
        reserve_rows => reserve_tab()
    }.

geo_enabled_safe() ->
    try
        janus_geo:geo_enabled()
    catch
        _:_ -> false
    end.

%%%===================================================================
%%% Scheduler v2 — reconcile / purge (30 s tick, spec Part 0.11)
%%%===================================================================

reconcile(Now, #state{tracked = Tracked, excess_seen = Seen} = State) ->
    State1 = purge_tracked(Now, Tracked, State),
    NewExcess = reconcile_counters(State1#state.tracked, Seen),
    prune_absent_nodes(State1#state.pool),
    State1#state{excess_seen = NewExcess}.

%% Purge tracked entries older than PURGE_AGE_MS measured from
%% ReservedAtMono (silently-lost jobs can no longer pin a capacity
%% slot until nodedown): removed + decremented ONCE (skip Internal —
%% never incremented) + sched_reserve_purged_total.
purge_tracked(Now, Tracked, State) ->
    {Expired, Kept} =
        lists:partition(
            fun({_JobRef, {_Node, ReservedAt, _ProviderId, _Internal}}) ->
                Now - ReservedAt >= ?PURGE_AGE_MS
            end,
            maps:to_list(Tracked)
        ),
    State1 =
        lists:foldl(
            fun({JobRef, {Node, _ReservedAt, _ProviderId, Internal}}, Acc) ->
                %% reserve_purged counts actual RESERVATION slots
                %% freed — Internal (probe) entries never held one
                %% (ocr review). A purged probe also releases its
                %% in-flight slot (its completion may never arrive;
                %% without this the node would stay probe-blocked
                %% until nodedown). No skip counter — the launch
                %% succeeded; send_fail counts launch failures.
                case Internal of
                    false ->
                        _ = ets:update_counter(?RESERVE, Node, {2, -1}, {Node, 0}),
                        ok = bump(reserve_purged),
                        Acc;
                    true ->
                        Acc#state{
                            probe_inflight = maps:remove(Node, Acc#state.probe_inflight),
                            probe_sent = maps:remove(JobRef, Acc#state.probe_sent)
                        }
                end
            end,
            State,
            Expired
        ),
    State1#state{tracked = maps:from_list(Kept)}.

%% Counter vs tracked-set reconcile: decrement the EXCESS only
%% (Internal entries are SKIPPED by the excess math — counter
%% neutrality), idempotent; negatives are fixed by corrective writes
%% (ets:update_counter cannot clamp — decrement, read, fix if < 0;
%% non-atomic, healed by the tick, spec Part 0.6).
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
            %% increment beat its {track} cast; the register lands
            %% within milliseconds and clears itself before the next
            %% tick. Persisting excess is genuine drift (lost register
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

expected_by_node(Tracked) ->
    lists:foldl(
        fun({_JobRef, {Node, _At, _ProviderId, false}}, Acc) ->
            maps:update_with(Node, fun(C) -> C + 1 end, 1, Acc);
            (_, Acc) ->
                Acc
        end,
        #{},
        maps:to_list(Tracked)
    ).

reserve_count(Node) ->
    try
        ets:lookup_element(?RESERVE, Node, 2, 0)
    catch
        _:_ -> 0
    end.

reserve_nodes() ->
    try
        [N || {N, _} <- ets:tab2list(?RESERVE)]
    catch
        _:_ -> []
    end.

%% Delete sched_reserve AND sched_rtt rows (plus stale sched_workers
%% rows) for nodes absent from pool records (spec Part 0.5/0.11) —
%% immediately post-adopt that is ALL rows.
prune_absent_nodes(#{members := Members}) ->
    Keep = fun(Node) -> maps:is_key(Node, Members) end,
    _ = [ets:delete(?RESERVE, N) || {N, _} <- reserve_tab(), not Keep(N)],
    _ = [ets:delete(?WORKERS, N) || {N, _} <- workers_tab(), not Keep(N)],
    _ = [
        ets:delete(?RTT, Key)
     || {{N, _ProviderId} = Key, _Ms, _Source, _SampledAt, _ExpiresAt} <- sched_rtt_rows(),
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
