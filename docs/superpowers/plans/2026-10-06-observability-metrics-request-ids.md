# Observability: Prometheus /metrics + End-to-End Request IDs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Janus a standard observability surface — a token-authenticated Prometheus `/metrics` endpoint on the admin plane and a client-visible `x-request-id` on every agent response, threaded through logs and usage rows.

**Architecture:** Metrics series live in a named public ETS table (write_concurrency) bumped from terminal paths (`janus_http_proxy:track/3` fires once per terminal outcome; auth rejects bump in `janus_http_auth`; `/v1/models` in its handler). Gauges are computed at scrape time from existing sources (`janus_config`, `janus_lb`, `janus_usage:stats/0`, `janus_catalog`). A pure renderer turns a sorted ETS snapshot into Prometheus text (eunit-first). Request IDs are resolved once per request (sanitize inbound or generate `req_<16 lowercase hex>`), echoed via `cowboy_req:set_resp_header` at handler entry (covers success, error, 401, and stream replies on the same Req chain), added to the `janus_request`/`janus_agent_reject`/auth-reject logs, and stored in a new nullable `usage_events.request_id` column (migration 005).

**Tech Stack:** Erlang/OTP (cowboy, atomics/ETS, thoas), Prometheus text exposition format (hand-rolled — no new dependency), SQLite + Postgres migrations, sibling-repo E2E gate (`../janus-dashboard/scripts/e2e_local.sh`), sibling-repo dashboard read path (`../janus-dashboard` FastAPI usage router + SPA type).

**Testing rules (user-mandated, from AGENTS.md):** E2E is the sole test mechanism; pure parsers/logic may get eunit **written first** with production-shaped fixtures. All testing is local; prod gets only the read-only smoke. Nothing is done until the local gate is green.

**Naming contract (locked by audit):** series are `janus_requests_total`, `janus_upstream_requests_total`, `janus_request_duration_seconds` (+`_bucket`/`_sum`/`_count`), gauges `janus_catalog_generation`, `janus_catalog_ready`, `janus_models_serving`, `janus_lb_routes_cooling`, `janus_usage_writer_buffered_rows`, `janus_uptime_seconds`, counters `janus_usage_writer_dropped_total` and `janus_lb_stats_total{stat="..."}` (cumulative LB counters — summable/rateable across nodes), and `janus_build_info` (TYPE `untyped` — `info` is OpenMetrics-only and invalid under `text/plain; version=0.0.4`). The renderer prefixes `janus_` onto the registered name and derives counter families **from the rows** (never a hardcoded family list). The E2E gate and the Grafana JSON use these exact strings.

**Key file facts an implementer must know:**
- Admin plane (:8090) routes: `janus_http_sup.erl` AdminDispatch — `/healthz`, `/stats`, `/stats/[...]` (handler: `janus_gateway_stats.erl`). Auth pattern: `JANUS_STATS_TOKEN` bearer (constant-time compare) with loopback-only fallback when unset. Loopback check reads the **socket peer IP** — `X-Forwarded-For` is never consulted; the admin plane must never be exposed through Caddy without the token (document in README).
- Counter convention: `janus_http_stats.erl` (atomics in persistent_term, no-op when missing). For labeled series we use a named ETS table with `ets:update_counter(Tid, Key, Incr, {Key, 0})` (atomic create-and-bump, no registry race). The tid is looked up per bump with `ets:whereis(?TABLE)` (constant-time, and immune to the persistent_term-survives-app-restart trap: a dead tid is never cached).
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
Expected: `request_id | text` + the index. (Boot-migration of a table WITH pre-existing rows is the interesting case — the gate's stack has usage rows from earlier runs.) Note: `CREATE INDEX` on `usage_events` takes a brief write lock — sub-second at current volume; if prod ever holds millions of rows, build the index manually with `CONCURRENTLY` before the rolling deploy (it cannot run inside a transaction — check `janus_migrate`'s wrapping first).

- [ ] **Step 2b: Document the schema change** — add the `request_id` column (nullable TEXT, client-facing id from the proxy) to `docs/SCHEMA_ETS_CONTRACT.md`'s usage_events entry.

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

- [ ] **Step 1: Registry eunit, written first** (per the testing rules — pure logic: cumulative bucket bumps, negative clamp, µs rounding, label normalization; `janus_metrics:init/0` + real ETS table)

Create `apps/janus_http/test/janus_metrics_tests.erl`:

```erlang
-module(janus_metrics_tests).
-include_lib("eunit/include/eunit.hrl").

setup() ->
    janus_metrics:init(),
    ets:delete_all_objects(janus_metrics).

cumulative_buckets_test() ->
    setup(),
    janus_metrics:observe(request_duration_seconds, #{protocol => openai_chat, stream => 0}, 0.4),
    Rows = janus_metrics:snapshot(),
    %% 0.4s lands in 0.5, 1, 2.5, … +Inf — cumulative: every bound >= 0.4.
    ?assertEqual(1, get({hist, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}], <<"0.5">>}, Rows)),
    ?assertEqual(0, get({hist, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}], <<"0.25">>}, Rows)),
    ?assertEqual(1, get({hist, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}], <<"+Inf">>}, Rows)),
    ?assertEqual(400000, get({hist_sum_us, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}]}, Rows)),
    ?assertEqual(1, get({hist_count, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}]}, Rows)).

negative_clamp_test() ->
    setup(),
    janus_metrics:observe(request_duration_seconds, #{protocol => openai_chat, stream => 0}, -1.0),
    Rows = janus_metrics:snapshot(),
    ?assertEqual(0, get({hist_sum_us, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}]}, Rows)),
    ?assertEqual(1, get({hist_count, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}]}, Rows)).

label_normalization_test() ->
    setup(),
    %% provider name as a LIST (DB charlist) must not crash or drop.
    janus_metrics:inc(upstream_requests_total, #{provider => "acme", status_class => <<"2xx">>}),
    Rows = janus_metrics:snapshot(),
    ?assertEqual(1, get({counter, upstream_requests_total, [{<<"provider">>, <<"acme">>}, {<<"status_class">>, <<"2xx">>}]}, Rows)).

init_idempotent_test() ->
    janus_metrics:init(),
    janus_metrics:init(),
    ?assert(lists:any(fun(T) -> T =:= janus_metrics end, ets:all())).

concurrent_observe_final_consistency_test() ->
    setup(),
    Self = self(),
    Pids = [
        spawn_link(fun() ->
            janus_metrics:observe(request_duration_seconds, #{protocol => openai_chat, stream => 0}, 0.3),
            Self ! done
        end)
     || _ <- lists:seq(1, 500)
    ],
    [receive done -> ok end || _ <- Pids],
    Rows = janus_metrics:snapshot(),
    L = [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}],
    Count = get({hist_count, request_duration_seconds, L}, Rows),
    Inf = get({hist, request_duration_seconds, L, <<"+Inf">>}, Rows),
    ?assertEqual(500, Count),
    ?assertEqual(Count, Inf),
    ?assert(Inf >= get({hist, request_duration_seconds, L, <<"0.5">>}, Rows)).

get(K, Rows) ->
    case lists:keyfind(K, 1, Rows) of
        {_, V} -> V;
        false -> 0
    end.
```

