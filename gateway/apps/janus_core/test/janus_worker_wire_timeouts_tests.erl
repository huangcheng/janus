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

%% Guards against a zero/negative value silently disabling the window.
positive_test() ->
    ?assert(janus_worker_wire:stream_inactivity_timeout_ms() > 0),
    ?assert(janus_worker_wire:stream_timeout_ms() > 0),
    ?assert(janus_worker_wire:non_stream_timeout_ms() > 0).