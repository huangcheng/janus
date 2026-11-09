%%%-------------------------------------------------------------------
%%% @doc OTLP log export (design §10.2).
%%%
%%% A `logger' handler that hands every event to the exporter, which
%%% batches and posts it to `/v1/logs'. Opt-in via the same export knob the
%%% traces and metrics obey, so a deployment that exports nothing pays a
%%% module-load and no traffic.
%%%
%%% ## Why a handler and not the formatter
%%%
%%% §10.1 rejected a handler for CORRELATION, because the formatter is
%%% already the single funnel for the text stream and adding `trace_id'
%%% there covers every call site. Export is different: it needs the raw
%%% event (level, meta, the structured report), not a formatted line, and a
%%% formatted line cannot be parsed back into the OTLP body/attributes
%%% split without re-parsing our own output. So the text stream stays on
%%% the formatter and the OTLP stream taps `logger' directly.
%%%
%%% This handler renders nothing and writes nowhere: it is a filter-shaped
%%% tap whose only job is to cast the event to the exporter. All buffering,
%%% batching and HTTP live there, so a slow or dead collector can never
%%% block the process that logged.
%%%
%%% ## Severity is normative, not cosmetic
%%%
%%% The spec says `severityNumber >= 17' is what backends count as an
%%% error. Mapping `warning' into the ERROR band would therefore misreport
%%% every recoverable provider hiccup as an error — which is why the table
%%% below puts `warning' at 13 (WARN) and only `error' and above at 17+.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_otel_logs).

-export([log/2, severity/1, install/0, uninstall/0, handler_id/0]).

-define(HANDLER, janus_otel_logs).

%% @doc logger handler callback.
%%
%% Never crashes and never blocks: a handler that raises takes the logging
%% call down with it, and telemetry must not be able to fail a request.
log(Event, _Config) ->
    try
        case janus_telemetry:export_enabled() of
            true -> janus_otel_export:record_log(Event);
            false -> ok
        end
    catch
        _:_ -> ok
    end.

%% @doc OTLP severity for an OTP logger level.
%%
%% The number is the MIDPOINT of its band (TRACE 1-4, DEBUG 5-8, INFO 9-12,
%% WARN 13-16, ERROR 17-20, FATAL 21-24). `notice' and `critical' sit one
%% above their band's midpoint because OTP has finer levels than OTLP's
%% six bands, and the text carries the distinction.
-spec severity(atom()) -> {pos_integer(), binary()}.
severity(debug) -> {5, <<"DEBUG">>};
severity(info) -> {9, <<"INFO">>};
severity(notice) -> {10, <<"INFO2">>};
severity(warning) -> {13, <<"WARN">>};
severity(error) -> {17, <<"ERROR">>};
severity(critical) -> {18, <<"ERROR2">>};
severity(alert) -> {21, <<"FATAL">>};
severity(emergency) -> {22, <<"FATAL2">>};
severity(_) -> {9, <<"INFO">>}.

-spec handler_id() -> atom().
handler_id() ->
    ?HANDLER.

%% @doc Install the handler. Idempotent, and called only when export is on.
-spec install() -> ok.
install() ->
    Config = #{
        %% The exporter decides what to keep; the handler must see every
        %% level the primary logger lets through, so it does not filter.
        level => all,
        config => #{},
        %% No formatter: this handler emits nothing to any device.
        formatter => {janus_otel_log_fmt, #{}}
    },
    case logger:add_handler(?HANDLER, ?MODULE, Config) of
        ok -> ok;
        {error, already_present} -> ok;
        _ -> ok
    end.

%% @doc Remove the handler. Idempotent.
-spec uninstall() -> ok.
uninstall() ->
    _ = logger:remove_handler(?HANDLER),
    ok.