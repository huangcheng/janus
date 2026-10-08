%%%-------------------------------------------------------------------
%%% @doc Native Erlang distribution for fleet runtime signals (spec
%%% docs/superpowers/plans/2026-10-08-native-distribution.md rev 11,
%%% Parts A/B/B2/F.2 — gateway side).
%%%
%%% Owns the signal mirrors (remote cooldowns, latency verdicts, quota
%%% rows, shared judge decision-cache entries), the pg membership
%%% broadcast, the static-peer connector loop, the 5 s leader-lease
%%% tick, and the 2 s quota heartbeat. Architecture boundary: the
%%% distribution carries ONLY advisory, self-expiring signals; local
%%% request-path evidence always wins; the cluster being down,
%%% partitioned, or disabled is indistinguishable from single-node
%%% behavior.
%%%
%%% Failure-mode discipline (spec Part 0):
%%% - TTL expiry on the receiver's monotonic clock is the correctness
%%%   mechanism; eager delete on nodedown is an optimization.
%%% - init/1 is crash-free by construction: any misconfig yields an
%%%   idle standalone state plus an error log, never an init crash.
%%% - Mirror reads go through the tolerant helpers below (missing
%%%   table == empty), so a parked janus_fleet can never badarg the
%%%   janus_lb pick path.
%%% - Egress is cast-only, knob-checked via persistent_term first,
%%%   self-excluded (node/1 based — publish/1 runs in caller
%%%   processes).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_fleet).
-behaviour(gen_server).

%% Knob + read helpers — safe before/without the gen_server.
-export([
    init_knob/0,
    enabled/0,
    peers/0,
    publish/1,
    bump/1,
    %% Read-path consults (janus_lb pick + /stats + /metrics).
    remote_cooling/1,
    remote_cooling/2,
    remote_lat_rows/1,
    remote_lat_rows/2,
    status/0,
    counters/0,
    record_command/2,
    %% Local mirror mutations (edge-triggered from janus_lb hooks and
    %% the fleet command originator — direct, eventual-free).
    local_success_clear/1,
    local_cool_purge/1,
    %% Pure logic, eunit-first (see test/janus_fleet_tests.erl).
    validate_signal/3,
    clamp_ttl/2,
    window_id/2,
    window_ok/2,
    cache_put_expiry/3,
    quota_publish_set/4,
    backoff_ms/2,
    parse_peers/1,
    hash_to_wire/1,
    wire_to_hash/1
]).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("janus_lb.hrl").
-include_lib("kernel/include/file.hrl").

-define(SERVER, ?MODULE).
-define(PG_SCOPE, janus_fleet_pg).
-define(PG_GROUP, janus_fleet).
%% Mirror tables (all named + public; reads tolerate absence).
-define(COOL, janus_fleet_remote_cool).
-define(LAT, janus_fleet_remote_lat).
-define(QUOTA, janus_fleet_remote_quota).
-define(CACHE, janus_fleet_remote_cache).
-define(STATE, janus_fleet_state).
-define(COUNTERS, janus_fleet_counters).
-define(SENDERROWS, janus_fleet_sender_rows).
-define(RING, janus_fleet_cmd_ring).
%% TTL classes (Part 0.2): generic signals 30 s; cache_put its own
%% 300 s class — the generic clamp must not apply to it.
-define(TTL_SIGNAL_MAX_MS, 30000).
-define(TTL_CACHE_MAX_MS, 300000).
-define(CACHE_GC_GRACE_MS, 60000).
%% Sweeper / lease / quota heartbeat cadence.
-define(SWEEP_MS, 30000).
-define(LEASE_TICK_MS, 5000).
-define(QUOTA_TICK_MS, 2000).
-define(QUOTA_TTL_MS, 6000).
-define(QUOTA_TOP_N, 32).
-define(QUOTA_MIN_RATIO_PCT, 50).
-define(QUOTA_HIGH_RATIO_PCT, 80).
%% Per-sender row caps (rev 11: the 8 192/sender cap is AGGREGATE
%% across ALL signal mirrors; cache_put has its own 4 096 class).
-define(SENDER_SIGNAL_CAP, 8192).
-define(SENDER_CACHE_CAP, 4096).
%% Ingress byte clamps (rev 10).
-define(MAX_TARGET_EXT_BYTES, 512).
-define(MAX_CLASS_EXT_BYTES, 128).
-define(MAX_AGENT_KEY_BYTES, 128).
-define(MAX_TIER_BYTES, 32).
-define(MAX_JUDGE_BYTES, 256).
%% Connector backoff: exponential with jitter, capped at 5 min, then
%% retry forever (log-only) at the cap.
-define(BACKOFF_BASE_MS, 1000).
-define(BACKOFF_CAP_MS, 300000).
-define(CMD_RING_SIZE, 20).
%% knob persistent_term key — written by init_knob/0 from env BEFORE
%% janus_core_sup builds its child list; hook paths read only this.
-define(KNOB_PT, {janus, fleet_enabled}).
%% cert_days_remaining PT cache: {mtime, days} guarded by file mtime —
%% no per-request disk I/O (Part A read path).
-define(CERT_PT, {janus, fleet_cert_age}).

-record(state, {
    peers = [] :: [node()],
    self :: node(),
    %% connector attempt counter per peer (backoff exponent)
    attempts = #{} :: #{node() => pos_integer()},
    %% quota 80% hysteresis: agent-key id -> consecutive >= 80% evals
    quota_high = #{} :: #{term() => non_neg_integer()},
    last_drop_log = 0 :: integer()
}).

