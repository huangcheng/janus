-module(janus_core_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    %% db_conn wired by integrator — start only when module is present.
    %% db_conn → lb → config (config expects fetch_catalog / NOTIFY).
    Children =
        db_conn_children() ++
            [
                #{
                    id => janus_lb,
                    start => {janus_lb, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [janus_lb]
                },

                %% Data-plane usage events (buffered writer + retention
                %% sweep); 15s shutdown budget gives terminate/2 room to
                %% flush a full buffer.
                #{
                    id => janus_usage,
                    start => {janus_usage, start_link, []},
                    restart => permanent,
                    shutdown => 15000,
                    type => worker,
                    modules => [janus_usage]
                },

                #{
                    id => janus_config,
                    start => {janus_config, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [janus_config]
                },

                %% Provider model-list sync (poll /models, upsert new
                %% names as disabled rows; interval env-configurable).
                #{
                    id => janus_model_sync,
                    start => {janus_model_sync, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [janus_model_sync]
                }
            ] ++ fleet_children(),
    {ok, {SupFlags, Children}}.

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
