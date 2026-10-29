%%%-------------------------------------------------------------------
%%% @doc Modality plugin shared plumbing (spec M1.0).
%%
%% One cowboy entry (janus_http_modality) fronts every modality plugin.
%% A plugin implements:
%%   modality/0  -> <<"image">> | <<"tts">> | <<"asr">> | ...
%%   max_body/0  -> request byte cap (413 beyond)
%%   process/5   -> (Req, State, Agent, Body, Meta) -> {ok, Req, State}
%%
%% Shared here: agent auth, request id, body cap, the model allowlist
%% (403 model_not_allowed before quota when the client named a model;
%% design spec
%% docs/superpowers/specs/2026-10-12-agent-key-model-allowlist-design.md
%% §4.8), JSON helpers, route pick, the generic upstream JSON POST
%% (provider key from the LB's route), canonical error envelope,
%% usage-row recording with modality/units/outcome, and the
%% wrong_modality guard.
%% @end
%%%-------------------------------------------------------------------
-module(janus_modality).

-export([
    run/3,
    parse_json/1,
    model_of/1,
    check_modality/2,
    pick_route/1,
    upstream_post/3,
    upstream_post/4,
    reply_json/4,
    reply_bytes/5,
    record_usage/2,
    endpoint_for/1,
    asr_form/3
]).

%% Hard ceiling for every modality request body (review 02b L3): cowboy
%% has no listener-level body limit, so this shared reader is the one
%% place that bounds all plugin paths uniformly. A plugin may ask for
%% less (images 10 MiB, video 5 MiB, tts 64 KiB); it can never ask more.
-define(MAX_BODY, 200 * 1024 * 1024).

%%--------------------------------------------------------------------
%% Entry (called by janus_http_modality:init/2)
%%--------------------------------------------------------------------

run(Plugin, Req0, State) ->
    %% Observability-depth Task 3: the trace context resolves BEFORE the
    %% knob check so even the knob-off 503 (modality_disabled) carries
    %% the x-trace-id echo; the unconditional put also covers keep-alive
    %% process reuse. (Requests rejected by cowboy's own HTTP parser
    %% never reach here and echo neither x-trace-id nor x-request-id.)
    Trace = janus_trace:ensure(cowboy_req:header(<<"traceparent">>, Req0)),
    Req1 = cowboy_req:set_resp_header(<<"x-trace-id">>, janus_trace:trace_id(Trace), Req0),
    put(janus_trace, Trace),
    %% Cowboy keep-alive hygiene for modality ACL / plugin process dict.
    erase(janus_req_model),
    erase(janus_requested_model),
    case enabled(Plugin:modality()) of
        false ->
            reply_json(
                Req1,
                State,
                503,
                #{
                    error => #{
                        message => <<
                            "modality disabled on this gateway (settings knob "
                            "modality.<name>, default off)"
                        >>,
                        type => <<"janus_error">>,
                        code => <<"modality_disabled">>
                    }
                }
            );
        true ->
            run_enabled(Plugin, Req1, State)
    end.

%% Knob check: settings key `modality` = {"image": true, ...} via
%% persistent_term {janus, modality_cfg}. Absent = OFF (shipped
%% default; the operator flips after gate+smoke).
enabled(Modality) when is_binary(Modality) ->
    case persistent_term:get({janus, modality_cfg}, undefined) of
        #{Modality := true} -> true;
        _ -> false
    end.

