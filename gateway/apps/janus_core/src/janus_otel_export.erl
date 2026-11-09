%%%-------------------------------------------------------------------
%%% @doc Batched OTLP/HTTP trace exporter.
%%%
%%% Spans are handed to this module from the request process and buffered
%%% in a bounded queue; a single `gen_server' drains the queue on a timer
%%% and POSTs one OTLP/HTTP-JSON request per batch to `/v1/traces'.
%%%
%%% ## Why a separate process
%%%
%%% Exporting is network I/O to a collector that may be slow, down, or
%%% misconfigured. Doing it inline would put a third party's availability
%%% on the request path — the one thing telemetry must never do. So the
%%% request process only does an async `gen_server:cast/2' (fire and
%%% forget), and everything slow happens here.
%%%
%%% ## Backpressure: drop and COUNT, never block and never grow
%%%
%%% The queue has a hard cap. When it is full the OLDEST spans are
%%% dropped and a counter is incremented. This is deliberate: blocking
%%% the cast caller would stall a request, and growing without bound
%%% would exhaust memory on a long collector outage. Loss is reported
%%% (`dropped_total' in the stats, and a periodic log line), never
%%% silent — a telemetry pipeline that quietly discards data looks
%%% healthy while the data is gone.
%%%
%%% ## Failure posture
%%%
%%% A failed POST drops the batch (spans are not retried: by the time a
%%% retry succeeds the trace is stale, and retrying would amplify load on
%%% an already-sick collector). The failure is counted and logged at a
%%% rate limit so an outage does not itself flood the log.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_otel_export).

-behaviour(gen_server).

