%%% @doc /stats/sched JSON assembly tests (scheduler v2 spec Part C,
%%% Task B2): the PURE janus_gateway_stats:sched_json/1 renders the
%%% pinned schema from injected counters/rows — every fixed-enum
%%% sub-map carries all keys with 0 defaults, rtt_ms is capped at the
%%% 64 most recent unexpired rows with the overflow aggregate ALWAYS
%%% present, and time is injected (no clock reads).
%%%
%%% Live-stack behavior behind the same surface is covered by
%%% janus_worker_pool_v2_tests (counters/tables the collector reads).
-module(janus_gateway_sched_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NOW, 1_000_000).

%%%===================================================================
%%% Pinned schema (spec Part C, rev 10)
%%%===================================================================

sched_json_full_shape_test() ->
    Json = janus_gateway_stats:sched_json(full_data()),
    ?assertEqual(
        lists:sort([
            schema_version,
            geo_enabled,
            rtt_enabled,
            health_enabled,
            probe_enabled,
            snapshot_gen,
            geo_match_total,
            dispatch_worker_total,
            dispatch_local_total,
            capacity_exhausted_total,
            health_demote_total,
            probe_total,
            probe_skip_total,
            rtt_ms,
            rtt_ms_other,
            rtt_dropped_total,
            reserve_purged_total,
            reserve_inflight,
            health_ewma_ms,
            geo_disabled_total,
            fleet_worker_report_mismatch_total
        ]),
        lists:sort(maps:keys(Json))
    ),
    ?assertEqual(1, maps:get(schema_version, Json)),
    ?assertEqual(true, maps:get(geo_enabled, Json)),
    ?assertEqual(false, maps:get(rtt_enabled, Json)),
    ?assertEqual(true, maps:get(health_enabled, Json)),
    ?assertEqual(true, maps:get(probe_enabled, Json)),
    ?assertEqual(7, maps:get(snapshot_gen, Json)),
    ?assertEqual(#{region_tag => 2, auto => 0, none => 1}, maps:get(geo_match_total, Json)),
    ?assertEqual(#{<<"w1/5">> => 4}, maps:get(dispatch_worker_total, Json)),
    ?assertEqual(
        #{
            empty_pool => 1,
            capacity => 2,
            drained => 0,
            drained_pin => 0,
            send_fail => 0,
            ack_miss => 1
        },
        maps:get(dispatch_local_total, Json)
    ),
    ?assertEqual(3, maps:get(capacity_exhausted_total, Json)),
    ?assertEqual(2, maps:get(health_demote_total, Json)),
    ?assertEqual(#{<<"5">> => 4}, maps:get(probe_total, Json)),
    ?assertEqual(
        #{cap => 1, cadence => 2, fresh => 3, drained => 4, send_fail => 5},
        maps:get(probe_skip_total, Json)
    ),
    ?assertEqual(#{<<"w1/5">> => 12.5}, maps:get(rtt_ms, Json)),
    ?assertEqual(#{count => 0, max_ms => 0.0}, maps:get(rtt_ms_other, Json)),
    ?assertEqual(#{negative => 1, non_finite => 2}, maps:get(rtt_dropped_total, Json)),
    ?assertEqual(1, maps:get(reserve_purged_total, Json)),
    ?assertEqual(#{<<"w1">> => 2, <<"w2">> => 0}, maps:get(reserve_inflight, Json)),
    ?assertEqual(#{<<"w1">> => 8000.0, <<"w2">> => 750.5}, maps:get(health_ewma_ms, Json)),
    ?assertEqual(1, maps:get(geo_disabled_total, Json)),
    ?assertEqual(9, maps:get(fleet_worker_report_mismatch_total, Json)),
    %% The assembled map must be JSON-encodable (thoas is the handler's
    %% encoder).
    ?assertMatch(<<_/binary>>, thoas:encode(Json)).

sched_json_empty_data_test() ->
    Json = janus_gateway_stats:sched_json(#{}),
    ?assertEqual(1, maps:get(schema_version, Json)),
    ?assertEqual(false, maps:get(geo_enabled, Json)),
    ?assertEqual(0, maps:get(snapshot_gen, Json)),
    ?assertEqual(#{region_tag => 0, auto => 0, none => 0}, maps:get(geo_match_total, Json)),
    ?assertEqual(#{}, maps:get(dispatch_worker_total, Json)),
    ?assertEqual(#{}, maps:get(probe_total, Json)),
    ?assertEqual(
        #{cap => 0, cadence => 0, fresh => 0, drained => 0, send_fail => 0},
        maps:get(probe_skip_total, Json)
    ),
    ?assertEqual(#{}, maps:get(rtt_ms, Json)),
    %% The overflow aggregate is ALWAYS present.
    ?assertEqual(#{count => 0, max_ms => 0.0}, maps:get(rtt_ms_other, Json)),
    ?assertEqual(#{}, maps:get(reserve_inflight, Json)),
    ?assertEqual(#{}, maps:get(health_ewma_ms, Json)),
    ?assertEqual(0, maps:get(geo_disabled_total, Json)).

%%%===================================================================
%%% rtt_ms cap: 64 most recent unexpired by SampledAtMono
%%%===================================================================

sched_json_rtt_cap_64_test() ->
    %% 70 unexpired pairs, SampledAt == provider id (1..70), Ms == float
    %% of the same — the 64 NEWEST survive (7..70), the 6 oldest
    %% overflow with max_ms = 6.0. One EXPIRED row is dropped at read
    %% time regardless of recency.
    Rows = [{{w1, I}, I * 1.0, passive, I, ?NOW + 600_000} || I <- lists:seq(1, 70)],
    Expired = {{w1, 999}, 1.0, probe, 10_000, ?NOW - 1},
    Json = janus_gateway_stats:sched_json(data(#{}, Rows ++ [Expired], [], #{})),
    RttMs = maps:get(rtt_ms, Json),
    ?assertEqual(64, map_size(RttMs)),
    ?assertMatch(#{<<"w1/70">> := 70.0}, RttMs),
    ?assertMatch(#{<<"w1/7">> := 7.0}, RttMs),
    ?assertNot(maps:is_key(<<"w1/6">>, RttMs)),
    ?assertNot(maps:is_key(<<"w1/999">>, RttMs)),
    ?assertEqual(#{count => 6, max_ms => 6.0}, maps:get(rtt_ms_other, Json)).

sched_json_rtt_cap_exact_64_test() ->
    Rows = [{{w1, I}, I * 1.0, probe, I, ?NOW + 1} || I <- lists:seq(1, 64)],
    Json = janus_gateway_stats:sched_json(data(#{}, Rows, [], #{})),
    ?assertEqual(64, map_size(maps:get(rtt_ms, Json))),
    ?assertEqual(#{count => 0, max_ms => 0.0}, maps:get(rtt_ms_other, Json)).

%%%===================================================================
%%% Fixtures
%%%===================================================================

data(Counters, RttRows, ReserveRows, Ewma) ->
    #{
        stats => Counters#{
            knobs => #{
                geo_enabled => true,
                rtt_enabled => false,
                health_enabled => true,
                probe => true
            },
            rtt_rows => RttRows,
            reserve_rows => ReserveRows,
            health_ewma => Ewma
        },
        now_mono => ?NOW,
        geo_disabled => 1
    }.

full_data() ->
    Counters = #{
        snapshot_gen => 7,
        {geo_match, region_tag} => 2,
        {geo_match, none} => 1,
        {dispatch_worker, w1, 5} => 4,
        {dispatch_local, empty_pool} => 1,
        {dispatch_local, capacity} => 2,
        {dispatch_local, ack_miss} => 1,
        capacity_exhausted => 3,
        health_demote => 2,
        {probe, 5} => 4,
        {probe_skip, cap} => 1,
        {probe_skip, cadence} => 2,
        {probe_skip, fresh} => 3,
        {probe_skip, drained} => 4,
        {probe_skip, send_fail} => 5,
        {rtt_dropped, negative} => 1,
        {rtt_dropped, non_finite} => 2,
        reserve_purged => 1,
        fleet_worker_report_mismatch => 9
    },
    data(
        Counters,
        [{{w1, 5}, 12.5, passive, ?NOW - 10, ?NOW + 600_000}],
        [{w1, 2}, {w2, 0}],
        #{w1 => 8000, w2 => 750.5}
    ).


%% Legacy knobs shape (rtt/health keys, no derived aliases): the
%% handler must fall back to the raw keys (ocr review contract).
legacy_knob_keys_fallback_test() ->
    D = data(#{}, [], [], #{}),
    Knobs0 = maps:get(knobs, maps:get(stats, D)),
    Base = maps:without([rtt_enabled, health_enabled], Knobs0),
    Legacy = Base#{rtt => true, health => false},
    D1 = (maps:get(stats, D))#{knobs := Legacy},
    J = janus_gateway_stats:sched_json(#{stats => D1, now_mono => 1, geo_disabled => 0}),
    %% sched_json returns atom-keyed maps (thoas encodes afterwards).
    ?assertEqual(true, maps:get(rtt_enabled, J)),
    ?assertEqual(false, maps:get(health_enabled, J)).
