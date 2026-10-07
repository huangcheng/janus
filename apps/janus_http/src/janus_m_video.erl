%%%-------------------------------------------------------------------
%%% @doc Video modality plugin (spec M3, V1 SCOPE — read the
%%% deviations list before extending).
%%%
%%% Canonical wire = OpenAI /v1/videos. Three surfaces behind one
%%% cowboy route pair (`/v1/videos` + `/v1/videos/[...]`, dispatched on
%%% method + path_info):
%%%
%%%   POST   /v1/videos          submit. The body passes through minus
%%%                              gateway-owned fields (`stream` — the
%%%                              sync/async mode is a provider
%%%                              property read off the RESPONSE, never
%%%                              a client switch). Reply-mode
%%%                              classification:
%%%                                - upstream content-type
%%%                                  text/event-stream -> SYNC: the
%%%                                  upstream SSE body is streamed to
%%%                                  the client as-is (lazy by
%%%                                  construction — upstream_post
%%%                                  buffers, so the first client byte
%%%                                  exists only after the upstream
%%%                                  responded);
%%%                                - 2xx JSON carrying `status` (+ an
%%%                                  `id`) -> ASYNC: reply
%%%                                  `{jvid, status: "queued"}` where
%%%                                  jvid is the self-routing HMAC id
%%%                                  minted by janus_jvid.
%%%   GET    /v1/videos/{jvid}   poll. jvid parse + HMAC verify +
%%%                              expiry, owner check (mismatch -> 404,
%%%                              no existence leak), then a
%%%                              provider-bound upstream GET (the
%%%                              route is rebuilt from the jvid's
%%%                              provider_id — polls NEVER re-enter the
%%%                              LB and never failover). 2xx upstream
%%%                              bodies pass through byte-for-byte;
%%%                              upstream 404 -> local 404 job_not_found.
%%%   DELETE /v1/videos/{jvid}   cancel. v1 answers
%%%                              `{status: "cancelled"}` locally — the
%%%                              best-effort upstream cancel is
%%%                              DEFERRED (deviation list).
%%%
%%% Usage: one submit row per accepted submit (modality <<"video">>,
%%% status 200, units null, NO outcome — the terminal outcome lands
%%% with the video_jobs persistence follow-up). Polls and cancels
%%% write nothing (spec M3.3).
%%%
%%% V1 DEVIATIONS vs spec M3 (all land with the leader-bootstrap +
%%% SSE-envelope follow-ups):
%%%   - video_jobs persistence, nightly sweep, SSE progress synthesis
%%%     and Accept-upgrade polls: DEFERRED. Migration 011 ships the
%%%     empty table for forward compat only.
%%%   - GET /v1/videos/{jvid}/content: DEFERRED (501).
%%%   - DELETE: local-only cancel (no upstream call).
%%%   - Submit/poll upstream budgets pinned at 30s (spec A5 budgets
%%%     are idle-timeout-relative — 270s pre-accept; they arrive with
%%%     the per-request gun budget work).
%%%   - Single upstream attempt per submit, no pre-accept failover
%%%     (same v1 posture as TTS; A6's commit point — upstream accept —
%%%     is honored: no retry after a 2xx).
%%%   - Poll key pick = first enabled provider key (LB-managed poll
%%%     key selection lands later).
%%%   - jvid secret: cookie-derived deterministic dev mint when the
%%%     settings key is absent (janus_jvid doc); leader bootstrap is
%%%     the follow-up.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_m_video).

-export([
    modality/0,
    max_body/0,
    process/5,
    %% Pure surface (eunit, spec M3.1/M3.2)
    exp_seconds/0,
    classify_submit/2,
    build_submit_request/1,
    owner_matches/2,
    poll_outcome/2,
    map_jvid_error/1,
    relay_error_body/1
]).

-define(MAX_BODY, 5 * 1024 * 1024).
%% Spec-pinned v1 budgets (deviation list above).
-define(SUBMIT_MS, 30_000).
-define(POLL_MS, 30_000).
-define(DEFAULT_EXP_SECONDS, 86400).
-define(RELAY_MSG_CAP, 500).

