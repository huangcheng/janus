%%%-------------------------------------------------------------------
%%% @doc Images modality plugin (spec M1.2): POST /v1/images/generations.
%%
%% Canonical wire = OpenAI images generations. Two translator faces,
%% selected by the ROUTE's provider NAME (catalog `providers.name`):
%%  - <<"minimax">>: native translator, POST /v1/image_generation —
%%    request {model, prompt, n, response_format, aspect_ratio?};
%%    reply {id, data.image_urls, metadata counts, base_resp} where
%%    base_resp.status_code is an INTEGER (0 = ok) but the metadata
%%    counts arrive as JSON STRINGS in production captures (see
%%    test/fixtures/probes/minimax_t2i_*.json — both are normalized).
%%  - every other provider: OpenAI-shaped passthrough on
%%    /images/generations with the canonical body minus gateway-only
%%    fields (`aspect_ratio` is minimax vocabulary).
%%
%% Pre-flight caps (400 BEFORE spend, spec Contracts): n integer 1..9
%% (default 1), prompt non-empty, response_format url|b64_json
%% (default url), size per the per-provider predicate valid_size/2.
%% wrong_modality / no_route / provider_disabled / all_cooling map
%% like the chat proxy. Usage rows: modality <<"image">>, units = n.
%% @end
%%%-------------------------------------------------------------------
-module(janus_m_images).

-export([modality/0, max_body/0, process/5]).

%% Pure translators + validation (exported for eunit, spec M1.2).
-export([
    validate_for/2,
    valid_size/2,
    build_minimax_request/1,
    build_passthrough_request/1,
    normalize_minimax_reply/2,
    relay_error_body/1,
    pick_error/1,
    error_envelope/2
]).

-define(MAX_BODY, 10 * 1024 * 1024).
-define(UPSTREAM_MS, 180_000).
-define(RELAY_MSG_CAP, 500).

%%%--------------------------------------------------------------------
%% Plugin contract (janus_modality behaviour surface)
%%%--------------------------------------------------------------------

-spec modality() -> binary().
modality() ->
    <<"image">>.

-spec max_body() -> pos_integer().
max_body() ->
    ?MAX_BODY.

-spec process(
    cowboy_req:req(), term(), map(), binary(), map()
) -> {ok, cowboy_req:req(), term()}.
process(Req, State, Agent, Body, _Meta) ->
    case json_body(Body) of
        {ok, Map} when is_map(Map) ->
            case janus_modality:model_of(Map) of
                undefined ->
                    reply(Req, State, 400, error_envelope(
                        <<"model is required">>, <<"invalid_request">>
                    ));
                Model ->
                    %% Same pdict contract as the chat proxy: set
                    %% BEFORE any upstream call so logging/usage see it.
                    put(janus_req_model, Model),
                    handle_model(Model, Agent, Map, Req, State)
            end;
        _ ->
            reply(Req, State, 400, error_envelope(
                <<"request body is not a valid JSON object">>, <<"invalid_json">>
            ))
    end.

%%%--------------------------------------------------------------------
%% Request flow
%%%--------------------------------------------------------------------

handle_model(Model, Agent, Map, Req, State) ->
    case janus_modality:check_modality(<<"image">>, Model) of
        {error, Msg} ->
            reply(Req, State, 400, error_envelope(Msg, <<"wrong_modality">>));
        ok ->
            case janus_modality:pick_route(Model) of
                {ok, Route} ->
                    preflight(provider_name(Route), Route, Agent, Map, Req, State);
                {error, Reason} ->
                    {Status, Code, Msg, Extra} = pick_error(Reason),
                    Req1 = apply_headers(Extra, Req),
                    reply(Req1, State, Status, error_envelope(Msg, Code))
            end
    end.

%% Pre-flight caps per provider table: 400 BEFORE any upstream spend.
preflight(ProviderName, Route, Agent, Map, Req, State) ->
    case validate_for(ProviderName, Map) of
        {error, Msg} ->
            reply(Req, State, 400, error_envelope(Msg, <<"invalid_request">>));
        {ok, N} ->
            Started = erlang:monotonic_time(millisecond),
            call_upstream(ProviderName, Route, Agent, Map, N, Started, Req, State)
    end.

call_upstream(<<"minimax">>, Route, Agent, Map, N, Started, Req, State) ->
    Reply =
        janus_modality:upstream_post(
            Route,
            <<"/image_generation">>,
            build_minimax_request(Map),
            #{timeout_ms => ?UPSTREAM_MS}
        ),
    finish_minimax(Reply, Route, Agent, N, Started, Req, State);