- [ ] **Step 2: Write the module**

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
%%% The table is looked up by name per bump via ets:whereis/1
%%% (constant-time, and never returns a stale tid — survives app
%%% restart). `ets:update_counter/4` with a default tuple
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

%% Duration buckets (seconds): fast path 0.05 → reasoning upstreams 600s.
%% Precomputed once — the hot path never formats floats, and the
%% descending order observe/3 bumps in is computed at parse time.
-define(BUCKETS_DESC, lists:reverse(buckets())).

-define(TABLE, janus_metrics).

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

%% The table is looked up by name on every bump (ets:whereis on a named
%% table is a constant-time atomic read — no persistent_term lifecycle
%% traps across app restarts).

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
        bump({counter, Name, norm_labels(Labels)}, 1)
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
        %% Integer microseconds — ETS update_counter is integer-only.
        %% Bump order is best-effort scrape hygiene: +Inf first, then
        %% the ladder DESCENDING (a concurrent tab2list then always sees
        %% bucket counts non-decreasing in le), sum, and count LAST —
        %% so count =< +Inf holds at every interleaving. Exact
        %% count == +Inf equality is unattainable without a multi-key
        %% transaction; the gate asserts >= and equality at quiescence.
        bump({hist, Name, L, <<"+Inf">>}, 1),
        lists:foreach(
            fun({Le, LeBin}) ->
                case Sec =< Le of
                    true -> bump({hist, Name, L, LeBin}, 1);
                    false -> ok
                end
            end,
            lists:reverse(buckets())
        ),
        bump({hist_sum_us, Name, L}, round(Sec * 1_000_000)),
        bump({hist_count, Name, L}, 1),
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
bump(Key, Incr) when is_integer(Incr) ->
    case ets:whereis(?TABLE) of
        undefined -> ok;
        Tid ->
            _ = ets:update_counter(Tid, Key, Incr, {Key, 0}),
            ok
    end.

norm_labels(Labels) ->
    lists:sort([
        {to_bin(K), to_bin(V)}
     || {K, V} <- maps:to_list(Labels)
    ]).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(F) when is_float(F) -> float_to_binary(F, [short]);
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).
```

- [ ] **Step 3: Wire init**

In `apps/janus_http/src/janus_http_app.erl`, after `ok = janus_http_stats:init(),`:

```erlang
    ok = janus_metrics:init(),
```

- [ ] **Step 4: Compile in the build container** (per AGENTS.md — never host Erlang; canonical command from AGENTS.md, including fmt --check):

```bash
docker build --target test -t janus-build:test .
docker run --rm -v F:/Janus/apps:/app/apps -v F:/Janus/config:/app/config -v F:/Janus/rebar.config:/app/rebar.config -v F:/Janus/rebar.lock:/app/rebar.lock -v janus-ebin-otp27:/app/_build -w /app janus-build:test sh -c 'rebar3 compile'
```
Expected: compiles clean.

- [ ] **Step 5: Commit**

```bash
git add apps/janus_http/src/janus_metrics.erl apps/janus_http/test/janus_metrics_tests.erl apps/janus_http/src/janus_http_app.erl
git commit -m "Add janus_metrics labeled ETS registry (integer µs histograms, whereis-per-bump)"
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
        <<"# HELP janus_requests_total Client LLM requests (terminal outcomes).\n"
          "# TYPE janus_requests_total counter\n"
          "janus_requests_total{endpoint=\"chat\",status_class=\"2xx\"} 42\n">>,
        Out
    ).

histogram_zero_filled_order_exact_test() ->
    %% Buckets: ALL canonical bounds emitted (zero-filled), numerically
    %% ascending, +Inf LAST — a lexicographic sort or sparse emission
    %% breaks histogram_quantile.
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
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"0.1\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"0.25\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"0.5\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"1\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"2.5\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"5\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"10\"} 5\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"30\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"60\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"120\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"1\",le=\"300\"} 0\n"
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

