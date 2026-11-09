%%%-------------------------------------------------------------------
%%% @doc Render a janus_metrics snapshot as Prometheus text exposition.
%%% Pure, total, deterministic: grouped counters → histograms → gauges,
%%% name-sorted within each group; one HELP+TYPE per family (HELP
%%% omitted for unregistered families — they still render); histogram
%%% buckets zero-filled to the canonical ladder UNION any bound already
%%% present in ETS (a ladder edited between deploys never silently
%%% drops a series), numerically ascending with +Inf last; labels
%%% sorted by key with `le` appended last; floats via [short].
%%% Gauges are supplied by the caller (scrape-time reads) as
%%% {Name, Value, LabelsMap}.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_metrics_render).

-export([render/2, unit/1, units/0, family_names/0, help/1]).

%% Family registry: name => {type, help}. Drives TYPE/HELP lines.
%% Unregistered counter families still render — a series must never
%% silently vanish (that was the audit's bug class).
-define(FAMILIES, #{
    requests_total => {counter, <<"Client LLM requests (terminal outcomes).">>},
    requests_with_images_total => {counter, <<"Client LLM requests whose body carried image parts (image_url / image / input_image), by face.">>},
    upstream_requests_total => {counter, <<"Terminal client outcomes by provider (failover inner attempts excluded).">>},
    usage_writer_dropped_total => {counter, <<"Usage events dropped by the writer.">>},
    request_duration_seconds => {histogram, <<"End-to-end request duration (streams include client drain).">>},
    http_server_request_duration => {histogram, <<"http.server.request.duration (semconv). ADDITIVE to janus_request_duration_seconds, which keeps its own ladder.">>},
    gen_ai_client_inference_duration => {histogram, <<"gen_ai.client.inference.duration (semconv). The provider call only, from the upstream attempt's wall time.">>},
    gen_ai_client_inference_usage_input_tokens_total => {counter, <<"gen_ai.client.inference.usage.input_tokens (semconv). Billed input, cache included.">>},
    gen_ai_client_inference_usage_output_tokens_total => {counter, <<"gen_ai.client.inference.usage.output_tokens (semconv).">>},
    gen_ai_client_inference_usage_cache_read_input_tokens_total => {counter, <<"gen_ai.client.inference.usage.cache_read.input_tokens (semconv). Emitted only when non-zero.">>},
    gen_ai_client_inference_usage_cache_write_input_tokens_total => {counter, <<"gen_ai.client.inference.usage.cache_write.input_tokens (semconv). Emitted only when non-zero.">>},
    catalog_generation => {gauge, <<"Serving catalog generation.">>},
    catalog_ready => {gauge, <<"Serving catalog warm (1) or cold (0).">>},
    models_serving => {gauge, <<"Models in the serving catalog.">>},
    lb_routes_cooling => {gauge, <<"LB routes currently cooling down.">>},
    lb_stats_total => {counter, <<"LB counters from janus_lb:stats/0 (cumulative).">>},
    decisions_upstream_429_total => {counter, <<"Upstream Decisions 429 responses (Retry-After passthrough).">>},
    fleet_signals_tx_total => {counter, <<"Fleet signals broadcast (egress, knob-gated).">>},
    fleet_signals_rx_total => {counter, <<"Fleet signals received (ingress, pre-validation).">>},
    fleet_bad_ingress_total => {counter, <<"Fleet signals dropped at ingress validation (incl. judge-model mismatch).">>},
    fleet_remote_cool_last_resort_total => {counter, <<"Picks where the remote-cool consult was ignored to keep a last candidate.">>},
    fleet_commands_total => {counter, <<"Fleet commands executed, by command and outcome.">>},
    fleet_lease_holder => {gauge, <<"1 on the fleet lease holder node, 0 elsewhere.">>},
    fleet_mirror_rows => {gauge, <<"Rows currently held in fleet mirror tables.">>},
    usage_writer_buffered_rows => {gauge, <<"Usage writer buffered rows.">>},
    otel_export_spans_total => {counter, <<"Spans handed to the OTLP exporter, by result. `dropped_queue_full` is the exporter's own backpressure drop (the oldest span is evicted).">>},
    otel_export_batches_total => {counter, <<"OTLP export HTTP attempts (one batch = one POST), by result.">>},
    otel_export_queue_depth => {gauge, <<"Spans waiting in the exporter queue.">>},
    otel_export_enabled => {gauge, <<"1 when OTLP export is configured and switched on, else 0.">>},
    otel_export_last_success_age_seconds => {gauge, <<"Seconds since the last successful OTLP export. Absent until the first success.">>},
    otel_export_last_error => {gauge, <<"1 while the last export attempt is still failing, labelled with the failure class. Absent after a success.">>},
    uptime_seconds => {gauge, <<"VM wall-clock uptime.">>},
    workers_available => {gauge, <<"Dispatchable worker pool members (hello'd, non-draining).">>},
    build_info => {untyped, <<"Build/version info.">>},
    %% Scheduler v2.1 series (spec Part C.1 — pool series are master-
    %% only; dist counters render on every node).
    sched_geo_match_total => {counter, <<"Scheduler picks by geo comparator source.">>},
    sched_dispatch_local_total => {counter, <<"Master-side local executions by reason (worker dispatch bypassed/failed).">>},
    sched_dispatch_worker_total => {counter, <<"Worker dispatches by node and provider (capped at 256 label sets; excess in sched_dispatch_worker_overflow_total).">>},
    sched_dispatch_worker_overflow_total => {counter, <<"dispatch_worker label sets beyond the per-family cap, summed.">>},
    sched_capacity_exhausted_total => {counter, <<"Reservation rollbacks at worker capacity.">>},
    sched_health_demote_total => {counter, <<"Health-tier worker exclusions at pick time.">>},
    sched_probe_total => {counter, <<"Internal scheduler probes attempted per provider.">>},
    sched_probe_skip_total => {counter, <<"Probe candidates skipped by reason.">>},
    sched_rtt_dropped_total => {counter, <<"RTT samples dropped at ingest by reason.">>},
    sched_reserve_purged_total => {counter, <<"Reservation slots reclaimed by the 10-min purge.">>},
    sched_note_inflight_deprecated_total => {counter, <<"Deprecated v1 note_inflight casts received (counted no-op).">>},
    sched_release_barrier_timeout_total => {counter, <<"Release FIFO-ordering barrier timeouts (bookkeeping proceeded; rtt/ttfb casts may be lost).">>},
    sched_knobs_off_total => {counter, <<"Pool lifetimes admitted a worker with geo/health/rtt ALL off (0 or 1 per boot).">>},
    sched_dist_busy_events_total => {counter, <<"busy_dist_port suspensions on this node (no unbusy event exists — age below).">>},
    sched_snapshot_gen => {gauge, <<"Scheduler snapshot generation (dirty-flush + tick republishes).">>},
    sched_workers_available => {gauge, <<"Dispatchable pool members from the /stats/sched snapshot.">>},
    sched_health_ewma_ms => {gauge, <<"Per-worker TTFB health EWMA (ms, raw display value).">>},
    sched_rtt_ms => {gauge, <<"Per node/provider passive RTT EWMA (ms) — the row cell verbatim.">>},
    sched_pool_message_queue_len => {gauge, <<"Pool gen_server mailbox depth (the B.1 off-mailbox success signal).">>},
    sched_knob_geo => {gauge, <<"JANUS_SCHED_GEO effective state (1/0, boot-time).">>},
    sched_knob_rtt => {gauge, <<"JANUS_SCHED_RTT effective state (1/0, boot-time).">>},
    sched_knob_health => {gauge, <<"JANUS_SCHED_HEALTH effective state (1/0, boot-time).">>},
    sched_knob_probe => {gauge, <<"JANUS_SCHED_PROBE effective state (1/0, boot-time).">>},
    sched_dist_last_busy_age_ms => {gauge, <<"Milliseconds since the last busy_dist_port event on this node.">>},
    %% Wire compression (spec 2026-10-12-wire-compression D9 — PR1
    %% Task C: master-local + relayed worker snapshots, aggregated by
    %% the pool into the single sched_stats view).
    wire_enc_chunks_total => {counter, <<"Internal-hop wire messages by direction and encoding (each message exactly one of identity|zlib).">>},
    wire_enc_bytes_total => {counter, <<"Internal-hop wire bytes by direction and encoding; plain = pre-compression size of compressed messages (supplementary, never summed with the wire buckets).">>},
    wire_enc_deflate_time_us_total => {counter, <<"Worker-side deflate CPU in microseconds (relayed via the load cast).">>},
    wire_enc_inflate_time_us_total => {counter, <<"Master-side inflate CPU in microseconds.">>},
    wire_enc_inflate_fail_total => {counter, <<"Internal-hop inflate failures (wire corruption / cap exceeded) — the rollout gate requires this to stay 0.">>},
    wire_enc_bad_config_total => {counter, <<"Codec invocations rejected for a bad local config (distinct from wire corruption; never inflates inflate_fail_total).">>},
    %% PR2 (spec 2026-10-12-wire-compression D9/F5): unsolicited
    %% stream-gzip ops signal (decode handled; TTFB risk indicator).
    upstream_enc_unsolicited_total => {counter, <<"Stream responses arriving Content-Encoding: gzip when none was requested — provider/proxy flush-buffering TTFB risk signal.">>},
    %% janus-auto same-tier next-name failover (design 2026-10-15 D12).
    auto_tier_name_failover_total => {counter, <<"janus-auto same-tier next-name advances after Part C exhaustion (by tier).">>},
    auto_tier_name_failover_exhausted_total => {counter, <<"janus-auto next-name walk stopped (by tier and reason: all_cooling|no_eligible|budget|max_names).">>},
    auto_tier_name_skip_total => {counter, <<"janus-auto next-name candidates skipped (by tier and reason).">>}
}).