call_upstream(_OpenAIshapedProvider, Route, Agent, Map, N, Started, Req, State) ->
    Reply =
        janus_modality:upstream_post(
            Route,
            <<"/images/generations">>,
            build_passthrough_request(Map),
            #{timeout_ms => ?UPSTREAM_MS}
        ),
    finish_passthrough(Reply, Route, Agent, N, Started, Req, State).

%%%--------------------------------------------------------------------
%% minimax native face
%%%--------------------------------------------------------------------

finish_minimax({ok, UpStatus, _Headers, RespBody}, Route, Agent, N, Started, Req, State) ->
    case json_body(RespBody) of
        {ok, Up} when is_map(Up) ->
            case normalize_minimax_reply(Up, UpStatus) of
                {ok, Canon} ->
                    record(200, Route, Agent, N, <<"completed">>, Started),
                    reply(Req, State, 200, Canon);
                {partial, Canon, _Failed} ->
                    record(200, Route, Agent, N, <<"completed">>, Started),
                    reply(Req, State, 200, Canon);
                {error, EStatus, EMsg} ->
                    record(EStatus, Route, Agent, N, <<"failed">>, Started),
                    reply(Req, State, EStatus, error_envelope(EMsg, <<"upstream_error">>))
            end;
        _ ->
            %% 2xx-shaped transport with a non-JSON body: broken upstream.
            record(502, Route, Agent, N, <<"failed">>, Started),
            reply(Req, State, 502, error_envelope(
                <<"upstream replied with a non-JSON body">>, <<"upstream_error">>
            ))
    end;
finish_minimax({error, Reason}, Route, Agent, N, Started, Req, State) ->
    record(502, Route, Agent, N, <<"failed">>, Started),
    reply(Req, State, 502, error_envelope(sanitize_reason(Reason), <<"upstream_error">>)).

%%%--------------------------------------------------------------------
%% OpenAI-shaped passthrough face
%%%--------------------------------------------------------------------

finish_passthrough({ok, Status, _Headers, RespBody}, Route, Agent, N, Started, Req, State) when
    Status >= 200, Status < 300
->
    case json_body(RespBody) of
        {ok, Up} when is_map(Up) ->
            %% Canonical already: re-emit parsed JSON as-is.
            record(Status, Route, Agent, N, <<"completed">>, Started),
            reply(Req, State, Status, Up);
        _ ->
            record(502, Route, Agent, N, <<"failed">>, Started),
            reply(Req, State, 502, error_envelope(
                <<"upstream replied with a non-JSON body">>, <<"upstream_error">>
            ))
    end;
%% Any non-2xx (>=300, incl. errors) relays the upstream error body.
finish_passthrough({ok, Status, _Headers, RespBody}, Route, Agent, N, Started, Req, State) ->
    %% Relay the upstream error body with its status; canonical
    %% envelope when the body is not JSON (dashscope probes 404 empty).
    record(Status, Route, Agent, N, <<"failed">>, Started),
    case relay_error_body(RespBody) of
        {json, Raw} ->
            janus_modality:reply_bytes(Req, State, Status, <<"application/json">>, Raw);
        {envelope, Msg} ->
            reply(Req, State, Status, error_envelope(Msg, <<"upstream_error">>))
    end;
finish_passthrough({error, Reason}, Route, Agent, N, Started, Req, State) ->
    record(502, Route, Agent, N, <<"failed">>, Started),
    reply(Req, State, 502, error_envelope(sanitize_reason(Reason), <<"upstream_error">>)).

%%%--------------------------------------------------------------------
%% Pure translators (eunit-covered; production shapes = JSON-decoded
%% binary keys)
%%%--------------------------------------------------------------------

%% Pre-flight validation for one provider: returns the effective n
%% (the usage unit) or a 400 message. Checks prompt (required,
%% non-empty binary), n (integer 1..9, default 1), response_format
%% (url|b64_json, default url) and size (per-provider predicate —
%% SKIPPED for minimax, which takes aspect_ratio instead).
-spec validate_for(binary(), map()) -> {ok, 1..9} | {error, binary()}.
validate_for(ProviderName, Map) when is_binary(ProviderName), is_map(Map) ->
    case prompt_error(Map) of
        ok ->
            case n_of(maps:get(<<"n">>, Map, 1)) of
                {ok, N} ->
                    case rf_of(maps:get(<<"response_format">>, Map, <<"url">>)) of
                        ok ->
                            case valid_size(ProviderName, maps:get(<<"size">>, Map, undefined)) of
                                true -> {ok, N};
                                false -> {error, size_msg(ProviderName)}
                            end;
                        {error, Msg} ->
                            {error, Msg}
                    end;
                {error, Msg} ->
                    {error, Msg}
            end;
        {error, Msg} ->
            {error, Msg}
    end.

