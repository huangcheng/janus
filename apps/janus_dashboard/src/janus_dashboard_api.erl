%%%-------------------------------------------------------------------
%%% @doc Dashboard JSON API. Mounted at `/dashboard/api/[...]` on the dashboard
%%% listener (see design/dashboard-ui/api.html for the contract).
%%%
%%% Auth: `janus_dashboard_session` cookie; mutations additionally require
%%% the `X-Janus-CSRF` header. Every mutation and login attempt is
%%% written to {@link janus_dashboard_audit} and bumps the catalog
%%% generation so the serving catalog hot-reloads.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_dashboard_api).

-behaviour(cowboy_handler).

-export([init/2]).

-define(MAX_BODY, 1_048_576).
-define(COOKIE, <<"janus_dashboard_session">>).

init(Req0, State) ->
    Req =
        try
            route(cowboy_req:method(Req0), cowboy_req:path_info(Req0), Req0)
        catch
            throw:{reply, Status, Body} ->
                reply_json(Status, Body, Req0);
            Class:Reason:Stack ->
                logger:error(#{
                    what => janus_dashboard_api_crash,
                    class => Class,
                    reason => Reason,
                    stack => Stack
                }),
                reply_json(
                    500,
                    #{
                        error => #{
                            code => <<"internal_error">>, message => <<"dashboard api crashed">>
                        }
                    },
                    Req0
                )
        end,
    {ok, Req, State}.

%%%===================================================================
%%% Routing
%%%===================================================================

%% session
route(<<"POST">>, [<<"session">>], Req) ->
    handle_login(Req);
