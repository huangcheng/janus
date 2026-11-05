%% /stats.stream_budgets is the answer to "which ceiling is actually in
%% force?". It exists because two incidents this week were diagnosed with a
%% stopwatch: one stream cut at exactly 600.0s (the stream total), another
%% at exactly 1200.0s (the transport idle timeout, after a config reload
%% had silently failed to move it).
%%
%% A diagnostic that reports null everywhere is worse than none — it looks
%% like an answer. These tests pin that the numbers are real on a working
%% node, and that the ORDERING invariant holds, which is the property the
%% whole knob rests on:
%%
%%     inactivity < total < transport idle
%%
%% violating it either kills healthy streams (total <= inactivity) or lets
%% the transport cut a stream before the gateway can report a stall.
-module(janus_stream_budgets_tests).

-include_lib("eunit/include/eunit.hrl").

budgets_are_integers_test() ->
    B = janus_gateway_stats:stream_budgets(),
    ?assert(is_map(B)),
    [
        ?assert(is_integer(maps:get(K, B)))
     || K <- [total_ms, inactivity_ms, keepalive_ms]
    ].

%% The ordering is the contract. If a future change flips it, a healthy
%% stream is torn down and blamed on the wrong ceiling.
ordering_invariant_test() ->
    B = janus_gateway_stats:stream_budgets(),
    Inactivity = maps:get(inactivity_ms, B),
    Total = maps:get(total_ms, B),
    ?assert(Inactivity < Total),
    %% The transport ceiling is absent in a unit-test node (no listener),
    %% so only assert the relation when it is actually reported.
    case maps:get(http_idle_timeout_ms, B) of
        null -> ok;
        Idle -> ?assertEqual(true, Idle > Total)
    end.

%% Values come from janus_worker_wire, not from a second copy that could
%% drift.
totals_match_the_wire_module_test() ->
    B = janus_gateway_stats:stream_budgets(),
    ?assertEqual(janus_worker_wire:stream_timeout_ms(), maps:get(total_ms, B)),
    ?assertEqual(
        janus_worker_wire:stream_inactivity_timeout_ms(), maps:get(inactivity_ms, B)
    ),
    ?assertEqual(janus_worker_wire:stream_keepalive_ms(), maps:get(keepalive_ms, B)).

%% No listener in a unit-test node: the key is present and null, so a
%% caller can tell "not applicable here" from "the field was dropped".
idle_timeout_is_null_without_a_listener_test() ->
    B = janus_gateway_stats:stream_budgets(),
    ?assertEqual(null, maps:get(http_idle_timeout_ms, B)).

%% The listener refs have ONE definition; both the reload refresh and this
%% report read it. Renaming a listener must not silently no-op both.
listener_refs_are_shared_test() ->
    Refs = janus_http_sup:listener_refs(),
    ?assert(is_list(Refs)),
    ?assert(length(Refs) >= 1),
    ?assert(lists:member(janus_http_listener, Refs)).
