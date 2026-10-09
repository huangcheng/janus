%%%-------------------------------------------------------------------
%%% @doc GET /metrics — Prometheus text exposition on the admin plane.
%%% Same token/loopback auth as /stats (janus_admin_auth).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_metrics).

-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Req =
        case janus_admin_auth:authorize(Req0) of
            ok ->
                case cowboy_req:method(Req0) of
                    <<"GET">> -> render(Req0);
                    _ ->
                        cowboy_req:reply(405, #{
                            <<"content-type">> => <<"application/json">>,
                            <<"allow">> => <<"GET">>
                        }, thoas:encode(#{error => #{code => <<"method_not_allowed">>}}), Req0)
                end;
            {error, Req1} -> Req1
        end,
    {ok, Req, State}.

render(Req) ->
    Usage = safe(fun janus_usage:stats/0, usage_stats),
    LbStats = safe(fun janus_lb:stats/0, lb_stats),
    {WallMs, _} = statistics(wall_clock),
    %% A render failure must not wedge the scrape: 500 + log. ALL
    %% consumption of scrape-time values lives INSIDE the try — a dead
    %% ETS table, a wrong-shape stats return, or a bad gauge must never
    %% escape as an uncaught 500.
    try
        Version =
            case application:get_key(janus, vsn) of
                {ok, V} -> janus_metrics:to_bin(V);
                _ -> <<"unknown">>
            end,
        LbList = case LbStats of
            {ok, LbMap} when is_map(LbMap) -> maps:to_list(LbMap);
            _ -> []
        end,
        BadStats = [K || {K, V} <- LbList, not is_integer(V)],
        case BadStats of
            [] -> ok;
            _ -> logger:warning(#{what => janus_metrics_lb_stat_skip, stats => BadStats})
        end,
        LbRows = [
            {{counter, lb_stats_total, [{<<"stat">>, janus_metrics:to_bin(K)}]}, V}
         || {K, V} <- LbList, is_integer(V)
        ],
        %% usage writer down/wrong-shape → the dropped series is
        %% OMITTED (a counter must never report a fabricated 0).
        DropRows =
            case Usage of
                {ok, UsageMap} when is_map(UsageMap) ->
                    [{{counter, usage_writer_dropped_total, []},
                      int_or_zero(maps:get(dropped, UsageMap, 0), usage_dropped)}];
                _ ->
                    []
            end,
        Buffered =
            case Usage of
                {ok, UsageMap2} when is_map(UsageMap2) ->
                    int_or_zero(maps:get(buffered, UsageMap2, 0), usage_buffered);
                _ ->
                    0
            end,
        Rows = janus_metrics:snapshot() ++ DropRows ++ LbRows ++ fleet_rows(),
        Gauges =
            [
                {catalog_generation, gauge_val(fun janus_config:generation/0, 0, catalog_generation), #{}},
                {catalog_ready, bool01(gauge_val(fun janus_config:ready/0, false, catalog_ready)), #{}},
                {models_serving, gauge_val(fun janus_http_stats:models_serving/0, 0, models_serving), #{}},
                {lb_routes_cooling, gauge_val(fun janus_lb:cooling_count/0, 0, lb_cooling), #{}},
                {usage_writer_buffered_rows, Buffered, #{}},
                {uptime_seconds, WallMs div 1000, #{}},
                {workers_available, workers_available_gauge(), #{}},
                {build_info, 1, #{<<"version">> => Version}}
            ] ++ fleet_gauges(),
        Body = janus_metrics_render:render(Rows, Gauges),
        cowboy_req:reply(200, #{
            <<"content-type">> => <<"text/plain; version=0.0.4; charset=utf-8">>
        }, Body, Req)
    catch
        Class:Reason:Stack ->
            logger:error(#{
                what => janus_metrics_render_error,
                class => Class, reason => Reason, stack => Stack
            }),
            cowboy_req:reply(500, #{
                <<"content-type">> => <<"text/plain; charset=utf-8">>
            }, <<"render error\n">>, Req)
    end.

%% Scrape-time sources return {ok, V} | error (logged). A crashing
%% source is an error; a wrong-shape return is an error; the caller
%% decides the fallback (omit series / substitute gauge value).
safe(Fun, What) ->
    try Fun() of
        V -> {ok, V}
    catch
        Class:Reason ->
            logger:warning(#{
                what => janus_metrics_gauge_error, source => What,
                class => Class, reason => Reason
            }),
            error
    end.

%%%--------------------------------------------------------------------
%%% Fleet series (native-distribution spec Part C): present ONLY when
%%% the knob is on; a parked janus_fleet (tables gone) omits rather
%%% than fabricating zeros — status comes from /stats.fleet instead.
%%%--------------------------------------------------------------------

fleet_rows() ->
    case catch janus_fleet:enabled() of
        true ->
            C = case catch janus_fleet:counters() of
                M when is_map(M) -> M;
                _ -> #{}
            end,
            Base = [
                {{counter, MetricName, []}, V}
             || {CtrName, MetricName} <- [
                    {signals_tx, fleet_signals_tx_total},
                    {signals_rx, fleet_signals_rx_total},
                    {bad_ingress, fleet_bad_ingress_total},
                    {remote_cool_last_resort, fleet_remote_cool_last_resort_total}
                ],
                V <- [maps:get(CtrName, C, undefined)],
                is_integer(V)
            ],
            Cmd = [
                {{counter, fleet_commands_total, [
                    {<<"command">>, CmdB},
                    {<<"outcome">>, janus_metrics:to_bin(Outcome)}
                ]}, V}
             || {{cmd_outcome, CmdB, Outcome}, V} <- maps:to_list(C), is_integer(V)
            ],
            Base ++ Cmd;
        _ ->
            []
    end.

fleet_gauges() ->
    case catch janus_fleet:enabled() of
        true ->
            Status = case catch janus_fleet:status() of
                M when is_map(M) -> M;
                _ -> #{}
            end,
            Holder = case Status of
                #{lease := #{holder := H}} when is_atom(H) -> H;
                _ -> undefined
            end,
            Sizes = case Status of
                #{mirror_sizes := S} when is_map(S) -> S;
                _ -> #{}
            end,
            [
                {fleet_lease_holder,
                    case Holder of
                        undefined -> 0;
                        _ -> bool01(Holder =:= node())
                    end,
                    #{}}
            ] ++ [
                {fleet_mirror_rows, int_or_zero(N, fleet_mirror_size), #{<<"mirror">> => janus_metrics:to_bin(K)}}
             || {K, N} <- maps:to_list(Sizes)
            ];
        _ ->
            []
    end.

gauge_val(Fun, Default, What) ->
    case safe(Fun, What) of
        {ok, V} when is_integer(V) -> V;
        {ok, V} when is_boolean(V) -> V;
        {ok, V} when is_float(V) -> V;
        _ -> Default
    end.

%% Master: live hello'd non-draining pool size. Worker / absent pool → 0.
workers_available_gauge() ->
    case safe_role() of
        master ->
            gauge_val(fun janus_worker_pool:available/0, 0, workers_available);
        _ ->
            0
    end.

safe_role() ->
    try
        janus_role:get()
    catch
        _:_ ->
            %% Boot / non-gateway scrape: treat as master so an empty
            %% pool still reports 0 rather than omitting the series.
            master
    end.

bool01(true) -> 1;
bool01(1) -> 1;
bool01(_) -> 0.

%% Scrape values from other processes are untrusted shapes — coerce or
%% zero + warn, never crash the scrape on one bad value.
int_or_zero(V, _What) when is_integer(V) ->
    V;
int_or_zero(V, What) ->
    logger:warning(#{what => janus_metrics_gauge_error, source => What, value => V}),
    0.
