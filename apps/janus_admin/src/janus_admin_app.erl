-module(janus_admin_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    janus_admin_sup:start_link().

stop(_State) ->
    ok.