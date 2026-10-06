%%%-------------------------------------------------------------------
%%% @doc EUnit tests for the streaming SSE translate path (Slice A):
%%% sse_events/2 parser + translate_sse/4 + finalize_sse/3. Written
%%% BEFORE the implementation; fixtures use provider-shaped JSON with
%%% binary keys (thoas-decoded), never hand-idiomatic atoms.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_translate_sse_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../src/janus_protocol_translate.hrl").

%%%-------------------------------------------------------------------
%%% sse_events/2 — parser
%%%-------------------------------------------------------------------

sse_split_data_line_test() ->
    {ok, [], Rest} = janus_protocol_translate:sse_events(<<>>, <<"data: {\"a\":">>),
    ?assertEqual(<<"data: {\"a\":">>, Rest),
    {ok, [Ev], <<>>} = janus_protocol_translate:sse_events(Rest, <<"1}\n\n">>),
    ?assertEqual(#{type => <<"chunk">>, data => #{<<"a">> => 1}}, Ev).

sse_crlf_and_multiple_events_test() ->
    Chunk =
        <<"event: message_start\r\ndata: {\"x\":1}\r\n\r\n"
          "event: ping\r\ndata: {}\r\n\r\n">>,
    {ok, [E1, E2], <<>>} = janus_protocol_translate:sse_events(<<>>, Chunk),
    ?assertEqual(#{type => <<"message_start">>, data => #{<<"x">> => 1}}, E1),
    ?assertEqual(#{type => <<"ping">>, data => #{}}, E2).

sse_comment_lines_skipped_test() ->
    {ok, Events, <<>>} =
        janus_protocol_translate:sse_events(
            <<>>,
            <<": keepalive\ndata: {\"a\":2}\n: another\n\n">>
        ),
    ?assertEqual([#{type => <<"chunk">>, data => #{<<"a">> => 2}}], Events).

sse_done_marker_test() ->
    {ok, [Done], <<>>} = janus_protocol_translate:sse_events(<<>>, <<"data: [DONE]\n\n">>),
    ?assertEqual(#{type => <<"done">>, data => <<>>}, Done).

sse_no_space_after_colon_test() ->
    %% SSE strips at most ONE leading space after the field colon.
    {ok, [Ev], <<>>} = janus_protocol_translate:sse_events(<<>>, <<"data:{\"a\":3}\n\n">>),
    ?assertEqual(#{type => <<"chunk">>, data => #{<<"a">> => 3}}, Ev).

sse_malformed_json_is_binary_test() ->
    {ok, [Ev], <<>>} = janus_protocol_translate:sse_events(<<>>, <<"data: not-json\n\n">>),
    ?assertEqual(#{type => <<"chunk">>, data => <<"not-json">>}, Ev).

sse_leftover_cap_test() ->
    Big = binary:copy(<<"a">>, 1024 * 1024),
    ?assertEqual(
        {error, leftover_cap},
        janus_protocol_translate:sse_events(Big, <<"x">>)
    ),
    ?assertEqual(
        {error, leftover_cap},
        janus_protocol_translate:sse_events(<<>>, <<Big/binary, "data: x\n\n">>)
    ).

%%%-------------------------------------------------------------------
%%% translate_sse/4 — provider Anthropic -> client Chat
%%%-------------------------------------------------------------------

anthro_ping_to_chat_comment_test() ->
    {ok, Frames, St} = janus_protocol_translate:translate_sse(
        openai_chat, anthropic_messages, #{type => <<"ping">>, data => #{}}, #sse_st{}
    ),
    ?assertEqual([<<": ping\n\n">>], Frames),
    ?assertEqual(false, St#sse_st.role_sent).

anthro_message_start_first_chunk_test() ->
    Ev = #{
        type => <<"message_start">>,
        data => #{
            <<"type">> => <<"message_start">>,
            <<"message">> => #{
                <<"id">> => <<"msg_1">>,
                <<"model">> => <<"kimi">>,
                <<"usage">> => #{<<"input_tokens">> => 12}
            }
        }
    },
    {ok, Frames, St} =
        janus_protocol_translate:translate_sse(openai_chat, anthropic_messages, Ev, #sse_st{}),
    ?assertEqual(true, St#sse_st.role_sent),
    ?assertEqual(<<"msg_1">>, St#sse_st.msg_id),
    ?assertEqual(12, St#sse_st.in_tokens),
    ?assert(is_integer(St#sse_st.created)),
    ?assertMatch([<<"data: ", _/binary>>], Frames),
    [<<"data: ", Json/binary>>] = Frames,
    {ok, Map} = thoas:decode(Json),
    ?assertEqual(<<"chat.completion.chunk">>, maps:get(<<"object">>, Map)),
    ?assertEqual(<<"msg_1">>, maps:get(<<"id">>, Map)),
    [Choice] = maps:get(<<"choices">>, Map),
    ?assertEqual(#{<<"role">> => <<"assistant">>}, maps:get(<<"delta">>, Choice)).

anthro_thinking_delta_to_reasoning_test() ->
    St0 = #sse_st{role_sent = true},
    Ev = #{
        type => <<"content_block_delta">>,
        data => #{<<"index">> => 0, <<"delta">> => #{<<"type">> => <<"thinking_delta">>, <<"thinking">> => <<"hmm">>}}
    },
    {ok, Frames, St} =
        janus_protocol_translate:translate_sse(openai_chat, anthropic_messages, Ev, St0),
    ?assertMatch([<<"data: ", _/binary>>], Frames),
    [<<"data: ", Json/binary>>] = Frames,
    {ok, Map} = thoas:decode(Json),
    [Choice] = maps:get(<<"choices">>, Map),
    ?assertEqual(#{<<"reasoning_content">> => <<"hmm">>}, maps:get(<<"delta">>, Choice)),
    ?assertEqual(false, St#sse_st.finish_sent).

anthro_text_delta_test() ->
    St0 = #sse_st{role_sent = true},
    Ev = #{
        type => <<"content_block_delta">>,
        data => #{<<"index">> => 0, <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => <<"hi">>}}
    },
    {ok, Frames, _} =
        janus_protocol_translate:translate_sse(openai_chat, anthropic_messages, Ev, St0),
    [<<"data: ", Json/binary>>] = Frames,
    {ok, Map} = thoas:decode(Json),
    [Choice] = maps:get(<<"choices">>, Map),
    ?assertEqual(#{<<"content">> => <<"hi">>}, maps:get(<<"delta">>, Choice)).

anthro_block_start_with_text_test() ->
    %% Non-empty text on the start object emits as the first delta.
    Ev = #{
        type => <<"content_block_start">>,
        data => #{<<"index">> => 0, <<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<"go">>}}
    },
    {ok, Frames, St} =
        janus_protocol_translate:translate_sse(openai_chat, anthropic_messages, Ev, #sse_st{role_sent = true}),
    ?assertMatch([_], Frames),
    ?assertEqual(text, St#sse_st.block_kind),
    [<<"data: ", Json/binary>>] = Frames,
    {ok, Map} = thoas:decode(Json),
    [Choice] = maps:get(<<"choices">>, Map),
    ?assertEqual(#{<<"content">> => <<"go">>}, maps:get(<<"delta">>, Choice)).

anthro_block_start_empty_test() ->
    Ev = #{
        type => <<"content_block_start">>,
        data => #{<<"index">> => 0, <<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<>>}}
    },
    {ok, [], St} =
        janus_protocol_translate:translate_sse(openai_chat, anthropic_messages, Ev, #sse_st{role_sent = true}),
    ?assertEqual(text, St#sse_st.block_kind).

%% Tool_use blocks translate now (Phase 1); a malformed block (no
%% id/name) still fails closed.
anthro_tool_use_block_malformed_error_test() ->
    Ev = #{
        type => <<"content_block_start">>,
        data => #{<<"index">> => 0, <<"content_block">> => #{<<"type">> => <<"tool_use">>}}
    },
    ?assertMatch(
        {error, translate_unsupported, #sse_st{}},
        janus_protocol_translate:translate_sse(openai_chat, anthropic_messages, Ev, #sse_st{})
    ).

anthro_signature_delta_skip_test() ->
    Ev = #{
        type => <<"content_block_delta">>,
        data => #{<<"index">> => 0, <<"delta">> => #{<<"type">> => <<"signature_delta">>, <<"signature">> => <<"x">>}}
    },
    {ok, [], _} =
        janus_protocol_translate:translate_sse(openai_chat, anthropic_messages, Ev, #sse_st{}).

anthro_message_delta_finish_test() ->
    %% end_turn -> stop; usage output stashed, NOT on the finish chunk.
    Ev = #{
        type => <<"message_delta">>,
        data => #{
            <<"delta">> => #{<<"stop_reason">> => <<"end_turn">>},
            <<"usage">> => #{<<"output_tokens">> => 7}
        }
    },
    {ok, Frames, St} =
        janus_protocol_translate:translate_sse(
            openai_chat, anthropic_messages, Ev, #sse_st{role_sent = true, finish_sent = false}
        ),
    ?assertEqual(true, St#sse_st.finish_sent),
    ?assertEqual(7, St#sse_st.out_tokens),
    ?assertEqual(false, St#sse_st.usage_sent),
    [<<"data: ", Json/binary>>] = Frames,
    {ok, Map} = thoas:decode(Json),
    [Choice] = maps:get(<<"choices">>, Map),
    ?assertEqual(<<"stop">>, maps:get(<<"finish_reason">>, Choice)),
    ?assertNot(maps:is_key(<<"usage">>, Map)).

anthro_stop_reason_mapping_test() ->
    Pairs = [
        {<<"max_tokens">>, <<"length">>},
        {<<"refusal">>, <<"content_filter">>},
        {<<"pause_turn">>, <<"stop">>},
        {<<"weird_new_one">>, <<"stop">>}
    ],
    lists:foreach(fun({In, Out}) ->
        Ev = #{type => <<"message_delta">>, data => #{<<"delta">> => #{<<"stop_reason">> => In}}},
        {ok, Frames, _} = janus_protocol_translate:translate_sse(
            openai_chat, anthropic_messages, Ev, #sse_st{role_sent = true}
        ),
        [<<"data: ", Json/binary>>] = Frames,
        {ok, Map} = thoas:decode(Json),
        [Choice] = maps:get(<<"choices">>, Map),
        ?assertEqual(Out, maps:get(<<"finish_reason">>, Choice), In)
    end, Pairs).

anthro_message_stop_usage_then_done_test() ->
    %% message_stop with pending usage: usage chunk then [DONE].
    St0 = #sse_st{role_sent = true, finish_sent = true, in_tokens = 3, out_tokens = 5, msg_id = <<"m">>, model = <<"mm">>, created = 99},
    {ok, Frames, St} =
        janus_protocol_translate:translate_sse(
            openai_chat, anthropic_messages, #{type => <<"message_stop">>, data => #{}}, St0
        ),
    ?assertEqual(2, length(Frames)),
    [<<"data: ", Json/binary>>, <<"data: [DONE]\n\n">>] = Frames,
    {ok, Map} = thoas:decode(Json),
    ?assertEqual([], maps:get(<<"choices">>, Map)),
    ?assertEqual(#{<<"prompt_tokens">> => 3, <<"completion_tokens">> => 5}, maps:get(<<"usage">>, Map)),
    ?assertEqual(true, St#sse_st.terminal_sent),
    ?assertEqual(true, St#sse_st.usage_sent).

anthro_message_stop_no_usage_test() ->
    St0 = #sse_st{role_sent = true, finish_sent = true},
    {ok, Frames, St} =
        janus_protocol_translate:translate_sse(
            openai_chat, anthropic_messages, #{type => <<"message_stop">>, data => #{}}, St0
        ),
    ?assertEqual([<<"data: [DONE]\n\n">>], Frames),
    ?assertEqual(true, St#sse_st.terminal_sent).

anthro_inband_error_test() ->
    ?assertMatch(
        {error, translate_unsupported, #sse_st{}},
        janus_protocol_translate:translate_sse(
            openai_chat,
            anthropic_messages,
            #{type => <<"error">>, data => #{<<"error">> => #{<<"message">> => <<"boom">>}}},
            #sse_st{role_sent = true}
        )
    ).

anthro_unknown_event_noop_test() ->
    {ok, [], _} =
        janus_protocol_translate:translate_sse(
            openai_chat,
            anthropic_messages,
            #{type => <<"content_block_stop">>, data => #{<<"index">> => 0}},
            #sse_st{role_sent = true}
        ),
    %% Undecodable data (parser kept it binary) never crashes the fold.
    {ok, [], _} =
        janus_protocol_translate:translate_sse(
            openai_chat,
            anthropic_messages,
            #{type => <<"message_start">>, data => <<"garbage">>},
            #sse_st{}
        ).

%%%-------------------------------------------------------------------
%%% translate_sse/4 — provider Chat -> client Anthropic
%%%-------------------------------------------------------------------

chat_first_chunk_envelope_test() ->
    Ev = #{
        type => <<"chunk">>,
        data => #{
            <<"id">> => <<"chatcmpl-1">>,
            <<"model">> => <<"glm">>,
            <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"role">> => <<"assistant">>}}]
        }
    },
    {ok, Frames, St} =
        janus_protocol_translate:translate_sse(anthropic_messages, openai_chat, Ev, #sse_st{}),
    ?assertEqual(true, St#sse_st.role_sent),
    ?assertEqual(false, St#sse_st.terminal_sent),
    [<<"event: message_start\ndata: ", Json/binary>>] = Frames,
    {ok, Map} = thoas:decode(Json),
    ?assertEqual(<<"message_start">>, maps:get(<<"type">>, Map)),
    Msg = maps:get(<<"message">>, Map),
    ?assertEqual(<<"chatcmpl-1">>, maps:get(<<"id">>, Msg)),
    ?assertEqual(<<"glm">>, maps:get(<<"model">>, Msg)),
    ?assertEqual(0, maps:get(<<"input_tokens">>, maps:get(<<"usage">>, Msg))).

chat_no_role_first_chunk_test() ->
    Ev = #{
        type => <<"chunk">>,
        data => #{<<"id">> => <<"c2">>, <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"content">> => <<"hey">>}}]}
    },
    {ok, Frames, St} =
        janus_protocol_translate:translate_sse(anthropic_messages, openai_chat, Ev, #sse_st{}),
    ?assertEqual(true, St#sse_st.role_sent),
    ?assertEqual(text, St#sse_st.block_kind),
    ?assertEqual(0, St#sse_st.block),
    ?assertEqual(1, St#sse_st.next_block),
    ?assertEqual(3, length(Frames)),
    %% message_start, content_block_start(text), text_delta
    [Start, BlockStart, Delta] = Frames,
    ?assertMatch(<<"event: message_start", _/binary>>, Start),
    ?assertMatch(<<"event: content_block_start\ndata: ", _/binary>>, BlockStart),
    ?assertMatch(<<"event: content_block_delta\ndata: ", _/binary>>, Delta),
    Prefix = <<"event: content_block_delta\ndata: ">>,
    {ok, DMap} = thoas:decode(binary:part(Delta, byte_size(Prefix), byte_size(Delta) - byte_size(Prefix))),
    ?assertEqual(<<"text_delta">>, maps:get(<<"type">>, maps:get(<<"delta">>, DMap))).

chat_empty_delta_keepalive_test() ->
    %% Empty delta after start: keepalive, no frames, no new block.
    St0 = #sse_st{role_sent = true},
    Ev = #{type => <<"chunk">>, data => #{<<"id">> => <<"c">>, <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{}}]}},
    {ok, [], St} = janus_protocol_translate:translate_sse(anthropic_messages, openai_chat, Ev, St0),
    ?assertEqual(undefined, St#sse_st.block).

chat_reasoning_transition_test() ->
    %% Same chunk carries content AND reasoning: content first, then ONE
    %% transition into thinking (stop text block, start thinking block).
    St0 = #sse_st{role_sent = true, block = 0, block_kind = text, next_block = 1},
    Ev = #{
        type => <<"chunk">>,
        data => #{
            <<"id">> => <<"c">>,
            <<"choices">> => [
                #{
                    <<"index">> => 0,
                    <<"delta">> => #{<<"content">> => <<"A">>, <<"reasoning_content">> => <<"B">>}
                }
            ]
        }
    },
    {ok, Frames, St} = janus_protocol_translate:translate_sse(anthropic_messages, openai_chat, Ev, St0),
    %% text_delta(A), content_block_stop(0), content_block_start(thinking,1), thinking_delta(B)
    ?assertEqual(4, length(Frames)),
    ?assertEqual(thinking, St#sse_st.block_kind),
    ?assertEqual(1, St#sse_st.block),
    ?assertEqual(2, St#sse_st.next_block),
    [D1, Stop, Start, D2] = Frames,
    ?assertMatch(<<"event: content_block_delta", _/binary>>, D1),
    ?assertMatch(<<"event: content_block_stop", _/binary>>, Stop),
    ?assertMatch(<<"event: content_block_start", _/binary>>, Start),
    ?assertMatch(<<"event: content_block_delta", _/binary>>, D2),
    %% No signature anywhere.
    ?assertNot(lists:member(<<"signature">>, Frames)).

chat_usage_stash_then_done_test() ->
    St0 = #sse_st{role_sent = true, finish_sent = true, finish_reason = <<"stop">>, in_tokens = 4, out_tokens = 6},
    %% Standalone usage chunk after finish: message_delta now.
    EvU = #{type => <<"chunk">>, data => #{<<"id">> => <<"c">>, <<"choices">> => [], <<"usage">> => #{<<"prompt_tokens">> => 4, <<"completion_tokens">> => 6}}},
    {ok, Frames1, St1} = janus_protocol_translate:translate_sse(anthropic_messages, openai_chat, EvU, St0),
    ?assertEqual(true, St1#sse_st.usage_sent),
    [<<"event: message_delta\ndata: ", Json/binary>>] = Frames1,
    {ok, M} = thoas:decode(Json),
    ?assertEqual(<<"end_turn">>, maps:get(<<"stop_reason">>, maps:get(<<"delta">>, M))),
    ?assertEqual(#{<<"input_tokens">> => 4, <<"output_tokens">> => 6}, maps:get(<<"usage">>, M)),
    %% Then [DONE]: message_stop only.
    {ok, Frames2, St2} =
        janus_protocol_translate:translate_sse(anthropic_messages, openai_chat, #{type => <<"done">>}, St1),
    ?assertEqual([<<"event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n">>], Frames2),
    ?assertEqual(true, St2#sse_st.terminal_sent).

chat_done_without_usage_test() ->
    St0 = #sse_st{role_sent = true, finish_sent = true, finish_reason = <<"length">>},
    {ok, Frames, St} =
        janus_protocol_translate:translate_sse(anthropic_messages, openai_chat, #{type => <<"done">>}, St0),
    ?assertEqual(2, length(Frames)),
    [<<"event: message_delta\ndata: ", Json/binary>>, <<"event: message_stop", _/binary>>] = Frames,
    {ok, M} = thoas:decode(Json),
    ?assertEqual(<<"max_tokens">>, maps:get(<<"stop_reason">>, maps:get(<<"delta">>, M))),
    %% Usage object omitted when both token fields are unknown.
    ?assertNot(maps:is_key(<<"usage">>, M)),
    ?assertEqual(true, St#sse_st.terminal_sent).

chat_finish_reason_closes_block_test() ->
    St0 = #sse_st{role_sent = true, block = 0, block_kind = text, next_block = 1},
    Ev = #{
        type => <<"chunk">>,
        data => #{<<"id">> => <<"c">>, <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{}, <<"finish_reason">> => <<"stop">>}]}
    },
    {ok, Frames, St} = janus_protocol_translate:translate_sse(anthropic_messages, openai_chat, Ev, St0),
    ?assertEqual(true, St#sse_st.finish_sent),
    ?assertEqual(<<"end_turn">>, St#sse_st.stop_reason),
    %% Only the block stop; message_delta is delayed until usage/[DONE].
    ?assertEqual([<<"event: content_block_stop\ndata: {\"index\":0}\n\n">>], Frames).

%% An empty tool_calls array carries no entries: a keepalive no-op.
chat_tool_calls_empty_list_noop_test() ->
    Ev = #{
        type => <<"chunk">>,
        data => #{<<"id">> => <<"c">>, <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"tool_calls">> => []}}]}
    },
    {ok, [], St} =
        janus_protocol_translate:translate_sse(anthropic_messages, openai_chat, Ev, #sse_st{role_sent = true}),
    ?assertEqual(undefined, St#sse_st.open_tool).

%% finish_reason=tool_calls with an empty delta maps to stop tool_use;
%% the message_delta stays delayed until usage/[DONE].
chat_finish_reason_tool_calls_maps_stop_test() ->
    Ev = #{
        type => <<"chunk">>,
        data => #{
            <<"id">> => <<"c">>,
            <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{}, <<"finish_reason">> => <<"tool_calls">>}]
        }
    },
    {ok, [], St} =
        janus_protocol_translate:translate_sse(anthropic_messages, openai_chat, Ev, #sse_st{role_sent = true}),
    ?assertEqual(true, St#sse_st.finish_sent),
    ?assertEqual(<<"tool_use">>, St#sse_st.stop_reason).

anthro_stop_reason_tool_use_maps_to_tool_calls_test() ->
    %% tool_use -> finish_reason=tool_calls (C2 map), usage stashed.
    Ev = #{
        type => <<"message_delta">>,
        data => #{<<"delta">> => #{<<"stop_reason">> => <<"tool_use">>}, <<"usage">> => #{<<"output_tokens">> => 4}}
    },
    {ok, Frames, St} =
        janus_protocol_translate:translate_sse(
            openai_chat, anthropic_messages, Ev, #sse_st{role_sent = true}
        ),
    ?assertEqual(true, St#sse_st.finish_sent),
    ?assertEqual(4, St#sse_st.out_tokens),
    [<<"data: ", Json/binary>>] = Frames,
    {ok, Map} = thoas:decode(Json),
    [Choice] = maps:get(<<"choices">>, Map),
    ?assertEqual(<<"tool_calls">>, maps:get(<<"finish_reason">>, Choice)),
    ?assertNot(maps:is_key(<<"usage">>, Map)).

chat_instream_error_object_test() ->
    Ev = #{type => <<"chunk">>, data => #{<<"error">> => #{<<"message">> => <<"quota">>}}},
    ?assertMatch(
        {error, translate_unsupported, #sse_st{}},
        janus_protocol_translate:translate_sse(anthropic_messages, openai_chat, Ev, #sse_st{})
    ).

%%%-------------------------------------------------------------------
%%% finalize_sse/3
%%%-------------------------------------------------------------------

finalize_chat_normal_test() ->
    %% EOF without message_stop: finish chunk (default stop) + usage + [DONE].
    St0 = #sse_st{role_sent = true, in_tokens = 2, out_tokens = 3, msg_id = <<"m">>, model = <<"mm">>, created = 5},
    {ok, Frames, St} = janus_protocol_translate:finalize_sse(openai_chat, normal, St0),
    ?assertEqual(3, length(Frames)),
    [Finish, Usage, Done] = Frames,
    ?assertMatch(<<"data: ", _/binary>>, Finish),
    ?assertMatch(<<"data: ", _/binary>>, Usage),
    ?assertEqual(<<"data: [DONE]\n\n">>, Done),
    {ok, FMap} = thoas:decode(binary:part(Finish, 6, byte_size(Finish) - 6)),
    [C] = maps:get(<<"choices">>, FMap),
    ?assertEqual(<<"stop">>, maps:get(<<"finish_reason">>, C)),
    {ok, UMap} = thoas:decode(binary:part(Usage, 6, byte_size(Usage) - 6)),
    ?assertEqual(#{<<"prompt_tokens">> => 2, <<"completion_tokens">> => 3}, maps:get(<<"usage">>, UMap)),
    ?assertEqual(true, St#sse_st.terminal_sent).

finalize_chat_no_double_usage_test() ->
    %% finish and usage already sent: terminator only.
    St0 = #sse_st{role_sent = true, finish_sent = true, usage_sent = true, terminal_sent = false, in_tokens = 1, out_tokens = 1},
    {ok, Frames, _} = janus_protocol_translate:finalize_sse(openai_chat, normal, St0),
    ?assertEqual([<<"data: [DONE]\n\n">>], Frames).

finalize_anthropic_zero_content_test() ->
    %% Zero-content face: one empty text start+stop, message_delta, message_stop.
    St0 = #sse_st{role_sent = true},
    {ok, Frames, St} = janus_protocol_translate:finalize_sse(anthropic_messages, normal, St0),
    ?assertEqual(4, length(Frames)),
    [BS, BStop, MDelta, MStop] = Frames,
    ?assertMatch(<<"event: content_block_start", _/binary>>, BS),
    ?assertMatch(<<"event: content_block_stop", _/binary>>, BStop),
    ?assertMatch(<<"event: message_delta", _/binary>>, MDelta),
    ?assertMatch(<<"event: message_stop", _/binary>>, MStop),
    ?assertEqual(true, St#sse_st.terminal_sent).

finalize_anthropic_open_block_test() ->
    %% Open block at EOF: content_block_stop first; no zero-content block.
    St0 = #sse_st{role_sent = true, block = 0, block_kind = text, next_block = 1},
    {ok, Frames, _} = janus_protocol_translate:finalize_sse(anthropic_messages, normal, St0),
    [Stop | _] = Frames,
    ?assertMatch(<<"event: content_block_stop\ndata: {\"index\":0}\n\n">>, Stop),
    ?assertEqual(3, length(Frames)).

finalize_idempotent_test() ->
    St0 = #sse_st{role_sent = true},
    {ok, _, St1} = janus_protocol_translate:finalize_sse(openai_chat, normal, St0),
    {ok, [], St2} = janus_protocol_translate:finalize_sse(openai_chat, normal, St1),
    ?assertEqual(true, St2#sse_st.terminal_sent).

finalize_disconnect_no_frames_test() ->
    {ok, [], St} = janus_protocol_translate:finalize_sse(openai_chat, disconnect, #sse_st{role_sent = true}),
    ?assertEqual(true, St#sse_st.terminal_sent),
    {ok, [], _} = janus_protocol_translate:finalize_sse(openai_chat, normal, St).

finalize_chat_error_invalid_request_test() ->
    {ok, Frames, St} =
        janus_protocol_translate:finalize_sse(
            openai_chat, {error, invalid_request, <<"n must be 1">>}, #sse_st{role_sent = true}
        ),
    ?assertEqual(2, length(Frames)),
    [Err, Done] = Frames,
    ?assertMatch(<<"data: {\"error\"", _/binary>>, Err),
    ?assertEqual(<<"data: [DONE]\n\n">>, Done),
    ?assertEqual(true, St#sse_st.terminal_sent).

finalize_anthropic_error_upstream_test() ->
    {ok, Frames, _} =
        janus_protocol_translate:finalize_sse(
            anthropic_messages, {error, upstream, <<"provider died">>}, #sse_st{role_sent = true}
        ),
    [Err, MStop] = Frames,
    ?assertMatch(<<"event: error\ndata: ", _/binary>>, Err),
    ErrPrefix = <<"event: error\ndata: ">>,
    {ok, M} = thoas:decode(
        binary:part(Err, byte_size(ErrPrefix), byte_size(Err) - byte_size(ErrPrefix))
    ),
    ?assertEqual(<<"api_error">>, maps:get(<<"type">>, maps:get(<<"error">>, M))),
    ?assertMatch(<<"event: message_stop", _/binary>>, MStop).

finalize_error_message_truncated_test() ->
    Long = binary:copy(<<"z">>, 500),
    {ok, Frames, _} =
        janus_protocol_translate:finalize_sse(openai_chat, {error, upstream, Long}, #sse_st{role_sent = true}),
    [Err, _] = Frames,
    ?assert(byte_size(Err) =< 300).

stream_translate_blocked_table_test() ->
    T = fun(Client, Map) ->
        janus_protocol_translate:stream_translate_blocked(Client, Map)
    end,
    Base = #{<<"messages">> => []},
    ?assertEqual(false, T(openai_chat, Base)),
    ?assertEqual(false, T(anthropic_messages, Base)),
    ?assertEqual(true, T(openai_responses, #{<<"input">> => []})),
    ?assertEqual(true, T(openai_chat, Base#{<<"tools">> => [#{<<"x">> => 1}]})),
    ?assertEqual(false, T(openai_chat, Base#{<<"tools">> => []})),
    ?assertEqual(true, T(openai_chat, Base#{<<"n">> => 2})),
    ?assertEqual(false, T(openai_chat, Base#{<<"n">> => 1})),
    ?assertEqual(
        true,
        T(openai_chat, #{
            <<"messages">> => [
                #{<<"role">> => <<"user">>, <<"content">> => [#{<<"type">> => <<"image_url">>}]}
            ]
        })
    ).

finalize_anthropic_missing_start_test() ->
    %% Empty 200 body (no decodable chunk): finalize must still open
    %% with message_start so the client stream is never malformed.
    {ok, Frames, St} = janus_protocol_translate:finalize_sse(anthropic_messages, normal, #sse_st{}),
    [First | _] = Frames,
    ?assertMatch(<<"event: message_start", _/binary>>, First),
    ?assertEqual(true, St#sse_st.role_sent).
