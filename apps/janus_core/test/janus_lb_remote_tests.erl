%% Fleet read-path consults + egress coalescer in janus_lb (spec
%% native-distribution Part B), pure-logic eunit-first with injected
%% funs exactly like janus_lb_degraded_tests. Fixtures use the
%% production route/target shapes ({route, ModelId, ProviderId}).
-module(janus_lb_remote_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../include/janus_lb.hrl").

r(P, M) -> #{provider_id => P, model_id => M}.
t(P, M) -> {route, M, P}.
provider_target(#{provider_id := P}) -> {provider, P}.

%%--------------------------------------------------------------------
%% Remote-cool consult: any single live sender's unexpired row cools
%% the target — EXCEPT when it would remove the last candidate.
%%--------------------------------------------------------------------

coolfun(Map) ->
    fun(Target) -> maps:get(Target, Map, false) end.

remote_cool_sheds_sick_route_test() ->
    Routes = [r(1, 7), r(2, 7)],
    {Kept, Flag} = janus_lb:remote_cool_filter(Routes, coolfun(#{t(2, 7) => true})),
    ?assertEqual([r(1, 7)], Kept),
    ?assertEqual(shed, Flag).

remote_cool_provider_target_also_consulted_test() ->
    Routes = [r(1, 7), r(2, 7)],
    {Kept, Flag} = janus_lb:remote_cool_filter(Routes, coolfun(#{provider_target(r(1, 7)) => true})),
    ?assertEqual([r(2, 7)], Kept),
    ?assertEqual(shed, Flag).

remote_cool_never_sheds_last_test() ->
    Routes = [r(1, 7)],
    {Kept, Flag} = janus_lb:remote_cool_filter(Routes, coolfun(#{t(1, 7) => true})),
    ?assertEqual(Routes, Kept),
    ?assertEqual(last_resort, Flag).

remote_cool_all_shed_keeps_all_test() ->
    Routes = [r(1, 7), r(2, 7)],
    {Kept, Flag} = janus_lb:remote_cool_filter(Routes, coolfun(#{t(1, 7) => true, t(2, 7) => true})),
    ?assertEqual(Routes, Kept),
    ?assertEqual(last_resort, Flag).

remote_cool_empty_passthrough_test() ->
    {[], passthrough} = janus_lb:remote_cool_filter([], coolfun(#{})),
    {Routes, shed} = janus_lb:remote_cool_filter([r(1, 7)], coolfun(#{})),
    ?assertEqual([r(1, 7)], Routes).

%%--------------------------------------------------------------------
%% Remote latency quorum post-filter (>= 2 distinct live senders
%% degraded; fresh local evidence wins; never sheds the last route).
%%--------------------------------------------------------------------

latfun(Map) ->
    fun(Target) -> maps:get(Target, Map, []) end.
localfun(Map) ->
    fun(Target) -> maps:get(Target, Map, undefined) end.

quorum_two_senders_sheds_absent_local_test() ->
    Routes = [r(1, 7), r(2, 7)],
    Rows = #{t(2, 7) => [{gw1, degraded}, {gw2, degraded}]},
    ?assertEqual([r(1, 7)], janus_lb:remote_lat_postfilter(Routes, latfun(Rows), localfun(#{}))).

single_sender_never_sheds_test() ->
    Routes = [r(1, 7), r(2, 7)],
    Rows = #{t(2, 7) => [{gw1, degraded}]},
    ?assertEqual(Routes, janus_lb:remote_lat_postfilter(Routes, latfun(Rows), localfun(#{}))).

same_sender_two_rows_not_quorum_test() ->
    %% duplicate rows from ONE sender (duplicate_bag upsert keeps one,
    %% but the filter must be robust regardless) never count twice.
    Routes = [r(1, 7), r(2, 7)],
    Rows = #{t(2, 7) => [{gw1, degraded}, {gw1, degraded}]},
    ?assertEqual(Routes, janus_lb:remote_lat_postfilter(Routes, latfun(Rows), localfun(#{}))).

healthy_remote_rows_do_not_shed_test() ->
    Routes = [r(1, 7), r(2, 7)],
    Rows = #{t(2, 7) => [{gw1, healthy}, {gw2, healthy}]},
    ?assertEqual(Routes, janus_lb:remote_lat_postfilter(Routes, latfun(Rows), localfun(#{}))).

local_fresh_wins_test() ->
    Routes = [r(1, 7), r(2, 7)],
    Rows = #{t(2, 7) => [{gw1, degraded}, {gw2, degraded}]},
    Local = #{t(2, 7) => {600, 10}},
    ?assertEqual(Routes, janus_lb:remote_lat_postfilter(Routes, latfun(Rows), localfun(Local))).

local_under_sampled_still_sheds_test() ->
    %% A single probe sample (< ?EWMA_MIN_SAMPLES) is NOT local-wins —
    %% the F.3 phase-2 witness contract.
    Routes = [r(1, 7), r(2, 7)],
    Rows = #{t(2, 7) => [{gw1, degraded}, {gw2, degraded}]},
    Local = #{t(2, 7) => {600, ?EWMA_MIN_SAMPLES - 1}},
    ?assertEqual([r(1, 7)], janus_lb:remote_lat_postfilter(Routes, latfun(Rows), localfun(Local))).

never_sheds_last_test() ->
    Routes = [r(1, 7)],
    Rows = #{t(1, 7) => [{gw1, degraded}, {gw2, degraded}]},
    ?assertEqual(Routes, janus_lb:remote_lat_postfilter(Routes, latfun(Rows), localfun(#{}))).

would_empty_returns_prefilter_set_test() ->
    Routes = [r(1, 7), r(2, 7)],
    Rows = #{t(1, 7) => [{gw1, degraded}, {gw2, degraded}], t(2, 7) => [{gw1, degraded}, {gw2, degraded}]},
    ?assertEqual(Routes, janus_lb:remote_lat_postfilter(Routes, latfun(Rows), localfun(#{}))).

%%--------------------------------------------------------------------
%% Latency verdict (sender-side, family-relative): same thresholds as
%% the local degraded_filter, computed per model family.
%%--------------------------------------------------------------------

lat_verdict_test() ->
    Fam = [{400, 10}, {6000, 10}],
    ?assertEqual(degraded, janus_lb:lat_verdict({6000, 10}, Fam, 300, 1500)),
    ?assertEqual(healthy, janus_lb:lat_verdict({400, 10}, Fam, 300, 1500)),
    %% Under the floor: never degraded.
    ?assertEqual(healthy, janus_lb:lat_verdict({900, 10}, [{100, 10}, {900, 10}], 300, 1500)),
    %% Own-best route is healthy by construction.
    ?assertEqual(healthy, janus_lb:lat_verdict({400, 10}, [{400, 10}], 300, 1500)),
    %% No eligible peers: no basis, healthy.
    ?assertEqual(healthy, janus_lb:lat_verdict({6000, 10}, [{400, 3}], 300, 1500)).

%%--------------------------------------------------------------------
%% Publish coalescer: verdict flips need 2 consecutive evaluations;
%% degraded heartbeat is 5 s coalesced; healthy flips announce too.
%%--------------------------------------------------------------------

lpe(Entry, Target, Verdict, Ewma, Samples, Now) ->
    janus_lb:lat_publish_eval(Entry, Target, Verdict, Ewma, Samples, Now).

single_degraded_eval_does_not_publish_test() ->
    {Entry, undefined} = lpe(undefined, t(1, 7), degraded, 6000, 10, 1000),
    %% LastVerdict stays at the healthy baseline after one evaluation.
    ?assertEqual(healthy, element(1, Entry)).

first_eval_never_flips_test() ->
    %% First-ever evaluation (even healthy) establishes the baseline
    %% without publishing.
    {Entry, undefined} = lpe(undefined, t(1, 7), healthy, 400, 10, 1000),
    ?assertEqual(healthy, element(1, Entry)).

flip_needs_two_consecutive_test() ->
    {E1, undefined} = lpe(undefined, t(1, 7), degraded, 6000, 10, 1000),
    {E2, Msg} = lpe(E1, t(1, 7), degraded, 6100, 11, 2000),
    ?assertMatch({lb_lat, _, degraded, 6100, 11, ?FLEET_LAT_TTL_MS}, Msg),
    ?assertEqual(degraded, element(1, E2)).

flip_requires_consecutive_test() ->
    {E1, undefined} = lpe(undefined, t(1, 7), degraded, 6000, 10, 1000),
    %% Interleaved healthy eval resets the pending streak.
    {E2, undefined} = lpe(E1, t(1, 7), healthy, 700, 11, 1500),
    {E3, undefined} = lpe(E2, t(1, 7), degraded, 6100, 12, 2000),
    %% The second consecutive degraded evaluation after the reset flips.
    {E4, Msg} = lpe(E3, t(1, 7), degraded, 6200, 13, 2500),
    ?assertMatch({lb_lat, _, degraded, 6200, 13, _}, Msg),
    ?assertEqual(degraded, element(1, E4)).

heartbeat_five_second_coalesced_test() ->
    {E1, undefined} = lpe(undefined, t(1, 7), degraded, 6000, 10, 1000),
    {E2, Flip} = lpe(E1, t(1, 7), degraded, 6100, 11, 2000),
    ?assertMatch({lb_lat, _, degraded, _, _, _}, Flip),
    %% Below the heartbeat window: silent.
    {E3, undefined} = lpe(E2, t(1, 7), degraded, 6200, 12, 5000),
    %% >= 5 s since the flip publish: heartbeat.
    {E4, Heartbeat} = lpe(E3, t(1, 7), degraded, 6300, 13, 7001),
    ?assertMatch({lb_lat, _, degraded, 6300, 13, ?FLEET_LAT_TTL_MS}, Heartbeat),
    %% Coalesced again right after.
    {_, undefined} = lpe(E4, t(1, 7), degraded, 6400, 14, 7002).

healthy_flip_publishes_once_test() ->
    {E1, _} = lpe(undefined, t(1, 7), degraded, 6000, 10, 1000),
    {E2, _} = lpe(E1, t(1, 7), degraded, 6100, 11, 2000),
    {E3, undefined} = lpe(E2, t(1, 7), healthy, 700, 12, 3000),
    {E4, Msg} = lpe(E3, t(1, 7), healthy, 750, 13, 4000),
    ?assertMatch({lb_lat, _, healthy, 750, 13, ?FLEET_LAT_TTL_MS}, Msg),
    ?assertEqual(healthy, element(1, E4)),
    %% No heartbeat while healthy.
    {_, undefined} = lpe(E4, t(1, 7), healthy, 800, 14, 600000).

heartbeat_carries_degraded_only_test() ->
    %% LastV still degraded, current verdict healthy (pending reset):
    %% no publish at all (the flip will announce after 2 evals).
    {E1, _} = lpe(undefined, t(1, 7), degraded, 6000, 10, 1000),
    {E2, _} = lpe(E1, t(1, 7), degraded, 6100, 11, 2000),
    {E3, undefined} = lpe(E2, t(1, 7), healthy, 700, 12, 600000),
    ?assertEqual(degraded, element(1, E3)).
