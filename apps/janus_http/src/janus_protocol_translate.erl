%%%-------------------------------------------------------------------
%%% @doc Pure request/response translation between OpenAI chat,
%%% OpenAI responses, and Anthropic messages. Fail-closed.
%%% Streaming (SSE) translate: sse_events/2 parser, translate_sse/4
%%% event mapper, finalize_sse/3 terminator — also pure; the handler
%%% (janus_http_proxy) owns gun/cowboy side effects.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_protocol_translate).

-include("janus_protocol_translate.hrl").

-export([
    normalize_protocol/1,
    wants_stream/1,
    translate_request/3,
    translate_response/3,
    default_max_tokens/0,
    %% Streaming translate (Slice A)
    new_sse_st/0,
    sse_events/2,
    translate_sse/4,
    finalize_sse/3,
    stream_translate_blocked/2
]).

-define(DEFAULT_MAX_TOKENS, 4096).

-type proto() :: openai_chat | openai_responses | anthropic_messages.

-spec normalize_protocol(term()) -> {ok, proto()} | {error, unknown_protocol}.
normalize_protocol(<<"openai_chat">>) -> {ok, openai_chat};
normalize_protocol(<<"openai_responses">>) -> {ok, openai_responses};
normalize_protocol(<<"anthropic_messages">>) -> {ok, anthropic_messages};
normalize_protocol(openai_chat) -> {ok, openai_chat};
normalize_protocol(openai_responses) -> {ok, openai_responses};
normalize_protocol(anthropic_messages) -> {ok, anthropic_messages};
normalize_protocol(undefined) -> {ok, openai_chat};
normalize_protocol(null) -> {ok, openai_chat};
normalize_protocol(_) -> {error, unknown_protocol}.

-spec wants_stream(map()) -> boolean().
wants_stream(Map) when is_map(Map) ->
    case maps:get(<<"stream">>, Map, false) of
        true -> true;
        <<"true">> -> true;
        _ -> false
    end.

-spec default_max_tokens() -> pos_integer().
default_max_tokens() ->
    case os:getenv("JANUS_ANTHROPIC_DEFAULT_MAX_TOKENS") of
        false ->
            ?DEFAULT_MAX_TOKENS;
        "" ->
            ?DEFAULT_MAX_TOKENS;
        Val ->
            try
                N = list_to_integer(Val),
                case N > 0 of
                    true -> N;
                    false -> ?DEFAULT_MAX_TOKENS
                end
            catch
                _:_ -> ?DEFAULT_MAX_TOKENS
            end
    end.

chat_max_tokens(Map) ->
    case maps:get(<<"max_completion_tokens">>, Map, undefined) of
        N when is_integer(N), N > 0 -> N;
        _ -> maps:get(<<"max_tokens">>, Map, default_max_tokens())
    end.

%%--------------------------------------------------------------------
%% Request translation
%%--------------------------------------------------------------------

-spec translate_request(proto(), proto(), map()) ->
    {ok, map()} | {error, {translate_unsupported, binary()}}.
translate_request(P, P, Map) ->
    {ok, Map};
translate_request(Client, Provider, Map) ->
    case reject_unsupported_request(Client, Map) of
        ok ->
            case do_translate_request(Client, Provider, Map) of
                {ok, _} = Ok -> Ok;
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.

do_translate_request(openai_chat, anthropic_messages, Map) ->
    chat_to_messages(Map);
do_translate_request(anthropic_messages, openai_chat, Map) ->
    messages_to_chat(Map);
do_translate_request(openai_chat, openai_responses, Map) ->
    chat_to_responses(Map);
do_translate_request(openai_responses, openai_chat, Map) ->
    responses_to_chat(Map);
do_translate_request(anthropic_messages, openai_responses, Map) ->
    case messages_to_chat(Map) of
        {ok, Chat} -> chat_to_responses(Chat);
        {error, _} = Err -> Err
    end;
do_translate_request(openai_responses, anthropic_messages, Map) ->
    case responses_to_chat(Map) of
        {ok, Chat} -> chat_to_messages(Chat);
        {error, _} = Err -> Err
    end;
do_translate_request(_, _, _) ->
    {error, {translate_unsupported, <<"unsupported protocol pair">>}}.

reject_unsupported_request(openai_responses, Map) ->
    Prev = maps:get(<<"previous_response_id">>, Map, undefined),
    case Prev =/= undefined andalso Prev =/= null of
        true ->
            {error, {translate_unsupported, <<"previous_response_id not supported">>}};
        false ->
            case maps:get(<<"background">>, Map, false) of
                true ->
                    {error, {translate_unsupported, <<"background responses not supported">>}};
                _ ->
                    reject_vision(Map)
            end
    end;
reject_unsupported_request(_, Map) ->
    case maps:get(<<"n">>, Map, 1) of
        1 -> reject_vision(Map);
        undefined -> reject_vision(Map);
        null -> reject_vision(Map);
        _ -> {error, {translate_unsupported, <<"n>1 not supported">>}}
    end.

reject_vision(Map) ->
    case has_non_text_content(Map) of
        true ->
            {error, {translate_unsupported, <<"vision/multimodal content not supported">>}};
        false ->
            ok
    end.

has_non_text_content(Map) ->
    lists:any(
        fun(Key) ->
            case maps:get(Key, Map, undefined) of
                undefined -> false;
                null -> false;
                V -> content_has_non_text(V)
            end
        end,
        [<<"messages">>, <<"input">>, <<"content">>]
    ).

content_has_non_text(Bin) when is_binary(Bin) ->
    false;
content_has_non_text(List) when is_list(List) ->
    lists:any(fun part_non_text/1, List);
content_has_non_text(_) ->
    false.

