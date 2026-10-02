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
    case env_truthy(os:getenv("JANUS_AUTO_SEED")) of
        true ->
            spawn(fun() ->
                try
                    case janus_seed:from_file() of
                        ok ->
                            logger:info(#{what => janus_auto_seed_ok});
                        {error, Reason} ->
                            logger:error(#{
                                what => janus_auto_seed_failed,
                                reason => janus_seed:sanitize_error(Reason)
                            })
                    end
                catch
                    Class:CatchReason:Stack ->
                        logger:error(#{
                            what => janus_auto_seed_crashed,
                            class => Class,
                            reason => janus_seed:sanitize_error(CatchReason),
                            stack => janus_seed:redact_stack(Stack)
                        })
                end
            end);
        false ->
            ok
    end.

env_truthy(false) -> false;
env_truthy("") -> false;
env_truthy(Val) when is_list(Val) ->
    lists:member(string:lowercase(Val), ["1", "true", "yes", "on"]);
env_truthy(_) ->
    false.
