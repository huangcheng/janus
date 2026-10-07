%%%-------------------------------------------------------------------
%%% @doc Pure request/response translation between OpenAI chat,
%%% OpenAI responses, and Anthropic messages. Fail-closed.
%%% Streaming (SSE) translate: sse_events/2 parser, translate_sse/4
%%% event mapper, finalize_sse/3 terminator — also pure; the handler
%%% (janus_http_proxy) owns gun/cowboy side effects.
%%%
%%% Phase 1 adds streaming tool-call translation both ways between
%%% chat and anthropic (C5: four index/id spaces kept apart, argument
%%% fragments streamed, content_block_stop / finish only after the ONE
%%% decode-at-close completeness check, deferred interleaved text,
%%% per-stream accumulator caps) and request-side vision translation
%%% on the chat<->anthropic pair.
%%%
%%% Phase 2 adds the ->responses STREAM face (plan 2026-10-06): both
%%% chat and anthropic upstreams render the responses event grammar
%%% (response.created lazily, output_item.added/delta/output_item.done
%%% per item, exactly one terminal response.completed /
%%% response.incomplete / response.failed with usage on the response
%%% object). The dispatch unblock lives in janus_http_proxy under the
%%% `translate' settings knob key <<"responses">>;
%%% stream_translate_blocked/2 itself keeps its conservative view (the
%%% LB bias / janus-auto / repick consumers are unchanged).
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
    stream_translate_blocked/2,
    %% Phase-2 dispatch gate eligibility (the knob lives in the proxy)
    responses_stream_gatable/1,
    %% Audit R2: a stream toward a responses-protocol provider is never
    %% translatable cross-protocol (no Phase-3 SSE translator) — shared
    %% by the dispatch guard and route selection.
    stream_pair_untranslatable/2,
    %% Tools/tool_choice shape translation (audit Q4).
    responses_tool_choice_to_chat/1,
    chat_tool_choice_to_responses/1,
    chat_tool_to_responses/1,
    responses_tool_to_chat/1,
    responses_tools_to_chat/1
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
    %% 1.6 structured output: response_format/json_schema only rides
    %% same-protocol routes; cross-protocol strips + records the drop.
    Map1 =
        case {Client =:= Provider, maps:with([<<"response_format">>, <<"json_schema">>], Map)} of
            {false, Dropped} when map_size(Dropped) > 0 ->
                _ = logger:info(#{
                    what => janus_structured_output_dropped,
                    keys => maps:keys(Dropped)
                }),
                maps:remove(<<"response_format">>, maps:remove(<<"json_schema">>, Map));
            _ ->
                Map
        end,
    case reject_unsupported_request(Client, Provider, Map1) of
        ok ->
            case do_translate_request(Client, Provider, Map1) of
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

reject_unsupported_request(openai_responses, _Provider, Map) ->
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
reject_unsupported_request(Client, Provider, Map) ->
    case maps:get(<<"n">>, Map, 1) of
        N when N =:= 1; N =:= undefined; N =:= null ->
            maybe_reject_vision(Client, Provider, Map);
        _ ->
            {error, {translate_unsupported, <<"n>1 not supported">>}}
    end.

%% Images translate on the chat<->anthropic pair (Phase 1, request
%% side); every other pair keeps the vision reject (Phases 2-3 own
%% them). STREAMING stays dispatch-blocked either way — the unblock is
%% the separate 1.9 ship unit (stream_translate_blocked is unchanged).
maybe_reject_vision(Client, Provider, Map) ->
    case vision_translatable(Client, Provider) of
        true -> ok;
        false -> reject_vision(Map)
    end.

vision_translatable(openai_chat, anthropic_messages) -> true;
vision_translatable(anthropic_messages, openai_chat) -> true;
vision_translatable(_, _) -> false.

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
%% Responses tool-loop history items (audit A-1): these are TEXT-class
%% — falling through to the type catch-all rejected the whole loop
%% with a misleading "vision" error.
part_non_text(#{<<"type">> := <<"function_call">>}) ->
    false;
part_non_text(#{<<"type">> := <<"function_call_output">>}) ->
    false;
%% Responses `reasoning` history items are text-class echoes of the
%% assistant's own chain — the input mapper skips them (audit R2).
part_non_text(#{<<"type">> := <<"reasoning">>}) ->
    false;
part_non_text(#{<<"role">> := _, <<"content">> := C}) ->
    content_has_non_text(C);
part_non_text(#{<<"type">> := <<"message">>, <<"content">> := C}) ->
    content_has_non_text(C);
%% Unknown types are NOT vision (audit R2): the input mappers reject
%% them with honest "unsupported …" errors. Only genuinely multimodal
%% part types take the vision reject.
part_non_text(#{<<"type">> := T}) when is_binary(T) ->
    lists:member(T, [
        <<"input_image">>, <<"image_url">>, <<"image">>,
        <<"input_audio">>, <<"audio">>,
        <<"input_video">>, <<"video">>,
        <<"input_file">>, <<"file">>, <<"document">>
    ]);
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
    case user_parts_to_blocks(List) of
        {ok, Blocks} ->
            %% Text-only lists keep the flattened-binary shape; images
            %% force the block-list form (anthropic native).
            Content = case blocks_text_only(Blocks) of
                {ok, Bin} -> Bin;
                mixed -> Blocks
            end,
            {ok, #{<<"role">> => <<"user">>, <<"content">> => Content}};
        error ->
            {error, {translate_unsupported, <<"invalid user content part">>}}
    end;
user_to_anthropic(_) ->
    {error, {translate_unsupported, <<"invalid user message">>}}.

user_parts_to_blocks(List) ->
    user_parts_to_blocks(List, []).

user_parts_to_blocks([], Acc) ->
    {ok, lists:reverse(Acc)};
user_parts_to_blocks([#{<<"type">> := <<"text">>, <<"text">> := T} | Rest], Acc) when
    is_binary(T)
->
    user_parts_to_blocks(Rest, [#{<<"type">> => <<"text">>, <<"text">> => T} | Acc]);
user_parts_to_blocks([B | Rest], Acc) when is_binary(B) ->
    user_parts_to_blocks(Rest, [#{<<"type">> => <<"text">>, <<"text">> => B} | Acc]);
user_parts_to_blocks([#{<<"type">> := <<"image_url">>} = P | Rest], Acc) ->
    case image_url_part_to_block(P) of
        {ok, Block} -> user_parts_to_blocks(Rest, [Block | Acc]);
        error -> error
    end;
user_parts_to_blocks(_, _) ->
    error.

blocks_text_only(Blocks) ->
    Texts = [T || #{<<"type">> := <<"text">>, <<"text">> := T} <- Blocks],
    case length(Texts) =:= length(Blocks) of
        true -> {ok, iolist_to_binary(Texts)};
        false -> mixed
    end.

%% chat image_url part -> anthropic image block. The URL must be a
%% base64 data URL (-> base64 media source) or a plain URL (-> url
%% source); both round-trip. Anything else fails closed.
image_url_part_to_block(#{<<"image_url">> := IU}) ->
    Url =
        case IU of
            #{<<"url">> := U} when is_binary(U) -> U;
            U when is_binary(U) -> U;
            _ -> error
        end,
    case Url of
        <<"data:", Rest/binary>> ->
            case binary:split(Rest, <<";base64,">>) of
                [MT, Data] when MT =/= <<>>, Data =/= <<>> ->
                    {ok, #{
                        <<"type">> => <<"image">>,
                        <<"source">> => #{
                            <<"type">> => <<"base64">>,
                            <<"media_type">> => MT,
                            <<"data">> => Data
                        }
                    }};
                _ ->
                    error
            end;
        Plain when is_binary(Plain), Plain =/= <<>> ->
            {ok, #{<<"type">> => <<"image">>, <<"source">> => #{<<"type">> => <<"url">>, <<"url">> => Plain}}};
        _ ->
            %% Covers the Url = error atom (malformed image_url) —
            %% fail closed instead of serializing "error" upstream.
            error
    end;
image_url_part_to_block(_) ->
    error.

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

%% Pending non-tool parts between tool_results: reversed [{Kind, Bin}],
%% flushed as one user message — flattened binary when text-only
%% (unchanged shape), an ordered parts list once images appear.
expand_user_parts([], Acc, Pending) ->
    {ok, flush_pending_user(Pending, Acc)};
expand_user_parts([#{<<"type">> := <<"text">>, <<"text">> := T} | Rest], Acc, Pending) when
    is_binary(T)
->
    expand_user_parts(Rest, Acc, [{text, T} | Pending]);
expand_user_parts([#{<<"type">> := <<"image">>} = B | Rest], Acc, Pending) ->
    case image_block_to_chat_part(B) of
        {ok, Part} -> expand_user_parts(Rest, Acc, [{image, Part} | Pending]);
        error -> {error, {translate_unsupported, <<"invalid image block">>}}
    end;
expand_user_parts(
    [#{<<"type">> := <<"tool_result">>, <<"tool_use_id">> := Id, <<"content">> := C} | Rest],
    Acc,
    Pending
) ->
    Acc1 = flush_pending_user(Pending, Acc),
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

flush_pending_user([], Acc) ->
    Acc;
flush_pending_user(Pending, Acc) ->
    Rev = lists:reverse(Pending),
    HasImage = lists:any(fun({image, _}) -> true; (_) -> false end, Rev),
    Content =
        case HasImage of
            false ->
                iolist_to_binary([T || {text, T} <- Rev]);
            true ->
                [
                    case P of
                        {text, T} -> #{<<"type">> => <<"text">>, <<"text">> => T};
                        {image, ImagePart} -> ImagePart
                    end
                 || P <- Rev
                ]
        end,
    [#{<<"role">> => <<"user">>, <<"content">> => Content} | Acc].

%% anthropic image block -> chat image_url part; base64 sources become
%% data URLs again so the pair round-trips (Phase 1 request side).
image_block_to_chat_part(#{
    <<"source">> := #{
        <<"type">> := <<"base64">>,
        <<"media_type">> := MT,
        <<"data">> := Data
    }
}) when is_binary(MT), MT =/= <<>>, is_binary(Data), Data =/= <<>> ->
    {ok, #{
        <<"type">> => <<"image_url">>,
        <<"image_url">> => #{<<"url">> => <<"data:", MT/binary, ";base64,", Data/binary>>}
    }};
image_block_to_chat_part(#{<<"source">> := #{<<"type">> := <<"url">>, <<"url">> := U}}) when
    is_binary(U), U =/= <<>>
->
    {ok, #{<<"type">> => <<"image_url">>, <<"image_url">> => #{<<"url">> => U}}};
image_block_to_chat_part(_) ->
    error.

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
                            case chat_tools_to_responses(Tools) of
                                {ok, RespTools} ->
                                    OutT = Out4#{<<"tools">> => RespTools},
                                    case chat_tool_choice_to_responses(maps:get(<<"tool_choice">>, Map, undefined)) of
                                        undefined -> {ok, OutT};
                                        TC -> {ok, OutT#{<<"tool_choice">> => TC}}
                                    end;
                                {error, _} = TErr ->
                                    TErr
                            end;
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
                                Tools when is_list(Tools) ->
                                    case responses_tools_to_chat(Tools) of
                                        {ok, ChatTools} ->
                                            OutT = Out3#{<<"tools">> => ChatTools},
                                            case responses_tool_choice_to_chat(maps:get(<<"tool_choice">>, Map, undefined)) of
                                                undefined -> {ok, OutT};
                                                TC -> {ok, OutT#{<<"tool_choice">> => TC}}
                                            end;
                                        {error, _} = TErr ->
                                            TErr
                                    end;
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
    case flatten_tool_output(Out) of
        {ok, Text} ->
            Msg = #{<<"role">> => <<"tool">>, <<"tool_call_id">> => Id, <<"content">> => Text},
            input_items_to_chat(Rest, [Msg | Acc]);
        {error, _} = Err ->
            Err
    end;
input_items_to_chat([#{<<"type">> := <<"reasoning">>} | Rest], Acc) ->
    %% Echo of the assistant's own reasoning — providers don't need it
    %% back; skip so the standard Responses agent loop rides (audit R2).
    input_items_to_chat(Rest, Acc);
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

%% function_call_output.output is a string OR an array of content parts
%% in the Responses spec — flatten both to a chat tool-message string.
%% Tools cross the chat/responses boundary in different shapes:
%% responses = flat {type,name,parameters,description?}; chat = wrapped
%% {type,function,{name,parameters,description}}. Reshape both ways;
%% already-correct shapes pass through untouched (upstream find, the
%% verbatim passthrough got flat tools rejected by chat providers).
responses_tools_to_chat(Tools) ->
    reshape(Tools, fun responses_tool_to_chat/1).

responses_tool_to_chat(#{<<"function">> := _} = T) ->
    %% Already chat-wrapped — pass untouched.
    {ok, T};
responses_tool_to_chat(#{<<"type">> := <<"function">>} = T) ->
    case maps:with([<<"name">>, <<"parameters">>, <<"description">>], T) of
        #{<<"name">> := _} = Fn0 ->
            Fn = Fn0#{<<"type">> => <<"function">>},
            {ok, #{<<"type">> => <<"function">>, <<"function">> => Fn}};
        _ ->
            {error, {translate_unsupported, <<"responses tool missing name">>}}
    end;
responses_tool_to_chat(T) when is_map(T) ->
    %% Custom type — pass.
    {ok, T}.

chat_tools_to_responses(Tools) ->
    reshape(Tools, fun chat_tool_to_responses/1).

chat_tool_to_responses(#{<<"name">> := _, <<"type">> := <<"function">>} = T) ->
    %% Already responses-flat — pass untouched.
    {ok, T};
chat_tool_to_responses(#{<<"type">> := <<"function">>, <<"function">> := Fn} = T) when is_map(Fn) ->
    case maps:get(<<"name">>, Fn, undefined) of
        undefined ->
            {error, {translate_unsupported, <<"chat tool missing name">>}};
        _ ->
            Flat0 = maps:merge(
                maps:with([<<"name">>, <<"parameters">>, <<"description">>], Fn),
                #{<<"type">> => <<"function">>}
            ),
            {ok, maps:merge(Flat0, maps:without([<<"type">>, <<"function">>], T))}
    end;
chat_tool_to_responses(T) when is_map(T) ->
    %% Custom type — pass.
    {ok, T}.

%% tool_choice crosses with the same flat/wrapped split as tools.
responses_tool_choice_to_chat(#{<<"type">> := <<"function">>} = TC) ->
    case maps:get(<<"name">>, TC, undefined) of
        undefined -> undefined;
        Name -> #{<<"type">> => <<"function">>, <<"function">> => #{<<"name">> => Name}}
    end;
responses_tool_choice_to_chat(undefined) -> undefined;
responses_tool_choice_to_chat(null) -> undefined;
responses_tool_choice_to_chat(Bin) when is_binary(Bin) -> Bin;
responses_tool_choice_to_chat(_) -> undefined.

chat_tool_choice_to_responses(#{<<"type">> := <<"function">>, <<"function">> := #{<<"name">> := Name}}) ->
    #{<<"type">> => <<"function">>, <<"name">> => Name};
chat_tool_choice_to_responses(Bin) when is_binary(Bin) -> Bin;
chat_tool_choice_to_responses(_) -> undefined.

reshape(Tools, F) ->
    reshape_loop(Tools, F, []).

reshape_loop([], _F, Acc) ->
    {ok, lists:reverse(Acc)};
reshape_loop([T | Rest], F, Acc) ->
    case F(T) of
        {ok, T2} -> reshape_loop(Rest, F, [T2 | Acc]);
        {error, _} = Err -> Err
    end;
reshape_loop(_, _F, _Acc) ->
    {error, {translate_unsupported, <<"invalid tools">>}}.

flatten_tool_output(Bin) when is_binary(Bin) ->
    {ok, Bin};
flatten_tool_output(List) when is_list(List) ->
    flatten_response_content(List);
flatten_tool_output(_) ->
    {error, {translate_unsupported, <<"invalid function_call_output">>}}.

%%--------------------------------------------------------------------
%% Response translation
%%--------------------------------------------------------------------

-spec translate_response(proto(), proto(), map()) ->
    {ok, map()} | {error, {translate_unsupported, binary()}}.
translate_response(P, P, Map) ->
    {ok, Map};
translate_response(Client, Provider, Map) ->
    do_translate_response(Client, Provider, Map).

%% Total unix-seconds coercion for translated response timestamps —
%% upstream null/garbage falls back to now, never a case_clause (R2).
created_unix(V) when is_integer(V) ->
    V;
created_unix(_) ->
    erlang:system_time(second).

-spec stream_pair_untranslatable(proto(), proto()) -> boolean().
stream_pair_untranslatable(openai_responses, openai_responses) ->
    false;
stream_pair_untranslatable(_, openai_responses) ->
    true;
stream_pair_untranslatable(_, _) ->
    false.

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
                %% Audit find (Kimi 2026-10-07): `created` is a required
                %% chat-completion field — strict clients broke on the
                %% translated non-stream path (the stream path had it).
                <<"created">> => created_unix(maps:get(<<"created">>, Map, undefined)),
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
                %% Same required-field fix as the anthropic face (R2):
                %% Responses payloads name the timestamp `created_at`.
                <<"created">> =>
                    created_unix(
                        maps:get(<<"created_at">>, Map, maps:get(<<"created">>, Map, undefined))
                    ),
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
                %% `created_at` is required on the Responses object (R2);
                %% mirror the chat face's `created`.
                <<"created_at">> => created_unix(maps:get(<<"created">>, Map, undefined)),
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

%% Phase-2 dispatch gate eligibility: true when an openai_responses
%% streaming request carries nothing beyond the responses-client gate
%% itself. Vision content and n>1 stay blocked (n_blocked unchanged);
%% TOOLS ride the translate path — the responses knob is independent of
%% the tools knob (plan 2.3's 2x2 matrix). stream_translate_blocked/2
%% keeps blocking all responses clients: the LB bias, janus-auto tier
%% constraint, and failover repick consume that conservative view; the
%% knob decision is made in janus_http_proxy's dispatch.
-spec responses_stream_gatable(map()) -> boolean().
responses_stream_gatable(Map) when is_map(Map) ->
    not has_non_text_content(Map) andalso not n_blocked(Map).

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
            %% C-2 regression (audit 2026-10-07): the pending event's
            %% already-parsed lines (Ev/Datas) were dropped here, so a
            %% chunk split mid-event lost fields. Re-encode them into
            %% the leftover — self-contained, the next chunk re-parses.
            Pending = pending_prefix(Ev, Datas),
            {ok, lists:reverse(Acc), <<Pending/binary, Bin/binary>>};
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

%% Rebuild the pending event's parsed lines as literal SSE text so the
%% leftover binary is self-contained across chunk boundaries.
pending_prefix(none, []) ->
    <<>>;
pending_prefix(Ev, Datas) ->
    EvLine =
        case Ev of
            none -> <<>>;
            _ -> [<<"event: ">>, Ev, <<"
">>]
        end,
    DataLines = [[<<"data: ">>, D, <<"
">>] || D <- lists:reverse(Datas)],
    iolist_to_binary([EvLine, DataLines]).

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

%% Phase-2 ->responses face: same event-framed shape (the terminal
%% EVENT is the terminator — no chat [DONE] on this face, C1).
responses_frame(Event, Map) ->
    iolist_to_binary([<<"event: ">>, Event, <<"\ndata: ">>, thoas:encode(Map), <<"\n\n">>]).

chat_synthetic_id() ->
    <<"chatcmpl-", (integer_to_binary(erlang:unique_integer([positive]), 16))/binary>>.

anthropic_synthetic_id() ->
    Hex = string:lowercase(integer_to_binary(erlang:unique_integer([positive]), 16)),
    <<"msg_", (binary:part(Hex, 0, min(8, byte_size(Hex))))/binary>>.

%% Janus-namespaced synthesized ids (C5): the response object id and
%% the responses output-item id are SEPARATE id spaces from tool call
%% ids (jfc_, see tool_synthetic_id/0) and never collide with upstream
%% id prefixes (chatcmpl-/msg_/call_/tool_/fc_/item_). Per-attempt,
%% non-repeating (erlang:unique_integer, C4).
responses_resp_id() ->
    <<"jresp_", (integer_to_binary(erlang:unique_integer([positive]), 16))/binary>>.

responses_item_id() ->
    <<"jitem_", (integer_to_binary(erlang:unique_integer([positive]), 16))/binary>>.

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

%% Error tuples of translate_sse/4:
%%  - translate_unsupported: an upstream construct the mapper cannot
%%    carry (incl. tool arguments that fail the ONE decode-at-close
%%    completeness check — truncated by an upstream cut or bug).
%%  - tool_args_cap: a C5 accumulator cap tripped (256KiB args per call
%%    id, 64 calls, 1MiB total args). Phase-1 contract: the caller
%%    terminates the stream on this tuple; the 1.9 ship unit wires the
%%    full C2 target-format error event.
-spec translate_sse(atom(), atom(), map(), #sse_st{}) ->
    {ok, [iodata()], #sse_st{}}
    | {error, translate_unsupported, #sse_st{}}
    | {error, tool_args_cap, #sse_st{}}.
translate_sse(openai_chat, anthropic_messages, Event, St) ->
    anthro_to_chat(Event, St);
translate_sse(anthropic_messages, openai_chat, Event, St) ->
    chat_to_anthropic(Event, St);
translate_sse(openai_responses, openai_chat, Event, St) ->
    chat_to_responses_stream(Event, St);
translate_sse(openai_responses, anthropic_messages, Event, St) ->
    anthro_to_responses_stream(Event, St);
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
        <<"tool_use">> ->
            anthro_tool_start(D, St);
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
            anthro_tool_fragment(D, St);
        _ ->
            {ok, [], St}
    end;
anthro_to_chat(#{type := <<"content_block_delta">>}, St) ->
    {ok, [], St};
anthro_to_chat(#{type := <<"content_block_stop">>, data := D}, St) when
    is_map(D)
->
    case maps:get(<<"index">>, D, undefined) of
        Idx when is_map_key(Idx, St#sse_st.tools) ->
            anthro_tool_stop(Idx, St);
        _ ->
            %% text/thinking block stop: no chat-face equivalent.
            {ok, [], St}
    end;
anthro_to_chat(#{type := <<"message_delta">>, data := D}, St) when
    is_map(D)
->
    StopIn = maps:get(<<"stop_reason">>, maps:get(<<"delta">>, D, #{}), undefined),
    case St#sse_st.open_tool of
        undefined ->
            anthro_message_delta_finish(D, StopIn, St);
        _ ->
            %% A stop while a tool block is still open: upstream skipped
            %% content_block_stop; never make the call look finished (C5).
            {error, translate_unsupported, St}
    end;
anthro_to_chat(#{type := <<"message_delta">>}, St) ->
    {ok, [], St};
anthro_to_chat(#{type := <<"message_stop">>}, St) ->
    {UsageFrames, St1} = chat_pending_usage(St),
    {ok, UsageFrames ++ [<<"data: [DONE]\n\n">>], St1#sse_st{terminal_sent = true}};
anthro_to_chat(#{type := <<"error">>}, St) ->
    {error, translate_unsupported, St};
anthro_to_chat(#{type := _}, St) ->
    %% Unknown events: no-op.
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

%%%-------------------------------------------------------------------
%%% Tool-call streaming (Phase 1) — anthropic upstream -> chat face.
%%% tool_use blocks render as chat tool_calls chunks; the chat index is
%%% the per-stream tool ORDINAL (tool_seq), never the anthropic block
%%% index (C5: separate index/id spaces). Fragments stream through;
%%% content_block_stop runs the ONE decode-at-close check; the zero-arg
%%% call closes with "{}" (C5).
%%%-------------------------------------------------------------------

anthro_tool_start(D, St) ->
    case maps:get(<<"index">>, D, undefined) of
        Idx when is_integer(Idx), Idx >= 0 ->
            case St#sse_st.tools of
                #{Idx := _} ->
                    %% Duplicate block index: upstream bug, fail closed.
                    {error, translate_unsupported, St};
                _ ->
                    case map_size(St#sse_st.tools) >= ?TOOL_CALLS_PER_STREAM_CAP of
                        true ->
                            {error, tool_args_cap, St};
                        false ->
                            anthro_tool_start_validated(Idx, D, St)
                    end
            end;
        _ ->
            {error, translate_unsupported, St}
    end.

anthro_tool_start_validated(Idx, D, St) ->
    B = maps:get(<<"content_block">>, D, #{}),
    case maps:get(<<"name">>, B, undefined) of
        Name when is_binary(Name), Name =/= <<>> ->
            Id =
                case maps:get(<<"id">>, B, undefined) of
                    I when is_binary(I), I =/= <<>> -> I;
                    _ -> tool_synthetic_id()
                end,
            ChatIdx = St#sse_st.tool_seq,
            TA = #tool_acc{id = Id, name = Name, chat_index = ChatIdx, block = Idx},
            %% No frame yet: the chat chunk waits for the first argument
            %% fragment (or the close, which carries "{}").
            {ok, [], St#sse_st{
                tools = (St#sse_st.tools)#{Idx => TA},
                open_tool = Idx,
                tool_seq = ChatIdx + 1,
                block_kind = tool_use,
                block = Idx
            }};
        _ ->
            {error, translate_unsupported, St}
    end.

anthro_tool_fragment(D, St) ->
    case maps:get(<<"partial_json">>, maps:get(<<"delta">>, D, #{}), undefined) of
        P when is_binary(P), P =/= <<>> ->
            anthro_tool_fragment_bytes(maps:get(<<"index">>, D, undefined), P, St);
        _ ->
            %% Empty fragment: no bytes, no frame.
            {ok, [], St}
    end.

anthro_tool_fragment_bytes(Idx, P, St) ->
    case St#sse_st.tools of
        #{Idx := #tool_acc{closed = false} = TA0} when St#sse_st.open_tool =:= Idx ->
            PerCall = TA0#tool_acc.args_bytes + byte_size(P),
            Total = St#sse_st.total_args + byte_size(P),
            case
                PerCall > ?TOOL_ARGS_PER_CALL_CAP orelse
                    Total > ?TOOL_ARGS_TOTAL_CAP
            of
                true ->
                    {error, tool_args_cap, St};
                false ->
                    %% The id/type/name ride the FIRST chunk of the call;
                    %% fragments carry index + arguments only.
                    Entry =
                        case TA0#tool_acc.header_sent of
                            false ->
                                #{
                                    <<"index">> => TA0#tool_acc.chat_index,
                                    <<"id">> => TA0#tool_acc.id,
                                    <<"type">> => <<"function">>,
                                    <<"function">> => #{
                                        <<"name">> => TA0#tool_acc.name,
                                        <<"arguments">> => P
                                    }
                                };
                            true ->
                                #{
                                    <<"index">> => TA0#tool_acc.chat_index,
                                    <<"type">> => <<"function">>,
                                    <<"function">> => #{<<"arguments">> => P}
                                }
                        end,
                    TA1 = TA0#tool_acc{
                        args = [P | TA0#tool_acc.args],
                        args_bytes = PerCall,
                        header_sent = true
                    },
                    {ok, [chat_tool_call_frame(Entry, St)], St#sse_st{
                        tools = (St#sse_st.tools)#{Idx := TA1},
                        total_args = Total
                    }}
            end;
        #{Idx := _} ->
            %% Fragment after the block closed (or before it opened):
            %% upstream bug, fail closed.
            {error, translate_unsupported, St};
        _ ->
            {error, translate_unsupported, St}
    end.

anthro_tool_stop(Idx, St) ->
    TA0 = maps:get(Idx, St#sse_st.tools),
    case tool_args_complete(tool_args_of(TA0)) of
        ok ->
            %% Zero-argument call: the whole call rides one chunk whose
            %% arguments are "{}" — complete on arrival (C5).
            {Frames, TA1} =
                case TA0#tool_acc.header_sent of
                    true ->
                        {[], TA0};
                    false ->
                        Entry = #{
                            <<"index">> => TA0#tool_acc.chat_index,
                            <<"id">> => TA0#tool_acc.id,
                            <<"type">> => <<"function">>,
                            <<"function">> => #{
                                <<"name">> => TA0#tool_acc.name,
                                <<"arguments">> => <<"{}">>
                            }
                        },
                        {[chat_tool_call_frame(Entry, St)], TA0#tool_acc{header_sent = true}}
                end,
            St1 = St#sse_st{
                tools = (St#sse_st.tools)#{Idx := TA1#tool_acc{args = [], args_bytes = 0, closed = true}},
                open_tool = case St#sse_st.open_tool of Idx -> undefined; Other -> Other end
            },
            {ok, Frames, St1};
        {error, incomplete_json} ->
            %% Truncated arguments at close time: never emit the finish
            %% as tool_calls — C2 error path via the caller.
            {error, translate_unsupported, St}
    end.

chat_tool_call_frame(Entry, St) ->
    Chunk = #{
        <<"id">> => bin_or(St#sse_st.msg_id, chat_synthetic_id()),
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => created_now(St),
        <<"model">> => bin_or(St#sse_st.model, <<"unknown">>),
        <<"choices">> => [#{<<"index">> => 0, <<"delta">> => #{<<"tool_calls">> => [Entry]}}]
    },
    chat_frame(Chunk).

chat_to_anthropic(#{type := <<"done">>}, St) ->
    case chat_close_open_tool(St) of
        {error, _, _} = Err ->
            Err;
        {ToolFrames, St1} ->
            {CloseFrames, St2} = close_open_block(St1),
            {DeltaFrames, St3} = anthropic_pending_stop(St2),
            {ok,
                ToolFrames ++ CloseFrames ++ DeltaFrames ++
                    [anthropic_frame(<<"message_stop">>, #{<<"type">> => <<"message_stop">>})],
                St3#sse_st{terminal_sent = true}}
    end;
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
chat_finish_reason(<<"tool_use">>) -> <<"tool_calls">>;
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
    case maps:get(<<"tool_calls">>, Delta, undefined) of
        Entries when is_list(Entries), Entries =/= [] ->
            case chat_tool_entries(Entries, St, Acc) of
                {error, _, _} = Err ->
                    Err;
                {Frames, St1} ->
                    %% Text on a tool-bearing chunk defers while the call
                    %% stays open (C5); the wire normally carries "".
                    chat_chunk_usage(D, Choice, Delta, St1, Frames)
            end;
        _ ->
            case maps:get(<<"function_call">>, Delta, undefined) of
                FC when FC =/= undefined, FC =/= null ->
                    %% Legacy function_call deltas do not translate.
                    {error, translate_unsupported, St};
                _ ->
                    chat_chunk_usage(D, Choice, Delta, St, Acc)
            end
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
    case maps:get(<<"finish_reason">>, Choice, undefined) of
        <<"function_call">> ->
            {error, translate_unsupported, St1};
        FR when is_binary(FR), FR =/= <<>>, not St1#sse_st.finish_sent ->
            case chat_close_open_tool(St1) of
                {error, _, _} = Err ->
                    Err;
                {ToolFrames, St2} ->
                    {StopFrames, St3} = close_open_block(St2),
                    St4 = St3#sse_st{
                        finish_sent = true,
                        stop_reason = anthropic_stop_reason(FR),
                        finish_reason = FR
                    },
                    %% message_delta is delayed until the usage chunk or [DONE].
                    chat_flush_or_delta(Delta, St4, Acc ++ ToolFrames ++ StopFrames)
            end;
        _ ->
            chat_flush_or_delta(Delta, St1, Acc)
    end.

%%%-------------------------------------------------------------------
%%% Tool-call streaming (Phase 1) — chat upstream -> anthropic face.
%%% Fragments stream through as input_json_delta; the ONLY close point
%%% (content_block_stop) is chat_close_open_tool/1, guarded by the ONE
%%% decode-at-close completeness check; text interleaving defers to the
%%% close point (C5). All pure folds over #sse_st{}.
%%%-------------------------------------------------------------------

chat_tool_entries([], St, Acc) ->
    {Acc, St};
chat_tool_entries([E | Rest], St, Acc) ->
    case chat_tool_entry(E, St, Acc) of
        {error, _, _} = Err ->
            Err;
        {Frames, St1} ->
            chat_tool_entries(Rest, St1, Acc ++ Frames)
    end.

%% Returns only its OWN frames (the chat_tool_entries fold threads Acc).
chat_tool_entry(#{<<"index">> := Idx} = E, St, _Acc) when is_integer(Idx), Idx >= 0 ->
    Fragment = maps:get(<<"arguments">>, maps:get(<<"function">>, E, #{}), undefined),
    case St#sse_st.open_tool of
        Idx ->
            chat_tool_fragment(Idx, Fragment, St);
        _ ->
            %% Different call (or none open): close the current one,
            %% then open for Idx — anthropic blocks are sequential.
            case chat_close_open_tool(St) of
                {error, _, _} = Err ->
                    Err;
                {CloseFrames, St1} ->
                    case chat_tool_open(Idx, E, St1) of
                        {error, _, _} = Err ->
                            Err;
                        {OpenFrames, St2} ->
                            case chat_tool_fragment(Idx, Fragment, St2) of
                                {error, _, _} = Err ->
                                    Err;
                                {FragFrames, St3} ->
                                    {CloseFrames ++ OpenFrames ++ FragFrames, St3}
                            end
                    end
            end
    end;
chat_tool_entry(_, St, _Acc) ->
    %% Entries always carry an integer index on the wire.
    {error, translate_unsupported, St}.

chat_tool_open(Idx, E, St) ->
    case St#sse_st.tools of
        #{Idx := _} ->
            %% Index re-opened after its call closed: the wire cannot
            %% splice a call in half; fail closed.
            {error, translate_unsupported, St};
        _ ->
            case map_size(St#sse_st.tools) >= ?TOOL_CALLS_PER_STREAM_CAP of
                true ->
                    {error, tool_args_cap, St};
                false ->
                    chat_tool_open_validated(Idx, E, St)
            end
    end.

chat_tool_open_validated(Idx, E, St) ->
    case maps:get(<<"name">>, maps:get(<<"function">>, E, #{}), undefined) of
        Name when is_binary(Name), Name =/= <<>> ->
            Id =
                case maps:get(<<"id">>, E, undefined) of
                    I when is_binary(I), I =/= <<>> -> I;
                    _ -> tool_synthetic_id()
                end,
            {StopFrames, St1} = close_open_block(St),
            BlockIdx = St1#sse_st.next_block,
            Start = anthropic_frame(
                <<"content_block_start">>,
                #{
                    <<"index">> => BlockIdx,
                    <<"content_block">> => #{
                        <<"type">> => <<"tool_use">>,
                        <<"id">> => Id,
                        <<"name">> => Name,
                        <<"input">> => #{}
                    }
                }
            ),
            TA = #tool_acc{id = Id, name = Name, block = BlockIdx},
            {StopFrames ++ [Start], St1#sse_st{
                tools = (St1#sse_st.tools)#{Idx => TA},
                open_tool = Idx,
                next_block = BlockIdx + 1
            }};
        _ ->
            {error, translate_unsupported, St}
    end.

chat_tool_fragment(Idx, Fragment, St) ->
    TA = maps:get(Idx, St#sse_st.tools),
    case Fragment of
        F when is_binary(F), F =/= <<>> ->
            PerCall = TA#tool_acc.args_bytes + byte_size(F),
            Total = St#sse_st.total_args + byte_size(F),
            case
                PerCall > ?TOOL_ARGS_PER_CALL_CAP orelse
                    Total > ?TOOL_ARGS_TOTAL_CAP
            of
                true ->
                    {error, tool_args_cap, St};
                false ->
                    Frame = anthropic_frame(
                        <<"content_block_delta">>,
                        #{
                            <<"index">> => TA#tool_acc.block,
                            <<"delta">> => #{
                                <<"type">> => <<"input_json_delta">>,
                                <<"partial_json">> => F
                            }
                        }
                    ),
                    TA1 = TA#tool_acc{
                        args = [F | TA#tool_acc.args],
                        args_bytes = PerCall
                    },
                    {[Frame], St#sse_st{
                        tools = (St#sse_st.tools)#{Idx := TA1},
                        total_args = Total
                    }}
            end;
        _ ->
            %% "" / null / absent: no bytes, no frame.
            {[], St}
    end.

%% The ONLY emitter of a tool block's content_block_stop — and only
%% after the ONE decode-at-close completeness check. Deferred text
%% flushes after the stop as sequential blocks (C5).
chat_close_open_tool(#sse_st{open_tool = undefined} = St) ->
    {[], St};
chat_close_open_tool(St) ->
    Key = St#sse_st.open_tool,
    TA = maps:get(Key, St#sse_st.tools),
    case tool_args_complete(tool_args_of(TA)) of
        ok ->
            Stop = anthropic_frame(
                <<"content_block_stop">>, #{<<"index">> => TA#tool_acc.block}
            ),
            St1 = St#sse_st{
                tools = (St#sse_st.tools)#{Key := TA#tool_acc{args = [], args_bytes = 0, closed = true}},
                open_tool = undefined
            },
            {FlushFrames, St2} = flush_deferred(St1),
            {[Stop] ++ FlushFrames, St2};
        {error, incomplete_json} ->
            %% Truncated arguments at close time: never make the call
            %% look finished — C2 error path via the caller.
            {error, translate_unsupported, St}
    end.

%%%-------------------------------------------------------------------
%%% Shared tool-call helpers (both directions)
%%%-------------------------------------------------------------------

tool_synthetic_id() ->
    <<"jfc_", (integer_to_binary(erlang:unique_integer([positive]), 16))/binary>>.

%% C5 completeness: ONE decode of the FULL concat at close time (never
%% per fragment — a UTF-8 sequence split across fragments would fake
%% truncation); zero accumulated bytes are complete as "{}".
tool_args_complete(<<>>) ->
    ok;
tool_args_complete(Bin) when is_binary(Bin) ->
    case thoas:decode(Bin) of
        {ok, Map} when is_map(Map) -> ok;
        _ -> {error, incomplete_json}
    end.

tool_args_of(#tool_acc{args = []}) ->
    <<>>;
tool_args_of(#tool_acc{args = Frags}) ->
    iolist_to_binary(lists:reverse(Frags)).

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
    case St#sse_st.open_tool of
        undefined ->
            chat_text_reasoning_emit(Delta, St, Acc);
        _ ->
            %% A tool call is open: text fragments defer to its close
            %% point and flush there as sequential blocks (C5).
            {ok, Acc, defer_delta_text(Delta, St)}
    end.

chat_text_reasoning_emit(Delta, St, Acc) ->
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

%% Defer non-empty content/reasoning while a tool call is open; kept
%% reversed, flushed in wire order with text before reasoning (the
%% chat_text_reasoning_emit order).
defer_delta_text(Delta, St) ->
    St1 = defer_field(<<"content">>, text, Delta, St),
    defer_field(<<"reasoning_content">>, thinking, Delta, St1).

defer_field(Field, Kind, Delta, St) ->
    case maps:get(Field, Delta, undefined) of
        B when is_binary(B), B =/= <<>> ->
            St#sse_st{deferred = [{Kind, B} | St#sse_st.deferred]};
        _ ->
            St
    end.

%% Flush deferred text at the tool close point as sequential blocks:
%% consecutive same-kind runs coalesce, order is preserved, and the
%% last block stays open so following deltas stream on.
flush_deferred(#sse_st{deferred = []} = St) ->
    {[], St};
flush_deferred(St) ->
    Runs = merge_runs(lists:reverse(St#sse_st.deferred), []),
    lists:foldl(
        fun({Kind, Bin}, {FAcc, SAcc}) ->
            open_block_and_delta(Kind, block_text_field(Kind), Bin, SAcc, FAcc)
        end,
        {[], St#sse_st{deferred = []}},
        Runs
    ).

merge_runs([], Acc) ->
    lists:reverse(Acc);
merge_runs([{Kind, Bin} | Rest], [{Kind, AccBin} | RAcc]) ->
    merge_runs(Rest, [{Kind, <<AccBin/binary, Bin/binary>>} | RAcc]);
merge_runs([{Kind, Bin} | Rest], Acc) ->
    merge_runs(Rest, [{Kind, Bin} | Acc]).

block_text_field(text) -> <<"text">>;
block_text_field(thinking) -> <<"thinking">>.

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
%%% translate_sse/4 — provider Chat -> client Responses (Phase 2)
%%%
%%% C1 skeleton: response.created (LAZY — the first content-bearing
%%% chunk only; role-only and reasoning-only chunks never trigger it,
%%% C4), then per output item output_item.added -> delta events ->
%%% output_item.done, then exactly ONE terminal event carrying usage on
%%% the response object (C3). response.incomplete is the legal terminal
%%% when the source finished `length` (C2 map). Chat reasoning_content
%%% deltas are DROPPED: reasoning/summary item framing waits for the
%%% 1.0 responses corpus (no event names invented here). tool_calls
%%% become function_call items (C5: arguments decode ONCE at close;
%%% text interleaved with an open call defers to its close point and
%%% flushes as a sequential message item; jitem_/jfc_ id spaces).
%%%-------------------------------------------------------------------

chat_to_responses_stream(#{type := <<"done">>}, St) ->
    %% The chat [DONE] terminator: close anything open, then the ONE
    %% terminal. [DONE] itself has NO responses-face bytes (the
    %% terminal event is the terminator, C1); finalize covers an EOF
    %% without [DONE] with the same emitters (terminal_sent guard).
    responses_finish(St);
chat_to_responses_stream(#{type := <<"chunk">>, data := D}, St) when
    is_map(D)
->
    case maps:get(<<"error">>, D, undefined) of
        Err when is_map(Err) ->
            {error, translate_unsupported, St};
        _ ->
            St1 = resp_capture_model(D, resp_capture_usage(D, St)),
            chat_resp_chunk(D, St1)
    end;
chat_to_responses_stream(#{type := _}, St) ->
    %% Undecodable data (binary): skip, never crash the fold.
    {ok, [], St}.

chat_resp_chunk(D, St) ->
    Choice = first_choice(D),
    Delta = maps:get(<<"delta">>, Choice, #{}),
    case maps:get(<<"tool_calls">>, Delta, undefined) of
        Entries when is_list(Entries), Entries =/= [] ->
            case chat_resp_tool_entries(Entries, St, []) of
                {error, _, _} = Err ->
                    Err;
                {Frames, St1} ->
                    %% finish_reason may ride the same chunk as the last
                    %% fragment (dashscope wire) — handled after entries.
                    chat_resp_finish(Choice, Delta, St1, Frames)
            end;
        _ ->
            case maps:get(<<"function_call">>, Delta, undefined) of
                FC when FC =/= undefined, FC =/= null ->
                    %% Legacy function_call deltas do not translate.
                    {error, translate_unsupported, St};
                _ ->
                    chat_resp_finish(Choice, Delta, St, [])
            end
    end.

%% Finish handling: the finish chunk CLOSES every open item; the
%% terminal itself waits for [DONE]/finalize (usage may still arrive on
%% a trailing usage-only chunk, C1 ->chat wire order).
chat_resp_finish(Choice, Delta, St, Acc) ->
    case maps:get(<<"finish_reason">>, Choice, undefined) of
        FR when is_binary(FR), FR =/= <<>>, not St#sse_st.finish_sent ->
            case resp_close_tool(St) of
                {error, _, _} = Err ->
                    Err;
                {ToolFrames, St1} ->
                    %% Content on the finish chunk still streams (mirrors
                    %% the chat face's flush-after-close order).
                    case resp_text_delta(Delta, St1) of
                        {error, _, _} = Err ->
                            Err;
                        {TextFrames, St2} ->
                            {ok, Acc ++ ToolFrames ++ TextFrames, St2#sse_st{
                                finish_sent = true, finish_reason = FR
                            }}
                    end
            end;
        _ ->
            case resp_text_delta(Delta, St) of
                {error, _, _} = Err ->
                    Err;
                {Frames, St1} ->
                    {ok, Acc ++ Frames, St1}
            end
    end.

%% Non-empty content streams through immediately UNLESS a tool call is
%% open — then it defers to the close point (C5 interleaving rule).
%% reasoning_content is dropped on this face (corpus-pending, C1).
%% Deferred bytes count against the content budget AT DEFER TIME (the
%% only accumulation point for them — the flush never re-counts).
resp_text_delta(Delta, St) ->
    case maps:get(<<"content">>, Delta, undefined) of
        C when is_binary(C), C =/= <<>> ->
            case St#sse_st.open_tool of
                undefined ->
                    resp_emit_text(C, St);
                _ ->
                    case resp_budget(St, byte_size(C)) of
                        true ->
                            {[],
                                St#sse_st{
                                    deferred = [{text, C} | St#sse_st.deferred],
                                    content_bytes = St#sse_st.content_bytes + byte_size(C)
                                }};
                        false ->
                            {error, translate_unsupported, St}
                    end
            end;
        _ ->
            {[], St}
    end.

chat_resp_tool_entries([], St, Acc) ->
    {Acc, St};
chat_resp_tool_entries([E | Rest], St, Acc) ->
    case chat_resp_tool_entry(E, St) of
        {error, _, _} = Err ->
            Err;
        {Frames, St1} ->
            chat_resp_tool_entries(Rest, St1, Acc ++ Frames)
    end.

%% Returns only its OWN frames (the chat_resp_tool_entries fold threads
%% Acc). The chat tool_calls INDEX is the accumulator key — never the
%% responses output_index (C5).
chat_resp_tool_entry(#{<<"index">> := Idx} = E, St) when is_integer(Idx), Idx >= 0 ->
    Fragment = maps:get(<<"arguments">>, maps:get(<<"function">>, E, #{}), undefined),
    case St#sse_st.open_tool of
        Idx ->
            resp_tool_fragment(Idx, Fragment, St);
        _ ->
            %% Different call (or none open): close the current one,
            %% then open for Idx — output items are sequential.
            case resp_close_tool(St) of
                {error, _, _} = Err ->
                    Err;
                {CloseFrames, St1} ->
                    case resp_tool_open_chat(Idx, E, St1) of
                        {error, _, _} = Err ->
                            Err;
                        {OpenFrames, St2} ->
                            case resp_tool_fragment(Idx, Fragment, St2) of
                                {error, _, _} = Err ->
                                    Err;
                                {FragFrames, St3} ->
                                    {CloseFrames ++ OpenFrames ++ FragFrames, St3}
                            end
                    end
            end
    end;
chat_resp_tool_entry(_, St) ->
    %% Entries always carry an integer index on the wire.
    {error, translate_unsupported, St}.

resp_tool_open_chat(Idx, E, St) ->
    case St#sse_st.tools of
        #{Idx := _} ->
            %% Index re-opened after its call closed: the wire cannot
            %% splice a call in half; fail closed.
            {error, translate_unsupported, St};
        _ ->
            case map_size(St#sse_st.tools) >= ?TOOL_CALLS_PER_STREAM_CAP of
                true ->
                    {error, tool_args_cap, St};
                false ->
                    resp_tool_open_chat_validated(Idx, E, St)
            end
    end.

resp_tool_open_chat_validated(Idx, E, St) ->
    case maps:get(<<"name">>, maps:get(<<"function">>, E, #{}), undefined) of
        Name when is_binary(Name), Name =/= <<>> ->
            CallId =
                case maps:get(<<"id">>, E, undefined) of
                    I when is_binary(I), I =/= <<>> -> I;
                    _ -> tool_synthetic_id()
                end,
            resp_tool_open_item(CallId, Name, Idx, St);
        _ ->
            {error, translate_unsupported, St}
    end.

%%%-------------------------------------------------------------------
%%% translate_sse/4 — provider Anthropic -> client Responses (Phase 2)
%%%
%%% message_start captures model/input tokens but emits NOTHING (C1
%%% lazy — the C4 failover window must not close on an eager
%%% response.created). Thinking/signature deltas are dropped (reasoning
%%% framing is corpus-pending). tool_use blocks become function_call
%%% items keyed by the anthropic content_block INDEX (never reused as
%%% output_index, C5); message_delta with an open tool block fails
%%% closed; message_stop drives the single terminal.
%%%-------------------------------------------------------------------

anthro_to_responses_stream(#{type := <<"ping">>}, St) ->
    {ok, [<<": ping\n\n">>], St};
anthro_to_responses_stream(#{type := <<"message_start">>, data := D}, St) when
    is_map(D)
->
    Msg = maps:get(<<"message">>, D, #{}),
    U = maps:get(<<"usage">>, Msg, #{}),
    InTok = int_or_undef(maps:get(<<"input_tokens">>, U, undefined)),
    Model =
        case maps:get(<<"model">>, Msg, undefined) of
            M when is_binary(M), M =/= <<>> -> M;
            _ -> undefined
        end,
    St1 = merge_tokens(St, InTok, undefined),
    {ok, [], St1#sse_st{model = first_defined(Model, St1#sse_st.model)}};
anthro_to_responses_stream(#{type := <<"message_start">>}, St) ->
    %% Undecodable data: skip, never crash the fold.
    {ok, [], St};
anthro_to_responses_stream(#{type := <<"content_block_start">>, data := D}, St) when
    is_map(D)
->
    B = maps:get(<<"content_block">>, D, #{}),
    case maps:get(<<"type">>, B, undefined) of
        <<"text">> ->
            %% Non-empty text on the start object emits as the first delta.
            case maps:get(<<"text">>, B, undefined) of
                T when is_binary(T), T =/= <<>> -> resp_wrap(resp_emit_text(T, St));
                _ -> {ok, [], St}
            end;
        <<"thinking">> ->
            %% Dropped on this face (corpus-pending reasoning framing).
            {ok, [], St};
        <<"tool_use">> ->
            anthro_resp_tool_start(D, St);
        _ ->
            {error, translate_unsupported, St}
    end;
anthro_to_responses_stream(#{type := <<"content_block_start">>}, St) ->
    {ok, [], St};
anthro_to_responses_stream(#{type := <<"content_block_delta">>, data := D}, St) when
    is_map(D)
->
    Delta = maps:get(<<"delta">>, D, #{}),
    case maps:get(<<"type">>, Delta, undefined) of
        <<"text_delta">> ->
            case maps:get(<<"text">>, Delta, undefined) of
                T when is_binary(T), T =/= <<>> -> resp_wrap(resp_emit_text(T, St));
                _ -> {ok, [], St}
            end;
        <<"thinking_delta">> ->
            {ok, [], St};
        <<"signature_delta">> ->
            {ok, [], St};
        <<"input_json_delta">> ->
            anthro_resp_tool_fragment(D, St);
        _ ->
            {ok, [], St}
    end;
anthro_to_responses_stream(#{type := <<"content_block_delta">>}, St) ->
    {ok, [], St};
anthro_to_responses_stream(#{type := <<"content_block_stop">>, data := D}, St) when
    is_map(D)
->
    case maps:get(<<"index">>, D, undefined) of
        Idx when is_map_key(Idx, St#sse_st.tools), St#sse_st.open_tool =:= Idx ->
            %% The ONLY close point: ONE decode of the full concat at
            %% close time (C5) gates output_item.done.
            case resp_close_tool(St) of
                {error, _, _} = Err -> Err;
                {Frames, St1} -> {ok, Frames, St1}
            end;
        Idx when is_map_key(Idx, St#sse_st.tools) ->
            %% Duplicate stop for an already-closed call: no-op (a
            %% second output_item.done must never be emitted).
            {ok, [], St};
        _ ->
            %% Text/thinking block stop: the message item stays open so
            %% later text deltas continue the same output item.
            {ok, [], St}
    end;
anthro_to_responses_stream(#{type := <<"content_block_stop">>}, St) ->
    {ok, [], St};
anthro_to_responses_stream(#{type := <<"message_delta">>, data := D}, St) when
    is_map(D)
->
    case St#sse_st.open_tool of
        undefined ->
            StopIn = maps:get(<<"stop_reason">>, maps:get(<<"delta">>, D, #{}), undefined),
            U = maps:get(<<"usage">>, D, #{}),
            OutTok = int_or_undef(maps:get(<<"output_tokens">>, U, undefined)),
            %% C3 merge rule: message_start.input_tokens +
            %% message_delta.output_tokens. message_delta's repeated
            %% input_tokens is IGNORED (the message_start value is
            %% authoritative — same choice as the ->chat face).
            St1 = merge_tokens(St, undefined, OutTok),
            Stop =
                case StopIn of
                    S when is_binary(S), S =/= <<>> -> S;
                    _ -> undefined
                end,
            {ok, [], St1#sse_st{stop_reason = first_defined(Stop, St1#sse_st.stop_reason)}};
        _ ->
            %% A stop while a tool block is still open: upstream skipped
            %% content_block_stop; never make the call look finished (C5).
            {error, translate_unsupported, St}
    end;
anthro_to_responses_stream(#{type := <<"message_delta">>}, St) ->
    {ok, [], St};
anthro_to_responses_stream(#{type := <<"message_stop">>}, St) ->
    responses_finish(St);
anthro_to_responses_stream(#{type := <<"error">>}, St) ->
    {error, translate_unsupported, St};
anthro_to_responses_stream(#{type := _}, St) ->
    %% Unknown events: no-op.
    {ok, [], St}.

anthro_resp_tool_start(D, St) ->
    case maps:get(<<"index">>, D, undefined) of
        Idx when is_integer(Idx), Idx >= 0 ->
            case St#sse_st.tools of
                #{Idx := _} ->
                    %% Duplicate block index: upstream bug, fail closed.
                    {error, translate_unsupported, St};
                _ ->
                    case map_size(St#sse_st.tools) >= ?TOOL_CALLS_PER_STREAM_CAP of
                        true ->
                            {error, tool_args_cap, St};
                        false ->
                            anthro_resp_tool_start_validated(Idx, D, St)
                    end
            end;
        _ ->
            {error, translate_unsupported, St}
    end.

anthro_resp_tool_start_validated(Idx, D, St) ->
    B = maps:get(<<"content_block">>, D, #{}),
    case maps:get(<<"name">>, B, undefined) of
        Name when is_binary(Name), Name =/= <<>> ->
            CallId =
                case maps:get(<<"id">>, B, undefined) of
                    I when is_binary(I), I =/= <<>> -> I;
                    _ -> tool_synthetic_id()
                end,
            resp_wrap(resp_tool_open_item(CallId, Name, Idx, St));
        _ ->
            {error, translate_unsupported, St}
    end.

anthro_resp_tool_fragment(D, St) ->
    case maps:get(<<"partial_json">>, maps:get(<<"delta">>, D, #{}), undefined) of
        P when is_binary(P), P =/= <<>> ->
            resp_wrap(resp_tool_fragment(maps:get(<<"index">>, D, undefined), P, St));
        _ ->
            %% Empty fragment: no bytes, no frame.
            {ok, [], St}
    end.

%%%-------------------------------------------------------------------
%%% Shared responses-face helpers (both source protocols)
%%%-------------------------------------------------------------------

%% Tag a helper's {Frames, St} result as a translate_sse success;
%% tagged error tuples pass through unchanged.
resp_wrap({error, _, _} = Err) ->
    Err;
resp_wrap({Frames, St}) ->
    {ok, Frames, St}.

%% Envelope capture: model + usage only — the response id is ALWAYS
%% janus-synthesized (jresp_; the upstream chatcmpl-/msg_ id is a
%% different id space, C5).
resp_capture_model(D, #sse_st{model = undefined} = St) ->
    case maps:get(<<"model">>, D, undefined) of
        M when is_binary(M), M =/= <<>> -> St#sse_st{model = M};
        _ -> St
    end;
resp_capture_model(_, St) ->
    St.

resp_capture_usage(D, St) ->
    case maps:get(<<"usage">>, D, undefined) of
        UMap when is_map(UMap) ->
            In = int_or_undef(maps:get(<<"prompt_tokens">>, UMap, undefined)),
            Out = int_or_undef(maps:get(<<"completion_tokens">>, UMap, undefined)),
            merge_tokens(St, In, Out);
        _ ->
            St
    end.

%% 4MiB total-content budget (C5): bounds text + argument bytes (the
%% terminal response.output reconstruction reuses the accumulated
%% bytes, so this bounds both).
resp_budget(St, N) ->
    St#sse_st.content_bytes + N =< ?STREAM_CONTENT_CAP.

%% Lazy skeleton (C1): response.created exactly once, on the first
%% content-bearing event. Usage ZEROED here (framing, not a count —
%% same convention as the ->anthropic message_start); totals land on
%% the terminal event.
resp_ensure_created(#sse_st{role_sent = true} = St) ->
    {[], St};
resp_ensure_created(St) ->
    Id = responses_resp_id(),
    Frame = responses_frame(
        <<"response.created">>,
        #{
            <<"type">> => <<"response.created">>,
            <<"response">> => #{
                <<"id">> => Id,
                <<"object">> => <<"response">>,
                <<"status">> => <<"in_progress">>,
                <<"model">> => bin_or(St#sse_st.model, <<"unknown">>),
                <<"usage">> => #{
                    <<"input_tokens">> => 0,
                    <<"output_tokens">> => 0,
                    <<"total_tokens">> => 0
                }
            }
        }
    ),
    {[Frame], St#sse_st{role_sent = true, resp_id = Id}}.

%% Open the message output item if none is open, then the text delta.
%% Budget-checked and counted HERE (direct/anthropic text path); the
%% deferred flush uses resp_text_frames/2 directly (already counted at
%% defer time — every byte counts against the cap exactly once).
resp_emit_text(C, St) ->
    case resp_budget(St, byte_size(C)) of
        false ->
            {error, translate_unsupported, St};
        true ->
            resp_text_frames(C, St#sse_st{
                content_bytes = St#sse_st.content_bytes + byte_size(C)
            })
    end.

%% Build created/added/delta frames and append the text to the open
%% message item. Never fails (budget decided by the caller).
resp_text_frames(C, St) ->
    {Created, St1} = resp_ensure_created(St),
    {Added, St2} = resp_ensure_msg_item(St1),
    #{id := MsgId, index := MsgIdx} = St2#sse_st.msg_item,
    Delta = responses_frame(
        <<"response.output_text.delta">>,
        #{
            <<"type">> => <<"response.output_text.delta">>,
            <<"item_id">> => MsgId,
            <<"output_index">> => MsgIdx,
            <<"content_index">> => 0,
            <<"delta">> => C
        }
    ),
    #{text := Rev} = St2#sse_st.msg_item,
    St3 = St2#sse_st{msg_item = (St2#sse_st.msg_item)#{text := [C | Rev]}},
    {Created ++ Added ++ [Delta], St3}.

resp_ensure_msg_item(#sse_st{msg_item = undefined} = St) ->
    Id = responses_item_id(),
    Idx = St#sse_st.item_seq,
    Frame = responses_frame(
        <<"response.output_item.added">>,
        #{
            <<"type">> => <<"response.output_item.added">>,
            <<"output_index">> => Idx,
            <<"item">> => #{
                <<"id">> => Id,
                <<"type">> => <<"message">>,
                <<"status">> => <<"in_progress">>,
                <<"role">> => <<"assistant">>,
                <<"content">> => []
            }
        }
    ),
    {[Frame], St#sse_st{
        msg_item = #{id => Id, index => Idx, text => []},
        item_seq = Idx + 1
    }};
resp_ensure_msg_item(St) ->
    {[], St}.

%% Close the open message item (output_item.done with the full text);
%% no-op when none is open. Text items always have content (they only
%% open on the first delta).
resp_msg_close(#sse_st{msg_item = undefined} = St) ->
    {[], St};
resp_msg_close(St) ->
    #{id := Id, index := Idx, text := Rev} = St#sse_st.msg_item,
    Full = iolist_to_binary(lists:reverse(Rev)),
    Item = #{
        <<"id">> => Id,
        <<"type">> => <<"message">>,
        <<"status">> => <<"completed">>,
        <<"role">> => <<"assistant">>,
        <<"content">> => [
            #{<<"type">> => <<"output_text">>, <<"text">> => Full, <<"annotations">> => []}
        ]
    },
    Frame = responses_frame(
        <<"response.output_item.done">>,
        #{
            <<"type">> => <<"response.output_item.done">>,
            <<"output_index">> => Idx,
            <<"item">> => Item
        }
    ),
    {[Frame], St#sse_st{msg_item = undefined, items = [Item | St#sse_st.items]}}.

%% Open a function_call output item: closes the open message item
%% first (items are sequential), flushes the lazy skeleton, allocates
%% the responses output_index and the jitem_ item id. `Key` is the
%% SOURCE-local index space (chat tool_calls index / anthropic block
%% index) — only ever an accumulator key, never on the wire (C5).
resp_tool_open_item(CallId, Name, Key, St) ->
    {MsgFrames, St1} = resp_msg_close(St),
    {Created, St2} = resp_ensure_created(St1),
    ItemId = responses_item_id(),
    Idx = St2#sse_st.item_seq,
    Added = responses_frame(
        <<"response.output_item.added">>,
        #{
            <<"type">> => <<"response.output_item.added">>,
            <<"output_index">> => Idx,
            <<"item">> => #{
                <<"id">> => ItemId,
                <<"type">> => <<"function_call">>,
                <<"status">> => <<"in_progress">>,
                <<"call_id">> => CallId,
                <<"name">> => Name,
                <<"arguments">> => <<>>
            }
        }
    ),
    TA = #tool_acc{id = CallId, name = Name, item_id = ItemId, resp_index = Idx},
    {MsgFrames ++ Created ++ [Added], St2#sse_st{
        tools = (St2#sse_st.tools)#{Key => TA},
        open_tool = Key,
        item_seq = Idx + 1
    }}.

%% Argument fragment: streams through immediately; bytes accumulate
%% for the ONE decode at close. Caps: 256KiB/call, 1MiB total (C5);
%% the 4MiB content budget covers the reconstruction.
resp_tool_fragment(Idx, Fragment, St) ->
    case St#sse_st.tools of
        #{Idx := #tool_acc{} = TA0} when St#sse_st.open_tool =:= Idx ->
            case Fragment of
                F when is_binary(F), F =/= <<>> ->
                    PerCall = TA0#tool_acc.args_bytes + byte_size(F),
                    Total = St#sse_st.total_args + byte_size(F),
                    case
                        PerCall > ?TOOL_ARGS_PER_CALL_CAP orelse
                            Total > ?TOOL_ARGS_TOTAL_CAP
                    of
                        true ->
                            {error, tool_args_cap, St};
                        false ->
                            case resp_budget(St, byte_size(F)) of
                                false ->
                                    {error, translate_unsupported, St};
                                true ->
                                    Delta = responses_frame(
                                        <<"response.function_call_arguments.delta">>,
                                        #{
                                            <<"type">> => <<"response.function_call_arguments.delta">>,
                                            <<"item_id">> => TA0#tool_acc.item_id,
                                            <<"output_index">> => TA0#tool_acc.resp_index,
                                            <<"delta">> => F
                                        }
                                    ),
                                    TA1 = TA0#tool_acc{
                                        args = [F | TA0#tool_acc.args], args_bytes = PerCall
                                    },
                                    {[Delta], St#sse_st{
                                        tools = (St#sse_st.tools)#{Idx := TA1},
                                        total_args = Total,
                                        content_bytes = St#sse_st.content_bytes + byte_size(F)
                                    }}
                            end
                    end;
                _ ->
                    %% ""/null/absent: no bytes, no frame.
                    {[], St}
            end;
        #{Idx := _} ->
            %% Fragment after the call closed (or before it opened):
            %% upstream bug, fail closed.
            {error, translate_unsupported, St};
        _ ->
            {error, translate_unsupported, St}
    end.

%% The ONLY emitter of a function_call item's output_item.done — and
%% only after the ONE decode-at-close completeness check. Deferred
%% interleaved text flushes after the done, as a sequential message
%% item (C5). Zero accumulated bytes close with "{}".
resp_close_tool(#sse_st{open_tool = undefined} = St) ->
    {[], St};
resp_close_tool(St) ->
    Key = St#sse_st.open_tool,
    TA = maps:get(Key, St#sse_st.tools),
    Args = tool_args_of(TA),
    case tool_args_complete(Args) of
        ok ->
            Full =
                case Args of
                    <<>> -> <<"{}">>;
                    _ -> Args
                end,
            Item = #{
                <<"id">> => TA#tool_acc.item_id,
                <<"type">> => <<"function_call">>,
                <<"status">> => <<"completed">>,
                <<"call_id">> => TA#tool_acc.id,
                <<"name">> => TA#tool_acc.name,
                <<"arguments">> => Full
            },
            Done = responses_frame(
                <<"response.output_item.done">>,
                #{
                    <<"type">> => <<"response.output_item.done">>,
                    <<"output_index">> => TA#tool_acc.resp_index,
                    <<"item">> => Item
                }
            ),
            St1 = St#sse_st{
                tools = (St#sse_st.tools)#{Key := TA#tool_acc{args = [], args_bytes = 0, closed = true}},
                open_tool = undefined,
                items = [Item | St#sse_st.items]
            },
            {FlushFrames, St2} = resp_flush_deferred(St1),
            {[Done] ++ FlushFrames, St2};
        {error, incomplete_json} ->
            %% Truncated arguments at close time: output_item.done must
            %% never follow a truncated call — C2 error path via the
            %% caller (response.failed replaces the terminal).
            {error, translate_unsupported, St}
    end.

%% Flush deferred text at the tool close point: consecutive text runs
%% coalesce (merge_runs), order is preserved, and each run continues
%% into a (possibly new) sequential message item. Bytes were counted at
%% DEFER time — the flush emits without re-counting.
resp_flush_deferred(#sse_st{deferred = []} = St) ->
    {[], St};
resp_flush_deferred(St) ->
    Runs = merge_runs(lists:reverse(St#sse_st.deferred), []),
    lists:foldl(
        fun({text, Bin}, {FAcc, SAcc}) ->
            {F, S2} = resp_text_frames(Bin, SAcc),
            {FAcc ++ F, S2}
        end,
        {[], St#sse_st{deferred = []}},
        Runs
    ).

%% Terminator driver for [DONE] / message_stop: close anything open,
%% then exactly ONE terminal event.
responses_finish(#sse_st{terminal_sent = true} = St) ->
    {ok, [], St};
responses_finish(St) ->
    case resp_close_tool(St) of
        {error, _, _} = Err ->
            Err;
        {ToolFrames, St1} ->
            {Frames, St2} = responses_finish_tail(St1),
            {ok, ToolFrames ++ Frames, St2}
    end.

%% Close the open message item, ensure the skeleton, emit the ONE
%% terminal. Usage totals ride the response object (C3); nulls when
%% the upstream reported nothing (never invented).
responses_finish_tail(St) ->
    {MsgFrames, St1} = resp_msg_close(St),
    {TermFrames, St2} = resp_terminal(St1),
    {MsgFrames ++ TermFrames, St2}.

resp_terminal(St0) ->
    {Created, St} = resp_ensure_created(St0),
    Incomplete = responses_incomplete(St),
    Resp0 = #{
        <<"id">> => resp_id_of(St),
        <<"object">> => <<"response">>,
        <<"status">> =>
            case Incomplete of
                true -> <<"incomplete">>;
                false -> <<"completed">>
            end,
        <<"model">> => bin_or(St#sse_st.model, <<"unknown">>),
        <<"output">> => lists:reverse(St#sse_st.items),
        <<"usage">> => resp_usage(St)
    },
    {Ev, Resp} =
        case Incomplete of
            true ->
                {<<"response.incomplete">>, Resp0#{
                    <<"incomplete_details">> => #{<<"reason">> => <<"max_output_tokens">>}
                }};
            false ->
                {<<"response.completed">>, Resp0}
        end,
    Frame = responses_frame(Ev, #{<<"type">> => Ev, <<"response">> => Resp}),
    {Created ++ [Frame], St#sse_st{terminal_sent = true, usage_sent = true}}.

%% C2 map: chat finish_reason=length / anthropic stop_reason=max_tokens
%% -> response.incomplete(incomplete_details.reason=max_output_tokens).
responses_incomplete(St) ->
    St#sse_st.finish_reason =:= <<"length">> orelse St#sse_st.stop_reason =:= <<"max_tokens">>.

resp_id_of(#sse_st{resp_id = Id}) when is_binary(Id), Id =/= <<>> ->
    Id;
resp_id_of(_) ->
    responses_resp_id().

resp_usage(St) ->
    In = St#sse_st.in_tokens,
    Out = St#sse_st.out_tokens,
    #{
        <<"input_tokens">> => resp_usage_val(In),
        <<"output_tokens">> => resp_usage_val(Out),
        <<"total_tokens">> => resp_total(In, Out)
    }.

resp_usage_val(undefined) -> null;
resp_usage_val(N) when is_integer(N) -> N.

resp_total(In, Out) when is_integer(In), is_integer(Out) -> In + Out;
resp_total(_, _) -> null.

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
finalize_sse(openai_chat, normal, #sse_st{open_tool = Open} = St) when Open =/= undefined ->
    %% EOF inside a tool call (upstream cut): fragments may already be
    %% out; the finish chunk must NOT follow a truncated call (C5) —
    %% the C2 error event replaces the terminator instead.
    finalize_sse(openai_chat, {error, upstream, <<"stream ended inside a tool call">>}, St);
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
finalize_sse(anthropic_messages, normal, #sse_st{open_tool = Open} = St) when Open =/= undefined ->
    %% EOF inside a tool call: the ONE decode at close decides —
    %% complete args close normally, truncated args take the C2 error
    %% path (a half-open block is closed by the error event itself).
    case chat_close_open_tool(St) of
        {error, _, _} ->
            finalize_sse(
                anthropic_messages, {error, upstream, <<"truncated tool arguments">>}, St
            );
        {ToolFrames, St1} ->
            {Frames, St2} = finalize_anthropic_normal(St1),
            {ok, ToolFrames ++ Frames, St2#sse_st{terminal_sent = true}}
    end;
finalize_sse(anthropic_messages, normal, St) ->
    {Frames, St1} = finalize_anthropic_normal(St),
    {ok, Frames, St1#sse_st{terminal_sent = true}};
finalize_sse(openai_responses, normal, #sse_st{open_tool = Open} = St) when Open =/= undefined ->
    %% EOF inside a tool call: the ONE decode at close decides —
    %% complete args close the item normally, truncated args take the
    %% C2 error path (output_item.done must never follow a truncated
    %% call, C5).
    case resp_close_tool(St) of
        {error, _, _} ->
            finalize_sse(
                openai_responses, {error, upstream, <<"truncated tool arguments">>}, St
            );
        {ToolFrames, St1} ->
            {Frames, St2} = responses_finish_tail(St1),
            {ok, ToolFrames ++ Frames, St2#sse_st{terminal_sent = true}}
    end;
finalize_sse(openai_responses, normal, St) ->
    {Frames, St1} = responses_finish_tail(St),
    {ok, Frames, St1#sse_st{terminal_sent = true}};
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
    {ok, [Err, StopFrame], St#sse_st{terminal_sent = true}};
finalize_sse(openai_responses, {error, Kind, Msg}, St) ->
    %% C2: a failure before any content frame still flushes the OPENING
    %% skeleton (responses SDKs require response.created), then
    %% response.failed ALONE — no completed may follow a failure, and
    %% usage never rides the failure wire (usage row only).
    {Created, St1} = resp_ensure_created(St),
    Failed = responses_frame(
        <<"response.failed">>,
        #{
            <<"type">> => <<"response.failed">>,
            <<"response">> => #{
                <<"id">> => resp_id_of(St1),
                <<"object">> => <<"response">>,
                <<"status">> => <<"failed">>,
                <<"error">> => #{
                    <<"type">> => error_type(Kind),
                    <<"code">> => error_type(Kind),
                    <<"message">> => trunc_200(Msg)
                }
            }
        }
    ),
    {ok, Created ++ [Failed], St1#sse_st{terminal_sent = true}}.

%% The anthropic normal-EOF tail: start (if never sent), a zero-content
%% block for an empty face, close, delayed message_delta, message_stop.
finalize_anthropic_normal(St) ->
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
    {StartIfMissing ++ ZeroFrames ++ CloseFrames ++ DeltaFrames ++ [StopFrame], St3}.

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
