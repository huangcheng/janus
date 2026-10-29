%%%-------------------------------------------------------------------
%%% @doc PURE projection of `janus_lb` cool-down ETS rows into the
%%% `/stats/health` cool snapshot and `cool_edge` ops-ring payloads
%%% (failure-observability spec 2026-10-13 §4.1 / §4.2, plan Task 2).
%%%
%%% No ETS, no clock reads, no catalog reads in here — the caller
%%% injects `Clock = {NowMono, NowWallMs}` and a `ProviderOf :: fun((KeyId)
%%% -> ProviderId | undefined)` so every function is eunit-testable with
%%% production-shaped fixtures.
%%%
%%% Cool rows (owned by `janus_lb`): `{Key, UntilMono, Reason}` (legacy
%%% 2-tuple `{Key, UntilMono}` tolerated), `Key` one of
%%% `{provider_key, KeyId}` | `{provider, ProviderId}` |
%%% `{route, ModelId | null, ProviderId}` | `{route, ProviderId}`;
%%% `UntilMono` is `erlang:monotonic_time(millisecond)`; `Reason` the
%%% sanitized shapes the proxy emits.
%%%
%%% Failure modes guarded:
%%%   * `provider_id` ALWAYS set on a target (the catalog may not know a
%%%     key deleted mid-cooldown: `<<"unknown">>`, never null/missing).
%%%   * Ids are rendered as binaries (BIGSERIAL integers on the wire
%%%     must not become JSON numbers the dashboard cannot key on).
%%%   * Unrecognised target shapes are dropped, never emitted (they
%%%     would break the dashboard's `kind` enum).
%%%   * Expired rows never appear in `cool` / `cool_ids` (the sweeper
%%%     owns the `clear`/`expired` edge; the projection is a pure read).
%%%   * Caps: `cool` 100, `cool_ids` 2000 (+ exact `cool_count`,
%%%     `cool_ids_overflow`, `cool_provider_counts` over ALL cooling
%%%     targets when truncated).
%%%   * Extend storms: a re-cool computes `Until = Now + Ms`, which
%%%     creeps forward by a few ms per failed in-flight call. An
%%%     `extend` edge is emitted only when until moved by at least
%%%     `extend_min_delta_ms/0`, so a storm cannot flood the 2000-slot
%%%     ring (the ETS row and the snapshot still carry the exact value).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_cool_view).

-export([
    clock/0,
    reason_class/1,
    error_code/1,
    valid_target/1,
    target_json/2,
    norm_row/1,
    split_expired/2,
    project/3,
    provider_counts/3,
    edge_plan/2,
    edge_event/7,
    extend_min_delta_ms/0,
    detail_cap/0,
    ids_cap/0
]).

-define(DETAIL_CAP, 100).
-define(IDS_CAP, 2000).
-define(EXTEND_MIN_DELTA_MS, 1000).
-define(UNKNOWN, <<"unknown">>).

-type clock() :: {integer(), integer()}.
-type provider_of() :: fun((term()) -> term() | undefined).

-export_type([clock/0, provider_of/0]).

detail_cap() -> ?DETAIL_CAP.
ids_cap() -> ?IDS_CAP.
extend_min_delta_ms() -> ?EXTEND_MIN_DELTA_MS.

%% @doc `{NowMono, NowWallMs}` captured together so mono->wall
%% conversion within one snapshot/edge is self-consistent.
-spec clock() -> clock().
clock() ->
    {erlang:monotonic_time(millisecond), erlang:system_time(millisecond)}.

%%--------------------------------------------------------------------
%% Reason -> enum / code
%%--------------------------------------------------------------------

%% @doc Map an LB cool reason onto the spec §4.4 enum
%% (`auth|rate|balance|deny|input_shape|unclassified|upstream_5xx|transport`).
-spec reason_class(term()) -> binary().
reason_class({auth, _}) -> <<"auth">>;
reason_class({retry_after, _}) -> <<"rate">>;
reason_class({http, 429}) -> <<"rate">>;
reason_class({http, 402}) -> <<"balance">>;
reason_class({http, 403}) -> <<"deny">>;
reason_class({http, 400}) -> <<"input_shape">>;
reason_class({http, N}) when is_integer(N), N >= 500, N =< 599 -> <<"upstream_5xx">>;
reason_class({http, _}) -> <<"unclassified">>;
reason_class({Tag, _}) when is_atom(Tag) ->
    case is_transport_tag(Tag) of
        true -> <<"transport">>;
        false -> <<"unclassified">>
    end;
reason_class(Tag) when is_atom(Tag) ->
    case is_transport_tag(Tag) of
        true -> <<"transport">>;
        false -> <<"unclassified">>
    end;
reason_class(_) ->
    <<"unclassified">>.

