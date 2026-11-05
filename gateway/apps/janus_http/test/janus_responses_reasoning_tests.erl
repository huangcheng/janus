%% Reasoning forwarding on the responses face.
%%
%% Why this suite exists (2026-11-05, live): an agent on the responses
%% protocol reported `output: 10944` tokens against `textlen: 0` — the
%% model spent its whole budget reasoning and the client received an empty
%% answer. The gateway was dropping thinking text on the
%% anthropic->responses face on purpose ("corpus-pending reasoning
%% framing"), so a client had no way to tell a long think from a stall.
%%
%% Two things are pinned:
%%
%%   R1 — thinking text becomes `response.reasoning_summary_text.delta`
%%        events on its own `reasoning` output item, not message text.
%%        Folding it into the message item would make clients render the
%%        summary as the answer — worse than dropping it.
%%   R2 — the reasoning item and the message item keep separate
%%        output_index values, so a client can order them.
-module(janus_responses_reasoning_tests).

-include_lib("eunit/include/eunit.hrl").
-include("janus_protocol_translate.hrl").

%% --- helpers --------------------------------------------------------

%% One upstream anthropic SSE event folded through the translate face.
%% Returns {Frames, St}.
fold(Event, St) ->
    {ok, Frames, St2} = janus_protocol_translate:translate_sse(openai_responses, anthropic_messages, Event, St),
    {iolist_to_binary(Frames), St2}.

%% Concatenate every frame emitted so far, so a test can assert on the
%% whole wire without depending on how the fold batches.
fold_all(Events) ->
    lists:foldl(
        fun(E, {Acc, St}) ->
            {Bin, St2} = fold(E, St),
            {<<Acc/binary, Bin/binary>>, St2}
        end,
        {<<>>, janus_protocol_translate:new_sse_st(0)},
        Events
    ).

thinking_start(Text) ->
    #{
        type => <<"content_block_start">>,
        data => #{
            <<"index">> => 0,
            <<"content_block">> => #{<<"type">> => <<"thinking">>, <<"thinking">> => Text}
        }
    }.

thinking_delta(Text) ->
    #{
        type => <<"content_block_delta">>,
        data => #{
            <<"index">> => 0,
            <<"delta">> => #{<<"type">> => <<"thinking_delta">>, <<"thinking">> => Text}
        }
    }.

text_delta(Text) ->
    #{
        type => <<"content_block_delta">>,
        data => #{
            <<"index">> => 1,
            <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => Text}
        }
    }.

%% --- R1: thinking becomes reasoning events, not message text --------

thinking_start_emits_reasoning_item_test() ->
    {Wire, _St} = fold_all([thinking_start(<<"let me think">>)]),
    ?assert(binary:match(Wire, <<"response.output_item.added">>) =/= nomatch),
    ?assert(binary:match(Wire, <<"\"type\":\"reasoning\"">>) =/= nomatch),
    ?assert(binary:match(Wire, <<"response.reasoning_summary_text.delta">>) =/= nomatch),
    ?assert(binary:match(Wire, <<"let me think">>) =/= nomatch),
    %% The summary must NOT ride the message item's text delta.
    ?assertEqual(nomatch, binary:match(Wire, <<"response.output_text.delta">>)).

