%% model_routes.priority semantics (review 06d M6): the dashboard
%% Router copy documents "Lower priorities are tried first; failover
%% moves to the next one" and "Traffic share within the same priority
%% (weighted round-robin)". Boots the REAL janus_lb gen_server and
%% publishes a REAL bundle through janus_catalog:build/1 — no DB.
%% Fixtures are production-shaped: integer ids and SMALLINT 0/1
%% enabled columns (never atoms/booleans).
-module(janus_lb_priority_tests).

-include_lib("eunit/include/eunit.hrl").

-define(GEN, 999_994).

priority_test_() ->
    {setup, fun setup/0, fun cleanup/1,
        {inorder, [
            fun lowest_priority_serves_alone/0,
            fun unusable_tier_falls_through/0,
            fun same_priority_shares_by_weight/0
        ]}}.

setup() ->
    janus_catalog:publish(?GEN, janus_catalog:build(rows())),
    {ok, Lb} = janus_lb:start_link(),
    Lb.

cleanup(Lb) ->
    stop(Lb),
    janus_catalog:publish(?GEN, janus_catalog:build(#{})),
    ok.

%% Model 1: provider 10 at priority 0, provider 20 at priority 10.
%% Model 2: provider 30 at priority 0 (its only key disabled), provider
%% 40 at priority 10.
%% Model 3: providers 50/60 both at priority 0, weight 1 each.
rows() ->
    #{
        models => [
            #{id => 1, name => <<"prio-model">>, enabled => 1},
            #{id => 2, name => <<"fallback-model">>, enabled => 1},
            #{id => 3, name => <<"equal-model">>, enabled => 1}
        ],
        model_routes => [
            route(1, 10, 0),
            route(1, 20, 10),
            route(2, 30, 0),
            route(2, 40, 10),
            route(3, 50, 0),
            route(3, 60, 0)
        ],
        providers => [provider(Id) || Id <- [10, 20, 30, 40, 50, 60]],
        provider_keys => [key(Id, enabled(Id)) || Id <- [10, 20, 30, 40, 50, 60]],
        api_keys => [],
        api_key_models => [],
        provider_models => []
    }.

route(ModelId, ProviderId, Priority) ->
    #{
        model_id => ModelId,
        provider_id => ProviderId,
        upstream_model_id => null,
        weight => 1,
        priority => Priority,
        enabled => 1
    }.

provider(Id) ->
    #{
        id => Id,
        name => iolist_to_binary(["prov-", integer_to_list(Id)]),
        base_url => <<"https://provider.test/v1">>,
        protocol => <<"openai_chat">>,
        enabled => 1
    }.

key(Id, Enabled) ->
    #{
        id => Id * 10,
        provider_id => Id,
        secret_ciphertext => <<"ciphertext">>,
        key_id => iolist_to_binary(["kid-", integer_to_list(Id)]),
        weight => 1,
        enabled => Enabled
    }.

%% Provider 30's only key is disabled, so its priority-0 tier is not
%% usable and the pick must fall through to priority 10.
enabled(30) -> 0;
enabled(_) -> 1.

%% Priority 0 is tried first: a healthy primary must serve every pick
%% (the old weighted RR alternated 50/50 with the priority-10 backup).
lowest_priority_serves_alone() ->
    ?assertEqual([10, 10, 10, 10], [picked(1) || _ <- lists:seq(1, 4)]).

%% Failover moves to the next priority when the best tier has no
%% usable key.
unusable_tier_falls_through() ->
    ?assertEqual([40, 40, 40], [picked(2) || _ <- lists:seq(1, 3)]).

%% Equal priorities still share traffic by weight (weight 1 each:
%% strictly alternating weighted RR).
same_priority_shares_by_weight() ->
    ?assertEqual([50, 60, 50, 60], [picked(3) || _ <- lists:seq(1, 4)]).

picked(ModelId) ->
    {ok, Route} = janus_lb:pick_route(ModelId, #{}),
    maps:get(provider_id, Route).

stop(Pid) ->
    Ref = monitor(process, Pid),
    try
        gen_server:stop(Pid)
    catch
        _:_ -> ok
    end,
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 2000 ->
        exit(Pid, kill)
    end,
    ok.
