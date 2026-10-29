%% Stream timeout budgets (2026-10-29).
%%
%% stream_timeout_ms/0 bounds a stream's TOTAL age; the inactivity
%% ceiling bounds time since the last forwarded byte. The ordering
%% between them is load-bearing: the inactivity cap must be the SMALLER
%% of the two or it can never trip, and we are back to a stalled
%% upstream holding a request for the full total budget while the
%% client's own idle timer expires first (the 2026-10-29 incident).
%%
%% Both are independent literals, so a later tuning of either one could
%% silently invert the ordering. These assertions make that a CI
%% failure instead of a production surprise.
-module(janus_worker_wire_timeouts_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DEFAULT_KA, 15_000).

%% The inactivity ceiling only means anything if it fires FIRST.
inactivity_shorter_than_total_test() ->
    ?assert(
        janus_worker_wire:stream_inactivity_timeout_ms() <
            janus_worker_wire:stream_timeout_ms()
    ).

%% The point of the ceiling is to speak before the CLIENT gives up: pi
%% defaults its HTTP idle timeout to 300s, so a cap above that would
%% leave the gateway reporting a stall the client never lives to read.
inactivity_under_client_idle_default_test() ->
    ?assert(janus_worker_wire:stream_inactivity_timeout_ms() < 300_000).

%% The keepalive must fire BEFORE the ceiling tears the stream down,
%% otherwise the client never hears it. This module owns the knob, so it
%% owns the invariant.
keepalive_below_ceiling_test() ->
    ?assert(
        janus_worker_wire:stream_keepalive_ms() <
            janus_worker_wire:stream_inactivity_timeout_ms()
    ).

%% ...and below the client idle default too, or it is useless.
keepalive_under_client_idle_default_test() ->
    ?assert(janus_worker_wire:stream_keepalive_ms() < 300_000).

keepalive_positive_test() ->
    ?assert(janus_worker_wire:stream_keepalive_ms() > 0).

%% An override at or above the ceiling is refused: such a cadence could
%% never fire before the stream died.
keepalive_override_at_ceiling_refused_test() ->
    Ceiling = janus_worker_wire:stream_inactivity_timeout_ms(),
    lists:foreach(
        fun(Bad) ->
            ok = application:set_env(janus_core, stream_keepalive_ms, Bad),
            try
                ?assertEqual(?DEFAULT_KA, janus_worker_wire:stream_keepalive_ms())
            after
                application:unset_env(janus_core, stream_keepalive_ms)
            end
        end,
        [Ceiling, Ceiling + 1, Ceiling * 4]
    ).

%% Garbage in the app env falls back rather than crashing a drain.
keepalive_garbage_env_falls_back_test() ->
    lists:foreach(
        fun(Bad) ->
            ok = application:set_env(janus_core, stream_keepalive_ms, Bad),
            try
                ?assertEqual(?DEFAULT_KA, janus_worker_wire:stream_keepalive_ms())
            after
                application:unset_env(janus_core, stream_keepalive_ms)
            end
        end,
        [0, -5, <<"nope">>, undefined, 1.5]
    ).

%% The invariant must hold for EVERY configurable input, not just the
%% defaults: a tiny ceiling must not collapse onto its own keepalive.
keepalive_strictly_below_ceiling_for_tiny_ceilings_test() ->
    lists:foreach(
        fun(Idle) ->
            ok = application:set_env(janus_core, stream_inactivity_timeout_ms, Idle),
            try
                C = janus_worker_wire:stream_inactivity_timeout_ms(),
                K = janus_worker_wire:stream_keepalive_ms(),
                ?assert(K < C)
            after
                application:unset_env(janus_core, stream_inactivity_timeout_ms)
            end
        end,
        [1, 2, 10, 100, 1_000, 6_000]
    ).

%% ...and for a tiny EXPLICIT cadence, which must be floored rather than
%% turning the drain into a ~1 kHz wakeup flood.
keepalive_explicit_tiny_is_floored_test() ->
    lists:foreach(
        fun(Ka) ->
            ok = application:set_env(janus_core, stream_keepalive_ms, Ka),
            try
                ?assert(janus_worker_wire:stream_keepalive_ms() >= 50),
                ?assert(
                    janus_worker_wire:stream_keepalive_ms() <
                        janus_worker_wire:stream_inactivity_timeout_ms()
                )
            after
                application:unset_env(janus_core, stream_keepalive_ms)
            end
        end,
        [1, 2, 49]
    ).

%% Guards against a zero/negative value silently disabling the window.
positive_test() ->
    ?assert(janus_worker_wire:stream_inactivity_timeout_ms() > 0),
    ?assert(janus_worker_wire:stream_timeout_ms() > 0),
    ?assert(janus_worker_wire:non_stream_timeout_ms() > 0).