thinking_delta_emits_reasoning_delta_test() ->
    {Wire, _St} = fold_all([thinking_delta(<<"step one">>)]),
    ?assert(binary:match(Wire, <<"response.reasoning_summary_text.delta">>) =/= nomatch),
    ?assert(binary:match(Wire, <<"step one">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(Wire, <<"response.output_text.delta">>)).

%% An empty thinking payload is framing only: no delta, no empty item.
empty_thinking_emits_nothing_test() ->
    {Wire, _St} = fold_all([thinking_delta(<<>>)]),
    ?assertEqual(<<>>, Wire).

%% --- R2: reasoning and message items keep separate indices ----------

reasoning_and_text_get_distinct_output_indices_test() ->
    {Wire, _St} = fold_all([thinking_delta(<<"hmm">>), text_delta(<<"answer">>)]),
    ?assert(binary:match(Wire, <<"response.reasoning_summary_text.delta">>) =/= nomatch),
    ?assert(binary:match(Wire, <<"response.output_text.delta">>) =/= nomatch),
    %% Exactly two output items opened: the reasoning summary and the
    %% message. Count the SSE `event:` lines, not every occurrence of the
    %% string (the payload repeats the type name).
    Added = binary:matches(Wire, <<"event: response.output_item.added\n">>),
    ?assertEqual(2, length(Added)),
    ?assert(binary:match(Wire, <<"\"type\":\"reasoning\"">>) =/= nomatch),
    ?assert(binary:match(Wire, <<"\"type\":\"message\"">>) =/= nomatch),
    %% The message text must not contain the reasoning text and vice versa.
    ?assert(binary:match(Wire, <<"hmm">>) =/= nomatch),
    ?assert(binary:match(Wire, <<"answer">>) =/= nomatch).
%% --- R3: the reasoning item is CLOSED, not just opened --------------
%%
%% An item that opens and never completes leaves the client with an
%% output_index the terminal event mentions but it never saw finished,
%% and leaves the summary text unserialized at the end of the stream.

%% Fold a whole turn — thinking then text — and finalize it, exactly as
%% the handler does at EOF.
finish_turn(Events) ->
    {Wire0, St0} = fold_all(Events),
    {ok, TailFrames, _St1} = janus_protocol_translate:finalize_sse(openai_responses, normal, St0),
    <<Wire0/binary, (iolist_to_binary(TailFrames))/binary>>.

reasoning_item_is_closed_at_finish_test() ->
    Wire = finish_turn([thinking_delta(<<"weighing options">>), text_delta(<<"done">>)]),
    %% One done event per item: the reasoning summary and the message.
    Dones = binary:matches(Wire, <<"event: response.output_item.done\n">>),
    ?assertEqual(2, length(Dones)),
    %% The reasoning item's done event carries the collected summary as a
    %% summary_text part, not as message text.
    ?assert(binary:match(Wire, <<"\"type\":\"summary_text\"">>) =/= nomatch),
    ?assert(binary:match(Wire, <<"weighing options">>) =/= nomatch).

reasoning_only_turn_still_closes_test() ->
    %% A turn that only thinks (no answer text at all) must still close
    %% the reasoning item, or the stream ends with an open item.
    Wire = finish_turn([thinking_delta(<<"no answer, just thought">>)]),
    ?assert(binary:match(Wire, <<"event: response.output_item.done\n">>) =/= nomatch),
    ?assert(binary:match(Wire, <<"\"type\":\"reasoning\"">>) =/= nomatch),
    ?assert(binary:match(Wire, <<"no answer, just thought">>) =/= nomatch).

%% --- R4: chat upstream reasoning_content is forwarded too -----------
%%
%% The first half of the bug was on the chat face: `resp_text_delta/2`
%% read only `content`, so a chat turn that reasoned and then answered
%% streamed no summary at all. Chat and anthropic upstreams reach the
%% same responses face and must behave the same.

chat_delta_with_reasoning(Reasoning, Content) ->
    #{
        type => <<"chunk">>,
        data => #{
            <<"choices">> => [
                #{
                    <<"index">> => 0,
                    <<"delta">> => #{
                        <<"reasoning_content">> => Reasoning,
                        <<"content">> => Content
                    }
                }
            ]
        }
    }.

fold_chat(Events) ->
    lists:foldl(
        fun(E, {Acc, St}) ->
            {ok, Frames, St2} =
                janus_protocol_translate:translate_sse(openai_responses, openai_chat, E, St),
            {<<Acc/binary, (iolist_to_binary(Frames))/binary>>, St2}
        end,
        {<<>>, janus_protocol_translate:new_sse_st(0)},
        Events
    ).

chat_reasoning_becomes_a_reasoning_item_test() ->
    {Wire, _St} = fold_chat([chat_delta_with_reasoning(<<"considering">>, <<>>)]),
    ?assert(binary:match(Wire, <<"\"type\":\"reasoning\"">>) =/= nomatch),
    ?assert(binary:match(Wire, <<"response.reasoning_summary_text.delta">>) =/= nomatch),
    ?assert(binary:match(Wire, <<"considering">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(Wire, <<"response.output_text.delta">>)).

%% A single delta carrying both goes to two different output items.
chat_delta_with_both_keeps_them_apart_test() ->
    {Wire, _St} = fold_chat([chat_delta_with_reasoning(<<"why">>, <<"what">>)]),
    ?assert(binary:match(Wire, <<"response.reasoning_summary_text.delta">>) =/= nomatch),
    ?assert(binary:match(Wire, <<"response.output_text.delta">>) =/= nomatch),
    ?assert(binary:match(Wire, <<"why">>) =/= nomatch),
    ?assert(binary:match(Wire, <<"what">>) =/= nomatch).

%% --- R5: two consecutive thinking blocks stay two summaries --------

thinking_stop() ->
    #{type => <<"content_block_stop">>, data => #{<<"index">> => 0}}.

two_thinking_blocks_are_two_items_test() ->
    {Wire, _St} =
        fold_all([
            thinking_delta(<<"first">>),
            thinking_stop(),
            thinking_delta(<<"second">>)
        ]),
    Added = binary:matches(Wire, <<"event: response.output_item.added\n">>),
    Dones = binary:matches(Wire, <<"event: response.output_item.done\n">>),
    ?assertEqual(2, length(Added)),
    %% The first block is closed by its content_block_stop, so by the time
    %% the second starts one item is already done.
    ?assertEqual(1, length(Dones)),
    ?assert(binary:match(Wire, <<"first">>) =/= nomatch),
    ?assert(binary:match(Wire, <<"second">>) =/= nomatch).

%% --- R6: the deferred path — reasoning while a tool call is open ----
%%
%% Reasoning that arrives while a tool call is open cannot be emitted (it
%% would interleave two output items), so it is deferred and flushed at
%% the close. That branch previously took the text-only clause of
%% resp_flush_deferred/1 and died on a badmatch, truncating the stream
%% mid-turn — the worst outcome for a long agent run.

tool_call_delta() ->
    #{
        type => <<"chunk">>,
        data => #{
            <<"choices">> => [
                #{
                    <<"index">> => 0,
                    <<"delta">> => #{
                        <<"tool_calls">> => [
                            #{
                                <<"index">> => 0,
                                <<"id">> => <<"call_r6">>,
                                <<"type">> => <<"function">>,
                                <<"function">> => #{
                                    <<"name">> => <<"edit_file">>,
                                    <<"arguments">> => <<"{\"p\":1}">>
                                }
                            }
                        ]
                    }
                }
            ]
        }
    }.

