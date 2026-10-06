# Observability: Prometheus /metrics + End-to-End Request IDs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Janus a standard observability surface — a token-authenticated Prometheus `/metrics` endpoint on the admin plane and a client-visible `x-request-id` on every agent response, threaded through logs and usage rows.

**Architecture:** Metrics counters live in a public ETS table (write_concurrency) bumped from existing terminal paths (`janus_http_proxy:track/3` already fires once per terminal outcome; auth rejects bump in `janus_http_auth`). Gauges are computed at scrape time from existing sources (`janus_config`, `janus_lb`, `janus_usage:stats/0`, `janus_catalog`). A pure renderer turns an ETS snapshot into Prometheus text (eunit-first). Request IDs are resolved once per request (sanitize inbound or generate `req_<hex>`), echoed via `cowboy_req:set_resp_header` at proxy entry (covers success, error, and stream replies), added to the existing `janus_request` summary log + `janus_agent_reject` warning, and stored in a new nullable `usage_events.request_id` column (migration 005).

**Tech Stack:** Erlang/OTP (cowboy, atomics/ETS, thoas), Prometheus text exposition format (hand-rolled — no new dependency), SQLite + Postgres migrations, sibling-repo E2E gate (`../janus-dashboard/scripts/e2e_local.sh`).

**Testing rules (user-mandated, from AGENTS.md):** E2E is the sole test mechanism; pure parsers/logic may get eunit **written first** with production-shaped fixtures. All testing is local (`e2e_local.sh`); prod gets only the read-only smoke. Nothing is done until the local gate is green.

**Key file facts an implementer must know:**
- Admin plane (:8090) routes: `janus_http_sup.erl` AdminDispatch — `/healthz`, `/stats`, `/stats/[...]` (handler: `janus_gateway_stats.erl`). Auth pattern: `JANUS_STATS_TOKEN` bearer (constant-time compare) with loopback-only fallback when unset.
- Counter convention: atomics created ONCE at app init, kept in persistent_term, every call a no-op when missing (`janus_http_stats.erl` is the model). For labeled metrics we use a named public ETS table instead: `ets:update_counter(Tid, Key, Incr, {Key, 0})` creates-and-bumps atomically with no registry race.
- `janus_http_proxy:track/3` (line ~1200) fires once per terminal outcome with `{Status, Route, Usage}`; the failover system tags `janus_failover_*` pdict keys (`attempt`, `request_ref`, `is_terminal`) — request_ref is the INTERNAL failover correlation id; this plan adds the CLIENT-facing id as a separate column.
- Per-request log already exists: `logger:info(#{what => janus_request, ...})` in `track/3`; rejections: `logger:warning(#{what => janus_agent_reject, ...})` in `reply_err/6`.
- Proxy entry: `handle/5` erases/puts pdict ctx (`janus_usage_ctx` etc.); handlers: `janus_http_chat|messages|responses|models` (thin: auth → read_body → proxy).
- `janus_http_stats:init/0` is called from `janus_http_app.erl` (line 9) before listeners.
- Migrations: `apps/janus_core/priv/migrations/NNN_name.{postgres,sqlite}.sql` AND subdir copies `postgres/NNN_name.sql`, `sqlite/NNN_name.sql` (both layouts exist; AGENTS.md: subdirs canonical + flat copies). Next is `005`.
- `janus_db_conn:query/2` returns `{ok, Rows} | {error, _}`; `?` placeholders rewritten to `$N` for Postgres (pattern: `janus_usage:rewrite_pg/1`; no `?` inside SQL string literals).
- Release version: `application:get_key(janus, vsn)` (currently "0.1.0").

---

### Task 1: Migration 005 — `usage_events.request_id`

Nullable so old rows and non-proxy writers stay valid; indexed for log↔usage correlation lookups.

**Files:**
- Create: `apps/janus_core/priv/migrations/005_request_id.postgres.sql`
- Create: `apps/janus_core/priv/migrations/005_request_id.sqlite.sql`
- Create: `apps/janus_core/priv/migrations/postgres/005_request_id.sql`
- Create: `apps/janus_core/priv/migrations/sqlite/005_request_id.sql`

