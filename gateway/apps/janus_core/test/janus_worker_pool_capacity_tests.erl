%% Capacity override precedence (worker-capacity-override spec Part 1).
%%
%% `effective_capacity/3` is the rule that governs admission for every
%% node: a settings override wins over the value the worker declared in
%% its hello, and a malformed override falls back to the declared value
%% rather than refusing — a bad settings row must not take a node out of
%% rotation. Pinned here because the rule is pure and the alternatives
%% (silently inert override, or a node removed from the fleet) are both
%% invisible from the outside.
-module(janus_worker_pool_capacity_tests).

-include_lib("eunit/include/eunit.hrl").

node() -> 'janus@10.0.0.5'.

%% An override for the node wins over the declared value.
override_wins_test() ->
    ?assertEqual(24, janus_worker_pool:effective_capacity(node(), 48, #{
        <<"janus@10.0.0.5">> => 24
    })).

%% No entry for this node: the declared value applies unchanged.
absent_entry_uses_declared_test() ->
    ?assertEqual(
        48,
        janus_worker_pool:effective_capacity(node(), 48, #{<<"janus@10.0.0.9">> => 24})
    ),
    ?assertEqual(48, janus_worker_pool:effective_capacity(node(), 48, #{})).

%% A worker that declared nothing stays unbounded when no override exists.
infinity_declared_preserved_test() ->
    ?assertEqual(infinity, janus_worker_pool:effective_capacity(node(), infinity, #{})).

%% An override applies to a node that declared nothing — that is the whole
%% point of setting a ceiling on a worker whose env carries none.
override_beats_infinity_test() ->
    ?assertEqual(32, janus_worker_pool:effective_capacity(node(), infinity, #{
        <<"janus@10.0.0.5">> => 32
    })).

%% Malformed values fall back to declared, never refuse. Zero is the
%% tempting foot-gun: it would strand the node if honoured.
malformed_override_falls_back_test() ->
    lists:foreach(
        fun(Bad) ->
            ?assertEqual(
                48,
                janus_worker_pool:effective_capacity(node(), 48, #{<<"janus@10.0.0.5">> => Bad})
            )
        end,
        [0, -1, <<"24">>, null, 3.5, true]
    ).

%% The node key is the long-name BINARY while members are keyed by ATOM;
%% a mismatch must read as "absent", not crash.
atom_binary_key_mismatch_test() ->
    %% Stored under a name that is not this node's long name.
    ?assertEqual(
        48,
        janus_worker_pool:effective_capacity(node(), 48, #{<<"10.0.0.5">> => 24})
    ).
%% --- Part 2: suspect-adjusted load ---------------------------------------
%%
%% The load figure shown to sort_tier/2 and the dashboard is
%% reserve - suspect, and the clamp at 0 is the invariant that matters: a
%% purge and a release can race on the same job, so the subtraction can go
%% negative, and a negative load would rank a node that is AT capacity as
%% the least loaded candidate in the fleet.

%% Ordinary case: some slots are suspect, the rest are real work.
suspect_adjusted_subtracts_test() ->
    ?assertEqual(18, janus_worker_pool:suspect_adjusted(25, 7)).

%% No suspects: the raw reserve passes through.
suspect_adjusted_no_suspects_test() ->
    ?assertEqual(25, janus_worker_pool:suspect_adjusted(25, 0)).

%% Every slot suspect: an idle node reports 0, not its raw reserve.
suspect_adjusted_all_suspect_test() ->
    ?assertEqual(0, janus_worker_pool:suspect_adjusted(25, 25)).

%% THE CLAMP: more suspects than reservations must read as 0, never
%% negative. This is reachable when a purge and a caller-side release race.
suspect_adjusted_clamps_at_zero_test() ->
    ?assertEqual(0, janus_worker_pool:suspect_adjusted(3, 5)),
    ?assertEqual(0, janus_worker_pool:suspect_adjusted(0, 1)),
    ?assertEqual(0, janus_worker_pool:suspect_adjusted(0, 0)).
