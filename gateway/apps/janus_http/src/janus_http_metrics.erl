%%%-------------------------------------------------------------------
%%% @doc GET /metrics — Prometheus text exposition on the admin plane.
%%% Same token/loopback auth as /stats (janus_admin_auth).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_metrics).

-behaviour(cowboy_handler).

-export([init/2]).
%% v2.1 C.1 sched-series builders (eunit — the cap/overflow logic is
%% pure over the pool counters map).
-export([one_label_rows/4, dispatch_worker_rows/1, sched_workers_available/1]).
%% Wire-enc series builder (spec 2026-10-12-wire-compression D9 —
%% eunit: pure over the pool's aggregated wire_enc view).
-export([wire_enc_rows/1]).

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
        {SchedRows, SchedGauges} = sched_series(),
        Rows = janus_metrics:snapshot() ++ DropRows ++ LbRows ++ fleet_rows() ++ SchedRows,
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
            ] ++ fleet_gauges() ++ SchedGauges,
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
%%% Scheduler v2.1 series (spec Part C.1,
%%% `2026-10-11-scheduler-v2.1-hardening.md`). ONE
%%% janus_worker_pool:sched_stats/0 read per scrape — the SAME single
%%% F7 snapshot /stats/sched uses — guarded by a whereis check (no
%%% call into a dead name; on a worker the pool series are simply
%%% ABSENT, never a crash). The dist counters are a separate PER-NODE
%%% local read (two reads per scrape, stated) and render on master AND
%%% worker — a dist storm is exactly when the worker side matters.
%%%
%%% Cardinality (F4): counter label sets are NEVER evicted (eviction
%%% breaks monotonicity/rate) — each labeled family is capped at 256
%%% label sets, the sorted-first 256 render and the REMAINDER sums
%%% into the family's label-free `_overflow_total` accumulator. Gauges
%%% render deterministically (sorted; rtt cells churn naturally with
%%% the 10-min TTL — no eviction flapping).
%%%--------------------------------------------------------------------

-define(SCHED_FAMILY_CAP, 256).

%% ONE sched_stats/0 read per scrape drives BOTH the counter rows and
%% the gauges (F7: the same single snapshot /stats/sched uses). The
%% dist counters are a SEPARATE per-node local read (two reads per
%% scrape in total — stated).
sched_series() ->
    {DistRows, DistGauges} = dist_series(),
    {PoolRows, PoolGauges} = pool_series(),
    {DistRows ++ PoolRows, DistGauges ++ PoolGauges}.