%% Mirrors janus_http_proxy:is_transient/1 plus the bare transport atoms
%% the gun layer reports.
is_transport_tag(Tag) ->
    lists:member(Tag, [
        content_encoding,
        open,
        await_up,
        await,
        body,
        unexpected_await,
        unexpected_body,
        timeout,
        closed,
        connect_timeout,
        econnrefused,
        econnreset,
        nxdomain,
        ehostunreach,
        enetunreach,
        etimedout,
        tls_alert
    ]).

%% @doc Scrubbed short error code: only integers / atoms are ever
%% rendered (the sanitized reason carries no upstream text), anything
%% else is `<<"unknown">>` — never a secret-bearing string.
-spec error_code(term()) -> binary().
error_code({auth, N}) when is_integer(N) -> integer_to_binary(N);
error_code({http, N}) when is_integer(N) -> integer_to_binary(N);
error_code({retry_after, _}) -> <<"retry_after">>;
error_code(undefined) -> ?UNKNOWN;
error_code(Tag) when is_atom(Tag) -> atom_to_binary(Tag, utf8);
error_code({Tag, Sub}) when is_atom(Tag), is_atom(Sub) ->
    <<(atom_to_binary(Tag, utf8))/binary, "_", (atom_to_binary(Sub, utf8))/binary>>;
error_code({Tag, N}) when is_atom(Tag), is_integer(N) ->
    <<(atom_to_binary(Tag, utf8))/binary, "_", (integer_to_binary(N))/binary>>;
error_code(_) ->
    ?UNKNOWN.

%%--------------------------------------------------------------------
%% Targets
%%--------------------------------------------------------------------

%% @doc Is this a cool target shape the dashboard enum can carry?
-spec valid_target(term()) -> boolean().
valid_target({provider_key, _}) -> true;
valid_target({provider, _}) -> true;
valid_target({route, _, _}) -> true;
valid_target({route, _}) -> true;
valid_target(_) -> false.

%% @doc Spec §4.1 target object. `provider_id` is ALWAYS set; for
%% `route` the `id` is the provider id and `model_id` rides separately.
-spec target_json(term(), provider_of()) -> map().
target_json({provider_key, KeyId}, ProviderOf) ->
    #{
        kind => <<"provider_key">>,
        id => to_bin(KeyId),
        provider_id => provider_bin(ProviderOf, KeyId),
        model_id => null
    };
target_json({provider, ProviderId}, _ProviderOf) ->
    P = to_bin(ProviderId),
    #{kind => <<"provider">>, id => P, provider_id => P, model_id => null};
target_json({route, ModelId, ProviderId}, _ProviderOf) ->
    P = to_bin(ProviderId),
    #{kind => <<"route">>, id => P, provider_id => P, model_id => model_bin(ModelId)};
target_json({route, ProviderId}, _ProviderOf) ->
    P = to_bin(ProviderId),
    #{kind => <<"route">>, id => P, provider_id => P, model_id => null}.

provider_bin(ProviderOf, KeyId) ->
    case catch ProviderOf(KeyId) of
        undefined -> ?UNKNOWN;
        {'EXIT', _} -> ?UNKNOWN;
        P -> to_bin(P)
    end.

model_bin(null) -> null;
model_bin(undefined) -> null;
model_bin(M) -> to_bin(M).

to_bin(B) when is_binary(B) -> B;
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(A) when is_atom(A), A =/= undefined, A =/= null -> atom_to_binary(A, utf8);
to_bin(_) -> ?UNKNOWN.

%%--------------------------------------------------------------------
%% Rows
%%--------------------------------------------------------------------

%% @doc Normalise an ETS row to `{Key, Until, Reason}`; the legacy
%% 2-tuple gets reason `undefined`. Anything else is `skip`.
-spec norm_row(term()) -> {term(), term(), term()} | skip.
norm_row({Key, Until, Reason}) -> {Key, Until, Reason};
norm_row({Key, Until}) -> {Key, Until, undefined};
norm_row(_) -> skip.

%% @doc Split rows into still-cooling (`Until > Now`, the exact
%% predicate `janus_lb:is_cooling/3` uses) and expired. Rows with a
%% non-integer `Until` or unrecognised shape are treated as expired
%% (the LB deletes those lazily too) — except unrecognised shapes,
%% which are dropped.
-spec split_expired([term()], integer()) -> {[tuple()], [tuple()]}.
split_expired(Rows, Now) ->
    lists:foldr(
        fun(Row, {Live, Expired}) ->
            case norm_row(Row) of
                skip ->
                    {Live, Expired};
                {_, Until, _} = R when is_integer(Until), Until > Now ->
                    {[R | Live], Expired};
                R ->
                    {Live, [R | Expired]}
            end
        end,
        {[], []},
        Rows
    ).

%%--------------------------------------------------------------------
%% Projection
%%--------------------------------------------------------------------

