# Observability: Prometheus /metrics + End-to-End Request IDs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Janus a standard observability surface — a token-authenticated Prometheus `/metrics` endpoint on the admin plane and a client-visible `x-request-id` on every agent response, threaded through logs and usage rows.

**Architecture:** Metrics series live in a named public ETS table (write_concurrency) bumped from terminal paths (`janus_http_proxy:track/3` fires once per terminal outcome; auth rejects bump in `janus_http_auth`; `/v1/models` in its handler). Gauges are computed at scrape time from existing sources (`janus_config`, `janus_lb`, `janus_usage:stats/0`, `janus_catalog`). A pure renderer turns a sorted ETS snapshot into Prometheus text (eunit-first). Request IDs are resolved once per request (sanitize inbound or generate `req_<16 lowercase hex>`), echoed via `cowboy_req:set_resp_header` at handler entry (covers success, error, 401, and stream replies on the same Req chain), added to the `janus_request`/`janus_agent_reject`/auth-reject logs, and stored in a new nullable `usage_events.request_id` column (migration 005).

**Tech Stack:** Erlang/OTP (cowboy, atomics/ETS, thoas), Prometheus text exposition format (hand-rolled — no new dependency), SQLite + Postgres migrations, sibling-repo E2E gate (`../janus-dashboard/scripts/e2e_local.sh`), sibling-repo dashboard read path (`../janus-dashboard` FastAPI usage router + SPA type).

**Testing rules (user-mandated, from AGENTS.md):** E2E is the sole test mechanism; pure parsers/logic may get eunit **written first** with production-shaped fixtures. All testing is local; prod gets only the read-only smoke. Nothing is done until the local gate is green.

**Naming contract (locked by audit):** series are `janus_requests_total`, `janus_upstream_requests_total`, `janus_request_duration_seconds` (+`_bucket`/`_sum`/`_count`), gauges `janus_catalog_generation`, `janus_catalog_ready`, `janus_models_serving`, `janus_lb_routes_cooling`, `janus_usage_writer_buffered_rows`, `janus_uptime_seconds`, counter `janus_usage_writer_dropped_total`, `janus_build_info` (TYPE `info`, value 1). The renderer prefixes `janus_` onto the registered name — call sites register `requests_total`, `upstream_requests_total`, `request_duration_seconds`. The E2E gate and the Grafana JSON use these exact strings.