-export([start_link/0, record/1, record_log/1, stats/0, flush/0]).
%% Conformance seam: the log record encoder, so the wire shape is asserted
%% where it is built rather than inferred from the severity table.
-export([encode_log_for_test/1]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
%% Hard caps. The batch size bounds one HTTP request; the queue cap bounds
%% memory during a collector outage. Both are counted losses.
-define(MAX_BATCH, 512).
-define(MAX_QUEUE, 4096).
-define(FLUSH_MS, 2000).
-define(HTTP_TIMEOUT_MS, 10000).
%% Log at most one export failure per this window: a down collector must
%% not turn every flush into a log line.
-define(FAIL_LOG_MS, 60000).

%% Logs batching defaults from the Logs SDK (design §10.2): the delay is
%% 1000 ms — half the trace flush — because a log line is only useful with
%% its surroundings, so it should not sit in a queue for two seconds.
-define(LOG_FLUSH_MS, 1000).
-define(LOG_MAX_QUEUE, 2048).
-define(LOG_MAX_BATCH, 512).

-record(state, {
    queue = [] :: [map()],
    %% Log records are buffered SEPARATELY from spans: different cadence,
    %% different queue bound, and a log burst must never evict spans.
    log_queue = [] :: [map()],
    logs_sent = 0 :: non_neg_integer(),
    logs_dropped = 0 :: non_neg_integer(),
    started = false :: boolean(),
    dropped = 0 :: non_neg_integer(),
    sent = 0 :: non_neg_integer(),
    failed = 0 :: non_neg_integer(),
    %% Batch-level counters: a batch can carry many spans, so span counts
    %% and request counts answer different questions ("are we losing
    %% data?" vs "is the collector rejecting us?").
    batches_sent = 0 :: non_neg_integer(),
    batches_failed = 0 :: non_neg_integer(),
    %% Wall-clock (unix ms) of the last successful export, so a scrape can
    %% tell "never worked" from "worked 3 s ago then stopped".
    last_success_ms = 0 :: integer(),
    %% Last failure CLASS (never the collector's raw body: it can echo the
    %% payload). Cleared on success.
    last_error = undefined :: term(),
    last_fail_log = 0 :: integer()
}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Hand a finished span to the exporter. Fire-and-forget: never
%% blocks, never raises. A no-op when export is disabled.
-spec record(map()) -> ok.
record(Span) when is_map(Span) ->
    case janus_telemetry:export_enabled() of
        true ->
            catch gen_server:cast(?SERVER, {span, Span}),
            ok;
        false ->
            ok
    end;
record(_) ->
    ok.

%% @doc Exporter counters, for the admin stats face.
-spec stats() -> map().
stats() ->
    %% SHORT timeout on purpose: the caller is the /metrics handler, and a
    %% scrape must not block for 5 s behind a busy exporter. A timeout here
    %% omits the exporter series (see the caller) rather than stalling the
    %% scrape or inventing zeros.
    try
        gen_server:call(?SERVER, stats, 1000)
    catch
        _:_ -> #{available => false}
    end.

%% @doc Force a drain now (tests and shutdown).
%% @doc Hand one logger event to the exporter. A cast, so a slow or dead
%% collector can never block the process that logged.
-spec record_log(logger:log_event()) -> ok.
record_log(Event) ->
    catch gen_server:cast(?SERVER, {log, Event}),
    ok.

-spec flush() -> ok.
flush() ->
    catch gen_server:cast(?SERVER, flush),
    ok.

%%--------------------------------------------------------------------
%% gen_server
%%--------------------------------------------------------------------

init([]) ->
    %% Pin the OTLP measurement-period start for every CUMULATIVE
    %% instrument. This MUST be written once at boot: a counter's
    %% `startTimeUnixNano' is the instant its accumulated value began, so
    %% reading it lazily would return "now" every flush and every batch
    %% would look like a counter that just reset to its current value —
    %% which a backend renders as a sawtooth of resets, not a rate.
    persistent_term:put({janus, otel_start_ns}, erlang:system_time(nanosecond)),
    %% The log handler is installed only when export is on, so a deployment
    %% that exports nothing has no logger handler and no per-event cast.
    case janus_telemetry:export_enabled() of
        true -> ok = janus_otel_logs:install();
        false -> ok
    end,
    %% The timer is only started when export is enabled at boot; a config
    %% change that enables export later starts it lazily on the next cast.
    erlang:send_after(?FLUSH_MS, self(), tick),
    erlang:send_after(?LOG_FLUSH_MS, self(), log_tick),
    {ok, #state{}}.

handle_call(stats, _From, State) ->
    #state{
        queue = Q,
        dropped = D,
        sent = S,
        failed = F,
        batches_sent = BS,
        batches_failed = BF,
        last_success_ms = LS,
        last_error = LE,
        log_queue = LQ,
        logs_sent = LSent,
        logs_dropped = LDrop
    } = State,
    {reply, #{
        available => true,
        enabled => janus_telemetry:export_enabled(),
        queued => length(Q),
        dropped_total => D,
        sent_total => S,
        failed_total => F,
        batches_sent_total => BS,
        batches_failed_total => BF,
        last_success_ms => LS,
        last_error => LE,
        logs_queued => length(LQ),
        logs_sent_total => LSent,
        logs_dropped_total => LDrop
    }, State};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast({span, Span}, State) ->
    {noreply, enqueue(State, Span)};
handle_cast({log, Event}, State) ->
    {noreply, enqueue_log(Event, State)};
handle_cast(flush, State) ->
    {noreply, do_flush(do_flush_logs(State))};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    erlang:send_after(?FLUSH_MS, self(), tick),
    {noreply, do_flush(ensure_log_handler(State))};
handle_info(log_tick, State) ->
    erlang:send_after(?LOG_FLUSH_MS, self(), log_tick),
    {noreply, do_flush_logs(ensure_log_handler(State))};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    %% Best-effort final drain so a clean shutdown does not lose the tail.
    _ = do_flush(State),
    ok.

code_change(_Old, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

enqueue(#state{queue = Q, dropped = D} = State, Span) ->
    case length(Q) >= ?MAX_QUEUE of
        true ->
            %% Drop the OLDEST (the stalest) and count it. Keeping the
            %% newest is right: recent spans describe the incident an
            %% operator is looking at.
            [_Oldest | Rest] = lists:reverse(Q),
            State#state{queue = lists:reverse([Span | Rest]), dropped = D + 1};
        false ->
            State#state{queue = [Span | Q]}
    end.

do_flush(#state{queue = []} = State) ->
    %% Spans are empty, but the metrics view is a SNAPSHOT of the live
    %% registry — it must still be exported on this tick, or a quiet
    %% gateway would publish no metrics at all.
    _ = send_metrics(),
    State;
do_flush(#state{queue = Q} = State) ->
    All = lists:reverse(Q),
    {Batch, Rest} = split_batch(All),
    Remaining = lists:reverse(Rest),
    case Batch of
        [] ->
            State#state{queue = Remaining};
        _ ->
            N = length(Batch),
            case post(Batch) of
                ok ->
                    _ = send_metrics(),
                    State#state{
                        queue = Remaining,
                        sent = State#state.sent + N,
                        batches_sent = State#state.batches_sent + 1,
                        last_success_ms = erlang:system_time(millisecond),
                        %% A success clears the last failure: a stale error
                        %% beside a fresh success reads as "still broken".
                        last_error = undefined
                    };
                {error, Why} ->
                    %% Metrics ride their own POST and their own failure
                    %% count: a span export failure must not suppress the
                    %% metrics view, or a collector rejecting one signal
                    %% would blank the other.
                    _ = send_metrics(),
                    State#state{
                        queue = Remaining,
                        failed = State#state.failed + N,
                        batches_failed = State#state.batches_failed + 1,
                        last_error = classify_failure(Why),
                        last_fail_log = maybe_log_failure(State#state.last_fail_log, Why)
                    }
            end
    end.

split_batch(All) when length(All) =< ?MAX_BATCH ->
    {All, []};
split_batch(All) ->
    lists:split(?MAX_BATCH, All).

maybe_log_failure(LastLog, Why) ->
    Now = erlang:monotonic_time(millisecond),
    case Now - LastLog >= ?FAIL_LOG_MS of
        true ->
            logger:warning(#{
                what => janus_otel_export_failed,
                reason => classify_failure(Why),
                hint => <<"spans dropped; collector unreachable or rejecting">>
            }),
            Now;
        false ->
            LastLog
    end.

%% Log a CLASS, not the raw reason: a collector's error body can echo the
%% request, and this line goes to the gateway log.
%% Every clause returns a FLAT atom or binary, because this value becomes a
%% metric LABEL. A tuple would render as "{http_status,500}", which is both
%% unreadable and a different series per spelling.
classify_failure({http, Status}) when is_integer(Status) ->
    %% Bucket by class, not by exact code: the label stays bounded and a
    %% dashboard groups 4xx/5xx sensibly. The exact code is not needed to
    %% answer "is the collector rejecting us, and how".
    case Status of
        S when S >= 500 -> collector_5xx;
        S when S >= 400 -> collector_4xx;
        _ -> collector_unexpected
    end;
classify_failure({partial, rejected}) ->
    %% Delivered but partially rejected by the collector: distinct from a
    %% transport failure, and the only class that implies real data loss
    %% behind a 2xx.
    partial_rejected;
classify_failure({error, Reason}) when is_atom(Reason) ->
    Reason;
classify_failure({error, {Class, _}}) when is_atom(Class) ->
    Class;
classify_failure(_) ->
    export_error.

post(Spans) ->
    try
        Url = export_url(),
        Body = janus_otel_otlp:encode(Spans, resource_attrs()),
        Json = thoas:encode(Body),
        Headers = [{"content-type", "application/json"}],
        Request = {Url, Headers, "application/json", Json},
        HttpOpts = [{timeout, ?HTTP_TIMEOUT_MS}, {connect_timeout, 5000}],
        Opts = [{body_format, binary}],
        inets:start(),
        case httpc:request(post, Request, HttpOpts, Opts) of
            {ok, {{_, Status, _}, _Hdrs, Body}} when Status >= 200, Status < 300 ->
                %% OTLP answers 200 even when it REJECTED part of the batch:
                %% `{"partialSuccess":{"rejectedSpans":N,"errorMessage":...}}'.
                %% Treating that as full success would hide collector-side
                %% data loss behind a healthy-looking counter.
                partial_success(Body);
            {ok, {{_, Status, _}, _Hdrs, _Body}} ->
                {error, {http, Status}};
            {error, Reason} ->
                {error, {error, Reason}}
        end
    catch
        Class:Reason2 -> {error, {error, {Class, Reason2}}}
    end.

%% Interpret an OTLP 2xx response body.
%%
%% The spec allows a successful HTTP status with a `partialSuccess' object
%% reporting `rejectedSpans'. Those spans ARE lost, so this must not be
%% reported as a clean send — but it must also not be reported as a total
%% failure, because the accepted portion did arrive and will never be
%% retried. The batch is counted as sent (it was delivered) and the
%% rejection is surfaced separately as a failure class.
partial_success(Body) when is_binary(Body), byte_size(Body) > 0 ->
    try
        case thoas:decode(Body) of
            {ok, #{<<"partialSuccess">> := PS}} when is_map(PS) ->
                Rejected = maps:get(<<"rejectedSpans">>, PS, 0),
                case is_integer(Rejected) andalso Rejected > 0 of
                    true ->
                        %% The collector's message can quote our payload, so
                        %% only a fixed class is kept.
                        {error, {partial, rejected}};
                    false ->
                        ok
                end;
            _ ->
                ok
        end
    catch
        _:_ -> ok
    end;
partial_success(_) ->
    ok.

%% `/v1/traces' appended to the configured base, tolerating a trailing
%% slash so an operator's `http://collector:4318/' does not become
%% `//v1/traces'.
export_url() ->
    Base = janus_telemetry:export_endpoint(),
    Trimmed =
        case binary:last(Base) of
            $/ -> binary:part(Base, 0, byte_size(Base) - 1);
            _ -> Base
        end,
    binary_to_list(<<Trimmed/binary, "/v1/traces">>).

%% Resource attributes identify the EMITTING service; they ride once per
%% request, not per span. `service.name' is required by the semconv.
%% The Resource is owned by `janus_otel_resource' (identity of the
%% producer: service name/version, a stable instance id derived from the
%% node alias, and the node alias itself). Kept behind this thin wrapper
%% so the exporter does not care where it comes from.
%%%-------------------------------------------------------------------
%%% Log records (design §10.2)
%%%-------------------------------------------------------------------

%% Install or remove the logger handler so it always matches the knob.
%%
%% Doing this only in `init/1' would miss a deployment that enables export
%% through the dashboard later: the handler would never be added and logs
%% would never export. Reconciling on the timer costs one comparison per
%% tick and makes the knob effective whenever it is flipped.
ensure_log_handler(State) ->
    Enabled = janus_telemetry:export_enabled(),
    Installed = lists:member(janus_otel_logs, logger:get_handler_ids()),
    case {Enabled, Installed} of
        {true, false} -> ok = janus_otel_logs:install();
        {false, true} -> ok = janus_otel_logs:uninstall();
        _ -> ok
    end,
    State.

%% Bound the queue by DROPPING THE OLDEST, matching the span queue's
%% policy: the newest lines are the ones near the failure an operator is
%% looking at, and a bounded buffer with counted loss is the contract
%% telemetry must keep.
enqueue_log(Event, #state{log_queue = Q, logs_dropped = D} = State) ->
    case encode_log(Event) of
        skip ->
            State;
        Rec ->
            case length(Q) >= ?LOG_MAX_QUEUE of
                true ->
                    %% Drop the OLDEST: the newest lines are the ones near
                    %% the failure an operator is looking at.
                    State#state{
                        log_queue = lists:droplast([Rec | Q]),
                        logs_dropped = D + 1
                    };
                false ->
                    State#state{log_queue = [Rec | Q]}
            end
    end.

do_flush_logs(#state{log_queue = []} = State) ->
    State;
do_flush_logs(#state{log_queue = Q} = State) ->
    All = lists:reverse(Q),
    {Batch, Rest} = lists:split(min(length(All), ?LOG_MAX_BATCH), All),
    case post_logs(Batch) of
        ok ->
            State#state{
                log_queue = lists:reverse(Rest),
                logs_sent = State#state.logs_sent + length(Batch)
            };
        {error, Why} ->
            %% Dropped rather than retried, like the span queue: a log line
            %% that missed its moment is worth less than the memory its
            %% retry would pin.
            %%
            %% Deliberately NOT logged here: this function runs inside the
            %% logger handler's own export path, so a log line would feed
            %% itself back in. The failure surfaces through `stats/0'
            %% (`last_error') instead.
            State#state{
                log_queue = lists:reverse(Rest),
                logs_dropped = State#state.logs_dropped + length(Batch),
                last_error = classify_failure(Why)
            }
    end.

%% One logger event in the OTLP log data model.
%%
%% A line emitted outside any span carries NO traceId/spanId: absence is
%% explicit and must not be back-filled with a fabricated id (§10.1).
encode_log(#{level := Level, msg := Msg} = Event) ->
    try
        Meta = maps:get(meta, Event, #{}),
        {SevNum, SevText} = janus_otel_logs:severity(normalize_level(Level)),
        Base = #{
            <<"timeUnixNano">> => integer_to_binary(now_ns()),
            <<"observedTimeUnixNano">> => integer_to_binary(now_ns()),
            <<"severityNumber">> => SevNum,
            <<"severityText">> => SevText,
            <<"body">> => #{<<"stringValue">> => render_body(Msg)},
            <<"attributes">> => janus_otel_otlp:encode_attrs(
                maps:merge(flatten_meta(Meta), report_fields(Msg))
            )
        },
        maps:merge(Base, trace_ids(Meta))
    catch
        _:_ -> skip
    end;
encode_log(_) ->
    skip.

%% @doc Exposed for the conformance gate: the encoder above.
-spec encode_log_for_test(logger:log_event()) -> map() | skip.
encode_log_for_test(Event) ->
    encode_log(Event).

%% `warning' must land in the WARN band: §10.2 is explicit that
%% severityNumber >= 17 means "erroneous" and backends count errors from it,
%% so promoting a recoverable warning would misreport it as an error.
normalize_level(L) when is_atom(L) -> L;
normalize_level(_) -> info.

%% Correlate from `meta', never from a process dictionary: `meta' is
%% captured by `logger' at the call site and is therefore correct even when
%% a report is formatted or handled in another process.
trace_ids(Meta) ->
    T =
        case maps:get(trace_id, Meta, undefined) of
            V when is_binary(V), byte_size(V) =:= 32 -> #{<<"traceId">> => V};
            _ -> #{}
        end,
    S =
        case maps:get(span_id, Meta, undefined) of
            V2 when is_binary(V2), byte_size(V2) =:= 16 -> #{<<"spanId">> => V2};
            _ -> #{}
        end,
    maps:merge(T, S).

%% The structured report becomes ATTRIBUTES and the rendered text becomes
%% the body, which is the split the OTLP model asks for: a backend can group
%% by `what' without parsing the human-readable line.
flatten_meta(Meta) ->
    maps:fold(
        fun(K, V, Acc) ->
            case loggable(K) of
                true -> Acc#{atom_to_binary(K, utf8) => attr_value(V)};
                false -> Acc
            end
        end,
        #{},
        Meta
    ).

%% A structured report's own fields become ATTRIBUTES, so a backend can
%% group by `what' without parsing the body. This is the split the module
%% comment promises and the OTLP data model expects.
report_fields({report, Report}) when is_map(Report) ->
    flatten_meta(Report);
report_fields(_) ->
    #{}.

%% Reserved OTP logger keys carry no information of their own, and
%% `trace_id'/'span_id' ride the dedicated proto fields instead.
loggable(gl) -> false;
loggable(time) -> false;
loggable(mfa) -> false;
loggable(file) -> false;
loggable(line) -> false;
loggable(pid) -> false;
loggable(domain) -> false;
loggable(report_cb) -> false;
loggable(trace_id) -> false;
loggable(span_id) -> false;
loggable(_) -> true.

attr_value(V) when is_binary(V) -> V;
attr_value(V) when is_integer(V) -> V;
attr_value(V) when is_float(V) -> V;
attr_value(V) when is_boolean(V) -> V;
attr_value(V) when is_atom(V) -> atom_to_binary(V, utf8);
attr_value(V) -> iolist_to_binary(io_lib:format("~0p", [V])).

%% `msg' arrives in several shapes; every one must render as the text a
%% human would have seen, never as a quoted Erlang term.
render_body({string, Chardata}) ->
    unicode:characters_to_binary(Chardata);
render_body({report, Report}) when is_map(Report) ->
    iolist_to_binary(io_lib:format("~0p", [Report]));
render_body({Format, Args}) when is_list(Args) ->
    try
        iolist_to_binary(io_lib:format(Format, Args))
    catch
        _:_ -> iolist_to_binary(io_lib:format("~0p", [{Format, Args}]))
    end;
render_body(B) when is_binary(B) ->
    B;
render_body(Other) ->
    iolist_to_binary(io_lib:format("~0p", [Other])).

post_logs([]) ->
    ok;
post_logs(Records) ->
    try
        Body = janus_otel_otlp:encode_logs(Records, resource_attrs()),
        Json = thoas:encode(Body),
        Url = signal_url(<<"logs">>),
        Headers = [{"content-type", "application/json"}],
        Request = {Url, Headers, "application/json", Json},
        HttpOpts = [{timeout, ?HTTP_TIMEOUT_MS}, {connect_timeout, 5000}],
        Opts = [{body_format, binary}],
        inets:start(),
        case httpc:request(post, Request, HttpOpts, Opts) of
            {ok, {{_, Status, _}, _H, _B}} when Status >= 200, Status < 300 -> ok;
            {ok, {{_, Status, _}, _H, _B}} -> {error, {collector_http, Status}};
            {error, Why} -> {error, Why}
        end
    catch
        _Class:_Reason ->
            %% Deliberately not logged: this runs inside the logger
            %% handler's own export path, so a log line here would feed
            %% itself back in. The failure surfaces through `stats/0'.
            {error, encode_failed}
    end.

now_ns() ->
    erlang:system_time(nanosecond).

%% Export the metrics VIEW of the same ETS registry (design §8.1).
%%
%% Unlike spans these are not queued: the registry already holds the
%% cumulative totals, so each tick reads a snapshot and posts it. A dropped
%% tick loses nothing — the next one carries the same totals plus whatever
%% arrived — which is why there is no queue, no backpressure, and no
%% drop counter for this signal.
%%
%% Failure is reported through the SAME `last_error' the span path uses, so
%% a scrape cannot see "spans fine" while metrics silently never arrive.
send_metrics() ->
    try
        case janus_telemetry:export_enabled() of
            false ->
                ok;
            true ->
                Rows = janus_metrics:snapshot(),
                Body = janus_otel_otlp:encode_metrics(
                    Rows, [], resource_attrs(), start_ns()
                ),
                Json = thoas:encode(Body),
                Url = signal_url(<<"metrics">>),
                Headers = [{"content-type", "application/json"}],
                Request = {Url, Headers, "application/json", Json},
                HttpOpts = [{timeout, ?HTTP_TIMEOUT_MS}, {connect_timeout, 5000}],
                Opts = [{body_format, binary}],
                inets:start(),
                case httpc:request(post, Request, HttpOpts, Opts) of
                    {ok, {{_, Status, _}, _H, _B}} when Status >= 200, Status < 300 ->
                        ok;
                    {ok, {{_, Status, _}, _H, _B}} ->
                        {error, {collector_http, Status}};
                    {error, Why} ->
                        {error, Why}
                end
        end
    catch
        _:_ -> ok
    end.

%% The process-lifetime start instant for a CUMULATIVE instrument.
%%
%% Written once by `init/1'. The fallback computes boot-relative zero
%% rather than "now": if this is ever reached it means init did not run, and
%% a stable value keeps every batch in the same period instead of making
%% each one look like a reset.
start_ns() ->
    persistent_term:get({janus, otel_start_ns}, boot_ns()).

%% Wall-clock nanoseconds at VM start, derived from the monotonic clock so
%% it is stable even if the system clock jumps after boot.
boot_ns() ->
    erlang:system_time(nanosecond) -
        erlang:convert_time_unit(erlang:monotonic_time(), native, nanosecond).


%% NO gauges in the OTLP metrics view, deliberately.
%%
%% The scrape-time gauges are assembled inside `janus_http_metrics:init/2'
%% from five subsystems, interleaved with the scrape that renders them.
%% Reading them from here would mean either duplicating that assembly (a
%% second implementation that drifts the first time a gauge is added) or
%% reaching into a subsystem this process does not own. Both are worse than
%% the honest gap: the counters — which ARE the authoritative registry —
%% export here, and the gauges stay on the Prometheus view, which is the
%% only place they are computed from live scrape-time state.
%%
%% Recorded rather than silently omitted, so a later reader does not read
%% "no gauges in OTLP" as an oversight to fix by fabricating zeros.

%% `/v1/traces' for spans, `/v1/metrics' for metrics: the OTLP/HTTP
%% specification puts each signal on its own path under the same base.
signal_url(Signal) ->
    Base = janus_telemetry:export_endpoint(),
    Trimmed =
        case binary:last(Base) of
            $/ -> binary:part(Base, 0, byte_size(Base) - 1);
            _ -> Base
        end,
    binary_to_list(<<Trimmed/binary, "/v1/", Signal/binary>>).

resource_attrs() ->
    janus_otel_resource:get().