%% Dist series (v2.1 C.2): per-node local read, rendered everywhere
%% (master AND worker run janus_dist_monitor). OTP 27 has NO unbusy
%% notification — events + last-busy age is the deliverable; there is
%% deliberately no busy-ms series.
dist_series() ->
    case catch janus_dist_monitor:stats() of
        #{busy_events_total := N, last_busy_age_ms := Age} when
            is_integer(N), N >= 0
        ->
            Rows = [{{counter, sched_dist_busy_events_total, []}, N}],
            Gauges =
                case is_number(Age) andalso Age >= 0 of
                    %% Rendered ONLY once an event has fired (null when
                    %% never busy — a gauge must not fabricate a 0 age).
                    true -> [{sched_dist_last_busy_age_ms, Age, #{}}];
                    false -> []
                end,
            {Rows, Gauges};
        _ ->
            {[], []}
    end.

pool_series() ->
    case whereis(janus_worker_pool) of
        undefined ->
            %% Worker node / pool down: pool-derived series are ABSENT
            %% (sched_stats/0 is master-only) — the dist rows still
            %% render, never a call into a dead name.
            {[], []};
        Pid ->
            case catch janus_worker_pool:sched_stats() of
                Stats when is_map(Stats) ->
                    {pool_counter_rows(Stats), pool_gauges(Pid, Stats)};
                _ ->
                    {[], []}
            end
    end.

pool_counter_rows(Stats) ->
    Ctr = fun(Key) -> counter_int(Stats, Key) end,
    [
        %% Label-free counters (the spec C.1 enumeration).
        {{counter, sched_capacity_exhausted_total, []}, Ctr(capacity_exhausted)},
        {{counter, sched_health_demote_total, []}, Ctr(health_demote)},
        {{counter, sched_reserve_purged_total, []}, Ctr(reserve_purged)},
        {{counter, sched_note_inflight_deprecated_total, []}, Ctr(note_inflight_deprecated)},
        {{counter, sched_release_barrier_timeout_total, []}, Ctr(release_barrier_timeout)},
        {{counter, sched_knobs_off_total, []}, Ctr(knobs_off)}
    ]
    %% Enum-bounded label sets (geo_match: 3 values; dispatch_local:
    %% the reason enum incl. unary_fallback; probe_skip: five v2
    %% reasons; rtt_dropped: negative/non_finite).
    ++ one_label_rows(Stats, geo_match, sched_geo_match_total, <<"source">>)
    ++ one_label_rows(Stats, dispatch_local, sched_dispatch_local_total, <<"reason">>)
    ++ one_label_rows(Stats, probe_skip, sched_probe_skip_total, <<"reason">>)
    ++ one_label_rows(Stats, rtt_dropped, sched_rtt_dropped_total, <<"reason">>)
    %% Fleet/provider-bounded label sets — capped per family (F4).
    ++ one_label_rows(Stats, probe, sched_probe_total, <<"provider">>)
    ++ dispatch_worker_rows(Stats)
    %% Wire-enc family (2026-10-12 spec D9): enum-bounded — no cap.
    ++ wire_enc_rows(Stats).

counter_int(Stats, Key) ->
    case Stats of
        #{Key := V} when is_integer(V), V >= 0 -> V;
        _ -> 0
    end.

%% One-label counter families (`{Prefix, Label} => V` keys in the pool
%% counters map) with the per-family cap: the sorted-first
%% ?SCHED_FAMILY_CAP label sets render; the remainder sums into
%% `{counter, Metric_overflow_total, []}`.
one_label_rows(Stats, Prefix, Metric, LabelKey) ->
    Labeled = [
        {janus_metrics:to_bin(L), V}
     || {{P, L}, V} <- maps:to_list(Stats), P =:= Prefix, is_integer(V), V >= 0
    ],
    {Kept, Overflow} = cap_family(lists:sort(Labeled), Metric),
    Rows = [
        {{counter, Metric, [{LabelKey, LBin}]}, V}
     || {LBin, V} <- Kept
    ],
    case Overflow of
        0 -> Rows;
        _ -> Rows ++ [{{counter, overflow_metric(Metric), []}, Overflow}]
    end.

%% dispatch_worker_total{node, provider} — the two-label family
%% (cap 256; 4-node x 20-provider fleets fit, spec C.1).
dispatch_worker_rows(Stats) ->
    Labeled = [
        {{janus_metrics:to_bin(N), janus_metrics:to_bin(P)}, V}
     || {{dispatch_worker, N, P}, V} <- maps:to_list(Stats), is_integer(V), V >= 0
    ],
    {Kept, Overflow} = cap_family(lists:sort(Labeled), sched_dispatch_worker_total),
    Rows = [
        {{counter, sched_dispatch_worker_total, [
            {<<"node">>, NB}, {<<"provider">>, PB}
        ]}, V}
     || {{NB, PB}, V} <- Kept
    ],
    case Overflow of
        0 -> Rows;
        _ -> Rows ++ [{{counter, overflow_metric(sched_dispatch_worker_total), []}, Overflow}]
    end.

%%%--------------------------------------------------------------------
%%% Wire-enc series (spec 2026-10-12-wire-compression D9, PR1 Task C)
%%%--------------------------------------------------------------------

%% The pool's aggregated `wire_enc` view (master-local decode counters
%% + relayed worker snapshots — the SAME single sched_stats read the
%% /stats/sched section uses) rendered as prometheus counter families:
%% chunks_total{dir,enc} (2x2 — identity|zlib partition messages, no
%% plain bucket), bytes_total{dir,enc} (2x3 — plain is SUPPLEMENTARY,
%% never summed with the wire buckets), plus the label-free CPU/fail
%% totals. Label sets are FIXED-ENUM (the geo_match precedent — no cap
%% needed); only series PRESENT in the aggregated map render (a
%% counter must never report a fabricated 0 — the usage-drop idiom;
%% the /stats/sched JSON side carries the full zeroed enum instead).
%% Rows are sorted for deterministic output (the renderer re-sorts per
%% family anyway).
wire_enc_rows(Stats) ->
    case Stats of
        #{wire_enc := Agg} when is_map(Agg) ->
            Rows = lists:filtermap(
                fun({K, V}) ->
                    case is_integer(V) andalso V >= 0 of
                        true -> wire_enc_row(K, V);
                        false -> false
                    end
                end,
                maps:to_list(Agg)
            ),
            %% Name-based sort (atom term order is not name order
            %% across the BEAM — the renderer's own name_sort rule);
            %% deterministic output for tests and diffs.
            lists:sort(
                fun({{counter, M1, L1}, _}, {{counter, M2, L2}, _}) ->
                    {atom_to_binary(M1, utf8), L1} =< {atom_to_binary(M2, utf8), L2}
                end,
                Rows
            );
        _ ->
            []
    end.

wire_enc_row({wire_enc_chunks_total, {Dir, Enc}}, V) ->
    wire_enc_labeled_row(wire_enc_chunks_total, Dir, Enc, [identity, zlib], V);
wire_enc_row({wire_enc_bytes_total, {Dir, Enc}}, V) ->
    wire_enc_labeled_row(wire_enc_bytes_total, Dir, Enc, [identity, zlib, plain], V);
wire_enc_row({upstream_enc_unsolicited_total, {in, gzip}}, V) ->
    %% PR2 (spec D9/F5): the unsolicited-gzip ops signal — a fixed
    %% single-label series (dir=in, enc=gzip only). BINARY labels —
    %% the renderer's escape/1 does binary:replace on values (atoms
    %% would badarg the whole /metrics scrape; ocr review critical).
    {true, {
        {counter, upstream_enc_unsolicited_total, [
            {<<"dir">>, <<"in">>}, {<<"enc">>, <<"gzip">>}
        ]},
        V
    }};
wire_enc_row(Metric, V) when
    Metric =:= wire_enc_deflate_time_us_total;
    Metric =:= wire_enc_inflate_time_us_total;
    Metric =:= wire_enc_inflate_fail_total;
    Metric =:= wire_enc_bad_config_total
->
    {true, {{counter, Metric, []}, V}};
wire_enc_row(_K, _V) ->
    %% Not a D9 family key (the pool's ingest normalizer already
    %% strips these — defense in depth for hand-built stats maps).
    false.

wire_enc_labeled_row(Metric, Dir, Enc, Enum, V) ->
    case lists:member(Dir, [out, in]) andalso lists:member(Enc, Enum) of
        true ->
            {true, {{counter, Metric, [
                {<<"dir">>, atom_to_binary(Dir, utf8)},
                {<<"enc">>, atom_to_binary(Enc, utf8)}
            ]}, V}};
        false ->
            false
    end.

%% Sorted label lists: keep the first Cap, sum the rest (deterministic
%% — the same label sets survive every scrape while under the cap, so
%% monotonicity per series is preserved).
cap_family(Sorted, _Metric) when length(Sorted) =< ?SCHED_FAMILY_CAP ->
    {Sorted, 0};
cap_family(Sorted, _Metric) ->
    {Kept, Dropped} = lists:split(?SCHED_FAMILY_CAP, Sorted),
    {Kept, lists:sum([V || {_, V} <- Dropped])}.

overflow_metric(Metric) ->
    %% Metric already carries the `sched_` prefix; a trailing `_total`
    %% swaps for `_overflow_total` (sched_dispatch_worker_total ->
    %% sched_dispatch_worker_overflow_total — the registered family),
    %% anything else appends.
    Bin = atom_to_binary(Metric, utf8),
    Suffix = <<"_total">>,
    Size = byte_size(Bin) - byte_size(Suffix),
    Out =
        case Size > 0 andalso binary:part(Bin, Size, byte_size(Suffix)) =:= Suffix of
            true -> <<(binary:part(Bin, 0, Size))/binary, "_overflow_total">>;
            false -> <<Bin/binary, "_overflow_total">>
        end,
    binary_to_atom(Out, utf8).

pool_gauges(Pid, Stats) ->
    Knobs = maps:get(knobs, Stats, #{}),
    HealthEwma = maps:get(health_ewma, Stats, #{}),
    RttRows = maps:get(rtt_rows, Stats, []),
    Workers = maps:get(workers, Stats, []),
    Now = erlang:monotonic_time(millisecond),
    [
        %% snapshot_gen lives in the pool's counters table but is a
        %% GENERATION, not a rate — rendered as a gauge (spec C.1).
        {sched_snapshot_gen, counter_int(Stats, snapshot_gen), #{}},
        {sched_pool_message_queue_len, queue_len(Pid), #{}},
        {sched_workers_available, sched_workers_available(Workers), #{}},
        {sched_knob_geo, bool01(maps:get(geo_enabled, Knobs, false)), #{}},
        {sched_knob_rtt, bool01(maps:get(rtt_enabled, Knobs, maps:get(rtt, Knobs, false))), #{}},
        {sched_knob_health, bool01(maps:get(health_enabled, Knobs, maps:get(health, Knobs, false))), #{}},
        {sched_knob_probe, bool01(maps:get(probe, Knobs, false)), #{}}
    ]
    ++ [
        {sched_health_ewma_ms, E * 1.0, #{<<"node">> => janus_metrics:to_bin(N)}}
     || {N, E} <- maps:to_list(HealthEwma), is_number(E)
    ]
    ++ [
        {sched_rtt_ms, Ewma * 1.0, #{
            <<"node">> => janus_metrics:to_bin(N),
            <<"provider">> => janus_metrics:to_bin(P)
        }}
     || {{N, P}, _Ms, _Source, _SampledAt, ExpiresAt, Ewma, _Count} <- RttRows,
        ExpiresAt > Now,
        is_number(Ewma)
    ].

%% The B.1 success signal: the pool gen_server's mailbox depth. 0 on a
%% process_info failure (never crash the scrape).
queue_len(Pid) ->
    case process_info(Pid, message_queue_len) of
        {message_queue_len, N} when is_integer(N) -> N;
        _ -> 0
    end.

%% From the single F7 snapshot: hello'd, non-draining members (the
%% same class janus_worker_pool:available/0 counts — no second call).
sched_workers_available(Workers) when is_list(Workers) ->
    length([
        W
     || W <- Workers,
        is_map(W),
        maps:get(status, W, up) =:= up,
        maps:get(dispatchable, W, false) =:= true
    ]);
sched_workers_available(_) ->
    0.

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

%% Master: live hello'd non-draining pool size. Worker / absent role or
%% pool → 0 (no gen_server:call, no scrape warning spam).
workers_available_gauge() ->
    case safe_role() of
        master ->
            case whereis(janus_worker_pool) of
                undefined ->
                    0;
                _ ->
                    gauge_val(fun janus_worker_pool:available/0, 0, workers_available)
            end;
        _ ->
            0
    end.

safe_role() ->
    try
        janus_role:get()
    catch
        error:_ ->
            undefined
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
