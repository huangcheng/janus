%%% @doc Pure select / drain / sticky state-machine tests for
%%% `janus_worker_pool` (spec §3.4 / §6). No dist, no DB, no timers.
-module(janus_worker_pool_tests).

-include_lib("eunit/include/eunit.hrl").

-define(A, 'worker_a@127.0.0.1').
-define(B, 'worker_b@127.0.0.1').
-define(C, 'worker_c@127.0.0.1').

drain_idle_pinned_test() ->
    ?assertEqual(30_000, janus_worker_pool:drain_idle_ms()).

hello_acks_and_makes_dispatchable_test() ->
    P0 = janus_worker_pool:new_pool([]),
    {ack, P1} = janus_worker_pool:apply_hello(P0, ?A, #{
        role => worker, vsn => 1, region => <<"cn-east">>
    }),
    ?assertEqual(1, janus_worker_pool:available(P1)),
    ?assertEqual({ok, ?A}, janus_worker_pool:select(P1, #{})),
    %% Idempotent re-hello: still one member.
    {ack, P2} = janus_worker_pool:apply_hello(P1, ?A, #{
        role => worker, vsn => 1, region => <<"cn-east">>
    }),
    ?assertEqual(1, janus_worker_pool:available(P2)).

hello_sticky_nacks_test() ->
    P0 = janus_worker_pool:new_pool([?A]),
    {{nack, drained}, P1} = janus_worker_pool:apply_hello(
        P0, ?A, #{role => worker, vsn => 1, region => undefined}
    ),
    ?assertEqual(0, janus_worker_pool:available(P1)),
    ?assertEqual(true, janus_worker_pool:is_sticky(P1, ?A)).

hello_bad_vsn_nacks_test() ->
    P0 = janus_worker_pool:new_pool([]),
    {{nack, vsn}, P1} = janus_worker_pool:apply_hello(
        P0, ?A, #{role => worker, vsn => 2, region => undefined}
    ),
    ?assertEqual(0, janus_worker_pool:available(P1)),
    ?assertEqual(false, janus_worker_pool:is_member(P1, ?A)).

hello_while_draining_stays_draining_test() ->
    P0 = janus_worker_pool:new_pool([]),
    {ack, P1} = janus_worker_pool:apply_hello(
        P0, ?A, #{role => worker, vsn => 1, region => <<"r1">>}
    ),
    {P2, true} = janus_worker_pool:apply_drain(P1, ?A),
    ?assertEqual(0, janus_worker_pool:available(P2)),
    ?assertEqual(true, janus_worker_pool:is_draining(P2, ?A)),
    {ack, P3} = janus_worker_pool:apply_hello(
        P2, ?A, #{role => worker, vsn => 1, region => <<"r1">>}
    ),
    ?assertEqual(true, janus_worker_pool:is_draining(P3, ?A)),
    ?assertEqual(0, janus_worker_pool:available(P3)),
    ?assertEqual(empty, janus_worker_pool:select(P3, #{})).

drain_idle_becomes_sticky_test() ->
    P0 = janus_worker_pool:new_pool([]),
    {ack, P1} = janus_worker_pool:apply_hello(
        P0, ?A, #{role => worker, vsn => 1, region => undefined}
    ),
    {P2, true} = janus_worker_pool:apply_drain(P1, ?A),
    {P3, true} = janus_worker_pool:apply_drain_idle(P2, ?A),
    ?assertEqual(false, janus_worker_pool:is_member(P3, ?A)),
    ?assertEqual(true, janus_worker_pool:is_sticky(P3, ?A)),
    {{nack, drained}, _} = janus_worker_pool:apply_hello(
        P3, ?A, #{role => worker, vsn => 1, region => undefined}
    ).

nodedown_while_draining_not_sticky_test() ->
    P0 = janus_worker_pool:new_pool([]),
    {ack, P1} = janus_worker_pool:apply_hello(
        P0, ?A, #{role => worker, vsn => 1, region => undefined}
    ),
    {P2, false} = janus_worker_pool:apply_inflight(P1, ?A, 1),
    {P3, false} = janus_worker_pool:apply_drain(P2, ?A),
    P4 = janus_worker_pool:apply_nodedown(P3, ?A),
    ?assertEqual(false, janus_worker_pool:is_member(P4, ?A)),
    ?assertEqual(false, janus_worker_pool:is_sticky(P4, ?A)),
    %% Can re-hello after nodedown (not sticky).
    {ack, P5} = janus_worker_pool:apply_hello(
        P4, ?A, #{role => worker, vsn => 1, region => undefined}
    ),
    ?assertEqual(1, janus_worker_pool:available(P5)).

nodedown_live_removes_not_sticky_test() ->
    P0 = janus_worker_pool:new_pool([]),
    {ack, P1} = janus_worker_pool:apply_hello(
        P0, ?A, #{role => worker, vsn => 1, region => undefined}
    ),
    P2 = janus_worker_pool:apply_nodedown(P1, ?A),
    ?assertEqual(0, janus_worker_pool:available(P2)),
    ?assertEqual(false, janus_worker_pool:is_sticky(P2, ?A)).

inflight_zero_starts_drain_idle_test() ->
    P0 = janus_worker_pool:new_pool([]),
    {ack, P1} = janus_worker_pool:apply_hello(
        P0, ?A, #{role => worker, vsn => 1, region => undefined}
    ),
    {P2, false} = janus_worker_pool:apply_inflight(P1, ?A, 1),
    {P3, false} = janus_worker_pool:apply_drain(P2, ?A),
    {P4, true} = janus_worker_pool:apply_inflight(P3, ?A, -1),
    ?assertEqual(0, janus_worker_pool:inflight(P4, ?A)),
    ?assertEqual(true, janus_worker_pool:is_draining(P4, ?A)).

undrain_clears_sticky_requires_rehello_test() ->
    P0 = janus_worker_pool:new_pool([?A]),
    P1 = janus_worker_pool:apply_undrain(P0, ?A),
    ?assertEqual(false, janus_worker_pool:is_sticky(P1, ?A)),
    ?assertEqual(0, janus_worker_pool:available(P1)),
    {ack, P2} = janus_worker_pool:apply_hello(
        P1, ?A, #{role => worker, vsn => 1, region => undefined}
    ),
    ?assertEqual(1, janus_worker_pool:available(P2)).

least_inflight_name_tiebreak_test() ->
    P0 = janus_worker_pool:new_pool([]),
    {ack, P1} = janus_worker_pool:apply_hello(
        P0, ?B, #{role => worker, vsn => 1, region => undefined}
    ),
    {ack, P2} = janus_worker_pool:apply_hello(
        P1, ?A, #{role => worker, vsn => 1, region => undefined}
    ),
    {ack, P3} = janus_worker_pool:apply_hello(
        P2, ?C, #{role => worker, vsn => 1, region => undefined}
    ),
    %% Equal inflight → atom name order: A < B < C
    ?assertEqual({ok, ?A}, janus_worker_pool:select(P3, #{})),
    {P4, false} = janus_worker_pool:apply_inflight(P3, ?A, 1),
    ?assertEqual({ok, ?B}, janus_worker_pool:select(P4, #{})),
    {P5, false} = janus_worker_pool:apply_inflight(P4, ?B, 1),
    {P6, false} = janus_worker_pool:apply_inflight(P5, ?B, 1),
    %% A has 1, B has 2, C has 0 → C
    ?assertEqual({ok, ?C}, janus_worker_pool:select(P6, #{})).

affinity_node_prefers_match_test() ->
    P0 = janus_worker_pool:new_pool([]),
    {ack, P1} = janus_worker_pool:apply_hello(
        P0, ?A, #{role => worker, vsn => 1, region => <<"east">>}
    ),
    {ack, P2} = janus_worker_pool:apply_hello(
        P1, ?B, #{role => worker, vsn => 1, region => <<"west">>}
    ),
    {P3, false} = bump_inflight(P2, ?B, 5),
    ?assertEqual({ok, ?B}, janus_worker_pool:select(P3, #{affinity_node => ?B})),
    %% Missing / non-dispatchable affinity falls through to least-inflight (A).
    ?assertEqual({ok, ?A}, janus_worker_pool:select(P3, #{affinity_node => ?C})).

affinity_region_prefers_match_test() ->
    P0 = janus_worker_pool:new_pool([]),
    {ack, P1} = janus_worker_pool:apply_hello(
        P0, ?A, #{role => worker, vsn => 1, region => <<"east">>}
    ),
    {ack, P2} = janus_worker_pool:apply_hello(
        P1, ?B, #{role => worker, vsn => 1, region => <<"west">>}
    ),
    {P3, false} = bump_inflight(P2, ?A, 3),
    %% Region match prefers B even though A would lose on least-inflight alone.
    ?assertEqual({ok, ?B}, janus_worker_pool:select(P3, #{region_tag => <<"west">>})),
    %% Unknown region → fall through; least inflight is B (0 vs 3).
    ?assertEqual({ok, ?B}, janus_worker_pool:select(P3, #{region_tag => <<"mars">>})).

affinity_node_draining_falls_through_test() ->
    P0 = janus_worker_pool:new_pool([]),
    {ack, P1} = janus_worker_pool:apply_hello(
        P0, ?A, #{role => worker, vsn => 1, region => undefined}
    ),
    {ack, P2} = janus_worker_pool:apply_hello(
        P1, ?B, #{role => worker, vsn => 1, region => undefined}
    ),
    {P3, true} = janus_worker_pool:apply_drain(P2, ?A),
    ?assertEqual({ok, ?B}, janus_worker_pool:select(P3, #{affinity_node => ?A})).

empty_pool_select_test() ->
    P0 = janus_worker_pool:new_pool([]),
    ?assertEqual(empty, janus_worker_pool:select(P0, #{})),
    ?assertEqual(0, janus_worker_pool:available(P0)).

%% Apply note_inflight(+1) N times (API only allows ±1).
bump_inflight(Pool, _Node, 0) ->
    {Pool, false};
bump_inflight(Pool, Node, N) when N > 0 ->
    {Pool1, false} = janus_worker_pool:apply_inflight(Pool, Node, 1),
    bump_inflight(Pool1, Node, N - 1).
