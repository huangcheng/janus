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
        case janus_admin_auth:authorize(Req0) of
            ok ->
                handle(cowboy_req:method(Req0), cowboy_req:path_info(Req0), Req0);
            {error, Req1} ->
                Req1
        end,
    {ok, Req, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

handle(_Method, undefined, Req) ->
    %% Exact /stats match has undefined path_info; normalize.
    handle(_Method, [], Req);
handle(<<"GET">>, [], Req) ->
    Usage = janus_usage:stats(),
    %% Snapshot merged WITH the update result — a bare `Stats#{...}`
    %% statement discards the new map (immutability) and /stats would
    %% ship only the three counter fields.
    Base = janus_http_stats:snapshot(),
    Stats0 = Base#{
        generation => janus_config:generation(),
        ready => janus_config:ready(),
        backend => janus_db:select_backend(),
        uptime_sec => uptime_sec(),
        routes_cooling => janus_lb:cooling_count(),
        models_serving => janus_http_stats:models_serving(),
        %% Failover/entitlement counters (requests_retried,
        %% failovers_exhausted, entitlement_failopen, ...).
        lb => janus_lb:stats(),
        usage => Usage,
        usage_writer => Usage
    },
    %% `fleet` appears ONLY when the knob is on (spec Part C) — knob-off
    %% /stats is byte-identical to today's.
    Stats = maybe_fleet(Stats0),
    reply_json(200, Stats, Req);
handle(<<"GET">>, [<<"fleet">>], Req) ->
    case fleet_on() of
        true ->
            reply_json(200, safe_fleet_status(), Req);
        false ->
            reply_json(404, #{error => #{code => <<"fleet_disabled">>}}, Req)
    end;
handle(<<"GET">>, [<<"logs">>], Req) ->
    Limit = qs_int(Req, <<"limit">>, 100, 1, 2000),
    {ok, Events, Total} = janus_log_tail:recent(Limit, undefined),
    reply_json(200, #{events => Events, total => Total}, Req);
handle(_, _, Req) ->
    reply_json(405, #{error => #{code => <<"method_not_allowed">>}}, Req).

fleet_on() ->
    case catch janus_fleet:enabled() of
        true -> true;
        _ -> false
    end.

maybe_fleet(Stats) ->
    case fleet_on() of
        true -> Stats#{fleet => safe_fleet_status()};
        false -> Stats
    end.

%% The Part A read path is ETS/pg reads, never a gen_server call — a
%% parked janus_fleet still answers (status: down), and a crashed read
%% helper degrades to a stub rather than a 500.
safe_fleet_status() ->
    case catch janus_fleet:status() of
        M when is_map(M) -> M;
        _ -> #{status => down}
    end.

uptime_sec() ->
    %% Wall clock seconds since boot (erlang:statistics(wall_clock) is
    %% milliseconds since VM start).
    {WallMs, _} = statistics(wall_clock),
    WallMs div 1000.

qs_int(Req, Name, Default, Min, Max) ->
    Qs = cowboy_req:parse_qs(Req),
    case lists:keyfind(Name, 1, Qs) of
        {_, Bin} ->
            try
                N = binary_to_integer(Bin),
                max(Min, min(Max, N))
            catch
                _:_ -> Default
            end;
        false ->
            Default
    end.

reply_json(Status, Map, Req) ->
    Body = thoas:encode(Map),
    cowboy_req:reply(Status, #{
        <<"content-type">> => <<"application/json">>
    }, Body, Req).
