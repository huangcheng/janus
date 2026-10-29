%%%-------------------------------------------------------------------
%%% @doc Data-plane usage events: buffered writes to `usage_events`.
%%%
%%% The proxy casts `record/1` on the request hot path; events are
%%% flushed every second or every 100 buffered rows, whichever comes
%%% first. A failed INSERT keeps its rows buffered and retries on a
%%% capped backoff — a DB blip delays usage instead of destroying it —
%%% and rows are abandoned (counted + logged at error) only after
%%% ?MAX_FLUSH_ATTEMPTS consecutive failures. Rows older than 31 days
%%% are swept daily in 5000-row batches (31 > 30 so a 30-day range never
%%% loses rows mid-window). Dropped events (cap overflow, malformed,
%%% abandoned inserts) are counted and logged — never silently lost.
%%% `stats/0` is surfaced through the admin /stats endpoint for the
%%% dashboard.
%%%
%%% Read-side rollups live in the standalone dashboard (management
%%% plane); the gateway only writes.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_usage).

-behaviour(gen_server).

-export([start_link/0]).
-export([record/1, stats/0, usage_attempt_rows/0, writable/1]).
-export([build_insert/2, chunk/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(FLUSH_MS, 1000).
-define(FLUSH_COUNT, 100).
-define(MAX_BUF, 10000).
-define(MAX_QUEUE, 8000).
-define(INSERT_CHUNK, 50).
%% Failed flushes keep their rows and retry with a capped backoff;
%% ?MAX_FLUSH_ATTEMPTS bounds the retry episode so one poison chunk
%% (schema mismatch, a value the DB always rejects) cannot pin the
%% buffer forever. ~8 minutes of DB outage at the capped 30s backoff.
-define(MAX_FLUSH_ATTEMPTS, 20).
-define(MAX_RETRY_BACKOFF_MS, 30000).
-define(RETENTION_SEC, 31 * 86400).
-define(SWEEP_MS, 24 * 3600 * 1000).
-define(SWEEP_BATCH, 5000).
-define(PROTOS, [openai_chat, openai_responses, anthropic_messages]).
%% TF-A.0b capability marker (reorder spec `2026-10-11` Hard
%% sequencing): the schema_migrations row whose `applied_at` is the
%% reorder loop's warm-up watermark (D36). DB-VISIBLE — no build tag.
-define(ATTEMPT_ROWS_VERSION, <<"018_usage_attempt_rows">>).
-define(PT_ATTEMPT_ROWS, {janus_usage, attempt_rows}).

-record(state, {
    buf = [] :: [map()],
    buf_size = 0 :: non_neg_integer(),
    dropped = 0 :: non_neg_integer(),
    %% Consecutive failed flush attempts and the monotonic time before
    %% which the retained rows must not be retried (0 = NO DEADLINE —
    %% a sentinel, never a timestamp: erlang:monotonic_time() is
    %% negative on Linux, so an absolute-0 comparison would never pass).
    flush_failures = 0 :: non_neg_integer(),
    retry_at_ms = 0 :: integer()
}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Event keys (all optional; see build_insert for defaults):
%% ts, agent_key_id, model_id, provider_id, provider_key_id,
%% protocol, stream, status, prompt, completion, latency_ms.
%% Events lacking an integer status are dropped. Never raises.
%% TF-A.0b writer-side pin (reorder spec `2026-10-11` terminal_count):
%% rows WITHOUT a provider_id are NEVER written — local pre-pick
%% rejects (no_route / wrong_modality / translate guards) stay
%% unwritten; one row shape, no query-side either/or. Deliberately NOT
%% counted under `dropped` (policy, not loss).
%% When the writer's mailbox is saturated the event is dropped HERE
%% (counted via an atomics counter created in init/1) — the mailbox is
%% the last unbounded resource, and this keeps it bounded.
-spec record(map()) -> ok.
record(#{status := Status, provider_id := Pid} = Ev) when
    is_integer(Status), is_integer(Pid)
->
    guarded_cast({record, Ev});
record(#{status := Status}) when is_integer(Status) ->
    %% TF-A.0b pin: a well-formed event WITHOUT provider_id is a local
    %% pre-pick reject — deliberately UNWRITTEN and deliberately NOT a
    %% drop (policy, not loss): no cast, no counter. Malformed events
    %% (no integer status) still count as drops below.
    ok;
record(Bad) ->
    guarded_cast({drop, Bad}).

%% TF-A.0b pure pin: an event is writable iff it carries an INTEGER
%% provider_id (every PROXIED attempt has one — the route map; rows
%% without it are local rejects that must never reach the ledger).
-spec writable(map()) -> boolean().
writable(#{provider_id := Pid}) when is_integer(Pid) ->
    true;
writable(_) ->
    false.

%% TF-A.0b capability surface (reorder spec Hard sequencing): TRUE once
%% migration 018_usage_attempt_rows is applied on THIS node's DB (the
%% ledger applied_at is the dashboard warm-up watermark, D36). Exposed
%% in /stats as `usage_attempt_rows` for the dashboard leader's
%% pre-write mirror. Result memoized once TRUE (a migration never
%% un-applies without a fresh DB; false results re-query — the check
%% runs on catalog generation bumps only, not the hot path). Tolerant:
%% DB unavailable => false (the reorder knob ingest guard refuses).
-spec usage_attempt_rows() -> boolean().
usage_attempt_rows() ->
    try
        case persistent_term:get(?PT_ATTEMPT_ROWS, false) of
            true ->
                true;
            false ->
                case migration_applied() of
                    true ->
                        persistent_term:put(?PT_ATTEMPT_ROWS, true),
                        true;
                    false ->
                        false
                end
        end
    catch
        _:_ -> false
    end.

migration_applied() ->
    Sql = <<"SELECT 1 FROM schema_migrations WHERE version = ?">>,
    try
        case janus_db_conn:query(Sql, [?ATTEMPT_ROWS_VERSION]) of
            {ok, [_ | _]} -> true;
            {ok, []} -> false;
            {error, _} -> false
        end
    catch
        _:_ -> false
    end.

%% {alive, buffered, dropped} — dropped is cumulative since boot
%% (gen_server drops + mailbox-saturated drops + writer-down drops).
-spec stats() -> map().
stats() ->
    Alive = whereis(?SERVER) =/= undefined,
    Base = #{alive => Alive, dropped => dropped_external()},
    try
        gen_server:call(?SERVER, stats, 1000) of
        M -> maps:merge(Base, M)
    catch
        _:_ -> Base#{buffered => 0}
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    %% Create the drop counter ONCE here (writer process); hot paths
    %% only read persistent_term, never put.
    persistent_term:put(janus_usage_drop_atomics, atomics:new(1, [{signed, false}])),
    _ = erlang:send_after(?FLUSH_MS, self(), flush),
    _ = erlang:send_after(60_000, self(), sweep),
    {ok, #state{}}.

handle_call(stats, _From, State) ->
    %% dropped must include INTERNAL losses (malformed events, buffer
    %% cap, failed inserts) — stats/0 merges this over its external
    %% (mailbox/writer-down) counter.
    {reply, #{
        buffered => State#state.buf_size,
        dropped => State#state.dropped + dropped_external()
    }, State};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

%% Cap overflow drops the INCOMING event (drop-newest, not drop-oldest):
%% the buffer drains in order and old rows are already on their way out.
%% The warning is throttled (first drop, then every 1000th) so a stalled
%% DB cannot flood the logs.
handle_cast({record, _Ev}, #state{buf_size = N} = State) when N >= ?MAX_BUF ->
    D = State#state.dropped + 1,
    case D rem 1000 of
        1 -> logger:warning(#{what => janus_usage_drop, reason => buffer_full, total => D});
        _ -> ok
    end,
    {noreply, State#state{dropped = D}};
handle_cast({record, Ev}, #state{buf = Buf, buf_size = N} = State) ->
    maybe_flush(State#state{buf = [Ev | Buf], buf_size = N + 1});
handle_cast({drop, _Bad}, State) ->
    D = State#state.dropped + 1,
    case D rem 1000 of
        1 -> logger:warning(#{what => janus_usage_drop, reason => malformed_event, total => D});
        _ -> ok
    end,
    {noreply, State#state{dropped = D}};
handle_cast(_Other, State) ->
    {noreply, State}.

handle_info(flush, State) ->
    _ = erlang:send_after(?FLUSH_MS, self(), flush),
    {noreply, do_flush(State)};
handle_info(sweep, State) ->
    %% Sweep in a worker so the DELETE never blocks casts; the worker
    %% must not die silently on a DB error. Instrumented via
    %% janus_task_run (failure-observability priority-2). must_complete:
    %% a large backlog may exceed the 5m expected wall — report timeout
    %% but do not abort mid-DELETE (idempotent batches).
    _ =
        erlang:spawn(fun() ->
            case janus_task_run:with(
                usage_sweep,
                #{must_complete => true},
                fun() -> sweep() end
            ) of
                {done, ok} ->
                    ok;
                {done, {error, Reason}} ->
                    logger:warning(#{
                        what => janus_usage_sweep_error, reason => Reason
                    });
                {crash, Reason} ->
                    logger:warning(#{
                        what => janus_usage_sweep_crashed, reason => Reason
                    });
                timeout ->
                    logger:warning(#{what => janus_usage_sweep_timeout})
            end
        end),
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    %% Shutdown has one last chance: force a flush even if a retry
    %% backoff is pending. Anything still buffered after it is lost with
    %% this process — say so at error level (the running path retries).
    Flushed = do_flush_now(State),
    case Flushed#state.buf_size of
        0 ->
            ok;
        N ->
            logger:error(#{what => janus_usage_shutdown_flush_incomplete, rows => N})
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal — writes
%%%===================================================================

guarded_cast(Msg) ->
    try
        case whereis(?SERVER) of
            undefined ->
                %% Writer down (restarting): count the loss — the
                %% "never silently lost" contract applies here too.
                atomics:add(drop_counter(), 1, 1),
                ok;
            Pid ->
                {message_queue_len, Q} = erlang:process_info(Pid, message_queue_len),
                case Q >= ?MAX_QUEUE of
                    true ->
                        D = atomics:add_get(drop_counter(), 1, 1),
                        case D rem 1000 of
                            1 ->
                                logger:warning(#{
                                    what => janus_usage_drop, reason => mailbox_full, total => D
                                });
                            _ ->
                                ok
                        end;
                    false ->
                        gen_server:cast(?SERVER, Msg)
                end
        end,
        ok
    catch
        _:_ -> ok
    end.

%% The atomics ref is created once by init/1 (writer process) — this
%% accessor only READS persistent_term (no put from hot paths, no race).
drop_counter() ->
    persistent_term:get(janus_usage_drop_atomics).

dropped_external() ->
    try
        atomics:get(persistent_term:get(janus_usage_drop_atomics), 1)
    catch
        _:_ -> 0
    end.

maybe_flush(#state{buf_size = N} = State) when N >= ?FLUSH_COUNT ->
    {noreply, do_flush(State)};
maybe_flush(State) ->
    {noreply, State}.

%% Retry gate: while a previous flush is in backoff, a new event (or the
%% 1s tick) must not hammer the failing DB. The retained rows and the
%% new ones they precede are flushed together when the deadline passes.
%% retry_at_ms = 0 is the NO-DEADLINE sentinel, NOT a timestamp:
%% erlang:monotonic_time() is negative on Linux (its epoch is decades
%% in the future), so `now >= 0` is false and the gate would stay shut
%% forever — the 2026-10-23 prod incident where usage rows only ever
%% appeared in restart-time terminate/2 bursts.
do_flush(#state{buf = []} = State) ->
    State;
do_flush(#state{retry_at_ms = 0} = State) ->
    do_flush_now(State);
do_flush(#state{retry_at_ms = At} = State) ->
    case erlang:monotonic_time(millisecond) >= At of
        true -> do_flush_now(State);
        false -> State
    end.

do_flush_now(#state{buf = []} = State) ->
    State;
do_flush_now(#state{buf = Buf} = State) ->
    Cols =
        <<"(ts, agent_key_id, model_id, provider_id, provider_key_id, "
          " protocol, stream, status, prompt_tokens, completion_tokens, latency_ms, "
          " error_code, attempt, request_ref, is_terminal, request_id, "
          " modality, units, outcome, cache_read_input_tokens, "
          " failover_reason, trace_id, requested_model, error_detail)">>,
    %% Successful chunks are written and gone; failed chunks are KEPT
    %% (oldest-first) for the next attempt. Only the FK salvage path
    %% ("ok") retires a failed chunk, and it does so by writing the rows.
    {FailedChunksRev, FailedChunkCount, FirstReason} =
        lists:foldl(
            fun(Rows, {Acc, Chunks, Reason0}) ->
                {Sql, Params} = build_insert(Cols, Rows),
                case q(Sql, Params) of
                    {ok, _} ->
                        {Acc, Chunks, Reason0};
                    {error, Reason} ->
                        case fk_salvage(Cols, Rows, Reason) of
                            ok ->
                                logger:warning(#{
                                    what => janus_usage_flush_fk_salvaged, rows => length(Rows)
                                }),
                                {Acc, Chunks, Reason0};
                            keep ->
                                {[Rows | Acc], Chunks + 1, first_reason(Reason0, Reason)}
                        end
                end
            end,
            {[], 0, undefined},
            chunk(lists:reverse(Buf), ?INSERT_CHUNK)
        ),
    Retained = lists:append(lists:reverse(FailedChunksRev)),
    case Retained of
        [] ->
            State#state{buf = [], buf_size = 0, flush_failures = 0, retry_at_ms = 0};
        _ ->
            Attempts = State#state.flush_failures + 1,
            Now = erlang:monotonic_time(millisecond),
            logger:warning(#{
                what => janus_usage_flush_error,
                retrying => true,
                rows => length(Retained),
                chunks => FailedChunkCount,
                attempt => Attempts,
                max_attempts => ?MAX_FLUSH_ATTEMPTS,
                reason => FirstReason
            }),
            case Attempts >= ?MAX_FLUSH_ATTEMPTS of
                true ->
                    %% Retry episode exhausted: one poison chunk must not
                    %% pin the buffer forever. Loud, counted, and bounded.
                    logger:error(#{
                        what => janus_usage_flush_abandoned,
                        rows => length(Retained),
                        chunks => FailedChunkCount,
                        attempts => Attempts,
                        reason => FirstReason
                    }),
                    State#state{
                        buf = [],
                        buf_size = 0,
                        dropped = State#state.dropped + length(Retained),
                        flush_failures = 0,
                        retry_at_ms = 0
                    };
                false ->
                    State#state{
                        %% buf is newest-first; Retained was collected
                        %% oldest-first.
                        buf = lists:reverse(Retained),
                        buf_size = length(Retained),
                        flush_failures = Attempts,
                        retry_at_ms = Now + retry_backoff_ms(Attempts)
                    }
            end
    end.

first_reason(undefined, Reason) -> Reason;
first_reason(Reason, _Later) -> Reason.

%% Capped exponential backoff between retries (1s, 2s, 4s, 8s, 16s,
%% 30s, 30s, ...): a sustained outage is retried at a steady low rate
%% instead of once per tick.
retry_backoff_ms(Attempts) when Attempts >= 1 ->
    min(?FLUSH_MS bsl min(Attempts - 1, 5), ?MAX_RETRY_BACKOFF_MS).

%% FK-race salvage: a key/model/provider row can be deleted between
%% record/1 and the flush (the dashboard revokes a key while its events
%% are still buffered), failing the whole chunk with 23503. Retry once
%% with the id columns NULLed — attribution is lost for those rows, the
%% events are not.
fk_salvage(Cols, Rows, Reason) ->
    Bin = iolist_to_binary(io_lib:format("~0p", [Reason])),
    IsFk =
        binary:match(Bin, <<"23503">>) =/= nomatch orelse
            binary:match(Bin, <<"foreign_key">>) =/= nomatch,
    case IsFk of
        false ->
            keep;
        true ->
            Stripped = [maps:with(fk_keep_keys(), Ev) || Ev <- Rows],
            {Sql, Params} = build_insert(Cols, Stripped),
            case q(Sql, Params) of
                {ok, _} -> ok;
                _ -> keep
            end
    end.

%% The salvage keep-list is the FULL semantic column set (event-map key
%% names): only the FK id columns (agent_key_id/model_id/provider_id/
%% provider_key_id) are stripped. Stripping to fewer keys would default
%% attempt->1/is_terminal->true on a salvaged non-terminal row (a
%% double-count trap) and silently drop the 010/012/021 fields.
fk_keep_keys() ->
    [
        ts, protocol, stream, status, prompt, completion, latency_ms,
        error_code, attempt, request_ref, is_terminal, request_id,
        failover_reason, trace_id, modality, units, outcome,
        cache_read_input_tokens, requested_model, error_detail
    ].

chunk(L, N) ->
    chunk(L, N, []).

chunk([], _N, Acc) ->
    lists:reverse(Acc);
chunk(L, N, Acc) ->
    {H, T} = safe_split(N, L),
    chunk(T, N, [H | Acc]).

safe_split(N, L) ->
    safe_split(N, L, []).

safe_split(0, Rest, Acc) ->
    {lists:reverse(Acc), Rest};
safe_split(_, [], Acc) ->
    {lists:reverse(Acc), []};
safe_split(N, [H | T], Acc) ->
    safe_split(N - 1, T, [H | Acc]).

build_insert(Cols, Rows) ->
    {ValuesSql, Params} =
        lists:foldl(
            fun(Ev, {SqlAcc, PAcc}) ->
                Ph = string:join(lists:duplicate(24, "?"), ", "),
                Params = [
                    maps:get(ts, Ev, erlang:system_time(second)),
                    int_or_null(maps:get(agent_key_id, Ev, null)),
                    int_or_null(maps:get(model_id, Ev, null)),
                    int_or_null(maps:get(provider_id, Ev, null)),
                    int_or_null(maps:get(provider_key_id, Ev, null)),
                    proto_bin(maps:get(protocol, Ev, openai_chat)),
                    bool_int(maps:get(stream, Ev, false)),
                    maps:get(status, Ev),
                    int_or_null(maps:get(prompt, Ev, null)),
                    int_or_null(maps:get(completion, Ev, null)),
                    int_or_null(maps:get(latency_ms, Ev, null)),
                    err_code_bin(maps:get(error_code, Ev, null)),
                    int_or_null(maps:get(attempt, Ev, 1)),
                    ref_bin(maps:get(request_ref, Ev, null)),
                    bool_val(maps:get(is_terminal, Ev, true)),
                    bin_or_null(maps:get(request_id, Ev, null)),
                    modality_bin(maps:get(modality, Ev, <<"chat">>)),
                    num_or_null(maps:get(units, Ev, null)),
                    outcome_bin(maps:get(outcome, Ev, null)),
                    int_or_null(maps:get(cache_read_input_tokens, Ev, null)),
                    bin_or_null(maps:get(failover_reason, Ev, null)),
                    bin_or_null(maps:get(trace_id, Ev, null)),
                    bin_or_null(maps:get(requested_model, Ev, null)),
                    err_detail_bin(maps:get(error_detail, Ev, null))
                ],
                {SqlAcc ++ ["(" ++ Ph ++ ")"], PAcc ++ Params}
            end,
            {[], []},
            Rows
        ),
    Sql = iolist_to_binary([
        "INSERT INTO usage_events ", Cols, " VALUES ", string:join(ValuesSql, ", ")
    ]),
    {Sql, Params}.

int_or_null(N) when is_integer(N) -> N;
int_or_null(_) -> null.

bin_or_null(B) when is_binary(B) -> B;
bin_or_null(_) -> null.

%% is_terminal is a REAL BOOLEAN on postgres (epgsql bool codec
%% rejects 0/1); the sqlite path normalizes to 1/0 in q/2 below.
bool_val(true) -> true;
bool_val(1) -> true;
bool_val(_) -> false.

err_code_bin(B) when is_binary(B) ->
    binary:part(B, 0, min(byte_size(B), 120));
err_code_bin(_) ->
    null.

ref_bin(B) when is_binary(B), byte_size(B) =< 64 -> B;
ref_bin(_) ->
    null.

proto_bin(P) when is_atom(P) ->
    case lists:member(P, ?PROTOS) of
        true -> atom_to_binary(P, utf8);
        false -> <<"openai_chat">>
    end;
proto_bin(P) when is_binary(P) ->
    case
        lists:member(P, [<<"openai_chat">>, <<"openai_responses">>, <<"anthropic_messages">>])
    of
        true -> P;
        false -> <<"openai_chat">>
    end;
proto_bin(_) ->
    <<"openai_chat">>.

bool_int(true) -> 1;
bool_int(1) -> 1;
bool_int(_) -> 0.

%% @doc Returns `ok` or `{error, Reason}` so janus_task_run can class the
%% outcome (OCR Medium: never report ok when the DELETE path failed).
sweep() ->
    Cutoff = erlang:system_time(second) - ?RETENTION_SEC,
    sweep_batch(Cutoff, 0).

%% janus_db_conn:query returns {ok, Rows}, not affected counts, so loop
%% on COUNT(*) — stop when nothing old remains. Log if the 100-batch
%% ceiling is hit (rows older than retention remain; visible, not silent).
sweep_batch(_Cutoff, 100) ->
    logger:warning(#{what => janus_usage_sweep_capped, batches => 100}),
    {error, capped};
sweep_batch(Cutoff, Iter) ->
    case q(<<"SELECT COUNT(*) FROM usage_events WHERE ts < ?">>, [Cutoff]) of
        {ok, [{0}]} ->
            ok;
        {ok, [{_}]} ->
            case q(
                <<"DELETE FROM usage_events WHERE id IN "
                  "(SELECT id FROM usage_events WHERE ts < ? LIMIT 5000)">>,
                [Cutoff]
            ) of
                {ok, _} ->
                    sweep_batch(Cutoff, Iter + 1);
                {error, Reason} ->
                    logger:warning(#{what => janus_usage_sweep_error, reason => Reason}),
                    {error, Reason}
            end;
        {error, Reason} ->
            logger:warning(#{what => janus_usage_sweep_error, reason => Reason}),
            {error, Reason}
    end.

q(Sql, Params) ->
    try
        case janus_db_conn:backend() of
            postgres -> janus_db_conn:query(rewrite_pg(Sql), Params);
            _ -> janus_db_conn:query(Sql, sqlite_bools(Params))
        end
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%% SQLite stores booleans as 1/0 (esqlite has no bool binding);
%% postgres gets real booleans (epgsql bool codec rejects 0/1).
sqlite_bools(Params) when is_list(Params) ->
    [sqlite_bool(P) || P <- Params];
sqlite_bools(P) ->
    P.

sqlite_bool(true) -> 1;
sqlite_bool(false) -> 0;
sqlite_bool(P) -> P.

rewrite_pg(Sql) ->
    rewrite_pg(Sql, 1).

rewrite_pg(<<"?", Rest/binary>>, N) ->
    <<"$", (integer_to_binary(N))/binary, (rewrite_pg(Rest, N + 1))/binary>>;
rewrite_pg(<<C, Rest/binary>>, N) ->
    <<C, (rewrite_pg(Rest, N))/binary>>;
rewrite_pg(<<>>, _N) ->
    <<>>.

%%%===================================================================
%%% Tests (write-path helpers; read rollups live in the dashboard)
%%%===================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

build_insert_shape_test() ->
    {Sql, Params} = janus_usage:build_insert(
        <<"(a, b)">>,
        [
            #{status => 200, prompt => 1, stream => true},
            #{
                status => 502,
                failover_reason => <<"auth">>,
                trace_id => <<"4bf92f3577b34da6a3ce929d0e0e4736">>
            }
        ]
    ),
    %% 24 placeholders per row (16 legacy + error_code/attempt/
    %% request_ref/is_terminal/request_id + modality/units/outcome/
    %% cache_read_input_tokens + failover_reason/trace_id +
    %% requested_model + error_detail), one VALUES group per row.
    ?assertEqual(48, length(Params)),
    Row24 = lists:duplicate(24, "?"),
    ?assertMatch(
        {ok, _},
        begin
            Want = iolist_to_binary([
                <<"INSERT INTO usage_events (a, b) VALUES (">>,
                string:join(Row24, ", "), <<"), (">>,
                string:join(Row24, ", "), <<")">>
            ]),
            case Sql of
                Want -> {ok, matched};
                _ -> {error, Sql}
            end
        end
    ),
    %% row 2: status 502 present, prompt defaults to null (not 0);
    %% attempt defaults to 1, is_terminal to true, request_id to null;
    %% modality defaults to chat, units and outcome to null;
    %% failover_reason/trace_id ride through as binaries.
    ?assertEqual(502, lists:nth(31, Params)),
    ?assertEqual(null, lists:nth(32, Params)),
    ?assertEqual(1, lists:nth(36, Params)),
    ?assertEqual(true, lists:nth(38, Params)),
    ?assertEqual(null, lists:nth(39, Params)),
    ?assertEqual(<<"chat">>, lists:nth(40, Params)),
    ?assertEqual(null, lists:nth(41, Params)),
    ?assertEqual(null, lists:nth(42, Params)),
    ?assertEqual(null, lists:nth(43, Params)),
    ?assertEqual(<<"auth">>, lists:nth(44, Params)),
    ?assertEqual(<<"4bf92f3577b34da6a3ce929d0e0e4736">>, lists:nth(45, Params)),
    %% requested_model defaults to null; error_detail rides last and
    %% defaults to null.
    ?assertEqual(null, lists:nth(47, Params)),
    ?assertEqual(null, lists:nth(48, Params)).

%% FK-race salvage keeps the FULL semantic column set (only the FK id
%% columns are stripped) — a salvaged non-terminal row must not flip
%% terminal via defaults, and the 010/012/021 fields must survive.
%% Set equality (order is irrelevant to maps:with), so a future column
%% addition fails this test until the keep-list is revisited.
fk_salvage_keep_list_test() ->
    Want = lists:sort([
        ts, protocol, stream, status, prompt, completion, latency_ms,
        error_code, attempt, request_ref, is_terminal, request_id,
        failover_reason, trace_id, modality, units, outcome,
        cache_read_input_tokens, requested_model, error_detail
    ]),
    ?assertEqual(Want, lists:sort(fk_keep_keys())).

chunk_test() ->
    ?assertEqual([[1, 2], [3]], janus_usage:chunk([1, 2, 3], 2)),
    ?assertEqual([], janus_usage:chunk([], 3)),
    ?assertEqual([[1]], janus_usage:chunk([1], 3)).

-endif.

%% error_detail: keep the upstream's own sentence, clamp at 512 bytes
%% (cut on a byte boundary; usage rows are bulk-written, the Failures
%% page needs a headline, not the body).
err_detail_bin(B) when is_binary(B), byte_size(B) > 512 ->
    binary:part(B, 0, 512);
err_detail_bin(B) when is_binary(B) -> B;
err_detail_bin(_) -> null.

%% Modality tag from the event; anything unexpected reads as chat.
modality_bin(M) when is_binary(M) -> M;
modality_bin(_) -> <<"chat">>.

%% units is NUMERIC — integers or floats pass, everything else NULL.
num_or_null(N) when is_integer(N) -> N;
num_or_null(N) when is_float(N) -> N;
num_or_null(_) -> null.

%% Terminal outcome tag (completed/failed/cancelled/truncated); NULL
%% for chat rows and non-terminal attempts. The wire-enc inflate-fail
%% abort (spec 2026-10-12-wire-compression F2) carries its own tag so
%% ops can distinguish corruption from node loss in usage_events.
outcome_bin(<<"completed">>) -> <<"completed">>;
outcome_bin(<<"failed">>) -> <<"failed">>;
outcome_bin(<<"cancelled">>) -> <<"cancelled">>;
outcome_bin(<<"truncated">>) -> <<"truncated">>;
outcome_bin(<<"wire_enc_inflate_fail">>) -> <<"wire_enc_inflate_fail">>;
%% Worker-relay terminal aborts (security-audit run-1): distinguish
%% them from node loss in usage_events the same way.
outcome_bin(<<"translate_abort">>) -> <<"translate_abort">>;
outcome_bin(<<"stream_relay_crash">>) -> <<"stream_relay_crash">>;
outcome_bin(_) -> null.