build_info_is_untyped_test() ->
    %% `info` is OpenMetrics-only; under text/0.0.4 it must be untyped.
    Out = janus_metrics_render:render([], [{build_info, 1, #{<<"version">> => <<"0.1.0">>}}]),
    ?assertMatch({_, _}, binary:match(Out, <<"# TYPE janus_build_info untyped">>)),
    ?assertMatch({_, _}, binary:match(Out, <<"janus_build_info{version=\"0.1.0\"} 1\n">>)).

label_escape_test() ->
    %% quote, backslash, newline escaped; NUL stripped (unrepresentable).
    Rows = [{{counter, requests_total, [{<<"k">>, <<"a\"b\\c\nd", 0>>}]}, 1}],
    Out = janus_metrics_render:render(Rows, []),
    ?assertMatch({_, _}, binary:match(Out, <<"k=\"a\\\"b\\\\c\\nd\"">>)).

dropped_counter_family_renders_test() ->
    %% The writer-drop counter is appended by the handler as a row —
    %% regression guard for the hardcoded-family-list bug.
    Rows = [{{counter, usage_writer_dropped_total, []}, 3}],
    Out = janus_metrics_render:render(Rows, []),
    ?assertMatch({_, _}, binary:match(Out, <<"# TYPE janus_usage_writer_dropped_total counter">>)),
    ?assertMatch({_, _}, binary:match(Out, <<"janus_usage_writer_dropped_total 3\n">>)).

unknown_counter_family_still_renders_test() ->
    %% Unregistered families render (no HELP) — never silently dropped.
    Rows = [{{counter, surprise_total, []}, 1}],
    Out = janus_metrics_render:render(Rows, []),
    ?assertMatch({_, _}, binary:match(Out, <<"# TYPE janus_surprise_total counter\njanus_surprise_total 1\n">>)).

families_sorted_once_test() ->
    %% One TYPE/HELP line per family, families in name order, no
    %% duplicate TYPE lines even with several label sets.
    Rows = [
        {{counter, requests_total, [{<<"endpoint">>, <<"models">>}, {<<"status_class">>, <<"2xx">>}]}, 2},
        {{counter, requests_total, [{<<"endpoint">>, <<"chat">>}, {<<"status_class">>, <<"2xx">>}]}, 1}
    ],
    Out = janus_metrics_render:render(Rows, []),
    ?assertEqual(1, count_occ(Out, <<"# TYPE janus_requests_total">>)),
    ?assertEqual(1, count_occ(Out, <<"# HELP janus_requests_total">>)).

mixed_snapshot_exact_test() ->
    %% One of each kind: registered counter, unregistered counter
    %% (renders without HELP), histogram, gauge, untyped build_info.
    Rows = [
        {{counter, requests_total, [{<<"endpoint">>, <<"chat">>}, {<<"status_class">>, <<"2xx">>}]}, 1},
        {{counter, usage_writer_dropped_total, []}, 2},
        {{hist, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}], <<"0.05">>}, 1},
        {{hist, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}], <<"+Inf">>}, 1},
        {{hist_sum_us, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}]}, 30000},
        {{hist_count, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}]}, 1}
    ],
    Gauges = [
        {build_info, 1, #{<<"version">> => <<"0.1.0">>}},
        {catalog_generation, 7, #{}}
    ],
    Out = janus_metrics_render:render(Rows, Gauges),
    Expected = <<
        "# HELP janus_requests_total Client LLM requests (terminal outcomes).\n"
        "# TYPE janus_requests_total counter\n"
        "janus_requests_total{endpoint=\"chat\",status_class=\"2xx\"} 1\n"
        "# HELP janus_usage_writer_dropped_total Usage events dropped by the writer.\n"
        "# TYPE janus_usage_writer_dropped_total counter\n"
        "janus_usage_writer_dropped_total 2\n"
        "# HELP janus_request_duration_seconds End-to-end request duration (streams include client drain).\n"
        "# TYPE janus_request_duration_seconds histogram\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"0.05\"} 1\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"0.1\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"0.25\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"0.5\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"1\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"2.5\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"5\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"10\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"30\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"60\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"120\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"300\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"600\"} 0\n"
        "janus_request_duration_seconds_bucket{protocol=\"openai_chat\",stream=\"0\",le=\"+Inf\"} 1\n"
        "janus_request_duration_seconds_sum{protocol=\"openai_chat\",stream=\"0\"} 0.03\n"
        "janus_request_duration_seconds_count{protocol=\"openai_chat\",stream=\"0\"} 1\n"
        "# HELP janus_build_info Build/version info.\n"
        "# TYPE janus_build_info untyped\n"
        "janus_build_info{version=\"0.1.0\"} 1\n"
        "# HELP janus_catalog_generation Serving catalog generation.\n"
        "# TYPE janus_catalog_generation gauge\n"
        "janus_catalog_generation 7\n"
    >>,
    ?assertEqual(Expected, Out).

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
%%% Pure, total, deterministic: grouped counters → histograms → gauges,
%%% name-sorted within each group; one HELP+TYPE per family (HELP
%%% omitted for unregistered families — they still render); histogram
%%% buckets zero-filled to the canonical ladder UNION any bound already
%%% present in ETS (a ladder edited between deploys never silently
%%% drops a series), numerically ascending with +Inf last; labels
%%% sorted by key with `le` appended last; floats via [short].
%%% @end
%%%-------------------------------------------------------------------
-module(janus_metrics_render).

-export([render/2]).

%% Family registry: name => {type, help}. Drives TYPE/HELP lines.
%% Unregistered counter families still render — a series must never
%% silently vanish (that was the audit's bug class).
-define(FAMILIES, #{
    requests_total => {counter, <<"Client LLM requests (terminal outcomes).">>},
    upstream_requests_total => {counter, <<"Terminal client outcomes by provider (failover inner attempts excluded).">>},
    usage_writer_dropped_total => {counter, <<"Usage events dropped by the writer.">>},
    request_duration_seconds => {histogram, <<"End-to-end request duration (streams include client drain).">>},
    catalog_generation => {gauge, <<"Serving catalog generation.">>},
    catalog_ready => {gauge, <<"Serving catalog warm (1) or cold (0).">>},
    models_serving => {gauge, <<"Models in the serving catalog.">>},
    lb_routes_cooling => {gauge, <<"LB routes currently cooling down.">>},
    lb_stats_total => {counter, <<"LB counters from janus_lb:stats/0 (cumulative).">>},
    usage_writer_buffered_rows => {gauge, <<"Usage writer buffered rows.">>},
    uptime_seconds => {gauge, <<"VM wall-clock uptime.">>},
    build_info => {untyped, <<"Build/version info.">>}
}).

-spec render([{tuple(), integer()}], [{atom(), number(), map()}]) -> binary().
render(Rows, Gauges) ->
    Sums = maps:from_list([{K, V} || {{hist_sum_us, _, _} = K, V} <- Rows]),
    Counts = maps:from_list([{K, V} || {{hist_count, _, _} = K, V} <- Rows]),
    CounterNames = name_sort(lists:usort([N || {{counter, N, _}, _} <- Rows])),
    HistNames = name_sort(lists:usort([N || {{hist, N, _, _}, _} <- Rows])),
    GaugeNames = name_sort(lists:usort([N || {N, _, _} <- Gauges])),
    iolist_to_binary([
        [render_counter_family(N, Rows) || N <- CounterNames],
        [render_hist_family(N, Rows, Sums, Counts) || N <- HistNames],
        [render_gauge_family(N, Gauges) || N <- GaugeNames]
    ]).

%%% internal — counter family

render_counter_family(Name, Rows) ->
    Series = lists:sort([{L, V} || {{counter, N, L}, V} <- Rows, N =:= Name]),
    case Series of
        [] -> [];
        _ ->
            Lines = [
                [name_bin(Name), labels_bin(L), " ", integer_to_binary(V), "\n"]
             || {L, V} <- Series
            ],
            [help_line(Name), type_line(Name, counter), Lines]
    end.

%%% internal — histogram family

render_hist_family(Name, Rows, Sums, Counts) ->
    ByLabels = lists:foldl(
        fun
            ({{hist, N, L, Le}, V}, Acc) when N =:= Name ->
                maps:update_with(L, fun(M) -> M#{Le => V} end, #{Le => V}, Acc);
            (_, Acc) ->
                Acc
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
    %% Canonical ladder UNION whatever bounds ETS already holds (a
    %% ladder edited between deploys must not silently drop series),
    %% numerically ascending, +Inf last, zero-filled.
    NameB = name_bin(Name),
    Canonical = [LeBin || {_Le, LeBin} <- janus_metrics:buckets()] ++ [<<"+Inf">>],
    All = lists:usort(Canonical ++ maps:keys(BucketMap)),
    %% +Inf never parses as a float — whitelist it BEFORE the validity
    %% partition. Unparseable non-canonical bounds (hand-crafted rows,
    %% ladder edits) are dropped silently: the registry owns all
    %% producer-side LeBin values, so this is defense-in-depth, and the
    %% byte-exact gate assertions catch real breakage. (Renderer stays
    %% pure — no logging here.)
    {Valid, _Dropped} = lists:partition(
        fun(Le) -> Le =:= <<"+Inf">> orelse le_num(Le) =/= invalid end, All
    ),
    Les = lists:sort(
        fun
            (<<"+Inf">>, _) -> false;
            (_, <<"+Inf">>) -> true;
            (A, B) -> le_num(A) =< le_num(B)
        end,
        Valid
    ),
    SumUs = maps:get({hist_sum_us, Name, L}, Sums, 0),
    Count = maps:get({hist_count, Name, L}, Counts, 0),
    BLines = [
        [
            NameB, "_bucket", labels_bin(L ++ [{<<"le">>, Le}]), " ",
            integer_to_binary(maps:get(Le, BucketMap, 0)), "\n"
        ]
     || Le <- Les
    ],
    %% One concatenated iolist — buckets + _sum + _count.
    [
        BLines,
        [NameB, "_sum", labels_bin(L), " ", float_to_binary(SumUs / 1_000_000, [short]), "\n"],
        [NameB, "_count", labels_bin(L), " ", integer_to_binary(Count), "\n"]
    ].

le_num(Le) ->
    try binary_to_float(Le)
    catch _:_ -> (try float(binary_to_integer(Le)) catch _:_ -> invalid end)
    end.

%%% internal — gauge family

render_gauge_family(Name, Gauges) ->
    %% Sort by LABELS (not value — output must not churn with values).
    Series = lists:sort([{norm_labels(L), V} || {N, V, L} <- Gauges, N =:= Name]),
    case Series of
        [] -> [];
        _ ->
            %% Registry type wins; unregistered gauge families render as
            %% gauge (never the counter default).
            Type = fam_type(Name, gauge),
            Lines = [
                [name_bin(Name), labels_bin(L), " ", num_bin(V), "\n"]
             || {L, V} <- Series
            ],
            [help_line(Name), type_line(Name, Type), Lines]
    end.

%%% internal — shared

%% Atom term order is not name order across the BEAM — sort by the
%% name's binary so output is stable across nodes and builds.
name_sort(Names) ->
    lists:sort(fun(A, B) -> atom_to_binary(A, utf8) =< atom_to_binary(B, utf8) end, Names).

fam_type(Name, Default) ->
    case maps:get(Name, ?FAMILIES, undefined) of
        {T, _} -> T;
        undefined -> Default
    end.

help_line(Name) ->
    case maps:get(Name, ?FAMILIES, undefined) of
        undefined -> [];
        {_, Text} -> <<"# HELP ", (name_bin(Name))/binary, " ", Text/binary, "\n">>
    end.

type_line(Name, Type) ->
    <<"# TYPE ", (name_bin(Name))/binary, " ", (atom_to_binary(Type, utf8))/binary, "\n">>.

name_bin(Name) ->
    <<"janus_", (atom_to_binary(Name, utf8))/binary>>.

norm_labels(L) when is_map(L) ->
    lists:sort([{to_bin(K), to_bin(V)} || {K, V} <- maps:to_list(L)]);
norm_labels(L) when is_list(L) ->
    lists:sort(L).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(F) when is_float(F) -> float_to_binary(F, [short]);
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).

labels_bin([]) ->
    <<>>;
labels_bin(Ls) ->
    Inner = lists:join(<<",">>, [[K, "=\"", escape(V), "\""] || {K, V} <- Ls]),
    iolist_to_binary(["{", Inner, "}"]).

escape(V) ->
    %% Prometheus label values: NUL is unrepresentable (strip), then
    %% backslash, double-quote, newline escaped.
    binary:replace(
        binary:replace(
            binary:replace(
                binary:replace(V, <<0>>, <<>>, [global]),
                <<"\\">>, <<"\\\\">>, [global]
            ),
            <<"\"">>, <<"\\\"">>, [global]
        ),
        <<"\n">>, <<"\\n">>, [global]
    ).

num_bin(I) when is_integer(I) -> integer_to_binary(I);
num_bin(F) when is_float(F) -> float_to_binary(F, [short]).
```

- [ ] **Step 4: Run, verify pass** — same command as Step 2. Expected: `All 9 tests passed.`

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

- [ ] **Step 1b: Pre-coding verification** — before wiring the handler, confirm every scrape-time source exists with the expected shape (grep, don't assume): `janus_config:generation/0` + `ready/0`, `janus_lb:cooling_count/0`; `janus_lb:stats/0` — keys are a CLOSED set of counter names, values are integers, and **values are cumulative for the node's boot lifetime** (verified by reading `janus_lb.erl`: the stats ETS map only ever increments — no decrement/reset on route removal; this is what justifies the `_total` counter TYPE); `janus_usage:stats/0` keys (`buffered`, `dropped` — confirm `dropped` is cumulative-since-writer-boot, not per-window) + `alive`; the `janus_catalog:get()` → `#{catalog := #{models := Tid}}` row shape (`models_serving/0` mirrors `janus_gateway_stats`'s existing one — if it has drifted, fix both); and in `janus_http_proxy:track/3`, the variable names `Route`/`Proto`/`Status`/`Stream`/`LatencyMs` + helpers `usage_bool_int/1`, `route_provider_name/1`.

- [ ] **Step 1c: Shared `models_serving`** — move `models_serving/0` out of `janus_gateway_stats.erl` into `janus_http_stats.erl` as a public export (it is counter/state infrastructure, not endpoint logic); both `janus_gateway_stats` and `janus_http_metrics` call `janus_http_stats:models_serving()` (no duplicated catalog-shape logic to drift).

- [ ] **Step 2: The handler** — the writer-drop counter is appended to the snapshot rows (the renderer's registry covers it); LB failover counters ride through the renderer as the `lb_stats_total` counter family (one `janus_lb:stats/0` call, sorted/escaped by the renderer). Non-GET gets a 405.

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
            ok ->
                case cowboy_req:method(Req0) of
                    <<"GET">> -> render(Req0);
                    _ ->
                        cowboy_req:reply(405, #{
                            <<"content-type">> => <<"application/json">>,
                            <<"allow">> => <<"GET">>
                        }, thoas:encode(#{error => #{code => <<"method_not_allowed">>}}), Req0)
                end;
            {error, Req1} -> Req1
        end,
    {ok, Req, State}.

render(Req) ->
    Usage = safe(fun janus_usage:stats/0, #{}, usage_stats),
    LbStats = safe(fun janus_lb:stats/0, #{}, lb_stats),
    {WallMs, _} = statistics(wall_clock),
    Version =
        case application:get_key(janus, vsn) of
            {ok, V} -> to_bin(V);
            _ -> <<"unknown">>
        end,
    %% Dropped/buffered come from another process's map — validate
    %% before they reach integer_to_binary (one bad value must not
    %% 500 the whole scrape).
    Dropped = int_or_zero(maps:get(dropped, Usage, 0), usage_dropped),
    Buffered = int_or_zero(maps:get(buffered, Usage, 0), usage_buffered),
    %% Cumulative counters appended as counter rows (registered
    %% families in the renderer): the writer's dropped count, plus the
    %% LB failover counters from janus_lb:stats/0 (one call; a skipped
    %% non-integer value logs once per scrape, not silently).
    LbRows = [
        {{counter, lb_stats_total, [{<<"stat">>, to_bin(K)}]}, V}
     || {K, V} <- maps:to_list(LbStats), is_integer(V)
    ],
    %% One batched warning per scrape for skipped non-integer values.
    BadStats = [K || {K, V} <- maps:to_list(LbStats), not is_integer(V)],
    case BadStats of
        [] -> ok;
        _ -> logger:warning(#{what => janus_metrics_lb_stat_skip, stats => BadStats})
    end,
    Rows =
        janus_metrics:snapshot() ++
            [{{counter, usage_writer_dropped_total, []}, Dropped}] ++
            LbRows,
    Gauges = [
        {catalog_generation, safe(fun janus_config:generation/0, 0, catalog_generation), #{}},
        {catalog_ready, bool01(safe(fun janus_config:ready/0, false, catalog_ready)), #{}},
        {models_serving, safe(fun janus_http_stats:models_serving/0, 0, models_serving), #{}},
        {lb_routes_cooling, safe(fun janus_lb:cooling_count/0, 0, lb_cooling), #{}},
        {usage_writer_buffered_rows, Buffered, #{}},
        {uptime_seconds, WallMs div 1000, #{}},
        {build_info, 1, #{<<"version">> => Version}}
    ],
    %% A render failure must not wedge the scrape: 500 + log.
    try
        Body = janus_metrics_render:render(Rows, Gauges),
        cowboy_req:reply(200, #{
            <<"content-type">> => <<"text/plain; version=0.0.4; charset=utf-8">>
        }, Body, Req)
    catch
        Class:Reason:Stack ->
            logger:error(#{
                what => janus_metrics_render_error,
                class => Class, reason => Reason, stack => Stack
            }),
            cowboy_req:reply(500, #{
                <<"content-type">> => <<"text/plain; charset=utf-8">>
            }, <<"render error\n">>, Req)
    end.

%% Scrape-time sources get logged defaults on failure — a perpetually
%% failing gauge source is visible in the gateway log, not just zeros.
safe(Fun, Default, What) ->
    try Fun()
    catch
        Class:Reason ->
            logger:warning(#{
                what => janus_metrics_gauge_error, source => What,
                class => Class, reason => Reason
            }),
            Default
    end.

bool01(true) -> 1;
bool01(1) -> 1;
bool01(_) -> 0.

%% Scrape values from other processes are untrusted shapes — coerce or
%% zero + warn, never crash the scrape on one bad value.
int_or_zero(V, _What) when is_integer(V) ->
    V;
int_or_zero(V, What) ->
    logger:warning(#{what => janus_metrics_gauge_error, source => What, value => V}),
    0.

%% Reuse the registry's total to_bin (never hand another partial one).
to_bin(V) ->
    janus_metrics:to_bin(V).
```

- [ ] **Step 3: Route**

In `janus_http_sup.erl` AdminDispatch, after the `/stats/[...]` line:

```erlang
            {"/metrics", janus_http_metrics, []}
```

- [ ] **Step 4: Compile + eunit** (container command from Task 2 Step 4, with `&& rebar3 eunit`). Expected: green.

- [ ] **Step 5: Commit**

```bash
git add apps/janus_http/src/janus_admin_auth.erl apps/janus_http/src/janus_gateway_stats.erl apps/janus_http/src/janus_http_metrics.erl apps/janus_http/src/janus_http_sup.erl apps/janus_http/src/janus_http_stats.erl
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

Rules: `/healthz` `/readyz` `/metrics` `/stats` are NOT counted. janus-auto inner calls stay invisible (`track/3` terminal guard). `/v1/models` gets `protocol="none"` (it is protocol-agnostic — never label it `openai_chat`). Cowboy-router 404s on unmatched paths run no handler — uncounted, and no `x-request-id` is echoed there (echo scope = the four agent endpoints); both are documented exclusions. Crashes that bypass `track/3` are uncounted by design (the proxy crash fallback tracks 500). Handler-entry 413 (cowboy body limit, before the proxy) is the one documented exclusion; the proxy-level `request_too_large` (auto-router context guard) IS counted via `reply_err/6` — distinct paths. The proxy never copies upstream response headers onto the client reply (`filter_headers` keeps only content-type) — an upstream `x-request-id` can never clobber ours (verify by reading `filter_headers/1` during implementation; the gate asserts exactly one `x-request-id` header on responses). Duplicate inbound `x-request-id` headers comma-join under Cowboy → fail the charset check → a generated id replaces them (correct; documented).

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

and at proxy entry (`handle/5`, next to the existing pdict setup — do NOT add `janus_request_id`/`janus_req_path` to the erase list; DO add `janus_req_counted`):

```erlang
    erase(janus_req_counted),
    put(janus_req_path, cowboy_req:path(Req)),
```

- [ ] **Step 2b: Early rejects counted via `reply_err/6`** — rejects that never reach an upstream (`invalid_json`, `model_not_allowed`, `no_route`, `catalog_not_ready`, `stream_requires_native_protocol`, `request_too_large`, translate errors) bypass `track/3`. Count them in the central `reply_err/6`, guarded against the upstream-error paths that already tracked (`{error, Reason}`/`crashed` → `track(500|502)` then `reply_err`):

In `track/3` (before or after the inc — order irrelevant within the process): `put(janus_req_counted, true),`

In `reply_err/6` (before the reply):

```erlang
    case get(janus_req_counted) of
        true ->
            ok;
        _ ->
            put(janus_req_counted, true),
            janus_metrics:inc(requests_total, #{
                endpoint => janus_http_classify:endpoint(cowboy_req:path(Req)),
                protocol => janus_http_classify:protocol(cowboy_req:path(Req)),
                status_class => janus_http_classify:status_class(Status)
            })
    end,
```

- [ ] **Step 3: Auth rejects** — in `janus_http_auth:unauthorized/2`, before the reply (auth rejects are currently silent in logs — add the warning too, mirroring `janus_agent_reject`). The `request_id` field lands in Task 6 (at this intermediate commit it logs `undefined` — harmless):

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
- Modify: `apps/janus_http/src/janus_http_auth.erl` (auth-reject log gains `request_id`)
- Modify: `apps/janus_http/src/janus_http_chat.erl`, `janus_http_messages.erl`, `janus_http_responses.erl`, `janus_http_models.erl`

- [ ] **Step 1: Failing tests first**

```erlang
-module(janus_request_id_tests).
-include_lib("eunit/include/eunit.hrl").

generate_when_absent_test() ->
    Id = janus_request_id:resolve(undefined),
    ?assertMatch({0, _}, binary:match(Id, <<"req_">>)),
    ?assertEqual(20, byte_size(Id)),
    ?assertEqual(match, re:run(Id, <<"^req_[0-9a-f]{16}$">>, [{capture, none}])).

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
    %% req_[0-9a-f]{16} shape. crypto:strong_rand_bytes is guarded:
    %% request ids must never 500 a request — fall back to a
    %% unique_integer-derived hex if crypto is unavailable.
    try
        Hex = string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(8))),
        <<"req_", Hex/binary>>
    catch
        _:_ ->
            Hex = string:lowercase(
                binary:encode_hex(binary:encode_unsigned(erlang:unique_integer([positive])))
            ),
            <<"req_", Hex/binary>>
    end.
```

(`crypto` must be in `janus_http.app.src` `applications` — it currently is NOT; add it in this task. The `janus_admin_auth` constant-time compare already uses `crypto:hash_equals` and works because cowboy pulls crypto transitively — the explicit dep ends that accident.)

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

(The handler's Req chain shifts: `require_agent(Req1)`, body read from its returned Req, proxy called with it. `set_resp_header` covers all later replies incl. `stream_reply` on that Req. Each handler also erases `janus_req_counted` BEFORE any reply path — a leftover `true` from a previous request on a keep-alive process would silently suppress the early-reject bump:

```erlang
    erase(janus_req_counted),
```

The proxy `handle/5` entry also erases it — belt and braces; the handler erase is the authoritative per-request reset. Note `janus_req_path` is self-contained at proxy entry (put there); only `janus_request_id` must survive from the handler.)

Proxy `track/3`: add `request_id => get(janus_request_id)` to the `logger:info` map AND the `janus_usage:record` map. Reject log (`reply_err/6`): add `request_id => get(janus_request_id)`. Auth-reject log (`janus_http_auth:unauthorized/2` warning added in Task 5): add `request_id => get(janus_request_id)` (the handler puts it before `require_agent` runs). `handle/5` erase list: keep `janus_request_id` OUT of it (comment why: the handler puts it before the proxy runs).

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

- [ ] **Step 1: Backend column** (read the usage router's existing SELECT; add `ue.request_id` following its existing column conventions; response event gains `"request_id": row.get("request_id")`). **Deploy order:** gateways with migration 005 ship BEFORE this dashboard change (deploy_prod rebuilds gateway images first) — a dashboard reading `request_id` from an unmigrated Postgres would 500.
- [ ] **Step 2: SPA type + column** (mono font, truncated with title tooltip, copy-on-click like the endpoints panel)
- [ ] **Step 2b: Browser verification (testing rule 4)** — open the usage page in a real browser, confirm the request id column renders and copy-on-click works, save the screenshot with the run artifacts.
- [ ] **Step 3: SPA build** (`cd ../janus-dashboard/spa && npm run build`)
- [ ] **Step 4: Commit sibling repo**

---

### Task 8: E2E gate steps (sibling repo)

**Files:**
- Modify: `../janus-dashboard/scripts/e2e_local.sh` (follow the existing step structure)
- Modify: `../janus-dashboard/docs/TEST-FLOWS.md` (document the new steps per authoring rules)

New gate steps (all local, real stack; the gate self-heals seed provider/key/binding):

1. `GET :8090/metrics` without token (gate env sets `JANUS_STATS_TOKEN`) → **401**; a tokenless `POST` → **401** (auth runs before the method check); a **token-carrying** `POST` → **405** with `allow: GET`.
1b. `GET :8080/metrics` (agent plane) → **404** — metrics must never leak onto the agent plane.
2. With token → **200**, `content-type` contains `text/plain` (substring assert), body contains `janus_build_info` (present on an idle node — never assert a requests series before any call bumped it), `janus_usage_writer_dropped_total` (appended even at 0), and gauges with real values on the seeded stack (after the gate's catalog warmup): `janus_catalog_generation` ≥ 1, `janus_models_serving` ≥ 1, `janus_uptime_seconds` > 0 (guards against silently-wrong zero gauges). Histogram sanity: for every `janus_request_duration_seconds` label set present, bucket counts are monotonically non-decreasing in `le` order, and `le="+Inf"` ≥ `_count` (exact equality holds at quiescence; under concurrent traffic count trails +Inf by at most the in-flight count — ETS has no multi-key transaction).
2b. Tokenless `GET :8090/stats` still → **401** (regression guard for the auth extraction).
3. One real non-stream chat completion → metrics bump synchronously (no flush wait; scrape immediately after the call): the scrape delta for `janus_requests_total{endpoint="chat",protocol="openai_chat",status_class="2xx"}` is ≥ 1 vs the pre-call scrape (label-set delta, not a global count — other gate traffic may interleave); `janus_request_duration_seconds_count{protocol="openai_chat",stream="0"}` ≥ +1; and the `endpoint="other"` series count does NOT increase across this call (a global no-`other` assertion would false-fail on stray probes).
4. A streaming chat call → same scrape shape with `stream="1"`; the streamed response carries `x-request-id`.
4b. A translated-path call (Anthropic `/v1/messages` against an OpenAI-protocol provider, or vice versa if seeded) → response carries `x-request-id` (verifies the translate chain reuses the same Req).
4c. The STREAMING call from step 4 → poll `/api/usage/events?limit=5` until its row appears; that row's `request_id` equals the streamed response's header (proves `track/3` sees the pdict id on the stream path — the exact process-boundary risk).
5. Bad-key call → 401 and `status_class="4xx"` +1 on the full label set (`endpoint="chat"`, `protocol="openai_chat"` — locks the classifier wiring); the 401 response carries `x-request-id`.
5b. A no-route call (unknown model, valid key) → 404 and `status_class="4xx"` increments (covers the `reply_err` path).
6. Send `x-request-id: e2e-fixed-id-1` on a call → response header echoes it byte-identical; poll the dashboard `/api/usage/events?limit=1` (≤3s, usage writer flush is 1s — the ONLY async step here) until the latest row's `request_id` equals it.
7. Call without the header → response `x-request-id` matches `^req_[0-9a-f]{16}$`.
8. Call with `x-request-id: "bad id with spaces"` → generated id instead (regex, NOT the inbound value).
9. `GET :8090/stats/logs?limit=50` (token-auth) → parse the JSON events; the newest `janus_request` event for the call has a structured `request_id` field equal to `e2e-fixed-id-1` (not a substring match).
10. If `promtool` is available (`which promtool`), pipe the captured `/metrics` sample through `promtool check metrics` → parse errors FAIL the gate; lint advisories (e.g. counter-naming nits) are recorded in the artifact log without failing.

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

- [ ] **Step 2: Grafana dashboard JSON** (uid `janus-overview`, title "Janus Gateway") — panels: request rate `sum by (endpoint, status_class) (rate(janus_requests_total[5m]))` (counters are node-local — sum across instances), error ratio, `histogram_quantile(0.95, sum by (le, protocol, stream) (rate(janus_request_duration_seconds_bucket[5m])))`, upstream error rate by provider, catalog generation per node (drift = `max != min` across instances), usage writer buffered rows / dropped rate, `rate(janus_lb_stats_total[5m])` by stat, uptime. Dashboard description notes counters reset per node restart (rate handles it).

- [ ] **Step 3: README observability section** — endpoint + auth (same stats token; admin plane must never be exposed through Caddy without it; the loopback fallback reads the socket peer and never trusts `X-Forwarded-For`; external Prometheus reaches nodes over the internal network or a Caddy host that requires the bearer token), example PromQL, the label-cardinality rule (closed enums + provider names only; never request/key/model labels), counter reset semantics on restart (`rate()` handles it), stream-duration semantics (end-to-end incl. client drain), inbound request ids are **untrusted client data** (never assume uniqueness), echo scope (the four agent endpoints; router 404s excluded), deleted-provider series orphan until restart, float rendering may use scientific notation (`1.0e7` is legal), `janus_lb_stats_total` counters are summable/rateable across nodes (only per-node gauges like `lb_routes_cooling` are node-scoped). Ops notes: rotating `JANUS_STATS_TOKEN` = restart the node + update the scrape job's token file (rolling, one node at a time); the Grafana dashboard JSON is imported by hand or provisioned from `docker/grafana-dashboard.json` per the operator's Grafana setup.

- [ ] **Step 4: Commit**

---

### Task 10: Final gate + artifacts + report

- [ ] Full `e2e_local.sh` green with artifacts saved durably (`/tmp/janus-e2e-YYYYMMDD/`).
- [ ] Read-only prod smoke (`run_test_flows.py --smoke`) after the next deploy.
- [ ] Commit message(s) reference artifact paths per the testing rules.

---

**Revision history:**
- rev 1: initial plan.
- rev 2: round-1 audit (7/7 GO WITH FIXES) folded inline — naming contract, numeric buckets, integer-µs sums, HELP/TYPE once per family, idempotent init, classify module, lowercase hex, per-node scrape jobs, dashboard read-path task.
- rev 3 (this document): round-2 audit (6 replies; deepseek lost to provider failure) folded inline — renderer drives families from a registry (the dropped counter renders; unknown families render without HELP), histogram comma-sequence bug fixed (single iolist), buckets zero-filled to the canonical ladder, build_info `untyped` (info is OpenMetrics-only), `ets:whereis` per bump (no stale-tid trap), whole-body try/catch on inc/observe + `max(0.0, _)`, `to_bin` total, NUL stripped in label escape, one `janus_lb:stats/0` call through the renderer, 405 on non-GET, `safe/2` logs gauge failures, pre-coding verification step, auth-reject log field timing noted, deploy order (gateway → dashboard) documented, gate asserts gauges are non-zero + `dropped_total` present + content-type by substring, re:run test typo fixed.
- rev 4 (this document): round-3 audit (6 replies + stepfun retry; deepseek excluded after 5 consecutive provider failures) folded inline — registry eunit moved before the module (tests-first rule), `janus_metrics:to_bin/1` made total (list/float), gauge families sort by labels and default TYPE gauge, zero-fill unions ETS-present bounds with the ladder, observe bumps count/+Inf before lower buckets, handler render wrapped in try/catch → 500+log, `lb_stat` typed counter (cumulative), early rejects (`no_route`, invalid JSON, translate errors) counted via `reply_err/6` with a `janus_req_counted` double-count guard, auth-reject log gains `request_id` (Task 6 files updated), gate: label-set deltas + no-`endpoint="other"` assertion + translate-path echo + proxy-404 + structured log-key assertion + optional promtool check, migration notes on index-lock/deploy-order, `docs/SCHEMA_ETS_CONTRACT.md` update step, stale "cached tid"/"safe/2"/"families sorted by name" wording purged.
- rev 5: round-4 audit (7/7 GO WITH FIXES; deepseek-v4-pro substituted for the flaky flash id) folded inline — observe bump order (buckets → +Inf → sum → count), `janus_req_counted` erased at handler init, `lb_stat` → `janus_lb_stats_total{stat=...}` counter (promlint counter-suffix), `bool01` SMALLINT, bad-bound drop+warn, family sort by name binary, init failure logs, `models_serving` extracted to `janus_http_stats`, mixed-snapshot byte-exact eunit, gate: token-POST 405, agent-plane 404, +Inf==count + monotonicity, scoped no-`other`, promtool parse-vs-lint policy, README scoping.
- rev 6 (this document): round-5 audit (7/7 GO WITH FIXES after retries) folded inline — `+Inf` whitelisted before the bad-bound partition (it never parses as a float; the partition was dropping it from every histogram), renderer purity restored (bad bounds drop silently — defense-in-depth, byte-exact gate asserts catch real breakage), observe order settled to +Inf → descending ladder → sum → count last (monotone buckets + count ≤ +Inf at every interleaving; exact equality asserted only at quiescence), handler `to_bin` delegates to the registry's total one (exported), LB skip-warning batched one-per-scrape, `crypto` added to `janus_http.app.src` (the admin auth's `hash_equals` worked only via cowboy's transitive dep), `generate/0` guarded with a unique-integer fallback, Task 4 commit list includes `janus_http_stats.erl`, gate gains tokenless-`/stats` 401 regression + 401 full-label-set + streamed-row `request_id` assertions, SPA column browser-verified per testing rule 4, token-rotation + Grafana-provisioning ops notes, concurrent-observe final-consistency eunit.

---

## Self-review notes

- Spec coverage: metrics endpoint + auth (T2–T5), request IDs end-to-end (T1, T6), dashboard read path (T7), gate (T8), operator surface (T9), artifacts (T10).
- Cardinality discipline: labels are closed enums + operator provider names only; the three bump sites contain no dynamic values (provider names are operator-managed; deleted providers orphan their series until restart — documented in README).
- Counters reset on VM restart (same as `janus_http_stats`); Prometheus `rate()` handles resets; documented.
- Histogram sums are integer µs in ETS (update_counter is integer-only), rendered as seconds at scrape with full precision.
- Hot path per request: 3 counter bumps + ~13 bucket bumps + sum/count, each one `ets:update_counter` on an `ets:whereis` lookup — ns-scale, try/catch'd; no formatting on the hot path (bucket binaries precomputed).
- The renderer is pure/deterministic/total: families sorted, one HELP+TYPE per family, buckets numerically ascending with `+Inf` last, `float_to_binary(F, [short])` values, escaped labels.
- Request-id echo is verified by construction (same Req chain) and asserted by the gate on 2xx, 401, and streamed responses.
- `null` atom params for nullable columns follow the existing `janus_usage` precedent on both drivers.
- Type consistency: `render/2` gauge input `{Name, Value, LabelsMap}` matches the handler; `usage_events.request_id` nullable TEXT end-to-end; gate regex matches `generate/0`'s lowercase hex.
- Out of scope (documented follow-ups): tracing (`traceparent`), per-key metrics (cardinality), alerting rules, log shipping.