**Key file facts an implementer must know:**
- Admin plane (:8090) routes: `janus_http_sup.erl` AdminDispatch — `/healthz`, `/stats`, `/stats/[...]` (handler: `janus_gateway_stats.erl`). Auth pattern: `JANUS_STATS_TOKEN` bearer (constant-time compare) with loopback-only fallback when unset. Loopback check reads the **socket peer IP** — `X-Forwarded-For` is never consulted; the admin plane must never be exposed through Caddy without the token (document in README).
- Counter convention: `janus_http_stats.erl` (atomics in persistent_term, no-op when missing). For labeled series we use the named ETS table with `ets:update_counter(Tid, Key, Incr, {Key, 0})` (atomic create-and-bump, no registry race). The tid is cached in persistent_term at init; bumps never call `ets:info`.
- **ETS table ownership:** created in `janus_http_app:start/2` (app master outlives listeners); `init/0` must be idempotent (`case ets:info(...) of undefined -> new; _ -> ok`) so app restart/hot reload survives.
- `janus_http_proxy:track/3` fires once per terminal client outcome (failover inner attempts are non-terminal — no double counting) inside the `is_map(Agent)` branch; it computes `LatencyMs` and logs `janus_request`. It must also bump the three metric series there. Existing helpers in proxy: `usage_bool_int/1`, `route_provider_name/1` (verify both exist before coding; they are used by `track/3` already).
- `janus_http_proxy:handle/5` erases pdict keys at entry for keep-alive safety — the erase list must NOT gain `janus_request_id` or `janus_req_path` (the handler puts them before calling the proxy; `track/3` reads them).
- Every reply on the agent endpoints goes through `cowboy_req:reply/stream_reply` on the SAME Req chain that got `set_resp_header` at handler entry — verified at implementation by reading `reply_err/6`, `reply_json`, and the stream paths (assert in the E2E gate: 401 + stream responses carry the header).
- `janus_lb:stats/0` returns the failover/LB counter map (from `/stats`); `janus_lb:cooling_count/0` exists (used by `/stats`). Verify names by reading `janus_lb.erl` before wiring.
- Migrations: flat layout `priv/migrations/NNN_name.{postgres,sqlite}.sql` is what `janus_migrate` executes (`suffix(Dialect)`); the `{postgres,sqlite}/` subdirs hold identical copies (repo convention). Next is `005`. The migration ledger (`schema_migrations`) dedupes — non-idempotent `ALTER TABLE ADD COLUMN` runs once.
- `janus_db_conn:query/2` → `{ok, Rows} | {error, _}`; `?` → `$N` rewrite for Postgres; existing nullable columns are bound with the `null` atom on both drivers (precedent: `janus_usage` `build_insert`).
- Release version: `application:get_key(janus, vsn)`.
- `statistics(wall_clock)` is a non-destructive read (no reset side effect).
- Prometheus text format: `# HELP` + `# TYPE` lines ONCE per metric family (group by family name), buckets numerically ascending with `+Inf` last, float values via `float_to_binary(F, [short])` (`~g` loses precision), labels sorted by key, values escaped (`\`, `"`, newline).

---

### Task 1: Migration 005 — `usage_events.request_id`

Nullable so old rows and non-proxy writers stay valid; indexed for log↔usage correlation lookups.

**Files:**
- Create: `apps/janus_core/priv/migrations/005_request_id.postgres.sql` + identical copy `postgres/005_request_id.sql`
- Create: `apps/janus_core/priv/migrations/005_request_id.sqlite.sql` + identical copy `sqlite/005_request_id.sql`

- [ ] **Step 1: SQL (both dialects identical)**

```sql
-- Client-facing request id (x-request-id) for log/usage correlation.
-- Nullable: rows predating 005 and non-proxy writers have none.
ALTER TABLE usage_events ADD COLUMN request_id TEXT;

CREATE INDEX IF NOT EXISTS usage_events_request_id_idx ON usage_events (request_id);
```

- [ ] **Step 2: Verify via the local gate** (migrations run at gateway boot; then a fresh row carries the column)

```bash
bash ../janus-dashboard/scripts/e2e_local.sh 2>&1 | tail -5
docker exec janus-pg psql -U janus -c "\d usage_events" | grep request_id
```
Expected: `request_id | text` + the index. (Boot-migration of a table WITH pre-existing rows is the interesting case — the gate's stack has usage rows from earlier runs.)

- [ ] **Step 3: Commit**

```bash
git add apps/janus_core/priv/migrations
git commit -m "Migration 005: usage_events.request_id for log/usage correlation"
```

---

### Task 2: `janus_metrics` — labeled counter/histogram registry (janus_http)

**Files:**
- Create: `apps/janus_http/src/janus_metrics.erl`
- Modify: `apps/janus_http/src/janus_http_app.erl` (call `janus_metrics:init()` next to `janus_http_stats:init()`)

- [ ] **Step 1: Write the module**

```erlang
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
%%% The tid lives in persistent_term (created once at app init);
%%% bumps are try/catch'd — observability must never crash the data
%%% plane. `ets:update_counter/4` with a default tuple creates-and-bumps
%%% atomically (no registry race on first use).
%%%
%%% Cardinality is bounded by construction: label VALUES come only from
%%% closed enums (endpoint/protocol/status_class/stream) and
%%% operator-defined provider names. Never put request ids, key ids, or
%%% model names in labels.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_metrics).

-export([init/0, inc/2, observe/3, snapshot/0]).
-export([buckets/0]).

-define(TABLE, janus_metrics).
-define(PT_TID, {janus_metrics, tid}).

%% Duration buckets (seconds): fast path 0.05 → reasoning upstreams 600s.
%% Precomputed [{Float, RenderedBinary}] once — the hot path never
%% formats floats.
-spec buckets() -> [{float(), binary()}].
buckets() ->
    [
        {0.05, <<"0.05">>}, {0.1, <<"0.1">>}, {0.25, <<"0.25">>},
        {0.5, <<"0.5">>}, {1.0, <<"1">>}, {2.5, <<"2.5">>}, {5.0, <<"5">>},
        {10.0, <<"10">>}, {30.0, <<"30">>}, {60.0, <<"60">>},
        {120.0, <<"120">>}, {300.0, <<"300">>}, {600.0, <<"600">>}
    ].

-spec init() -> ok.
init() ->
    case persistent_term:get(?PT_TID, undefined) of
        undefined ->
            Tid = ets:new(?TABLE, [
                named_table, public, set,
                {write_concurrency, true},
                {read_concurrency, true}
            ]),
            persistent_term:put(?PT_TID, Tid),
            ok;
        _Tid ->
            ok
    end.

%% inc(requests_total, #{endpoint => chat, protocol => openai_chat, status_class => <<"2xx">>})
-spec inc(atom(), map()) -> ok.
inc(Name, Labels) when is_atom(Name), is_map(Labels) ->
    safe_bump({counter, Name, norm_labels(Labels)}, 1).

%% observe(request_duration_seconds, #{protocol => ..., stream => 0|1}, Seconds)
-spec observe(atom(), map(), number()) -> ok.
observe(Name, Labels, Seconds) when
    is_atom(Name), is_map(Labels), is_number(Seconds), Seconds >= 0
->
    L = norm_labels(Labels),
    %% Integer microseconds — ETS update_counter is integer-only.
    safe_bump({hist_sum_us, Name, L}, round(Seconds * 1_000_000)),
    safe_bump({hist_count, Name, L}, 1),
    lists:foreach(
        fun({Le, LeBin}) ->
            case Seconds =< Le of
                true -> safe_bump({hist, Name, L, LeBin}, 1);
                false -> ok
            end
        end,
        buckets()
    ),
    safe_bump({hist, Name, L, <<"+Inf">>}, 1),
    ok.

-spec snapshot() -> [{tuple(), integer()}].
snapshot() ->
    case tid() of
        undefined -> [];
        Tid -> ets:tab2list(Tid)
    end.

%%% internal

tid() ->
    persistent_term:get(?PT_TID, undefined).

safe_bump(Key, Incr) when is_integer(Incr) ->
    try
        case tid() of
            undefined -> ok;
            Tid ->
                _ = ets:update_counter(Tid, Key, Incr, {Key, 0}),
                ok
        end
    catch
        _:_ -> ok
    end.

norm_labels(Labels) ->
    lists:sort([
        {to_bin(K), to_bin(V)}
     || {K, V} <- maps:to_list(Labels)
    ]).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I).
```

- [ ] **Step 2: Wire init**

In `apps/janus_http/src/janus_http_app.erl`, after `ok = janus_http_stats:init(),`:

```erlang
    ok = janus_metrics:init(),
```

- [ ] **Step 3: Compile in the build container** (per AGENTS.md — never host Erlang):

```bash
docker build --target test -t janus-build:test .
docker run --rm -v F:/Janus/apps:/app/apps -v F:/Janus/config:/app/config -v F:/Janus/rebar.config:/app/rebar.config -v F:/Janus/rebar.lock:/app/rebar.lock -v janus-ebin-otp27:/app/_build -w /app janus-build:test sh -c 'rebar3 compile'
```
Expected: compiles clean.

- [ ] **Step 4: Commit**

```bash
git add apps/janus_http/src/janus_metrics.erl apps/janus_http/src/janus_http_app.erl
git commit -m "Add janus_metrics labeled ETS registry (integer µs histograms, cached tid)"
```

---

### Task 3: `janus_metrics_render` — pure exposition renderer (TDD)

**Files:**
- Create: `apps/janus_http/src/janus_metrics_render.erl`
- Test: `apps/janus_http/test/janus_metrics_render_tests.erl`

- [ ] **Step 1: Write the failing tests first** (production-shaped rows: `{Key, Value}` tuples from `ets:tab2list`; labels pre-sorted binary pairs; histogram sums are integer µs)

```erlang
-module(janus_metrics_render_tests).
-include_lib("eunit/include/eunit.hrl").

counter_render_exact_test() ->
    Rows = [
        {{counter, requests_total, [{<<"endpoint">>, <<"chat">>}, {<<"status_class">>, <<"2xx">>}]}, 42}
    ],
    Out = janus_metrics_render:render(Rows, []),
    ?assertEqual(
        <<"# HELP janus_requests_total Client LLM requests.\n"
          "# TYPE janus_requests_total counter\n"
          "janus_requests_total{endpoint=\"chat\",status_class=\"2xx\"} 42\n">>,
        Out
    ).

histogram_bucket_order_exact_test() ->
    %% Buckets must be numerically ascending with +Inf LAST — a
    %% lexicographic sort breaks histogram_quantile.
    L = [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"1">>}],
    Rows = [
        {{hist, request_duration_seconds, L, <<"600">>}, 7},
        {{hist, request_duration_seconds, L, <<"+Inf">>}, 7},
        {{hist, request_duration_seconds, L, <<"0.05">>}, 3},
        {{hist, request_duration_seconds, L, <<"10">>}, 5},
        {{hist_sum_us, request_duration_seconds, L}, 900000},
        {{hist_count, request_duration_seconds, L}, 7}
    ],
    Out = janus_metrics_render:render(Rows, []),
    Expected = <<
        "# HELP janus_request_duration_seconds End-to-end request duration (streams include client drain).\n"
        "# TYPE janus_request_duration_seconds histogram\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"0.05\"} 3\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"10\"} 5\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"600\"} 7\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"+Inf\"} 7\n"
        "janus_request_duration_seconds_sum{protocol=\"openai_chat\",stream=\"1\"} 0.9\n"
        "janus_request_duration_seconds_count{protocol=\"openai_chat\",stream=\"1\"} 7\n"
    >>,
    ?assertEqual(Expected, Out).

gauge_render_test() ->
    Out = janus_metrics_render:render([], [{catalog_generation, 12, #{}}]),
    ?assertEqual(
        <<"# HELP janus_catalog_generation Serving catalog generation.\n"
          "# TYPE janus_catalog_generation gauge\n"
          "janus_catalog_generation 12\n">>,
        Out
    ).

build_info_is_info_type_test() ->
    Out = janus_metrics_render:render([], [{build_info, 1, #{<<"version">> => <<"0.1.0">>}}]),
    ?assertMatch({_, _}, binary:match(Out, <<"# TYPE janus_build_info info">>)),
    ?assertMatch({_, _}, binary:match(Out, <<"janus_build_info{version=\"0.1.0\"} 1\n">>)).

label_escape_test() ->
    Rows = [{{counter, x_total, [{<<"k">>, <<"a\"b\\c\nd">>}]}, 1}],
    Out = janus_metrics_render:render(Rows, []),
    ?assertMatch({_, _}, binary:match(Out, <<"k=\"a\\\"b\\\\c\\nd\"">>)).

families_sorted_once_test() ->
    %% One TYPE/HELP line per family, families in name order, no
    %% duplicate TYPE lines even with several label sets.
    Rows = [
        {{counter, requests_total, [{<<"endpoint">>, <<"chat">>}, {<<"status_class">>, <<"2xx">>}]}, 1},
        {{counter, requests_total, [{<<"endpoint">>, <<"models">>}, {<<"status_class">>, <<"2xx">>}]}, 2}
    ],
    Out = janus_metrics_render:render(Rows, []),
    ?assertEqual(1, count_occ(Out, <<"# TYPE janus_requests_total">>)),
    ?assertEqual(1, count_occ(Out, <<"# HELP janus_requests_total">>)).

count_occ(Bin, Pat) ->
    count_occ(Bin, Pat, 0).
count_occ(Bin, Pat, N) ->
    case binary:match(Bin, Pat) of
        nomatch -> N;
        {Pos, Len} -> count_occ(binary:part(Bin, Pos + Len, byte_size(Bin) - Pos - Len), Pat, N + 1)
    end.
```

- [ ] **Step 2: Run, verify failure**

```bash
docker run --rm -v F:/Janus/apps:/app/apps -v F:/Janus/config:/app/config -v F:/Janus/rebar.config:/app/rebar.config -v F:/Janus/rebar.lock:/app/rebar.lock -v janus-ebin-otp27:/app/_build -w /app janus-build:test sh -c 'rebar3 eunit --module=janus_metrics_render_tests'
```
Expected: FAIL (module undefined).

- [ ] **Step 3: Implement the renderer**

```erlang
%%%-------------------------------------------------------------------
%%% @doc Render a janus_metrics snapshot as Prometheus text exposition.
%%% Pure, total, deterministic: families sorted by name, one HELP+TYPE
%%% line per family, histogram buckets numerically ascending with +Inf
%%% last, float values via float_to_binary(..., [short]).
%%% Gauges are supplied by the caller (scrape-time reads) as
%%% {Name, Value, LabelsMap}.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_metrics_render).

-export([render/2]).

-define(HELP, #{
    requests_total => <<"Client LLM requests.">>,
    upstream_requests_total => <<"Upstream provider requests.">>,
    request_duration_seconds =>
        <<"End-to-end request duration (streams include client drain).">>,
    catalog_generation => <<"Serving catalog generation.">>,
    catalog_ready => <<"Serving catalog warm (1) or cold (0).">>,
    models_serving => <<"Models in the serving catalog.">>,
    lb_routes_cooling => <<"LB routes currently cooling down.">>,
    usage_writer_buffered_rows => <<"Usage writer buffered rows.">>,
    usage_writer_dropped_total => <<"Usage events dropped by the writer.">>,
    uptime_seconds => <<"VM wall-clock uptime.">>,
    build_info => <<"Build/version info.">>
}).

-spec render([{tuple(), integer()}], [{atom(), number(), map()}]) -> binary().
render(Rows, Gauges) ->
    CounterRows = [R || {{counter, _, _}, _} = R <- Rows],
    HistRows = [R || {{hist, _, _, _}, _} = R <- Rows],
    Sums = maps:from_list([{K, V} || {{hist_sum_us, _, _} = K, V} <- Rows]),
    Counts = maps:from_list([{K, V} || {{hist_count, _, _} = K, V} <- Rows]),
    GaugeNames = lists:usort([N || {N, _, _} <- Gauges]),
    iolist_to_binary([
        render_family(requests_total, counter, CounterRows),
        render_family(upstream_requests_total, counter, CounterRows),
        render_family(x_total, counter, CounterRows),
        render_hist_family(request_duration_seconds, HistRows, Sums, Counts),
        [render_gauge_family(N, Gauges) || N <- GaugeNames]
    ]).

%%% internal — generic counter family

render_family(Name, counter, Rows) ->
    Series = [
        {L, V}
     || {{counter, N, L}, V} <- Rows, N =:= Name
    ],
    case Series of
        [] -> [];
        _ ->
            Lines = [
                [name_bin(Name), labels_bin(L), " ", integer_to_binary(V), "\n"]
             || {L, V} <- lists:sort(Series)
            ],
            [help_line(Name), type_line(Name, counter), Lines]
    end.

%%% internal — histogram family

render_hist_family(Name, Rows, Sums, Counts) ->
    ByLabels = lists:foldl(
        fun({{hist, N, L, Le}, V}, Acc) when N =:= Name ->
            maps:update_with(L, fun(M) -> M#{Le => V} end, #{Le => V}, Acc);
           (_, Acc) -> Acc
        end,
        #{},
        Rows
    ),
    case maps:size(ByLabels) of
        0 -> [];
        _ ->
            [
                help_line(Name),
                type_line(Name, histogram),
                [
                    render_hist_series(Name, L, BucketMap, Sums, Counts)
                 || {L, BucketMap} <- lists:sort(maps:to_list(ByLabels))
                ]
            ]
    end.

render_hist_series(Name, L, BucketMap, Sums, Counts) ->
    %% Numeric ascending; +Inf pinned last.
    Les = lists:sort(
        fun
            (<<"+Inf">>, _) -> false;
            (_, <<"+Inf">>) -> true;
            (A, B) -> le_num(A) =< le_num(B)
        end,
        maps:keys(BucketMap)
    ),
    SumUs = maps:get({hist_sum_us, Name, L}, Sums, 0),
    Count = maps:get({hist_count, Name, L}, Counts, 0),
    NameB = name_bin(Name),
    [
        [
            NameB, "_bucket", labels_bin(L ++ [{<<"le">>, Le}]), " ",
            integer_to_binary(maps:get(Le, BucketMap)), "\n"
        ]
     || Le <- Les
    ],
    %% µs → seconds at render time, full precision.
    [NameB, "_sum", labels_bin(L), " ", float_to_binary(SumUs / 1_000_000, [short]), "\n"],
    [NameB, "_count", labels_bin(L), " ", integer_to_binary(Count), "\n"]
    ].

le_num(Le) ->
    try binary_to_float(Le)
    catch _:_ -> (try float(binary_to_integer(Le)) catch _:_ -> 0.0 end)
    end.

%%% internal — gauges + build_info

render_gauge_family(Name, Gauges) ->
    Series = [{V, L} || {N, V, L} <- Gauges, N =:= Name],
    case Series of
        [] -> [];
        _ ->
            Type = case Name of build_info -> info; _ -> gauge end,
            Lines = [
                [name_bin(Name), labels_bin(norm_labels(L)), " ", num_bin(V), "\n"]
             || {V, L} <- lists:sort(Series)
            ],
            [help_line(Name), type_line(Name, Type), Lines]
    end.

norm_labels(L) when is_map(L) ->
    lists:sort([{to_bin(K), to_bin(V)} || {K, V} <- maps:to_list(L)]).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I).

%%% internal — shared

help_line(Name) ->
    Text = maps:get(Name, ?HELP, <<>>),
    <<"# HELP ", (name_bin(Name))/binary, " ", Text/binary, "\n">>.

type_line(Name, Type) ->
    <<"# TYPE ", (name_bin(Name))/binary, " ", (atom_to_binary(Type, utf8))/binary, "\n">>.

name_bin(Name) ->
    <<"janus_", (atom_to_binary(Name, utf8))/binary>>.

labels_bin([]) ->
    <<>>;
labels_bin(Ls) ->
    Inner = lists:join(<<",">>, [[K, "=\"", escape(V), "\""] || {K, V} <- Ls]),
    iolist_to_binary(["{", Inner, "}"]).

escape(V) ->
    %% Prometheus label values: backslash, double-quote, newline.
    binary:replace(
        binary:replace(
            binary:replace(V, <<"\\">>, <<"\\\\">>, [global]),
            <<"\"">>, <<"\\\"">>, [global]
        ),
        <<"\n">>, <<"\\n">>, [global]
    ).

num_bin(I) when is_integer(I) -> integer_to_binary(I);
num_bin(F) when is_float(F) -> float_to_binary(F, [short]).
```

- [ ] **Step 4: Run, verify pass** — same command as Step 2. Expected: `All 6 tests passed.`

- [ ] **Step 5: Commit**

```bash
git add apps/janus_http/src/janus_metrics_render.erl apps/janus_http/test/janus_metrics_render_tests.erl
git commit -m "Add deterministic Prometheus text renderer (HELP/TYPE, sorted buckets, escaping)"
```

---

### Task 4: `/metrics` handler + shared admin auth

**Files:**
- Create: `apps/janus_http/src/janus_admin_auth.erl` (extracted from `janus_gateway_stats.erl`)
- Modify: `apps/janus_http/src/janus_gateway_stats.erl` (delegate; behavior identical)
- Create: `apps/janus_http/src/janus_http_metrics.erl`
- Modify: `apps/janus_http/src/janus_http_sup.erl` (add route)

- [ ] **Step 1: Extract the auth module** — move `authorize/1`, `bearer_token/1`, `token_eq/2`, `stats_token/0`, `is_loopback/1`, `unauthorized/2` verbatim from `janus_gateway_stats.erl` into `janus_admin_auth.erl` with `-export([authorize/1]).`; in `janus_gateway_stats:init/2` call `janus_admin_auth:authorize(Req0)` and delete the moved private functions.

- [ ] **Step 2: The handler** (no placeholder gymnastics: gauges list + the writer-drop counter rendered as a counter family by the renderer — add `usage_writer_dropped_total` handling as a counter row appended to the snapshot rows, not as a fake gauge)

```erlang
%%%-------------------------------------------------------------------
%%% @doc GET /metrics — Prometheus text exposition on the admin plane.
%%% Same token/loopback auth as /stats (janus_admin_auth).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_metrics).

-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Req =
        case janus_admin_auth:authorize(Req0) of
            ok -> render(Req0);
            {error, Req1} -> Req1
        end,
    {ok, Req, State}.

render(Req) ->
    Usage = safe(fun janus_usage:stats/0, #{}),
    {WallMs, _} = statistics(wall_clock),
    Version =
        case application:get_key(janus, vsn) of
            {ok, V} -> to_bin(V);
            _ -> <<"unknown">>
        end,
    Dropped = maps:get(dropped, Usage, 0),
    %% The writer's dropped counter is cumulative → append as a counter
    %% row; gauges are scrape-time reads.
    Rows =
        janus_metrics:snapshot() ++
            [{{counter, usage_writer_dropped_total, []}, Dropped}],
    Gauges = [
        {catalog_generation, safe(fun janus_config:generation/0, 0), #{}},
        {catalog_ready, bool01(safe(fun janus_config:ready/0, false)), #{}},
        {models_serving, models_serving(), #{}},
        {lb_routes_cooling, safe(fun janus_lb:cooling_count/0, 0), #{}},
        {usage_writer_buffered_rows, maps:get(buffered, Usage, 0), #{}},
        {uptime_seconds, WallMs div 1000, #{}},
        {build_info, 1, #{<<"version">> => Version}}
    ],
    %% LB failover counters (requests_retried, failovers_exhausted, …)
    %% ride along as gauges from janus_lb:stats().
    LbGauges = [
        {lb_stat, V, #{<<"counter">> => to_bin(K)}}
     || {K, V} <- maps:to_list(safe(fun janus_lb:stats/0, #{})), is_integer(V)
    ],
    %% lb_stat is not in HELP — generic line:
    Body = janus_metrics_render:render(Rows, Gauges),
    Body2 = <<
        Body/binary,
        "# HELP janus_lb_stat LB counters from janus_lb:stats/0.\n",
        "# TYPE janus_lb_stat gauge\n"
    >>,
    LbLines = [
        <<"janus_lb_stat{counter=\"", (to_bin(K))/binary, "\"} ",
          (integer_to_binary(V))/binary, "\n">>
     || {K, V} <- maps:to_list(safe(fun janus_lb:stats/0, #{})), is_integer(V)
    ],
    cowboy_req:reply(200, #{
        <<"content-type">> => <<"text/plain; version=0.0.4; charset=utf-8">>
    }, <<Body2/binary, (iolist_to_binary(LbLines))/binary>>, Req).

safe(Fun, Default) ->
    try Fun() catch _:_ -> Default end.

bool01(true) -> 1;
bool01(_) -> 0.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) -> list_to_binary(L).

models_serving() ->
    try
        case janus_catalog:get() of
            #{catalog := #{models := Tid}} ->
                Rows = ets:tab2list(Tid),
                Ids = sets:from_list([Id || {Id, #{id := Id}} <- Rows], [{version, 2}]),
                sets:size(Ids);
            _ ->
                0
        end
    catch
        _:_ -> 0
    end.
```

(The `LbGauges` binding is intentionally folded into the appended lines; keep one construction — build `LbStats` once, use for both. The HELP map has no `lb_stat` entry because that family is appended by the handler, not the renderer; if the renderer's family list grows a `lb_stat` entry later, delete the append.)

Simplify: build `LbStats = safe(fun janus_lb:stats/0, #{})` once at the top and drop the unused `LbGauges` variable.

- [ ] **Step 3: Route**

In `janus_http_sup.erl` AdminDispatch, after the `/stats/[...]` line:

```erlang
            {"/metrics", janus_http_metrics, []}
```

- [ ] **Step 4: Compile + eunit** (container command from Task 2 Step 3, with `&& rebar3 eunit`). Expected: green.

- [ ] **Step 5: Commit**

```bash
git add apps/janus_http/src/janus_admin_auth.erl apps/janus_http/src/janus_gateway_stats.erl apps/janus_http/src/janus_http_metrics.erl apps/janus_http/src/janus_http_sup.erl
git commit -m "Add token-authenticated GET /metrics on the admin plane"
```

---

### Task 5: Hook the counters into the request paths

**Files:**
- Create: `apps/janus_http/src/janus_http_classify.erl` (single path→labels mapper — proxy and auth share it; no drift)
- Modify: `apps/janus_http/src/janus_http_proxy.erl`
- Modify: `apps/janus_http/src/janus_http_auth.erl`
- Modify: `apps/janus_http/src/janus_http_models.erl`

Metric surface (labels normalized by the registry):

| Series | Type | Labels | Bump site |
|---|---|---|---|
| `janus_requests_total` | counter | `endpoint` (chat/responses/messages/models/other), `protocol` (openai_chat/openai_responses/anthropic_messages/none/other), `status_class` (2xx/4xx/5xx/unknown) | proxy `track/3` + `janus_http_auth` 401 + models handler 2xx |
| `janus_request_duration_seconds` | histogram | `protocol`, `stream` (0/1) | proxy `track/3` (existing `LatencyMs`) |
| `janus_upstream_requests_total` | counter | `provider` (operator name), `status_class` | proxy `track/3` |

Rules: `/healthz` `/readyz` `/metrics` `/stats` are NOT counted. janus-auto inner calls stay invisible (`track/3` terminal guard). `/v1/models` gets `protocol="none"` (it is protocol-agnostic — never label it `openai_chat`). Crashes/disconnects that bypass `track/3` are uncounted by design (documented; the proxy crash fallback already tracks 500).

- [ ] **Step 1: The shared classifier**

```erlang
%%%-------------------------------------------------------------------
%%% @doc Path → closed-enum label values for metrics. Single source
%%% used by the proxy, auth rejects, and the models handler.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_classify).

-export([endpoint/1, protocol/1, status_class/1]).

endpoint(<<"/v1/chat/completions">>) -> chat;
endpoint(<<"/v1/responses">>) -> responses;
endpoint(<<"/v1/messages">>) -> messages;
endpoint(<<"/v1/models">>) -> models;
endpoint(_) -> other.

protocol(<<"/v1/chat/completions">>) -> openai_chat;
protocol(<<"/v1/responses">>) -> openai_responses;
protocol(<<"/v1/messages">>) -> anthropic_messages;
protocol(<<"/v1/models">>) -> none;
protocol(_) -> other.

status_class(S) when is_integer(S), S >= 200, S < 300 -> <<"2xx">>;
status_class(S) when is_integer(S), S >= 400, S < 500 -> <<"4xx">>;
status_class(S) when is_integer(S), S >= 500 -> <<"5xx">>;
status_class(_) -> <<"unknown">>.
```

- [ ] **Step 2: Proxy bumps** — in `track/3`, after the `logger:info(#{what => janus_request, ...})` call (inside the `is_map(Agent)` branch):

```erlang
            janus_metrics:inc(requests_total, #{
                endpoint => janus_http_classify:endpoint(get(janus_req_path)),
                protocol => Proto,
                status_class => janus_http_classify:status_class(Status)
            }),
            janus_metrics:observe(request_duration_seconds, #{
                protocol => Proto,
                stream => usage_bool_int(Stream)
            }, LatencyMs / 1000),
            janus_metrics:inc(upstream_requests_total, #{
                provider => route_provider_name(Route),
                status_class => janus_http_classify:status_class(Status)
            }),
```

and at proxy entry (`handle/5`, next to the existing pdict setup — do NOT add `janus_request_id`/`janus_req_path` to the erase list): `put(janus_req_path, cowboy_req:path(Req)),`

- [ ] **Step 3: Auth rejects** — in `janus_http_auth:unauthorized/2`, before the reply (auth rejects are currently silent in logs — add the warning too, mirroring `janus_agent_reject`):

```erlang
    janus_metrics:inc(requests_total, #{
        endpoint => janus_http_classify:endpoint(cowboy_req:path(Req)),
        protocol => janus_http_classify:protocol(cowboy_req:path(Req)),
        status_class => <<"4xx">>
    }),
    logger:warning(#{
        what => janus_agent_reject,
        status => 401,
        code => <<"unauthorized">>,
        request_id => get(janus_request_id),
        method => cowboy_req:method(Req),
        path => cowboy_req:path(Req)
    }),
```

- [ ] **Step 4: Models endpoint** — in `janus_http_models:init/2` success path: `janus_metrics:inc(requests_total, #{endpoint => models, protocol => none, status_class => <<"2xx">>}),` (the models handler is separate from the proxy — verify there is no double count; its errors post-auth are not counted, documented).

- [ ] **Step 5: Compile + eunit** (container). Expected: green.

- [ ] **Step 6: Commit**

```bash
git add apps/janus_http/src/janus_http_classify.erl apps/janus_http/src/janus_http_proxy.erl apps/janus_http/src/janus_http_auth.erl apps/janus_http/src/janus_http_models.erl
git commit -m "Bump request/upstream counters and duration histogram at terminal paths"
```

---

### Task 6: `janus_request_id` — resolve/sanitize (TDD) + integration

**Files:**
- Create: `apps/janus_http/src/janus_request_id.erl`
- Test: `apps/janus_http/test/janus_request_id_tests.erl`
- Modify: `apps/janus_http/src/janus_http_proxy.erl`
- Modify: `apps/janus_http/src/janus_http_chat.erl`, `janus_http_messages.erl`, `janus_http_responses.erl`, `janus_http_models.erl`

- [ ] **Step 1: Failing tests first**

```erlang
-module(janus_request_id_tests).
-include_lib("eunit/include/eunit.hrl").

generate_when_absent_test() ->
    Id = janus_request_id:resolve(undefined),
    ?assertMatch({0, _}, binary:match(Id, <<"req_">>)),
    ?assertEqual(20, byte_size(Id)),
    ?assertMatch(match, re:run(Id, <<"^req_[0-9a-f]{16}$">>) , {capture, none}).

accept_valid_test() ->
    ?assertEqual(<<"abc-DEF_0123">>, janus_request_id:resolve(<<"abc-DEF_0123">>)).

reject_bad_chars_test() ->
    ?assertMatch(<<"req_", _/binary>>, janus_request_id:resolve(<<"has spaces">>)),
    ?assertMatch(<<"req_", _/binary>>, janus_request_id:resolve(<<"emoji-", 16#F0, 16#9F, 16#98, 16#80>>)).

reject_too_long_test() ->
    ?assertMatch(<<"req_", _/binary>>, janus_request_id:resolve(binary:copy(<<"a">>, 129))).

accept_max_len_test() ->
    ?assertEqual(128, byte_size(janus_request_id:resolve(binary:copy(<<"a">>, 128)))).

unique_test() ->
    ?assertNotEqual(janus_request_id:resolve(undefined), janus_request_id:resolve(undefined)).
```

- [ ] **Step 2: Run, verify failure** (container; module undefined).

- [ ] **Step 3: Implement**

```erlang
%%%-------------------------------------------------------------------
%%% @doc Resolve the client-facing request id: honor a well-formed
%%% inbound x-request-id, else generate req_<16 lowercase hex>.
%%% Well-formed = 1..128 bytes of [A-Za-z0-9-_]. Anything else is
%%% ignored (never echoed back — response-header injection hygiene).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_request_id).

-export([resolve/1]).

-define(MAX_LEN, 128).

-spec resolve(binary() | undefined) -> binary().
resolve(In) when is_binary(In), byte_size(In) >= 1, byte_size(In) =< ?MAX_LEN ->
    case valid(In) of
        true -> In;
        false -> generate()
    end;
resolve(_) ->
    generate().

valid(Bin) ->
    lists:all(
        fun(C) ->
            (C >= $a andalso C =< $z) orelse
                (C >= $A andalso C =< $Z) orelse
                (C >= $0 andalso C =< $9) orelse
                C =:= $- orelse C =:= $_
        end,
        binary_to_list(Bin)
    ).

generate() ->
    %% encode_hex is uppercase; lowercase to match the documented
    %% req_[0-9a-f]{16} shape.
    Hex = string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(8))),
    <<"req_", Hex/binary>>.
```

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Integrate**

Handlers (`janus_http_chat|messages|responses|models:init/2`), first lines of `init/2` (before auth, so 401s echo the id too — chat shown):

```erlang
init(Req0, State) ->
    ReqId = janus_request_id:resolve(cowboy_req:header(<<"x-request-id">>, Req0)),
    Req1 = cowboy_req:set_resp_header(<<"x-request-id">>, ReqId, Req0),
    put(janus_request_id, ReqId),
    case janus_http_auth:require_agent(Req1) of
```

(The handler's Req chain shifts: `require_agent(Req1)`, body read from its returned Req, proxy called with it. `set_resp_header` covers all later replies incl. `stream_reply` on that Req.)

Proxy `track/3`: add `request_id => get(janus_request_id)` to the `logger:info` map AND the `janus_usage:record` map. Reject log (`reply_err/6`): add `request_id => get(janus_request_id)`. `handle/5` erase list: keep `janus_request_id` OUT of it (comment why: the handler puts it before the proxy runs).

`janus_usage:build_insert` gains the 12th column: column list becomes `(ts, agent_key_id, model_id, provider_id, provider_key_id, protocol, stream, status, prompt_tokens, completion_tokens, latency_ms, request_id)`, params list gains `bin_or_null(maps:get(request_id, Ev, null))`:

```erlang
bin_or_null(B) when is_binary(B) -> B;
bin_or_null(_) -> null.
```

`janus_usage_sql_tests:build_insert_shape_test`: 2-row fixture → 24 placeholders, 24 params; row-2 assertions shift: status at position 20, prompt at 21, request_id at 24.

- [ ] **Step 6: Compile + full eunit** (container). Expected: green.

- [ ] **Step 7: Commit**

```bash
git add apps/janus_http/src/janus_request_id.erl apps/janus_http/test/janus_request_id_tests.erl apps/janus_http/src/janus_http_*.erl apps/janus_core/src/janus_usage.erl apps/janus_core/test/janus_usage_sql_tests.erl
git commit -m "End-to-end request ids: echo x-request-id, log it, store it on usage rows"
```

---

### Task 7: Dashboard read path (sibling repo)

The gate's correlation step reads the latest usage row's `request_id` — the dashboard API must expose it.

**Files:**
- Modify: `../janus-dashboard/app/routers/usage.py` — SELECT gains `request_id`; event dict gains the field (nullable)
- Modify: `../janus-dashboard/spa/src/pages/shared.tsx` — `UsageEvent.request_id: string | null`
- Modify: `../janus-dashboard/spa/src/pages/usage.tsx` — recent table gains a mono truncated `request_id` column (click copies full id)

- [ ] **Step 1: Backend column** (read the usage router's existing SELECT; add `ue.request_id` following its existing column conventions; response event gains `"request_id": row.get("request_id")`)
- [ ] **Step 2: SPA type + column** (mono font, truncated with title tooltip, copy-on-click like the endpoints panel)
- [ ] **Step 3: SPA build** (`cd ../janus-dashboard/spa && npm run build`)
- [ ] **Step 4: Commit sibling repo**

---

### Task 8: E2E gate steps (sibling repo)

**Files:**
- Modify: `../janus-dashboard/scripts/e2e_local.sh` (follow the existing step structure)
- Modify: `../janus-dashboard/docs/TEST-FLOWS.md` (document the new steps per authoring rules)

New gate steps (all local, real stack; the gate self-heals seed provider/key/binding):

1. `GET :8090/metrics` without token (gate env sets `JANUS_STATS_TOKEN`) → **401**.
2. With token → **200**, `content-type: text/plain; version=0.0.4`, body contains `janus_build_info` (series that exists on an idle node — never assert a requests series before any call bumped it).
3. One real non-stream chat completion → poll-scrape until flush (≤2s): `janus_requests_total{endpoint="chat",protocol="openai_chat",status_class="2xx"}` incremented by exactly 1 vs the pre-call scrape; `janus_request_duration_seconds_count{protocol="openai_chat",stream="0"}` +1.
4. A streaming chat call → same scrape shape with `stream="1"`; the streamed response carries `x-request-id`.
5. Bad-key call → 401 and `status_class="4xx"` +1; the 401 response carries `x-request-id`.
6. Send `x-request-id: e2e-fixed-id-1` on a call → response header echoes it byte-identical; poll the dashboard `/api/usage/events?limit=1` (≤3s, writer flush is 1s) until the latest row's `request_id` equals it.
7. Call without the header → response `x-request-id` matches `^req_[0-9a-f]{16}$`.
8. Call with `x-request-id: "bad id with spaces"` → generated id instead (regex, NOT the inbound value).
9. `GET :8090/stats/logs?limit=50` (token-auth) → the newest `janus_request` event for the call contains the fixed id (assert substring `e2e-fixed-id-1`, format-agnostic).

Smoke (`run_test_flows.py --smoke`, read-only prod): `GET /metrics` with the node's stats token → 200 + contains `janus_build_info`.

- [ ] **Step 1: Implement the gate steps + TEST-FLOWS.md entries**
- [ ] **Step 2: Run the full gate**: `bash ../janus-dashboard/scripts/e2e_local.sh` — green (existing steps + new). Save the PASS/FAIL list + a captured `/metrics` sample to `/tmp/janus-e2e-<date>/` per artifact rules.
- [ ] **Step 3: Commit both repos** (commit messages reference the artifact path).

---

### Task 9: Grafana dashboard + scrape config + docs

**Files:**
- Create: `docker/grafana-dashboard.json`
- Create: `docker/prometheus.yml` (example)
- Modify: `README.md` (observability section)

- [ ] **Step 1: `docker/prometheus.yml`** — one job per node (per-node stats tokens are per-node credentials):

```yaml
# Example: one scrape job per gateway node (each has its own stats token).
scrape_configs:
  - job_name: janus-node-1
    scrape_interval: 15s
    metrics_path: /metrics
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/janus-node-1.token
    static_configs:
      - targets: ["janus-1:8090"]
  # janus-node-2, janus-node-3 identical shape with their token files.
```

- [ ] **Step 2: Grafana dashboard JSON** (uid `janus-overview`, title "Janus Gateway") — panels: request rate `sum by (endpoint, status_class) (rate(janus_requests_total[5m]))` (counters are node-local — sum across instances), error ratio, `histogram_quantile(0.95, sum by (le, stream) (rate(janus_request_duration_seconds_bucket[5m])))`, upstream error rate by provider, catalog generation per node (drift = `max != min` across instances), usage writer buffered rows / dropped rate, uptime. Note in the dashboard description: never `sum` LB gauges across nodes.

- [ ] **Step 3: README observability section** — endpoint + auth (same stats token; admin plane must never be exposed through Caddy without it; the loopback fallback reads the socket peer and never trusts `X-Forwarded-For`), example PromQL, the label-cardinality rule (closed enums + provider names only; never request/key/model labels), counter reset semantics on restart (`rate()` handles it), stream-duration semantics (end-to-end incl. client drain), inbound request ids are **untrusted client data** (never assume uniqueness).

- [ ] **Step 4: Commit**

---

### Task 10: Final gate + artifacts + report

- [ ] Full `e2e_local.sh` green with artifacts saved durably (`/tmp/janus-e2e-YYYYMMDD/`).
- [ ] Read-only prod smoke (`run_test_flows.py --smoke`) after the next deploy.
- [ ] Commit message(s) reference artifact paths per the testing rules.

---

## Self-review notes

- Spec coverage: metrics endpoint + auth (T2–T5), request IDs end-to-end (T1, T6), dashboard read path (T7), gate (T8), operator surface (T9), artifacts (T10).
- Cardinality discipline: labels are closed enums + operator provider names only; the three bump sites contain no dynamic values (provider names are operator-managed; deleted providers orphan their series until restart — documented in README).
- Counters reset on VM restart (same as `janus_http_stats`); Prometheus `rate()` handles resets; documented.
- Histogram sums are integer µs in ETS (update_counter is integer-only), rendered as seconds at scrape with full precision.
- Hot path per request: 3 counter bumps + ~13 bucket bumps + sum/count, each one `ets:update_counter` on a cached tid — ns-scale, try/catch'd; no formatting on the hot path (bucket binaries precomputed).
- The renderer is pure/deterministic/total: families sorted, one HELP+TYPE per family, buckets numerically ascending with `+Inf` last, `float_to_binary(F, [short])` values, escaped labels.
- Request-id echo is verified by construction (same Req chain) and asserted by the gate on 2xx, 401, and streamed responses.
- `null` atom params for nullable columns follow the existing `janus_usage` precedent on both drivers.
- Type consistency: `render/2` gauge input `{Name, Value, LabelsMap}` matches the handler; `usage_events.request_id` nullable TEXT end-to-end; gate regex matches `generate/0`'s lowercase hex.
- Out of scope (documented follow-ups): tracing (`traceparent`), per-key metrics (cardinality), alerting rules, log shipping.
