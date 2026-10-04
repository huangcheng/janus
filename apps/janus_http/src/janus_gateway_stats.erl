%%%-------------------------------------------------------------------
%%% @doc Read-only gateway stats endpoint for the Python dashboard to
%%% poll. Token-authenticated via JANUS_STATS_TOKEN; no session/CSRF.
%%% GET /stats      — node health + counters
%%% GET /stats/logs — recent log events (from janus_log_tail)
%%% @end
%%%-------------------------------------------------------------------
-module(janus_gateway_stats).

-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Req =
        case authorize(Req0) of
            ok ->
                handle(cowboy_req:method(Req0), cowboy_req:path_info(Req0), Req0);
            {error, Req1} ->
                Req1
        end,
    {ok, Req, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

authorize(Req0) ->
    case stats_token() of
        undefined ->
            %% No token configured: allow only loopback connections.
            {{Ip, _Port} = _Peer} = cowboy_req:peer(Req0),
            case is_loopback(Ip) of
                true -> ok;
                false -> {error, unauthorized(Req0, <<"stats token not configured; loopback only">>)}
            end;
        Token ->
            case cowboy_req:header(<<"authorization">>, Req0) of
                <<"Bearer ", Token/binary>> -> ok;
                _ -> {error, unauthorized(Req0, <<"invalid or missing stats token">>)}
        end
    end.

stats_token() ->
    case os:getenv("JANUS_STATS_TOKEN") of
        Val when is_list(Val), Val =/= [] -> list_to_binary(Val);
        _ -> application:get_env(janus, stats_token, undefined)
    end.

is_loopback({127, 0, 0, 1}) -> true;
is_loopback({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
is_loopback(_) -> false.

handle(_Method, undefined, Req) ->
    %% Exact /stats match has undefined path_info; normalize.
    handle(_Method, [], Req);
handle(<<"GET">>, [], Req) ->
    Stats = #{
        generation => janus_config:generation(),
        ready => janus_config:ready(),
        backend => janus_db:select_backend(),
        uptime_sec => uptime_sec(),
        routes_cooling => janus_lb:cooling_count(),
        models_serving => models_serving()
    },
    reply_json(200, Stats, Req);
handle(<<"GET">>, [<<"logs">>], Req) ->
    {ok, Events, Total} = janus_log_tail:recent(100, undefined),
    reply_json(200, #{events => Events, total => Total}, Req);
handle(_, _, Req) ->
    reply_json(405, #{error => #{code => <<"method_not_allowed">>}}, Req).

uptime_sec() ->
    %% Wall clock seconds since boot (erlang:statistics(wall_clock) is
    %% milliseconds since VM start).
    {WallMs, _} = statistics(wall_clock),
    WallMs div 1000.

models_serving() ->
    case janus_catalog:get() of
        #{catalog := #{models := Tid}} ->
            try
                Rows = ets:tab2list(Tid),
                %% Count unique model ids (table has id and name keys).
                Ids = sets:from_list([Id || {Id, #{id := Id}} <- Rows], [{version, 2}]),
                sets:size(Ids)
            catch
                _:_ -> 0
            end;
        _ ->
            0
    end.

unauthorized(Req, Msg) ->
    Body = thoas:encode(#{
        error => #{code => <<"unauthorized">>, message => Msg}
    }),
    cowboy_req:reply(401, #{
        <<"content-type">> => <<"application/json">>,
        <<"www-authenticate">> => <<"Bearer">>
    }, Body, Req).

reply_json(Status, Map, Req) ->
    Body = thoas:encode(Map),
    cowboy_req:reply(Status, #{
        <<"content-type">> => <<"application/json">>
    }, Body, Req).
