-module(janus_catalog_tests).

%% Regression tests for the listing-union surface. Fixtures mirror the
%% REAL pipeline shapes — epgsql rows with SMALLINT 0/1 booleans and
%% JSONB meta as a binary — because every bug these tests guard against
%% (integer enabled in a boolean predicate, `case M of #{}` matching
%% every map, fold arity) shipped green while the hand-written fixtures
%% used atoms and booleans.

-include_lib("eunit/include/eunit.hrl").

production_shaped_listings_test() ->
    Meta = <<"{\"context_window\":1048576,\"reasoning\":true}">>,
    Tabs = janus_catalog:build(#{
        models => [],
        model_routes => [],
        providers => [],
        provider_keys => [],
        api_keys => [],
        api_key_models => [],
        provider_models => [
            #{id => 1, provider_id => 1, name => <<"m-a">>, enabled => 1, meta => Meta},
            #{id => 2, provider_id => 2, name => <<"m-a">>, enabled => 1, meta => null},
            #{id => 3, provider_id => 3, name => <<"m-off">>, enabled => 0, meta => Meta}
        ]
    }),
    janus_catalog:publish(999_999, Tabs),
    try
        %% disabled listings are not part of the agent surface
        ?assertEqual([<<"m-a">>], lists:sort(janus_catalog:listing_names())),
        %% every enabled provider offering the name gives a route
        ?assertEqual(
            [#{model_id => null, provider_id => 1}, #{model_id => null, provider_id => 2}],
            lists:sort(janus_catalog:listings_for(<<"m-a">>))
        ),
        ?assertEqual([], janus_catalog:listings_for(<<"m-off">>)),
        %% merged capability metadata: `case Merged of #{}` used to match
        %% EVERY map (open subset) and silently discard all metadata.
        S = janus_catalog:listings_summary(),
        ?assertMatch([_], maps:to_list(S)),
        #{<<"m-a">> := Merged} = S,
        ?assertEqual(1048576, maps:get(<<"context_length">>, Merged)),
        ?assert(maps:get(<<"reasoning">>, Merged) =:= true)
    after
        janus_catalog:publish(999_999, janus_catalog:build(#{}))
    end.

tier_members_union_test() ->
    Tabs = janus_catalog:build(#{
        models => [],
        model_routes => [],
        providers => [],
        provider_keys => [],
        api_keys => [],
        api_key_models => [],
        provider_models => [
            #{id => 1, provider_id => 1, name => <<"x">>, enabled => 1, meta => null},
            #{id => 2, provider_id => 2, name => <<"x">>, enabled => 1, meta => null}
        ]
    }),
    janus_catalog:publish(999_998, Tabs),
    try
        Routes = lists:sort(janus_catalog:listings_for(<<"x">>)),
        ?assertEqual(
            [#{model_id => null, provider_id => 1}, #{model_id => null, provider_id => 2}],
            Routes
        )
    after
        janus_catalog:publish(999_998, janus_catalog:build(#{}))
    end.
