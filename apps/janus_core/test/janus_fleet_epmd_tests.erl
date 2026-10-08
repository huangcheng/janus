%% Static EPMD replacement (spec Part A): pinned port map, no daemon.
%% The module runs before any janus process, so it reads env directly —
%% tests drive it exactly like the entrypoint-rendered boot does.
-module(janus_fleet_epmd_tests).

-include_lib("eunit/include/eunit.hrl").

setup(Peers, Port) ->
    os:putenv("JANUS_FLEET_PEERS", Peers),
    os:putenv("JANUS_FLEET_DIST_PORT", integer_to_list(Port)).

teardown() ->
    os:unsetenv("JANUS_FLEET_PEERS"),
    os:unsetenv("JANUS_FLEET_DIST_PORT").

with_env(Peers, Port, Fun) ->
    setup(Peers, Port),
    try
        Fun()
    after
        teardown()
    end.

port_please_maps_configured_peer_test() ->
    with_env("janus@alpha.example,janus@beta.example", 25672, fun() ->
        %% Atom name (net_kernel convention on the wire)...
        ?assertEqual({port, 25672, 6}, janus_fleet_epmd:port_please('janus@alpha.example', host)),
        %% ...and the list spelling erl_epmd passes through internally.
        ?assertEqual({port, 25672, 6}, janus_fleet_epmd:port_please("janus@beta.example", host))
    end).

port_please_rejects_unknown_node_test() ->
    with_env("janus@alpha.example", 25672, fun() ->
        ?assertEqual({error, noport}, janus_fleet_epmd:port_please('janus@intruder', host)),
        ?assertEqual({error, noport}, janus_fleet_epmd:port_please(undefined, host))
    end).

port_please_two_delegates_test() ->
    with_env("janus@alpha.example", 26001, fun() ->
        ?assertEqual({port, 26001, 6}, janus_fleet_epmd:port_please('janus@alpha.example', host))
    end).

listen_port_please_is_env_pinned_test() ->
    with_env("janus@alpha.example", 25672, fun() ->
        ?assertEqual({ok, 25672}, janus_fleet_epmd:listen_port_please(name, host))
    end),
    %% Default when the env is absent (production default 25672).
    ?assertEqual({ok, 25672}, janus_fleet_epmd:listen_port_please(name, host)).

register_node_static_creation_test() ->
    ?assertEqual({ok, 1}, janus_fleet_epmd:register_node(name, 25672)),
    ?assertEqual({ok, 1}, janus_fleet_epmd:register_node(name, 25672, 5)).

names_empty_test() ->
    ?assertEqual({ok, []}, janus_fleet_epmd:names()),
    ?assertEqual({ok, []}, janus_fleet_epmd:names("somehost")).

start_stop_noop_test() ->
    {ok, Pid} = janus_fleet_epmd:start(),
    ?assert(is_pid(Pid)),
    ?assertEqual(ok, janus_fleet_epmd:stop()).

address_please_delegates_to_inet_test() ->
    ?assertEqual({ok, {127, 0, 0, 1}}, janus_fleet_epmd:address_please(name, "localhost")),
    ?assertEqual({ok, {127, 0, 0, 1}}, janus_fleet_epmd:address_please(name, "localhost", inet)),
    %% Pure delegation: the return IS inet:getaddr's return, whatever
    %% the resolver thinks of the name (some sandboxes wildcard-resolve).
    ?assertEqual(
        inet:getaddr("no.such.host.invalid", inet),
        janus_fleet_epmd:address_please(name, "no.such.host.invalid", inet)
    ).