route(<<"GET">>, [<<"session">>], Req) ->
    with_session(Req, fun(Csrf) -> reply_json(200, #{csrf => Csrf}, Req) end);
route(<<"DELETE">>, [<<"session">>], Req) ->
    with_session(Req, fun(_Csrf) ->
        logout_cookie(Req),
        reply_json(200, #{ok => true}, Req)
    end);
%% overview
route(<<"GET">>, [<<"overview">>], Req) ->
    with_session(Req, fun(_Csrf) -> handle_overview(Req) end);
%% providers
route(<<"GET">>, [<<"providers">>], Req) ->
    with_session(Req, fun(_Csrf) -> handle_providers_get(Req) end);
route(<<"POST">>, [<<"providers">>], Req) ->
    with_mutating_session(Req, fun(Body, _Csrf) -> handle_provider_add(Body, Req) end);
route(<<"POST">>, [<<"providers">>, Id, <<"disable">>], Req) ->
    with_mutating_session(Req, fun(_, _) -> toggle(provider, Id, false, Req) end);
route(<<"POST">>, [<<"providers">>, Id, <<"enable">>], Req) ->
    with_mutating_session(Req, fun(_, _) -> toggle(provider, Id, true, Req) end);
route(<<"DELETE">>, [<<"providers">>, Id], Req) ->
    with_mutating_session(Req, fun(_, _) -> handle_delete(provider, Id, Req) end);
route(<<"POST">>, [<<"providers">>, Id, <<"keys">>], Req) ->
    with_mutating_session(Req, fun(Body, _) -> handle_provider_key_add(Id, Body, Req) end);
%% provider keys
route(<<"POST">>, [<<"provider-keys">>, Id, <<"disable">>], Req) ->
    with_mutating_session(Req, fun(_, _) -> toggle(provider_key, Id, false, Req) end);
route(<<"POST">>, [<<"provider-keys">>, Id, <<"enable">>], Req) ->
    with_mutating_session(Req, fun(_, _) -> toggle(provider_key, Id, true, Req) end);
route(<<"DELETE">>, [<<"provider-keys">>, Id], Req) ->
    with_mutating_session(Req, fun(_, _) -> handle_delete(provider_key, Id, Req) end);
%% models & routes
route(<<"GET">>, [<<"models">>], Req) ->
    with_session(Req, fun(_Csrf) -> handle_models_get(Req) end);
route(<<"POST">>, [<<"models">>], Req) ->
    with_mutating_session(Req, fun(Body, _) -> handle_model_add(Body, Req) end);
route(<<"POST">>, [<<"models">>, Id, <<"disable">>], Req) ->
    with_mutating_session(Req, fun(_, _) -> toggle(model, Id, false, Req) end);
route(<<"POST">>, [<<"models">>, Id, <<"enable">>], Req) ->
    with_mutating_session(Req, fun(_, _) -> toggle(model, Id, true, Req) end);
route(<<"POST">>, [<<"models">>, Id, <<"routes">>], Req) ->
    with_mutating_session(Req, fun(Body, _) -> handle_route_add(Id, Body, Req) end);
route(<<"POST">>, [<<"models">>, Id, <<"routes">>, Pid, <<"disable">>], Req) ->
    with_mutating_session(Req, fun(_, _) -> toggle_route(Id, Pid, false, Req) end);
route(<<"POST">>, [<<"models">>, Id, <<"routes">>, Pid, <<"enable">>], Req) ->
    with_mutating_session(Req, fun(_, _) -> toggle_route(Id, Pid, true, Req) end);
route(<<"DELETE">>, [<<"models">>, Id, <<"routes">>, Pid], Req) ->
    with_mutating_session(Req, fun(_, _) -> handle_route_delete(Id, Pid, Req) end);
%% agent keys
route(<<"GET">>, [<<"keys">>], Req) ->
    with_session(Req, fun(_Csrf) -> handle_keys_get(Req) end);
route(<<"POST">>, [<<"keys">>], Req) ->
    with_mutating_session(Req, fun(Body, _) -> handle_key_create(Body, Req) end);
route(<<"POST">>, [<<"keys">>, Id, <<"disable">>], Req) ->
    with_mutating_session(Req, fun(_, _) -> toggle(agent_key, Id, false, Req) end);
route(<<"POST">>, [<<"keys">>, Id, <<"enable">>], Req) ->
    with_mutating_session(Req, fun(_, _) -> toggle(agent_key, Id, true, Req) end);
route(<<"DELETE">>, [<<"keys">>, Id], Req) ->
    with_mutating_session(Req, fun(_, _) -> handle_delete(agent_key, Id, Req) end);
%% catalog & audit
route(<<"POST">>, [<<"models">>, <<"sync">>], Req) ->
    with_mutating_session(Req, fun(_, _) -> sync_models(Req) end);
route(<<"GET">>, [<<"models">>, <<"sync">>, <<"status">>], Req) ->
    with_session(Req, fun(_Csrf) -> sync_status(Req) end);
route(<<"PUT">>, [<<"models">>, <<"sync">>, <<"interval">>], Req) ->
    with_mutating_session(Req, fun(Body, _) -> sync_set_interval(Body, Req) end);
%% catalog & audit
route(<<"POST">>, [<<"catalog">>, <<"reload">>], Req) ->
    with_mutating_session(Req, fun(_, _) ->
        case janus_dashboard_store:bump_generation() of
            {ok, Gen} ->
                mutate(<<"catalog.reload">>, undefined, Req),
                reply_json(200, #{generation => Gen, ok => true}, Req);
            {error, Reason} ->
                err(500, <<"reload_failed">>, Reason, Req)
        end
    end);
route(<<"GET">>, [<<"audit">>], Req) ->
    with_session(Req, fun(_Csrf) ->
        N = query_int(Req, <<"limit">>, 50),
        reply_json(200, #{events => janus_dashboard_audit:recent(N)}, Req)
    end);
route(_, _, Req) ->
    reply_json(
        404,
        #{error => #{code => <<"not_found">>, message => <<"unknown dashboard api route">>}},
        Req
    ).

%%%===================================================================
%%% Handlers
%%%===================================================================

handle_login(Req) ->
    Actor = actor(Req),
    case read_json(Req) of
        {ok, #{<<"password">> := Pw}} when is_binary(Pw) ->
            case janus_dashboard_session:login(Pw, Actor) of
                {ok, Token, Csrf} ->
                    audit(Actor, <<"auth.login">>, undefined, <<"password ok">>),
                    reply_json(200, #{csrf => Csrf}, set_cookie(Req, Token));
                {error, locked, RetrySec} ->
                    audit(
                        Actor,
                        <<"auth.lockout">>,
                        undefined,
                        <<"retry after ", (integer_to_binary(RetrySec))/binary, "s">>
                    ),
                    reply_json(
                        429,
                        #{
                            error => #{
                                code => <<"locked">>,
                                message => <<"too many failed logins; try again later">>,
                                retry_after_sec => RetrySec
                            }
                        },
                        Req,
                        #{<<"retry-after">> => integer_to_binary(RetrySec)}
                    );
                {error, invalid} ->
                    audit(Actor, <<"auth.login_failed">>, undefined, <<"bad password">>),
                    reply_json(
                        401,
                        #{
                            error => #{
                                code => <<"invalid_credentials">>, message => <<"wrong password">>
                            }
                        },
                        Req
                    );
                {error, not_configured} ->
                    reply_json(
                        503,
                        #{
                            error => #{
                                code => <<"not_configured">>,
                                message =>
                                    <<"JANUS_DASHBOARD_PASSWORD is not set; logins disabled">>
                            }
                        },
                        Req
                    )
            end;
        _ ->
            err(400, <<"bad_request">>, <<"expected {\"password\": \"...\"}">>, Req)
    end.

handle_overview(Req) ->
    {ok, Providers} = janus_dashboard_store:providers(),
    {ok, Models} = janus_dashboard_store:models(),
    {ok, Routes} = janus_dashboard_store:routes(),
    {ok, Keys} = janus_dashboard_store:agent_keys(),
    {ok, KeyCounts} = janus_dashboard_store:provider_key_counts(),
    ProvRows = [
        #{
            id => maps:get(id, P),
            name => maps:get(name, P),
            enabled => maps:get(enabled, P),
            keys => maps:get(maps:get(id, P), KeyCounts, 0)
        }
     || P <- Providers
    ],
    reply_json(
        200,
        #{
            generation => janus_config:generation(),
            ready => janus_config:ready(),
            backend => janus_db:select_backend(),
            counts => #{
                providers => length(Providers),
                models => length(Models),
                routes => length(Routes),
                agent_keys => length(Keys)
            },
            providers => ProvRows,
            recent_audit => janus_dashboard_audit:recent(5)
        },
        Req
    ).