tool_finish_delta() ->
    #{
        type => <<"chunk">>,
        data => #{
            <<"choices">> => [
                #{<<"index">> => 0, <<"delta">> => #{}, <<"finish_reason">> => <<"tool_calls">>}
            ]
        }
    }.

reasoning_while_tool_open_survives_test() ->
    {ok, _Frames, _St} =
        janus_protocol_translate:translate_sse(
            openai_responses, openai_chat, tool_call_delta(), janus_protocol_translate:new_sse_st(0)
        ),
    %% The turn continues: a later reasoning delta must not crash the fold.
    {Wire, St} =
        fold_chat([
            tool_call_delta(),
            chat_delta_with_reasoning(<<"thinking while the call is open">>, <<>>),
            tool_finish_delta()
        ]),
    ?assert(is_tuple(St)),
    %% Whether it surfaced inline or on the deferred flush, the summary
    %% text reaches the client and the stream terminates normally.
    ?assert(binary:match(Wire, <<"thinking while the call is open">>) =/= nomatch).

%% --- R7: output_index order is monotonic on the wire ----------------
%%
%% Items are sequential: an item takes the next index only after the open
%% one is done. The normal chat path is the case that breaks it if either
%% side is left unguarded — one delta carries reasoning AND content, so
%% the summary opens first and the answer opens second.

%% The output_index of every output_item.added, in wire order. Each SSE
%% block here is one `event:` line followed by one `data:` line, so walk
%% the lines and remember the last event name seen.
added_indices(Wire) ->
    Lines = binary:split(Wire, <<"\n">>, [global]),
    {Acc, _Last} = lists:foldl(fun added_step/2, {[], undefined}, Lines),
    lists:reverse(Acc).

added_step(<<"event: ", Name/binary>>, {Acc, _}) ->
    {Acc, Name};
added_step(<<"data: ", Json/binary>>, {Acc, <<"response.output_item.added">>}) ->
    {[output_index_of(Json) | Acc], undefined};
added_step(_Line, {Acc, Last}) ->
    {Acc, Last}.

output_index_of(Json) ->
    case binary:match(Json, <<"\"output_index\":">>) of
        {S, L} ->
            Tail = binary:part(Json, S + L, byte_size(Json) - S - L),
            {N, _} = string:to_integer(binary_to_list(Tail)),
            N;
        nomatch ->
            undefined
    end.

added_indices_are_monotonic_test() ->
    Wire = finish_turn([thinking_delta(<<"hmm">>), text_delta(<<"answer">>)]),
    Indices = [I || I <- added_indices(Wire), I =/= undefined],
    ?assertEqual(2, length(Indices)),
    ?assertEqual(Indices, lists:sort(Indices)),
    ?assertEqual([0, 1], Indices).

%% The chat path that opens both items from ONE delta.
chat_reasoning_then_content_indices_monotonic_test() ->
    {Wire0, St0} = fold_chat([chat_delta_with_reasoning(<<"why">>, <<"what">>)]),
    {ok, Tail, _} = janus_protocol_translate:finalize_sse(openai_responses, normal, St0),
    Wire = <<Wire0/binary, (iolist_to_binary(Tail))/binary>>,
    Indices = [I || I <- added_indices(Wire), I =/= undefined],
    ?assertEqual(2, length(Indices)),
    ?assertEqual([0, 1], Indices).