%%%===================================================================
%%% Knob + boot bridge (Part 0.1)
%%%===================================================================

%% @doc Env -> persistent_term bridge, called from janus_core_app
%% start BEFORE janus_core_sup builds its child list (the child-list
%% condition reads the env var directly; hook-path knob checks read
%% only the PT key).
-spec init_knob() -> ok.
init_knob() ->
    _ = persistent_term:put(?KNOB_PT, env_truthy(os:getenv("JANUS_FLEET_ENABLED"))),
    ok.

-spec enabled() -> boolean().
enabled() ->
    try
        persistent_term:get(?KNOB_PT, false)
    catch
        _:_ -> false
    end.

env_truthy(false) -> false;
env_truthy("") -> false;
env_truthy(Val) when is_list(Val) ->
    lists:member(string:lowercase(Val), ["1", "true", "yes", "on"]);
env_truthy(_) -> false.

%%%===================================================================
%%% Pure logic (eunit-first)
%%%===================================================================

%% TTL classes: positive integers clamped to the class maximum.
-spec clamp_ttl(term(), signal | cache) -> pos_integer() | {error, ttl}.
clamp_ttl(TtlMs, signal) when is_integer(TtlMs), TtlMs > 0 ->
    min(TtlMs, ?TTL_SIGNAL_MAX_MS);
clamp_ttl(TtlMs, cache) when is_integer(TtlMs), TtlMs > 0 ->
    min(TtlMs, ?TTL_CACHE_MAX_MS);
clamp_ttl(_, _) ->
    {error, ttl}.

-spec parse_peers(false | string()) -> [node()].
parse_peers(Env) when is_list(Env) ->
    Names = [string:trim(P) || P <- string:split(Env, ",", all)],
    [list_to_atom(N) || N <- Names, N =/= []];
parse_peers(_) ->
    [].

-spec window_id(non_neg_integer(), pos_integer()) -> non_neg_integer().
window_id(EpochSec, WindowSec) when is_integer(WindowSec), WindowSec >= 1 ->
    EpochSec div WindowSec.

%% Receivers accept the CURRENT and the PREVIOUS bucket (bucket-boundary
%% races make a strict match flicker at the edge); older drops.
-spec window_ok(non_neg_integer(), non_neg_integer()) -> boolean().
window_ok(RecvWindow, WireWindow) ->
    RecvWindow =:= WireWindow orelse RecvWindow - 1 =:= WireWindow.

