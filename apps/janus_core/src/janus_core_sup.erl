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
    db_conn_children() ++
        [
            lb_child(),
            usage_child(),
            config_child(),
            model_sync_child()
        ] ++ master_worker_pool_children() ++ fleet_children().

%% Worker: gun + dispatch only — no Postgres/catalog poll (spec §3.2).
worker_children() ->
    [
        #{
            id => janus_worker_dispatch,
            start => {janus_worker_dispatch, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [janus_worker_dispatch]
        }
    ].

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

%% Fleet subtree (spec Part A / 0.12): present ONLY when the knob is
%% on, registered TRANSIENT so a crash-looping fleet supervisor parks
%% itself (exhausted intensity exits `shutdown`; transient children are
%% not restarted on shutdown) without ever restarting its siblings.
fleet_children() ->
    case env_truthy(os:getenv("JANUS_FLEET_ENABLED")) of
        true ->
            [
                #{
                    id => janus_fleet_sup,
                    start => {janus_fleet_sup, start_link, []},
                    restart => transient,
                    shutdown => 5000,
                    type => supervisor,
                    modules => [janus_fleet_sup]
                }
            ];
        false ->
            []
    end.

env_truthy(false) ->
    false;
env_truthy("") ->
    false;
env_truthy(Val) when is_list(Val) ->
    lists:member(string:lowercase(Val), ["1", "true", "yes", "on"]);
env_truthy(_) ->
    false.

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
