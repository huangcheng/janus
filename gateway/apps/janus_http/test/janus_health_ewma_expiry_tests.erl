%%%-------------------------------------------------------------------
%%% @doc Characterization tests for the health-EWMA staleness gate.
%%%
%%% Why this exists: a worker was observed rendering
%%% `janus_sched_health_ewma_ms = 31260` (31 s) while its measured
%%% provider RTT was the FASTEST in the fleet. The EWMA only advances
%%% when a job completes on that node, so a quiet node's value freezes;
%%% presenting it as current accuses a healthy node of being slow.
%%%
%%% The gate is one pure predicate and the entire contract hangs on it,
%%% so it is pinned here directly. An E2E scrape cannot reach the exact
%%% boundary (600 s) without waiting ten minutes, which is why this is a
%%% unit seam rather than an E2E one.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_health_ewma_expiry_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TTL_MS, 600000).

%% The boundary is the whole point: an off-by-one here either hides a
%% healthy node or keeps publishing a stale one.
boundary_is_inclusive_at_ttl_test() ->
    ?assert(janus_http_metrics:ewma_fresh(?TTL_MS)).

just_past_ttl_is_stale_test() ->
    ?assertNot(janus_http_metrics:ewma_fresh(?TTL_MS + 1)).

%% A fresh sample must survive.
recent_sample_is_fresh_test() ->
    ?assert(janus_http_metrics:ewma_fresh(0)),
    ?assert(janus_http_metrics:ewma_fresh(30_000)),
    ?assert(janus_http_metrics:ewma_fresh(?TTL_MS - 1)).

%% An absolutely stale sample must not render.
very_old_sample_is_stale_test() ->
    ?assertNot(janus_http_metrics:ewma_fresh(7_200_000)).

%% Unknown age must be treated as STALE, never as fresh. This is the
%% case that matters for entries written before freshness tracking
%% existed, and for a node whose stamp is absent: assuming freshness is
%% exactly the bug this whole change removes.
unknown_age_is_stale_test() ->
    ?assertNot(janus_http_metrics:ewma_fresh(undefined)),
    ?assertNot(janus_http_metrics:ewma_fresh(null)),
    ?assertNot(janus_http_metrics:ewma_fresh(<<"60000">>)),
    ?assertNot(janus_http_metrics:ewma_fresh(1.5)).
