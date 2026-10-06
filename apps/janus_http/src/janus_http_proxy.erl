%%%-------------------------------------------------------------------
%%% @doc Shared data-plane proxy: auth'd handlers call proxy/5 with
%%% client protocol; dispatches native or translate paths.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_proxy).

-include("janus_protocol_translate.hrl").

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
    erase(janus_req_model),
    erase(janus_sse_state),
    erase(janus_sse_tracked),
    erase(janus_failover_started),
    erase(janus_failover_ref),
    erase(janus_failover_attempt),
    erase(janus_failover_keys),
    erase(janus_failover_err_code),
    erase(janus_failover_unclassified_retried),
    erase(janus_stats_counted),
    erase(janus_stats_tracked),
    erase(janus_stats_failed),
    erase(janus_stats_inner),
    erase(janus_req_counted),
    %% janus_request_id is deliberately NOT erased here: the handler
    %% resolves and puts it (fresh for every request, incl. keep-alive
    %% reuse) before calling the proxy; track/3 reads it below.
    put(janus_req_path, cowboy_req:path(Req)),
    put(janus_usage_ctx, #{
        started => erlang:monotonic_time(microsecond),
        agent => Agent,
        client_proto => ClientProto,
        stream => false
    }),
    try
        handle_body(ClientProto, Agent, Body, Req, State)
    catch
        Class:Reason:Stack ->
            %% Crash fallback: bump failed ONLY when this request was
            %% counted (entered do_proxy), is not an inner call, and
            %% nothing already tracked/failed it.
            maybe_crash_bump_failed(),
            erlang:raise(Class, Reason, Stack)
    end.

