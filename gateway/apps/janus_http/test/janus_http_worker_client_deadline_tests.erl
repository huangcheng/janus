%% Stream drain deadline arithmetic (2026-10-29).
%%
%% Two independent budgets guard a stream: a TOTAL age cap and an
%% INACTIVITY cap measuring time since the last forwarded byte. The
%% drain waits on whichever expires first and must classify which one
%% tripped, because the two take different paths (the inactivity trip
%% additionally releases the scheduler reservation).
%%
%% These are pure functions over absolute monotonic instants, so they
%% can be pinned without sleeping.
-module(janus_http_worker_client_deadline_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CLIENT_IDLE_MS, 300_000).

%% A deadline in the future yields the remaining budget.
remaining_positive_test() ->
    Now = erlang:monotonic_time(millisecond),
    ?assert(janus_http_worker_client:deadline_remaining(Now + 1_000) > 0).

%% An elapsed deadline clamps to 0 rather than going negative — the
%% drain's `after 0 ->` wake relies on this.
remaining_clamped_test() ->
    Now = erlang:monotonic_time(millisecond),
    ?assertEqual(0, janus_http_worker_client:deadline_remaining(Now - 5_000)).

%% min/2 of the two budgets is the wait length.
remaining_pair_takes_min_test() ->
    Now = erlang:monotonic_time(millisecond),
    Total = Now + 600_000,
    Inactivity = Now + 180_000,
    R = janus_http_worker_client:deadline_remaining(Total, Inactivity),
    ?assert(R =< 180_001),
    ?assert(R > 179_000).

%% Equal instants resolve to 0, so the drain wakes instead of sleeping
%% on an already-expired pair.
remaining_pair_elapsed_test() ->
    Now = erlang:monotonic_time(millisecond),
    ?assertEqual(0, janus_http_worker_client:deadline_remaining(Now - 1, Now - 1)).

%% Total budget nearer than inactivity -> a total timeout. This is the
%% pre-existing behavior and must not change.
classify_total_test() ->
    ?assertEqual(timeout, janus_http_worker_client:classify_stream_timeout(50_000, 180_000)).

%% Inactivity nearer -> a stall, which additionally releases the
%% scheduler reservation.
classify_no_progress_test() ->
    ?assertEqual(
        no_progress, janus_http_worker_client:classify_stream_timeout(200_000, 180_000)
    ).

%% Tie goes to the total budget, deterministically (the release policy
%% differs, so this must not depend on clause order).
classify_tie_test() ->
    ?assertEqual(timeout, janus_http_worker_client:classify_stream_timeout(0, 0)),
    ?assertEqual(timeout, janus_http_worker_client:classify_stream_timeout(1_000, 1_000)).

%% Both expired -> total budget, preserving the old semantics.
classify_both_expired_test() ->
    ?assertEqual(timeout, janus_http_worker_client:classify_stream_timeout(0, 0)).