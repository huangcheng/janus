%%%-------------------------------------------------------------------
%%% @doc EUnit tests for Phase-1 tool-call + vision translation in
%%% janus_protocol_translate. Written BEFORE the implementation. The
%%% streaming fixtures are the real captured transcripts under
%%% test/fixtures/sse/ (dashscope chat wire, kimi anthropic wire);
%%% every hand-built event below SPLICES those captured shapes (same
%%% keys, same nulls) — no invented wire forms. Fixtures are parsed
%%% with the production sse_events/2 parser, so all maps are
%%% JSON-decoded with binary keys, never hand-idiomatic atoms.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_translate_tools_tests).

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

%% One written frame -> {anthro, Event, Map} | {chat, Map} | done | comment.
parse_frame(<<":", _/binary>>) ->
    comment;
parse_frame(<<"event: ", Rest/binary>>) ->
    [Ev, Data0] = binary:split(Rest, <<"\ndata: ">>),
    {anthro, Ev, decode_json(strip_nl(Data0))};
parse_frame(<<"data: [DONE]\n\n">>) ->
    done;
parse_frame(<<"data: ", Rest/binary>>) ->
    {chat, decode_json(strip_nl(Rest))}.

strip_nl(Bin) ->
    binary:part(Bin, 0, byte_size(Bin) - 2).

decode_json(Bin) ->
    {ok, Map} = thoas:decode(Bin),
    Map.

decode_map(Bin) ->
    {ok, Map} = thoas:decode(Bin),
    Map.

parse_frames(Frames) ->
    [parse_frame(F) || F <- Frames].

chat_chunks(Parsed) ->
    [M || {chat, M} <- Parsed].

indexed(Parsed) ->
    lists:zip(lists:seq(1, length(Parsed)), Parsed).

anthro_events(Parsed) ->
    [Ev || {anthro, Ev, _} <- Parsed].

anthro_frames(Parsed) ->
    [{Ev, M} || {anthro, Ev, M} <- Parsed].

anthro_starts(Parsed) ->
    [M || {anthro, <<"content_block_start">>, M} <- Parsed].

anthro_block_starts(Parsed) ->
    [
        {maps:get(<<"index">>, M), maps:get(<<"type">>, maps:get(<<"content_block">>, M))}
     || {anthro, <<"content_block_start">>, M} <- Parsed
    ].

anthro_block_stops(Parsed) ->
    [maps:get(<<"index">>, M) || {anthro, <<"content_block_stop">>, M} <- Parsed].

anthro_partial_json(Parsed, BlockIndex) ->
    iolist_to_binary([
        maps:get(<<"partial_json">>, maps:get(<<"delta">>, M))
     || {anthro, <<"content_block_delta">>, M} <- Parsed,
        maps:get(<<"index">>, M) =:= BlockIndex,
        maps:get(<<"type">>, maps:get(<<"delta">>, M)) =:= <<"input_json_delta">>
    ]).

position_of_stop(Parsed, Index) ->
    hd([
        P
     || {P, {anthro, <<"content_block_stop">>, M}} <- indexed(Parsed),
        maps:get(<<"index">>, M) =:= Index
    ]).

position_of_start(Parsed, Index) ->
    hd([
        P
     || {P, {anthro, <<"content_block_start">>, M}} <- indexed(Parsed),
        maps:get(<<"index">>, M) =:= Index
    ]).

positions_of_deltas(Parsed, Index) ->
    [
        P
     || {P, {anthro, <<"content_block_delta">>, M}} <- indexed(Parsed),
        maps:get(<<"index">>, M) =:= Index
    ].

%% Collapse runs of the same element (delta sequences -> one).
collapse([]) ->
    [];
collapse([X | Rest]) ->
    [X | collapse_skip(X, Rest)].

collapse_skip(X, [X | Rest]) ->
    collapse_skip(X, Rest);
collapse_skip(_, Rest) ->
    collapse(Rest).

%% All tool_calls entries across chat chunks, in wire order.
tool_call_entries(Chunks) ->
    lists:append([entries_of(C) || C <- Chunks]).