handle_body(ClientProto, Agent, Body, Req, State) ->
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
    WantStream = janus_protocol_translate:wants_stream(Map),
    %% janus-auto skips cross-protocol tier members ONLY when the
    %% stream translate path is blocked (tools/vision/n>1 or a
    %% responses client). Plain text/thinking streams translate now.
    AutoConstraint = #{
        client_proto => ClientProto,
        stream => WantStream andalso janus_protocol_translate:stream_translate_blocked(ClientProto, Map)
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
    inc_total_once(),
    put(janus_req_model, ModelName),
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
                    _ = track(502, Route, #{}),
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
            case janus_protocol_translate:stream_translate_blocked(ClientProto, Map) of
                false ->
                    call_translate(ClientProto, ProviderProto, Route, Map, true, Req, State);
                true ->
                    _ = release_route_inflight(Route),
                    _ = track(400, Route, #{}),
                    case translatable_stream_pair(ClientProto, ProviderProto) of
                        true ->
                            %% Tools/vision/n>1 on a translate pair: the
                            %% stream translate is text+thinking only.
                            reply_err(
                                ClientProto,
                                Req,
                                State,
                                400,
                                <<"translate_unsupported">>,
                                <<"streaming translate supports text and thinking only">>
                            );
                        false ->
                            reply_err(
                                ClientProto,
                                Req,
                                State,
                                400,
                                <<"stream_requires_native_protocol">>,
                                <<"streaming requires a same-protocol provider route">>
                            )
                    end
            end;
        {true, _} ->
            {Body2, Map2} = maybe_inject_stream_usage(ClientProto, WantStream, Body, Map),
            call_native(ClientProto, ProviderProto, Route, Body2, Map2, WantStream, Req, State);
        {false, false} ->
            call_translate(ClientProto, ProviderProto, Route, Map, false, Req, State)
    end.

translatable_stream_pair(openai_chat, anthropic_messages) -> true;
translatable_stream_pair(anthropic_messages, openai_chat) -> true;
translatable_stream_pair(_, _) -> false.

call_native(ClientProto, ProviderProto, Route, Body, Map, WantStream, Req, State) ->
    Result = upstream_call(ProviderProto, Route, Body, Map, WantStream),
    case failover_decide(ClientProto, Route, Map, Body, Result, Req, State) of
        {continue, Result2} ->
            handle_upstream(ClientProto, ProviderProto, Result2, Route, false, Req, State);
        {handled, Ok} ->
            Ok
    end.

call_translate(ClientProto, ProviderProto, Route, Map, WantStream, Req, State) ->
    case janus_protocol_translate:translate_request(ClientProto, ProviderProto, Map) of
        {error, {translate_unsupported, Msg}} ->
            _ = release_route_inflight(Route),
            _ = track(400, Route, #{}),
            reply_err(ClientProto, Req, State, 400, <<"translate_unsupported">>, Msg);
        {ok, ProviderMap0} ->
            %% chat_to_messages hardcodes stream=false; the streaming
            %% leg overrides it and drops any client stream_options
            %% (the gateway injects its own when needed).
            ProviderMap1 =
                case WantStream of
                    true -> maps:remove(<<"stream_options">>, ProviderMap0#{<<"stream">> => true});
                    false -> ProviderMap0
                end,
            {InjectUsed, ProviderMap} =
                maybe_inject_include_usage(ClientProto, ProviderProto, WantStream, ProviderMap1),
            OutBody = thoas:encode(ProviderMap),
            Result = upstream_call(ProviderProto, Route, OutBody, ProviderMap, WantStream),
            Result2 = maybe_retry_include_usage(
                ClientProto, ProviderProto, Route, ProviderMap, InjectUsed, WantStream, Result
            ),
            case failover_decide(ClientProto, Route, Map, OutBody, Result2, Req, State) of
                {continue, Result3} ->
                    translate_result(
                        ClientProto, ProviderProto, Route, Result3, Req, State
                    );
                {handled, Ok} ->
                    Ok
            end
    end.

translate_result(ClientProto, ProviderProto, Route, Result, Req, State) ->
    WantStream = true,
    case {WantStream, Result} of
        {true, {ok, stream, Status, Headers, Drain}} when Status < 400 ->
                    handle_translate_stream(
                        ClientProto, ProviderProto, Status, Headers, Drain, Route, Req, State
                    );
                {true, {ok, stream, Status, Headers, Drain}} when Status >= 400 ->
                    %% Error-status stream: collect, then the normal
                    %% non-stream error reply path (retryable upstream state).
                    case collect_drain(Drain) of
                        {ok, RespBody} ->
                            handle_upstream(
                                ClientProto, ProviderProto, {ok, Status, Headers, RespBody}, Route, true, Req, State
                            );
                        {error, Reason} ->
                            handle_upstream(ClientProto, ProviderProto, {error, Reason}, Route, true, Req, State)
                    end;
        _ ->
            handle_upstream(ClientProto, ProviderProto, Result, Route, true, Req, State)
    end.

upstream_call(ProviderProto, Route, Body, Map, WantStream) ->
    try
        call_adapter(ProviderProto, Route, Body, Map, #{stream => WantStream})
    catch
        Class:CatchReason:Stack ->
            logger:error(#{
                what => janus_proxy_crashed,
                class => Class,
                reason => sanitize_upstream_error(CatchReason),
                stack => janus_seed:redact_stack(Stack)
            }),
            {error, crashed}
    end.

%% Slice A include_usage: only provider openai_chat + client Messages.
%% The injected field rides the TRANSLATED provider body (the client's
%% own stream_options never survives translation).
maybe_inject_include_usage(anthropic_messages, openai_chat, true, ProviderMap) ->
    Inject = application:get_env(janus_core, usage_inject_include_usage, true),
    case Inject of
        true -> {true, ProviderMap#{<<"stream_options">> => #{<<"include_usage">> => true}}};
        false -> {false, ProviderMap}
    end;
maybe_inject_include_usage(_, _, _, ProviderMap) ->
    {false, ProviderMap}.

%% Some strict OpenAI-compatible upstreams 400 on stream_options.
%% Retry EXACTLY once, only on a pre-200 400, re-encoding the already
%% translated body without stream_options; the discarded attempt is
%% never tracked (no usage row, no counters).
maybe_retry_include_usage(_ClientProto, ProviderProto, Route, ProviderMap, true, true, {ok, stream, 400, _H, Drain}) ->
    _ = collect_drain(Drain),
    ProviderMap2 = maps:remove(<<"stream_options">>, ProviderMap),
    upstream_call(ProviderProto, Route, thoas:encode(ProviderMap2), ProviderMap2, true);
maybe_retry_include_usage(_, _, _, _, _, _, Result) ->
    Result.

%%%--------------------------------------------------------------------
%%% Streaming translate (Slice A): fold provider SSE -> client frames
%%%--------------------------------------------------------------------

handle_translate_stream(ClientProto, ProviderProto, Status, Headers, Drain, Route, Req, State) ->
    put(janus_sse_state, janus_protocol_translate:new_sse_st()),
    put(janus_sse_tracked, false),
    Req2 = cowboy_req:stream_reply(Status, filter_stream_headers(Headers), Req),
    try
        Drain(fun(Chunk) -> translate_chunk(ClientProto, ProviderProto, Chunk, Req2) end)
    of
        ok ->
            finish_translate_stream(ClientProto, Route, Req2, State, normal)
    catch
        throw:{janus_translate, Kind, Msg} ->
            finish_translate_stream(ClientProto, Route, Req2, State, {error, Kind, Msg});
        throw:janus_client_disconnect ->
            %% Drain aborted from a dead client socket; the drain's
            %% after-clause already closed gun. No frames can be sent.
            finalize_quiet(ClientProto),
            translate_track(502, Route, ClientProto),
            _ = release_route_inflight(Route),
            {ok, Req2, State};
        Class:Reason ->
            %% EXIT path: request process would otherwise die without a
            %% usage row (socket close, cowboy transport error).
            _ = logger:warning(#{
                what => janus_translate_stream_exit,
                class => Class,
                reason => sanitize_upstream_error(Reason)
            }),
            finalize_quiet(ClientProto),
            translate_track(502, Route, ClientProto),
            _ = release_route_inflight(Route),
            {ok, Req2, State}
    end.

%% Drain callback: parse + translate + write each frame immediately.
translate_chunk(ClientProto, ProviderProto, Chunk, Req2) ->
    capture_usage_chunk(Chunk),
    St0 = get(janus_sse_state),
    case janus_protocol_translate:sse_events(St0#sse_st.leftover, Chunk) of
        {error, leftover_cap} ->
            put(janus_sse_state, St0),
            throw({janus_translate, upstream, <<"upstream SSE frame exceeds 1MiB">>});
        {ok, Events, Rest} ->
            St1 = St0#sse_st{leftover = Rest},
            St2 =
                lists:foldl(
                    fun(Ev, StAcc) ->
                        guard_chat_multi_choice(ProviderProto, Ev),
                        case janus_protocol_translate:translate_sse(ClientProto, ProviderProto, Ev, StAcc) of
                            {ok, Frames, StNext} ->
                                write_frames(Frames, Req2),
                                StNext;
                            {error, translate_unsupported, StNext} ->
                                put(janus_sse_state, StNext),
                                throw(
                                    {janus_translate, upstream,
                                        <<"upstream sent an unsupported stream construct">>}
                                )
                        end
                    end,
                    St1,
                    Events
                ),
            put(janus_sse_state, St2)
    end.

%% Defensive: a misbehaving OpenAI-compatible proxy emitting extra
%% choices would corrupt the translated single-choice Anthropic face.
guard_chat_multi_choice(openai_chat, #{type := <<"chunk">>, data := D}) when is_map(D) ->
    case maps:get(<<"choices">>, D, []) of
        Choices when is_list(Choices), length(Choices) > 1 ->
            throw({janus_translate, invalid_request, <<"provider emitted multiple choices">>});
        _ ->
            ok
    end;
guard_chat_multi_choice(_, _) ->
    ok.

write_frames(Frames, Req2) ->
    lists:foreach(fun(F) -> stream_client_frame(F, nofin, Req2) end, Frames).

%% Cowboy returns ok | {ok, Req} on a live socket and errors/throws when
%% the client is gone. Throw janus_client_disconnect so the drain's
%% after-clause can close gun and the handler records 502.
stream_client_frame(Data, Fin, Req2) ->
    try cowboy_req:stream_body(iolist_to_binary(Data), Fin, Req2) of
        ok -> ok;
        {ok, _} -> ok;
        {error, _} -> throw(janus_client_disconnect)
    catch
        throw:janus_client_disconnect ->
            throw(janus_client_disconnect);
        error:closed ->
            throw(janus_client_disconnect);
        error:{closed, _} ->
            throw(janus_client_disconnect);
        exit:{noproc, _} ->
            throw(janus_client_disconnect);
        exit:{shutdown, _} ->
            throw(janus_client_disconnect);
        throw:{error, _} ->
            throw(janus_client_disconnect)
    end.

finish_translate_stream(ClientProto, Route, Req2, State, Reason) ->
    St0 = get(janus_sse_state),
    {ok, Frames, St1} = janus_protocol_translate:finalize_sse(ClientProto, Reason, St0),
    put(janus_sse_state, St1),
    case Reason of
        normal ->
            TrackStatus = 200,
            _ = note_key_success(Route),
            _ = note_route_success(Route);
        {error, invalid_request, _} ->
            TrackStatus = 400;
        {error, upstream, Msg} ->
            TrackStatus = 502,
            _ = note_provider_failure(Route, sanitize_upstream_error(Msg))
    end,
    %% Record BEFORE the final frame so a dying client can never cost
    %% us the usage row.
    translate_track(TrackStatus, Route, ClientProto),
    try
        write_frames(Frames, Req2),
        catch cowboy_req:stream_body(<<>>, fin, Req2)
    catch
        throw:janus_client_disconnect ->
            ok
    end,
    _ = release_route_inflight(Route),
    {ok, Req2, State}.

finalize_quiet(ClientProto) ->
    St0 = get(janus_sse_state),
    {ok, [], St1} = janus_protocol_translate:finalize_sse(ClientProto, disconnect, St0),
    put(janus_sse_state, St1).

translate_track(Status, Route, ClientProto) ->
    case get(janus_sse_tracked) of
        true ->
            ok;
        _ ->
            put(janus_sse_tracked, true),
            _ = track(Status, Route, stream_usage(ClientProto)),
            ok
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

native_stream_fail(ClientProto, Route, Req2, State, Reason) ->
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
    catch cowboy_req:stream_body(<<"\n">>, fin, Req2),
    {ok, Req2, State}.

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
    try
        Drain(fun(Chunk) ->
            capture_usage_chunk(Chunk),
            stream_client_frame(Chunk, nofin, Req2)
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
            native_stream_fail(ClientProto, Route, Req2, State, Reason)
    catch
        throw:janus_client_disconnect ->
            native_stream_fail(ClientProto, Route, Req2, State, closed)
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
    Status = error_http_status(Reason),
    _ = track(Status, Route, #{}),
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
    {Code, Msg} =
        case Status of
            504 -> {<<"upstream_timeout">>, <<"upstream first-byte timeout">>};
            503 -> {<<"upstream_error">>, <<"upstream request failed">>};
            _ -> {<<"upstream_error">>, <<"upstream request failed">>}
        end,
    reply_err(ClientProto, Req, State, Status, Code, Msg).

%% TTFB (gun await of the response headers) is 504; a disabled provider
%% is 503; everything else that never produced headers is 502.
error_http_status(provider_disabled) -> 503;
error_http_status({await, timeout}) -> 504;
error_http_status({await, {timeout, _}}) -> 504;
error_http_status(_) -> 502.

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


%%%--------------------------------------------------------------------
%%% In-request key failover (spec Part C)
%%%
%%% Wraps every upstream attempt: retryable key-scoped failures
%%% (401/403/429/deny-shaped 400/404, 5xx, transport) retry on another
%%% key/route inside the budget; input-shape 400s and committed 2xx
%%% streams are terminal. The FIRST call is unconditional; the knobs
%%% bound RETRIES. Knobs live in the settings table (failover key,
%%% distributed via persistent_term) with sys.config defaults.
%%%--------------------------------------------------------------------

pd(Key, Default) ->
    case get(Key) of
        undefined -> Default;
        V -> V
    end.

failover_knobs() ->
    case persistent_term:get({janus, failover_cfg}, undefined) of
        #{<<"max_attempts">> := A} = Cfg when is_integer(A), A >= 0, A =< 20 ->
            B =
                case maps:get(<<"max_budget_ms">>, Cfg, 45000) of
                    BB when is_integer(BB), BB > 0 -> min(BB, 180000);
                    _ -> 45000
                end,
            {A, B};
        _ ->
            {application:get_env(janus, failover_max_attempts, 3),
                application:get_env(janus, failover_max_budget_ms, 45000)}
    end.

failover_start() ->
    case get(janus_failover_started) of
        undefined ->
            put(janus_failover_started, erlang:monotonic_time(millisecond)),
            put(janus_failover_ref, binary:encode_hex(crypto:strong_rand_bytes(16))),
            put(janus_failover_attempt, 1),
            ok;
        _ ->
            ok
    end.

%% Error-status streams are collected HERE (pre-reply upstream state is
%% retryable; the body feeds classification).
normalize_result({ok, stream, Status, Headers, Drain}) when Status >= 400 ->
    case collect_drain(Drain) of
        {ok, Body} -> {ok, Status, Headers, Body};
        {error, Reason} -> {error, Reason}
    end;
normalize_result(R) ->
    R.

%% {continue, Result} -> caller replies via handle_upstream.
%% {handled, {ok, Req, State}} -> a retry completed the request.
failover_decide(ClientProto, Route, Map, Body, Result0, Req, State) ->
    failover_start(),
    Result = normalize_result(Result0),
    case failover_classify(Route, Result) of
        terminal ->
            {continue, Result};
        {retryable, ErrCode} ->
            put(janus_failover_err_code, ErrCode),
            {Attempts, Budget} = failover_knobs(),
            Attempt = get(janus_failover_attempt),
            Elapsed = erlang:monotonic_time(millisecond) - pd(janus_failover_started, 0),
            case Attempt =< Attempts andalso Elapsed < Budget of
                true ->
                    failover_note(Route, Result),
                    failover_record_attempt(Route, Result, ErrCode),
                    retry_jitter(),
                    janus_lb:bump_stat(requests_retried),
                    put(janus_failover_attempt, Attempt + 1),
                    mark_key_attempted(Route),
                    case repick_route(ClientProto, Map, 3) of
                        {ok, Route2} ->
                            {handled, retry_dispatch(ClientProto, Route2, Body, Map, Req, State)};
                        error ->
                            {continue, Result}
                    end;
                false ->
                    janus_lb:bump_stat(failovers_exhausted),
                    {continue, Result}
            end
    end.

retry_dispatch(ClientProto, Route2, Body, Map, Req, State) ->
    case provider_protocol(Route2) of
        {ok, ProviderProto2} ->
            dispatch(ClientProto, ProviderProto2, Route2, Body, Map, Req, State);
        {error, unknown_protocol} ->
            _ = release_route_inflight(Route2),
            reply_err(ClientProto, Req, State, 502, <<"unknown_protocol">>, <<"provider has unknown protocol">>)
    end.

retry_jitter() ->
    rand:uniform(200) + 99.

mark_key_attempted(Route) ->
    case key_id_of(Route) of
        Kid when is_integer(Kid) ->
            Attempted = [Kid | lists:delete(Kid, key_attempt_list())],
            put(janus_failover_keys, Attempted);
        _ ->
            ok
    end.

key_attempt_list() ->
    case get(janus_failover_keys) of
        L when is_list(L) -> L;
        _ -> []
    end.

key_attempted(Route) ->
    case key_id_of(Route) of
        Kid when is_integer(Kid) -> lists:member(Kid, key_attempt_list());
        _ -> false
    end.

%% Re-pick a route for the SAME model, skipping already-attempted keys
%% and (for translate-blocked streams) protocol-incompatible routes.
repick_route(_ClientProto, _Map, 0) ->
    error;
repick_route(ClientProto, Map, Tries) ->
    ModelName = get(janus_req_model),
    Blocked =
        janus_protocol_translate:wants_stream(Map) andalso
            janus_protocol_translate:stream_translate_blocked(ClientProto, Map),
    Pick =
        case resolve_model(ModelName) of
            {ok, ModelId} -> janus_lb:pick_route(ModelId, #{});
            error -> janus_lb:pick_listing_route(ModelName, #{})
        end,
    case Pick of
        {ok, Route} ->
            ProtoOK =
                (not Blocked) orelse
                    (provider_protocol(Route) =:= {ok, ClientProto}),
            case key_attempted(Route) orelse not ProtoOK of
                true ->
                    _ = release_route_inflight(Route),
                    repick_route(ClientProto, Map, Tries - 1);
                false ->
                    {ok, Route}
            end;
        {error, _} ->
            error
    end.

failover_note(Route, {ok, 401, _H, _B}) ->
    _ = note_auth_failure(Route, 401),
    _ = release_route_inflight(Route),
    ok;
failover_note(Route, {ok, 403, _H, _B}) ->
    _ = note_route_failure(Route, {http, 403}),
    _ = release_route_inflight(Route),
    ok;
failover_note(Route, {ok, 429, H, _B}) ->
    _ = note_key_failure(Route, H, 429),
    _ = release_route_inflight(Route),
    ok;
failover_note(Route, {ok, Status, _H, _B}) when Status >= 500 ->
    _ = note_provider_failure(Route, {http, Status}),
    _ = release_route_inflight(Route),
    ok;
failover_note(Route, {error, _Reason}) ->
    _ = release_route_inflight(Route),
    ok;
failover_note(Route, _Other) ->
    %% Deny-shaped 4xx: key-scoped — bench the key briefly.
    _ = note_key_failure(Route, #{}, 400),
    _ = release_route_inflight(Route),
    ok.

%% Non-terminal usage row for a retried attempt (terminal row comes
%% from track/3 on the final outcome; it attaches the same
%% request_ref/attempt from the process dictionary).
failover_record_attempt(Route, {ok, Status, _H, _B}, ErrCode) ->
    record_failover_row(Route, Status, ErrCode);
failover_record_attempt(Route, {error, crashed}, _ErrCode) ->
    record_failover_row(Route, 500, crashed);
failover_record_attempt(Route, {error, Reason}, _ErrCode) ->
    record_failover_row(Route, 502, sanitize_upstream_error(Reason)).

record_failover_row(Route, Status, ErrCode) ->
    case get(janus_usage_ctx) of
        #{started := _Started, agent := Agent, client_proto := Proto, stream := Stream} ->
            janus_usage:record(#{
                ts => erlang:system_time(second),
                agent_key_id => maps:get(id, Agent, null),
                model_id => maps:get(model_id, Route, null),
                provider_id => maps:get(provider_id, Route, null),
                provider_key_id => key_id_of(Route),
                protocol => Proto,
                stream => usage_bool_int(Stream),
                status => Status,
                prompt => null,
                completion => null,
                latency_ms => 0,
                error_code => ErrCode,
                attempt => pd(janus_failover_attempt, 1),
                request_ref => pd(janus_failover_ref, null),
                is_terminal => false
            });
        _ ->
            ok
    end.

%%% Retry-time classification (codes table single-source, spec C.1)

failover_classify(_Route, {ok, Status, _H, _B}) when
    Status =:= 401; Status =:= 403; Status =:= 429; Status >= 500
->
    {retryable, null};
failover_classify(Route, {ok, Status, _H, Body}) when Status >= 400, Status < 500 ->
    case classify_client_error(Route, Status, Body) of
        deny ->
            {retryable, deny};
        balance ->
            {retryable, balance};
        rate ->
            {retryable, rate};
        input_shape ->
            terminal;
        unclassified ->
            %% Bounded cost: one failover attempt on an unclassified
            %% 4xx, then terminal (codes-table feedback for the next
            %% seed update). Fully fail-open when the table is empty.
            case get(janus_failover_unclassified_retried) of
                true ->
                    terminal;
                _ ->
                    put(janus_failover_unclassified_retried, true),
                    {retryable, unclassified}
            end
    end;
failover_classify(_Route, {error, _Reason}) ->
    %% Transport errors behave like 5xx: retryable within the budget.
    {retryable, null};
failover_classify(_Route, _Result) ->
    terminal.

classify_client_error(Route, _Status, Body) ->
    Codes = janus_catalog:entitlement_codes(),
    Provider = route_provider_name(Route),
    Rows = maps:get(Provider, Codes, []),
    {Code, Message} = extract_error_code_message(Body),
    classify_with_rows(Rows, Code, Message).

classify_with_rows([], _Code, _Message) ->
    unclassified;
classify_with_rows([Row | Rest], Code, Message) ->
    MS = maps:get(match_status, Row, undefined),
    KW = maps:get(code_keyword, Row, undefined),
    Outcome = maps:get(outcome, Row, undefined),
    Matched =
        case MS of
            <<"regex">> -> regex_matches(KW, Message) orelse regex_matches(KW, Code);
            _ -> is_binary(KW) andalso KW =/= <<>> andalso KW =:= Code
        end,
    case Matched of
        true -> outcome_atom(Outcome);
        false -> classify_with_rows(Rest, Code, Message)
    end.

regex_matches(Pattern, Subject) when is_binary(Pattern), is_binary(Subject), Subject =/= <<>> ->
    try
        re:run(Subject, Pattern, [{capture, none}]) =:= match
    catch
        _:_ -> false
    end;
regex_matches(_, _) ->
    false.

outcome_atom(<<"deny">>) -> deny;
outcome_atom(<<"balance">>) -> balance;
outcome_atom(<<"rate">>) -> rate;
outcome_atom(<<"input_shape">>) -> input_shape;
outcome_atom(_) -> unclassified.

%% Provider-native error code + message from the error body. Tolerant:
%% OpenAI {error:{code,message}}, DashScope top-level {code,message},
%% Anthropic {type:error,error:{type,message}}.
extract_error_code_message(Body) when is_binary(Body) ->
    case thoas:decode(Body) of
        {ok, Map} when is_map(Map) ->
            Err = maps:get(<<"error">>, Map, #{}),
            Inner =
                case Err of
                    E when is_map(E) -> E;
                    _ -> #{}
                end,
            Code =
                first_bin([
                    maps:get(<<"code">>, Map, undefined),
                    maps:get(<<"code">>, Inner, undefined),
                    maps:get(<<"type">>, Inner, undefined)
                ]),
            Message =
                first_bin([
                    maps:get(<<"message">>, Map, undefined),
                    maps:get(<<"message">>, Inner, undefined)
                ]),
            {Code, Message};
        _ ->
            {undefined, undefined}
    end;
extract_error_code_message(_) ->
    {undefined, undefined}.

first_bin([B | Rest]) when is_binary(B), B =/= <<>> -> B;
first_bin([_ | Rest]) -> first_bin(Rest);
first_bin([]) -> undefined.

%%--------------------------------------------------------------------
%% Errors / replies
%%--------------------------------------------------------------------

reply_pick_error(ClientProto, Req, State, Reason) ->
    %% Pick failures happen INSIDE do_proxy (already counted). track/3
    %% writes the usage row (null route ids) and bumps failed.
    _ = track(pick_error_status(Reason), #{}, #{}),
    do_reply_pick_error(ClientProto, Req, State, Reason).

pick_error_status({all_cooling, _}) -> 503;
pick_error_status(provider_disabled) -> 503;
pick_error_status(keys_disabled) -> 503;
pick_error_status(missing_provider_key) -> 503;
pick_error_status(catalog_not_ready) -> 503;
pick_error_status(_) -> 404.

do_reply_pick_error(ClientProto, Req, State, all_cooling) ->
    do_reply_pick_error(ClientProto, Req, State, {all_cooling, 5000});
do_reply_pick_error(ClientProto, Req, State, {all_cooling, Ms}) when is_integer(Ms), Ms > 0 ->
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
do_reply_pick_error(ClientProto, Req, State, provider_disabled) ->
    reply_err(
        ClientProto, Req, State, 503, <<"provider_disabled">>,
        <<"the provider for this model is disabled">>
    );
do_reply_pick_error(ClientProto, Req, State, keys_disabled) ->
    reply_err(ClientProto, Req, State, 503, <<"no_usable_key">>, <<"no enabled upstream keys">>);
do_reply_pick_error(ClientProto, Req, State, missing_provider_key) ->
    reply_err(
        ClientProto, Req, State, 503, <<"no_usable_key">>, <<"provider has no keys configured">>
    );
do_reply_pick_error(ClientProto, Req, State, catalog_not_ready) ->
    reply_err(
        ClientProto,
        Req,
        State,
        503,
        <<"catalog_not_ready">>,
        <<"catalog not ready">>,
        #{<<"retry-after">> => <<"1">>}
    );
do_reply_pick_error(ClientProto, Req, State, _Reason) ->
    reply_err(ClientProto, Req, State, 404, <<"no_route">>, <<"no route for model">>).

reply_err(ClientProto, Req, State, Status, Code, Msg) ->
    reply_err(ClientProto, Req, State, Status, Code, Msg, #{}).

reply_err(ClientProto, Req, State, Status, Code, Msg, Extra) ->
    %% Every agent-facing rejection is logged (warning): the dashboard
    %% Logs page is the first place operators look when a client reports
    %% "provider rejected my request" — silent 400s forced Caddy-log
    %% archaeography once too often.
    logger:warning(#{
        what => janus_agent_reject,
        status => Status,
        code => Code,
        model => get(janus_req_model),
        method => cowboy_req:method(Req),
        path => cowboy_req:path(Req),
        request_id => get(janus_request_id)
    }),
    case get(janus_req_counted) of
        true ->
            ok;
        _ ->
            put(janus_req_counted, true),
            janus_metrics:inc(requests_total, #{
                endpoint => janus_http_classify:endpoint(cowboy_req:path(Req)),
                protocol => janus_http_classify:protocol(cowboy_req:path(Req)),
                status_class => janus_http_classify:status_class(Status)
            })
    end,
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

filter_stream_headers(_Headers) when is_map(_Headers) ->
    %% Always SSE, even if the upstream advertised JSON (some OpenAI-
    %% compatible proxies lie on the streaming face).
    #{
        <<"content-type">> => <<"text/event-stream">>,
        <<"cache-control">> => <<"no-cache">>,
        <<"connection">> => <<"keep-alive">>,
        <<"x-accel-buffering">> => <<"no">>
    };
filter_stream_headers(_) ->
    #{<<"content-type">> => <<"text/event-stream">>}.

%%--------------------------------------------------------------------
%% Node counters (Slice B): one client LLM call = +1 total at
%% do_proxy entry; +1 failed exactly once on a client-visible >=400
%% outcome (outer track) or the crash fallback. Inner calls (a future
%% janus-auto/failover inner do_proxy) never bump either counter.
%%--------------------------------------------------------------------

inc_total_once() ->
    case get(janus_stats_inner) of
        true ->
            ok;
        _ ->
            janus_http_stats:inc_total(),
            put(janus_stats_counted, true)
    end.

bump_failed_maybe(Status) when Status >= 400 ->
    case {get(janus_stats_inner), get(janus_stats_failed)} of
        {true, _} ->
            ok;
        {_, true} ->
            ok;
        _ ->
            janus_http_stats:inc_failed(),
            put(janus_stats_failed, true)
    end;
bump_failed_maybe(_Status) ->
    ok.

maybe_crash_bump_failed() ->
    %% Cowboy keep-alive leaves inner as undefined after erase/1, not
    %% the atom false. Only skip when this process is an inner call.
    Counted = get(janus_stats_counted) =:= true,
    Inner = get(janus_stats_inner) =:= true,
    Tracked = get(janus_stats_tracked) =:= true,
    Failed = get(janus_stats_failed) =:= true,
    case Counted andalso (not Inner) andalso (not Tracked) andalso (not Failed) of
        true ->
            janus_http_stats:inc_failed(),
            put(janus_stats_failed, true);
        false ->
            ok
    end.

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
    put(janus_stats_tracked, true),
    bump_failed_maybe(Status),
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
            logger:info(#{
                what => janus_request,
                model => maps:get(model_id, Route, null),
                model_name => get(janus_req_model),
                provider => maps:get(provider_id, Route, null),
                status => Status,
                stream => usage_bool_int(Stream),
                latency_ms => LatencyMs,
                request_id => get(janus_request_id)
            }),
            janus_metrics:inc(requests_total, #{
                endpoint => janus_http_classify:endpoint(get(janus_req_path)),
                protocol => janus_http_classify:protocol(get(janus_req_path)),
                status_class => janus_http_classify:status_class(Status)
            }),
            janus_metrics:observe(
                request_duration_seconds,
                #{
                    protocol => janus_http_classify:protocol(get(janus_req_path)),
                    stream => usage_bool_int(Stream)
                },
                LatencyMs / 1000
            ),
            case maps:get(provider_id, Route, undefined) of
                undefined ->
                    ok;
                _ ->
                    janus_metrics:inc(upstream_requests_total, #{
                        provider => route_provider_name(Route),
                        status_class => janus_http_classify:status_class(Status)
                    })
            end,
            put(janus_req_counted, true),
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
                latency_ms => LatencyMs,
                error_code => pd(janus_failover_err_code, null),
                attempt => pd(janus_failover_attempt, 1),
                request_ref => pd(janus_failover_ref, null),
                is_terminal => true,
                request_id => get(janus_request_id)
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
