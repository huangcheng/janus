%%%-------------------------------------------------------------------
%%% @doc EUnit tests for Phase-2 responses-client stream translation
%%% (plan 2026-10-06, tasks 2.1/2.4 eunit half): the →responses SSE
%%% emitters in janus_protocol_translate (translate_sse/4 with an
%%% openai_responses client face over chat and anthropic upstreams)
%%% plus the dispatch knob helper
%%% janus_http_proxy:responses_stream_translate_enabled/0. Written
%%% BEFORE the implementation. The streaming fixtures are the real
%%% captured transcripts under test/fixtures/sse/ (dashscope chat
%%% wire, kimi anthropic wire); every hand-built event SPLICES those
%%% captured shapes (same keys, same nulls) — no invented wire forms.
%%% Fixtures are parsed with the production sse_events/2 parser, so all
%%% maps are JSON-decoded with binary keys, never hand-idiomatic atoms.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_translate_responses_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../src/janus_protocol_translate.hrl").

-define(FIXTURE_DIR, "test/fixtures/sse").

%%%-------------------------------------------------------------------
%%% Helpers
%%%-------------------------------------------------------------------

fixture(Name) ->
    Candidates = [
        filename:join(["apps/janus_http", ?FIXTURE_DIR, Name]),
        filename:join([?FIXTURE_DIR, Name])
    ],
    case lists:filter(fun(P) -> filelib:is_file(P) end, Candidates) of
        [P | _] ->
            {ok, Bin} = file:read_file(P),
            Bin;
        [] ->
            erlang:error({fixture_not_found, Candidates})
    end.

%% Fold a whole wire transcript through parse + translate + finalize.
run_wire(Client, Provider, Wire) ->
    {ok, Events, <<>>} = janus_protocol_translate:sse_events(<<>>, Wire),
    run_events(Client, Provider, Events).

run_events(_Client, _Provider, []) ->
    {error, no_events};
run_events(Client, Provider, Events) ->
    St0 = janus_protocol_translate:new_sse_st(),
    case fold_events(Client, Provider, Events, St0, []) of
        {error, Reason, StErr, Frames} ->
            {error, Reason, StErr, Frames};
        {ok, Frames, St1} ->
            {ok, FinFrames, St2} = janus_protocol_translate:finalize_sse(Client, normal, St1),
            {ok, Frames ++ FinFrames, St2}
    end.

fold_events(_Client, _Provider, [], St, Acc) ->
    {ok, Acc, St};
fold_events(Client, Provider, [Ev | Rest], St, Acc) ->
    case janus_protocol_translate:translate_sse(Client, Provider, Ev, St) of
        {ok, Frames, St1} -> fold_events(Client, Provider, Rest, St1, Acc ++ Frames);
        {error, Reason, St1} -> {error, Reason, St1, Acc}
    end.

%% Responses-face frames are all event-framed (no bare data: frames,
%% no chat [DONE] — the terminal EVENT is the terminator, C1).
parse_frame(<<":", _/binary>>) ->
    comment;
parse_frame(<<"event: ", Rest/binary>>) ->
    [Ev, Data0] = binary:split(Rest, <<"\ndata: ">>),
    {resp, Ev, decode_json(strip_nl(Data0))}.

strip_nl(Bin) ->
    binary:part(Bin, 0, byte_size(Bin) - 2).

decode_json(Bin) ->
    {ok, Map} = thoas:decode(Bin),
    Map.

parse_frames(Frames) ->
    [parse_frame(F) || F <- Frames].

resp_events(Parsed) ->
    [Ev || {resp, Ev, _} <- Parsed].

resp_frames(Parsed, Event) ->
    [M || {resp, E, M} <- Parsed, E =:= Event].

resp_added(Parsed) ->
    [M || {resp, <<"response.output_item.added">>, M} <- Parsed].

resp_done(Parsed) ->
    [M || {resp, <<"response.output_item.done">>, M} <- Parsed].

item_of(Map) ->
    maps:get(<<"item">>, Map).

%% Exactly one terminal event, C1/C2.
terminal_count(Parsed) ->
    length([
        Ev
     || {resp, Ev, _} <- Parsed,
        Ev =:= <<"response.completed">> orelse
            Ev =:= <<"response.incomplete">> orelse
            Ev =:= <<"response.failed">>
    ]).

resp_text_concat(Parsed, ItemId) ->
    iolist_to_binary([
        maps:get(<<"delta">>, M)
     || {resp, <<"response.output_text.delta">>, M} <- Parsed,
        maps:get(<<"item_id">>, M) =:= ItemId
    ]).

resp_args_concat(Parsed, ItemId) ->
    iolist_to_binary([
        maps:get(<<"delta">>, M)
     || {resp, <<"response.function_call_arguments.delta">>, M} <- Parsed,
        maps:get(<<"item_id">>, M) =:= ItemId
    ]).

%% Nth (1-based) occurrence position of an event in the parsed frames.
nth_position(Parsed, Event, Nth) ->
    Poss = [
        P
     || {P, {resp, E, _}} <- lists:zip(lists:seq(1, length(Parsed)), Parsed),
        E =:= Event
    ],
    lists:nth(Nth, Poss).

%%%-------------------------------------------------------------------
%%% Spliced wire-shape builders (dashscope qwen3.8 chat capture)
%%%-------------------------------------------------------------------

chat_role_event() ->
    #{
        type => <<"chunk">>,
        data => #{
            <<"model">> => <<"qwen3.8-max">>,
            <<"id">> => <<"chatcmpl-t">>,
            <<"created">> => 1791310285,
            <<"object">> => <<"chat.completion.chunk">>,
            <<"usage">> => null,
            <<"choices">> => [
                #{
                    <<"logprobs">> => null,
                    <<"index">> => 0,
                    <<"delta">> => #{<<"content">> => <<"">>, <<"role">> => <<"assistant">>, <<"reasoning_content">> => <<"">>},
                    <<"finish_reason">> => null
                }
            ]
        }
    }.

