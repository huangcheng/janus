%% Diagnosability of the gateway's own accumulator ceilings (2026-11-09).
%%
%% Live: a coding-agent turn died with `api_error: tool call accumulator cap
%% exceeded`. Four different limits shared that one string (per-call args,
%% calls per stream, total args, and the 4MiB content budget), and it was
%% reported with kind `upstream` — so the client saw a server fault, the usage
%% row was a 502, and a healthy provider got benched. "Which cap did I hit,
%% and how far over?" was answerable only by guessing.
%%
%% Two properties are pinned here:
%%
%%   1. Each tripped ceiling reports WHICH cap, the limit IN FORCE (it is
%%      hot-tunable, so not the shipped constant), and the observed value.
%%   2. A limit is not an upstream failure: the client-visible `type` is
%%      `limit_error`, distinguishable from the generic `api_error` that a
%%      stall or a translation gap still uses.
-module(janus_cap_diagnostics_tests).

-include_lib("eunit/include/eunit.hrl").

-define(KIND, <<"limit_error">>).

%% Names the SETTING, not just "a cap" — that is the actionable half.
per_call_text_names_the_setting_test() ->
    %% Pin the shipped defaults explicitly: cap_info/2 reads the hot
    %% `translate` row, so an empty config here is what makes the limit
    %% predictable rather than dependent on test ordering.
    with_cfg(#{}, fun() ->
        Info = janus_protocol_translate:cap_info(per_call, 300_000),
        Text = janus_protocol_translate:cap_error_text(tool_args_cap, Info),
        ?assert(binary:match(Text, <<"tool_args_per_call_cap">>) =/= nomatch),
        %% BOTH numbers matter and must be asserted separately: the LIMIT in
        %% force is what tells the operator which value is enforcing, the
        %% observed value how far over they are. (The shipped per-call cap is
        %% 262144, distinct from the 300000 used here, so a format string that
        %% dropped the limit would fail this.)
        #{limit := Limit} = Info,
        ?assertNotEqual(300_000, Limit),
        ?assert(binary:match(Text, integer_to_binary(Limit)) =/= nomatch),
        ?assert(binary:match(Text, integer_to_binary(300_000)) =/= nomatch)
    end).

calls_text_names_the_setting_test() ->
    Text = janus_protocol_translate:cap_error_text(
        tool_args_cap, janus_protocol_translate:cap_info(calls, 513)
    ),
    ?assert(binary:match(Text, <<"tool_calls_per_stream_cap">>) =/= nomatch),
    ?assert(binary:match(Text, <<"tool calls">>) =/= nomatch).

total_text_names_the_setting_test() ->
    Text = janus_protocol_translate:cap_error_text(
        tool_args_cap, janus_protocol_translate:cap_info(total, 1_048_577)
    ),
    ?assert(binary:match(Text, <<"tool_args_total_cap">>) =/= nomatch).

content_text_names_the_setting_test() ->
    with_cfg(#{}, fun() ->
        Text = janus_protocol_translate:cap_error_text(
            content_budget, janus_protocol_translate:cap_info(content, 4_194_305)
        ),
        %% Names the KNOB, like the tool_args_cap clause does — now that
        %% `stream_content_cap` is itself a dashboard setting, "the content
        %% budget" alone is still ambiguous in a usage row.
        ?assert(binary:match(Text, <<"stream_content_cap">>) =/= nomatch),
        %% The limit (4MiB shipped) and the observed value are distinct
        %% numbers, so assert both.
        ?assert(binary:match(Text, integer_to_binary(4 * 1024 * 1024)) =/= nomatch),
        ?assert(binary:match(Text, integer_to_binary(4_194_305)) =/= nomatch)
    end).

