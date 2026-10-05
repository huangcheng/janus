%%%-------------------------------------------------------------------
%%% @doc Data-plane usage events: buffered writes to `usage_events`.
%%%
%%% The proxy casts `record/1` on the request hot path; events are
%%% flushed every second or every 100 buffered rows, whichever comes
%%% first. Rows older than 31 days are swept daily in 5000-row batches
%%% (31 > 30 so a 30-day range never loses rows mid-window). Dropped
%%% events (cap overflow, malformed, insert failure) are counted and
%%% logged — never silently lost. `stats/0` is surfaced through the
%%% admin /stats endpoint for the dashboard.
%%%
%%% Read-side rollups live in the standalone dashboard (management
%%% plane); the gateway only writes.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_usage).

-behaviour(gen_server).

-export([start_link/0]).
-export([record/1, stats/0]).
-export([build_insert/2, chunk/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(FLUSH_MS, 1000).
-define(FLUSH_COUNT, 100).
-define(MAX_BUF, 10000).
-define(MAX_QUEUE, 8000).
-define(INSERT_CHUNK, 50).
-define(RETENTION_SEC, 31 * 86400).
-define(SWEEP_MS, 24 * 3600 * 1000).
-define(SWEEP_BATCH, 5000).
-define(PROTOS, [openai_chat, openai_responses, anthropic_messages]).

-record(state, {
    buf = [] :: [map()],
    buf_size = 0 :: non_neg_integer(),
    dropped = 0 :: non_neg_integer()
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
%% When the writer's mailbox is saturated the event is dropped HERE
%% (counted via an atomics counter created in init/1) — the mailbox is
%% the last unbounded resource, and this keeps it bounded.
-spec record(map()) -> ok.
record(#{status := Status} = Ev) when is_integer(Status) ->
    guarded_cast({record, Ev});
record(Bad) ->
    guarded_cast({drop, Bad}).

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
    %% must not die silently on a DB error.
    _ =
        erlang:spawn(fun() ->
            try
                sweep()
            catch
                Class:Reason ->
                    logger:warning(#{
                        what => janus_usage_sweep_crashed, class => Class, reason => Reason
                    })
            end
        end),
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = do_flush(State),
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

do_flush(#state{buf = []} = State) ->
    State;
do_flush(#state{buf = Buf} = State) ->
    Cols =
        <<"(ts, agent_key_id, model_id, provider_id, provider_key_id, "
          " protocol, stream, status, prompt_tokens, completion_tokens, latency_ms)">>,
    Failed =
        lists:foldl(
            fun(Rows, Acc) ->
                {Sql, Params} = build_insert(Cols, Rows),
                case q(Sql, Params) of
                    {ok, _} ->
                        Acc;
                    {error, Reason} ->
                        case fk_salvage(Cols, Rows, Reason) of
                            ok ->
                                logger:warning(#{
                                    what => janus_usage_flush_fk_salvaged, rows => length(Rows)
                                }),
                                Acc;
                            keep ->
                                logger:warning(#{
                                    what => janus_usage_flush_error,
                                    rows => length(Rows),
                                    reason => Reason
                                }),
                                Acc + length(Rows)
                        end
                end
            end,
            0,
            chunk(lists:reverse(Buf), ?INSERT_CHUNK)
        ),
    State#state{buf = [], buf_size = 0, dropped = State#state.dropped + Failed}.

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
            KeepKeys = [ts, protocol, stream, status, prompt, completion, latency_ms],
            Stripped = [maps:with(KeepKeys, Ev) || Ev <- Rows],
            {Sql, Params} = build_insert(Cols, Stripped),
            case q(Sql, Params) of
                {ok, _} -> ok;
                _ -> keep
            end
    end.

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
                Ph = string:join(lists:duplicate(11, "?"), ", "),
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
                    int_or_null(maps:get(latency_ms, Ev, null))
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

sweep() ->
    Cutoff = erlang:system_time(second) - ?RETENTION_SEC,
    sweep_batch(Cutoff, 0).

%% janus_db_conn:query returns {ok, Rows}, not affected counts, so loop
%% on COUNT(*) — stop when nothing old remains. Log if the 100-batch
%% ceiling is hit (rows older than retention remain; visible, not silent).
sweep_batch(_Cutoff, 100) ->
    logger:warning(#{what => janus_usage_sweep_capped, batches => 100}),
    ok;
sweep_batch(Cutoff, Iter) ->
    case q(<<"SELECT COUNT(*) FROM usage_events WHERE ts < ?">>, [Cutoff]) of
        {ok, [{0}]} ->
            ok;
        {ok, [{_}]} ->
            _ = q(
                <<"DELETE FROM usage_events WHERE id IN "
                  "(SELECT id FROM usage_events WHERE ts < ? LIMIT 5000)">>,
                [Cutoff]
            ),
            sweep_batch(Cutoff, Iter + 1);
        {error, Reason} ->
            logger:warning(#{what => janus_usage_sweep_error, reason => Reason}),
            ok
    end.

q(Sql, Params) ->
    try
        case janus_db_conn:backend() of
            postgres -> janus_db_conn:query(rewrite_pg(Sql), Params);
            _ -> janus_db_conn:query(Sql, Params)
        end
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

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
        [#{status => 200, prompt => 1, stream => true}, #{status => 502}]
    ),
    %% 11 placeholders per row, one VALUES group per row.
    ?assertEqual(22, length(Params)),
    ?assertMatch(
        <<"INSERT INTO usage_events (a, b) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)">>,
        Sql
    ),
    %% row 2: status 502 present, prompt defaults to null (not 0).
    ?assertEqual(502, lists:nth(19, Params)),
    ?assertEqual(null, lists:nth(20, Params)).

chunk_test() ->
    ?assertEqual([[1, 2], [3]], janus_usage:chunk([1, 2, 3], 2)),
    ?assertEqual([], janus_usage:chunk([], 3)),
    ?assertEqual([[1]], janus_usage:chunk([1], 3)).

-endif.
