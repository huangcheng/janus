%%%-------------------------------------------------------------------
%%% @doc Shared data-plane proxy: auth'd handlers call proxy/5 with
%%% client protocol; dispatches native or translate paths.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_proxy).

-define(UPSTREAM_STALLED_MSG, <<"upstream stopped sending data mid-stream">>).
%% Shared by BOTH renderers (stream_failure_text/1 on the native path and
%% sanitize_stream_reason/1 on the translate path). A macro rather than two
%% literals so the agreement is structural: the whole point of the
%% reason-text tests is that these two cannot drift, and every other shared
%% sentence is already centralized.
-define(UNEXPECTED_FRAME_MSG, <<"upstream sent an unexpected stream frame">>).
%% An internal-hop inflate failure is OUR wire, not the provider's. Written
%% from two exits (the committed native path and the uncommitted reply), so
%% it is a macro: two literals are exactly how "one cause, one sentence"
%% silently breaks.
-define(INTERNAL_INFLATE_FAIL_MSG, <<"internal wire inflate failed">>).
-define(STREAM_TIMEOUT_MSG, <<"upstream stream exceeded the total time budget">>).


-include("janus_protocol_translate.hrl").

-export([handle/5, model_field/1, open_server_span/2, close_server_span/1, export_request_spans/0]).
-export([route_provider_name/1]).
%% Cross-module peels (failover/otel) call these on the orchestrator.
-export([
    key_id_of/1,
    collect_drain/1,
    stash_upstream_error_detail/1,
    usage_bool_int/1,
    retry_reason/2,
    dispatch/7,
    provider_protocol/1,
    resolve_model/1,
    route_model_name/1,
    route_target/1,
    key_target/1,
    track/3,
    sanitize_upstream_error/1,
    note_usage_outcome/1,
    reply_err/6,
    reply_err/7,
    release_route_inflight/1,
    maybe_note_latency/1
]).
%% Conformance seam (F13): drives the auto-tier bump so the closed-enum
%% rule is asserted against the producer rather than trusted.
-export([bump_auto_name_failover/0]).
%% Conformance seam: drives the REAL producer of the semconv HTTP family,
%% so its attribute set is asserted where it is built rather than mocked.
-export([observe_http_server_duration/3, method_label/0, scheme_label/0]).
%% Same seam for the GenAI duration producer.
-export([maybe_observe_genai_duration/1, observe_genai_tokens/5]).
%% Exported for eunit (usage capture helpers + Phase-2 knob).
-export([
    maybe_trim/2,
    maybe_inject_stream_usage/4,
    stream_translate_blocked_for/2,
    responses_stream_translate_enabled/0,
    %% Image detection is the input to the tier walk's vision gate; a gate
    %% that cannot see the image cannot protect anything, so the shapes it
    %% accepts are pinned by eunit.
    request_has_image/1,
    vision_gate/2,
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
%% Exported for eunit: a tripped accumulator ceiling is a LIMIT, not an
%% upstream failure, and that distinction decides whether a healthy provider
%% gets benched. Pure so the contract is pinnable without a socket.
-export([limit_terminal_accounting/0]).
%% Exported for eunit: the two renderers of a mid-stream drain reason. They
%% had drifted apart (the native one knew {body,_}, the translate one did
%% not, so the client read `api_error: body`), and a test that compares them
%% is the only thing that keeps them in step.
-export([
    sanitize_stream_reason/1, stream_failure_text/1, drain_detail_text/3,
    body_failure_text/1
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
    %% Wire format of the captured usage bytes. A stale value would make a
    %% later keep-alive request parse its tokens under the previous
    %% request's provider accounting rule.
    erase(janus_usage_wire_proto),
    erase(janus_first_content_chunk_us),
    erase(janus_ttfc_buf),
    %% upstream_call/5 wall time: absent on paths that never reached
    %% upstream, and must never be inherited by a later keep-alive
    %% request (maybe_note_latency/1 feeds it into the LB EWMA).
    erase(janus_upstream_ms),
    erase(janus_upstream_proto),
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
    erase(janus_auto_decided),
    erase(janus_auto_shape),
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
    %% Published AFTER the erase block above, alongside `janus_req_path',
    %% so the ordering cannot silently invert. Reading it in the preamble
    %% instead would be wiped on arrival here, and every HTTP-duration
    %% sample would carry the `_OTHER' fallback.
    put(janus_req_method, cowboy_req:method(Req)),
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
            case maybe_materialize_files(Agent, Body, Map) of
                {error, file_expansion_limit} ->
                    reply_err(
                        ClientProto,
                        Req,
                        State,
                        413,
                        <<"file_expansion_limit">>,
                        <<"request exceeds the file-reference count or expansion budget">>
                    );
                {Body1, Map1} ->
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
                    end
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
            case janus_files:materialize(AgentKeyId, Map) of
                {error, file_expansion_limit} ->
                    %% Per-request expansion bound tripped (reference
                    %% count or aggregate bytes): reject BEFORE the
                    %% unbounded re-encode (security-audit run-1).
                    {error, file_expansion_limit};
                Map1 when is_map(Map1) ->
                    {thoas:encode(Map1), Map1}
            end;
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

%% Both keys, OR-ed rather than first-match: a body carrying `messages`
%% and `input` together would otherwise have its images inspected only in
%% whichever key happened to be listed first — the same blindness this
%% function exists to remove, moved to a different axis.
request_has_image(Map) when is_map(Map) ->
    item_list_has_image(maps:get(<<"messages">>, Map, undefined)) orelse
        item_list_has_image(maps:get(<<"input">>, Map, undefined));
request_has_image(_) ->
    false.

item_list_has_image(Items) when is_list(Items) ->
    lists:any(fun item_has_image/1, Items);
item_list_has_image(_) ->
    false.

%% An image can ride an input item in more places than a user message's
%% content array, and the places it does not cover are the agent ones:
%%
%%   - a standalone `input_image` item at the top level of `input`
%%     (a Responses client may hoist it out of `content`),
%%   - a tool result: `function_call_output.output` may be a list of
%%     parts, which is exactly where a screenshot from a tool lands.
%%
%% Missing either one makes the tier walk's vision gate blind for the
%% requests that carry the most images, and the walk then hands the
%% image to a model that cannot read it — the client sees an upstream
%% 400 that names neither the model nor the image.
%% One clause, OR-ing every place an image can sit, rather than clauses
%% keyed on `content` / `output` in order: an item is allowed to carry
%% more than one of them, and a first-match walk would inspect only the
%% first key present. That is the same blindness this change removes,
%% just moved to a different shape.
%% `computer_call_output` is never itself an image part — the screenshot
%% lives in its `output` — so only `content` and `output` are read here.
item_has_image(#{<<"type">> := <<"computer_call_output">>} = M) ->
    container_has_image(maps:get(<<"content">>, M, undefined)) orelse
        output_object_has_image(maps:get(<<"output">>, M, undefined));
item_has_image(M) when is_map(M) ->
    part_is_image(M) orelse container_has_image(maps:get(<<"content">>, M, undefined)) orelse
        container_has_image(maps:get(<<"output">>, M, undefined));
item_has_image(_) ->
    false.

%% The one item type whose `output` is an OBJECT rather than a list: a
%% Responses `computer_call_output` wraps its screenshot that way. Listed
%% types are kept narrow on purpose — see container_has_image/1.
output_object_has_image(Inner) when is_map(Inner) ->
    item_has_image(Inner);
output_object_has_image(Inner) ->
    container_has_image(Inner).

%% `content` / `output` may be a list of parts, or a plain string (a
%% text-only tool result). Only the LIST form can hide an image here.
%%
%% A map-valued `output` is handled by its own clause in item_has_image/1
%% and only for `computer_call_output`: elsewhere a map is not a part at
%% all (the translate layer accepts a tool result as binary, null or a
%% list, and rejects a map as malformed). Recursing into any map would
%% report a browser or image-search tool result whose JSON happens to
%% carry an `image_url` field as image-bearing, moving a text-only
%% request onto the vision pool.
container_has_image(Parts) when is_list(Parts) ->
    lists:any(fun item_has_image/1, Parts);
container_has_image(_) ->
    false.

%% Type first, data second. The type name is required for every shape:
%% a tool result is free-form JSON, so a browser or image-search tool
%% echoing a result that happens to contain an `image_url` field would
%% otherwise read as image-bearing and push a text-only request onto the
%% vision pool — or exhaust an all-blind tier over a request that carried
%% no image. This also matches the translate layer, which decides by type
%% and rejects an unrecognized part rather than passing it through.
%%
%% A `computer_screenshot` is in the allowlist for exactly this reason:
%% its data lives in `image_url` but its type is its own.
part_is_image(P) when is_map(P) ->
    is_image_type(P) andalso part_carries_image_data(P);
part_is_image(_) ->
    false.

%% The three data fields are INDEPENDENT and OR-ed. Keying on one in
%% order hides the others: an SDK that serializes an unused optional
%% field as `image_url: null` beside a valid `source` would match the
%% `image_url` clause, find no url, and never look at `source` — blind
%% for a genuine image, which is the failure this whole change removes.
part_carries_image_data(P) when is_map(P) ->
    url_has_image(maps:get(<<"image_url">>, P, undefined)) orelse
        source_has_image(maps:get(<<"source">>, P, undefined)) orelse
        references_a_file(P).

%% Anthropic carries the bytes in `source` rather than `image_url`. Both
%% accepted forms are spelled out to match image_block_to_chat_part/1
%% exactly: a base64 source needs a non-empty media_type AND data, a url
%% source a non-empty url. Anything else is an error there, so accepting
%% it here would mark a data-less part vision-bearing and route a request
%% onto the vision pool over an image it does not carry.
source_has_image(#{<<"type">> := <<"base64">>, <<"media_type">> := MT, <<"data">> := Data}) when
    is_binary(MT), MT =/= <<>>, is_binary(Data), Data =/= <<>>
->
    true;
source_has_image(#{<<"type">> := <<"url">>, <<"url">> := U}) when is_binary(U), U =/= <<>> ->
    true;
source_has_image(_) ->
    false.

url_has_image(U) when is_binary(U) -> U =/= <<>>;
url_has_image(#{<<"url">> := U}) when is_binary(U) -> U =/= <<>>;
url_has_image(_) -> false.

is_image_type(#{<<"type">> := T}) ->
    lists:member(T, [
        <<"image_url">>, <<"image">>, <<"input_image">>, <<"computer_screenshot">>
    ]);
is_image_type(_) ->
    false.

%% A `file_id` only makes a part an image when the part is claiming to be
%% one: an ordinary text part that happens to carry a file attachment is
%% still text, and counting it would move a text-only request onto the
%% vision pool.
references_a_file(P) ->
    non_empty_file_id(P).

non_empty_file_id(#{<<"file_id">> := F}) when is_binary(F), F =/= <<>> -> true;
non_empty_file_id(_) -> false.

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
            %% A4: which zone/rule settled the tier, and what a judge saw
            %% (shape only). Rides the request-scoped pdict the walk already
            %% uses, so the usage row and the logs agree.
            put(janus_auto_decided, maps:get(decided, Meta, undefined)),
            put(janus_auto_shape, maps:get(shape, Meta, undefined)),
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
                    put(janus_auto_decided, maps:get(decided, Meta, undefined)),
                    put(janus_auto_shape, maps:get(shape, Meta, undefined)),
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
                    %% Detail before the row: track is the writer.
                    _ = put(janus_error_detail, <<"provider has unknown protocol">>),
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
            _ = put(janus_error_detail, <<"computer use requires a native provider route">>),
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
            _ = put(janus_error_detail, <<"streaming requires a same-protocol provider route">>),
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
            _ = put(janus_error_detail, Msg),
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
    %% One CLIENT span per upstream ATTEMPT (not per request): a retry or
    %% failover leg is a distinct network call with its own latency,
    %% status and upstream, and collapsing them would destroy exactly the
    %% evidence the failover cascade exists to produce. The span is opened
    %% before the call and closed by attach_attempt_span/3 once the
    %% outcome is known.
    AttemptSpan = open_attempt_span(ProviderProto, Route, Map, WantStream),
    Stream = janus_http_worker_client:normalize_want_stream(WantStream),
    Local = fun() -> call_adapter(ProviderProto, Route, Body, Map, #{stream => Stream}) end,
    %% Publish THIS attempt's span id for the duration of the dispatch, so
    %% the worker-side span can name it as its parent.
    %%
    %% The wire already carried `trace_id' and `sampled', which put the
    %% worker's span in the same trace but left it parentless: the master
    %% and worker spans rendered as siblings under one trace, so the chain
    %% master -> worker -> provider was not recoverable from a trace view.
    %% The id is published through the process dictionary because the span
    %% is opened here while the wire fields are assembled deeper inside
    %% `janus_http_worker_client:call/6' — same process, so the put is
    %% visible there, and `after' keeps it from leaking into the next
    %% attempt on a reused keep-alive connection.
    ok = janus_http_worker_client:publish_attempt_span(AttemptSpan),
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
        after
            ok = janus_http_worker_client:clear_attempt_span()
        end,
    %% Wall time of THIS attempt (connect + first byte for streams, plus
    %% body for unary); read by note_route_success/1 to feed the LB
    %% latency EWMA. Retried attempts overwrite it — attribution always
    %% lands on the route that produced the terminal result.
    put(janus_upstream_ms, erlang:monotonic_time(millisecond) - T0),
    %% Feeds gen_ai_operation/1 (otel) — without this every non-chat
    %% face was mislabelled as `chat` (ocr high on peel).
    put(janus_upstream_proto, ProviderProto),
    _ = close_attempt_span(AttemptSpan, Result),
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
    %% The usage capture stores the RAW provider SSE (capture_usage_chunk
    %% runs before translation rewrites the chunk), so the parser must be
    %% told the PROVIDER's protocol. This is the only path where the two
    %% protocols can differ, and picking the client's here applies the
    %% wrong cache-accounting rule (OpenAI's inclusive input count vs
    %% Anthropic's additive one) to a translated stream.
    _ = record_usage_wire_proto(ProviderProto),
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
                        _ = note_first_content_chunk(Ev),
                        case janus_protocol_translate:translate_sse(ClientProto, ProviderProto, Ev, StAcc) of
                            {ok, Frames, StNext} ->
                                write_frames(Frames, Req2),
                                StNext;
                            {error, translate_unsupported, StNext} ->
                                put(janus_sse_state, StNext),
                                %% Capture the offending frame's STRUCTURE
                                %% (keys and types, never values) before the
                                %% generic message goes out. Without this the
                                %% only way to act on "unsupported stream
                                %% construct" was to reproduce the stream and
                                %% guess which frame confused the mapper.
                                %%
                                %% Only when the frame carried NO in-band error:
                                %% if the provider named its own reason, that
                                %% sentence is the actionable evidence and a
                                %% structural fingerprint beside it just
                                %% suggests a translate bug that did not exist.
                                case Ev of
                                    #{data := #{<<"error">> := _}} ->
                                        ok;
                                    _ ->
                                        janus_shape_capture:stream_translate_reject(
                                            ClientProto, ProviderProto, Ev
                                        )
                                end,
                                %% Prefer the PROVIDER's own words when it
                                %% reported the failure in band; fall back
                                %% to the generic string only when it gave
                                %% us nothing to quote.
                                throw(
                                    {janus_translate, upstream, upstream_stream_error_msg()}
                                );
                            {error, CapKind, CapInfo, StNext} when
                                CapKind =:= tool_args_cap; CapKind =:= content_budget
                            ->
                                %% One of OUR OWN accumulator ceilings tripped (a
                                %% per-call/calls/total args cap, or the stream
                                %% content budget): the C2 error path —
                                %% target-format error event + terminator via
                                %% finalize, not a crash.
                                %%
                                %% The kind is `limit`, not `upstream`: this is a
                                %% configured limit being reached, not a provider
                                %% fault and not a translation gap. Reporting it as
                                %% `upstream` made it a 502 on the usage row and
                                %% benched a healthy provider, and put it on the
                                %% wire as an anonymous `api_error` the operator
                                %% could not act on. `cap_error_text/2` names the
                                %% setting, the limit in force, and the value that
                                %% crossed it.
                                put(janus_sse_state, StNext),
                                throw(
                                    {janus_translate, limit,
                                        janus_protocol_translate:cap_error_text(
                                            CapKind, CapInfo
                                        )}
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

%% Failed-request counter for a tripped ceiling, guarded exactly like
%% bump_failed_maybe/1: inner calls (failover attempts) never bump, and a
%% request that already bumped cannot bump again. Without these a limit would
%% inflate the counter once per attempt and once more on the central track path.
limit_bump_failed() ->
    case {get(janus_stats_inner), get(janus_stats_failed)} of
        {true, _} ->
            ok;
        {_, true} ->
            ok;
        _ ->
            janus_http_stats:inc_failed(),
            put(janus_stats_failed, true)
    end.

%% How a tripped accumulator ceiling is accounted.
%%
%% The wire status was already committed as 200 by stream_reply/3 before the
%% ceiling fired, so tracking 502 would contradict the status the client saw
%% AND bench a provider that did nothing wrong — the cap is ours, the provider
%% is healthy. Both halves are pinned by eunit.
-spec limit_terminal_accounting() -> {200, boolean()}.
limit_terminal_accounting() ->
    {200, false}.

finish_translate_stream(ClientProto, Route, Req2, State, Reason) ->
    St0 = get(janus_sse_state),
    WireReason = wire_reason(Reason),
    {ok, Frames, St1} = janus_protocol_translate:finalize_sse(ClientProto, WireReason, St0),
    put(janus_sse_state, St1),
    %% How close did this stream come to the accumulator ceilings? The caps
    %% are only visible when they TRIP, which made "is the limit too low?" a
    %% question with no data behind it: a stream that used 250 KiB of the
    %% 256 KiB budget looked identical to one that used 2 KiB. Logged once
    %% per finished stream, at INFO only when it matters (see the ratio
    %% guard), so the ring stays readable.
    note_cap_headroom(St1),
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
        {error, limit, Msg} ->
            %% One of OUR ceilings tripped; the provider is healthy. The wire
            %% status was already committed as 200 by stream_reply/3, so track
            %% 200 for the same reason the invalid_request arm does — a 502
            %% here would both contradict the status the client saw and bench a
            %% provider that did nothing wrong.
            {TrackStatus, BenchProvider} = limit_terminal_accounting(),
            %% Consumed, not decorative: if this ever flips, the provider IS
            %% benched here. Keeping the call site means the contract decides
            %% behaviour instead of merely describing it.
            case BenchProvider of
                true -> _ = note_provider_failure(Route, sanitize_upstream_error(Msg));
                false -> ok
            end,
            %% A cap is a failed request from the CLIENT's perspective, but it
            %% is tracked 200 so the row agrees with the status the socket
            %% already sent. That moved it out of every status-derived failure
            %% signal (bump_failed_maybe and the status-class counters are
            %% `Status >= 400` only), so a cap storm read as 100% 2xx traffic.
            %% Bump here — with the SAME two guards bump_failed_maybe uses, so
            %% an inner (failover) call never bumps and the later central
            %% track path cannot double-count the same request.
            _ = limit_bump_failed(),
            note_usage_outcome(error),
            %% The detail is what makes "which limit, and how close" answerable
            %% after the fact: it names the setting, the cap in force, and the
            %% value that crossed it.
            _ =
                case is_binary(Msg) of
                    true -> put(janus_error_detail, Msg);
                    false -> ok
                end;
        {error, upstream, Msg} ->
            TrackStatus = 502,
            note_usage_outcome(error),
            %% Carry the reason into the usage row. Mid-stream failures never
            %% went through stash_upstream_error_detail/1 (that path is the
            %% NON-stream one), so every terminal 502 on the translate path
            %% was written with error_detail = NULL — 301 rows over 20 days —
            %% and a cap being hit was indistinguishable from any other
            %% upstream stream failure. Quantifying a limit requires the row
            %% to say which limit.
            %% Binary only, matching every other writer of this key: the
            %% reader guards `is_binary`, so a non-binary would be silently
            %% dropped rather than recorded, which defeats the point.
            _ =
                case is_binary(Msg) of
                    true -> put(janus_error_detail, Msg);
                    false -> ok
                end,
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

%% One line per finished translate stream when it came within 50% of any
%% ceiling. Silent below that: a short exchange is the common case and does
%% not need a log line.
note_cap_headroom(#sse_st{tools = Tools, total_args = Total, content_bytes = ContentBytes}) ->
    Calls = map_size(Tools),
    %% Largest single call, in argument bytes.
    PerCall =
        maps:fold(
            fun(_K, #tool_acc{args_bytes = B}, Acc) -> max(Acc, B) end,
            0,
            Tools
        ),
    Caps = [
        {calls, Calls, janus_protocol_translate:tool_cap(calls)},
        {per_call, PerCall, janus_protocol_translate:tool_cap(per_call)},
        {total, Total, janus_protocol_translate:tool_cap(total)},
        %% The whole-stream text+args budget: without it, "how close were we?"
        %% stayed unanswerable for the one ceiling that bounds BOTH, even
        %% though the count is already sitting in the state.
        {content, ContentBytes, janus_protocol_translate:content_cap()}
    ],
    Near = [
        {Kind, Used, Cap}
     || {Kind, Used, Cap} <- Caps, Cap > 0, Used * 2 >= Cap
    ],
    case Near of
        [] ->
            ok;
        _ ->
            logger:info(#{
                what => janus_translate_cap_headroom,
                calls => Calls,
                largest_call_args => PerCall,
                total_args => Total,
                near => Near
            })
    end.

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
    _ = put(janus_error_detail, <<"upstream call crashed">>),
    _ = track_proxied(500, Route, #{}),
    _ = release_route_inflight(Route),
    reply_err(openai_decisions, Req, State, 500, <<"internal_error">>, <<"upstream call crashed">>);
decisions_terminal({error, response_too_large}, Route, Req, State) ->
    {Code, Msg} = decisions_local_error(response_too_large),
    %% Detail (and code) resolved BEFORE the row is written.
    _ = put(janus_error_detail, Msg),
    _ = track_proxied(502, Route, #{}),
    _ = release_route_inflight(Route),
    reply_err(openai_decisions, Req, State, 502, Code, Msg);
decisions_terminal({error, Reason}, Route, Req, State) ->
    Status = error_http_status(Reason),
    %% Derive the message from the STATUS, exactly as decisions_error_reply/4
    %% will, and stash it BEFORE the row. Deriving it from `Reason` instead
    %% would put a different sentence in the row than the caller receives.
    {_Code, DetailMsg} =
        case Status of
            504 -> decisions_local_error(upstream_timeout);
            _ -> decisions_local_error(other)
        end,
    _ = put(janus_error_detail, DetailMsg),
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
%% Time to first chunk (TTFC)
%%
%% The semconv defines `gen_ai.response.time_to_first_chunk' as seconds
%% from the start of the LOGICAL operation (before auth, before the first
%% attempt, including retries) to the arrival of the first content-bearing
%% chunk, and says it MUST NOT be set when no chunk arrives. Two things
%% follow, and both are easy to get wrong:
%%
%%   * The anchor is NOT `janus_usage_ctx.started' (captured at PROXY
%%     entry, after auth and quota admission) and NOT `TtfbStart' (starts
%%     at dispatch-ack, i.e. after the worker round trip). It is
%%     `janus_req_started', taken in the preamble.
%%   * A "chunk" is a CONTENT-BEARING decoded event. A role-only start
%%     event arrives BEFORE any token is generated, so counting it would
%%     report a TTFC that is really just connection setup and measure
%%     nothing.
%%--------------------------------------------------------------------

%% Record the first content-bearing chunk for this request, once.
note_first_content_chunk(Event) ->
    case get(janus_first_content_chunk_us) of
        undefined ->
            case is_content_chunk(Event) of
                true ->
                    put(janus_first_content_chunk_us, erlang:monotonic_time(microsecond)),
                    ok;
                false ->
                    ok
            end;
        _ ->
            ok
    end.

%% True when this decoded SSE event actually carries generated content.
%% Checked against the DECODED payload, not the raw bytes, so a keepalive
%% comment, a `[DONE]` sentinel, a usage-only terminal event, or a bare
%% role announcement cannot be mistaken for the first token.
is_content_chunk(#{data := Data}) when is_map(Data) ->
    is_content_chunk_map(Data);
is_content_chunk(_) ->
    false.

is_content_chunk_map(Data) ->
    case maps:get(<<"type">>, Data, undefined) of
        <<"content_block_delta">> ->
            has_delta_content(maps:get(<<"delta">>, Data, #{}));
        <<"content_block_start">> ->
            has_block_content(maps:get(<<"content_block">>, Data, #{}));
        _ ->
            %% Chat-shaped chunks: choices[].delta with content or tool
            %% calls. A delta carrying only `role` is the start marker and
            %% is deliberately NOT content.
            openai_has_content(maps:get(<<"choices">>, Data, undefined)) orelse
                is_responses_delta(Data) orelse
                is_untyped_delta(Data)
    end.

%% Responses-family streams tag every event with `type' ("response.*") and
%% put the generated text under a top-level `delta'. Handled as a family
%% rather than one event name at a time: `response.output_text.delta' is
%% the common one, but the reasoning and function-argument deltas carry
%% generated content the same way, and enumerating them would silently
%% stop measuring TTFC the day a new one appears.
%%
%% The `type' prefix check is what keeps this from firing on chat chunks,
%% which have no `type' but DO sometimes carry a top-level `delta' from
%% provider-specific extensions.
is_responses_delta(Data) ->
    case maps:get(<<"type">>, Data, undefined) of
        T when is_binary(T) ->
            case T of
                <<"response.", _/binary>> -> is_nonempty_bin(maps:get(<<"delta">>, Data, undefined));
                _ -> false
            end;
        _ ->
            false
    end.

%% A chat-shaped chunk with NO `type` that carries a non-empty top-level
%% `delta`. Some OpenAI-compatible providers emit this shape. Only
%% consulted when `type` is absent, so a Responses event (which always has
%% one) cannot fall through to it and be double-counted.
is_untyped_delta(Data) ->
    case maps:is_key(<<"type">>, Data) of
        true -> false;
        false -> is_nonempty_bin(maps:get(<<"delta">>, Data, undefined))
    end.

%% An attribute/stream value counts as content only when it is actually
%% non-empty; `<<>>` deltas occur in keepalive-ish frames.
is_nonempty_bin(B) ->
    is_binary(B) andalso B =/= <<>>.

has_delta_content(Delta) when is_map(Delta) ->
    Text = maps:get(<<"text">>, Delta, undefined),
    ToolInput = maps:get(<<"partial_json">>, Delta, undefined),
    case is_binary(Text) andalso Text =/= <<>> of
        true -> true;
        false -> is_binary(ToolInput) andalso ToolInput =/= <<>>
    end;
has_delta_content(_) ->
    false.

has_block_content(Block) when is_map(Block) ->
    Text = maps:get(<<"text">>, Block, undefined),
    is_binary(Text) andalso Text =/= <<>>;
has_block_content(_) ->
    false.

openai_has_content(Choices) when is_list(Choices) ->
    lists:any(
        fun
            (Choice) when is_map(Choice) ->
                case maps:get(<<"delta">>, Choice, undefined) of
                    Delta when is_map(Delta) ->
                        Content = maps:get(<<"content">>, Delta, undefined),
                        ToolCalls = maps:get(<<"tool_calls">>, Delta, undefined),
                        (is_binary(Content) andalso Content =/= <<>>) orelse
                            (is_list(ToolCalls) andalso ToolCalls =/= []);
                    _ ->
                        false
                end;
            (_) ->
                false
        end,
        Choices
    );
openai_has_content(_) ->
    false.

%% Native (passthrough) streams forward raw provider bytes and never
%% decode them, so the first content chunk has to be found here.
%%
%% The cost is bounded and paid only until the answer is known: the first
%% thing this does is check whether TTFC is already recorded, which is the
%% case for every chunk after the first token. Only the handful of chunks
%% before it are actually parsed.
note_ttfc_native(Chunk) ->
    %% Telemetry must never break the response it is measuring: a decoder
    %% throw here would abort a healthy passthrough stream. Swallow it and
    %% leave TTFC unset for this request.
    try
        note_ttfc_native_1(Chunk)
    catch
        _:_ -> erase(janus_ttfc_buf), ok
    end.

note_ttfc_native_1(Chunk) ->
    case get(janus_first_content_chunk_us) of
        undefined ->
            Buffer = case get(janus_ttfc_buf) of
                B when is_binary(B) -> B;
                _ -> <<>>
            end,
            case janus_protocol_translate:sse_events(Buffer, Chunk) of
                {ok, Events, Rest} ->
                    put(janus_ttfc_buf, Rest),
                    case lists:any(fun is_content_chunk/1, Events) of
                        true ->
                            put(janus_first_content_chunk_us, erlang:monotonic_time(microsecond)),
                            %% Stop parsing from here on.
                            erase(janus_ttfc_buf),
                            ok;
                        false ->
                            ok
                    end;
                {error, leftover_cap} ->
                    %% Oversized frame: give up on TTFC for this request
                    %% rather than holding an unbounded buffer. Recorded
                    %% as unavailable so a reader can tell "no chunk yet"
                    %% from "we stopped measuring".
                    logger:warning(#{what => janus_ttfc_abandoned, reason => leftover_cap}),
                    erase(janus_ttfc_buf),
                    ok
            end;
        _ ->
            ok
    end.

ttfc_seconds() -> janus_http_proxy_otel:ttfc_seconds().


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
    %% Stash BEFORE the row is written. This exit is the COMMITTED native
    %% passthrough stream, and it stashed nothing: every such 502 was written
    %% with error_detail NULL, so a body-side stall here was indistinguishable
    %% from any other upstream failure after the fact — the same loss the
    %% local execution path had. A client disconnect (499/cancelled) is not an
    %% upstream fault and keeps a clean row.
    _ =
        case Reason of
            closed -> ok;
            _ -> put(janus_error_detail, drain_detail_text(TrackStatus, Reason, stream_failure_text(Reason)))
        end,
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

%% Usage-row detail for a local-path upstream failure: the DRAIN reason when it
%% is specific enough to be useful, else the client-facing text. Kept a binary
%% because the row reader guards on is_binary.
drain_detail_text(Status, Reason, Fallback) ->
    Detailed =
        case {Status, Reason} of
            %% A 504 is the FIRST-BYTE budget and the client text already says
            %% so. Every 504-shaped reason maps here, including
            %% {await, timeout} — error_http_status/1 turns that tuple into 504
            %% unconditionally, so there is no 502/await-timeout state to
            %% distinguish and no need for a branch for one.
            {504, _} ->
                undefined;
            %% timeout is a STALL, not a generic body error — the same
            %% distinction both renderers make, so the row matches the client.
            {_, {body, timeout}} ->
                ?UPSTREAM_STALLED_MSG;
            {_, {body, R}} ->
                body_failure_text(R);
            {_, {await, no_progress}} ->
                ?UPSTREAM_STALLED_MSG;
            %% Internal-hop inflate failure is OUR wire, not the provider's
            %% (native_stream_fail skips benching for exactly this reason).
            %% Without this clause the row falls back to a provider-blaming
            %% sentence, and the sibling uncommitted branch already records
            %% the honest "internal wire inflate failed" for the same
            %% condition — one cause must not produce two different rows.
            {_, R} when ?IS_WIRE_ENC_ABORT(R) ->
                ?INTERNAL_INFLATE_FAIL_MSG;
            %% Delegated, never re-worded: one condition, one sentence. The
            %% guard keeps an UNKNOWN shape out of stream_failure_text/1 (whose
            %% catch-all is the vague "upstream error") so an unrecognised
            %% reason still falls back to the status-derived client text.
            %% Only the shapes not already handled above: `body` has its two
            %% clauses, so listing it here would be dead.
            {_, R} when
                is_tuple(R) andalso tuple_size(R) >= 1 andalso
                    (element(1, R) =:= content_encoding orelse
                        element(1, R) =:= unexpected_body)
            ->
                stream_failure_text(R);
            _ ->
                undefined
        end,
    case Detailed of
        undefined -> Fallback;
        Bin -> Bin
    end.

%% Human-readable, single-line, SSE-safe reason for a mid-stream close.
sse_failure_notice(closed) ->
    <<>>;
sse_failure_notice(Reason) ->
    Text = stream_failure_text(Reason),
    iolist_to_binary([<<": janus stream failed - ">>, Text, <<"\n\n">>]).

stream_failure_text({body, timeout}) -> ?UPSTREAM_STALLED_MSG;
stream_failure_text({body, Reason}) -> body_failure_text(Reason);
stream_failure_text({await, timeout}) -> ?STREAM_TIMEOUT_MSG;
stream_failure_text({await, no_progress}) -> ?UPSTREAM_STALLED_MSG;
stream_failure_text({unexpected_body, _}) -> ?UNEXPECTED_FRAME_MSG;
%% Top-level shape: janus_providers_http surfaces a decode failure on the
%% decoded drain as {content_encoding, _} rather than nesting it under body.
stream_failure_text({content_encoding, _}) -> body_failure_text({content_encoding, x});
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
handle_upstream(ClientProto, ProviderProto, {ok, stream, Status, Headers, Drain}, Route, false, Req, State) ->
    mark_client_committed(),
    %% Recorded for symmetry: on the passthrough path the provider protocol
    %% and the client protocol are identical, so this cannot change the
    %% answer. The path that MATTERS is handle_translate_stream/9.
    _ = record_usage_wire_proto(ProviderProto),
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
                _ = note_ttfc_native(Chunk),
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
    %% Canonical success outcome. Without this a LOCAL 200 recorded
    %% `outcome = null' while a WORKER 200 recorded `completed', so the
    %% same response meant different things depending on which node
    %% executed it. A span status derived from `outcome' inherited that.
    note_usage_outcome(ok),
    _ = track_proxied(
        Status,
        Route,
        usage_or_undef(janus_usage_parse:from_response_body(ProviderProto, RespBody))
    ),
    reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, Translate, Req, State);
handle_upstream(ClientProto, _ProviderProto, {error, crashed}, Route, _Translate, Req, State) ->
    _ = put(janus_error_detail, <<"upstream call crashed">>),
    note_usage_outcome(error),
    _ = track_proxied(500, Route, #{}),
    _ = release_route_inflight(Route),
    reply_err(ClientProto, Req, State, 500, <<"internal_error">>, <<"upstream call crashed">>);
handle_upstream(ClientProto, _ProviderProto, {error, worker_lost}, Route, _Translate, Req, State) ->
    %% In-flight worker death (N9): abort, no retry. Counts as a rate
    %% failure on the master (spec §4.1) without cooling the provider.
    note_usage_outcome(error),
    %% Detail BEFORE the row, not after. `track_proxied` is what writes the
    %% usage row, and `reply_err` (which normally stashes this key) runs
    %% afterwards — so setting it there left every worker_lost row with
    %% error_detail NULL and error_code empty, which is why four production
    %% 502s on this path could not be told apart from any other failure.
    _ = put(janus_error_detail, <<"upstream worker lost">>),
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
    _ = put(janus_error_detail, ?INTERNAL_INFLATE_FAIL_MSG),
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
    %% Stash the reason BEFORE reply_err writes the row. This branch is the
    %% LOCAL execution path's failure exit (the worker was unavailable, so
    %% the master drained the provider itself) and it computed `Msg` without
    %% ever recording it: every such 502 was written with error_detail NULL,
    %% so a body-side stall was indistinguishable from any other upstream
    %% failure after the fact — the live 2026-11-11 case where a 147s stream
    %% produced `api_error: body` and no row said why.
    %%
    %% The drain reason is the useful part and it is richer than the generic
    %% client text, so record the sanitized reason when there is one.
    _ = put(janus_error_detail, drain_detail_text(Status, Reason, Msg)),
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
%% Body-side failures, same words as stream_failure_text/1. This clause was
%% MISSING and it was the live 2026-11-11 bug: the local execution path
%% (janus_providers_http drains the provider directly when no worker is
%% available) reports a silent body as {body, timeout}, which fell through to
%% sanitize_upstream_error/1 — whose {Tag, _} -> Tag clause returns the bare
%% atom `body`, so the client was told `api_error: body` after a 147s stream.
sanitize_stream_reason({body, timeout}) -> ?UPSTREAM_STALLED_MSG;
sanitize_stream_reason({body, Reason}) -> body_failure_text(Reason);
%% The sibling drain shape: a frame arrived where none was expected. Named
%% like the two above so it cannot fall through to sanitize_upstream_error/1
%% and reach the client as the bare atom `unexpected_body`.
sanitize_stream_reason({unexpected_body, _}) -> ?UNEXPECTED_FRAME_MSG;
%% Top-level decode failure (janus_providers_http's decoded drain). Without
%% this clause it fell through to sanitize_upstream_error/1, which returns the
%% bare atom `content_encoding` — the same leak as `body`, one shape over.
sanitize_stream_reason({content_encoding, _}) ->
    body_failure_text({content_encoding, x});
sanitize_stream_reason(Other) -> sanitize_upstream_error(Other).

%% A body that stopped for a reason other than silence. Still names the body
%% (that is where it broke and it is what an operator greps for) but never
%% echoes an Erlang term.
%% Reasons that mean the connection ENDED, in gun's vocabulary. Grouped so
%% an operator sees "closed" for a reset rather than a vaguer "error".
body_failure_text(closed) -> <<"upstream body closed">>;
body_failure_text(econnreset) -> <<"upstream body closed">>;
body_failure_text(closed_by_peer) -> <<"upstream body closed">>;
%% A HEADERS-level contract violation (janus_wire_enc:classify_content_encoding/1
%% rejected the provider's Content-Encoding) is not a decompression failure —
%% nothing was ever decompressed. "Unsupported encoding" is the honest
%% sentence, and this text now reaches both the SSE comment and the usage row,
%% so the distinction is worth a clause.
body_failure_text({content_encoding, {violation, _}}) ->
    <<"upstream sent an unsupported content-encoding">>;
body_failure_text({content_encoding, _}) -> <<"upstream body decompression error">>;
%% A size cap is a distinct, greppable cause (janus_providers_http:
%% collect_body/5 crosses ?MAX_BODY_BYTES) and the decisions face already has
%% its own sentence for it. Reported as a generic body error it reads like a
%% transport fault and sends an operator looking in the wrong place.
body_failure_text(too_large) -> <<"upstream response body exceeds size limit">>;
body_failure_text(_) -> <<"upstream body error">>.

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



%% Failover — bodies live in janus_http_proxy_failover (OCR line budget).
failover_start() -> janus_http_proxy_failover:failover_start().
failover_classify(R, X) -> janus_http_proxy_failover:failover_classify(R, X).
failover_decide(A,B,C,D,E,F,G) -> janus_http_proxy_failover:failover_decide(A,B,C,D,E,F,G).
bump_auto_name_failover() -> janus_http_proxy_failover:bump_auto_name_failover().
within_failover_budget() -> janus_http_proxy_failover:within_failover_budget().
failover_knobs() -> janus_http_proxy_failover:failover_knobs().
is_advanceable_pick_error(A1) -> janus_http_proxy_failover:is_advanceable_pick_error(A1).
pick_error_status(A1) -> janus_http_proxy_failover:pick_error_status(A1).
vision_gate(A1, A2) -> janus_http_proxy_failover:vision_gate(A1, A2).
record_failover_row(A1, A2, A3) -> janus_http_proxy_failover:record_failover_row(A1, A2, A3).

bump_failed_maybe(A1) -> janus_http_proxy_failover:bump_failed_maybe(A1).
error_map(A1, A2, A3) -> janus_http_proxy_failover:error_map(A1, A2, A3).
filter_headers(A1) -> janus_http_proxy_failover:filter_headers(A1).
filter_headers_json(A1) -> janus_http_proxy_failover:filter_headers_json(A1).
filter_stream_headers(A1) -> janus_http_proxy_failover:filter_stream_headers(A1).
inc_total_once() -> janus_http_proxy_failover:inc_total_once().
mark_client_committed() -> janus_http_proxy_failover:mark_client_committed().
maybe_crash_bump_failed() -> janus_http_proxy_failover:maybe_crash_bump_failed().
maybe_next_name_on_pick_error(A1, A2, A3, A4, A5, A6) -> janus_http_proxy_failover:maybe_next_name_on_pick_error(A1, A2, A3, A4, A5, A6).
note_attempt_outcome(A1, A2, A3, A4) -> janus_http_proxy_failover:note_attempt_outcome(A1, A2, A3, A4).
note_auth_failure(A1, A2) -> janus_http_proxy_failover:note_auth_failure(A1, A2).
note_key_failure(A1, A2, A3) -> janus_http_proxy_failover:note_key_failure(A1, A2, A3).
note_key_success(A1) -> janus_http_proxy_failover:note_key_success(A1).
note_provider_failure(A1, A2) -> janus_http_proxy_failover:note_provider_failure(A1, A2).
note_route_failure(A1, A2) -> janus_http_proxy_failover:note_route_failure(A1, A2).
note_route_success(A1) -> janus_http_proxy_failover:note_route_success(A1).
pd(A1, A2) -> janus_http_proxy_failover:pd(A1, A2).
release_route_inflight(A1) -> janus_http_proxy_failover:release_route_inflight(A1).
maybe_note_latency(A1) -> janus_http_proxy_failover:maybe_note_latency(A1).
repick_route(A1, A2, A3) -> janus_http_proxy_failover:repick_route(A1, A2, A3).
reply_err(A1, A2, A3, A4, A5, A6) -> janus_http_proxy_failover:reply_err(A1, A2, A3, A4, A5, A6).
reply_err(A1, A2, A3, A4, A5, A6, A7) -> janus_http_proxy_failover:reply_err(A1, A2, A3, A4, A5, A6, A7).
reply_json(A1, A2, A3, A4) -> janus_http_proxy_failover:reply_json(A1, A2, A3, A4).
reply_pick_error(A1, A2, A3, A4) -> janus_http_proxy_failover:reply_pick_error(A1, A2, A3, A4).
retry_jitter() -> janus_http_proxy_failover:retry_jitter().
stash_classification(A1, A2) -> janus_http_proxy_failover:stash_classification(A1, A2).


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
                    ),
                    %% ADDITIVE semconv instrument over the same
                    %% measurement (design §8.1: one registry, two views).
                    %% Gated on the EXPORT knob so a knob-off deployment
                    %% registers no new family and its /metrics output is
                    %% unchanged in content (§13.4: export on = superset —
                    %% the Prometheus view must NOT follow the per-signal
                    %% selection; only the OTLP POST does).
                    case janus_telemetry:export_enabled() of
                        true -> observe_http_server_duration(Status, Stream, LatencyMs);
                        false -> ok
                    end;
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
            CacheRead = maps:get(cache_read, Usage1, null),
            CacheWrite = maps:get(cache_write, Usage1, null),
            %% Token counts belong on the CLIENT span (the semconv puts
            %% usage there, not on the SERVER span: the server cannot know
            %% what the upstream billed). Attached here because this is
            %% where the parsed usage first exists, and it is the same map
            %% the ledger row is written from, so a trace and the billing
            %% row can never disagree.
            ok = attach_usage_to_span(Usage1),
            %% ADDITIVE semconv token counters, from the SAME map the
            %% ledger row and the span attributes are built from, so the
            %% three can never disagree about what was billed. Gated on
            %% the export knob (design §13.4).
            ok = observe_genai_tokens(Route, Prompt, Completion, CacheRead, CacheWrite),
            case {get(janus_quota_charge_id), maps:get(id, Agent, null)} of
                {ChargeId, Aid} when is_binary(ChargeId), is_integer(Aid) ->
                    _ = janus_quota:charge_tokens(ChargeId, Aid, Prompt, Completion);
                _ ->
                    ok
            end,
            case maps:get(provider_id, Route, undefined) of
                Pid when is_integer(Pid) ->
                    Outcome = usage_outcome_or_null(),
                    %% Close the SERVER span with the same terminal status
                    %% the ledger row records, so a trace and the usage
                    %% table can never disagree about how a request ended.
                    ok = close_server_span(Status),
                    {FailoverReason, NativeCode} = terminal_classification(Status, Outcome),
                    janus_usage:record((row_span_ids())#{
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
                        cache_read_input_tokens => CacheRead,
                        cache_write_input_tokens => CacheWrite,
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
                        %%
                        %% The 200s that DO carry it are the NON-OK
                        %% outcomes — a mid-stream limit, and the other
                        %% post-commit aborts like translate_abort. The wire
                        %% status was already committed as 200 before those
                        %% fired, so gating on Status alone dropped the only
                        %% record of what went wrong, leaving the row
                        %% indistinguishable from a clean stream.
                        error_detail =>
                            case Status >= 400 orelse outcome_non_ok(Outcome) of
                                true -> error_detail_pd();
                                false -> null
                            end,
                        trace_id => janus_trace:trace_id(get(janus_trace))
                    }),
                    %% Emit AFTER the row is written and after usage is
                    %% on the span, so the exported trace and the ledger
                    %% agree on tokens, span ids and status.
                    ok = export_request_spans();
                _ ->
                    %% TF-A.0b writer-side pin (reorder spec
                    %% terminal_count): rows without provider_id are
                    %% NEVER written — local pre-pick rejects stay
                    %% unwritten (the metrics above still fire; only
                    %% the usage row is suppressed).
                    %%
                    %% The span still closes and exports: these are the
                    %% pre-pick rejects (invalid_json, wrong_modality,
                    %% no_route, ...) and their responses already carry a
                    %% `traceparent' naming the SERVER span — leaving it
                    %% unexported moves the phantom-parent defect from a
                    %% minted id to an opened-but-never-sent span.
                    ok = close_server_span(Status),
                    ok = export_request_spans()
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
    %% The bytes in the buffer are provider-format; the caller passes the
    %% client proto for its own reasons, so prefer the protocol recorded at
    %% dispatch. The key is set and cleared per request (see
    %% `record_usage_wire_proto/1' and the header reset), so a keep-alive
    %% reuse cannot leak the previous request's protocol.
    WireProto = case get(janus_usage_wire_proto) of
        undefined -> ClientProto;
        P -> P
    end,
    stream_usage_1(WireProto).

%% Record the wire format of the usage bytes captured for this request.
%% Cleared with the other per-request state at the top of `handle/5'.
record_usage_wire_proto(Proto) ->
    put(janus_usage_wire_proto, Proto),
    ok.

stream_usage_1(WireProto) ->
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
    usage_or_undef(janus_usage_parse:from_sse(WireProto, Head, Tail)).

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


%% OTel / metrics — bodies live in janus_http_proxy_otel (OCR line budget).
open_server_span(Method, Path) -> janus_http_proxy_otel:open_server_span(Method, Path).
close_server_span(Status) -> janus_http_proxy_otel:close_server_span(Status).
export_request_spans() -> janus_http_proxy_otel:export_request_spans().
open_attempt_span(A, B, C, D) -> janus_http_proxy_otel:open_attempt_span(A, B, C, D).
close_attempt_span(A, B) -> janus_http_proxy_otel:close_attempt_span(A, B).
attach_usage_to_span(U) -> janus_http_proxy_otel:attach_usage_to_span(U).
observe_genai_tokens(A, B, C, D, E) -> janus_http_proxy_otel:observe_genai_tokens(A, B, C, D, E).
observe_http_server_duration(A, B, C) -> janus_http_proxy_otel:observe_http_server_duration(A, B, C).
method_label() -> janus_http_proxy_otel:method_label().
scheme_label() -> janus_http_proxy_otel:scheme_label().
maybe_observe_genai_duration(R) -> janus_http_proxy_otel:maybe_observe_genai_duration(R).
row_span_ids() -> janus_http_proxy_otel:row_span_ids().

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
