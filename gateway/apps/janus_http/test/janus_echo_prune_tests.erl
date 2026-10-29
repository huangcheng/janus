%% Echo bucket prune regression (security audit run-1, confirmed
%% gateway/apps/janus_http/src/janus_http_echo.erl:prune_stale:
%% select_delete-matchspec-body). The stale-sweep match spec carried
%% a bare `true` body — an invalid match program — so select_delete
%% raised badarg on every call and allow/1's catch-all silently
%% swallowed it: neither the stale sweep nor the oldest-row eviction
%% ever ran, and the unauthenticated per-peer-IP bucket table grew
%% one permanent row per distinct source address. These tests drive
%% the table past the cap through the public allow/1 path and assert
%% the documented cap actually holds (with the sweep's hysteresis:
%% trigger at cap+margin, evict down to cap-slack). Like the other
%% suites in this directory they run via `rebar3 eunit` (CI
%% compiles/formats only).
-module(janus_echo_prune_tests).

-include_lib("eunit/include/eunit.hrl").

-define(BUCKET, janus_echo_buckets).
%% Enough fresh peers past the cap to cross the sweep margin (128)
%% several times over, so the run exercises multiple eviction waves.
-define(OVER_CAP, 400).

distinct_ip(N) ->
    <<"198.18.", (integer_to_binary(N div 250))/binary, ".",
        (integer_to_binary(N rem 250))/binary>>.

prune_enforces_bucket_cap_test() ->
    try
        ok = janus_http_echo:init_knob(),
        _ = ets:delete_all_objects(?BUCKET),
        Cap = janus_http_echo:bucket_cap(),
        [true = janus_http_echo:allow(distinct_ip(N)) || N <- lists:seq(1, Cap + ?OVER_CAP)],
        %% Hysteresis: the table may float up to cap+margin between
        %% sweeps and down to cap-slack after one — but never beyond
        %% cap+margin (the unbounded-growth defect this guards).
        Size = ets:info(?BUCKET, size),
        ?assert(Size =< Cap + 128),
        ?assert(Size >= Cap - 64),
        %% A fresh address after the prune is still admitted (the cap
        %% evicts, it never blocks).
        true = janus_http_echo:allow(<<"203.0.113.7">>)
    after
        _ = ets:delete_all_objects(?BUCKET)
    end.

prune_stale_deletes_only_stale_rows_test() ->
    %% Drives the production prune_stale/0 (no hand-copied match
    %% spec): a row older than the 1 h staleness window must be
    %% deleted, a fresh row must survive, and the call must not
    %% raise — the bare-`true` body defect raised badarg here.
    try
        ok = janus_http_echo:init_knob(),
        _ = ets:delete_all_objects(?BUCKET),
        Now = erlang:monotonic_time(millisecond),
        Stale = {<<"203.0.113.1">>, 1.0, Now - 3_600_001},
        Fresh = {<<"203.0.113.2">>, 24.0, Now},
        _ = ets:insert(?BUCKET, [Stale, Fresh]),
        ok = janus_http_echo:prune_stale(),
        ?assertNot(ets:member(?BUCKET, element(1, Stale))),
        ?assert(ets:member(?BUCKET, element(1, Fresh)))
    after
        _ = ets:delete_all_objects(?BUCKET)
    end.

