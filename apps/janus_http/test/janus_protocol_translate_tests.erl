%%%-------------------------------------------------------------------
%%% @doc EUnit tests for protocol translation.
%%% Run: rebar3 eunit --app janus_http
%%% @end
%%%-------------------------------------------------------------------
-module(janus_protocol_translate_tests).

-include_lib("eunit/include/eunit.hrl").

normalize_test() ->
    ?assertEqual({ok, openai_chat}, janus_protocol_translate:normalize_protocol(<<"openai_chat">>)),
    ?assertEqual({ok, openai_chat}, janus_protocol_translate:normalize_protocol(undefined)),
    ?assertEqual({error, unknown_protocol}, janus_protocol_translate:normalize_protocol(<<"foo">>)).

wants_stream_test() ->
    ?assertEqual(true, janus_protocol_translate:wants_stream(#{<<"stream">> => true})),
    ?assertEqual(false, janus_protocol_translate:wants_stream(#{<<"stream">> => false})),
    ?assertEqual(false, janus_protocol_translate:wants_stream(#{})).

chat_to_messages_text_test() ->
    In = #{
        <<"model">> => <<"m">>,
        <<"messages">> => [
            #{<<"role">> => <<"system">>, <<"content">> => <<"be nice">>},
            #{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}
        ],
        <<"max_tokens">> => 128
    },
    {ok, Out} = janus_protocol_translate:translate_request(
        openai_chat, anthropic_messages, In
    ),
    ?assertEqual(<<"m">>, maps:get(<<"model">>, Out)),
    ?assertEqual(<<"be nice">>, maps:get(<<"system">>, Out)),
    ?assertEqual(128, maps:get(<<"max_tokens">>, Out)),
    ?assertMatch([#{<<"role">> := <<"user">>, <<"content">> := <<"hi">>}], maps:get(<<"messages">>, Out)).

messages_to_chat_text_test() ->
    In = #{
        <<"model">> => <<"m">>,
        <<"system">> => <<"sys">>,
        <<"max_tokens">> => 64,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"yo">>}]
    },
    {ok, Out} = janus_protocol_translate:translate_request(
        anthropic_messages, openai_chat, In
    ),
    Msgs = maps:get(<<"messages">>, Out),
    ?assertEqual(
        [
            #{<<"role">> => <<"system">>, <<"content">> => <<"sys">>},
            #{<<"role">> => <<"user">>, <<"content">> => <<"yo">>}
        ],
        Msgs
    ).

tool_roundtrip_chat_messages_test() ->
    ChatReq = #{
        <<"model">> => <<"m">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"weather?">>},
            #{
                <<"role">> => <<"assistant">>,
                <<"content">> => <<>>,
                <<"tool_calls">> => [
                    #{
                        <<"id">> => <<"call_1">>,
                        <<"type">> => <<"function">>,
                        <<"function">> => #{
                            <<"name">> => <<"get_weather">>,
                            <<"arguments">> => <<"{\"city\":\"SF\"}">>
                        }
                    }
                ]
            },
            #{
                <<"role">> => <<"tool">>,
                <<"tool_call_id">> => <<"call_1">>,
                <<"content">> => <<"sunny">>
            }
        ],
        <<"tools">> => [
            #{
                <<"type">> => <<"function">>,
                <<"function">> => #{
                    <<"name">> => <<"get_weather">>,
                    <<"description">> => <<"w">>,
                    <<"parameters">> => #{
                        <<"type">> => <<"object">>,
                        <<"properties">> => #{<<"city">> => #{<<"type">> => <<"string">>}}
                    }
                }
            }
        ]
    },
    {ok, MsgReq} = janus_protocol_translate:translate_request(
        openai_chat, anthropic_messages, ChatReq
    ),
    ?assert(is_list(maps:get(<<"tools">>, MsgReq))),
    Msgs = maps:get(<<"messages">>, MsgReq),
    ?assertEqual(3, length(Msgs)),
    {ok, Back} = janus_protocol_translate:translate_request(
        anthropic_messages, openai_chat, MsgReq
    ),
    BackMsgs = maps:get(<<"messages">>, Back),
    ?assert(lists:any(fun(M) -> maps:get(<<"role">>, M) =:= <<"tool">> end, BackMsgs)).

