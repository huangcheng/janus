%% Latency-aware candidate shedding (EWMA degradation filter).
%% Pure logic, eunit-first per repo rules; fixtures use the production
%% shape: route maps with integer provider_id/model_id, and the lookup
%% fun receives janus_lb:route_target/1 = {route, ModelId, ProviderId}
%% exactly as the ETS-backed wiring produces.
-module(janus_lb_degraded_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FACTOR, 300). %% degrade when > 3x the best peer
-define(FLOOR, 1500). %% ... and above this absolute floor (ms)

ewma(Map) ->
    fun(Target) -> maps:get(Target, Map, undefined) end.

r(P, M) -> #{provider_id => P, model_id => M}.
t(P, M) -> {route, M, P}.

filter(Routes, Ew) ->
    janus_lb:degraded_filter(Routes, Ew, ?FACTOR, ?FLOOR).

drops_sick_peer_test() ->
    Routes = [r(1, 7), r(2, 7)],
    Ew = ewma(#{t(1, 7) => {400, 10}, t(2, 7) => {6000, 10}}),
    ?assertEqual([r(1, 7)], filter(Routes, Ew)).

below_floor_never_degrades_test() ->
    %% 9x the best but still under the floor: jitter among fast
    %% providers must not shed anyone.
    Routes = [r(1, 7), r(2, 7)],
    Ew = ewma(#{t(1, 7) => {100, 10}, t(2, 7) => {900, 10}}),
    ?assertEqual(Routes, filter(Routes, Ew)).

cold_route_never_degraded_test() ->
    Routes = [r(1, 7), r(2, 7)],
    Ew = ewma(#{t(1, 7) => {200, 10}}),
    ?assertEqual(Routes, filter(Routes, Ew)).

lone_eligible_route_is_own_best_test() ->
    %% A single route with samples can never be degraded relative to
    %% itself; cold routes cannot make it look sick either.
    Routes = [r(1, 7), r(2, 7)],
    Ew = ewma(#{t(1, 7) => {9000, 10}}),
    ?assertEqual(Routes, filter(Routes, Ew)).

factor_boundary_is_strict_test() ->
    Routes = [r(1, 7), r(2, 7)],
    Exact = ewma(#{t(1, 7) => {2000, 10}, t(2, 7) => {6000, 10}}),
    ?assertEqual(Routes, filter(Routes, Exact)),
    Over = ewma(#{t(1, 7) => {2000, 10}, t(2, 7) => {6001, 10}}),
    ?assertEqual([r(1, 7)], filter(Routes, Over)).

too_few_samples_kept_test() ->
    Routes = [r(1, 7), r(2, 7)],
    Ew = ewma(#{t(1, 7) => {400, 10}, t(2, 7) => {9000, 3}}),
    ?assertEqual(Routes, filter(Routes, Ew)).

single_route_unchanged_test() ->
    Routes = [r(1, 7)],
    Ew = ewma(#{t(1, 7) => {30000, 100}}),
    ?assertEqual(Routes, filter(Routes, Ew)).

empty_input_test() ->
    ?assertEqual([], filter([], ewma(#{}))).

sheds_only_the_sick_among_many_test() ->
    Routes = [r(1, 7), r(2, 7), r(3, 7)],
    Ew = ewma(#{t(1, 7) => {500, 20}, t(2, 7) => {800, 20}, t(3, 7) => {7000, 20}}),
    ?assertEqual([r(1, 7), r(2, 7)], filter(Routes, Ew)).
