%%%-------------------------------------------------------------------
%%% @doc Shared data-plane proxy: auth'd handlers call proxy/5 with
%%% client protocol; dispatches native or translate paths.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_proxy).

-define(UPSTREAM_STALLED_MSG, <<"upstream stopped sending data mid-stream">>).
-define(STREAM_TIMEOUT_MSG, <<"upstream stream exceeded the total time budget">>).


-include("janus_protocol_translate.hrl").

-export([handle/5, model_field/1]).
%% Exported for eunit (usage capture helpers + Phase-2 knob).
-export([
    maybe_trim/2,
    maybe_inject_stream_usage/4,
    stream_translate_blocked_for/2,
    responses_stream_translate_enabled/0,
    %% SSE keepalive framing (native path): pure, so eunit can pin the
    %% event-boundary rule without a socket.
    sse_at_event_boundary/2
]).
%% failover_start/0 is also called by janus_modality (the modality
%% entry mints the per-request ref through the same helper);
%% failover_classify/2 is exported for the precedence-table eunit.
-export([
    failover_start/0,
    failover_classify/2
]).
%% Exported for eunit (Decisions spec 2026-10-07): face eligibility
%% gate + ordered pre-pick pipeline + forward-decision predicates.
-export([
    proto_gate/2,
    route_eligible/2,
    protocol_requires_native_msg/2,
    face_eligibility_opts/1,
    stream_pick_opts/2,
    decisions_pre_pick/2,
    decisions_auto_model/1,
    decisions_presend_failure/1,
    decisions_local_error/1,
    %% error envelope builder (envelope-shape eunit, Decisions spec)
    error_map/3,
    %% Wire compression abort classification (spec
    %% 2026-10-12-wire-compression F2 — eunit): the inflate-fail abort
    %% is TERMINAL (the N9 worker_lost class, never 5xx-retryable).
    failover_classify/2,
    %% Pick-error matrix (review 06d M2/M5, eunit): which pick errors
    %% may advance the janus-auto next-name walk, and the status class
    %% fed to track/3 for every pick-error reply.
    is_advanceable_pick_error/1,
    pick_error_status/1
]).

-define(MAX_BODY, 200 * 1024 * 1024).
-define(IS_WIRE_ENC_ABORT(R),
    ((R) =:= wire_enc_inflate_fail orelse
        (is_tuple(R) andalso tuple_size(R) >= 1 andalso
            element(1, R) =:= wire_enc_inflate_fail))
).

-define(USAGE_HEAD_BYTES, 4096).
-define(USAGE_TAIL_BYTES, 16384).
-define(USAGE_TAIL_CHUNKS, 256).

%% ClientProto = openai_chat | openai_responses | anthropic_messages |
%%                openai_decisions (native passthrough only, D4)
-spec handle(atom(), map(), binary(), cowboy_req:req(), term()) ->
    {ok, cowboy_req:req(), term()}.
handle(ClientProto, Agent, Body, Req, State) ->
    %% Per-request usage context. Cowboy reuses the process across
    %% HTTP/1.1 keep-alive requests, so erase first — stale keys from a
    %% previous request must never leak into this one.
    erase(janus_usage_ctx),
    erase(janus_usage_head),
    erase(janus_usage_tail),
    erase(janus_dead_jobs),
    erase(janus_usage_outcome),
    erase(janus_worker_done_usage),
    %% upstream_call/5 wall time: absent on paths that never reached
    %% upstream, and must never be inherited by a later keep-alive
    %% request (maybe_note_latency/1 feeds it into the LB EWMA).
    erase(janus_upstream_ms),
    erase(janus_req_model),
    %% Resolution accounting: the client's ORIGINAL model name (before
    %% janus-auto tier routing replaced it); rides usage rows as
    %% requested_model so spend can be attributed per resolution.
    erase(janus_requested_model),
    erase(janus_sse_state),
    erase(janus_sse_tracked),
    erase(janus_failover_started),
    erase(janus_failover_ref),
    erase(janus_failover_attempt),
    erase(janus_last_upstream_error),
    erase(janus_part_c_attempt),
    erase(janus_failover_keys),
    erase(janus_failover_unclassified_retried),
    %% janus-auto same-tier next-name snapshot (design 2026-10-15 D2).
    erase(janus_auto_tier),
    erase(janus_auto_tier_names),
    erase(janus_auto_names_attempted),
    erase(janus_auto_tier_failover),
    erase(janus_auto_tier_max_names),
    erase(janus_auto_http_attempts),
    erase(janus_client_committed),
    %% Observability-depth Task 2 stash keys (the last retryable
    %% failover classification): erased per request so a 2xx following
    %% a failed request on this keep-alive process cannot inherit
    %% stale values.
    erase(janus_last_native_code),
    erase(janus_last_reason),
    erase(janus_stats_counted),
    erase(janus_stats_tracked),
    erase(janus_stats_failed),
    erase(janus_stats_inner),
    erase(janus_req_counted),
    %% janus_request_id is deliberately NOT erased here: the handler
    %% resolves and puts it (fresh for every request, incl. keep-alive
    %% reuse) before calling the proxy; track/3 reads it below.
    %% janus_trace (Task 3) follows the same discipline: the handler
    %% entry puts it before the proxy runs, so it must survive this
    %% list; every entry re-puts unconditionally, so no stale trace can
    %% leak across keep-alive requests.
    %% Mint the per-request failover ref for EVERY request (hoisted
    %% from the retry paths — observability-depth Task 2): the mint is
    %% idempotent per request (the janus_failover_started guard), so
    %% the retry-path calls below become harmless no-ops.
    failover_start(),
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

handle_body(openai_decisions, Agent, Body, Req, State) ->
    %% Decisions pipeline §4.2 steps 3-5: JSON parse -> grant check by
    %% body model -> stream guard (D18: body field ONLY — the Accept
    %% header is never examined). Step 6 (pick/eligibility) runs in
    %% do_proxy/6. No janus-auto routing on this face (§4.5 last row).
    case thoas:decode(Body) of
        {ok, Map} when is_map(Map) ->
            case decisions_pre_pick(Agent, Map) of
                {ok, Model} ->
                    do_proxy(openai_decisions, Model, Body, Map, Req, State);
                {error, {Status, Code, Msg}} ->
                    reply_err(openai_decisions, Req, State, Status, Code, Msg)
            end;
        {ok, _} ->
            reply_err(
                openai_decisions,
                Req,
                State,
                400,
                <<"invalid_json">>,
                <<"request body must be a JSON object">>
            );
        {error, _} ->
            reply_err(
                openai_decisions, Req, State, 400, <<"invalid_json">>, <<"request body must be JSON">>
            )
    end;
handle_body(ClientProto, Agent, Body, Req, State) ->
    case thoas:decode(Body) of
        {ok, Map} when is_map(Map) ->
            {Body1, Map1} = maybe_materialize_files(Agent, Body, Map),
            {Body2, Map2} = maybe_repair_tools(ClientProto, Body1, Map1),
            maybe_count_images(ClientProto, Map2),
            case extract_model(ClientProto, Map1) of
                {ok, Model} ->
                    %% Seed before the allowlist reject so the reject log
                    %% names the client's raw model, not just the
                    %% (unset) resolved one.
                    put(janus_requested_model, Model),
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
                            proxy_model(ClientProto, Model, Body2, Map2, Req, State, Agent)
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

%% Files API materialization (2026-10-26): rewrite file-janus-*
%% content references into ordinary content BEFORE any routing or
%% translation, on the canonical chat shape. The RAW body is re-encoded
%% too — the native (same-protocol) path forwards raw bytes and would
%% otherwise carry the stale references upstream. Knob-off or no
%% references: byte-for-byte passthrough (zero overhead, zero drift).
maybe_materialize_files(#{id := AgentKeyId}, RawBody, Map) ->
    case janus_files:enabled() andalso janus_files:has_references(RawBody) of
        true ->
            Map1 = janus_files:materialize(AgentKeyId, Map),
            {thoas:encode(Map1), Map1};
        false ->
            {RawBody, Map}
    end;
maybe_materialize_files(_Agent, RawBody, Map) ->
    {RawBody, Map}.

-spec model_field(atom()) -> binary().
model_field(_) ->
    <<"model">>.

%% Requests carrying image parts, counted by face. Answers the recurring
%% "did the image reach the gateway" question in one grep (2026-10-21:
%% memoh's sub-agent answered NO_VISION because its runtime stripped the
%% image before the call — provable only with this counter).
maybe_count_images(ClientProto, Map) ->
    case request_has_image(Map) of
        true ->
            janus_metrics:inc(requests_with_images_total, #{
                endpoint => janus_http_classify:endpoint(get(janus_req_path)),
                protocol => ClientProto
            });
        false ->
            ok
    end.

request_has_image(Map) when is_map(Map) ->
    Msgs =
        case Map of
            #{<<"messages">> := M} when is_list(M) -> M;
            #{<<"input">> := I} when is_list(I) -> I;
            _ -> []
        end,
    lists:any(fun message_has_image/1, Msgs);
request_has_image(_) ->
    false.

