%%% @doc Scheduler v2 Task C tests for `janus_worker_dispatch` (spec
%%% rev 10 Part 0.5 / A.3): additive hello keys (capacity from
%%% JANUS_WORKER_CAPACITY, sched_v => 2), the 60 s keepalive re-hello
%%% after ack, the pool-owner monitor (DOWN => immediate re-hello),
%%% the per-provider passive EWMA, and the 30 s coalesced load cast
%%% with the >20 % suppression rule.
%%%
%%% Pure helpers run without processes. Live tests boot the REAL
%%% gen_server: eunit runs undistributed, so the master-pool ack is
%%% injected as the production wire message and a fake local
%%% `janus_worker_pool` (name free under eunit) receives keepalive
%%% hellos and load casts — same direct-info injection as
%%% janus_worker_pool_v2_tests.
-module(janus_worker_dispatch_tests).

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Pure helpers
%%%===================================================================

capacity_opt_test() ->
    ?assertEqual(undefined, janus_worker_dispatch:capacity_opt(false)),
    ?assertEqual(undefined, janus_worker_dispatch:capacity_opt("")),
    ?assertEqual(3, janus_worker_dispatch:capacity_opt("3")),
    %% Explicit values clamp >= 1; garbage => 1 (spec A.5).
    ?assertEqual(1, janus_worker_dispatch:capacity_opt("0")),
    ?assertEqual(1, janus_worker_dispatch:capacity_opt("-5")),
    ?assertEqual(1, janus_worker_dispatch:capacity_opt("four")).

hello_opts_test() ->
    os:unsetenv("JANUS_WORKER_CAPACITY"),
    Base = janus_worker_dispatch:hello_opts(<<"cn-east">>),
    ?assertEqual(<<"cn-east">>, maps:get(region, Base)),
    ?assertEqual(2, maps:get(sched_v, Base)),
    %% Unset capacity: key OMITTED (master defaults infinity).
    ?assertEqual(false, maps:is_key(capacity, Base)),
    os:putenv("JANUS_WORKER_CAPACITY", "4"),
    WithCap = janus_worker_dispatch:hello_opts(undefined),
    ?assertEqual(4, maps:get(capacity, WithCap)),
    ?assertEqual(undefined, maps:get(region, WithCap)),
    ?assertEqual(2, maps:get(sched_v, WithCap)),
    os:putenv("JANUS_WORKER_CAPACITY", "junk"),
    ?assertEqual(1, maps:get(capacity, janus_worker_dispatch:hello_opts(undefined))),
    os:unsetenv("JANUS_WORKER_CAPACITY"),
    %% The opts validate through the wire constructor (additive keys).
    Msg = janus_worker_wire:hello(self(), node(), WithCap),
    ?assertEqual(ok, janus_worker_wire:validate(Msg)).

should_report_load_test() ->
    %% First report once anything is measured.
    ?assert(janus_worker_dispatch:should_report_load(undefined, 100.0)),
    %% Unmoved => suppressed.
    ?assertNot(janus_worker_dispatch:should_report_load(100.0, 100.0)),
    ?assertNot(janus_worker_dispatch:should_report_load(100.0, 119.0)),
    %% >20 % move in EITHER direction => report.
    ?assert(janus_worker_dispatch:should_report_load(100.0, 121.0)),
    ?assert(janus_worker_dispatch:should_report_load(100.0, 79.0)),
    %% Degenerate Old = 0: no ratio move (EWMA seeds positive).
    ?assertNot(janus_worker_dispatch:should_report_load(0.0, 5.0)).