prompt_error(Map) ->
    case Map of
        #{<<"prompt">> := P} when is_binary(P), P =/= <<>> -> ok;
        _ -> {error, <<"prompt is required and must be a non-empty string">>}
    end.

n_of(N) when is_integer(N), N >= 1, N =< 9 -> {ok, N};
n_of(_) -> {error, <<"n must be an integer between 1 and 9">>}.

rf_of(<<"url">>) -> ok;
rf_of(<<"b64_json">>) -> ok;
rf_of(_) -> {error, <<"response_format must be one of: url, b64_json">>}.

size_msg(_ProviderName) ->
    <<"size is not supported by this provider">>.

%% Per-provider size predicate table (spec M1.2 pre-flight caps):
%%  - <<"minimax">> ignores `size` entirely (aspect_ratio instead);
%%  - default (OpenAI-shaped): the classic three-square enum;
%%  - wxh_providers() additionally accept any WxH whose sides are
%%    positive multiples of 8 (the qwen-image family's free sizes).
-spec valid_size(binary(), term()) -> boolean().
valid_size(<<"minimax">>, _Size) ->
    true;
valid_size(ProviderName, undefined) when is_binary(ProviderName) ->
    true;
valid_size(ProviderName, Size) when is_binary(ProviderName) ->
    square_enum(Size) orelse
        (lists:member(ProviderName, wxh_providers()) andalso wxh_size(Size)).

wxh_providers() ->
    [<<"dashscope">>].

square_enum(<<"256x256">>) -> true;
square_enum(<<"512x512">>) -> true;
square_enum(<<"1024x1024">>) -> true;
square_enum(_) -> false.

wxh_size(Size) when is_binary(Size) ->
    case binary:split(Size, <<"x">>) of
        [W, H] ->
            case {dim(W), dim(H)} of
                {{ok, WI}, {ok, HI}} ->
                    WI > 0 andalso HI > 0 andalso WI rem 8 =:= 0 andalso HI rem 8 =:= 0;
                _ ->
                    false
            end;
        _ ->
            false
    end;
wxh_size(_) ->
    false.

dim(D) ->
    try
        {ok, binary_to_integer(D)}
    catch
        _:_ -> error
    end.

%% canonical -> minimax native: exactly the fields minimax accepts —
%% model/prompt/n/response_format plus aspect_ratio when the client
%% sent one (minimax's orientation knob; `size` has no equivalent and
%% is dropped, quality/style/user are gateway-side noise).
-spec build_minimax_request(map()) -> map().
build_minimax_request(Map) when is_map(Map) ->
    M0 = maps:with([<<"model">>, <<"prompt">>, <<"n">>, <<"response_format">>], Map),
    case Map of
        #{<<"aspect_ratio">> := AR} -> M0#{<<"aspect_ratio">> => AR};
        _ -> M0
    end.

%% canonical -> OpenAI-shaped passthrough: the client body minus
%% gateway-only fields (`aspect_ratio` is minimax vocabulary and would
%% 400 upstream).
-spec build_passthrough_request(map()) -> map().
build_passthrough_request(Map) when is_map(Map) ->
    maps:remove(<<"aspect_ratio">>, Map).

%% minimax native -> canonical. Production captures (probes): counts
%% as JSON strings OR integers, status_code integer, urls under
%% data.image_urls. base_resp.status_code =/= 0 -> error with the
%% upstream HTTP status when it was 4xx/5xx, else 502. failed_count>0
%% with some successes -> partial success (note added, urls kept).
-spec normalize_minimax_reply(map(), pos_integer()) ->
    {ok, map()} | {partial, map(), non_neg_integer()} | {error, pos_integer(), binary()}.
normalize_minimax_reply(Up, UpStatus) when is_map(Up), is_integer(UpStatus) ->
    case int_of(base_resp_field(Up, <<"status_code">>)) of
        SC when SC =/= 0 ->
            {error, err_status(UpStatus), base_resp_msg(Up)};
        _ ->
            case image_urls(Up) of
                [] ->
                    {error, 502, base_resp_msg(Up)};
                Urls ->
                    Canon = #{
                        <<"created">> => erlang:system_time(second),
                        <<"data">> => [#{<<"url">> => U} || U <- Urls]
                    },
                    Failed = int_of(meta_field(Up, <<"failed_count">>)),
                    case is_integer(Failed) andalso Failed > 0 of
                        true -> {partial, Canon#{<<"note">> => partial_note(Failed)}, Failed};
                        false -> {ok, Canon}
                    end
            end
    end.

base_resp_field(Up, Key) ->
    case Up of
        #{<<"base_resp">> := BR} when is_map(BR) -> maps:get(Key, BR, undefined);
        _ -> undefined
    end.

base_resp_msg(Up) ->
    case base_resp_field(Up, <<"status_msg">>) of
        M when is_binary(M), M =/= <<>> -> M;
        _ -> <<"upstream error">>
    end.

meta_field(Up, Key) ->
    case Up of
        #{<<"metadata">> := Meta} when is_map(Meta) -> maps:get(Key, Meta, undefined);
        _ -> undefined
    end.

image_urls(Up) ->
    case Up of
        #{<<"data">> := Data} when is_map(Data) ->
            case Data of
                #{<<"image_urls">> := Urls} when is_list(Urls) ->
                    [U || U <- Urls, is_binary(U)];
                _ ->
                    []
            end;
        _ ->
            []
    end.

%% REAL captures ship string counts ("0") — accept integers too.
int_of(I) when is_integer(I) -> I;
int_of(B) when is_binary(B) ->
    try
        binary_to_integer(B)
    catch
        _:_ -> undefined
    end;
int_of(_) ->
    undefined.

err_status(S) when is_integer(S), S >= 400 -> S;
err_status(_) -> 502.

partial_note(Failed) when is_integer(Failed) ->
    iolist_to_binary([
        integer_to_binary(Failed),
        <<" of the requested images failed upstream and are missing from data">>
    ]).

%% Classify an upstream error body for relay: valid JSON (any shape)
%% passes through byte-for-byte with the upstream status; anything
%% else becomes the message of the canonical envelope (capped).
-spec relay_error_body(binary()) -> {json, binary()} | {envelope, binary()}.
relay_error_body(Body) when is_binary(Body) ->
    case json_body(Body) of
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

%% Strict JSON classification. thoas:decode/1 RETURNS {error,_}
%% tuples for invalid JSON (it does not throw), so a validity check
%% must match the tuple — wrapping it in {ok,_} (as a try/catch
%% around the call would) turns every decode error into a false
%% positive. Used everywhere this plugin must KNOW the body is JSON.
-spec json_body(binary()) -> {ok, term()} | {error, bad_json}.
json_body(Body) when is_binary(Body), byte_size(Body) > 0 ->
    case catch thoas:decode(Body) of
        {ok, Term} -> {ok, Term};
        _ -> {error, bad_json}
    end;
json_body(_) ->
    {error, bad_json}.

%% LB pick error -> {status, code, message, extra headers}. Mirrors the
%% chat proxy: 404 no_route, 503 for disabled/cooling/not-ready.
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

%% Canonical error envelope (same shape as the chat proxy's
%% error_map/3 for openai clients).
-spec error_envelope(binary(), binary()) -> map().
error_envelope(Msg, Code) when is_binary(Msg), is_binary(Code) ->
    #{error => #{message => Msg, type => <<"janus_error">>, code => Code}}.

%%%--------------------------------------------------------------------
%% Internals
%%%--------------------------------------------------------------------

provider_name(Route) ->
    case janus_catalog:lookup_provider(maps:get(provider_id, Route, undefined)) of
        {ok, #{name := Name}} when is_binary(Name) -> Name;
        _ -> <<>>
    end.

record(Status, Route, Agent, N, Outcome, Started) ->
    janus_modality:record_usage(
        #{
            status => Status,
            modality => <<"image">>,
            units => N,
            outcome => Outcome,
            latency_ms => erlang:monotonic_time(millisecond) - Started,
            agent_key_id => maps:get(id, Agent, null),
            model_id => maps:get(model_id, Route, null)
        },
        Route
    ).

sanitize_reason(Reason) ->
    Fmt = iolist_to_binary(io_lib:format("~p", [Reason])),
    binary:part(Fmt, 0, min(byte_size(Fmt), ?RELAY_MSG_CAP)).

apply_headers(Headers, Req) ->
    maps:fold(
        fun(H, V, R) -> cowboy_req:set_resp_header(H, V, R) end,
        Req,
        Headers
    ).

reply(Req, State, Status, Map) ->
    janus_modality:reply_json(Req, State, Status, Map).