%% The limit reported is the one ACTUALLY in force, which after a hot raise is
%% not the shipped constant. Reporting the constant would send an operator to
%% check a setting that no longer holds the value shown.
limit_is_the_live_value_not_the_shipped_constant_test() ->
    Key = {janus, translate_cfg},
    Prev = persistent_term:get(Key, undefined),
    try
        persistent_term:put(Key, #{<<"tool_args_per_call_cap">> => 1_000_000}),
        #{limit := Limit} = janus_protocol_translate:cap_info(per_call, 1_000_001),
        ?assertEqual(1_000_000, Limit)
    after
        case Prev of
            undefined -> persistent_term:erase(Key);
            _ -> persistent_term:put(Key, Prev)
        end
    end.

%% A limit is not an upstream failure and not a request-shape error: it gets
%% its own type on the wire, so a client can tell "you hit a configured cap"
%% from "the gateway broke" and from "your request was malformed".
limit_has_its_own_error_type_test() ->
    ?assertEqual(?KIND, error_type_via_finalize(limit)),
    ?assertEqual(<<"invalid_request_error">>, error_type_via_finalize(invalid_request)),
    %% The generic default must NOT catch limits.
    ?assertNotEqual(?KIND, error_type_via_finalize(upstream)).

%% The type that reaches the client, taken from the real terminal frame rather
%% than from error_type/1 directly (which is not exported).
error_type_via_finalize(Kind) ->
    St = janus_protocol_translate:new_sse_st(1),
    {ok, Frames, _} = janus_protocol_translate:finalize_sse(
        openai_chat, {error, Kind, <<"boom">>}, St
    ),
    %% Frames are SSE (`data: {json}\n\n`), so pull the payload line out
    %% before decoding.
    Json = iolist_to_binary([
        Payload
     || F <- Frames,
        <<"data: ", Rest/binary>> <- [iolist_to_binary(F)],
        Payload <- [binary:part(Rest, 0, byte_size(Rest) - 2)],
        Payload =/= <<"[DONE]">>
    ]),
    {ok, Decoded} = thoas:decode(Json),
    #{<<"error">> := #{<<"type">> := Type}} = Decoded,
    Type.

%% The whole-stream content budget used to be a hardcoded 4MiB while the
%% dashboard allowed tool_args_total_cap up to 256MB. On the ->responses face
%% that made a raised args cap unreachable: resp_budget/2 stopped the stream at
%% the constant with nothing logged. The budget must follow the same hot
%% settings row so the two caps can be raised together.
content_cap_defaults_to_the_shipped_value_test() ->
    Key = {janus, translate_cfg},
    Prev = persistent_term:get(Key, undefined),
    try
        persistent_term:erase(Key),
        ?assertEqual(4 * 1024 * 1024, janus_protocol_translate:content_cap())
    after
        case Prev of
            undefined -> persistent_term:erase(Key);
            _ -> persistent_term:put(Key, Prev)
        end
    end.

content_cap_is_hot_tunable_test() ->
    Key = {janus, translate_cfg},
    Prev = persistent_term:get(Key, undefined),
    try
        persistent_term:put(Key, #{<<"stream_content_cap">> => 64 * 1024 * 1024}),
        ?assertEqual(64 * 1024 * 1024, janus_protocol_translate:content_cap()),
        %% And the reported limit follows it, so the error text names the
        %% value actually in force.
        #{limit := Limit} = janus_protocol_translate:cap_info(content, 1),
        ?assertEqual(64 * 1024 * 1024, Limit)
    after
        case Prev of
            undefined -> persistent_term:erase(Key);
            _ -> persistent_term:put(Key, Prev)
        end
    end.

%% Malformed values must not disable the ceiling: zero would cap every stream
%% at nothing, a non-integer would crash the fold on an arithmetic compare.
malformed_content_cap_falls_back_test() ->
    Key = {janus, translate_cfg},
    Prev = persistent_term:get(Key, undefined),
    try
        lists:foreach(
            fun(Bad) ->
                persistent_term:put(Key, #{<<"stream_content_cap">> => Bad}),
                ?assertEqual(4 * 1024 * 1024, janus_protocol_translate:content_cap())
            end,
            [0, -1, <<"nope">>, undefined]
        )
    after
        case Prev of
            undefined -> persistent_term:erase(Key);
            _ -> persistent_term:put(Key, Prev)
        end
    end.

%%%===================================================================
%%% Driving the real fold, not just the helpers
%%%
%%% The helpers could all pass while the failure PATH crashed: the mapper
%%% returns error tuples of two different arities, and the inner folds used to
%%% match a fixed arity, which turned a tripped ceiling into a function_clause
%%% instead of forwarding it. These tests trip real ceilings through
%%% translate_sse/4.
%%%===================================================================

with_cfg(Cfg, Fun) ->
    Key = {janus, translate_cfg},
    Prev = persistent_term:get(Key, undefined),
    try
        persistent_term:put(Key, Cfg),
        Fun()
    after
        case Prev of
            undefined -> persistent_term:erase(Key);
            _ -> persistent_term:put(Key, Prev)
        end
    end.

%% A content-budget trip on the ->responses text path must be RETURNED as the
%% 4-tuple, not raised.
content_budget_trips_as_a_returned_error_test() ->
    with_cfg(#{<<"stream_content_cap">> => 16}, fun() ->
        St = janus_protocol_translate:new_sse_st(1),
        Ev = #{
            type => <<"chunk">>,
            data => #{
                <<"choices">> => [
                    #{<<"index">> => 0, <<"delta">> => #{<<"content">> => <<"abcdefghijklmnopqrstuvwxyz">>}}
                ]
            }
        },
        Result = janus_protocol_translate:translate_sse(openai_responses, openai_chat, Ev, St),
        ?assertMatch({error, content_budget, #{cap := content}, _}, Result)
    end).

%% A calls-per-stream trip on the chat -> anthropic tool path must be RETURNED
%% as the 4-tuple, and must name the calls cap rather than the args cap.
calls_cap_trips_as_a_returned_error_test() ->
    with_cfg(#{<<"tool_calls_per_stream_cap">> => 1}, fun() ->
        St0 = janus_protocol_translate:new_sse_st(1),
        Open = fun(Idx) ->
            #{
                type => <<"chunk">>,
                data => #{
                    <<"choices">> => [
                        #{
                            <<"index">> => 0,
                            <<"delta">> => #{
                                <<"tool_calls">> => [
                                    #{
                                        <<"index">> => Idx,
                                        <<"id">> => <<"call_", (integer_to_binary(Idx))/binary>>,
                                        <<"function">> => #{<<"name">> => <<"f">>, <<"arguments">> => <<>>}
                                    }
                                ]
                            }
                        }
                    ]
                }
            }
        end,
        %% First call is allowed (capacity 1).
        ?assertMatch(
            {ok, _, _},
            janus_protocol_translate:translate_sse(anthropic_messages, openai_chat, Open(0), St0)
        ),
        %% Second call exceeds the cap.
        {ok, _, St1} = janus_protocol_translate:translate_sse(
            anthropic_messages, openai_chat, Open(0), St0
        ),
        Result = janus_protocol_translate:translate_sse(
            anthropic_messages, openai_chat, Open(1), St1
        ),
        ?assertMatch({error, tool_args_cap, #{cap := calls}, _}, Result)
    end).

%%%===================================================================
%%% The terminal-accounting contract for a tripped ceiling
%%%===================================================================

%% The wire status was committed as 200 before the ceiling fired, and a cap is
%% the GATEWAY's limit rather than a provider fault. Tracking 502 would both
%% contradict the status the client saw and bench a healthy provider — which is
%% what made a 1MiB args cap look like a sick upstream.
%%
%% SCOPE: this pins the CONTRACT the `{error, limit, Msg}` arm of
%% finish_translate_stream/5 consults, not the arm itself. That arm needs a
%% cowboy request to drive, so it is covered by the live matrix rather than
%% here — deleting the arm would still leave this test green.
limit_accounting_tracks_200_and_keeps_the_provider_test() ->
    {Status, BenchProvider} = janus_http_proxy:limit_terminal_accounting(),
    ?assertEqual(200, Status),
    ?assertEqual(false, BenchProvider).

%% A frame that never decoded into a map still yields a label, not the bytes —
%% the sentinel must be safe on every shape it can be handed.
non_map_frame_is_labelled_test() ->
    ?assertEqual(binary, janus_shape_capture:stream_frame_shape(<<"x">>)).

%% The calls ceiling must report the call that CROSSED it, not the number
%% already accepted (the guard is `>=`, so at the trip point the accepted count
%% equals the limit exactly). "allows 64, reached 64" reads as a bug when a
%% 65th call is what tripped it.
calls_cap_reports_the_offending_call_count_test() ->
    with_cfg(#{<<"tool_calls_per_stream_cap">> => 1}, fun() ->
        St0 = janus_protocol_translate:new_sse_st(1),
        Open = fun(Idx) ->
            #{
                type => <<"chunk">>,
                data => #{
                    <<"choices">> => [
                        #{
                            <<"index">> => 0,
                            <<"delta">> => #{
                                <<"tool_calls">> => [
                                    #{
                                        <<"index">> => Idx,
                                        <<"id">> => <<"c">>,
                                        <<"function">> => #{<<"name">> => <<"f">>, <<"arguments">> => <<>>}
                                    }
                                ]
                            }
                        }
                    ]
                }
            }
        end,
        {ok, _, St1} = janus_protocol_translate:translate_sse(
            anthropic_messages, openai_chat, Open(0), St0
        ),
        {error, tool_args_cap, CapInfo, _} = janus_protocol_translate:translate_sse(
            anthropic_messages, openai_chat, Open(1), St1
        ),
        %% limit 1, and the SECOND call is what exceeded it.
        ?assertMatch(#{cap := calls, limit := 1, used := 2}, CapInfo)
    end).

