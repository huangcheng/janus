%% Responses -> chat tool adjacency (2026-10-29).
%%
%% The Responses API pairs function results by call_id, so ORDERING IS
%% FREE: a client may legally place a plain assistant message between a
%% function_call and its function_call_output, and may place several
%% calls before any output. The chat wire has no such freedom — strict
%% upstreams demand assistant(tool_calls) be followed IMMEDIATELY by
%% its tool messages (live: dashscope "tool_calls must be followed by
%% tool messages", minimax "(2013) tool call result does not follow
%% tool call"). Every shape below must therefore come out of the
%% translator with the run contiguous.
-module(janus_translate_tool_adjacency_tests).

-include_lib("eunit/include/eunit.hrl").

fc(Id) ->
    #{
        <<"type">> => <<"function_call">>,
        <<"call_id">> => Id,
        <<"name">> => <<"bash">>,
        <<"arguments">> => <<"{}">>
    }.

out(Id) ->
    #{
        <<"type">> => <<"function_call_output">>,
        <<"call_id">> => Id,
        <<"output">> => <<"ok">>
    }.

umsg(Text) ->
    #{
        <<"type">> => <<"message">>,
        <<"role">> => <<"user">>,
        <<"content">> => [#{<<"type">> => <<"input_text">>, <<"text">> => Text}]
    }.

amsg(Text) ->
    #{
        <<"type">> => <<"message">>,
        <<"role">> => <<"assistant">>,
        <<"content">> => [#{<<"type">> => <<"output_text">>, <<"text">> => Text}]
    }.

to_chat(Input) ->
    Map = #{<<"model">> => <<"m">>, <<"input">> => Input, <<"stream">> => false},
    {ok, Chat} = janus_protocol_translate:translate_request(openai_responses, openai_chat, Map),
    maps:get(<<"messages">>, Chat).

roles(Msgs) ->
    [maps:get(<<"role">>, M) || M <- Msgs].

texts(Msgs) ->
    [
        case maps:get(<<"content">>, M, <<>>) of
            B when is_binary(B) -> B;
            L when is_list(L) -> [maps:get(<<"text">>, X, <<>>) || X <- L, is_map(X)];
            _ -> <<>>
        end
     || M <- Msgs
    ].

%% Every assistant carrying tool_calls is followed by a contiguous run
%% of tool messages covering exactly those ids — nothing interleaved.
assert_adjacent([]) ->
    ok;
assert_adjacent([
    #{<<"role">> := <<"assistant">>, <<"tool_calls">> := TCs} | Rest
]) when is_list(TCs), TCs =/= [] ->
    Ids = [maps:get(<<"id">>, C) || C <- TCs],
    {Tools, R2} = take_tools(Rest, []),
    Got = [maps:get(<<"tool_call_id">>, M) || M <- Tools],
    ?assertEqual(length(Ids), length(Tools)),
    ?assertEqual(lists:sort(Ids), lists:sort(Got)),
    assert_adjacent(R2);
assert_adjacent([_ | Rest]) ->
    assert_adjacent(Rest).

