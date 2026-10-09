%%%-------------------------------------------------------------------
%%% @doc Anthropic Messages API upstream via gun.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_providers_anthropic).

-export([messages/3, messages/4, anthropic_version/0, prepare/3]).

-define(DEFAULT_VERSION, <<"2023-06-01">>).

-spec anthropic_version() -> binary().
anthropic_version() ->
    case os:getenv("JANUS_ANTHROPIC_VERSION") of
        false -> ?DEFAULT_VERSION;
        "" -> ?DEFAULT_VERSION;
        Val -> list_to_binary(Val)
    end.

%% Build self-contained job fields for remote dispatch (no gun I/O).
-spec prepare(map(), map(), boolean()) ->
    {ok, #{
        url := binary(),
        method := post,
        headers := [{binary(), binary()}],
        body := binary()
    }}
    | {error, term()}.
prepare(Route, ReqMap, Stream) when is_map(Route), is_map(ReqMap), is_boolean(Stream) ->
    case resolve_upstream(Route, ReqMap, Stream) of
        {ok, Target, Headers, OutBody} ->
            {ok, #{
                url => janus_providers_http:target_url(Target),
                method => post,
                headers => Headers,
                body => OutBody
            }};
        {error, _} = Err ->
            Err
    end.

-spec messages(map(), binary(), map()) ->
    {ok, pos_integer(), map(), binary()}
    | {error, term()}.
messages(Route, Body, ReqMap) ->
    messages(Route, Body, ReqMap, #{stream => false}).

-spec messages(map(), binary(), map(), map()) ->
    {ok, pos_integer(), map(), binary()}
    | {ok, stream, pos_integer(), map(), fun((fun((binary()) -> ok)) -> ok | {error, term()})}
    | {error, term()}.
messages(Route, _Body, ReqMap, Opts) when is_map(Route), is_map(ReqMap), is_map(Opts) ->
    Stream = maps:get(stream, Opts, false) =:= true,
    case resolve_upstream(Route, ReqMap, Stream) of
        {ok, Target, Headers, OutBody} ->
            case Stream of
                false ->
                    janus_providers_http:post(Target, Headers, OutBody);
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

resolve_upstream(#{provider_id := Pid, provider_key := KeyMeta} = Route, ReqMap, Stream) ->
    case janus_catalog:lookup_provider(Pid) of
        {ok, #{base_url := BaseUrl0, enabled := true}} ->
            case janus_providers_http:decrypt_key(KeyMeta) of
                {ok, Token} ->
                    BaseUrl = iolist_to_binary(BaseUrl0),
                    case janus_providers_http:parse_base(BaseUrl) of
                        {ok, Host, Port, BasePath, Tls} ->
                            Path = janus_providers_http:join_path(BasePath, <<"/messages">>),
                            UpstreamModel = upstream_model(Route, ReqMap),
                            OutMap0 = ReqMap#{<<"model">> => UpstreamModel},
                            OutMap =
                                case Stream of
                                    true -> OutMap0#{<<"stream">> => true};
                                    false -> OutMap0#{<<"stream">> => false}
                                end,
                            OutBody = thoas:encode(OutMap),
                            Headers = [
                                {<<"x-api-key">>, Token},
                                {<<"anthropic-version">>, anthropic_version()},
                                {<<"content-type">>, <<"application/json">>},
                                {<<"accept">>,
                                    case Stream of
                                        true -> <<"text/event-stream">>;
                                        false -> <<"application/json">>
                                    end},
                                {<<"user-agent">>, janus_providers_http:user_agent()}
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
resolve_upstream(_, _, _) ->
    {error, missing_provider_key}.

upstream_model(Route, ReqMap) ->
    case maps:get(upstream_model_id, Route, undefined) of
        undefined -> maps:get(<<"model">>, ReqMap, <<>>);
        null -> maps:get(<<"model">>, ReqMap, <<>>);
        UM -> UM
    end.
