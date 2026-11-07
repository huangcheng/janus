%%%-------------------------------------------------------------------
%%% @doc Telemetry configuration surface (OpenTelemetry alignment spec).
%%%
%%% One read seam for the `telemetry' settings key, following the
%%% house convention: the dashboard writes a `settings' row, the master
%%% distributes it via `janus_config:distribute_settings/1' into
%%% `persistent_term', and consumers READ that term directly (never a
%%% cast, never a SQL query on the hot path).
%%%
%%% ## Default OFF, fail closed to "off"
%%%
%%% An unset, absent, malformed or partially-applied config means
%%% telemetry is OFF. `persistent_term:erase/1' is how
%%% `janus_config:clear_telemetry/1' represents "row deleted", so a
%%% read of a missing key must be the disabled state rather than a
%%% crash. This is the same knob-off discipline as every other
%%% capability family in the tree.
%%%
%%% ## What exists today vs what is planned
%%%
%%% Only `sampling_ratio/0' has a live effect: the trace sampler reads it
%%% per root span. The export fields (`enabled', `endpoint', headers) are
%%% parsed and validated now so operators can stage a configuration, but
%%% nothing exports until the OTLP writer lands — `export_enabled/0'
%%% returns false today regardless of the stored value, and that is
%%% deliberate: claiming export is on when no exporter exists would be
%%% worse than reporting off.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_telemetry).

-export([
    config/0,
    enabled/0,
    export_enabled/0,
    export_endpoint/0,
    sampling_ratio/0,
    default_sampling_ratio/0
]).

-define(PT_KEY, {janus, telemetry_cfg}).
-define(DEFAULT_RATIO, 0.05).
%% Endpoint the OTLP exporter will target once it lands; matches the
%% OTLP/HTTP default so an operator's collector "just works".
-define(DEFAULT_ENDPOINT, <<"http://localhost:4318">>).

-spec config() -> map().
config() ->
    try
        persistent_term:get(?PT_KEY)
    catch
        error:badarg -> #{}
    end.

%% @doc Telemetry as a whole is enabled. OFF unless a config says
%% otherwise. Nothing is emitted while this is false, which is today's
%% behaviour and the shipped default.
-spec enabled() -> boolean().
enabled() ->
    case config() of
        #{<<"export">> := #{<<"enabled">> := true}} -> true;
        _ -> false
    end.

%% @doc Whether OTLP export is actually available.
%%
%% Always false until the exporter ships. Kept as its own function so the
%% call site that flips it is a one-line change and cannot be confused
%% with the configuration flag above.
-spec export_enabled() -> boolean().
export_enabled() ->
    false.

%% @doc The OTLP endpoint to export to (a binary URL).
-spec export_endpoint() -> binary().
export_endpoint() ->
    case config() of
        #{<<"export">> := #{<<"endpoint">> := E}} when is_binary(E) -> E;
        _ -> ?DEFAULT_ENDPOINT
    end.

%% @doc The root-trace sampling ratio. Precedence: the `sampling.ratio'
%% setting, then `OTEL_TRACES_SAMPLER_ARG', then the built-in default.
%% `janus_trace' caches the effective value on first read, so this is
%% consulted once per boot in practice.
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