chat_delta_event(Content, Reasoning) ->
    #{
        type => <<"chunk">>,
        data => #{
            <<"model">> => <<"qwen3.8-max">>,
            <<"id">> => <<"chatcmpl-t">>,
            <<"created">> => 1791310285,
            <<"object">> => <<"chat.completion.chunk">>,
            <<"usage">> => null,
            <<"choices">> => [
                #{
                    <<"logprobs">> => null,
                    <<"index">> => 0,
                    <<"delta">> => #{<<"content">> => Content, <<"reasoning_content">> => Reasoning},
                    <<"finish_reason">> => null
                }
            ]
        }
    }.

chat_tool_event(Entries) ->
    #{
        type => <<"chunk">>,
        data => #{
            <<"model">> => <<"qwen3.8-max">>,
            <<"id">> => <<"chatcmpl-t">>,
            <<"created">> => 1791310285,
            <<"object">> => <<"chat.completion.chunk">>,
            <<"usage">> => null,
            <<"choices">> => [
                #{
                    <<"logprobs">> => null,
                    <<"index">> => 0,
                    <<"delta">> => #{
                        <<"tool_calls">> => Entries,
                        <<"content">> => <<"">>,
                        <<"reasoning_content">> => <<"">>
                    },
                    <<"finish_reason">> => null
                }
            ]
        }
    }.

chat_header_entry(Index, Id, Name) ->
    #{
        <<"index">> => Index,
        <<"id">> => Id,
        <<"type">> => <<"function">>,
        <<"function">> => #{<<"name">> => Name, <<"arguments">> => <<>>}
    }.

chat_frag_entry(Index, Frag) ->
    #{
        <<"type">> => <<"function">>,
        <<"index">> => Index,
        <<"function">> => #{<<"arguments">> => Frag}
    }.

chat_finish_event(FinishReason) ->
    #{
        type => <<"chunk">>,
        data => #{
            <<"model">> => <<"qwen3.8-max">>,
            <<"id">> => <<"chatcmpl-t">>,
            <<"created">> => 1791310285,
            <<"object">> => <<"chat.completion.chunk">>,
            <<"usage">> => null,
            <<"choices">> => [
                #{
                    <<"logprobs">> => null,
                    <<"index">> => 0,
                    <<"delta">> => #{},
                    <<"finish_reason">> => FinishReason
                }
            ]
        }
    }.

%% The fixture's usage-only chunk shape (empty choices, C1 ->chat tail).
chat_usage_event(Prompt, Completion) ->
    #{
        type => <<"chunk">>,
        data => #{
            <<"choices">> => [],
            <<"created">> => 1791310285,
            <<"id">> => <<"chatcmpl-t">>,
            <<"model">> => <<"qwen3.8-max">>,
            <<"object">> => <<"chat.completion.chunk">>,
            <<"usage">> => #{
                <<"prompt_tokens">> => Prompt,
                <<"completion_tokens">> => Completion,
                <<"total_tokens">> => Prompt + Completion
            }
        }
    }.

%%%-------------------------------------------------------------------
%%% Spliced wire-shape builders (kimi anthropic capture)
%%%-------------------------------------------------------------------

anthro_message_start_event(Input) ->
    #{
        type => <<"message_start">>,
        data => #{
            <<"type">> => <<"message_start">>,
            <<"message">> => #{
                <<"id">> => <<"msg_t">>,
                <<"type">> => <<"message">>,
                <<"role">> => <<"assistant">>,
                <<"content">> => [],
                <<"model">> => <<"kimi-for-coding">>,
                <<"stop_reason">> => null,
                <<"stop_sequence">> => null,
                <<"usage">> => #{<<"input_tokens">> => Input, <<"output_tokens">> => 0}
            }
        }
    }.

anthro_text_start_event() ->
    #{
        type => <<"content_block_start">>,
        data => #{
            <<"type">> => <<"content_block_start">>,
            <<"index">> => 0,
            <<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<>>}
        }
    }.

anthro_text_delta_event(Text) ->
    #{
        type => <<"content_block_delta">>,
        data => #{
            <<"type">> => <<"content_block_delta">>,
            <<"index">> => 0,
            <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => Text}
        }
    }.

anthro_block_stop_event(Index) ->
    #{
        type => <<"content_block_stop">>,
        data => #{<<"type">> => <<"content_block_stop">>, <<"index">> => Index}
    }.

anthro_tool_start_event(Index, Id, Name) ->
    #{
        type => <<"content_block_start">>,
        data => #{
            <<"type">> => <<"content_block_start">>,
            <<"index">> => Index,
            <<"content_block">> => #{
                <<"type">> => <<"tool_use">>,
                <<"id">> => Id,
                <<"name">> => Name,
                <<"input">> => #{}
            }
        }
    }.

anthro_json_delta_event(Index, Partial) ->
    #{
        type => <<"content_block_delta">>,
        data => #{
            <<"type">> => <<"content_block_delta">>,
            <<"index">> => Index,
            <<"delta">> => #{<<"type">> => <<"input_json_delta">>, <<"partial_json">> => Partial}
        }
    }.

anthro_message_delta_event(StopReason, Output) ->
    #{
        type => <<"message_delta">>,
        data => #{
            <<"type">> => <<"message_delta">>,
            <<"delta">> => #{<<"stop_reason">> => StopReason, <<"stop_sequence">> => null},
            <<"usage">> => #{<<"input_tokens">> => 10, <<"output_tokens">> => Output}
        }
    }.

anthro_message_stop_event() ->
    #{type => <<"message_stop">>, data => #{<<"type">> => <<"message_stop">>}}.

%%%-------------------------------------------------------------------
%%% chat wire -> responses face: captured dashscope transcript
%%%-------------------------------------------------------------------