message_has_image(#{<<"content">> := Parts}) when is_list(Parts) ->
    lists:any(fun part_is_image/1, Parts);
message_has_image(_) ->
    false.

part_is_image(#{<<"type">> := T}) ->
    T =:= <<"image_url">> orelse T =:= <<"image">> orelse T =:= <<"input_image">>;
part_is_image(_) ->
    false.

extract_model(_Proto, Map) ->
    case maps:get(<<"model">>, Map, undefined) of
        undefined ->
            {error, <<"model required">>};
        Model when is_binary(Model), Model =/= <<>> ->
            {ok, Model};
        _ ->
            {error, <<"model must be a non-empty string">>}
    end.

%%--------------------------------------------------------------------
%% OpenAI Decisions face (spec 2026-10-07). Native passthrough only:
%% no translate clauses anywhere (D4), no streaming (§4.6), no auto
%% routing, failover only on pre-send failures (D15).
%%--------------------------------------------------------------------

%% §4.2 steps 3-5 as one ordered function (exported so eunit can pin
%% the ORDER, not just the outcomes): model extract -> grant check ->
%% stream guard. Precedence rows 2/3 are disjoint BY order — a
%% denylisted model with "stream": true reports model_not_allowed
%% (grant outranks stream), an allowed model with "stream": true
%% reports stream_not_supported (stream outranks route resolution).
decisions_pre_pick(Agent, Map) when is_map(Map) ->
    case extract_model(openai_decisions, Map) of
        {error, Msg} ->
            {error, {400, <<"invalid_request">>, Msg}};
        {ok, Model} ->
            case model_allowed(Agent, Model) of
                false ->
                    {error,
                        {403, <<"model_not_allowed">>, <<"model not in allowlist">>}};
                true ->
                    %% D18: reject on the BODY field only (boolean
                    %% true or the string "true", same rule as every
                    %% other face's wants_stream); an
                    %% `Accept: text/event-stream` header alone never
                    %% reaches this check — headers are not inputs.
                    case janus_protocol_translate:wants_stream(Map) of
                        true ->
                            {error,
                                {400, <<"stream_not_supported">>,
                                    <<"decisions does not support streaming">>}};
                        false ->
                            {ok, Model}
                    end
            end
    end.

%% §4.5 last row: the janus-auto virtual model is never callable on
%% /v1/decisions — it resolves to protocol_requires_native, not a
%% route. Reads the configured auto model name (default janus-auto);
%% total — a broken router config degrades to the default name.
decisions_auto_model(Name) when is_binary(Name) ->
    AutoModel =
        case catch janus_auto:snapshot() of
            #{model := M} when is_binary(M) -> M;
            _ -> <<"janus-auto">>
        end,
    Name =:= AutoModel;
decisions_auto_model(_) ->
    false.

proxy_model(ClientProto, ModelName, Body, Map, Req, State, Agent) ->
    put(janus_requested_model, ModelName),
    %% janus-auto skips cross-protocol tier members ONLY when the
    %% stream translate path is blocked (tools/vision/n>1, or a
    %% responses client the responses knob does not cover). Plain
    %% text/thinking streams translate, including responses clients
    %% when translate.responses is ON.
    AutoConstraint = #{
        client_proto => ClientProto,
        stream => stream_translate_blocked_for(ClientProto, Map),
        vision => request_has_image(Map)
    },
    case janus_auto:maybe_route(ModelName, Map, AutoConstraint) of
        {ok, Target, Meta} when is_map(Meta) ->
            %% Snapshot effective walk list + knobs once (D2). The
            %% direct-member walk (below) sets the same keys; plain
            %% non-member names still set none.
            put(janus_req_model, Target),
            put(janus_auto_tier, maps:get(tier, Meta)),
            put(janus_auto_tier_names, maps:get(names, Meta, [])),
            put(janus_auto_names_attempted, [Target]),
            put(janus_auto_tier_failover, maps:get(tier_failover_enabled, Meta, false)),
            put(janus_auto_tier_max_names, maps:get(tier_failover_max_names, Meta, 3)),
            put(janus_auto_http_attempts, 0),
            do_proxy(ClientProto, Target, Body, Map#{<<"model">> => Target}, Req, State);
        pass ->
            %% Direct tier-member names arm the same-tier walk too (quota
            %% 429 on a pinned member must advance, not leak). The walk
            %% list is filtered to the agent key's allowlist: failover
            %% must never grant a model the ACL denies. Non-member names
            %% keep the old direct behaviour (no walk).
            case janus_auto:direct_walk(ModelName) of
                {ok, Meta} when is_map(Meta) ->
                    Allowed = [N || N <- maps:get(names, Meta, []), model_allowed(Agent, N)],
                    put(janus_req_model, ModelName),
                    put(janus_auto_tier, maps:get(tier, Meta)),
                    put(janus_auto_tier_names, Allowed),
                    put(janus_auto_names_attempted, [ModelName]),
                    put(janus_auto_tier_failover, maps:get(tier_failover_enabled, Meta, false)),
                    put(janus_auto_tier_max_names, maps:get(tier_failover_max_names, Meta, 3)),
                    put(janus_auto_http_attempts, 0),
                    do_proxy(ClientProto, ModelName, Body, Map, Req, State);
                _ ->
                    do_proxy(ClientProto, ModelName, Body, Map, Req, State)
            end;
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

do_proxy(openai_decisions, ModelName, Body, Map, Req, State) ->
    inc_total_once(),
    put(janus_req_model, ModelName),
    %% §4.5 last row: janus-auto on the Decisions face answers
    %% protocol_requires_native — the auto-router itself is never
    %% consulted on this face (its tiers are chat-protocol routes).
    case decisions_auto_model(ModelName) of
        true ->
            _ = track(400, #{}, #{}),
            reply_err(
                openai_decisions,
                Req,
                State,
                400,
                <<"protocol_requires_native">>,
                <<"client face openai_decisions cannot call model that requires janus-auto">>
            );
        false ->
            proxy_common(openai_decisions, ModelName, Body, Map, Req, State)
    end;
do_proxy(ClientProto, ModelName, Body, Map, Req, State) ->
    inc_total_once(),
    put(janus_req_model, ModelName),
    proxy_common(ClientProto, ModelName, Body, Map, Req, State).

%% Shared post-count pipeline for every face: face-eligibility gate
%% (§4.5 rows 4-5) runs BEFORE the wrong_modality guard (TF-D.13 —
%% eligibility outranks modality, and a chat-family call naming a
%% Decisions-only listing must answer protocol_requires_native, never
%% wrong_modality), then the modality guard, then the pick.
proxy_common(ClientProto, ModelName, Body, Map, Req, State) ->
    case proto_gate(ClientProto, ModelName) of
        {error, protocol_requires_native} ->
            _ = track(400, #{}, #{}),
            reply_err(
                ClientProto,
                Req,
                State,
                400,
                <<"protocol_requires_native">>,
                protocol_requires_native_msg(ClientProto, ModelName)
            );
        ok ->
            %% wrong_modality guard (modality spec Contracts): a chat-family
            %% call naming a non-chat-listed model is rejected LOCALLY — the
            %% upstream would only 400 with a worse message.
            case janus_catalog:model_modality(ModelName) of
                <<"chat">> ->
                    proxy_after_modality(ClientProto, ModelName, Body, Map, Req, State);
                Other ->
                    Msg = iolist_to_binary([
                        <<"model is of modality '">>, Other, <<"'; call ">>,
                        janus_modality:endpoint_for(Other), <<" instead">>
                    ]),
                    _ = track(400, #{}, #{}),
                    reply_err(ClientProto, Req, State, 400, <<"wrong_modality">>, Msg)
            end
    end.

proxy_after_modality(openai_decisions, ModelName, Body, Map, Req, State) ->
    %% §4.2 step 6 + §4.5 row 8: pick among ELIGIBLE routes only
    %% (require_proto openai_decisions — the LB applies the hard
    %% filter; rows 6/7 surface as the pick's existing errors).
    PickOpts = face_eligibility_opts(openai_decisions),
    Pick =
        case resolve_model(ModelName) of
            {ok, ModelId} -> janus_lb:pick_route(ModelId, PickOpts);
            error -> janus_lb:pick_listing_route(ModelName, PickOpts)
        end,
    case Pick of
        {ok, Route} ->
            decisions_dispatch(Route, Body, Map, Req, State, 1);
        {error, Reason} ->
            reply_pick_error(openai_decisions, Req, State, Reason)
    end;
proxy_after_modality(ClientProto, ModelName, Body, Map, Req, State) ->
    PickOpts = stream_pick_opts(ClientProto, Map),
    case resolve_model(ModelName) of
        {ok, ModelId} ->
            proxy_picked(
                ClientProto,
                janus_lb:pick_route(ModelId, PickOpts),
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
                janus_lb:pick_listing_route(ModelName, PickOpts),
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
            %% An initial empty pick (all_cooling / provider_disabled /
            %% keys_disabled / missing_provider_key) can still next-name
            %% when the auto snapshot allows it (D15.1 zero-HTTP path).
            case maybe_next_name_on_pick_error(ClientProto, Reason, Body, Map, Req, State) of
                {handled, Ok} -> Ok;
                continue -> reply_pick_error(ClientProto, Req, State, Reason)
            end
    end.

provider_protocol(#{provider_id := Pid}) ->
    case janus_catalog:lookup_provider(Pid) of
        {ok, #{protocol := P}} ->
            janus_protocol_translate:normalize_protocol(P);
        {ok, Map} ->
            janus_protocol_translate:normalize_protocol(maps:get(protocol, Map, undefined));
        error ->
            {error, unknown_protocol}
    end;
%% Total (Decisions spec §4.5): the eligibility gate feeds it raw
%% route maps — a malformed route must defer (unknown), never crash.
provider_protocol(_) ->
    {error, unknown_protocol}.

%%--------------------------------------------------------------------
%% Face eligibility (§4.5 eligibility filter + rows 4-5)
%%--------------------------------------------------------------------

%% §4.5 rows 4-5 pre-gate, ordered and disjoint from rows 6-8 (the
%% pick owns those). `ok` = proceed (unknown names defer to the pick's
%% no_route so the usage row and 404 semantics stay byte-identical);
%% `{error, protocol_requires_native}` = the name exists in the
%% catalog but EVERY route speaks a protocol this face may not call.
%% Runs before the wrong_modality guard (TF-D.13).
-spec proto_gate(atom(), binary()) -> ok | {error, protocol_requires_native}.
proto_gate(ClientProto, ModelName) when is_binary(ModelName) ->
    Routes =
        case resolve_model(ModelName) of
            {ok, ModelId} -> janus_catalog:routes_for_model(ModelId);
            error -> janus_catalog:listings_for(ModelName)
        end,
    case Routes of
        [] ->
            ok;
        _ ->
            case lists:any(fun(R) -> route_eligible(ClientProto, R) end, Routes) of
                true -> ok;
                false -> {error, protocol_requires_native}
            end
    end;
proto_gate(_, _) ->
    ok.

%% Eligibility filter (§4.5): the Decisions client rides ONLY
%% openai_decisions routes; chat/responses/anthropic clients EXCLUDE
%% openai_decisions routes. Unknown provider protocols defer (kept) —
%% old beams skip such rows and fail closed at dispatch with
%% unknown_protocol (D2/TF-D.12), never here.
-spec route_eligible(atom(), map()) -> boolean().
route_eligible(ClientProto, Route) when is_map(Route) ->
    case provider_protocol(Route) of
        {ok, openai_decisions} -> ClientProto =:= openai_decisions;
        {ok, _Other} -> ClientProto =/= openai_decisions;
        {error, unknown_protocol} -> true
    end;
route_eligible(_, _) ->
    true.

%% Pinned message shape (§4.2 table): F = the calling face, P = the
%% protocol the named model requires (first non-eligible route's
%% protocol; deterministic by catalog order).
-spec protocol_requires_native_msg(atom(), binary()) -> binary().
protocol_requires_native_msg(ClientProto, ModelName) ->
    P = first_required_proto(ModelName),
    iolist_to_binary([
        <<"client face ">>,
        atom_to_binary(ClientProto, utf8),
        <<" cannot call model that requires ">>,
        P
    ]).

first_required_proto(ModelName) ->
    Routes =
        case resolve_model(ModelName) of
            {ok, ModelId} -> janus_catalog:routes_for_model(ModelId);
            error -> janus_catalog:listings_for(ModelName)
        end,
    first_proto(Routes).

first_proto([Route | Rest]) ->
    case provider_protocol(Route) of
        {ok, Proto} -> atom_to_binary(Proto, utf8);
        {error, unknown_protocol} -> first_proto(Rest)
    end;
first_proto([]) ->
    <<"another protocol">>.

%% Face -> LB pick-opt policy (§4.5): mechanism in janus_lb
%% (protocol_filter/3), policy here. The Decisions face requires its
%% own protocol; every other face excludes Decisions routes. Applied
%% by stream_pick_opts/2 so the initial pick AND failover repicks
%% share one source (auto-router tier resolution picks by NAME — the
%% exclude is per-protocol route level, exactly TF-D.7's line).
-spec face_eligibility_opts(atom()) -> map().
face_eligibility_opts(openai_decisions) ->
    #{require_proto => <<"openai_decisions">>};
face_eligibility_opts(_) ->
    #{exclude_protos => [<<"openai_decisions">>]}.

%% True when this request wants streaming AND the streaming translate
%% path cannot carry it (tools/vision/n>1, or a responses client with
%% the responses knob off). Exported for eunit; the single source for
%% the auto-router tier constraint and dispatch's 400. (The LB pick
%% bias no longer derives from this — stream_pick_opts prefers
%% same-protocol for every stream, audit R2 C-1.)
-spec stream_translate_blocked_for(atom(), map()) -> boolean().
stream_translate_blocked_for(ClientProto, Map) ->
    janus_protocol_translate:wants_stream(Map)
        andalso stream_blocked_after_knobs(ClientProto, Map).

%% Knob overlay on the conservative stream_translate_blocked/2: a
%% responses-client stream that dispatch would gate through the
%% Phase-2 translate path (gatable + translate.responses ON) must not
%% be "blocked" here either — the auto-tier constraint consumes this
%% predicate, and marking it blocked made tier resolution skip every
%% chat/anthropic member (production no_route 2026-10-17: a streaming
%% translation client on /v1/responses got 404 via janus-auto while
%% naming qwen-flash directly worked). Images are gatable (Responses→
%% chat request mapper preserves input_image); n>1 stays blocked.
%% Knob-off keeps the same-protocol selection. Chat/anthropic clients
%% keep the bare predicate: for them a same-protocol member is picked
%% natively anyway.
stream_blocked_after_knobs(openai_responses, Map) ->
    not (
        responses_stream_translate_enabled()
            andalso janus_protocol_translate:responses_stream_gatable(Map)
     )
        andalso janus_protocol_translate:stream_translate_blocked(openai_responses, Map);
stream_blocked_after_knobs(ClientProto, Map) ->
    janus_protocol_translate:stream_translate_blocked(ClientProto, Map).

%% A streaming request that cannot ride the translate path (responses
%% client, or tools/vision/n>1 on a chat/anthropic pair) must run
%% native: bias the initial pick toward a same-protocol route when the
%% model has one. Without this, the LB could hand dispatch a
%% cross-protocol route and 400 immediately even though a usable
%% same-protocol binding exists (failover's repick already had the
%% constraint; the initial pick did not). When no route matches, the LB
%% falls back to all routes and dispatch answers with the
%% stream_requires_native_protocol 400 that explains what is missing.
%% Translation spec 1.9 ship knob: settings key `translate` =
%% {"tools": boolean} via persistent_term; absent = OFF.
tools_stream_translate_enabled() ->
    case persistent_term:get({janus, translate_cfg}, undefined) of
        #{<<"tools">> := true} -> true;
        _ -> false
    end.

%% Phase-2 ship knob (plan 2.3): streaming translate for
%% openai_responses CLIENTS over chat/anthropic providers. Same
%% settings key `translate`, map key <<"responses">>; absent = OFF
%% (default-off discipline — the dashboard PUTs {"tools": bool} today;
%% the gateway reads this key independently, no dashboard change
%% required). Independent of the tools knob (2x2 matrix, plan 2.3).
responses_stream_translate_enabled() ->
    case persistent_term:get({janus, translate_cfg}, undefined) of
        Cfg when is_map(Cfg) -> maps:get(<<"responses">>, Cfg, false) =:= true;
        _ -> false
    end.

%% Dangling tool-call repair (2026-10-28): settings key `translate`,
%% map key <<"repair_tools">> — synthesize a placeholder tool RESULT for
%% each unanswered CALL in the client's history (strict upstreams 400
%% the whole request otherwise; live: dashscope + minimax through the
%% auto-tier walk). Absent = OFF (byte-identical passthrough).
tools_repair_enabled() ->
    case persistent_term:get({janus, translate_cfg}, undefined) of
        Cfg when is_map(Cfg) -> maps:get(<<"repair_tools">>, Cfg, false) =:= true;
        _ -> false
    end.

%% Entry-side dangling tool-call repair (settings translate.repair_tools):
%% valid histories pass through byte-identical; only an actually
%% repaired body is re-encoded. Covers native AND translate paths —
%% the dangling CALL lives in the client's own history.
maybe_repair_tools(ClientProto, Body, Map) ->
    case tools_repair_enabled() of
        true ->
            case janus_protocol_translate:repair_dangling_tools(ClientProto, Map) of
                {ok, Map} ->
                    {Body, Map};
                {repaired, Map1} ->
                    {thoas:encode(Map1), Map1}
            end;
        false ->
            {Body, Map}
    end.

%% Pick opts = face-eligibility policy (§4.5, hard filter — see
%% face_eligibility_opts/1) + the stream same-protocol bias. The bias
%% prefers same-protocol routes for EVERY stream (audit R2, C-1): a
%% plain-text stream is not "blocked" for translation, but a
%% responses-protocol route can never serve one cross-protocol —
%% without the bias the LB could strand the request on the dispatch
%% guard's 400 while native routes exist. It falls back to all routes
%% when no same-protocol route exists, so translated streams and the
%% explanatory 400s still work. Exported for eunit: the Decisions face
%% must always carry require_proto, the other faces must always
%% exclude openai_decisions, stream or not.
-spec stream_pick_opts(atom(), map()) -> map().
stream_pick_opts(ClientProto, Map) ->
    Base = face_eligibility_opts(ClientProto),
    case janus_protocol_translate:wants_stream(Map) of
        true ->
            Base#{prefer_proto => atom_to_binary(ClientProto, utf8)};
        false ->
            Base
    end.

-define(COMPUTER_USE_TOOLS, [<<"computer_20250124">>]).

has_computer_use_tool(Map) when is_map(Map) ->
    case maps:get(<<"tools">>, Map, undefined) of
        L when is_list(L) ->
            lists:any(
                fun
                    (#{<<"type">> := T}) ->
                        lists:member(T, ?COMPUTER_USE_TOOLS);
                    (_) ->
                        false
                end,
                L
            );
        _ ->
            false
    end;
has_computer_use_tool(_) ->
    false.

dispatch(ClientProto, ProviderProto, Route, Body, Map, Req, State) ->
    %% M4.2 computer-use gate: the computer_* tool family only ever
    %% rides anthropic-native routes — hard-reject locally instead of
    %% letting translation damage the schema.
    case
        ClientProto =:= anthropic_messages andalso
            ProviderProto =/= anthropic_messages andalso
            has_computer_use_tool(Map)
    of
        true ->
            _ = release_route_inflight(Route),
            _ = track(400, Route, #{}),
            reply_err(
                ClientProto, Req, State, 400,
                <<"computer_use_requires_native">>,
                <<"computer-use tools require an anthropic-protocol provider route">>
            );
        false ->
            dispatch_after_computer_use(ClientProto, ProviderProto, Route, Body, Map, Req, State)
    end.

dispatch_after_computer_use(ClientProto, ProviderProto, Route, Body, Map, Req, State) ->
    WantStream = janus_protocol_translate:wants_stream(Map),
    case get(janus_usage_ctx) of
        undefined -> ok;
        Ctx0 -> put(janus_usage_ctx, Ctx0#{stream => WantStream})
    end,
    Native = ClientProto =:= ProviderProto,
    %% C-1 (audit 2026-10-07): streaming toward a Responses-protocol
    %% PROVIDER has no SSE translator (Phase 3) — guard pre-flight
    %% instead of failing mid-stream behind a committed 200. Route
    %% selection uses the same predicate to avoid stranding streams here.
    case
        WantStream andalso
            janus_protocol_translate:stream_pair_untranslatable(ClientProto, ProviderProto)
    of
        true ->
            _ = release_route_inflight(Route),
            _ = track(400, Route, #{}),
            reply_err(
                ClientProto, Req, State, 400,
                <<"stream_requires_native_protocol">>,
                <<"streaming toward a responses-protocol provider is not translated (phase 3)">>
            );
        false ->
            dispatch_after_c1_guard(Native, WantStream, ClientProto, ProviderProto, Route, Body, Map, Req, State)
    end.

dispatch_after_c1_guard(Native, WantStream, ClientProto, ProviderProto, Route, Body, Map, Req, State) ->
    case {Native, WantStream} of
        {false, true} ->
            case janus_protocol_translate:stream_translate_blocked(ClientProto, Map) of
                false ->
                    call_translate(ClientProto, ProviderProto, Route, Map, true, Req, State);
                true ->
                    %% Decide BEFORE any bookkeeping: with a knob ON the
                    %% request proceeds on the translate path (its own
                    %% terminal accounting fires there); recording a 400
                    %% here would double-count every knob-on request as a
                    %% failure.
                    KnobOn =
                        case ClientProto of
                            openai_responses ->
                                %% Phase-2 knob: responses clients stream
                                %% through the chat/anthropic ->responses
                                %% emitters. Tools and images ride THIS knob
                                %% (independent of the tools knob); n>1 stays
                                %% blocked (responses_stream_gatable).
                                responses_stream_pair(ProviderProto) andalso
                                    janus_protocol_translate:responses_stream_gatable(Map) andalso
                                    responses_stream_translate_enabled();
                            _ ->
                                translatable_stream_pair(ClientProto, ProviderProto) =:= true andalso
                                    ClientProto =/= openai_responses andalso
                                    tools_stream_translate_enabled()
                        end,
                    case KnobOn of
                        true ->
                            call_translate(ClientProto, ProviderProto, Route, Map, true, Req, State);
                        false ->
                            _ = release_route_inflight(Route),
                            _ = track(400, Route, #{}),
                            Err =
                                case translatable_stream_pair(ClientProto, ProviderProto) of
                                    true ->
                                        %% Tools/vision/n>1 on a chat<->anthropic
                                        %% pair with the knob off: legacy 400.
                                        {400, <<"translate_unsupported">>,
                                            <<"streaming translate supports text and thinking only (tools knob off)">>};
                                    false ->
                                        {400, <<"stream_requires_native_protocol">>,
                                            <<"streaming requires a same-protocol provider route">>}
                                end,
                            {St, Code, Msg} = Err,
                            reply_err(ClientProto, Req, State, St, Code, Msg)
                    end
            end;
        {true, _} ->
            %% include_usage injection stays on the NATIVE path too:
            %% it is the README-documented usage-accounting mechanism
            %% (without it native streams record null token counts),
            %% and maybe_inject_stream_usage/4 SKIPS requests where the
            %% client set its own stream_options — a client knob is
            %% never overwritten (re-verified after the 2026-10-07
            %% audit flagged it; the overwrite claim did not hold).
            {Body2, Map2} = maybe_inject_stream_usage(ClientProto, WantStream, Body, Map),
            call_native(ClientProto, ProviderProto, Route, Body2, Map2, WantStream, Req, State);
        {false, false} ->
            call_translate(ClientProto, ProviderProto, Route, Map, false, Req, State)
    end.

translatable_stream_pair(openai_chat, anthropic_messages) -> true;
translatable_stream_pair(anthropic_messages, openai_chat) -> true;
translatable_stream_pair(_, _) -> false.

%% Phase-2: the provider protocols the ->responses stream emitters
%% cover. Responses-provider streaming is Phase 3.
responses_stream_pair(openai_chat) -> true;
responses_stream_pair(anthropic_messages) -> true;
responses_stream_pair(_) -> false.

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
            janus_shape_capture:translate_reject(ClientProto, Map, Msg),
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
            %% Request-side prompt estimate for usage synthesis: dialects
            %% that report no usable input token count get this in the
            %% client's terminal usage, marked janus_estimated.
            EstIn = janus_protocol_translate:est_prompt_tokens(ClientProto, Map),
            Result = upstream_call(ProviderProto, Route, OutBody, ProviderMap, WantStream),
            Result2 = maybe_retry_include_usage(
                ClientProto, ProviderProto, Route, ProviderMap, InjectUsed, WantStream, Result
            ),
            case failover_decide(ClientProto, Route, Map, OutBody, Result2, Req, State) of
                {continue, Result3} ->
                    translate_result(
                        ClientProto, ProviderProto, Route, Result3, Req, State, EstIn
                    );
                {handled, Ok} ->
                    Ok
            end
    end.

translate_result(ClientProto, ProviderProto, Route, Result, Req, State, EstIn) ->
    WantStream = true,
    case {WantStream, Result} of
        {true, {ok, stream, Status, Headers, Drain}} when Status < 400 ->
                    handle_translate_stream(
                        ClientProto, ProviderProto, Status, Headers, Drain, Route, Req, State, EstIn
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
    T0 = erlang:monotonic_time(millisecond),
    Stream = janus_http_worker_client:normalize_want_stream(WantStream),
    Local = fun() -> call_adapter(ProviderProto, Route, Body, Map, #{stream => Stream}) end,
    Result =
        try
            %% Master→worker seam (W2.1): pick / ack / relay, else Local.
            janus_http_worker_client:call(ProviderProto, Route, Body, Map, Stream, Local)
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
    %% Wall time of THIS attempt (connect + first byte for streams, plus
    %% body for unary); read by note_route_success/1 to feed the LB
    %% latency EWMA. Retried attempts overwrite it — attribution always
    %% lands on the route that produced the terminal result.
    put(janus_upstream_ms, erlang:monotonic_time(millisecond) - T0),
    normalize_drain_arity(Result).

%% Drain arity normalization: the LOCAL adapter returns the provider's
%% 1-arity drain (janus_providers_http:post_stream/3), while the
%% master->worker seam returns a 2-arity drain that also accepts a
%% client keepalive writer. Every caller now expects 2. The local path
%% is reachable whenever dispatch is not (single node, worker_force_local,
%% empty pool, failed send, missed ack), so wrapping here — once, at the
%% seam — keeps degraded mode from raising badarity on every stream.
%%
%% janus_providers_http:post_stream/3 now returns a 2-arity drain as
%% well, so the local path emits real keepalives from inside its gun
%% loop and BOTH dispatch paths behave the same (verified live
%% 2026-10-29: 12 keepalive frames on the local path during a stall).
%% The 1-arity clause is retained only for older provider adapters.
normalize_drain_arity({ok, stream, Status, Headers, Drain}) when is_function(Drain, 1) ->
    %% Legacy 1-arity provider drain: no keepalive capability.
    {ok, stream, Status, Headers, fun(ChunkFun, _KeepaliveFun) -> Drain(ChunkFun) end};
normalize_drain_arity(Other) ->
    Other.

%% Include_usage injection: only provider openai_chat (never send
%% stream_options to anthropic/responses upstreams, C3), for clients
%% whose translated face reads the trailing usage chunk — anthropic
%% (message_delta.usage) and responses (response.<terminal>.usage).
%% The injected field rides the TRANSLATED provider body (the client's
%% own stream_options never survives translation).
maybe_inject_include_usage(ClientProto, openai_chat, true, ProviderMap) when
    ClientProto =:= anthropic_messages; ClientProto =:= openai_responses
->
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

handle_translate_stream(ClientProto, ProviderProto, Status, Headers, Drain, Route, Req, State, EstIn) ->
    put(janus_sse_state, janus_protocol_translate:new_sse_st(EstIn)),
    put(janus_sse_tracked, false),
    mark_client_committed(),
    Req2 = cowboy_req:stream_reply(Status, filter_stream_headers(Headers), Req),
    try
        Drain(
            fun(Chunk) -> translate_chunk(ClientProto, ProviderProto, Chunk, Req2) end,
            fun(Frame) -> stream_client_frame(Frame, nofin, Req2) end
        )
    of
        ok ->
            finish_translate_stream(ClientProto, Route, Req2, State, normal);
        {error, DrainReason} ->
            %% Remote Drain (and gun) may return {error,_}; must still
            %% finalize + fin (OCR: bare try_clause left clients hanging).
            finish_translate_stream(
                ClientProto,
                Route,
                Req2,
                State,
                {error, upstream, sanitize_stream_reason(DrainReason)}
            )
    catch
        throw:{janus_translate, Kind, Msg} ->
            finish_translate_stream(ClientProto, Route, Req2, State, {error, Kind, Msg});
        throw:janus_client_disconnect ->
            %% Drain aborted from a dead client socket; the drain's
            %% after-clause already closed gun. No frames can be sent.
            finalize_quiet(ClientProto),
            note_usage_outcome(cancelled),
            translate_track(499, Route, ClientProto),
            _ = release_route_inflight(Route),
            {ok, Req2, State};
        Class:Reason ->
            %% EXIT path: the chunked 200 is already committed, so a
            %% bare crash would leave the body unterminated. Funnel
            %% through the same terminal-frame + fin path as the
            %% sibling error clause (OCR: bare try_clause left clients
            %% hanging); finalize_quiet/1 stays for the disconnect
            %% clause only. The client-visible message is a fixed
            %% binary because finalize_sse/3 JSON-encodes Msg and some
            %% sanitized crash reasons are tuples; the detailed reason
            %% goes to the warning below.
            _ = logger:warning(#{
                what => janus_translate_stream_exit,
                class => Class,
                reason => sanitize_upstream_error(Reason)
            }),
            finish_translate_stream(
                ClientProto,
                Route,
                Req2,
                State,
                {error, upstream, <<"stream terminated by an internal gateway error">>}
            )
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
                                %% Prefer the PROVIDER's own words when it
                                %% reported the failure in band; fall back
                                %% to the generic string only when it gave
                                %% us nothing to quote.
                                throw(
                                    {janus_translate, upstream, upstream_stream_error_msg()}
                                );
                            {error, tool_args_cap, StNext} ->
                                %% C5 accumulator cap (args/calls/total or
                                %% the 4MiB content budget): the C2 error
                                %% path — target-format error event +
                                %% terminator via finalize, not a crash.
                                put(janus_sse_state, StNext),
                                throw(
                                    {janus_translate, upstream,
                                        <<"tool call accumulator cap exceeded">>}
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

%% Track SSE framing across forwarded chunks so a keepalive is only ever
%% injected where it cannot corrupt the stream.
%%
%% A keepalive frame is ": comment\n\n" — its trailing BLANK LINE
%% DISPATCHES any pending event. So a line boundary is not enough: for a
%% multi-line event (anthropic's "event: X\ndata: {...}\n\n"), a chunk
%% ending right after the "event:" line still ends in \n, and injecting
%% there would dispatch the event early with no data. What matters is an
%% EVENT boundary: the previous two bytes were \n\n, which is carried
%% across chunk boundaries via janus_sse_prev_byte.
note_sse_line_state(<<>>) ->
    ok;
note_sse_line_state(Chunk) when is_binary(Chunk) ->
    %% Previous byte BEFORE this chunk (undefined on the first chunk).
    %% Read it before overwriting, and let a size-1 chunk use it: the
    %% "\n\n" pair can straddle the chunk boundary.
    Prev = case get(janus_sse_prev_byte) of
        B when is_integer(B) -> B;
        _ -> undefined
    end,
    AtBoundary = sse_at_event_boundary(Prev, Chunk),
    put(janus_sse_prev_byte, binary:last(Chunk)),
    put(janus_sse_at_boundary, AtBoundary),
    ok;
note_sse_line_state(_) ->
    ok.

%% Is the stream positioned at an EVENT boundary after this chunk?
%% Decided from the chunk's trailing bytes alone (plus the carried
%% previous byte when the chunk is a single byte, where the pair can
%% straddle the boundary). A size >= 2 chunk never consults Prev, so a
%% stale value cannot influence it.
%%
%% CRLF is legal SSE, but a line always terminates with \n, so an event
%% boundary is still a blank line: the last two bytes are \n\n.
sse_at_event_boundary(_Prev, <<>>) ->
    false;
sse_at_event_boundary(Prev, Chunk) when is_binary(Chunk) ->
    case byte_size(Chunk) of
        1 -> Prev =:= $\n andalso binary:last(Chunk) =:= $\n;
        N -> binary:part(Chunk, N - 2, 2) =:= <<"\n\n">>
    end.

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
    WireReason = wire_reason(Reason),
    {ok, Frames, St1} = janus_protocol_translate:finalize_sse(ClientProto, WireReason, St0),
    put(janus_sse_state, St1),
    case Reason of
        normal ->
            TrackStatus = 200,
            _ = note_key_success(Route),
            _ = note_route_success(Route);
        {error, invalid_request, _} ->
            %% The wire status (200) was committed by stream_reply/3
            %% before this mid-stream guard fired; tracking 400 here
            %% made the usage row and status_class metric disagree
            %% with the status the client actually saw (review L2).
            TrackStatus = 200,
            note_usage_outcome(error);
        {error, upstream, Msg} ->
            TrackStatus = 502,
            note_usage_outcome(error),
            case wire_enc_abort_reason(Msg) of
                true ->
                    %% Internal-hop inflate failure on the TRANSLATE
                    %% stream path (spec 2026-10-12-wire-compression F2):
                    %% identical frames/accounting to any other upstream
                    %% stream failure, but NO provider benching (our
                    %% wire, not the provider's). The Msg here is already
                    %% the sanitized reason (see handle_translate_stream)
                    %% — both sanitize shapes of the abort reason match.
                    logger:error(#{what => janus_wire_enc_inflate_fail, reason => Msg});
                false ->
                    _ = note_provider_failure(Route, sanitize_upstream_error(Msg))
            end
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
            _ = track_proxied(Status, Route, stream_usage(ClientProto)),
            ok
    end.

call_adapter(openai_chat, Route, Body, Map, Opts) ->
    janus_providers_openai:chat_completions(Route, Body, Map, Opts);
call_adapter(openai_responses, Route, Body, Map, Opts) ->
    janus_providers_openai:responses(Route, Body, Map, Opts);
call_adapter(anthropic_messages, Route, Body, Map, Opts) ->
    janus_providers_anthropic:messages(Route, Body, Map, Opts);
call_adapter(openai_decisions, Route, Body, Map, Opts) ->
    janus_providers_openai:decisions(Route, Body, Map, Opts).

%%--------------------------------------------------------------------
%% Decisions upstream attempt loop (D15)
%%
%% Failover ONLY on pre-send failures — gun open/await_up errors,
%% provably before any request byte is written. ANY HTTP status,
%% mid-body error, response-cap breach or 60 s first-byte timeout is
%% terminal: no second upstream. Decisions never enters
%% failover_decide/7 (post-send retries are opted out by not calling
%% it); chat/responses/anthropic failover paths are untouched.
%%--------------------------------------------------------------------

-define(DECISIONS_PRESEND_TRIES, 3).

%% True only for the two provably pre-send error tags (D15 signals).
decisions_presend_failure({error, {open, _}}) -> true;
decisions_presend_failure({error, {await_up, _}}) -> true;
decisions_presend_failure(_) -> false.

decisions_dispatch(Route, Body, Map, Req, State, Attempt) ->
    Result = upstream_call(openai_decisions, Route, Body, Map, #{stream => false}),
    case decisions_presend_failure(Result) andalso Attempt < ?DECISIONS_PRESEND_TRIES of
        true ->
            failover_start(),
            SafeReason =
                case Result of
                    {error, R} -> sanitize_upstream_error(R);
                    _ -> presend
                end,
            %% Note → record row → THEN bump (mirror failover_decide/7).
            %% Bumping before record_failover_row stamped usage attempt=N+1
            %% while the note minted Ref-N (ocr Medium on Task 3 fix).
            _ = note_provider_failure(Route, SafeReason),
            _ = release_route_inflight(Route),
            %% Pre-send failure = transport class (gun open/await_up —
            %% no request byte was ever written); there is no upstream
            %% body to parse, so the native code is null. Stash it too:
            %% a terminal-failure row must surface the LAST retryable
            %% classification (the locked terminal-row read rule), which
            %% on this face is the pre-send transport class.
            stash_classification(transport, null),
            _ = record_failover_row(Route, 502, {transport, null}),
            put(janus_failover_attempt, Attempt + 1),
            janus_lb:bump_stat(requests_retried),
            timer:sleep(retry_jitter()),
            case repick_route(openai_decisions, Map, 3) of
                {ok, Route2} ->
                    decisions_dispatch(Route2, Body, Map, Req, State, Attempt + 1);
                error ->
                    decisions_terminal(Result, Route, Req, State)
            end;
        false ->
            decisions_terminal(Result, Route, Req, State)
    end.

%% Terminal handling: upstream status+body forwarded VERBATIM except
%% sensitive upstream headers are stripped (content-type survives;
%% Retry-After is forwarded on 429); local caps/timeouts answer with
%% the pinned §4.2 codes.
decisions_terminal({ok, Status, Headers, RespBody}, Route, Req, State) when Status =:= 429 ->
    _ = track_proxied(429, Route, #{}),
    _ = note_key_failure(Route, Headers, Status),
    _ = release_route_inflight(Route),
    janus_metrics:inc(decisions_upstream_429_total, #{}),
    mark_client_committed(),
    Req2 = janus_downstream_enc:reply(Status, decisions_filter_headers(Headers), RespBody, Req),
    {ok, Req2, State};
decisions_terminal({ok, Status, Headers, RespBody}, Route, Req, State) when Status =:= 401 ->
    _ = track_proxied(401, Route, #{}),
    _ = note_auth_failure(Route, Status),
    _ = release_route_inflight(Route),
    decisions_reply_verbatim(Status, Headers, RespBody, Req, State);
decisions_terminal({ok, Status, Headers, RespBody}, Route, Req, State) when Status =:= 403 ->
    _ = track_proxied(403, Route, #{}),
    _ = note_route_failure(Route, retry_reason(Headers, Status)),
    _ = release_route_inflight(Route),
    decisions_reply_verbatim(Status, Headers, RespBody, Req, State);
decisions_terminal({ok, Status, Headers, RespBody}, Route, Req, State) when Status >= 500 ->
    _ = track_proxied(Status, Route, #{}),
    _ = note_provider_failure(Route, retry_reason(Headers, Status)),
    _ = release_route_inflight(Route),
    decisions_reply_verbatim(Status, Headers, RespBody, Req, State);
decisions_terminal({ok, Status, Headers, RespBody}, Route, Req, State) when Status >= 400 ->
    _ = track_proxied(Status, Route, #{}),
    _ = release_route_inflight(Route),
    decisions_reply_verbatim(Status, Headers, RespBody, Req, State);
decisions_terminal({ok, Status, Headers, RespBody}, Route, Req, State) ->
    %% Success: body verbatim (no translate, D4). Usage tokens are
    %% null-safe until O1 is pinned from the D13 live fixture: a
    %% body usage object maps known token fields, absence records
    %% null prompt/completion (janus_usage_missing is dashboard-side).
    _ = note_key_success(Route),
    _ = note_route_success(Route),
    _ = track_proxied(
        Status,
        Route,
        usage_or_undef(janus_usage_parse:from_response_body(openai_decisions, RespBody))
    ),
    %% Decisions is a UNARY-only JSON face — the JSON-defaulting
    %% filter applies.
    mark_client_committed(),
    Req2 = janus_downstream_enc:reply(Status, filter_headers_json(Headers), RespBody, Req),
    {ok, Req2, State};
decisions_terminal({error, crashed}, Route, Req, State) ->
    _ = track_proxied(500, Route, #{}),
    _ = release_route_inflight(Route),
    reply_err(openai_decisions, Req, State, 500, <<"internal_error">>, <<"upstream call crashed">>);
decisions_terminal({error, response_too_large}, Route, Req, State) ->
    _ = track_proxied(502, Route, #{}),
    _ = release_route_inflight(Route),
    {Code, Msg} = decisions_local_error(response_too_large),
    reply_err(openai_decisions, Req, State, 502, Code, Msg);
decisions_terminal({error, Reason}, Route, Req, State) ->
    Status = error_http_status(Reason),
    _ = track_proxied(Status, Route, #{}),
    case is_transient(Reason) of
        true ->
            _ = note_provider_failure(Route, sanitize_upstream_error(Reason));
        false ->
            ok
    end,
    _ = release_route_inflight(Route),
    logger:warning(#{
        what => janus_proxy_upstream_error,
        reason => sanitize_upstream_error(Reason),
        provider => route_provider_name(Route),
        model => route_model_name(Route)
    }),
    decisions_error_reply(Status, Req, State).

%% Pinned local error codes (§4.2 table). Pure mapping — exported for
%% eunit so the code+message pairs stay verbatim.
decisions_local_error(upstream_timeout) ->
    {<<"upstream_timeout">>, <<"upstream decisions response timed out">>};
decisions_local_error(response_too_large) ->
    {<<"upstream_response_too_large">>, <<"upstream decisions response exceeds size limit">>};
decisions_local_error(_) ->
    {<<"upstream_error">>, <<"upstream request failed">>}.

decisions_error_reply(504, Req, State) ->
    {Code, Msg} = decisions_local_error(upstream_timeout),
    reply_err(openai_decisions, Req, State, 504, Code, Msg);
decisions_error_reply(Status, Req, State) ->
    {Code, Msg} = decisions_local_error(other),
    reply_err(openai_decisions, Req, State, Status, Code, Msg).

decisions_reply_verbatim(Status, Headers, RespBody, Req, State) ->
    %% Decisions is a UNARY-only JSON face (no stream flag) — the
    %% downstream gzip seam + JSON-defaulting filter apply to every
    %% verbatim reply.
    mark_client_committed(),
    Req2 = janus_downstream_enc:reply(Status, filter_headers_json(Headers), RespBody, Req),
    {ok, Req2, State}.

%% Non-2xx passthrough keeps only content-type (sensitive upstream
%% headers stripped); a 429 additionally forwards Retry-After (§4.2).
decisions_filter_headers(Headers) when is_map(Headers) ->
    Base = filter_headers_json(Headers),
    case maps:get(<<"retry-after">>, Headers, undefined) of
        Ra when is_binary(Ra), Ra =/= <<>> ->
            Base#{<<"retry-after">> => Ra};
        _ ->
            Base
    end;
decisions_filter_headers(Headers) ->
    filter_headers_json(Headers).

%%--------------------------------------------------------------------
%% Upstream result handling
%%--------------------------------------------------------------------

native_stream_fail(ClientProto, Route, Req2, State, Reason) ->
    %% Mid-stream failure: record 502, not the already-sent 200.
    %% Client disconnect uses 499 + cancelled (W2.4).
    {TrackStatus, OutcomeKind} =
        case Reason of
            closed -> {499, cancelled};
            _ -> {502, error}
        end,
    note_usage_outcome(OutcomeKind),
    _ = track_proxied(TrackStatus, Route, stream_usage(ClientProto)),
    SafeReason = sanitize_upstream_error(Reason),
    case Reason of
        closed -> ok;
        R1 when ?IS_WIRE_ENC_ABORT(R1) ->
            %% Internal-hop inflate failure (spec 2026-10-12-wire-
            %% compression F2): the committed leg rides this function
            %% VERBATIM (truncation + stream_body fin + 502 accounting —
            %% clients need zero new handling), but provider benching is
            %% SKIPPED: the corrupt bytes are on OUR wire, not the
            %% provider's (the receive loop already logged job_ref/seq
            %% and cancelled the worker).
            logger:error(#{what => janus_wire_enc_inflate_fail, reason => SafeReason});
        _ -> _ = note_provider_failure(Route, SafeReason)
    end,
    _ = release_route_inflight(Route),
    logger:warning(#{
        what => janus_proxy_stream_error,
        reason => SafeReason,
        client_proto => ClientProto
    }),
    %% Tell the client WHY the stream ended. Until now this path closed
    %% with a bare newline, so a mid-stream failure looked like a
    %% truncation with no cause — the stream simply stopped. An SSE
    %% comment frame is the safe carrier: it is ignored by any SSE
    %% parser, so it cannot corrupt a partially-delivered event, yet it
    %% survives into the client's raw bytes where it explains the close.
    %% (The translate path already emits a proper error event through
    %% finalize_sse/3; this is the native/verbatim path.)
    catch cowboy_req:stream_body(sse_failure_notice(Reason), nofin, Req2),
    catch cowboy_req:stream_body(<<"\n">>, fin, Req2),
    {ok, Req2, State}.

%% Human-readable, single-line, SSE-safe reason for a mid-stream close.
sse_failure_notice(closed) ->
    <<>>;
sse_failure_notice(Reason) ->
    Text = stream_failure_text(Reason),
    iolist_to_binary([<<": janus stream failed - ">>, Text, <<"\n\n">>]).

stream_failure_text({body, timeout}) -> ?UPSTREAM_STALLED_MSG;
stream_failure_text({await, timeout}) -> ?STREAM_TIMEOUT_MSG;
stream_failure_text({await, no_progress}) -> ?UPSTREAM_STALLED_MSG;
stream_failure_text(closed) -> <<"client disconnected">>;
stream_failure_text(_) -> <<"upstream error">>.

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
    mark_client_committed(),
    Req2 = cowboy_req:stream_reply(
        Status,
        filter_stream_headers(Headers),
        Req
    ),
    %% A keepalive comment may only be appended at an SSE LINE BOUNDARY.
    %% This path forwards upstream bytes verbatim, so a chunk can end
    %% mid-line; injecting ": keepalive" there would be parsed as data
    %% and corrupt the event (e.g. a truncated `data: {"choices":...`
    %% would swallow the comment). The translate path needs no such
    %% guard — its ChunkFun feeds an SSE parser that buffers leftovers.
    _ = erase(janus_sse_line_open),
    _ = erase(janus_sse_prev_byte),
    try
        Drain(
            fun(Chunk) ->
                capture_usage_chunk(Chunk),
                ok = note_sse_line_state(Chunk),
                stream_client_frame(Chunk, nofin, Req2)
            end,
            fun(Frame) ->
                case get(janus_sse_at_boundary) of
                    true ->
                        stream_client_frame(Frame, nofin, Req2);
                    _ ->
                        %% Mid-event: a keepalive's blank line would
                        %% dispatch the event early. Skip this tick.
                        ok
                end
            end
        )
    of
        ok ->
            %% Record BEFORE the final frame so a dying client can
            %% never cost us the usage row.
            _ = note_key_success(Route),
            _ = note_route_success(Route),
            _ = track_proxied(Status, Route, stream_usage(ClientProto)),
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
    _ = track_proxied(401, Route, #{}),
    _ = note_auth_failure(Route, Status),
    _ = release_route_inflight(Route),
    reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, Translate, Req, State);
handle_upstream(ClientProto, ProviderProto, {ok, Status, Headers, RespBody}, Route, Translate, Req, State) when
    Status =:= 403
->
    _ = track_proxied(403, Route, #{}),
    _ = note_route_failure(Route, retry_reason(Headers, Status)),
    _ = release_route_inflight(Route),
    reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, Translate, Req, State);
handle_upstream(ClientProto, ProviderProto, {ok, Status, Headers, RespBody}, Route, Translate, Req, State) when
    Status =:= 429
->
    _ = track_proxied(429, Route, #{}),
    _ = note_key_failure(Route, Headers, Status),
    _ = release_route_inflight(Route),
    reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, Translate, Req, State);
handle_upstream(ClientProto, ProviderProto, {ok, Status, Headers, RespBody}, Route, Translate, Req, State) when
    Status >= 500
->
    _ = track_proxied(Status, Route, #{}),
    _ = note_provider_failure(Route, retry_reason(Headers, Status)),
    _ = release_route_inflight(Route),
    reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, Translate, Req, State);
handle_upstream(ClientProto, ProviderProto, {ok, Status, Headers, RespBody}, Route, Translate, Req, State) when
    Status >= 400
->
    _ = track_proxied(Status, Route, #{}),
    _ = release_route_inflight(Route),
    reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, Translate, Req, State);
handle_upstream(ClientProto, ProviderProto, {ok, Status, Headers, RespBody}, Route, Translate, Req, State) ->
    _ = note_key_success(Route),
    _ = note_route_success(Route),
    _ = track_proxied(
        Status,
        Route,
        usage_or_undef(janus_usage_parse:from_response_body(ProviderProto, RespBody))
    ),
    reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, Translate, Req, State);
handle_upstream(ClientProto, _ProviderProto, {error, crashed}, Route, _Translate, Req, State) ->
    note_usage_outcome(error),
    _ = track_proxied(500, Route, #{}),
    _ = release_route_inflight(Route),
    reply_err(ClientProto, Req, State, 500, <<"internal_error">>, <<"upstream call crashed">>);
handle_upstream(ClientProto, _ProviderProto, {error, worker_lost}, Route, _Translate, Req, State) ->
    %% In-flight worker death (N9): abort, no retry. Counts as a rate
    %% failure on the master (spec §4.1) without cooling the provider.
    note_usage_outcome(error),
    _ = track_proxied(502, Route, #{}),
    _ = note_attempt_outcome(Route, provider, worker_lost, worker_lost),
    _ = release_route_inflight(Route),
    logger:warning(#{
        what => janus_proxy_worker_lost,
        provider => route_provider_name(Route),
        model => route_model_name(Route)
    }),
    reply_err(ClientProto, Req, State, 502, <<"worker_lost">>, <<"upstream worker lost">>);
handle_upstream(
    ClientProto, _ProviderProto, {error, {wire_enc_inflate_fail, _} = Reason}, Route, _Translate, Req, State
) ->
    %% Internal-hop inflate failure (spec 2026-10-12-wire-compression
    %% F2): the uncommitted leg mirrors the worker_lost clause
    %% BYTE-FOR-BYTE — same static 502 body, no reason interpolation,
    %% usage outcome error, NO provider benching (internal wire, not a
    %% provider fault; the worker_lost clause benches nothing either —
    %% the is_transient gate below never fired for it). The receive
    %% loop already logged job_ref/seq, cancelled the worker session,
    %% and stashed the distinguishing `wire_enc_inflate_fail` usage
    %% outcome (first-write-wins — note_usage_outcome stays inert).
    note_usage_outcome(error),
    _ = track_proxied(502, Route, #{}),
    _ = release_route_inflight(Route),
    logger:error(#{
        what => janus_wire_enc_inflate_fail,
        reason => sanitize_upstream_error(Reason),
        provider => route_provider_name(Route),
        model => route_model_name(Route)
    }),
    reply_err(ClientProto, Req, State, 502, <<"worker_lost">>, <<"upstream worker lost">>);
handle_upstream(ClientProto, _ProviderProto, {error, Reason}, Route, _Translate, Req, State) ->
    Status = error_http_status(Reason),
    note_usage_outcome(error),
    _ = track_proxied(Status, Route, #{}),
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
        case {Status, Reason} of
            {504, _} -> {<<"upstream_timeout">>, <<"upstream first-byte timeout">>};
            {503, _} -> {<<"upstream_error">>, <<"upstream request failed">>};
            {_, {worker_error, _}} -> {<<"worker_upstream_error">>, <<"upstream worker error">>};
            _ -> {<<"upstream_error">>, upstream_detail_msg()}
        end,
    reply_err(ClientProto, Req, State, Status, Code, Msg).

%% Error fidelity (2026-10-27): failover exhaustion used to collapse
%% every upstream rejection into "upstream request failed", hiding the
%% actionable reason ("...maximum context length is 131072..."). The
%% LAST upstream 4xx/5xx message rides the client error instead.
stash_upstream_error_detail({ok, Status, _Headers, Body}) when
    Status >= 400, is_binary(Body), byte_size(Body) > 0
->
    _ = logger:warning(#{
        what => janus_upstream_error_detail,
        status => Status,
        body => binary:part(Body, 0, min(byte_size(Body), 600))
    }),
    UpMsg = upstream_err_msg(Body),
    put(janus_last_upstream_error, {Status, UpMsg}),
    %% Terminal usage-row detail: stash AT ARRIVAL — reply_err's own
    %% stash runs after track on the dispatch reject paths, too late
    %% for the row. Same binary, independent keep-alive key (erased
    %% in the preamble).
    case UpMsg of
        <<>> -> ok;
        _ -> put(janus_error_detail, UpMsg)
    end;
stash_upstream_error_detail(_) ->
    ok.

upstream_err_msg(Body) ->
    Msg =
        try
            case thoas:decode(Body) of
                {ok, Decoded} when is_map(Decoded) ->
                    extract_error_message(Decoded);
                _ ->
                    <<>>
            end
        catch
            _:_ -> <<>>
        end,
    case Msg of
        <<"upstream request failed">> -> <<>>;
        M -> binary:part(M, 0, min(byte_size(M), 400))
    end.

upstream_detail_msg() ->
    case get(janus_last_upstream_error) of
        {UStatus, M} when byte_size(M) > 0 ->
            iolist_to_binary([
                <<"upstream (HTTP ">>, integer_to_binary(UStatus), <<"): ">>, M
            ]);
        _ ->
            <<"upstream request failed">>
    end.

%% Wire-compression abort reason guard (spec 2026-10-12-wire-compression
%% F2): matches BOTH sanitize_upstream_error shapes of the internal-hop
%% inflate-fail reason ({Tag, Sub} when the sub-reason sanitizes to an
%% atom/int pair, and the bare Tag otherwise).
wire_enc_abort_reason(R) -> ?IS_WIRE_ENC_ABORT(R).

%% finalize_sse/3's JSON encoder needs a binary message, but a drain
%% error reaches it as sanitize_upstream_error/1 output, which can be a
%% 2-tuple ({Tag, Sub} / {Tag, N}). Normalise for the WIRE only:
%% finish_translate_stream/5 still matches its accounting branches on
%% the original shape (wire_enc_abort_reason/1 needs the tuple).
wire_reason({error, Kind, Msg}) when is_binary(Msg) -> {error, Kind, Msg};
wire_reason({error, Kind, Msg}) -> {error, Kind, wire_msg(Msg)};
wire_reason(Other) -> Other.

%% The provider's in-band error text when the stream fold captured one,
%% else the generic construct message. The upstream's own words are what
%% makes a mid-stream failure actionable.
upstream_stream_error_msg() ->
    case janus_protocol_translate:take_upstream_stream_error() of
        undefined ->
            <<"upstream sent an unsupported stream construct">>;
        Text ->
            %% Provider-controlled text entering a client-visible frame.
            %% Bound it the way the sibling relay paths do
            %% (upstream_err_msg/1 caps at 400, the error detail at 600);
            %% without this a misbehaving upstream could push its whole
            %% 1 MiB SSE frame into the terminal error event.
            trunc_utf8(Text, 400)
    end.

%% Byte-capped, codepoint-safe (the message is JSON-encoded downstream,
%% and a split multi-byte sequence would produce invalid UTF-8).
trunc_utf8(B, Max) when is_binary(B), byte_size(B) > Max ->
    trim_partial_utf8(binary:part(B, 0, Max));
trunc_utf8(B, _Max) ->
    B.

trim_partial_utf8(B) -> trim_partial_utf8(B, byte_size(B) - 1, 0).

trim_partial_utf8(B, I, _Extra) when I < 0; _Extra >= 3 ->
    B;
trim_partial_utf8(B, I, Extra) ->
    case binary:at(B, I) of
        C when C < 128 -> B;
        C when C >= 192 ->
            Need =
                if
                    C < 224 -> 2;
                    C < 240 -> 3;
                    true -> 4
                end,
            case Need =< Extra + 1 of
                true -> B;
                false -> binary:part(B, 0, I)
            end;
        _ ->
            trim_partial_utf8(B, I - 1, Extra + 1)
    end.

%% Upstream silence in the middle of a stream (janus_worker_wire:
%% stream_inactivity_timeout_ms/0). The worker client reports it as
%% {await, no_progress}; sanitize_upstream_error/1 would keep it a
%% tuple and the client would read an Erlang term. Name it in words a
%% human can act on — this is the gateway saying "the upstream stalled",
%% which is precisely what the generic 502 used to hide.

%% NOTE: this fills the Msg slot of {error, upstream, Msg}, so it must
%% yield a BINARY. Returning {stalled, Binary} here would fall through
%% wire_reason/1's non-binary clause, which renders with ~w — the client
%% would read an Erlang term again, the exact leak this removes.
sanitize_stream_reason({await, no_progress}) -> ?UPSTREAM_STALLED_MSG;
%% The sibling budget: without this clause the tuple falls through to
%% wire_reason's ~w rendering and the client reads an Erlang term.
sanitize_stream_reason({await, timeout}) -> ?STREAM_TIMEOUT_MSG;
sanitize_stream_reason(Other) -> sanitize_upstream_error(Other).

wire_msg(Msg) when is_atom(Msg) -> atom_to_binary(Msg, utf8);
wire_msg(Msg) -> unicode:characters_to_binary(io_lib:format("~w", [Msg])).

%% TTFB (gun await of the response headers) is 504; a disabled provider
%% is 503; everything else that never produced headers is 502.
error_http_status(provider_disabled) -> 503;
error_http_status(worker_lost) -> 502;
error_http_status({worker_error, timeout}) -> 504;
error_http_status({worker_error, _}) -> 502;
error_http_status({worker_http_status, _}) -> 502;
error_http_status({worker_http_status, _, _, _}) -> 502;
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
            %% Reached PRECISELY because thoas:decode did not yield a
            %% map: the body is not known to be JSON, so it gets the
            %% UN-defaulted filter (an existing content-type passes
            %% through, a missing one stays missing — never labelled
            %% application/json; ocr r3).
            mark_client_committed(),
            Req2 = janus_downstream_enc:reply(Status, filter_headers(Headers), RespBody, Req),
            {ok, Req2, State}
    end;
reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, true, Req, State) ->
    %% Error body: reshape to client dialect when possible. The chat
    %% faces' error envelopes are JSON by contract (cross-proto
    %% reshapes re-encode; same-proto verbatim bodies are provider
    %% JSON), so this is a JSON-contract path: the JSON-defaulting
    %% filter applies (worker done trailers arrive here too).
    Body2 = reshape_error(ClientProto, ProviderProto, RespBody),
    mark_client_committed(),
    Req2 = janus_downstream_enc:reply(Status, filter_headers_json(Headers), Body2, Req),
    {ok, Req2, State};
reply_upstream_body(_ClientProto, _ProviderProto, Status, Headers, RespBody, false, Req, State) ->
    %% Non-stream upstream body on a NATIVE same-protocol face — the
    %% chat/responses/messages protocols speak JSON by contract, so
    %% the JSON-defaulting filter applies (the worker-dispatch unary
    %% done carries `trailers => #{}` — without the default that
    %% execution path's reply would carry no content-type while the
    %% local-fallback path carries the provider's; spec F6 wants the
    %% downstream gzip seam to see the same application/json on both
    %% paths). The stream flag was decided long before this point, so
    %% the seam applies.
    mark_client_committed(),
    Req2 = janus_downstream_enc:reply(Status, filter_headers_json(Headers), RespBody, Req),
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
%% Top-level spellings (dashscope and friends: {"code": ..., "message": ...}).
extract_error_message(#{<<"message">> := M}) when is_binary(M), M =/= <<>> ->
    M;
extract_error_message(#{<<"msg">> := M}) when is_binary(M), M =/= <<>> ->
    M;
extract_error_message(#{<<"detail">> := M}) when is_binary(M), M =/= <<>> ->
    M;
extract_error_message(#{<<"error">> := M}) when is_binary(M), M =/= <<>> ->
    M;
extract_error_message(_) ->
    <<"upstream request failed">>.

collect_drain(Drain) ->
    Acc = ets:new(janus_stream_acc, [private]),
    try
        case
            Drain(
                fun(Chunk) ->
                    ets:insert(Acc, {erlang:unique_integer([monotonic]), Chunk}),
                    ok
                end,
                undefined
            )
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
            %% janus_failover_attempt: monotonic usage attempt (D17).
            %% janus_part_c_attempt: per-name Part C counter (D6; reset
            %% on next-name advance). Both start at 1; stay in sync
            %% unless a next-name advance resets only part_c.
            put(janus_failover_attempt, 1),
            put(janus_part_c_attempt, 1),
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
%%
%% Next-name (design 2026-10-15 D3/D16): when Part C would surface a
%% retryable error (attempts/budget exhausted OR same-model repick
%% empty), intercept BEFORE continue and try the next snapshotted tier
%% name when gates allow. Judge path never reaches here (D14).
failover_decide(ClientProto, Route, Map, Body, Result0, Req, State) ->
    failover_start(),
    Result = remap_worker_http_status(normalize_result(Result0)),
    stash_upstream_error_detail(Result),
    %% Shape sentinel (2026-10-28): shape-class upstream rejects
    %% capture the structural fingerprint of BOTH sides.
    janus_shape_capture:upstream_reject(Body, Map, Result),
    maybe_count_auto_http_attempt(Result),
    case failover_classify(Route, Result) of
        terminal ->
            {continue, Result};
        {retryable, Reason, NativeCode} ->
            {Attempts, Budget} = failover_knobs(),
            PartC = pd(janus_part_c_attempt, pd(janus_failover_attempt, 1)),
            Elapsed = erlang:monotonic_time(millisecond) - pd(janus_failover_started, 0),
            case PartC =< Attempts andalso Elapsed < Budget of
                true ->
                    failover_note(Route, Result),
                    failover_record_attempt(Route, Result, {Reason, NativeCode}),
                    %% Spec Part C: sleep the jitter — retry bursts must
                    %% not hammer a sick upstream back-to-back.
                    timer:sleep(retry_jitter()),
                    janus_lb:bump_stat(requests_retried),
                    bump_usage_and_part_c(),
                    mark_key_attempted(Route),
                    case repick_route(ClientProto, Map, 3) of
                        {ok, Route2} ->
                            {handled, retry_dispatch(ClientProto, Route2, Body, Map, Req, State)};
                        error ->
                            %% Same-model keys exhausted — try next name.
                            maybe_advance_tier_name(
                                ClientProto, Route, Map, Result, {Reason, NativeCode}, Req, State,
                                false
                            )
                    end;
                false ->
                    janus_lb:bump_stat(failovers_exhausted),
                    %% Budget / max_attempts for this name — try next name
                    %% (record the failed attempt only if we actually advance).
                    maybe_advance_tier_name(
                        ClientProto, Route, Map, Result, {Reason, NativeCode}, Req, State,
                        true
                    )
            end
    end.

%% D17: usage attempt is monotonic across names; Part C counter tracks
%% per-name key retries.
bump_usage_and_part_c() ->
    put(janus_failover_attempt, pd(janus_failover_attempt, 1) + 1),
    put(janus_part_c_attempt, pd(janus_part_c_attempt, 1) + 1),
    ok.

%% Count real upstream HTTP statuses for D15 (transport errors do not).
maybe_count_auto_http_attempt({ok, Status, _H, _B}) when is_integer(Status) ->
    case get(janus_auto_tier_failover) of
        true -> put(janus_auto_http_attempts, pd(janus_auto_http_attempts, 0) + 1);
        _ -> ok
    end;
maybe_count_auto_http_attempt({ok, stream, Status, _H, _D}) when is_integer(Status) ->
    case get(janus_auto_tier_failover) of
        true -> put(janus_auto_http_attempts, pd(janus_auto_http_attempts, 0) + 1);
        _ -> ok
    end;
maybe_count_auto_http_attempt(_) ->
    ok.

%% D4: pre-forward worker HTTP errors arrive as a 4-tuple carrying the
%% upstream Headers/Body. Remap to the local {ok,Status,H,B} shape
%% BEFORE classify so deny/rate/balance body rules apply unchanged.
%% The 2-tuple form means post-forward (or bodyless) and stays N9.
%% Remapped non-2xx must NOT take the success commit path — classify
%% + failover_note see the status, never treat it as 2xx.
remap_worker_http_status({error, {worker_http_status, Status, Headers, Body}}) when
    is_integer(Status), is_map(Headers), is_binary(Body)
->
    {ok, Status, Headers, Body};
remap_worker_http_status(R) ->
    R.

%%--------------------------------------------------------------------
%% Same-tier next-name failover (design 2026-10-15 D3/D5/D6/D7/D15/D16)
%%--------------------------------------------------------------------

%% RecordNeeded=true: Part C budget/attempts exhausted without having
%% written a non-terminal usage row yet — note+record only if we advance.
%% RecordNeeded=false: already noted/recorded/bumped before a failed repick.
maybe_advance_tier_name(ClientProto, Route, Map, Result, Classified, Req, State, RecordNeeded) ->
    case next_name_gates_ok(Result) of
        false ->
            logger:info(#{
                what => janus_auto_walk_gate_closed,
                tier => get(janus_auto_tier),
                enabled => get(janus_auto_tier_failover),
                committed => client_committed(),
                names => get(janus_auto_tier_names),
                attempted => pd(janus_auto_names_attempted, [])
            }),
            {continue, Result};
        true ->
            case next_eligible_carry(ClientProto, Map) of
                {ok, Next, Route2} ->
                    logger:info(#{
                        what => janus_auto_walk_advance,
                        from => get(janus_req_model),
                        to => Next
                    }),
                    case RecordNeeded of
                        true ->
                            failover_note(Route, Result),
                            failover_record_attempt(Route, Result, Classified),
                            put(janus_failover_attempt, pd(janus_failover_attempt, 1) + 1);
                        false ->
                            ok
                    end,
                    advance_tier_name(Next, Route2, ClientProto, Map, Req, State);
                {exhausted, Why} ->
                    logger:info(#{
                        what => janus_auto_walk_exhausted,
                        tier => get(janus_auto_tier),
                        why => Why,
                        names => get(janus_auto_tier_names),
                        attempted => pd(janus_auto_names_attempted, [])
                    }),
                    bump_auto_name_exhausted(Why),
                    case Why =:= all_cooling andalso pd(janus_auto_http_attempts, 0) =:= 0 of
                        true ->
                            %% D15.1: zero HTTP attempts → all_cooling/503.
                            {handled, reply_pick_error(ClientProto, Req, State, all_cooling)};
                        false ->
                            %% D15.2: last upstream error (already in Result).
                            {continue, Result}
                    end
            end
    end.

%% Pick-error entry (initial empty pick before any upstream HTTP):
%% all_cooling, provider_disabled, keys_disabled and
%% missing_provider_key all mean "this tier member cannot serve", so
%% the walk may probe the next name (D7's empty-pick class). When the
%% walk exhausts, the caller replies with the ORIGINAL reason — the
%% client-visible status stays honest.
maybe_next_name_on_pick_error(ClientProto, Reason, _Body, Map, Req, State) ->
    case next_name_gates_ok(pick_error) andalso is_advanceable_pick_error(Reason) of
        false ->
            continue;
        true ->
            case next_eligible_carry(ClientProto, Map) of
                {ok, Next, Route2} ->
                    {handled, advance_tier_name(Next, Route2, ClientProto, Map, Req, State)};
                {exhausted, Why} ->
                    bump_auto_name_exhausted(Why),
                    %% Fall through to the original pick-error reply.
                    continue
            end
    end.

%% Pick errors the next-name walk can skip. catalog_not_ready and a
%% plain no_route stay terminal (the former is a node-wide condition,
%% the latter a 404 with no tier semantics). Other reasons keep their
%% current terminal behaviour.
is_advanceable_pick_error(all_cooling) -> true;
is_advanceable_pick_error({all_cooling, _}) -> true;
is_advanceable_pick_error(provider_disabled) -> true;
is_advanceable_pick_error(keys_disabled) -> true;
is_advanceable_pick_error(missing_provider_key) -> true;
is_advanceable_pick_error(_) -> false.

%% D5's commit marker is the Cowboy WRITE (mark_client_committed on
%% every reply / stream_reply). janus_worker_forwarded is NOT a client
%% commit: it is the worker client's per-dispatch pre-byte predicate
%% for the unary fallback, and the worker client sets it on result
%% emission (janus_error / unary done legs) even when zero bytes ever
%% reached the client. OR-ing it here closed the same-tier walk for
%% every worker-path upstream error — a TTFB timeout 504'd with the
%% walk frozen despite healthy tier siblings (2026-10-21, flag
%% visible in janus_auto_walk_gate_closed: committed=true on a
%% zero-byte timeout).
client_committed() ->
    get(janus_client_committed) =:= true.

%% D5: any Cowboy write commits the request against next-name.
mark_client_committed() ->
    put(janus_client_committed, true),
    ok.

upstream_2xx_result(pick_error) -> false;
upstream_2xx_result({ok, Status, _H, _B}) when is_integer(Status), Status >= 200, Status < 300 ->
    true;
upstream_2xx_result({ok, stream, Status, _H, _D}) when is_integer(Status), Status >= 200, Status < 300 ->
    true;
upstream_2xx_result(_) ->
    false.

within_failover_budget() ->
    {_Attempts, Budget} = failover_knobs(),
    Started = pd(janus_failover_started, undefined),
    case Started of
        undefined ->
            %% No upstream yet (pick-error path) — budget starts at first
            %% attempt; allow the advance probe.
            true;
        S when is_integer(S) ->
            erlang:monotonic_time(millisecond) - S < Budget
    end.

%% Walk strictly rightward from the last attempted index (D2/D7).
%% Skips bump skip_total and do not consume max_names. Successful pick
%% is carried into dispatch (no second pick).
next_eligible_carry(ClientProto, Map) ->
    Names = pd(janus_auto_tier_names, []),
    Attempted = pd(janus_auto_names_attempted, []),
    case Attempted of
        [] ->
            {exhausted, no_eligible};
        _ ->
            Last = lists:last(Attempted),
            case index_of_name(Last, Names) of
                error ->
                    {exhausted, no_eligible};
                Idx ->
                    Len = length(Names),
                    walk_eligible(Idx + 1, Len, Names, Attempted, ClientProto, Map, no_eligible)
            end
    end.

walk_eligible(I, Len, _Names, _Attempted, _ClientProto, _Map, LastSkip) when I > Len ->
    {exhausted, LastSkip};
walk_eligible(I, Len, Names, Attempted, ClientProto, Map, LastSkip) ->
    Name = lists:nth(I, Names),
    case lists:member(Name, Attempted) of
        true ->
            walk_eligible(I + 1, Len, Names, Attempted, ClientProto, Map, LastSkip);
        false ->
            case probe_next_name(Name, ClientProto, Map) of
                {ok, Route} ->
                    {ok, Name, Route};
                {skip, Reason} ->
                    bump_auto_name_skip(Reason),
                    NextSkip =
                        case Reason of
                            all_cooling -> all_cooling;
                            _ when LastSkip =:= all_cooling -> all_cooling;
                            _ -> no_eligible
                        end,
                    walk_eligible(I + 1, Len, Names, Attempted, ClientProto, Map, NextSkip)
            end
    end.

index_of_name(Name, Names) ->
    index_of_name(Name, Names, 1).

index_of_name(_Name, [], _) -> error;
index_of_name(Name, [Name | _], I) -> I;
index_of_name(Name, [_ | Rest], I) -> index_of_name(Name, Rest, I + 1).

%% D7 skip classes: unavailable / stream-incompatible / modality /
%% protocol_requires_native / stream_pair_untranslatable / all_cooling.
%% try/catch: a catalog/LB hiccup must skip, not crash the proxy (ocr).
probe_next_name(Name, ClientProto, Map) ->
    try
        probe_next_name_unguarded(Name, ClientProto, Map)
    catch
        Class:Reason:Stack ->
            logger:warning(#{
                what => janus_auto_next_name_probe_crashed,
                name => Name,
                class => Class,
                reason => Reason,
                stack => janus_seed:redact_stack(Stack)
            }),
            {skip, unavailable}
    end.

probe_next_name_unguarded(Name, ClientProto, Map) ->
    Constraint = #{
        client_proto => ClientProto,
        stream => stream_translate_blocked_for(ClientProto, Map),
        vision => request_has_image(Map)
    },
    case maps:get(vision, Constraint, false) andalso not janus_catalog:vision_capable(Name) of
        true ->
            {skip, no_vision};
        false ->
            case janus_auto:model_available(Name) of
                false ->
                    {skip, unavailable};
                true ->
                    case janus_auto:stream_compatible(Name, Constraint) of
                        false ->
                            {skip, stream_incompatible};
                        true ->
                            case proto_gate(ClientProto, Name) of
                                {error, protocol_requires_native} ->
                                    {skip, protocol_requires_native};
                                ok ->
                                    case janus_catalog:model_modality(Name) of
                                        <<"chat">> ->
                                            pick_probe_route(Name, ClientProto, Map);
                                        _ ->
                                            {skip, wrong_modality}
                                    end
                            end
                    end
            end
    end.

pick_probe_route(Name, ClientProto, Map) ->
    PickOpts = stream_pick_opts(ClientProto, Map),
    Pick =
        case resolve_model(Name) of
            {ok, ModelId} -> janus_lb:pick_route(ModelId, PickOpts);
            error -> janus_lb:pick_listing_route(Name, PickOpts)
        end,
    case Pick of
        {ok, Route} ->
            case provider_protocol(Route) of
                {ok, RP} ->
                    StreamUnservable =
                        janus_protocol_translate:wants_stream(Map) andalso
                            janus_protocol_translate:stream_pair_untranslatable(ClientProto, RP),
                    case StreamUnservable of
                        true ->
                            _ = release_route_inflight(Route),
                            {skip, stream_pair_untranslatable};
                        false ->
                            {ok, Route}
                    end;
                {error, unknown_protocol} ->
                    _ = release_route_inflight(Route),
                    {skip, unavailable}
            end;
        {error, all_cooling} ->
            {skip, all_cooling};
        {error, {all_cooling, _}} ->
            {skip, all_cooling};
        {error, _} ->
            %% Not a cooling condition (provider_disabled, malformed
            %% route, ...): report the module's generic skip vocabulary
            %% instead of mislabelling it all_cooling and letting
            %% walk_eligible/7 promote it into a bogus 503 (review 02c
            %% M1).
            {skip, unavailable}
    end.

advance_tier_name(Next, Route2, ClientProto, Map, Req, State) ->
    put(janus_req_model, Next),
    Attempted = pd(janus_auto_names_attempted, []),
    put(janus_auto_names_attempted, Attempted ++ [Next]),
    %% D6: clear per-name Part C key set; reset part_c attempt; keep
    %% shared Deadline / monotonic usage attempt / request_ref.
    erase(janus_failover_keys),
    put(janus_part_c_attempt, 1),
    erase(janus_failover_unclassified_retried),
    bump_auto_name_failover(),
    %% Re-encode from the client Map so cross-protocol next-name does
    %% not reuse a prior provider-shaped body.
    Map2 = Map#{<<"model">> => Next},
    Body2 = thoas:encode(Map2),
    %% D9: do not touch poscache on advance — judge pos_write is the
    %% only writer today; leave pre-existing entries untouched.
    retry_dispatch(ClientProto, Route2, Body2, Map2, Req, State).

bump_auto_name_failover() ->
    Tier = auto_tier_label(),
    janus_metrics:inc(auto_tier_name_failover_total, #{tier => Tier}),
    ok.

bump_auto_name_exhausted(Reason) ->
    Tier = auto_tier_label(),
    janus_metrics:inc(auto_tier_name_failover_exhausted_total, #{
        tier => Tier, reason => exhaust_reason(Reason)
    }),
    ok.

bump_auto_name_skip(Reason) ->
    Tier = auto_tier_label(),
    janus_metrics:inc(auto_tier_name_skip_total, #{
        tier => Tier, reason => skip_reason(Reason)
    }),
    ok.

auto_tier_label() ->
    case get(janus_auto_tier) of
        T when is_atom(T) -> T;
        T when is_binary(T) -> T;
        _ -> unknown
    end.

exhaust_reason(all_cooling) -> all_cooling;
exhaust_reason(no_eligible) -> no_eligible;
exhaust_reason(budget) -> budget;
exhaust_reason(max_names) -> max_names;
exhaust_reason(R) when is_atom(R) -> R;
exhaust_reason(_) -> no_eligible.

skip_reason(unavailable) -> unavailable;
skip_reason(stream_incompatible) -> stream_incompatible;
skip_reason(stream_pair_untranslatable) -> stream_pair_untranslatable;
skip_reason(wrong_modality) -> wrong_modality;
skip_reason(protocol_requires_native) -> protocol_requires_native;
skip_reason(all_cooling) -> all_cooling;
skip_reason(no_vision) -> no_vision;
skip_reason(R) when is_atom(R) -> R;
skip_reason(_) -> unavailable.

%% Distinguish budget vs max_names exhaustion when gates fail mid-walk.
%% (Caller already bumped no_eligible/all_cooling from next_eligible.)
next_name_gates_ok(Result) ->
    Enabled = get(janus_auto_tier_failover) =:= true,
    case Enabled of
        false ->
            false;
        true ->
            case
                not client_committed() andalso
                    not upstream_2xx_result(Result) andalso
                    is_list(get(janus_auto_tier_names))
            of
                false ->
                    false;
                true ->
                    AttemptedN = length(pd(janus_auto_names_attempted, [])),
                    MaxN = pd(janus_auto_tier_max_names, 3),
                    case AttemptedN < MaxN of
                        false ->
                            bump_auto_name_exhausted(max_names),
                            false;
                        true ->
                            case within_failover_budget() of
                                true ->
                                    true;
                                false ->
                                    bump_auto_name_exhausted(budget),
                                    false
                            end
                    end
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
    %% Spend attempts on candidate routes (ocr review 2026-10-07):
    %% the same same-protocol bias the initial pick applies, else the
    %% round-robin cursor can burn the retry budget on routes the
    %% ProtoOK filter below would discard anyway.
    PickOpts = stream_pick_opts(ClientProto, Map),
    Pick =
        case resolve_model(ModelName) of
            {ok, ModelId} -> janus_lb:pick_route(ModelId, PickOpts);
            error -> janus_lb:pick_listing_route(ModelName, PickOpts)
        end,
    case Pick of
        {ok, Route} ->
            RouteProto = provider_protocol(Route),
            %% Never fail over INTO a responses-protocol provider on a
            %% stream it cannot serve (audit R2, C-1): that turns a
            %% recoverable failure into the dispatch guard's terminal 400.
            StreamUnservable =
                janus_protocol_translate:wants_stream(Map) andalso
                    case RouteProto of
                        {ok, RP} ->
                            janus_protocol_translate:stream_pair_untranslatable(ClientProto, RP);
                        _ ->
                            false
                    end,
            ProtoOK =
                ((not Blocked) orelse (RouteProto =:= {ok, ClientProto})) andalso
                    (not StreamUnservable),
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
failover_note(Route, {error, Reason}) ->
    %% Transport-class failure: bench the provider like a mid-loop 5xx,
    %% else every subsequent request keeps re-opening connections to a
    %% sick endpoint until a TERMINAL outcome finally cools it.
    _ = note_provider_failure(Route, sanitize_upstream_error(Reason)),
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
%% TF-A.0b (reorder spec D8/terminal_count): this IS the per-attempt
%% cascade row — every attempted listing in the failover cascade gets
%% exactly one row (retried attempts here with tokens null + latency 0;
%% the final attempt's terminal row via track_proxied, mid-stream
%% aborts at 5xx-class statuses through native_stream_fail /
%% handle_upstream's worker_lost 502). Routes here always carry an
%% integer provider_id (a pick produced them) — the writer-side pin
%% holds.
%% {Reason, NativeCode} comes straight from failover_classify/2 (the
%% single derivation — observability-depth Task 2); error_code now
%% carries the parsed provider-native code (previously the parsed
%% binary was discarded and the column was never populated).
failover_record_attempt(Route, {ok, Status, _H, _B}, Classified) ->
    record_failover_row(Route, Status, Classified);
failover_record_attempt(Route, {error, crashed}, Classified) ->
    record_failover_row(Route, 500, Classified);
failover_record_attempt(Route, {error, _Reason}, Classified) ->
    record_failover_row(Route, 502, Classified).

record_failover_row(Route, Status, {Reason, NativeCode}) ->
    case get(janus_usage_ctx) of
        #{started := _Started, agent := Agent, client_proto := Proto, stream := Stream} ->
            janus_usage:record(#{
                ts => erlang:system_time(second),
                requested_model => pd(janus_requested_model, null),
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
                error_code => NativeCode,
                attempt => pd(janus_failover_attempt, 1),
                request_ref => pd(janus_failover_ref, null),
                is_terminal => false,
                request_id => get(janus_request_id),
                failover_reason => atom_to_binary(Reason, utf8),
                %% Per-attempt attribution (2026-10-28): the arrival
                %% stash belongs to THIS attempt's upstream answer —
                %% without it the walk's terminal row kept attempt 1's
                %% message (live: dashscope's text on a minimax row).
                error_detail =>
                    case get(janus_error_detail) of
                        D when is_binary(D) -> D;
                        _ -> null
                    end,
                trace_id => janus_trace:trace_id(get(janus_trace))
            }),
            %% The next attempt (Part C retry or auto-walk) re-stashes
            %% its OWN message on arrival; clear so a walk path that
            %% never stashes cannot inherit this attempt's text.
            erase(janus_error_detail),
            ok;
        _ ->
            ok
    end.

%%% Retry-time classification (codes table single-source, spec C.1)
%%%
%%% Observability-depth Task 2: the classifier is the SINGLE derivation
%%% the write path consumes — each retryable call returns
%%% {retryable, Reason, NativeCode} AND stashes both values
%%% (janus_last_reason / janus_last_native_code), so the terminal row
%%% surfaces the LAST retryable classification. Terminal branches stash
%%% NOTHING: a terminal failure must surface the previous retryable
%%% classification (a terminal-first request records NULL/NULL). Status
%%% classes are checked BEFORE body classification (401/403 -> auth even
%%% when the body matches an entitlement code). Total — never raises: an
%%% unexpected shape returns {retryable, unclassified, null}.

-type failover_reason() ::
    auth | rate | balance | deny | input_shape | unclassified | upstream_5xx | transport.

-spec failover_classify(map(), term()) ->
    terminal | {retryable, failover_reason(), binary() | null}.
%% Worker mesh failures are terminal (N9: no in-flight retry / no
%% key-failover on worker_lost, worker-emitted transport errors, or
%% post-forward worker_http_status) and stash nothing. D4 amends N9
%% ONLY for the remapped pre-forward retryable set: the 4-tuple
%% `{worker_http_status,Status,H,B}` is rewritten to `{ok,Status,H,B}`
%% in remap_worker_http_status/1 before this classifier runs, so
%% 401/403/429/5xx/deny enter the same clauses as the local path.
%% Raw 2-tuple worker_http_status (post-forward / non-remapped) and
%% an unremapped 4-tuple (fail-closed) stay terminal here. The
%% janus_error wire map carries only code+message — the upstream body
%% does NOT survive that path — so a worker-executed terminal failure
%% can only surface a PREVIOUS attempt's retryable classification; a
%% first-attempt worker_* terminal records failover_reason NULL +
%% error_code NULL. (Unary / pre-forward stream errors return the body
%% in janus_done and classify with the native code intact after remap.)
failover_classify(_Route, {error, worker_lost}) ->
    terminal;
%% Internal-hop inflate failure (spec 2026-10-12-wire-compression F2):
%% terminal for the same N9 reason — a retry would re-dispatch a NEW
%% job while the client already owns any committed bytes, and the
%% fault is OUR wire, not a candidate key/provider.
failover_classify(_Route, {error, Reason}) when ?IS_WIRE_ENC_ABORT(Reason) ->
    terminal;
failover_classify(_Route, {error, {worker_error, _}}) ->
    terminal;
%% Post-forward (2-tuple) or remap-miss 4-tuple: N9 terminal.
failover_classify(_Route, {error, {worker_http_status, _}}) ->
    terminal;
failover_classify(_Route, {error, {worker_http_status, _, _, _}}) ->
    terminal;
failover_classify(_Route, {error, _Reason}) ->
    %% Transport errors behave like 5xx: retryable within the budget.
    stash_classification(transport, null),
    {retryable, transport, null};
failover_classify(_Route, {ok, Status, _H, Body}) when
    Status =:= 401; Status =:= 403
->
    NativeCode = native_code_of(Body),
    stash_classification(auth, NativeCode),
    {retryable, auth, NativeCode};
failover_classify(_Route, {ok, Status, _H, Body}) when Status >= 500 ->
    NativeCode = native_code_of(Body),
    stash_classification(upstream_5xx, NativeCode),
    {retryable, upstream_5xx, NativeCode};
failover_classify(Route, {ok, Status, _H, Body}) when Status >= 400, Status < 500 ->
    {Code, Message} = extract_error_code_message(Body),
    NativeCode = code_or_null(Code),
    case classify_client_error(Route, Code, Message) of
        deny ->
            stash_classification(deny, NativeCode),
            {retryable, deny, NativeCode};
        balance ->
            stash_classification(balance, NativeCode),
            {retryable, balance, NativeCode};
        rate ->
            stash_classification(rate, NativeCode),
            {retryable, rate, NativeCode};
        input_shape ->
            %% Known input-shape mismatch: TERMINAL, zero retries (the
            %% same request shape fails identically on every key —
            %% entitlement spec). Stash untouched.
            terminal;
        unclassified ->
            %% A 429 is rate-shaped even when the codes table has no
            %% matching row. Any other unclassified 4xx gets ONE
            %% failover attempt, then terminal (codes-table feedback for
            %% the next seed update). Fully fail-open when the table is
            %% empty.
            case Status of
                429 ->
                    stash_classification(rate, NativeCode),
                    {retryable, rate, NativeCode};
                _ ->
                    case get(janus_failover_unclassified_retried) of
                        true ->
                            terminal;
                        _ ->
                            put(janus_failover_unclassified_retried, true),
                            stash_classification(unclassified, NativeCode),
                            {retryable, unclassified, NativeCode}
                    end
            end
    end;
%% Success (2xx/3xx) and committed streams are terminal — never a
%% reason, never a stash write.
failover_classify(_Route, {ok, _Status, _H, _B}) ->
    terminal;
failover_classify(_Route, {ok, stream, _Status, _H, _Drain}) ->
    terminal;
failover_classify(_Route, _Unexpected) ->
    %% Totality guard: the classifier runs inside the failover loop and
    %% must never raise on an unexpected shape.
    stash_classification(unclassified, null),
    {retryable, unclassified, null}.

stash_classification(Reason, NativeCode) ->
    put(janus_last_reason, Reason),
    put(janus_last_native_code, NativeCode),
    ok.

native_code_of(Body) ->
    {Code, _Message} = extract_error_code_message(Body),
    code_or_null(Code).

code_or_null(Code) when is_binary(Code) -> Code;
code_or_null(_) -> null.

classify_client_error(Route, Code, Message) ->
    Codes = janus_catalog:entitlement_codes(),
    Provider = route_provider_name(Route),
    Rows = maps:get(Provider, Codes, []),
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
    %% writes the usage row (null route ids) and bumps failed. The
    %% status must be the class of the reply the client actually gets:
    %% a bare all_cooling answers 503 and used to be tracked as 404
    %% (review 06d M5), hiding D15.1 exhaustion from 5xx alerting.
    _ = track(pick_error_status(Reason), #{}, #{}),
    do_reply_pick_error(ClientProto, Req, State, Reason).

pick_error_status(all_cooling) -> 503;
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
%% Malformed cooldown: still a cooling condition, never a 404 — keep
%% the reply class identical to pick_error_status/1.
do_reply_pick_error(ClientProto, Req, State, {all_cooling, _}) ->
    do_reply_pick_error(ClientProto, Req, State, {all_cooling, 5000});
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
%% Decisions face (D2): empty pick after require_proto means the model
%% has no openai_decisions listing — report that explicitly so operators
%% do not chase a generic "no route" on a chat-only name.
do_reply_pick_error(openai_decisions, Req, State, _Reason) ->
    reply_err(
        openai_decisions,
        Req,
        State,
        404,
        <<"no_route">>,
        <<"no decisions-capable route for model (provider protocol must be openai_decisions)">>
    );
do_reply_pick_error(ClientProto, Req, State, _Reason) ->
    reply_err(ClientProto, Req, State, 404, <<"no_route">>, <<"no route for model">>).

reply_err(ClientProto, Req, State, Status, Code, Msg) ->
    reply_err(ClientProto, Req, State, Status, Code, Msg, #{}).

reply_err(ClientProto, Req, State, Status, Code, Msg, Extra) ->
    %% The message rides the terminal usage row (error_detail) so the
    %% Failures page can show WHY (e.g. the upstream's own sentence)
    %% instead of a bare status+code. Binary messages only; the list
    %% of tuples shapes stay unrecorded. Cleared per request in the
    %% preamble (keep-alive hygiene).
    case is_binary(Msg) of
        true -> put(janus_error_detail, Msg);
        false -> ok
    end,
    %% Every agent-facing rejection is logged (warning): the dashboard
    %% Logs page is the first place operators look when a client reports
    %% "provider rejected my request" — silent 400s forced Caddy-log
    %% archaeography once too often.
    logger:warning(#{
        what => janus_agent_reject,
        status => Status,
        code => Code,
        model => get(janus_req_model),
        %% The resolved name is unset for pre-pick rejects (allowlist,
        %% missing model) — the client's raw name is what operators need.
        requested_model => get(janus_requested_model),
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
    %% Downstream gzip seam (spec 2026-10-12-wire-compression F6/D8):
    %% the ONE unary reply choke point — SSE never passes here.
    mark_client_committed(),
    Req2 = janus_downstream_enc:reply(Status, Headers, Body, Req),
    {ok, Req2, State};
reply_json(Req, State, Status, Map, ExtraHeaders) when is_map(Map), is_map(ExtraHeaders) ->
    reply_json(Req, State, Status, thoas:encode(Map), ExtraHeaders).

%% Upstream headers distilled to content-type ONLY (sensitive
%% upstream headers stripped). TWO variants, split by what the caller
%% KNOWS about the body (ocr r3 scoping):
%%
%%   - filter_headers_json/1: JSON-by-contract paths (the native
%%     same-protocol faces, the error-envelope relay, the Decisions
%%     face). A headers map WITHOUT content-type defaults to
%%     application/json — the worker-dispatch unary done carries
%%     `trailers => #{}` (janus_worker_session emit_done; D2 keeps
%%     only body/status/usage), so without the default that
%%     execution path's client reply would carry no content-type
%%     while the local-fallback path carries the provider's (spec
%%     2026-10-12-wire-compression F6: the downstream gzip seam's
%%     content-type enumeration must see the same application/json on
%%     both execution paths). Total via maps:get — a partial map
%%     pattern would case_clause the reply on exactly such a map
%%     (ocr r1).
%%
%%   - filter_headers/1: unknown-shape bodies (the non-JSON 2xx
%%     passthrough). Keeps ONLY an existing content-type — never
%%     LABELS an unknown body as application/json (mislabelling would
%%     both lie to the client and make the body gzip-eligible under
%%     the JSON label; the gate's conservatism is compress only
%%     positively-identified types).
filter_headers_json(Headers) when is_map(Headers) ->
    case maps:get(<<"content-type">>, Headers, undefined) of
        undefined -> #{<<"content-type">> => <<"application/json">>};
        Ct -> #{<<"content-type">> => Ct}
    end;
filter_headers_json(_) ->
    #{<<"content-type">> => <<"application/json">>}.

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
    note_attempt_outcome(Route, provider_key, auth, {auth, Status}).

note_key_failure(Route, Headers, Status) when is_integer(Status) ->
    Reason = retry_reason(Headers, Status),
    note_attempt_outcome(Route, provider_key, reason_class_atom(Reason), Reason).

%% Key cool-clear only — the paired note_route_success/1 owns the
%% single attempt_id rate bump for a successful attempt (spec §4.5
%% at-most-once).
note_key_success(Route) ->
    janus_lb:note_success(key_target(Route)).

note_provider_failure(Route, Reason) ->
    note_attempt_outcome(Route, provider, reason_class_atom(Reason), Reason).

note_route_failure(Route, Reason) ->
    note_attempt_outcome(Route, route, reason_class_atom(Reason), Reason).

note_route_success(Route) ->
    maybe_note_latency(Route),
    note_attempt_outcome(Route, route, ok, ok).

%% Master-minted attempt_id + entity + class → janus_lb:note_attempt/1
%% (cool + rates atomically). Kind selects which cool/rate entity the
%% attempt attaches to (key / provider / route).
note_attempt_outcome(Route, Kind, Class, Reason) ->
    case attempt_entity(Route, Kind) of
        undefined ->
            ok;
        Entity ->
            janus_lb:note_attempt(#{
                attempt_id => mint_attempt_id(),
                entity => Entity,
                class => Class,
                reason => Reason
            })
    end.

mint_attempt_id() ->
    Ref = pd(janus_failover_ref, <<>>),
    Attempt = pd(janus_failover_attempt, 1),
    case Ref of
        R when is_binary(R), R =/= <<>> ->
            <<R/binary, "-", (integer_to_binary(Attempt))/binary>>;
        _ ->
            binary:encode_hex(crypto:strong_rand_bytes(16))
    end.

attempt_entity(Route, provider_key) ->
    case key_id_of(Route) of
        Kid when Kid =/= null, Kid =/= undefined ->
            #{
                kind => <<"provider_key">>,
                id => id_bin(Kid),
                provider_id => id_bin(maps:get(provider_id, Route, <<"unknown">>)),
                model_id => null
            };
        _ ->
            undefined
    end;
attempt_entity(Route, provider) ->
    case maps:get(provider_id, Route, undefined) of
        undefined ->
            undefined;
        Pid ->
            P = id_bin(Pid),
            #{kind => <<"provider">>, id => P, provider_id => P, model_id => null}
    end;
attempt_entity(Route, route) ->
    case maps:get(provider_id, Route, undefined) of
        undefined ->
            undefined;
        Pid ->
            P = id_bin(Pid),
            #{
                kind => <<"route">>,
                id => P,
                provider_id => P,
                model_id =>
                    case maps:get(model_id, Route, null) of
                        null -> null;
                        undefined -> null;
                        M -> id_bin(M)
                    end
            }
    end.

id_bin(B) when is_binary(B) -> B;
id_bin(I) when is_integer(I) -> integer_to_binary(I);
id_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
id_bin(_) -> <<"unknown">>.

reason_class_atom(Reason) ->
    %% janus_cool_view:reason_class/1 returns binaries; note_attempt
    %% accepts atoms or binaries — normalize to atom for the class field.
    Bin = janus_cool_view:reason_class(Reason),
    janus_rate_view:normalize_class(Bin).

%% Feed the LB latency EWMA from the last upstream_call's wall time
%% (pdict). Absent on paths that never reached upstream_call — those
%% must not invent a sample.
maybe_note_latency(Route) ->
    case get(janus_upstream_ms) of
        Ms when is_integer(Ms), Ms >= 0 ->
            janus_lb:note_latency(route_target(Route), Ms);
        _ ->
            ok
    end.

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
track(Status, Route, Usage) ->
    do_track(Status, Route, Usage, false).

%% Proxied terminals only: the duration histogram never sees early
%% rejects (pick errors, translate rejections, unknown_protocol).
track_proxied(Status, Route, Usage) ->
    do_track(Status, Route, Usage, true).

do_track(_Status, Route, _Usage, _Observe) when not is_map(Route) ->
    ok;
do_track(Status, Route, Usage, Observe) ->
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
            case Observe of
                true ->
                    janus_metrics:observe(
                        request_duration_seconds,
                        #{
                            protocol => janus_http_classify:protocol(get(janus_req_path)),
                            stream => usage_bool_int(Stream)
                        },
                        LatencyMs / 1000
                    );
                false ->
                    ok
            end,
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
            Usage1 = merge_worker_done_usage(Usage),
            Prompt = maps:get(prompt, Usage1, null),
            Completion = maps:get(completion, Usage1, null),
            case {get(janus_request_id), maps:get(id, Agent, null)} of
                {Rid, Aid} when is_binary(Rid), is_integer(Aid) ->
                    _ = janus_quota:charge_tokens(Rid, Aid, Prompt, Completion);
                _ ->
                    ok
            end,
            case maps:get(provider_id, Route, undefined) of
                Pid when is_integer(Pid) ->
                    Outcome = usage_outcome_or_null(),
                    {FailoverReason, NativeCode} = terminal_classification(Status, Outcome),
                    janus_usage:record(#{
                        ts => erlang:system_time(second),
                        requested_model => pd(janus_requested_model, null),
                        agent_key_id => maps:get(id, Agent, null),
                        model_id => maps:get(model_id, Route, null),
                        provider_id => Pid,
                        provider_key_id => key_id_of(Route),
                        protocol => Proto,
                        stream => usage_bool_int(Stream),
                        status => Status,
                        prompt => Prompt,
                        completion => Completion,
                        latency_ms => LatencyMs,
                        error_code => NativeCode,
                        attempt => pd(janus_failover_attempt, 1),
                        request_ref => pd(janus_failover_ref, null),
                        is_terminal => true,
                        request_id => get(janus_request_id),
                        outcome => Outcome,
                        failover_reason => FailoverReason,
                        %% Failed-terminal only: a request that walked
                        %% past a failed attempt to a 200 must not
                        %% carry that attempt's message (observed live:
                        %% success rows with the dashscope reject).
                        error_detail =>
                            case Status >= 400 of
                                true -> error_detail_pd();
                                false -> null
                            end,
                        trace_id => janus_trace:trace_id(get(janus_trace))
                    });
                _ ->
                    %% TF-A.0b writer-side pin (reorder spec
                    %% terminal_count): rows without provider_id are
                    %% NEVER written — local pre-pick rejects stay
                    %% unwritten (the metrics above still fire; only
                    %% the usage row is suppressed).
                    ok
            end;
        _ ->
            ok
    end.

%% Terminal-row error detail (stashed by reply_err; truncated at the
%% writer). Kept short: the Failures page needs the upstream's own
%% sentence, not the whole body.
error_detail_pd() ->
    case get(janus_error_detail) of
        B when is_binary(B) -> B;
        _ -> null
    end.

%% Worker client / abort paths stash via janus_http_worker_client:outcome_bin/1.
note_usage_outcome(Kind) when Kind =:= ok; Kind =:= error; Kind =:= cancelled ->
    case get(janus_usage_outcome) of
        B when is_binary(B) ->
            ok;
        _ ->
            put(janus_usage_outcome, janus_http_worker_client:outcome_bin(Kind)),
            ok
    end.

%% Remote-dispatch `janus_done.usage` is stashed in pdict by the worker
%% client; prefer those tokens over any local-parse empty Usage map.
merge_worker_done_usage(Usage) when is_map(Usage) ->
    case get(janus_worker_done_usage) of
        W when is_map(W) ->
            maps:merge(Usage, W);
        _ ->
            Usage
    end;
merge_worker_done_usage(Usage) ->
    Usage.

usage_outcome_or_null() ->
    case get(janus_usage_outcome) of
        B when is_binary(B) -> B;
        _ -> null
    end.

%% Locked terminal-row read rule (observability-depth Task 2): the
%% classification stash (janus_last_reason / janus_last_native_code) is
%% read ONLY for terminal failures — status >= 400, or a non-`ok'
%% outcome (mid-stream aborts can record status 200). Terminal success
%% rows write NULL/NULL regardless of any earlier retried attempts.
terminal_classification(Status, Outcome) ->
    case Status >= 400 orelse outcome_non_ok(Outcome) of
        true ->
            {last_reason_bin(), last_native_code()};
        false ->
            {null, null}
    end.

outcome_non_ok(<<"completed">>) -> false;
outcome_non_ok(null) -> false;
outcome_non_ok(B) when is_binary(B) -> true;
outcome_non_ok(_) -> false.

last_reason_bin() ->
    case get(janus_last_reason) of
        R when is_atom(R) -> atom_to_binary(R, utf8);
        _ -> null
    end.

last_native_code() ->
    case get(janus_last_native_code) of
        B when is_binary(B) -> B;
        _ -> null
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

%% PR2 CE violations/decode failures bench + retry like upstream 5xx
%% (spec 2026-10-12-wire-compression D6 parity).
is_transient({content_encoding, _}) -> true;
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

%% Shared with modality (janus_model_acl). See
%% docs/superpowers/specs/2026-10-12-agent-key-model-allowlist-design.md
%% §7. Chat still runs this before wrong_modality.
model_allowed(Agent, ModelName) ->
    janus_model_acl:model_allowed(Agent, ModelName).

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
    {route, null, P};
route_target(_) ->
    undefined.
