%% The HTTP idle timeout must FOLLOW the stream ceiling when an operator
%% raises it, or the transport layer keeps closing long streams at the
%% boot-time value.
%%
%% Bug this pins (2026-11-05, live): refresh_http_idle_timeout/0 used
%% cowboy:set_env(Ref, idle_timeout, Value). That function writes into the
%% protocol options' `env` sub-map, but idle_timeout is a TOP-LEVEL option
%% — so the write went somewhere Cowboy never reads, the code looked
%% right, and every stream still died at exactly 1200s (the boot-time
%% ceiling of 600000 * 2) no matter what the operator set.
%%
%% These tests exercise the real Ranch plumbing against a listener, which
%% is the only way to see the difference: a unit test of the value alone
%% passes while the wiring is wrong.
-module(janus_config_idle_refresh_tests).

-include_lib("eunit/include/eunit.hrl").

%% The refreshed value must land on TOP-LEVEL protocol options, read back
%% through the same ranch API Coyboy uses internally.
idle_timeout_lands_on_protocol_options_test() ->
    with_listener(
        fun(Ref) ->
            ok = janus_config:refresh_http_idle_timeout_for(Ref, 1_800_000),
            Opts = ranch:get_protocol_options(Ref),
            ?assertEqual(1_800_000, maps:get(idle_timeout, Opts)),
            %% And NOT in env, which is where the old implementation put it.
            Env = maps:get(env, Opts, #{}),
            ?assertEqual(error, maps:find(idle_timeout, Env))
        end
    ).

%% The rewrite REPLACES the whole protocol-options map, so the thing most
%% likely to regress is the dispatch table disappearing — every route on
%% the listener would unmount, and a test that only looked for the new
%% idle_timeout would stay green. The dispatch must survive verbatim.
dispatch_survives_the_rewrite_test() ->
    with_listener(
        fun(Ref) ->
            Before = ranch:get_protocol_options(Ref),
            DispatchBefore = maps:get(dispatch, maps:get(env, Before)),
            ?assertNotEqual([], DispatchBefore),
            ok = janus_config:refresh_http_idle_timeout_for(Ref, 1_800_000),
            After = ranch:get_protocol_options(Ref),
            ?assertEqual(DispatchBefore, maps:get(dispatch, maps:get(env, After))),
            %% Everything else the listener needs is still there.
            ?assert(maps:is_key(env, After))
        end
    ).

%% A listener that is not running stays a no-op, but a broken write must be
%% REPORTED: the bug this fixes was a silent no-op that still said ok.
missing_listener_is_not_an_error_test() ->
    ?assertEqual(ok, janus_config:refresh_http_idle_timeout_for(janus_no_such_listener, 1_000)).

%% A listener that is not running must not make a config reload fail.
missing_listener_is_ignored_test() ->
    ?assertEqual(ok, janus_config:refresh_http_idle_timeout_for(janus_no_such_listener, 1_000)).

%% --- helper: a throwaway Ranch listener -----------------------------

with_listener(Fun) ->
    %% ranch_sup must be up before a listener can be started.
    {ok, _} = application:ensure_all_started(ranch),
    Ref = janus_test_idle_listener,
    TransportOpts = [{port, 0}],
    ProtoOpts = #{
        env => #{dispatch => cowboy_router:compile([{'_', []}])},
        idle_timeout => 1_200_000
    },
    {ok, _} = ranch:start_listener(Ref, ranch_tcp, TransportOpts, cowboy_clear, ProtoOpts),
    try
        Fun(Ref)
    after
        _ = ranch:stop_listener(Ref)
    end.