- [ ] **Step 1: SQLite files** (`005_request_id.sqlite.sql` and identical `sqlite/005_request_id.sql`)

```sql
-- Client-facing request id (x-request-id) for log/usage correlation.
ALTER TABLE usage_events ADD COLUMN request_id TEXT;

CREATE INDEX IF NOT EXISTS usage_events_request_id_idx ON usage_events (request_id);
```

- [ ] **Step 2: Postgres files** (`005_request_id.postgres.sql` and identical `postgres/005_request_id.sql`)

```sql
ALTER TABLE usage_events ADD COLUMN request_id TEXT;

CREATE INDEX IF NOT EXISTS usage_events_request_id_idx ON usage_events (request_id);
```

- [ ] **Step 3: Verify on the local stack** (migrations run at gateway boot; the E2E gate boots the real stack)

```bash
bash ../janus-dashboard/scripts/e2e_local.sh 2>&1 | tail -5
# then, inside the gate's Postgres:
docker exec janus-pg psql -U janus -c "\d usage_events" | grep request_id
```
Expected: `request_id | text |` row + index listed.

- [ ] **Step 4: Commit**

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
%%%   {counter, Name, Labels}   — Labels = sorted [{K, V}] binaries
%%%   {hist, Name, Labels, Le}  — Le = bucket bound binary ("0.1", "+Inf")
%%%   {hist_sum, Name, Labels} / {hist_count, Name, Labels}
%%% ets:update_counter/4 with a default tuple creates-and-bumps
%%% atomically — no registry process, no cast, no race on first use.
%%%
%%% Cardinality is bounded by construction: label VALUES come only from
%%% protocol/endpoint/status-class atoms and operator-defined provider
%%% names. Never put request ids, key ids, or model names in labels.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_metrics).

-export([init/0, inc/2, observe/3, snapshot/0]).
-export([buckets/0]).

-define(TABLE, janus_metrics).

%% Duration histogram buckets (seconds). Reasoning upstreams can take
%% minutes; the top bucket must cover that.
buckets() ->
    [0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300].

-spec init() -> ok.
init() ->
    _ = ets:new(?TABLE, [
        named_table, public, set,
        {write_concurrency, true},
        {read_concurrency, true}
    ]),
    ok.

