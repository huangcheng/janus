%%%-------------------------------------------------------------------
%%% @doc OpenAI-compatible chat/completions and responses upstream via gun.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_providers_openai).

-export([chat_completions/3, chat_completions/4, responses/3, responses/4, user_agent/0]).

-spec user_agent() -> binary().
user_agent() ->
    janus_providers_http:user_agent().

%% Legacy: always non-stream.
-spec chat_completions(map(), binary(), map()) ->
    {ok, pos_integer(), map(), binary()}
    | {error, term()}.
chat_completions(Route, Body, ReqMap) ->
    chat_completions(Route, Body, ReqMap, #{stream => false}).

-spec chat_completions(map(), binary(), map(), map()) ->
    {ok, pos_integer(), map(), binary()}
    | {ok, stream, pos_integer(), map(), fun((fun((binary()) -> ok)) -> ok | {error, term()})}
    | {error, term()}.
chat_completions(Route, _Body, ReqMap, Opts) when is_map(Route), is_map(ReqMap), is_map(Opts) ->
    call(Route, ReqMap, <<"/chat/completions">>, Opts).

-spec responses(map(), binary(), map()) ->
    {ok, pos_integer(), map(), binary()}
    | {error, term()}.
responses(Route, Body, ReqMap) ->
    responses(Route, Body, ReqMap, #{stream => false}).

-spec responses(map(), binary(), map(), map()) ->
    {ok, pos_integer(), map(), binary()}
    | {ok, stream, pos_integer(), map(), fun((fun((binary()) -> ok)) -> ok | {error, term()})}
    | {error, term()}.
responses(Route, _Body, ReqMap, Opts) when is_map(Route), is_map(ReqMap), is_map(Opts) ->
    %% Gateway is stateless — DEFAULT store off when the client
    %% didn't choose (audit find: forcing false also overwrote an
    %% explicit client store=true on the native passthrough).
    ReqMap1 =
        case maps:get(<<"store">>, ReqMap, undefined) of
            undefined -> ReqMap#{<<"store">> => false};
            _ -> ReqMap
        end,
    call(Route, ReqMap1, <<"/responses">>, Opts).

call(Route, ReqMap, PathSuffix, Opts) ->
    Stream = maps:get(stream, Opts, false) =:= true,
    case resolve_upstream(Route, ReqMap, PathSuffix, Stream) of
        {ok, Target, Headers, OutBody} ->
            case Stream of
                false ->
                    case janus_providers_http:post(Target, Headers, OutBody) of
                        {ok, Status, RespHeaders, RespBody} ->
                            {ok, Status, RespHeaders, RespBody};
                        {error, _} = Err ->
                            Err
                    end;
                true ->
                    case janus_providers_http:post_stream(Target, Headers, OutBody) of
                        {ok, Status, RespHeaders, Drain} ->
                            {ok, stream, Status, RespHeaders, Drain};
                        {error, _} = Err ->
                            Err
                    end
            end;
        {error, _} = Err ->
            Err
    end.

resolve_upstream(#{provider_id := Pid, provider_key := KeyMeta} = Route, ReqMap, PathSuffix, Stream) ->
    case janus_catalog:lookup_provider(Pid) of
        {ok, #{base_url := BaseUrl0, enabled := true}} ->
            case janus_providers_http:decrypt_key(KeyMeta) of
                {ok, Token} ->
                    BaseUrl = iolist_to_binary(BaseUrl0),
                    case janus_providers_http:parse_base(BaseUrl) of
                        {ok, Host, Port, BasePath, Tls} ->
                            Path = janus_providers_http:join_path(BasePath, PathSuffix),
                            UpstreamModel = upstream_model(Route, ReqMap),
                            OutMap0 = ReqMap#{<<"model">> => UpstreamModel},
                            OutMap =
                                case Stream of
                                    true -> OutMap0#{<<"stream">> => true};
                                    false -> OutMap0#{<<"stream">> => false}
                                end,
                            OutBody = thoas:encode(OutMap),
                            Headers = [
                                {<<"authorization">>, <<"Bearer ", Token/binary>>},
                                {<<"content-type">>, <<"application/json">>},
                                {<<"accept">>,
                                    case Stream of
                                        true -> <<"text/event-stream">>;
                                        false -> <<"application/json">>
                                    end},
                                {<<"user-agent">>, user_agent()}
                            ],
                            Target = #{host => Host, port => Port, path => Path, tls => Tls},
                            {ok, Target, Headers, OutBody};
                        {error, _} = Err ->
                            Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        {ok, #{enabled := false}} ->
            {error, provider_disabled};
        error ->
            {error, provider_not_found}
    end;
resolve_upstream(_, _, _, _) ->
    {error, missing_provider_key}.

upstream_model(Route, ReqMap) ->
    case maps:get(upstream_model_id, Route, undefined) of
        undefined -> maps:get(<<"model">>, ReqMap, <<>>);
        null -> maps:get(<<"model">>, ReqMap, <<>>);
        UM -> UM
    end.
