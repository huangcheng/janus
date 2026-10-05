%%%-------------------------------------------------------------------
%%% @doc Extract normalized token usage #{prompt, completion} from
%%% provider response bodies and from head+tail captures of SSE streams.
%%% Pure and total: all failures return `undefined`.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_usage_parse).

-export([from_response_body/2, from_sse/3]).

-spec from_response_body(atom(), binary()) ->
    #{prompt := non_neg_integer(), completion := non_neg_integer()} | undefined.
from_response_body(_Proto, Body) when is_binary(Body) ->
    case thoas:decode(Body) of
        {ok, Map} when is_map(Map) -> usage_in_map(Map);
        _ -> undefined
    end;
from_response_body(_, _) ->
    undefined.

%% Head holds the first ~4KB (Anthropic message_start input tokens);
%% tail the last ~16KB (OpenAI terminal usage chunk, Anthropic
%% message_delta output tokens, Responses response.completed).
-spec from_sse(atom(), binary(), binary()) ->
    #{prompt := non_neg_integer(), completion := non_neg_integer()} | undefined.
from_sse(_Proto, Head, Tail) when is_binary(Head), is_binary(Tail) ->
    Blob = <<Head/binary, "\n", Tail/binary>>,
    Lines = binary:split(Blob, <<"\n">>, [global]),
    case lists:filtermap(fun data_line_usage/1, Lines) of
        [] -> usage_regex_fallback(Blob);
        Usages ->
            %% Any decoded usage object is a REAL report — even {0, 0}
            %% (symmetric with from_response_body/2).
            P = lists:max([maps:get(prompt, U, 0) || U <- Usages]),
            C = lists:max([maps:get(completion, U, 0) || U <- Usages]),
            #{prompt => P, completion => C}
    end;
from_sse(_, _, _) ->
    undefined.

%% Some terminal events (Responses response.completed embeds the whole
%% response and can exceed the tail window) never decode as one line —
%% but their trailing usage object survives. Extract the last
%% "usage":{...} fragment (one nesting level for *_details objects).
usage_regex_fallback(Blob) ->
    Pattern = <<"\"usage\"\\s*:\\s*(\\{(?:[^{}]|\\{[^{}]*\\})*\\})">>,
    case re:run(Blob, Pattern, [{capture, all_but_first, binary}, global]) of
        {match, Ms} ->
            case thoas:decode(lists:last(lists:flatten(Ms))) of
                {ok, U} when is_map(U) -> norm(U);
                _ -> undefined
            end;
        nomatch ->
            undefined
    end.

%%% internal

data_line_usage(<<"data:", Rest/binary>>) ->
    Json = string:trim(Rest),
    case thoas:decode(Json) of
        {ok, Map} when is_map(Map) ->
            case usage_in_map(Map) of
                undefined -> false;
                U -> {true, U}
            end;
        _ ->
            false
    end;
data_line_usage(_) ->
    false.

usage_in_map(Map) ->
    case maps:get(<<"usage">>, Map, undefined) of
        U when is_map(U) -> norm(U);
        _ -> nested(Map)
    end.

%% openai_responses nests usage under "response" (response.completed);
%% Anthropic message_start nests it under "message".
nested(Map) ->
    case maps:get(<<"response">>, Map, undefined) of
        R when is_map(R) -> norm(maps:get(<<"usage">>, R, #{}));
        _ ->
            case maps:get(<<"message">>, Map, undefined) of
                M when is_map(M) -> norm(maps:get(<<"usage">>, M, #{}));
                _ -> undefined
            end
    end.

norm(U) when is_map(U), map_size(U) > 0 ->
    Base = first_int(U, [<<"prompt_tokens">>, <<"input_tokens">>]),
    Cache =
        first_int(U, [<<"cache_creation_input_tokens">>]) +
            first_int(U, [<<"cache_read_input_tokens">>]),
    P = Base + Cache,
    C = first_int(U, [<<"completion_tokens">>, <<"output_tokens">>]),
    %% A usage object carrying any recognized key is a REAL report — even
    %% a genuine {0, 0} — and must not collapse to "unreported".
    case has_known_key(U) of
        true -> #{prompt => P, completion => C};
        false -> undefined
    end;
norm(_) ->
    undefined.

has_known_key(U) ->
    lists:any(
        fun(K) -> maps:is_key(K, U) end,
        [
            <<"prompt_tokens">>,
            <<"input_tokens">>,
            <<"completion_tokens">>,
            <<"output_tokens">>,
            <<"cache_creation_input_tokens">>,
            <<"cache_read_input_tokens">>
        ]
    ).

first_int(Map, [K | Ks]) ->
    case Map of
        #{K := V} when is_integer(V), V >= 0 -> V;
        _ -> first_int(Map, Ks)
    end;
first_int(_, []) ->
    0.
