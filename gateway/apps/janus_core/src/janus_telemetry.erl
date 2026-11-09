%%%-------------------------------------------------------------------
%%% @doc Telemetry configuration surface (OpenTelemetry alignment spec).
%%%
%%% ## Two configuration channels, and where each one wins
%%%
%%% The two channels resolve differently, on purpose:
%%%
%%% **Export endpoint/enablement — environment WINS.** An OTel-emitting
%%% process is expected to be configurable with the standard variables,
%%% and a per-node endpoint is a deployment concern (each node may ship
%%% to a different collector). `OTEL_SDK_DISABLED' additionally wins over
%%% everything.
%%%
%%% **Sampling ratio — the dashboard setting WINS.** The ratio is what an
%%% operator changes in the UI at runtime; letting a boot-time env var
%%% outrank it would make a live edit silently ineffective, which is the
%%% hot-reload promise this whole feature exists to keep. The standard
%%% `OTEL_TRACES_SAMPLER' names (`always_on' / `always_off') still apply,
%%% resolved in `janus_trace'.
%%%
%%% Both fall back to a built-in default (export OFF, 5 % sampling).
%%%
%%% ## Why the environment channel is not optional
%%%
%%% Only the MASTER runs `janus_config', so only the master ever receives
%%% the dashboard setting. A worker has an exporter process, creates
%%% CLIENT spans, and would otherwise read `export_enabled = false'
%%% forever — its spans silently never leave the node. The environment is
%%% the one channel every role reads, which makes it the correct place to
%%% configure per-node export.
%%%
%%% ## Default OFF, fail closed to "off"
%%%
%%% Unset, absent, malformed or partially-applied configuration all mean
%%% telemetry is OFF. `persistent_term:erase/1' is how the config layer
%%% represents "row deleted", so reading a missing key must yield the
%%% disabled state rather than a crash.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_telemetry).

-export([
    config/0,
    enabled/0,
    export_enabled/0,
    export_endpoint/0,
    sampling_ratio/0,
    default_sampling_ratio/0,
    sdk_disabled/0
]).

-define(PT_KEY, {janus, telemetry_cfg}).
-define(DEFAULT_RATIO, 0.05).
%% OTLP/HTTP default, so a collector on the same host "just works".
-define(DEFAULT_ENDPOINT, <<"http://localhost:4318">>).

-spec config() -> map().
config() ->
    try
        persistent_term:get(?PT_KEY)
    catch
        error:badarg -> #{}
    end.

%% @doc Telemetry as a whole is enabled: not explicitly disabled, AND
%% either a collector is configured or the dashboard setting says so.
-spec enabled() -> boolean().
enabled() ->
    case sdk_disabled() of
        true -> false;
        false -> export_enabled()
    end.

%% @doc The standard kill switch. `OTEL_SDK_DISABLED=true' MUST stop all
%% telemetry regardless of any other configuration, so it is checked
%% before anything else.
-spec sdk_disabled() -> boolean().
sdk_disabled() ->
    case os:getenv("OTEL_SDK_DISABLED") of
        false -> false;
        V -> truthy(V)
    end.

%% @doc Whether spans are actually exported right now.
%%
%% Enabled when EITHER channel configures it:
%%   * the standard variables name an endpoint, or
%%   * the dashboard setting has `export.enabled = true' with a usable
%%     endpoint.
%% An endpoint is part of the predicate because a config that says
%% "export" while pointing nowhere would fail on every batch.
%%
%% `OTEL_SDK_DISABLED' is checked FIRST and wins over everything: the
%% spec defines it as the kill switch for the whole SDK, so a deployment
%% that flips it must stop exporting even if an endpoint is configured.
-spec export_enabled() -> boolean().
export_enabled() ->
    case sdk_disabled() of
        true -> false;
        false -> export_enabled_1()
    end.

export_enabled_1() ->
    case env_endpoint() of
        {ok, _} ->
            true;
        error ->
            case config() of
                #{<<"export">> := #{<<"enabled">> := true} = E} ->
                    case maps:get(<<"endpoint">>, E, ?DEFAULT_ENDPOINT) of
                        Url when is_binary(Url), byte_size(Url) > 0 -> true;
                        _ -> false
                    end;
                _ ->
                    false
            end
    end.

%% @doc The OTLP endpoint to export to.
%%
%% Standard precedence: the traces-specific variable wins over the
%% generic one (a deployment may send traces and metrics to different
%% collectors).
-spec export_endpoint() -> binary().
export_endpoint() ->
    case env_endpoint() of
        {ok, Url} ->
            Url;
        error ->
            case config() of
                #{<<"export">> := #{<<"endpoint">> := E}} when is_binary(E), byte_size(E) > 0 -> E;
                _ -> ?DEFAULT_ENDPOINT
            end
    end.

%% `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT' > `OTEL_EXPORTER_OTLP_ENDPOINT'.
%%
%% The traces-specific value is a FULL url (it names the path too), while
%% the generic one is a BASE (the exporter appends `/v1/traces'). Both are
%% accepted and both end up as a base this module appends to, so a
%% traces-endpoint that already carries `/v1/traces' is left alone.
env_endpoint() ->
    case nonempty(os:getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")) of
        {ok, Url} ->
            {ok, strip_traces_suffix(Url)};
        error ->
            case nonempty(os:getenv("OTEL_EXPORTER_OTLP_ENDPOINT")) of
                {ok, Url} -> {ok, strip_traces_suffix(Url)};
                error -> error
            end
    end.

%% The exporter appends `/v1/traces'; strip it from a traces-endpoint so
%% the path is not doubled. `/v1/traces' -> base.
strip_traces_suffix(Url) ->
    Suffix = <<"/v1/traces">>,
    Size = byte_size(Url) - byte_size(Suffix),
    case Size >= 0 andalso binary:part(Url, Size, byte_size(Suffix)) =:= Suffix of
        true -> binary:part(Url, 0, Size);
        false -> Url
    end.

%% @doc The root-trace sampling ratio.
%%
%% Precedence: dashboard setting -> `OTEL_TRACES_SAMPLER_ARG' -> default.
%% `OTEL_TRACES_SAMPLER' itself (`always_on' / `always_off' / `parentbased_*')
%% is honoured in `janus_trace', which owns the sampler.
-spec sampling_ratio() -> float().
sampling_ratio() ->
    case config() of
        #{<<"sampling">> := #{<<"ratio">> := R}} when is_number(R), R >= 0, R =< 1 ->
            R * 1.0;
        _ ->
            case janus_trace:ratio() of
                R when is_float(R) -> R;
                _ -> ?DEFAULT_RATIO
            end
    end.

-spec default_sampling_ratio() -> float().
default_sampling_ratio() ->
    ?DEFAULT_RATIO.

%% ------------------------------------------------------------------
%% Internal
%% ------------------------------------------------------------------

truthy(V) when is_binary(V) -> truthy(binary_to_list(V));
truthy(V) when is_list(V) ->
    case string:lowercase(string:trim(V)) of
        "true" -> true;
        "1" -> true;
        "yes" -> true;
        _ -> false
    end;
truthy(_) ->
    false.

nonempty(undefined) ->
    error;
nonempty(false) ->
    error;
nonempty("") ->
    error;
nonempty(V) when is_list(V) ->
    case string:trim(V) of
        "" -> error;
        S -> {ok, list_to_binary(S)}
    end;
nonempty(V) when is_binary(V), V =/= <<>> ->
    case string:trim(V, both, " \t") of
        <<>> -> error;
        B -> {ok, B}
    end;
nonempty(_) ->
    error.