take_tools([#{<<"role">> := <<"tool">>} = M | Rest], Acc) ->
    take_tools(Rest, [M | Acc]);
take_tools(Rest, Acc) ->
    {lists:reverse(Acc), Rest}.

%% The live failure: assistant text between a call and its own output.
interleaved_assistant_text_test() ->
    Msgs = to_chat([umsg(<<"go">>), fc(<<"c1">>), amsg(<<"note">>), out(<<"c1">>)]),
    assert_adjacent(Msgs),
    %% the deferred text lands AFTER the run, not inside it
    ?assertEqual([<<"user">>, <<"assistant">>, <<"tool">>, <<"assistant">>], roles(Msgs)).

%% Parallel calls with no text: grouped, and both outputs follow.
parallel_calls_test() ->
    Msgs = to_chat([umsg(<<"go">>), fc(<<"c1">>), fc(<<"c2">>), out(<<"c1">>), out(<<"c2">>)]),
    assert_adjacent(Msgs),
    [_, Assistant | _] = Msgs,
    ?assertEqual(
        [<<"c1">>, <<"c2">>],
        [maps:get(<<"id">>, C) || C <- maps:get(<<"tool_calls">>, Assistant)]
    ).

%% Text after a CLOSED run is a real boundary: emitted in place, in the
%% original order (regression: a role-based check put it after the user
%% message that followed it).
text_after_closed_run_test() ->
    Msgs = to_chat([umsg(<<"go">>), fc(<<"c1">>), out(<<"c1">>), amsg(<<"after">>), umsg(<<"next">>)]),
    assert_adjacent(Msgs),
    ?assertEqual(
        [<<"user">>, <<"assistant">>, <<"tool">>, <<"assistant">>, <<"user">>],
        roles(Msgs)
    ).

%% Text sitting between two separate runs.
text_between_runs_test() ->
    Msgs = to_chat([
        umsg(<<"go">>), fc(<<"c1">>), out(<<"c1">>), amsg(<<"mid">>), fc(<<"c2">>), out(<<"c2">>)
    ]),
    assert_adjacent(Msgs),
    ?assertEqual(
        [<<"user">>, <<"assistant">>, <<"tool">>, <<"assistant">>, <<"tool">>],
        roles(Msgs)
    ).

%% Parallel calls AND interleaved text together.
parallel_with_interleaved_text_test() ->
    Msgs = to_chat([
        umsg(<<"go">>),
        fc(<<"c1">>),
        fc(<<"c2">>),
        amsg(<<"note">>),
        out(<<"c1">>),
        out(<<"c2">>)
    ]),
    assert_adjacent(Msgs),
    ?assertEqual(
        [<<"user">>, <<"assistant">>, <<"tool">>, <<"tool">>, <<"assistant">>],
        roles(Msgs)
    ).

%% A deferred message must survive a second call of the SAME run: the
%% function_call clause used to flush Pending unconditionally, splitting
%% the run. Order must also be preserved (append, never prepend).
deferred_text_survives_sibling_call_test() ->
    Msgs = to_chat([fc(<<"A">>), amsg(<<"mid">>), fc(<<"B">>), out(<<"A">>), out(<<"B">>)]),
    assert_adjacent(Msgs),
    ?assertEqual([<<"assistant">>, <<"tool">>, <<"tool">>, <<"assistant">>], roles(Msgs)),
    [_, _, _, TextMsg] = Msgs,
    ?assertEqual([<<"mid">>], texts([TextMsg])).

%% Several deferrals keep creation order.
two_deferred_messages_order_test() ->
    Msgs = to_chat([fc(<<"c1">>), amsg(<<"first">>), amsg(<<"second">>), out(<<"c1">>)]),
    assert_adjacent(Msgs),
    ?assertEqual([<<"assistant">>, <<"tool">>, <<"assistant">>, <<"assistant">>], roles(Msgs)),
    [_, _, M1, M2] = Msgs,
    ?assertEqual([<<"first">>], texts([M1])),
    ?assertEqual([<<"second">>], texts([M2])).

%% Two fully closed runs back to back: the function_call clause's
%% closed-run branch starts a NEW assistant message instead of merging
%% into the previous run.
sequential_closed_runs_test() ->
    Msgs = to_chat([umsg(<<"go">>), fc(<<"c1">>), out(<<"c1">>), fc(<<"c2">>), out(<<"c2">>)]),
    assert_adjacent(Msgs),
    ?assertEqual(
        [<<"user">>, <<"assistant">>, <<"tool">>, <<"assistant">>, <<"tool">>],
        roles(Msgs)
    ).

%% A deferred message flushed on a closed run must be CONSUMED: the
%% function_call clause used to carry the old Pending forward after
%% flushing it, emitting the text a second time.
deferred_message_consumed_on_flush_test() ->
    Msgs = to_chat([fc(<<"A">>), amsg(<<"deferred">>), out(<<"A">>), fc(<<"B">>), out(<<"B">>)]),
    assert_adjacent(Msgs),
    Flat = lists:flatten(texts(Msgs)),
    ?assertEqual(1, length([T || T <- Flat, T =:= <<"deferred">>])).

%% The anthropic leg must satisfy the same invariant via
%% tool_use/tool_result adjacency.
interleaved_text_to_anthropic_test() ->
    Map = #{
        <<"model">> => <<"m">>,
        <<"input">> => [umsg(<<"go">>), fc(<<"c1">>), amsg(<<"note">>), out(<<"c1">>)],
        <<"stream">> => false
    },
    {ok, Anth} = janus_protocol_translate:translate_request(
        openai_responses, anthropic_messages, Map
    ),
    Msgs = maps:get(<<"messages">>, Anth),
    assert_anth_adjacent(Msgs).

assert_anth_adjacent([]) ->
    ok;
assert_anth_adjacent([#{<<"role">> := <<"assistant">>, <<"content">> := Blocks} | Rest]) when
    is_list(Blocks)
->
    case [Id || #{<<"type">> := <<"tool_use">>, <<"id">> := Id} <- Blocks] of
        [] ->
            assert_anth_adjacent(Rest);
        Ids ->
            [#{<<"role">> := <<"user">>, <<"content">> := RB} | R2] = Rest,
            Res = [I || #{<<"type">> := <<"tool_result">>, <<"tool_use_id">> := I} <- RB],
            ?assertEqual(lists:sort(Ids), lists:sort(Res)),
            assert_anth_adjacent(R2)
    end;
assert_anth_adjacent([_ | Rest]) ->
    assert_anth_adjacent(Rest).
