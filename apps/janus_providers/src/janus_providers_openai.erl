%%%-------------------------------------------------------------------
%%% @doc OpenAI-compatible chat/completions and responses upstream via gun.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_providers_openai).

-export([
    chat_completions/3,
    chat_completions/4,
    responses/3,
    responses/4,
    decisions/3,
    decisions/4,
    user_agent/0,
    %% Master→worker job material (url/headers/body) without gun I/O.
    prepare/4
]).
%% Exported for eunit (pure forward-shape helpers, no side effects).
-export([decisions_out_map/2, decisions_headers/1]).

%% OpenAI Decisions (spec 2026-10-07): native non-stream forward.
%% Gun timeouts: 60 s to first byte (§4.2), 60 s per body chunk.
%% Response cap 4 MiB — answers are small; a runaway upstream must not
%% balloon gateway memory (§4.2 upstream_response_too_large).
-define(DECISIONS_CONNECT_MS, 5000).
-define(DECISIONS_TTFB_MS, 60000).
-define(DECISIONS_BODY_MS, 60000).
-define(DECISIONS_MAX_RESPONSE, 4 * 1024 * 1024).

-spec user_agent() -> binary().
user_agent() ->
    janus_providers_http:user_agent().

%% Build self-contained job fields for remote dispatch (same material
%% chat_completions/responses/decisions would send via gun).
-spec prepare(chat_completions | responses | decisions, map(), map(), boolean()) ->
    {ok, #{
        url := binary(),
        method := post,
        headers := [{binary(), binary()}],
        body := binary()
    }}
    | {error, term()}.
prepare(chat_completions, Route, ReqMap, Stream) when is_map(Route), is_map(ReqMap) ->
    materialize(Route, ReqMap, <<"/chat/completions">>, Stream);
prepare(responses, Route, ReqMap, Stream) when is_map(Route), is_map(ReqMap) ->
    ReqMap1 =
        case maps:get(<<"store">>, ReqMap, undefined) of
            undefined -> ReqMap#{<<"store">> => false};
            _ -> ReqMap
        end,
    materialize(Route, ReqMap1, <<"/responses">>, Stream);
prepare(decisions, Route, ReqMap, _Stream) when is_map(Route), is_map(ReqMap) ->
    case resolve_decisions(Route, ReqMap) of
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

materialize(Route, ReqMap, PathSuffix, Stream) ->
    case resolve_upstream(Route, ReqMap, PathSuffix, Stream) of
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

%%--------------------------------------------------------------------
%% OpenAI Decisions forward (spec 2026-10-07 §4.3)
%%--------------------------------------------------------------------

%% Legacy arity: always non-stream (Decisions has no stream mode at
%% all — §4.6).
-spec decisions(map(), binary(), map()) ->
    {ok, pos_integer(), map(), binary()}
    | {error, term()}.
