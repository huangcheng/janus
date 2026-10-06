-module(janus_metrics_render_tests).
-include_lib("eunit/include/eunit.hrl").

counter_render_exact_test() ->
    Rows = [
        {{counter, requests_total, [{<<"endpoint">>, <<"chat">>}, {<<"status_class">>, <<"2xx">>}]}, 42}
    ],
    Out = janus_metrics_render:render(Rows, []),
    ?assertEqual(
        <<"# HELP janus_requests_total Client LLM requests (terminal outcomes).\n"
          "# TYPE janus_requests_total counter\n"
          "janus_requests_total{endpoint=\"chat\",status_class=\"2xx\"} 42\n">>,
        Out
    ).

histogram_zero_filled_order_exact_test() ->
    %% Buckets: ALL canonical bounds emitted (zero-filled), numerically
    %% ascending, +Inf LAST — a lexicographic sort or sparse emission
    %% breaks histogram_quantile. The fixture is production-shaped: one
    %% 30s observation bumps every bound >= 30 (a SUFFIX of the ladder),
    %% so the rendered ladder is cumulative — sparse fixtures that
    %% violate monotonicity are impossible from observe/3.
    L = [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"1">>}],
    Rows = [
        {{hist, request_duration_seconds, L, <<"600">>}, 1},
        {{hist, request_duration_seconds, L, <<"+Inf">>}, 1},
        {{hist, request_duration_seconds, L, <<"30">>}, 1},
        {{hist, request_duration_seconds, L, <<"60">>}, 1},
        {{hist, request_duration_seconds, L, <<"120">>}, 1},
        {{hist, request_duration_seconds, L, <<"300">>}, 1},
        {{hist_sum_us, request_duration_seconds, L}, 30000000},
        {{hist_count, request_duration_seconds, L}, 1}
    ],
    Out = janus_metrics_render:render(Rows, []),
    Expected = <<
        "# HELP janus_request_duration_seconds End-to-end request duration (streams include client drain).\n"
        "# TYPE janus_request_duration_seconds histogram\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"0.05\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"0.1\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"0.25\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"0.5\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"1\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"2.5\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"5\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"10\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"30\"} 1\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"60\"} 1\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"120\"} 1\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"300\"} 1\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"600\"} 1\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"+Inf\"} 1\n"
        "janus_request_duration_seconds_sum{protocol=\"openai_chat\",stream=\"1\"} 30.0\n"
        "janus_request_duration_seconds_count{protocol=\"openai_chat\",stream=\"1\"} 1\n"
    >>,
    ?assertEqual(Expected, Out).

