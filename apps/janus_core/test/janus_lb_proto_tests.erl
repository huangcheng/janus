%% Prefer-proto route filtering (streaming translate-blocked requests
%% must ride a same-protocol route when one exists). Fixtures use the
%% production shape: route maps with binary protocol via the lookup
%% fun, exactly as janus_catalog:lookup_provider returns them.
-module(janus_lb_proto_tests).

-include_lib("eunit/include/eunit.hrl").

%% Production shape: the injected fun takes the ROUTE map (as
%% janus_lb:route_protocol/1 does) and returns its provider protocol.
route_proto(#{provider_id := 1}) -> <<"openai_chat">>;
route_proto(#{provider_id := 2}) -> <<"anthropic_messages">>;
route_proto(#{provider_id := 3}) -> <<"openai_responses">>;
route_proto(#{provider_id := missing}) -> undefined;
route_proto(#{provider_id := broken}) -> undefined;
%% Route without a provider_id key at all — production's
%% maps:get(..., undefined) branch must tolerate it.
route_proto(Route) when is_map(Route) -> maps:get(protocol, Route, undefined).

routes() ->
    [
        #{provider_id => 1},
        #{provider_id => 2},
        #{provider_id => missing}
    ].

filter(Rs, Proto) ->
    janus_lb:prefer_proto_filter(Rs, Proto, fun route_proto/1).

keeps_only_matching_test() ->
    ?assertEqual(
        [#{provider_id => 2}],
        filter(routes(), <<"anthropic_messages">>)
    ).

falls_back_to_all_when_none_matches_test() ->
    ?assertEqual(
        routes(),
        filter(routes(), <<"openai_responses">>)
    ).

falls_back_when_provider_unknown_or_protocolless_test() ->
    ?assertEqual(
        [#{provider_id => missing}, #{provider_id => broken}],
        filter([#{provider_id => missing}, #{provider_id => broken}], <<"openai_chat">>)
    ).

route_without_provider_id_uses_inline_protocol_test() ->
    ?assertEqual(
        [#{protocol => <<"openai_chat">>}],
        filter([#{protocol => <<"openai_chat">>}, #{other => 1}], <<"openai_chat">>)
    ).

preference_applies_within_pickable_set_test() ->
    %% ocr review (2026-10-07): pick_from_routes composes preference
    %% with the PICKABLE set — same-protocol preferred when pickable,
    %% ALL pickable routes otherwise, so a cooling same-protocol route
    %% never strands a translatable stream on a 503.
    Pickable = [#{provider_id => 2}, #{provider_id => 3}],
    ?assertEqual([#{provider_id => 2}], filter(Pickable, <<"anthropic_messages">>)),
    OnlyCrossProtocolPickable = [#{provider_id => 2}],
    ?assertEqual(OnlyCrossProtocolPickable, filter(OnlyCrossProtocolPickable, <<"openai_chat">>)).

empty_input_test() ->
    ?assertEqual([], filter([], <<"openai_chat">>)).