%% Unit metadata per family, as an OTel UCUM unit string.
%%
%% Kept SEPARATE from `?FAMILIES' on purpose: those tuples are consumed by
%% the Prometheus renderer, whose contract is that existing series keep
%% working, so they are not rewritten for metadata only the OTLP signal
%% consumes.
%%
%% UCUM is what OTLP specifies: `s' not `seconds', `ms' not
%% `milliseconds', `By' not `bytes'. The curly-braced form (`{request}')
%% is UCUM's annotation syntax for a dimensionless count of a specific
%% thing -- the honest unit for "how many requests", where `1' would say
%% the number means nothing in particular.
%%
%% A family absent here declares no unit; the OTLP view then omits the
%% field rather than inventing one.
-define(UNITS, #{
    requests_total => <<"{request}">>,
    requests_with_images_total => <<"{request}">>,
    upstream_requests_total => <<"{request}">>,
    usage_writer_dropped_total => <<"{row}">>,
    request_duration_seconds => <<"s">>,
    http_server_request_duration => <<"s">>,
    gen_ai_client_inference_duration => <<"s">>,
    gen_ai_client_inference_usage_input_tokens_total => <<"{token}">>,
    gen_ai_client_inference_usage_output_tokens_total => <<"{token}">>,
    gen_ai_client_inference_usage_cache_read_input_tokens_total => <<"{token}">>,
    gen_ai_client_inference_usage_cache_write_input_tokens_total => <<"{token}">>,
    catalog_generation => <<"1">>,
    catalog_ready => <<"1">>,
    models_serving => <<"{model}">>,
    lb_routes_cooling => <<"{route}">>,
    lb_stats_total => <<"{event}">>,
    decisions_upstream_429_total => <<"{event}">>,
    fleet_signals_tx_total => <<"{signal}">>,
    fleet_signals_rx_total => <<"{signal}">>,
    fleet_bad_ingress_total => <<"{signal}">>,
    fleet_remote_cool_last_resort_total => <<"{pick}">>,
    fleet_commands_total => <<"{command}">>,
    fleet_lease_holder => <<"1">>,
    fleet_mirror_rows => <<"{row}">>,
    usage_writer_buffered_rows => <<"{row}">>,
    otel_export_spans_total => <<"{span}">>,
    otel_export_batches_total => <<"{batch}">>,
    otel_export_queue_depth => <<"{span}">>,
    otel_export_enabled => <<"1">>,
    otel_export_last_success_age_seconds => <<"s">>,
    otel_export_last_error => <<"1">>,
    uptime_seconds => <<"s">>,
    workers_available => <<"{worker}">>,
    build_info => <<"1">>,
    sched_geo_match_total => <<"{pick}">>,
    sched_dispatch_local_total => <<"{dispatch}">>,
    sched_dispatch_worker_total => <<"{dispatch}">>,
    sched_dispatch_worker_overflow_total => <<"{dispatch}">>,
    sched_capacity_exhausted_total => <<"{event}">>,
    sched_health_demote_total => <<"{event}">>,
    sched_probe_total => <<"{probe}">>,
    sched_probe_skip_total => <<"{probe}">>,
    sched_rtt_dropped_total => <<"{sample}">>,
    sched_reserve_purged_total => <<"{entry}">>,
    sched_note_inflight_deprecated_total => <<"{call}">>,
    sched_release_barrier_timeout_total => <<"{event}">>,
    sched_knobs_off_total => <<"{event}">>,
    sched_dist_busy_events_total => <<"{event}">>,
    sched_snapshot_gen => <<"1">>,
    sched_workers_available => <<"{worker}">>,
    sched_health_ewma_ms => <<"ms">>,
    sched_rtt_ms => <<"ms">>,
    sched_pool_message_queue_len => <<"{message}">>,
    sched_knob_geo => <<"1">>,
    sched_knob_rtt => <<"1">>,
    sched_knob_health => <<"1">>,
    sched_knob_probe => <<"1">>,
    sched_dist_last_busy_age_ms => <<"ms">>,
    wire_enc_chunks_total => <<"{chunk}">>,
    wire_enc_bytes_total => <<"By">>,
    wire_enc_deflate_time_us_total => <<"us">>,
    wire_enc_inflate_time_us_total => <<"us">>,
    wire_enc_inflate_fail_total => <<"{event}">>,
    wire_enc_bad_config_total => <<"{event}">>,
    upstream_enc_unsolicited_total => <<"{event}">>,
    auto_tier_name_failover_total => <<"{event}">>,
    auto_tier_name_failover_exhausted_total => <<"{event}">>,
    auto_tier_name_skip_total => <<"{event}">>
}).


-spec render([{tuple(), integer()}], [{atom(), number(), map()}]) -> binary().
render(Rows, Gauges) ->
    Sums = maps:from_list([{K, V} || {{hist_sum_us, _, _} = K, V} <- Rows]),
    Counts = maps:from_list([{K, V} || {{hist_count, _, _} = K, V} <- Rows]),
    %% The semconv families are gated on the export knob (design §13.4):
    %% with it off they must not appear at all, even for a row that was
    %% written before the knob was flipped or by a code path that does not
    %% check it. Filtering at the RENDER boundary is what makes the
    %% promise hold for the whole scrape, not just for well-behaved
    %% producers.
    Visible = fun(N) -> semconv_visible(N) end,
    CounterNames = name_sort(lists:usort([N || {{counter, N, _}, _} <- Rows, Visible(N)])),
    HistNames = name_sort(
        lists:usort(
            [N || {{hist, N, _, _}, _} <- Rows, Visible(N)] ++
                [N || {{hist_sum_us, N, _}, _} <- Rows, Visible(N)] ++
                [N || {{hist_count, N, _}, _} <- Rows, Visible(N)]
        )
    ),
    GaugeNames = name_sort(lists:usort([N || {N, _, _} <- Gauges, Visible(N)])),
    iolist_to_binary([
        [render_counter_family(N, Rows) || N <- CounterNames],
        [render_hist_family(N, Rows, Sums, Counts) || N <- HistNames],
        [render_gauge_family(N, Gauges) || N <- GaugeNames]
    ]).

%%% internal — counter family

render_counter_family(Name, Rows) ->
    Series = lists:sort([{L, V} || {{counter, N, L}, V} <- Rows, N =:= Name]),
    case Series of
        [] -> [];
        _ ->
            Lines = [
                [name_bin(Name), labels_bin(L), " ", integer_to_binary(V), "\n"]
             || {L, V} <- Series
            ],
            [help_line(Name), type_line(Name, counter), Lines]
    end.

%%% internal — histogram family

render_hist_family(Name, Rows, Sums, Counts) ->
    ByLabels = lists:foldl(
        fun
            ({{hist, N, L, Le}, V}, Acc) when N =:= Name ->
                maps:update_with(L, fun(M) -> M#{Le => V} end, #{Le => V}, Acc);
            ({{hist_sum_us, N, L}, _}, Acc) when N =:= Name ->
                %% sum/count-only label sets still render (zero-filled
                %% ladder + _sum/_count) — never silently drop a series.
                ensure_labels(L, Acc);
            ({{hist_count, N, L}, _}, Acc) when N =:= Name ->
                ensure_labels(L, Acc);
            (_, Acc) ->
                Acc
        end,
        #{},
        Rows
    ),
    case maps:size(ByLabels) of
        0 -> [];
        _ ->
            [
                help_line(Name),
                type_line(Name, histogram),
                [
                    render_hist_series(Name, L, BucketMap, Sums, Counts)
                 || {L, BucketMap} <- lists:sort(maps:to_list(ByLabels))
                ]
            ]
    end.

%% maps:put_new/3 is OTP 28+; the build image is OTP 27.
ensure_labels(L, Acc) ->
    case maps:is_key(L, Acc) of
        true -> Acc;
        false -> Acc#{L => #{}}
    end.

render_hist_series(Name, L, BucketMap, Sums, Counts) ->
    NameB = name_bin(Name),
    Canonical = [LeBin || {_Le, LeBin} <- janus_metrics:buckets(Name)] ++ [<<"+Inf">>],
    All = lists:usort(Canonical ++ maps:keys(BucketMap)),
    %% +Inf never parses as a float — whitelist it BEFORE the validity
    %% partition. Unparseable non-canonical bounds (hand-crafted rows,
    %% ladder edits) are dropped silently: the registry owns all
    %% producer-side LeBin values, so this is defense-in-depth, and the
    %% byte-exact gate assertions catch real breakage. (Renderer stays
    %% pure — no logging here.)
    {Valid, _Dropped} = lists:partition(
        fun(Le) -> Le =:= <<"+Inf">> orelse le_num(Le) =/= invalid end, All
    ),
    %% Numerically-equal spellings from different deployments ("1" vs
    %% "1.0") must not both render — keep the CANONICAL spelling.
    Deduped = dedupe_bounds(Valid, Canonical),
    Les = lists:sort(
        fun
            (<<"+Inf">>, _) -> false;
            (_, <<"+Inf">>) -> true;
            (A, B) -> le_num(A) =< le_num(B)
        end,
        Deduped
    ),
    SumUs = maps:get({hist_sum_us, Name, L}, Sums, 0),
    Count = maps:get({hist_count, Name, L}, Counts, 0),
    BLines = [
        [
            NameB, "_bucket", labels_bin(L ++ [{<<"le">>, Le}]), " ",
            %% Merge counts from any same-valued duplicate spellings
            %% (e.g. a stale "1.0" row after a ladder spelling change).
            integer_to_binary(sum_dupes(Le, BucketMap)), "\n"
        ]
     || Le <- Les
    ],
    %% One concatenated iolist — buckets + _sum + _count.
    [
        BLines,
        [NameB, "_sum", labels_bin(L), " ", float_to_binary(SumUs / 1_000_000, [short]), "\n"],
        [NameB, "_count", labels_bin(L), " ", integer_to_binary(Count), "\n"]
    ].

le_num(Le) ->
    try binary_to_float(Le)
    catch _:_ -> (try float(binary_to_integer(Le)) catch _:_ -> invalid end)
    end.

%% Two spellings of the same numeric bound ("1" vs "1.0") must not both
%% render; the canonical ladder spelling wins. Its count carries any
%% duplicates' counts (sum_dupes merges them at render).
dedupe_bounds(Valid, Canonical) ->
    lists:foldl(
        fun(Le, Acc) ->
            case lists:any(fun(C) -> le_num(C) =:= le_num(Le) end, Canonical) of
                true ->
                    case lists:member(Le, Canonical) of
                        true -> [Le | Acc];
                        false -> Acc
                    end;
                false ->
                    [Le | Acc]
            end
        end,
        [],
        Valid
    ).

sum_dupes(Le, BucketMap) ->
    case Le of
        <<"+Inf">> ->
            maps:get(Le, BucketMap, 0);
        _ ->
            N = le_num(Le),
            lists:sum([V || {K, V} <- maps:to_list(BucketMap), K =/= <<"+Inf">>, le_num(K) =:= N])
    end.

%%% internal — gauge family

render_gauge_family(Name, Gauges) ->
    %% Sort by LABELS (not value — output must not churn with values).
    Series = lists:sort([{norm_labels(L), V} || {N, V, L} <- Gauges, N =:= Name]),
    case Series of
        [] -> [];
        _ ->
            %% Registry type wins; unregistered gauge families render as
            %% gauge (never the counter default).
            Type = fam_type(Name, gauge),
            Lines = [
                [name_bin(Name), labels_bin(L), " ", num_bin(V), "\n"]
             || {L, V} <- Series
            ],
            [help_line(Name), type_line(Name, Type), Lines]
    end.

%%% internal — shared

%% Atom term order is not name order across the BEAM — sort by the
%% name's binary so output is stable across nodes and builds.
name_sort(Names) ->
    lists:sort(fun(A, B) -> atom_to_binary(A, utf8) =< atom_to_binary(B, utf8) end, Names).

fam_type(Name, Default) ->
    case maps:get(Name, ?FAMILIES, undefined) of
        {T, _} -> T;
        undefined -> Default
    end.

help_line(Name) ->
    case maps:get(Name, ?FAMILIES, undefined) of
        undefined ->
            [];
        {_, Text} ->
            <<"# HELP ", (name_bin(Name))/binary, " ", (help_text(Name, Text))/binary, "\n">>
    end.

%% Whether a semconv-named family may appear in the Prometheus view.
%%
%% Legacy `janus_*' families are always visible: they ARE the contract.
%% Only the semconv additions are gated, and a family without a semconv
%% mapping is by definition legacy.
semconv_visible(Name) ->
    case janus_metrics:semconv_name(Name) of
        undefined -> true;
        %% ONE authority. Re-deriving the predicate here would let the
        %% render gate disagree with the WRITE gate: a producer would skip
        %% the observation while the renderer displayed a stale row, or —
        %% worse — the reverse, so /metrics would claim data the exporter
        %% is not actually sending. `janus_telemetry' already resolves the
        %% whole environment precedence chain, `OTEL_SDK_DISABLED' kill
        %% switch included.
        _ -> janus_telemetry:export_enabled()
    end.

