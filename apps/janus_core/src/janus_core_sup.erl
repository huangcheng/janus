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
    Children = db_conn_children() ++ [
        #{
            id => janus_lb,
            start => {janus_lb, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [janus_lb]
        },

        #{
            id => janus_config,
            start => {janus_config, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [janus_config]
        }
    ],
    {ok, {SupFlags, Children}}.

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