%% inc(requests, #{endpoint => chat, protocol => openai_chat, status_class => <<"2xx">>})
-spec inc(atom(), map()) -> ok.
inc(Name, Labels) when is_atom(Name), is_map(Labels) ->
    bump({counter, Name, norm_labels(Labels)}, 1),
    ok.

%% observe(request_duration, #{protocol => ..., stream => 0|1}, Seconds)
-spec observe(atom(), map(), number()) -> ok.
observe(Name, Labels, Seconds) when is_atom(Name), is_map(Labels), is_number(Seconds) ->
    L = norm_labels(Labels),
    bump({hist_sum, Name, L}, Seconds),
    bump({hist_count, Name, L}, 1),
    lists:foreach(
        fun(Le) ->
            case Seconds =< Le of
                true -> bump({hist, Name, L, le_bin(Le)}, 1);
                false -> ok
            end
        end,
        buckets()
    ),
    bump({hist, Name, L, <<"+Inf">>}, 1),
    ok.

%% All rows as {Key, Value}; called by the renderer at scrape time.
-spec snapshot() -> [{tuple(), integer() | float()}].
snapshot() ->
    case ets:info(?TABLE) of
        undefined -> [];
        _ -> ets:tab2list(?TABLE)
    end.

%%% internal

bump(_Key, _Incr) when not is_atom(?TABLE) ->
    ok.  %% unreachable marker; see below

bump(Key, Incr) ->
    case ets:info(?TABLE) of
        undefined ->
            ok;
        _ ->
            _ = ets:update_counter(?TABLE, Key, Incr, {Key, 0}),
            ok
    end.

norm_labels(Labels) ->
    lists:sort([
        {to_bin(K), to_bin(V)}
     || {K, V} <- maps:to_list(Labels)
    ]).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I).

le_bin(Le) when is_float(Le) ->
    %% Render 0.1 not 0.10000000000000001
    list_to_binary(io_lib:format("~g", [Le])).
```

Delete the stray `bump/2` marker clause (`when not is_atom(?TABLE)` is nonsense — it is a placeholder reminder; the real clause below it carries the code). Final module has exactly one `bump/2`.

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
git commit -m "Add janus_metrics labeled ETS counter/histogram registry"
```

---

### Task 3: `janus_metrics_render` — pure exposition renderer (TDD)

**Files:**
- Create: `apps/janus_http/src/janus_metrics_render.erl`
- Test: `apps/janus_http/test/janus_metrics_render_tests.erl`

- [ ] **Step 1: Write the failing tests first** (production-shaped rows: `{Key, Value}` tuples straight from `ets:tab2list`, labels pre-sorted binaries)

```erlang
-module(janus_metrics_render_tests).
-include_lib("eunit/include/eunit.hrl").

counter_render_test() ->
    Rows = [
        {{counter, requests, [{<<"endpoint">>, <<"chat">>}, {<<"status_class">>, <<"2xx">>}]}, 42}
    ],
    Out = janus_metrics_render:render(Rows, []),
    ?assertEqual(
        <<"# TYPE janus_requests counter\n"
          "janus_requests{endpoint=\"chat\",status_class=\"2xx\"} 42\n">>,
        Out
    ).

histogram_render_test() ->
    L = [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"1">>}],
    Rows = [
        {{hist, request_duration, L, <<"0.1">>}, 3},
        {{hist, request_duration, L, <<"0.25">>}, 5},
        {{hist, request_duration, L, <<"+Inf">>}, 7},
        {{hist_sum, request_duration, L}, 0.9},
        {{hist_count, request_duration, L}, 7}
    ],
    Out = janus_metrics_render:render(Rows, []),
    ?assertMatch({_, _}, binary:match(Out, <<"# TYPE janus_request_duration histogram">>)),
    ?assertMatch({_, _}, binary:match(Out, <<"janus_request_duration_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"0.1\"} 3">>)),
    ?assertMatch({_, _}, binary:match(Out, <<"janus_request_duration_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"+Inf\"} 7">>)),
    ?assertMatch({_, _}, binary:match(Out, <<"janus_request_duration_sum{protocol=\"openai_chat\",stream=\"1\"} 0.9">>)),
    ?assertMatch({_, _}, binary:match(Out, <<"janus_request_duration_count{protocol=\"openai_chat\",stream=\"1\"} 7">>)).

gauge_render_test() ->
    Rows = [],
    Gauges = [{catalog_generation, 12, #{}}, {catalog_ready, 1, #{}}],
    Out = janus_metrics_render:render(Rows, Gauges),
    ?assertMatch({_, _}, binary:match(Out, <<"# TYPE janus_catalog_generation gauge\njanus_catalog_generation 12\n">>)),
    ?assertMatch({_, _}, binary:match(Out, <<"janus_catalog_ready 1\n">>)).

build_info_test() ->
    Out = janus_metrics_render:render([], [{build_info, 1, #{<<"version">> => <<"0.1.0">>}}]),
    ?assertMatch({_, _}, binary:match(Out, <<"janus_build_info{version=\"0.1.0\"} 1\n">>)).

label_escape_test() ->
    Rows = [{{counter, x, [{<<"k">>, <<"a\"b\\c\nd">>}]}, 1}],
    Out = janus_metrics_render:render(Rows, []),
    ?assertMatch({_, _}, binary:match(Out, <<"k=\"a\\\"b\\\\c\\nd\"">>)).
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
%%% Pure and total. Gauges are supplied by the caller (scrape-time
%%% reads) as {Name, Value, Labels} with Labels a #{K => V} map.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_metrics_render).

-export([render/2]).

-spec render([{tuple(), number()}], [{atom(), number(), map()}]) -> binary().
render(Rows, Gauges) ->
    Counters = [R || {{counter, _, _}, _} = R <- Rows],
    Hists = [R || {{hist, _, _, _}, _} = R <- Rows],
    Sums = maps:from_list([{K, V} || {{hist_sum, _, _} = K, V} <- Rows]),
    Counts = maps:from_list([{K, V} || {{hist_count, _, _} = K, V} <- Rows]),
    iolist_to_binary([
        render_counters(Counters),
        render_hists(Hists, Sums, Counts),
        render_gauges(Gauges)
    ]).

%%% internal — counters

render_counters(Rows) ->
    ByName = group_by_name(Rows),
    maps:fold(
        fun(Name, Rs, Acc) ->
            Lines = [
                [<<"janus_", (atom_to_binary(Name, utf8))/binary, labels_bin(L), " ", num_bin(V), "\n">>]
             || {{counter, _, L}, V} <- lists:keysort(1, Rs)
            ],
            [Acc, type_line(Name, <<"counter">>), Lines]
        end,
        [],
        ByName
    ).

group_by_name(Rows) ->
    lists:foldl(
        fun({{counter, Name, _} = K, V}, Acc) ->
            maps:update_with(Name, fun(L) -> [{K, V} | L] end, [{K, V}], Acc)
        end,
        #{},
        Rows
    ).

%%% internal — histograms

render_hists(Rows, Sums, Counts) ->
    ByKey = lists:foldl(
        fun({{hist, Name, L, Le}, V}, Acc) ->
            maps:update_with({Name, L}, fun(M) -> M#{Le => V} end, #{Le => V}, Acc)
        end,
        #{},
        Rows
    ),
    maps:fold(
        fun({Name, L}, BucketMap, Acc) ->
            Sum = maps:get({hist_sum, Name, L}, Sums, 0),
            Count = maps:get({hist_count, Name, L}, Counts, 0),
            Les = lists:sort(maps:keys(BucketMap)),
            BLines = [
                [
                    <<"janus_", (atom_to_binary(Name, utf8))/binary, "_bucket">>,
                    labels_bin(L ++ [{<<"le">>, Le}]),
                    " ", num_bin(maps:get(Le, BucketMap)), "\n"
                ]
             || Le <- Les
            ],
            NameB = atom_to_binary(Name, utf8),
            [
                Acc,
                type_line(Name, <<"histogram">>),
                BLines,
                <<"janus_", NameB/binary, "_sum", (labels_bin(L))/binary, " ", (num_bin(Sum))/binary, "\n">>,
                <<"janus_", NameB/binary, "_count", (labels_bin(L))/binary, " ", (num_bin(Count))/binary, "\n">>
            ]
        end,
        [],
        ByKey
    ).

%%% internal — gauges

render_gauges(Gauges) ->
    maps:fold(
        fun(Name, Vs, Acc) ->
            Lines = [
                [<<"janus_", (atom_to_binary(Name, utf8))/binary, labels_bin(norm(L)), " ", num_bin(V), "\n">>]
             || {V, L} <- Vs
            ],
            [Acc, type_line(Name, <<"gauge">>), Lines]
        end,
        [],
        lists:foldl(
            fun({Name, V, L}, Acc) -> maps:update_with(Name, fun(Vs) -> [{V, L} | Vs] end, [{V, L}], Acc) end,
            #{},
            Gauges
        )
    ).

norm(L) when is_map(L) -> lists:sort(maps:to_list(L)).

%%% internal — shared

type_line(Name, Type) ->
    B = atom_to_binary(Name, utf8),
    <<"# TYPE janus_", B/binary, " ", Type/binary, "\n">>.

labels_bin([]) ->
    <<>>;
labels_bin(Ls) ->
    Inner = string:join(
        [[K, "=\"", escape(V), "\""] || {K, V} <- Ls],
        ","
    ),
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
num_bin(F) when is_float(F) -> list_to_binary(io_lib:format("~g", [F])).
```

- [ ] **Step 4: Run, verify pass**

Same command as Step 2. Expected: `All 5 tests passed.`

- [ ] **Step 5: Commit**

```bash
git add apps/janus_http/src/janus_metrics_render.erl apps/janus_http/test/janus_metrics_render_tests.erl
git commit -m "Add pure Prometheus text renderer with label escaping"
```

---

### Task 4: `/metrics` handler + shared admin auth

**Files:**
- Create: `apps/janus_http/src/janus_admin_auth.erl` (extracted from `janus_gateway_stats.erl`)
- Modify: `apps/janus_http/src/janus_gateway_stats.erl` (delegate to the shared module — behavior identical)
- Create: `apps/janus_http/src/janus_http_metrics.erl`
- Modify: `apps/janus_http/src/janus_http_sup.erl` (add route)

- [ ] **Step 1: Extract the auth module** — move `authorize/1`, `bearer_token/1`, `token_eq/2`, `stats_token/0`, `is_loopback/1`, `unauthorized/2` verbatim from `janus_gateway_stats.erl` into `janus_admin_auth.erl` with `-export([authorize/1]).`; in `janus_gateway_stats:init/2` replace the `authorize(Req0)` call with `janus_admin_auth:authorize(Req0)` and delete the moved private functions.

- [ ] **Step 2: The handler**

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
    Usage = janus_usage:stats(),
    Base = janus_http_stats:snapshot(),
    {WallMs, _} = statistics(wall_clock),
    Version =
        case application:get_key(janus, vsn) of
            {ok, V} -> to_bin(V);
            _ -> <<"unknown">>
        end,
    Gauges = [
        {catalog_generation, janus_config:generation(), #{}},
        {catalog_ready, bool01(janus_config:ready()), #{}},
        {models_serving, models_serving(), #{}},
        {lb_routes_cooling, janus_lb:cooling_count(), #{}},
        {usage_writer_buffered_rows, maps:get(buffered, Usage, 0), #{}},
        {usage_writer_dropped_total_note, 0, #{}},
        {uptime_seconds, WallMs div 1000, #{}},
        {build_info, 1, #{<<"version">> => Version}}
    ],
    %% usage writer's dropped counter is cumulative — render as a
    %% counter, not a gauge (dropped via a dedicated series below).
    Body = janus_metrics_render:render(
        janus_metrics:snapshot(),
        [G || {N, _, _} = G <- Gauges, N =/= usage_writer_dropped_total_note]
    ),
    Body2 = <<
        Body/binary,
        "# TYPE janus_usage_writer_dropped_total counter\n",
        "janus_usage_writer_dropped_total ", (integer_to_binary(maps:get(dropped, Usage, 0)))/binary, "\n"
    >>,
    cowboy_req:reply(200, #{
        <<"content-type">> => <<"text/plain; version=0.0.4; charset=utf-8">>
    }, Body2, Req).

bool01(true) -> 1;
bool01(_) -> 0.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L).

models_serving() ->
    case janus_catalog:get() of
        #{catalog := #{models := Tid}} ->
            try
                Rows = ets:tab2list(Tid),
                Ids = sets:from_list([Id || {Id, #{id := Id}} <- Rows], [{version, 2}]),
                sets:size(Ids)
            catch
                _:_ -> 0
            end;
        _ ->
            0
    end.
```

(`usage_writer_dropped_total_note` is a zero-valued placeholder filtered out before render so the gauge list stays a homogeneous shape; the real series is appended as a counter.)

- [ ] **Step 3: Route**

In `janus_http_sup.erl` AdminDispatch, after the `/stats/[...]` line:

```erlang
            {"/metrics", janus_http_metrics, []}
```

- [ ] **Step 4: Compile + smoke on the local stack**

```bash
docker run --rm -v F:/Janus/apps:/app/apps -v F:/Janus/config:/app/config -v F:/Janus/rebar.config:/app/rebar.config -v F:/Janus/rebar.lock:/app/rebar.lock -v janus-ebin-otp27:/app/_build -w /app janus-build:test sh -c 'rebar3 compile && rebar3 eunit'
```
Expected: compile + all eunit green.

- [ ] **Step 5: Commit**

```bash
git add apps/janus_http/src/janus_admin_auth.erl apps/janus_http/src/janus_gateway_stats.erl apps/janus_http/src/janus_http_metrics.erl apps/janus_http/src/janus_http_sup.erl
git commit -m "Add token-authenticated GET /metrics on the admin plane"
```

---

### Task 5: Hook the counters into the request paths

**Files:**
- Modify: `apps/janus_http/src/janus_http_proxy.erl`
- Modify: `apps/janus_http/src/janus_http_auth.erl`
- Modify: `apps/janus_http/src/janus_http_models.erl`

Metric surface (labels sorted by the registry):

| Series | Type | Labels | Bump site |
|---|---|---|---|
| `janus_requests_total` | counter | `endpoint` (chat/responses/models), `protocol`, `status_class` | proxy `track/3` (terminal) + `janus_http_auth` 401 + models handler |
| `janus_request_duration_seconds` | histogram | `protocol`, `stream` (0/1) | proxy `track/3` (uses the existing `LatencyMs`) |
| `janus_upstream_requests_total` | counter | `provider`, `status_class` | proxy `track/3` (provider name via `route_provider_name/1`) |

Notes: `/healthz`/`/readyz`/`/metrics`/`/stats` are NOT counted (ops noise). janus-auto inner calls stay invisible (one client call = one bump) — `track/3`'s `is_terminal => true` guard already prevents inner-counting.

- [ ] **Step 1: Proxy bumps** — in `janus_http_proxy:track/3`, immediately after the `logger:info(#{what => janus_request, ...})` call (both bump inside the existing `is_map(Agent)` branch):

```erlang
            janus_metrics:inc(requests, #{
                endpoint => endpoint_of(get(janus_req_path)),
                protocol => Proto,
                status_class => status_class(Status)
            }),
            janus_metrics:observe(request_duration, #{
                protocol => Proto,
                stream => usage_bool_int(Stream)
            }, LatencyMs / 1000),
            janus_metrics:inc(upstream_requests, #{
                provider => route_provider_name(Route),
                status_class => status_class(Status)
            }),
```

Add helpers (internal section, next to `status_class` — if absent, add):

```erlang
status_class(S) when is_integer(S), S >= 500 -> <<"5xx">>;
status_class(S) when is_integer(S), S >= 400 -> <<"4xx">>;
status_class(_) -> <<"2xx">>.

endpoint_of(P) when is_binary(P) ->
    case P of
        <<"/v1/chat/completions">> -> chat;
        <<"/v1/responses">> -> responses;
        <<"/v1/messages">> -> messages;
        <<"/v1/models">> -> models;
        _ -> other
    end;
endpoint_of(_) ->
    other.
```

and at proxy entry (`handle/5`, with the other pdict setup): `put(janus_req_path, cowboy_req:path(Req)),` — verify whether `janus_req_path` already exists (the reject log uses `cowboy_req:path(Req)` directly; if a pdict path exists, reuse it).

- [ ] **Step 2: Auth rejects** — in `janus_http_auth:unauthorized/2`, before the reply:

```erlang
    janus_metrics:inc(requests, #{
        endpoint => endpoint_from(cowboy_req:path(Req)),
        protocol => protocol_from(cowboy_req:path(Req)),
        status_class => <<"4xx">>
    }),
```

with local helpers mapping path → endpoint/protocol (chat/responses/messages/models/other; protocol: openai_chat/openai_responses/anthropic_messages/other).

- [ ] **Step 3: Models endpoint** — in `janus_http_models:init/2` success reply path: `janus_metrics:inc(requests, #{endpoint => models, protocol => openai_chat, status_class => <<"2xx">>}),` (models is protocol-agnostic; label `openai_chat` keeps the enum closed — document).

- [ ] **Step 4: Compile + eunit** (same container command). Expected: green.

- [ ] **Step 5: Commit**

```bash
git add apps/janus_http/src/janus_http_proxy.erl apps/janus_http/src/janus_http_auth.erl apps/janus_http/src/janus_http_models.erl
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
    ?assertEqual(20, byte_size(Id)).

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

- [ ] **Step 2: Run, verify failure** (container eunit command; module undefined).

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
    Hex = binary:encode_hex(crypto:strong_rand_bytes(8)),
    <<"req_", Hex/binary>>.
```

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Integrate**

Handlers (`janus_http_chat|messages|responses|models:init/2`), first line of the `require_agent` ok-branch AND the error branch — the id must exist before auth so 401s echo it too. Pattern (chat shown):

```erlang
init(Req0, State) ->
    ReqId = janus_request_id:resolve(cowboy_req:header(<<"x-request-id">>, Req0)),
    Req1 = cowboy_req:set_resp_header(<<"x-request-id">>, ReqId, Req0),
    put(janus_request_id, ReqId),
    case janus_http_auth:require_agent(Req1) of
```

(The handler's existing `Req0` chain shifts accordingly: `require_agent(Req1)`, bodies read from the returned Req, etc. `set_resp_header` applies to all later replies including `stream_reply`.)

Proxy `track/3`: add `request_id => get(janus_request_id)` to the `logger:info` map AND to the `janus_usage:record(#{...})` map (new key `request_id`). Reject log (`reply_err/6`): add `request_id => get(janus_request_id)`.

`janus_usage:record` path: add `request_id` to the event → `build_insert` gains a 12th column. Update the INSERT column list to `(ts, agent_key_id, model_id, provider_id, provider_key_id, protocol, stream, status, prompt_tokens, completion_tokens, latency_ms, request_id)` and the params list with `bin_or_null(maps:get(request_id, Ev, null))`:

```erlang
bin_or_null(B) when is_binary(B) -> B;
bin_or_null(_) -> null.
```

(`janus_usage_sql_tests:build_insert_shape_test` param counts change 11→22 per row: update to 24 params / 24 placeholders for the 2-row fixture.)

- [ ] **Step 6: Compile + full eunit** (container). Expected: green.

- [ ] **Step 7: Commit**

```bash
git add apps/janus_http/src/janus_request_id.erl apps/janus_http/test/janus_request_id_tests.erl apps/janus_http/src/janus_http_*.erl apps/janus_core/src/janus_usage.erl
git commit -m "End-to-end request ids: echo x-request-id, log it, store it on usage rows"
```

---

### Task 7: E2E gate steps (sibling repo)

**Files:**
- Modify: `../janus-dashboard/scripts/e2e_local.sh` (or its Python step modules — follow existing structure)
- Modify: `../janus-dashboard/docs/TEST-FLOWS.md` (document the new steps per authoring rules)

New gate steps (all local, real stack; the gate self-heals a seed provider/key/binding already):

1. `GET :8090/metrics` without token (with `JANUS_STATS_TOKEN` set in the gate env) → **401**.
2. With token → **200**, `content-type: text/plain; version=0.0.4`, body contains `janus_requests_total` and `janus_build_info`.
3. One real chat completion (the gate already makes one) → scrape → `janus_requests_total{endpoint="chat",protocol="openai_chat",status_class="2xx"}` incremented by exactly 1 vs the pre-call scrape; `janus_request_duration_count{protocol="openai_chat",stream="0"}` incremented by 1.
4. A streaming chat call → `stream="1"` count increments.
5. Bad-key call → `status_class="4xx"` increments; response 401.
6. Send `x-request-id: e2e-fixed-id-1` on a call → response header echoes it byte-identical; dashboard `/api/usage/events?limit=1` latest row's `request_id` equals it (dashboard read path — SPA usage page uses this API).
7. Call without the header → response has `x-request-id: req_<16 hex>` matching `^req_[0-9a-f]{16}$`.
8. Call with `x-request-id: "bad id with spaces"` → generated id instead (regex check, NOT the inbound value).
9. The `janus_request` log line for the call contains `request_id=e2e-fixed-id-1` (via `/stats/logs` on the admin plane or the gate's log capture).

Smoke (`run_test_flows.py --smoke`, read-only prod): `GET /metrics` with the node's stats token → 200 + contains `janus_build_info`.

- [ ] **Step 1: Implement the gate steps + TEST-FLOWS.md entries**
- [ ] **Step 2: Run the full gate**: `bash ../janus-dashboard/scripts/e2e_local.sh` — must be green (existing ~47 steps + new ones). Save the PASS/FAIL list + a captured `/metrics` sample to `/tmp/janus-e2e-<date>/` per artifact rules.
- [ ] **Step 3: Commit both repos** (gateway commit message references the artifact path).

---

### Task 8: Grafana dashboard + scrape config + docs

**Files:**
- Create: `docker/grafana-dashboard.json` (committed dashboard)
- Create: `docker/prometheus.yml` (example scrape config)
- Modify: `README.md` (observability section)
- Modify: `docs/` config reference — document `JANUS_STATS_TOKEN` already covers `/metrics`.

- [ ] **Step 1: `docker/prometheus.yml` example**

```yaml
# Example: scrape all gateway nodes' admin planes.
scrape_configs:
  - job_name: janus
    scrape_interval: 15s
    metrics_path: /metrics
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/janus_stats_token  # per-node tokens: one job per node
    static_configs:
      - targets: ["janus-1:8090", "janus-2:8090", "janus-3:8090"]
```

- [ ] **Step 2: Grafana dashboard JSON** — panels: request rate by endpoint/status (rate over 5m), error ratio, p95 from `janus_request_duration_seconds` (`histogram_quantile(0.95, rate(...[5m]))` split by stream), upstream error rate by provider, catalog generation per node (generation drift = broken sync), usage writer buffered/dropped, uptime. Keep it minimal but real (uid `janus-overview`, title "Janus Gateway").

- [ ] **Step 3: README observability section** — endpoint, auth (same stats token), example PromQL, the label-cardinality rule (never request/key/model labels), screenshot placeholder.

- [ ] **Step 4: Commit**

---

### Task 9: Final gate + artifacts + report

- [ ] Full `e2e_local.sh` green with artifacts saved durably (`/tmp/janus-e2e-YYYYMMDD/`).
- [ ] Read-only prod smoke (`run_test_flows.py --smoke`) after the next deploy.
- [ ] Commit message(s) reference artifact paths per the testing rules.

---

## Self-review notes

- Spec coverage: metrics endpoint + auth (T2–T5), request IDs end-to-end (T1, T6), gate (T7), operator surface (T8), artifacts (T9).
- Cardinality discipline is the classic Prometheus footgun — labels are closed enums + operator provider names only; enforced by code review of the three bump sites (no dynamic label values exist in the patch).
- `track/3` fires once per terminal client outcome (failover inner attempts tagged non-terminal — no double counting).
- Counters reset on VM restart (same as `janus_http_stats` today) — Prometheus `rate()` handles resets; documented in the README section.
- The usage-writer `dropped` series is rendered as a counter (cumulative) while `buffered` is a gauge — intentional, matches Prometheus conventions.
- `/v1/models` labeled `openai_chat` keeps the protocol enum closed (it has no protocol); noted in Task 5.
- Type consistency: `janus_metrics_render:render/2` gauge input `{Name, Value, LabelsMap}` matches Task 4's handler construction; `usage_events.request_id` is nullable TEXT end-to-end (migration → `bin_or_null` → insert).
- Out of scope (documented follow-ups): dashboard UI correlation (logs page filter by request id), tracing (`traceparent`), per-key metrics (cardinality), alerting rules.
