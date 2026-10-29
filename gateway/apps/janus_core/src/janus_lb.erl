%%%-------------------------------------------------------------------
%%% @doc Node-local LB runtime ETS owner.
%%%
%%% Owns cool-downs, in-flight counters, weighted-RR cursors, and the
%%% per-route latency EWMA in separate ETS tables from the catalog.
%%% Config publish must never wipe these tables.
%%%
%%% Failover is across providers for a model: an invalid/dead key is
%%% keyed per provider_key (shared by every model on that provider).
%%% When a provider has no usable keys left — or the provider itself
%%% is cooling (auth/transport/5xx) — pick skips the whole provider
%%% and RR among remaining providers that still route the model.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_lb).
-behaviour(gen_server).

-include("janus_lb.hrl").

-export([start_link/0, cooling_count/0]).
%% Failure observability (spec 2026-10-13 §4.1/§4.2/§4.5): expiry
%% sweeper (serialized with pick/note mutations), cool + rate views,
%% and attempt-outcome parity via note_attempt/1.
-export([sweep_cool/0, cool_snapshot/0, rates_snapshot/0, note_attempt/1]).
-export([
    note_failure/2,
    note_success/1,
    note_latency/2,
    note_auth_failure/3,
    release_inflight/1,
    pick_route/2,
    pick_listing_route/2,
    %% Pure prefer-proto filter (eunit-tested with an injected lookup
    %% fun; production wires it to the catalog).
    prefer_proto_filter/3,
    %% Pure latency-degradation filter (same injection style; the
    %% production wiring reads the latency ETS table).
    degraded_filter/4,
    %% Hard face-protocol filter (Decisions spec §4.5) — same
    %% injection style; mechanism only, the proxy owns the policy.
    protocol_filter/3,
    %% Fleet distribution (native-distribution spec Part B):
    %% cool_clear/1 is the pinned F.1 command MFA; the three filters
    %% below are pure with injected consults (same style as above).
    cool_clear/1,
    remote_cool_filter/2,
    remote_lat_postfilter/3,
    lat_publish_eval/6,
    lat_verdict/4,
    %% Entitlement carrier observability (spec Part B/C)
    bump_stat/1,
    stats/0
]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(COOLDOWNS, janus_lb_cooldowns).
-define(INFLIGHT, janus_lb_inflight).
-define(CURSORS, janus_lb_rr_cursors).
-define(ENT_STATS, janus_lb_ent_stats).
-define(LATENCY, janus_lb_latency).
-define(ATTEMPTS, janus_lb_attempts).
-define(DEFAULT_COOLDOWN_MS, 5000).
%% Expiry sweeper tick (spec §4.2: "on snapshot build and <=1s tick").
-define(SWEEP_MS, 1000).
-define(AUTH_COOLDOWN_MS, 60000).
-define(MAX_RETRY_AFTER_MS, 300000).
%% At-most-once attempt_id set; prune when over this size.
-define(ATTEMPT_ID_CAP, 10000).
%% Latency shedding: EWMA of upstream call wall time per route target.
%% A candidate is degraded when its EWMA exceeds BOTH the absolute
%% floor and FACTOR x the best eligible peer (>= MIN_SAMPLES samples).
%% (?EWMA_MIN_SAMPLES / ?EWMA_STALE_MS live in janus_lb.hrl, shared
%% with the fleet remote consults so local and fleet verdicts cannot
%% drift.)
-define(EWMA_ALPHA_PCT, 25).
-define(EWMA_CLAMP_MS, 30000).
-define(DEFAULT_DEGRADED_FACTOR_PCT, 300).
-define(DEFAULT_DEGRADED_FLOOR_MS, 1500).
%% Upper bound for a published route/key weight. The catalog already
%% normalizes weights (janus_catalog:to_pos_int/2); this is the LB-side
%% defense in depth: `weighted_rr_pick/3` expands one list slot per
%% weight unit, so an operator typo like 1000000 would otherwise build a
%% million-element list on every pick (review 01b M2).
-define(MAX_WEIGHT, 1000).
%% Heir adoption backoff (mirrors janus_worker_pool's table bootstrap):
%% a runtime restart can race the heir's own restart processing the dead
%% owner's {'ETS-TRANSFER'}.
-define(ADOPT_RETRIES, 10).
-define(ADOPT_RETRY_MS, 50).

%% Fleet latency-publish coalescer state lives in the gen_server
%% (#state.lat_pub, per target): {LastVerdict, Pending :: {Verdict,
%% ConsecutiveEvals}, LastPublishMono}.

-record(state, {
    cooldowns :: ets:tid(),
    inflight :: ets:tid(),
    cursors :: ets:tid(),
    latency :: ets:tid(),
    attempts :: ets:tid(),
    lat_pub = #{} :: map(),
    %% Pure rate-window state (janus_rate_view); mutated only on the
    %% gen_server so cool + rates stay atomic with note_attempt/1.
    rates = #{entities => #{}, evicted => []} :: map()
}).

-type target() ::
    term()
    | #{provider_id := term(), key_id => term(), model_id => term()}.

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Master attempt-outcome (spec §4.5): update cool + rate windows
%% atomically. At-most-once per `attempt_id`. `Attempt` is
%% `#{attempt_id := binary(), entity := map(), class := atom()|binary(),
%% reason => term()}` — entity uses the health JSON shape (binary ids).
-spec note_attempt(map()) -> ok.
note_attempt(#{attempt_id := Id, entity := Entity, class := Class} = Attempt) when
    is_binary(Id), is_map(Entity)
->
    gen_server:cast(?SERVER, {note_attempt, Attempt#{entity => Entity, class => Class}});
note_attempt(_) ->
    ok.

%% @doc Record a failure against a route/key/provider target; apply cool-down.
-spec note_failure(target(), term()) -> ok.
note_failure(undefined, _Reason) ->
    ok;
note_failure(Target, Reason) ->
    gen_server:cast(?SERVER, {note_failure, Target, Reason}).

%% @doc Auth failure on a key: cool the key; if the provider has no
%% remaining usable keys, cool the whole provider so every model on it
%% fails over to other providers.
-spec note_auth_failure(term(), term(), term()) -> ok.
note_auth_failure(undefined, _KeyId, _Reason) ->
    ok;
note_auth_failure(ProviderId, undefined, Reason) ->
    gen_server:cast(?SERVER, {note_failure, {provider, ProviderId}, Reason});
note_auth_failure(ProviderId, KeyId, Reason) ->
    gen_server:cast(?SERVER, {note_auth_failure, ProviderId, KeyId, Reason}).

%% @doc Record a success; clear cool-down and decrement in-flight.
-spec note_success(target()) -> ok.
note_success(undefined) ->
    ok;
note_success(Target) ->
    gen_server:cast(?SERVER, {note_success, Target}).

%% @doc Record one upstream call's wall time (connect + first-byte for
%% streams, plus body for unary calls) against a route target; feeds
%% the EWMA degradation filter. Samples are clamped so one hang cannot
%% poison the average.
-spec note_latency(target(), non_neg_integer()) -> ok.
note_latency(undefined, _Ms) ->
    ok;
note_latency(_Target, Ms) when not is_integer(Ms) ->
    ok;
note_latency(Target, Ms) ->
    gen_server:cast(?SERVER, {note_latency, Target, min(max(Ms, 0), ?EWMA_CLAMP_MS)}).

%% @doc Decrement in-flight only — never clears an active cool-down.
-spec release_inflight(target()) -> ok.
release_inflight(undefined) ->
    ok;
release_inflight(Target) ->
    gen_server:cast(?SERVER, {release_inflight, Target}).

%% @doc Remove elapsed cool rows and emit `cool_edge clear/expired` for
%% each. A gen_server call, so it is serialized with note_*/pick
%% mutations (and every cast queued before it has been applied).
-spec sweep_cool() -> ok.
sweep_cool() ->
    gen_server:call(?SERVER, sweep_cool, 5000).

%% @doc The `/stats/health` cool section (see `janus_cool_view:project/3`).
%% Sweeps first (best effort) so elapsed rows emit their `expired` edge
%% before the snapshot's ring meta is read; the projection itself also
%% filters elapsed rows, so a busy/absent LB still yields a valid view.
-spec cool_snapshot() -> map().
cool_snapshot() ->
    _ =
        try
            sweep_cool()
        catch
            _:_ -> ok
        end,
    Rows =
        try
            ets:tab2list(?COOLDOWNS)
        catch
            _:_ -> []
        end,
    Idx = janus_catalog:key_provider_index(),
    janus_cool_view:project(
        Rows, janus_cool_view:clock(), fun(KeyId) -> maps:get(KeyId, Idx, undefined) end
    ).

%% @doc The `/stats/health` rates section (see `janus_rate_view:project/3`).
%% Serialized call so the projection sees a consistent rates+cool pair.
-spec rates_snapshot() -> map().
rates_snapshot() ->
    try
        gen_server:call(?SERVER, rates_snapshot, 5000)
    catch
        _:_ ->
            janus_rate_view:project(janus_rate_view:empty_state(), sets:new(), erlang:system_time(millisecond))
    end.

%% @doc Pick a route for `ModelId`. `Opts` may include `generation`.
%% Returns `{ok, Route}` or `{error, Reason}`. Weighted RR across
%% providers that still have a usable key.
-spec pick_route(term(), map()) -> {ok, map()} | {error, term()}.
pick_route(ModelId, Opts) when is_map(Opts) ->
    gen_server:call(?SERVER, {pick_route, ModelId, Opts}, 5000).

%% @doc Pick a provider for a direct listing call (model not in the
%% bound models table): candidates are the enabled listings under
%% `Name`. Shares the cooling/inflight/key-pick pipeline with bound
%% routes; the returned route carries `model_id => null`.
-spec pick_listing_route(binary(), map()) -> {ok, map()} | {error, term()}.
pick_listing_route(Name, Opts) when is_binary(Name), is_map(Opts) ->
    gen_server:call(?SERVER, {pick_listing_route, Name, Opts}, 5000).

%%--------------------------------------------------------------------
%% gen_server
%%--------------------------------------------------------------------

init([]) ->
    %% LB state is heir'd (review 01b M1): when this gen_server crashes,
    %% janus_ets_heir takes the six tables instead of OTP destroying
    %% them, and this init/1 adopts them back — cooldowns (incl. 60s
    %% auth cooldowns), EWMA latency history, RR cursors and counters
    %% survive the restart. A crash loop caused by one catalog row (see
    %% weighted_rr_pick/3) therefore no longer re-hammers a provider
    %% that the fleet already knows is failing.
    Heir = heir_pid(),
    Cool = ensure_tab(
        ?COOLDOWNS,
        [named_table, set, public, {read_concurrency, true}, {write_concurrency, true}],
        Heir
    ),
    Inflight = ensure_tab(
        ?INFLIGHT,
        [named_table, set, public, {write_concurrency, true}],
        Heir
    ),
    Cursors = ensure_tab(
        ?CURSORS,
        [named_table, set, public, {write_concurrency, true}],
        Heir
    ),
    _ = ensure_tab(
        ?ENT_STATS,
        [named_table, set, public, {write_concurrency, true}],
        Heir
    ),
    Latency = ensure_tab(
        ?LATENCY,
        [named_table, set, public, {read_concurrency, true}, {write_concurrency, true}],
        Heir
    ),
    Attempts = ensure_tab(?ATTEMPTS, [named_table, set, public], Heir),
    logger:info(#{what => janus_lb_started}),
    erlang:send_after(?SWEEP_MS, self(), sweep_cool),
    {ok, #state{
        cooldowns = Cool,
        inflight = Inflight,
        cursors = Cursors,
        latency = Latency,
        attempts = Attempts,
        rates = janus_rate_view:empty_state()
    }}.

handle_call({pick_route, ModelId, Opts}, _From, State) ->
    {reply, do_pick_route(ModelId, Opts, State), State};
handle_call({pick_listing_route, Name, Opts}, _From, State) ->
    {reply, do_pick_listing_route(Name, Opts, State), State};
handle_call(sweep_cool, _From, #state{cooldowns = Cool} = State) ->
    do_sweep(Cool),
    {reply, ok, State};
handle_call(rates_snapshot, _From, #state{cooldowns = Cool, rates = Rates} = State) ->
    _ = do_sweep(Cool),
    {reply, project_rates(Cool, Rates), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({note_attempt, Attempt}, State) ->
    {noreply, do_note_attempt(Attempt, State)};
handle_cast({note_failure, Target, Reason}, State) ->
    do_note_failure(Target, Reason, State),
    {noreply, State};
handle_cast({note_auth_failure, ProviderId, KeyId, Reason}, State) ->
    do_note_auth_failure(ProviderId, KeyId, Reason, State),
    {noreply, State};
handle_cast({note_success, Target}, State) ->
    do_note_success(Target, State),
    {noreply, State};
handle_cast({note_latency, Target, Ms}, #state{latency = Lat, lat_pub = Pub} = State) ->
    Pub1 = do_note_latency(normalize_target(Target), Ms, Lat, Pub),
    {noreply, State#state{lat_pub = Pub1}};
handle_cast({release_inflight, Target}, #state{inflight = Inflight} = State) ->
    dec_inflight(Target, Inflight),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sweep_cool, #state{cooldowns = Cool} = State) ->
    do_sweep(Cool),
    erlang:send_after(?SWEEP_MS, self(), sweep_cool),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

%% The stable ETS heir (scheduler v2 spec Part 0.5). `undefined` when the
%% heir is not running: production starts janus_ets_heir before this
%% child (janus_core_sup), but eunit boots janus_lb standalone, and a
%% state-only suite must not depend on it — those tables are then plain
%% (cold on restart, the pre-review behavior).
heir_pid() ->
    case whereis(janus_ets_heir) of
        Pid when is_pid(Pid) -> Pid;
        undefined -> undefined
    end.

ensure_tab(Tag, Opts, undefined) ->
    %% No heir (eunit, or a restart racing the heir's own): wait out a
    %% dying heir that still has the name registered, then create plain.
    _ = wait_tab_free(Tag, ?ADOPT_RETRIES),
    ets:new(Tag, Opts);
ensure_tab(Tag, Opts, Heir) ->
    case ets:info(Tag) of
        undefined ->
            %% Cold boot: the name is free, no adopt-retry burn.
            ets:new(Tag, Opts ++ [{heir, Heir, {Tag, self()}}]);
        _ ->
            %% The heir is holding the previous owner's table (it still
            %% answers ets:info): adopt it back. `not_held` after the
            %% retries means the heir died under us — its death destroyed
            %% the held tables, so create cold.
            case adopt_retry(Tag, ?ADOPT_RETRIES) of
                {ok, Tab} ->
                    Tab;
                not_held ->
                    ets:new(Tag, Opts ++ [{heir, Heir, {Tag, self()}}])
            end
    end.

adopt_retry(_Tag, 0) ->
    not_held;
adopt_retry(Tag, N) when N > 0 ->
    case janus_ets_heir:adopt(Tag) of
        {ok, Tab} ->
            {ok, Tab};
        not_held ->
            timer:sleep(?ADOPT_RETRY_MS),
            adopt_retry(Tag, N - 1);
        {error, give_away_failed} ->
            timer:sleep(?ADOPT_RETRY_MS),
            adopt_retry(Tag, N - 1)
    end.

wait_tab_free(_Tag, 0) ->
    ok;
wait_tab_free(Tag, N) ->
    case ets:info(Tag) of
        undefined ->
            ok;
        _ ->
            timer:sleep(?ADOPT_RETRY_MS),
            wait_tab_free(Tag, N - 1)
    end.

%% A streaming request prefers a same-protocol route (responses client,
%% or tools/vision/n>1 must ride one; every other stream rides one when
%% available — audit R2). The preference composes with the PICKABLE
%% set (ocr review 2026-10-07): applied after cooling/enabled filtering
%% and falling back to ALL pickable routes when no same-protocol route
%% is pickable, so a cooling native route strands a stream on a 503
%% only when there is genuinely nothing else healthy to serve it.
prefer_proto_routes(Routes, Opts) ->
    case Opts of
        #{prefer_proto := Proto} when is_binary(Proto) ->
            prefer_proto_filter(Routes, Proto, fun route_protocol/1);
        _ ->
            Routes
    end.

%% Pure filter (eunit-tested): unknown-provider routes never match and
%% never crash the pick.
prefer_proto_filter(Routes, Proto, RouteProto) ->
    Match = [R || R <- Routes, RouteProto(R) =:= Proto],
    case Match of
        [] -> Routes;
        _ -> Match
    end.

route_protocol(R) ->
    case janus_catalog:lookup_provider(maps:get(provider_id, R, undefined)) of
        {ok, #{protocol := P}} when is_binary(P) -> P;
        _ -> undefined
    end.

%% Latency degradation filter (pure; eunit-driven with an injected
%% lookup fun). EwmaFun(route_target(R)) -> undefined | {EwmaMs,
%% Samples}. A candidate is degraded only when it has enough samples,
%% its EWMA exceeds the absolute floor, AND it is more than FactorPct
%% percent of the best eligible peer. Cold routes (no/insufficient
%% data) are never degraded and never feed the best computation. The
%% survivor set can only be empty when nothing was eligible (the best
%% route itself never satisfies the strict inequality), but fall back
%% to the input regardless: availability beats preference.
degraded_filter(Routes, _EwmaFun, _FactorPct, _FloorMs) when length(Routes) < 2 ->
    Routes;
degraded_filter(Routes, EwmaFun, FactorPct, FloorMs) when is_list(Routes) ->
    Sampled = [{R, EwmaFun(route_target(R))} || R <- Routes],
    Eligible = [{R, Ms} || {R, {Ms, S}} <- Sampled, S >= ?EWMA_MIN_SAMPLES],
    case Eligible of
        [] ->
            Routes;
        _ ->
            Best = lists:min([Ms || {_, Ms} <- Eligible]),
            case [R || {R, S} <- Sampled, not is_degraded(S, Best, FactorPct, FloorMs)] of
                [] -> Routes;
                Survivors -> Survivors
            end
    end.

is_degraded({Ms, Samples}, Best, FactorPct, FloorMs) ->
    Samples >= ?EWMA_MIN_SAMPLES andalso Ms > FloorMs andalso Ms * 100 > FactorPct * Best;
is_degraded(_, _, _, _) ->
    false.

%% ETS-backed lookup for the pick path: entries older than the
%% staleness window are treated as no-data (and dropped lazily).
latency_fun(Lat) ->
    Now = erlang:monotonic_time(millisecond),
    fun(Target) ->
        case ets:lookup(Lat, Target) of
            [{_, Ms, Samples, Updated}] when Now - Updated < ?EWMA_STALE_MS ->
                {Ms, Samples};
            [{_, _, _, _}] ->
                ets:delete(Lat, Target),
                undefined;
            _ ->
                undefined
        end
    end.

%%%--------------------------------------------------------------------
%%% Fleet distribution (native-distribution spec Part B)
%%%--------------------------------------------------------------------

%% Egress hook (Part 0.1 invariant): persistent_term knob check first,
%% then a catch-guarded publish — zero cost when off, no badarg when
%% the fleet process is absent or parked.
maybe_publish(Msg) ->
    case catch janus_fleet:enabled() of
        true -> catch janus_fleet:publish(Msg);
        _ -> ok
    end.

%% Remote-cool consult (pure; injected consult fun Target ->
%% boolean): any single live sender's unexpired row cools the target —
%% EXCEPT when that would remove the last available candidate: then
%% the remote rows are ignored for this pick (advisory-only, never a
%% hard remote 503) and last_resort is flagged for counting.
remote_cool_filter(Routes, RemoteCoolFun) when is_list(Routes) ->
    Kept = [
        R
     || R <- Routes,
        not (RemoteCoolFun(provider_target(R)) orelse RemoteCoolFun(route_target(R)))
    ],
    case Kept of
        [] when Routes =/= [] -> {Routes, last_resort};
        [] -> {Routes, passthrough};
        _ -> {Kept, shed}
    end.

%% Remote latency quorum post-filter (pure; runs AFTER the local
%% degraded_filter): drop a candidate only when >= ?REMOTE_LAT_QUORUM
%% distinct live senders hold unexpired degraded rows AND there is no
%% fresh, sufficiently-sampled local EWMA for it (local wins); if the
%% post-filter would empty the set, return the pre-filter set
%% (never-shed-last, mirroring degraded_filter).
remote_lat_postfilter(Routes, RemoteRowsFun, LocalFun) when is_list(Routes) ->
    Kept = [R || R <- Routes, not remote_lat_shed(route_target(R), RemoteRowsFun, LocalFun)],
    case Kept of
        [] -> Routes;
        _ -> Kept
    end.

remote_lat_shed(Target, RemoteRowsFun, LocalFun) ->
    case LocalFun(Target) of
        {_Ms, Samples} when Samples >= ?EWMA_MIN_SAMPLES ->
            false;
        _ ->
            DegradedSenders = lists:usort([S || {S, degraded} <- RemoteRowsFun(Target)]),
            length(DegradedSenders) >= ?REMOTE_LAT_QUORUM
    end.

%% Sender-side local verdict for the publish path (pure): the target's
%% EWMA judged against the FRESH rows of its own family (same model) —
%% identical thresholds to degraded_filter so a published verdict is
%% exactly what the sender's local pick would conclude.
lat_verdict(Self, FamilySamples, FactorPct, FloorMs) ->
    Eligible = [{Ms, S} || {Ms, S} <- FamilySamples, S >= ?EWMA_MIN_SAMPLES],
    case Eligible of
        [] ->
            healthy;
        _ ->
            Best = lists:min([Ms || {Ms, _} <- Eligible]),
            case is_degraded(Self, Best, FactorPct, FloorMs) of
                true -> degraded;
                false -> healthy
            end
    end.

%% Publish coalescer (pure; Part 0.4 storm bound): a verdict flip
%% publishes only after 2 consecutive evaluations (hysteresis); while
%% a route stays locally degraded a heartbeat republishes at most
%% every ?FLEET_HEARTBEAT_MS; healthy flips announce as well.
lat_publish_eval(Entry, Target, Verdict, EwmaMs, Samples, Now) ->
    {LastV, {PV, PN}, LastPub} = lat_entry(Entry),
    Pending =
        case PV =:= Verdict of
            true -> {PV, PN + 1};
            false -> {Verdict, 1}
        end,
    {LastV1, Flipped} =
        case Pending of
            {V, N} when N >= 2, V =/= LastV -> {V, true};
            _ -> {LastV, false}
        end,
    Heartbeat =
        Verdict =:= degraded andalso LastV1 =:= degraded andalso
            Now - LastPub >= ?FLEET_HEARTBEAT_MS,
    {Publish, NewLastPub} =
        case Flipped orelse Heartbeat of
            true -> {{lb_lat, Target, Verdict, EwmaMs, Samples, ?FLEET_LAT_TTL_MS}, Now};
            false -> {undefined, LastPub}
        end,
    {{LastV1, Pending, NewLastPub}, Publish}.

lat_entry(undefined) -> {healthy, {healthy, 0}, 0};
lat_entry(Entry) when tuple_size(Entry) =:= 3 -> Entry.

%% F.1 command target: clear the LOCAL cooldown row for the target
%% (idempotent, tolerant when LB is down). The fleet-wide purge signal
%% is broadcast separately by the command originator only.
-spec cool_clear(target()) -> ok.
cool_clear(Target) ->
    try
        %% take (atomic) so only the process that actually removed the
        %% row emits the edge — a concurrent sweeper/success cannot
        %% double-emit.
        Key = normalize_target(Target),
        _ = emit_clear_for_taken(ets:take(?COOLDOWNS, Key), undefined),
        ok
    catch
        _:_ -> ok
    end.

remote_cool_fun() ->
    case catch janus_fleet:enabled() of
        true -> fun janus_fleet:remote_cooling/1;
        _ -> fun(_) -> false end
    end.

remote_lat_fun() ->
    case catch janus_fleet:enabled() of
        true ->
            fun(Target) ->
                [{S, V} || {S, _E, _N, V} <- janus_fleet:remote_lat_rows(Target)]
            end;
        _ ->
            fun(_) -> [] end
    end.

degraded_factor_pct() ->
    env_int("JANUS_LB_DEGRADED_FACTOR_PCT", ?DEFAULT_DEGRADED_FACTOR_PCT).

degraded_floor_ms() ->
    env_int("JANUS_LB_DEGRADED_FLOOR_MS", ?DEFAULT_DEGRADED_FLOOR_MS).

env_int(Name, Default) ->
    case os:getenv(Name) of
        false ->
            Default;
        "" ->
            Default;
        Val ->
            try
                case list_to_integer(Val) of
                    N when is_integer(N), N > 0 -> N;
                    _ -> Default
                end
            catch
                _:_ -> Default
            end
    end.

%% Hard face-eligibility filter (Decisions spec §4.5): unlike
%% prefer_proto (a bias that falls back), routes dropped here are
%% NEVER pickable for this request. Pick opts (policy owned by
%% janus_http_proxy):
%%   require_proto  => binary()   — keep ONLY routes on exactly that
%%                                   provider protocol (the Decisions
%%                                   face; unknown protocols fail
%%                                   closed to no_route, D2)
%%   exclude_protos => [binary()] — drop routes on the listed
%%                                   protocols (every other face
%%                                   excludes openai_decisions);
%%                                   unknown protocols are KEPT — they
%%                                   defer to the dispatch-time
%%                                   unknown_protocol guard (D2/TF-D.12)
%% Pure + total for eunit (inject the proto lookup like
%% prefer_proto_filter/3).
protocol_filter(Routes, Opts, RouteProto) when is_map(Opts) ->
    R1 =
        case Opts of
            #{require_proto := Proto} when is_binary(Proto) ->
                [R || R <- Routes, RouteProto(R) =:= Proto];
            _ ->
                Routes
        end,
    case Opts of
        #{exclude_protos := Excluded} when is_list(Excluded) ->
            [R || R <- R1, not lists:member(RouteProto(R), Excluded)];
        _ ->
            R1
    end;
protocol_filter(Routes, _, _) ->
    Routes.

do_pick_route(ModelId, Opts, State) ->
    case catalog_generation_ok(Opts) of
        false ->
            {error, catalog_not_ready};
        true ->
            case model_disabled(ModelId) of
                true ->
                    {error, no_route};
                false ->
                    pick_from_routes(
                        ModelId, janus_catalog:routes_for_model(ModelId), Opts, State
                    )
            end
    end.

%% models.enabled is the dashboard's per-model kill switch (review 06d
%% H1): a disabled row must not be routed even when its routes and
%% provider are still enabled. Answer the pick's existing no_route (the
%% 404 a route-less model already gets) instead of a new error shape.
%% A missing row — listing-only picks, or a pre-`models` catalog — is
%% not blocked here; route/provider/listing enablement still applies.
model_disabled(ModelId) ->
    case janus_catalog:lookup_model(ModelId) of
        {ok, #{enabled := false}} -> true;
        _ -> false
    end.

do_pick_listing_route(Name, Opts, State) ->
    case catalog_generation_ok(Opts) of
        false ->
            {error, catalog_not_ready};
        true ->
            pick_from_routes({listing, Name}, janus_catalog:listings_for(Name), Opts, State)
    end.

pick_from_routes(
    PickKey,
    Routes0,
    Opts,
    #state{cooldowns = Cool, cursors = Cursors, inflight = Inflight, latency = Lat}
) ->
    {Kept, Dropped} = lists:partition(
        fun(R) -> route_listing_enabled(PickKey, R) end,
        [R || R <- Routes0, maps:get(enabled, R, true)]
    ),
    %% A route dropped because its listing is explicitly disabled is a
    %% deliberate operator state, not a fault — but it used to be invisible:
    %% the client saw only no_route, byte-identical to "this model has no
    %% routes at all". Count it (one flat counter; no per-listing label, to
    %% keep cardinality bounded), same discipline as affinity_miss.
    _ =
        case Dropped of
            [] -> ok;
            _ -> bump_stat(listing_disabled_route)
        end,
    Routes1 = protocol_filter(Kept, Opts, fun route_protocol/1),
    case Routes1 of
        [] ->
            {error, no_route};
        _ ->
            Now = erlang:monotonic_time(millisecond),
            Available0 = [
                R
             || R <- Routes1,
                not is_cooling(provider_target(R), Cool, Now),
                not is_cooling(route_target(R), Cool, Now),
                provider_enabled(R)
            ],
            %% Remote-cool consult (Part B): any single live sender's
            %% unexpired mirror row cools the candidate — except when
            %% it would remove the LAST candidate (never a hard remote
            %% 503; the ignored case is counted).
            {Available0b, CoolFlag} = remote_cool_filter(Available0, remote_cool_fun()),
            case CoolFlag of
                last_resort -> _ = catch janus_fleet:bump(remote_cool_last_resort);
                _ -> ok
            end,
            case Available0b of
                [] ->
                    %% All routes filtered out: cooling is only the
                    %% diagnosis when at least one provider is
                    %% enabled — a disabled provider must not
                    %% surface as a cooldown.
                    case lists:any(fun(R) -> provider_enabled(R) end, Routes1) of
                        false -> {error, provider_disabled};
                        true -> {error, {all_cooling, remaining_cooldown_ms(Routes1, Cool, Now)}}
                    end;
                _ ->
                    %% Preference among PICKABLE routes only (see
                    %% prefer_proto_routes/2): falls back to all of
                    %% them when no same-protocol route is pickable.
                    Available = prefer_proto_routes(Available0b, Opts),
                    case pick_usable_route(PickKey, Available, Cool, Cursors, Now, Inflight, Lat) of
                        {ok, _} = Ok ->
                            Ok;
                        {error, Reason} = Err ->
                            logger:warning(#{
                                what => janus_lb_no_usable_route,
                                pick_key => PickKey,
                                reason => Reason,
                                candidates => length(Available)
                            }),
                            case Reason of
                                all_cooling ->
                                    {error,
                                        {all_cooling,
                                            remaining_cooldown_ms(Available, Cool, Now)}};
                                _ ->
                                    Err
                            end
                    end
            end
    end.

%% Prefer another provider when this one's keys are exhausted; shed
%% candidates whose EWMA latency is degraded relative to their peers
%% (falls back to the full usable set when data is insufficient), then
%% apply the remote latency quorum post-filter (Part B).
pick_usable_route(PickKey, Candidates, Cool, Cursors, Now, Inflight, Lat) ->
    Usable = [R || R <- Candidates, has_usable_key(R, Cool, Now)],
    case Usable of
        [] ->
            {error, classify_key_failures(Candidates, Cool, Now)};
        _ ->
            %% Priority is the failover tier (dashboard Router copy:
            %% "Lower priorities are tried first; failover moves to the
            %% next one. Traffic share within the same priority"): only
            %% the best usable tier competes, and a tier whose keys are
            %% all cooling/disabled falls through to the next. It used
            %% to be parsed and sorted but never consulted (review 06d
            %% M6).
            Tier = priority_tier(Usable),
            Healthy0 = degraded_filter(
                Tier, latency_fun(Lat), degraded_factor_pct(), degraded_floor_ms()
            ),
            Healthy =
                remote_lat_postfilter(Healthy0, remote_lat_fun(), latency_fun(Lat)),
            Picked = weighted_rr_pick(PickKey, Healthy, Cursors),
            case select_key(PickKey, Picked, Cool, Cursors, Now) of
                {ok, Key} ->
                    bump_inflight(route_target(Picked), Inflight),
                    {ok, Picked#{provider_key => Key}};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

has_usable_key(#{provider_id := ProviderId}, Cool, Now) ->
    provider_has_usable_key(ProviderId, Cool, Now);
has_usable_key(_, _, _) ->
    false.

classify_key_failures(Candidates, Cool, Now) ->
    Statuses = [key_status(R, Cool, Now) || R <- Candidates],
    case lists:member(all_cooling, Statuses) of
        true ->
            all_cooling;
        false ->
            case lists:member(keys_disabled, Statuses) of
                true -> keys_disabled;
                false -> missing_provider_key
            end
    end.

key_status(#{provider_id := ProviderId}, Cool, Now) ->
    All = janus_catalog:provider_keys(ProviderId),
    Enabled = [K || K <- All, maps:get(enabled, K, true)],
    Usable = [K || K <- Enabled, not is_cooling(key_target(K), Cool, Now)],
    case {All, Enabled, Usable} of
        {[], _, _} -> missing_provider_key;
        {_, [], _} -> keys_disabled;
        {_, _, []} -> all_cooling;
        {_, _, _} -> ok
    end;
key_status(_, _, _) ->
    missing_provider_key.

select_key(PickKey, #{provider_id := ProviderId} = Route, Cool, Cursors, Now) ->
    Keys0 = [
        K
     || K <- janus_catalog:provider_keys(ProviderId),
        maps:get(enabled, K, true),
        not is_cooling(key_target(K), Cool, Now)
    ],
    Upstream = upstream_model_name(PickKey, Route),
    %% Entitlement carrier pre-filter: skip deny/balance/broken keys
    %% for THIS upstream listing (spec Part B). broken = key-level row.
    Allowed = [
        K
     || K <- Keys0,
        janus_catalog:entitlement_denied(
            ProviderId, Upstream, maps:get(id, K, undefined)
        ) =:= false
    ],
    case Allowed of
        [] when Keys0 =/= [] ->
            %% Zero-eligible fail-open: the matrix is advisory; stale
            %% deny/balance data must not cause a total outage.
            _ = bump_stat(entitlement_failopen),
            logger:warning(#{
                what => janus_entitlement_failopen,
                provider => ProviderId,
                model => Upstream,
                excluded => length(Keys0)
            }),
            pick_rr_key(ProviderId, Route, Keys0, Cursors);
        [] ->
            {error, key_status(Route, Cool, Now)};
        _ ->
            pick_rr_key(ProviderId, Route, Allowed, Cursors)
    end;
select_key(_, _, _, _, _) ->
    {error, missing_provider_key}.

%% The listing a bound route would call must not be EXPLICITLY disabled
%% (janus_catalog:listing_enabled/2). Provider enablement is checked further
%% down; this covers provider_models.enabled, which the bound-route path
%% used to ignore (the dashboard compensated by turning such routes off).
%% A missing listing row stays pickable — unknown is not disabled, the
%% catalog may lag the DB, and routed_limits/1 already treats it as
%% "contributes nothing" without refusing the pick.
route_listing_enabled(PickKey, Route) ->
    case upstream_model_name(PickKey, Route) of
        Name when is_binary(Name) ->
            janus_catalog:listing_enabled(maps:get(provider_id, Route, undefined), Name);
        _ ->
            true
    end.

pick_rr_key(ProviderId, Route, Keys, Cursors) ->
    CursorKey = {provider_keys, ProviderId, maps:get(model_id, Route, undefined)},
    {ok, weighted_rr_pick(CursorKey, Keys, Cursors)}.

%% The listing name actually sent upstream: the route's explicit
%% upstream_model_id, else the bound public name, else the listing
%% pick's own name. Deny-map lookups are binary-exact (the
%% binary-vs-atom bug class).
upstream_model_name({listing, Name}, _Route) when is_binary(Name) ->
    Name;
upstream_model_name(_PickKey, Route) ->
    case maps:get(upstream_model_id, Route, undefined) of
        Bin when is_binary(Bin), Bin =/= <<>> ->
            Bin;
        _ ->
            ModelId = maps:get(model_id, Route, undefined),
            case janus_catalog:lookup_model(ModelId) of
                {ok, #{name := N}} when is_binary(N) -> N;
                _ -> undefined
            end
    end.

%% Entitlement/failover observability counters (read by /stats).
-spec bump_stat(atom()) -> ok.
bump_stat(Key) when is_atom(Key) ->
    try
        _ = ets:update_counter(?ENT_STATS, Key, 1, {Key, 0}),
        ok
    catch
        _:_ -> ok
    end.

-spec stats() -> map().
stats() ->
    try
        maps:from_list(ets:tab2list(?ENT_STATS))
    catch
        _:_ -> #{}
    end.

catalog_generation_ok(Opts) ->
    case janus_catalog:get() of
        undefined ->
            false;
        #{generation := Gen} ->
            case maps:get(generation, Opts, undefined) of
                undefined -> true;
                Want when Want =:= Gen -> true;
                _ -> false
            end
    end.

provider_enabled(#{provider_id := ProviderId}) ->
    case janus_catalog:lookup_provider(ProviderId) of
        {ok, #{enabled := false}} -> false;
        {ok, _} -> true;
        error -> false
    end;
provider_enabled(_) ->
    false.

weighted_rr_pick(CursorKey, Items, Cursors) ->
    Expanded = lists:append([lists:duplicate(weight_of(I), I) || I <- Items]),
    case Expanded of
        [] ->
            hd(Items);
        _ ->
            Len = length(Expanded),
            Idx =
                case ets:lookup(Cursors, CursorKey) of
                    [{_, N}] -> N rem Len;
                    [] -> 0
                end,
            ets:insert(Cursors, {CursorKey, Idx + 1}),
            lists:nth(Idx + 1, Expanded)
    end.

%% Defense in depth for the weighted-RR arithmetic (review 01b M2): the
%% catalog already normalizes `weight` on the way in, but this runs in
%% the gen_server's handle_call, so a bad value must never reach
%% lists:duplicate/2 — a negative/non-integer weight raises badarg there
%% and takes the whole LB (and its heir-held state) down, while weight 0
%% silently starves the route. Invalid weights are treated as 1 and
%% logged once per distinct value (a repeat offender is one warning, not
%% one per pick).
weight_of(Item) ->
    case maps:get(weight, Item, 1) of
        W when is_integer(W), W >= 1, W =< ?MAX_WEIGHT ->
            W;
        W ->
            warn_weight_once(W),
            1
    end.

%% Best (lowest) priority among usable routes. A malformed value reads
%% as the default tier 0 — the same default the catalog parser applies
%% — so a hand-built/legacy route map can never crash the pick.
priority_tier(Items) ->
    Min = lists:min([priority_of(I) || I <- Items]),
    [I || I <- Items, priority_of(I) =:= Min].

priority_of(Item) ->
    case maps:get(priority, Item, 0) of
        P when is_integer(P) -> P;
        _ -> 0
    end.

warn_weight_once(W) ->
    Key = {?MODULE, weight_clamped, W},
    case get(Key) of
        undefined ->
            put(Key, true),
            logger:warning(#{
                what => janus_lb_weight_clamped,
                weight => W,
                max_weight => ?MAX_WEIGHT
            });
        _ ->
            ok
    end.

do_note_failure(Target, Reason, State) ->
    do_note_failure(Target, Reason, undefined, State).

%% `ProviderHint` is the owning provider id when the caller knows it
%% (key auth failures) — used ONLY for the cool_edge target's
%% `provider_id`; the cool row itself keeps its legacy shape.
do_note_failure(Target, Reason, ProviderHint, #state{cooldowns = Cool}) ->
    Key = normalize_target(Target),
    SafeReason = sanitize_cooldown_reason(Reason),
    Ms = cooldown_ms(SafeReason),
    Now = erlang:monotonic_time(millisecond),
    Until = Now + Ms,
    %% Prev = the LIVE prior row. An elapsed-but-unswept row is a
    %% finished episode: close it (`expired`) before the new one starts.
    Prev =
        case ets:lookup(Cool, Key) of
            [{_, Existing, PrevR}] when is_integer(Existing), Existing > Now ->
                {Existing, PrevR};
            [{_, Existing}] when is_integer(Existing), Existing > Now ->
                {Existing, undefined};
            [_Stale] ->
                %% ets:take (not the looked-up row): an external
                %% cool_clear/1 racing this window must not double-emit.
                _ = emit_clear_for_taken(ets:take(Cool, Key), ProviderHint),
                none;
            [] ->
                none
        end,
    {FinalUntil, FinalReason, WasCooling} =
        case Prev of
            {Ex, PrevReason} when Ex >= Until, PrevReason =/= undefined ->
                {Ex, PrevReason, true};
            {Ex, _} when Ex >= Until ->
                {Ex, SafeReason, true};
            {_, _} ->
                {Until, SafeReason, true};
            none ->
                {Until, SafeReason, false}
        end,
    ets:insert(Cool, {Key, FinalUntil, FinalReason}),
    lists:foreach(
        fun
            (start) ->
                emit_edge(start, null, Key, FinalReason, FinalUntil, ProviderHint);
            (extend) ->
                emit_edge(extend, null, Key, FinalReason, FinalUntil, ProviderHint);
            ({clear, Cause}) ->
                {PrevUntil, PrevRsn} = Prev,
                emit_edge(clear, Cause, Key, PrevRsn, PrevUntil, ProviderHint)
        end,
        janus_cool_view:edge_plan(Prev, {FinalUntil, FinalReason})
    ),
    case WasCooling of
        false ->
            %% Into-cool transition ONLY (spec Part B storm closure):
            %% one publish per cooldown episode per (Target, Class);
            %% extensions of an existing cooldown never re-publish.
            maybe_publish({lb_cool, Key, min(FinalUntil - Now, ?FLEET_COOL_CAP_MS), FinalReason});
        true ->
            ok
    end,
    logger:info(#{
        what => janus_lb_cooldown,
        target => Key,
        reason => FinalReason,
        ms => FinalUntil - Now
    }),
    ok.

do_note_auth_failure(ProviderId, KeyId, Reason, #state{cooldowns = Cool} = State) ->
    do_note_failure({provider_key, KeyId}, Reason, ProviderId, State),
    Now = erlang:monotonic_time(millisecond),
    %% Escalate only when every enabled key is auth-cooled/disabled.
    %% Rate-limited keys must not trigger a 60s provider blackhole.
    case provider_has_non_auth_blocked_key(ProviderId, Cool, Now) of
        true ->
            ok;
        false ->
            do_note_failure({provider, ProviderId}, Reason, State)
    end.

provider_has_usable_key(ProviderId, Cool, Now) ->
    lists:any(
        fun(K) ->
            maps:get(enabled, K, true) andalso not is_cooling(key_target(K), Cool, Now)
        end,
        janus_catalog:provider_keys(ProviderId)
    ).

provider_has_non_auth_blocked_key(ProviderId, Cool, Now) ->
    lists:any(
        fun(K) ->
            maps:get(enabled, K, true) andalso not is_auth_cooling(key_target(K), Cool, Now)
        end,
        janus_catalog:provider_keys(ProviderId)
    ).

do_note_success(Target, #state{cooldowns = Cool, inflight = Inflight}) ->
    Key = normalize_target(Target),
    %% Edge ONLY (spec Part B): an unexpired cooldown row actually
    %% existed and is being cleared — per-success casts are forbidden.
    %% take (not lookup+delete): the removed row decides the edge —
    %% live => `clear/explicit`, elapsed-but-unswept => `clear/expired`.
    Cleared = emit_clear_for_taken(ets:take(Cool, Key), undefined),
    dec_inflight(Key, Inflight),
    case Cleared of
        true ->
            %% (a) tell peers to drop THIS node's cool-row for the
            %% target (per-sender retraction), and (b) clear the
            %% target's rows in BOTH local remote mirrors — local
            %% evidence wins, literally.
            maybe_publish({lb_recovered, Key}),
            catch janus_fleet:local_success_clear(Key);
        false ->
            ok
    end,
    ok.

do_note_latency(Target, Ms, Lat, Pub) ->
    Now = erlang:monotonic_time(millisecond),
    {Ewma, Samples} =
        case ets:lookup(Lat, Target) of
            [{_, Old, N, _}] ->
                {(?EWMA_ALPHA_PCT * Ms + (100 - ?EWMA_ALPHA_PCT) * Old) div 100, N + 1};
            [] ->
                {Ms, 1}
        end,
    ets:insert(Lat, {Target, Ewma, Samples, Now}),
    Verdict = family_verdict(Target, {Ewma, Samples}, Lat, Now),
    {Entry, Publish} = lat_publish_eval(maps:get(Target, Pub, undefined), Target, Verdict, Ewma, Samples, Now),
    _ =
        case Publish of
            undefined -> ok;
            Msg -> maybe_publish(Msg)
        end,
    Pub#{Target => Entry}.

%% Family-relative local verdict: targets of the same pick family
%% (same model) share alternatives, so the sender-side verdict uses
%% the same eligible-best rule as the pick path's degraded_filter.
family_verdict(Target, Self, Lat, Now) ->
    case family_prefix(Target) of
        undefined ->
            healthy;
        Prefix ->
            Family = fresh_family_samples(Prefix, Lat, Now),
            lat_verdict(Self, Family, degraded_factor_pct(), degraded_floor_ms())
    end.

family_prefix({route, ModelId, _ProviderId}) -> {route, ModelId};
family_prefix(_) -> undefined.

fresh_family_samples(Prefix, Lat, Now) ->
    Pattern = {list_to_tuple(tuple_to_list(Prefix) ++ ['_']), '$1', '$2', '$3'},
    try
        [
            {Ewma, Samples}
         || [Ewma, Samples, Updated] <- ets:match(Lat, Pattern),
            Now - Updated < ?EWMA_STALE_MS
        ]
    catch
        _:_ -> []
    end.

is_cooling(Target, Cool, Now) ->
    case ets:lookup(Cool, Target) of
        [{_, Until, _}] when is_integer(Until), Until > Now -> true;
        [{_, Until}] when is_integer(Until), Until > Now -> true;
        [{_, _, _}] ->
            expire_row(Target, Cool),
            false;
        [{_, _}] ->
            expire_row(Target, Cool),
            false;
        [] ->
            false
    end.

%%--------------------------------------------------------------------
%% note_attempt — cool + rate parity (failure-observability §4.5)
%%--------------------------------------------------------------------

do_note_attempt(#{attempt_id := AttemptId} = Attempt, #state{attempts = Attempts} = State) ->
    case ets:lookup(Attempts, AttemptId) of
        [{_, _}] ->
            State;
        [] ->
            remember_attempt(Attempts, AttemptId),
            apply_attempt(Attempt, State)
    end;
do_note_attempt(_, State) ->
    State.

remember_attempt(Attempts, AttemptId) ->
    %% unique_integer avoids 1ms stamp collisions that made the median
    %% prune delete freshly-inserted attempt ids (ocr Medium on Task 3).
    ets:insert(Attempts, {AttemptId, erlang:unique_integer([monotonic])}),
    case ets:info(Attempts, size) of
        N when is_integer(N), N > ?ATTEMPT_ID_CAP ->
            %% Drop oldest half by stamp (exact: never removes the just-inserted id).
            Cut =
                case ets:tab2list(Attempts) of
                    [] ->
                        0;
                    Rows ->
                        Stamps = lists:sort([T || {_, T} <- Rows]),
                        lists:nth(max(1, length(Stamps) div 2), Stamps)
                end,
            ets:foldl(
                fun
                    ({Id, T}, Acc) when T =< Cut ->
                        ets:delete(Attempts, Id),
                        Acc;
                    (_, Acc) ->
                        Acc
                end,
                ok,
                Attempts
            );
        _ ->
            ok
    end,
    ok.

apply_attempt(#{entity := Entity0, class := Class0} = Attempt, #state{rates = Rates0} = State) ->
    Entity = janus_rate_view:normalize_entity(Entity0),
    Class = janus_rate_view:normalize_class(Class0),
    NowWall = erlang:system_time(millisecond),
    Rates1 = janus_rate_view:touch_record(
        Rates0, Entity, Class, NowWall, janus_rate_view:entity_cap()
    ),
    State1 = State#state{rates = Rates1},
    Reason = maps:get(reason, Attempt, class_default_reason(Class)),
    case Class of
        ok ->
            case entity_to_cool_key(Entity) of
                undefined -> ok;
                Key -> do_note_success(Key, State1)
            end,
            State1;
        _ ->
            case janus_rate_view:cools(Class) of
                true ->
                    apply_attempt_cool(Entity, Class, Reason, State1);
                false ->
                    State1
            end
    end.

apply_attempt_cool(Entity, Class, Reason, #state{cooldowns = Cool} = State) ->
    case entity_to_cool_key(Entity) of
        undefined ->
            State;
        {provider_key, _KeyId} = Key ->
            ProviderId = parse_entity_id(maps:get(provider_id, Entity)),
            do_note_failure(Key, cool_reason(Class, Reason), ProviderId, State),
            %% Auth escalation mirrors note_auth_failure: cool the
            %% provider when every enabled key is auth-blocked. Rate
            %% counters stay on the key entity only (one attempt_id).
            case Class =:= auth of
                true ->
                    Now = erlang:monotonic_time(millisecond),
                    case provider_has_non_auth_blocked_key(ProviderId, Cool, Now) of
                        true -> ok;
                        false -> do_note_failure({provider, ProviderId}, cool_reason(Class, Reason), State)
                    end;
                false ->
                    ok
            end,
            State;
        Key ->
            do_note_failure(Key, cool_reason(Class, Reason), State),
            State
    end.

cool_reason(_Class, Reason) when Reason =/= undefined, Reason =/= ok ->
    Reason;
cool_reason(Class, _) ->
    class_default_reason(Class).

class_default_reason(auth) -> {auth, 401};
class_default_reason(rate) -> {http, 429};
class_default_reason(balance) -> {http, 402};
class_default_reason(deny) -> {http, 403};
class_default_reason(input_shape) -> {http, 400};
class_default_reason(upstream_5xx) -> {http, 503};
class_default_reason(transport) -> timeout;
class_default_reason(unclassified) -> failure;
class_default_reason(_) -> failure.

entity_to_cool_key(#{kind := <<"provider">>, id := Id}) ->
    {provider, parse_entity_id(Id)};
entity_to_cool_key(#{kind := <<"provider_key">>, id := Id}) ->
    {provider_key, parse_entity_id(Id)};
%% Match `route_target/1`: always `{route, ModelId, ProviderId}` so
%% pick-path `is_cooling` sees the same key (model_id may be null).
entity_to_cool_key(#{kind := <<"route">>, id := Id, model_id := ModelId}) ->
    {route, parse_entity_id(ModelId), parse_entity_id(Id)};
entity_to_cool_key(_) ->
    undefined.

parse_entity_id(I) when is_integer(I) -> I;
parse_entity_id(B) when is_binary(B) ->
    try
        binary_to_integer(B)
    catch
        _:_ -> B
    end;
parse_entity_id(A) when is_atom(A) -> A;
parse_entity_id(Other) ->
    Other.

project_rates(Cool, Rates) ->
    NowMono = erlang:monotonic_time(millisecond),
    NowWall = erlang:system_time(millisecond),
    Rows =
        try
            ets:tab2list(Cool)
        catch
            _:_ -> []
        end,
    {Live, _} = janus_cool_view:split_expired(Rows, NowMono),
    Idx = janus_catalog:key_provider_index(),
    ProviderOf = fun(KeyId) -> maps:get(KeyId, Idx, undefined) end,
    Cooling = sets:from_list([
        janus_cool_view:target_json(K, ProviderOf)
     || {K, _, _} <- Live, janus_cool_view:valid_target(K)
    ]),
    janus_rate_view:project(Rates, Cooling, NowWall).

%%--------------------------------------------------------------------
%% cool_edge emission + expiry sweeper (failure-observability §4.2)
%%--------------------------------------------------------------------

%% Remove elapsed rows and emit `clear/expired`. Runs inside the LB
%% gen_server (tick + sweep_cool/0 call), i.e. under the same
%% serialization as note_failure/is_cooling; ets:take keeps it safe
%% against an external cool_clear/1 racing the same row (only the taker
%% emits).
do_sweep(Cool) ->
    Now = erlang:monotonic_time(millisecond),
    Rows =
        try
            ets:tab2list(Cool)
        catch
            _:_ -> []
        end,
    {_Live, Expired} = janus_cool_view:split_expired(Rows, Now),
    case Expired of
        [] ->
            ok;
        _ ->
            %% One catalog index fold per sweep, not one per expired row.
            Hint = {index, janus_catalog:key_provider_index()},
            lists:foreach(
                fun({Key, _, _}) ->
                    _ = emit_clear_for_taken(ets:take(Cool, Key), Hint)
                end,
                Expired
            )
    end.

%% Lazy expiry (pick path / sweeper): drop the row and keep the edge —
%% the sweeper must not be the only place `expired` can be observed.
expire_row(Key, Cool) ->
    _ = emit_clear_for_taken(ets:take(Cool, Key), undefined),
    ok.

%% Emit the clear edge for rows just removed from the cool table.
%% Returns true iff a LIVE cool row was cleared (the fleet
%% `lb_recovered` publish predicate); an elapsed row emits
%% `clear/expired` and returns false.
emit_clear_for_taken([Row], Hint) ->
    Now = erlang:monotonic_time(millisecond),
    case janus_cool_view:norm_row(Row) of
        {Key, Until, Reason} when is_integer(Until), Until > Now ->
            emit_edge(clear, explicit, Key, Reason, Until, Hint),
            true;
        {Key, Until, Reason} when is_integer(Until) ->
            emit_edge(clear, expired, Key, Reason, Until, Hint),
            false;
        _ ->
            false
    end;
emit_clear_for_taken(_, _) ->
    false.

%% Never raises, never blocks (ops_tail:push/1 is a cast): the LB hot
%% path must not depend on the observability ring.
emit_edge(Action, Cause, Key, Reason, UntilMono, Hint) ->
    try
        case janus_cool_view:valid_target(Key) of
            true ->
                janus_ops_tail:push(
                    janus_cool_view:edge_event(
                        Action,
                        Cause,
                        Key,
                        Reason,
                        UntilMono,
                        janus_cool_view:clock(),
                        edge_provider_fun(Hint)
                    )
                );
            false ->
                ok
        end
    catch
        _:_ -> ok
    end.

edge_provider_fun(undefined) ->
    fun(KeyId) -> maps:get(KeyId, janus_catalog:key_provider_index(), undefined) end;
edge_provider_fun({index, Idx}) when is_map(Idx) ->
    fun(KeyId) -> maps:get(KeyId, Idx, undefined) end;
edge_provider_fun(ProviderId) ->
    fun(_KeyId) -> ProviderId end.

is_auth_cooling(Target, Cool, Now) ->
    case ets:lookup(Cool, Target) of
        [{_, Until, {auth, _}}] when is_integer(Until), Until > Now -> true;
        _ -> false
    end.

remaining_cooldown_ms(Routes, Cool, Now) when is_list(Routes) ->
    Remainings =
        lists:filtermap(
            fun(R) ->
                case cooldown_remaining(provider_target(R), Cool, Now) of
                    Ms when is_integer(Ms), Ms > 0 -> {true, Ms};
                    _ ->
                        case cooldown_remaining(route_target(R), Cool, Now) of
                            Ms2 when is_integer(Ms2), Ms2 > 0 -> {true, Ms2};
                            _ -> false
                        end
                end
            end,
            Routes
        ),
    case Remainings of
        [] -> ?DEFAULT_COOLDOWN_MS;
        _ -> lists:min(Remainings)
    end.

cooldown_remaining(Target, Cool, Now) ->
    case ets:lookup(Cool, Target) of
        [{_, Until, _}] when is_integer(Until), Until > Now -> Until - Now;
        [{_, Until}] when is_integer(Until), Until > Now -> Until - Now;
        _ -> 0
    end.

bump_inflight(Target, Inflight) ->
    Key = normalize_target(Target),
    case ets:lookup(Inflight, Key) of
        [{_, N}] -> ets:insert(Inflight, {Key, N + 1});
        [] -> ets:insert(Inflight, {Key, 1})
    end.

dec_inflight(Target, Inflight) ->
    Key = normalize_target(Target),
    case ets:lookup(Inflight, Key) of
        [{_, N}] when N > 1 -> ets:insert(Inflight, {Key, N - 1});
        [{_, _}] -> ets:delete(Inflight, Key);
        [] -> ok
    end.

route_target(#{provider_id := P, model_id := M}) ->
    {route, M, P};
route_target(#{provider_id := P}) ->
    {route, null, P};
route_target(Other) ->
    normalize_target(Other).

provider_target(#{provider_id := P}) ->
    {provider, P};
provider_target(Other) ->
    normalize_target(Other).

key_target(#{id := Id}) ->
    {provider_key, Id};
key_target(Other) ->
    normalize_target(Other).

normalize_target({provider, _} = T) -> T;
normalize_target({provider_key, _} = T) -> T;
normalize_target({provider_key, _P, K}) -> {provider_key, K};
normalize_target({route, _, _} = T) -> T;
%% Fold legacy 2-tuple listing routes onto the pick-path 3-tuple so
%% cool_clear / fleet mirrors hit rows written by entity_to_cool_key/1.
normalize_target({route, P}) -> {route, null, P};
normalize_target(#{provider_id := _P, key_id := K}) -> {provider_key, K};
normalize_target(#{provider_id := P, model_id := M}) -> {route, M, P};
normalize_target(#{provider_id := P}) -> {provider, P};
normalize_target(#{id := Id}) -> {provider_key, Id};
normalize_target(Target) -> Target.

cooldown_ms({auth, _}) ->
    case os:getenv("JANUS_LB_AUTH_COOLDOWN_MS") of
        false ->
            ?AUTH_COOLDOWN_MS;
        "" ->
            ?AUTH_COOLDOWN_MS;
        Val ->
            try
                case list_to_integer(Val) of
                    Ms when is_integer(Ms), Ms > 0 -> min(Ms, ?MAX_RETRY_AFTER_MS);
                    _ -> ?AUTH_COOLDOWN_MS
                end
            catch
                _:_ -> ?AUTH_COOLDOWN_MS
            end
    end;
cooldown_ms({retry_after, Ms}) when is_integer(Ms), Ms > 0 ->
    min(Ms, ?MAX_RETRY_AFTER_MS);
cooldown_ms(#{retry_after_ms := Ms}) when is_integer(Ms), Ms > 0 ->
    min(Ms, ?MAX_RETRY_AFTER_MS);
cooldown_ms(_Reason) ->
    case os:getenv("JANUS_LB_COOLDOWN_MS") of
        false ->
            ?DEFAULT_COOLDOWN_MS;
        "" ->
            ?DEFAULT_COOLDOWN_MS;
        Val ->
            try
                case list_to_integer(Val) of
                    Ms when is_integer(Ms), Ms > 0 -> Ms;
                    _ -> ?DEFAULT_COOLDOWN_MS
                end
            catch
                _:_ -> ?DEFAULT_COOLDOWN_MS
            end
    end.

sanitize_cooldown_reason({auth, N}) when is_integer(N) -> {auth, N};
sanitize_cooldown_reason(R) when is_atom(R) -> R;
sanitize_cooldown_reason({http, N}) when is_integer(N) -> {http, N};
sanitize_cooldown_reason({retry_after, Ms}) when is_integer(Ms) -> {retry_after, Ms};
sanitize_cooldown_reason({Tag, Sub}) when is_atom(Tag), is_atom(Sub) -> {Tag, Sub};
sanitize_cooldown_reason({Tag, _}) when is_atom(Tag) -> Tag;
sanitize_cooldown_reason(_) -> failure.


%% Count routes currently in cooldown (for /stats reporting).
cooling_count() ->
    try
        Now = erlang:monotonic_time(millisecond),
        Tid = janus_lb_cooldowns,
        ets:foldl(
            fun
                ({_Key, Until, _Reason}, Acc) when is_integer(Until) ->
                    case Until > Now of
                        true -> Acc + 1;
                        false -> Acc
                    end;
                ({_Key, Until}, Acc) when is_integer(Until) ->
                    case Until > Now of
                        true -> Acc + 1;
                        false -> Acc
                    end;
                (_, Acc) ->
                    Acc
            end,
            0,
            Tid
        )
    catch
        _:_ -> 0
    end.
