%% Fleet signal distribution — pure logic eunit-first (spec
%% native-distribution Parts A/B/B2): ingress validation, TTL classes,
%% WindowId rules, cache_put replay bound, quota publish set, connector
%% backoff, wire hash codec; then live gen_server ingress against the
%% real mirror tables (production shapes: binaries/atoms/ints exactly as
%% the wire and local hooks produce them).
-module(janus_fleet_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../include/janus_lb.hrl").

-define(PEER_A, 'janus_test_a@host').
-define(PEER_B, 'janus_test_b@host').
-define(SELF, 'janus_test_self@host').

ctx() ->
    #{peers => [?PEER_A, ?PEER_B], self => ?SELF}.

%%--------------------------------------------------------------------
%% TTL classes (Part 0.2/B: generic signals 30 s, cache_put its own
%% 300 s class — the generic clamp must NOT apply to cache entries).
%%--------------------------------------------------------------------

ttl_clamp_test() ->
    ?assertEqual(5000, janus_fleet:clamp_ttl(5000, signal)),
    ?assertEqual(30000, janus_fleet:clamp_ttl(60000, signal)),
    ?assertEqual(30000, janus_fleet:clamp_ttl(30000, signal)),
    ?assertEqual(6000, janus_fleet:clamp_ttl(6000, signal)),
    ?assertEqual(300000, janus_fleet:clamp_ttl(999999, cache)),
    ?assertEqual(5000, janus_fleet:clamp_ttl(5000, cache)).

ttl_must_be_positive_test() ->
    ?assertEqual({error, ttl}, janus_fleet:clamp_ttl(0, signal)),
    ?assertEqual({error, ttl}, janus_fleet:clamp_ttl(-1, cache)),
    ?assertEqual({error, ttl}, janus_fleet:clamp_ttl(forever, signal)).

%%--------------------------------------------------------------------
%% Ingress validation (Part 0.6d/7): exact tuple shapes, sender
%% membership, byte clamps.
%%--------------------------------------------------------------------

lb_cool_happy_test() ->
    Target = {route, 7, 3},
    {ok, Norm} = janus_fleet:validate_signal(?PEER_A, {lb_cool, Target, 60000, {auth, 401}}, ctx()),
    ?assertEqual(#{kind => lb_cool, target => Target, ttl_ms => 30000, class => {auth, 401}}, Norm).

sender_must_be_peer_test() ->
    ?assertEqual({error, sender}, janus_fleet:validate_signal(?SELF, {lb_cool, t, 1000, x}, ctx())),
    ?assertEqual(
        {error, sender}, janus_fleet:validate_signal('janus@intruder', {lb_cool, t, 1000, x}, ctx())
    ),
    ?assertEqual({error, sender}, janus_fleet:validate_signal(<<"binary">>, {lb_cool, t, 1000, x}, ctx())).

unknown_tag_shape_dropped_test() ->
    ?assertEqual({error, shape}, janus_fleet:validate_signal(?PEER_A, {lb_cool, only_three}, ctx())),
    ?assertEqual({error, shape}, janus_fleet:validate_signal(?PEER_A, whatever_atom, ctx())),
    ?assertEqual(
        {error, shape}, janus_fleet:validate_signal(?PEER_A, {janus_fleet, 1, {unknown_signal, x}}, ctx())
    ),
    ?assertEqual(
        {error, shape}, janus_fleet:validate_signal(?PEER_A, {janus_fleet, 2, {lb_cool, t, 5, x}}, ctx())
    ).

target_byte_clamp_test() ->
    Huge = {route, binary:copy(<<"x">>, 1024), 3},
    ?assertEqual({error, target}, janus_fleet:validate_signal(?PEER_A, {lb_cool, Huge, 5000, x}, ctx())),
    %% production-shaped target passes the clamp
    ?assertMatch(
        {ok, #{kind := lb_cool}},
        janus_fleet:validate_signal(?PEER_A, {lb_cool, {provider_key, 42}, 5000, x}, ctx())
    ).

lb_lat_shape_test() ->
    Ok = {lb_lat, {route, 7, 3}, degraded, 6100, 12, 15000},
    ?assertMatch({ok, #{verdict := degraded}}, janus_fleet:validate_signal(?PEER_A, Ok, ctx())),
    BadVerdict = {lb_lat, {route, 7, 3}, sick, 6100, 12, 15000},
    ?assertEqual({error, shape}, janus_fleet:validate_signal(?PEER_A, BadVerdict, ctx())),
    BadEwma = {lb_lat, {route, 7, 3}, degraded, <<"slow">>, 12, 15000},
    ?assertEqual({error, shape}, janus_fleet:validate_signal(?PEER_A, BadEwma, ctx())).

lb_recovered_and_purge_shape_test() ->
    ?assertMatch(
        {ok, #{kind := lb_recovered, target := {provider, 3}}},
        janus_fleet:validate_signal(?PEER_A, {lb_recovered, {provider, 3}}, ctx())
    ),
    ?assertMatch(
        {ok, #{kind := lb_cool_purge, target := {route, 7, 3}}},
        janus_fleet:validate_signal(?PEER_B, {lb_cool_purge, {route, 7, 3}}, ctx())
    ).

quota_shape_test() ->
    %% production shape: integer agent-key id from the api_keys table,
    %% limits exactly as the catalog normalizes them (ints; null was
    %% already filtered by the publisher)
    Ok = {quota, 42, 101, 60, {31, 60}, 6000},
    ?assertMatch({ok, #{kind := quota}}, janus_fleet:validate_signal(?PEER_A, Ok, ctx())),
    ?assertMatch(
        {ok, #{kind := quota}},
        janus_fleet:validate_signal(?PEER_A, {quota, <<"agent-key-bin">>, 5, 86400, {9, 10}, 6000}, ctx())
    ),
    %% AgentKeyId > 128 bytes is dropped (rev 10 clamp)
    LongKey = binary:copy(<<"k">>, 129),
    ?assertEqual(
        {error, agent_key}, janus_fleet:validate_signal(?PEER_A, {quota, LongKey, 5, 60, {1, 2}, 6000}, ctx())
    ),
    %% window must be a sane bucket (>= 60 s)
    ?assertEqual(
        {error, shape}, janus_fleet:validate_signal(?PEER_A, {quota, 42, 5, 1, {1, 2}, 6000}, ctx())
    ).

cache_put_shape_test() ->
    Hash = janus_fleet:hash_to_wire(123456),
    ?assertMatch(
        {ok, #{kind := cache_put, ttl_ms := 300000}},
        janus_fleet:validate_signal(?PEER_A, {cache_put, Hash, <<"fast">>, <<"judge-m">>, 400000}, ctx())
    ),
    ?assertEqual(
        {error, hash},
        janus_fleet:validate_signal(?PEER_A, {cache_put, <<"nothex">>, <<"fast">>, <<"judge-m">>, 5000}, ctx())
    ),
    Short = binary:part(janus_fleet:hash_to_wire(1), 0, 63),
    ?assertEqual(
        {error, hash},
        janus_fleet:validate_signal(?PEER_A, {cache_put, Short, <<"fast">>, <<"judge-m">>, 5000}, ctx())
    ),
    NotHex = binary:copy(<<"z">>, 64),
    ?assertEqual(
        {error, hash},
        janus_fleet:validate_signal(?PEER_A, {cache_put, NotHex, <<"fast">>, <<"judge-m">>, 5000}, ctx())
    ),
    ?assertEqual(
        {error, hash},
        janus_fleet:validate_signal(?PEER_A, {cache_put, 123456, <<"fast">>, <<"judge-m">>, 5000}, ctx())
    ).

%%--------------------------------------------------------------------
%% WindowId rule (B2): pure bucket index; receivers accept the current
%% AND the previous bucket, older drops.
%%--------------------------------------------------------------------

window_id_test() ->
    ?assertEqual(10, janus_fleet:window_id(600, 60)),
    ?assertEqual(0, janus_fleet:window_id(59, 60)),
    ?assertEqual(0, janus_fleet:window_id(86399, 86400)),
    ?assertEqual(1, janus_fleet:window_id(86400, 86400)).

window_ok_test() ->
    ?assert(janus_fleet:window_ok(10, 10)),
    ?assert(janus_fleet:window_ok(10, 9)),
    ?assertNot(janus_fleet:window_ok(10, 8)),
    ?assertNot(janus_fleet:window_ok(10, 11)).

%%--------------------------------------------------------------------
%% cache_put first_seen replay bound (B2 / rev 11): a replay may
%% extend an entry by at most one TTL; expires_at <= first_seen + 2xTTL.
%%--------------------------------------------------------------------

cache_put_first_seen_bound_test() ->
    Now = 1_000_000,
    %% Fresh entry: full TTL from now, GC at first_seen + 2xTTL + 60s.
    {ok, Exp1, Fs1, Gc1} = janus_fleet:cache_put_expiry(none, 30000, Now),
    ?assertEqual(Now + 30000, Exp1),
    ?assertEqual(Now, Fs1),
    ?assertEqual(Now + 60000 + 60000, Gc1),
    %% Early replay (t=+10s): extends to now+TTL (still inside the
    %% first lifetime, one-TTL extension max).
    {ok, Exp2, Fs2, Gc2} = janus_fleet:cache_put_expiry({Fs1, Exp1}, 30000, Now + 10000),
    ?assertEqual(Fs1, Fs2),
    ?assertEqual(Now + 10000 + 30000, Exp2),
    ?assertEqual(Gc1, Gc2),
    %% Late replay (t=+40s): now+TTL would exceed the bound, so the
    %% expiry clamps at first_seen + 2xTTL.
    {ok, Exp3, Fs3, _} = janus_fleet:cache_put_expiry({Fs1, Exp1}, 30000, Now + 40000),
    ?assertEqual(Fs1, Fs3),
    ?assertEqual(Now + 60000, Exp3),
    %% Replay past the bound (now > first_seen + TTL): the entry cannot
    %% be resurrected — the bound is exhausted (tombstone semantics).
    expired = janus_fleet:cache_put_expiry({Fs1, Exp1}, 30000, Now + 61000).

%%--------------------------------------------------------------------
%% Wire hash codec (B2): local phash2 key <-> 64-hex digest on the wire.
%%--------------------------------------------------------------------

wire_hash_roundtrip_test() ->
    [begin
        Wire = janus_fleet:hash_to_wire(N),
        ?assertEqual(64, byte_size(Wire)),
        ?assertEqual(N, janus_fleet:wire_to_hash(Wire))
    end || N <- [0, 1, 42, 268435455, 123456789012345678901234567890]].

wire_hash_zero_is_zero_padded_test() ->
    ?assertEqual(
        binary:copy(<<"0">>, 64), janus_fleet:hash_to_wire(0)
    ).

%%--------------------------------------------------------------------
%% Quota publish set (B2): top-32 hottest >= 50%, one row per key (the
%% payload tuple carries no kind field, so the hottest kind wins),
%% 2-eval hysteresis on the 80% crossing, per-cycle cap 32.
%%--------------------------------------------------------------------

quota_meta(Id, Rpm, Tpm, Daily) ->
    #{id => Id, rpm_limit => Rpm, tpm_limit => Tpm, daily_token_limit => Daily}.

quota_publish_set_filters_below_half_test() ->
    Usage = #{1 => {5, 0, 0}, 2 => {4, 0, 0}},
    Metas = [quota_meta(1, 10, null, null), quota_meta(2, 10, null, null)],
    {Rows, _} = janus_fleet:quota_publish_set(Usage, Metas, #{}, 600),
    %% key 1 at 50% in, key 2 at 40% out
    [{quota, 1, 10, 60, {5, 10}, 6000}] = Rows.

quota_publish_set_hottest_kind_only_test() ->
    %% Same key hot on rpm (90%) and tpm (60%): one row, the hotter kind.
    Usage = #{1 => {9, 600, 0}},
    Metas = [quota_meta(1, 10, 1000, null)],
    {[{quota, 1, W, 60, {9, 10}, 6000}], _} = janus_fleet:quota_publish_set(Usage, Metas, #{}, 600),
    ?assertEqual(10, W).

quota_publish_set_unlimited_and_zero_limits_skipped_test() ->
    %% null = unlimited (never pressure); 0 = hard block, no row (the
    %% payload requires Limit > 0 and a blocked key is policy, not heat).
    Usage = #{1 => {50, 0, 0}, 2 => {7, 0, 0}},
    Metas = [quota_meta(1, null, null, null), quota_meta(2, 0, null, null)],
    {Rows, _} = janus_fleet:quota_publish_set(Usage, Metas, #{}, 600),
    ?assertEqual([], Rows).

quota_publish_set_daily_window_test() ->
    Usage = #{1 => {0, 0, 500000}},
    Metas = [quota_meta(1, null, null, 1000000)],
    {[{quota, 1, 0, 86400, {500000, 1000000}, 6000}], _} =
        janus_fleet:quota_publish_set(Usage, Metas, #{}, 600).

quota_publish_set_top32_cap_test() ->
    N = 50,
    %% Usage/limit ratios all >= 50% (pct = 50*I with limit 2).
    Usage = maps:from_list([{I, {I, 0, 0}} || I <- lists:seq(1, N)]),
    Metas = [quota_meta(I, 2, null, null) || I <- lists:seq(1, N)],
    {Rows, _} = janus_fleet:quota_publish_set(Usage, Metas, #{}, 600),
    ?assertEqual(32, length(Rows)),
    %% Hottest first: the top-32 ratios sorted descending.
    Ids = [Id || {quota, Id, _, _, _, _} <- Rows],
    ?assertEqual(lists:seq(N, N - 31, -1), Ids).

quota_publish_set_edge_latch_priority_test() ->
    %% 33 keys >= 50%: key 1 just crossed 80% (2nd consecutive eval) but
    %% is colder than 32 others — the edge latch still publishes it.
    N = 34,
    Usage = maps:from_list([{1, {81, 0, 0}}] ++ [{I, {90, 0, 0}} || I <- lists:seq(2, N)]),
    Metas = [quota_meta(I, 100, null, null) || I <- lists:seq(1, N)],
    PrevHigh = #{1 => 1},
    {Rows, NewHigh} = janus_fleet:quota_publish_set(Usage, Metas, PrevHigh, 600),
    ?assertEqual(32, length(Rows)),
    ?assert(lists:member(1, [Id || {quota, Id, _, _, _, _} <- Rows])),
    ?assertEqual(2, maps:get(1, NewHigh)),
    %% A key whose high state already announced (prev >= 2) is not edge.
    {Rows2, _} = janus_fleet:quota_publish_set(Usage, Metas, #{1 => 2}, 600),
    ?assertNot(lists:member(1, [Id || {quota, Id, _, _, _, _} <- Rows2])).

quota_publish_set_hysteresis_counts_test() ->
    Usage = #{1 => {85, 0, 0}},
    Metas = [quota_meta(1, 100, null, null)],
    {_, H1} = janus_fleet:quota_publish_set(Usage, Metas, #{}, 600),
    ?assertEqual(1, maps:get(1, H1)),
    {_, H2} = janus_fleet:quota_publish_set(Usage, Metas, H1, 600),
    ?assertEqual(2, maps:get(1, H2)),
    %% Below 80% resets the streak.
    Usage2 = #{1 => {70, 0, 0}},
    {_, H3} = janus_fleet:quota_publish_set(Usage2, Metas, H2, 600),
    ?assertEqual(false, maps:is_key(1, H3)).

quota_publish_set_daily_boundary_test() ->
    %% epoch 86399 with a 60 s window -> bucket 1439.
    Usage = #{1 => {5, 0, 0}},
    Metas = [quota_meta(1, 10, null, null)],
    {[{quota, 1, 1439, 60, {5, 10}, 6000}], _} =
        janus_fleet:quota_publish_set(Usage, Metas, #{}, 86399).

%%--------------------------------------------------------------------
%% Connector backoff (Part A): exponential with jitter, capped at 5 min.
%%--------------------------------------------------------------------

backoff_test() ->
    ?assertEqual(1000, janus_fleet:backoff_ms(1, 0)),
    ?assertEqual(2000, janus_fleet:backoff_ms(2, 0)),
    ?assertEqual(8000, janus_fleet:backoff_ms(4, 0)),
    ?assertEqual(256000, janus_fleet:backoff_ms(9, 0)),
    %% Caps at 5 min from attempt 10 on, forever (retry-then-log-only).
    ?assertEqual(300000, janus_fleet:backoff_ms(10, 0)),
    ?assertEqual(300000, janus_fleet:backoff_ms(100, 0)),
    ?assertEqual(1007, janus_fleet:backoff_ms(1, 7)),
    ?assert(janus_fleet:backoff_ms(1, 999999) >= 1000).

%%--------------------------------------------------------------------
%% Peer parsing (Part A env contract).
%%--------------------------------------------------------------------

parse_peers_test() ->
    ?assertEqual(
        ['janus@a.example', 'janus@b.example'],
        janus_fleet:parse_peers("janus@a.example,janus@b.example")
    ),
    ?assertEqual([], janus_fleet:parse_peers(false)),
    ?assertEqual([], janus_fleet:parse_peers("")),
    ?assertEqual([], janus_fleet:parse_peers(",, ")),
    ?assertEqual(
        ['janus@c.example'], janus_fleet:parse_peers(" janus@c.example ,")
    ).

%%--------------------------------------------------------------------
%% Live gen_server ingress: real mirror tables, real validation path.
%%--------------------------------------------------------------------

boot_fleet(Peers) ->
    os:putenv("JANUS_FLEET_PEERS", Peers),
    persistent_term:put({janus, fleet_enabled}, true),
    {ok, Pid} = janus_fleet:start_link(),
    Pid.

stop_fleet(Pid) ->
    gen_server:stop(Pid),
    persistent_term:put({janus, fleet_enabled}, false),
    os:unsetenv("JANUS_FLEET_PEERS"),
    ok.

sync(Pid) ->
    ok = gen_server:call(Pid, ping, 1000).

live_ingest_cool_test() ->
    Pid = boot_fleet("janus_test_a@host,janus_test_b@host"),
    try
        Target = {route, 7, 3},
        gen_server:cast(janus_fleet, {janus_fleet, 1, {lb_cool, Target, 5000, {http, 503}}, ?PEER_A}),
        sync(Pid),
        ?assert(janus_fleet:remote_cooling(Target)),
        ?assertNot(janus_fleet:remote_cooling({route, 8, 3})),
        %% Bad sender dropped + counted, never touches the mirror.
        gen_server:cast(janus_fleet, {janus_fleet, 1, {lb_cool, {route, 9, 3}, 5000, x}, ?SELF}),
        sync(Pid),
        ?assertNot(janus_fleet:remote_cooling({route, 9, 3})),
        C = janus_fleet:counters(),
        ?assertEqual(1, maps:get(bad_ingress, C, 0)),
        ?assertEqual(2, maps:get(signals_rx, C, 0))
    after
        stop_fleet(Pid)
    end.

live_recovered_scopes_to_sender_test() ->
    Pid = boot_fleet("janus_test_a@host,janus_test_b@host"),
    try
        T = {route, 7, 3},
        gen_server:cast(janus_fleet, {janus_fleet, 1, {lb_cool, T, 60000, x}, ?PEER_A}),
        gen_server:cast(janus_fleet, {janus_fleet, 1, {lb_cool, T, 60000, x}, ?PEER_B}),
        sync(Pid),
        ?assert(janus_fleet:remote_cooling(T)),
        %% Peer A retracts only its own row; B's row keeps the target cool.
        gen_server:cast(janus_fleet, {janus_fleet, 1, {lb_recovered, T}, ?PEER_A}),
        sync(Pid),
        ?assert(janus_fleet:remote_cooling(T)),
        gen_server:cast(janus_fleet, {janus_fleet, 1, {lb_recovered, T}, ?PEER_B}),
        sync(Pid),
        ?assertNot(janus_fleet:remote_cooling(T))
    after
        stop_fleet(Pid)
    end.

live_cool_purge_removes_all_senders_test() ->
    Pid = boot_fleet("janus_test_a@host,janus_test_b@host"),
    try
        T = {route, 7, 3},
        gen_server:cast(janus_fleet, {janus_fleet, 1, {lb_cool, T, 60000, x}, ?PEER_A}),
        gen_server:cast(janus_fleet, {janus_fleet, 1, {lb_cool, T, 60000, x}, ?PEER_B}),
        sync(Pid),
        gen_server:cast(janus_fleet, {janus_fleet, 1, {lb_cool_purge, T}, ?PEER_A}),
        sync(Pid),
        ?assertNot(janus_fleet:remote_cooling(T))
    after
        stop_fleet(Pid)
    end.

live_ttl_expiry_test() ->
    Pid = boot_fleet("janus_test_a@host"),
    try
        T = {route, 7, 3},
        gen_server:cast(janus_fleet, {janus_fleet, 1, {lb_cool, T, 1, x}, ?PEER_A}),
        sync(Pid),
        ?assert(janus_fleet:remote_cooling(T)),
        timer:sleep(50),
        %% Expiry is on the receiver's monotonic clock (lazy on read).
        ?assertNot(janus_fleet:remote_cooling(T))
    after
        stop_fleet(Pid)
    end.

live_upsert_one_row_per_sender_test() ->
    Pid = boot_fleet("janus_test_a@host"),
    try
        T = {route, 7, 3},
        [gen_server:cast(janus_fleet, {janus_fleet, 1, {lb_cool, T, 60000, x}, ?PEER_A})
         || _ <- lists:seq(1, 5)],
        sync(Pid),
        ?assertMatch([_], ets:lookup(janus_fleet_remote_cool, T))
    after
        stop_fleet(Pid)
    end.

live_quota_window_gate_test() ->
    Pid = boot_fleet("janus_test_a@host"),
    try
        W = janus_fleet:window_id(erlang:system_time(second), 60),
        gen_server:cast(janus_fleet, {janus_fleet, 1, {quota, 42, W, 60, {9, 10}, 6000}, ?PEER_A}),
        sync(Pid),
        ?assertMatch([_], ets:lookup(janus_fleet_remote_quota, {42, W})),
        %% Ancient bucket dropped.
        gen_server:cast(janus_fleet, {janus_fleet, 1, {quota, 42, W - 5, 60, {9, 10}, 6000}, ?PEER_A}),
        sync(Pid),
        ?assertMatch([_], ets:lookup(janus_fleet_remote_quota, {42, W}))
    after
        stop_fleet(Pid)
    end.

live_nodedown_purges_signal_mirrors_not_cache_test() ->
    Pid = boot_fleet("janus_test_a@host"),
    try
        T = {route, 7, 3},
        gen_server:cast(janus_fleet, {janus_fleet, 1, {lb_cool, T, 60000, x}, ?PEER_A}),
        gen_server:cast(janus_fleet, {janus_fleet, 1, {lb_lat, T, degraded, 5000, 9, 15000}, ?PEER_A}),
        sync(Pid),
        Pid ! {nodedown, ?PEER_A},
        sync(Pid),
        ?assertNot(janus_fleet:remote_cooling(T)),
        ?assertEqual([], janus_fleet:remote_lat_rows(T))
    after
        stop_fleet(Pid)
    end.

live_cache_put_dropped_without_judge_test() ->
    %% janus_auto lives in janus_http — absent under janus_core eunit,
    %% so the JudgeModel-match drop path is the observable behavior.
    Pid = boot_fleet("janus_test_a@host"),
    try
        Hash = janus_fleet:hash_to_wire(424242),
        gen_server:cast(
            janus_fleet,
            {janus_fleet, 1, {cache_put, Hash, <<"fast">>, <<"judge-m">>, 300000}, ?PEER_A}
        ),
        sync(Pid),
        ?assertMatch([], ets:lookup(janus_fleet_remote_cache, Hash)),
        ?assertEqual(1, maps:get(bad_ingress, janus_fleet:counters(), 0))
    after
        stop_fleet(Pid)
    end.

status_reports_counters_and_mirrors_test() ->
    Pid = boot_fleet("janus_test_a@host"),
    try
        T = {route, 7, 3},
        gen_server:cast(janus_fleet, {janus_fleet, 1, {lb_cool, T, 60000, x}, ?PEER_A}),
        sync(Pid),
        S = janus_fleet:status(),
        ?assertEqual(up, maps:get(status, S)),
        ?assertEqual(1, maps:get(signals_rx, S)),
        ?assertMatch(#{cool := 1}, maps:get(mirror_sizes, S)),
        [Row] = maps:get(mirrors, S),
        ?assertEqual(?PEER_A, maps:get(sender, Row)),
        ?assertEqual(cool, maps:get(kind, Row)),
        ?assert(is_integer(maps:get(expires_in_ms, Row)))
    after
        stop_fleet(Pid)
    end.
