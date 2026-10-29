%%%-------------------------------------------------------------------
%%% @doc PURE rate-window math + `/stats/health` rates projection
%%% (failure-observability spec 2026-10-13 §4.1, plan Task 3).
%%%
%%% Wall-clock 60s / 300s approximated by **12 fixed buckets**
%%% (5s / 25s). Ratio = sum(failures)/sum(attempts) over the last N
%%% whole buckets (boundary bucket counted whole — bucket-granularity).
%%%
%%% No ETS / clock / catalog reads — the LB injects wall time and the
%%% cooling-entity set so every function is eunit-testable with
%%% production-shaped fixtures (binary entity ids, class atoms).
%%%
%%% Failure modes guarded:
%%%   * input_shape|deny|ok never inflate failure counts
%%%   * worker_lost|crash count as failures
%%%   * attempts=0 ⇒ failure_ratio null (no-data)
%%%   * degraded only on the 5m window
%%%   * rates[] cap 200 + rates_truncated; degraded_ids cap 500;
%%%     rates_evicted cap 100 + overflow
%%%   * entity map max 500 with LRU eviction into rates_evicted
%%% @end
%%%-------------------------------------------------------------------
-module(janus_rate_view).

-export([
    bucket_1m_ms/0,
    bucket_5m_ms/0,
    entity_cap/0,
    rates_cap/0,
    degraded_ids_cap/0,
    evicted_cap/0,
    counts_as_failure/1,
    cools/1,
    empty_ring/2,
    bump/2,
    advance/3,
    sum/1,
    window_totals/1,
    record_class/2,
    failure_ratio/2,
    is_degraded/2,
    empty_state/0,
    put_entity/4,
    touch_record/5,
    project/3,
    normalize_class/1,
    normalize_entity/1
]).

-define(BUCKETS, 12).
-define(BUCKET_1M_MS, 5000).
-define(BUCKET_5M_MS, 25000).
-define(ENTITY_CAP, 500).
-define(RATES_CAP, 200).
-define(DEGRADED_IDS_CAP, 500).
-define(EVICTED_CAP, 100).
-define(CLASS_ATOMS, [
    auth,
    rate,
    balance,
    deny,
    input_shape,
    upstream_5xx,
    transport,
    unclassified,
    worker_lost,
    crash,
    ok
]).

-type entity() :: #{
    kind := binary(),
    id := binary(),
    provider_id := binary(),
    model_id := binary() | null
}.
-type ring() :: {non_neg_integer(), non_neg_integer(), tuple()}.
-type class() :: atom() | binary().

-export_type([entity/0, ring/0, class/0]).

bucket_1m_ms() -> ?BUCKET_1M_MS.
bucket_5m_ms() -> ?BUCKET_5M_MS.
entity_cap() -> ?ENTITY_CAP.
rates_cap() -> ?RATES_CAP.
degraded_ids_cap() -> ?DEGRADED_IDS_CAP.
evicted_cap() -> ?EVICTED_CAP.

%%--------------------------------------------------------------------
%% Class accounting
%%--------------------------------------------------------------------

-spec counts_as_failure(class()) -> boolean().
counts_as_failure(C) ->
    case normalize_class(C) of
        auth -> true;
        rate -> true;
        balance -> true;
        upstream_5xx -> true;
        transport -> true;
        unclassified -> true;
        worker_lost -> true;
        crash -> true;
        _ -> false
    end.

%% @doc Classes that apply cool via note_attempt. Includes deny/input_shape
%% (cool reasons per spec §4.4) even though they are excluded from rate
%% failure counts; worker_lost/crash/ok never cool through this path.
-spec cools(class()) -> boolean().
cools(C) ->
    case normalize_class(C) of
        auth -> true;
        rate -> true;
        balance -> true;
        upstream_5xx -> true;
        transport -> true;
        unclassified -> true;
        deny -> true;
        input_shape -> true;
        _ -> false
    end.

