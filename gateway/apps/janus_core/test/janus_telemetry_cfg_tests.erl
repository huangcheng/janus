%%%-------------------------------------------------------------------
%%% @doc Characterization tests for the telemetry config seam.
%%%
%%% The load-bearing invariant is "absent means OFF". An operator who
%%% deletes the settings row, or a fresh database that never had one,
%%% must not start emitting; and a malformed value must not be silently
%%% coerced into something plausible-looking.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_telemetry_cfg_tests).

-include_lib("eunit/include/eunit.hrl").

-define(KEY, {janus, telemetry_cfg}).

%% Every OTEL env var the config surface reads. Tests set/clear these;
%% the foreach restores exactly what was there, so a developer machine
%% with a real collector configured cannot leak into the suite.
-define(ENV_VARS, [
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
    "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
    "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT",
    "OTEL_EXPORTER_OTLP_HEADERS",
    "OTEL_EXPORTER_OTLP_TRACES_HEADERS",
    "OTEL_EXPORTER_OTLP_METRICS_HEADERS",
    "OTEL_EXPORTER_OTLP_LOGS_HEADERS",
    "OTEL_TRACES_EXPORTER",
    "OTEL_METRICS_EXPORTER",
    "OTEL_LOGS_EXPORTER",
    "OTEL_SDK_DISABLED"
]).

setup() ->
    Saved = [{V, os:getenv(V)} || V <- ?ENV_VARS],
    [os:unsetenv(V) || V <- ?ENV_VARS],
    Saved.
cleanup(Saved) ->
    persistent_term:erase(?KEY),
    lists:foreach(
        fun
            ({V, false}) -> os:unsetenv(V);
            ({V, Val}) -> os:putenv(V, Val)
        end,
        Saved
    ).

cfg_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun absent_is_disabled/0,
        fun explicit_false_is_disabled/0,
        fun explicit_true_is_enabled/0,
        fun export_needs_an_endpoint/0,
        fun default_endpoint/0,
        fun configured_endpoint/0,
        fun default_ratio/0,
        fun configured_ratio_wins/0,
        fun signal_urls_default/0,
        fun signal_url_appends_to_generic_base/0,
        fun signal_url_appends_tolerating_trailing_slash/0,
        fun per_signal_endpoint_is_used_as_is/0,
        fun per_signal_endpoint_alone_enables_export/0,
        fun per_signal_endpoint_does_not_leak_into_other_signals/0,
        fun signals_default_to_traces_only/0,
        fun signals_env_none_disables/0,
        fun signals_env_otlp_enables/0,
        fun signals_env_invalid_falls_to_setting/0,
        fun signals_setting_selects/0,
        fun headers_none_configured_test/0,
        fun headers_empty_per_signal_means_none_test/0,
        fun signals_kill_switch_wins_test/0,
        fun empty_per_signal_endpoint_falls_back_test/0,
        fun headers_generic_parse/0,
        fun headers_per_signal_override/0,
        fun headers_malformed_dropped/0
    ]}.

