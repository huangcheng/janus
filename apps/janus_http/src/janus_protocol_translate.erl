%%%-------------------------------------------------------------------
%%% @doc Pure request/response translation between OpenAI chat,
%%% OpenAI responses, and Anthropic messages. Fail-closed.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_protocol_translate).

-export([
    normalize_protocol/1,
    wants_stream/1,
    translate_request/3,
    translate_response/3,
    default_max_tokens/0
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
                            MaxTok = maps:get(<<"max_tokens">>, Map, default_max_tokens()),
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
    {Texts, ToolCalls} = lists:foldl(
        fun
            (#{<<"type">> := <<"text">>, <<"text">> := T}, {Ts, Cs}) when is_binary(T) ->
                {[T | Ts], Cs};
            (
                #{<<"type">> := <<"tool_use">>, <<"id">> := Id, <<"name">> := Name, <<"input">> := Input},
                {Ts, Cs}
            ) when is_binary(Id), is_binary(Name), is_map(Input) ->
                Args = iolist_to_binary(thoas:encode(Input)),
                Call = #{
                    <<"id">> => Id,
                    <<"type">> => <<"function">>,
                    <<"function">> => #{<<"name">> => Name, <<"arguments">> => Args}
                },
                {Ts, [Call | Cs]};
            (#{<<"type">> := <<"tool_use">>}, _) ->
                throw(bad_tool);
            (#{<<"type">> := _}, _) ->
                throw(bad_part);
            (_, Acc) ->
                Acc
        end,
        {[], []},
        List
    ),
    try
        Msg0 = #{<<"role">> => <<"assistant">>, <<"content">> => iolist_to_binary(lists:reverse(Texts))},
        case lists:reverse(ToolCalls) of
            [] -> {ok, Msg0};
            Calls -> {ok, Msg0#{<<"tool_calls">> => Calls}}
        end
    catch
        bad_tool -> {error, {translate_unsupported, <<"invalid tool_use">>}};
        bad_part -> {error, {translate_unsupported, <<"vision/multimodal content not supported">>}}
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
