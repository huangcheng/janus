%%%-------------------------------------------------------------------
%%% @doc Read-only gateway stats endpoint for the Python dashboard to
%%% poll. Token-authenticated via JANUS_STATS_TOKEN; no session/CSRF.
%%% GET /stats      — node health + counters
%%% GET /stats/logs — recent log events (from janus_log_tail)
%%% GET /stats/ops-events — cursor-drainable ops ring (janus_ops_tail;
%%%                    ?boot_id=&after_idx=&limit=, failure-observability §4.2)
%%% GET /stats/health — failure-observability live snapshot (spec
%%%                    2026-10-13 §4.1): boot_id, cool[]/cool_ids[],
%%%                    rates[]/degraded_ids/rates_evicted from
%%%                    janus_lb, ops_ring meta; pure assembly is
%%%                    health_json/1; tasks[] from janus_task_run:snapshot/0.
%%%                    Master only (503 on a worker).
%%% GET /stats/sched — scheduler v2 pinned surface (spec Part C; the
%%%                    pure assembly is sched_json/1, eunit-tested).
%%%                    v2.1 additive keys: `workers` array (A.3),
%%%                    `knobs_off_total` (C.4), `git_sha` (C.3) and
%%%                    `dist` (C.2 — this node's busy_dist_port
%%%                    counters, a per-node local read that renders on
%%%                    master AND worker); schema_version stays 1.
%%%                    Wire-enc additive section (spec
%%%                    2026-10-12-wire-compression D9, PR1 Task C):
%%%                    `wire_enc` — master-local codec counters +
%%%                    relayed worker snapshots (workers run no
%%%                    `:8090`; the load cast is their telemetry
%%%                    path), aggregated by the pool.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_gateway_stats).

-behaviour(cowboy_handler).

-export([init/2, sched_json/1, health_json/1]).

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
        %% Master/worker role for Maintenance master discovery
        %% (settings hot-knobs spec §5.1).
        role => role_bin(),
        %% Failover/entitlement counters (requests_retried,
        %% failovers_exhausted, entitlement_failopen, ...).
        lb => janus_lb:stats(),
        usage => Usage,
        usage_writer => Usage,
        %% TF-A.0b capability (reorder spec Hard sequencing): true once
        %% migration 018_usage_attempt_rows is applied — the dashboard
        %% leader's pre-write mirror polls this before enabling the
        %% reorder loop. The ingest-guard refusal counter rides along.
        usage_attempt_rows => safe_bool(fun janus_usage:usage_attempt_rows/0),
        reorder_enabled_refused_total => reorder_refused_total(),
        %% Local-judge SPEC: dashboard Router page polls /stats.auto for
        %% readiness (local_ready / downloading / error). Catch-guarded —
        %% janus_auto may be absent on pure workers.
        auto => safe_auto_snapshot()
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
handle(<<"GET">>, [<<"ops-events">>], Req) ->
    %% Cursor-drainable ops ring (failure-observability §4.2). Master
    %% only — workers run no janus_ops_tail (503, never a 500).
    BootId = qs_bin(Req, <<"boot_id">>),
    AfterIdx = qs_int(Req, <<"after_idx">>, 0, 0, 16#7FFFFFFFFFFFFFFF),
    Limit = qs_int(Req, <<"limit">>, 500, 1, janus_ops_tail:capacity()),
    case janus_ops_tail:recent_after(BootId, AfterIdx, Limit) of
        {ok, Page} ->
            reply_json(200, Page, Req);
        {error, _} ->
            reply_json(
                503,
                #{error => #{code => <<"ops_tail_unavailable">>, message => <<"janus_ops_tail not running">>}},
                Req
            )
    end;
handle(<<"GET">>, [<<"health">>], Req) ->
    %% Cool view FIRST: building it runs the expiry sweeper, so the
    %% `clear/expired` edges it emits are (best effort — cast from the LB
    %% process vs call from this one carry no cross-sender ordering
    %% guarantee) inside the ring bounds read next. The dashboard's
    %% reconcile pass is the backstop for a missed edge.
    %% Rates snapshot is a serialized LB call (advances buckets +
    %% joins the live cooling set) — take it after cool so the
    %% `cooling` flags match the cool[] just emitted.
    View = janus_lb:cool_snapshot(),
    Rates = janus_lb:rates_snapshot(),
    case janus_ops_tail:meta() of
        {ok, Meta} ->
            reply_json(
                200,
                health_json(#{
                    now_wall_ms => erlang:system_time(millisecond),
                    cool_view => View,
                    rates_view => Rates,
                    tasks_view => janus_task_run:snapshot(),
                    ops_meta => Meta
                }),
                Req
            );
        {error, _} ->
            reply_json(
                503,
                #{error => #{code => <<"ops_tail_unavailable">>, message => <<"janus_ops_tail not running">>}},
                Req
            )
    end;
