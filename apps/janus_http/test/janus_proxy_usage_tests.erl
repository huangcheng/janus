-module(janus_proxy_usage_tests).

-include_lib("eunit/include/eunit.hrl").

trim_under_cap_passthrough_test() ->
    ?assertEqual({[<<"c">>, <<"b">>], 2}, janus_http_proxy:maybe_trim([<<"c">>, <<"b">>], 2)).

trim_keeps_newest_within_byte_cap_test() ->
    C1 = binary:copy(<<"a">>, 8192),
    C2 = binary:copy(<<"b">>, 8192),
    C3 = binary:copy(<<"c">>, 8192),
    %% newest-first input, 24KB total -> keeps the two newest (16KB),
    %% result stored newest-first; stream_usage/1 reverses for bytes.
    ?assertEqual({[C3, C2], 16384}, janus_http_proxy:maybe_trim([C3, C2, C1], 24576)).

trim_chunk_count_cap_test() ->
    Chunks = lists:duplicate(300, <<"x">>),
    {Kept, _} = janus_http_proxy:maybe_trim(Chunks, 300),
    ?assertEqual(256, length(Kept)).

injection_absent_by_default_for_non_openai_test() ->
    ?assertEqual(
        {<<"{}">>, #{<<"stream">> => true}},
        janus_http_proxy:maybe_inject_stream_usage(
            anthropic_messages, true, <<"{}">>, #{<<"stream">> => true}
        )
    ).

injection_adds_include_usage_test() ->
    application:set_env(janus_core, usage_inject_include_usage, true),
    {Body2, Map2} = janus_http_proxy:maybe_inject_stream_usage(openai_chat, true, <<"{}">>, #{}),
    ?assertEqual(#{<<"include_usage">> => true}, maps:get(<<"stream_options">>, Map2)),
    ?assert(is_binary(Body2)).

injection_respects_client_stream_options_test() ->
    application:set_env(janus_core, usage_inject_include_usage, true),
    Map = #{<<"stream_options">> => #{<<"include_usage">> => false}},
    ?assertEqual(
        {<<"{}">>, Map},
        janus_http_proxy:maybe_inject_stream_usage(openai_chat, true, <<"{}">>, Map)
    ).

injection_kill_switch_test() ->
    application:set_env(janus_core, usage_inject_include_usage, false),
    Map = #{},
    ?assertEqual(
        {<<"{}">>, Map},
        janus_http_proxy:maybe_inject_stream_usage(openai_chat, true, <<"{}">>, Map)
    ),
    application:set_env(janus_core, usage_inject_include_usage, true).