entries_of(Chunk) ->
    case maps:get(<<"choices">>, Chunk, []) of
        [#{<<"delta">> := #{<<"tool_calls">> := Calls}}] when is_list(Calls) -> Calls;
        _ -> []
    end.

tool_args_concat(Entries, Index) ->
    iolist_to_binary([
        maps:get(<<"arguments">>, maps:get(<<"function">>, E))
     || E <- Entries,
        maps:get(<<"index">>, E) =:= Index
    ]).

chunk_kind(#{<<"choices">> := []}) ->
    usage;
chunk_kind(#{<<"choices">> := [#{<<"finish_reason">> := FR}]}) when FR =/= null, FR =/= undefined ->
    finish;
chunk_kind(#{<<"choices">> := [#{<<"delta">> := #{<<"role">> := _}}]}) ->
    role;
chunk_kind(#{<<"choices">> := [#{<<"delta">> := #{<<"reasoning_content">> := _}}]}) ->
    reasoning;
chunk_kind(#{<<"choices">> := [#{<<"delta">> := #{<<"tool_calls">> := _}}]}) ->
    tool_calls;
chunk_kind(#{<<"choices">> := [#{<<"delta">> := #{<<"content">> := _}}]}) ->
    content.

%%%-------------------------------------------------------------------
%%% Spliced wire-shape builders (dashscope qwen3.8 chat capture)
%%%-------------------------------------------------------------------

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

%%%-------------------------------------------------------------------
%%% Spliced wire-shape builders (kimi anthropic capture)
%%%-------------------------------------------------------------------

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

anthro_block_stop_event(Index) ->
    #{
        type => <<"content_block_stop">>,
        data => #{<<"type">> => <<"content_block_stop">>, <<"index">> => Index}
    }.

anthro_message_delta_event(StopReason) ->
    #{
        type => <<"message_delta">>,
        data => #{
            <<"type">> => <<"message_delta">>,
            <<"delta">> => #{<<"stop_reason">> => StopReason, <<"stop_sequence">> => null},
            <<"usage">> => #{<<"input_tokens">> => 10, <<"output_tokens">> => 4}
        }
    }.

%%%-------------------------------------------------------------------
%%% chat wire -> anthropic face: captured dashscope transcript
%%%-------------------------------------------------------------------

chat_fixture_full_skeleton_test() ->
    {ok, Frames, _St} = run_wire(anthropic_messages, openai_chat, fixture(<<"dashscope-qwen3.8-tools-chat.sse">>)),
    Parsed = parse_frames(Frames),
    %% C1 skeleton: start, per-block start/delta/stop, delta, stop.
    ?assertEqual(
        [
            <<"message_start">>,
            <<"content_block_start">>,
            <<"content_block_delta">>,
            <<"content_block_stop">>,
            <<"content_block_start">>,
            <<"content_block_delta">>,
            <<"content_block_stop">>,
            <<"content_block_start">>,
            <<"content_block_delta">>,
            <<"content_block_stop">>,
            <<"message_delta">>,
            <<"message_stop">>
        ],
        collapse(anthro_events(Parsed))
    ),
    %% message_start: id/model from the provider, usage ZEROED (C1 —
    %% totals land in message_delta).
    [{<<"message_start">>, StartMap} | _] = anthro_frames(Parsed),
    StartMsg = maps:get(<<"message">>, StartMap),
    ?assertEqual(<<"chatcmpl-a259ea33-dafe-91e1-99ac-0850821ed47c">>, maps:get(<<"id">>, StartMsg)),
    ?assertEqual(<<"qwen3.8-max">>, maps:get(<<"model">>, StartMsg)),
    ?assertEqual(#{<<"input_tokens">> => 0, <<"output_tokens">> => 0}, maps:get(<<"usage">>, StartMsg)),
    %% C5 block index counts ALL blocks: thinking 0, text 1, tool 2 —
    %% the chat tool index 0 never leaks in as a block index.
    ?assertEqual([{0, <<"thinking">>}, {1, <<"text">>}, {2, <<"tool_use">>}], anthro_block_starts(Parsed)),
    ?assertEqual([0, 1, 2], anthro_block_stops(Parsed)),
    %% The tool call: server id + name preserved, input starts empty.
    [ToolStartMap] = [
        M
     || {anthro, <<"content_block_start">>, M} <- Parsed,
        maps:get(<<"type">>, maps:get(<<"content_block">>, M)) =:= <<"tool_use">>
    ],
    ToolBlock = maps:get(<<"content_block">>, ToolStartMap),
    ?assertEqual(<<"call_50ef219470664f36a25ed1f7">>, maps:get(<<"id">>, ToolBlock)),
    ?assertEqual(<<"get_weather">>, maps:get(<<"name">>, ToolBlock)),
    ?assertEqual(#{}, maps:get(<<"input">>, ToolBlock)),
    %% Fragments stream through incrementally; ONE decode of the full
    %% concat at close time (C5) — each fragment alone is invalid JSON.
    {ok, Decoded} = thoas:decode(anthro_partial_json(Parsed, 2)),
    ?assertEqual(#{<<"city">> => <<"Beijing">>}, Decoded),
    %% content_block_stop(tool) only after the tool's last fragment.
    ?assert(lists:max(positions_of_deltas(Parsed, 2)) < position_of_stop(Parsed, 2)),
    %% message_delta carries the mapped stop + the real totals.
    [{<<"message_delta">>, DeltaMap}] = [
        {E, M} || {E, M} <- anthro_frames(Parsed), E =:= <<"message_delta">>
    ],
    ?assertEqual(<<"tool_use">>, maps:get(<<"stop_reason">>, maps:get(<<"delta">>, DeltaMap))),
    ?assertEqual(#{<<"input_tokens">> => 325, <<"output_tokens">> => 56}, maps:get(<<"usage">>, DeltaMap)),
    ?assertEqual(<<"message_stop">>, lists:last(anthro_events(Parsed))).

%%%-------------------------------------------------------------------
%%% anthropic wire -> chat face: captured kimi transcript
%%%-------------------------------------------------------------------

anthro_fixture_full_skeleton_test() ->
    {ok, Frames, _St} = run_wire(openai_chat, anthropic_messages, fixture(<<"kimi-anthropic-tools.sse">>)),
    Parsed = parse_frames(Frames),
    Chunks = chat_chunks(Parsed),
    %% Wire order: role, reasoning deltas, tool_calls chunks, finish,
    %% usage-only (C1 ->chat skeleton); [DONE] is the terminator.
    ?assertEqual([role, reasoning, tool_calls, finish, usage], collapse([chunk_kind(C) || C <- Chunks])),
    [RoleChunk | _] = Chunks,
    ?assertEqual(<<"msg_Kmr4m0IVPU7VYTa7N9Bsh9MT">>, maps:get(<<"id">>, RoleChunk)),
    ?assertEqual(<<"kimi-for-coding">>, maps:get(<<"model">>, RoleChunk)),
    %% C5: the chat tool_calls index is the tool ordinal 0, NEVER the
    %% anthropic block index 1.
    Entries = tool_call_entries(Chunks),
    [First | Rest] = Entries,
    ?assertEqual(0, maps:get(<<"index">>, First)),
    ?assertEqual(<<"tool_L7y4rpzMo4Jn563MuZNGqCHJ">>, maps:get(<<"id">>, First)),
    ?assertEqual(<<"function">>, maps:get(<<"type">>, First)),
    ?assertEqual(<<"get_weather">>, maps:get(<<"name">>, maps:get(<<"function">>, First))),
    ?assertEqual([<<"Be">>, <<"ijing">>, <<"\"">>, <<"}">>], [
        maps:get(<<"arguments">>, maps:get(<<"function">>, E))
     || E <- Rest
    ]),
    lists:foreach(fun(E) -> ?assertEqual(0, maps:get(<<"index">>, E)) end, Rest),
    ?assertEqual(#{<<"city">> => <<"Beijing">>}, decode_map(tool_args_concat(Entries, 0))),
    %% finish_reason=tool_calls chunk AFTER the last fragment, empty delta.
    [FinishChunk] = [C || C <- Chunks, chunk_kind(C) =:= finish],
    [FinishChoice] = maps:get(<<"choices">>, FinishChunk),
    ?assertEqual(<<"tool_calls">>, maps:get(<<"finish_reason">>, FinishChoice)),
    ?assertEqual(#{}, maps:get(<<"delta">>, FinishChoice)),
    %% usage-only chunk: EMPTY choices, merged message_start input +
    %% message_delta output (C3), then [DONE] exactly once.
    [UsageChunk] = [C || C <- Chunks, chunk_kind(C) =:= usage],
    ?assertEqual([], maps:get(<<"choices">>, UsageChunk)),
    ?assertEqual(#{<<"prompt_tokens">> => 173, <<"completion_tokens">> => 82}, maps:get(<<"usage">>, UsageChunk)),
    ?assertEqual(done, lists:last(Parsed)),
    ?assertEqual(1, length([P || P <- Parsed, P =:= done])),
    %% The signature delta never reaches the chat face.
    ?assertEqual([], [F || F <- Frames, binary:match(F, <<"signature">>) =/= nomatch]).

%%%-------------------------------------------------------------------
%%% Multi-tool parallel calls
%%%-------------------------------------------------------------------

chat_parallel_two_calls_test() ->
    Events = [
        chat_tool_event([chat_header_entry(0, <<"call_a">>, <<"get_weather">>)]),
        chat_tool_event([chat_frag_entry(0, <<"{\"a\":1}">>)]),
        chat_tool_event([chat_header_entry(1, <<"call_b">>, <<"get_time">>)]),
        chat_tool_event([chat_frag_entry(1, <<"{\"b\":2}">>)]),
        chat_finish_event(<<"tool_calls">>)
    ],
    {ok, Frames, _St} = run_events(anthropic_messages, openai_chat, Events),
    Parsed = parse_frames(Frames),
    ?assertEqual([{0, <<"tool_use">>}, {1, <<"tool_use">>}], anthro_block_starts(Parsed)),
    ?assertEqual([0, 1], anthro_block_stops(Parsed)),
    %% call_a closes BEFORE call_b opens (sequential anthropic blocks).
    ?assert(position_of_stop(Parsed, 0) < position_of_start(Parsed, 1)),
    %% ids and args preserved per call.
    [BlkA, BlkB] = [maps:get(<<"content_block">>, M) || M <- anthro_starts(Parsed)],
    ?assertEqual(<<"call_a">>, maps:get(<<"id">>, BlkA)),
    ?assertEqual(<<"call_b">>, maps:get(<<"id">>, BlkB)),
    ?assertEqual(#{<<"a">> => 1}, decode_map(anthro_partial_json(Parsed, 0))),
    ?assertEqual(#{<<"b">> => 2}, decode_map(anthro_partial_json(Parsed, 1))),
    [{<<"message_delta">>, DeltaMap}] = [
        {E, M} || {E, M} <- anthro_frames(Parsed), E =:= <<"message_delta">>
    ],
    ?assertEqual(<<"tool_use">>, maps:get(<<"stop_reason">>, maps:get(<<"delta">>, DeltaMap))).

%% Two headers in ONE tool_calls array (parallel OpenAI shape).
chat_same_chunk_two_headers_test() ->
    Events = [
        chat_tool_event([
            chat_header_entry(0, <<"call_a">>, <<"get_weather">>),
            chat_header_entry(1, <<"call_b">>, <<"get_time">>)
        ]),
        chat_tool_event([chat_frag_entry(1, <<"{\"b\":2}">>)]),
        chat_finish_event(<<"tool_calls">>)
    ],
    {ok, Frames, _St} = run_events(anthropic_messages, openai_chat, Events),
    Parsed = parse_frames(Frames),
    ?assertEqual([{0, <<"tool_use">>}, {1, <<"tool_use">>}], anthro_block_starts(Parsed)),
    ?assertEqual([0, 1], anthro_block_stops(Parsed)).

anthro_two_tool_blocks_test() ->
    Events = [
        anthro_tool_start_event(0, <<"tool_a">>, <<"get_weather">>),
        anthro_json_delta_event(0, <<"{\"a\":">>),
        anthro_json_delta_event(0, <<"1}">>),
        anthro_block_stop_event(0),
        anthro_tool_start_event(1, <<"tool_b">>, <<"get_time">>),
        anthro_json_delta_event(1, <<"{\"b\":2}">>),
        anthro_block_stop_event(1),
        anthro_message_delta_event(<<"tool_use">>)
    ],
    {ok, Frames, _St} = run_events(openai_chat, anthropic_messages, Events),
    Chunks = chat_chunks(parse_frames(Frames)),
    Entries = tool_call_entries(Chunks),
    %% Two sequential anthropic blocks -> chat ordinals 0 and 1; the
    %% id rides the first chunk of each call only.
    ?assertEqual([0, 0, 1], [maps:get(<<"index">>, E) || E <- Entries]),
    ?assertEqual([<<"tool_a">>, <<>>, <<"tool_b">>], [maps:get(<<"id">>, E, <<>>) || E <- Entries]),
    ?assertEqual(#{<<"a">> => 1}, decode_map(tool_args_concat(Entries, 0))),
    ?assertEqual(#{<<"b">> => 2}, decode_map(tool_args_concat(Entries, 1))),
    [Finish] = [C || C <- Chunks, chunk_kind(C) =:= finish],
    [FinishChoice] = maps:get(<<"choices">>, Finish),
    ?assertEqual(<<"tool_calls">>, maps:get(<<"finish_reason">>, FinishChoice)).

%%%-------------------------------------------------------------------
%%% Zero-argument tool calls
%%%-------------------------------------------------------------------

chat_zero_args_call_test() ->
    Events = [
        chat_tool_event([chat_header_entry(0, <<"call_z">>, <<"ping">>)]),
        chat_finish_event(<<"tool_calls">>)
    ],
    {ok, Frames, _St} = run_events(anthropic_messages, openai_chat, Events),
    Parsed = parse_frames(Frames),
    %% Zero argument bytes: complete with "{}" — block start + stop,
    %% NO input_json_delta, never looks truncated.
    ?assertEqual([{0, <<"tool_use">>}], anthro_block_starts(Parsed)),
    ?assertEqual([0], anthro_block_stops(Parsed)),
    ?assertEqual(<<>>, anthro_partial_json(Parsed, 0)),
    [{<<"message_delta">>, DeltaMap}] = [
        {E, M} || {E, M} <- anthro_frames(Parsed), E =:= <<"message_delta">>
    ],
    ?assertEqual(<<"tool_use">>, maps:get(<<"stop_reason">>, maps:get(<<"delta">>, DeltaMap))).

anthro_zero_args_call_test() ->
    Events = [
        anthro_tool_start_event(0, <<"tool_z">>, <<"ping">>),
        anthro_block_stop_event(0),
        anthro_message_delta_event(<<"tool_use">>)
    ],
    {ok, Frames, _St} = run_events(openai_chat, anthropic_messages, Events),
    Chunks = chat_chunks(parse_frames(Frames)),
    Entries = tool_call_entries(Chunks),
    %% One chunk carries the whole call with "{}" arguments (C5).
    ?assertEqual(1, length(Entries)),
    [Entry] = Entries,
    ?assertEqual(0, maps:get(<<"index">>, Entry)),
    ?assertEqual(<<"tool_z">>, maps:get(<<"id">>, Entry)),
    ?assertEqual(<<"{}">>, maps:get(<<"arguments">>, maps:get(<<"function">>, Entry))),
    [Finish] = [C || C <- Chunks, chunk_kind(C) =:= finish],
    [FinishChoice] = maps:get(<<"choices">>, Finish),
    ?assertEqual(<<"tool_calls">>, maps:get(<<"finish_reason">>, FinishChoice)).

%%%-------------------------------------------------------------------
%%% C5 interleaving: chat text between tool fragments defers to close
%%%-------------------------------------------------------------------

chat_interleaved_text_deferred_test() ->
    Events = [
        chat_delta_event(<<"A">>, <<"">>),
        chat_tool_event([chat_header_entry(0, <<"call_i">>, <<"get_weather">>)]),
        chat_tool_event([chat_frag_entry(0, <<"{\"x\":">>)]),
        chat_delta_event(<<"B">>, <<"">>),
        chat_delta_event(<<"">>, <<"R">>),
        chat_tool_event([chat_frag_entry(0, <<"1}">>)]),
        chat_finish_event(<<"tool_calls">>)
    ],
    {ok, Frames, _St} = run_events(anthropic_messages, openai_chat, Events),
    Parsed = parse_frames(Frames),
    %% Block order preserves wire text order: text(A) 0, tool 1, then
    %% the DEFERRED text(B) 2 and thinking(R) 3 flushed at close.
    ?assertEqual(
        [
            {0, <<"text">>},
            {1, <<"tool_use">>},
            {2, <<"text">>},
            {3, <<"thinking">>}
        ],
        anthro_block_starts(Parsed)
    ),
    %% B is NOT between the two tool fragments: it follows stop(1).
    ?assert(lists:max(positions_of_deltas(Parsed, 1)) < position_of_stop(Parsed, 1)),
    ?assert(hd(positions_of_deltas(Parsed, 2)) > position_of_stop(Parsed, 1)),
    ?assertEqual([<<"B">>], [
        maps:get(<<"text">>, maps:get(<<"delta">>, M))
     || {anthro, <<"content_block_delta">>, M} <- Parsed,
        maps:get(<<"index">>, M) =:= 2,
        maps:get(<<"type">>, maps:get(<<"delta">>, M)) =:= <<"text_delta">>
    ]),
    ?assertEqual([0, 1, 2, 3], anthro_block_stops(Parsed)).

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
        run_events(anthropic_messages, openai_chat, Events)
    ).

anthro_truncated_args_error_test() ->
    Events = [
        anthro_tool_start_event(0, <<"tool_t">>, <<"get_weather">>),
        anthro_json_delta_event(0, <<"{\"city\":">>),
        anthro_block_stop_event(0),
        anthro_message_delta_event(<<"tool_use">>)
    ],
    ?assertMatch(
        {error, translate_unsupported, #sse_st{}, _},
        run_events(openai_chat, anthropic_messages, Events)
    ).

%% finish while a tool block is still open (no content_block_stop):
%% never make it look finished.
anthro_unclosed_tool_at_finish_error_test() ->
    Events = [
        anthro_tool_start_event(0, <<"tool_u">>, <<"get_weather">>),
        anthro_json_delta_event(0, <<"{\"a\":1}">>),
        anthro_message_delta_event(<<"tool_use">>)
    ],
    ?assertMatch(
        {error, translate_unsupported, #sse_st{}, _},
        run_events(openai_chat, anthropic_messages, Events)
    ).

%% Fragment for a block that was never started: fail closed.
anthro_fragment_unknown_block_error_test() ->
    Events = [
        anthro_tool_start_event(0, <<"tool_k">>, <<"get_weather">>),
        anthro_json_delta_event(5, <<"{}">>)
    ],
    ?assertMatch(
        {error, translate_unsupported, #sse_st{}, _},
        run_events(openai_chat, anthropic_messages, Events)
    ).

%% A closed chat index re-opening: the wire cannot splice mid-call.
chat_tool_reopen_error_test() ->
    Events = [
        chat_tool_event([chat_header_entry(0, <<"call_r0">>, <<"get_weather">>)]),
        chat_tool_event([chat_header_entry(1, <<"call_r1">>, <<"get_time">>)]),
        chat_tool_event([chat_frag_entry(0, <<"{}">>)]),
        chat_finish_event(<<"tool_calls">>)
    ],
    ?assertMatch(
        {error, translate_unsupported, #sse_st{}, _},
        run_events(anthropic_messages, openai_chat, Events)
    ).

%%%-------------------------------------------------------------------
%%% Caps (C5): 256KiB per call, 64 calls, 1MiB total args
%%%-------------------------------------------------------------------

%% A VALID JSON argument blob of exactly Size bytes (padded string
%% field) so cap boundary tests never trip the decode-at-close check.
json_blob(Size) when Size >= 8 ->
    Pad = binary:copy(<<"a">>, Size - 8),
    <<"{\"p\":\"", Pad/binary, "\"}">>.

chat_args_per_call_cap_test() ->
    Exactly = json_blob(256 * 1024),
    {ok, _, _} = run_events(anthropic_messages, openai_chat, [
        chat_tool_event([chat_header_entry(0, <<"call_c">>, <<"get_weather">>)]),
        chat_tool_event([chat_frag_entry(0, Exactly)]),
        chat_finish_event(<<"tool_calls">>)
    ]),
    ?assertMatch(
        {error, tool_args_cap, #sse_st{}, _},
        run_events(anthropic_messages, openai_chat, [
            chat_tool_event([chat_header_entry(0, <<"call_c">>, <<"get_weather">>)]),
            chat_tool_event([chat_frag_entry(0, json_blob(256 * 1024 + 1))]),
            chat_finish_event(<<"tool_calls">>)
        ])
    ).

chat_calls_cap_test() ->
    Headers = [
        chat_tool_event([
            chat_header_entry(I, <<"call_", (integer_to_binary(I))/binary>>, <<"p">>)
        ])
     || I <- lists:seq(0, 63)
    ],
    {ok, Frames, _} =
        run_events(anthropic_messages, openai_chat, Headers ++ [chat_finish_event(<<"tool_calls">>)]),
    ?assertEqual(64, length(anthro_block_starts(parse_frames(Frames)))),
    ?assertMatch(
        {error, tool_args_cap, #sse_st{}, _},
        run_events(
            anthropic_messages,
            openai_chat,
            Headers ++ [chat_tool_event([chat_header_entry(64, <<"call_64">>, <<"p">>)])]
        )
    ).

chat_total_args_cap_test() ->
    Quarter = json_blob(256 * 1024),
    %% 4 calls x 256KiB = exactly 1MiB: allowed; the next byte trips it.
    FourCalls = lists:append([
        [
            chat_tool_event([
                chat_header_entry(I, <<"call_", (integer_to_binary(I))/binary>>, <<"p">>)
            ]),
            chat_tool_event([chat_frag_entry(I, Quarter)])
        ]
     || I <- lists:seq(0, 3)
    ]),
    {ok, _, _} =
        run_events(anthropic_messages, openai_chat, FourCalls ++ [chat_finish_event(<<"tool_calls">>)]),
    ?assertMatch(
        {error, tool_args_cap, #sse_st{}, _},
        run_events(anthropic_messages, openai_chat, FourCalls ++ [
            chat_tool_event([chat_header_entry(4, <<"call_4">>, <<"p">>)]),
            chat_tool_event([chat_frag_entry(4, <<"a">>)])
        ])
    ).

anthro_args_per_call_cap_test() ->
    Big = binary:copy(<<"a">>, 256 * 1024 + 1),
    ?assertMatch(
        {error, tool_args_cap, #sse_st{}, _},
        run_events(openai_chat, anthropic_messages, [
            anthro_tool_start_event(0, <<"tool_big">>, <<"get_weather">>),
            anthro_json_delta_event(0, Big)
        ])
    ).

%%%-------------------------------------------------------------------
%%% Synthesized ids (C4/C5): jfc_ prefix, never repeating
%%%-------------------------------------------------------------------

chat_tool_id_synthesized_test() ->
    %% No id on the wire (null, dashscope late-fragment shape): the
    %% anthropic tool_use block gets a janus-namespaced id; two such
    %% calls never share one.
    {ok, Frames, _} = run_events(anthropic_messages, openai_chat, [
        chat_tool_event([
            chat_header_entry(0, null, <<"p">>)
        ]),
        chat_tool_event([
            chat_header_entry(1, null, <<"p">>)
        ]),
        chat_finish_event(<<"tool_calls">>)
    ]),
    Starts = [maps:get(<<"content_block">>, M) || M <- anthro_starts(parse_frames(Frames))],
    [IdA, IdB] = [maps:get(<<"id">>, B) || B <- Starts],
    ?assertMatch(<<"jfc_", _/binary>>, IdA),
    ?assertMatch(<<"jfc_", _/binary>>, IdB),
    ?assertNotEqual(IdA, IdB).

%%%-------------------------------------------------------------------
%%% Vision request-side translate (chat <-> anthropic)
%%%-------------------------------------------------------------------

-define(PNG_B64, <<"iVBORw0KGgoAAAANSUhEUg==">>).
-define(DATA_URL, <<"data:image/png;base64,", ?PNG_B64/binary>>).

chat_image_url_request_test() ->
    In = #{
        <<"model">> => <<"m">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{<<"type">> => <<"text">>, <<"text">> => <<"what is this?">>},
                    #{<<"type">> => <<"image_url">>, <<"image_url">> => #{<<"url">> => ?DATA_URL}}
                ]
            }
        ]
    },
    {ok, Out} = janus_protocol_translate:translate_request(openai_chat, anthropic_messages, In),
    [UserMsg] = maps:get(<<"messages">>, Out),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, UserMsg)),
    ?assertEqual(
        [
            #{<<"type">> => <<"text">>, <<"text">> => <<"what is this?">>},
            #{
                <<"type">> => <<"image">>,
                <<"source">> => #{
                    <<"type">> => <<"base64">>,
                    <<"media_type">> => <<"image/png">>,
                    <<"data">> => ?PNG_B64
                }
            }
        ],
        maps:get(<<"content">>, UserMsg)
    ),
    %% Round-trip back to chat restores the data URL verbatim.
    {ok, Back} = janus_protocol_translate:translate_request(anthropic_messages, openai_chat, Out),
    [BackUser] = maps:get(<<"messages">>, Back),
    BackContent = maps:get(<<"content">>, BackUser),
    ?assertEqual(2, length(BackContent)),
    ?assertEqual(
        #{<<"type">> => <<"image_url">>, <<"image_url">> => #{<<"url">> => ?DATA_URL}},
        lists:last(BackContent)
    ).

%% image_url may also be the URL string itself.
chat_image_url_string_form_test() ->
    In = #{
        <<"model">> => <<"m">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [#{<<"type">> => <<"image_url">>, <<"image_url">> => ?DATA_URL}]
            }
        ]
    },
    {ok, Out} = janus_protocol_translate:translate_request(openai_chat, anthropic_messages, In),
    [UserMsg] = maps:get(<<"messages">>, Out),
    [ImageBlock] = maps:get(<<"content">>, UserMsg),
    ?assertEqual(<<"base64">>, maps:get(<<"type">>, maps:get(<<"source">>, ImageBlock))).

%% Plain http(s) URLs map to the anthropic url source and back.
chat_plain_url_image_test() ->
    In = #{
        <<"model">> => <<"m">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{<<"type">> => <<"image_url">>, <<"image_url">> => #{<<"url">> => <<"https://x.test/cat.png">>}}
                ]
            }
        ]
    },
    {ok, Out} = janus_protocol_translate:translate_request(openai_chat, anthropic_messages, In),
    [UserMsg] = maps:get(<<"messages">>, Out),
    [ImageBlock] = maps:get(<<"content">>, UserMsg),
    ?assertEqual(
        #{<<"type">> => <<"url">>, <<"url">> => <<"https://x.test/cat.png">>},
        maps:get(<<"source">>, ImageBlock)
    ),
    {ok, Back} = janus_protocol_translate:translate_request(anthropic_messages, openai_chat, Out),
    [BackUser] = maps:get(<<"messages">>, Back),
    ?assertEqual(
        [#{<<"type">> => <<"image_url">>, <<"image_url">> => #{<<"url">> => <<"https://x.test/cat.png">>}}],
        maps:get(<<"content">>, BackUser)
    ).

anthropic_image_blocks_to_chat_test() ->
    In = #{
        <<"model">> => <<"m">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{<<"type">> => <<"text">>, <<"text">> => <<"look">>},
                    #{
                        <<"type">> => <<"image">>,
                        <<"source">> => #{<<"type">> => <<"base64">>, <<"media_type">> => <<"image/jpeg">>, <<"data">> => <<"QUJD">>}
                    }
                ]
            }
        ]
    },
    {ok, Out} = janus_protocol_translate:translate_request(anthropic_messages, openai_chat, In),
    [UserMsg] = maps:get(<<"messages">>, Out),
    Content = maps:get(<<"content">>, UserMsg),
    ?assertEqual(2, length(Content)),
    ?assertEqual(<<"look">>, maps:get(<<"text">>, hd(Content))),
    ?assertEqual(
        #{
            <<"type">> => <<"image_url">>,
            <<"image_url">> => #{<<"url">> => <<"data:image/jpeg;base64,QUJD">>}
        },
        lists:last(Content)
    ),
    %% Round-trip restores the anthropic base64 source.
    {ok, Back} = janus_protocol_translate:translate_request(openai_chat, anthropic_messages, Out),
    [BackUser] = maps:get(<<"messages">>, Back),
    ?assertMatch(
        [
            #{<<"type">> := <<"text">>, <<"text">> := <<"look">>},
            #{
                <<"type">> := <<"image">>,
                <<"source">> :=
                    #{<<"type">> := <<"base64">>, <<"media_type">> := <<"image/jpeg">>, <<"data">> := <<"QUJD">>}
            }
        ],
        maps:get(<<"content">>, BackUser)
    ).

%% Text-only chat content lists keep the flattened-binary shape.
vision_text_only_still_flattens_test() ->
    In = #{
        <<"model">> => <<"m">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{<<"type">> => <<"text">>, <<"text">> => <<"a">>},
                    #{<<"type">> => <<"text">>, <<"text">> => <<"b">>}
                ]
            }
        ]
    },
    {ok, Out} = janus_protocol_translate:translate_request(openai_chat, anthropic_messages, In),
    [UserMsg] = maps:get(<<"messages">>, Out),
    ?assertEqual(<<"ab">>, maps:get(<<"content">>, UserMsg)).

