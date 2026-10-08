%% janus-auto fleet integration (spec Part B2): the exported
%% receive-side API (fleet_cache_put/4) and judge_model/0 against the
%% REAL table set (the supervised gen_server boots like janus_usage
%% eunit — stateful modules are tested live). The miss-only publish
%% hook inside pos_write is covered by janus_auto's internal TEST block.
-module(janus_auto_fleet_tests).

-include_lib("eunit/include/eunit.hrl").

with_auto(Judge, Fun) ->
    application:set_env(janus, auto_router, [{judge_model, Judge}]),
    persistent_term:put({janus, fleet_enabled}, false),
    {ok, Pid} = janus_auto:start_link(),
    try
        Fun()
    after
        catch gen_server:stop(Pid),
        application:unset_env(janus, auto_router),
        persistent_term:put({janus, fleet_enabled}, false)
    end.

judge_model_reflects_config_test() ->
    with_auto(<<"judge-m">>, fun() ->
        ?assertEqual(<<"judge-m">>, janus_auto:judge_model())
    end).

judge_model_undefined_when_unset_test() ->
    with_auto(undefined, fun() ->
        ?assertEqual(undefined, janus_auto:judge_model())
    end).

fleet_cache_put_roundtrip_test() ->
    with_auto(<<"judge-m">>, fun() ->
        H = 424242,
        ok = janus_auto:fleet_cache_put(H, <<"fast">>, <<"judge-m">>, 300),
        %% The local decision cache now serves the hash a peer shared —
        %% pos_read is the judge-zone read the request path uses.
        ?assertEqual({ok, fast}, janus_auto:pos_read(H, <<"judge-m">>))
    end).

fleet_cache_put_judge_mismatch_drops_test() ->
    with_auto(<<"judge-m">>, fun() ->
        H = 424243,
        ?assertEqual({error, judge_mismatch}, janus_auto:fleet_cache_put(H, <<"fast">>, <<"other">>, 300)),
        ?assertEqual(miss, janus_auto:pos_read(H, <<"other">>))
    end).

fleet_cache_put_ttl_clamped_test() ->
    with_auto(<<"judge-m">>, fun() ->
        H = 424244,
        %% TTLs beyond the cache_put class are clamped (300 s max).
        ok = janus_auto:fleet_cache_put(H, <<"big">>, <<"judge-m">>, 9999),
        ?assertEqual({ok, big}, janus_auto:pos_read(H, <<"judge-m">>))
    end).

fleet_cache_put_badarg_test() ->
    with_auto(<<"judge-m">>, fun() ->
        ?assertEqual({error, badarg}, janus_auto:fleet_cache_put(<<>>, <<"fast">>, <<"judge-m">>, 300)),
        ?assertEqual({error, badarg}, janus_auto:fleet_cache_put(1, <<"fast">>, <<"judge-m">>, 0))
    end).

wire_hash_codec_test() ->
    [?assertEqual(N, janus_fleet:wire_to_hash(janus_fleet:hash_to_wire(N))) || N <- [0, 1, 268435455]].
