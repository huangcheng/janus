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

-export([render/2]).

%% Family registry: name => {type, help}. Drives TYPE/HELP lines.
%% Unregistered counter families still render — a series must never
%% silently vanish (that was the audit's bug class).
-define(FAMILIES, #{
    requests_total => {counter, <<"Client LLM requests (terminal outcomes).">>},
    upstream_requests_total => {counter, <<"Terminal client outcomes by provider (failover inner attempts excluded).">>},
    usage_writer_dropped_total => {counter, <<"Usage events dropped by the writer.">>},
    request_duration_seconds => {histogram, <<"End-to-end request duration (streams include client drain).">>},
    catalog_generation => {gauge, <<"Serving catalog generation.">>},
    catalog_ready => {gauge, <<"Serving catalog warm (1) or cold (0).">>},
    models_serving => {gauge, <<"Models in the serving catalog.">>},
    lb_routes_cooling => {gauge, <<"LB routes currently cooling down.">>},
    lb_stats_total => {counter, <<"LB counters from janus_lb:stats/0 (cumulative).">>},
    usage_writer_buffered_rows => {gauge, <<"Usage writer buffered rows.">>},
    uptime_seconds => {gauge, <<"VM wall-clock uptime.">>},
    build_info => {untyped, <<"Build/version info.">>}
}).

-spec render([{tuple(), integer()}], [{atom(), number(), map()}]) -> binary().
render(Rows, Gauges) ->
    Sums = maps:from_list([{K, V} || {{hist_sum_us, _, _} = K, V} <- Rows]),
    Counts = maps:from_list([{K, V} || {{hist_count, _, _} = K, V} <- Rows]),
    CounterNames = name_sort(lists:usort([N || {{counter, N, _}, _} <- Rows])),
    HistNames = name_sort(lists:usort([N || {{hist, N, _, _}, _} <- Rows] ++
        [N || {{hist_sum_us, N, _}, _} <- Rows] ++ [N || {{hist_count, N, _}, _} <- Rows])),
    GaugeNames = name_sort(lists:usort([N || {N, _, _} <- Gauges])),
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

render_hist_series(Name, L, BucketMap, Sums, Counts) ->
    NameB = name_bin(Name),
    Canonical = [LeBin || {_Le, LeBin} <- janus_metrics:buckets()] ++ [<<"+Inf">>],
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
        undefined -> [];
        {_, Text} -> <<"# HELP ", (name_bin(Name))/binary, " ", Text/binary, "\n">>
    end.

type_line(Name, Type) ->
    <<"# TYPE ", (name_bin(Name))/binary, " ", (atom_to_binary(Type, utf8))/binary, "\n">>.

name_bin(Name) ->
    <<"janus_", (atom_to_binary(Name, utf8))/binary>>.

norm_labels(L) ->
    janus_metrics:norm_labels(L).

to_bin(V) ->
    janus_metrics:to_bin(V).

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