%%%--------------------------------------------------------------------
%% Plugin contract (janus_modality behaviour surface)
%%%--------------------------------------------------------------------

-spec modality() -> binary().
modality() ->
    <<"video">>.

-spec max_body() -> pos_integer().
max_body() ->
    ?MAX_BODY.

-spec process(
    cowboy_req:req(), term(), map(), binary(), map()
) -> {ok, cowboy_req:req(), term()}.
process(Req, State, Agent, Body, _Meta) ->
    Method = cowboy_req:method(Req),
    %% The exact "/v1/videos" route has no path_info (undefined); only
    %% the "[...]" route carries a list. Normalize so POST submits.
    PathInfo = case cowboy_req:path_info(Req) of
        undefined -> [];
        PI -> PI
    end,
    dispatch(Method, PathInfo, Req, State, Agent, Body).

%%%--------------------------------------------------------------------
%% Method/path dispatch (path_info rides the [...]-route)
%%%--------------------------------------------------------------------

dispatch(<<"POST">>, [], Req, State, Agent, Body) ->
    submit(Req, State, Agent, Body);
dispatch(<<"GET">>, [Jvid], Req, State, Agent, _Body) ->
    poll(Jvid, Req, State, Agent);
dispatch(<<"DELETE">>, [Jvid], Req, State, Agent, _Body) ->
    cancel(Jvid, Req, State, Agent);
dispatch(<<"GET">>, [_Jvid, <<"content">>], Req, State, _Agent, _Body) ->
    %% M3.2d deferral (see module doc).
    reply(
        Req,
        State,
        501,
        error_envelope(
            <<"video content download lands with the persistence follow-up">>,
            <<"not_implemented">>
        )
    );
dispatch(_Method, _PathInfo, Req, State, _Agent, _Body) ->
    reply(
        Req,
        State,
        405,
        error_envelope(
            <<"method not allowed on this video endpoint">>,
            <<"method_not_allowed">>
        )
    ).

%%%--------------------------------------------------------------------
%% POST /v1/videos — submit
%%%--------------------------------------------------------------------

submit(Req, State, Agent, Body) ->
    Started = erlang:monotonic_time(millisecond),
    case janus_modality:parse_json(Body) of
        {ok, Map} ->
            case janus_modality:model_of(Map) of
                undefined ->
                    reply(
                        Req, State, 400,
                        error_envelope(<<"model is required">>, <<"invalid_request">>)
                    );
                Model ->
                    %% Same pdict contract as the chat proxy: set
                    %% BEFORE any upstream call so logging/usage see it.
                    put(janus_req_model, Model),
                    handle_model(Model, Agent, Map, Req, State, Started)
            end;
        {error, bad_json} ->
            reply(
                Req,
                State,
                400,
                error_envelope(<<"request body is not a valid JSON object">>, <<"invalid_json">>)
            )
    end.

handle_model(Model, Agent, Map, Req, State, Started) ->
    case janus_modality:check_modality(<<"video">>, Model) of
        {error, Msg} ->
            reply(Req, State, 400, error_envelope(Msg, <<"wrong_modality">>));
        ok ->
            case janus_modality:pick_route(Model) of
                {ok, Route} ->
                    call_upstream(Route, Agent, Model, Map, Req, State, Started);
                {error, Reason} ->
                    {Status, Code, Msg, Extra} = pick_error(Reason),
                    Req1 = apply_headers(Extra, Req),
                    reply(Req1, State, Status, error_envelope(Msg, Code))
            end
    end.

call_upstream(Route, Agent, Model, Map, Req, State, Started) ->
    Reply =
        janus_modality:upstream_post(
            Route,
            <<"/videos">>,
            build_submit_request(Map),
            #{timeout_ms => ?SUBMIT_MS}
        ),
    finish_submit(Reply, Route, Agent, Model, Req, State, Started).

