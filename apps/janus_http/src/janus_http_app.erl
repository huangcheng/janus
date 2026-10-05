-module(janus_http_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Counters BEFORE the listeners: handlers may bump the moment
    %% Cowboy accepts (persistent_term — consumers can't lose the race).
    ok = janus_http_stats:init(),
    janus_http_sup:start_link().

stop(_State) ->
    ok.
