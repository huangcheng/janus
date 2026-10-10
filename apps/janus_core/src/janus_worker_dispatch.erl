%%% @doc Worker-side job intake (spec §3.2 / §3.4 / §4).
%%%
%%% Registers as `janus_worker_dispatch`. Hellos the master pool until
%%% ack/nack, then spawns per-job `janus_worker_session` processes.
%%% Control for unknown JobRefs is dropped; cancel for a known job is
%%% forwarded to its session (covers the pre-ack orphan cancel path).
%%%
%%% Scheduler v2 (Task C, spec rev 10 Part 0.5 / A.3): hello carries
%%% the ADDITIVE `capacity` (`JANUS_WORKER_CAPACITY`; unset => key
%%% omitted => master defaults infinity) and `sched_v => 2` markers.
%%% After ack the dispatcher runs a 60 s KEEPALIVE re-hello (plain
%%% hello, idempotent admit — an adopted-pool master must be
%%% re-hello'd by every worker) and monitors the master pool process
%%% by its registered name — owner death (dist still up) triggers an
%%% IMMEDIATE re-hello. The dispatcher also owns the worker's
%%% per-provider passive EWMA (sessions report successful non-internal
%%% durations via `{job_duration, ProviderId, Ms}` — the EWMA must
%%% survive across per-job sessions) and emits the 30 s COALESCED
%%% load cast, sent ONLY when the aggregate EWMA moved > 20 % since
%%% the last report (storm-bounded, spec A.3).
-module(janus_worker_dispatch).
-behaviour(gen_server).

-export([start_link/0, hello_retry_ms/0, keepalive_ms/0, load_report_ms/0]).

%% Pure helpers (eunit).
-export([
    capacity_opt/1,
    hello_opts/1,
    should_report_load/2,
    aggregate_ewma/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
%% BINDING: fixed 1s hello retry (spec pinned numerics; no backoff).
-define(HELLO_RETRY_MS, 1000).
%% BINDING (spec Part 0.5 / A.3): 60 s keepalive hello; 30 s coalesced
%% load cast. Overridable via env for tests only.
-define(KEEPALIVE_MS, 60_000).
-define(LOAD_REPORT_MS, 30_000).
%% Load-cast suppression: report only when the aggregate EWMA moved
%% more than 20 % since the last report (spec A.3).
-define(LOAD_MOVE_RATIO, 0.20).

-record(state, {
    master_node :: node(),
    region :: binary() | undefined,
    hello = connecting :: connecting | helloing | acked | nacked,
    hello_timer :: reference() | undefined,
    %% Scheduler v2 timers/monitors (Task C).
    keepalive_timer = undefined :: reference() | undefined,
    load_timer = undefined :: reference() | undefined,
    pool_mon = undefined :: reference() | undefined,
    %% ProviderId => EwmaMs — the per-provider passive upstream EWMA.
    ewma = #{} :: map(),
    %% Aggregate EWMA at the last load cast (undefined = never sent).
    last_report = undefined :: number() | undefined,
    %% JobRef => session pid
    jobs = #{} :: #{binary() => pid()},
    %% MonitorRef => JobRef
    mons = #{} :: #{reference() => binary()}
}).

%%%===================================================================
%%% Public API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec hello_retry_ms() -> pos_integer().
hello_retry_ms() ->
    ?HELLO_RETRY_MS.

%% 60 s keepalive re-hello after ack (spec Part 0.5). Test seam only.
-spec keepalive_ms() -> pos_integer().
keepalive_ms() ->
    env_pos_int("JANUS_WORKER_KEEPALIVE_MS", ?KEEPALIVE_MS).

%% 30 s coalesced load-cast interval (spec A.3). Test seam only.
-spec load_report_ms() -> pos_integer().
load_report_ms() ->
    env_pos_int("JANUS_WORKER_LOAD_REPORT_MS", ?LOAD_REPORT_MS).

%%%===================================================================
%%% Pure helpers (eunit)
%%%===================================================================

%% `JANUS_WORKER_CAPACITY` parse (spec A.5): unset => undefined (the
%% hello key is OMITTED — the master defaults to infinity); integer
%% clamped >= 1; garbage => 1. Takes the os:getenv/1 return value.
-spec capacity_opt(false | string()) -> pos_integer() | undefined.
capacity_opt(false) ->
    undefined;
capacity_opt("") ->
    undefined;
capacity_opt(Val) when is_list(Val) ->
    try
        max(1, list_to_integer(Val))
    catch
        _:_ -> 1
    end.

%% Hello opts for the wire constructor: region from
%% `JANUS_WORKER_REGION` as today + the additive scheduler v2 markers
%% (`sched_v => 2` always; `capacity` only when the env is set).
-spec hello_opts(binary() | undefined) -> map().
hello_opts(Region) ->
    Opts0 = #{region => Region, sched_v => 2},
    case capacity_opt(os:getenv("JANUS_WORKER_CAPACITY")) of
        undefined -> Opts0;
        Capacity -> Opts0#{capacity => Capacity}
    end.

%% Load-cast suppression rule (spec A.3): first report once anything
%% is measured (Last = undefined); afterwards only when the aggregate
%% EWMA moved more than 20 %. `Old = 0` cannot move by ratio — false
%% (EWMA seeds at the first positive sample, so unreachable in
%% practice).
-spec should_report_load(undefined | number(), number()) -> boolean().
should_report_load(undefined, _New) ->
    true;
should_report_load(Old, New) when is_number(Old), is_number(New), Old > 0 ->
    abs(New - Old) > ?LOAD_MOVE_RATIO * Old;
should_report_load(_Old, _New) ->
    false.

%% Aggregate the per-provider EWMA map into the single advisory
%% `ewma_upstream_ms` value (mean; undefined when nothing is measured
%% — no cast is sent, spec A.3).
-spec aggregate_ewma(map()) -> float() | undefined.
now_mono() ->
    erlang:monotonic_time(millisecond).

aggregate_ewma(Ewma) when is_map(Ewma) ->
    Values = [V || {_, {V, _At}} <- maps:to_list(Ewma), is_number(V)],
    case Values of
        [] -> undefined;
        _ -> lists:sum(Values) / length(Values)
    end.

env_pos_int(Name, Default) ->
    case os:getenv(Name) of
        Val when is_list(Val), Val =/= "" ->
            try
                max(1, list_to_integer(Val))
            catch
                _:_ -> Default
            end;
        _ ->
            Default
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    case master_node_from_env() of
        {ok, MasterNode} ->
            Region = region_from_env(),
            ok = maybe_monitor_nodes(),
            State0 = #state{
                master_node = MasterNode,
                region = Region,
                hello = connecting
            },
            %% First hello immediately; retries every hello_retry_ms.
            State1 = do_hello_tick(State0),
            logger:info(#{
                what => janus_worker_dispatch_started,
                master_node => MasterNode
            }),
            {ok, State1};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(hello_tick, State) ->
    {noreply, do_hello_tick(State#state{hello_timer = undefined})};
handle_info(keepalive_tick, #state{hello = acked} = State) ->
    %% Plain periodic re-hello after ack (spec Part 0.5): idempotent
    %% admit, NO load payload (the load cast keeps its own suppression
    %% rule). Any nack lands in hello_nacked (sticky, as today).
    {noreply, arm_keepalive(send_hello(State))};
handle_info(keepalive_tick, State) ->
    %% Not acked (stray tick after leaving acked): the 1 s retry loop
    %% owns reconnection; the timer re-arms at the next ack.
    {noreply, State};
handle_info(load_report_tick, #state{hello = acked} = State) ->
    {noreply, arm_load_report(maybe_send_load(State))};
handle_info(load_report_tick, State) ->
    %% Not acked (stray tick after nack / master loss): do NOT
    %% re-arm — the 1 s retry loop owns reconnection and the next
    %% ack re-arms the cadence (ocr review: an in-flight tick after
    %% cancel_sched_timers must not spin forever).
    {noreply, State#state{load_timer = undefined}};
handle_info({job_duration, ProviderId, ElapsedMs}, State) when
    is_number(ElapsedMs), ElapsedMs >= 0
->
    %% Session completion report (successful non-internal upstream
    %% duration — the session filters; internal jobs never report).
    {noreply, State#state{ewma = ewma_update(ProviderId, ElapsedMs, State#state.ewma)}};
handle_info({janus_worker_hello_ack, Node, _Meta}, #state{master_node = Node} = State) ->
    {noreply, hello_acked(State)};
handle_info({janus_worker_hello_nack, Node, _Meta}, #state{master_node = Node} = State) ->
    {noreply, hello_nacked(State)};
handle_info({janus_job, JobRef, MasterSessionPid, Fields}, State) ->
    {noreply, do_job(JobRef, MasterSessionPid, Fields, State)};
handle_info({janus_cancel, JobRef}, State) when is_binary(JobRef) ->
    {noreply, do_cancel(JobRef, State)};
handle_info({'DOWN', Mon, process, _Pid, Reason}, State) ->
    case State#state.pool_mon of
        Mon ->
            %% Master pool owner death (spec Part 0.5): dist survives
            %% but the adopted pool has NO member records — immediate
            %% re-hello. The name-based monitor also fires on nodedown
            %% (noconnection), where the reconnect path below resumes.
            State1 = State#state{pool_mon = undefined},
            {noreply, master_pool_lost(State1)};
        _ ->
            case Reason of
                normal ->
                    ok;
                shutdown ->
                    ok;
                _ ->
                    JobRef = maps:get(Mon, State#state.mons, undefined),
                    logger:warning(#{
                        what => janus_worker_session_down,
                        reason => Reason,
                        monitor => Mon,
                        job_ref => JobRef
                    })
            end,
            {noreply, do_session_down(Mon, State)}
    end;
handle_info({nodedown, Node}, #state{master_node = Node} = State) ->
    {noreply, master_lost(State)};
handle_info({nodedown, Node, _Info}, #state{master_node = Node} = State) ->
    {noreply, master_lost(State)};
handle_info({nodeup, Node}, #state{master_node = Node} = State) ->
    {noreply, master_up(State)};
handle_info({nodeup, Node, _Info}, #state{master_node = Node} = State) ->
    {noreply, master_up(State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{jobs = Jobs} = State) ->
    cancel_hello_timer(State),
    cancel_keepalive(State),
    cancel_load_report(State),
    _ = demonitor_pool(State),
    maps:foreach(
        fun(_JobRef, Pid) ->
            exit(Pid, shutdown)
        end,
        Jobs
    ),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Hello loop
%%%===================================================================

do_hello_tick(#state{hello = Hello} = State) when Hello =:= acked; Hello =:= nacked ->
    State;
do_hello_tick(#state{master_node = MasterNode} = State) ->
    case catch net_kernel:connect_node(MasterNode) of
        true ->
            arm_hello(send_hello(State#state{hello = helloing}));
        _Other ->
            %% Not connected yet — retry without wasting a hello send.
            arm_hello(State#state{hello = connecting})
    end.

send_hello(#state{master_node = MasterNode, region = Region} = State) ->
    Msg = janus_worker_wire:hello(self(), node(), hello_opts(Region)),
    try
        {janus_worker_pool, MasterNode} ! Msg
    catch
        _:_ -> ok
    end,
    State.

hello_acked(#state{hello = acked, load_timer = TRef} = State) when
    is_reference(TRef)
->
    %% Keepalive re-ack: refresh the pool monitor + keepalive, but
    %% leave the 30 s load cadence ALONE — restarting it here would
    %% delay/skip scheduled casts around every keepalive (ocr review).
    State1 = cancel_hello_timer(State),
    State2 = demonitor_pool(State1),
    Mon = monitor_pool(State2#state.master_node),
    logger:debug(#{what => janus_worker_keepalive_acked, master_node => State#state.master_node}),
    arm_keepalive(State2#state{hello = acked, pool_mon = Mon});
hello_acked(State) ->
    State1 = cancel_hello_timer(State),
    State2 = demonitor_pool(State1),
    Mon = monitor_pool(State2#state.master_node),
    logger:info(#{what => janus_worker_hello_acked, master_node => State#state.master_node}),
    %% First ack: keepalive re-hello + the coalesced load-cast cadence
    %% (nack / master loss cancels them).
    arm_load_report(arm_keepalive(State2#state{hello = acked, pool_mon = Mon})).

hello_nacked(State) ->
    State1 = cancel_hello_timer(cancel_sched_timers(State)),
    logger:warning(#{what => janus_worker_hello_nacked, master_node => State#state.master_node}),
    State1#state{hello = nacked}.

%% Pool owner death WITHOUT nodedown: immediate re-hello attempt (the
%% new owner admits; a not-yet-restarted owner leaves the retry loop
%% running — same shape as the nodedown path).
master_pool_lost(#state{hello = nacked} = State) ->
    %% Sticky/vsn nack is sticky until ops undrain.
    State;
master_pool_lost(State) ->
    logger:info(#{
        what => janus_worker_master_pool_down, master_node => State#state.master_node
    }),
    do_hello_tick(cancel_sched_timers(State#state{hello = connecting})).

master_lost(#state{hello = nacked} = State) ->
    %% Sticky/vsn nack is sticky until ops undrain; do not auto-rehello.
    State;
master_lost(State) ->
    logger:info(#{what => janus_worker_master_nodedown, master_node => State#state.master_node}),
    do_hello_tick(cancel_sched_timers(State#state{hello = connecting})).

master_up(#state{hello = nacked} = State) ->
    State;
master_up(#state{hello = acked} = State) ->
    %% Dist reconnect: re-advertise (spec §3.4). hello_acked re-arms
    %% the keepalive/load cadence and the pool monitor.
    do_hello_tick(cancel_sched_timers(State#state{hello = connecting}));
master_up(State) ->
    arm_hello(State).

arm_hello(State) ->
    State1 = cancel_hello_timer(State),
    TRef = erlang:send_after(?HELLO_RETRY_MS, self(), hello_tick),
    State1#state{hello_timer = TRef}.

cancel_hello_timer(#state{hello_timer = undefined} = State) ->
    State;
cancel_hello_timer(#state{hello_timer = TRef} = State) ->
    _ = erlang:cancel_timer(TRef),
    State#state{hello_timer = undefined}.

arm_keepalive(State) ->
    State1 = cancel_keepalive(State),
    TRef = erlang:send_after(keepalive_ms(), self(), keepalive_tick),
    State1#state{keepalive_timer = TRef}.

cancel_keepalive(#state{keepalive_timer = undefined} = State) ->
    State;
cancel_keepalive(#state{keepalive_timer = TRef} = State) ->
    _ = erlang:cancel_timer(TRef),
    State#state{keepalive_timer = undefined}.

arm_load_report(State) ->
    State1 = cancel_load_report(State),
    TRef = erlang:send_after(load_report_ms(), self(), load_report_tick),
    State1#state{load_timer = TRef}.

cancel_load_report(#state{load_timer = undefined} = State) ->
    State;
cancel_load_report(#state{load_timer = TRef} = State) ->
    _ = erlang:cancel_timer(TRef),
    State#state{load_timer = undefined}.

cancel_sched_timers(State) ->
    cancel_load_report(cancel_keepalive(demonitor_pool(State))).

%%%===================================================================
%%% Master pool monitor + load cast (Task C, spec Part 0.5 / A.3)
%%%===================================================================

%% Monitor the master pool by its registered name (the ack handshake
%% is a plain send — the sender pid is not on the wire). A name-based
%% monitor fires on owner death AND on nodedown (noconnection); both
%% routes converge on the re-hello paths above.
monitor_pool(MasterNode) ->
    try
        erlang:monitor(process, {janus_worker_pool, MasterNode})
    catch
        _:_ -> undefined
    end.

demonitor_pool(#state{pool_mon = undefined} = State) ->
    State;
demonitor_pool(#state{pool_mon = Mon} = State) ->
    _ = demonitor(Mon, [flush]),
    State#state{pool_mon = undefined}.

%% Cast destination: the plain atom on the local node (the {Name,
%% Node} tuple form is silently dropped by an UNDISTRIBUTED runtime —
%% single-node dev/eunit; production always runs distributed).
pool_dest(MasterNode) when MasterNode =:= node() ->
    janus_worker_pool;
pool_dest(MasterNode) ->
    {janus_worker_pool, MasterNode}.

%% 30 s coalesced load cast (spec A.3): sent to the master pool via
%% gen_server:cast (the `{sched, 2, _}` delivery class — an old master
%% drops+counts it in the catch-all, spec Part 0.10) ONLY when acked
%% and the aggregate passive EWMA moved > 20 % since the last report.
%% Nothing measured => no cast. Advisory-only on the master side.
maybe_send_load(#state{hello = acked, master_node = MasterNode, jobs = Jobs, ewma = Ewma, last_report = Last} = State) ->
    case aggregate_ewma(Ewma) of
        undefined ->
            State;
        Aggregate ->
            case should_report_load(Last, Aggregate) of
                true ->
                    ok =
                        try
                            gen_server:cast(
                                pool_dest(MasterNode),
                                {sched, 2, {load, node(), #{
                                    inflight_self => maps:size(Jobs),
                                    ewma_upstream_ms => Aggregate
                                }}}
                            )
                        catch
                            _:_ -> ok
                        end,
                    State#state{last_report = Aggregate};
                false ->
                    State
            end
    end;
maybe_send_load(State) ->
    State.

%% Per-provider passive EWMA (spec A.3): alpha 0.25, seeds at the
%% FIRST sample — the pure step function is shared with the master
%% pool (`janus_worker_pool:ewma_step/2`).
%% Entries carry their last-update stamp so a stray/dynamic
%% provider_id cannot grow the map without bound: past EWMA_CAP the
%% oldest entry is evicted (ocr review).
-define(EWMA_CAP, 128).

ewma_update(ProviderId, X, Ewma) when is_map(Ewma) ->
    Now = now_mono(),
    Prev =
        case maps:find(ProviderId, Ewma) of
            {ok, {E, _At}} when is_number(E) -> {E, 0};
            _ -> none
        end,
    {E1, _Count} = janus_worker_pool:ewma_step(Prev, X),
    Bounded =
        case map_size(Ewma) >= ?EWMA_CAP andalso not maps:is_key(ProviderId, Ewma) of
            true ->
                [{K, _} | _] = lists:keysort(2, maps:to_list(Ewma)),
                maps:remove(K, Ewma);
            false ->
                Ewma
        end,
    Bounded#{ProviderId => {E1, Now}}.

%%%===================================================================
%%% Jobs
%%%===================================================================

do_job(JobRef, MasterSessionPid, Fields, #state{jobs = Jobs} = State) when
    is_binary(JobRef), is_pid(MasterSessionPid), is_map(Fields)
->
    case maps:is_key(JobRef, Jobs) of
        true ->
            logger:debug(#{
                what => janus_worker_dispatch_duplicate_job,
                job_ref => JobRef
            }),
            State;
        false ->
            case janus_worker_wire:validate({janus_job, JobRef, MasterSessionPid, Fields}) of
                ok ->
                    {Pid, Mon} = spawn_monitor(fun() ->
                        janus_worker_session:run(JobRef, MasterSessionPid, Fields)
                    end),
                    State#state{
                        jobs = Jobs#{JobRef => Pid},
                        mons = (State#state.mons)#{Mon => JobRef}
                    };
                {error, Reason} ->
                    logger:warning(#{
                        what => janus_worker_job_rejected,
                        reason => Reason
                    }),
                    maybe_reject(JobRef, MasterSessionPid, Reason),
                    State
            end
    end;
do_job(_JobRef, _MasterSessionPid, _Fields, State) ->
    State.

do_cancel(JobRef, #state{jobs = Jobs} = State) ->
    case maps:find(JobRef, Jobs) of
        {ok, Pid} ->
            Pid ! janus_worker_wire:cancel(JobRef),
            State;
        error ->
            State
    end.

do_session_down(Mon, #state{mons = Mons, jobs = Jobs} = State) ->
    case maps:take(Mon, Mons) of
        {JobRef, Mons1} ->
            State#state{
                mons = Mons1,
                jobs = maps:remove(JobRef, Jobs)
            };
        error ->
            State
    end.

maybe_reject(JobRef, MasterSessionPid, Reason) ->
    Msg = iolist_to_binary(io_lib:format("~p", [Reason])),
    case janus_worker_wire:error(JobRef, internal, Msg) of
        {ok, Err} ->
            MasterSessionPid ! Err;
        {error, _} ->
            ok
    end.

%%%===================================================================
%%% Env / nodes
%%%===================================================================

master_node_from_env() ->
    case os:getenv("JANUS_MASTER_NODE") of
        false ->
            {error, missing_master_node};
        "" ->
            {error, missing_master_node};
        NodeStr when is_list(NodeStr) ->
            {ok, list_to_atom(NodeStr)}
    end.

region_from_env() ->
    case os:getenv("JANUS_WORKER_REGION") of
        false -> undefined;
        "" -> undefined;
        Val when is_list(Val) -> list_to_binary(Val)
    end.

maybe_monitor_nodes() ->
    case net_kernel:monitor_nodes(true) of
        ok ->
            ok;
        {error, Reason} ->
            logger:warning(#{what => janus_worker_dispatch_monitor_nodes, reason => Reason}),
            ok
    end.
