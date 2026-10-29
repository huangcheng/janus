application:ensure_all_started(crypto),
application:ensure_all_started(ssl),
application:ensure_all_started(inets),
application:ensure_all_started(esqlite),
application:ensure_all_started(thoas),
{ok, _} = janus_core_app:start(normal, []),
timer:sleep(400),
R = janus_seed:from_file(),
io:format("seed=~p~n", [R]),
io:format("ready=~p gen=~p~n", [janus_config:ready(), janus_config:generation()]),
{ok, Cat} = janus_db_conn:fetch_catalog(),
Prov = maps:get(providers, Cat, []),
PKeys = maps:get(provider_keys, Cat, []),
lists:foreach(
    fun(#{id := Id, name := Name}) ->
        N = length([1 || #{provider_id := Pid} <- PKeys, Pid =:= Id]),
        io:format("  ~s keys=~p~n", [Name, N])
    end,
    Prov
),
init:stop().