%% Responses pairs keep the vision reject (Phase 2/3 own them).
vision_responses_pair_still_rejected_test() ->
    In = #{
        <<"model">> => <<"m">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [#{<<"type">> => <<"image_url">>, <<"image_url">> => #{<<"url">> => ?DATA_URL}}]
            }
        ]
    },
    ?assertMatch(
        {error, {translate_unsupported, _}},
        janus_protocol_translate:translate_request(openai_chat, openai_responses, In)
    ),
    AnthropicIn = #{
        <<"model">> => <<"m">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{
                        <<"type">> => <<"image">>,
                        <<"source">> => #{<<"type">> => <<"url">>, <<"url">> => <<"https://x.test/a.png">>}
                    }
                ]
            }
        ]
    },
    ?assertMatch(
        {error, {translate_unsupported, _}},
        janus_protocol_translate:translate_request(anthropic_messages, openai_responses, AnthropicIn)
    ).

%% Dispatch still blocks vision STREAMS: the unblock is the separate
%% 1.9 ship unit, not this phase.
vision_stream_still_blocked_test() ->
    Map = #{
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => [#{<<"type">> => <<"image_url">>}]}
        ]
    },
    ?assertEqual(true, janus_protocol_translate:stream_translate_blocked(openai_chat, Map)),
    ?assertEqual(true, janus_protocol_translate:stream_translate_blocked(anthropic_messages, Map)).

%%%-------------------------------------------------------------------
%%% State registration (anthropic -> chat)
%%%-------------------------------------------------------------------

anthro_tool_start_registers_call_test() ->
    Ev = anthro_tool_start_event(0, <<"tool_s">>, <<"get_weather">>),
    {ok, Frames, St} =
        janus_protocol_translate:translate_sse(
            openai_chat, anthropic_messages, Ev, janus_protocol_translate:new_sse_st()
        ),
    %% The chat chunk waits for the first fragment (or the close).
    ?assertEqual([], Frames),
    ?assertEqual(1, map_size(St#sse_st.tools)),
    ?assertEqual(0, St#sse_st.open_tool),
    ?assertEqual(1, St#sse_st.tool_seq).