aggregate_ewma_test() ->
    %% Entries are {Ewma, LastUpdate} tuples (stamped for the cap).
    ?assertEqual(undefined, janus_worker_dispatch:aggregate_ewma(#{})),
    ?assertEqual(100.0,
        janus_worker_dispatch:aggregate_ewma(#{<<"p1">> => {100.0, 1}})),
    ?assertEqual(200.0,
        janus_worker_dispatch:aggregate_ewma(#{
            <<"p1">> => {100.0, 1}, <<"p2">> => {300.0, 2}
        })).

pinned_intervals_test() ->
    ?assertEqual(1000, janus_worker_dispatch:hello_retry_ms()),
    ?assertEqual(60_000, janus_worker_dispatch:keepalive_ms()),
    ?assertEqual(30_000, janus_worker_dispatch:load_report_ms()),
    os:putenv("JANUS_WORKER_KEEPALIVE_MS", "50"),
    os:putenv("JANUS_WORKER_LOAD_REPORT_MS", "40"),
    ?assertEqual(50, janus_worker_dispatch:keepalive_ms()),
    ?assertEqual(40, janus_worker_dispatch:load_report_ms()),
    os:unsetenv("JANUS_WORKER_KEEPALIVE_MS"),
    os:unsetenv("JANUS_WORKER_LOAD_REPORT_MS").

%%%===================================================================
%%% Live gen_server (keepalive + pool monitor + load cast)
%%%===================================================================

%% After ack: keepalive hellos flow to the master pool name at
%% keepalive_ms cadence carrying the v2 markers (spec Part 0.5).
keepalive_rehellos_after_ack_test_() ->
    {timeout, 30, fun keepalive_rehellos_after_ack/0}.

keepalive_rehellos_after_ack() ->
    os:putenv("JANUS_MASTER_NODE", atom_to_list(node())),
    os:putenv("JANUS_WORKER_KEEPALIVE_MS", "50"),
    os:putenv("JANUS_WORKER_LOAD_REPORT_MS", "10000"),
    FakePool = start_fake_pool(),
    {ok, Dispatch} = janus_worker_dispatch:start_link(),
    try
        %% Undistributed eunit: connect_node never succeeds, so inject
        %% the production ack message (the wire shape).
        Dispatch ! {janus_worker_hello_ack, node(), #{vsn => 1}},
        Hellos = collect_hellos(FakePool, 3),
        ?assert(length(Hellos) >= 2),
        [{janus_worker_hello, _From, _Node, Meta} | _] = Hellos,
        ?assertEqual(2, maps:get(sched_v, Meta)),
        ?assertEqual(false, maps:is_key(capacity, Meta))
    after
        stop_dispatch(Dispatch),
        stop_fake_pool(FakePool),
        clean_env()
    end.

%% Pool owner death (dist still up in production): the name-based
%% monitor fires, sched timers cancel, and the state returns to the
%% reconnect loop (immediate re-hello attempt).
pool_monitor_down_rehellos_test_() ->
    {timeout, 30, fun pool_monitor_down_rehellos/0}.

pool_monitor_down_rehellos() ->
    os:putenv("JANUS_MASTER_NODE", atom_to_list(node())),
    os:putenv("JANUS_WORKER_KEEPALIVE_MS", "10000"),
    os:putenv("JANUS_WORKER_LOAD_REPORT_MS", "10000"),
    FakePool = start_fake_pool(),
    {ok, Dispatch} = janus_worker_dispatch:start_link(),
    try
        Dispatch ! {janus_worker_hello_ack, node(), #{vsn => 1}},
        %% Sanity: acked + armed (keepalive timer + pool monitor).
        ?assertEqual(acked, state_field(Dispatch, 3)),
        ?assert(is_reference(state_field(Dispatch, 5))),
        ?assert(is_reference(state_field(Dispatch, 7))),
        exit(FakePool, kill),
        ok = wait_until(fun() -> state_field(Dispatch, 3) =:= connecting end, 200),
        ?assertEqual(undefined, state_field(Dispatch, 5)),
        ?assertEqual(undefined, state_field(Dispatch, 6)),
        ?assertEqual(undefined, state_field(Dispatch, 7))
    after
        stop_dispatch(Dispatch),
        stop_fake_pool(FakePool),
        clean_env()
    end.

%% The 30 s coalesced load cast (spec A.3): first report once measured
%% (undefined last_report), suppressed while the aggregate EWMA is
%% unmoved, re-sent on a >20 % move. {job_duration,...} reports from
%% sessions feed the per-provider EWMA.
load_cast_suppression_test_() ->
    {timeout, 30, fun load_cast_suppression/0}.

load_cast_suppression() ->
    os:putenv("JANUS_MASTER_NODE", atom_to_list(node())),
    os:putenv("JANUS_WORKER_KEEPALIVE_MS", "10000"),
    os:putenv("JANUS_WORKER_LOAD_REPORT_MS", "50"),
    FakePool = start_fake_pool(),
    {ok, Dispatch} = janus_worker_dispatch:start_link(),
    try
        Dispatch ! {janus_worker_hello_ack, node(), #{vsn => 1}},
        %% No EWMA yet: no cast even after several ticks.
        timer:sleep(150),
        ?assertEqual(undefined, state_field(Dispatch, 9)),
        receive
            {fake, {'$gen_cast', {sched, 2, {load, _, _}}}} -> error(unexpected_load_cast)
        after 0 ->
            ok
        end,
        %% First sample (E1 = x1, seeds at the sample): first report.
        %% EWMA entries are {Value, LastUpdate} tuples (cap stamps).
        EwmaVal = fun() ->
            case maps:get(<<"p1">>, state_field(Dispatch, 8, #{}), none) of
                {V, _At} -> V;
                none -> none
            end
        end,
        Dispatch ! {job_duration, <<"p1">>, 100.0},
        ok = wait_until(fun() -> EwmaVal() =:= 100.0 end, 200),
        {load, #{inflight_self := 0, ewma_upstream_ms := 100.0}} =
            wait_load(),
        %% Identical move-free sample: EWMA stays 100 => SUPPRESSED.
        Dispatch ! {job_duration, <<"p1">>, 100.0},
        ok = wait_until(fun() -> EwmaVal() =:= 100.0 end, 200),
        timer:sleep(150),
        receive
            {fake, {'$gen_cast', {sched, 2, {load, _, _}}}} -> error(unexpected_load_cast)
        after 0 ->
            ok
        end,
        %% 500 ms sample: EWMA = 100 + 0.25 * 400 = 200 (100 % move) =>
        %% reported again.
        Dispatch ! {job_duration, <<"p1">>, 500.0},
        ok = wait_until(fun() -> EwmaVal() =:= 200.0 end, 200),
        {load, #{inflight_self := 0, ewma_upstream_ms := 200.0}} =
            wait_load()
    after
        stop_dispatch(Dispatch),
        stop_fake_pool(FakePool),
        clean_env()
    end.

%%%===================================================================
%%% Fixture
%%%===================================================================

%% Fake LOCAL master pool: registered under the production name so the
%% dispatcher's keepalive sends (plain messages) and load casts
%% (gen_server:cast) both land here; every message is forwarded to the
%% test process as {fake, Msg}.
start_fake_pool() ->
    Parent = self(),
    Pid = spawn(fun() ->
        register(janus_worker_pool, self()),
        Parent ! {fake_pool_ready, self()},
        fake_pool_loop(Parent)
    end),
    receive
        {fake_pool_ready, Pid} -> Pid
    after 5000 ->
        error(fake_pool_not_ready)
    end.

fake_pool_loop(Parent) ->
    receive
        Msg ->
            Parent ! {fake, Msg},
            fake_pool_loop(Parent)
    after 5000 ->
        ok
    end.

stop_dispatch(Pid) ->
    try
        gen_server:stop(Pid)
    catch
        _:_ -> ok
    end,
    ok.

stop_fake_pool(Pid) ->
    case is_process_alive(Pid) of
        true ->
            Ref = monitor(process, Pid),
            exit(Pid, kill),
            receive
                {'DOWN', Ref, process, Pid, _} -> ok
            after 1000 ->
                ok
            end;
        false ->
            ok
    end,
    %% Clean any stale registration for the next test.
    catch unregister(janus_worker_pool),
    ok.

collect_hellos(_FakePool, 0) ->
    [];
collect_hellos(FakePool, N) ->
    case wait_hello(FakePool, 2000) of
        {ok, Hello} -> [Hello | collect_hellos(FakePool, N - 1)];
        none -> []
    end.

wait_hello(_FakePool, WaitMs) ->
    receive
        {fake, {janus_worker_hello, _, _, _} = Hello} -> {ok, Hello}
    after WaitMs ->
        none
    end.

wait_load() ->
    receive
        {fake, {'$gen_cast', {sched, 2, {load, _Node, Info}}}} -> {load, Info}
    after 5000 ->
        error(no_load_cast)
    end.

%% sys:get_state returns the raw #state record; fields (1-based
%% positions): 1 master_node, 2 region, 3 hello, 4 hello_timer,
%% 5 keepalive_timer, 6 load_timer, 7 pool_mon, 8 ewma, 9 last_report,
%% 10 jobs, 11 mons.
state_field(Pid, N) ->
    element(N + 1, sys:get_state(Pid)).

state_field(Pid, N, Default) ->
    case state_field(Pid, N) of
        undefined -> Default;
        V -> V
    end.

wait_until(_Fun, 0) ->
    error(wait_timeout);
wait_until(Fun, Tries) when Tries > 0 ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(25),
            wait_until(Fun, Tries - 1)
    end.

clean_env() ->
    os:unsetenv("JANUS_MASTER_NODE"),
    os:unsetenv("JANUS_WORKER_KEEPALIVE_MS"),
    os:unsetenv("JANUS_WORKER_LOAD_REPORT_MS"),
    ok.
