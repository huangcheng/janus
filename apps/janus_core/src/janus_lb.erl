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

-export([start_link/0, cooling_count/0]).
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
-define(DEFAULT_COOLDOWN_MS, 5000).
-define(AUTH_COOLDOWN_MS, 60000).
-define(MAX_RETRY_AFTER_MS, 300000).
%% Latency shedding: EWMA of upstream call wall time per route target.
%% A candidate is degraded when its EWMA exceeds BOTH the absolute
%% floor and FACTOR x the best eligible peer (>= MIN_SAMPLES samples).
-define(EWMA_ALPHA_PCT, 25).
-define(EWMA_MIN_SAMPLES, 4).
-define(EWMA_CLAMP_MS, 30000).
-define(EWMA_STALE_MS, 600000).
-define(DEFAULT_DEGRADED_FACTOR_PCT, 300).
-define(DEFAULT_DEGRADED_FLOOR_MS, 1500).

-record(state, {
    cooldowns :: ets:tid(),
    inflight :: ets:tid(),
    cursors :: ets:tid(),
    latency :: ets:tid()
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
    Cool = ets:new(?COOLDOWNS, [
        named_table, set, public, {read_concurrency, true}, {write_concurrency, true}
    ]),
    Inflight = ets:new(?INFLIGHT, [
        named_table, set, public, {write_concurrency, true}
    ]),
    Cursors = ets:new(?CURSORS, [
        named_table, set, public, {write_concurrency, true}
    ]),
    _ = ets:new(?ENT_STATS, [
        named_table, set, public, {write_concurrency, true}
    ]),
    Latency = ets:new(?LATENCY, [
        named_table, set, public, {read_concurrency, true}, {write_concurrency, true}
    ]),
    logger:info(#{what => janus_lb_started}),
    {ok, #state{cooldowns = Cool, inflight = Inflight, cursors = Cursors, latency = Latency}}.

handle_call({pick_route, ModelId, Opts}, _From, State) ->
    {reply, do_pick_route(ModelId, Opts, State), State};
handle_call({pick_listing_route, Name, Opts}, _From, State) ->
    {reply, do_pick_listing_route(Name, Opts, State), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({note_failure, Target, Reason}, State) ->
    do_note_failure(Target, Reason, State),
    {noreply, State};
handle_cast({note_auth_failure, ProviderId, KeyId, Reason}, State) ->
    do_note_auth_failure(ProviderId, KeyId, Reason, State),
    {noreply, State};
handle_cast({note_success, Target}, State) ->
    do_note_success(Target, State),
    {noreply, State};
handle_cast({note_latency, Target, Ms}, #state{latency = Lat} = State) ->
    do_note_latency(normalize_target(Target), Ms, Lat),
    {noreply, State};
handle_cast({release_inflight, Target}, #state{inflight = Inflight} = State) ->
    dec_inflight(Target, Inflight),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

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
            pick_from_routes(ModelId, janus_catalog:routes_for_model(ModelId), Opts, State)
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
    Routes1 =
        protocol_filter(
            [R || R <- Routes0, maps:get(enabled, R, true)], Opts, fun route_protocol/1
        ),
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
            case Available0 of
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
                    Available = prefer_proto_routes(Available0, Opts),
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
%% (falls back to the full usable set when data is insufficient).
pick_usable_route(PickKey, Candidates, Cool, Cursors, Now, Inflight, Lat) ->
    Usable = [R || R <- Candidates, has_usable_key(R, Cool, Now)],
    case Usable of
        [] ->
            {error, classify_key_failures(Candidates, Cool, Now)};
        _ ->
            Healthy = degraded_filter(Usable, latency_fun(Lat), degraded_factor_pct(), degraded_floor_ms()),
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
    Expanded = lists:append([lists:duplicate(maps:get(weight, I, 1), I) || I <- Items]),
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

do_note_failure(Target, Reason, #state{cooldowns = Cool}) ->
    Key = normalize_target(Target),
    SafeReason = sanitize_cooldown_reason(Reason),
    Ms = cooldown_ms(SafeReason),
    Now = erlang:monotonic_time(millisecond),
    Until = Now + Ms,
    {FinalUntil, FinalReason} =
        case ets:lookup(Cool, Key) of
            [{_, Existing, PrevReason}] when is_integer(Existing), Existing > Now ->
                case Existing >= Until of
                    true -> {Existing, PrevReason};
                    false -> {Until, SafeReason}
                end;
            [{_, Existing}] when is_integer(Existing), Existing > Now ->
                {max(Existing, Until), SafeReason};
            _ ->
                {Until, SafeReason}
        end,
    ets:insert(Cool, {Key, FinalUntil, FinalReason}),
    logger:info(#{
        what => janus_lb_cooldown,
        target => Key,
        reason => FinalReason,
        ms => FinalUntil - Now
    }),
    ok.

do_note_auth_failure(ProviderId, KeyId, Reason, #state{cooldowns = Cool} = State) ->
    do_note_failure({provider_key, KeyId}, Reason, State),
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
    ets:delete(Cool, Key),
    dec_inflight(Key, Inflight),
    ok.

do_note_latency(Target, Ms, Lat) ->
    Now = erlang:monotonic_time(millisecond),
    {Ewma, Samples} =
        case ets:lookup(Lat, Target) of
            [{_, Old, N, _}] ->
                {(?EWMA_ALPHA_PCT * Ms + (100 - ?EWMA_ALPHA_PCT) * Old) div 100, N + 1};
            [] ->
                {Ms, 1}
        end,
    ets:insert(Lat, {Target, Ewma, Samples, Now}),
    ok.

is_cooling(Target, Cool, Now) ->
    case ets:lookup(Cool, Target) of
        [{_, Until, _}] when is_integer(Until), Until > Now -> true;
        [{_, Until}] when is_integer(Until), Until > Now -> true;
        [{_, _, _}] ->
            ets:delete(Cool, Target),
            false;
        [{_, _}] ->
            ets:delete(Cool, Target),
            false;
        [] ->
            false
    end.

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
    {route, P};
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
normalize_target({route, _} = T) -> T;
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
