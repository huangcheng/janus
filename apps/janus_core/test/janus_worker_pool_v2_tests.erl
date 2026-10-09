%%% @doc Scheduler v2 tests for `janus_worker_pool` (spec rev 10,
%%% Parts B / C: E.2 tier matrix, E.3 v1-equivalence, E.4 live reserve
%%% loop, E.8 EWMA math, divergence window, RTT clamp; Task B2 E.4b —
%%% probe dispatch / five skip reasons / ack-miss abort).
%%%
%%% Pure tier-matrix tests run without processes. Live tests boot the
%%% REAL pool gen_server (janus_usage precedent — stateful modules are
%%% tested live) on a real sqlite backend: the pool's init loads sticky
%%% state from the DB and a failed load REFUSES boot, so the fixture
%%% starts `janus_db_conn` (sqlite, temp file) plus the real
%%% `janus_ets_heir`. Public ETS tables are driven directly with
%%% production-shaped rows (the reserve loop's contract is the table
%%% content, not a mock).
-module(janus_worker_pool_v2_tests).

-include_lib("eunit/include/eunit.hrl").

-define(A, 'v2w_a@127.0.0.1').
-define(B, 'v2w_b@127.0.0.1').
-define(C, 'v2w_c@127.0.0.1').
-define(D, 'v2w_d@127.0.0.1').
-define(E, 'v2w_e@127.0.0.1').