%% @doc The `/stats/health` cool section: `cool` (detail, cap 100,
%% newest `until_ms` first, ties by target id), `cool_ids` (compact,
%% cap 2000), exact `cool_count`, `cool_ids_overflow`, and
%% `cool_provider_counts` (only populated on overflow; computed over
%% ALL cooling targets, not the truncated ids).
-spec project([term()], clock(), provider_of()) -> map().
project(Rows, {NowMono, _} = Clock, ProviderOf) ->
    {Live0, _} = split_expired(Rows, NowMono),
    Live = [R || {K, _, _} = R <- Live0, valid_target(K)],
    Items = [item(R, Clock, ProviderOf) || R <- Live],
    Sorted = lists:sort(fun sort_before/2, Items),
    Count = length(Sorted),
    Overflow = Count > ?IDS_CAP,
    Kept = lists:sublist(Sorted, ?IDS_CAP),
    #{
        cool => [detail(I) || I <- lists:sublist(Sorted, ?DETAIL_CAP)],
        cool_ids => [maps:get(target, I) || I <- Kept],
        cool_count => Count,
        cool_ids_overflow => Overflow,
        cool_provider_counts =>
            case Overflow of
                true -> counts_from_items(Sorted);
                false -> []
            end
    }.

%% @doc Per-provider cooling counts over ALL live targets, as maps
%% `#{provider_id, keys_cooling, provider_cooling, routes_cooling}`.
-spec provider_counts([term()], clock(), provider_of()) -> [map()].
provider_counts(Rows, {NowMono, _} = Clock, ProviderOf) ->
    {Live0, _} = split_expired(Rows, NowMono),
    counts_from_items([item(R, Clock, ProviderOf) || {K, _, _} = R <- Live0, valid_target(K)]).

item({Key, Until, Reason}, {NowMono, NowWall}, ProviderOf) ->
    #{
        target => target_json(Key, ProviderOf),
        reason => reason_class(Reason),
        until_ms => NowWall + (Until - NowMono),
        last_error_code => error_code(Reason)
    }.

detail(Item) -> Item.

%% Newest until first; ties by target id then kind then model (total
%% order => deterministic snapshots).
sort_before(A, B) ->
    key(A) =< key(B).

key(#{until_ms := U, target := T}) ->
    {-U, maps:get(id, T), maps:get(kind, T), maps:get(model_id, T)}.

counts_from_items(Items) ->
    Acc = lists:foldl(
        fun(#{target := #{kind := Kind, provider_id := P}}, M) ->
            C0 = maps:get(P, M, {0, false, 0}),
            maps:put(P, bump(Kind, C0), M)
        end,
        #{},
        Items
    ),
    [
        #{
            provider_id => P,
            keys_cooling => Keys,
            provider_cooling => ProvCooling,
            routes_cooling => Routes
        }
     || {P, {Keys, ProvCooling, Routes}} <- lists:sort(maps:to_list(Acc))
    ].

bump(<<"provider_key">>, {K, P, R}) -> {K + 1, P, R};
bump(<<"provider">>, {K, _, R}) -> {K, true, R};
bump(<<"route">>, {K, P, R}) -> {K, P, R + 1}.

%%--------------------------------------------------------------------
%% Edges
%%--------------------------------------------------------------------

%% @doc Decide which `cool_edge` actions a re-cool produces.
%% `Prev` is `none` (not cooling / expired) or `{Until, Reason}` of the
%% LIVE prior row; `New` the row about to be stored.
%%   none                          -> [start]
%%   reason CLASS changed          -> [{clear, explicit}, start]
%%   same class, until moved >= Δ  -> [extend]
%%   otherwise                     -> []   (extend-on-change dedupe)
-spec edge_plan(none | {integer(), term()}, {integer(), term()}) ->
    [start | extend | {clear, explicit}].
edge_plan(none, _New) ->
    [start];
edge_plan({PrevUntil, PrevReason}, {NewUntil, NewReason}) ->
    case reason_class(PrevReason) =:= reason_class(NewReason) of
        false ->
            [{clear, explicit}, start];
        true when NewUntil - PrevUntil >= ?EXTEND_MIN_DELTA_MS ->
            [extend];
        true ->
            []
    end.

%% @doc Ops-ring event for one cool edge (spec §4.2 cool_edge payload).
%% `Cause` is `null` (start/extend) | `explicit` | `expired`.
-spec edge_event(
    start | extend | clear, null | explicit | expired, term(), term(), integer(), clock(), provider_of()
) -> map().
edge_event(Action, Cause, Key, Reason, UntilMono, {NowMono, NowWall}, ProviderOf) ->
    #{
        type => <<"cool_edge">>,
        payload => #{
            action => atom_to_binary(Action, utf8),
            cause =>
                case Cause of
                    null -> null;
                    C -> atom_to_binary(C, utf8)
                end,
            target => target_json(Key, ProviderOf),
            reason => reason_class(Reason),
            until_ms => NowWall + (UntilMono - NowMono),
            last_error_code => error_code(Reason),
            request_ref => null,
            trace_id => null
        }
    }.