gauge_render_test() ->
    Out = janus_metrics_render:render([], [{catalog_generation, 12, #{}}]),
    ?assertEqual(
        <<"# HELP janus_catalog_generation Serving catalog generation.\n"
          "# TYPE janus_catalog_generation gauge\n"
          "janus_catalog_generation 12\n">>,
        Out
    ).

build_info_is_untyped_test() ->
    %% `info` is OpenMetrics-only; under text/0.0.4 it must be untyped.
    Out = janus_metrics_render:render([], [{build_info, 1, #{<<"version">> => <<"0.1.0">>}}]),
    ?assertMatch({_, _}, binary:match(Out, <<"# TYPE janus_build_info untyped">>)),
    ?assertMatch({_, _}, binary:match(Out, <<"janus_build_info{version=\"0.1.0\"} 1\n">>)).

label_escape_test() ->
    %% quote, backslash, newline escaped; NUL stripped (unrepresentable).
    Rows = [{{counter, requests_total, [{<<"k">>, <<"a\"b\\c\nd", 0>>}]}, 1}],
    Out = janus_metrics_render:render(Rows, []),
    ?assertMatch({_, _}, binary:match(Out, <<"k=\"a\\\"b\\\\c\\nd\"">>)).

dropped_counter_family_renders_test() ->
    %% The writer-drop counter is appended by the handler as a row —
    %% regression guard for the hardcoded-family-list bug.
    Rows = [{{counter, usage_writer_dropped_total, []}, 3}],
    Out = janus_metrics_render:render(Rows, []),
    ?assertMatch({_, _}, binary:match(Out, <<"# TYPE janus_usage_writer_dropped_total counter">>)),
    ?assertMatch({_, _}, binary:match(Out, <<"janus_usage_writer_dropped_total 3\n">>)).

unknown_counter_family_still_renders_test() ->
    %% Unregistered families render (no HELP) — never silently dropped.
    Rows = [{{counter, surprise_total, []}, 1}],
    Out = janus_metrics_render:render(Rows, []),
    ?assertMatch({_, _}, binary:match(Out, <<"# TYPE janus_surprise_total counter\njanus_surprise_total 1\n">>)).

families_dedup_test() ->
    %% One TYPE/HELP line per family, no duplicate TYPE lines even with
    %% several label sets. (Global byte order is pinned by
    %% mixed_snapshot_exact_test.)
    Rows = [
        {{counter, requests_total, [{<<"endpoint">>, <<"models">>}, {<<"status_class">>, <<"2xx">>}]}, 2},
        {{counter, requests_total, [{<<"endpoint">>, <<"chat">>}, {<<"status_class">>, <<"2xx">>}]}, 1}
    ],
    Out = janus_metrics_render:render(Rows, []),
    ?assertEqual(1, count_occ(Out, <<"# TYPE janus_requests_total">>)),
    ?assertEqual(1, count_occ(Out, <<"# HELP janus_requests_total">>)).

mixed_snapshot_exact_test() ->
    %% One of each kind: registered counter, registered handler-appended
    %% counter, histogram (one 30s observation — a SUFFIX ladder, as
    %% observe/3 actually writes it), gauge, untyped build_info.
    L = [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}],
    Rows = [
        {{counter, requests_total, [{<<"endpoint">>, <<"chat">>}, {<<"status_class">>, <<"2xx">>}]}, 1},
        {{counter, usage_writer_dropped_total, []}, 2},
        {{hist, request_duration_seconds, L, <<"30">>}, 1},
        {{hist, request_duration_seconds, L, <<"60">>}, 1},
        {{hist, request_duration_seconds, L, <<"120">>}, 1},
        {{hist, request_duration_seconds, L, <<"300">>}, 1},
        {{hist, request_duration_seconds, L, <<"600">>}, 1},
        {{hist, request_duration_seconds, L, <<"+Inf">>}, 1},
        {{hist_sum_us, request_duration_seconds, L}, 30000000},
        {{hist_count, request_duration_seconds, L}, 1}
    ],
    Gauges = [
        {build_info, 1, #{<<"version">> => <<"0.1.0">>}},
        {catalog_generation, 7, #{}}
    ],
    Out = janus_metrics_render:render(Rows, Gauges),
    Expected = <<
        "# HELP janus_requests_total Client LLM requests (terminal outcomes).\n"
        "# TYPE janus_requests_total counter\n"
        "janus_requests_total{endpoint=\"chat\",status_class=\"2xx\"} 1\n"
        "# HELP janus_usage_writer_dropped_total Usage events dropped by the writer.\n"
        "# TYPE janus_usage_writer_dropped_total counter\n"
        "janus_usage_writer_dropped_total 2\n"
        "# HELP janus_request_duration_seconds End-to-end request duration (streams include client drain).\n"
        "# TYPE janus_request_duration_seconds histogram\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"0.05\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"0.1\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"0.25\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"0.5\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"1\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"2.5\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"5\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"10\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"30\"} 1\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"60\"} 1\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"120\"} 1\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"300\"} 1\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"600\"} 1\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"+Inf\"} 1\n"
        "janus_request_duration_seconds_sum{protocol=\"openai_chat\",stream=\"0\"} 30.0\n"
        "janus_request_duration_seconds_count{protocol=\"openai_chat\",stream=\"0\"} 1\n"
        "# HELP janus_build_info Build/version info.\n"
        "# TYPE janus_build_info untyped\n"
        "janus_build_info{version=\"0.1.0\"} 1\n"
        "# HELP janus_catalog_generation Serving catalog generation.\n"
        "# TYPE janus_catalog_generation gauge\n"
        "janus_catalog_generation 7\n"
    >>,
    ?assertEqual(Expected, Out).

count_occ(Bin, Pat) ->
    count_occ(Bin, Pat, 0).
count_occ(Bin, Pat, N) ->
    case binary:match(Bin, Pat) of
        nomatch -> N;
        {Pos, Len} -> count_occ(binary:part(Bin, Pos + Len, byte_size(Bin) - Pos - Len), Pat, N + 1)
    end.
