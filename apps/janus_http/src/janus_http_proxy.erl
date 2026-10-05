%%%-------------------------------------------------------------------
%%% @doc Shared data-plane proxy: auth'd handlers call proxy/5 with
%%% client protocol; dispatches native or translate paths.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_proxy).

-export([handle/5, model_field/1]).
%% Exported for eunit (usage capture helpers).
-export([maybe_trim/2, maybe_inject_stream_usage/4]).

-define(MAX_BODY, 10 * 1024 * 1024).

-define(USAGE_HEAD_BYTES, 4096).
-define(USAGE_TAIL_BYTES, 16384).
-define(USAGE_TAIL_CHUNKS, 256).

%% ClientProto = openai_chat | openai_responses | anthropic_messages
-spec handle(atom(), map(), binary(), cowboy_req:req(), term()) ->
    {ok, cowboy_req:req(), term()}.
handle(ClientProto, Agent, Body, Req, State) ->
    %% Per-request usage context. Cowboy reuses the process across
    %% HTTP/1.1 keep-alive requests, so erase first — stale keys from a
    %% previous request must never leak into this one.
    erase(janus_usage_ctx),
    erase(janus_usage_head),
    erase(janus_usage_tail),
    put(janus_usage_ctx, #{
        started => erlang:monotonic_time(microsecond),
        agent => Agent,
        client_proto => ClientProto,
        stream => false
    }),
    case thoas:decode(Body) of
        {ok, Map} when is_map(Map) ->
            case extract_model(ClientProto, Map) of
                {ok, Model} ->
                    case model_allowed(Agent, Model) of
                        false ->
                            reply_err(
                                ClientProto,
                                Req,
                                State,
                                403,
                                <<"model_not_allowed">>,
                                <<"model not in allowlist">>
                            );
                        true ->
                            proxy_model(ClientProto, Model, Body, Map, Req, State)
                    end;
                {error, Msg} ->
                    reply_err(ClientProto, Req, State, 400, <<"invalid_request">>, Msg)
            end;
        {ok, _} ->
            reply_err(
                ClientProto,
                Req,
                State,
                400,
                <<"invalid_json">>,
                <<"request body must be a JSON object">>
            );
        {error, _} ->
            reply_err(ClientProto, Req, State, 400, <<"invalid_json">>, <<"request body must be JSON">>)
    end.

-spec model_field(atom()) -> binary().
model_field(_) ->
    <<"model">>.

extract_model(_Proto, Map) ->
    case maps:get(<<"model">>, Map, undefined) of
        undefined ->
            {error, <<"model required">>};
        Model when is_binary(Model), Model =/= <<>> ->
            {ok, Model};
        _ ->
            {error, <<"model must be a non-empty string">>}
    end.

