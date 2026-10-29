-module(janus_core_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Children =
        case janus_role:get() of
            worker -> worker_children();
            master -> master_children()
        end,
    {ok, {SupFlags, Children}}.

%% Master: DB, catalog poll, usage, optional fleet (spec §3.1).
master_children() ->
    [
        %% Stable ETS heir FIRST (scheduler v2 spec Part 0.5): every
        %% owner of an heir'd table must see it running in init/1 —
        %% janus_lb creates/adopts its six state tables and janus_config
        %% owns the catalog generation, both before the old
        %% sched_v2_children position this child used to have (review
        %% 01b H0/M1). janus_geo/janus_worker_pool below adopt against
        %% the same process.
        ets_heir_child()
    ] ++
        db_conn_children() ++
        [
            dist_monitor_child(),
            %% Ops event ring BEFORE lb/config/model_sync: those emit
            %% cool/task events into it (failure-observability §4.2).
            ops_tail_child(),
            %% Task runner (terminal-once guard + tasks[] snapshot) right
            %% after the ring it pushes to, before model_sync wraps in it.
            task_run_child(),
            lb_child(),
            usage_child(),
            config_child(),
            model_sync_child()
        ] ++
        %% Scheduler v2 (spec Part 0.5 / A.1): janus_geo before the
        %% pool's picks read the PT provider map.
        %% Fleet children start AFTER the first settings distribute
        %% (janus_config:maybe_start_fleet_once/0 — F9). Not listed
        %% here so a cold env-only PT miss cannot start fleet before
        %% settings resolve.
        sched_v2_children() ++
        master_worker_pool_children().

ets_heir_child() ->
    #{
        id => janus_ets_heir,
        start => {janus_ets_heir, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [janus_ets_heir]
    }.

%% Worker: gun + dispatch only — no Postgres/catalog poll (spec §3.2).
%% v2.1 C.2: janus_dist_monitor runs on BOTH roles (dist is symmetric;
%% each node renders its own busy_dist_port counters locally).
worker_children() ->
    [
        dist_monitor_child(),
        #{
            id => janus_worker_dispatch,
            start => {janus_worker_dispatch, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [janus_worker_dispatch]
        }
    ].

%% v2.1 C.2 busy_dist_port telemetry: a dedicated counting-only
%% gen_server owns the node-global system_monitor slot (master AND
%% worker — see janus_dist_monitor module doc).
dist_monitor_child() ->
    #{
        id => janus_dist_monitor,
        start => {janus_dist_monitor, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [janus_dist_monitor]
    }.

master_worker_pool_children() ->
    case code:ensure_loaded(janus_worker_pool) of
        {module, janus_worker_pool} ->
            [
                #{
                    id => janus_worker_pool,
                    start => {janus_worker_pool, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [janus_worker_pool]
                }
            ];
        {error, _} ->
            []
    end.

%% Scheduler v2 children (master-only: the mmdb and the geo fill are
%% master-side; workers need NO mmdb, spec Part A.1). janus_geo's init
%% REFUSES boot (CRITICAL + {stop, Reason}) on explicit JANUS_SCHED_GEO=1
%% with a missing mmdb — the permanent restart exhausts supervisor
%% intensity and stops the node, the spec's refuse-boot path. The heir
%% itself is started first (ets_heir_child/0) so every owner can adopt.
sched_v2_children() ->
    [
        #{
            id => janus_geo,
            start => {janus_geo, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [janus_geo]
        }
    ].

ops_tail_child() ->
    #{
        id => janus_ops_tail,
        start => {janus_ops_tail, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [janus_ops_tail]
    }.

task_run_child() ->
    #{
        id => janus_task_run,
        start => {janus_task_run, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [janus_task_run]
    }.

lb_child() ->
    #{
        id => janus_lb,
        start => {janus_lb, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [janus_lb]
    }.

usage_child() ->
    #{
        id => janus_usage,
        start => {janus_usage, start_link, []},
        restart => permanent,
        shutdown => 15000,
        type => worker,
        modules => [janus_usage]
    }.

config_child() ->
    #{
        id => janus_config,
        start => {janus_config, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [janus_config]
    }.

model_sync_child() ->
    #{
        id => janus_model_sync,
        start => {janus_model_sync, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [janus_model_sync]
    }.

db_conn_children() ->
    case code:ensure_loaded(janus_db_conn) of
        {module, janus_db_conn} ->
            [
                #{
                    id => janus_db_conn,
                    start => {janus_db_conn, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [janus_db_conn]
                }
            ];
        {error, _} ->
            %% db_conn wired by integrator
            []
    end.
