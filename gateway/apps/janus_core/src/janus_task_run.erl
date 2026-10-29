%%%-------------------------------------------------------------------
%%% @doc Background-task runner + registry for the dashboard's failure
%%% observability (spec 2026-10-13-failure-observability-design.md §4.3,
%%% §4.1 `tasks[]`).
%%%
%%% `with/3` runs a task body under a per-run MONITOR process that
%%% pushes `task_run` start/end events into `janus_ops_tail`. The
%%% gen_server half of this module owns two things that must be
%%% gateway-global rather than per-run:
%%%
%%%   * the TERMINAL-ONCE guard: after the first terminal emission for a
%%%     `run_id` every further event for that id is suppressed (a
%%%     timeout cancel followed by the worker's DOWN, a must-complete
%%%     body finishing after its deadline, a caller death racing a
%%%     normal finish ...). The decision is taken inside one serialized
%%%     `gen_server:call`, so concurrent emitters cannot both win.
%%%   * the "last run" snapshot table behind `/stats/health` `tasks[]`.
%%%
%%% Outcomes: normal return → `ok` (or `error` when the body returned
%%% `{error, _}` / the optional `classify` hook says so); unexpected
%%% worker exit → `crash`; wall overrun → `timeout` (worker cancelled,
%%% its DOWN swallowed); caller died mid-run → `crash` with
%%% `error_class = orphan`.
%%%
%%% Failure modes guarded (and the invariants):
%%%   1. Exactly ONE terminal event per run_id, whatever the race.
%%%   2. The caller's mailbox only ever receives the monitor's single
%%%      reply: the worker's DOWN / late result stay inside the monitor
%%%      (a gen_server caller would crash on a stray 'DOWN').
%%%   3. The observability path never breaks the task: server or ring
%%%      absent (worker node, boot order) → the body still runs and
%%%      returns; every emission is wrapped.
%%%   4. Bounded memory: terminal bookkeeping is a FIFO of
%%%      `terminal_cap/0` run_ids; the last-run table is one row per task
%%%      name.
%%%   5. No secrets in the ring: error text is rendered, scrubbed
%%%      (Bearer / sk- / gsk- / AIza / api key / PEM) and truncated.
%%%   6. Registry drift: `validate_registry/0` (checked at server init and
%%%      by eunit) plus the eunit "covers supervised periodic jobs" list.
%%%
%%% Must-complete tasks (`#{must_complete => true}`, e.g. model sync):
%%% aborting them mid-pass is unsafe (half-applied inventory writes), so
%%% on deadline overrun the monitor emits `timeout` ONCE and lets the
%%% body run to completion (its real result is still returned to the
%%% caller; its later end is suppressed). This is the §4.3 residual
%%% ("wall overrun → cancel") deliberately narrowed to "report, don't
%%% kill" for tasks that opt in. If the caller dies, the body is left
%%% running for the same reason.
%%%
%%% Snapshot semantics (`snapshot/0`): `last_*` describe the most recent
%%% run. When a run starts, the previous outcome fields reset to `null`
%%% and `running` flips true (`last_ok_ts` survives so "no success
%%% since" stays computable); `running` is "no terminal yet" — it also
%%% turns false at a must-complete `timeout` terminal. Dashboard
%%% history lives in its own task_runs table fed from the ring.
%%%
%%% Registry: every periodic MASTER job the gateway supervises has a row
%%% (`instrumented=false` until wired). `node_scope=master` in v1.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_task_run).

-behaviour(gen_server).

