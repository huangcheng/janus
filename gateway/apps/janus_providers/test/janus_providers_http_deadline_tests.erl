%% Local (provider) drain deadline arithmetic (2026-10-29).
%%
%% janus_providers_http's drain loops guard a stream with TWO instants:
%% a stall deadline (the shared inactivity ceiling, reset only by a
%% forwarded chunk) and a tick deadline (the keepalive cadence, re-armed
%% on every wakeup). gun:await/3 cannot be cancelled, so the tick IS the
%% wait granularity — the un-reset stall deadline is what stops a
%% permanently silent upstream from keepaliving forever instead of
%% failing.
%%
%% These helpers are pure, so the discipline is pinnable without a gun
%% connection. A regression here is invisible until a degraded/local
%% deployment stalls in production.
-module(janus_providers_http_deadline_tests).

-include_lib("eunit/include/eunit.hrl").

now_ms() ->
    erlang:monotonic_time(millisecond).

%% The nearer instant wins, so a keepalive can fire long before the
%% stall ceiling.
next_tick_prefers_tick_test() ->
    Now = now_ms(),
    Wait = janus_providers_http:next_tick(Now + 6_000, Now + 800),
    ?assert(Wait =< 801),
    ?assert(Wait > 700).

%% ...and the stall deadline wins when it is the nearer of the two, so
%% the ceiling is never overshot.
next_tick_prefers_stall_test() ->
    Now = now_ms(),
    Wait = janus_providers_http:next_tick(Now + 300, Now + 800),
    ?assert(Wait =< 301),
    ?assert(Wait > 200).

%% Never 0 or negative: gun:await must not spin.
next_tick_never_spins_test() ->
    Now = now_ms(),
    ?assert(janus_providers_http:next_tick(Now - 5_000, Now - 5_000) >= 1),
    ?assert(janus_providers_http:next_tick(Now, Now) >= 1).

expired_past_and_future_test() ->
    Now = now_ms(),
    ?assert(janus_providers_http:expired(Now - 1)),
    ?assertNot(janus_providers_http:expired(Now + 5_000)).

%% A wakeup past the stall deadline reports `stalled` and does NOT emit
%% a keepalive — this is what makes the ceiling a real bound rather than
%% an infinite keepalive loop.
idle_action_stalled_test() ->
    Self = self(),
    Ka = fun(_) -> Self ! emitted, ok end,
    ?assertEqual(stalled, janus_providers_http:idle_action(now_ms() - 1, Ka)),
    receive
        emitted -> ?assert(false)
    after 0 -> ok
    end.

%% A wakeup before the deadline emits exactly one keepalive and reports
%% `keepalive` so the caller re-arms.
idle_action_keepalive_test() ->
    Self = self(),
    Ka = fun(Frame) -> Self ! {emitted, Frame}, ok end,
    ?assertEqual(keepalive, janus_providers_http:idle_action(now_ms() + 5_000, Ka)),
    receive
        {emitted, Frame} -> ?assertEqual(<<": keepalive\n\n">>, Frame)
    after 1000 -> ?assert(false)
    end.

%% No client sink (an error-body collect): still "keepalive", never a
%% crash, and nothing is written anywhere.
idle_action_no_sink_test() ->
    ?assertEqual(keepalive, janus_providers_http:idle_action(now_ms() + 5_000, undefined)).

%% A dead client raises through emit_keepalive so the drain aborts and
%% the request is accounted as cancelled — swallowing it would blame the
%% upstream for a client disconnect.
idle_action_propagates_disconnect_test() ->
    Ka = fun(_) -> throw(janus_client_disconnect) end,
    ?assertThrow(
        janus_client_disconnect,
        janus_providers_http:idle_action(now_ms() + 5_000, Ka)
    ).