proxy_model(ClientProto, ModelName, Body, Map, Req, State) ->
    AutoConstraint = #{
        client_proto => ClientProto,
        stream => janus_protocol_translate:wants_stream(Map)
    },
    case janus_auto:maybe_route(ModelName, Map, AutoConstraint) of
        {ok, Target} ->
            do_proxy(ClientProto, Target, Body, Map#{<<"model">> => Target}, Req, State);
        pass ->
            do_proxy(ClientProto, ModelName, Body, Map, Req, State);
        {error, request_too_large} ->
            reply_err(
                ClientProto,
                Req,
                State,
                400,
                <<"request_too_large">>,
                <<"estimated context exceeds max_ctx_tokens">>
            );
        {error, no_route} ->
            reply_err(
                ClientProto,
                Req,
                State,
                404,
                <<"no_route">>,
                <<"auto-router tier unconfigured/unavailable">>
            )
    end.

do_proxy(ClientProto, ModelName, Body, Map, Req, State) ->
    case resolve_model(ModelName) of
        {ok, ModelId} ->
            proxy_picked(
                ClientProto,
                janus_lb:pick_route(ModelId, #{}),
                Body,
                Map,
                Req,
                State
            );
        error ->
            %% Not a bound public model — try a direct provider listing
            %% (the agent-visible surface is the union of all provider
            %% catalogs; binding on the Router page is for curation and
            %% janus-auto tiers, not a precondition for calling).
            proxy_picked(
                ClientProto,
                janus_lb:pick_listing_route(ModelName, #{}),
                Body,
                Map,
                Req,
                State
            )
    end.

proxy_picked(ClientProto, Pick, Body, Map, Req, State) ->
    case Pick of
        {ok, Route} ->
            case provider_protocol(Route) of
                {ok, ProviderProto} ->
                    dispatch(ClientProto, ProviderProto, Route, Body, Map, Req, State);
                {error, unknown_protocol} ->
                    _ = release_route_inflight(Route),
                    reply_err(
                        ClientProto,
                        Req,
                        State,
                        502,
                        <<"unknown_protocol">>,
                        <<"provider has unknown protocol">>
                    )
            end;
        {error, Reason} ->
            reply_pick_error(ClientProto, Req, State, Reason)
    end.

provider_protocol(#{provider_id := Pid}) ->
    case janus_catalog:lookup_provider(Pid) of
        {ok, #{protocol := P}} ->
            janus_protocol_translate:normalize_protocol(P);
        {ok, Map} ->
            janus_protocol_translate:normalize_protocol(maps:get(protocol, Map, undefined));
        error ->
            {error, unknown_protocol}
    end.

dispatch(ClientProto, ProviderProto, Route, Body, Map, Req, State) ->
    WantStream = janus_protocol_translate:wants_stream(Map),
    case get(janus_usage_ctx) of
        undefined -> ok;
        Ctx0 -> put(janus_usage_ctx, Ctx0#{stream => WantStream})
    end,
    Native = ClientProto =:= ProviderProto,
    case {Native, WantStream} of
        {false, true} ->
            _ = release_route_inflight(Route),
            reply_err(
                ClientProto,
                Req,
                State,
                400,
                <<"stream_requires_native_protocol">>,
                <<"streaming requires a same-protocol provider route">>
            );
        {true, _} ->
            {Body2, Map2} = maybe_inject_stream_usage(ClientProto, WantStream, Body, Map),
            call_native(ClientProto, ProviderProto, Route, Body2, Map2, WantStream, Req, State);
        {false, false} ->
            call_translate(ClientProto, ProviderProto, Route, Map, Req, State)
    end.

call_native(ClientProto, ProviderProto, Route, Body, Map, WantStream, Req, State) ->
    Opts = #{stream => WantStream},
    Result =
        try
            call_adapter(ProviderProto, Route, Body, Map, Opts)
        catch
            Class:CatchReason:Stack ->
                logger:error(#{
                    what => janus_proxy_crashed,
                    class => Class,
                    reason => sanitize_upstream_error(CatchReason),
                    stack => janus_seed:redact_stack(Stack)
                }),
                {error, crashed}
        end,
    handle_upstream(ClientProto, ProviderProto, Result, Route, false, Req, State).

call_translate(ClientProto, ProviderProto, Route, Map, Req, State) ->
    case janus_protocol_translate:translate_request(ClientProto, ProviderProto, Map) of
        {error, {translate_unsupported, Msg}} ->
            _ = release_route_inflight(Route),
            reply_err(ClientProto, Req, State, 400, <<"translate_unsupported">>, Msg);
        {ok, ProviderMap} ->
            OutBody = thoas:encode(ProviderMap),
            Result =
                try
                    call_adapter(ProviderProto, Route, OutBody, ProviderMap, #{stream => false})
                catch
                    Class:CatchReason:Stack ->
                        logger:error(#{
                            what => janus_proxy_crashed,
                            class => Class,
                            reason => sanitize_upstream_error(CatchReason),
                            stack => janus_seed:redact_stack(Stack)
                        }),
                        {error, crashed}
                end,
            handle_upstream(ClientProto, ProviderProto, Result, Route, true, Req, State)
    end.

call_adapter(openai_chat, Route, Body, Map, Opts) ->
    janus_providers_openai:chat_completions(Route, Body, Map, Opts);
call_adapter(openai_responses, Route, Body, Map, Opts) ->
    janus_providers_openai:responses(Route, Body, Map, Opts);
call_adapter(anthropic_messages, Route, Body, Map, Opts) ->
    janus_providers_anthropic:messages(Route, Body, Map, Opts).

%%--------------------------------------------------------------------
%% Upstream result handling
%%--------------------------------------------------------------------

handle_upstream(ClientProto, _ProviderProto, {ok, stream, Status, Headers, Drain}, Route, false, Req, State) when
    Status >= 400
->
    %% Error with stream framing — drain to body and treat as non-stream error.
    case collect_drain(Drain) of
        {ok, RespBody} ->
            handle_upstream(
                ClientProto, _ProviderProto, {ok, Status, Headers, RespBody}, Route, false, Req, State
            );
        {error, Reason} ->
            handle_upstream(ClientProto, _ProviderProto, {error, Reason}, Route, false, Req, State)
    end;
handle_upstream(ClientProto, _ProviderProto, {ok, stream, Status, Headers, Drain}, Route, false, Req, State) ->
    Req2 = cowboy_req:stream_reply(
        Status,
        filter_stream_headers(Headers),
        Req
    ),
    case
        Drain(fun(Chunk) ->
            capture_usage_chunk(Chunk),
            %% `_ =`: a client disconnect makes stream_body fail; the
            %% drain surfaces it as {error, _} below (recorded as 502)
            %% instead of crashing the request process mid-callback.
            _ = cowboy_req:stream_body(Chunk, nofin, Req2)
        end)
    of
        ok ->
            %% Record BEFORE the final frame so a dying client can
            %% never cost us the usage row.
            _ = note_key_success(Route),
            _ = note_route_success(Route),
            _ = track(Status, Route, stream_usage(ClientProto)),
            _ = cowboy_req:stream_body(<<>>, fin, Req2),
            {ok, Req2, State};
        {error, Reason} ->
            %% Mid-stream failure: record 502, not the already-sent 200.
            _ = track(502, Route, stream_usage(ClientProto)),
            SafeReason = sanitize_upstream_error(Reason),
            _ = note_provider_failure(Route, SafeReason),
            _ = release_route_inflight(Route),
            logger:warning(#{
                what => janus_proxy_stream_error,
                reason => SafeReason,
                client_proto => ClientProto
            }),
            %% Best-effort close; connection may already be half-closed.
            catch cowboy_req:stream_body(<<"\n">>, fin, Req2),
            {ok, Req2, State}
    end;
handle_upstream(ClientProto, ProviderProto, {ok, Status, Headers, RespBody}, Route, Translate, Req, State) when
    Status =:= 401
->
    _ = track(401, Route, #{}),
    _ = note_auth_failure(Route, Status),
    _ = release_route_inflight(Route),
    reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, Translate, Req, State);
handle_upstream(ClientProto, ProviderProto, {ok, Status, Headers, RespBody}, Route, Translate, Req, State) when
    Status =:= 403
->
    _ = track(403, Route, #{}),
    _ = note_route_failure(Route, retry_reason(Headers, Status)),
    _ = release_route_inflight(Route),
    reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, Translate, Req, State);
handle_upstream(ClientProto, ProviderProto, {ok, Status, Headers, RespBody}, Route, Translate, Req, State) when
    Status =:= 429
->
    _ = track(429, Route, #{}),
    _ = note_key_failure(Route, Headers, Status),
    _ = release_route_inflight(Route),
    reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, Translate, Req, State);
handle_upstream(ClientProto, ProviderProto, {ok, Status, Headers, RespBody}, Route, Translate, Req, State) when
    Status >= 500
->
    _ = track(Status, Route, #{}),
    _ = note_provider_failure(Route, retry_reason(Headers, Status)),
    _ = release_route_inflight(Route),
    reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, Translate, Req, State);
handle_upstream(ClientProto, ProviderProto, {ok, Status, Headers, RespBody}, Route, Translate, Req, State) when
    Status >= 400
->
    _ = track(Status, Route, #{}),
    _ = release_route_inflight(Route),
    reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, Translate, Req, State);
handle_upstream(ClientProto, ProviderProto, {ok, Status, Headers, RespBody}, Route, Translate, Req, State) ->
    _ = note_key_success(Route),
    _ = note_route_success(Route),
    _ = track(
        Status,
        Route,
        usage_or_undef(janus_usage_parse:from_response_body(ProviderProto, RespBody))
    ),
    reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, Translate, Req, State);
handle_upstream(ClientProto, _ProviderProto, {error, crashed}, Route, _Translate, Req, State) ->
    _ = track(500, Route, #{}),
    _ = release_route_inflight(Route),
    reply_err(ClientProto, Req, State, 500, <<"internal_error">>, <<"upstream call crashed">>);
handle_upstream(ClientProto, _ProviderProto, {error, Reason}, Route, _Translate, Req, State) ->
    _ = track(
        case Reason of
            provider_disabled -> 503;
            _ -> 502
        end,
        Route,
        #{}
    ),
    SafeReason = sanitize_upstream_error(Reason),
    case is_transient(Reason) of
        true ->
            _ = note_provider_failure(Route, SafeReason),
            _ = release_route_inflight(Route);
        false ->
            _ = release_route_inflight(Route)
    end,
    logger:warning(#{
        what => janus_proxy_upstream_error,
        reason => SafeReason,
        provider => route_provider_name(Route),
        model => route_model_name(Route)
    }),
    Status =
        case Reason of
            provider_disabled -> 503;
            _ -> 502
        end,
    reply_err(ClientProto, Req, State, Status, <<"upstream_error">>, <<"upstream request failed">>).

reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, true, Req, State) when
    Status >= 200, Status < 300
->
    case thoas:decode(RespBody) of
        {ok, ProviderMap} when is_map(ProviderMap) ->
            case janus_protocol_translate:translate_response(ClientProto, ProviderProto, ProviderMap) of
                {ok, ClientMap} ->
                    reply_json(Req, State, Status, ClientMap);
                {error, {translate_unsupported, Msg}} ->
                    reply_err(ClientProto, Req, State, 502, <<"translate_unsupported">>, Msg)
            end;
        _ ->
            %% Non-JSON success — pass through (shouldn't happen often).
            Req2 = cowboy_req:reply(Status, filter_headers(Headers), RespBody, Req),
            {ok, Req2, State}
    end;
reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, true, Req, State) ->
    %% Error body: reshape to client dialect when possible.
    Body2 = reshape_error(ClientProto, ProviderProto, RespBody),
    Req2 = cowboy_req:reply(Status, filter_headers(Headers), Body2, Req),
    {ok, Req2, State};
reply_upstream_body(_ClientProto, _ProviderProto, Status, Headers, RespBody, false, Req, State) ->
    Req2 = cowboy_req:reply(Status, filter_headers(Headers), RespBody, Req),
    {ok, Req2, State}.

reshape_error(ClientProto, ProviderProto, RespBody) when ClientProto =/= ProviderProto ->
    case thoas:decode(RespBody) of
        {ok, Map} when is_map(Map) ->
            Msg = extract_error_message(Map),
            thoas:encode(error_map(ClientProto, <<"upstream_error">>, Msg));
        _ ->
            thoas:encode(
                error_map(ClientProto, <<"upstream_error">>, <<"upstream request failed">>)
            )
    end;
reshape_error(_, _, RespBody) ->
    RespBody.

extract_error_message(#{<<"error">> := #{<<"message">> := M}}) when is_binary(M) ->
    M;
extract_error_message(#{<<"error">> := #{<<"type">> := _, <<"message">> := M}}) when is_binary(M) ->
    M;
extract_error_message(#{<<"type">> := <<"error">>, <<"error">> := #{<<"message">> := M}}) when
    is_binary(M)
->
    M;
extract_error_message(_) ->
    <<"upstream request failed">>.

collect_drain(Drain) ->
    Acc = ets:new(janus_stream_acc, [private]),
    try
        case
            Drain(fun(Chunk) ->
                ets:insert(Acc, {erlang:unique_integer([monotonic]), Chunk}),
                ok
            end)
        of
            ok ->
                Chunks = [C || {_K, C} <- lists:keysort(1, ets:tab2list(Acc))],
                {ok, iolist_to_binary(Chunks)};
            {error, _} = Err ->
                Err
        end
    after
        ets:delete(Acc)
    end.

%%--------------------------------------------------------------------
%% Errors / replies
%%--------------------------------------------------------------------

reply_pick_error(ClientProto, Req, State, all_cooling) ->
    reply_pick_error(ClientProto, Req, State, {all_cooling, 5000});
reply_pick_error(ClientProto, Req, State, {all_cooling, Ms}) when is_integer(Ms), Ms > 0 ->
    Sec = max(1, (Ms + 999) div 1000),
    reply_err(
        ClientProto,
        Req,
        State,
        503,
        <<"all_cooling">>,
        <<"all upstream routes are cooling down">>,
        #{<<"retry-after">> => integer_to_binary(Sec)}
    );
reply_pick_error(ClientProto, Req, State, provider_disabled) ->
    reply_err(
        ClientProto, Req, State, 503, <<"provider_disabled">>,
        <<"the provider for this model is disabled">>
    );
reply_pick_error(ClientProto, Req, State, keys_disabled) ->
    reply_err(ClientProto, Req, State, 503, <<"no_usable_key">>, <<"no enabled upstream keys">>);
reply_pick_error(ClientProto, Req, State, missing_provider_key) ->
    reply_err(
        ClientProto, Req, State, 503, <<"no_usable_key">>, <<"provider has no keys configured">>
    );
reply_pick_error(ClientProto, Req, State, catalog_not_ready) ->
    reply_err(
        ClientProto,
        Req,
        State,
        503,
        <<"catalog_not_ready">>,
        <<"catalog not ready">>,
        #{<<"retry-after">> => <<"1">>}
    );
reply_pick_error(ClientProto, Req, State, _Reason) ->
    reply_err(ClientProto, Req, State, 404, <<"no_route">>, <<"no route for model">>).

reply_err(ClientProto, Req, State, Status, Code, Msg) ->
    reply_err(ClientProto, Req, State, Status, Code, Msg, #{}).

reply_err(ClientProto, Req, State, Status, Code, Msg, Extra) ->
    reply_json(Req, State, Status, error_map(ClientProto, Code, Msg), Extra).

error_map(anthropic_messages, Code, Msg) ->
    #{
        type => <<"error">>,
        error => #{
            type => <<"invalid_request_error">>,
            message => Msg,
            code => Code
        }
    };
error_map(_ClientProto, Code, Msg) ->
    #{
        error => #{
            message => Msg,
            type => <<"janus_error">>,
            code => Code
        }
    }.

reply_json(Req, State, Status, Body) ->
    reply_json(Req, State, Status, Body, #{}).

reply_json(Req, State, Status, Body, ExtraHeaders) when is_binary(Body), is_map(ExtraHeaders) ->
    Headers = maps:merge(#{<<"content-type">> => <<"application/json">>}, ExtraHeaders),
    Req2 = cowboy_req:reply(Status, Headers, Body, Req),
    {ok, Req2, State};
reply_json(Req, State, Status, Map, ExtraHeaders) when is_map(Map), is_map(ExtraHeaders) ->
    reply_json(Req, State, Status, thoas:encode(Map), ExtraHeaders).

filter_headers(Headers) when is_map(Headers) ->
    maps:with([<<"content-type">>], Headers);
filter_headers(_) ->
    #{<<"content-type">> => <<"application/json">>}.

filter_stream_headers(Headers) when is_map(Headers) ->
    Base = #{
        <<"content-type">> => <<"text/event-stream">>,
        <<"cache-control">> => <<"no-cache">>,
        <<"connection">> => <<"keep-alive">>
    },
    case maps:get(<<"content-type">>, Headers, undefined) of
        CT when is_binary(CT) -> Base#{<<"content-type">> => CT};
        _ -> Base
    end;
filter_stream_headers(_) ->
    #{<<"content-type">> => <<"text/event-stream">>}.

%%--------------------------------------------------------------------
%% LB helpers (same contracts as former janus_http_chat)
%%--------------------------------------------------------------------

note_auth_failure(Route, Status) ->
    ProviderId = maps:get(provider_id, Route, undefined),
    KeyId =
        case maps:get(provider_key, Route, undefined) of
            #{id := Id} -> Id;
            _ -> undefined
        end,
    janus_lb:note_auth_failure(ProviderId, KeyId, {auth, Status}).

note_key_failure(Route, Headers, Status) when is_integer(Status) ->
    janus_lb:note_failure(key_target(Route), retry_reason(Headers, Status)).

note_key_success(Route) ->
    janus_lb:note_success(key_target(Route)).

note_provider_failure(Route, Reason) ->
    janus_lb:note_failure(provider_target(Route), Reason).

note_route_failure(Route, Reason) ->
    janus_lb:note_failure(route_target(Route), Reason).

note_route_success(Route) ->
    janus_lb:note_success(route_target(Route)).

release_route_inflight(Route) ->
    janus_lb:release_inflight(route_target(Route)).

%%--------------------------------------------------------------------
%% Usage capture (data-plane stats; rows land in usage_events via
%% janus_usage)
%%--------------------------------------------------------------------

key_id_of(#{provider_key := #{id := Kid}}) -> Kid;
key_id_of(#{provider_key := _}) -> null;
key_id_of(_) -> null.

usage_bool_int(true) -> 1;
usage_bool_int(1) -> 1;
usage_bool_int(_) -> 0.

usage_or_undef(undefined) -> #{};
usage_or_undef(U) -> U.

%% Token counts default to null (= upstream did not report usage),
%% NOT 0 — a missing usage must stay distinguishable from a real zero.
track(_Status, Route, _Usage) when not is_map(Route) ->
    ok;
track(Status, Route, Usage) ->
    case get(janus_usage_ctx) of
        undefined ->
            ok;
        #{started := Started, agent := Agent, client_proto := Proto, stream := Stream} when
            is_map(Agent)
        ->
            LatencyMs =
                erlang:convert_time_unit(
                    erlang:monotonic_time(microsecond) - Started,
                    microsecond,
                    millisecond
                ),
            janus_usage:record(#{
                ts => erlang:system_time(second),
                agent_key_id => maps:get(id, Agent, null),
                model_id => maps:get(model_id, Route, null),
                provider_id => maps:get(provider_id, Route, null),
                provider_key_id => key_id_of(Route),
                protocol => Proto,
                stream => usage_bool_int(Stream),
                status => Status,
                prompt => maps:get(prompt, Usage, null),
                completion => maps:get(completion, Usage, null),
                latency_ms => LatencyMs
            });
        _ ->
            ok
    end.

%% Ask OpenAI-compatible upstreams to always emit the terminal usage
%% chunk on streams. Skip when the client set its own stream_options
%% (respect explicit choices) or the operator disabled injection
%% (strict upstreams may 400 on unknown fields). The usage chunk is
%% spec-compliant and forwarded to the client like any other chunk.
maybe_inject_stream_usage(openai_chat, true, Body, Map) ->
    Inject = application:get_env(janus_core, usage_inject_include_usage, true),
    case {Inject, maps:get(<<"stream_options">>, Map, undefined)} of
        {true, undefined} ->
            Map2 = Map#{<<"stream_options">> => #{<<"include_usage">> => true}},
            {iolist_to_binary(thoas:encode(Map2)), Map2};
        _ ->
            {Body, Map}
    end;
maybe_inject_stream_usage(_, _, Body, Map) ->
    {Body, Map}.

capture_usage_chunk(Chunk) ->
    Head0 =
        case get(janus_usage_head) of
            undefined -> <<>>;
            H -> H
        end,
    case byte_size(Head0) < ?USAGE_HEAD_BYTES of
        true ->
            Need = ?USAGE_HEAD_BYTES - byte_size(Head0),
            Take = binary:part(Chunk, 0, min(byte_size(Chunk), Need)),
            put(janus_usage_head, <<Head0/binary, Take/binary>>);
        false ->
            ok
    end,
    %% Tail is a newest-first {Chunks, TotalBytes} tuple; prepending is
    %% O(1) and the refold only runs when a cap is exceeded (both caps
    %% bound the fold size, so per-chunk cost stays constant).
    case Chunk of
        <<>> ->
            ok;
        _ ->
            {Chunks0, Size0} =
                case get(janus_usage_tail) of
                    undefined -> {[], 0};
                    T0 -> T0
                end,
            put(
                janus_usage_tail,
                maybe_trim([Chunk | Chunks0], Size0 + byte_size(Chunk))
            )
    end.

maybe_trim(Chunks, Size) when Size =< ?USAGE_TAIL_BYTES ->
    case length(Chunks) =< ?USAGE_TAIL_CHUNKS of
        true ->
            {Chunks, Size};
        false ->
            Kept = lists:sublist(Chunks, ?USAGE_TAIL_CHUNKS),
            {Kept, lists:sum([byte_size(C) || C <- Kept])}
    end;
maybe_trim(Chunks, _Size) ->
    %% Over the byte cap: refold newest-first, keeping whole chunks
    %% that fit (whole-chunk granularity; the parser tolerates the
    %% remaining partial first line).
    {Kept, Size} =
        lists:foldl(
            fun(C, {Acc, S}) ->
                case S + byte_size(C) =< ?USAGE_TAIL_BYTES of
                    true -> {[C | Acc], S + byte_size(C)};
                    false -> {Acc, S}
                end
            end,
            {[], 0},
            Chunks
        ),
    {lists:reverse(Kept), Size}.

stream_usage(ClientProto) ->
    Head =
        case get(janus_usage_head) of
            undefined -> <<>>;
            H -> H
        end,
    Tail =
        case get(janus_usage_tail) of
            undefined -> <<>>;
            {Chunks, _} -> iolist_to_binary(lists:reverse(Chunks))
        end,
    erase(janus_usage_head),
    erase(janus_usage_tail),
    usage_or_undef(janus_usage_parse:from_sse(ClientProto, Head, Tail)).

retry_reason(Headers, Status) when Status =:= 429; Status =:= 503 ->
    case maps:get(<<"retry-after">>, Headers, undefined) of
        Bin when is_binary(Bin) ->
            try
                Sec = binary_to_integer(Bin),
                case Sec > 0 of
                    true -> {retry_after, Sec * 1000};
                    false -> {http, Status}
                end
            catch
                _:_ -> {http, Status}
            end;
        _ ->
            {http, Status}
    end;
retry_reason(_Headers, Status) when is_integer(Status) ->
    {http, Status}.

is_transient({open, _}) -> true;
is_transient({await_up, _}) -> true;
is_transient({await, _}) -> true;
is_transient({body, _}) -> true;
is_transient({unexpected_await, _}) -> true;
is_transient({unexpected_body, _}) -> true;
is_transient(_) -> false.

sanitize_upstream_error(R) when is_atom(R) -> R;
sanitize_upstream_error({Tag, Sub}) when is_atom(Tag), is_atom(Sub) -> {Tag, Sub};
sanitize_upstream_error({Tag, N}) when is_atom(Tag), is_integer(N) -> {Tag, N};
sanitize_upstream_error({Tag, _}) when is_atom(Tag) -> Tag;
sanitize_upstream_error(_) -> upstream_error.

route_provider_name(Route) ->
    case janus_catalog:lookup_provider(maps:get(provider_id, Route, undefined)) of
        {ok, #{name := N}} -> N;
        _ -> maps:get(provider_id, Route, undefined)
    end.

route_model_name(Route) ->
    Mid = maps:get(model_id, Route, undefined),
    case janus_catalog:lookup_model(Mid) of
        {ok, #{name := N}} -> N;
        _ -> Mid
    end.

resolve_model(Name) when is_binary(Name), Name =/= <<>> ->
    case janus_catalog:lookup_model(Name) of
        {ok, #{id := Id}} -> {ok, Id};
        error -> error
    end;
resolve_model(_) ->
    error.

model_allowed(#{model_ids := all}, _) ->
    true;
model_allowed(#{model_ids := Ids}, ModelName) when is_list(Ids) ->
    case janus_catalog:lookup_model(ModelName) of
        {ok, #{id := Id}} -> lists:member(Id, Ids);
        error -> false
    end;
model_allowed(_, _) ->
    true.

key_target(#{provider_key := #{id := Kid}}) ->
    {provider_key, Kid};
key_target(_) ->
    undefined.

provider_target(#{provider_id := P}) ->
    {provider, P};
provider_target(_) ->
    undefined.

route_target(#{provider_id := P, model_id := M}) ->
    {route, M, P};
route_target(#{provider_id := P}) ->
    {route, P};
route_target(_) ->
    undefined.