-export([start_link/0]).
-export([
    with/3,
    registry/0,
    validate_registry/0,
    validate_registry/1,
    snapshot/0,
    deadline_ms/2,
    new_run_id/0,
    scrub/1,
    format_error/1,
    note_terminal/3,
    terminal_cap/0,
    terminal_seen_count/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(LAST_TAB, janus_task_run_last).
-define(TERMINAL_CAP, 1024).
-define(DEFAULT_GRACE_MS, 60_000).
-define(UNREGISTERED_EXPECTED_MS, 60_000).
-define(ERROR_TEXT_PRE_CAP, 16_384).
-define(ERROR_TEXT_CAP, 1024).
-define(CALL_TIMEOUT, 2_000).
-define(REDACTED, <<"[REDACTED]">>).

-record(state, {
    seen = #{} :: #{binary() => true},
    order = queue:new() :: queue:queue(binary())
}).

%% Monitor-process loop state (one per run).
-record(m, {
    tag :: reference(),
    caller :: pid(),
    caller_mon :: reference(),
    name :: atom(),
    run_id :: binary(),
    t0 :: integer(),
    expected_ms :: pos_integer(),
    schedule_ms :: non_neg_integer(),
    deadline_ms :: pos_integer(),
    must_complete :: boolean(),
    meta :: map(),
    worker :: pid(),
    worker_mon :: reference() | undefined,
    timer :: reference() | undefined,
    done = false :: boolean()
}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Run `Fun` as task `Name`. Blocks the caller until the body
%% finishes (or is cancelled on overrun).
%%
%% Meta (all optional): `deadline_ms` (absolute override), `grace_ms`
%% (on-demand grace, default 60s), `on_demand` (force grace on a
%% periodic task — a manual trigger), `must_complete` (never kill the
%% body), `expected_duration_ms` (override the registry row),
%% `classify` (`fun(Result) -> ok | {error, Reason} | {error, Class,
%% Reason}`) to turn a returned value into an `error` outcome.
%%
%% Returns `{done, Value}` (body returned), `{crash, Reason}` (body
%% exited abnormally) or `timeout` (cancelled on overrun; never returned
%% for `must_complete`).
-spec with(atom(), map(), fun(() -> term())) -> {done, term()} | {crash, term()} | timeout.
with(Name, Meta, Fun) when is_atom(Name), is_map(Meta), is_function(Fun, 0) ->
    Tag = make_ref(),
    Caller = self(),
    {Mon, MRef} = spawn_monitor(fun() -> monitor_main(Tag, Caller, Name, Meta, Fun) end),
    receive
        {Tag, Result} ->
            erlang:demonitor(MRef, [flush]),
            Result;
        {'DOWN', MRef, process, Mon, Reason} ->
            %% The monitor itself died (bug): never hang the caller.
            {crash, {task_monitor_down, Reason}}
    end.

%% @doc The task registry (spec §4.3). `schedule_interval_ms` is an
%% integer (0 = on-demand) or a zero-arity resolver for live-tunable
%% periods (model sync interval).
-spec registry() -> [map()].
registry() ->
    [
        row(config_poll, 5_000, 2_000, false),
        row(cool_sweep, 500, 1_000, false),
        row(usage_flush, 5_000, 1_000, false),
        row(usage_sweep, 300_000, 86_400_000, true),
        row(model_sync, 120_000, fun model_sync_interval_ms/0, true),
        row(worker_pool_tick, 5_000, 30_000, false),
        row(worker_pool_flush, 1_000, 250, false),
        %% Legacy signal-fleet loops (listed so the boot assertion holds;
        %% they only tick when JANUS_FLEET_ENABLED).
        row(fleet_sweep, 10_000, 30_000, false),
        row(fleet_lease_tick, 2_000, 5_000, false),
        row(fleet_quota_tick, 1_000, 2_000, false)
    ].

row(Name, ExpectedMs, Schedule, Instrumented) ->
    #{
        name => Name,
        expected_duration_ms => ExpectedMs,
        schedule_interval_ms => Schedule,
        instrumented => Instrumented,
        node_scope => master
    }.

model_sync_interval_ms() ->
    janus_model_sync:interval() * 1000.

-spec validate_registry() -> ok | {error, [term()]}.
validate_registry() ->
    validate_registry(registry()).

-spec validate_registry([map()]) -> ok | {error, [term()]}.
validate_registry(Rows) when is_list(Rows) ->
    Names = [maps:get(name, R, undefined) || R <- Rows, is_map(R)],
    Dups = Names -- lists:usort(Names),
    Problems =
        [{duplicate_name, N} || N <- lists:usort(Dups)] ++
            lists:append([row_problems(R) || R <- Rows]),
    case Problems of
        [] -> ok;
        _ -> {error, Problems}
    end.

row_problems(R) when is_map(R) ->
    Name = maps:get(name, R, undefined),
    Checks = [
        {name, is_atom(Name) andalso Name =/= undefined},
        {expected_duration_ms, is_pos_int(maps:get(expected_duration_ms, R, undefined))},
        {schedule_interval_ms, valid_schedule(maps:get(schedule_interval_ms, R, undefined))},
        {instrumented, is_boolean(maps:get(instrumented, R, undefined))},
        {node_scope, maps:get(node_scope, R, undefined) =:= master}
    ],
    [{bad_field, Name, Field} || {Field, false} <- Checks];
row_problems(Other) ->
    [{bad_row, Other}].

is_pos_int(N) -> is_integer(N) andalso N > 0.

valid_schedule(N) when is_integer(N), N >= 0 -> true;
valid_schedule(F) when is_function(F, 0) -> true;
valid_schedule(_) -> false.

%% @doc `/stats/health` `tasks[]`: one entry per registry row, in
%% registry order, merged with the last-run row. Never raises; with the
%% server down every `last_*` is null.
-spec snapshot() -> [map()].
snapshot() ->
    [snapshot_row(R) || R <- registry()].

snapshot_row(#{name := Name} = R) ->
    Last = lookup_last(Name),
    #{
        name => Name,
        instrumented => maps:get(instrumented, R),
        node_scope => <<"master">>,
        expected_duration_ms => maps:get(expected_duration_ms, R),
        schedule_interval_ms => resolve_schedule(R),
        running => maps:get(running, Last, false),
        last_run_id => maps:get(run_id, Last, null),
        last_started_ts => ts_json(maps:get(started_ms, Last, null)),
        last_finished_ts => ts_json(maps:get(finished_ms, Last, null)),
        last_ok_ts => ts_json(maps:get(ok_ms, Last, null)),
        last_outcome => maps:get(outcome, Last, null),
        last_error_class => maps:get(error_class, Last, null),
        last_error => maps:get(error, Last, null),
        last_duration_ms => maps:get(duration_ms, Last, null)
    }.

lookup_last(Name) ->
    try ets:lookup(?LAST_TAB, Name) of
        [{Name, Last}] -> Last;
        [] -> #{}
    catch
        error:badarg -> #{}
    end.

ts_json(null) ->
    null;
ts_json(Ms) when is_integer(Ms) ->
    list_to_binary(calendar:system_time_to_rfc3339(Ms, [{unit, millisecond}, {offset, "Z"}])).

%% @doc Wall deadline for a run: `deadline_ms` override, else the
%% expected duration (Meta may override it), plus grace for on-demand
%% runs (schedule 0 or `on_demand => true`).
-spec deadline_ms(map(), map()) -> pos_integer().
deadline_ms(Row, Meta) ->
    case maps:get(deadline_ms, Meta, undefined) of
        D when is_integer(D), D > 0 ->
            D;
        _ ->
            Expected = expected_ms(Row, Meta),
            Grace =
                case maps:get(grace_ms, Meta, ?DEFAULT_GRACE_MS) of
                    G when is_integer(G), G >= 0 -> G;
                    _ -> ?DEFAULT_GRACE_MS
                end,
            case maps:get(on_demand, Meta, false) =:= true orelse resolve_schedule(Row) =:= 0 of
                true -> Expected + Grace;
                false -> Expected
            end
    end.

expected_ms(Row, Meta) ->
    case maps:get(expected_duration_ms, Meta, undefined) of
        E when is_integer(E), E > 0 -> E;
        _ -> maps:get(expected_duration_ms, Row)
    end.

%% Resolver crash/garbage => 0 would wrongly flip the task to
%% "on-demand"; fall back to a large periodic value instead.
resolve_schedule(Row) ->
    case maps:get(schedule_interval_ms, Row, 0) of
        N when is_integer(N), N >= 0 ->
            N;
        F when is_function(F, 0) ->
            try F() of
                N when is_integer(N), N >= 0 -> N;
                _ -> 21_600_000
            catch
                _:_ -> 21_600_000
            end;
        _ ->
            0
    end.

%% @doc RFC 4122 v4 UUID, lowercase hex.
-spec new_run_id() -> binary().
new_run_id() ->
    <<A:32, B:16, C0:16, D0:16, E:48>> = crypto:strong_rand_bytes(16),
    C = (C0 band 16#0FFF) bor 16#4000,
    D = (D0 band 16#3FFF) bor 16#8000,
    iolist_to_binary(
        io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [A, B, C, D, E])
    ).

%% @doc Terminal emission (internal; exported for the monitor process and
%% eunit). `emitted` | `suppressed` (run_id already terminated) |
%% `unavailable` (server not running — caller falls back to its local
%% guard).
-spec note_terminal(binary(), atom(), map()) -> emitted | suppressed | unavailable.
note_terminal(RunId, Name, Payload) ->
    %% Bounded retry: a transient gen_server restart must not leave a
    %% start event without a matching end (ocr Medium on Task 4).
    call_retry(
        {terminal, RunId, Name, Payload, erlang:system_time(millisecond)},
        unavailable,
        3
    ).

terminal_cap() -> ?TERMINAL_CAP.

-spec terminal_seen_count() -> non_neg_integer().
terminal_seen_count() ->
    call(seen_count, 0).

call(Req, Default) ->
    try
        gen_server:call(?MODULE, Req, ?CALL_TIMEOUT)
    catch
        exit:_ -> Default
    end.

call_retry(_Req, Default, 0) ->
    Default;
call_retry(Req, Default, N) when N > 0 ->
    case call(Req, Default) of
        R when R =:= Default, N > 1 ->
            timer:sleep(50),
            call_retry(Req, Default, N - 1);
        Other ->
            Other
    end.

%%%===================================================================
%%% Error text: scrub + truncate
%%%===================================================================

%% @doc Render a reason for the ring / snapshot: bounded, scrubbed,
%% UTF-8 safe, never raises.
-spec format_error(term()) -> binary().
format_error(Reason) ->
    try
        %% Repo-safe depth-bounded print (`~0P`, depth 20).
        Text0 = unicode:characters_to_binary(io_lib:format("~0P", [Reason, 20])),
        Text =
            case Text0 of
                B when is_binary(B) -> B;
                _ -> <<"unprintable">>
            end,
        truncate_utf8(scrub(truncate_utf8(Text, ?ERROR_TEXT_PRE_CAP)), ?ERROR_TEXT_CAP)
    catch
        _:_ -> <<"unprintable">>
    end.

truncate_utf8(Bin, Max) when byte_size(Bin) =< Max ->
    Bin;
truncate_utf8(Bin, Max) ->
    Part = binary:part(Bin, 0, Max),
    Good =
        case unicode:characters_to_binary(Part) of
            B when is_binary(B) -> B;
            {incomplete, B, _} -> B;
            {error, B, _} -> B
        end,
    <<Good/binary, "...">>.

%% @doc Redact credential shapes (shared pattern set, spec §4.2):
%% Bearer tokens, sk-/gsk- keys, Google AIza keys, `api[_-]?key`
%% assignments, PEM blocks. Order matters: PEM first so an embedded key
%% body is removed as a unit.
-spec scrub(binary()) -> binary().
scrub(Bin) when is_binary(Bin) ->
    try
        lists:foldl(fun(Pat, Acc) -> redact(Acc, Pat) end, Bin, scrub_patterns())
    catch
        _:_ -> ?REDACTED
    end.

scrub_patterns() ->
    [
        "(?s)-----BEGIN [A-Z ]+-----.*?(?:-----END [A-Z ]+-----|\\z)",
        "(?i)\\bBearer\\s+[A-Za-z0-9._~+/=\\-]+",
        "(?<![A-Za-z0-9])g?sk-[A-Za-z0-9_\\-]{8,}",
        "AIza[0-9A-Za-z_\\-]{20,}",
        "(?i)api[_-]?key[\"']?\\s*[:=]\\s*[\"']?[^\\s\"',;}]+"
    ].

redact(Bin, Pat) ->
    case re:run(Bin, Pat, [{capture, none}]) of
        match -> re:replace(Bin, Pat, ?REDACTED, [global, {return, binary}]);
        nomatch -> Bin
    end.

%%%===================================================================
%%% Per-run monitor process
%%%===================================================================

monitor_main(Tag, Caller, Name, Meta, Fun) ->
    Row = registry_row(Name),
    RunId = new_run_id(),
    Self = self(),
    CallerMon = erlang:monitor(process, Caller),
    T0 = erlang:monotonic_time(millisecond),
    Deadline = deadline_ms(Row, Meta),
    S0 = #m{
        tag = Tag,
        caller = Caller,
        caller_mon = CallerMon,
        name = Name,
        run_id = RunId,
        t0 = T0,
        expected_ms = expected_ms(Row, Meta),
        schedule_ms = resolve_schedule(Row),
        deadline_ms = Deadline,
        must_complete = maps:get(must_complete, Meta, false) =:= true,
        meta = Meta
    },
    note_start(S0),
    {Worker, WMon} = spawn_monitor(fun() -> Self ! {task_result, RunId, Fun()} end),
    TRef = erlang:start_timer(Deadline, Self, {deadline, RunId}),
    loop(S0#m{worker = Worker, worker_mon = WMon, timer = TRef}).

%% Unregistered names still run (and emit) with conservative defaults;
%% they are simply not listed in tasks[].
registry_row(Name) ->
    case [R || #{name := N} = R <- registry(), N =:= Name] of
        [R | _] ->
            R;
        [] ->
            row(Name, ?UNREGISTERED_EXPECTED_MS, 0, false)
    end.

loop(#m{run_id = RunId, worker_mon = WMon, timer = TRef, caller_mon = CMon} = S) ->
    receive
        {task_result, RunId, Res} ->
            %% Result precedes the worker's (normal) DOWN; drop the DOWN.
            _ = demonitor_worker(S),
            cancel_timer(TRef),
            S1 = emit_terminal(S, classify_result(Res, S#m.meta)),
            reply(S1, {done, Res});
        {'DOWN', WMon, process, _Pid, Reason} ->
            cancel_timer(TRef),
            S1 = emit_terminal(S, {<<"crash">>, <<"crash">>, format_error(Reason)}),
            reply(S1, {crash, Reason});
        {timeout, TRef, {deadline, RunId}} ->
            Info = {
                <<"timeout">>,
                <<"timeout">>,
                iolist_to_binary(
                    io_lib:format("exceeded wall deadline of ~b ms", [S#m.deadline_ms])
                )
            },
            case S#m.must_complete of
                true ->
                    %% Report once, keep waiting: the body is not aborted
                    %% and its eventual end is suppressed by the done flag
                    %% (and by the gateway-side guard).
                    S1 = emit_terminal(S, Info),
                    loop(S1#m{timer = undefined});
                false ->
                    %% Cancel: demonitor FIRST (flush) so the kill's DOWN
                    %% is swallowed, then kill.
                    _ = demonitor_worker(S),
                    exit(S#m.worker, kill),
                    S1 = emit_terminal(S, Info),
                    reply(S1, timeout)
            end;
        {'DOWN', CMon, process, _Pid, CReason} ->
            cancel_timer(TRef),
            case S#m.must_complete of
                true -> ok;
                false -> _ = demonitor_worker(S), exit(S#m.worker, kill)
            end,
            _ = emit_terminal(
                S,
                {<<"crash">>, <<"orphan">>, format_error({caller_down, CReason})}
            ),
            ok
    end.

demonitor_worker(#m{worker_mon = undefined}) ->
    ok;
demonitor_worker(#m{worker_mon = WMon}) ->
    erlang:demonitor(WMon, [flush]).

cancel_timer(undefined) ->
    ok;
cancel_timer(TRef) ->
    case erlang:cancel_timer(TRef) of
        false ->
            receive
                {timeout, TRef, _} -> ok
            after 0 -> ok
            end;
        _ ->
            ok
    end.

reply(#m{caller = Caller, tag = Tag}, Result) ->
    Caller ! {Tag, Result},
    ok.

%% Result -> {Outcome, ErrorClass, ErrorText}. Never raises: a monitor
%% crash would lose the terminal event.
classify_result(Res, Meta) ->
    Verdict =
        try
            case maps:get(classify, Meta, undefined) of
                F when is_function(F, 1) -> F(Res);
                _ -> default_classify(Res)
            end
        catch
            _:_ -> default_classify(Res)
        end,
    try
        case Verdict of
            ok ->
                {<<"ok">>, null, null};
            {error, Reason} ->
                {<<"error">>, error_class(Reason), format_error(Reason)};
            {error, Class, Reason} ->
                {<<"error">>, class_bin(Class), format_error(Reason)};
            Other ->
                %% Unknown verdict shapes are errors, never silent ok
                %% (a buggy classify hook must not look healthy).
                {<<"error">>, <<"internal">>, format_error({bad_classify, Other})}
        end
    catch
        _:_ -> {<<"error">>, <<"internal">>, <<"unprintable">>}
    end.

default_classify({error, _} = E) -> E;
default_classify(_) -> ok.

error_class(Reason) ->
    try
        janus_cool_view:reason_class(Reason)
    catch
        _:_ -> <<"unclassified">>
    end.

class_bin(C) when is_binary(C), C =/= <<>> -> C;
class_bin(C) when is_atom(C), C =/= undefined, C =/= null ->
    atom_to_binary(C, utf8);
class_bin(_) ->
    <<"unclassified">>.

%%%-------------------------------------------------------------------
%%% emission (monitor side)
%%%-------------------------------------------------------------------

payload(#m{name = Name, run_id = RunId, expected_ms = Exp, schedule_ms = Sched}, Phase) ->
    Base = #{
        name => atom_to_binary(Name, utf8),
        run_id => RunId,
        phase => Phase,
        outcome => null,
        error_class => null,
        error => null,
        duration_ms => null,
        expected_duration_ms => Exp,
        schedule_interval_ms => Sched
    },
    Base.

note_start(#m{name = Name, run_id = RunId} = S) ->
    %% Best-effort single emit: `{start, ...}` is not idempotent (each
    %% successful call pushes another start). Retrying on call-timeout
    %% would duplicate starts for one run_id (ocr Medium). Terminal
    %% emission stays on call_retry/3 because the server dedupes it.
    _ = call(
        {start, RunId, Name, payload(S, <<"start">>), erlang:system_time(millisecond)},
        unavailable
    ),
    ok.

emit_terminal(#m{done = true} = S, _Info) ->
    S;
emit_terminal(#m{name = Name, run_id = RunId, t0 = T0} = S, {Outcome, Class, Text}) ->
    Payload0 = payload(S, <<"end">>),
    Payload = Payload0#{
        outcome => Outcome,
        error_class => Class,
        error => Text,
        duration_ms => erlang:monotonic_time(millisecond) - T0
    },
    _ = note_terminal(RunId, Name, Payload),
    S#m{done = true}.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    _ = catch ets:delete(?LAST_TAB),
    _ = ets:new(?LAST_TAB, [named_table, set, protected, {read_concurrency, true}]),
    case validate_registry() of
        ok ->
            ok;
        {error, Problems} ->
            logger:error(#{what => janus_task_registry_invalid, problems => Problems})
    end,
    {ok, #state{}}.

handle_call({start, RunId, Name, Payload, NowMs}, _From, State) ->
    _ = push(Payload),
    Last = lookup_last(Name),
    ets:insert(
        ?LAST_TAB,
        {Name, #{
            run_id => RunId,
            started_ms => NowMs,
            running => true,
            ok_ms => maps:get(ok_ms, Last, null)
        }}
    ),
    {reply, ok, State};
handle_call({terminal, RunId, Name, Payload, NowMs}, _From, State) ->
    case maps:is_key(RunId, State#state.seen) of
        true ->
            {reply, suppressed, State};
        false ->
            _ = push(Payload),
            note_last_terminal(RunId, Name, Payload, NowMs),
            {reply, emitted, remember(RunId, State)}
    end;
handle_call(seen_count, _From, #state{seen = Seen} = State) ->
    {reply, map_size(Seen), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Never raises (the ring push is a cast and tolerates a missing server).
push(Payload) ->
    janus_ops_tail:push(#{type => <<"task_run">>, payload => Payload}).

%% FIFO-bounded set of terminated run_ids.
remember(RunId, #state{seen = Seen0, order = Order0} = State) ->
    Seen1 = Seen0#{RunId => true},
    Order1 = queue:in(RunId, Order0),
    case map_size(Seen1) > ?TERMINAL_CAP of
        true ->
            {{value, Old}, Order2} = queue:out(Order1),
            State#state{seen = maps:remove(Old, Seen1), order = Order2};
        false ->
            State#state{seen = Seen1, order = Order1}
    end.

%% Update the last-run row only when this terminal belongs to the run the
%% row currently describes (a late must-complete end for run X must not
%% clobber run Y that started since) — or when there is no row yet.
note_last_terminal(RunId, Name, Payload, NowMs) ->
    Last = lookup_last(Name),
    case maps:get(run_id, Last, RunId) =:= RunId of
        false ->
            ok;
        true ->
            Outcome = maps:get(outcome, Payload, null),
            OkMs =
                case Outcome of
                    <<"ok">> -> NowMs;
                    _ -> maps:get(ok_ms, Last, null)
                end,
            ets:insert(
                ?LAST_TAB,
                {Name, #{
                    run_id => RunId,
                    started_ms => maps:get(started_ms, Last, null),
                    finished_ms => NowMs,
                    ok_ms => OkMs,
                    running => false,
                    outcome => Outcome,
                    error_class => maps:get(error_class, Payload, null),
                    error => maps:get(error, Payload, null),
                    duration_ms => maps:get(duration_ms, Payload, null)
                }}
            ),
            ok
    end.