%% Knob-off already returned 503. When the client named a model:
%% 403 model_not_allowed, then quota 429, then the plugin. A missing
%% model skips the allowlist (the plugin keeps its 400). A body over
%% the cap has no reliable model field, so quota still outranks 413.
%%
%% The allowlist has to see `model` before admit, so the capped body
%% is buffered first. An over-quota client can therefore force a full
%% read (ASR is 25 MiB). The model part may follow the file, so a
%% prefix read cannot decide the allowlist.
run_enabled(Plugin, Req0, State) ->
    %% The trace context was already resolved in run/3 (ahead of the
    %% knob check, so modality_disabled echoes it); the request id stays
    %% here beside auth.
    ReqId = janus_request_id:resolve(cowboy_req:header(<<"x-request-id">>, Req0)),
    Req1 = cowboy_req:set_resp_header(<<"x-request-id">>, ReqId, Req0),
    put(janus_request_id, ReqId),
    %% Server-side charge nonce (same rationale as the preamble: a
    %% replayed client x-request-id must never suppress TPM/daily
    %% charges on modality faces either).
    janus_quota:mint_charge_id(),
    %% Keep-alive hygiene (observability-depth Task 2): mirror
    %% janus_http_proxy:handle/5's failover erase list — a proxy request
    %% may have run on this same process earlier in the connection's
    %% life — then mint a FRESH request_ref, else a second modality
    %% request on this connection would inherit the previous request's
    %% ref/stash.
    erase(janus_failover_started),
    erase(janus_failover_ref),
    erase(janus_failover_attempt),
    erase(janus_part_c_attempt),
    erase(janus_failover_keys),
    erase(janus_failover_unclassified_retried),
    %% Mirror proxy handle/5 keep-alive hygiene for next-name snapshot
    %% keys (ocr High: a prior janus-auto proxy request on this process
    %% must not leak enabled/names into a later modality request).
    erase(janus_auto_tier),
    erase(janus_auto_tier_names),
    erase(janus_auto_names_attempted),
    erase(janus_auto_tier_failover),
    erase(janus_auto_tier_max_names),
    erase(janus_auto_http_attempts),
    erase(janus_client_committed),
    erase(janus_last_native_code),
    erase(janus_last_reason),
    janus_http_proxy:failover_start(),
    case janus_http_auth:require_agent(Req1) of
        {ok, Agent, Req2} ->
            erase(janus_req_counted),
            erase(janus_error_detail),
            erase(janus_quota_admitted),
            erase(janus_quota_charged),
            Max = min(Plugin:max_body(), ?MAX_BODY),
            %% Same slow-upload fix as the preamble: loop until the body
            %% completes; {more,_} is a period expiry, not an oversize.
            case janus_http_preamble:read_full(Req2, Max) of
                {ok, Body, Req3} ->
                    gate_model(Plugin, Req3, State, Agent, Body, ReqId);
                {too_large, Req3} ->
                    case janus_quota:admit(Agent) of
                        ok ->
                            reply_too_large(Req3, State);
                        {error, {quota, Kind, Sec}} ->
                            reject_quota(Req3, State, Kind, Sec)
                    end
            end;
        {error, ReqErr} ->
            {ok, ReqErr, State}
    end.

%% Allowlist before quota only once a non-empty model name is known.
%% Video status/result never carry one (create is POST /v1/videos).
gate_model(Plugin, Req, State, Agent, Body, ReqId) ->
    case named_client_model(Plugin, Req, Body) of
        {ok, Model, Extra} ->
            case janus_model_acl:model_allowed(Agent, Model) of
                true ->
                    admit_and_process(Plugin, Req, State, Agent, Body, ReqId, Extra);
                false ->
                    put(janus_req_model, Model),
                    {ok, reply_model_not_allowed(Req), State}
            end;
        {skip, Extra} ->
            admit_and_process(Plugin, Req, State, Agent, Body, ReqId, Extra)
    end.

admit_and_process(Plugin, Req, State, Agent, Body, ReqId, Extra) ->
    case janus_quota:admit(Agent) of
        ok ->
            Meta = Extra#{request_id => ReqId},
            Plugin:process(Req, State, Agent, Body, Meta);
        {error, {quota, Kind, Sec}} ->
            reject_quota(Req, State, Kind, Sec)
    end.

