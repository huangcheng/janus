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
    signal_url/1,
    signal_enabled/1,
    export_headers/1,
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

%% @doc Whether the OTLP export subsystem is on at all.
%%
%% True when at least one signal is actually exportable (`signal_enabled/1'
%% for any signal): that requires BOTH a selection and an endpoint source
%% for it. An endpoint var for one signal no longer switches the whole
%% subsystem on — the earlier predicate did exactly that and, combined
%% with the traces-only default, made a logs-only endpoint send TRACES to
%% the never-configured `localhost:4318' default on every flush.
%%
%% Per-SIGNAL selection is a separate predicate (`signal_enabled/1'):
%% this being true does not mean every signal is exported.
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
    lists:any(
        fun(S) -> signal_enabled(S) end,
        [traces, metrics, logs]
    ).

%% @doc The OTLP BASE endpoint (no signal path).
%%
%% Only the generic `OTEL_EXPORTER_OTLP_ENDPOINT' and the dashboard
%% setting feed this; per-signal variables never become another signal's
%% base (pointing traces at one collector must not send metrics there
%% too). `signal_url/1' is what callers should use — this is the base it
%% appends to.
-spec export_endpoint() -> binary().
export_endpoint() ->
    case nonempty(os:getenv("OTEL_EXPORTER_OTLP_ENDPOINT")) of
        {ok, Url} ->
            Url;
        error ->
            case config() of
                #{<<"export">> := #{<<"endpoint">> := E}} when is_binary(E), byte_size(E) > 0 -> E;
                _ -> ?DEFAULT_ENDPOINT
            end
    end.

%% Whether ANY endpoint source names the GENERIC base (the generic
%% variable or the dashboard setting). A per-signal variable does NOT:
%% it is a source for its own signal only (see signal_source/1) and must
%% not make the other signals fall back to the unconfigured default.
generic_endpoint_env() ->
    nonempty(os:getenv("OTEL_EXPORTER_OTLP_ENDPOINT")) =/= error.

dashboard_export_on() ->
    case config() of
        #{<<"export">> := #{<<"enabled">> := true} = E} ->
            case maps:get(<<"endpoint">>, E, ?DEFAULT_ENDPOINT) of
                Url when is_binary(Url), byte_size(Url) > 0 -> true;
                _ -> false
            end;
        _ ->
            false
    end.

%% @doc The FULL URL one signal POSTs to.
%%
%% Exporter spec: a per-signal variable "MUST be used as-is without any
%% modification" — so `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT' is returned
%% verbatim, path and all, and an operator pointing at a non-default path
%% gets exactly that. Only the generic base gets `/v1/<signal>' appended
%% (tolerating a trailing slash so `http://c:4318/' does not become
%% `//v1/traces').
-spec signal_url(traces | metrics | logs) -> binary().
signal_url(Signal) when Signal =:= traces; Signal =:= metrics; Signal =:= logs ->
    case nonempty(os:getenv(signal_env_var(Signal, "ENDPOINT"))) of
        {ok, Url} ->
            Url;
        error ->
            append_signal(export_endpoint(), Signal)
    end.

signal_env_var(Signal, Suffix) ->
    Name = string:uppercase(atom_to_list(Signal)),
    "OTEL_EXPORTER_OTLP_" ++ Name ++ "_" ++ Suffix.

append_signal(Base, Signal) ->
    Trimmed =
        case binary:last(Base) of
            $/ -> binary:part(Base, 0, byte_size(Base) - 1);
            _ -> Base
        end,
    <<Trimmed/binary, "/v1/", (atom_to_binary(Signal, utf8))/binary>>.

%% @doc Whether one signal is actually exported.
%%
%% Two conditions, both required:
%%
%%   1. SELECTION. Resolution per signal, first match wins:
%%      a. `OTEL_{TRACES,METRICS,LOGS}_EXPORTER', normalized (trimmed,
%%         lowercased). `otlp' selects; `none' and every other present
%%         value — `console', `zipkin', a typo, a spec-legal comma list —
%%         mean "not the OTLP exporter for this signal". Falling through
%%         on those instead would let the lower-priority dashboard setting
%%         re-enable OTLP the operator explicitly did not select.
%%      b. The dashboard setting `telemetry.export.signals' (a list of
%%         signal-name binaries).
%%      c. Default: `traces' only — the design's deliberate default,
%%         because the common backend is a traces-only collector and a
%%         metrics/logs POST against it is a guaranteed 404 loop
%%         (observed in production).
%%   2. AN ENDPOINT SOURCE for that signal: its per-signal variable, the
%%      generic variable, or the dashboard export setting. An EXPLICIT
%%      `otlp' selection in the environment is its own source (the spec's
%%      default endpoint then applies, by operator intent); the implicit
%%      traces-only default is NOT — otherwise a logs-only endpoint
%%      variable would send traces to the unconfigured `localhost:4318'.
-spec signal_enabled(traces | metrics | logs) -> boolean().
signal_enabled(Signal) when Signal =:= traces; Signal =:= metrics; Signal =:= logs ->
    %% The kill switch wins over EVERYTHING, this predicate included —
    %% `export_enabled/0' checks it too, but a caller that gates on the
    %% signal directly must not be able to route around it.
    case sdk_disabled() of
        true -> false;
        false -> signal_enabled_1(Signal)
    end.

signal_enabled_1(Signal) ->
    case exporter_env(Signal) of
        {ok, Value} ->
            %% The spec defines this variable as a comma-separated LIST of
            %% exporters: `otlp,console' is legal and DOES select OTLP.
            %% Split and test membership rather than matching the whole
            %% string, and treat `none'/anything-else as no OTLP here.
            lists:member(<<"otlp">>, [
                trim(P) || P <- binary:split(Value, <<",">>, [global])
            ]);
        unset ->
            setting_signal(Signal) andalso signal_source(Signal)
    end.

%% The normalized `OTEL_<SIGNAL>_EXPORTER' value, or `unset'. An empty or
%% whitespace value counts as unset — an env line like `OTLP=\n' is not a
%% selection.
exporter_env(Signal) ->
    case os:getenv("OTEL_" ++ string:uppercase(atom_to_list(Signal)) ++ "_EXPORTER") of
        false ->
            unset;
        V when is_list(V) ->
            case trim(list_to_binary(V)) of
                <<>> -> unset;
                B -> {ok, string:lowercase(B)}
            end
    end.

%% Whether an explicit endpoint source exists for this signal.
signal_source(Signal) ->
    nonempty(os:getenv(signal_env_var(Signal, "ENDPOINT"))) =/= error
        orelse generic_endpoint_env()
        orelse dashboard_export_on().

setting_signal(Signal) ->
    Name = atom_to_binary(Signal, utf8),
    case config() of
        #{<<"export">> := #{<<"signals">> := List}} when is_list(List) ->
            lists:member(Name, [L || L <- List, is_binary(L)]);
        _ ->
            Signal =:= traces
    end.

%% @doc Extra request headers for one signal's POSTs (collector auth).
%%
%% `OTEL_EXPORTER_OTLP_{TRACES,METRICS,LOGS}_HEADERS' overrides the
%% generic `OTEL_EXPORTER_OTLP_HEADERS'. Values are `k=v,k2=v2' per the
%% exporter spec; a malformed pair is skipped, not fatal — but an
%% empty key or value is dropped whole, because sending
%% `Authorization: ' is worse than not sending the header.
%%
%% A per-signal variable set but EMPTY means "no headers for THIS
%% signal" — distinct from unset, which falls back to the generic value.
%% Collapsing the two would attach the traces collector's bearer token to
%% a metrics POST against a different collector, and these values are
%% SECRETS by assumption: nothing may log them, consumers only forward.
-spec export_headers(traces | metrics | logs) -> [{binary(), binary()}].
export_headers(Signal) when Signal =:= traces; Signal =:= metrics; Signal =:= logs ->
    %% `Raw' is always a binary; an explicit per-signal empty value and a
    %% fully absent configuration both arrive as `<<>>' and yield no
    %% headers — the difference is only whether the GENERIC value was
    %% consulted, which the resolution below already encodes.
    Raw =
        case os:getenv(signal_env_var(Signal, "HEADERS")) of
            false ->
                generic_headers();
            V when is_list(V) ->
                trim(list_to_binary(V))
        end,
    case Raw of
        <<>> ->
            [];
        _ ->
            [Pair || Pair <- [header_pair(P) || P <- binary:split(Raw, <<",">>, [global])], Pair =/= skip]
    end.

generic_headers() ->
    case os:getenv("OTEL_EXPORTER_OTLP_HEADERS") of
        false -> <<>>;
        V when is_list(V) -> list_to_binary(V)
    end.

header_pair(P) ->
    case binary:split(trim(P), <<"=">>) of
        [K0, V0] ->
            %% Trim both halves: `k = v' is one syntax, `k=v ' another,
            %% and a stray space in a header VALUE is an auth failure on
            %% a collector that no log line will ever explain. CR/LF and
            %% other control bytes drop the pair whole — forwarded, they
            %% would split or corrupt the HTTP request headers.
            K = trim(K0),
            V = trim(V0),
            case
                byte_size(K) > 0 andalso byte_size(V) > 0 andalso
                    printable(K) andalso printable(V)
            of
                true -> {K, V};
                false -> skip
            end;
        _ ->
            skip
    end.

%% Printable ASCII only (no DEL): the shape an HTTP header value may
%% legally carry. Anything else cannot be forwarded safely.
printable(B) ->
    lists:all(fun(C) -> C >= 16#20 andalso C =< 16#7E end, binary_to_list(B)).

%% Byte-level trim: `string:trim/3' decodes as Unicode and raises on
%% malformed sequences — env bytes must never crash the config read.
trim(B) when is_binary(B) ->
    trim_r(trim_l(B)).

trim_l(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t -> trim_l(Rest);
trim_l(B) -> B.

trim_r(B) ->
    case byte_size(B) of
        0 -> B;
        Sz ->
            case binary:at(B, Sz - 1) of
                C when C =:= $\s; C =:= $\t -> trim_r(binary:part(B, 0, Sz - 1));
                _ -> B
            end
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
    case trim(V) of
        <<>> -> error;
        B -> {ok, B}
    end;
nonempty(_) ->
    error.