-spec normalize_class(class()) -> atom().
normalize_class(C) when is_atom(C) ->
    case lists:member(C, ?CLASS_ATOMS) of
        true -> C;
        false -> unclassified
    end;
normalize_class(C) when is_binary(C) ->
    case C of
        <<"auth">> -> auth;
        <<"rate">> -> rate;
        <<"balance">> -> balance;
        <<"deny">> -> deny;
        <<"input_shape">> -> input_shape;
        <<"upstream_5xx">> -> upstream_5xx;
        <<"transport">> -> transport;
        <<"unclassified">> -> unclassified;
        <<"worker_lost">> -> worker_lost;
        <<"crash">> -> crash;
        <<"ok">> -> ok;
        _ -> unclassified
    end;
normalize_class(_) ->
    unclassified.

%%--------------------------------------------------------------------
%% Rings
%%--------------------------------------------------------------------

-spec empty_ring(non_neg_integer(), pos_integer()) -> ring().
empty_ring(NowWallMs, BucketMs) when is_integer(NowWallMs), is_integer(BucketMs), BucketMs > 0 ->
    Epoch = NowWallMs - (NowWallMs rem BucketMs),
    Buckets = list_to_tuple(lists:duplicate(?BUCKETS, {0, 0})),
    {Epoch, 0, Buckets}.

-spec bump(ring(), boolean()) -> ring().
bump({Epoch, Idx, Buckets}, IsFailure) when Idx >= 0, Idx < ?BUCKETS ->
    {A, F} = element(Idx + 1, Buckets),
    F1 =
        case IsFailure of
            true -> F + 1;
            false -> F
        end,
    {Epoch, Idx, setelement(Idx + 1, Buckets, {A + 1, F1})}.

-spec advance(non_neg_integer(), pos_integer(), ring()) -> ring().
advance(NowWallMs, BucketMs, {Epoch, Idx, Buckets}) ->
    TargetEpoch = NowWallMs - (NowWallMs rem BucketMs),
    case TargetEpoch =< Epoch of
        true ->
            {Epoch, Idx, Buckets};
        false ->
            Steps = (TargetEpoch - Epoch) div BucketMs,
            advance_n(Steps, TargetEpoch, Idx, Buckets, BucketMs)
    end.

advance_n(0, Epoch, Idx, Buckets, _BucketMs) ->
    {Epoch, Idx, Buckets};
advance_n(Steps, TargetEpoch, _Idx, _Buckets, _BucketMs) when Steps >= ?BUCKETS ->
    %% Full wrap: every bucket is stale — zero the ring, land on target.
    {TargetEpoch, 0, list_to_tuple(lists:duplicate(?BUCKETS, {0, 0}))};
advance_n(Steps, TargetEpoch, Idx, Buckets, _BucketMs) ->
    {Idx2, Buckets2} = roll(Steps, Idx, Buckets),
    {TargetEpoch, Idx2, Buckets2}.

roll(0, Idx, Buckets) ->
    {Idx, Buckets};
roll(N, Idx, Buckets) when N > 0 ->
    Next = (Idx + 1) rem ?BUCKETS,
    roll(N - 1, Next, setelement(Next + 1, Buckets, {0, 0})).

-spec sum(ring()) -> {non_neg_integer(), non_neg_integer()}.
sum({_Epoch, _Idx, Buckets}) ->
    lists:foldl(
        fun(I, {A, F}) ->
            {Ba, Bf} = element(I, Buckets),
            {A + Ba, F + Bf}
        end,
        {0, 0},
        lists:seq(1, ?BUCKETS)
    ).

window_totals(Ring) ->
    sum(Ring).

-spec record_class(ring(), class()) -> ring().
record_class(Ring, Class) ->
    bump(Ring, counts_as_failure(Class)).

-spec failure_ratio(non_neg_integer(), non_neg_integer()) -> float() | null.
failure_ratio(0, _) -> null;
failure_ratio(Attempts, Failures) when Attempts > 0 ->
    Failures / Attempts.

