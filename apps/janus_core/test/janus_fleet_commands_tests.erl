%% Fleet command registry (spec Part F.1): closed enum with pinned
%% MFAs, local arg validation before ANY fan-out, per-command timeouts,
%% and the normalized erpc wrapper driven with the documented failure
%% classes (undef / timeout / noconnection).
-module(janus_fleet_commands_tests).

-include_lib("eunit/include/eunit.hrl").

registry_is_closed_and_pinned_test() ->
    ?assertEqual(
        [catalog_cache_flush, config_reload_nudge, fleet_status, lb_cool_clear],
        lists:sort(janus_fleet_commands:command_names())
    ),
    ?assertEqual({janus_fleet, status, 0}, janus_fleet_commands:mfa(fleet_status)),
    ?assertEqual({janus_config, reload, 0}, janus_fleet_commands:mfa(config_reload_nudge)),
    ?assertEqual({janus_catalog, flush, 0}, janus_fleet_commands:mfa(catalog_cache_flush)),
    ?assertEqual({janus_lb, cool_clear, 1}, janus_fleet_commands:mfa(lb_cool_clear)),
    %% Per-command timeouts pinned (fleet_status 1 s, the rest 10 s).
    ?assertEqual(1000, janus_fleet_commands:timeout(fleet_status)),
    ?assertEqual(10000, janus_fleet_commands:timeout(config_reload_nudge)),
    ?assertEqual(10000, janus_fleet_commands:timeout(catalog_cache_flush)),
    ?assertEqual(10000, janus_fleet_commands:timeout(lb_cool_clear)).

name_from_binary_test() ->
    ?assertEqual({ok, fleet_status}, janus_fleet_commands:command(<<"fleet_status">>)),
    ?assertEqual(error, janus_fleet_commands:command(<<"reboot_everything">>)).

unknown_command_is_local_400_test() ->
    ?assertEqual({error, unknown_command}, janus_fleet_commands:execute(<<"rm_rf">>, #{})).

target_shape_validated_before_fanout_test() ->
    %% Accepted shapes are exactly the LB-normalized target tuples.
    ?assert(janus_fleet_commands:valid_target({route, 7, 3})),
    ?assert(janus_fleet_commands:valid_target({route, 3})),
    ?assert(janus_fleet_commands:valid_target({provider, 3})),
    ?assert(janus_fleet_commands:valid_target({provider_key, 42})),
    ?assert(janus_fleet_commands:valid_target({listing, <<"gpt-x">>})),
    %% Rejected: junk of every flavor — never fanned out.
    [?assertNot(janus_fleet_commands:valid_target(T)) || T <- [
        undefined,
        <<"route">>,
        {route},
        {route, 7, 3, 4},
        {nuke, everything},
        {provider},
        {provider_key, undefined},
        [route, 7, 3],
        {listing, not_a_binary},
        {route, undefined, 3}
    ]].

lb_cool_clear_bad_arg_is_local_400_test() ->
    ?assertEqual(
        {error, {bad_arg, target}},
        janus_fleet_commands:execute(<<"lb_cool_clear">>, #{target => <<"junk">>})
    ).

%% erpc raises error:{erpc, Reason} — the wrapper normalizes that class
%% to {error, Reason} FIRST, all other classes to {error, Class, Reason}.

wrapper_undef_test() ->
    %% Version skew: a command an old node lacks raises undef there. On
    %% the LOCAL node erpc re-raises with the original class (error) and
    %% an {exception, undef, Stack} reason; REMOTE peers raise
    %% error:{erpc, undef} -> {error, undef} via the normalized first
    %% clause (the timeout case below exercises the {erpc, _} shape).
    ?assertMatch(
        {error, error, {exception, undef, _}},
        janus_fleet_commands:safe_call(node(), janus_fleet_no_such_module, nope, [], 1000)
    ).

wrapper_timeout_test() ->
    %% A PAUSED peer: TCP alive, no answer.
    ?assertEqual(
        {error, timeout},
        janus_fleet_commands:safe_call(node(), timer, sleep, [5000], 100)
    ).

wrapper_noconnection_test() ->
    %% A down peer.
    ?assertEqual(
        {error, noconnection},
        janus_fleet_commands:safe_call('janus_fleet_dead@127.0.0.1', erlang, node, [], 1000)
    ).

execute_runs_local_direct_test() ->
    %% fleet_status executes LOCALLY via direct call (no erpc to self):
    %% with no peers configured the single result is the local node.
    {ok, #{results := Results}} = janus_fleet_commands:execute(<<"fleet_status">>, #{}),
    ?assertMatch([{_, {ok, _}}], maps:to_list(Results)).

execute_lb_cool_clear_local_test() ->
    %% No peers: executes the local clear (tolerant when LB is down) and
    %% reports partial/ok outcomes without touching the network.
    {ok, #{results := Results}} =
        janus_fleet_commands:execute(<<"lb_cool_clear">>, #{target => {route, 7, 3}}),
    ?assertMatch([{_, {ok, ok}}], maps:to_list(Results)).

outcome_classification_test() ->
    ?assertEqual(ok, janus_fleet_commands:outcome([{a, {ok, 1}}])),
    ?assertEqual(partial, janus_fleet_commands:outcome([{a, {error, x}}, {b, {ok, 1}}])),
    ?assertEqual(error, janus_fleet_commands:outcome([{a, {error, x}}])).
