%% stream_pick_opts / auto-tier constraint predicate (single source:
%% stream_translate_blocked_for/2). Fixtures are JSON-decoded shapes
%% (binary keys) exactly as cowboy/thoas hand them to the handler.
-module(janus_proxy_stream_pick_tests).

-include_lib("eunit/include/eunit.hrl").

plain_text_stream_not_blocked_test() ->
    ?assertNot(
        janus_http_proxy:stream_translate_blocked_for(
            openai_chat,
            #{<<"stream">> => true, <<"messages">> => []}
        )
    ).

tools_stream_blocked_test() ->
    ?assert(
        janus_http_proxy:stream_translate_blocked_for(
            anthropic_messages,
            #{
                <<"stream">> => true,
                <<"tools">> => [#{<<"name">> => <<"f">>}]
            }
        )
    ).

n_over_1_blocked_test() ->
    ?assert(
        janus_http_proxy:stream_translate_blocked_for(
            openai_chat,
            #{<<"stream">> => <<"true">>, <<"n">> => 2}
        )
    ).

responses_client_always_blocked_when_streaming_test() ->
    ?assert(
        janus_http_proxy:stream_translate_blocked_for(
            openai_responses,
            #{<<"stream">> => true, <<"input">> => <<"hi">>}
        )
    ).

non_stream_never_blocked_test() ->
    ?assertNot(
        janus_http_proxy:stream_translate_blocked_for(
            openai_responses,
            #{<<"input">> => <<"hi">>}
        )
    ).