handle(<<"POST">>, [<<"mmdb">>, <<"reload">>], Req) ->
    %% After dashboard/deploy refreshes GeoLite2 on disk — re-bind locus.
    %% Master-only (workers have no mmdb / no janus_geo child).
    case catch janus_geo:reload_mmdb() of
        ok ->
            reply_json(200, #{ok => true, mmdb_present => true, geo_enabled => janus_geo:geo_enabled()}, Req);
        {error, mmdb_missing} ->
            reply_json(409, #{error => #{code => <<"mmdb_missing">>, message => <<"JANUS_MMDB_PATH absent or not a file">>}}, Req);
        {error, reload_in_progress} ->
            reply_json(409, #{error => #{code => <<"reload_in_progress">>, message => <<"mmdb reload already in flight">>}}, Req);
        {error, Reason} ->
            reply_json(500, #{error => #{code => <<"mmdb_reload_failed">>, message => fmt_reason(Reason)}}, Req);
        {'EXIT', {noproc, _}} ->
            reply_json(503, #{error => #{code => <<"geo_unavailable">>, message => <<"janus_geo not running (worker node?)">>}}, Req);
        {'EXIT', Reason} ->
            reply_json(500, #{error => #{code => <<"mmdb_reload_failed">>, message => fmt_reason(Reason)}}, Req)
    end;
handle(_, _, Req) ->
    reply_json(405, #{error => #{code => <<"method_not_allowed">>}}, Req).

%%%===================================================================
%%% /stats/health — PURE JSON assembly (failure-observability §4.1)
%%%===================================================================

%% @doc `Data`: `now_wall_ms` (injected wall clock), `cool_view`
%% (`janus_cool_view:project/3` result), `rates_view`
%% (`janus_rate_view:project/3` result), `ops_meta`
%% (`janus_ops_tail:meta/0`), optional `tasks_view`
%% (`janus_task_run:snapshot/0` — registry-driven, `instrumented` bool
%% per row; `[]` when absent).
-spec health_json(map()) -> map().
health_json(#{now_wall_ms := NowMs, cool_view := View, ops_meta := Meta} = Data) ->
    Rates = maps:get(rates_view, Data, #{}),
    #{
        boot_id => maps:get(boot_id, Meta),
        schema_version => 1,
        snapshot_ts => rfc3339_ms(NowMs),
        cool => maps:get(cool, View, []),
        cool_ids => maps:get(cool_ids, View, []),
        cool_count => maps:get(cool_count, View, 0),
        cool_ids_overflow => maps:get(cool_ids_overflow, View, false),
        cool_provider_counts => maps:get(cool_provider_counts, View, []),
        rates => maps:get(rates, Rates, []),
        rates_truncated => maps:get(rates_truncated, Rates, false),
        degraded_ids => maps:get(degraded_ids, Rates, []),
        degraded_ids_overflow => maps:get(degraded_ids_overflow, Rates, false),
        rates_evicted => maps:get(rates_evicted, Rates, []),
        rates_evicted_overflow => maps:get(rates_evicted_overflow, Rates, false),
        tasks => maps:get(tasks_view, Data, []),
        ops_ring => maps:with([capacity, next_idx, oldest_idx, overflow_count], Meta)
    }.

rfc3339_ms(Ms) ->
    list_to_binary(
        calendar:system_time_to_rfc3339(Ms, [{unit, millisecond}, {offset, "Z"}])
    ).

%%%===================================================================
%%% /stats/sched — data collection (impure) + pure JSON assembly
%%%===================================================================

-define(RTT_JSON_CAP, 64).

%% Impure collector: one tolerant call per source. `stats` is
%% janus_worker_pool:sched_stats/0 (counters + knobs + display EWMA +
%% raw rtt/reserve rows, assembled atomically by the pool);
%% `geo_disabled` comes from janus_geo's own counters (Task A bump
%% site; tolerant call, no janus_geo change needed); `now_mono` is
%% injected so the assembly stays pure/testable. v2.1 C.2/C.3: `dist`
%% (this node's busy_dist_port counters — a PER-NODE local read that
%% works on master AND worker; workers run no pool, the handler must
%% still answer) and `git_sha` (this image's stamped SHA, boot ->
%% persistent_term) are the same by-design local-read class.
sched_data() ->
    #{
        stats => safe_map(fun janus_worker_pool:sched_stats/0),
        now_mono => erlang:monotonic_time(millisecond),
        geo_disabled => maps:get(geo_disabled, safe_map(fun janus_geo:counters/0), 0),
        dist => safe_map(fun janus_dist_monitor:stats/0),
        git_sha => janus_build:sha()
    }.

safe_map(Fun) ->
    case catch Fun() of
        M when is_map(M) -> M;
        _ -> #{}
    end.

safe_bool(Fun) ->
    case catch Fun() of
        true -> true;
        _ -> false
    end.

safe_auto_snapshot() ->
    safe_map(fun janus_auto:snapshot/0).

%% The auto_router_reorder.enabled ingest-guard refusal counter
%% (janus_config writes the persistent_term value; single writer, the
%% config gen_server — a plain read is race-free enough for a counter).
reorder_refused_total() ->
    try
        case persistent_term:get({janus, reorder_refused_total}, 0) of
            N when is_integer(N), N >= 0 -> N;
            _ -> 0
        end
    catch
        _:_ -> 0
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
        geo_desired => maps:get(geo_desired, Knobs, null),
        rtt_enabled => maps:get(rtt_enabled, Knobs, maps:get(rtt, Knobs, false)),
        health_enabled => maps:get(health_enabled, Knobs, maps:get(health, Knobs, false)),
        probe_enabled => maps:get(probe, Knobs, false),
        unary_fallback_enabled => maps:get(unary_fallback, Knobs, false),
        probe_max_hourly => maps:get(probe_max_hourly, Knobs, 10),
        model_sync_interval_sec => maps:get(model_sync_interval_sec, Knobs, 21600),
        knobs_source => maps:get(knobs_source, Knobs, null),
        mmdb_present => maps:get(mmdb_present, Knobs, false),
        fleet_desired => maps:get(fleet_desired, Knobs, null),
        fleet_effective => maps:get(fleet_effective, Knobs, false),
        sched_geo_refused_total => maps:get(sched_geo_refused_total, Knobs, 0),
        snapshot_gen => Ctr(snapshot_gen),
        geo_match_total => #{
            region_tag => Ctr({geo_match, region_tag}),
            auto => Ctr({geo_match, auto}),
            none => Ctr({geo_match, none})
        },
        %% Affinity pin outcome (spec 2026-10-22 §6/D4, ADDITIVE key —
        %% schema_version stays 1): fixed-enum buckets with 0 defaults,
        %% exactly like geo_match_total. `honoured' = the declared pin
        %% reached its node; `miss' = a pin was declared and the pick
        %% fell through to the tiers (fail-open preserved — the miss is
        %% loud here, never a refusal); `none' = no pin declared. The
        %% three sum to the pick total on this node.
        affinity_total => #{
            honoured => Ctr({affinity, honoured}),
            miss => Ctr({affinity, miss}),
            none => Ctr({affinity, none})
        },
        %% The MISS breakdown by declared pin label (`{affinity_miss,
        %% Pin}` keys) — the label names the §7.6 typo directly. Bounded
        %% cardinality: one affinity_node per provider row, so the
        %% distinct labels cannot grow with traffic (empty map when no
        %% miss has ever fired, same discipline as geo_mismatch_total).
        affinity_miss_total => labeled_counters(Stats, affinity_miss),
        dispatch_worker_total => labeled_counters(Stats, dispatch_worker),
        dispatch_local_total => #{
            empty_pool => Ctr({dispatch_local, empty_pool}),
            capacity => Ctr({dispatch_local, capacity}),
            drained => Ctr({dispatch_local, drained}),
            drained_pin => Ctr({dispatch_local, drained_pin}),
            send_fail => Ctr({dispatch_local, send_fail}),
            ack_miss => Ctr({dispatch_local, ack_miss}),
            %% v2.1 Part E: the unary worker_lost fallback reason (a
            %% VALUE addition to the enum — schema_version stays 1).
            unary_fallback => Ctr({dispatch_local, unary_fallback})
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
        %% v2.1 A.3: the repo-side workers array (additive key).
        %% schema_version stays 1; NOTE (ocr): the rtt_ms map VALUE
        %% semantics changed in v2.1 from raw sample to the row's
        %% incremental EWMA (one canonical number, spec B.2) — a
        %% documented value-semantics change under an existing key.
        workers => workers_json(maps:get(workers, Stats, [])),
        %% Geo-affinity (spec 2026-10-11, additive): edge-triggered
        %% mismatch counter per node + the worker-geo knob view.
        geo_mismatch_total => labeled_by_node(Stats, geo_mismatch),
        worker_geo_enabled =>
            case Knobs of
                #{worker_geo_enabled := Wge} -> Wge =:= true;
                _ -> false
            end,
        geo_disabled_total => GeoDisabled,
        fleet_worker_report_mismatch_total => Ctr(fleet_worker_report_mismatch),
        %% v2.1 C.4: knob-off blindness guard counter (0 until the
        %% first admission on an all-off pool; additive key).
        knobs_off_total => Ctr(knobs_off),
        %% v2.1 C.3: this image's stamped git SHA (additive key; the
        %% literal <<"unknown">> when the build-arg was missing — never
        %% empty). Workers also report per-worker shas in the workers
        %% array (hello git_sha) — mixed-image fleets are visible.
        git_sha => to_bin(maps:get(git_sha, Data, <<"unknown">>)),
        %% v2.1 C.2: this node's busy_dist_port counters (per-node
        %% local read — every node renders its OWN; no aggregation).
        dist => dist_json(maps:get(dist, Data, #{})),
        %% Wire compression (spec 2026-10-12-wire-compression D9,
        %% PR1 Task C — ADDITIVE key): the pool's aggregated view
        %% (master-local decode counters + relayed worker snapshots,
        %% `janus_worker_pool:aggregate_wire_enc/2`). schema_version
        %% stays 1.
        wire_enc => wire_enc_json(maps:get(wire_enc, Stats, #{}))
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
%% maybe_bump_dispatch_worker/2). affinity_miss keys are
%% {affinity_miss, PinLabel} -> "<pin>" (the declared pin that was not
%% honoured; bounded by the providers table — one label per pinned row).
labeled_counters(Stats, probe) ->
    maps:from_list([
        {to_bin(P), V}
     || {{probe, P}, V} <- maps:to_list(Stats), is_integer(V)
    ]);
labeled_counters(Stats, dispatch_worker) ->
    maps:from_list([
        {pair_bin(Node, ProviderId), V}
     || {{dispatch_worker, Node, ProviderId}, V} <- maps:to_list(Stats), is_integer(V)
    ]);
labeled_counters(Stats, affinity_miss) ->
    maps:from_list([
        {to_bin(Pin), V}
     || {{affinity_miss, Pin}, V} <- maps:to_list(Stats), is_integer(V)
    ]).

%% Node-labeled counter family ({Name, Node} keys) — geo-affinity
%% geo_mismatch_total{node} (schema additive; every read defaults 0).
labeled_by_node(Stats, Name) when is_atom(Name) ->
    maps:from_list([
        {to_bin(Node), V}
     || {{N, Node}, V} <- maps:to_list(Stats), N =:= Name, is_integer(V)
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
%% v2.1 B.2: the VALUE is the row's incremental EWMA (the ONE
%% canonical number — raw RttMs never surfaces here; row shape is the
%% 7-tuple with Ewma + SampleCount).
rtt_json(Rows, Now) when is_list(Rows) ->
    Fresh = [
        Row
     || {{_Node, _ProviderId}, _Ms, _Source, _SampledAt, ExpiresAt, Ewma, _Count} = Row <- Rows,
        ExpiresAt > Now,
        is_number(Ewma)
    ],
    Sorted = lists:sort(
        fun({_, _, _, A1, _, _, _}, {_, _, _, A2, _, _, _}) -> A1 >= A2 end,
        Fresh
    ),
    {Top, Overflow} = safe_split(?RTT_JSON_CAP, Sorted),
    RttMap = maps:from_list([
        {pair_bin(Node, ProviderId), Ewma * 1.0}
     || {{Node, ProviderId}, _Ms, _Source, _SampledAt, _ExpiresAt, Ewma, _Count} <- Top
    ]),
    OtherMax =
        case [Ewma || {_, _, _, _, _, Ewma, _} <- Overflow] of
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

%% v2.1 A.3 workers array: the pool's workers_view rows normalized to
%% JSON-safe values (node/status/binaries via to_bin; region undefined
%% and capacity infinity => null; health_ewma_ms unknown => null;
%% would_demote true/false/null passes through; the atom `null` is
%% thoas's JSON null). The pool renders the same 14-field + git_sha
%% set; this layer only normalizes representation.
workers_json(Rows) when is_list(Rows) ->
    [worker_json(R) || R <- Rows];
workers_json(_) ->
    [].

worker_json(R) when is_map(R) ->
    #{
        node => to_bin(maps:get(node, R, undefined)),
        status => to_bin(maps:get(status, R, up)),
        sticky => maps:get(sticky, R, false) =:= true,
        capacity => capacity_json(maps:get(capacity, R, infinity)),
        region => nullable_bin(maps:get(region, R, undefined)),
        sched_v => maps:get(sched_v, R, 1),
        draining => maps:get(draining, R, false) =:= true,
        inflight => maps:get(inflight, R, 0),
        %% Capacity observability (2026-10-28): the worker's latest
        %% self-reported beam split, MB (null before its first load
        %% report). Atom keys from the wire map become JSON names.
        mem_mb =>
            case maps:get(mem_mb, R, null) of
                #{t := T, p := P, b := B, e := E} when
                    is_integer(T), is_integer(P), is_integer(B), is_integer(E)
                ->
                    #{<<"total">> => T, <<"processes">> => P, <<"binary">> => B, <<"ets">> => E};
                _ ->
                    null
            end,
        dispatchable => maps:get(dispatchable, R, false) =:= true,
        dispatched_total => maps:get(dispatched_total, R, 0),
        health_ewma_ms => nullable_num(maps:get(health_ewma_ms, R, unknown)),
        rtt_ms_avg => nullable_num(maps:get(rtt_ms_avg, R, null)),
        rtt_sample_count => maps:get(rtt_sample_count, R, 0),
        would_demote => maps:get(would_demote, R, null),
        git_sha => to_bin(maps:get(git_sha, R, <<"unknown">>)),
        %% Geo-affinity additive fields (spec 2026-10-11): the overlay
        %% source/region, the mismatch gauge, the retain-window stamp
        %% and the worker's gw-echo health counters (display-only).
        geo_source =>
            case maps:get(geo_source, R, unset) of
                unset -> <<"unset">>;
                Src -> to_bin(Src)
            end,
        geo_region => nullable_bin(maps:get(geo_region, R, undefined)),
        geo_mismatch => maps:get(geo_mismatch, R, false) =:= true,
        egress_fetched_at =>
            case maps:get(egress_fetched_at, R, null) of
                N when is_integer(N), N > 0 -> N;
                _ -> null
            end,
        echo_ok_total => maps:get(echo_ok_total, R, 0),
        echo_fail_total => maps:get(echo_fail_total, R, 0)
    };
worker_json(_) ->
    #{}.

nullable_bin(undefined) ->
    null;
nullable_bin(null) ->
    null;
nullable_bin(B) when is_binary(B) ->
    B;
nullable_bin(A) when is_atom(A), A =/= null, A =/= undefined ->
    to_bin(A);
nullable_bin(_) ->
    null.

%% unknown => null (never "unknown" — the pool's raw display sentinel);
%% numbers pass as floats; anything else => null.
nullable_num(unknown) ->
    null;
nullable_num(null) ->
    null;
nullable_num(N) when is_number(N) ->
    N * 1.0;
nullable_num(_) ->
    null.

capacity_json(infinity) ->
    null;
capacity_json(N) when is_integer(N) ->
    N;
capacity_json(_) ->
    null.

%% v2.1 C.2: this node's busy_dist_port view. `last_busy_age_ms` is
%% null when no busy event has EVER fired (never a fabricated 0 —
%% "no event" and "event right now" must not alias); `last_busy_at_mono`
%% and the suspended pid/port ride along for display. OTP 27 has NO
%% unbusy notification (janus_dist_monitor header) — events + age is
%% the deliverable, there is no busy-ms accumulation.
dist_json(Dist) when is_map(Dist) ->
    #{
        busy_events_total =>
            case Dist of
                #{busy_events_total := N} when is_integer(N) -> N;
                _ -> 0
            end,
        last_busy_age_ms =>
            case Dist of
                #{last_busy_age_ms := A} when is_number(A) -> A * 1.0;
                _ -> null
            end,
        last_busy_at_mono =>
            case Dist of
                #{last_busy_at_mono := T} when is_integer(T) -> T;
                _ -> null
            end
    };
dist_json(_) ->
    #{busy_events_total => 0, last_busy_age_ms => null, last_busy_at_mono => null}.

%% Wire-enc section (D9, PR1 Task C): fixed-enum sub-maps carry EVERY
%% key with 0 defaults (the dispatch_local_total gate-assertion
%% discipline). `chunks_total` has NO plain bucket (identity|zlib
%% partition messages); `bytes_total` adds the SUPPLEMENTARY `plain`
%% bucket (pre-compression size of compressed messages — never summed
%% with the wire buckets). `bad_config_total` is Task A's DISTINCT
%% master-side wiring-fault counter: the §5 rollout gate requires
%% `inflate_fail_total` = 0 for the whole bake, and a local config
%% fault must never pollute that signal.
wire_enc_json(Agg) ->
    Ctr = fun(Key) ->
        case Agg of
            #{Key := V} when is_integer(V), V >= 0 -> V;
            _ -> 0
        end
    end,
    Chunks = fun(Dir) ->
        #{
            identity => Ctr({wire_enc_chunks_total, {Dir, identity}}),
            zlib => Ctr({wire_enc_chunks_total, {Dir, zlib}})
        }
    end,
    Bytes = fun(Dir) ->
        #{
            identity => Ctr({wire_enc_bytes_total, {Dir, identity}}),
            zlib => Ctr({wire_enc_bytes_total, {Dir, zlib}}),
            plain => Ctr({wire_enc_bytes_total, {Dir, plain}})
        }
    end,
    #{
        chunks_total => #{out => Chunks(out), in => Chunks(in)},
        bytes_total => #{out => Bytes(out), in => Bytes(in)},
        deflate_time_us_total => Ctr(wire_enc_deflate_time_us_total),
        inflate_time_us_total => Ctr(wire_enc_inflate_time_us_total),
        inflate_fail_total => Ctr(wire_enc_inflate_fail_total),
        bad_config_total => Ctr(wire_enc_bad_config_total),
        %% PR2 (spec D9/F5): unsolicited stream-gzip ops signal.
        upstream_enc_unsolicited_total =>
            Ctr({upstream_enc_unsolicited_total, {in, gzip}})
    }.

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

role_bin() ->
    try
        case janus_role:get() of
            master -> <<"master">>;
            worker -> <<"worker">>;
            Other when is_atom(Other) -> atom_to_binary(Other)
        end
    catch
        _:_ -> <<"unknown">>
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

qs_bin(Req, Name) ->
    case lists:keyfind(Name, 1, cowboy_req:parse_qs(Req)) of
        {_, Bin} when is_binary(Bin) -> Bin;
        _ -> <<>>
    end.

fmt_reason(Reason) when is_binary(Reason) ->
    Reason;
fmt_reason(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
fmt_reason(Reason) ->
    iolist_to_binary(io_lib:format("~0p", [Reason])).

reply_json(Status, Map, Req) ->
    Body = thoas:encode(Map),
    cowboy_req:reply(Status, #{
        <<"content-type">> => <<"application/json">>
    }, Body, Req).