-spec is_degraded(non_neg_integer(), non_neg_integer()) -> boolean().
is_degraded(Attempts, Failures) ->
    Ratio = failure_ratio(Attempts, Failures),
    Failures >= 10 orelse (is_number(Ratio) andalso Ratio >= 0.5 andalso Attempts >= 20).

%%--------------------------------------------------------------------
%% Entity state (pure map; LB owns persistence)
%%--------------------------------------------------------------------

-spec empty_state() -> map().
empty_state() ->
    #{entities => #{}, evicted => [], evicted_overflow => false}.

%% Total: never throws; bad/partial maps land on a stable unknown entity.
-spec normalize_entity(term()) -> entity().
normalize_entity(E) when is_map(E) ->
    #{
        kind => to_bin(maps:get(kind, E, <<"unknown">>)),
        id => to_bin(maps:get(id, E, <<"unknown">>)),
        provider_id => to_bin(maps:get(provider_id, E, <<"unknown">>)),
        model_id =>
            case maps:get(model_id, E, null) of
                null -> null;
                undefined -> null;
                M -> to_bin(M)
            end
    };
normalize_entity(_) ->
    #{
        kind => <<"unknown">>,
        id => <<"unknown">>,
        provider_id => <<"unknown">>,
        model_id => null
    }.

to_bin(B) when is_binary(B) -> B;
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(A) when is_atom(A), A =/= undefined, A =/= null -> atom_to_binary(A, utf8);
to_bin(_) -> <<"unknown">>.

%% @doc Ensure entity exists (empty rings); LRU-evict if over Cap.
-spec put_entity(map(), entity(), non_neg_integer(), pos_integer()) -> map().
put_entity(State, Entity0, NowMs, Cap) ->
    Entity = normalize_entity(Entity0),
    Ents0 = maps:get(entities, State, #{}),
    Evicted0 = maps:get(evicted, State, []),
    Overflow0 = maps:get(evicted_overflow, State, false),
    case maps:get(Entity, Ents0, undefined) of
        undefined ->
            Rec = new_record(NowMs),
            Ents1 = Ents0#{Entity => Rec},
            {Ents2, Evicted1, Overflow1} = maybe_evict(Ents1, Evicted0, Overflow0, Cap),
            State#{entities => Ents2, evicted => Evicted1, evicted_overflow => Overflow1};
        Rec ->
            State#{entities => Ents0#{Entity => Rec#{last_ms => NowMs}}}
    end.

new_record(NowMs) ->
    #{
        ring_1m => empty_ring(NowMs, ?BUCKET_1M_MS),
        ring_5m => empty_ring(NowMs, ?BUCKET_5M_MS),
        last_ms => NowMs
    }.

maybe_evict(Ents, Evicted, Overflow, Cap) when map_size(Ents) =< Cap ->
    {Ents, Evicted, Overflow};
maybe_evict(Ents, Evicted, Overflow, _Cap) ->
    %% Evict the oldest last_ms entity (caller already knows size > Cap).
    {Victim, _} =
        maps:fold(
            fun(E, #{last_ms := T}, Acc) ->
                case Acc of
                    undefined -> {E, T};
                    {_, BestT} when T < BestT -> {E, T};
                    Keep -> Keep
                end
            end,
            undefined,
            Ents
        ),
    %% Newest-first; trim in place so the list cannot grow unbounded.
    Evicted1 = [Victim | Evicted],
    {Evicted2, Overflow2} = trim_evicted(Evicted1, Overflow),
    {maps:remove(Victim, Ents), Evicted2, Overflow2}.

trim_evicted(Evicted, Overflow) ->
    case length(Evicted) > ?EVICTED_CAP of
        true -> {lists:sublist(Evicted, ?EVICTED_CAP), true};
        false -> {Evicted, Overflow}
    end.

%% @doc Advance both rings to NowMs and record Class against Entity.
-spec touch_record(map(), entity(), class(), non_neg_integer(), pos_integer()) -> map().
touch_record(State0, Entity0, Class, NowMs, Cap) ->
    Entity = normalize_entity(Entity0),
    State1 = put_entity(State0, Entity, NowMs, Cap),
    Ents = maps:get(entities, State1),
    Rec0 = maps:get(Entity, Ents),
    R1 = advance(NowMs, ?BUCKET_1M_MS, maps:get(ring_1m, Rec0)),
    R5 = advance(NowMs, ?BUCKET_5M_MS, maps:get(ring_5m, Rec0)),
    Rec1 = #{
        ring_1m => record_class(R1, Class),
        ring_5m => record_class(R5, Class),
        last_ms => NowMs
    },
    State1#{entities => Ents#{Entity => Rec1}}.

