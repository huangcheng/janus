%%%-------------------------------------------------------------------
%%% @doc Modality plugin shared plumbing (spec M1.0).
%%
%% One cowboy entry (janus_http_modality) fronts every modality plugin.
%% A plugin implements:
%%   modality/0  -> <<"image">> | <<"tts">> | <<"asr">> | ...
%%   max_body/0  -> request byte cap (413 beyond)
%%   process/5   -> (Req, State, Agent, Body, Meta) -> {ok, Req, State}
%%
%% Shared here: agent auth, request id, body cap, JSON helpers, route
%% pick, the generic upstream JSON POST (provider key from the LB's
%% route), canonical error envelope, usage-row recording with
%% modality/units/outcome, and the wrong_modality guard.
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
    endpoint_for/1
]).

-define(DEFAULT_UPSTREAM_MS, 120_000).

%%--------------------------------------------------------------------
%% Entry (called by janus_http_modality:init/2)
%%--------------------------------------------------------------------

run(Plugin, Req0, State) ->
    case enabled(Plugin:modality()) of
        false ->
            reply_json(
                Req0,
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
            run_enabled(Plugin, Req0, State)
    end.

%% Knob check: settings key `modality` = {"image": true, ...} via
%% persistent_term {janus, modality_cfg}. Absent = OFF (shipped
%% default; the operator flips after gate+smoke).
enabled(Modality) when is_binary(Modality) ->
    case persistent_term:get({janus, modality_cfg}, undefined) of
        #{Modality := true} -> true;
        _ -> false
    end.

run_enabled(Plugin, Req0, State) ->
    ReqId = janus_request_id:resolve(cowboy_req:header(<<"x-request-id">>, Req0)),
    Req1 = cowboy_req:set_resp_header(<<"x-request-id">>, ReqId, Req0),
    put(janus_request_id, ReqId),
    case janus_http_auth:require_agent(Req1) of
        {ok, Agent, Req2} ->
            erase(janus_req_counted),
            erase(janus_quota_admitted),
            erase(janus_quota_charged),
            case janus_quota:admit(Agent) of
                ok ->
                    Max = Plugin:max_body(),
                    case cowboy_req:read_body(Req2, #{length => Max}) of
                        {ok, Body, Req3} ->
                            Meta = #{request_id => ReqId},
                            Plugin:process(Req3, State, Agent, Body, Meta);
                        {more, _, Req3} ->
                            reply_json(
                                Req3,
                                State,
                                413,
                                #{
                                    error => #{
                                        message => <<"body exceeds limit">>,
                                        type => <<"janus_error">>,
                                        code => <<"request_too_large">>
                                    }
                                }
                            )
                    end;
                {error, {quota, Kind, Sec}} ->
                    {ok, reply_quota_modality(Req2, State, Kind, Sec), State}
            end;
        {error, ReqErr} ->
            {ok, ReqErr, State}
    end.

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
%% exact body. Binary passthrough replies ride upstream_post_raw.
-spec upstream_post(map(), binary(), map() | binary(), map()) ->
    {ok, pos_integer(), map(), binary()} | {error, term()}.
upstream_post(Route, PathSuffix, ReqMapOrBody, Opts) when is_map(Route) ->
    case janus_catalog:lookup_provider(maps:get(provider_id, Route)) of
        {ok, #{base_url := BaseUrl0, enabled := true}} ->
            case janus_providers_http:decrypt_key(maps:get(provider_key, Route, undefined)) of
                {ok, Token} ->
                    case
                        janus_providers_http:parse_base(iolist_to_binary(BaseUrl0))
                    of
                        {ok, Host, Port, BasePath, Tls} ->
                            Path = janus_providers_http:join_path(BasePath, PathSuffix),
                            Body =
                                case ReqMapOrBody of
                                    B when is_binary(B) -> B;
                                    M -> thoas:encode(M)
                                end,
                            Headers = [
                                {<<"authorization">>, <<"Bearer ", Token/binary>>},
                                {<<"content-type">>, <<"application/json">>},
                                {<<"accept">>, <<"application/json">>},
                                {<<"user-agent">>, janus_providers_http:user_agent()}
                            ],
                            Target = #{
                                host => Host, port => Port, path => Path, tls => Tls,
                                timeout => maps:get(timeout_ms, Opts, ?DEFAULT_UPSTREAM_MS)
                            },
                            janus_providers_http:post(Target, Headers, Body);
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
    end.

upstream_post(Route, PathSuffix, ReqMapOrBody) ->
    upstream_post(Route, PathSuffix, ReqMapOrBody, #{}).

reply_json(Req, State, Status, Map) ->
    Body = thoas:encode(Map),
    Req2 = cowboy_req:reply(
        Status,
        #{<<"content-type">> => <<"application/json">>},
        Body,
        Req
    ),
    {ok, Req2, State}.

reply_bytes(Req, State, Status, ContentType, Body) ->
    Req2 = cowboy_req:reply(
        Status, #{<<"content-type">> => ContentType}, Body, Req
    ),
    {ok, Req2, State}.

%% Usage row: the plugin passes modality/units/outcome + the usual
%% fields; route context is pulled from the pdict like the proxy does.
record_usage(#{status := _} = Ev0, Route) ->
    ReqId = get(janus_request_id),
    Ev = Ev0#{
        provider_id => maps:get(provider_id, Route, null),
        provider_key_id =>
            case maps:get(provider_key, Route, undefined) of
                #{id := Kid} -> Kid;
                _ -> null
            end,
        request_id => ReqId
    },
    case {ReqId, maps:get(agent_key_id, Ev, null)} of
        {Rid, Aid} when is_binary(Rid), is_integer(Aid) ->
            _ = janus_quota:charge_tokens(
                Rid, Aid, maps:get(prompt, Ev, null), maps:get(completion, Ev, null)
            );
        _ ->
            ok
    end,
    _ = janus_usage:record(Ev),
    ok.

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
    cowboy_req:reply(
        429,
        #{
            <<"content-type">> => <<"application/json">>,
            <<"retry-after">> => integer_to_binary(Sec)
        },
        Body,
        Req
    ).