finish_submit(
    {ok, Status, Headers, RespBody}, Route, Agent, Model, Req, State, Started
) when Status >= 200, Status < 300 ->
    case classify_submit(Headers, RespBody) of
        {sync, SseBody} ->
            %% Upstream accepted (A6): record BEFORE the first client
            %% byte, then emit the buffered SSE body verbatim.
            record_submitted(Status, Route, Agent, Started),
            CT = maps:get(<<"content-type">>, Headers, <<"text/event-stream">>),
            Req1 = cowboy_req:stream_reply(Status, #{<<"content-type">> => CT}, Req),
            _ = cowboy_req:stream_body(SseBody, fin, Req1),
            {ok, Req1, State};
        {async, UpstreamId} ->
            record_submitted(Status, Route, Agent, Started),
            Exp = erlang:system_time(second) + exp_seconds(),
            case
                janus_jvid:encode(
                    UpstreamId,
                    maps:get(provider_id, Route),
                    Model,
                    maps:get(id, Agent, null),
                    Exp
                )
            of
                {ok, Jvid} ->
                    reply(Req, State, 200, #{<<"jvid">> => Jvid, <<"status">> => <<"queued">>});
                {error, _} ->
                    %% Fail-closed (spec A5): a job we cannot sign is a
                    %% local 500, never an unsigned id.
                    reply(
                        Req,
                        State,
                        500,
                        error_envelope(
                            <<"jvid secret unavailable on this gateway">>,
                            <<"jvid_no_secret">>
                        )
                    )
            end;
        {error, unclassifiable} ->
            record_failed(502, Route, Agent, Started),
            reply(
                Req,
                State,
                502,
                error_envelope(
                    <<"upstream 2xx submit reply carries neither an SSE stream nor a queued job">>,
                    <<"upstream_bad_reply">>
                )
            )
    end;
%% Any non-2xx (incl. errors) relays the upstream error body.
finish_submit({ok, Status, _Headers, RespBody}, Route, Agent, _Model, Req, State, Started) ->
    record_failed(Status, Route, Agent, Started),
    case relay_error_body(RespBody) of
        {json, Raw} ->
            janus_modality:reply_bytes(Req, State, Status, <<"application/json">>, Raw);
        {envelope, Msg} ->
            reply(Req, State, Status, error_envelope(Msg, <<"upstream_error">>))
    end;
finish_submit({error, Reason}, Route, Agent, _Model, Req, State, Started) ->
    logger:warning(#{what => janus_video_upstream_error, reason => Reason}),
    record_failed(502, Route, Agent, Started),
    reply(
        Req,
        State,
        502,
        error_envelope(<<"upstream request failed">>, <<"upstream_unreachable">>)
    ).

%%%--------------------------------------------------------------------
%% GET /v1/videos/{jvid} — poll (provider-bound, never fails over)
%%%--------------------------------------------------------------------

poll(JvidRaw, Req, State, Agent) ->
    case janus_jvid:parse(JvidRaw) of
        {ok, J} ->
            case owner_matches(Agent, J) of
                false ->
                    %% No existence leak: a foreign id is
                    %% indistinguishable from an unknown one.
                    reply(Req, State, 404, not_found_envelope());
                true ->
                    do_poll(J, Req, State)
            end;
        {error, Reason} ->
            reply_jvid_error(Reason, Req, State)
    end.

do_poll(#{upstream_id := UpId} = J, Req, State) ->
    case route_for_provider(J) of
        {ok, Route} ->
            Path = <<"/videos/", UpId/binary>>,
            case upstream_get(Route, Path, ?POLL_MS) of
                {ok, Status, Headers, Body} ->
                    render_poll(poll_outcome(Status, Body), Status, Headers, Req, State);
                {error, Reason} ->
                    logger:warning(#{what => janus_video_poll_upstream_error, reason => Reason}),
                    reply(
                        Req,
                        State,
                        502,
                        error_envelope(<<"upstream request failed">>, <<"upstream_unreachable">>)
                    )
            end;
        {error, no_key} ->
            reply(
                Req,
                State,
                503,
                error_envelope(
                    <<"provider has no usable key for this job">>,
                    <<"provider_disabled">>
                )
            );
        {error, provider_not_found} ->
            reply(Req, State, 404, not_found_envelope())
    end.

render_poll({passthrough, Body}, Status, Headers, Req, State) ->
    CT = maps:get(<<"content-type">>, Headers, <<"application/json">>),
    janus_modality:reply_bytes(Req, State, Status, CT, Body);
render_poll(job_not_found, _Status, _Headers, Req, State) ->
    reply(Req, State, 404, not_found_envelope());
render_poll({relay, RStatus, RBody}, _Status, _Headers, Req, State) ->
    case relay_error_body(RBody) of
        {json, Raw} ->
            janus_modality:reply_bytes(Req, State, RStatus, <<"application/json">>, Raw);
        {envelope, Msg} ->
            reply(Req, State, RStatus, error_envelope(Msg, <<"upstream_error">>))
    end.

%%%--------------------------------------------------------------------
%% DELETE /v1/videos/{jvid} — local cancel (v1 deviation)
%%%--------------------------------------------------------------------

cancel(JvidRaw, Req, State, Agent) ->
    case janus_jvid:parse(JvidRaw) of
        {ok, J} ->
            case owner_matches(Agent, J) of
                false ->
                    reply(Req, State, 404, not_found_envelope());
                true ->
                    reply(Req, State, 200, #{<<"status">> => <<"cancelled">>})
            end;
        {error, Reason} ->
            reply_jvid_error(Reason, Req, State)
    end.

%%%--------------------------------------------------------------------
%% Pure surface (eunit-covered; production shapes = JSON-decoded
%% binary keys, gun-style lowercase header maps)
%%%--------------------------------------------------------------------

%% jvid TTL knob (spec A5: default 24h, settings override via
%% persistent_term, direct-PT convention).
-spec exp_seconds() -> pos_integer().
exp_seconds() ->
    case persistent_term:get({janus, jvid_exp_seconds}, undefined) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_EXP_SECONDS
    end.

%% Canonical -> upstream submit body: the client map minus gateway-
%% owned fields. `stream` is gateway vocabulary (mode is read off the
%% upstream RESPONSE) and would flip providers unpredictably.
-spec build_submit_request(map()) -> map().
build_submit_request(Map) when is_map(Map) ->
    maps:remove(<<"stream">>, Map);
build_submit_request(Other) ->
    Other.

%% Reply-mode classification (A5: the response content-type always
%% tells the client what happened). SSE content-type -> {sync, Body}
%% (body passed through verbatim, never parsed here). JSON carrying
%% `status` + a non-empty `id` -> {async, UpstreamId}. Anything else
%% on a 2xx is a broken upstream -> {error, unclassifiable}.
-spec classify_submit(map(), binary()) ->
    {sync, binary()} | {async, binary()} | {error, unclassifiable}.
classify_submit(Headers, Body) when is_map(Headers), is_binary(Body) ->
    case is_sse_ct(Headers) of
        true ->
            {sync, Body};
        false ->
            case janus_modality:parse_json(Body) of
                {ok, #{<<"id">> := Id, <<"status">> := _Status}} when
                    is_binary(Id), Id =/= <<>>
                ->
                    {async, Id};
                _ ->
                    {error, unclassifiable}
            end
    end.

is_sse_ct(Headers) ->
    case Headers of
        #{<<"content-type">> := CT} when is_binary(CT) ->
            [Main | _] = binary:split(CT, <<";">>),
            string:trim(string:lowercase(Main), both, " \t") =:= <<"text/event-stream">>;
        _ ->
            false
    end.

%% Owner check: the jvid's agent_key_id segment vs the AUTHENTICATED
%% agent's id (catalog ids are integers; jvid segments are binaries).
-spec owner_matches(map(), map()) -> boolean().
owner_matches(Agent, J) when is_map(Agent), is_map(J) ->
    case {Agent, J} of
        {#{id := Id}, #{agent_key_id := AKey}} -> id_to_bin(Id) =:= AKey;
        _ -> false
    end;
owner_matches(_, _) ->
    false.

id_to_bin(Id) when is_integer(Id) -> integer_to_binary(Id);
id_to_bin(Id) when is_binary(Id) -> Id;
id_to_bin(_) -> undefined.

%% Poll mapping: 2xx passes the body through untouched; upstream 404
%% is the canonical job_not_found; anything else relays.
-spec poll_outcome(pos_integer(), binary()) ->
    {passthrough, binary()} | job_not_found | {relay, pos_integer(), binary()}.
poll_outcome(Status, Body) when is_integer(Status), Status >= 200, Status < 300 ->
    {passthrough, Body};
poll_outcome(404, _Body) ->
    job_not_found;
poll_outcome(Status, Body) when is_integer(Status), is_binary(Body) ->
    {relay, Status, Body}.

%% jvid codec error -> {http status, canonical code}.
-spec map_jvid_error(term()) -> {pos_integer(), binary()}.
map_jvid_error(no_secret) -> {500, <<"jvid_no_secret">>};
map_jvid_error(bad_format) -> {400, <<"bad_jvid">>};
map_jvid_error(bad_hmac) -> {400, <<"bad_jvid">>};
map_jvid_error(unknown_keyid) -> {404, <<"job_unknown_key">>};
map_jvid_error(job_expired) -> {404, <<"job_expired">>};
map_jvid_error(_) -> {400, <<"bad_jvid">>}.

%% Classify an upstream error body for relay (same rules as images):
%% valid JSON passes through byte-for-byte; anything else becomes the
%% canonical envelope message (capped).
-spec relay_error_body(binary()) -> {json, binary()} | {envelope, binary()}.
relay_error_body(Body) when is_binary(Body) ->
    case janus_modality:parse_json(Body) of
        {ok, _} ->
            {json, Body};
        {error, bad_json} ->
            case byte_size(Body) of
                0 -> {envelope, <<"upstream error">>};
                N when N > ?RELAY_MSG_CAP ->
                    {envelope, <<(binary:part(Body, 0, ?RELAY_MSG_CAP))/binary, "...">>};
                _ ->
                    {envelope, Body}
            end
    end.

%%%--------------------------------------------------------------------
%% LB pick error -> {status, code, message, extra headers} (mirrors
%% the chat proxy + images plugin).
%%%--------------------------------------------------------------------

-spec pick_error(term()) -> {pos_integer(), binary(), binary(), #{binary() => binary()}}.
pick_error(no_route) ->
    {404, <<"no_route">>, <<"no route for model">>, #{}};
pick_error(provider_disabled) ->
    {503, <<"provider_disabled">>, <<"provider disabled">>, #{}};
pick_error(catalog_not_ready) ->
    {503, <<"catalog_not_ready">>, <<"catalog not ready">>, #{<<"retry-after">> => <<"1">>}};
pick_error({all_cooling, Ms}) when is_integer(Ms), Ms > 0 ->
    Secs = max(1, min(Ms, 300000) div 1000),
    {503, <<"all_cooling">>, <<"all routes cooling down">>, #{
        <<"retry-after">> => integer_to_binary(Secs)
    }};
pick_error({all_cooling, _}) ->
    {503, <<"all_cooling">>, <<"all routes cooling down">>, #{<<"retry-after">> => <<"5">>}};
pick_error(_) ->
    {404, <<"no_route">>, <<"no route for model">>, #{}}.

%%%--------------------------------------------------------------------
%% Internals
%%%--------------------------------------------------------------------

reply_jvid_error(Reason, Req, State) ->
    {Status, Code} = map_jvid_error(Reason),
    reply(Req, State, Status, error_envelope(jvid_msg(Reason), Code)).

jvid_msg(no_secret) -> <<"jvid secret unavailable on this gateway">>;
jvid_msg(unknown_keyid) -> <<"video job id was signed with an unknown key">>;
jvid_msg(job_expired) -> <<"video job id has expired">>;
jvid_msg(_) -> <<"malformed video job id">>.

not_found_envelope() ->
    error_envelope(<<"no video found with this id">>, <<"job_not_found">>).

error_envelope(Msg, Code) when is_binary(Msg), is_binary(Code) ->
    #{error => #{message => Msg, type => <<"janus_error">>, code => Code}}.

%% Provider-bound route rebuild for polls/cancels: base_url + the
%% first enabled provider key. Deliberately NOT the LB (spec A5: polls
%% never failover; the job is bound at submit) — and deliberately not
%% gated on the provider's `enabled` flag (a mid-job disable must not
%% strand the id; hot-reload honors the binding).
route_for_provider(#{provider_id := PidBin}) ->
    case int_of(PidBin) of
        {ok, Pid} ->
            case janus_catalog:lookup_provider(Pid) of
                {ok, #{base_url := _}} ->
                    Keys = [K || K <- janus_catalog:provider_keys(Pid), maps:get(enabled, K, true)],
                    case Keys of
                        [Key | _] -> {ok, #{provider_id => Pid, provider_key => Key}};
                        [] -> {error, no_key}
                    end;
                _ ->
                    {error, provider_not_found}
            end;
        error ->
            {error, provider_not_found}
    end;
route_for_provider(_) ->
    {error, provider_not_found}.

int_of(B) when is_binary(B) ->
    try
        {ok, binary_to_integer(B)}
    catch
        _:_ -> error
    end;
int_of(I) when is_integer(I) ->
    {ok, I};
int_of(_) ->
    error.

%% GET twin of janus_modality:upstream_post (same resolve chain:
%% provider base_url, key decrypt, base parse, path join) over the
%% janus_providers_http:get/3 transport.
upstream_get(Route, PathSuffix, TimeoutMs) ->
    case janus_catalog:lookup_provider(maps:get(provider_id, Route)) of
        {ok, #{base_url := BaseUrl0}} ->
            case janus_providers_http:decrypt_key(maps:get(provider_key, Route, undefined)) of
                {ok, Token} ->
                    case
                        janus_providers_http:parse_base(iolist_to_binary(BaseUrl0))
                    of
                        {ok, Host, Port, BasePath, Tls} ->
                            Path = janus_providers_http:join_path(BasePath, PathSuffix),
                            Headers = [
                                {<<"authorization">>, <<"Bearer ", Token/binary>>},
                                {<<"accept">>, <<"application/json">>},
                                {<<"user-agent">>, janus_providers_http:user_agent()}
                            ],
                            janus_providers_http:get(
                                #{host => Host, port => Port, path => Path, tls => Tls},
                                Headers,
                                TimeoutMs
                            );
                        {error, _} = Err ->
                            Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        error ->
            {error, provider_not_found}
    end.

%% Submit usage row: outcome is intentionally ABSENT (terminal outcome
%% lands with the video_jobs follow-up); units null (video-seconds are
%% only known at terminal).
record_submitted(Status, Route, Agent, Started) ->
    janus_modality:record_usage(
        #{
            ts => erlang:system_time(second),
            status => Status,
            modality => <<"video">>,
            units => null,
            agent_key_id => maps:get(id, Agent, null),
            model_id => maps:get(model_id, Route, null),
            latency_ms => erlang:monotonic_time(millisecond) - Started
        },
        Route
    ).

record_failed(Status, Route, Agent, Started) ->
    janus_modality:record_usage(
        #{
            ts => erlang:system_time(second),
            status => Status,
            modality => <<"video">>,
            units => null,
            outcome => <<"failed">>,
            agent_key_id => maps:get(id, Agent, null),
            model_id => maps:get(model_id, Route, null),
            latency_ms => erlang:monotonic_time(millisecond) - Started
        },
        Route
    ).

apply_headers(Headers, Req) ->
    maps:fold(
        fun(H, V, R) -> cowboy_req:set_resp_header(H, V, R) end,
        Req,
        Headers
    ).

reply(Req, State, Status, Map) ->
    janus_modality:reply_json(Req, State, Status, Map).