decisions(Route, Body, ReqMap) ->
    decisions(Route, Body, ReqMap, #{}).

%% D15 falsifiable error tags: {open,_} / {await_up,_} happen BEFORE
%% any request byte is written (failover-eligible per the proxy);
%% {await,_} (incl. the 60 s first-byte timeout), {body,_} and any
%% HTTP status are post-send and terminal.
-spec decisions(map(), binary(), map(), map()) ->
    {ok, pos_integer(), map(), binary()}
    | {error, term()}.
decisions(Route, _Body, ReqMap, _Opts) when is_map(Route), is_map(ReqMap), is_map(_Opts) ->
    case resolve_decisions(Route, ReqMap) of
        {ok, Target, Headers, OutBody} ->
            decisions_post(Target, Headers, OutBody);
        {error, _} = Err ->
            Err
    end.

resolve_decisions(#{provider_id := Pid, provider_key := KeyMeta} = Route, ReqMap) ->
    case janus_catalog:lookup_provider(Pid) of
        {ok, #{base_url := BaseUrl0, enabled := true}} ->
            case janus_providers_http:decrypt_key(KeyMeta) of
                {ok, Token} ->
                    BaseUrl = iolist_to_binary(BaseUrl0),
                    case janus_providers_http:parse_base(BaseUrl) of
                        {ok, Host, Port, BasePath, Tls} ->
                            Path = janus_providers_http:join_path(BasePath, <<"/decisions">>),
                            OutBody = thoas:encode(decisions_out_map(Route, ReqMap)),
                            Target = #{host => Host, port => Port, path => Path, tls => Tls},
                            {ok, Target, decisions_headers(Token), OutBody};
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
resolve_decisions(_, _) ->
    {error, missing_provider_key}.

%% Pure: the upstream body map. `model` is rewritten to the route's
%% upstream listing id (same rule as the probe, §4.3); every other
%% field — known or unknown to this gateway — is forwarded verbatim.
%% NO stream field is injected (§4.6: the face already rejected body
%% "stream": true; a client-sent "stream": false rides through as-is).
decisions_out_map(Route, ReqMap) when is_map(ReqMap) ->
    ReqMap#{<<"model">> => upstream_model(Route, ReqMap)};
decisions_out_map(_, ReqMap) ->
    ReqMap.

%% D17: the outbound header list is built from scratch — the client's
%% OpenAI-Organization / OpenAI-Project (and every other client
%% header) are never forwarded upstream (spoofing risk, §1 non-goals).
decisions_headers(Token) when is_binary(Token) ->
    [
        {<<"authorization">>, <<"Bearer ", Token/binary>>},
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json">>},
        {<<"user-agent">>, user_agent()}
    ].

%% Gun call with the Decisions-specific caps. Scope note: this cannot
%% ride janus_providers_http:post/3 (no response-size cap there), and
%% that module's TLS-verify knob is private — duplicated here rather
%% than widening the shared client's API in this change.
decisions_post(#{host := Host, port := Port, path := Path, tls := Tls}, Headers, Body) ->
    Transport =
        case Tls of
            true -> tls;
            false -> tcp
        end,
    GunOpts = #{
        transport => Transport,
        tls_opts => decisions_tls_opts(),
        connect_timeout => ?DECISIONS_CONNECT_MS
    },
    case gun:open(Host, Port, GunOpts) of
        {ok, Conn} ->
            try
                case gun:await_up(Conn, ?DECISIONS_CONNECT_MS) of
                    {ok, _} ->
                        Stream = gun:post(Conn, Path, Headers, Body),
                        case gun:await(Conn, Stream, ?DECISIONS_TTFB_MS) of
                            {response, fin, Status, RespHeaders} ->
                                {ok, Status, decisions_resp_headers(RespHeaders), <<>>};
                            {response, nofin, Status, RespHeaders} ->
                                case decisions_collect(Conn, Stream, <<>>) of
                                    {ok, RespBody} ->
                                        {ok, Status, decisions_resp_headers(RespHeaders), RespBody};
                                    {error, _} = Err ->
                                        Err
                                end;
                            {error, Reason} ->
                                {error, {await, Reason}};
                            Other ->
                                {error, {unexpected_await, Other}}
                        end;
                    {error, Reason} ->
                        {error, {await_up, Reason}}
                end
            after
                gun:close(Conn)
            end;
        {error, Reason} ->
            {error, {open, Reason}}
    end.

decisions_collect(Conn, Stream, Acc) ->
    case gun:await(Conn, Stream, ?DECISIONS_BODY_MS) of
        {data, nofin, Data} ->
            Acc2 = <<Acc/binary, Data/binary>>,
            case byte_size(Acc2) > ?DECISIONS_MAX_RESPONSE of
                true ->
                    {error, response_too_large};
                false ->
                    decisions_collect(Conn, Stream, Acc2)
            end;
        {data, fin, Data} ->
            {ok, <<Acc/binary, Data/binary>>};
        {error, Reason} ->
            {error, {body, Reason}};
        Other ->
            {error, {unexpected_body, Other}}
    end.

decisions_resp_headers(Headers) when is_list(Headers) ->
    maps:from_list([{lower(K), V} || {K, V} <- Headers]);
decisions_resp_headers(_) ->
    #{}.

lower(B) when is_binary(B) ->
    string:lowercase(B);
lower(L) when is_list(L) ->
    string:lowercase(list_to_binary(L)).

decisions_tls_opts() ->
    case os:getenv("JANUS_UPSTREAM_TLS_VERIFY") of
        "none" ->
            [{verify, verify_none}];
        _ ->
            [{verify, verify_peer},
             {cacerts, public_key:cacerts_get()},
             {depth, 3},
             {customize_hostname_check,
                 [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]
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