%% Prometheus has no unit field, so the unit can ride the HELP text.
%%
%% OPT-IN (`JANUS_METRICS_HELP_UNITS=1`) because HELP text is part of the
%% existing /metrics contract: appending unconditionally would change what
%% every scraper sees for a benefit that the OTLP signal already provides
%% natively. With the knob off the output is byte-identical to before.
help_text(Name, Text) ->
    case help_units_enabled() of
        false ->
            Text;
        true ->
            case maps:get(Name, ?UNITS, undefined) of
                undefined -> Text;
                Unit -> <<Text/binary, " (unit: ", Unit/binary, ")">>
            end
    end.

%% Read per call: this is a scrape-time path, and a boot-time cache would
%% make the knob un-flippable without a restart.
help_units_enabled() ->
    case os:getenv("JANUS_METRICS_HELP_UNITS") of
        false -> false;
        V -> lists:member(string:lowercase(V), ["1", "true", "yes", "on"])
    end.

type_line(Name, Type) ->
    <<"# TYPE ", (name_bin(Name))/binary, " ", (atom_to_binary(Type, utf8))/binary, "\n">>.

name_bin(Name) ->
    <<"janus_", (atom_to_binary(Name, utf8))/binary>>.

norm_labels(L) ->
    janus_metrics:norm_labels(L).