-define(DEFAULT_OPTS, #{geo_enabled => false, rtt_enabled => false, health_enabled => false}).

%%%===================================================================
%%% E.2 — select_v2 tier matrix (pure)
%%%===================================================================

select_v2_affinity_absolute_test() ->
    %% Pinned node is sick AND cross-geo: the pin outranks everything.
    Snap = [
        {?A, meta(#{observed_ewma_ms => 90000.0, demote_ms => 5000, geo_region => <<"us">>})},
        {?B, meta(#{geo_region => <<"cn-east">>, inflight => 0})}
    ],
    Opts = ?DEFAULT_OPTS#{
        affinity_node => ?A,
        health_enabled => true,
        geo_enabled => true,
        provider_geo => <<"cn-east">>
    },
    {Order, Decisions} = janus_worker_pool:select_v2(Snap, Opts),
    ?assertEqual([?A], Order),
    ?assertEqual(#{geo_source => none, demoted => []}, Decisions).

select_v2_affinity_miss_falls_through_test() ->
    Snap = [
        {?A, meta(#{geo_region => <<"cn-east">>})},
        {?B, meta(#{geo_region => <<"us">>, inflight => 1})}
    ],
    %% Pinned node absent from the snapshot => v1 affinity-miss path.
    {Order, Decisions} = janus_worker_pool:select_v2(Snap, ?DEFAULT_OPTS#{affinity_node => ?C}),
    ?assertEqual([?A, ?B], Order),
    ?assertEqual(#{geo_source => none, demoted => []}, Decisions).

select_v2_affinity_draining_falls_through_test() ->
    Snap = [
        {?A, meta(#{draining => true})},
        {?B, meta(#{})}
    ],
    {Order, _} = janus_worker_pool:select_v2(Snap, ?DEFAULT_OPTS#{affinity_node => ?A}),
    ?assertEqual([?B], Order).

select_v2_health_before_geo_test() ->
    %% A is sick AND same-geo; B is healthy but cross-geo. Health
    %% outranks preference: A is shed despite matching the comparator.
    Snap = [
        {?A, meta(#{observed_ewma_ms => 9000.0, demote_ms => 5000, geo_region => <<"cn-east">>})},
        {?B, meta(#{geo_region => <<"us">>})}
    ],
    Opts = ?DEFAULT_OPTS#{health_enabled => true, geo_enabled => true, provider_geo => <<"cn-east">>},
    {Order, Decisions} = janus_worker_pool:select_v2(Snap, Opts),
    ?assertEqual([?B], Order),
    %% No geo candidate remains after the shed: source none, demoted
    %% lists ONLY the actual exclusion.
    ?assertEqual(#{geo_source => none, demoted => [?A]}, Decisions).

select_v2_never_shed_all_test() ->
    Snap = [
        {?A, meta(#{observed_ewma_ms => 9000.0, demote_ms => 5000})},
        {?B, meta(#{observed_ewma_ms => 8000.0, demote_ms => 5000})}
    ],
    {Order, Decisions} = janus_worker_pool:select_v2(Snap, ?DEFAULT_OPTS#{health_enabled => true}),
    ?assertEqual([?A, ?B], Order),
    %% Suppression emits NOTHING into demoted.
    ?assertEqual(#{geo_source => none, demoted => []}, Decisions).

select_v2_health_off_keeps_sick_test() ->
    Snap = [{?A, meta(#{observed_ewma_ms => 9000.0, demote_ms => 5000})}],
    {Order, Decisions} = janus_worker_pool:select_v2(Snap, ?DEFAULT_OPTS),
    ?assertEqual([?A], Order),
    ?assertEqual([], maps:get(demoted, Decisions)).

select_v2_unknown_vs_unknown_no_match_test() ->
    %% provider_geo unknown => no auto comparator (unknown-vs-unknown
    %% never matches); even known-comparator vs unknown candidate
    %% geo does not match.
    SnapUnknown = [{?A, meta(#{geo_region => unknown})}, {?B, meta(#{geo_region => undefined})}],
    {Order1, D1} = janus_worker_pool:select_v2(
        SnapUnknown, ?DEFAULT_OPTS#{geo_enabled => true, provider_geo => unknown}
    ),
    ?assertEqual([?A, ?B], Order1),
    ?assertEqual(none, maps:get(geo_source, D1)),
    SnapKnown = [{?A, meta(#{geo_region => undefined})}, {?B, meta(#{geo_region => unknown})}],
    {Order2, D2} = janus_worker_pool:select_v2(
        SnapKnown, ?DEFAULT_OPTS#{geo_enabled => true, provider_geo => <<"cn-east">>}
    ),
    ?assertEqual([?A, ?B], Order2),
    ?assertEqual(none, maps:get(geo_source, D2)).

select_v2_other_matches_other_test() ->
    Snap = [{?A, meta(#{geo_region => <<"other">>})}, {?B, meta(#{geo_region => <<"cn-east">>})}],
    {Order, Decisions} = janus_worker_pool:select_v2(
        Snap, ?DEFAULT_OPTS#{geo_enabled => true, provider_geo => <<"other">>}
    ),
    ?assertEqual([?A], Order),
    ?assertEqual(auto, maps:get(geo_source, Decisions)).

select_v2_geo_narrows_never_excludes_test() ->
    %% Known comparator matching no worker: keep ALL (source none).
    Snap = [{?A, meta(#{geo_region => <<"cn-east">>})}, {?B, meta(#{geo_region => <<"us">>})}],
    {Order, Decisions} = janus_worker_pool:select_v2(
        Snap, ?DEFAULT_OPTS#{geo_enabled => true, provider_geo => <<"eu">>}
    ),
    ?assertEqual([?A, ?B], Order),
    ?assertEqual(none, maps:get(geo_source, Decisions)).

select_v2_region_tag_ungated_test() ->
    %% Legacy region_tag comparator is ALWAYS active (knob-independent).
    Snap = [{?A, meta(#{geo_region => <<"cn-east">>})}, {?B, meta(#{geo_region => <<"us">>, inflight => 0})}],
    {Order, Decisions} = janus_worker_pool:select_v2(
        Snap, ?DEFAULT_OPTS#{region_tag => <<"cn-east">>}
    ),
    ?assertEqual([?A], Order),
    ?assertEqual(region_tag, maps:get(geo_source, Decisions)).

select_v2_region_tag_beats_auto_test() ->
    %% region_tag set => it IS the comparator; provider_geo ignored.
    Snap = [{?A, meta(#{geo_region => <<"us">>})}, {?B, meta(#{geo_region => <<"eu">>})}],
    {Order, Decisions} = janus_worker_pool:select_v2(
        Snap,
        ?DEFAULT_OPTS#{
            region_tag => <<"eu">>, geo_enabled => true, provider_geo => <<"us">>
        }
    ),
    ?assertEqual([?B], Order),
    ?assertEqual(region_tag, maps:get(geo_source, Decisions)).

select_v2_new_worker_never_demoted_test() ->
    %% observed_ewma_ms unknown (below 3 samples): the is_number guard
    %% keeps it out of demoted even with a tiny demote_ms.
    Snap = [{?A, meta(#{observed_ewma_ms => unknown, demote_ms => 5000})}, {?B, meta(#{observed_ewma_ms => 100.0, demote_ms => 5000})}],
    {Order, Decisions} = janus_worker_pool:select_v2(Snap, ?DEFAULT_OPTS#{health_enabled => true}),
    ?assertEqual([?A, ?B], Order),
    ?assertEqual([], maps:get(demoted, Decisions)).

select_v2_single_worker_demote_infinity_test() ->
    %% No OTHER measured candidate => demote_ms infinity => tier inert.
    ?assertEqual(infinity, janus_worker_pool:demote_ms(?A, #{?A => {8000.0, 5}})),
    ?assertEqual(infinity, janus_worker_pool:demote_ms(?A, #{?A => {8000.0, 5}, ?B => {500.0, 2}})),
    Snap = [{?A, meta(#{observed_ewma_ms => 900000.0, demote_ms => infinity})}],
    {Order, Decisions} = janus_worker_pool:select_v2(Snap, ?DEFAULT_OPTS#{health_enabled => true}),
    ?assertEqual([?A], Order),
    ?assertEqual([], maps:get(demoted, Decisions)).

select_v2_exclude_self_two_workers_test() ->
    %% A fast (800, 3 samples), B slow (8000, 3 samples):
    %% demote_ms(B) = max(5000, 3*median(others=[800])) = 5000 < 8000
    %% => B demoted; demote_ms(A) = 3*8000 = 24000 > 800 => A kept.
    Ewma = #{?A => {800.0, 3}, ?B => {8000.0, 3}},
    ?assertEqual(5000, janus_worker_pool:demote_ms(?B, Ewma)),
    ?assertEqual(24000.0, janus_worker_pool:demote_ms(?A, Ewma)),
    Snap = [
        {?A, meta(#{observed_ewma_ms => 800.0, demote_ms => 24000})},
        {?B, meta(#{observed_ewma_ms => 8000.0, demote_ms => 5000})}
    ],
    {Order, Decisions} = janus_worker_pool:select_v2(Snap, ?DEFAULT_OPTS#{health_enabled => true}),
    ?assertEqual([?A], Order),
    ?assertEqual([?B], maps:get(demoted, Decisions)).

select_v2_median_even_n_test() ->
    ?assertEqual(5, janus_worker_pool:median([5])),
    ?assertEqual(5, janus_worker_pool:median([9, 5, 1])),
    ?assertEqual(4.0, janus_worker_pool:median([3, 5])),
    ?assertEqual(2.5, janus_worker_pool:median([4, 1, 3, 2])),
    %% Even N averages the two middles on the EXCLUDE-SELF side:
    %% floor binds: others = [100, 200, 300, 400] => median 250 =>
    %% 3 x 250 = 750 < 5000.
    Ewma1 = #{
        ?A => {8000.0, 3},
        ?B => {100.0, 3}, ?C => {200.0, 3}, ?D => {300.0, 3}, ?E => {400.0, 3}
    },
    ?assertEqual(5000, janus_worker_pool:demote_ms(?A, Ewma1)),
    %% median binds: others = [1000, 2000, 3000, 4000] => median 2500
    %% => 3 x 2500 = 7500 > 5000.
    Ewma2 = #{
        ?A => {8000.0, 3},
        ?B => {1000.0, 3}, ?C => {2000.0, 3}, ?D => {3000.0, 3}, ?E => {4000.0, 3}
    },
    ?assertEqual(7500.0, janus_worker_pool:demote_ms(?A, Ewma2)).

select_v2_unknown_rtt_sorts_last_test() ->
    Snap = [
        {?A, meta(#{rtt_map => #{p1 => 500.0}})},
        {?B, meta(#{})}
    ],
    {Order, _} = janus_worker_pool:select_v2(Snap, ?DEFAULT_OPTS#{
        rtt_enabled => true, provider_id => p1
    }),
    %% infinity (the atom) sorts after all floats.
    ?assertEqual([?A, ?B], Order).

select_v2_rtt_sorts_before_inflight_test() ->
    %% rtt_enabled: the rtt key outranks the inflight hint.
    Snap = [
        {?A, meta(#{inflight => 5, rtt_map => #{p1 => 10.0}})},
        {?B, meta(#{inflight => 0, rtt_map => #{p1 => 900.0}})}
    ],
    {Order, _} = janus_worker_pool:select_v2(Snap, ?DEFAULT_OPTS#{
        rtt_enabled => true, provider_id => p1
    }),
    ?assertEqual([?A, ?B], Order).

select_v2_rtt_disabled_ignores_map_test() ->
    %% rtt_enabled=false forces infinity for ALL => (inflight, name).
    Snap = [
        {?A, meta(#{inflight => 0, rtt_map => #{p1 => 9000.0}})},
        {?B, meta(#{inflight => 1, rtt_map => #{p1 => 10.0}})}
    ],
    {Order, _} = janus_worker_pool:select_v2(Snap, ?DEFAULT_OPTS#{provider_id => p1}),
    ?assertEqual([?A, ?B], Order).

select_v2_determinism_test() ->
    Snap = [
        {?A, meta(#{rtt_map => #{p1 => 300.0}, geo_region => <<"cn-east">>})},
        {?B, meta(#{inflight => 0, geo_region => <<"us">>})},
        {?C, meta(#{observed_ewma_ms => 7000.0, demote_ms => 5000})}
    ],
    Opts = ?DEFAULT_OPTS#{health_enabled => true, rtt_enabled => true, provider_id => p1},
    ?assertEqual(
        janus_worker_pool:select_v2(Snap, Opts),
        janus_worker_pool:select_v2(Snap, Opts)
    ).

select_v2_empty_snapshot_test() ->
    {[], Decisions} = janus_worker_pool:select_v2([], ?DEFAULT_OPTS),
    ?assertEqual(#{geo_source => none, demoted => []}, Decisions).

%%%===================================================================
%%% E.3 — v1 equivalence (pure): fixtures in BOTH shapes
%%%===================================================================

select_v2_matches_v1_test() ->
    Fixtures = [
        {[{?A, undefined, 0}, {?B, undefined, 0}], #{}},
        {[{?B, undefined, 0}, {?A, undefined, 0}], #{}},
        {[{?A, <<"east">>, 0}, {?B, <<"west">>, 5}], #{}},
        {[{?A, <<"east">>, 2}, {?B, <<"west">>, 1}, {?C, undefined, 0}], #{}},
        {[{?A, <<"east">>, 2}, {?B, <<"west">>, 1}, {?C, undefined, 0}], #{region_tag => <<"west">>}},
        {[{?A, <<"east">>, 0}, {?B, <<"west">>, 5}], #{region_tag => <<"east">>}},
        %% Known comparator matching no worker: keep all (v1 behavior).
        {[{?A, <<"east">>, 3}, {?B, <<"west">>, 5}], #{region_tag => <<"mars">>}},
        %% Empty region_tag is "unset" (client normalizes null/empty).
        {[{?A, <<"east">>, 0}, {?B, <<"west">>, 5}], #{region_tag => <<>>}},
        {[{?A, <<"east">>, 3}, {?B, <<"west">>, 1}], #{affinity_node => ?B}},
        %% Affinity miss falls through to the tiers.
        {[{?A, <<"east">>, 3}, {?B, <<"west">>, 1}], #{affinity_node => ?C}},
        {[{?A, <<"east">>, 3}, {?B, <<"west">>, 1}], #{affinity_node => ?A, region_tag => <<"west">>}}
    ],
    lists:foreach(
        fun({Spec, Opts}) ->
            Pool = build_v1_pool(Spec),
            Snapshot = build_v2_snapshot(Spec),
            PickOpts = maps:merge(?DEFAULT_OPTS, Opts),
            {Order, _Decisions} = janus_worker_pool:select_v2(Snapshot, PickOpts),
            %% Winner equality + full ordered-list equality against an
            %% independent restatement of v1's semantics.
            ?assertEqual(janus_worker_pool:select(Pool, PickOpts), {ok, hd(Order)}),
            ?assertEqual(v1_full_order(Spec, Opts), Order)
        end,
        Fixtures
    ).

%%%===================================================================
%%% E.8 — EWMA pure math
%%%===================================================================

ewma_seed_at_first_sample_test() ->
    %% E1 = x1 (seeded-at-0 would make three 8000 ms samples read 4625).
    {8000, 1} = janus_worker_pool:ewma_step(none, 8000),
    {E2, 2} = janus_worker_pool:ewma_step({8000, 1}, 8000),
    ?assertEqual(8000.0, E2),
    {E3, 3} = janus_worker_pool:ewma_step({E2, 2}, 8000),
    ?assert(abs(E3 - 8000.0) < 0.0001),
    %% alpha = 0.25: seed 100, sample 200 => 125.
    {125.0, 2} = janus_worker_pool:ewma_step({100, 1}, 200).

ewma_observed_admission_test() ->
    %% < 3 samples => the builder renders unknown (structural guard).
    ?assertEqual(unknown, janus_worker_pool:observed_ewma(none)),
    ?assertEqual(unknown, janus_worker_pool:observed_ewma({100.0, 1})),
    ?assertEqual(unknown, janus_worker_pool:observed_ewma({100.0, 2})),
    ?assertEqual(100.0, janus_worker_pool:observed_ewma({100.0, 3})).

%%%===================================================================
%%% Divergence window (pure, time-parameterized)
%%%===================================================================

report_divergent_test() ->
    %% >= 100 ms floor on both sides.
    ?assertNot(janus_worker_pool:report_divergent(50, 5000)),
    ?assertNot(janus_worker_pool:report_divergent(5000, 50)),
    ?assertNot(janus_worker_pool:report_divergent(unknown, 5000)),
    ?assertNot(janus_worker_pool:report_divergent(5000, unknown)),
    %% Exactly 3.0 is NOT divergent; > 3 either direction is.
    ?assertNot(janus_worker_pool:report_divergent(6000, 2000)),
    ?assert(janus_worker_pool:report_divergent(6001, 2000)),
    ?assert(janus_worker_pool:report_divergent(2000, 6001)).

advance_divergence_window_test() ->
    {false, none} = janus_worker_pool:advance_divergence(none, false, 1000, 120_000),
    {false, #{since := 1000} = W1} = janus_worker_pool:advance_divergence(none, true, 1000, 120_000),
    %% Sustained but short of the window: no fire.
    {false, W2} = janus_worker_pool:advance_divergence(W1, true, 60_000, 120_000),
    ?assertEqual(1000, maps:get(since, W2)),
    %% Window completes: fire once, then re-arm (fires per window).
    {true, W3} = janus_worker_pool:advance_divergence(W2, true, 121_000, 120_000),
    ?assertEqual(121_000, maps:get(since, W3)),
    {false, _} = janus_worker_pool:advance_divergence(W3, true, 130_000, 120_000),
    %% Non-divergent report clears the window.
    {false, none} = janus_worker_pool:advance_divergence(W3, false, 999_999, 120_000).

%%%===================================================================
%%% Clamp (pure) — E.6 seam
%%%===================================================================

clamp_rtt_test() ->
    {ok, 0.0} = janus_worker_pool:clamp_rtt(0),
    {ok, 12.5} = janus_worker_pool:clamp_rtt(12.5),
    {ok, 300.0} = janus_worker_pool:clamp_rtt(300),
    %% > 600000 CLAMPS DOWN (not dropped, no drop counter).
    {ok, 600000.0} = janus_worker_pool:clamp_rtt(600001),
    {ok, 600000.0} = janus_worker_pool:clamp_rtt(600000.0),
    %% Negative / non-finite dropped.
    {drop, negative} = janus_worker_pool:clamp_rtt(-0.1),
    {drop, negative} = janus_worker_pool:clamp_rtt(-1),
    {drop, non_finite} = janus_worker_pool:clamp_rtt(inf),
    {drop, non_finite} = janus_worker_pool:clamp_rtt(nan),
    {drop, non_finite} = janus_worker_pool:clamp_rtt(<<"123">>).

%%%===================================================================
%%% E.4 — live pool (real gen_server + sqlite + heir)
%%%===================================================================

live_pick_and_reserve_counter_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{capacity => 1}),
        ok = wait_snapshot_member(?A),
        %% Insert-default: first pick on a fresh node must not badarg.
        ?assertEqual({ok, ?A}, janus_worker_pool:pick(#{provider_id => p1})),
        ?assertEqual([{?A, 1}], ets:tab2list(sched_reserve)),
        %% dispatch_worker_total{node, provider} counts the WINNING
        %% reserve only (B2); the capacity-rollback pick below does not.
        ?assertEqual(1, maps:get({dispatch_worker, ?A, p1}, janus_worker_pool:sched_stats(), 0)),
        %% Capacity 1: the second pick rolls back => local fallback.
        ?assertEqual(empty, janus_worker_pool:pick(#{provider_id => p1})),
        ?assertEqual([{?A, 1}], ets:tab2list(sched_reserve)),
        Stats = janus_worker_pool:sched_stats(),
        ?assertEqual(1, maps:get(capacity_exhausted, Stats, 0)),
        ?assertEqual(1, maps:get({dispatch_local, capacity}, Stats, 0)),
        %% pick_sync (v1 gen_server path) still selects over live state.
        ?assertEqual({ok, ?A}, janus_worker_pool:pick_sync(#{}))
    after
        stop_stack(Stack)
    end.

live_concurrent_picks_capacity_one_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{capacity => 1}),
        ok = wait_snapshot_member(?A),
        Parent = self(),
        Pids = [
            spawn(fun() -> Parent ! {self(), janus_worker_pool:pick(#{provider_id => p1})} end)
         || _ <- lists:seq(1, 2)
        ],
        Results = [receive {P, R} -> R end || P <- Pids],
        %% Exactly one reservation wins; the loser rolls back to local.
        ?assertEqual([empty, {ok, ?A}], lists:sort(Results)),
        ?assertEqual([{?A, 1}], ets:tab2list(sched_reserve))
    after
        stop_stack(Stack)
    end.

live_pinned_pick_never_refused_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{capacity => 1}),
        ok = wait_snapshot_member(?A),
        ?assertEqual({ok, ?A}, janus_worker_pool:pick(#{affinity_node => ?A, job_ref => <<"pin1">>})),
        %% Soft cap: the pinned candidate skips the capacity refusal.
        ?assertEqual({ok, ?A}, janus_worker_pool:pick(#{affinity_node => ?A, job_ref => <<"pin2">>})),
        ?assertEqual([{?A, 2}], ets:tab2list(sched_reserve))
    after
        stop_stack(Stack)
    end.

live_missing_workers_row_refuses_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{}),
        ok = wait_snapshot_member(?A),
        %% MISSING sched_workers row = drained (refuse, safe direction).
        true = ets:delete(sched_workers, ?A),
        ?assertEqual(empty, janus_worker_pool:pick(#{})),
        ?assertEqual(1, maps:get({dispatch_local, drained}, janus_worker_pool:sched_stats(), 0))
    after
        stop_stack(Stack)
    end.

live_drained_pin_reason_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{}),
        ok = wait_snapshot_member(?A),
        true = ets:insert(sched_workers, {?A, true}),
        ?assertEqual(empty, janus_worker_pool:pick(#{affinity_node => ?A})),
        ?assertEqual(1, maps:get({dispatch_local, drained_pin}, janus_worker_pool:sched_stats(), 0))
    after
        stop_stack(Stack)
    end.

live_exhaustion_reason_first_outcome_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{capacity => 1}),
        ok = hello(Pool, ?B, #{capacity => 1}),
        ok = wait_snapshot_member(?B),
        {ok, ?A} = janus_worker_pool:pick(#{job_ref => <<"x1">>}),
        {ok, ?B} = janus_worker_pool:pick(#{job_ref => <<"x2">>}),
        %% A: missing row (drained — FIRST outcome); B: full (capacity
        %% refusal second). The exhaustion reason is the FIRST outcome:
        %% drained. capacity_exhausted counts BOTH refusals (pick#2
        %% also rolled back on A before winning B — every refusal
        %% bumps its own counter).
        true = ets:delete(sched_workers, ?A),
        ?assertEqual(empty, janus_worker_pool:pick(#{})),
        Stats = janus_worker_pool:sched_stats(),
        ?assertEqual(1, maps:get({dispatch_local, drained}, Stats, 0)),
        ?assertEqual(0, maps:get({dispatch_local, capacity}, Stats, 0)),
        ?assertEqual(2, maps:get(capacity_exhausted, Stats, 0))
    after
        stop_stack(Stack)
    end.

live_empty_pool_local_fallback_test() ->
    Stack = start_stack(),
    try
        %% Snapshot published but empty (idle fleet at boot): pick
        %% falls back to local, counted under empty_pool.
        ?assertEqual([{candidates, []}], ets:lookup(sched_snapshot, candidates)),
        ?assertEqual(empty, janus_worker_pool:pick(#{})),
        ?assertEqual(1, maps:get({dispatch_local, empty_pool}, janus_worker_pool:sched_stats(), 0))
    after
        stop_stack(Stack)
    end.

live_release_semantics_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{capacity => 2}),
        ok = wait_snapshot_member(?A),
        {ok, ?A} = janus_worker_pool:pick(#{job_ref => <<"r1">>}),
        ?assertEqual([{?A, 1}], ets:tab2list(sched_reserve)),
        %% Send-fail release: tracked non-internal => decremented.
        gen_server:cast(Pool, {sched, 2, {release, <<"r1">>}}),
        sync_pool(Pool),
        ?assertEqual([{?A, 0}], ets:tab2list(sched_reserve)),
        %% Duplicate / unknown release: NO-OP (idempotent, no negative).
        gen_server:cast(Pool, {sched, 2, {release, <<"r1">>}}),
        gen_server:cast(Pool, {sched, 2, {release, <<"nope">>}}),
        sync_pool(Pool),
        ?assertEqual([{?A, 0}], ets:tab2list(sched_reserve)),
        %% Ack-miss: the reservation stays PENDING until done/purge.
        {ok, ?A} = janus_worker_pool:pick(#{job_ref => <<"r2">>}),
        sync_pool(Pool),
        ?assertEqual([{?A, 1}], ets:tab2list(sched_reserve))
    after
        stop_stack(Stack)
    end.

live_probe_track_never_decrements_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{}),
        ok = wait_snapshot_member(?A),
        %% Probes track with Internal=true and NO prior increment:
        %% release skips the decrement (counter-neutrality invariant).
        gen_server:cast(Pool, {sched, 2, {track, <<"probe1">>, ?A, p1, now_ms(), true}}),
        sync_pool(Pool),
        gen_server:cast(Pool, {sched, 2, {release, <<"probe1">>}}),
        sync_pool(Pool),
        ?assertEqual([], ets:tab2list(sched_reserve))
    after
        stop_stack(Stack)
    end.

live_purge_age_and_post_purge_noop_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{}),
        ok = wait_snapshot_member(?A),
        %% A tracked entry older than the 10-min purge age, with its
        %% (simulated) counter increment standing.
        Old = now_ms() - 660_000,
        gen_server:cast(Pool, {sched, 2, {track, <<"old">>, ?A, p1, Old, false}}),
        _ = ets:update_counter(sched_reserve, ?A, {2, 1}, {?A, 0}),
        sync_pool(Pool),
        ?assertEqual([{?A, 1}], ets:tab2list(sched_reserve)),
        force_tick(Pool),
        %% Purged: removed + decremented once + counted.
        ?assertEqual([{?A, 0}], ets:tab2list(sched_reserve)),
        ?assertEqual(1, maps:get(reserve_purged, janus_worker_pool:sched_stats(), 0)),
        %% Post-purge done: the release is a NO-OP (no double
        %% decrement, no negative).
        gen_server:cast(Pool, {sched, 2, {release, <<"old">>}}),
        sync_pool(Pool),
        ?assertEqual([{?A, 0}], ets:tab2list(sched_reserve))
    after
        stop_stack(Stack)
    end.

live_reconcile_drift_correction_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{}),
        ok = hello(Pool, ?B, #{}),
        ok = wait_snapshot_member(?B),
        %% Injected drift: excess counter on A (no tracked jobs) and a
        %% negative orphan on B (Default-tuple resurrection class).
        true = ets:insert(sched_reserve, {?A, 5}),
        true = ets:insert(sched_reserve, {?B, -2}),
        %% FIRST tick only RECORDS the excess (a pick's increment can
        %% beat its {track} cast — same-tick excess is an in-flight
        %% register, not drift; spec Part 0.11 two-tick guard).
        force_tick(Pool),
        ?assertEqual(5, proplists:get_value(?A, ets:tab2list(sched_reserve))),
        %% SECOND tick reclaims the persisted drift + heals negatives.
        force_tick(Pool),
        ?assertEqual([{?A, 0}, {?B, 0}], lists:sort(ets:tab2list(sched_reserve))),
        %% Idempotent: further ticks change nothing.
        force_tick(Pool),
        ?assertEqual([{?A, 0}, {?B, 0}], lists:sort(ets:tab2list(sched_reserve)))
    after
        stop_stack(Stack)
    end.

live_load_cast_and_pick_metrics_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{region => <<"cn-east">>}),
        ok = wait_snapshot_member(?A),
        %% Advisory load cast: stored for ops display; a diverging
        %% report sustains the mismatch window (pure window logic is
        %% covered by advance_divergence_window_test; here the cast
        %% path must land and persist).
        gen_server:cast(Pool, {sched, 2, {load, ?A, #{
            inflight_self => 0,
            ewma_upstream_ms => 99000.0
        }}}),
        %% The cast lands on the {load,...} clause (not the counting
        %% catch-all): the pool stays responsive and subsequent picks
        %% work. The 2-min window math is time-parameterized and
        %% covered by advance_divergence_window_test (ocr gap was the
        %% untested CAST path, not the window).
        sync_pool(Pool),
        %% Pick-emitted metrics: a region_tag pick bumps
        %% {geo_match, region_tag} once per pick (ocr coverage gap).
        {ok, ?A} = janus_worker_pool:pick(#{
            provider_id => p1, region_tag => <<"cn-east">>
        }),
        Stats = janus_worker_pool:sched_stats(),
        ?assertEqual(1, maps:get({geo_match, region_tag}, Stats, 0))
    after
        stop_stack(Stack)
    end.

live_snapshot_gen_advances_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{}),
        ok = wait_snapshot_member(?A),
        %% Tick path advances the generation unconditionally.
        G0 = janus_worker_pool:sched_snapshot_gen(),
        force_tick(Pool),
        ?assert(janus_worker_pool:sched_snapshot_gen() > G0),
        %% Dirty-flush path also advances (mutation => <= 250 ms flush).
        Pool ! {janus_worker_drain, ?A},
        G1 = janus_worker_pool:sched_snapshot_gen(),
        ok = wait_until(fun() -> janus_worker_pool:sched_snapshot_gen() > G1 end, 120)
    after
        stop_stack(Stack)
    end.

live_snapshot_carries_v2_meta_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{region => <<"cn-east">>, capacity => 7}),
        ok = hello(Pool, ?B, #{region => undefined}),
        ok = wait_snapshot_member(?B),
        [{candidates, Snap}] = ets:lookup(sched_snapshot, candidates),
        MetaA = snapshot_meta(?A, Snap),
        MetaB = snapshot_meta(?B, Snap),
        %% Builder output shape (spec Part B input).
        ?assertEqual([?A, ?B], lists:sort([N || {N, _} <- Snap])),
        ?assertEqual(0, maps:get(inflight, MetaA)),
        ?assertEqual(7, maps:get(capacity, MetaA)),
        ?assertEqual(false, maps:get(draining, MetaA)),
        ?assertEqual(<<"cn-east">>, maps:get(geo_region, MetaA)),
        ?assertEqual(infinity, maps:get(capacity, MetaB)),
        ?assertEqual(undefined, maps:get(geo_region, MetaB)),
        %% No samples yet: unknown observed EWMA, inert demote_ms.
        ?assertEqual(unknown, maps:get(observed_ewma_ms, MetaA)),
        ?assertEqual(infinity, maps:get(demote_ms, MetaA)),
        ?assertEqual(#{}, maps:get(rtt_map, MetaA))
    after
        stop_stack(Stack)
    end.

live_hello_shapes_and_refresh_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        %% Old-shape hello (no new keys) admits with defaults.
        Pool ! {janus_worker_hello, self(), ?A, #{role => worker, vsn => 1, region => <<"us">>}},
        ok = receive {janus_worker_hello_ack, ?A, _} -> ok after 5000 -> error(no_ack) end,
        ok = wait_snapshot_member(?A),
        ?assertEqual(infinity, snapshot_meta(?A, read_snapshot(), capacity)),
        %% Repeat (keepalive) hello refreshes capacity WITHOUT kicking
        %% the member (idempotent admit, no inflight reset).
        Pool ! {janus_worker_hello, self(), ?A,
            #{role => worker, vsn => 1, region => <<"us">>, capacity => 3}},
        ok = receive {janus_worker_hello_ack, ?A, _} -> ok after 5000 -> error(no_ack) end,
        force_tick(Pool),
        ?assertEqual(3, snapshot_meta(?A, read_snapshot(), capacity)),
        %% Non-integer capacity garbage => clamped to 1.
        Pool ! {janus_worker_hello, self(), ?A,
            #{role => worker, vsn => 1, region => <<"us">>, capacity => <<"four">>}},
        ok = receive {janus_worker_hello_ack, ?A, _} -> ok after 5000 -> error(no_ack) end,
        force_tick(Pool),
        ?assertEqual(1, snapshot_meta(?A, read_snapshot(), capacity))
    after
        stop_stack(Stack)
    end.

live_nodedown_clears_node_state_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{}),
        ok = wait_snapshot_member(?A),
        {ok, ?A} = janus_worker_pool:pick(#{job_ref => <<"n1">>, provider_id => p1}),
        gen_server:cast(Pool, {sched, 2, {rtt, <<"n1">>, 120.5}}),
        sync_pool(Pool),
        ?assertMatch([_], ets:tab2list(sched_rtt)),
        Pool ! {nodedown, ?A},
        sync_pool(Pool),
        %% ALL node scheduler state cleared: workers row, reserve row,
        %% rtt rows; snapshot member gone after flush.
        ?assertEqual([], ets:tab2list(sched_workers)),
        ?assertEqual([], ets:tab2list(sched_reserve)),
        ?assertEqual([], ets:tab2list(sched_rtt)),
        ok = wait_until(fun() ->
            [{candidates, Snap}] = ets:lookup(sched_snapshot, candidates),
            Snap =:= []
        end, 120)
    after
        stop_stack(Stack)
    end.

live_ttfb_ewma_admission_and_demote_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{}),
        ok = hello(Pool, ?B, #{}),
        ok = wait_snapshot_member(?B),
        Now = now_ms(),
        gen_server:cast(Pool, {sched, 2, {track, <<"ja">>, ?A, p1, Now, false}}),
        gen_server:cast(Pool, {sched, 2, {track, <<"jb">>, ?B, p1, Now, false}}),
        %% 2 samples on A: builder renders unknown (< 3).
        gen_server:cast(Pool, {sched, 2, {ttfb, <<"ja">>, 8000}}),
        gen_server:cast(Pool, {sched, 2, {ttfb, <<"ja">>, 8000}}),
        force_tick(Pool),
        ?assertEqual(unknown, snapshot_meta(?A, read_snapshot(), observed_ewma_ms)),
        %% Third sample: admitted. Three identical 8000 ms samples =>
        %% EWMA = 8000 (seed rule). B fed 3 x 50 ms: A's exclude-self
        %% threshold = max(5000, 3 x 50) = 5000.
        gen_server:cast(Pool, {sched, 2, {ttfb, <<"ja">>, 8000}}),
        gen_server:cast(Pool, {sched, 2, {ttfb, <<"jb">>, 50}}),
        gen_server:cast(Pool, {sched, 2, {ttfb, <<"jb">>, 50}}),
        gen_server:cast(Pool, {sched, 2, {ttfb, <<"jb">>, 50}}),
        force_tick(Pool),
        ?assertEqual(8000.0, snapshot_meta(?A, read_snapshot(), observed_ewma_ms)),
        ?assertEqual(50.0, snapshot_meta(?B, read_snapshot(), observed_ewma_ms)),
        ?assertEqual(5000, snapshot_meta(?A, read_snapshot(), demote_ms)),
        %% Internal (probe) completions never feed the health EWMA.
        gen_server:cast(Pool, {sched, 2, {track, <<"jp">>, ?B, p1, Now, true}}),
        gen_server:cast(Pool, {sched, 2, {ttfb, <<"jp">>, 90000}}),
        force_tick(Pool),
        ?assertEqual(50.0, snapshot_meta(?B, read_snapshot(), observed_ewma_ms))
    after
        stop_stack(Stack)
    end.

live_rtt_clamp_and_ingest_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{}),
        ok = wait_snapshot_member(?A),
        %% Two DISTINCT (node, provider) pairs — sched_rtt is a set
        %% keyed by the composite; a single pair keeps ONE row.
        {ok, ?A} = janus_worker_pool:pick(#{job_ref => <<"c1">>, provider_id => p1}),
        {ok, ?A} = janus_worker_pool:pick(#{job_ref => <<"c2">>, provider_id => p2}),
        %% > 600000 clamps DOWN (rows written regardless of the RTT
        %% knob — the knob gates the sort key only); integer 0 lands
        %% as 0.0.
        gen_server:cast(Pool, {sched, 2, {rtt, <<"c1">>, 750000}}),
        gen_server:cast(Pool, {sched, 2, {rtt, <<"c2">>, 0}}),
        sync_pool(Pool),
        Rows = lists:sort(ets:tab2list(sched_rtt)),
        ?assertMatch(
            [{{?A, p1}, 600000.0, passive, _, _}, {{?A, p2}, 0.0, passive, _, _}],
            Rows
        ),
        %% Negative / non-finite dropped + counted; a drop does NOT
        %% overwrite the last accepted row (last-arrival-wins applies
        %% to accepted samples only).
        gen_server:cast(Pool, {sched, 2, {rtt, <<"c1">>, -5}}),
        gen_server:cast(Pool, {sched, 2, {rtt, <<"c2">>, inf}}),
        sync_pool(Pool),
        Stats = janus_worker_pool:sched_stats(),
        ?assertEqual(1, maps:get({rtt_dropped, negative}, Stats, 0)),
        ?assertEqual(1, maps:get({rtt_dropped, non_finite}, Stats, 0)),
        %% Internal (probe) done-with-rtt is SKIPPED at ingest (the
        %% tracked Internal flag — the REACHABLE path, spec E.6).
        gen_server:cast(Pool, {sched, 2, {track, <<"jp">>, ?A, p1, now_ms(), true}}),
        gen_server:cast(Pool, {sched, 2, {rtt, <<"jp">>, 42.0}}),
        sync_pool(Pool),
        ?assertEqual(2, length(ets:tab2list(sched_rtt))),
        %% Unexpired rows feed the snapshot rtt_map.
        force_tick(Pool),
        ?assertEqual(
            #{p1 => 600000.0, p2 => 0.0},
            snapshot_meta(?A, read_snapshot(), rtt_map)
        )
    after
        stop_stack(Stack)
    end.

live_expired_rtt_absent_from_snapshot_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{}),
        ok = wait_snapshot_member(?A),
        Now = now_ms(),
        %% A pre-expired row (build-time TTL filter, spec Part 0.4).
        true = ets:insert(sched_rtt, {{?A, p1}, 100.0, passive, Now - 700_000, Now - 100_000}),
        force_tick(Pool),
        ?assertEqual(#{}, snapshot_meta(?A, read_snapshot(), rtt_map))
    after
        stop_stack(Stack)
    end.

live_unknown_sched_cast_dropped_counted_test() ->
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        ok = hello(Pool, ?A, #{}),
        ok = wait_snapshot_member(?A),
        %% Any newer-worker cast against THIS master whose inner tag is
        %% unknown ({probe,...} itself is CONSUMED by the Task B2 probe
        %% clause — use a still-unknown tag): dropped + counted by the
        %% catch-all.
        gen_server:cast(Pool, {sched, 2, {probe_next, whatever}}),
        sync_pool(Pool),
        ?assertEqual(1, maps:get({sched_unknown, probe_next}, janus_worker_pool:sched_stats(), 0)),
        ?assert(is_process_alive(Pool))
    after
        stop_stack(Stack)
    end.

live_knobs_boot_env_test() ->
    os:putenv("JANUS_SCHED_RTT", "1"),
    os:putenv("JANUS_SCHED_HEALTH", "1"),
    Stack = start_stack(),
    try
        ?assertEqual(
            #{
                rtt => true,
                health => true,
                probe => false,
                probe_max_hourly => 10,
                probe_force => false
            },
            janus_worker_pool:knobs()
        ),
        ?assert(janus_worker_pool:rtt_enabled()),
        ?assert(janus_worker_pool:health_enabled())
    after
        stop_stack(Stack),
        os:unsetenv("JANUS_SCHED_RTT"),
        os:unsetenv("JANUS_SCHED_HEALTH"),
        %% Rewrite the PT keys with defaults so later boots stay clean.
        Stack2 = start_stack(),
        ?assertEqual(
            #{
                rtt => false,
                health => false,
                probe => false,
                probe_max_hourly => 10,
                probe_force => false
            },
            janus_worker_pool:knobs()
        ),
        stop_stack(Stack2)
    end.

live_ets_transfer_adopt_cycle_test() ->
    Stack = start_stack(),
    try
        {Heir, _Db, Pool0, _Path} = Stack,
        ok = hello(Pool0, ?A, #{capacity => 1}),
        ok = wait_snapshot_member(?A),
        {ok, ?A} = janus_worker_pool:pick(#{job_ref => <<"a1">>, provider_id => p1}),
        gen_server:cast(Pool0, {sched, 2, {rtt, <<"a1">>, 88.0}}),
        sync_pool(Pool0),
        ?assertMatch([_], ets:tab2list(sched_workers)),
        ?assertMatch([_], ets:tab2list(sched_reserve)),
        %% Kill the owner: tables transfer to the heir (held, not lost).
        exit(Pool0, kill),
        ok = wait_until(fun() -> ets:info(sched_reserve, owner) =:= Heir end, 200),
        %% Supervisor-restarted pool ADOPTS: reserve RESET via
        %% delete_all_objects, sched_workers/sched_rtt rows pruned (at
        %% init there are no pool records — ALL rows go: cold re-hello).
        {ok, Pool1} = janus_worker_pool:start_link(),
        ok = wait_until(fun() -> ets:info(sched_reserve, owner) =:= Pool1 end, 200),
        ?assertEqual([], ets:tab2list(sched_reserve)),
        ?assertEqual([], ets:tab2list(sched_workers)),
        ?assertEqual([], ets:tab2list(sched_rtt)),
        %% Keepalive re-hello => snapshot rebuilt => pick dispatches.
        ok = hello(Pool1, ?A, #{capacity => 1}),
        ok = wait_snapshot_member(?A),
        {ok, ?A} = janus_worker_pool:pick(#{}),
        gen_server:stop(Pool1)
    after
        stop_stack(Stack)
    end.

%%%===================================================================
%%% E.4b — probes (Task B2: dispatch / five skip reasons / abort)
%%%===================================================================

live_probe_knobs_boot_env_test() ->
    os:putenv("JANUS_SCHED_PROBE", "1"),
    os:putenv("JANUS_SCHED_PROBE_FORCE", "1"),
    os:putenv("JANUS_SCHED_PROBE_MAX_HOURLY", "3"),
    Stack = start_stack(),
    try
        ?assert(janus_worker_pool:probe_enabled()),
        ?assert(janus_worker_pool:probe_force()),
        ?assertEqual(3, maps:get(probe_max_hourly, janus_worker_pool:knobs()))
    after
        stop_stack(Stack),
        os:unsetenv("JANUS_SCHED_PROBE"),
        os:unsetenv("JANUS_SCHED_PROBE_FORCE"),
        os:unsetenv("JANUS_SCHED_PROBE_MAX_HOURLY"),
        clean_stack()
    end.

%% Probe candidate source: no catalog published => [] (defensive read);
%% injected rows (the documented eunit seam) win when present.
live_probe_candidates_source_test() ->
    set_test_secrets_key(),
    Stack = start_stack(),
    try
        ?assertEqual([], janus_worker_pool:probe_candidates()),
        _ = inject_candidate(p2),
        _ = inject_candidate(p1),
        Cands = janus_worker_pool:probe_candidates(),
        %% Deterministic order (sorted by provider id) + the injected
        %% shape round-trips (ciphers are per-call random — compare the
        %% stable projection).
        ?assertEqual([p1, p2], [maps:get(provider_id, C) || C <- Cands]),
        ?assertEqual(
            [
                <<"https://mock.probe.test">>,
                <<"https://mock.probe.test">>
            ],
            [maps:get(base_url, C) || C <- Cands]
        )
    after
        stop_stack(Stack)
    end.

%% Probes are money: with the knob off the {probe, _} cast is a SILENT
%% no-op (no skip counters, no dispatch).
live_probe_knob_off_cast_noop_test() ->
    set_test_secrets_key(),
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        _ = inject_candidate(p1),
        ok = hello(Pool, ?A, #{sched_v => 2}),
        ok = wait_snapshot_member(?A),
        ?assertNot(janus_worker_pool:probe_enabled()),
        gen_server:cast(Pool, {sched, 2, {probe, #{}}}),
        sync_pool(Pool),
        Stats = janus_worker_pool:sched_stats(),
        lists:foreach(
            fun(Reason) ->
                ?assertEqual(0, maps:get({probe_skip, Reason}, Stats, 0))
            end,
            [cap, cadence, fresh, drained, send_fail]
        ),
        ?assertEqual(0, maps:get({probe, p1}, Stats, 0))
    after
        stop_stack(Stack)
    end.

%% Skip{drained}: the only target is drained at the LIVE re-check.
live_probe_drained_skip_test() ->
    set_test_secrets_key(),
    os:putenv("JANUS_SCHED_PROBE", "1"),
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        _ = inject_candidate(p1),
        ok = hello(Pool, ?A, #{sched_v => 2}),
        ok = wait_snapshot_member(?A),
        true = ets:insert(sched_workers, {?A, true}),
        gen_server:cast(Pool, {sched, 2, {probe, #{}}}),
        sync_pool(Pool),
        ?assertEqual(1, maps:get({probe_skip, drained}, janus_worker_pool:sched_stats(), 0))
    after
        stop_stack(Stack),
        os:unsetenv("JANUS_SCHED_PROBE"),
        clean_stack()
    end.

%% Old-version workers (hello without sched_v => 2) are NOT probe
%% targets — a SILENT no-op (no skip reason exists for version
%% exclusion; spec Part 0.2).
live_probe_old_worker_silent_test() ->
    set_test_secrets_key(),
    os:putenv("JANUS_SCHED_PROBE", "1"),
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        _ = inject_candidate(p1),
        ok = hello(Pool, ?A, #{}),
        ok = wait_snapshot_member(?A),
        gen_server:cast(Pool, {sched, 2, {probe, #{}}}),
        sync_pool(Pool),
        Stats = janus_worker_pool:sched_stats(),
        lists:foreach(
            fun(Reason) ->
                ?assertEqual(0, maps:get({probe_skip, Reason}, Stats, 0))
            end,
            [cap, cadence, fresh, drained, send_fail]
        )
    after
        stop_stack(Stack),
        os:unsetenv("JANUS_SCHED_PROBE"),
        clean_stack()
    end.

%% Skip{fresh}: an unexpired passive sched_rtt row (BOTH passive AND
%% probe rows count) blocks the pair; the probe knob is on, FORCE off.
live_probe_fresh_skip_test() ->
    set_test_secrets_key(),
    os:putenv("JANUS_SCHED_PROBE", "1"),
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        _ = inject_candidate(p1),
        ok = hello(Pool, node(), #{sched_v => 2}),
        ok = wait_snapshot_member(node()),
        Now = now_ms(),
        true = ets:insert(sched_rtt, {{node(), p1}, 100.0, passive, Now, Now + 600_000}),
        gen_server:cast(Pool, {sched, 2, {probe, #{}}}),
        sync_pool(Pool),
        Stats = janus_worker_pool:sched_stats(),
        ?assertEqual(1, maps:get({probe_skip, fresh}, Stats, 0)),
        ?assertEqual(0, maps:get({probe, p1}, Stats, 0))
    after
        stop_stack(Stack),
        os:unsetenv("JANUS_SCHED_PROBE"),
        clean_stack()
    end.

%% Skip{cap}: checked FIRST; FORCE never bypasses it (MAX_HOURLY=0).
live_probe_cap_skip_test() ->
    set_test_secrets_key(),
    os:putenv("JANUS_SCHED_PROBE", "1"),
    os:putenv("JANUS_SCHED_PROBE_FORCE", "1"),
    os:putenv("JANUS_SCHED_PROBE_MAX_HOURLY", "0"),
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        _ = inject_candidate(p1),
        ok = hello(Pool, ?A, #{sched_v => 2}),
        ok = wait_snapshot_member(?A),
        gen_server:cast(Pool, {sched, 2, {probe, #{}}}),
        sync_pool(Pool),
        Stats = janus_worker_pool:sched_stats(),
        ?assertEqual(1, maps:get({probe_skip, cap}, Stats, 0)),
        %% Never issued: no probe_total, no other skip reason.
        ?assertEqual(0, maps:get({probe, p1}, Stats, 0)),
        ?assertEqual(0, maps:get({probe_skip, fresh}, Stats, 0)),
        ?assertEqual(0, maps:get({probe_skip, cadence}, Stats, 0))
    after
        stop_stack(Stack),
        os:unsetenv("JANUS_SCHED_PROBE"),
        os:unsetenv("JANUS_SCHED_PROBE_FORCE"),
        os:unsetenv("JANUS_SCHED_PROBE_MAX_HOURLY"),
        clean_stack()
    end.

%% Full path on a REAL local dispatch: the fake janus_worker_dispatch
%% receives a NORMAL job whose Fields carry the ADDITIVE `internal =>
%% true` key, acks, and completes with done — the pool measures
%% elapsed, writes a probe-source cold-start rtt row, counts
%% probe_total{provider}, and NEVER touches the reserve counter.
live_probe_full_path_test() ->
    set_test_secrets_key(),
    os:putenv("JANUS_SCHED_PROBE", "1"),
    Stack = start_stack(),
    Fake = start_fake_worker(),
    try
        {_, _, Pool, _} = Stack,
        _ = inject_candidate(p1),
        ok = hello(Pool, node(), #{sched_v => 2}),
        ok = wait_snapshot_member(node()),
        gen_server:cast(Pool, {sched, 2, {probe, #{}}}),
        {JobRef, Fields} =
            receive
                {fake_job, JobRef0, Fields0} -> {JobRef0, Fields0}
            after 5000 ->
                error(no_probe_job)
            end,
        %% The additive internal marker rides the job map (Task C's
        %% worker-side hook); wire validation tolerates the extra key.
        ?assertEqual(true, maps:get(internal, Fields, undefined)),
        ok = janus_worker_wire:validate({janus_job, JobRef, self(), Fields}),
        %% Minimal entitlement-probe shape (dashboard _probe_request).
        ?assertEqual(post, maps:get(method, Fields)),
        ?assertEqual(false, maps:get(stream, Fields)),
        ?assertEqual(<<"https://mock.probe.test/chat/completions">>, maps:get(url, Fields)),
        {ok, #{<<"max_tokens">> := 1, <<"model">> := <<"probe-model">>}} =
            thoas:decode(maps:get(body, Fields)),
        ?assert(lists:keymember(<<"authorization">>, 1, maps:get(headers, Fields))),
        %% Ack + done route to the POOL (master session for probes).
        ok = wait_until(fun() ->
            [] =/= [R || {{N, P}, _, probe, _, _} = R <- ets:tab2list(sched_rtt), N =:= node(), P =:= p1]
        end, 200),
        [RttRow] = [R || {{N, P}, _, probe, _, _} = R <- ets:tab2list(sched_rtt), N =:= node(), P =:= p1],
        Self = node(),
        ?assertMatch({{Self, p1}, Ms, probe, _, _} when is_float(Ms), RttRow),
        Stats = janus_worker_pool:sched_stats(),
        ?assertEqual(1, maps:get({probe, p1}, Stats, 0)),
        ?assertEqual(0, maps:get({probe_skip, send_fail}, Stats, 0)),
        %% Counter-neutrality end-to-end (no reserve slot ever held).
        ?assertEqual([], ets:tab2list(sched_reserve))
    after
        Fake ! stop,
        stop_stack(Stack),
        os:unsetenv("JANUS_SCHED_PROBE"),
        clean_stack()
    end.

%% The 30 s TICK path (not the direct cast): with the probe knob on,
%% force_tick self-casts {sched, 2, {probe, _}} and the job dispatches.
live_probe_tick_kicks_when_enabled_test() ->
    set_test_secrets_key(),
    os:putenv("JANUS_SCHED_PROBE", "1"),
    Stack = start_stack(),
    Fake = start_fake_worker(),
    try
        {_, _, Pool, _} = Stack,
        _ = inject_candidate(p1),
        ok = hello(Pool, node(), #{sched_v => 2}),
        ok = wait_snapshot_member(node()),
        force_tick(Pool),
        receive
            {fake_job, _JobRef, _Fields} -> ok
        after 5000 ->
            error(tick_did_not_probe)
        end
    after
        Fake ! stop,
        stop_stack(Stack),
        os:unsetenv("JANUS_SCHED_PROBE"),
        clean_stack()
    end.

live_probe_force_bypasses_cadence_test() ->
    set_test_secrets_key(),
    os:putenv("JANUS_SCHED_PROBE", "1"),
    os:putenv("JANUS_SCHED_PROBE_FORCE", "1"),
    Stack = start_stack(),
    Fake = start_fake_worker(),
    try
        {_, _, Pool, _} = Stack,
        _ = inject_candidate(p1),
        ok = hello(Pool, node(), #{sched_v => 2}),
        ok = wait_snapshot_member(node()),
        %% First probe cast issues immediately...
        gen_server:cast(Pool, {sched, 2, {probe, #{}}}),
        receive
            {fake_job, _Ref1, _F1} -> ok
        after 5000 ->
            error(first_probe_did_not_issue)
        end,
        %% ...and the SECOND cast, within the 60 s cadence window,
        %% must STILL issue under FORCE (bypasses cadence, not just
        %% the fresh-skip — ocr review found the filter order bug).
        gen_server:cast(Pool, {sched, 2, {probe, #{}}}),
        receive
            {fake_job, _Ref2, _F2} -> ok
        after 5000 ->
            error(force_did_not_bypass_cadence)
        end,
        Stats = janus_worker_pool:sched_stats(),
        ?assertEqual(0, maps:get({probe_skip, cadence}, Stats, 0))
    after
        Fake ! stop,
        stop_stack(Stack),
        os:unsetenv("JANUS_SCHED_PROBE"),
        os:unsetenv("JANUS_SCHED_PROBE_FORCE"),
        clean_stack()
    end.

%% FORCE bypasses the fresh-skip but the probe row still respects the
%% COLD-START existence gate: an unexpired PASSIVE row survives the
%% probe completion (the probe result is discarded, spec A.3).
live_probe_force_bypasses_fresh_test() ->
    set_test_secrets_key(),
    os:putenv("JANUS_SCHED_PROBE", "1"),
    os:putenv("JANUS_SCHED_PROBE_FORCE", "1"),
    Stack = start_stack(),
    Fake = start_fake_worker(),
    try
        {_, _, Pool, _} = Stack,
        _ = inject_candidate(p1),
        ok = hello(Pool, node(), #{sched_v => 2}),
        ok = wait_snapshot_member(node()),
        Now = now_ms(),
        true = ets:insert(sched_rtt, {{node(), p1}, 100.0, passive, Now, Now + 600_000}),
        gen_server:cast(Pool, {sched, 2, {probe, #{}}}),
        receive
            {fake_job, _JobRef, _Fields} -> ok
        after 5000 ->
            error(force_did_not_bypass_fresh)
        end,
        %% The fake worker auto-acks + auto-dones; wait for completion.
        ok = wait_until(fun() ->
            maps:get({probe, p1}, janus_worker_pool:sched_stats(), 0) >= 1
        end, 200),
        %% The passive row SURVIVES (existence gate).
        ?assertEqual(
            [{{node(), p1}, 100.0, passive, Now, Now + 600_000}],
            [R || {{N, P}, _, _, _, _} = R <- ets:tab2list(sched_rtt), N =:= node(), P =:= p1]
        )
    after
        Fake ! stop,
        stop_stack(Stack),
        os:unsetenv("JANUS_SCHED_PROBE"),
        os:unsetenv("JANUS_SCHED_PROBE_FORCE"),
        clean_stack()
    end.

%% Ack-miss ABORT against an unreachable node: after the 5 s ack
%% deadline — probe_skip{send_fail}, in-flight + tracked cleared
%% WITHOUT decrement, NEVER a local fallback. A re-cast then skips
%% {cadence} (last-probed is fresh; the in-flight slot was freed).
%% Generator form: the real 5 s ack deadline + poll exceeds eunit's
%% default per-test timeout.
live_probe_ack_miss_aborts_test_() ->
    {timeout, 15, fun live_probe_ack_miss_aborts/0}.

live_probe_ack_miss_aborts() ->
    set_test_secrets_key(),
    os:putenv("JANUS_SCHED_PROBE", "1"),
    Stack = start_stack(),
    try
        {_, _, Pool, _} = Stack,
        _ = inject_candidate(p1),
        ok = hello(Pool, ?B, #{sched_v => 2}),
        ok = wait_snapshot_member(?B),
        gen_server:cast(Pool, {sched, 2, {probe, #{}}}),
        sync_pool(Pool),
        %% In flight: no skip yet (the 5 s ack deadline runs for real).
        ?assertEqual(0, maps:get({probe_skip, send_fail}, janus_worker_pool:sched_stats(), 0)),
        ok = wait_until(fun() ->
            maps:get({probe_skip, send_fail}, janus_worker_pool:sched_stats(), 0) >= 1
        end, 260),
        %% NO local fallback for internal jobs (no dispatch_local
        %% reason ever fired) and no reserve slot was ever held.
        Stats = janus_worker_pool:sched_stats(),
        ?assertEqual([], [K || {{dispatch_local, _} = K, V} <- maps:to_list(Stats), V > 0]),
        ?assertEqual([], ets:tab2list(sched_reserve)),
        %% In-flight cleared: the next evaluation is cadence-blocked
        %% (the pair was probed seconds ago), NOT in-flight-blocked.
        gen_server:cast(Pool, {sched, 2, {probe, #{}}}),
        sync_pool(Pool),
        ?assertEqual(1, maps:get({probe_skip, cadence}, janus_worker_pool:sched_stats(), 0))
    after
        stop_stack(Stack),
        os:unsetenv("JANUS_SCHED_PROBE"),
        clean_stack()
    end.

%%%===================================================================
%%% Fixture — real gen_server stack (sqlite backend + ETS heir)
%%%===================================================================

start_stack() ->
    {ok, _} = application:ensure_all_started(crypto),
    process_flag(trap_exit, true),
    {ok, Heir} = janus_ets_heir:start_link(),
    Path =
        "/tmp/janus_pool_v2_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic])) ++ ".db",
    %% The pool's init loads sticky state via janus_db_conn (a failed
    %% load REFUSES boot) — boot a real sqlite backend for it.
    {ok, Db} = janus_db_conn:start_link(#{backend => sqlite, path => Path}),
    {ok, Pool} = janus_worker_pool:start_link(),
    {Heir, Db, Pool, Path}.

stop_stack({Heir, Db, Pool, Path}) ->
    %% Scrub the test keyring so probe tests never leak it into
    %% later suites (ocr review: order independence).
    os:unsetenv("JANUS_SECRETS_KEY"),
    try
        gen_server:stop(Pool)
    catch
        _:_ -> ok
    end,
    try
        gen_server:stop(Db)
    catch
        _:_ -> ok
    end,
    try
        gen_server:stop(Heir)
    catch
        _:_ -> ok
    end,
    _ = file:delete(Path),
    ok.

%% Boot one clean-env stack to scrub the PT knob keys after an
%% env-dependent test (boot_knobs re-reads the environment at init).
clean_stack() ->
    Stack = start_stack(),
    ?assertNot(janus_worker_pool:probe_enabled()),
    stop_stack(Stack).

%% Probe envelopes are real JSEC secrets (production shape): a working
%% keyring must be in the environment for encrypt (test) + decrypt
%% (pool) — janus_secrets roundtrip-test precedent.
set_test_secrets_key() ->
    os:putenv(
        "JANUS_SECRETS_KEY",
        "k1:" ++ base64:encode_to_string(crypto:strong_rand_bytes(32))
    ).

%% Inject one probe PROVIDER candidate into the documented ETS seam
%% (sched_probe_candidates — wins over the catalog path when non-empty;
%% no catalog is published under eunit). Returns the injected map.
inject_candidate(ProviderId) ->
    {ok, Cipher} = janus_secrets:encrypt(<<"sk-probe-secret">>),
    Cand = #{
        provider_id => ProviderId,
        base_url => <<"https://mock.probe.test">>,
        protocol => <<"openai_chat">>,
        listing => <<"probe-model">>,
        secret_ref => {<<"k1">>, Cipher}
    },
    true = ets:insert(sched_probe_candidates, {ProviderId, Cand}),
    Cand.

%% Fake LOCAL janus_worker_dispatch (the name is free under eunit —
%% the real one only boots on worker nodes): receives the probe job,
%% tells the test process, acks, and completes with a production-shaped
%% done. Receives {janus_cancel, JobRef} defensively (reported).
start_fake_worker() ->
    Parent = self(),
    Pid = spawn(fun() ->
        register(janus_worker_dispatch, self()),
        Parent ! {fake_worker_ready, self()},
        fake_worker_loop(Parent)
    end),
    receive
        {fake_worker_ready, Pid} -> ok
    after 5000 ->
        error(fake_worker_not_ready)
    end,
    Pid.

fake_worker_loop(Parent) ->
    receive
        {janus_job, JobRef, MasterSessionPid, Fields} ->
            Parent ! {fake_job, JobRef, Fields},
            MasterSessionPid ! {janus_job_ack, JobRef, self()},
            MasterSessionPid ! {janus_done, JobRef, #{
                usage => undefined, status => 200, trailers => #{}, body => <<>>
            }},
            fake_worker_loop(Parent);
        {janus_cancel, JobRef} ->
            Parent ! {fake_cancel, JobRef},
            fake_worker_loop(Parent);
        stop ->
            ok
    after 10000 ->
        ok
    end.

hello(Pool, Node, Extra) ->
    Meta = maps:merge(#{role => worker, vsn => 1, region => undefined}, Extra),
    Pool ! {janus_worker_hello, self(), Node, Meta},
    receive
        {janus_worker_hello_ack, Node, _} ->
            ok;
        {janus_worker_hello_nack, Node, #{reason := Reason}} ->
            error({hello_nack, Reason})
    after 5000 ->
        error(hello_no_ack)
    end.

%% Same-sender FIFO: a sync call after a cast/info guarantees the
%% earlier message was processed.
sync_pool(Pool) ->
    _ = gen_server:call(Pool, available),
    ok.

%% Drive the 30 s tick synchronously (republish + reconcile + purge).
force_tick(Pool) ->
    Pool ! sched_tick,
    sync_pool(Pool).

wait_snapshot_member(Node) ->
    wait_until(fun() ->
        [{candidates, Snap}] = ets:lookup(sched_snapshot, candidates),
        lists:keymember(Node, 1, Snap)
    end, 200).

read_snapshot() ->
    [{candidates, Snap}] = ets:lookup(sched_snapshot, candidates),
    Snap.

snapshot_meta(Node, Snap) ->
    {Node, Meta} = lists:keyfind(Node, 1, Snap),
    Meta.

snapshot_meta(Node, Snap, Key) ->
    maps:get(Key, snapshot_meta(Node, Snap)).

wait_until(_Fun, 0) ->
    error(wait_timeout);
wait_until(Fun, Tries) when Tries > 0 ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(25),
            wait_until(Fun, Tries - 1)
    end.

now_ms() ->
    erlang:monotonic_time(millisecond).

%%%===================================================================
%%% Fixtures in both shapes (E.3)
%%%===================================================================

%% v2 snapshot Meta with per-test overrides.
meta(Overrides) when is_map(Overrides) ->
    maps:merge(
        #{
            inflight => 0,
            capacity => infinity,
            draining => false,
            geo_region => undefined,
            rtt_map => #{},
            observed_ewma_ms => unknown,
            demote_ms => infinity
        },
        Overrides
    ).

%% v1 pool: hello each node then bump inflight (old-shape metas).
build_v1_pool(Spec) ->
    Pool0 = lists:foldl(
        fun({Node, Region, _Inflight}, Acc) ->
            {ack, Acc1} = janus_worker_pool:apply_hello(
                Acc, Node, #{role => worker, vsn => 1, region => Region}
            ),
            Acc1
        end,
        janus_worker_pool:new_pool([]),
        Spec
    ),
    lists:foldl(
        fun({_Node, _Region, Inflight}, Acc) when Inflight =< 0 ->
            Acc;
            ({Node, _Region, Inflight}, Acc) ->
                {Acc1, _} = janus_worker_pool:apply_inflight(Acc, Node, 1),
                bump_v1_inflight(Acc1, Node, Inflight - 1)
        end,
        Pool0,
        Spec
    ).

bump_v1_inflight(Pool, _Node, 0) ->
    Pool;
bump_v1_inflight(Pool, Node, N) when N > 0 ->
    {Pool1, _} = janus_worker_pool:apply_inflight(Pool, Node, 1),
    bump_v1_inflight(Pool1, Node, N - 1).

%% v2 snapshot: the same logical facts in the builder's shape.
build_v2_snapshot(Spec) ->
    [{Node, meta(#{inflight => Inflight, geo_region => Region})} || {Node, Region, Inflight} <- Spec].

%% Independent restatement of v1's ordering for ordered-list equality:
%% affinity hit => that node; else region narrowing when the tag
%% matches anything; then (inflight, name).
v1_full_order(Spec, Opts) ->
    All = [N || {N, _, _} <- Spec],
    AffinityHit =
        case maps:get(affinity_node, Opts, undefined) of
            Node when is_atom(Node), Node =/= undefined ->
                lists:member(Node, All);
            _ ->
                false
        end,
    case AffinityHit of
        true ->
            [maps:get(affinity_node, Opts)];
        false ->
            case maps:get(region_tag, Opts, undefined) of
                RT when RT =/= undefined, RT =/= <<>> ->
                    Hits = [N || {N, R, _} <- Spec, R =:= RT],
                    Narrow = case Hits of [] -> All; _ -> Hits end,
                    v1_sort(Spec, Narrow);
                _ ->
                    v1_sort(Spec, All)
            end
    end.

v1_sort(Spec, Narrow) ->
    Sorted = lists:sort(
        fun({N1, _, I1}, {N2, _, I2}) -> {I1, N1} =< {I2, N2} end,
        [X || X = {N, _, _} <- Spec, lists:member(N, Narrow)]
    ),
    [N || {N, _, _} <- Sorted].
