%%%-------------------------------------------------------------------
%%% @doc Read-only gateway stats endpoint for the Python dashboard to
%%% poll. Token-authenticated via JANUS_STATS_TOKEN; no session/CSRF.
%%% GET /stats      — node health + counters
%%% GET /stats/logs — recent log events (from janus_log_tail)
%%% GET /stats/sched — scheduler v2 pinned surface (spec Part C; the
%%%                    pure assembly is sched_json/1, eunit-tested)
%%% @end
%%%-------------------------------------------------------------------
-module(janus_gateway_stats).

-behaviour(cowboy_handler).

-export([init/2, sched_json/1]).

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
handle(<<"GET">>, [<<"sched">>], Req) ->
    %% Scheduler v2 pinned assertion surface (spec Part C — THE gate
    %% surface, no log scraping). Read-only ETS/gen_server reads; the
    %% JSON map itself is assembled by the PURE sched_json/1.
    reply_json(200, sched_json(sched_data()), Req);
handle(<<"GET">>, [<<"logs">>], Req) ->
    Limit = qs_int(Req, <<"limit">>, 100, 1, 2000),
    {ok, Events, Total} = janus_log_tail:recent(Limit, undefined),
    reply_json(200, #{events => Events, total => Total}, Req);
handle(_, _, Req) ->
    reply_json(405, #{error => #{code => <<"method_not_allowed">>}}, Req).

%%%===================================================================
%%% /stats/sched — data collection (impure) + pure JSON assembly
%%%===================================================================

-define(RTT_JSON_CAP, 64).

%% Impure collector: one tolerant call per source. `stats` is
%% janus_worker_pool:sched_stats/0 (counters + knobs + display EWMA +
%% raw rtt/reserve rows, assembled atomically by the pool);
%% `geo_disabled` comes from janus_geo's own counters (Task A bump
%% site; tolerant call, no janus_geo change needed); `now_mono` is
%% injected so the assembly stays pure/testable.
sched_data() ->
    #{
        stats => safe_map(fun janus_worker_pool:sched_stats/0),
        now_mono => erlang:monotonic_time(millisecond),
        geo_disabled => maps:get(geo_disabled, safe_map(fun janus_geo:counters/0), 0)
    }.

safe_map(Fun) ->
    case catch Fun() of
        M when is_map(M) -> M;
        _ -> #{}
    end.

