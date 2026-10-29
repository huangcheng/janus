%% models.enabled on the direct-call pick path (review 06d H1): the
%% dashboard's per-model disable must yield the existing no_route pick
%% error instead of serving traffic. Boots the REAL janus_lb gen_server
%% and publishes a REAL bundle through janus_catalog:build/1 — no DB.
%% Fixtures are production-shaped: BIGSERIAL integer ids and SMALLINT
%% 0/1 enabled columns (never atoms/booleans).
-module(janus_lb_model_enabled_tests).

-include_lib("eunit/include/eunit.hrl").

-define(GEN, 999_995).

model_enabled_test_() ->
    {setup, fun setup/0, fun cleanup/1,
        {inorder, [
            fun disabled_model_yields_no_route/0,
            fun enabled_model_still_picks/0
        ]}}.

setup() ->
    janus_catalog:publish(?GEN, janus_catalog:build(rows())),
    {ok, Lb} = janus_lb:start_link(),
    Lb.

cleanup(Lb) ->
    stop(Lb),
    janus_catalog:publish(?GEN, janus_catalog:build(#{})),
    ok.

rows() ->
    #{
        models => [
            #{id => 1, name => <<"live-model">>, enabled => 1},
            #{id => 2, name => <<"off-model">>, enabled => 0}
        ],
        model_routes => [route(1), route(2)],
        providers => [
            #{
                id => 10,
                name => <<"prov">>,
                base_url => <<"https://provider.test/v1">>,
                protocol => <<"openai_chat">>,
                enabled => 1
            }
        ],
        provider_keys => [
            #{
                id => 100,
                provider_id => 10,
                secret_ciphertext => <<"ciphertext">>,
                key_id => <<"kid-1">>,
                weight => 1,
                enabled => 1
            }
        ],
        api_keys => [],
        api_key_models => [],
        provider_models => []
    }.

route(ModelId) ->
    #{
        model_id => ModelId,
        provider_id => 10,
        upstream_model_id => null,
        weight => 1,
        priority => 0,
        enabled => 1
    }.

%% Model 2 has an enabled route, an enabled provider and a usable key —
%% only its `models` row is disabled.
disabled_model_yields_no_route() ->
    ?assertMatch({ok, #{enabled := false}}, janus_catalog:lookup_model(2)),
    ?assertMatch([#{enabled := true}], janus_catalog:routes_for_model(2)),
    ?assertEqual({error, no_route}, janus_lb:pick_route(2, #{})).

%% The control: the identical fixture with enabled = 1 picks, so the
%% no_route above is the model-level disable and not a broken fixture.
enabled_model_still_picks() ->
    ?assertMatch({ok, #{provider_id := 10}}, janus_lb:pick_route(1, #{})).

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
