%%%-------------------------------------------------------------------
%%% @doc Process role for a Janus node.
%%%
%%% `JANUS_ROLE` (or `{role, ...}` on `janus_core`):
%%%   - `all` (default) — agent plane `:8080` + dashboard `:8090`
%%%   - `gateway` — agent plane only (no dashboard Cowboy / session)
%%%   - `dashboard` — dashboard only (no `/v1` listener)
%%% @end
%%%-------------------------------------------------------------------
-module(janus_role).

-export([role/0, serves_http/0, serves_dashboard/0]).

-export_type([role/0]).

-type role() :: all | gateway | dashboard.

-spec role() -> role().
role() ->
    case os_role() of
        {ok, Role} ->
            Role;
        undefined ->
            case application:get_env(janus_core, role, all) of
                gateway -> gateway;
                dashboard -> dashboard;
                all -> all;
                Other ->
                    logger:warning(#{
                        what => janus_role_unknown,
                        value => Other,
                        using => all
                    }),
                    all
            end
    end.

-spec serves_http() -> boolean().
serves_http() ->
    janus_role:role() =/= dashboard.

-spec serves_dashboard() -> boolean().
serves_dashboard() ->
    janus_role:role() =/= gateway.

os_role() ->
    case os:getenv("JANUS_ROLE") of
        Val when is_list(Val), Val =/= [] ->
            parse(string:lowercase(string:trim(Val)));
        _ ->
            undefined
    end.

parse("gateway") ->
    {ok, gateway};
parse("dashboard") ->
    {ok, dashboard};
parse("all") ->
    {ok, all};
parse(Other) ->
    logger:warning(#{what => janus_role_unknown, value => Other, using => all}),
    {ok, all}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

get_test_() ->
    {setup, fun save_env/0, fun restore_env/1, fun(_) ->
        [
            {"default all", fun() ->
                unset_role(),
                ?assertEqual(all, janus_role:role()),
                ?assert(janus_role:serves_http()),
                ?assert(janus_role:serves_dashboard())
            end},
            {"gateway env", fun() ->
                os:putenv("JANUS_ROLE", "gateway"),
                ?assertEqual(gateway, janus_role:role()),
                ?assert(janus_role:serves_http()),
                ?assertNot(janus_role:serves_dashboard())
            end},
            {"dashboard env", fun() ->
                os:putenv("JANUS_ROLE", "DASHBOARD"),
                ?assertEqual(dashboard, janus_role:role()),
                ?assertNot(janus_role:serves_http()),
                ?assert(janus_role:serves_dashboard())
            end}
        ]
    end}.

save_env() ->
    {os:getenv("JANUS_ROLE"), application:get_env(janus_core, role, undefined)}.

restore_env({Os, App}) ->
    case Os of
        false -> os:unsetenv("JANUS_ROLE");
        V -> os:putenv("JANUS_ROLE", V)
    end,
    case App of
        undefined -> application:unset_env(janus_core, role);
        R -> application:set_env(janus_core, role, R)
    end.

unset_role() ->
    os:unsetenv("JANUS_ROLE"),
    application:unset_env(janus_core, role).

-endif.