chat_to_responses_test() ->
    In = #{
        <<"model">> => <<"m">>,
        <<"messages">> => [
            #{<<"role">> => <<"system">>, <<"content">> => <<"s">>},
            #{<<"role">> => <<"user">>, <<"content">> => <<"u">>}
        ]
    },
    {ok, Out} = janus_protocol_translate:translate_request(openai_chat, openai_responses, In),
    ?assertEqual(<<"s">>, maps:get(<<"instructions">>, Out)),
    ?assertEqual(false, maps:get(<<"store">>, Out)),
    ?assertMatch([#{<<"type">> := <<"message">>, <<"role">> := <<"user">>} | _], maps:get(<<"input">>, Out)).

responses_to_chat_test() ->
    In = #{
        <<"model">> => <<"m">>,
        <<"instructions">> => <<"s">>,
        <<"input">> => <<"hello">>
    },
    {ok, Out} = janus_protocol_translate:translate_request(openai_responses, openai_chat, In),
    Msgs = maps:get(<<"messages">>, Out),
    ?assertEqual(<<"s">>, maps:get(<<"content">>, hd(Msgs))),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, lists:last(Msgs))).

vision_rejected_test() ->
    In = #{
        <<"model">> => <<"m">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{<<"type">> => <<"image_url">>, <<"image_url">> => #{<<"url">> => <<"x">>}}
                ]
            }
        ]
    },
    ?assertMatch(
        {error, {translate_unsupported, _}},
        janus_protocol_translate:translate_request(openai_chat, anthropic_messages, In)
    ).

previous_response_id_rejected_test() ->
    In = #{
        <<"model">> => <<"m">>,
        <<"input">> => <<"hi">>,
        <<"previous_response_id">> => <<"resp_x">>
    },
    ?assertMatch(
        {error, {translate_unsupported, _}},
        janus_protocol_translate:translate_request(openai_responses, openai_chat, In)
    ).

messages_responses_pivot_test() ->
    In = #{
        <<"model">> => <<"m">>,
        <<"max_tokens">> => 32,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    },
    {ok, Out} = janus_protocol_translate:translate_request(
        anthropic_messages, openai_responses, In
    ),
    ?assertEqual(false, maps:get(<<"store">>, Out)),
    ?assert(is_list(maps:get(<<"input">>, Out))).

chat_resp_to_messages_test() ->
    ChatResp = #{
        <<"id">> => <<"chatcmpl-1">>,
        <<"model">> => <<"m">>,
        <<"choices">> => [
            #{
                <<"finish_reason">> => <<"stop">>,
                <<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => <<"ok">>}
            }
        ],
        <<"usage">> => #{<<"prompt_tokens">> => 1, <<"completion_tokens">> => 2}
    },
    {ok, Out} = janus_protocol_translate:translate_response(
        anthropic_messages, openai_chat, ChatResp
    ),
    ?assertEqual(<<"end_turn">>, maps:get(<<"stop_reason">>, Out)),
    ?assertEqual(2, maps:get(<<"output_tokens">>, maps:get(<<"usage">>, Out))),
    Content = maps:get(<<"content">>, Out),
    ?assertMatch([#{<<"type">> := <<"text">>, <<"text">> := <<"ok">>}], Content).

thinking_blocks_to_reasoning_content_test() ->
    %% Kimi/MiniMax thinking models: text + thinking blocks in an
    %% anthropic response must translate (thinking -> reasoning_content),
    %% not crash the proxy (throw/bad_part used to escape the fold).
    AnthropicResp =
        #{
            <<"id">> => <<"msg_1">>,
            <<"model">> => <<"kimi-for-coding">>,
            <<"stop_reason">> => <<"end_turn">>,
            <<"content">> => [
                #{<<"type">> => <<"thinking">>, <<"thinking">> => <<"let me think">>},
                #{<<"type">> => <<"text">>, <<"text">> => <<"ok">>},
                #{<<"type">> => <<"thinking">>, <<"signature">> => <<"enc...">>}
            ],
            <<"usage">> => #{<<"input_tokens">> => 5, <<"output_tokens">> => 9}
        },
    {ok, Chat} = janus_protocol_translate:translate_response(
        openai_chat, anthropic_messages, AnthropicResp
    ),
    [#{<<"message">> := Msg}] = maps:get(<<"choices">>, Chat),
    ?assertEqual(<<"ok">>, maps:get(<<"content">>, Msg)),
    ?assertEqual(<<"let me think">>, maps:get(<<"reasoning_content">>, Msg)),
    ?assertEqual(9, maps:get(<<"completion_tokens">>, maps:get(<<"usage">>, Chat))).