chat_fixture_responses_grammar_test() ->
    {ok, Frames, _St} =
        run_wire(openai_responses, openai_chat, fixture(<<"dashscope-qwen3.8-tools-chat.sse">>)),
    Parsed = parse_frames(Frames),
    %% C1 grammar: created (lazy — first content chunk), message item,
    %% text deltas, item done, function_call item, arg deltas, item
    %% done, ONE terminal.
    ?assertEqual(
        [
            <<"response.created">>,
            <<"response.output_item.added">>,
            <<"response.output_text.delta">>,
            <<"response.output_item.done">>,
            <<"response.output_item.added">>,
            <<"response.function_call_arguments.delta">>,
            <<"response.output_item.done">>,
            <<"response.completed">>
        ],
        dedupe(resp_events(Parsed))
    ),
    ?assertEqual(1, terminal_count(Parsed)),
    %% created: synthesized jresp_ id, status in_progress, usage ZEROED
    %% (C1 — framing; totals land on the terminal event).
    [CreatedMap] = resp_frames(Parsed, <<"response.created">>),
    Created = maps:get(<<"response">>, CreatedMap),
    ?assertMatch(<<"jresp_", _/binary>>, maps:get(<<"id">>, Created)),
    ?assertEqual(<<"in_progress">>, maps:get(<<"status">>, Created)),
    ?assertEqual(
        #{<<"input_tokens">> => 0, <<"output_tokens">> => 0, <<"total_tokens">> => 0},
        maps:get(<<"usage">>, Created)
    ),
    ?assertEqual(<<"qwen3.8-max">>, maps:get(<<"model">>, Created)),
    %% Message item: added at output_index 0, text streams through.
    [MsgAdded, FcAdded] = resp_added(Parsed),
    ?assertEqual(0, maps:get(<<"output_index">>, MsgAdded)),
    MsgItem = item_of(MsgAdded),
    ?assertMatch(<<"jitem_", _/binary>>, maps:get(<<"id">>, MsgItem)),
    ?assertEqual(<<"message">>, maps:get(<<"type">>, MsgItem)),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, MsgItem)),
    MsgId = maps:get(<<"id">>, MsgItem),
    ?assertEqual(
        <<"I'll check the weather in Beijing for you.\n\n">>,
        resp_text_concat(Parsed, MsgId)
    ),
    ?assertEqual(4, length(resp_frames(Parsed, <<"response.output_text.delta">>))),
    %% Message done item carries the full text (decode at close).
    [MsgDone, FcDone] = resp_done(Parsed),
    ?assertEqual(0, maps:get(<<"output_index">>, MsgDone)),
    DoneMsgItem = item_of(MsgDone),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, DoneMsgItem)),
    ?assertEqual(
        [#{<<"type">> => <<"output_text">>, <<"text">> => <<"I'll check the weather in Beijing for you.\n\n">>, <<"annotations">> => []}],
        maps:get(<<"content">>, DoneMsgItem)
    ),
    %% Function_call item: output_index 1 (its own space, never the
    %% chat tool index), upstream call id passes through as call_id,
    %% item id is jitem_ (distinct space).
    ?assertEqual(1, maps:get(<<"output_index">>, FcAdded)),
    FcItem = item_of(FcAdded),
    ?assertEqual(<<"function_call">>, maps:get(<<"type">>, FcItem)),
    ?assertEqual(<<"call_50ef219470664f36a25ed1f7">>, maps:get(<<"call_id">>, FcItem)),
    ?assertEqual(<<"get_weather">>, maps:get(<<"name">>, FcItem)),
    ?assertEqual(<<>>, maps:get(<<"arguments">>, FcItem)),
    FcItemId = maps:get(<<"id">>, FcItem),
    ?assertMatch(<<"jitem_", _/binary>>, FcItemId),
    ?assertNotEqual(maps:get(<<"call_id">>, FcItem), FcItemId),
    %% Fragments stream through; ONE decode of the full concat at close.
    ?assertEqual(3, length(resp_frames(Parsed, <<"response.function_call_arguments.delta">>))),
    ?assertEqual(<<"{\"city\": \"Beijing\"}">>, resp_args_concat(Parsed, FcItemId)),
    ?assertEqual(<<"{\"city\": \"Beijing\"}">>, maps:get(<<"arguments">>, item_of(FcDone))),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, item_of(FcDone))),
    %% Terminal: usage totals on the response object (C3), output array
    %% reconstructed in item order.
    [CompletedMap] = resp_frames(Parsed, <<"response.completed">>),
    Completed = maps:get(<<"response">>, CompletedMap),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Completed)),
    ?assertEqual(
        #{<<"input_tokens">> => 325, <<"output_tokens">> => 56, <<"total_tokens">> => 381},
        maps:get(<<"usage">>, Completed)
    ),
    ?assertEqual(2, length(maps:get(<<"output">>, Completed))),
    ?assertEqual(<<"message">>, maps:get(<<"type">>, hd(maps:get(<<"output">>, Completed)))),
    ?assertEqual(
        <<"function_call">>,
        maps:get(<<"type">>, lists:last(maps:get(<<"output">>, Completed)))
    ),
    %% No chat [DONE] on the responses face; reasoning never reaches it.
    ?assertEqual([], [F || F <- Frames, binary:match(F, <<"[DONE]">>) =/= nomatch]),
    ?assertEqual([], [F || F <- Frames, binary:match(F, <<"reasoning_content">>) =/= nomatch]),
    ?assertEqual([], [F || F <- Frames, binary:match(F, <<"The user wants">>) =/= nomatch]).

%%%-------------------------------------------------------------------
%%% anthropic wire -> responses face: captured kimi transcript
%%%-------------------------------------------------------------------

