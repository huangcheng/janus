-module(janus_core_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case janus_core_sup:start_link() of
        {ok, _Pid} = Ok ->
            maybe_auto_seed(),
            Ok;
        Err ->
            Err
    end.

stop(_State) ->
    ok.

maybe_auto_seed() ->
    case os:getenv("JANUS_AUTO_SEED") of
        "1" -> spawn(fun() -> timer:sleep(300), _ = janus_seed:from_file() end);
        "true" -> spawn(fun() -> timer:sleep(300), _ = janus_seed:from_file() end);
        _ -> ok
    end.