%% The rendering is derived from `cap`, so a mismatched kind argument cannot
%% crash it — both constructors and cap_error_text/2 are exported, so a future
%% call site can pair them wrongly. A crash here would surface as a generic 502
%% on the very path that exists to explain limits.
mismatched_kind_cannot_crash_or_misrender_test() ->
    %% Kind says content, info says total: still renders as an args cap.
    A = janus_protocol_translate:cap_error_text(
        content_budget, janus_protocol_translate:cap_info(total, 5)
    ),
    ?assert(binary:match(A, <<"tool_args_total_cap">>) =/= nomatch),
    %% Kind says args, info says content: still renders as the content budget.
    B = janus_protocol_translate:cap_error_text(
        tool_args_cap, janus_protocol_translate:cap_info(content, 5)
    ),
    ?assert(binary:match(B, <<"stream_content_cap">>) =/= nomatch).

%% Terminal frames pass the message through trunc_200/1, so a longer text is
%% cut MID-WORD and the actionable tail ("raise it or split the work") is what
%% gets lost — exactly the guidance this change exists to deliver. Every cap
%% message must therefore fit the wire budget in full, with realistic numbers
%% (the largest limits the dashboard permits, so the digits are widest).
cap_messages_fit_the_wire_budget_test() ->
    Wide = 268_435_456,
    Texts = [
        janus_protocol_translate:cap_error_text(
            tool_args_cap, #{cap => per_call, limit => 262_144, used => Wide}
        ),
        janus_protocol_translate:cap_error_text(
            tool_args_cap, #{cap => total, limit => Wide, used => Wide}
        ),
        janus_protocol_translate:cap_error_text(
            tool_args_cap, #{cap => calls, limit => 4096, used => 4097}
        ),
        janus_protocol_translate:cap_error_text(
            content_budget, #{cap => content, limit => Wide, used => Wide}
        )
    ],
    lists:foreach(
        fun(T) ->
            ?assert(byte_size(T) =< 200),
            %% And the advice survives, rather than being cut off.
            ?assert(binary:match(T, <<"raise">>) =/= nomatch orelse
                binary:match(T, <<"Raise">>) =/= nomatch)
        end,
        Texts
    ).
