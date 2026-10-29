%% Usage-synthesis unit (2026-10-24): provider dialects that report no
%% usable input token count (observed live: an anthropic-compatible
%% upstream zeroes message_start usage, surfacing verbatim as
%% prompt_tokens:0 on the chat face) get the request-side estimate in the
%% client's terminal usage, marked <<"janus_estimated">> => true. Real
%% upstream numbers always win and carry no flag.
-module(janus_translate_usage_est_tests).

-include_lib("eunit/include/eunit.hrl").
-include("janus_protocol_translate.hrl").

%% upstream gave real numbers -> passthrough, no flag
chat_usage_real_wins_test() ->
    St = (janus_protocol_translate:new_sse_st(1200))
        #sse_st{in_tokens = 16, out_tokens = 90},
    {[Frame], _} = janus_protocol_translate:chat_pending_usage(St),
    {ok, Chunk} = parse_frame(Frame),
    Usage = maps:get(<<"usage">>, Chunk),
    ?assertEqual(16, maps:get(<<"prompt_tokens">>, Usage)),
    ?assertEqual(90, maps:get(<<"completion_tokens">>, Usage)),
    ?assertNot(maps:is_key(<<"janus_estimated">>, Usage)).

%% the observed dialect: message_start carried input_tokens=0 -> estimate
chat_usage_zero_input_uses_est_test() ->
    St = (janus_protocol_translate:new_sse_st(1200))
        #sse_st{in_tokens = 0, out_tokens = 42},
    {[Frame], _} = janus_protocol_translate:chat_pending_usage(St),
    {ok, Chunk} = parse_frame(Frame),
    Usage = maps:get(<<"usage">>, Chunk),
    ?assertEqual(1200, maps:get(<<"prompt_tokens">>, Usage)),
    ?assertEqual(42, maps:get(<<"completion_tokens">>, Usage)),
    ?assertEqual(true, maps:get(<<"janus_estimated">>, Usage)).

%% nothing at all from upstream and no estimate configured -> chunk omitted
chat_usage_all_unknown_omitted_test() ->
    ?assertMatch({[], _}, janus_protocol_translate:chat_pending_usage(#sse_st{})).

%% estimate alone (upstream sent only output) still emits with the flag
chat_usage_est_only_input_test() ->
    St = (janus_protocol_translate:new_sse_st(64))#sse_st{out_tokens = 7},
    {[Frame], _} = janus_protocol_translate:chat_pending_usage(St),
    {ok, Chunk} = parse_frame(Frame),
    Usage = maps:get(<<"usage">>, Chunk),
    ?assertEqual(64, maps:get(<<"prompt_tokens">>, Usage)),
    ?assertEqual(true, maps:get(<<"janus_estimated">>, Usage)).

%% anthropic face: message_start input fills from the estimate when the
%% upstream has not spoken yet (chat providers report usage only at end)
anthropic_start_estimated_test() ->
    St = janus_protocol_translate:new_sse_st(300),
    {[Frame], _} = janus_protocol_translate:anthropic_ensure_start(#{}, St),
    {ok, Ev, Data} = parse_anthropic_frame(Frame),
    ?assertEqual(<<"message_start">>, Ev),
    Usage = maps:get(<<"usage">>, maps:get(<<"message">>, Data)),
    ?assertEqual(300, maps:get(<<"input_tokens">>, Usage)),
    ?assertEqual(true, maps:get(<<"janus_estimated">>, Usage)).

%% estimator: ASCII /4 + non-ASCII *3/4 over text content only
est_ascii_test() ->
    Map = #{<<"messages">> => [#{<<"role">> => <<"user">>,
                                 <<"content">> => binary:copy(<<"ab">>, 100)}]},
    ?assertEqual(50, janus_protocol_translate:est_prompt_tokens(openai_chat, Map)).

est_cjk_test() ->
    %% 12 non-ASCII bytes -> (12*3) div 4 = 9 tokens. The binary is built
    %% from explicit codepoints so the test never depends on this file's
    %% own encoding.
    Cjk = unicode:characters_to_binary([20320, 22909, 19990, 30028], utf8),
    ?assertEqual(12, byte_size(Cjk)),
    Map = #{<<"messages">> => [#{<<"content">> => Cjk}]},
    ?assertEqual(9, janus_protocol_translate:est_prompt_tokens(openai_chat, Map)).

est_responses_input_test() ->
    ?assertEqual(
        25,
        janus_protocol_translate:est_prompt_tokens(
            openai_responses, #{<<"input">> => binary:copy(<<"x">>, 100)}
        )
    ).

est_structured_content_test() ->
    Map = #{<<"messages">> => [
        #{<<"content">> => [
            #{<<"type">> => <<"text">>, <<"text">> => binary:copy(<<"y">>, 40)}
        ]}
    ]},
    ?assertEqual(10, janus_protocol_translate:est_prompt_tokens(anthropic_messages, Map)).

parse_frame(Frame) ->
    Data = iolist_to_binary(Frame),
    [<<"data: ", Json0/binary>> | _] = binary:split(Data, <<"\n">>),
    [Clean | _] = binary:split(Json0, <<"\r">>),
    thoas:decode(Clean).

parse_anthropic_frame(Frame) ->
    Data = iolist_to_binary(Frame),
    {match, [EvS, Json0]} = re:run(
        Data, <<"event: ([a-z_]+)\\ndata: (.*)\\n\\n">>, [{capture, all_but_first, binary}]
    ),
    {ok, Json} = thoas:decode(Json0),
    {ok, EvS, Json}.
