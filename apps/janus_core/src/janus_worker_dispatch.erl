%%% @doc Worker-side job intake (spec §3.2 / §3.4 / §4).
%%%
%%% Registers as `janus_worker_dispatch`. Hellos the master pool until
%%% ack/nack, then spawns per-job `janus_worker_session` processes.
%%% Control for unknown JobRefs is dropped; cancel for a known job is
%%% forwarded to its session (covers the pre-ack orphan cancel path).
-module(janus_worker_dispatch).
-behaviour(gen_server).

-export([start_link/0, hello_retry_ms/0]).

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

-record(state, {
    master_node :: node(),
    region :: binary() | undefined,
    hello = connecting :: connecting | helloing | acked | nacked,
    hello_timer :: reference() | undefined,
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
handle_info({janus_worker_hello_ack, Node, _Meta}, #state{master_node = Node} = State) ->
    {noreply, hello_acked(State)};
handle_info({janus_worker_hello_nack, Node, _Meta}, #state{master_node = Node} = State) ->
    {noreply, hello_nacked(State)};
handle_info({janus_job, JobRef, MasterSessionPid, Fields}, State) ->
    {noreply, do_job(JobRef, MasterSessionPid, Fields, State)};
handle_info({janus_cancel, JobRef}, State) when is_binary(JobRef) ->
    {noreply, do_cancel(JobRef, State)};
handle_info({'DOWN', Mon, process, _Pid, Reason}, State) ->
    case Reason of
        normal ->
            ok;
        shutdown ->
            ok;
        _ ->
            logger:warning(#{
                what => janus_worker_session_down,
                reason => Reason,
                monitor => Mon
            })
    end,
    {noreply, do_session_down(Mon, State)};
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
do_hello_tick(#state{master_node = MasterNode, region = Region} = State) ->
    case catch net_kernel:connect_node(MasterNode) of
        true ->
            Msg = janus_worker_wire:hello(self(), node(), #{region => Region}),
            {janus_worker_pool, MasterNode} ! Msg,
            arm_hello(State#state{hello = helloing});
        _Other ->
            %% Not connected yet — retry without wasting a hello send.
            arm_hello(State#state{hello = connecting})
    end.

hello_acked(State) ->
    State1 = cancel_hello_timer(State),
    logger:info(#{what => janus_worker_hello_acked, master_node => State#state.master_node}),
    State1#state{hello = acked}.

hello_nacked(State) ->
    State1 = cancel_hello_timer(State),
    logger:warning(#{what => janus_worker_hello_nacked, master_node => State#state.master_node}),
    State1#state{hello = nacked}.

master_lost(#state{hello = nacked} = State) ->
    %% Sticky/vsn nack is sticky until ops undrain; do not auto-rehello.
    State;
master_lost(State) ->
    logger:info(#{what => janus_worker_master_nodedown, master_node => State#state.master_node}),
    arm_hello(State#state{hello = connecting}).

master_up(#state{hello = nacked} = State) ->
    State;
master_up(#state{hello = acked} = State) ->
    %% Dist reconnect: re-advertise (spec §3.4).
    arm_hello(State#state{hello = connecting});
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