named_client_model(Plugin, Req, Body) ->
    case Plugin:modality() of
        <<"video">> ->
            case {cowboy_req:method(Req), video_path_info(Req)} of
                {<<"POST">>, []} -> json_named_model(Body);
                _ -> {skip, #{}}
            end;
        <<"asr">> ->
            asr_named_model(Req, Body);
        _ ->
            json_named_model(Body)
    end.

video_path_info(Req) ->
    case cowboy_req:path_info(Req) of
        undefined -> [];
        PI when is_list(PI) -> PI;
        _ -> undefined
    end.

json_named_model(Body) ->
    case parse_json(Body) of
        {ok, Map} ->
            case maps:get(<<"model">>, Map, undefined) of
                M when is_binary(M), M =/= <<>> -> {ok, M, #{}};
                _ -> {skip, #{}}
            end;
        {error, bad_json} ->
            {skip, #{}}
    end.

%% The parsed form rides request Meta so the plugin does not parse the
%% file a second time, and so nothing is left in the process dictionary
%% when quota or the allowlist rejects the call.
asr_named_model(Req, Body) ->
    Form = parse_asr_form(Req, Body),
    Extra = #{asr_form => Form},
    case Form of
        {ok, #{fields := Fields}} when is_map(Fields) ->
            case maps:get(<<"model">>, Fields, undefined) of
                M when is_binary(M), M =/= <<>> -> {ok, M, Extra};
                _ -> {skip, Extra}
            end;
        _ ->
            {skip, Extra}
    end.

reject_quota(Req, State, Kind, Sec) ->
    {ok, reply_quota_modality(Req, State, Kind, Sec), State}.

reply_too_large(Req, State) ->
    reply_json(
        Req,
        State,
        413,
        #{
            error => #{
                message => <<"body exceeds limit">>,
                type => <<"janus_error">>,
                code => <<"request_too_large">>
            }
        }
    ).

%%--------------------------------------------------------------------
%% Helpers used by plugins
%%--------------------------------------------------------------------

%% thoas:decode/1 returns {ok, Map} | {error, _} — never raises on
%% bad input. Match the tuple or every body misreads.
-spec parse_json(binary()) -> {ok, map()} | {error, bad_json}.
parse_json(Body) when is_binary(Body), byte_size(Body) > 0 ->
    case thoas:decode(Body) of
        {ok, Map} when is_map(Map) -> {ok, Map};
        _ -> {error, bad_json}
    end;
parse_json(_) ->
    {error, bad_json}.

%% ASR multipart. The gate stashes its one parse under `asr_form` in
%% the request Meta; a missing key parses now.
-spec asr_form(map(), cowboy_req:req(), binary()) ->
    {ok, map()} | {error, bad_multipart | invalid_content_type}.
asr_form(Meta, Req, Body) when is_map(Meta) ->
    case maps:get(asr_form, Meta, undefined) of
        undefined -> parse_asr_form(Req, Body);
        Form -> Form
    end;
asr_form(_Meta, Req, Body) ->
    parse_asr_form(Req, Body).

parse_asr_form(Req, Body) ->
    case janus_multipart:boundary_of(cowboy_req:header(<<"content-type">>, Req)) of
        {ok, Boundary} ->
            case janus_multipart:parse(Body, Boundary) of
                {ok, Parsed} -> {ok, Parsed};
                {error, bad_multipart} -> {error, bad_multipart}
            end;
        error ->
            {error, invalid_content_type}
    end.

-spec model_of(map()) -> binary() | undefined.
model_of(Map) when is_map(Map) ->
    case maps:get(<<"model">>, Map, undefined) of
        M when is_binary(M) -> M;
        _ -> undefined
    end.

%% wrong_modality guard (spec Contracts): a chat call naming a
%% non-chat-listed model is rejected LOCALLY with the right endpoint.
-spec check_modality(binary(), binary()) -> ok | {error, binary()}.
check_modality(Want, ModelName) ->
    case janus_catalog:model_modality(ModelName) of
        Want -> ok;
        <<"chat">> -> ok;
        Other ->
            {error,
                iolist_to_binary([
                    <<"model is of modality '">>, Other,
                    <<"'; call ">>, endpoint_for(Other),
                    <<" instead (wrong_modality)">>
                ])}
    end.

endpoint_for(<<"image">>) -> <<"POST /v1/images/generations">>;
endpoint_for(<<"embedding">>) -> <<"POST /v1/embeddings">>;
endpoint_for(<<"tts">>) -> <<"POST /v1/audio/speech">>;
endpoint_for(<<"asr">>) -> <<"POST /v1/audio/transcriptions">>;
endpoint_for(<<"video">>) -> <<"POST /v1/videos">>;
endpoint_for(_) -> <<"the matching modality endpoint">>.

-spec pick_route(binary()) -> {ok, map()} | {error, term()}.
pick_route(ModelName) ->
    janus_lb:pick_listing_route(ModelName, #{}).

%% Generic upstream JSON POST — mirrors the chat adapter's resolve
%% (LB-injected provider_key, base_url parse, path join, bearer auth)
%% but injects NO stream key and NO model rewrite: the plugin owns the
%% exact body. Image/TTS/ASR may ride a worker (W2.2); video paths stay
%% master-local. Binary passthrough replies ride upstream_post_raw.
-spec upstream_post(map(), binary(), map() | binary(), map()) ->
    {ok, pos_integer(), map(), binary()} | {error, term()}.
upstream_post(Route, PathSuffix, ReqMapOrBody, Opts) when is_map(Route) ->
    Body =
        case ReqMapOrBody of
            B when is_binary(B) -> B;
            M -> thoas:encode(M)
        end,
    Local = fun() -> local_upstream_post(Route, PathSuffix, Body, Opts) end,
    janus_http_worker_client:unary_post(Route, PathSuffix, Body, Opts, Local).

upstream_post(Route, PathSuffix, ReqMapOrBody) ->
    upstream_post(Route, PathSuffix, ReqMapOrBody, #{}).

local_upstream_post(Route, PathSuffix, Body, Opts) when is_binary(Body) ->
    case janus_http_worker_client:resolve_unary_upstream(Route, PathSuffix, Body, Opts) of
        {ok, #{
            host := Host,
            port := Port,
            path := Path,
            tls := Tls,
            headers := Headers,
            body := BodyBin,
            timeout_ms := Timeout
        }} ->
            Target = #{
                host => Host,
                port => Port,
                path => Path,
                tls => Tls,
                timeout => Timeout
            },
            janus_providers_http:post(Target, Headers, BodyBin);
        {error, _} = Err ->
            Err
    end.

reply_json(Req, State, Status, Map) ->
    %% Downstream gzip seam (spec 2026-10-12-wire-compression F6/D8):
    %% modality JSON replies (image generation bodies carry base64
    %% payloads — the big modality win) compress under the same gate.
    Body = thoas:encode(Map),
    Req2 = janus_downstream_enc:reply(
        Status,
        #{<<"content-type">> => <<"application/json">>},
        Body,
        Req
    ),
    {ok, Req2, State}.

reply_bytes(Req, State, Status, ContentType, Body) ->
    %% Content-type decides: plugins ALSO use reply_bytes for
    %% application/json bodies (images/video base64 payloads — the big
    %% modality win, in the seam's compressible set); genuinely binary
    %% types (image/*, audio/*, video/*) stay identity by the seam's
    %% F6 enumeration.
    Req2 = janus_downstream_enc:reply(
        Status, #{<<"content-type">> => ContentType}, Body, Req
    ),
    {ok, Req2, State}.

%% Usage row: the plugin passes modality/units/outcome + the usual
%% fields; route context is pulled from the pdict like the proxy does.
%% request_ref/trace_id are stamped from the pdict (minted at the
%% modality entry) so modality rows join the Task 5 timeline.
record_usage(#{status := _} = Ev0, Route) ->
    ReqId = get(janus_request_id),
    %% Terminal-row error detail, same contract as the proxy faces:
    %% plugins stash the reply message in their reject clauses; the
    %% writer clamps it to 512 bytes.
    Ev0b =
        case get(janus_error_detail) of
            D when is_binary(D) -> Ev0#{error_detail => D};
            _ -> Ev0
        end,
    Ev = Ev0b#{
        provider_id => maps:get(provider_id, Route, null),
        provider_key_id =>
            case maps:get(provider_key, Route, undefined) of
                #{id := Kid} -> Kid;
                _ -> null
            end,
        request_id => ReqId,
        request_ref =>
            case get(janus_failover_ref) of
                Ref when is_binary(Ref) -> Ref;
                _ -> null
            end,
        trace_id => janus_trace:trace_id(get(janus_trace))
    },
    case {get(janus_quota_charge_id), maps:get(agent_key_id, Ev, null)} of
        {Cid, Aid} when is_binary(Cid), is_integer(Aid) ->
            _ = janus_quota:charge_tokens(
                Cid, Aid, maps:get(prompt, Ev, null), maps:get(completion, Ev, null)
            );
        _ ->
            ok
    end,
    _ = janus_usage:record(Ev),
    ok.

reply_model_not_allowed(Req) ->
    Code = <<"model_not_allowed">>,
    case get(janus_req_counted) of
        true ->
            ok;
        _ ->
            put(janus_req_counted, true),
            janus_metrics:inc(requests_total, #{
                endpoint => janus_http_classify:endpoint(cowboy_req:path(Req)),
                protocol => janus_http_classify:protocol(cowboy_req:path(Req)),
                status_class => <<"4xx">>
            })
    end,
    logger:warning(#{
        what => janus_agent_reject,
        status => 403,
        code => Code,
        model => get(janus_req_model),
        method => cowboy_req:method(Req),
        path => cowboy_req:path(Req),
        request_id => get(janus_request_id)
    }),
    Body = thoas:encode(#{
        error => #{
            message => <<"model not in allowlist">>,
            type => <<"janus_error">>,
            code => Code
        }
    }),
    janus_downstream_enc:reply(
        403, #{<<"content-type">> => <<"application/json">>}, Body, Req
    ).

reply_quota_modality(Req, _State, Kind, Sec) ->
    Code = janus_quota:kind_code(Kind),
    case get(janus_req_counted) of
        true ->
            ok;
        _ ->
            put(janus_req_counted, true),
            janus_metrics:inc(requests_total, #{
                endpoint => janus_http_classify:endpoint(cowboy_req:path(Req)),
                protocol => janus_http_classify:protocol(cowboy_req:path(Req)),
                status_class => <<"4xx">>
            })
    end,
    logger:warning(#{
        what => janus_agent_reject,
        status => 429,
        code => Code,
        method => cowboy_req:method(Req),
        path => cowboy_req:path(Req),
        request_id => get(janus_request_id)
    }),
    Body = thoas:encode(#{
        error => #{
            message => <<"agent key quota exceeded (", Code/binary, ")">>,
            type => <<"janus_error">>,
            code => Code
        }
    }),
    janus_downstream_enc:reply(
        429,
        #{
            <<"content-type">> => <<"application/json">>,
            <<"retry-after">> => integer_to_binary(Sec)
        },
        Body,
        Req
    ).