handle_providers_get(Req) ->
    {ok, Providers} = janus_dashboard_store:providers(),
    ProvidersWithKeys =
        lists:map(
            fun(P) ->
                {ok, Keys} = janus_dashboard_store:provider_keys(maps:get(id, P)),
                P#{keys => Keys}
            end,
            Providers
        ),
    reply_json(200, #{providers => ProvidersWithKeys}, Req).

handle_provider_add(Body, Req) ->
    Name = maps:get(<<"name">>, Body, undefined),
    BaseUrl = maps:get(<<"base_url">>, Body, undefined),
    Protocol = maps:get(<<"protocol">>, Body, undefined),
    case janus_dashboard_store:add_provider(Name, BaseUrl, Protocol) of
        {ok, Id} ->
            mutate(<<"provider.add">>, Name, Req),
            reply_json(201, #{id => Id, name => Name}, Req);
        {error, Code} when
            Code =:= duplicate; Code =:= invalid_url; Code =:= invalid_protocol; Code =:= invalid
        ->
            err(400, atom_to_binary(Code, utf8), pick_msg(Code), Req);
        {error, Reason} ->
            err(500, <<"db_error">>, Reason, Req)
    end.

handle_provider_key_add(IdBin, Body, Req) ->
    Secret = maps:get(<<"secret">>, Body, undefined),
    Weight = pos_int_or(maps:get(<<"weight">>, Body, 1), 1),
    case parse_id(IdBin) of
        {ok, Id} ->
            case
                {
                    janus_dashboard_store:provider_name(Id),
                    janus_dashboard_store:add_provider_key(Id, Secret, Weight)
                }
            of
                {{ok, Name}, {ok, KeyId}} ->
                    mutate(<<"provider_key.add">>, Name, Req),
                    reply_json(201, #{id => KeyId}, Req);
                {_, {error, {encrypt_unavailable, _}}} ->
                    err(
                        503,
                        <<"secrets_unavailable">>,
                        <<"JANUS_SECRETS_KEY not configured on this node">>,
                        Req
                    );
                {_, {error, invalid}} ->
                    err(
                        400,
                        <<"invalid">>,
                        <<"expected {\"secret\": \"sk-...\", \"weight\": 1}">>,
                        Req
                    );
                {_, {error, Reason}} ->
                    err(500, <<"db_error">>, Reason, Req)
            end;
        error ->
            err(400, <<"bad_id">>, <<"invalid provider id">>, Req)
    end.

handle_models_get(Req) ->
    {ok, Models} = janus_dashboard_store:models(),
    {ok, Routes} = janus_dashboard_store:routes(),
    {ok, Providers} = janus_dashboard_store:providers(),
    ProvNames = #{maps:get(id, P) => maps:get(name, P) || P <- Providers},
    RoutesByModel =
        lists:foldl(
            fun(Route, Acc) ->
                Mid = maps:get(model_id, Route),
                maps:update_with(Mid, fun(L) -> [Route | L] end, [Route], Acc)
            end,
            #{},
            Routes
        ),
    ModelRows = [
        M#{
            routes => [
                Route#{provider_name => maps:get(maps:get(provider_id, Route), ProvNames, null)}
             || Route <- maps:get(maps:get(id, M), RoutesByModel, [])
            ]
        }
     || M <- Models
    ],
    reply_json(200, #{models => ModelRows}, Req).

handle_model_add(Body, Req) ->
    Name = maps:get(<<"name">>, Body, undefined),
    case janus_dashboard_store:add_model(Name) of
        {ok, Id} ->
            mutate(<<"model.add">>, Name, Req),
            reply_json(201, #{id => Id, name => Name}, Req);
        {error, Code} when Code =:= duplicate; Code =:= invalid ->
            err(400, atom_to_binary(Code, utf8), pick_msg(Code), Req);
        {error, Reason} ->
            err(500, <<"db_error">>, Reason, Req)
    end.

handle_route_add(ModelIdBin, Body, Req) ->
    ProviderId = maps:get(<<"provider_id">>, Body, undefined),
    Upstream = maps:get(<<"upstream_model_id">>, Body, undefined),
    Weight = pos_int_or(maps:get(<<"weight">>, Body, 1), 1),
    Priority = int_or(maps:get(<<"priority">>, Body, 0), 0),
    case parse_id(ModelIdBin) of
        {ok, ModelId} ->
            case janus_dashboard_store:add_route(ModelId, ProviderId, Upstream, Weight, Priority) of
                ok ->
                    Target = route_target(ModelId, ProviderId),
                    mutate(<<"route.add">>, Target, Req),
                    reply_json(201, #{ok => true}, Req);
                {error, Code} when Code =:= invalid; Code =:= duplicate ->
                    err(400, atom_to_binary(Code, utf8), pick_msg(Code), Req);
                {error, Reason} ->
                    err(500, <<"db_error">>, Reason, Req)
            end;
        error ->
            err(400, <<"bad_id">>, <<"invalid model id">>, Req)
    end.

toggle_route(ModelIdBin, PidBin, Enabled, Req) ->
    case {parse_id(ModelIdBin), parse_id(PidBin)} of
        {{ok, Mid}, {ok, Pid}} ->
            case janus_dashboard_store:set_route_enabled(Mid, Pid, Enabled) of
                ok ->
                    mutate(<<"route.", (en_dis(Enabled))/binary>>, undefined, Req),
                    reply_json(200, #{ok => true}, Req);
                {error, Reason} ->
                    err(500, <<"db_error">>, Reason, Req)
            end;
        _ ->
            err(400, <<"bad_id">>, <<"invalid ids">>, Req)
    end.

handle_route_delete(ModelIdBin, PidBin, Req) ->
    case {parse_id(ModelIdBin), parse_id(PidBin)} of
        {{ok, Mid}, {ok, Pid}} ->
            case janus_dashboard_store:delete_route(Mid, Pid) of
                ok ->
                    mutate(<<"route.delete">>, undefined, Req),
                    reply_json(200, #{ok => true}, Req);
                {error, Reason} ->
                    err(500, <<"db_error">>, Reason, Req)
            end;
        _ ->
            err(400, <<"bad_id">>, <<"invalid ids">>, Req)
    end.

sync_set_interval(Body, Req) ->
    Raw = maps:get(<<"interval_sec">>, Body, undefined),
    case Raw of
        N when is_integer(N), N >= 0, N =< 2_592_000 ->
            {ok, Set} = janus_model_sync:set_interval(N),
            mutate(<<"model_sync.set_interval">>, undefined, Req),
            reply_json(200, #{interval_sec => Set, ok => true}, Req);
        _ ->
            err(400, <<"invalid">>,
                <<"interval_sec must be an integer 0..2592000 (0 = manual only)">>, Req)
    end.

sync_models(Req) ->
    case catch janus_model_sync:sync_now() of
        {ok, Result} ->
            mutate(<<"model_sync.run">>, undefined, Req),
            reply_json(200, Result, Req);
        Other ->
            err(500, <<"sync_failed">>, Other, Req)
    end.

sync_status(Req) ->
    S = janus_model_sync:status(),
    reply_json(200, S#{interval_sec => janus_model_sync:interval()}, Req).

handle_keys_get(Req) ->
    {ok, Keys} = janus_dashboard_store:agent_keys(),
    {ok, Grants} = janus_dashboard_store:grants(),
    {ok, Models} = janus_dashboard_store:models(),
    ModelNames = #{maps:get(id, M) => maps:get(name, M) || M <- Models},
    GrantsByKey =
        lists:foldl(
            fun(G, Acc) ->
                Kid = maps:get(api_key_id, G),
                maps:update_with(
                    Kid,
                    fun(L) -> [maps:get(model_id, G) | L] end,
                    [maps:get(model_id, G)],
                    Acc
                )
            end,
            #{},
            Grants
        ),
    Rows = [
        begin
            Mids = maps:get(maps:get(id, K), GrantsByKey, []),
            K#{
                model_ids => Mids,
                model_names => [maps:get(Mid, ModelNames, null) || Mid <- Mids]
            }
        end
     || K <- Keys
    ],
    reply_json(200, #{keys => Rows}, Req).

handle_key_create(Body, Req) ->
    RawIds =
        case maps:get(<<"model_ids">>, Body, undefined) of
            L when is_list(L) -> [I || I <- L, is_integer(I)];
            _ -> []
        end,
    case valid_model_ids(RawIds) of
        false ->
            err(
                400,
                <<"invalid">>,
                <<"model_ids must be a non-empty list of existing model ids">>,
                Req
            );
        true ->
            case janus_dashboard_store:create_agent_key(RawIds) of
                {ok, Key, Prefix, _Id} ->
                    mutate(<<"agent_key.create">>, <<Prefix/binary, "...">>, Req),
                    %% the ONLY response that ever carries the plaintext key
                    reply_json(201, #{key => Key, prefix => Prefix, model_ids => RawIds}, Req);
                {error, invalid} ->
                    err(
                        400,
                        <<"invalid">>,
                        <<"model_ids must be a non-empty list of integers">>,
                        Req
                    );
                {error, Reason} ->
                    err(500, <<"db_error">>, Reason, Req)
            end
    end.

toggle(Kind, IdBin, Enabled, Req) ->
    case parse_id(IdBin) of
        {ok, Id} ->
            Op = atom_to_binary(Kind, utf8),
            Result =
                case Kind of
                    provider -> janus_dashboard_store:set_provider_enabled(Id, Enabled);
                    provider_key -> janus_dashboard_store:set_provider_key_enabled(Id, Enabled);
                    model -> janus_dashboard_store:set_model_enabled(Id, Enabled);
                    agent_key -> janus_dashboard_store:set_agent_key_enabled(Id, Enabled)
                end,
            case Result of
                ok ->
                    mutate(<<Op/binary, ".", (en_dis(Enabled))/binary>>, undefined, Req),
                    reply_json(200, #{ok => true}, Req);
                {error, Reason} ->
                    err(500, <<"db_error">>, Reason, Req)
            end;
        error ->
            err(400, <<"bad_id">>, <<"invalid id">>, Req)
    end.

handle_delete(Kind, IdBin, Req) ->
    case parse_id(IdBin) of
        {ok, Id} ->
            Op = atom_to_binary(Kind, utf8),
            Result =
                case Kind of
                    provider -> janus_dashboard_store:delete_provider(Id);
                    provider_key -> janus_dashboard_store:delete_provider_key(Id);
                    agent_key -> janus_dashboard_store:delete_agent_key(Id)
                end,
            case Result of
                ok ->
                    mutate(<<Op/binary, ".delete">>, undefined, Req),
                    reply_json(200, #{ok => true}, Req);
                {error, Reason} ->
                    err(500, <<"db_error">>, Reason, Req)
            end;
        error ->
            err(400, <<"bad_id">>, <<"invalid id">>, Req)
    end.

%%%===================================================================
%%% Auth wrappers
%%%===================================================================

with_session(Req, Fun) ->
    case session_token(Req) of
        {ok, Token} ->
            case janus_dashboard_session:validate(Token) of
                {ok, Csrf} -> Fun(Csrf);
                error -> unauthorized(Req)
            end;
        error ->
            unauthorized(Req)
    end.

with_mutating_session(Req, Fun) ->
    with_session(Req, fun(Csrf) ->
        Header = cowboy_req:header(<<"x-janus-csrf">>, Req),
        Mac = fun(X) -> crypto:mac(hmac, sha256, <<"janus-csrf">>, X) end,
        case is_binary(Header) andalso crypto:hash_equals(Mac(Header), Mac(Csrf)) of
            true ->
                case read_json(Req) of
                    {ok, Body} -> Fun(Body, Csrf);
                    {error, Reason} -> err(400, <<"bad_json">>, Reason, Req)
                end;
            false ->
                err(403, <<"bad_csrf">>, <<"missing or wrong X-Janus-CSRF header">>, Req)
        end
    end).

unauthorized(Req) ->
    reply_json(
        401,
        #{error => #{code => <<"unauthorized">>, message => <<"not signed in">>}},
        Req
    ).

%%%===================================================================
%%% Helpers
%%%===================================================================

%% Shared mutation epilogue: audit + catalog generation bump.
mutate(Action, Target, Req) ->
    audit(actor(Req), Action, Target, undefined),
    catch janus_dashboard_store:bump_generation(),
    ok.

audit(Actor, Action, Target, Detail) ->
    catch janus_dashboard_audit:log(Actor, Action, Target, Detail),
    ok.

route_target(ModelId, ProviderId) ->
    M =
        case janus_dashboard_store:model_name(ModelId) of
            {ok, Mn} -> Mn;
            _ -> integer_to_binary(ModelId)
        end,
    P =
        case janus_dashboard_store:provider_name(ProviderId) of
            {ok, Pn} -> Pn;
            _ -> integer_to_binary(ProviderId)
        end,
    <<M/binary, " -> ", P/binary>>.

valid_model_ids([]) ->
    false;
valid_model_ids(Ids) ->
    case janus_dashboard_store:models() of
        {ok, Models} ->
            Known = sets:from_list([maps:get(id, M) || M <- Models], [{version, 2}]),
            lists:all(fun(I) -> sets:is_element(I, Known) end, Ids);
        {error, _} ->
            false
    end.

session_token(Req) ->
    Cookies = cowboy_req:parse_cookies(Req),
    case lists:keyfind(?COOKIE, 1, Cookies) of
        {?COOKIE, Token} when is_binary(Token), Token =/= <<>> -> {ok, Token};
        _ -> error
    end.

set_cookie(Req, Token) ->
    cowboy_req:set_resp_cookie(?COOKIE, Token, Req, #{
        path => <<"/">>,
        http_only => true,
        same_site => strict,
        max_age => 43200,
        secure => application:get_env(janus_dashboard, secure_cookies, false)
    }).

logout_cookie(Req) ->
    case session_token(Req) of
        {ok, Token} -> janus_dashboard_session:logout(Token);
        error -> ok
    end.

actor(Req) ->
    {Ip, _} = cowboy_req:peer(Req),
    list_to_binary(inet:ntoa(Ip)).

read_json(Req) ->
    case cowboy_req:has_body(Req) of
        false ->
            {ok, #{}};
        true ->
            case cowboy_req:read_body(Req, #{length => ?MAX_BODY}) of
                {ok, Body, _} ->
                    case thoas:decode(Body) of
                        {ok, Map} when is_map(Map) -> {ok, Map};
                        {ok, _} -> {error, <<"body must be a JSON object">>};
                        {error, Reason} -> {error, Reason}
                    end;
                {more, _, _} ->
                    {error, <<"body too large">>}
            end
    end.

reply_json(Status, Map, Req) ->
    reply_json(Status, Map, Req, #{}).

reply_json(Status, Map, Req, ExtraHeaders) ->
    Body = thoas:encode(Map),
    Headers = maps:merge(#{<<"content-type">> => <<"application/json">>}, ExtraHeaders),
    cowboy_req:reply(Status, Headers, Body, Req).

err(Status, Code, Reason, Req) when is_binary(Code) ->
    Msg =
        case Reason of
            B when is_binary(B) -> B;
            Other -> format_reason(Other)
        end,
    throw({reply, Status, #{error => #{code => Code, message => Msg}}}).

pick_msg(duplicate) -> <<"name already exists">>;
pick_msg(invalid) -> <<"invalid input">>;
pick_msg(invalid_url) -> <<"base_url must start with http:// or https://">>;
pick_msg(invalid_protocol) -> <<"unsupported protocol">>;
pick_msg(_) -> <<"invalid input">>.

format_reason(R) when is_binary(R) -> R;
format_reason(R) when is_atom(R) -> atom_to_binary(R, utf8);
format_reason(R) -> iolist_to_binary(io_lib:format("~0p", [R])).

parse_id(Bin) when is_binary(Bin) ->
    try
        {ok, binary_to_integer(Bin)}
    catch
        _:_ -> error
    end;
parse_id(N) when is_integer(N) ->
    {ok, N};
parse_id(_) ->
    error.

pos_int_or(N, _Default) when is_integer(N), N > 0 -> N;
pos_int_or(N, Default) when is_binary(N) ->
    try
        binary_to_integer(N)
    catch
        _:_ -> Default
    end;
pos_int_or(_, Default) ->
    Default.

int_or(N, _Default) when is_integer(N) -> N;
int_or(N, Default) when is_binary(N) ->
    try
        binary_to_integer(N)
    catch
        _:_ -> Default
    end;
int_or(_, Default) ->
    Default.

query_int(Req, Key, Default) ->
    Qs = cowboy_req:parse_qs(Req),
    case lists:keyfind(Key, 1, Qs) of
        {Key, Bin} when is_binary(Bin) ->
            try
                binary_to_integer(Bin)
            catch
                _:_ -> Default
            end;
        _ ->
            Default
    end.

en_dis(true) -> <<"enable">>;
en_dis(false) -> <<"disable">>.