absent_is_disabled() ->
    persistent_term:erase(?KEY),
    ?assertEqual(false, janus_telemetry:enabled()),
    ?assertEqual(#{}, janus_telemetry:config()).

explicit_false_is_disabled() ->
    persistent_term:put(?KEY, #{<<"export">> => #{<<"enabled">> => false}}),
    ?assertEqual(false, janus_telemetry:enabled()).

explicit_true_is_enabled() ->
    persistent_term:put(?KEY, #{<<"export">> => #{<<"enabled">> => true}}),
    ?assertEqual(true, janus_telemetry:enabled()).

%% Export requires BOTH the flag and a usable endpoint: a config that
%% says "on" while pointing nowhere would fail on every batch, so the
%% endpoint is part of the predicate rather than a separate check at the
%% call site that someone could forget.
export_needs_an_endpoint() ->
    persistent_term:put(?KEY, #{<<"export">> => #{<<"enabled">> => true}}),
    ?assertEqual(true, janus_telemetry:export_enabled()),
    persistent_term:put(?KEY, #{
        <<"export">> => #{<<"enabled">> => true, <<"endpoint">> => <<>>}
    }),
    ?assertEqual(false, janus_telemetry:export_enabled()).

default_endpoint() ->
    persistent_term:erase(?KEY),
    ?assertEqual(<<"http://localhost:4318">>, janus_telemetry:export_endpoint()).

configured_endpoint() ->
    persistent_term:put(?KEY, #{<<"export">> => #{<<"endpoint">> => <<"http://collector:4318">>}}),
    ?assertEqual(<<"http://collector:4318">>, janus_telemetry:export_endpoint()).

default_ratio() ->
    persistent_term:erase(?KEY),
    ?assertEqual(0.05, janus_telemetry:default_sampling_ratio()).

configured_ratio_wins() ->
    persistent_term:put(?KEY, #{<<"sampling">> => #{<<"ratio">> => 0.42}}),
    ?assertEqual(0.42, janus_telemetry:sampling_ratio()).

%%--------------------------------------------------------------------
%% Per-signal URLs (exporter spec: per-signal as-is, generic is a base)
%%--------------------------------------------------------------------

signal_urls_default() ->
    persistent_term:erase(?KEY),
    ?assertEqual(
        <<"http://localhost:4318/v1/traces">>, janus_telemetry:signal_url(traces)
    ),
    ?assertEqual(
        <<"http://localhost:4318/v1/metrics">>, janus_telemetry:signal_url(metrics)
    ),
    ?assertEqual(<<"http://localhost:4318/v1/logs">>, janus_telemetry:signal_url(logs)).

signal_url_appends_to_generic_base() ->
    os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318"),
    ?assertEqual(
        <<"http://collector:4318/v1/metrics">>, janus_telemetry:signal_url(metrics)
    ).

signal_url_appends_tolerating_trailing_slash() ->
    os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318/"),
    ?assertEqual(
        <<"http://collector:4318/v1/traces">>, janus_telemetry:signal_url(traces)
    ).

per_signal_endpoint_is_used_as_is() ->
    %% "the URL MUST be used as-is without any modification" — a
    %% non-default path is honored verbatim, never suffixed, never
    %% stripped. The previous implementation stripped a `/v1/traces'
    %% suffix and re-appended the signal path, which doubled any custom
    %% path an operator had configured.
    os:putenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "https://t.example/custom/traces"),
    ?assertEqual(
        <<"https://t.example/custom/traces">>, janus_telemetry:signal_url(traces)
    ),
    %% A per-signal value that looks like a base is ALSO used as-is:
    %% second-guessing it would violate the same MUST in the other
    %% direction.
    os:putenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "https://t.example"),
    ?assertEqual(<<"https://t.example">>, janus_telemetry:signal_url(traces)).

per_signal_endpoint_alone_enables_export() ->
    %% A per-signal endpoint alone is NOT an export switch: the logs
    %% signal is still unselected by default, and — the trap this pins —
    %% the traces-only default must NOT fall back to the never-configured
    %% `localhost:4318' and start POSTing there. Selecting the signal
    %% explicitly is what turns its endpoint on.
    os:putenv("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "https://l.example/v1/logs"),
    ?assertEqual(false, janus_telemetry:export_enabled()),
    ?assertEqual(false, janus_telemetry:signal_enabled(traces)),
    os:putenv("OTEL_LOGS_EXPORTER", "otlp"),
    ?assertEqual(true, janus_telemetry:signal_enabled(logs)),
    ?assertEqual(true, janus_telemetry:export_enabled()).

per_signal_endpoint_does_not_leak_into_other_signals() ->
    %% Pointing traces at one collector must not send the other signals
    %% there too — that is the per-signal override's entire point.
    os:putenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "https://t.example/custom/traces"),
    ?assertEqual(
        <<"http://localhost:4318/v1/metrics">>, janus_telemetry:signal_url(metrics)
    ).

%%--------------------------------------------------------------------
%% Signal selection (design §9.1: default traces only)
%%--------------------------------------------------------------------

signals_default_to_traces_only() ->
    %% The default exists because the common backend is a traces-only
    %% collector: metrics/logs POSTs against it are a guaranteed 404
    %% loop (observed live against Tempo). With a generic endpoint as
    %% the one source, exactly traces is exportable; with NO source at
    %% all nothing is (there is no collector to talk to, so not even the
    %% default-selected traces signal may fall back to localhost).
    os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318"),
    ?assertEqual(true, janus_telemetry:signal_enabled(traces)),
    ?assertEqual(false, janus_telemetry:signal_enabled(metrics)),
    ?assertEqual(false, janus_telemetry:signal_enabled(logs)),
    os:unsetenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
    ?assertEqual(false, janus_telemetry:signal_enabled(traces)),
    ?assertEqual(false, janus_telemetry:export_enabled()).

signals_env_none_disables() ->
    os:putenv("OTEL_TRACES_EXPORTER", "none"),
    ?assertEqual(false, janus_telemetry:signal_enabled(traces)).

signals_env_otlp_enables() ->
    os:putenv("OTEL_METRICS_EXPORTER", "otlp"),
    ?assertEqual(true, janus_telemetry:signal_enabled(metrics)).

signals_env_invalid_falls_to_setting() ->
    %% Spec: an invalid value is not guessed at. Any present value other
    %% than `otlp' — including valid-but-other exporters like `console',
    %% and spec-legal comma lists — means "no OTLP for this signal"; it
    %% must NOT fall through to the dashboard setting, which could
    %% re-enable what the operator turned away.
    persistent_term:put(?KEY, #{
        <<"export">> => #{
            <<"signals">> => [<<"logs">>],
            <<"enabled">> => true,
            <<"endpoint">> => <<"http://collector:4318">>
        }
    }),
    os:putenv("OTEL_METRICS_EXPORTER", "otlp2"),
    ?assertEqual(false, janus_telemetry:signal_enabled(metrics)),
    ?assertEqual(true, janus_telemetry:signal_enabled(logs)),
    os:putenv("OTEL_METRICS_EXPORTER", "console"),
    ?assertEqual(false, janus_telemetry:signal_enabled(metrics)).

signals_setting_selects() ->
    persistent_term:put(?KEY, #{
        <<"export">> => #{
            <<"signals">> => [<<"traces">>, <<"metrics">>],
            <<"enabled">> => true,
            <<"endpoint">> => <<"http://collector:4318">>
        }
    }),
    ?assertEqual(true, janus_telemetry:signal_enabled(traces)),
    ?assertEqual(true, janus_telemetry:signal_enabled(metrics)),
    ?assertEqual(false, janus_telemetry:signal_enabled(logs)).

%%--------------------------------------------------------------------
%% Collector auth headers (OTEL_EXPORTER_OTLP_HEADERS)
%%--------------------------------------------------------------------

headers_generic_parse() ->
    os:putenv("OTEL_EXPORTER_OTLP_HEADERS", "api-key=abc123, other= v "),
    ?assertEqual(
        [{<<"api-key">>, <<"abc123">>}, {<<"other">>, <<"v">>}],
        janus_telemetry:export_headers(traces)
    ).

headers_per_signal_override() ->
    os:putenv("OTEL_EXPORTER_OTLP_HEADERS", "api-key=abc123"),
    os:putenv("OTEL_EXPORTER_OTLP_METRICS_HEADERS", "api-key=metrics-specific"),
    ?assertEqual(
        [{<<"api-key">>, <<"metrics-specific">>}], janus_telemetry:export_headers(metrics)
    ),
    ?assertEqual([{<<"api-key">>, <<"abc123">>}], janus_telemetry:export_headers(traces)).

headers_none_configured_test() ->
    ?assertEqual([], janus_telemetry:export_headers(traces)).

headers_empty_per_signal_means_none_test() ->
    %% Set-but-empty is an explicit "no headers for this signal", not an
    %% unset: the generic token must NOT ride along to another collector.
    os:putenv("OTEL_EXPORTER_OTLP_HEADERS", "api-key=secret"),
    os:putenv("OTEL_EXPORTER_OTLP_METRICS_HEADERS", "  "),
    ?assertEqual([], janus_telemetry:export_headers(metrics)),
    ?assertEqual([{<<"api-key">>, <<"secret">>}], janus_telemetry:export_headers(traces)).

signals_kill_switch_wins_test() ->
    os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318"),
    os:putenv("OTEL_SDK_DISABLED", "true"),
    ?assertEqual(false, janus_telemetry:enabled()),
    ?assertEqual(false, janus_telemetry:export_enabled()),
    ?assertEqual(false, janus_telemetry:signal_enabled(traces)).

empty_per_signal_endpoint_falls_back_test() ->
    %% Empty/whitespace per-signal value is unset: the generic base plus
    %% the signal path is the URL.
    os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318"),
    os:putenv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "   "),
    ?assertEqual(
        <<"http://collector:4318/v1/metrics">>, janus_telemetry:signal_url(metrics)
    ).

headers_malformed_dropped() ->
    %% No `=', empty key, empty value: dropped whole. A header like
    %% `Authorization: ' is worse than a missing one.
    os:putenv("OTEL_EXPORTER_OTLP_HEADERS", "good=1,noequals,=novalue,bad=,x=2"),
    ?assertEqual(
        [{<<"good">>, <<"1">>}, {<<"x">>, <<"2">>}], janus_telemetry:export_headers(logs)
    ).