%% cache_put replay bound (B2/rev 11): a replayed entry may be extended
%% to at most first_seen + 2xTTL; past that the row is a tombstone
%% (GC'd at first_seen + 2xTTL + 60 s grace by the sweeper).
-spec cache_put_expiry
    (none, pos_integer(), integer()) -> {ok, ExpiresAt :: integer(), FirstSeen :: integer(), GcAt :: integer()};
    ({integer(), integer()}, pos_integer(), integer()) ->
        {ok, integer(), integer(), integer()} | expired.
cache_put_expiry(none, TtlMs, Now) ->
    {ok, Now + TtlMs, Now, Now + 2 * TtlMs + ?CACHE_GC_GRACE_MS};
cache_put_expiry({FirstSeen, _PrevExpires}, TtlMs, Now) ->
    Bound = FirstSeen + 2 * TtlMs,
    Expires = min(Now + TtlMs, Bound),
    case Expires > Now of
        true -> {ok, Expires, FirstSeen, Bound + ?CACHE_GC_GRACE_MS};
        false -> expired
    end.

%% Wire hash codec (B2): the local decision-cache key is a phash2
%% integer; the wire hash is an exact 64-hex-char digest (rev 10
%% ingress rule). 256-bit fixed-width big-endian keeps the round-trip
%% lossless so a receiver's local cache serves the same hash.
-spec hash_to_wire(non_neg_integer()) -> binary().
hash_to_wire(Int) when is_integer(Int), Int >= 0 ->
    Pad = 32 - byte_size(binary:encode_unsigned(Int)),
    binary:encode_hex(<<0:(Pad * 8), (binary:encode_unsigned(Int))/binary>>).

-spec wire_to_hash(binary()) -> non_neg_integer().
wire_to_hash(Bin) when is_binary(Bin), byte_size(Bin) =:= 64 ->
    binary:decode_unsigned(binary:decode_hex(Bin)).

%% Connector backoff: base 1 s doubling per attempt plus jitter,
%% capped at 5 min (retry continues forever at the cap, log-only).
-spec backoff_ms(pos_integer(), non_neg_integer()) -> pos_integer().
backoff_ms(Attempt, JitterMs) when Attempt >= 1, JitterMs >= 0 ->
    min(?BACKOFF_BASE_MS bsl min(Attempt - 1, 12) + JitterMs, ?BACKOFF_CAP_MS).

%% Ingress validation (Part 0.6d/0.7): exact tuple shapes, claimed
%% sender in the configured peer set and not self, TTL clamped to its
%% class, byte-clamped targets/keys/hashes. Total: never raises.
-spec validate_signal(term(), term(), #{peers => [node()], self => node()}) ->
    {ok, map()} | {error, atom()}.
validate_signal(Sender, Payload, #{peers := Peers, self := Self}) ->
    case
        is_atom(Sender) andalso Sender =/= Self andalso lists:member(Sender, Peers)
    of
        false ->
            {error, sender};
        true ->
            validate_payload(Payload)
    end.

validate_payload({lb_cool, Target, TtlMs, Class}) ->
    with_target(Target, fun(T) ->
        with_ttl(TtlMs, signal, fun(Ttl) ->
            with_class(Class, fun(C) ->
                {ok, #{kind => lb_cool, target => T, ttl_ms => Ttl, class => C}}
            end)
        end)
    end);
validate_payload({lb_recovered, Target}) ->
    with_target(Target, fun(T) -> {ok, #{kind => lb_recovered, target => T}} end);
validate_payload({lb_lat, Target, Verdict, EwmaMs, Samples, TtlMs}) ->
    with_target(Target, fun(T) ->
        case Verdict =:= degraded orelse Verdict =:= healthy of
            false ->
                {error, shape};
            true ->
                case
                    is_integer(EwmaMs) andalso EwmaMs >= 0 andalso EwmaMs =< 3_600_000 andalso
                        is_integer(Samples) andalso Samples >= 0 andalso Samples =< 1_000_000
                of
                    false ->
                        {error, shape};
                    true ->
                        with_ttl(TtlMs, signal, fun(Ttl) ->
                            {ok, #{
                                kind => lb_lat,
                                target => T,
                                verdict => Verdict,
                                ewma_ms => EwmaMs,
                                samples => Samples,
                                ttl_ms => Ttl
                            }}
                        end)
                end
        end
    end);
validate_payload({lb_cool_purge, Target}) ->
    with_target(Target, fun(T) -> {ok, #{kind => lb_cool_purge, target => T}} end);
validate_payload({quota, AgentKeyId, WindowId, WindowSec, {Used, Limit}, TtlMs}) ->
    case valid_agent_key(AgentKeyId) of
        false ->
            {error, agent_key};
        true ->
            case
                is_integer(WindowId) andalso WindowId >= 0 andalso
                    is_integer(WindowSec) andalso WindowSec >= 60 andalso
                    is_integer(Used) andalso Used >= 0 andalso
                    is_integer(Limit) andalso Limit > 0
            of
                false ->
                    {error, shape};
                true ->
                    with_ttl(TtlMs, signal, fun(Ttl) ->
                        {ok, #{
                            kind => quota,
                            agent_key_id => AgentKeyId,
                            window_id => WindowId,
                            window_sec => WindowSec,
                            used => Used,
                            limit => Limit,
                            ttl_ms => Ttl
                        }}
                    end)
            end
    end;
validate_payload({cache_put, Hash, Tier, JudgeModel, TtlMs}) ->
    case is_hex64(Hash) of
        false ->
            {error, hash};
        true ->
            case
                is_binary(Tier) andalso byte_size(Tier) =< ?MAX_TIER_BYTES andalso
                    is_binary(JudgeModel) andalso byte_size(JudgeModel) =< ?MAX_JUDGE_BYTES
            of
                false ->
                    {error, shape};
                true ->
                    with_ttl(TtlMs, cache, fun(Ttl) ->
                        {ok, #{
                            kind => cache_put, hash => Hash, tier => Tier,
                            judge_model => JudgeModel, ttl_ms => Ttl
                        }}
                    end)
            end
    end;
validate_payload(_Other) ->
    {error, shape}.

with_target(Target, K) ->
    case bounded_term(Target, ?MAX_TARGET_EXT_BYTES) of
        true -> K(Target);
        false -> {error, target}
    end.

with_class(Class, K) ->
    case bounded_term(Class, ?MAX_CLASS_EXT_BYTES) of
        true -> K(Class);
        false -> {error, class}
    end.

with_ttl(TtlMs, Class, K) ->
    case clamp_ttl(TtlMs, Class) of
        {error, ttl} -> {error, ttl};
        Ttl -> K(Ttl)
    end.

bounded_term(Term, MaxBytes) ->
    try
        erlang:external_size(Term) =< MaxBytes
    catch
        _:_ -> false
    end.

valid_agent_key(Id) when is_integer(Id) -> true;
valid_agent_key(Bin) when is_binary(Bin) -> byte_size(Bin) =< ?MAX_AGENT_KEY_BYTES;
valid_agent_key(_) -> false.

is_hex64(Bin) when is_binary(Bin), byte_size(Bin) =:= 64 ->
    case catch binary:decode_hex(Bin) of
        B when is_binary(B) -> true;
        _ -> false
    end;
is_hex64(_) ->
    false.

%% Quota publish set (B2): per 2 s cycle, for every agent key with a
%% finite limit, the hottest kind (highest Used/Limit ratio) is a
%% candidate when >= 50%; edge-latched keys (2 consecutive >= 80%
%% evaluations that were NOT announced before) lead the list; the
%% per-cycle cap is 32 rows total. The payload tuple carries no kind
%% field, so one row per key is the only shape that keeps the
%% per-(sender,key,window) upsert single-row.
-spec quota_publish_set(
    Usage :: #{term() => {Rpm :: non_neg_integer(), Tpm :: non_neg_integer(), Daily :: non_neg_integer()}},
    Metas :: [map()],
    PrevHigh :: #{term() => non_neg_integer()},
    NowSec :: non_neg_integer()
) -> {[tuple()], #{term() => non_neg_integer()}}.
quota_publish_set(Usage, Metas, PrevHigh, NowSec) when is_map(Usage), is_list(Metas) ->
    Candidates = [C || Meta <- Metas, C <- [key_candidate(Meta, Usage)], C =/= none],
    NewHigh = high_state(Candidates, PrevHigh),
    EdgeIds = sets:from_list(edge_ids(Candidates, NewHigh, PrevHigh), [{version, 2}]),
    {Edge, Rest} = lists:partition(fun({Id, _, _, _, _}) -> sets:is_element(Id, EdgeIds) end, Candidates),
    ByPctDesc = fun({_, _, P1, _, _}, {_, _, P2, _, _}) -> P1 >= P2 end,
    %% Edge-latched keys lead (crossing 80% publishes even when crowded
    %% out by hotter keys), each group hottest-first; the cap bounds the
    %% total per cycle.
    Ordered = lists:sublist(lists:sort(ByPctDesc, Edge) ++ lists:sort(ByPctDesc, Rest), ?QUOTA_TOP_N),
    Rows = [
        {quota, Id, window_id(NowSec, window_sec(Kind)), window_sec(Kind), {Used, Limit}, ?QUOTA_TTL_MS}
     || {Id, Kind, _Pct, Used, Limit} <- Ordered
    ],
    {Rows, NewHigh}.

key_candidate(Meta, Usage) when is_map(Meta) ->
    Id = maps:get(id, Meta, undefined),
    {Rpm, Tpm, Daily} = maps:get(Id, Usage, {0, 0, 0}),
    Kinds = [
        {rpm, Rpm, maps:get(rpm_limit, Meta, null)},
        {tpm, Tpm, maps:get(tpm_limit, Meta, null)},
        {daily, Daily, maps:get(daily_token_limit, Meta, null)}
    ],
    Scored = [
        {Kind, Pct, Used, Limit}
     || {Kind, Used, Limit} <- Kinds,
        is_integer(Limit),
        Limit > 0,
        Pct <- [Used * 100 div Limit],
        Pct >= ?QUOTA_MIN_RATIO_PCT
    ],
    case lists:reverse(lists:keysort(2, Scored)) of
        [{Kind, Pct, Used, Limit} | _] -> {Id, Kind, Pct, Used, Limit};
        [] -> none
    end;
key_candidate(_, _) ->
    none.

high_state(Candidates, PrevHigh) ->
    lists:foldl(
        fun({Id, _, Pct, _, _}, Acc) when Pct >= ?QUOTA_HIGH_RATIO_PCT ->
                Acc#{Id => maps:get(Id, PrevHigh, 0) + 1};
            ({Id, _, _, _, _}, Acc) ->
                maps:remove(Id, Acc)
        end,
        #{},
        Candidates
    ).

edge_ids(Candidates, NewHigh, PrevHigh) ->
    [Id || {Id, _, Pct, _, _} <- Candidates, Pct >= ?QUOTA_HIGH_RATIO_PCT, maps:get(Id, NewHigh, 0) >= 2, maps:get(Id, PrevHigh, 0) < 2].

window_sec(rpm) -> 60;
window_sec(tpm) -> 60;
window_sec(daily) -> 86400.

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Egress publish (Part A membership): knob-checked, cast-only,
%% self-excluded (node/1 based — this runs in caller processes such as
%% the janus_lb gen_server or request handlers).
-spec publish(term()) -> ok.
publish(Msg) ->
    case enabled() of
        true ->
            _ = [catch gen_server:cast(P, {janus_fleet, 1, Msg, node()}) || P <- members(), node(P) =/= node()],
            _ = bump(signals_tx),
            ok;
        false ->
            ok
    end.

%% @doc Configured peers (tolerant read — gen_server may be parked).
-spec peers() -> [node()].
peers() ->
    case tolerant_lookup(?STATE, peers) of
        [_, Ps] when is_list(Ps) -> Ps;
        _ -> []
    end.

%% @doc Counter bump (tolerant — counters live as long as the owner).
%% Keys are atoms or small tagged tuples (e.g. command outcomes).
-spec bump(atom() | tuple()) -> ok.
bump(Key) when is_atom(Key); is_tuple(Key) ->
    try
        _ = ets:update_counter(?COUNTERS, Key, 1, {Key, 0}),
        ok
    catch
        _:_ -> ok
    end.

-spec counters() -> map().
counters() ->
    try
        maps:from_list(ets:tab2list(?COUNTERS))
    catch
        _:_ -> #{}
    end.

%% @doc Remote-cool consult (Part B): any single live sender's
%% unexpired row marks the target cooling. Lazy-expires rows on read.
-spec remote_cooling(term()) -> boolean().
remote_cooling(Target) ->
    remote_cooling(Target, now_mono()).

-spec remote_cooling(term(), integer()) -> boolean().
remote_cooling(Target, Now) ->
    try ets:lookup(?COOL, Target) of
        Rows ->
            _ = [ets:delete_object(?COOL, R) || R <- Rows, element(3, R) =< Now],
            lists:any(fun(R) -> element(3, R) > Now end, Rows)
    catch
        _:_ -> false
    end.

%% @doc Unexpired remote latency rows: [{Sender, EwmaMs, Samples,
%% Verdict}] (lazy-expired on read).
-spec remote_lat_rows(term()) -> [{node(), integer(), non_neg_integer(), degraded | healthy}].
remote_lat_rows(Target) ->
    remote_lat_rows(Target, now_mono()).

-spec remote_lat_rows(term(), integer()) -> [{node(), integer(), non_neg_integer(), degraded | healthy}].
remote_lat_rows(Target, Now) ->
    try ets:lookup(?LAT, Target) of
        Rows ->
            _ = [ets:delete_object(?LAT, R) || R <- Rows, element(3, R) =< Now],
            [{S, E, N, V} || {_, S, Exp, E, N, V} <- Rows, Exp > Now]
    catch
        _:_ -> []
    end.

%% Local success edge (Part B consumption): a local success clears the
%% target's rows in BOTH remote mirrors — all senders' rows, so local
%% evidence wins literally. TTL-bounded eventual consistency under
%% racing ingress; direct (not a cast) so it also works while the
%% gen_server is briefly busy.
-spec local_success_clear(term()) -> ok.
local_success_clear(Target) ->
    ok = delete_target_rows(?COOL, Target),
    ok = delete_target_rows(?LAT, Target).

%% lb_cool_clear command originator: purge every sender's cool-row for
%% the target from the LOCAL mirror (the broadcast reaches peers).
-spec local_cool_purge(term()) -> ok.
local_cool_purge(Target) ->
    ok = delete_target_rows(?COOL, Target).

%% @doc Fleet status map (Part A read path + /stats.fleet + the
%% fleet_status command): direct ETS/pg reads, NEVER a gen_server call.
-spec status() -> map().
status() ->
    Now = now_mono(),
    #{
        status => fleet_proc_status(),
        nodes => member_nodes(),
        signals_tx => counter(signals_tx),
        signals_rx => counter(signals_rx),
        dropped_bad_ingress => counter(bad_ingress),
        remote_cool_last_resort => counter(remote_cool_last_resort),
        mirror_sizes => #{
            cool => table_size(?COOL),
            lat => table_size(?LAT),
            quota => table_size(?QUOTA),
            cache => table_size(?CACHE)
        },
        cert_days_remaining => cert_days_cached(),
        mirrors => mirror_rows(Now),
        quota_mirrors => quota_mirror_rows(Now),
        lease => lease_snapshot(Now),
        commands => ring_rows()
    }.

%% @doc Record an executed fleet command in the last-20 ring (audit).
-spec record_command(binary(), map()) -> ok.
record_command(Command, Results) when is_binary(Command), is_map(Results) ->
    try
        Seq = ets:update_counter(?COUNTERS, cmd_seq, 1, {cmd_seq, 0}),
        ets:insert(?RING, {Seq, #{
            ts => erlang:system_time(millisecond),
            command => Command,
            results => Results
        }}),
        trim_ring()
    catch
        _:_ -> ok
    end;
record_command(_, _) ->
    ok.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    Self = node(),
    Peers = lists:usort([P || P <- parse_peers(os:getenv("JANUS_FLEET_PEERS")), P =/= Self]),
    ok = ensure_tables(),
    _ = ets:insert(?STATE, {peers, Peers}),
    %% net_kernel:allow([]) would FORBID all nodes — only restrict when
    %% there is a real peer set (cert-backed at the dist handshake).
    case Peers of
        [] -> ok;
        _ -> log_catch(net_kernel_allow, fun() -> net_kernel:allow(Peers) end)
    end,
    ok = start_pg_scope(),
    log_catch(pg_join, fun() -> pg:join(?PG_SCOPE, ?PG_GROUP, self()) end),
    log_catch(monitor_nodes, fun() -> net_kernel:monitor_nodes(true) end),
    _ = [schedule_connect(P, 1, rand:uniform(500)) || P <- Peers],
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    _ = erlang:send_after(?LEASE_TICK_MS, self(), lease_tick),
    _ = erlang:send_after(?QUOTA_TICK_MS, self(), quota_tick),
    logger:info(#{what => janus_fleet_started, peers => Peers, self => Self}),
    {ok, #state{peers = Peers, self = Self}}.

handle_call(ping, _From, State) ->
    {reply, ok, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({janus_fleet, 1, Payload, Sender}, State) ->
    _ = bump(signals_rx),
    case catch validate_signal(Sender, Payload, #{peers => State#state.peers, self => State#state.self}) of
        {ok, Norm} ->
            %% Ingress runs in the single mirror-owner process.
            {noreply, apply_signal(Sender, Norm, State)};
        {error, Reason} ->
            {noreply, drop_signal(Sender, Reason, State)};
        {'EXIT', Reason} ->
            {noreply, drop_signal(Sender, {validator_crash, Reason}, State)}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sweep, State) ->
    ok = do_sweep(),
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, State};
handle_info(lease_tick, State) ->
    ok = recompute_lease(),
    _ = erlang:send_after(?LEASE_TICK_MS, self(), lease_tick),
    {noreply, State};
handle_info(quota_tick, State) ->
    {noreply, quota_heartbeat(State)};
handle_info({nodeup, Node}, State) ->
    logger:info(#{what => janus_fleet_nodeup, node => Node}),
    ok = recompute_lease(),
    {noreply, State#state{attempts = maps:remove(Node, State#state.attempts)}};
handle_info({nodedown, Node}, State) ->
    logger:info(#{what => janus_fleet_nodedown, node => Node}),
    %% Eager purge of the dead sender's rows from ALL signal mirrors
    %% (cache_put entries deliberately NOT purged — a departed peer's
    %% cached decisions stay valid; TTL <= 300 s is their bound). This
    %% lags net_ticktime; TTL expiry remains the correctness mechanism.
    ok = purge_sender(Node),
    ok = recompute_lease(),
    case lists:member(Node, State#state.peers) of
        true -> schedule_connect(Node, 1, rand:uniform(1000));
        false -> ok
    end,
    {noreply, State};
handle_info({connect_peer, Peer, Attempt}, State) ->
    case catch net_kernel:connect_node(Peer) of
        true ->
            %% nodeup logs and resets the attempt counter.
            {noreply, State};
        _Other ->
            Delay = backoff_ms(Attempt, rand:uniform(?BACKOFF_BASE_MS div 2)),
            _ =
                case Delay >= ?BACKOFF_CAP_MS of
                    true ->
                        %% Capped: keep retrying forever, log-only (rev 11).
                        logger:info(#{
                            what => janus_fleet_connect_retry_capped,
                            peer => Peer, delay_ms => Delay, attempt => Attempt
                        });
                    false ->
                        ok
                end,
            schedule_connect(Peer, Attempt + 1, Delay),
            {noreply, State#state{attempts = (State#state.attempts)#{Peer => Attempt + 1}}}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Ingress application
%%%===================================================================

apply_signal(Sender, #{kind := lb_cool, target := T, ttl_ms := Ttl, class := Class}, State) ->
    _ = upsert_signal_row(?COOL, T, Sender, {T, Sender, now_mono() + Ttl, Class}),
    State;
apply_signal(Sender, #{kind := lb_recovered, target := T}, State) ->
    %% A node retracts only its own signals (latency rows unaffected).
    ok = delete_sender_target_rows(?COOL, T, Sender),
    State;
apply_signal(Sender, #{kind := lb_lat, target := T, verdict := V, ewma_ms := E, samples := N, ttl_ms := Ttl}, State) ->
    _ = upsert_signal_row(?LAT, T, Sender, {T, Sender, now_mono() + Ttl, E, N, V}),
    State;
apply_signal(_Sender, #{kind := lb_cool_purge, target := T}, State) ->
    %% Operator override: every sender's cool-row for the target goes.
    ok = delete_target_rows(?COOL, T),
    State;
apply_signal(Sender, #{kind := quota, agent_key_id := Key, window_id := Wire, window_sec := WSec, used := Used, limit := Limit, ttl_ms := Ttl}, State) ->
    Recv = window_id(erlang:system_time(second), WSec),
    case window_ok(Recv, Wire) of
        true ->
            RowKey = {Key, Wire},
            _ = upsert_signal_row(?QUOTA, RowKey, Sender, {RowKey, Sender, now_mono() + Ttl, WSec, Used, Limit}),
            ok;
        false ->
            _ = bump(quota_window_drop)
    end,
    State;
apply_signal(Sender, #{kind := cache_put, hash := Hash, tier := Tier, judge_model := Judge, ttl_ms := TtlMs}, State) ->
    ok = apply_cache_put(Sender, Hash, Tier, Judge, TtlMs),
    State.

%% cache_put-specific rules on top of Part B validation (B2):
%% JudgeModel must equal the LOCAL configured judge (soft dependency —
%% janus_auto lives in janus_http), first_seen replay bound, own cap
%% class, then the receive-side write via the exported janus-auto API
%% (never cross-owner raw ETS).
apply_cache_put(Sender, Hash, Tier, Judge, TtlMs) ->
    case judge_model_local() of
        Judge ->
            TtlSec = max(1, TtlMs div 1000),
            Existing =
                case tolerant_lookup(?CACHE, Hash) of
                    [{Hash, PrevSender, _, _, PrevExpires, PrevFirstSeen, _}] when PrevSender =:= Sender ->
                        {PrevFirstSeen, PrevExpires};
                    _ ->
                        none
                end,
            Now = now_mono(),
            case cache_put_expiry(Existing, TtlSec * 1000, Now) of
                {ok, Expires, FirstSeen, GcAt} ->
                    case within_sender_cap(Sender, cache, ?SENDER_CACHE_CAP, Existing =/= none) of
                        true ->
                            _ = tolerant_delete(?CACHE, Hash),
                            _ = safe_insert(?CACHE, {Hash, Sender, Tier, Judge, Expires, FirstSeen, GcAt}),
                            case Existing of
                                none -> _ = sender_rows_bump(Sender, cache, +1);
                                _ -> ok
                            end,
                            ok;
                        false ->
                            _ = bump(cache_cap_drop)
                    end;
                expired ->
                    _ = bump(cache_replay_drop)
            end;
        _Other ->
            %% Rolling-deploy generation lag must not poison
            %% cross-version routing (F.8: visible in bad_ingress).
            _ = bump(bad_ingress)
    end.

judge_model_local() ->
    case code:ensure_loaded(janus_auto) of
        {module, JanusAuto} ->
            case erlang:function_exported(JanusAuto, judge_model, 0) of
                true -> catch JanusAuto:judge_model();
                false -> undefined
            end;
        {error, _} ->
            undefined
    end.

drop_signal(Sender, Reason, State) ->
    _ = bump(bad_ingress),
    Now = now_mono(),
    case Now - State#state.last_drop_log >= 1000 of
        true ->
            logger:warning(#{what => janus_fleet_ingress_drop, sender => Sender, reason => Reason}),
            State#state{last_drop_log = Now};
        false ->
            State
    end.

%%%===================================================================
%%% Mirror plumbing
%%%===================================================================

%% Per-(sender,target) upsert (Part B): delete the sender's prior row,
%% insert the new one; per-sender AGGREGATE cap 8 192 across all
%% signal mirrors, drop + count beyond.
upsert_signal_row(Tab, Key, Sender, NewRow) ->
    Prior = [R || R <- tolerant_lookup(Tab, Key), element(2, R) =:= Sender],
    _ = [ets:delete_object(Tab, R) || R <- Prior],
    case Prior of
        [_ | _] ->
            safe_insert(Tab, NewRow);
        [] ->
            case within_sender_cap(Sender, signal, ?SENDER_SIGNAL_CAP, false) of
                true ->
                    _ = sender_rows_bump(Sender, signal, +1),
                    safe_insert(Tab, NewRow);
                false ->
                    _ = bump(signal_cap_drop)
            end
    end.

delete_sender_target_rows(Tab, Key, Sender) ->
    Rows = [R || R <- tolerant_lookup(Tab, Key), element(2, R) =:= Sender],
    _ = [ets:delete_object(Tab, R) || R <- Rows],
    case Rows of
        [_ | _] -> _ = sender_rows_bump(Sender, signal, -1), ok;
        [] -> ok
    end.

delete_target_rows(Tab, Key) ->
    Rows = tolerant_lookup(Tab, Key),
    _ = [ets:delete_object(Tab, R) || R <- Rows],
    _ = [sender_rows_bump(element(2, R), signal_class(Tab), -1) || R <- Rows],
    ok.

signal_class(?CACHE) -> cache;
signal_class(_) -> signal.

purge_sender(Node) ->
    _ = purge_sender_rows(?COOL, Node),
    _ = purge_sender_rows(?LAT, Node),
    _ = purge_sender_rows(?QUOTA, Node),
    ok.

purge_sender_rows(Tab, Node) ->
    try
        Rows = [R || R <- ets:tab2list(Tab), element(2, R) =:= Node],
        _ = [ets:delete_object(Tab, R) || R <- Rows],
        _ = sender_rows_bump(Node, signal, -length(Rows))
    catch
        _:_ -> ok
    end.

within_sender_cap(Sender, Class, Cap, Replacing) ->
    Replacing orelse sender_rows(Sender, Class) < Cap.

sender_rows(Sender, Class) ->
    case tolerant_lookup(?SENDERROWS, {Class, Sender}) of
        [{_, N}] when is_integer(N) -> max(0, N);
        _ -> 0
    end.

sender_rows_bump(_Sender, _Class, 0) ->
    ok;
sender_rows_bump(Sender, Class, Delta) ->
    try
        %% Floor at zero (threshold form) so drift can never go negative.
        _ = ets:update_counter(?SENDERROWS, {Class, Sender}, {2, Delta, 0, 0}, {{Class, Sender}, 0}),
        ok
    catch
        _:_ -> ok
    end.

%% 30 s sweeper: delete expired rows even if never read; cache rows GC
%% at first_seen + 2xTTL + 60 s grace (tombstones); recount per-sender
%% row counters authoritatively (incremental drift self-corrects).
do_sweep() ->
    Now = now_mono(),
    ok = sweep_expired(?COOL, Now, fun(R) -> element(3, R) =< Now end),
    ok = sweep_expired(?LAT, Now, fun(R) -> element(3, R) =< Now end),
    ok = sweep_expired(?QUOTA, Now, fun(R) -> element(3, R) =< Now end),
    ok = sweep_expired(?CACHE, Now, fun(R) -> element(7, R) =< Now end),
    ok = recount_sender_rows().

sweep_expired(Tab, _Now, Pred) ->
    try
        Rows = [R || R <- ets:tab2list(Tab), Pred(R)],
        _ = [ets:delete_object(Tab, R) || R <- Rows]
    catch
        _:_ -> ok
    end.

recount_sender_rows() ->
    try
        Signal = count_by_sender([?COOL, ?LAT, ?QUOTA]),
        Cache = count_by_sender([?CACHE]),
        All = [{{signal, S}, N} || {S, N} <- maps:to_list(Signal)] ++
            [{{cache, S}, N} || {S, N} <- maps:to_list(Cache)],
        _ = ets:delete_all_objects(?SENDERROWS),
        _ = ets:insert(?SENDERROWS, All),
        ok
    catch
        _:_ -> ok
    end.

count_by_sender(Tabs) ->
    lists:foldl(
        fun(Tab, Acc) ->
            try
                lists:foldl(
                    fun(R, A) -> maps:update_with(element(2, R), fun(N) -> N + 1 end, 1, A) end,
                    Acc,
                    ets:tab2list(Tab)
                )
            catch
                _:_ -> Acc
            end
        end,
        #{},
        Tabs
    ).

%%%===================================================================
%%% Lease (F.2): holder = lowest node name among live pg members;
%%% tick-based failover (nodedown accelerates, never the mechanism).
%%%===================================================================

recompute_lease() ->
    Nodes = lists:usort([node() | member_nodes()]),
    Holder =
        case Nodes of
            [] -> undefined;
            _ -> hd(Nodes)
        end,
    try
        true = ets:insert(?STATE, [
            {lease_holder, Holder},
            {lease_next_tick, now_mono() + ?LEASE_TICK_MS}
        ])
    catch
        _:_ -> ok
    end,
    ok.

lease_snapshot(Now) ->
    Holder = tolerant_lookup(?STATE, lease_holder),
    Next =
        case tolerant_lookup(?STATE, lease_next_tick) of
            [{_, T}] when is_integer(T) -> max(0, T - Now);
            _ -> 0
        end,
    #{
        holder =>
            case Holder of
                [{_, H}] when is_atom(H) -> H;
                _ -> null
            end,
        next_check_in_ms => Next
    }.

%%%===================================================================
%%% Quota heartbeat (B2): 2 s coalesced, top-32 hottest >= 50%,
%% advisory-only (the pick path never consults ?QUOTA).
%%%===================================================================

quota_heartbeat(State) ->
    Usage = soft_map(fun janus_quota:current_usage/0),
    Metas = soft_list(fun janus_catalog:api_keys/0),
    {Rows, NewHigh} = quota_publish_set(Usage, Metas, State#state.quota_high, erlang:system_time(second)),
    _ = [publish(R) || R <- Rows],
    State#state{quota_high = NewHigh}.

soft_map(Fun) ->
    case catch Fun() of
        M when is_map(M) -> M;
        _ -> #{}
    end.

soft_list(Fun) ->
    case catch Fun() of
        L when is_list(L) -> L;
        _ -> []
    end.

%%%===================================================================
%%% Status read path helpers (never gen_server calls)
%%%===================================================================

fleet_proc_status() ->
    case whereis(?SERVER) of
        Pid when is_pid(Pid) -> up;
        _ -> down
    end.

members() ->
    case catch pg:get_members(?PG_SCOPE, ?PG_GROUP) of
        L when is_list(L) -> L;
        _ -> []
    end.

member_nodes() ->
    lists:usort([node(P) || P <- members(), node(P) =/= node()]).

counter(Key) ->
    maps:get(Key, counters(), 0).

table_size(Tab) ->
    case catch ets:info(Tab, size) of
        N when is_integer(N) -> N;
        _ -> 0
    end.

mirror_rows(Now) ->
    Cool =
        [
            #{
                target => fmt_term(T),
                sender => S,
                kind => cool,
                expires_in_ms => max(0, Exp - Now)
            }
         || {T, S, Exp, _Class} <- tab_rows(?COOL)
        ],
    Lat =
        [
            #{
                target => fmt_term(T),
                sender => S,
                kind => lat,
                verdict => V,
                ewma_ms => E,
                samples => N,
                expires_in_ms => max(0, Exp - Now)
            }
         || {T, S, Exp, E, N, V} <- tab_rows(?LAT)
        ],
    Cool ++ Lat.

quota_mirror_rows(Now) ->
    [
        #{
            agent_key_id => K,
            window_id => W,
            sender => S,
            window_sec => WSec,
            used => Used,
            limit => Limit,
            expires_in_ms => max(0, Exp - Now)
        }
     || {{K, W}, S, Exp, WSec, Used, Limit} <- tab_rows(?QUOTA)
    ].

tab_rows(Tab) ->
    case catch ets:tab2list(Tab) of
        L when is_list(L) -> L;
        _ -> []
    end.

ring_rows() ->
    L = tab_rows(?RING),
    [Entry || {_, Entry} <- lists:sublist(lists:reverse(lists:keysort(1, L)), ?CMD_RING_SIZE)].

trim_ring() ->
    try
        case ets:info(?RING, size) of
            N when is_integer(N), N > ?CMD_RING_SIZE ->
                _ = [ets:delete(?RING, K) || {K, _} <- lists:sublist(ets:tab2list(?RING), N - ?CMD_RING_SIZE)],
                ok;
            _ ->
                ok
        end
    catch
        _:_ -> ok
    end.

%% cert_days_remaining cached in persistent_term guarded by the cert
%% file's mtime (Part A: no per-request disk I/O).
cert_days_cached() ->
    Path =
        case os:getenv("JANUS_FLEET_TLS_DIR") of
            Dir when is_list(Dir), Dir =/= [] -> filename:join(Dir, "node.pem");
            _ -> undefined
        end,
    cert_days_cached(Path).

cert_days_cached(undefined) ->
    null;
cert_days_cached(Path) ->
    try
        {ok, #file_info{mtime = MTime}} = file:read_file_info(Path),
        case persistent_term:get(?CERT_PT, undefined) of
            {MTime, Days} when is_integer(Days) ->
                Days;
            _ ->
                case janus_fleet_tls:cert_days_remaining(Path) of
                    {ok, Days} ->
                        _ = persistent_term:put(?CERT_PT, {MTime, Days}),
                        Days;
                    error ->
                        null
                end
        end
    catch
        _:_ -> null
    end.

%%%===================================================================
%%% Boot plumbing
%%%===================================================================

ensure_tables() ->
    _ = ensure_tab(?COOL, duplicate_bag),
    _ = ensure_tab(?LAT, duplicate_bag),
    _ = ensure_tab(?QUOTA, duplicate_bag),
    _ = ensure_tab(?CACHE, set),
    _ = ensure_tab(?STATE, set),
    _ = ensure_tab(?COUNTERS, set),
    _ = ensure_tab(?SENDERROWS, set),
    _ = ensure_tab(?RING, ordered_set),
    ok.

ensure_tab(Name, Type) ->
    case ets:info(Name) of
        undefined ->
            try
                ets:new(Name, [
                    named_table,
                    public,
                    Type,
                    {read_concurrency, true},
                    {write_concurrency, true}
                ])
            catch
                error:badarg -> Name
            end;
        _ ->
            Name
    end.

start_pg_scope() ->
    case catch pg:start(?PG_SCOPE) of
        ok -> ok;
        {error, {already_started, _}} -> ok;
        {'EXIT', _} = Crash ->
            logger:error(#{what => janus_fleet_pg_start_failed, reason => Crash}),
            ok;
        Other ->
            logger:error(#{what => janus_fleet_pg_start_failed, reason => Other}),
            ok
    end.

schedule_connect(Peer, Attempt, Delay) ->
    _ = erlang:send_after(Delay, self(), {connect_peer, Peer, Attempt}),
    ok.

log_catch(What, Fun) ->
    try
        Fun()
    catch
        Class:Reason ->
            logger:error(#{what => What, class => Class, reason => Reason}),
            ok
    end.

tolerant_lookup(Tab, Key) ->
    try ets:lookup(Tab, Key) of
        L when is_list(L) -> L;
        _ -> []
    catch
        _:_ -> []
    end.

tolerant_delete(Tab, Key) ->
    try
        ets:delete(Tab, Key)
    catch
        _:_ -> ok
    end.

safe_insert(Tab, Row) ->
    try
        true = ets:insert(Tab, Row)
    catch
        _:_ -> false
    end.

now_mono() ->
    erlang:monotonic_time(millisecond).

fmt_term(T) ->
    unicode:characters_to_binary(io_lib:format("~0p", [T])).
