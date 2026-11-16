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
%%% ## Retry: in-flush, bounded by the export timeout (exporter spec MUST)
%%%
%%% "Transient errors MUST be handled with a retry strategy … the retry
%%% strategy MUST implement an exponential back-off with jitter … Each
%%% request attempt and wait between retries MUST be bounded by the
%%% remaining time allowed by the exporter timeout."
%%% (<https://opentelemetry.io/docs/specs/otel/protocol/exporter/>)
%%%
%%% Transient — and therefore retried — are exactly HTTP 429/502/503/504
%%% and transport-level failures (connect refused, timeout, TLS drops);
%%% "All other 4xx/5xx MUST NOT be retried" (OTLP spec), so a 400 or a
%%% 404 against a wrong endpoint fails fast instead of hammering it four
%%% times. `Retry-After' on a 429/503 is honoured when it fits the
%%% remaining budget. When the budget is gone the batch is dropped and
%%% counted — retrying is a property of this writer process, never of
%%% the caller.
%%%
%%% ## Failure posture
%%%
%%% A POST that survives its retry episode failed permanently: the batch
%%% is dropped, the failure counted and logged at a rate limit so an
%%% outage does not itself flood the log.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_otel_export).

-behaviour(gen_server).

-export([start_link/0, record/1, record_log/1, stats/0, flush/0]).
%% Conformance seam: the log record encoder, so the wire shape is asserted
%% where it is built rather than inferred from the severity table.
-export([encode_log_for_test/1]).
%% Exported for eunit: the retry policy is pure over (reason, attempt,
%% budget), so its exactness — which statuses retry, which never do,
%% that the backoff is exponential and jittered and never exceeds the
%% budget — can be pinned without a collector.
-export([retryable/1, backoff_delay_ms/3, retry_after_ms/1, partial_success/2]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
%% Named ETS mirror of the stats map (see stats/0): read by scrapes
%% without going through the exporter process.
-define(STATS_TABLE, janus_otel_export_stats).
%% Hard caps. The batch size bounds one HTTP request; the queue cap bounds
%% memory during a collector outage. Both are counted losses.
-define(MAX_BATCH, 512).
-define(MAX_QUEUE, 4096).
-define(FLUSH_MS, 2000).
%% The exporter-timeout budget from the exporter spec. It bounds ONE
%% signal POST including all of its retries: an attempt and every wait
%% between attempts must fit inside what remains of it.
%%
%% The NORMAL episode budget is deliberately tighter than the spec's 10s
%% default: a tick flush runs inside the gen_server, the supervisor's
%% shutdown window is 5 s, and a stop that lands mid-episode must let
%% BOTH the tick and terminate/2's one-shot drain finish inside it — or
%% the supervisor kills the port-holding process and the next boot races
%% "address already in use". 4 s + 1 s shutdown drain = 5 s worst case.
-define(HTTP_TIMEOUT_MS, 10000).
-define(FLUSH_BUDGET_MS, 4000).
%% In-flush retry episode: initial attempt plus up to 3 retries, sleeping
%% an exponentially growing jittered delay between them (200ms base:
%% 200, 400, 800 — worst case ~1.4s of waiting inside the 10s budget,
%% the rest is the attempts' own time).
-define(MAX_ATTEMPTS, 4).
-define(RETRY_BASE_MS, 200).
%% A retry sleep may never consume the LAST of the budget: the attempt
%% itself needs a slice, or the episode degrades into pure added latency
%% that ends in budget_exhausted without ever firing.
-define(MIN_ATTEMPT_BUDGET_MS, 1000).
%% The shutdown flush gets its own short budget AND a single attempt:
%% terminate/2 must not block past the supervisor's shutdown window
%% (see ?FLUSH_BUDGET_MS above for the arithmetic).
-define(SHUTDOWN_BUDGET_MS, 1000).
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
    %% The metrics view is a snapshot POST, not a queue, so its loss has
    %% no drop counter of its own — this is the counted-not-silent signal
    %% for "traces fine, metrics never arrive" (the live 404 case).
    metrics_batches_failed = 0 :: non_neg_integer(),
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
%% blocks, never raises. A no-op when export — or the traces signal —
%% is disabled.
-spec record(map()) -> ok.
record(Span) when is_map(Span) ->
    %% `signal_enabled' alone: it implies the kill switch is off, and
    %% `export_enabled()' is literally any(signal_enabled) — the
    %% conjunction re-derived three env resolutions per cast for nothing.
    case janus_telemetry:signal_enabled(traces) of
        true ->
            catch gen_server:cast(?SERVER, {span, Span}),
            ok;
        false ->
            ok
    end;
record(_) ->
    ok.

%% @doc Exporter counters, for the admin stats face.
%%
%% Reads the ETS MIRROR first: the exporter is one process, and during a
%% retry episode (up to ~seconds of sleeps against a sick collector) it
%% cannot answer a `gen_server:call'. The old call-only reader timed out
%% exactly then, and `/metrics' dropped the whole `otel_export_*' family
%% at the moment its failure counters were the thing an operator needed.
%% The exporter refreshes the mirror after every state change, so the
%% table is at most one mutation stale — a scrape that must be
%% instantaneous accepts that; the call fallback covers the window
%% between boot and the first refresh.
-spec stats() -> map().
stats() ->
    try
        case ets:lookup(?STATS_TABLE, stats) of
            [{stats, M}] when is_map(M) ->
                M;
            [] ->
                stats_via_call()
        end
    catch
        _:_ -> stats_via_call()
    end.

stats_via_call() ->
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
    %% The log handler is installed only when export AND the logs signal
    %% are on, so a deployment that exports nothing has no logger handler
    %% and no per-event cast.
    case janus_telemetry:signal_enabled(logs) of
        true -> ok = janus_otel_logs:install();
        false -> ok
    end,
    %% The timer is only started when export is enabled at boot; a config
    %% change that enables export later starts it lazily on the next cast.
    %% `protected': every process may READ (that is the point), only
    %% this gen_server may write — a `public' table would let any process
    %% in the VM corrupt the otel_export_* /metrics output.
    _ = (catch ets:new(?STATS_TABLE, [named_table, protected, set, {read_concurrency, true}])),
    mirror_stats(#state{}),
    erlang:send_after(?FLUSH_MS, self(), tick),
    erlang:send_after(?LOG_FLUSH_MS, self(), log_tick),
    {ok, #state{}}.

handle_call(stats, _From, State) ->
    {reply, stats_map(State), State};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

stats_map(#state{
    queue = Q,
    dropped = D,
    sent = S,
    failed = F,
    batches_sent = BS,
    batches_failed = BF,
    metrics_batches_failed = MBF,
    last_success_ms = LS,
    last_error = LE,
    log_queue = LQ,
    logs_sent = LSent,
    logs_dropped = LDrop
}) ->
    #{
        available => true,
        enabled => janus_telemetry:export_enabled(),
        queued => length(Q),
        dropped_total => D,
        sent_total => S,
        failed_total => F,
        batches_sent_total => BS,
        batches_failed_total => BF,
        metrics_batches_failed_total => MBF,
        last_success_ms => LS,
        last_error => LE,
        logs_queued => length(LQ),
        logs_sent_total => LSent,
        logs_dropped_total => LDrop
    }.

%% NOTE: enqueue casts do NOT mirror. The mirror exists for scrapes
%% during retry episodes; a burst of casts each paying `length/1' plus
%% the stats build would slow the drain exactly when it matters. The
%% queue-depth gauge lags at most one tick (2 s), which a human reading
%% a dashboard cannot perceive.
handle_cast({span, Span}, State) ->
    {noreply, enqueue(State, Span)};
handle_cast({log, Event}, State) ->
    {noreply, enqueue_log(Event, State)};
handle_cast(flush, State) ->
    {noreply, mirror_stats(do_flush(do_flush_logs(State)))};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    erlang:send_after(?FLUSH_MS, self(), tick),
    {noreply, mirror_stats(do_flush(ensure_log_handler(State)))};
handle_info(log_tick, State) ->
    erlang:send_after(?LOG_FLUSH_MS, self(), log_tick),
    {noreply, mirror_stats(do_flush_logs(ensure_log_handler(State)))};
handle_info(_Info, State) ->
    {noreply, State}.

%% Refresh the ETS stats mirror. `catch' because the table may be absent
%% (a fresh VM in tests before init ran, or after a crash) — the reader
%% falls back to the call, so a failed mirror write is a stale read, not
%% a crash of the exporter itself.
mirror_stats(State) ->
    _ = (catch ets:insert(?STATS_TABLE, {stats, stats_map(State)})),
    State.

terminate(_Reason, State) ->
    %% Best-effort final drain so a clean shutdown does not lose the tail.
    %% ONE attempt per signal AND a short budget, deliberately: a full
    %% episode (or one 10s-attempt against a hung collector) can block
    %% past the supervisor's shutdown window, and the port-reuse race
    %% that follows turns a restart into "address already in use". Losing
    %% the last batch on shutdown is the cheaper failure.
    _ = do_flush(State, 1, ?SHUTDOWN_BUDGET_MS),
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

do_flush(State) ->
    do_flush(State, ?MAX_ATTEMPTS, ?FLUSH_BUDGET_MS).

do_flush(#state{queue = []} = State, Attempts, BudgetMs) ->
    %% Spans are empty, but the metrics view is a SNAPSHOT of the live
    %% registry — it must still be exported on this tick, or a quiet
    %% gateway would publish no metrics at all.
    count_metrics_result(send_metrics(Attempts, BudgetMs), State);
do_flush(#state{queue = Q} = State, Attempts, BudgetMs) ->
    All = lists:reverse(Q),
    {Batch, Rest} = split_batch(All),
    Remaining = lists:reverse(Rest),
    case Batch of
        [] ->
            State#state{queue = Remaining};
        _ ->
            N = length(Batch),
            case post(Batch, Attempts, BudgetMs) of
                ok ->
                    %% Metrics ride their own POST and their own failure
                    %% count: a span export failure must not suppress the
                    %% metrics view, or a collector rejecting one signal
                    %% would blank the other. The metrics result is folded
                    %% LAST so a metrics-only failure (the 404 case) stays
                    %% visible in `last_error' on ticks where spans are
                    %% fine — folding it first would let the span success
                    %% reset it every time.
                    State1 = State#state{
                        queue = Remaining,
                        sent = State#state.sent + N,
                        batches_sent = State#state.batches_sent + 1,
                        last_success_ms = erlang:system_time(millisecond),
                        %% A success clears the last failure: a stale error
                        %% beside a fresh success reads as "still broken".
                        last_error = undefined
                    },
                    count_metrics_result(send_metrics(Attempts, BudgetMs), State1);
                {error, {partial, rejected} = Why} ->
                    %% Delivered, partially accepted: the accepted portion
                    %% arrived and will never be retried, so the batch is
                    %% counted as SENT and the rejection surfaced as its
                    %% own failure class — not folded into `failed', which
                    %% would read "nothing arrived" next to a collector
                    %% that ingested most of the batch.
                    StateP = State#state{
                        queue = Remaining,
                        sent = State#state.sent + N,
                        batches_sent = State#state.batches_sent + 1,
                        last_success_ms = erlang:system_time(millisecond),
                        last_error = classify_failure(Why)
                    },
                    count_metrics_result(send_metrics(Attempts, BudgetMs), StateP);
                {error, Why} ->
                    State1 = count_metrics_result(send_metrics(Attempts, BudgetMs), State),
                    State1#state{
                        queue = Remaining,
                        failed = State1#state.failed + N,
                        batches_failed = State1#state.batches_failed + 1,
                        last_error = classify_failure(Why),
                        last_fail_log = maybe_log_failure(State1#state.last_fail_log, Why)
                    }
            end
    end.

%% The metrics view's failures get their own counter (there is no queue,
%% hence no drop counter for this signal); `last_error' also adopts the
%% class so a scrape cannot read "spans fine" while metrics never arrive.
%% A metrics success does NOT clear `last_error' — only a successful span
%% batch does — because the two POSTs are independent and a metrics ok
%% says nothing about the span path.
count_metrics_result(ok, State) ->
    State;
count_metrics_result({error, Why}, #state{metrics_batches_failed = MF} = State) ->
    State#state{
        metrics_batches_failed = MF + 1,
        last_error = classify_failure(Why)
    };
count_metrics_result(_, State) ->
    State.

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

post(Spans, MaxAttempts, BudgetMs) ->
    try
        Body = thoas:encode(janus_otel_otlp:encode(Spans, resource_attrs())),
        case post_json(janus_telemetry:signal_url(traces), Body, traces, MaxAttempts, BudgetMs) of
            {ok, RespBody} -> partial_success(RespBody, <<"rejectedSpans">>);
            {error, Why} -> {error, Why}
        end
    catch
        Class:Reason -> {error, {error, {Class, Reason}}}
    end.

%% One OTLP POST with the exporter spec's bounded retry episode.
%%
%% Returns `{ok, RespBody}' for any 2xx, `{error, Why}' otherwise, where
%% `Why' is the LAST failure (`{http, Status}' | `{error, Transport}' |
%% `{error, {Class, Reason}}' from an exception | `{error,
%% budget_exhausted}'). The per-attempt HTTP timeout shrinks to the
%% remaining budget so the whole episode — attempts and sleeps both —
%% stays inside ?HTTP_TIMEOUT_MS.
post_json(Url, Json, Signal) ->
    post_json(Url, Json, Signal, ?MAX_ATTEMPTS, ?HTTP_TIMEOUT_MS).

post_json(Url, Json, Signal, MaxAttempts, BudgetMs)
    when is_integer(MaxAttempts), MaxAttempts >= 1, is_integer(BudgetMs), BudgetMs > 0 ->
    Headers = req_headers(Signal),
    Request = {binary_to_list(Url), Headers, "application/json", Json},
    Deadline = erlang:monotonic_time(millisecond) + BudgetMs,
    inets:start(),
    post_attempt(Request, Deadline, BudgetMs, MaxAttempts, 1).

req_headers(Signal) ->
    [{"content-type", "application/json"}]
    ++ [{binary_to_list(K), binary_to_list(V)} || {K, V} <- janus_telemetry:export_headers(Signal)].

post_attempt(Request, Deadline, BudgetMs, MaxAttempts, Attempt) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true ->
            {error, {error, budget_exhausted}};
        false ->
            HttpOpts = [
                {timeout, min(BudgetMs, Remaining)},
                {connect_timeout, min(5000, Remaining)}
            ],
            try httpc:request(post, Request, HttpOpts, [{body_format, binary}]) of
                {ok, {{_, Status, _}, _Hdrs, Body}} when Status >= 200, Status < 300 ->
                    {ok, Body};
                {ok, {{_, Status, _}, Hdrs, _Body}} ->
                    maybe_retry({http, Status}, retry_after_ms(Hdrs), Request, Deadline, BudgetMs, MaxAttempts, Attempt);
                {error, Reason} ->
                    maybe_retry({error, Reason}, undefined, Request, Deadline, BudgetMs, MaxAttempts, Attempt)
            catch
                Class:Reason ->
                    maybe_retry({error, {Class, Reason}}, undefined, Request, Deadline, BudgetMs, MaxAttempts, Attempt)
            end
    end.

%% Retry only the transient classes, only while attempts remain, and only
%% if the delay still fits the budget. `Retry-After' (429/503) is a floor
%% on the delay: the collector asked us to wait at least that long, and
%% retrying earlier would be the load spike the spec's jitter rule exists
%% to prevent.
maybe_retry(Why, RetryAfter, Request, Deadline, BudgetMs, MaxAttempts, Attempt) ->
    case retryable(Why) andalso Attempt < MaxAttempts of
        true ->
            Delay = backoff_delay_ms(Attempt, RetryAfter, Deadline - erlang:monotonic_time(millisecond)),
            case Delay =< 0 of
                true -> {error, Why};
                false ->
                    receive
                    after Delay -> ok
                    end,
                    post_attempt(Request, Deadline, BudgetMs, MaxAttempts, Attempt + 1)
            end;
        false ->
            {error, Why}
    end.

%% OTLP/HTTP: retryable is EXACTLY 429/502/503/504 — "all other 4xx/5xx
%% MUST NOT be retried". A 404 against a traces-only collector, a 400
%% against a strict one: fail fast, count, do not hammer. Transport-level
%% failures (connect refused, timeout, a dropped TLS connection) are
%% transient by nature; an exception tuple from our own code is NOT
%% (retrying a bug produces four identical crashes and no data).
-spec retryable(term()) -> boolean().
retryable({http, Status}) ->
    lists:member(Status, [429, 502, 503, 504]);
retryable({error, {failed_connect, _}}) ->
    true;
retryable({error, timeout}) ->
    true;
retryable({error, Reason}) when is_atom(Reason) ->
    %% The closed set of TRANSIENT transport reasons. A bare-atom
    %% catch-all would also retry `nxdomain' (a wrong host the operator
    %% must fix) and `emfile'/`enomem' (a host already on its knees) four
    %% times each — a spec violation ("all other errors MUST NOT be
    %% retried") and a self-inflicted spike at the worst moment.
    lists:member(Reason, [
        econnrefused,
        econnreset,
        ehostunreach,
        enetunreach,
        etimedout,
        connect_timeout,
        socket_closed_remotely,
        unexpected_end_of_input,
        closed,
        ebusy
    ]);
retryable(_) ->
    false.

%% Exponential back-off with jitter (both spec-mandated): the base doubles
%% per attempt and the actual delay lands in [50%, 100%) of it, so a fleet
%% hitting one recovering collector does not sync its retries. `RetryAfter'
%% raises the floor; the remaining budget caps the ceiling — a delay that
%% does not fit the budget returns <= 0 and the caller stops.
-spec backoff_delay_ms(pos_integer(), non_neg_integer() | undefined, integer()) -> integer().
backoff_delay_ms(Attempt, RetryAfterMs, RemainingMs) ->
    Base = ?RETRY_BASE_MS bsl (Attempt - 1),
    Delay = trunc(Base * (0.5 + rand:uniform() / 2)),
    WithFloor =
        case is_integer(RetryAfterMs) andalso RetryAfterMs > Delay of
            true -> RetryAfterMs;
            false -> Delay
        end,
    %% Reserve a slice for the attempt itself: a sleep that eats the whole
    %% budget ends the episode in budget_exhausted WITHOUT firing, which is
    %% pure added latency (and, on the shutdown path, delayed restart).
    min(WithFloor, RemainingMs - ?MIN_ATTEMPT_BUDGET_MS).

%% `Retry-After' as milliseconds when it is the spec's integer-seconds
%% form. Other forms (HTTP-date) are ignored: guessing a wrong delay is
%% worse than falling back to the backoff curve.
-spec retry_after_ms([{string(), string()}]) -> non_neg_integer() | undefined.
retry_after_ms(Hdrs) ->
    case proplists:get_value("retry-after", Hdrs) of
        V when is_list(V) ->
            case string:trim(V) of
                "0" -> 0;
                Digits ->
                    case catch list_to_integer(Digits) of
                        N when is_integer(N), N > 0 -> N * 1000;
                        _ -> undefined
                    end
            end;
        _ ->
            undefined
    end.

%% Interpret an OTLP 2xx response body against one signal's rejected-key
%% (`rejectedSpans' / `rejectedLogRecords' / `rejectedMetricPoints').
%%
%% The spec allows a successful HTTP status with a `partialSuccess' object
%% reporting rejections. Those items ARE lost, so this must not be
%% reported as a clean send — but it must also not be reported as a total
%% failure, because the accepted portion did arrive and will never be
%% retried. The caller counts the batch as sent when it was, and the
%% rejection is surfaced separately as a failure class. An ABSENT
%% partialSuccess, or an empty one (`{"partialSuccess":{}}', what Tempo
%% answers on a clean accept), is a success — production evidence: a
%% variant that treated the empty object as a rejection reported every
%% healthy POST as failed while the data was being ingested all along.
partial_success(Body, RejectedKeys)
    when is_binary(Body), byte_size(Body) > 0, is_binary(RejectedKeys) orelse is_list(RejectedKeys) ->
    try
        case thoas:decode(Body) of
            {ok, #{<<"partialSuccess">> := PS}} when is_map(PS) ->
                %% One decode, N candidate keys (the metrics field was
                %% renamed pre-1.1; both spellings are accepted).
                Keys = keys_list(RejectedKeys),
                Rejected = lists:foldl(
                    fun(K, Acc) -> max(Acc, rejected_count(maps:get(K, PS, 0))) end,
                    0,
                    Keys
                ),
                case Rejected > 0 of
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
partial_success(_, _) ->
    ok.

keys_list(K) when is_binary(K) -> [K];
keys_list(Ks) when is_list(Ks) -> [K || K <- Ks, is_binary(K)].

%% The rejected-count fields are int64, and proto3-JSON encodes int64 as a
%% decimal STRING — the same wire rule this gateway's own encoder follows
%% for `asInt'/`count'. A compliant collector answers
%% `{"rejectedSpans":"3"}'; reading the value as an integer-only guard
%% would misread that as a clean accept, hiding the exact collector-side
%% data loss this function exists to surface. Both forms normalize.
rejected_count(N) when is_integer(N) ->
    N;
rejected_count(S) when is_binary(S) ->
    try
        binary_to_integer(S)
    catch
        _:_ -> 0
    end;
rejected_count(_) ->
    0.

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
    Enabled = janus_telemetry:signal_enabled(logs),
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
%% `timeUnixNano' is the EVENT's own timestamp (logger stamps `meta.time'
%% in microseconds at the call site); `observedTimeUnixNano' is when the
%% exporter saw it. Under queue pressure the two diverge, which is exactly
%% what the second field exists to show — using "now" for both would
%% backdate every delayed record to its enqueue time.
encode_log(#{level := Level, msg := Msg} = Event) ->
    try
        Meta = maps:get(meta, Event, #{}),
        {SevNum, SevText} = janus_otel_logs:severity(normalize_level(Level)),
        Base = #{
            <<"timeUnixNano">> => integer_to_binary(event_ns(Meta)),
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

%% The event's own instant in nanoseconds, or "now" when the logger gave
%% no timestamp (a hand-rolled event, or an OTP version without one).
event_ns(Meta) ->
    case Meta of
        #{time := Us} when is_integer(Us), Us > 0 -> Us * 1000;
        _ -> now_ns()
    end.

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

%% Scrub credential shapes before OTLP encode (security audit run-2):
%% Bearer/sk-/PEM must not leave the gateway trust boundary.
attr_value(V) when is_binary(V) -> janus_task_run:scrub(V);
attr_value(V) when is_integer(V) -> V;
attr_value(V) when is_float(V) -> V;
attr_value(V) when is_boolean(V) -> V;
attr_value(V) when is_atom(V) -> atom_to_binary(V, utf8);
attr_value(V) -> janus_task_run:scrub(iolist_to_binary(io_lib:format("~0p", [V]))).

%% `msg' arrives in several shapes; every one must render as the text a
%% human would have seen, never as a quoted Erlang term.
render_body({string, Chardata}) ->
    janus_task_run:scrub(unicode:characters_to_binary(Chardata));
render_body({report, Report}) when is_map(Report) ->
    janus_task_run:scrub(iolist_to_binary(io_lib:format("~0p", [Report])));
render_body({Format, Args}) when is_list(Args) ->
    Text =
        try
            iolist_to_binary(io_lib:format(Format, Args))
        catch
            _:_ -> iolist_to_binary(io_lib:format("~0p", [{Format, Args}]))
        end,
    janus_task_run:scrub(Text);
render_body(B) when is_binary(B) ->
    janus_task_run:scrub(B);
render_body(Other) ->
    janus_task_run:scrub(iolist_to_binary(io_lib:format("~0p", [Other]))).

post_logs([]) ->
    ok;
post_logs(Records) ->
    try
        Body = thoas:encode(janus_otel_otlp:encode_logs(Records, resource_attrs())),
        case post_json(janus_telemetry:signal_url(logs), Body, logs) of
            {ok, RespBody} -> partial_success(RespBody, <<"rejectedLogRecords">>);
            {error, Why} -> {error, Why}
        end
    catch
        _Class:_Reason ->
            %% Deliberately not logged: this runs inside the logger
            %% handler's own export path, so a log line here would feed
            %% itself back in. The failure surfaces through `stats/0'.
            %% Bare atom, not a nested tuple: classify_failure keeps the
            %% specific `encode_failed' label.
            {error, encode_failed}
    end.

now_ns() ->
    erlang:system_time(nanosecond).

%% Export the metrics VIEW of the same ETS registry (design §8.1).
%%
%% Unlike spans these are not queued: the registry already holds the
%% cumulative totals, so each tick reads a snapshot and posts it. A dropped
%% tick loses nothing — the next one carries the same totals plus whatever
%% arrived — which is why there is no queue and no drop counter for this
%% signal. Failures ARE counted (`metrics_batches_failed_total' in
%% stats/0) and surface in `last_error', so a scrape cannot see "spans
%% fine" while metrics silently never arrive.
%%
%% Gated on the metrics signal: a traces-only collector (the common
%% deployment) would otherwise answer 404 to this POST every tick, forever
%% — observed live against Tempo.
send_metrics(MaxAttempts, BudgetMs) ->
    try
        case
            janus_telemetry:export_enabled() andalso janus_telemetry:signal_enabled(metrics)
        of
            false ->
                ok;
            true ->
                Rows = janus_metrics:snapshot(),
                Body = thoas:encode(
                    janus_otel_otlp:encode_metrics(Rows, [], resource_attrs(), start_ns())
                ),
                case
                    post_json(
                        janus_telemetry:signal_url(metrics), Body, metrics, MaxAttempts, BudgetMs
                    )
                of
                    {ok, RespBody} ->
                        %% Both known field names, ONE decode: they are
                        %% aliases of the same count (pre-1.1 and current).
                        partial_success(
                            RespBody,
                            [<<"rejectedMetricPoints">>, <<"rejectedDataPoints">>]
                        );
                    {error, Why} ->
                        {error, Why}
                end
        end
    catch
        %% Bare atom for the same reason as post_logs: the specific
        %% `encode_failed' label survives classification.
        _:_ -> {error, encode_failed}
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

%% The per-signal URL lives in `janus_telemetry:signal_url/1': it owns the
%% exporter-spec precedence (per-signal env var as-is, generic base with
%% `/v1/<signal>' appended), and this module must not second-guess it.

resource_attrs() ->
    janus_otel_resource:get().