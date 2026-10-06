%%%-------------------------------------------------------------------
%%% @doc Labeled metrics registry for the Prometheus /metrics endpoint.
%%%
%%% One named public ETS `set` table holds all series; keys are tuples:
%%%   {counter, Name, Labels}        — Labels = sorted [{K, V}] binaries
%%%   {hist, Name, Labels, LeBin}    — LeBin rendered bucket bound
%%%   {hist_sum_us, Name, Labels}    — integer MICROSECONDS (ETS
%%%                                    update_counter is integer-only;
%%%                                    the renderer divides by 1e6)
%%%   {hist_count, Name, Labels}
%%% The table is looked up by name once per inc/observe call via
%%% ets:whereis/1 (constant-time — no persistent_term lifecycle traps
%%% across app restarts). `ets:update_counter/4` with a default tuple
%%% creates-and-bumps atomically (no registry race on first use).
%%% inc/observe are whole-body try/catch — observability must never
%%% crash the data plane.
%%%
%%% Cardinality is bounded by construction: label VALUES come only from
%%% closed enums (endpoint/protocol/status_class/stream) and
%%% operator-defined provider names. Never put request ids, key ids, or
%%% model names in labels.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_metrics).

-export([init/0, inc/2, observe/3, snapshot/0]).
-export([buckets/0, to_bin/1, norm_labels/1]).

-define(TABLE, janus_metrics).

%% BUCKETS_DESC is the single source: the literal descending ladder the
%% hot path bumps in (no per-call reverse, no allocation). buckets/0
%% (the renderer's canonical ascending ladder) is derived from it.
-define(BUCKETS_DESC, [
    {600.0, <<"600">>}, {300.0, <<"300">>}, {120.0, <<"120">>},
    {60.0, <<"60">>}, {30.0, <<"30">>}, {10.0, <<"10">>}, {5.0, <<"5">>},
    {2.5, <<"2.5">>}, {1.0, <<"1">>}, {0.5, <<"0.5">>}, {0.25, <<"0.25">>},
    {0.1, <<"0.1">>}, {0.05, <<"0.05">>}
]).

%% The canonical ladder (ascending). Derived from BUCKETS_DESC — the two
%% can never drift.
-spec buckets() -> [{float(), binary()}].
buckets() ->
    lists:reverse(?BUCKETS_DESC).

-spec init() -> ok.
init() ->
    try
        case ets:info(?TABLE) of
            undefined ->
                _ = ets:new(?TABLE, [
                    named_table, public, set,
                    {write_concurrency, true},
                    {read_concurrency, true}
                ]),
                ok;
            _ ->
                ok
        end
    catch
        Class:Reason ->
            %% Metrics dead, gateway still serves — loud, not silent.
            logger:error(#{
                what => janus_metrics_init_failed,
                class => Class, reason => Reason
            }),
            ok
    end.

%% inc(requests_total, #{endpoint => chat, protocol => openai_chat, status_class => <<"2xx">>})
%% Whole body is guarded — observability must never crash the data plane.
-spec inc(atom(), map()) -> ok.
inc(Name, Labels) when is_atom(Name), is_map(Labels) ->
    try
        bump(ets:whereis(?TABLE), {counter, Name, norm_labels(Labels)}, 1)
    catch
        _:_ -> ok
    end;
inc(_, _) ->
    ok.

%% observe(request_duration_seconds, #{protocol => ..., stream => 0|1}, Seconds)
-spec observe(atom(), map(), number()) -> ok.
observe(Name, Labels, Seconds) when is_atom(Name), is_map(Labels), is_number(Seconds) ->
    try
        Sec = max(0.0, Seconds),
        L = norm_labels(Labels),
        %% One whereis per call, not per bump.
        Tid = ets:whereis(?TABLE),
        %% Integer microseconds — ETS update_counter is integer-only.
        %% Bump order is best-effort scrape hygiene: +Inf first, then
        %% the ladder DESCENDING (a concurrent tab2list then always sees
        %% bucket counts non-decreasing in le), sum, and count LAST —
        %% so count =< +Inf holds at every interleaving. Exact
        %% count == +Inf equality is unattainable without a multi-key
        %% transaction; the gate asserts >= and equality at quiescence.
        bump(Tid, {hist, Name, L, <<"+Inf">>}, 1),
        lists:foreach(
            fun({Le, LeBin}) ->
                case Sec =< Le of
                    true -> bump(Tid, {hist, Name, L, LeBin}, 1);
                    false -> ok
                end
            end,
            buckets_desc()
        ),
        bump(Tid, {hist_sum_us, Name, L}, round(Sec * 1_000_000)),
        bump(Tid, {hist_count, Name, L}, 1),
        ok
    catch
        _:_ -> ok
    end;
observe(_, _, _) ->
    ok.

-spec snapshot() -> [{tuple(), integer()}].
snapshot() ->
    case ets:whereis(?TABLE) of
        undefined -> [];
        Tid -> ets:tab2list(Tid)
    end.

%%% internal

buckets_desc() ->
    ?BUCKETS_DESC.

%% ets:whereis on a named table is a constant-time atomic read — and
%% never returns a stale/dead tid (no persistent_term lifecycle trap).
bump(undefined, _Key, _Incr) ->
    ok;
bump(Tid, Key, Incr) when is_integer(Incr) ->
    _ = ets:update_counter(Tid, Key, Incr, {Key, 0}),
    ok.

norm_labels(L) when is_list(L) ->
    %% Registry rows already carry [{KBin, VBin}] — the sort is a no-op.
    lists:sort(L);
norm_labels(Labels) when is_map(Labels) ->
    lists:sort([
        {to_bin(K), to_bin(V)}
     || {K, V} <- maps:to_list(Labels)
    ]).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(F) when is_float(F) -> float_to_binary(F, [short]);
to_bin(L) when is_list(L) ->
    case unicode:characters_to_binary(L) of
        B when is_binary(B) -> B;
        _ -> <<"unknown">>
    end;
to_bin(_) ->
    <<"unknown">>.
