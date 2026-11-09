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
-export([buckets/0, buckets/1, semconv_name/1, to_bin/1, norm_labels/1]).

-define(TABLE, janus_metrics).

%% BUCKETS_DESC is the single source: the literal descending ladder the
%% hot path bumps in (no per-call reverse, no allocation). buckets/0
%% (the renderer's canonical ascending ladder) is derived from it.
%% Semconv ladders, DESCENDING like ?BUCKETS_DESC so `observe/3' can bump
%% without a reverse. Written as the exact prescribed bounds, in order —
%% the design requires the prescribed bounds "unaltered and in order".
%%
%% `http.server.request.duration': the HTTP semconv advisory ladder.
%% `gen_ai.client.inference.duration': the GenAI advisory ladder. Its top
%% bound is 81.92s, so a long reasoning stream lands in +Inf; that is a
%% recorded, deliberate limit of the prescribed instrument (design §8.3),
%% not an oversight.
-define(HTTP_SERVER_LADDER_DESC, [
    {10.0, <<"10">>}, {7.5, <<"7.5">>}, {5.0, <<"5">>}, {2.5, <<"2.5">>},
    {1.0, <<"1">>}, {0.75, <<"0.75">>}, {0.5, <<"0.5">>}, {0.25, <<"0.25">>},
    {0.1, <<"0.1">>}, {0.075, <<"0.075">>}, {0.05, <<"0.05">>},
    {0.025, <<"0.025">>}, {0.01, <<"0.01">>}, {0.005, <<"0.005">>}
]).

-define(GEN_AI_LADDER_DESC, [
    {81.92, <<"81.92">>}, {40.96, <<"40.96">>}, {20.48, <<"20.48">>},
    {10.24, <<"10.24">>}, {5.12, <<"5.12">>}, {2.56, <<"2.56">>},
    {1.28, <<"1.28">>}, {0.64, <<"0.64">>}, {0.32, <<"0.32">>},
    {0.16, <<"0.16">>}, {0.08, <<"0.08">>}, {0.04, <<"0.04">>},
    {0.02, <<"0.02">>}, {0.01, <<"0.01">>}
]).

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

%% @doc Ladder for a specific family.
%%
%% `request_duration_seconds' keeps the legacy ladder EXACTLY: it is what
%% the deployed Grafana panels compute `histogram_quantile' over, and
%% changing the bucket set silently changes every published percentile.
%% The semconv families get their prescribed ladders instead, because
%% those bounds are part of the contract those instruments are defined by
%% — an approximating ladder is the failure mode the design calls out.
%%
%% An UNKNOWN name falls back to the legacy ladder. That is what keeps a
%% rolling deploy safe: a node that starts observing a family before its
%% renderer knows the ladder still produces usable buckets rather than
%% an empty series.
-spec buckets(atom()) -> [{float(), binary()}].
buckets(Name) ->
    case ladder_desc(Name) of
        ?BUCKETS_DESC -> buckets();
        Desc -> lists:reverse(Desc)
    end.

%% Descending form for the hot path (no per-call reverse).
ladder_desc(request_duration_seconds) ->
    ?BUCKETS_DESC;
ladder_desc(http_server_request_duration) ->
    ?HTTP_SERVER_LADDER_DESC;
ladder_desc(gen_ai_client_inference_duration) ->
    ?GEN_AI_LADDER_DESC;
ladder_desc(_) ->
    ?BUCKETS_DESC.

%% @doc Translate an OTel attribute name into a Prometheus label name.
%%
%% Prometheus labels are `[a-zA-Z_][a-zA-Z0-9_]*'; OTel attribute names are
%% dotted. Emitting a dotted name would make the ENTIRE /metrics body
%% invalid — not just that series — so every attribute goes through here
%% on the way into the Prometheus registry. `.` and `-` become `_`.
-spec prom_label(binary()) -> binary().
prom_label(Name) when is_binary(Name) ->
    Mapped = <<<<(prom_label_ch(C))>> || <<C>> <= Name>>,
    %% A name that still cannot start a Prometheus label (a leading digit)
    %% gets the `_` prefix the spec allows. Without this the guarantee above
    %% would be "dots become underscores" rather than "every name is
    %% legal", and a name like `2xx` would still break the exposition.
    case Mapped of
        <<C, _/binary>> when C >= $0, C =< $9 -> <<"_", Mapped/binary>>;
        <<>> -> <<"_">>;
        _ -> Mapped
    end.

prom_label_ch(C) when C >= $a, C =< $z -> C;
prom_label_ch(C) when C >= $A, C =< $Z -> C;
prom_label_ch(C) when C >= $0, C =< $9 -> C;
prom_label_ch($_) -> $_;
%% Everything else — dots from OTel attribute names, hyphens, but also
%% spaces and punctuation that no label name may contain — becomes `_`.
prom_label_ch(_) -> $_.

%% @doc The OTLP/semconv instrument name a legacy family maps to, or
%% `undefined' when the family has no semconv counterpart.
%%
%% Kept here rather than in the renderer: the mapping is a property of the
%% instrument, and both views (Prometheus text and OTLP) are generated
%% from the same ETS rows, so they cannot disagree numerically.
-spec semconv_name(atom()) -> binary() | undefined.
semconv_name(http_server_request_duration) -> <<"http.server.request.duration">>;
semconv_name(gen_ai_client_inference_duration) -> <<"gen_ai.client.inference.duration">>;
semconv_name(_) -> undefined.

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
            ladder_desc(Name)
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
    %% Label NAMES are transliterated here, at the registry boundary, so no
    %% producer can inject a name Prometheus cannot parse. A dotted OTel
    %% attribute name would make the whole exposition invalid — every
    %% scrape of the fleet fails, not just that series — so this cannot
    %% depend on each call site remembering to translate.
    lists:sort([
        {prom_label(to_bin(K)), to_bin(V)}
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