%%--------------------------------------------------------------------
%% Snapshot projection
%%--------------------------------------------------------------------

-spec project(map(), sets:set(entity()), non_neg_integer()) -> map().
project(State, CoolingSet, NowMs) ->
    Ents = maps:get(entities, State, #{}),
    %% Evicted is newest-first (see maybe_evict); keep newest 100.
    EvictedAll = maps:get(evicted, State, []),
    Rows = lists:append([
        entity_rows(E, Rec, CoolingSet, NowMs)
     || {E, Rec} <- maps:to_list(Ents)
    ]),
    Sorted = lists:sort(fun rate_before/2, Rows),
    Trunc = length(Sorted) > ?RATES_CAP,
    Rates = lists:sublist(Sorted, ?RATES_CAP),
    DegAll = [
        E
     || {E, Rec} <- maps:to_list(Ents),
        begin
            Ring5 = advance(NowMs, ?BUCKET_5M_MS, maps:get(ring_5m, Rec)),
            {A, F} = sum(Ring5),
            is_degraded(A, F)
        end
    ],
    DegSorted = lists:sort(fun(A, B) -> entity_sort_key(A) =< entity_sort_key(B) end, DegAll),
    DegOverflow = length(DegSorted) > ?DEGRADED_IDS_CAP,
    DegIds = lists:sublist(DegSorted, ?DEGRADED_IDS_CAP),
    EvOverflow =
        maps:get(evicted_overflow, State, false) orelse length(EvictedAll) > ?EVICTED_CAP,
    Evicted = lists:sublist(EvictedAll, ?EVICTED_CAP),
    #{
        rates => Rates,
        rates_truncated => Trunc,
        degraded_ids => DegIds,
        degraded_ids_overflow => DegOverflow,
        rates_evicted => Evicted,
        rates_evicted_overflow => EvOverflow
    }.

entity_rows(Entity, Rec, CoolingSet, NowMs) ->
    Cooling = sets:is_element(Entity, CoolingSet),
    R1 = advance(NowMs, ?BUCKET_1M_MS, maps:get(ring_1m, Rec)),
    R5 = advance(NowMs, ?BUCKET_5M_MS, maps:get(ring_5m, Rec)),
    {A1, F1} = sum(R1),
    {A5, F5} = sum(R5),
    Deg5 = is_degraded(A5, F5),
    [
        row(Entity, <<"5m">>, A5, F5, Deg5, Cooling),
        row(Entity, <<"1m">>, A1, F1, false, Cooling)
    ].

row(Entity, Window, Attempts, Failures, Degraded, Cooling) ->
    #{
        entity => Entity,
        window => Window,
        attempts => Attempts,
        failures => Failures,
        failure_ratio => failure_ratio(Attempts, Failures),
        degraded => Degraded,
        cooling => Cooling
    }.

%% degraded → cooling → failures desc → id
rate_before(A, B) ->
    rate_key(A) =< rate_key(B).

rate_key(#{degraded := D, cooling := C, failures := F, entity := E, window := W}) ->
    {
        not D,
        not C,
        -F,
        entity_sort_key(E),
        %% 5m before 1m when otherwise equal
        case W of
            <<"5m">> -> 0;
            _ -> 1
        end
    }.

entity_sort_key(#{kind := K, id := Id, provider_id := P, model_id := M}) ->
    {K, Id, P, M}.