single_flight_marker_test() ->
    %% Pins the marker semantics: a FRESH marker blocks over-cap
    %% sweeps (single flight), a marker older than the sweep TTL is
    %% reclaimed by the next arrival (a killed sweeper's marker can
    %% never disable pruning permanently). Key mirrors the module's
    %% ?SWEEP_MARKER ('__echo_sweep__').
    try
        ok = janus_http_echo:init_knob(),
        _ = ets:delete_all_objects(?BUCKET),
        Cap = janus_http_echo:bucket_cap(),
        Now = erlang:monotonic_time(millisecond),

        %% Fresh marker: sweeps are skipped while it is held. The
        %% marker's timestamp is refreshed every batch so a slow
        %% machine cannot age it past the 1 s sweep TTL mid-loop and
        %% turn the phase into an accidental reclaim test.
        Marker = {'__echo_sweep__', 0, Now},
        true = ets:insert_new(?BUCKET, Marker),
        Batch = 256,
        Total = Cap + 300,
        Refresh = fun Refresh(0, _) -> ok;
            Refresh(Left, FromN) ->
                N = min(Batch, Left),
                [true = janus_http_echo:allow(distinct_ip(FromN + I)) || I <- lists:seq(1, N)],
                _ = ets:delete(?BUCKET, '__echo_sweep__'),
                _ = ets:insert(
                    ?BUCKET,
                    {'__echo_sweep__', 0, erlang:monotonic_time(millisecond)}
                ),
                Refresh(Left - N, FromN + N)
            end,
        Refresh(Total, 1),
        ?assert(ets:info(?BUCKET, size) > Cap + 128),

        %% Stale marker (killed sweeper): reclaimed, sweep proceeds.
        _ = ets:delete(?BUCKET, '__echo_sweep__'),
        true = ets:insert_new(?BUCKET, {'__echo_sweep__', 0, erlang:monotonic_time(millisecond) - 10_000}),
        true = janus_http_echo:allow(<<"203.0.113.9">>),
        ?assert(ets:info(?BUCKET, size) =< Cap + 128)
    after
        _ = ets:delete_all_objects(?BUCKET)
    end.

concurrent_over_cap_stays_bounded_test() ->
    %% Exercises the single-flight marker under real parallelism: many
    %% processes admit fresh peers past the trigger at once. Not a
    %% deterministic scheduler test — it asserts the two invariants
    %% that must hold under ANY interleaving: no crash escapes the
    %% allow/1 catch-all and the table stays within cap+margin.
    try
        ok = janus_http_echo:init_knob(),
        _ = ets:delete_all_objects(?BUCKET),
        Cap = janus_http_echo:bucket_cap(),
        %% Pre-fill to just under the cap sequentially so the parallel
        %% wave crosses the sweep trigger mid-flight (a wave below the
        %% cap would never exercise the single-flight path at all).
        [true = janus_http_echo:allow(distinct_ip(N)) || N <- lists:seq(1, Cap - 256)],
        Self = self(),
        W = 40,
        Peers = 64,
        Pids = [spawn(fun() ->
            [janus_http_echo:allow(distinct_ip(100_000 + 1000 * Wx + I)) || I <- lists:seq(1, Peers)],
            Self ! done
         end) || Wx <- lists:seq(1, W)],
        %% Monitored barrier: a worker that dies before its `done` must
        %% not hang the suite.
        [erlang:monitor(process, P) || P <- Pids],
        [receive
             done -> ok;
             {'DOWN', _, process, _, _} -> ok
         after 10_000 -> erlang:error(barrier_timeout)
         end || _ <- lists:seq(1, W)],
        %% Worst-case interleaving: a single in-flight sweep covers
        %% only its snapshot, so concurrent arrivals during that sweep
        %% can overshoot the margin by up to one wave of inserts.
        Wave = W * Peers,
        ?assert(ets:info(?BUCKET, size) =< Cap - 256 + Wave),
        %% Self-healing, deterministically: a rare interleaving can
        %% leave a fresh-but-ownerless single-flight marker inside its
        %% 1 s TTL (the next arrival correctly treats it as a live
        %% sweep and skips). Settle past the TTL, then the very next
        %% over-cap arrival reclaims the marker and sweeps everything
        %% back under the margin.
        timer:sleep(1200),
        true = janus_http_echo:allow(<<"203.0.113.99">>),
        ?assert(ets:info(?BUCKET, size) =< Cap + 128)
    after
        _ = ets:delete_all_objects(?BUCKET)
    end.
