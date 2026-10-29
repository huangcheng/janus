%%%-------------------------------------------------------------------
%%% @doc Fleet subtree supervisor (spec Part A / 0.12): runs under
%%% janus_core_sup as a TRANSIENT child, only when the fleet knob is
%%% on. The 3/60 s intensity is a deliberate tripwire — an exhausted
%%% supervisor exits with reason `shutdown`, transient children are not
%%% restarted on shutdown, so a fleet crash loop parks the subtree
%%% (logged loudly) while catalog/DB/usage siblings keep running.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_fleet_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 3, period => 60},
    Children = [
        #{
            id => janus_fleet,
            start => {janus_fleet, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [janus_fleet]
        }
    ],
    {ok, {SupFlags, Children}}.