part_non_text(#{<<"type">> := <<"text">>}) ->
    false;
part_non_text(#{<<"type">> := <<"input_text">>}) ->
    false;
part_non_text(#{<<"type">> := <<"output_text">>}) ->
    false;
part_non_text(#{<<"type">> := <<"tool_use">>}) ->
    false;
part_non_text(#{<<"type">> := <<"tool_result">>}) ->
    false;
part_non_text(#{<<"type">> := <<"function">>}) ->
    false;
part_non_text(#{<<"role">> := _, <<"content">> := C}) ->
    content_has_non_text(C);
part_non_text(#{<<"type">> := <<"message">>, <<"content">> := C}) ->
    content_has_non_text(C);
part_non_text(#{<<"type">> := _}) ->
    true;
part_non_text(M) when is_map(M) ->
    false;
part_non_text(_) ->
    false.

%%--------------------------------------------------------------------
%% chat -> messages
%%--------------------------------------------------------------------

chat_to_messages(Map) ->
    Msgs0 = maps:get(<<"messages">>, Map, []),
    case is_list(Msgs0) of
        false ->
            {error, {translate_unsupported, <<"messages must be a list">>}};
        true ->
            case split_system(Msgs0) of
                {error, _} = Err ->
                    Err;
                {System, Msgs} ->
                    case convert_chat_messages(Msgs) of
                        {ok, AMsgs} ->
                            Model = maps:get(<<"model">>, Map),
                            MaxTok = chat_max_tokens(Map),
                            Out0 = #{
                                <<"model">> => Model,
                                <<"messages">> => AMsgs,
                                <<"max_tokens">> => MaxTok,
                                <<"stream">> => false
                            },
                            Out1 =
                                case System of
                                    undefined -> Out0;
                                    S -> Out0#{<<"system">> => S}
                                end,
                            Out2 = copy_if(Map, Out1, <<"temperature">>),
                            Out3 = copy_if(Map, Out2, <<"top_p">>),
                            Out4 =
                                case maps:get(<<"stop">>, Map, undefined) of
                                    undefined -> Out3;
                                    null -> Out3;
                                    Stop when is_binary(Stop) -> Out3#{<<"stop_sequences">> => [Stop]};
                                    Stop when is_list(Stop) -> Out3#{<<"stop_sequences">> => Stop};
                                    _ -> Out3
                                end,
                            case maps:get(<<"tools">>, Map, undefined) of
                                undefined ->
                                    {ok, maybe_tool_choice(Map, Out4)};
                                null ->
                                    {ok, maybe_tool_choice(Map, Out4)};
                                Tools when is_list(Tools) ->
                                    case convert_openai_tools(Tools) of
                                        {ok, ATools} ->
                                            {ok, maybe_tool_choice(Map, Out4#{<<"tools">> => ATools})};
                                        {error, _} = Err ->
                                            Err
                                    end;
                                _ ->
                                    {error, {translate_unsupported, <<"invalid tools">>}}
                            end;
                        {error, _} = Err ->
                            Err
                    end
            end
    end.

split_system(Msgs) ->
    {Sys, Rest} = lists:partition(
        fun
            (#{<<"role">> := <<"system">>}) -> true;
            (#{<<"role">> := <<"developer">>}) -> true;
            (_) -> false
        end,
        Msgs
    ),
    case Sys of
        [] ->
            {undefined, Rest};
        _ ->
            Texts = [msg_text(M) || M <- Sys],
            case lists:any(fun(E) -> E =:= error end, Texts) of
                true ->
                    {error, {translate_unsupported, <<"system content must be text">>}};
                false ->
                    {iolist_to_binary(lists:join(<<"\n\n">>, Texts)), Rest}
            end
    end.

msg_text(#{<<"content">> := C}) when is_binary(C) ->
    C;
msg_text(#{<<"content">> := null}) ->
    <<>>;
msg_text(#{<<"content">> := List}) when is_list(List) ->
    case flatten_text_parts(List) of
        {ok, T} -> T;
        error -> error
    end;
msg_text(_) ->
    error.

flatten_text_parts(Parts) ->
    try
        Bin = iolist_to_binary([
            case P of
                #{<<"type">> := <<"text">>, <<"text">> := T} when is_binary(T) -> T;
                B when is_binary(B) -> B;
                _ -> throw(bad)
            end
         || P <- Parts
        ]),
        {ok, Bin}
    catch
        _:_ -> error
    end.

convert_chat_messages(Msgs) ->
    convert_chat_messages(Msgs, []).

convert_chat_messages([], Acc) ->
    {ok, lists:reverse(Acc)};
convert_chat_messages([#{<<"role">> := <<"tool">>} = M | Rest], Acc) ->
    case tool_result_block(M) of
        {ok, Block} ->
            %% Anthropic: tool_result lives in a user message.
            case Acc of
                [#{<<"role">> := <<"user">>, <<"content">> := C} = U | AccRest] when is_list(C) ->
                    convert_chat_messages(Rest, [U#{<<"content">> => C ++ [Block]} | AccRest]);
                _ ->
                    convert_chat_messages(Rest, [
                        #{<<"role">> => <<"user">>, <<"content">> => [Block]} | Acc
                    ])
            end;
        {error, _} = Err ->
            Err
    end;
convert_chat_messages([#{<<"role">> := <<"assistant">>} = M | Rest], Acc) ->
    case assistant_to_anthropic(M) of
        {ok, AMsg} -> convert_chat_messages(Rest, [AMsg | Acc]);
        {error, _} = Err -> Err
    end;
convert_chat_messages([#{<<"role">> := <<"user">>} = M | Rest], Acc) ->
    case user_to_anthropic(M) of
        {ok, AMsg} -> convert_chat_messages(Rest, [AMsg | Acc]);
        {error, _} = Err -> Err
    end;
convert_chat_messages([#{<<"role">> := Role} | _], _) ->
    {error, {translate_unsupported, <<"unsupported role: ", Role/binary>>}};
convert_chat_messages([_ | _], _) ->
    {error, {translate_unsupported, <<"invalid message">>}}.

user_to_anthropic(#{<<"content">> := C}) when is_binary(C) ->
    {ok, #{<<"role">> => <<"user">>, <<"content">> => C}};
user_to_anthropic(#{<<"content">> := List}) when is_list(List) ->
    case flatten_text_parts(List) of
        {ok, T} -> {ok, #{<<"role">> => <<"user">>, <<"content">> => T}};
        error -> {error, {translate_unsupported, <<"user content must be text">>}}
    end;
user_to_anthropic(_) ->
    {error, {translate_unsupported, <<"invalid user message">>}}.

assistant_to_anthropic(M) ->
    Content0 =
        case maps:get(<<"content">>, M, null) of
            null -> [];
            undefined -> [];
            <<>> -> [];
            C when is_binary(C) -> [#{<<"type">> => <<"text">>, <<"text">> => C}];
            List when is_list(List) ->
                case flatten_text_parts(List) of
                    {ok, T} when T =/= <<>> -> [#{<<"type">> => <<"text">>, <<"text">> => T}];
                    {ok, <<>>} -> [];
                    error -> bad
                end;
            _ ->
                bad
        end,
    case Content0 of
        bad ->
            {error, {translate_unsupported, <<"assistant content must be text">>}};
        TextParts ->
            case maps:get(<<"tool_calls">>, M, undefined) of
                undefined ->
                    {ok, #{<<"role">> => <<"assistant">>, <<"content">> => TextParts}};
                null ->
                    {ok, #{<<"role">> => <<"assistant">>, <<"content">> => TextParts}};
                ToolCalls when is_list(ToolCalls) ->
                    case openai_tool_calls_to_blocks(ToolCalls) of
                        {ok, Blocks} ->
                            {ok, #{<<"role">> => <<"assistant">>, <<"content">> => TextParts ++ Blocks}};
                        {error, _} = Err ->
                            Err
                    end;
                _ ->
                    {error, {translate_unsupported, <<"invalid tool_calls">>}}
            end
    end.

openai_tool_calls_to_blocks(Calls) ->
    openai_tool_calls_to_blocks(Calls, []).

openai_tool_calls_to_blocks([], Acc) ->
    {ok, lists:reverse(Acc)};
openai_tool_calls_to_blocks(
    [
        #{
            <<"id">> := Id,
            <<"function">> := #{<<"name">> := Name, <<"arguments">> := Args}
        }
        | Rest
    ],
    Acc
) when is_binary(Id), is_binary(Name), is_binary(Args) ->
    case thoas:decode(Args) of
        {ok, Input} when is_map(Input) ->
            Block = #{
                <<"type">> => <<"tool_use">>,
                <<"id">> => Id,
                <<"name">> => Name,
                <<"input">> => Input
            },
            openai_tool_calls_to_blocks(Rest, [Block | Acc]);
        {ok, _} ->
            {error, {translate_unsupported, <<"tool arguments must be a JSON object">>}};
        {error, _} ->
            {error, {translate_unsupported, <<"malformed tool arguments JSON">>}}
    end;
openai_tool_calls_to_blocks(_, _) ->
    {error, {translate_unsupported, <<"invalid tool_call shape">>}}.

tool_result_block(#{<<"tool_call_id">> := Id, <<"content">> := C}) when is_binary(Id) ->
    Content =
        case C of
            B when is_binary(B) -> B;
            null -> <<>>;
            List when is_list(List) ->
                case flatten_text_parts(List) of
                    {ok, T} -> T;
                    error -> bad
                end;
            _ ->
                bad
        end,
    case Content of
        bad ->
            {error, {translate_unsupported, <<"tool result content must be text">>}};
        Text ->
            {ok, #{
                <<"type">> => <<"tool_result">>,
                <<"tool_use_id">> => Id,
                <<"content">> => Text
            }}
    end;
tool_result_block(_) ->
    {error, {translate_unsupported, <<"invalid tool message">>}}.

convert_openai_tools(Tools) ->
    convert_openai_tools(Tools, []).

convert_openai_tools([], Acc) ->
    {ok, lists:reverse(Acc)};
convert_openai_tools(
    [#{<<"type">> := <<"function">>, <<"function">> := #{<<"name">> := Name} = Fn} | Rest],
    Acc
) when is_binary(Name) ->
    Tool = #{
        <<"name">> => Name,
        <<"description">> => maps:get(<<"description">>, Fn, <<>>),
        <<"input_schema">> => maps:get(<<"parameters">>, Fn, #{
            <<"type">> => <<"object">>, <<"properties">> => #{}
        })
    },
    convert_openai_tools(Rest, [Tool | Acc]);
convert_openai_tools(_, _) ->
    {error, {translate_unsupported, <<"unsupported tool definition">>}}.

maybe_tool_choice(Map, Out) ->
    case maps:get(<<"tool_choice">>, Map, undefined) of
        undefined -> Out;
        null -> Out;
        <<"auto">> -> Out#{<<"tool_choice">> => #{<<"type">> => <<"auto">>}};
        <<"none">> -> Out#{<<"tool_choice">> => #{<<"type">> => <<"none">>}};
        <<"required">> -> Out#{<<"tool_choice">> => #{<<"type">> => <<"any">>}};
        #{<<"type">> := <<"function">>, <<"function">> := #{<<"name">> := N}} when is_binary(N) ->
            Out#{<<"tool_choice">> => #{<<"type">> => <<"tool">>, <<"name">> => N}};
        _ ->
            Out
    end.

%%--------------------------------------------------------------------
%% messages -> chat
%%--------------------------------------------------------------------

messages_to_chat(Map) ->
    case maps:get(<<"messages">>, Map, undefined) of
        Msgs when is_list(Msgs) ->
            case convert_anthropic_messages(Msgs) of
                {ok, ChatMsgs0} ->
                    ChatMsgs =
                        case maps:get(<<"system">>, Map, undefined) of
                            undefined -> ChatMsgs0;
                            null -> ChatMsgs0;
                            Sys when is_binary(Sys) ->
                                [#{<<"role">> => <<"system">>, <<"content">> => Sys} | ChatMsgs0];
                            Sys when is_list(Sys) ->
                                case flatten_text_parts(Sys) of
                                    {ok, T} ->
                                        [#{<<"role">> => <<"system">>, <<"content">> => T} | ChatMsgs0];
                                    error ->
                                        ChatMsgs0
                                end;
                            _ ->
                                ChatMsgs0
                        end,
                    Out0 = #{
                        <<"model">> => maps:get(<<"model">>, Map),
                        <<"messages">> => ChatMsgs,
                        <<"stream">> => false
                    },
                    Out1 = copy_if(Map, Out0, <<"temperature">>),
                    Out2 = copy_if(Map, Out1, <<"top_p">>),
                    Out3 =
                        case maps:get(<<"max_tokens">>, Map, undefined) of
                            undefined -> Out2;
                            null -> Out2;
                            MT -> Out2#{<<"max_tokens">> => MT}
                        end,
                    Out4 =
                        case maps:get(<<"stop_sequences">>, Map, undefined) of
                            undefined -> Out3;
                            null -> Out3;
                            Stop -> Out3#{<<"stop">> => Stop}
                        end,
                    case maps:get(<<"tools">>, Map, undefined) of
                        undefined ->
                            {ok, maybe_openai_tool_choice(Map, Out4)};
                        null ->
                            {ok, maybe_openai_tool_choice(Map, Out4)};
                        Tools when is_list(Tools) ->
                            case convert_anthropic_tools(Tools) of
                                {ok, OTools} ->
                                    {ok, maybe_openai_tool_choice(Map, Out4#{<<"tools">> => OTools})};
                                {error, _} = Err ->
                                    Err
                            end;
                        _ ->
                            {error, {translate_unsupported, <<"invalid tools">>}}
                    end;
                {error, _} = Err ->
                    Err
            end;
        _ ->
            {error, {translate_unsupported, <<"messages must be a list">>}}
    end.

convert_anthropic_messages(Msgs) ->
    convert_anthropic_messages(Msgs, []).

convert_anthropic_messages([], Acc) ->
    {ok, lists:reverse(Acc)};
convert_anthropic_messages([#{<<"role">> := <<"user">>, <<"content">> := C} | Rest], Acc) ->
    case expand_user_content(C, Acc) of
        {ok, Acc2} -> convert_anthropic_messages(Rest, Acc2);
        {error, _} = Err -> Err
    end;
convert_anthropic_messages([#{<<"role">> := <<"assistant">>, <<"content">> := C} | Rest], Acc) ->
    case assistant_from_anthropic(C) of
        {ok, Msg} -> convert_anthropic_messages(Rest, [Msg | Acc]);
        {error, _} = Err -> Err
    end;
convert_anthropic_messages([#{<<"role">> := Role} | _], _) ->
    {error, {translate_unsupported, <<"unsupported role: ", Role/binary>>}};
convert_anthropic_messages(_, _) ->
    {error, {translate_unsupported, <<"invalid message">>}}.

expand_user_content(C, Acc) when is_binary(C) ->
    {ok, [#{<<"role">> => <<"user">>, <<"content">> => C} | Acc]};
expand_user_content(List, Acc) when is_list(List) ->
    expand_user_parts(List, Acc, []);
expand_user_content(_, _) ->
    {error, {translate_unsupported, <<"invalid user content">>}}.

expand_user_parts([], Acc, TextAcc) ->
    case TextAcc of
        [] ->
            {ok, Acc};
        _ ->
            Text = iolist_to_binary(lists:reverse(TextAcc)),
            {ok, [#{<<"role">> => <<"user">>, <<"content">> => Text} | Acc]}
    end;
expand_user_parts([#{<<"type">> := <<"text">>, <<"text">> := T} | Rest], Acc, TextAcc) when
    is_binary(T)
->
    expand_user_parts(Rest, Acc, [T | TextAcc]);
expand_user_parts(
    [#{<<"type">> := <<"tool_result">>, <<"tool_use_id">> := Id, <<"content">> := C} | Rest],
    Acc,
    TextAcc
) ->
    Acc1 =
        case TextAcc of
            [] -> Acc;
            _ ->
                Text = iolist_to_binary(lists:reverse(TextAcc)),
                [#{<<"role">> => <<"user">>, <<"content">> => Text} | Acc]
        end,
    Content =
        case C of
            B when is_binary(B) -> B;
            L when is_list(L) ->
                case flatten_text_parts(L) of
                    {ok, T} -> T;
                    error -> <<>>
                end;
            _ ->
                <<>>
        end,
    ToolMsg = #{
        <<"role">> => <<"tool">>,
        <<"tool_call_id">> => Id,
        <<"content">> => Content
    },
    expand_user_parts(Rest, [ToolMsg | Acc1], []);
expand_user_parts([#{<<"type">> := _} | _], _, _) ->
    {error, {translate_unsupported, <<"vision/multimodal content not supported">>}};
expand_user_parts(_, _, _) ->
    {error, {translate_unsupported, <<"invalid content part">>}}.

assistant_from_anthropic(C) when is_binary(C) ->
    {ok, #{<<"role">> => <<"assistant">>, <<"content">> => C}};
assistant_from_anthropic(List) when is_list(List) ->
    %% The try must wrap the FOLD itself: the throw(bad_*) clauses fire
    %% inside lists:foldl, so a catch around the post-fold construction
    %% never sees them (a thinking block used to crash the proxy here).
    try
        {Texts, Reasons, ToolCalls} = lists:foldl(
            fun
                (#{<<"type">> := <<"text">>, <<"text">> := T}, {Ts, Rs, Cs}) when is_binary(T) ->
                    {[T | Ts], Rs, Cs};
                %% Thinking models (Kimi, MiniMax, …): surface the text
                %% reasoning as the OpenAI-style reasoning_content field
                %% (same shape DeepSeek/StepFun emit natively). Encrypted
                %% or non-text thinking payloads are skipped.
                (#{<<"type">> := <<"thinking">>, <<"thinking">> := R}, {Ts, Rs, Cs}) when
                    is_binary(R)
                ->
                    {Ts, [R | Rs], Cs};
                (#{<<"type">> := <<"thinking">>}, Acc) ->
                    Acc;
                (
                    #{<<"type">> := <<"tool_use">>, <<"id">> := Id, <<"name">> := Name, <<"input">> := Input},
                    {Ts, Rs, Cs}
                ) when is_binary(Id), is_binary(Name), is_map(Input) ->
                    Args = iolist_to_binary(thoas:encode(Input)),
                    Call = #{
                        <<"id">> => Id,
                        <<"type">> => <<"function">>,
                        <<"function">> => #{<<"name">> => Name, <<"arguments">> => Args}
                    },
                    {Ts, Rs, [Call | Cs]};
                (#{<<"type">> := <<"tool_use">>}, _) ->
                    throw(bad_tool);
                (#{<<"type">> := _}, _) ->
                    throw(bad_part);
                (_, Acc) ->
                    Acc
            end,
            {[], [], []},
            List
        ),
        Msg0 = #{<<"role">> => <<"assistant">>, <<"content">> => iolist_to_binary(lists:reverse(Texts))},
        Msg1 =
            case Reasons of
                [] -> Msg0;
                _ -> Msg0#{<<"reasoning_content">> => iolist_to_binary(lists:reverse(Reasons))}
            end,
        case lists:reverse(ToolCalls) of
            [] -> {ok, Msg1};
            Calls -> {ok, Msg1#{<<"tool_calls">> => Calls}}
        end
    catch
        throw:bad_tool -> {error, {translate_unsupported, <<"invalid tool_use">>}};
        throw:bad_part -> {error, {translate_unsupported, <<"vision/multimodal content not supported">>}}
    end;
assistant_from_anthropic(_) ->
    {error, {translate_unsupported, <<"invalid assistant content">>}}.

convert_anthropic_tools(Tools) ->
    convert_anthropic_tools(Tools, []).

convert_anthropic_tools([], Acc) ->
    {ok, lists:reverse(Acc)};
convert_anthropic_tools([#{<<"name">> := Name} = T | Rest], Acc) when is_binary(Name) ->
    Fn = #{
        <<"name">> => Name,
        <<"description">> => maps:get(<<"description">>, T, <<>>),
        <<"parameters">> => maps:get(<<"input_schema">>, T, #{
            <<"type">> => <<"object">>, <<"properties">> => #{}
        })
    },
    convert_anthropic_tools(Rest, [
        #{<<"type">> => <<"function">>, <<"function">> => Fn} | Acc
    ]);
convert_anthropic_tools(_, _) ->
    {error, {translate_unsupported, <<"unsupported tool definition">>}}.

maybe_openai_tool_choice(Map, Out) ->
    case maps:get(<<"tool_choice">>, Map, undefined) of
        undefined -> Out;
        null -> Out;
        #{<<"type">> := <<"auto">>} -> Out#{<<"tool_choice">> => <<"auto">>};
        #{<<"type">> := <<"none">>} -> Out#{<<"tool_choice">> => <<"none">>};
        #{<<"type">> := <<"any">>} -> Out#{<<"tool_choice">> => <<"required">>};
        #{<<"type">> := <<"tool">>, <<"name">> := N} when is_binary(N) ->
            Out#{
                <<"tool_choice">> => #{
                    <<"type">> => <<"function">>,
                    <<"function">> => #{<<"name">> => N}
                }
            };
        _ ->
            Out
    end.

%%--------------------------------------------------------------------
%% chat <-> responses
%%--------------------------------------------------------------------

chat_to_responses(Map) ->
    Msgs = maps:get(<<"messages">>, Map, []),
    case is_list(Msgs) of
        false ->
            {error, {translate_unsupported, <<"messages must be a list">>}};
        true ->
            {Instructions, InputMsgs} = split_system_for_responses(Msgs),
            case chat_msgs_to_input(InputMsgs) of
                {ok, Input} ->
                    Out0 = #{
                        <<"model">> => maps:get(<<"model">>, Map),
                        <<"input">> => Input,
                        <<"stream">> => false,
                        <<"store">> => false
                    },
                    Out1 =
                        case Instructions of
                            undefined -> Out0;
                            I -> Out0#{<<"instructions">> => I}
                        end,
                    Out2 =
                        case maps:get(<<"max_tokens">>, Map, undefined) of
                            undefined -> Out1;
                            null -> Out1;
                            MT -> Out1#{<<"max_output_tokens">> => MT}
                        end,
                    Out3 = copy_if(Map, Out2, <<"temperature">>),
                    Out4 = copy_if(Map, Out3, <<"top_p">>),
                    case maps:get(<<"tools">>, Map, undefined) of
                        undefined ->
                            {ok, Out4};
                        null ->
                            {ok, Out4};
                        Tools when is_list(Tools) ->
                            {ok, Out4#{<<"tools">> => Tools}};
                        _ ->
                            {error, {translate_unsupported, <<"invalid tools">>}}
                    end;
                {error, _} = Err ->
                    Err
            end
    end.

split_system_for_responses(Msgs) ->
    {Sys, Rest} = lists:partition(
        fun
            (#{<<"role">> := <<"system">>}) -> true;
            (#{<<"role">> := <<"developer">>}) -> true;
            (_) -> false
        end,
        Msgs
    ),
    case Sys of
        [] ->
            {undefined, Rest};
        _ ->
            Texts = [msg_text(M) || M <- Sys],
            case lists:any(fun(E) -> E =:= error end, Texts) of
                true -> {undefined, Rest};
                false -> {iolist_to_binary(lists:join(<<"\n\n">>, Texts)), Rest}
            end
    end.

chat_msgs_to_input(Msgs) ->
    chat_msgs_to_input(Msgs, []).

chat_msgs_to_input([], Acc) ->
    {ok, lists:reverse(Acc)};
chat_msgs_to_input([#{<<"role">> := <<"tool">>} = M | Rest], Acc) ->
    Id = maps:get(<<"tool_call_id">>, M, <<>>),
    Content = maps:get(<<"content">>, M, <<>>),
    Item = #{
        <<"type">> => <<"function_call_output">>,
        <<"call_id">> => Id,
        <<"output">> =>
            case Content of
                B when is_binary(B) -> B;
                _ -> <<>>
            end
    },
    chat_msgs_to_input(Rest, [Item | Acc]);
chat_msgs_to_input([#{<<"role">> := Role, <<"content">> := C} = M | Rest], Acc) when
    Role =:= <<"user">>; Role =:= <<"assistant">>
->
    case maps:get(<<"tool_calls">>, M, undefined) of
        ToolCalls when is_list(ToolCalls), ToolCalls =/= [] ->
            case openai_tool_calls_to_response_items(ToolCalls, C) of
                {ok, Items} -> chat_msgs_to_input(Rest, lists:reverse(Items) ++ Acc);
                {error, _} = Err -> Err
            end;
        _ ->
            case content_as_text(C) of
                {ok, OkText} ->
                    Item = #{
                        <<"type">> => <<"message">>,
                        <<"role">> => Role,
                        <<"content">> => [#{<<"type">> => <<"input_text">>, <<"text">> => OkText}]
                    },
                    chat_msgs_to_input(Rest, [Item | Acc]);
                error ->
                    {error, {translate_unsupported, <<"message content must be text">>}}
            end
    end;
chat_msgs_to_input(_, _) ->
    {error, {translate_unsupported, <<"unsupported chat message for responses">>}}.

openai_tool_calls_to_response_items(Calls, Content) ->
    Text =
        case Content of
            B when is_binary(B) -> B;
            null -> <<>>;
            _ -> <<>>
        end,
    Items0 =
        case Text of
            <<>> -> [];
            T ->
                [
                    #{
                        <<"type">> => <<"message">>,
                        <<"role">> => <<"assistant">>,
                        <<"content">> => [#{<<"type">> => <<"output_text">>, <<"text">> => T}]
                    }
                ]
        end,
    try
        Items1 = Items0 ++ [
            begin
                #{
                    <<"id">> := Id,
                    <<"function">> := #{<<"name">> := Name, <<"arguments">> := Args}
                } = Call,
                #{
                    <<"type">> => <<"function_call">>,
                    <<"call_id">> => Id,
                    <<"name">> => Name,
                    <<"arguments">> => Args
                }
            end
         || Call <- Calls
        ],
        {ok, Items1}
    catch
        _:_ -> {error, {translate_unsupported, <<"invalid tool_calls for responses">>}}
    end.

responses_to_chat(Map) ->
    case maps:is_key(<<"previous_response_id">>, Map) andalso
        maps:get(<<"previous_response_id">>, Map, undefined) =/= undefined andalso
        maps:get(<<"previous_response_id">>, Map, undefined) =/= null
    of
        true ->
            {error, {translate_unsupported, <<"previous_response_id not supported">>}};
        false ->
            case maps:get(<<"background">>, Map, false) of
                true ->
                    {error, {translate_unsupported, <<"background responses not supported">>}};
                _ ->
                    Input = maps:get(<<"input">>, Map, []),
                    case input_to_chat_messages(Input) of
                        {ok, Msgs0} ->
                            Msgs =
                                case maps:get(<<"instructions">>, Map, undefined) of
                                    undefined -> Msgs0;
                                    null -> Msgs0;
                                    Inst when is_binary(Inst) ->
                                        [#{<<"role">> => <<"system">>, <<"content">> => Inst} | Msgs0];
                                    _ ->
                                        Msgs0
                                end,
                            Out0 = #{
                                <<"model">> => maps:get(<<"model">>, Map),
                                <<"messages">> => Msgs,
                                <<"stream">> => false
                            },
                            Out1 =
                                case maps:get(<<"max_output_tokens">>, Map, undefined) of
                                    undefined -> Out0;
                                    null -> Out0;
                                    MT -> Out0#{<<"max_tokens">> => MT}
                                end,
                            Out2 = copy_if(Map, Out1, <<"temperature">>),
                            Out3 = copy_if(Map, Out2, <<"top_p">>),
                            case maps:get(<<"tools">>, Map, undefined) of
                                undefined -> {ok, Out3};
                                null -> {ok, Out3};
                                Tools when is_list(Tools) -> {ok, Out3#{<<"tools">> => Tools}};
                                _ -> {error, {translate_unsupported, <<"invalid tools">>}}
                            end;
                        {error, _} = Err ->
                            Err
                    end
            end
    end.

input_to_chat_messages(Bin) when is_binary(Bin) ->
    {ok, [#{<<"role">> => <<"user">>, <<"content">> => Bin}]};
input_to_chat_messages(List) when is_list(List) ->
    input_items_to_chat(List, []);
input_to_chat_messages(_) ->
    {error, {translate_unsupported, <<"invalid responses input">>}}.

input_items_to_chat([], Acc) ->
    {ok, lists:reverse(Acc)};
input_items_to_chat([#{<<"type">> := <<"message">>, <<"role">> := Role, <<"content">> := C} | Rest], Acc) ->
    case flatten_response_content(C) of
        {ok, Text} ->
            input_items_to_chat(Rest, [#{<<"role">> => Role, <<"content">> => Text} | Acc]);
        {error, _} = Err ->
            Err
    end;
input_items_to_chat(
    [#{<<"type">> := <<"function_call">>, <<"call_id">> := Id, <<"name">> := Name, <<"arguments">> := Args} | Rest],
    Acc
) ->
    %% Attach as assistant tool_calls; merge with previous assistant if present.
    Call = #{
        <<"id">> => Id,
        <<"type">> => <<"function">>,
        <<"function">> => #{<<"name">> => Name, <<"arguments">> => Args}
    },
    case Acc of
        [#{<<"role">> := <<"assistant">>} = A | AccRest] ->
            Calls = maps:get(<<"tool_calls">>, A, []) ++ [Call],
            input_items_to_chat(Rest, [A#{<<"tool_calls">> => Calls} | AccRest]);
        _ ->
            Msg = #{<<"role">> => <<"assistant">>, <<"content">> => <<>>, <<"tool_calls">> => [Call]},
            input_items_to_chat(Rest, [Msg | Acc])
    end;
input_items_to_chat(
    [#{<<"type">> := <<"function_call_output">>, <<"call_id">> := Id, <<"output">> := Out} | Rest],
    Acc
) ->
    Msg = #{<<"role">> => <<"tool">>, <<"tool_call_id">> => Id, <<"content">> => Out},
    input_items_to_chat(Rest, [Msg | Acc]);
input_items_to_chat([#{<<"role">> := Role, <<"content">> := C} | Rest], Acc) when
    is_binary(Role)
->
    case content_as_text(C) of
        {ok, OkText} ->
            input_items_to_chat(Rest, [#{<<"role">> => Role, <<"content">> => OkText} | Acc]);
        error ->
            {error, {translate_unsupported, <<"invalid input item">>}}
    end;
input_items_to_chat([#{<<"type">> := _} | _], _) ->
    {error, {translate_unsupported, <<"unsupported responses input item">>}};
input_items_to_chat(_, _) ->
    {error, {translate_unsupported, <<"invalid responses input">>}}.

flatten_response_content(Bin) when is_binary(Bin) ->
    {ok, Bin};
flatten_response_content(List) when is_list(List) ->
    try
        {ok,
            iolist_to_binary([
                case P of
                    #{<<"type">> := <<"input_text">>, <<"text">> := T} when is_binary(T) -> T;
                    #{<<"type">> := <<"output_text">>, <<"text">> := T} when is_binary(T) -> T;
                    #{<<"type">> := <<"text">>, <<"text">> := T} when is_binary(T) -> T;
                    B when is_binary(B) -> B;
                    _ -> throw(bad)
                end
             || P <- List
            ])}
    catch
        _:_ -> {error, {translate_unsupported, <<"vision/multimodal content not supported">>}}
    end;
flatten_response_content(_) ->
    {error, {translate_unsupported, <<"invalid content">>}}.

%%--------------------------------------------------------------------
%% Response translation
%%--------------------------------------------------------------------

-spec translate_response(proto(), proto(), map()) ->
    {ok, map()} | {error, {translate_unsupported, binary()}}.
translate_response(P, P, Map) ->
    {ok, Map};
translate_response(Client, Provider, Map) ->
    do_translate_response(Client, Provider, Map).

do_translate_response(openai_chat, anthropic_messages, Map) ->
    %% Provider spoke messages; client wants chat.
    messages_resp_to_chat(Map);
do_translate_response(anthropic_messages, openai_chat, Map) ->
    chat_resp_to_messages(Map);
do_translate_response(openai_chat, openai_responses, Map) ->
    responses_resp_to_chat(Map);
do_translate_response(openai_responses, openai_chat, Map) ->
    chat_resp_to_responses(Map);
do_translate_response(anthropic_messages, openai_responses, Map) ->
    case responses_resp_to_chat(Map) of
        {ok, Chat} -> chat_resp_to_messages(Chat);
        {error, _} = Err -> Err
    end;
do_translate_response(openai_responses, anthropic_messages, Map) ->
    case messages_resp_to_chat(Map) of
        {ok, Chat} -> chat_resp_to_responses(Chat);
        {error, _} = Err -> Err
    end;
do_translate_response(_, _, _) ->
    {error, {translate_unsupported, <<"unsupported response protocol pair">>}}.

content_as_text(B) when is_binary(B) ->
    {ok, B};
content_as_text(null) ->
    {ok, <<>>};
content_as_text(List) when is_list(List) ->
    case flatten_text_parts(List) of
        {ok, T} -> {ok, T};
        error ->
            case flatten_response_content(List) of
                {ok, T} -> {ok, T};
                {error, _} -> error
            end
    end;
content_as_text(_) ->
    error.

messages_resp_to_chat(Map) ->
    Content = maps:get(<<"content">>, Map, []),
    case assistant_from_anthropic(Content) of
        {ok, Asst} ->
            Finish =
                case maps:get(<<"stop_reason">>, Map, <<"end_turn">>) of
                    <<"tool_use">> -> <<"tool_calls">>;
                    <<"max_tokens">> -> <<"length">>;
                    <<"end_turn">> -> <<"stop">>;
                    <<"stop_sequence">> -> <<"stop">>;
                    _ -> <<"stop">>
                end,
            UsageIn = maps:get(<<"usage">>, Map, #{}),
            Usage = #{
                <<"prompt_tokens">> => maps:get(<<"input_tokens">>, UsageIn, 0),
                <<"completion_tokens">> => maps:get(<<"output_tokens">>, UsageIn, 0),
                <<"total_tokens">> =>
                    maps:get(<<"input_tokens">>, UsageIn, 0) +
                        maps:get(<<"output_tokens">>, UsageIn, 0)
            },
            Msg = maps:without([<<"tool_calls">>], Asst#{<<"refusal">> => null}),
            Msg2 =
                case maps:get(<<"tool_calls">>, Asst, undefined) of
                    undefined -> Msg;
                    TC -> Msg#{<<"tool_calls">> => TC}
                end,
            {ok, #{
                <<"id">> => maps:get(<<"id">>, Map, <<"chatcmpl-janus">>),
                <<"object">> => <<"chat.completion">>,
                <<"model">> => maps:get(<<"model">>, Map, <<>>),
                <<"choices">> => [
                    #{
                        <<"index">> => 0,
                        <<"message">> => Msg2#{<<"role">> => <<"assistant">>},
                        <<"finish_reason">> => Finish
                    }
                ],
                <<"usage">> => Usage
            }};
        {error, _} = Err ->
            Err
    end.

chat_resp_to_messages(Map) ->
    Choices = maps:get(<<"choices">>, Map, []),
    case Choices of
        [#{<<"message">> := Msg} = Ch | _] ->
            case assistant_to_anthropic(Msg) of
                {ok, #{<<"content">> := Content}} ->
                    Stop =
                        case maps:get(<<"finish_reason">>, Ch, <<"stop">>) of
                            <<"tool_calls">> -> <<"tool_use">>;
                            <<"length">> -> <<"max_tokens">>;
                            _ -> <<"end_turn">>
                        end,
                    UsageIn = maps:get(<<"usage">>, Map, #{}),
                    Usage = #{
                        <<"input_tokens">> => maps:get(<<"prompt_tokens">>, UsageIn, 0),
                        <<"output_tokens">> => maps:get(<<"completion_tokens">>, UsageIn, 0)
                    },
                    {ok, #{
                        <<"id">> => maps:get(<<"id">>, Map, <<"msg_janus">>),
                        <<"type">> => <<"message">>,
                        <<"role">> => <<"assistant">>,
                        <<"model">> => maps:get(<<"model">>, Map, <<>>),
                        <<"content">> => Content,
                        <<"stop_reason">> => Stop,
                        <<"stop_sequence">> => null,
                        <<"usage">> => Usage
                    }};
                {error, _} = Err ->
                    Err
            end;
        _ ->
            {error, {translate_unsupported, <<"empty chat choices">>}}
    end.

responses_resp_to_chat(Map) ->
    Output = maps:get(<<"output">>, Map, []),
    case output_to_assistant_message(Output) of
        {ok, Msg, Finish} ->
            UsageIn = maps:get(<<"usage">>, Map, #{}),
            Usage = #{
                <<"prompt_tokens">> => maps:get(<<"input_tokens">>, UsageIn, 0),
                <<"completion_tokens">> => maps:get(<<"output_tokens">>, UsageIn, 0),
                <<"total_tokens">> =>
                    maps:get(<<"input_tokens">>, UsageIn, 0) +
                        maps:get(<<"output_tokens">>, UsageIn, 0)
            },
            {ok, #{
                <<"id">> => maps:get(<<"id">>, Map, <<"chatcmpl-janus">>),
                <<"object">> => <<"chat.completion">>,
                <<"model">> => maps:get(<<"model">>, Map, <<>>),
                <<"choices">> => [
                    #{
                        <<"index">> => 0,
                        <<"message">> => Msg,
                        <<"finish_reason">> => Finish
                    }
                ],
                <<"usage">> => Usage
            }};
        {error, _} = Err ->
            Err
    end.

output_to_assistant_message(Output) when is_list(Output) ->
    {Texts, Calls} = lists:foldl(
        fun
            (#{<<"type">> := <<"message">>, <<"content">> := C}, {Ts, Cs}) ->
                case flatten_response_content(C) of
                    {ok, T} -> {[T | Ts], Cs};
                    {error, _} -> {Ts, Cs}
                end;
            (
                #{<<"type">> := <<"function_call">>, <<"call_id">> := Id, <<"name">> := Name, <<"arguments">> := Args},
                {Ts, Cs}
            ) ->
                Call = #{
                    <<"id">> => Id,
                    <<"type">> => <<"function">>,
                    <<"function">> => #{<<"name">> => Name, <<"arguments">> => Args}
                },
                {Ts, [Call | Cs]};
            (_, Acc) ->
                Acc
        end,
        {[], []},
        Output
    ),
    Msg0 = #{
        <<"role">> => <<"assistant">>,
        <<"content">> => iolist_to_binary(lists:reverse(Texts))
    },
    case lists:reverse(Calls) of
        [] -> {ok, Msg0, <<"stop">>};
        TC -> {ok, Msg0#{<<"tool_calls">> => TC}, <<"tool_calls">>}
    end;
output_to_assistant_message(_) ->
    {error, {translate_unsupported, <<"invalid responses output">>}}.

chat_resp_to_responses(Map) ->
    case chat_resp_to_messages(Map) of
        {ok, MsgResp} ->
            %% Reuse messages content as responses output message.
            Content = maps:get(<<"content">>, MsgResp, []),
            OutputItems = content_to_response_output(Content),
            UsageIn = maps:get(<<"usage">>, MsgResp, #{}),
            {ok, #{
                <<"id">> => maps:get(<<"id">>, Map, <<"resp_janus">>),
                <<"object">> => <<"response">>,
                <<"status">> => <<"completed">>,
                <<"model">> => maps:get(<<"model">>, Map, <<>>),
                <<"output">> => OutputItems,
                <<"usage">> => #{
                    <<"input_tokens">> => maps:get(<<"input_tokens">>, UsageIn, 0),
                    <<"output_tokens">> => maps:get(<<"output_tokens">>, UsageIn, 0)
                }
            }};
        {error, _} = Err ->
            Err
    end.

content_to_response_output(Content) when is_list(Content) ->
    lists:filtermap(
        fun
            (#{<<"type">> := <<"text">>, <<"text">> := T}) ->
                {true, #{
                    <<"type">> => <<"message">>,
                    <<"role">> => <<"assistant">>,
                    <<"content">> => [#{<<"type">> => <<"output_text">>, <<"text">> => T}]
                }};
            (#{<<"type">> := <<"tool_use">>, <<"id">> := Id, <<"name">> := Name, <<"input">> := Input}) ->
                {true, #{
                    <<"type">> => <<"function_call">>,
                    <<"call_id">> => Id,
                    <<"name">> => Name,
                    <<"arguments">> => iolist_to_binary(thoas:encode(Input))
                }};
            (_) ->
                false
        end,
        Content
    );
content_to_response_output(Bin) when is_binary(Bin) ->
    [
        #{
            <<"type">> => <<"message">>,
            <<"role">> => <<"assistant">>,
            <<"content">> => [#{<<"type">> => <<"output_text">>, <<"text">> => Bin}]
        }
    ];
content_to_response_output(_) ->
    [].

copy_if(Src, Dst, Key) ->
    case maps:get(Key, Src, undefined) of
        undefined -> Dst;
        null -> Dst;
        V -> Dst#{Key => V}
    end.

%%====================================================================
%% Streaming translate (Slice A): parser + event mapper + terminator.
%% All pure. Frames are iodata the handler writes immediately.
%%====================================================================

-spec new_sse_st() -> #sse_st{}.
new_sse_st() ->
    #sse_st{}.

%% True when a streaming request CANNOT ride the translate path and
%% must stay on a same-protocol route (client openai_responses, or the
%% request carries tools / non-text content / n>1). Single source for
%% the dispatch 400 and the janus-auto tier constraint.
-spec stream_translate_blocked(atom(), map()) -> boolean().
stream_translate_blocked(ClientProto, Map) when is_map(Map) ->
    PairOk =
        case ClientProto of
            openai_chat -> true;
            anthropic_messages -> true;
            _ -> false
        end,
    not PairOk orelse has_non_text_content(Map) orelse has_tools(Map) orelse n_blocked(Map).

n_blocked(Map) ->
    case maps:get(<<"n">>, Map, 1) of
        N when is_integer(N), N > 1 -> true;
        _ -> false
    end.

has_tools(Map) ->
    case maps:get(<<"tools">>, Map, undefined) of
        L when is_list(L), L =/= [] -> true;
        _ -> false
    end.

%%%-------------------------------------------------------------------
%%% sse_events/2 — SSE wire parser
%%%-------------------------------------------------------------------

%% Bin holds the bytes not yet consumed since the last event dispatch:
%% an event's lines only leave Bin at its blank-line terminator, so a
%% chunk split mid-event keeps the whole pending region in Rest.
-spec sse_events(binary(), binary()) ->
    {ok, [map()], binary()} | {error, leftover_cap}.
sse_events(Buffer, Chunk) when
    byte_size(Buffer) + byte_size(Chunk) > ?SSE_LEFTOVER_CAP
->
    {error, leftover_cap};
sse_events(Buffer, Chunk) ->
    sse_loop(<<Buffer/binary, Chunk/binary>>, none, [], []).

sse_loop(Bin, Ev, Datas, Acc) ->
    case binary:split(Bin, <<"\n">>) of
        [_Incomplete] when byte_size(Bin) > ?SSE_LEFTOVER_CAP ->
            {error, leftover_cap};
        [_Incomplete] ->
            {ok, lists:reverse(Acc), Bin};
        [Line0, Rest] ->
            Line = strip_cr(Line0),
            case Line of
                <<>> ->
                    case Datas of
                        [] ->
                            sse_loop(Rest, none, [], Acc);
                        _ ->
                            sse_loop(Rest, none, [], [sse_event(Ev, Datas) | Acc])
                    end;
                <<":", _/binary>> ->
                    %% SSE comment (keepalive) — never an event.
                    sse_loop(Rest, Ev, Datas, Acc);
                _ ->
                    {Field, Value} =
                        case binary:split(Line, <<":">>) of
                            [F, V] -> {F, strip_one_space(V)};
                            [F] -> {F, <<>>}
                        end,
                    case Field of
                        <<"event">> ->
                            sse_loop(Rest, Value, Datas, Acc);
                        <<"data">> ->
                            case byte_size(Value) > ?SSE_LEFTOVER_CAP of
                                true -> {error, leftover_cap};
                                false -> sse_loop(Rest, Ev, [Value | Datas], Acc)
                            end;
                        _ ->
                            %% id:/retry:/unknown fields are ignored.
                            sse_loop(Rest, Ev, Datas, Acc)
                    end
            end
    end.

strip_cr(Line) ->
    case byte_size(Line) > 0 andalso binary:last(Line) =:= 13 of
        true -> binary:part(Line, 0, byte_size(Line) - 1);
        false -> Line
    end.

strip_one_space(<<$\s, V/binary>>) -> V;
strip_one_space(V) -> V.

%% Anthropic events carry the type on the `event:` line; OpenAI chunks
%% have no event line. [DONE] becomes a bare done marker.
sse_event(Ev, Datas) ->
    Data = iolist_to_binary(lists:join(<<"\n">>, lists:reverse(Datas))),
    Decoded =
        case thoas:decode(Data) of
            {ok, Map} when is_map(Map) ->
                Map;
            _ ->
                _ = logger:warning(#{what => janus_translate_sse_bad_json}),
                Data
        end,
    case Data of
        <<"[DONE]">> -> #{type => <<"done">>, data => <<>>};
        _ when Ev =:= none -> #{type => <<"chunk">>, data => Decoded};
        _ -> #{type => Ev, data => Decoded}
    end.

%%%-------------------------------------------------------------------
%%% Frame helpers
%%%-------------------------------------------------------------------

%% One frame = one complete SSE event as a flat binary (the handler
%% writes frames verbatim; tests assert on them directly).
chat_frame(Map) ->
    iolist_to_binary([<<"data: ">>, thoas:encode(Map), <<"\n\n">>]).

anthropic_frame(Event, Map) ->
    iolist_to_binary([<<"event: ">>, Event, <<"\ndata: ">>, thoas:encode(Map), <<"\n\n">>]).

chat_synthetic_id() ->
    <<"chatcmpl-", (integer_to_binary(erlang:unique_integer([positive]), 16))/binary>>.

anthropic_synthetic_id() ->
    Hex = string:lowercase(integer_to_binary(erlang:unique_integer([positive]), 16)),
    <<"msg_", (binary:part(Hex, 0, min(8, byte_size(Hex))))/binary>>.

int_or_undef(V) when is_integer(V), V >= 0 -> V;
int_or_undef(_) -> undefined.

input_or_zero(undefined) -> 0;
input_or_zero(V) when is_integer(V), V >= 0 -> V.

bin_or(B, _Default) when is_binary(B), B =/= <<>> -> B;
bin_or(_, Default) -> Default.

trunc_200(B) when byte_size(B) > 200 ->
    binary:part(B, 0, 200);
trunc_200(B) ->
    B.

created_now(#sse_st{created = C}) when is_integer(C) ->
    C;
created_now(_) ->
    erlang:system_time(second).

%%%-------------------------------------------------------------------
%%% translate_sse/4 — provider Anthropic -> client Chat
%%%-------------------------------------------------------------------

-spec translate_sse(atom(), atom(), map(), #sse_st{}) ->
    {ok, [iodata()], #sse_st{}} | {error, translate_unsupported, #sse_st{}}.
translate_sse(openai_chat, anthropic_messages, Event, St) ->
    anthro_to_chat(Event, St);
translate_sse(anthropic_messages, openai_chat, Event, St) ->
    chat_to_anthropic(Event, St);
translate_sse(_ClientProto, _ProviderProto, _Event, St) ->
    {error, translate_unsupported, St}.
anthro_to_chat(#{type := <<"ping">>}, St) ->
    {ok, [<<": ping\n\n">>], St};
anthro_to_chat(#{type := <<"message_start">>, data := D}, St) when
    is_map(D)
->
    Msg = maps:get(<<"message">>, D, #{}),
    Id = bin_or(maps:get(<<"id">>, Msg, undefined), chat_synthetic_id()),
    Model = bin_or(maps:get(<<"model">>, Msg, undefined), <<"unknown">>),
    Created = created_now(St),
    U = maps:get(<<"usage">>, Msg, #{}),
    InTok = int_or_undef(maps:get(<<"input_tokens">>, U, undefined)),
    Chunk = #{
        <<"id">> => Id,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => Created,
        <<"model">> => Model,
        <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"role">> => <<"assistant">>}}]
    },
    {ok, [chat_frame(Chunk)], St#sse_st{
        role_sent = true, msg_id = Id, model = Model, created = Created, in_tokens = InTok
    }};
anthro_to_chat(#{type := <<"message_start">>}, St) ->
    %% Undecodable data: skip, never crash the fold.
    {ok, [], St};
anthro_to_chat(#{type := <<"content_block_start">>, data := D}, St) when
    is_map(D)
->
    B = maps:get(<<"content_block">>, D, #{}),
    case maps:get(<<"type">>, B, undefined) of
        <<"text">> ->
            emit_chat_first_delta(<<"content">>, maps:get(<<"text">>, B, undefined), St#sse_st{block_kind = text});
        <<"thinking">> ->
            emit_chat_first_delta(
                <<"reasoning_content">>, maps:get(<<"thinking">>, B, undefined), St#sse_st{block_kind = thinking}
            );
        _ ->
            {error, translate_unsupported, St}
    end;
anthro_to_chat(#{type := <<"content_block_start">>}, St) ->
    {ok, [], St};
anthro_to_chat(#{type := <<"content_block_delta">>, data := D}, St) when
    is_map(D)
->
    Delta = maps:get(<<"delta">>, D, #{}),
    case maps:get(<<"type">>, Delta, undefined) of
        <<"text_delta">> ->
            chat_delta_frame(<<"content">>, maps:get(<<"text">>, Delta, undefined), St);
        <<"thinking_delta">> ->
            chat_delta_frame(<<"reasoning_content">>, maps:get(<<"thinking">>, Delta, undefined), St);
        <<"signature_delta">> ->
            {ok, [], St};
        <<"input_json_delta">> ->
            {error, translate_unsupported, St};
        _ ->
            {ok, [], St}
    end;
anthro_to_chat(#{type := <<"content_block_delta">>}, St) ->
    {ok, [], St};
anthro_to_chat(#{type := <<"message_delta">>, data := D}, St) when
    is_map(D)
->
    StopIn = maps:get(<<"stop_reason">>, maps:get(<<"delta">>, D, #{}), undefined),
    case StopIn of
        <<"tool_use">> ->
            {error, translate_unsupported, St};
        _ ->
            anthro_message_delta_finish(D, StopIn, St)
    end;
anthro_to_chat(#{type := <<"message_delta">>}, St) ->
    {ok, [], St};
anthro_to_chat(#{type := <<"message_stop">>}, St) ->
    {UsageFrames, St1} = chat_pending_usage(St),
    {ok, UsageFrames ++ [<<"data: [DONE]\n\n">>], St1#sse_st{terminal_sent = true}};
anthro_to_chat(#{type := <<"error">>}, St) ->
    {error, translate_unsupported, St};
anthro_to_chat(#{type := _}, St) ->
    %% content_block_stop / unknown events: no-op.
    {ok, [], St}.

anthro_message_delta_finish(D, StopIn, St) ->
    FR = chat_finish_reason(StopIn),
    U = maps:get(<<"usage">>, D, #{}),
    OutTok = int_or_undef(maps:get(<<"output_tokens">>, U, undefined)),
    Chunk = #{
        <<"id">> => bin_or(St#sse_st.msg_id, chat_synthetic_id()),
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => created_now(St),
        <<"model">> => bin_or(St#sse_st.model, <<"unknown">>),
        <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{}, <<"finish_reason">> => FR}]
    },
    %% Usage is NEVER on the finish chunk — message_stop emits it.
    {ok, [chat_frame(Chunk)], St#sse_st{finish_sent = true, finish_reason = FR, out_tokens = OutTok}}.

chat_to_anthropic(#{type := <<"done">>}, St) ->
    {CloseFrames, St1} = close_open_block(St),
    {DeltaFrames, St2} = anthropic_pending_stop(St1),
    {ok,
        CloseFrames ++ DeltaFrames ++ [anthropic_frame(<<"message_stop">>, #{<<"type">> => <<"message_stop">>})],
        St2#sse_st{terminal_sent = true}};
chat_to_anthropic(#{type := <<"chunk">>, data := D}, St) when
    is_map(D)
->
    case maps:get(<<"error">>, D, undefined) of
        Err when is_map(Err) ->
            {error, translate_unsupported, St};
        _ ->
            {StartFrames, St1} = anthropic_ensure_start(D, St),
            chat_chunk_body(D, St1, StartFrames)
    end;
chat_to_anthropic(#{type := _}, St) ->
    %% Undecodable data (binary): skip.
    {ok, [], St}.
%% Emit a start object's non-empty text/thinking as the first delta.
emit_chat_first_delta(Field, Text, St) when is_binary(Text), Text =/= <<>> ->
    chat_delta_frame(Field, Text, St);
emit_chat_first_delta(_Field, _Text, St) ->
    {ok, [], St}.

chat_delta_frame(_Field, undefined, St) ->
    {ok, [], St};
chat_delta_frame(_Field, <<>>, St) ->
    {ok, [], St};
chat_delta_frame(Field, Text, St) when is_binary(Text) ->
    Chunk = #{
        <<"id">> => bin_or(St#sse_st.msg_id, chat_synthetic_id()),
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => created_now(St),
        <<"model">> => bin_or(St#sse_st.model, <<"unknown">>),
        <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{Field => Text}}]
    },
    {ok, [chat_frame(Chunk)], St}.

chat_finish_reason(<<"end_turn">>) -> <<"stop">>;
chat_finish_reason(<<"stop_sequence">>) -> <<"stop">>;
chat_finish_reason(<<"max_tokens">>) -> <<"length">>;
chat_finish_reason(<<"refusal">>) -> <<"content_filter">>;
chat_finish_reason(<<"pause_turn">>) -> <<"stop">>;
chat_finish_reason(undefined) -> <<"stop">>;
chat_finish_reason(null) -> <<"stop">>;
chat_finish_reason(Other) when is_binary(Other) ->
    _ = logger:warning(#{what => janus_translate_sse_unknown_stop, stop_reason => Other}),
    <<"stop">>;
chat_finish_reason(_) ->
    %% JSON null decodes to the atom null; any other shape must not
    %% crash the fold (function_clause escapes translate_sse/4).
    <<"stop">>.

%% At most one empty-choices usage chunk; omitted when both unknown.
chat_pending_usage(#sse_st{usage_sent = true} = St) ->
    {[], St};
chat_pending_usage(St) ->
    case {St#sse_st.in_tokens, St#sse_st.out_tokens} of
        {undefined, undefined} ->
            {[], St};
        {In, Out} ->
            Usage0 =
                case In of
                    undefined -> #{};
                    _ -> #{<<"prompt_tokens">> => In}
                end,
            Usage1 =
                case Out of
                    undefined -> Usage0;
                    _ -> Usage0#{<<"completion_tokens">> => Out}
                end,
            Chunk = #{
                <<"id">> => bin_or(St#sse_st.msg_id, chat_synthetic_id()),
                <<"object">> => <<"chat.completion.chunk">>,
                <<"created">> => created_now(St),
                <<"model">> => bin_or(St#sse_st.model, <<"unknown">>),
                <<"choices">> => [],
                <<"usage">> => Usage1
            },
            {[chat_frame(Chunk)], St#sse_st{usage_sent = true}}
    end.

%%%-------------------------------------------------------------------
%%% translate_sse/4 — provider Chat -> client Anthropic
%%%-------------------------------------------------------------------

%% Emit message_start on the first provider chunk (role optional).
anthropic_ensure_start(_D, #sse_st{role_sent = true} = St) ->
    {[], St};
anthropic_ensure_start(D, St) ->
    Msg = #{
        <<"type">> => <<"message">>,
        <<"id">> => bin_or(maps:get(<<"id">>, D, undefined), anthropic_synthetic_id()),
        <<"role">> => <<"assistant">>,
        <<"model">> => bin_or(maps:get(<<"model">>, D, undefined), <<"unknown">>),
        <<"content">> => [],
        <<"stop_reason">> => null,
        <<"usage">> => #{
            <<"input_tokens">> => input_or_zero(St#sse_st.in_tokens),
            <<"output_tokens">> => 0
        }
    },
    Frame = anthropic_frame(
        <<"message_start">>, #{<<"type">> => <<"message_start">>, <<"message">> => Msg}
    ),
    {[Frame], St#sse_st{role_sent = true}}.

chat_chunk_body(D, St, Acc) ->
    Choice = first_choice(D),
    Delta = maps:get(<<"delta">>, Choice, #{}),
    case {maps:get(<<"tool_calls">>, Delta, undefined), maps:get(<<"finish_reason">>, Choice, undefined)} of
        {TC, _} when TC =/= undefined ->
            {error, translate_unsupported, St};
        {_, <<"tool_calls">>} ->
            {error, translate_unsupported, St};
        {_, <<"function_call">>} ->
            {error, translate_unsupported, St};
        {_, _} ->
            chat_chunk_usage(D, Choice, Delta, St, Acc)
    end.

chat_chunk_usage(D, Choice, Delta, St, Acc) ->
    St1 =
        case maps:get(<<"usage">>, D, undefined) of
            UMap when is_map(UMap) ->
                In = int_or_undef(maps:get(<<"prompt_tokens">>, UMap, undefined)),
                Out = int_or_undef(maps:get(<<"completion_tokens">>, UMap, undefined)),
                merge_tokens(St, In, Out);
            _ ->
                St
        end,
    case {maps:get(<<"finish_reason">>, Choice, undefined), St1#sse_st.finish_sent} of
        {FR, false} when is_binary(FR), FR =/= <<>> ->
            {StopFrames, St2} = close_open_block(St1),
            St3 = St2#sse_st{
                finish_sent = true,
                stop_reason = anthropic_stop_reason(FR),
                finish_reason = FR
            },
            %% message_delta is delayed until the usage chunk or [DONE].
            chat_flush_or_delta(Delta, St3, Acc ++ StopFrames);
        _ ->
            chat_flush_or_delta(Delta, St1, Acc)
    end.

%% A usage chunk arriving after finish flushes message_delta now.
chat_flush_or_delta(Delta, St, Acc) ->
    case {St#sse_st.finish_sent, St#sse_st.usage_sent, has_usage_evidence(St)} of
        {true, false, true} ->
            {DeltaFrames, St1} = anthropic_pending_stop(St),
            chat_text_reasoning(Delta, St1, Acc ++ DeltaFrames);
        _ ->
            chat_text_reasoning(Delta, St, Acc)
    end.

has_usage_evidence(#sse_st{in_tokens = In, out_tokens = Out}) ->
    In =/= undefined orelse Out =/= undefined.

chat_text_reasoning(Delta, St, Acc) ->
    %% Content first, then reasoning — one transition per chunk.
    {Frames1, St1} =
        case maps:get(<<"content">>, Delta, undefined) of
            C when is_binary(C), C =/= <<>> ->
                open_block_and_delta(text, <<"text">>, C, St, Acc);
            _ ->
                {Acc, St}
        end,
    {Frames2, St2} =
        case maps:get(<<"reasoning_content">>, Delta, undefined) of
            R when is_binary(R), R =/= <<>> ->
                open_block_and_delta(thinking, <<"thinking">>, R, St1, Frames1);
            _ ->
                {Frames1, St1}
        end,
    {ok, Frames2, St2}.

%% Transition into the requested block kind if needed, then the delta.
open_block_and_delta(Kind, TextField, Text, St, Acc) ->
    {TransFrames, St1} =
        case St#sse_st.block_kind of
            Kind when St#sse_st.block =/= undefined ->
                {[], St};
            _ ->
                {Stop, St0} = close_open_block(St),
                Idx = St0#sse_st.next_block,
                BlockField =
                    case Kind of
                        text -> #{<<"type">> => <<"text">>, <<"text">> => <<>>};
                        thinking -> #{<<"type">> => <<"thinking">>, <<"thinking">> => <<>>}
                    end,
                Start = anthropic_frame(
                    <<"content_block_start">>,
                    #{<<"index">> => Idx, <<"content_block">> => BlockField}
                ),
                {Stop ++ [Start], St0#sse_st{block = Idx, block_kind = Kind, next_block = Idx + 1}}
        end,
    Delta = anthropic_frame(
        <<"content_block_delta">>,
        #{
            <<"index">> => St1#sse_st.block,
            <<"delta">> => #{<<"type">> => block_delta_type(Kind), TextField => Text}
        }
    ),
    {Acc ++ TransFrames ++ [Delta], St1}.

block_delta_type(text) -> <<"text_delta">>;
block_delta_type(thinking) -> <<"thinking_delta">>.

close_open_block(#sse_st{block = undefined} = St) ->
    {[], St};
close_open_block(St) ->
    Frame = anthropic_frame(<<"content_block_stop">>, #{<<"index">> => St#sse_st.block}),
    {[Frame], St#sse_st{block = undefined, block_kind = undefined}}.

anthropic_stop_reason(<<"stop">>) -> <<"end_turn">>;
anthropic_stop_reason(<<"length">>) -> <<"max_tokens">>;
anthropic_stop_reason(<<"content_filter">>) -> <<"refusal">>;
anthropic_stop_reason(<<"tool_calls">>) -> <<"tool_use">>;
anthropic_stop_reason(Other) when is_binary(Other), Other =/= <<>> ->
    _ = logger:warning(#{what => janus_translate_sse_unknown_stop, stop_reason => Other}),
    <<"end_turn">>;
anthropic_stop_reason(_) ->
    <<"end_turn">>.

%% The delayed message_delta (stop + usage) — emitted once, either at
%% the usage chunk or at [DONE]/finalize.
anthropic_pending_stop(#sse_st{finish_sent = false} = St) ->
    %% No finish seen at all (EOF): synthesize the default stop.
    anthropic_pending_stop(St#sse_st{finish_sent = true, stop_reason = <<"end_turn">>});
anthropic_pending_stop(#sse_st{usage_sent = true} = St) ->
    {[], St};
anthropic_pending_stop(St) ->
    Usage0 =
        case St#sse_st.in_tokens of
            undefined -> #{};
            In -> #{<<"input_tokens">> => In}
        end,
    Usage =
        case St#sse_st.out_tokens of
            undefined -> Usage0;
            Out -> Usage0#{<<"output_tokens">> => Out}
        end,
    StopReason = stop_reason_of(St),
    DeltaPart = #{
        <<"type">> => <<"message_delta">>,
        <<"delta">> => #{<<"stop_reason">> => StopReason, <<"stop_sequence">> => null}
    },
    Map =
        case map_size(Usage) of
            0 -> DeltaPart;
            _ -> DeltaPart#{<<"usage">> => Usage}
        end,
    {[anthropic_frame(<<"message_delta">>, Map)], St#sse_st{usage_sent = true}}.

merge_tokens(St, In, Out) ->
    St#sse_st{
        in_tokens = first_defined(In, St#sse_st.in_tokens),
        out_tokens = first_defined(Out, St#sse_st.out_tokens)
    }.

first_defined(undefined, Existing) -> Existing;
first_defined(New, _Existing) -> New.

first_choice(D) ->
    case maps:get(<<"choices">>, D, []) of
        [C | _] when is_map(C) -> C;
        _ -> #{}
    end.

%%%-------------------------------------------------------------------
%%% finalize_sse/3 — exactly one terminator
%%%-------------------------------------------------------------------

-spec finalize_sse(
    atom(), normal | disconnect | {error, invalid_request | upstream, binary()}, #sse_st{}
) ->
    {ok, [iodata()], #sse_st{}}.
finalize_sse(_ClientProto, _Reason, #sse_st{terminal_sent = true} = St) ->
    {ok, [], St};
finalize_sse(_ClientProto, disconnect, St) ->
    %% Frames are discarded — the socket cannot receive them.
    {ok, [], St#sse_st{terminal_sent = true}};
finalize_sse(openai_chat, normal, St) ->
    {FinishFrames, St1} =
        case St#sse_st.finish_sent of
            true ->
                {[], St};
            false ->
                Chunk = #{
                    <<"id">> => bin_or(St#sse_st.msg_id, chat_synthetic_id()),
                    <<"object">> => <<"chat.completion.chunk">>,
                    <<"created">> => created_now(St),
                    <<"model">> => bin_or(St#sse_st.model, <<"unknown">>),
                    <<"choices">> => [
                        #{<<"index">> => 0, <<"delta">> => #{}, <<"finish_reason">> => <<"stop">>}
                    ]
                },
                {[chat_frame(Chunk)], St#sse_st{finish_sent = true}}
        end,
    {UsageFrames, St2} = chat_pending_usage(St1),
    {ok, FinishFrames ++ UsageFrames ++ [<<"data: [DONE]\n\n">>], St2#sse_st{terminal_sent = true}};
finalize_sse(anthropic_messages, normal, St) ->
    {StartIfMissing, St0} = anthropic_ensure_start(#{}, St),
    {ZeroFrames, St1} =
        case St0#sse_st.next_block of
            0 ->
                Start = anthropic_frame(
                    <<"content_block_start">>,
                    #{<<"index">> => 0, <<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<>>}}
                ),
                Stop = anthropic_frame(<<"content_block_stop">>, #{<<"index">> => 0}),
                {[Start, Stop], St0#sse_st{next_block = 1}};
            _ ->
                {[], St0}
        end,
    {CloseFrames, St2} = close_open_block(St1),
    {DeltaFrames, St3} = anthropic_pending_stop(St2),
    StopFrame = anthropic_frame(<<"message_stop">>, #{<<"type">> => <<"message_stop">>}),
    {ok, StartIfMissing ++ ZeroFrames ++ CloseFrames ++ DeltaFrames ++ [StopFrame],
        St3#sse_st{terminal_sent = true}};
finalize_sse(openai_chat, {error, Kind, Msg}, St) ->
    Err = chat_frame(#{
        <<"error">> => #{<<"message">> => trunc_200(Msg), <<"type">> => error_type(Kind)}
    }),
    {ok, [Err, <<"data: [DONE]\n\n">>], St#sse_st{terminal_sent = true}};
finalize_sse(anthropic_messages, {error, Kind, Msg}, St) ->
    Err = anthropic_frame(
        <<"error">>,
        #{
            <<"type">> => <<"error">>,
            <<"error">> => #{<<"type">> => error_type(Kind), <<"message">> => trunc_200(Msg)}
        }
    ),
    StopFrame = anthropic_frame(<<"message_stop">>, #{<<"type">> => <<"message_stop">>}),
    {ok, [Err, StopFrame], St#sse_st{terminal_sent = true}}.

error_type(invalid_request) -> <<"invalid_request_error">>;
error_type(_) -> <<"api_error">>.

%% Stop reason for the delayed message_delta: the mapped value when
%% present, else derived from the raw finish_reason, else end_turn.
stop_reason_of(#sse_st{stop_reason = SR}) when is_binary(SR), SR =/= <<>> ->
    SR;
stop_reason_of(#sse_st{finish_reason = FR}) when is_binary(FR), FR =/= <<>> ->
    anthropic_stop_reason(FR);
stop_reason_of(_) ->
    <<"end_turn">>.