%% @doc PURE /stats/sched JSON assembly (spec Part C, pinned schema
%% rev 10): JSON keys = metric names minus the `sched_` prefix
%% (`fleet_worker_report_mismatch_total` keeps its full name). All
%% fixed-enum sub-maps carry EVERY key with 0 defaults (gate
%% assertions never race a missing label); `rtt_ms` is capped at the
%% ?RTT_JSON_CAP most recent unexpired rows by SampledAtMono with the
%% overflow aggregate ALWAYS present as `rtt_ms_other`. Time is
%% INJECTED (`now_mono`) — no clock reads here.
-spec sched_json(map()) -> map().
sched_json(Data) when is_map(Data) ->
    Stats = maps:get(stats, Data, #{}),
    Now = maps:get(now_mono, Data, 0),
    GeoDisabled = maps:get(geo_disabled, Data, 0),
    Knobs = maps:get(knobs, Stats, #{}),
    Ctr = fun(Key) -> counter(Stats, Key) end,
    {RttMs, RttOther} = rtt_json(maps:get(rtt_rows, Stats, []), Now),
    #{
        schema_version => 1,
        geo_enabled => maps:get(geo_enabled, Knobs, false),
        rtt_enabled => maps:get(rtt_enabled, Knobs, maps:get(rtt, Knobs, false)),
        health_enabled => maps:get(health_enabled, Knobs, maps:get(health, Knobs, false)),
        probe_enabled => maps:get(probe, Knobs, false),
        snapshot_gen => Ctr(snapshot_gen),
        geo_match_total => #{
            region_tag => Ctr({geo_match, region_tag}),
            auto => Ctr({geo_match, auto}),
            none => Ctr({geo_match, none})
        },
        dispatch_worker_total => labeled_counters(Stats, dispatch_worker),
        dispatch_local_total => #{
            empty_pool => Ctr({dispatch_local, empty_pool}),
            capacity => Ctr({dispatch_local, capacity}),
            drained => Ctr({dispatch_local, drained}),
            drained_pin => Ctr({dispatch_local, drained_pin}),
            send_fail => Ctr({dispatch_local, send_fail}),
            ack_miss => Ctr({dispatch_local, ack_miss})
        },
        capacity_exhausted_total => Ctr(capacity_exhausted),
        health_demote_total => Ctr(health_demote),
        probe_total => labeled_counters(Stats, probe),
        probe_skip_total => #{
            cap => Ctr({probe_skip, cap}),
            cadence => Ctr({probe_skip, cadence}),
            fresh => Ctr({probe_skip, fresh}),
            drained => Ctr({probe_skip, drained}),
            send_fail => Ctr({probe_skip, send_fail})
        },
        rtt_ms => RttMs,
        rtt_ms_other => RttOther,
        rtt_dropped_total => #{
            negative => Ctr({rtt_dropped, negative}),
            non_finite => Ctr({rtt_dropped, non_finite})
        },
        reserve_purged_total => Ctr(reserve_purged),
        reserve_inflight => reserve_inflight_json(maps:get(reserve_rows, Stats, [])),
        health_ewma_ms => health_ewma_json(maps:get(health_ewma, Stats, #{})),
        geo_disabled_total => GeoDisabled,
        fleet_worker_report_mismatch_total => Ctr(fleet_worker_report_mismatch)
    }.

counter(Stats, Key) ->
    case Stats of
        #{Key := V} when is_integer(V) -> V;
        _ -> 0
    end.

%% Labeled counter families into "<label>"-keyed maps:
%% dispatch_worker keys are {dispatch_worker, Node, ProviderId} ->
%% "<node>/<provider>"; probe keys are {probe, ProviderId} ->
%% "<provider>". Only picks WITH provider context count (the pool
%% skips undefined providers at bump time — see
%% maybe_bump_dispatch_worker/2).
labeled_counters(Stats, dispatch_worker) ->
    maps:from_list([
        {pair_bin(Node, ProviderId), V}
     || {{dispatch_worker, Node, ProviderId}, V} <- maps:to_list(Stats), is_integer(V)
    ]);
labeled_counters(Stats, probe) ->
    maps:from_list([
        {to_bin(P), V}
     || {{probe, P}, V} <- maps:to_list(Stats), is_integer(V)
    ]).

pair_bin(Node, ProviderId) ->
    <<(to_bin(Node))/binary, "/", (to_bin(ProviderId))/binary>>.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(F) when is_float(F) -> float_to_binary(F, [short]);
to_bin(_) -> <<"unknown">>.

%% rtt_ms: expired rows dropped at READ time, latest-per-pair comes
%% free (sched_rtt is a set keyed by the composite pair), capped at
%% the ?RTT_JSON_CAP most recent by SampledAtMono; the overflow
%% aggregate is ALWAYS present ({"count":0,"max_ms":0.0} when empty).
rtt_json(Rows, Now) when is_list(Rows) ->
    Fresh = [
        Row
     || {{_Node, _ProviderId}, Ms, _Source, _SampledAt, ExpiresAt} = Row <- Rows,
        ExpiresAt > Now,
        is_number(Ms)
    ],
    Sorted = lists:sort(
        fun({_, _, _, A1, _}, {_, _, _, A2, _}) -> A1 >= A2 end,
        Fresh
    ),
    {Top, Overflow} = safe_split(?RTT_JSON_CAP, Sorted),
    RttMap = maps:from_list([
        {pair_bin(Node, ProviderId), Ms * 1.0}
     || {{Node, ProviderId}, Ms, _Source, _SampledAt, _ExpiresAt} <- Top
    ]),
    OtherMax =
        case [Ms || {_, Ms, _, _, _} <- Overflow] of
            [] -> 0.0;
            MsList -> lists:max(MsList) * 1.0
        end,
    {RttMap, #{count => length(Overflow), max_ms => OtherMax}};
rtt_json(_, _Now) ->
    {#{}, #{count => 0, max_ms => 0.0}}.

safe_split(N, List) when N >= length(List) ->
    {List, []};
safe_split(N, List) ->
    lists:split(N, List).

reserve_inflight_json(Rows) when is_list(Rows) ->
    maps:from_list([
        {to_bin(Node), Count}
     || {Node, Count} <- Rows,
        is_integer(Count)
    ]);
reserve_inflight_json(_) ->
    #{}.

%% The DISPLAY value from sample 1 (spec A.4: selection admits the
%% EWMA only at >= 3 samples, the gauge shows the raw value).
health_ewma_json(Ewma) when is_map(Ewma) ->
    maps:from_list([
        {to_bin(Node), E * 1.0}
     || {Node, E} <- maps:to_list(Ewma),
        is_number(E)
    ]);
health_ewma_json(_) ->
    #{}.

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
