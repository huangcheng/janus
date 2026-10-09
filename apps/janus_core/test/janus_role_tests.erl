-module(janus_role_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PT_KEY, {janus, role}).
-define(MASTER_NODE, "janus_master@127.0.0.1").

clear_role_env() ->
    os:unsetenv("JANUS_ROLE"),
    os:unsetenv("JANUS_MASTER_NODE"),
    catch persistent_term:erase(?PT_KEY).

set_role_env(Role, MasterNode) ->
    clear_role_env(),
    case Role of
        unset ->
            ok;
        {set, RoleVal} ->
            true = os:putenv("JANUS_ROLE", RoleVal)
    end,
    case MasterNode of
        unset ->
            ok;
        {set, MasterVal} ->
            true = os:putenv("JANUS_MASTER_NODE", MasterVal)
    end.

unset_defaults_to_master_test() ->
    set_role_env(unset, unset),
    ?assertEqual({ok, master}, janus_role:resolve()),
    ?assertEqual(master, janus_role:get()).

master_env_test() ->
    set_role_env({set, "master"}, unset),
    ?assertEqual({ok, master}, janus_role:resolve()),
    ?assertEqual(master, janus_role:get()).

worker_env_test() ->
    set_role_env({set, "worker"}, {set, ?MASTER_NODE}),
    ?assertEqual({ok, worker}, janus_role:resolve()),
    ?assertEqual(worker, janus_role:get()).

unknown_role_test() ->
    set_role_env({set, "gateway"}, unset),
    ?assertEqual({error, unknown_role}, janus_role:resolve()).

worker_missing_master_test() ->
    set_role_env({set, "worker"}, unset),
    ?assertEqual({error, missing_master_node}, janus_role:resolve()).