anthro_fixture_responses_grammar_test() ->
    {ok, Frames, _St} =
        run_wire(openai_responses, anthropic_messages, fixture(<<"kimi-anthropic-tools.sse">>)),
    Parsed = parse_frames(Frames),
    %% Skeleton: created (lazy — thinking deltas never trigger it),
    %% one function_call item, fragment deltas, done, ONE terminal.
    %% No message item: the transcript's text is thinking-only.
    ?assertEqual(
        [
            <<"response.created">>,
            <<"response.output_item.added">>,
            <<"response.function_call_arguments.delta">>,
            <<"response.output_item.done">>,
            <<"response.completed">>
        ],
        dedupe(resp_events(Parsed))
    ),
    ?assertEqual(1, terminal_count(Parsed)),
    [CreatedMap] = resp_frames(Parsed, <<"response.created">>),
    Created = maps:get(<<"response">>, CreatedMap),
    ?assertMatch(<<"jresp_", _/binary>>, maps:get(<<"id">>, Created)),
    ?assertEqual(#{<<"input_tokens">> => 0, <<"output_tokens">> => 0, <<"total_tokens">> => 0}, maps:get(<<"usage">>, Created)),
    %% tool_use id passes through as call_id; block index 1 NEVER leaks
    %% into the responses output_index space (C5).
    [FcAdded] = resp_added(Parsed),
    ?assertEqual(0, maps:get(<<"output_index">>, FcAdded)),
    FcItem = item_of(FcAdded),
    ?assertEqual(<<"tool_L7y4rpzMo4Jn563MuZNGqCHJ">>, maps:get(<<"call_id">>, FcItem)),
    ?assertEqual(<<"get_weather">>, maps:get(<<"name">>, FcItem)),
    ?assertEqual(5, length(resp_frames(Parsed, <<"response.function_call_arguments.delta">>))),
    [FcDone] = resp_done(Parsed),
    ?assertEqual(
        #{<<"city">> => <<"Beijing">>},
        decode_json(maps:get(<<"arguments">>, item_of(FcDone)))
    ),
    %% Usage: message_start input + message_delta output MERGED (C3).
    [CompletedMap] = resp_frames(Parsed, <<"response.completed">>),
    Completed = maps:get(<<"response">>, CompletedMap),
    ?assertEqual(#{<<"input_tokens">> => 173, <<"output_tokens">> => 82, <<"total_tokens">> => 255}, maps:get(<<"usage">>, Completed)),
    %% Thinking/signature never reach the responses face.
    ?assertEqual([], [F || F <- Frames, binary:match(F, <<"signature">>) =/= nomatch]),
    ?assertEqual([], [F || F <- Frames, binary:match(F, <<"The user">>) =/= nomatch]),
    ?assertEqual([], [F || F <- Frames, binary:match(F, <<"[DONE]">>) =/= nomatch]).

%%%-------------------------------------------------------------------
%%% Lazy skeleton (C1): created waits for the first content event
%%%-------------------------------------------------------------------

chat_created_deferred_to_first_content_test() ->
    St0 = janus_protocol_translate:new_sse_st(),
    {ok, F1, St1} =
        janus_protocol_translate:translate_sse(openai_responses, openai_chat, chat_role_event(), St0),
    ?assertEqual([], F1),
    ?assertEqual(false, St1#sse_st.role_sent),
    ?assertEqual(<<"qwen3.8-max">>, St1#sse_st.model),
    %% A reasoning-only chunk is NOT content-bearing either.
    {ok, F2, St2} =
        janus_protocol_translate:translate_sse(
            openai_responses, openai_chat, chat_delta_event(<<"">>, <<"hmm">>), St1
        ),
    ?assertEqual([], F2),
    ?assertEqual(false, St2#sse_st.role_sent),
    {ok, F3, St3} =
        janus_protocol_translate:translate_sse(
            openai_responses, openai_chat, chat_delta_event(<<"Hi">>, <<"">>), St2
        ),
    ?assertEqual(
        [
            <<"response.created">>,
            <<"response.output_item.added">>,
            <<"response.output_text.delta">>
        ],
        resp_events(parse_frames(F3))
    ),
    ?assertEqual(true, St3#sse_st.role_sent).

anthro_created_deferred_to_first_text_test() ->
    St0 = janus_protocol_translate:new_sse_st(),
    {ok, F1, St1} =
        janus_protocol_translate:translate_sse(
            openai_responses, anthropic_messages, anthro_message_start_event(10), St0
        ),
    ?assertEqual([], F1),
    ?assertEqual(false, St1#sse_st.role_sent),
    ?assertEqual(10, St1#sse_st.in_tokens),
    {ok, F2, _} =
        janus_protocol_translate:translate_sse(
            openai_responses, anthropic_messages, anthro_text_delta_event(<<"Hi">>), St1
        ),
    ?assertEqual(
        [
            <<"response.created">>,
            <<"response.output_item.added">>,
            <<"response.output_text.delta">>
        ],
        resp_events(parse_frames(F2))
    ).

%%%-------------------------------------------------------------------
%%% Plain-text streams (spliced fixture shapes)
%%%-------------------------------------------------------------------

chat_plain_text_stream_test() ->
    Events = [
        chat_role_event(),
        chat_delta_event(<<"Hi">>, <<"">>),
        chat_delta_event(<<" there">>, <<"">>),
        chat_finish_event(<<"stop">>),
        chat_usage_event(7, 3),
        #{type => <<"done">>}
    ],
    {ok, Frames, _} = run_events(openai_responses, openai_chat, Events),
    Parsed = parse_frames(Frames),
    ?assertEqual(
        [
            <<"response.created">>,
            <<"response.output_item.added">>,
            <<"response.output_text.delta">>,
            <<"response.output_item.done">>,
            <<"response.completed">>
        ],
        dedupe(resp_events(Parsed))
    ),
    ?assertEqual(1, terminal_count(Parsed)),
    [CompletedMap] = resp_frames(Parsed, <<"response.completed">>),
    Completed = maps:get(<<"response">>, CompletedMap),
    ?assertEqual(#{<<"input_tokens">> => 7, <<"output_tokens">> => 3, <<"total_tokens">> => 10}, maps:get(<<"usage">>, Completed)),
    [OutputMsg] = maps:get(<<"output">>, Completed),
    ?assertEqual(<<"Hi there">>, hd_text(OutputMsg)).

%% No [DONE] marker at all: finalize emits the terminal exactly once.
chat_no_done_marker_finalize_test() ->
    Events = [
        chat_delta_event(<<"Hi">>, <<"">>),
        chat_finish_event(<<"stop">>),
        chat_usage_event(7, 3)
    ],
    {ok, Frames, _} = run_events(openai_responses, openai_chat, Events),
    Parsed = parse_frames(Frames),
    ?assertEqual(1, terminal_count(Parsed)),
    ?assertEqual(1, length(resp_frames(Parsed, <<"response.completed">>))),
    [CompletedMap] = resp_frames(Parsed, <<"response.completed">>),
    ?assertEqual(
        #{<<"input_tokens">> => 7, <<"output_tokens">> => 3, <<"total_tokens">> => 10},
        maps:get(<<"usage">>, maps:get(<<"response">>, CompletedMap))
    ).

anthro_plain_text_stream_test() ->
    Events = [
        anthro_message_start_event(10),
        anthro_text_start_event(),
        anthro_text_delta_event(<<"Hi">>),
        anthro_text_delta_event(<<" there">>),
        anthro_block_stop_event(0),
        anthro_message_delta_event(<<"end_turn">>, 4),
        anthro_message_stop_event()
    ],
    {ok, Frames, _} = run_events(openai_responses, anthropic_messages, Events),
    Parsed = parse_frames(Frames),
    ?assertEqual(
        [
            <<"response.created">>,
            <<"response.output_item.added">>,
            <<"response.output_text.delta">>,
            <<"response.output_item.done">>,
            <<"response.completed">>
        ],
        dedupe(resp_events(Parsed))
    ),
    ?assertEqual(1, terminal_count(Parsed)),
    [CompletedMap] = resp_frames(Parsed, <<"response.completed">>),
    Completed = maps:get(<<"response">>, CompletedMap),
    ?assertEqual(#{<<"input_tokens">> => 10, <<"output_tokens">> => 4, <<"total_tokens">> => 14}, maps:get(<<"usage">>, Completed)),
    [OutputMsg] = maps:get(<<"output">>, Completed),
    ?assertEqual(<<"Hi there">>, hd_text(OutputMsg)).

%%%-------------------------------------------------------------------
%%% Terminal selection (C2 map): length/max_tokens -> incomplete
%%%-------------------------------------------------------------------

chat_length_finish_incomplete_test() ->
    Events = [
        chat_delta_event(<<"Hi">>, <<"">>),
        chat_finish_event(<<"length">>),
        chat_usage_event(2, 9),
        #{type => <<"done">>}
    ],
    {ok, Frames, _} = run_events(openai_responses, openai_chat, Events),
    Parsed = parse_frames(Frames),
    ?assertEqual([], resp_frames(Parsed, <<"response.completed">>)),
    [IncompleteMap] = resp_frames(Parsed, <<"response.incomplete">>),
    Incomplete = maps:get(<<"response">>, IncompleteMap),
    ?assertEqual(<<"incomplete">>, maps:get(<<"status">>, Incomplete)),
    ?assertEqual(
        #{<<"reason">> => <<"max_output_tokens">>},
        maps:get(<<"incomplete_details">>, Incomplete)
    ),
    %% Usage still rides the terminal event (C3).
    ?assertEqual(#{<<"input_tokens">> => 2, <<"output_tokens">> => 9, <<"total_tokens">> => 11}, maps:get(<<"usage">>, Incomplete)),
    ?assertEqual(1, terminal_count(Parsed)).

anthro_max_tokens_incomplete_test() ->
    Events = [
        anthro_message_start_event(5),
        anthro_text_delta_event(<<"Hi">>),
        anthro_message_delta_event(<<"max_tokens">>, 9),
        anthro_message_stop_event()
    ],
    {ok, Frames, _} = run_events(openai_responses, anthropic_messages, Events),
    Parsed = parse_frames(Frames),
    ?assertEqual([], resp_frames(Parsed, <<"response.completed">>)),
    [IncompleteMap] = resp_frames(Parsed, <<"response.incomplete">>),
    Incomplete = maps:get(<<"response">>, IncompleteMap),
    ?assertEqual(
        #{<<"reason">> => <<"max_output_tokens">>},
        maps:get(<<"incomplete_details">>, Incomplete)
    ),
    ?assertEqual(#{<<"input_tokens">> => 5, <<"output_tokens">> => 9, <<"total_tokens">> => 14}, maps:get(<<"usage">>, Incomplete)).

%%%-------------------------------------------------------------------
%%% Zero-argument calls: complete with "{}" (C5)
%%%-------------------------------------------------------------------

chat_zero_args_test() ->
    Events = [
        chat_tool_event([chat_header_entry(0, <<"call_z">>, <<"ping">>)]),
        chat_finish_event(<<"tool_calls">>),
        #{type => <<"done">>}
    ],
    {ok, Frames, _} = run_events(openai_responses, openai_chat, Events),
    Parsed = parse_frames(Frames),
    ?assertEqual([], resp_frames(Parsed, <<"response.function_call_arguments.delta">>)),
    [FcDone] = resp_done(Parsed),
    ?assertEqual(<<"{}">>, maps:get(<<"arguments">>, item_of(FcDone))),
    ?assertEqual(1, terminal_count(Parsed)).

anthro_zero_args_test() ->
    Events = [
        anthro_tool_start_event(0, <<"tool_z">>, <<"ping">>),
        anthro_block_stop_event(0),
        anthro_message_delta_event(<<"tool_use">>, 3),
        anthro_message_stop_event()
    ],
    {ok, Frames, _} = run_events(openai_responses, anthropic_messages, Events),
    Parsed = parse_frames(Frames),
    ?assertEqual([], resp_frames(Parsed, <<"response.function_call_arguments.delta">>)),
    [FcDone] = resp_done(Parsed),
    ?assertEqual(<<"{}">>, maps:get(<<"arguments">>, item_of(FcDone))).

%%%-------------------------------------------------------------------
%%% C5 interleaving: chat text between tool fragments defers
%%%-------------------------------------------------------------------

chat_interleaved_text_deferred_test() ->
    Events = [
        chat_delta_event(<<"A">>, <<"">>),
        chat_tool_event([chat_header_entry(0, <<"call_i">>, <<"get_weather">>)]),
        chat_tool_event([chat_frag_entry(0, <<"{\"x\":">>)]),
        chat_delta_event(<<"B">>, <<"">>),
        chat_tool_event([chat_frag_entry(0, <<"1}">>)]),
        chat_finish_event(<<"tool_calls">>),
        #{type => <<"done">>}
    ],
    {ok, Frames, _} = run_events(openai_responses, openai_chat, Events),
    Parsed = parse_frames(Frames),
    %% Item order preserves wire text order: message(A) 0, function_call
    %% 1, then the DEFERRED message(B) 2 AFTER the tool item closes.
    Added = [item_of(M) || M <- resp_added(Parsed)],
    ?assertEqual([<<"message">>, <<"function_call">>, <<"message">>], [maps:get(<<"type">>, I) || I <- Added]),
    ?assertEqual([0, 1, 2], [maps:get(<<"output_index">>, M) || M <- resp_added(Parsed)]),
    %% B's delta (the 2nd text delta) is AFTER output_item.done of the
    %% tool item — never between its argument fragments.
    ?assert(
        nth_position(Parsed, <<"response.output_item.done">>, 1) <
            nth_position(Parsed, <<"response.output_text.delta">>, 2)
    ),
    [MsgB | _] = lists:reverse(Added),
    ?assertEqual(<<"B">>, resp_text_concat(Parsed, maps:get(<<"id">>, MsgB))),
    ?assertEqual(1, terminal_count(Parsed)).

%%%-------------------------------------------------------------------
%%% Completeness: decode-at-close errors (C2 path)
%%%-------------------------------------------------------------------

chat_truncated_args_error_test() ->
    Events = [
        chat_tool_event([chat_header_entry(0, <<"call_t">>, <<"get_weather">>)]),
        chat_tool_event([chat_frag_entry(0, <<"{\"city\":">>)]),
        chat_finish_event(<<"tool_calls">>)
    ],
    ?assertMatch(
        {error, translate_unsupported, #sse_st{}, _},
        run_events(openai_responses, openai_chat, Events)
    ).

anthro_truncated_args_error_test() ->
    Events = [
        anthro_tool_start_event(0, <<"tool_t">>, <<"get_weather">>),
        anthro_json_delta_event(0, <<"{\"city\":">>),
        anthro_block_stop_event(0)
    ],
    ?assertMatch(
        {error, translate_unsupported, #sse_st{}, _},
        run_events(openai_responses, anthropic_messages, Events)
    ).

%% message_delta while a tool block is still open: never looks finished.
anthro_unclosed_tool_at_message_delta_error_test() ->
    Events = [
        anthro_tool_start_event(0, <<"tool_u">>, <<"get_weather">>),
        anthro_json_delta_event(0, <<"{\"a\":1}">>),
        anthro_message_delta_event(<<"tool_use">>, 2)
    ],
    ?assertMatch(
        {error, translate_unsupported, #sse_st{}, _},
        run_events(openai_responses, anthropic_messages, Events)
    ).

%%%-------------------------------------------------------------------
%%% Synthesized ids (C4/C5): jresp_/jitem_/jfc_, never colliding
%%%-------------------------------------------------------------------

chat_synthesized_ids_test() ->
    %% No id on the wire (null — dashscope late-fragment shape): the
    %% call_id is janus-namespaced; two such calls never share one.
    Events = [
        chat_tool_event([chat_header_entry(0, null, <<"p">>)]),
        chat_tool_event([chat_header_entry(1, null, <<"p">>)]),
        chat_finish_event(<<"tool_calls">>),
        #{type => <<"done">>}
    ],
    {ok, Frames, _} = run_events(openai_responses, openai_chat, Events),
    Parsed = parse_frames(Frames),
    Added = [item_of(M) || M <- resp_added(Parsed)],
    [CallA, CallB] = [maps:get(<<"call_id">>, I) || I <- Added],
    ?assertMatch(<<"jfc_", _/binary>>, CallA),
    ?assertMatch(<<"jfc_", _/binary>>, CallB),
    ?assertNotEqual(CallA, CallB),
    [ItemA, ItemB] = [maps:get(<<"id">>, I) || I <- Added],
    ?assertMatch(<<"jitem_", _/binary>>, ItemA),
    ?assertMatch(<<"jitem_", _/binary>>, ItemB),
    ?assertNotEqual(ItemA, ItemB),
    [CreatedMap] = resp_frames(Parsed, <<"response.created">>),
    ?assertMatch(<<"jresp_", _/binary>>, maps:get(<<"id">>, maps:get(<<"response">>, CreatedMap))).

%% Replay the fixture twice (fresh states, the C4 retry shape): the
%% synthesized ids never repeat an upstream id and never repeat across
%% attempts.
chat_fixture_no_id_collision_test() ->
    {ok, FramesA, _} =
        run_wire(openai_responses, openai_chat, fixture(<<"dashscope-qwen3.8-tools-chat.sse">>)),
    {ok, FramesB, _} =
        run_wire(openai_responses, openai_chat, fixture(<<"dashscope-qwen3.8-tools-chat.sse">>)),
    UpstreamIds = [
        <<"chatcmpl-a259ea33-dafe-91e1-99ac-0850821ed47c">>,
        <<"call_50ef219470664f36a25ed1f7">>
    ],
    Synth = synth_ids(parse_frames(FramesA)) ++ synth_ids(parse_frames(FramesB)),
    %% Every synthesized id is j-prefixed and disjoint from upstream ids.
    lists:foreach(
        fun(Id) ->
            ?assertMatch(<<"j", _/binary>>, Id),
            ?assertNot(lists:member(Id, UpstreamIds), {collision, Id})
        end,
        Synth
    ),
    %% And unique across both attempts (per-attempt non-reuse, C4).
    ?assertEqual(length(Synth), length(lists:usort(Synth))).

synth_ids(Parsed) ->
    [
        Id
     || {resp, E, M} <- Parsed,
        E =:= <<"response.created">>,
        Id <- [maps:get(<<"id">>, maps:get(<<"response">>, M))]
    ] ++
        [
            Id
         || {resp, <<"response.output_item.added">>, M} <- Parsed,
            Id <- [maps:get(<<"id">>, item_of(M))]
        ].

%%%-------------------------------------------------------------------
%%% finalize_sse/3 — responses face
%%%-------------------------------------------------------------------

responses_error_after_created_test() ->
    %% Mid-stream failure: response.failed REPLACES the success
    %% terminal — alone, exactly one terminal, no completed (C2).
    {ok, _, St1} =
        janus_protocol_translate:translate_sse(
            openai_responses, openai_chat, chat_delta_event(<<"Hi">>, <<"">>), new_st()
        ),
    {ok, Frames, St2} =
        janus_protocol_translate:finalize_sse(
            openai_responses, {error, upstream, <<"provider died">>}, St1
        ),
    Parsed = parse_frames(Frames),
    ?assertEqual([<<"response.failed">>], resp_events(Parsed)),
    ?assertEqual(1, terminal_count(Parsed)),
    [FailedMap] = resp_frames(Parsed, <<"response.failed">>),
    Failed = maps:get(<<"response">>, FailedMap),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Failed)),
    Err = maps:get(<<"error">>, Failed),
    ?assertEqual(<<"api_error">>, maps:get(<<"code">>, Err)),
    ?assertEqual(<<"provider died">>, maps:get(<<"message">>, Err)),
    %% Same response id as the already-flushed created event.
    ?assertEqual(St1#sse_st.resp_id, maps:get(<<"id">>, Failed)),
    ?assertEqual(true, St2#sse_st.terminal_sent).

responses_error_before_created_test() ->
    %% Zero-data-frame rule (C2): the opening skeleton flushes first.
    {ok, Frames, _} =
        janus_protocol_translate:finalize_sse(
            openai_responses, {error, upstream, <<"boom">>}, new_st()
        ),
    Parsed = parse_frames(Frames),
    ?assertEqual([<<"response.created">>, <<"response.failed">>], resp_events(Parsed)).

responses_error_invalid_request_test() ->
    {ok, Frames, _} =
        janus_protocol_translate:finalize_sse(
            openai_responses, {error, invalid_request, <<"n must be 1">>}, new_st()
        ),
    [FailedMap | _] = resp_frames(parse_frames(Frames), <<"response.failed">>),
    ?assertEqual(
        <<"invalid_request_error">>,
        maps:get(<<"code">>, maps:get(<<"error">>, maps:get(<<"response">>, FailedMap)))
    ).

responses_error_message_truncated_test() ->
    Long = binary:copy(<<"z">>, 500),
    {ok, Frames, _} =
        janus_protocol_translate:finalize_sse(openai_responses, {error, upstream, Long}, new_st()),
    [Failed | _] = Frames,
    ?assert(byte_size(Failed) =< 500).

responses_normal_empty_stream_test() ->
    %% Empty 200 body: created + completed with EMPTY output; usage
    %% stays null (C3 — never invent counts).
    {ok, Frames, St} =
        janus_protocol_translate:finalize_sse(openai_responses, normal, new_st()),
    Parsed = parse_frames(Frames),
    ?assertEqual([<<"response.created">>, <<"response.completed">>], resp_events(Parsed)),
    [CompletedMap] = resp_frames(Parsed, <<"response.completed">>),
    Completed = maps:get(<<"response">>, CompletedMap),
    ?assertEqual([], maps:get(<<"output">>, Completed)),
    ?assertEqual(
        #{<<"input_tokens">> => null, <<"output_tokens">> => null, <<"total_tokens">> => null},
        maps:get(<<"usage">>, Completed)
    ),
    ?assertEqual(true, St#sse_st.terminal_sent).

responses_finalize_idempotent_test() ->
    {ok, _, St1} = janus_protocol_translate:finalize_sse(openai_responses, normal, new_st()),
    {ok, [], St2} = janus_protocol_translate:finalize_sse(openai_responses, normal, St1),
    ?assertEqual(true, St2#sse_st.terminal_sent).

responses_finalize_open_tool_complete_test() ->
    %% EOF inside a tool call with COMPLETE args: item closes normally.
    Events = [
        chat_tool_event([chat_header_entry(0, <<"call_c">>, <<"p">>)]),
        chat_tool_event([chat_frag_entry(0, <<"{\"a\":1}">>)])
    ],
    St0 = new_st(),
    {ok, _, St1} = fold_only(openai_responses, openai_chat, Events, St0, []),
    {ok, Frames, _} = janus_protocol_translate:finalize_sse(openai_responses, normal, St1),
    Parsed = parse_frames(Frames),
    ?assertEqual(
        [<<"response.output_item.done">>, <<"response.completed">>], resp_events(Parsed)
    ),
    [FcDone] = resp_done(Parsed),
    ?assertEqual(<<"{\"a\":1}">>, maps:get(<<"arguments">>, item_of(FcDone))).

responses_finalize_open_tool_truncated_test() ->
    %% EOF with truncated args: C2 error path — output_item.done must
    %% NEVER follow a truncated call (C5); created already flushed at
    %% the tool open (content-bearing), so response.failed comes alone.
    Events = [
        chat_tool_event([chat_header_entry(0, <<"call_t">>, <<"p">>)]),
        chat_tool_event([chat_frag_entry(0, <<"{">>)])
    ],
    St0 = new_st(),
    {ok, _, St1} = fold_only(openai_responses, openai_chat, Events, St0, []),
    {ok, Frames, _} = janus_protocol_translate:finalize_sse(openai_responses, normal, St1),
    ?assertEqual(
        [<<"response.failed">>],
        resp_events(parse_frames(Frames))
    ).

%%%-------------------------------------------------------------------
%%% Content budget (C5): 4MiB total accumulated content
%%%-------------------------------------------------------------------

content_cap_test() ->
    %% Direct text over the budget takes the C2 error path.
    Big = binary:copy(<<"a">>, 4 * 1024 * 1024 + 1),
    ?assertMatch(
        {error, translate_unsupported, #sse_st{}, _},
        run_events(openai_responses, openai_chat, [chat_delta_event(Big, <<"">>)])
    ),
    %% Deferred bytes count at DEFER time: deferrals that JOINTLY
    %% exceed the budget trip it even though none flushed yet (no
    %% under-counting while a tool call is open).
    Half = binary:copy(<<"a">>, 2 * 1024 * 1024),
    ?assertMatch(
        {error, translate_unsupported, #sse_st{}, _},
        run_events(openai_responses, openai_chat, [
            chat_tool_event([chat_header_entry(0, <<"call_d">>, <<"p">>)]),
            chat_delta_event(Half, <<"">>),
            chat_delta_event(Half, <<"">>),
            chat_delta_event(Half, <<"">>)
        ])
    ).

%%%-------------------------------------------------------------------
%%% Request-side stream leg (task 2): caller overrides stream flag
%%%-------------------------------------------------------------------

responses_request_stream_leg_test() ->
    In = #{<<"model">> => <<"m">>, <<"input">> => <<"hi">>, <<"stream">> => true},
    {ok, Out} = janus_protocol_translate:translate_request(openai_responses, openai_chat, In),
    %% responses_to_chat hardcodes stream=false; the proxy streaming leg
    %% overrides to true and drops stream_options (call_translate).
    ?assertEqual(false, maps:get(<<"stream">>, Out)),
    ?assert(is_list(maps:get(<<"messages">>, Out))).

%%%-------------------------------------------------------------------
%%% Dispatch knob (task 3): default OFF, independent of tools knob
%%%-------------------------------------------------------------------

responses_knob_default_off_test() ->
    persistent_term:erase({janus, translate_cfg}),
    ?assertEqual(false, janus_http_proxy:responses_stream_translate_enabled()).

responses_knob_on_test() ->
    try
        persistent_term:put({janus, translate_cfg}, #{<<"responses">> => true}),
        ?assertEqual(true, janus_http_proxy:responses_stream_translate_enabled())
    after
        persistent_term:erase({janus, translate_cfg})
    end.

responses_knob_independent_of_tools_test() ->
    try
        %% 2x2 matrix (plan 2.3): tools on alone does NOT flip responses.
        persistent_term:put({janus, translate_cfg}, #{<<"tools">> => true}),
        ?assertEqual(false, janus_http_proxy:responses_stream_translate_enabled()),
        %% responses on alone flips responses, tools key irrelevant.
        persistent_term:put({janus, translate_cfg}, #{<<"responses">> => true}),
        ?assertEqual(true, janus_http_proxy:responses_stream_translate_enabled()),
        persistent_term:put(
            {janus, translate_cfg}, #{<<"tools">> => true, <<"responses">> => true}
        ),
        ?assertEqual(true, janus_http_proxy:responses_stream_translate_enabled())
    after
        persistent_term:erase({janus, translate_cfg})
    end.

%%%-------------------------------------------------------------------
%%% Gate eligibility predicate: tools ride, vision and n>1 stay blocked
%%%-------------------------------------------------------------------

responses_stream_gatable_test() ->
    ?assertEqual(
        true,
        janus_protocol_translate:responses_stream_gatable(#{<<"input">> => <<"hi">>})
    ),
    ?assertEqual(
        true,
        janus_protocol_translate:responses_stream_gatable(#{
            <<"input">> => <<"hi">>, <<"tools">> => [#{<<"type">> => <<"function">>}]
        })
    ),
    %% n>1 stays blocked (task 5: n_blocked unchanged).
    ?assertEqual(
        false,
        janus_protocol_translate:responses_stream_gatable(#{<<"input">> => <<"hi">>, <<"n">> => 2})
    ),
    %% Vision content stays blocked (request translate rejects it too).
    ?assertEqual(
        false,
        janus_protocol_translate:responses_stream_gatable(#{
            <<"input">> => [#{<<"type">> => <<"input_image">>, <<"image_url">> => <<"data:image/png;base64,eA==">>}]
        })
    ),
    %% The blocked predicate itself is unchanged for responses clients
    %% (bias/auto/repick consumers keep the conservative view).
    ?assertEqual(
        true,
        janus_protocol_translate:stream_translate_blocked(
            openai_responses, #{<<"input">> => <<"hi">>}
        )
    ).

%%%-------------------------------------------------------------------
%%% Internal helpers
%%%-------------------------------------------------------------------

new_st() ->
    janus_protocol_translate:new_sse_st().

fold_only(_Client, _Provider, [], St, Acc) ->
    {ok, Acc, St};
fold_only(Client, Provider, [Ev | Rest], St, Acc) ->
    {ok, Frames, St1} = janus_protocol_translate:translate_sse(Client, Provider, Ev, St),
    fold_only(Client, Provider, Rest, St1, Acc ++ Frames).

%% Collapse runs of the same element (delta sequences -> one).
dedupe([]) ->
    [];
dedupe([X | Rest]) ->
    [X | dedupe_skip(X, Rest)].

dedupe_skip(X, [X | Rest]) ->
    dedupe_skip(X, Rest);
dedupe_skip(_, Rest) ->
    dedupe(Rest).

hd_text(#{<<"content">> := [#{<<"text">> := T} | _]}) ->
    T.
