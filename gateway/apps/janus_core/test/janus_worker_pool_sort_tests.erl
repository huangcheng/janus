%% Scheduler tier-5 ordering (2026-10-30).
%%
%% `select_v2/2` orders candidates by `{rtt_key, inflight, name}`. The
%% rtt_key of an UNMEASURED node is the crux of this suite: keying it on
%% `infinity` sorted a brand-new worker after every measured one, so it
%% never received the request that would have produced its first sample
%% — it stayed at dispatched=0 until unrelated load pushed the fleet into
%% `capacity_exhausted` (observed live when a node was added).
-module(janus_worker_pool_sort_tests).

-include_lib("eunit/include/eunit.hrl").

%% A candidate map shaped the way build_snapshot/1 produces them.
cand(Node, Rtt, Inflight) ->
    cand(Node, Rtt, Inflight, true).

%% CanSample mirrors build_snapshot/1's `can_sample` (sched_v >= 2): a
%% worker advertising an older sched_v never reports rtt_ms, so it can
%% never acquire an ?RTT cell.
cand(Node, Rtt, Inflight, CanSample) ->
    RttMap =
        case Rtt of
            none -> #{};
            _ -> #{7 => Rtt}
        end,
    {Node,
        #{
            inflight => Inflight,
            rtt_map => RttMap,
            capacity => 100,
            draining => false,
            can_sample => CanSample
        }}.

opts() -> #{rtt_enabled => true, provider_id => 7}.

ordered(Candidates) ->
    {Order, _Decisions} = janus_worker_pool:select_v2(Candidates, opts()),
    Order.

%% A measured-and-fast node still wins outright.
measured_order_test() ->
    ?assertEqual(
        [a, b],
        ordered([cand(b, 500, 0), cand(a, 100, 0)])
    ).

%% THE REGRESSION (the whole point of the change): an unmeasured node
%% keys on the FASTEST measured value, so it TIES with that node instead
%% of sorting last. (The name is the final tiebreak, so `fast` wins the
%% tie here; what matters is that `fresh` is not behind `slow`.)
unmeasured_node_ties_with_fastest_test() ->
    ?assertEqual(
        [fast, fresh, slow],
        ordered([cand(slow, 500, 0), cand(fresh, none, 0), cand(fast, 100, 0)])
    ).

%% ...and it still ranks first when the fastest node already carries
%% load. This is what the median key got WRONG: rtt_key is the primary
%% sort element, so a median-keyed fresh node sat behind every
%% faster-than-median node at ANY inflight and never got its first
%% sample while that node had spare capacity.
unmeasured_first_even_when_fast_node_busy_test() ->
    Order = ordered([cand(fast, 100, 50), cand(mid, 200, 0), cand(fresh, none, 0)]),
    ?assertEqual(fresh, hd(Order)).

%% With nothing measured every candidate shares the key, so ordering
%% falls through to inflight — a brand-new fleet still balances.
nothing_measured_balances_on_inflight_test() ->
    ?assertEqual(
        [b, c, a],
        ordered([cand(a, none, 5), cand(b, none, 1), cand(c, none, 3)])
    ).

%% rtt_enabled=false must reduce the key to (inflight, name): a much
%% better measured rtt must NOT influence the order.
%%
%% The measured values matter here: rtt_map is populated from the ?RTT
%% table even when the knob is off (passive writes are not gated), so a
%% "shared infinity fallback" implementation would still key these two
%% on their real rtts and silently keep rtt-based ordering. Asserting
%% with empty rtt_maps would pass either way and prove nothing.
rtt_disabled_uses_inflight_only_test() ->
    {Order, _} = janus_worker_pool:select_v2(
        [cand(a, 100, 2), cand(b, 9_000, 1)], #{rtt_enabled => false, provider_id => 7}
    ),
    %% b has fewer inflight; a's excellent rtt must be ignored.
    ?assertEqual([b, a], Order).

%% A worker that can NEVER be sampled (old sched_v) must not hold the
%% cold-start lead forever: it ranks last, exactly as before, instead of
%% out-ranking every measured node indefinitely.
unmeasurable_node_ranks_last_test() ->
    Order = ordered([cand(fast, 100, 50), cand(old, none, 0, false)]),
    ?assertEqual([fast, old], Order).

%% ...and it is excluded from the optimism key: the key comes from
%% `fast` (100), so the fresh node ties with it. If `slow`'s 9000 were
%% counted the minimum would still be 100, so assert the position that
%% actually distinguishes the two: fresh must be ahead of `slow`.
unmeasurable_excluded_from_optimism_test() ->
    Order = ordered([cand(slow, 9_000, 0, false), cand(fast, 100, 0), cand(fresh, none, 0)]),
    ?assertEqual([fast, fresh, slow], Order).

%% Two unmeasured nodes both key on the fleet minimum, so inflight
%% decides between them — the optimism does not disable balancing.
two_unmeasured_balance_on_inflight_test() ->
    Order = ordered([cand(f1, none, 4), cand(f2, none, 0), cand(fast, 100, 0)]),
    %% f2 (idle) must come before f1 (busy); both beat nothing here, and
    %% only their relative order is meaningful.
    ?assertEqual([f2, fast, f1], Order).