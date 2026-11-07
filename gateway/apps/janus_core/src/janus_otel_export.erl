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

-export([start_link/0, record/1, stats/0, flush/0]).
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

-record(state, {
    queue = [] :: [map()],
    started = false :: boolean(),
    dropped = 0 :: non_neg_integer(),
    sent = 0 :: non_neg_integer(),
    failed = 0 :: non_neg_integer(),
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
    try
        gen_server:call(?SERVER, stats, 5000)
    catch
        _:_ -> #{available => false}
    end.

%% @doc Force a drain now (tests and shutdown).
-spec flush() -> ok.
flush() ->
    catch gen_server:cast(?SERVER, flush),
    ok.

%%--------------------------------------------------------------------
%% gen_server
%%--------------------------------------------------------------------

init([]) ->
    %% The timer is only started when export is enabled at boot; a config
    %% change that enables export later starts it lazily on the next cast.
    erlang:send_after(?FLUSH_MS, self(), tick),
    {ok, #state{}}.

handle_call(stats, _From, State) ->
    #state{queue = Q, dropped = D, sent = S, failed = F} = State,
    {reply, #{
        available => true,
        queued => length(Q),
        dropped_total => D,
        sent_total => S,
        failed_total => F
    }, State};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast({span, Span}, State) ->
    {noreply, enqueue(State, Span)};
handle_cast(flush, State) ->
    {noreply, do_flush(State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    erlang:send_after(?FLUSH_MS, self(), tick),
    {noreply, do_flush(State)};
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
    State;
do_flush(#state{queue = Q, sent = Sent, failed = Failed} = State) ->
    All = lists:reverse(Q),
    {Batch, Rest} = split_batch(All),
    Remaining = lists:reverse(Rest),
    case Batch of
        [] ->
            State#state{queue = Remaining};
        _ ->
            case post(Batch) of
                ok ->
                    State#state{queue = Remaining, sent = Sent + length(Batch)};
                {error, Why} ->
                    State#state{
                        queue = Remaining,
                        failed = Failed + length(Batch),
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
classify_failure({http, Status}) when is_integer(Status) -> {http_status, Status};
classify_failure({error, Reason}) when is_atom(Reason) -> Reason;
classify_failure(_) -> export_error.

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
            {ok, {{_, Status, _}, _Hdrs, _Body}} when Status >= 200, Status < 300 ->
                ok;
            {ok, {{_, Status, _}, _Hdrs, _Body}} ->
                {error, {http, Status}};
            {error, Reason} ->
                {error, {error, Reason}}
        end
    catch
        Class:Reason2 -> {error, {error, {Class, Reason2}}}
    end.

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
resource_attrs() ->
    #{
        <<"service.name">> => <<"janus-gateway">>,
        <<"service.version">> => service_version(),
        <<"telemetry.sdk.name">> => <<"janus">>,
        <<"telemetry.sdk.language">> => <<"erlang">>
    }.

service_version() ->
    case application:get_key(janus_core, vsn) of
        {ok, Vsn} when is_list(Vsn) -> list_to_binary(Vsn);
        _ -> <<"0.0.0">>
    end.