labels_bin([]) ->
    <<>>;
labels_bin(Ls) ->
    Inner = lists:join(<<",">>, [[K, "=\"", escape(V), "\""] || {K, V} <- Ls]),
    iolist_to_binary(["{", Inner, "}"]).

escape(V) ->
    %% Prometheus label values: NUL is unrepresentable (strip), then
    %% backslash, double-quote, newline escaped.
    binary:replace(
        binary:replace(
            binary:replace(
                binary:replace(V, <<0>>, <<>>, [global]),
                <<"\\">>, <<"\\\\">>, [global]
            ),
            <<"\"">>, <<"\\\"">>, [global]
        ),
        <<"\n">>, <<"\\n">>, [global]
    ).

num_bin(I) when is_integer(I) -> integer_to_binary(I);
num_bin(F) when is_float(F) -> float_to_binary(F, [short]).

%% @doc UCUM unit for a family, or `undefined' when none is declared.
-spec unit(atom()) -> binary() | undefined.
unit(Name) ->
    maps:get(Name, ?UNITS, undefined).

%% @doc Every registered family name. The conformance gate walks this so a
%% newly added family cannot ship without a unit.
-spec family_names() -> [atom()].
family_names() ->
    maps:keys(?FAMILIES).

%% @doc The unit table (family => UCUM string).
-spec units() -> #{atom() => binary()}.
units() ->
    ?UNITS.

%% @doc The HELP text for a family, for the OTLP `description' field.
-spec help(atom()) -> binary().
help(Name) ->
    case maps:get(Name, ?FAMILIES, undefined) of
        {_, Text} -> Text;
        undefined -> <<>>
    end.
