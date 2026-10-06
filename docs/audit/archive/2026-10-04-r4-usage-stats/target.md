# Usage Statistics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record token usage + latency for every proxied agent request (streaming included), persist it in `usage_events`, and present per-key / per-model / per-provider statistics on a new Usage page in the dashboard.

**Architecture:** The data-plane proxy (`janus_http_proxy`) already carries every request's identity (agent key, model, route, provider key) and every response's usage payload. We hook its terminal paths, parse usage with a pure parser module, buffer events in a `janus_usage` gen_server (janus_core) that batch-inserts into a new `usage_events` table, and expose rollups through `/api/usage/*` to a React page. Streaming coverage: inject `stream_options.include_usage` into upstream OpenAI streams and parse usage from a bounded head+tail capture of the SSE stream.

**Tech Stack:** Erlang/OTP (gen_server, cowboy, thoas, esqlite/epgsql), SQLite + Postgres migrations, React + TanStack Router + Tailwind v4 + shadcn/ui + recharts.

**Agreed scope (from brainstorm):** full streaming coverage · agent keys + provider-key column · token counts only (no cost) · aggregates + 30-day raw retention + recent-requests drill-down · latency avg/p95 · both DB backends.

**Key file facts an implementer must know:**
- DB facade: `janus_db_conn:query(Sql, Params)`; `janus_db_conn:backend()` returns `postgres | sqlite`. `?` placeholders must be rewritten to `$N` for postgres (pattern lives in `janus_dashboard_store:rewrite_pg/1`, `apps/janus_dashboard/src/janus_dashboard_store.erl`).
- Migrations: `apps/janus_core/priv/migrations/NNN_name.{postgres|sqlite}.sql`, run by `janus_migrate:run/0`. Existing: `001`, `002` (postgres-only), `003` — next is `004`.
- Agent meta (from `janus_catalog:lookup_api_key/1`): `#{id, prefix, key_hash, enabled, model_ids}`.
- Route map (from `janus_lb:pick_route/2`): `#{model_id, provider_id, provider_key := #{id := KeyId}, ...}`.
- Auth, so unauthorized requests never reach the proxy and are intentionally not counted.
- JSON lib is `thoas` (in janus_core's `.app.src` applications).
- The proxy runs inside the cowboy request process, so the process dictionary is a safe per-request scratch pad.
- Live verification loop (established in this worktree): compile in container `janus-local` with `docker exec janus-local sh -c 'cd /app/.worktrees/dashboard-polish && REBAR_BASE_DIR=/app/_build ./rebar3 as dev compile'`, then hot-load with `docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'code:load_file(M).' "` (cookie file `/root/.erlang.cookie` = `janus` already written).

---

## Audit fixes (v1 contracts)

Multi-model audit (7/7 GO WITH FIXES — see `docs/audit/SYNTHESIS.md`). The items below **replace** the referenced task steps. Everything not mentioned stays as written.

**A1. Migration (replaces Task 1 SQL).** Add `stream`, make token columns nullable (NULL = upstream did not report usage, distinguishable from a real 0), and fix the latency comment:

```sql
-- sqlite variant
CREATE TABLE IF NOT EXISTS usage_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,               -- unix seconds
    agent_key_id INTEGER REFERENCES api_keys (id) ON DELETE SET NULL,
    model_id INTEGER REFERENCES models (id) ON DELETE SET NULL,
    provider_id INTEGER REFERENCES providers (id) ON DELETE SET NULL,
    provider_key_id INTEGER REFERENCES provider_keys (id) ON DELETE SET NULL,
    protocol TEXT NOT NULL,            -- openai_chat | openai_responses | anthropic_messages
    stream INTEGER NOT NULL DEFAULT 0 CHECK (stream IN (0, 1)),
    status INTEGER NOT NULL,           -- upstream HTTP status; 502 on mid-stream failure
    prompt_tokens INTEGER,             -- NULL when the upstream did not report usage
    completion_tokens INTEGER,
    latency_ms INTEGER                 -- end-to-end proxy span (full drain for streams)
);
CREATE INDEX IF NOT EXISTS usage_events_ts_idx ON usage_events (ts);
CREATE INDEX IF NOT EXISTS usage_events_key_ts_idx ON usage_events (agent_key_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_model_ts_idx ON usage_events (model_id, ts);
```

Postgres variant: same columns with `BIGSERIAL id`, `ts BIGINT`, `SMALLINT stream NOT NULL DEFAULT 0`, `prompt_tokens BIGINT`/`completion_tokens BIGINT` nullable, same indexes. FK note: `provider_keys` exists in the 001 SQLite lineage (002 being postgres-only is fine); verify `janus_db_conn` sets `PRAGMA foreign_keys = ON` per connection during Task 1 Step 3 — if it does not, the SET NULL clauses are inert on SQLite and we document that instead of relying on them.

**A2. Parser nesting bug (replaces `nested/1` in Task 2 Step 3 + adds a test).** Anthropic `message_start` nests usage under `<<"message">>`, not `<<"response">>`. Probe both, and add the regression test the audit derived:

```erlang
nested(Map) ->
    case maps:get(<<"response">>, Map, undefined) of
        R when is_map(R) -> norm(maps:get(<<"usage">>, R, #{}));
        _ ->
            case maps:get(<<"message">>, Map, undefined) of
                M when is_map(M) -> norm(maps:get(<<"usage">>, M, #{}));
                _ -> undefined
            end
    end.
```

```erlang
anthropic_message_start_nesting_test() ->
    Head = <<"data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":17,\"output_tokens\":1}}}\n\n">>,
    ?assertEqual(#{prompt => 17, completion => 1},
                 janus_usage_parse:from_sse(anthropic_messages, Head, <<>>)).
```

**A3. Writer failure-safety (replaces Task 3 Step 1 gen_server body).** Defaults on every field, drop-oldest cap with counter, multi-row single-statement flush (chunks of 50), error logging, `trap_exit`, integer `buf_size` (no `length/1` per cast), catch-all cast, total functions only:

```erlang
-record(state, {
    buf = [] :: [map()],
    buf_size = 0 :: non_neg_integer(),
    dropped = 0 :: non_neg_integer()
}).

-define(MAX_BUF, 10000).

init([]) ->
    process_flag(trap_exit, true),
    _ = erlang:send_after(?FLUSH_MS, self(), flush),
    _ = erlang:send_after(60_000, self(), sweep),
    {ok, #state{}}.

handle_cast({record, Ev}, #state{buf = Buf, buf_size = N} = State) ->
    case N + 1 > ?MAX_BUF of
        true ->
            logger:warning(#{what => janus_usage_drop, reason => buffer_full}),
            {noreply, State#state{dropped = State#state.dropped + 1}};
        false ->
            maybe_flush(State#state{buf = [Ev | Buf], buf_size = N + 1})
    end;
handle_cast(_Other, State) ->
    {noreply, State}.

maybe_flush(#state{buf_size = N} = State) when N >= ?FLUSH_COUNT ->
    {noreply, do_flush(State)};
maybe_flush(State) ->
    {noreply, State}.

handle_info(flush, State) ->
    _ = erlang:send_after(?FLUSH_MS, self(), flush),
    {noreply, do_flush(State)};
handle_info(sweep, State) ->
    sweep(),
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = do_flush(State),
    ok.

%% Flush the whole buffer as multi-row INSERTs, 50 rows per statement
%% (single statement = atomic per chunk, no transaction API needed).
%% On failure the buffer is cleared (data is lost) but always logged
%% with the row count — never silently.
do_flush(#state{buf = []} = State) ->
    State;
do_flush(#state{buf = Buf, buf_size = N} = State) ->
    Cols =
        <<"(ts, agent_key_id, model_id, provider_id, provider_key_id, "
          " protocol, stream, status, prompt_tokens, completion_tokens, latency_ms)">>,
    Chunks = chunk(lists:reverse(Buf), 50),
    Failed =
        lists:foldl(
            fun(Rows, Acc) ->
                {Sql, Params} = build_insert(Cols, Rows),
                case q(Sql, Params) of
                    {ok, _} -> Acc;
                    {error, Reason} ->
                        logger:warning(#{
                            what => janus_usage_flush_error,
                            rows => length(Rows),
                            reason => Reason
                        }),
                        Acc + length(Rows)
                end
            end,
            0,
            Chunks
        ),
    State#state{buf = [], buf_size = 0, dropped = State#state.dropped + Failed}.

chunk([], _N) -> [];
chunk(L, N) when length(L) =< N -> [L];
chunk(L, N) -> {H, T} = lists:split(N, L), [H | chunk(T, N)].

build_insert(Cols, Rows) ->
    {ValuesSql, Params} =
        lists:foldl(
            fun(Ev, {SqlAcc, PAcc}) ->
                Ph = string:join(lists:duplicate(11, "?"), ", "),
                Params = [
                    maps:get(ts, Ev, erlang:system_time(second)),
                    nz(maps:get(agent_key_id, Ev, null)),
                    nz(maps:get(model_id, Ev, null)),
                    nz(maps:get(provider_id, Ev, null)),
                    nz(maps:get(provider_key_id, Ev, null)),
                    maps:get(protocol, Ev, <<"openai_chat">>),
                    maps:get(stream, Ev, 0),
                    maps:get(status, Ev, 0),
                    nz(maps:get(prompt, Ev, null)),
                    nz(maps:get(completion, Ev, null)),
                    nz(maps:get(latency_ms, Ev, null))
                ],
                {SqlAcc ++ ["(" ++ Ph ++ ")"], PAcc ++ Params}
            end,
            {[], []},
            Rows
        ),
    Sql = iolist_to_binary(
        ["INSERT INTO usage_events ", Cols, " VALUES ", string:join(ValuesSql, ", ")]
    ),
    {Sql, Params}.

nz(undefined) -> null;
nz(V) -> V.
```

**A4. Batched sweep (replaces `sweep/0`).**

```erlang
sweep() ->
    Cutoff = erlang:system_time(second) - ?RETENTION_SEC,
    sweep_batch(Cutoff, 0).

sweep_batch(Cutoff, Acc) ->
    case q(
        <<"DELETE FROM usage_events WHERE id IN "
          "(SELECT id FROM usage_events WHERE ts < ? LIMIT 5000)">>,
        [Cutoff]
    ) of
        {ok, N} when is_integer(N), N > 0 -> sweep_batch(Cutoff, Acc + N);
        {ok, _} -> Acc;
        {error, Reason} ->
            logger:warning(#{what => janus_usage_sweep_error, reason => Reason}),
            Acc
    end.
```

(If the DB driver does not report affected rows as an integer, fall back to looping until a `SELECT COUNT(*) WHERE ts < ?` returns 0.)

**A5. Query fixes (replace the marked parts of Task 4).**
- `breakdown`: `ORDER BY 5 DESC` → `ORDER BY 3 DESC` (requests, not completion tokens).
- `p95`: nearest-rank on both backends, `null` when empty. Postgres: `SELECT percentile_disc(0.95) WITHIN GROUP (ORDER BY latency_ms) ...` (discrete = same semantics as SQLite nearest-rank; handle `numeric` possibly decoded as binary). SQLite: two queries — `SELECT COUNT(*) ... AND latency_ms IS NOT NULL` then `SELECT latency_ms ... ORDER BY latency_ms LIMIT 1 OFFSET ?` with `Offset = max(0, trunc(Count * 0.95) - 1)`. Return `null` when the count is 0.
- `num/1` must handle binaries: `num(B) when is_binary(B) -> try binary_to_integer(B) catch _:_ -> try round(binary_to_float(B)) catch _:_ -> 0 end end;`
- `bucket_expr`: UTC on both backends. Postgres: `to_char(date_trunc('hour', to_timestamp(ts) AT TIME ZONE 'UTC'), 'YYYY-MM-DD"T"HH24:00')` (same for `day` with `'YYYY-MM-DD"T"00:00'`). SQLite is already UTC via `unixepoch`.
- `recent/1`: inline the limit as a literal integer (epgsql rejects typed params in `LIMIT`): build the SQL with `integer_to_binary(Limit)` after validating `0 < Limit =< 200`. Add optional filters for drill-down: `recent(Limit, Filters)` where `Filters = #{key_id => Int | undefined, model_id => Int | undefined}` appends `AND ue.agent_key_id = ?` / `AND ue.model_id = ?`.
- Add the provider-key breakdown the scope promised:

```erlang
breakdown_dim(provider_key) ->
    {<<"ue.provider_key_id">>,
     <<"LEFT JOIN provider_keys pk ON pk.id = ue.provider_key_id "
       "LEFT JOIN providers pp ON pp.id = pk.provider_id">>,
     <<"pp.name || ' #' || COALESCE(CAST(pk.id AS TEXT), '?')">>}.
```

(`||` concatenation works in both SQLite and Postgres; SQLite needs `CAST(pk.id AS TEXT)`, Postgres accepts it too.) Export and handle `provider_key` in `breakdown/3` alongside `key | model | provider`.

**A6. Proxy hygiene (amend Task 5).**
- At `handle/5` entry, erase all capture keys before putting the fresh ctx (Cowboy may reuse the process across keep-alive requests): `erase(janus_usage_ctx), erase(janus_usage_head), erase(janus_usage_tail),` then the `put/2`.
- Drop the dead `usage_ctx_route/1` write (`track/3` receives `Route` as an argument) — remove the helper and its call.
- `track/3` guards non-map routes: add a clause `track(_Status, Route, _Usage) when not is_map(Route) -> ok;` before the main clause.
- Event gains `stream` (0/1): pass `WantStream` into the ctx at `dispatch/7` (`put(janus_usage_ctx, Ctx#{stream => Stream})` — or compute in `track` from a ctx key set in `dispatch`), and record `stream => bool_int(Stream)`.
- Latency comment: it is an end-to-end proxy span (full drain for streams).

**A7. Streaming capture (amend Task 6).**
- Head accumulates across chunks up to 4KB (not first-chunk-only):

```erlang
capture_usage_chunk(Chunk) ->
    Head0 = case get(janus_usage_head) of
        undefined -> <<>>;
        H -> H
    end,
    case byte_size(Head0) < ?USAGE_HEAD_BYTES of
        true ->
            Need = ?USAGE_HEAD_BYTES - byte_size(Head0),
            put(janus_usage_head, <<Head0/binary, (binary:part(Chunk, 0, min(byte_size(Chunk), Need)))/binary>>);
        false ->
            ok
    end,
    ...tail logic unchanged...
```

- Drain `{error, _}` clause records `track(502, Route, stream_usage(ClientProto))` (not the already-sent 200).
- Injection honors an explicit client `stream_options` and has a kill switch:

```erlang
maybe_inject_stream_usage(openai_chat, true, Body, Map) ->
    Inject = application:get_env(janus_core, usage_inject_include_usage, true),
    case {Inject, maps:get(<<"stream_options">>, Map, undefined)} of
        {true, undefined} ->
            Map2 = Map#{<<"stream_options">> => #{<<"include_usage">> => true}},
            {thoas:encode(Map2), Map2};
        _ ->
            %% Client set its own stream_options (respect it), or the
            %% operator disabled injection (strict upstreams may 400).
            {Body, Map}
    end;
maybe_inject_stream_usage(_, _, Body, Map) ->
    {Body, Map}.
```

- Comment at the injection site: on the native path `ClientProto == ProviderProto` by construction and translate paths force `stream = false`, so keying on `ClientProto` is exact — but the SSE bytes are always provider-dialect and the parser is deliberately dialect-agnostic.

**A8. API (amend Task 7).** Summary gains `by_provider_key => janus_usage:breakdown(provider_key, From, To)`. Events handler parses optional `key_id`/`model_id` integers from the query string and passes them as `Filters` to `recent/2`.

**A9. Page (amend Task 8 Step 2).** Four breakdown cards in `xl:grid-cols-2` (agent keys, models, providers, provider keys). Chart titles note UTC: "Tokens per hour (UTC)" / "per day (UTC)". p95 card label: "p95 end-to-end". Remove the authoring artifact line — the final chart set is: stacked tokens chart + requests chart.

**A10. Hot verification (amend Task 9).** `start_link` under `bin/janus eval` dies with the RPC process; start unlinked instead: `gen_server:start({local, janus_usage}, janus_usage, [], [])`. E2E additions: (1) one cross-protocol non-stream call if a mismatch route exists (parser dialect-agnosticism), (2) one streaming call verifying the injected usage chunk produces non-null tokens, (3) one deliberate flush-error check is optional — at minimum assert `janus_usage` survives a malformed event (`record(#{})` → still alive).

**Splits (decided):** keep `ON DELETE SET NULL` + "(deleted)" labels (no denormalized name snapshots in v1); flush stays in the writer process (multi-row single statement is fast enough); `request_id`/TTFT are follow-ups; no read-side caching in v1.

---

### Task 1: Migration — `usage_events` table

**Files:**
- Create: `apps/janus_core/priv/migrations/004_usage_events.sqlite.sql`
- Create: `apps/janus_core/priv/migrations/004_usage_events.postgres.sql`

- [ ] **Step 1: SQLite migration**

```sql
-- Data-plane usage events: one row per proxied agent request.
-- Token counts are as reported by the upstream provider.
CREATE TABLE IF NOT EXISTS usage_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,               -- unix seconds
    agent_key_id INTEGER REFERENCES api_keys (id) ON DELETE SET NULL,
    model_id INTEGER REFERENCES models (id) ON DELETE SET NULL,
    provider_id INTEGER REFERENCES providers (id) ON DELETE SET NULL,
    provider_key_id INTEGER REFERENCES provider_keys (id) ON DELETE SET NULL,
    protocol TEXT NOT NULL,            -- openai_chat | openai_responses | anthropic_messages
    status INTEGER NOT NULL,           -- upstream HTTP status
    prompt_tokens INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    latency_ms INTEGER                 -- upstream call duration; NULL when unknown
);

CREATE INDEX IF NOT EXISTS usage_events_ts_idx ON usage_events (ts);
CREATE INDEX IF NOT EXISTS usage_events_key_ts_idx ON usage_events (agent_key_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_model_ts_idx ON usage_events (model_id, ts);
```

- [ ] **Step 2: Postgres migration**

```sql
-- Data-plane usage events: one row per proxied agent request.
CREATE TABLE IF NOT EXISTS usage_events (
    id BIGSERIAL PRIMARY KEY,
    ts BIGINT NOT NULL,                -- unix seconds
    agent_key_id BIGINT REFERENCES api_keys (id) ON DELETE SET NULL,
    model_id BIGINT REFERENCES models (id) ON DELETE SET NULL,
    provider_id BIGINT REFERENCES providers (id) ON DELETE SET NULL,
    provider_key_id BIGINT REFERENCES provider_keys (id) ON DELETE SET NULL,
    protocol TEXT NOT NULL,
    status INTEGER NOT NULL,
    prompt_tokens BIGINT NOT NULL DEFAULT 0,
    completion_tokens BIGINT NOT NULL DEFAULT 0,
    latency_ms INTEGER
);

CREATE INDEX IF NOT EXISTS usage_events_ts_idx ON usage_events (ts);
CREATE INDEX IF NOT EXISTS usage_events_key_ts_idx ON usage_events (agent_key_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_model_ts_idx ON usage_events (model_id, ts);
```

- [ ] **Step 3: Run migrations on the live dev node and verify**

```bash
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'janus_migrate:run().'"
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'janus_db_conn:query(\"SELECT name FROM sqlite_master WHERE name='usage_events'\", []).'"
```
Expected: migration reports applied; second eval returns `{ok,[{<<"usage_events">>}]}`.

- [ ] **Step 4: Commit**

```bash
git add apps/janus_core/priv/migrations/004_usage_events.*
git commit -m "Migration: usage_events table for data-plane token stats"
```

---

### Task 2: Pure usage parser (`janus_usage_parse`) — TDD

Usage shapes seen in the wild:
- OpenAI non-stream body: `{"usage": {"prompt_tokens": N, "completion_tokens": M}}`
- OpenAI Responses non-stream / SSE `response.completed`: `{"response": {"usage": {"input_tokens": N, "output_tokens": M}}}` (also flat top-level `usage` on some providers)
- Anthropic non-stream body: `{"usage": {"input_tokens": N, "output_tokens": M}}`
- OpenAI chat SSE final chunk: `data: {"choices": [], "usage": {"prompt_tokens": N, "completion_tokens": M}}`
- Anthropic SSE: `message_start` event carries `usage.input_tokens`; final `message_delta` carries cumulative `usage.output_tokens`

Strategy: decode every `data:` event in the head+tail capture, normalize each usage map to `{prompt, completion}`, and take the **max** of each (usage is cumulative in both dialects; OpenAI emits one terminal usage event).

**Files:**
- Create: `apps/janus_core/src/janus_usage_parse.erl`
- Test: `apps/janus_core/test/janus_usage_parse_tests.erl`

- [ ] **Step 1: Write the failing tests**

```erlang
-module(janus_usage_parse_tests).
-include_lib("eunit/include/eunit.hrl").

openai_body_test() ->
    B = <<"{\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":7,\"total_tokens\":18}}">>,
    ?assertEqual(#{prompt => 11, completion => 7},
                 janus_usage_parse:from_response_body(openai_chat, B)).

anthropic_body_test() ->
    B = <<"{\"usage\":{\"input_tokens\":5,\"output_tokens\":9}}">>,
    ?assertEqual(#{prompt => 5, completion => 9},
                 janus_usage_parse:from_response_body(anthropic_messages, B)).

responses_nested_body_test() ->
    B = <<"{\"response\":{\"usage\":{\"input_tokens\":3,\"output_tokens\":4}}}">>,
    ?assertEqual(#{prompt => 3, completion => 4},
                 janus_usage_parse:from_response_body(openai_responses, B)).

no_usage_body_test() ->
    ?assertEqual(undefined, janus_usage_parse:from_response_body(openai_chat, <<"{}">>)),
    ?assertEqual(undefined, janus_usage_parse:from_response_body(openai_chat, <<"not json">>)).

openai_sse_tail_test() ->
    Tail = <<"data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
             "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":21,\"completion_tokens\":13,\"total_tokens\":34}}\n\n"
             "data: [DONE]\n\n">>,
    ?assertEqual(#{prompt => 21, completion => 13},
                 janus_usage_parse:from_sse(openai_chat, <<>>, Tail)).

anthropic_sse_head_tail_test() ->
    Head = <<"event: message_start\n"
             "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":17,\"output_tokens\":1}}}\n\n">>,
    Tail = <<"event: message_delta\n"
             "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":42}}\n\n">>,
    ?assertEqual(#{prompt => 17, completion => 42},
                 janus_usage_parse:from_sse(anthropic_messages, Head, Tail)).

responses_sse_tail_test() ->
    Tail = <<"event: response.completed\n"
             "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":8,\"output_tokens\":6}}}\n\n">>,
    ?assertEqual(#{prompt => 8, completion => 6},
                 janus_usage_parse:from_sse(openai_responses, <<>>, Tail)).

empty_sse_test() ->
    ?assertEqual(undefined, janus_usage_parse:from_sse(openai_chat, <<>>, <<"data: [DONE]\n\n">>)).
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
docker exec janus-local sh -c 'cd /app/.worktrees/dashboard-polish && REBAR_BASE_DIR=/app/_build ./rebar3 as dev eunit --module=janus_usage_parse_tests'
```
Expected: FAIL — `janus_usage_parse` undefined.

- [ ] **Step 3: Implement the parser**

```erlang
%%%-------------------------------------------------------------------
%%% @doc Extract normalized token usage #{prompt, completion} from
%%% provider response bodies and from head+tail captures of SSE streams.
%%% Pure functions; all failures return `undefined` (never raise on the
%%% data-plane hot path).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_usage_parse).

-export([from_response_body/2, from_sse/3]).

-spec from_response_body(atom(), binary()) -> #{prompt := non_neg_integer(), completion := non_neg_integer()} | undefined.
from_response_body(_Proto, Body) when is_binary(Body) ->
    case thoas:decode(Body) of
        {ok, Map} when is_map(Map) -> usage_in_map(Map);
        _ -> undefined
    end;
from_response_body(_, _) ->
    undefined.

%% Head holds the first ~4KB (Anthropic message_start input tokens);
%% tail the last ~16KB (OpenAI terminal usage chunk, Anthropic
%% message_delta output tokens, Responses response.completed).
-spec from_sse(atom(), binary(), binary()) -> #{prompt := non_neg_integer(), completion := non_neg_integer()} | undefined.
from_sse(_Proto, Head, Tail) when is_binary(Head), is_binary(Tail) ->
    Blob = <<Head/binary, "\n", Tail/binary>>,
    Lines = binary:split(Blob, <<"\n">>, [global]),
    Usages = lists:filtermap(fun data_line_usage/1, Lines),
    case Usages of
        [] -> undefined;
        _ ->
            P = lists:max([maps:get(prompt, U, 0) || U <- Usages]),
            C = lists:max([maps:get(completion, U, 0) || U <- Usages]),
            case {P, C} of
                {0, 0} -> undefined;
                _ -> #{prompt => P, completion => C}
            end
    end;
from_sse(_, _, _) ->
    undefined.

%%% internal

data_line_usage(<<"data:", Rest/binary>>) ->
    Json = string:trim(Rest),
    case thoas:decode(Json) of
        {ok, Map} when is_map(Map) ->
            case usage_in_map(Map) of
                undefined -> false;
                U -> {true, U}
            end;
        _ ->
            false
    end;
data_line_usage(_) ->
    false.

usage_in_map(Map) ->
    case maps:get(<<"usage">>, Map, undefined) of
        U when is_map(U) -> norm(U);
        _ -> nested(Map)
    end.

%% openai_responses nests usage under "response" on completed events.
nested(Map) ->
    case maps:get(<<"response">>, Map, undefined) of
        R when is_map(R) -> norm(maps:get(<<"usage">>, R, #{}));
        _ -> undefined
    end.

norm(U) when is_map(U), map_size(U) > 0 ->
    P = first_int(U, [<<"prompt_tokens">>, <<"input_tokens">>]),
    C = first_int(U, [<<"completion_tokens">>, <<"output_tokens">>]),
    case {P, C} of
        {0, 0} -> undefined;
        _ -> #{prompt => P, completion => C}
    end;
norm(_) ->
    undefined.

first_int(Map, [K | Ks]) ->
    case Map of
        #{K := V} when is_integer(V), V >= 0 -> V;
        _ -> first_int(Map, Ks)
    end;
first_int(_, []) ->
    0.
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
docker exec janus-local sh -c 'cd /app/.worktrees/dashboard-polish && REBAR_BASE_DIR=/app/_build ./rebar3 as dev eunit --module=janus_usage_parse_tests'
```
Expected: `All 8 tests passed.` (also run the full suite: `./rebar3 as dev eunit` — existing `janus_protocol_translate_tests` must stay green)

- [ ] **Step 5: Commit**

```bash
git add apps/janus_core/src/janus_usage_parse.erl apps/janus_core/test/janus_usage_parse_tests.erl
git commit -m "Add usage parser for provider bodies and SSE head/tail captures"
```

---

### Task 3: `janus_usage` — buffered writer + retention sweep

**Files:**
- Create: `apps/janus_core/src/janus_usage.erl`
- Modify: `apps/janus_core/src/janus_core_sup.erl` (add child after `janus_lb`)

- [ ] **Step 1: Write the gen_server (write path only; read queries are Task 4)**

```erlang
%%%-------------------------------------------------------------------
%%% @doc Data-plane usage events: buffered writes and rollup queries.
%%%
%%% The proxy casts `record/1` on the request hot path; events are
%%% flushed to `usage_events` every second or every 100 buffered rows,
%%% whichever comes first. Rows older than 30 days are swept daily.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_usage).

-behaviour(gen_server).

-export([start_link/0]).
-export([record/1]).
-export([totals/2, series/3, breakdown/3, recent/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(FLUSH_MS, 1000).
-define(FLUSH_COUNT, 100).
-define(RETENTION_SEC, 30 * 86400).
-define(SWEEP_MS, 24 * 3600 * 1000).

-record(state, {buf = [] :: [map()]}).

%%%===================================================================
%%% API — write path
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Event keys: ts, agent_key_id, model_id, provider_id, provider_key_id,
%% protocol, status, prompt, completion, latency_ms. Never raises.
-spec record(map()) -> ok.
record(Ev) when is_map(Ev) ->
    catch gen_server:cast(?SERVER, {record, Ev}),
    ok.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    _ = erlang:send_after(?FLUSH_MS, self(), flush),
    _ = erlang:send_after(60_000, self(), sweep),
    {ok, #state{}}.

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast({record, Ev}, #state{buf = Buf} = State) ->
    Buf2 = [Ev | Buf],
    case length(Buf2) >= ?FLUSH_COUNT of
        true ->
            flush(Buf2),
            {noreply, State#state{buf = []}};
        false ->
            {noreply, State#state{buf = Buf2}}
    end.

handle_info(flush, #state{buf = Buf} = State) ->
    flush(Buf),
    _ = erlang:send_after(?FLUSH_MS, self(), flush),
    {noreply, State#state{buf = []}};
handle_info(sweep, State) ->
    sweep(),
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{buf = Buf}) ->
    flush(Buf),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal — writes
%%%===================================================================

flush([]) ->
    ok;
flush(Buf) ->
    Sql =
        <<"INSERT INTO usage_events "
          "(ts, agent_key_id, model_id, provider_id, provider_key_id, "
          " protocol, status, prompt_tokens, completion_tokens, latency_ms) "
          "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)">>,
    lists:foreach(
        fun(Ev) ->
            _ = q(Sql, [
                maps:get(ts, Ev),
                null_undef(maps:get(agent_key_id, Ev, null)),
                null_undef(maps:get(model_id, Ev, null)),
                null_undef(maps:get(provider_id, Ev, null)),
                null_undef(maps:get(provider_key_id, Ev, null)),
                maps:get(protocol, Ev),
                maps:get(status, Ev),
                maps:get(prompt, Ev, 0),
                maps:get(completion, Ev, 0),
                null_undef(maps:get(latency_ms, Ev, null))
            ]),
            ok
        end,
        lists:reverse(Buf)
    ),
    ok.

null_undef(undefined) -> null;
null_undef(V) -> V.

sweep() ->
    Cutoff = erlang:system_time(second) - ?RETENTION_SEC,
    _ = q(<<"DELETE FROM usage_events WHERE ts < ?">>, [Cutoff]),
    ok.
```

Follow with the DB helper (same shape as `janus_dashboard_store`):

```erlang
q(Sql, Params) ->
    case janus_db_conn:backend() of
        postgres -> janus_db_conn:query(rewrite_pg(Sql), Params);
        _ -> janus_db_conn:query(Sql, Params)
    end.

rewrite_pg(Sql) ->
    rewrite_pg(Sql, 1).

rewrite_pg(<<"?", Rest/binary>>, N) ->
    <<"$", (integer_to_binary(N))/binary, (rewrite_pg(Rest, N + 1))/binary>>;
rewrite_pg(<<C, Rest/binary>>, N) ->
    <<C, (rewrite_pg(Rest, N))/binary>>;
rewrite_pg(<<>>, _N) ->
    <<>>.
```

- [ ] **Step 2: Supervise in `janus_core_sup`**

In `apps/janus_core/src/janus_core_sup.erl`, add a child spec right after the `janus_lb` child (mirroring its map shape):

```erlang
                #{
                    id => janus_usage,
                    start => {janus_usage, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [janus_usage]
                },
```

Also add `janus_usage` to the `registered` list in `apps/janus_core/src/janus_core.app.src`.

- [ ] **Step 3: Compile, hot-start on the live node, smoke-test the write path**

```bash
docker exec janus-local sh -c 'cd /app/.worktrees/dashboard-polish && REBAR_BASE_DIR=/app/_build ./rebar3 as dev compile'
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'code:load_file(janus_usage), janus_usage:start_link(), janus_usage:record(#{ts => erlang:system_time(second), agent_key_id => null, model_id => null, provider_id => null, provider_key_id => null, protocol => openai_chat, status => 200, prompt => 1, completion => 2, latency_ms => 42}), timer:sleep(1500), janus_db_conn:query(\"SELECT protocol, status, prompt_tokens, completion_tokens, latency_ms FROM usage_events ORDER BY id DESC LIMIT 1\", []).'"
```
Expected: `{module,janus_usage}`, `{ok,pid}`, then `{ok,[{<<"openai_chat">>,200,1,2,42}]}`. Delete the smoke row:
`janus_db_conn:query("DELETE FROM usage_events WHERE latency_ms = 42", []).`

- [ ] **Step 4: Commit**

```bash
git add apps/janus_core/src/janus_usage.erl apps/janus_core/src/janus_core_sup.erl apps/janus_core/src/janus_core.app.src
git commit -m "Add janus_usage buffered writer with 30-day retention sweep"
```

---

### Task 4: Rollup queries in `janus_usage`

All queries take `From`/`To` (unix seconds). Bucket labels are ISO strings for the SPA to render directly.

**Files:**
- Modify: `apps/janus_core/src/janus_usage.erl` (append to the `%%% API` area + internal section)

- [ ] **Step 1: Implement the queries**

```erlang
%%%===================================================================
%%% API — read path (called from the dashboard plane)
%%%===================================================================

-spec totals(integer(), integer()) -> map().
totals(From, To) ->
    {ok, Rows} = q(
        <<"SELECT COUNT(*), COALESCE(SUM(prompt_tokens), 0), "
          "COALESCE(SUM(completion_tokens), 0), "
          "COALESCE(SUM(CASE WHEN status >= 400 THEN 1 ELSE 0 END), 0), "
          "COALESCE(AVG(latency_ms), 0) "
          "FROM usage_events WHERE ts >= ? AND ts < ?">>,
        [From, To]
    ),
    {Req, Pin, Pout, Err, AvgLat} = one_row(Rows, {0, 0, 0, 0, 0}),
    #{
        requests => num(Req),
        prompt_tokens => num(Pin),
        completion_tokens => num(Pout),
        errors => num(Err),
        avg_latency_ms => round(num(AvgLat)),
        p95_latency_ms => p95(From, To)
    }.

-spec series(integer(), integer(), hour | day) -> [map()].
series(From, To, Bucket) ->
    Expr = bucket_expr(Bucket),
    Sql = <<
        "SELECT ", Expr/binary, " AS b, COUNT(*), ",
        "COALESCE(SUM(prompt_tokens), 0), COALESCE(SUM(completion_tokens), 0) ",
        "FROM usage_events WHERE ts >= ? AND ts < ? GROUP BY b ORDER BY b"
    >>,
    {ok, Rows} = q(Sql, [From, To]),
    [
        #{
            bucket => to_bin(B),
            requests => num(R),
            prompt_tokens => num(P),
            completion_tokens => num(C)
        }
     || {B, R, P, C} <- Rows
    ].

%% Dim = key | model | provider
-spec breakdown(key | model | provider, integer(), integer()) -> [map()].
breakdown(Dim, From, To) ->
    {Col, Join, NameExpr} = breakdown_dim(Dim),
    Sql = <<
        "SELECT ", Col/binary, ", ", NameExpr/binary, ", COUNT(*), ",
        "COALESCE(SUM(prompt_tokens), 0), COALESCE(SUM(completion_tokens), 0), ",
        "MAX(ts) ",
        "FROM usage_events ue ", Join/binary, " ",
        "WHERE ue.ts >= ? AND ue.ts < ? ",
        "GROUP BY ", Col/binary, ", ", NameExpr/binary, " ",
        "ORDER BY 5 DESC"
    >>,
    {ok, Rows} = q(Sql, [From, To]),
    [
        #{
            id => Id,
            name => to_bin(Name),
            requests => num(R),
            prompt_tokens => num(P),
            completion_tokens => num(C),
            last_ts => num(Last)
        }
     || {Id, Name, R, P, C, Last} <- Rows
    ].

-spec recent(pos_integer()) -> [map()].
recent(Limit) when is_integer(Limit), Limit > 0, Limit =< 200 ->
    {ok, Rows} = q(
        <<"SELECT ue.ts, ak.prefix, m.name, p.name, ue.protocol, ue.status, "
          "ue.prompt_tokens, ue.completion_tokens, ue.latency_ms "
          "FROM usage_events ue "
          "LEFT JOIN api_keys ak ON ak.id = ue.agent_key_id "
          "LEFT JOIN models m ON m.id = ue.model_id "
          "LEFT JOIN providers p ON p.id = ue.provider_id "
          "ORDER BY ue.ts DESC, ue.id DESC LIMIT ?">>,
        [Limit]
    ),
    [
        #{
            ts => num(Ts),
            key_prefix => to_bin(K),
            model => to_bin(M),
            provider => to_bin(P),
            protocol => to_bin(Proto),
            status => num(St),
            prompt_tokens => num(Pin),
            completion_tokens => num(Pout),
            latency_ms => num_or_null(Lat)
        }
     || {Ts, K, M, P, Proto, St, Pin, Pout, Lat} <- Rows
    ].
```

Internal helpers (append to the internal section):

```erlang
one_row([Row | _], _Default) -> Row;
one_row([], Default) -> Default.

num(N) when is_integer(N) -> N;
num(F) when is_float(F) -> round(F);
num(null) -> 0;
num(_) -> 0.

num_or_null(null) -> null;
num_or_null(N) -> num(N).

to_bin(null) -> null;
to_bin(undefined) -> null;
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).

bucket_expr(hour) ->
    case janus_db_conn:backend() of
        postgres -> <<"to_char(date_trunc('hour', to_timestamp(ts)), 'YYYY-MM-DD\"T\"HH24:00')">>;
        _ -> <<"strftime('%Y-%m-%dT%H:00', ts, 'unixepoch')">>
    end;
bucket_expr(day) ->
    case janus_db_conn:backend() of
        postgres -> <<"to_char(date_trunc('day', to_timestamp(ts)), 'YYYY-MM-DD\"T\"00:00')">>;
        _ -> <<"strftime('%Y-%m-%dT00:00', ts, 'unixepoch')">>
    end.

breakdown_dim(key) ->
    {<<"ue.agent_key_id">>, <<"LEFT JOIN api_keys ak ON ak.id = ue.agent_key_id">>, <<"ak.prefix">>};
breakdown_dim(model) ->
    {<<"ue.model_id">>, <<"LEFT JOIN models m ON m.id = ue.model_id">>, <<"m.name">>};
breakdown_dim(provider) ->
    {<<"ue.provider_id">>, <<"LEFT JOIN providers p ON p.id = ue.provider_id">>, <<"p.name">>}.

p95(From, To) ->
    case janus_db_conn:backend() of
        postgres ->
            {ok, Rows} = q(
                <<"SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms) "
                  "FROM usage_events WHERE ts >= ? AND ts < ? AND latency_ms IS NOT NULL">>,
                [From, To]
            ),
            case Rows of
                [{null}] -> 0;
                [{V}] -> round(num(V));
                _ -> 0
            end;
        _ ->
            {ok, Rows} = q(
                <<"SELECT latency_ms FROM usage_events "
                  "WHERE ts >= ? AND ts < ? AND latency_ms IS NOT NULL "
                  "ORDER BY latency_ms "
                  "LIMIT 1 OFFSET ("
                  "  SELECT CAST(COUNT(*) * 0.95 AS INTEGER) FROM usage_events "
                  "  WHERE ts >= ? AND ts < ? AND latency_ms IS NOT NULL)">>,
                [From, To, From, To]
            ),
            case Rows of
                [{V}] -> num(V);
                _ -> 0
            end
    end.
```

Note: `breakdown` param name `id` may be `null` for rows whose FK was SET NULL — the SPA renders those as "(deleted)".

- [ ] **Step 2: Compile and smoke-test with the row from Task 3 (or a fresh smoke row)**

```bash
docker exec janus-local sh -c 'cd /app/.worktrees/dashboard-polish && REBAR_BASE_DIR=/app/_build ./rebar3 as dev compile'
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'code:load_file(janus_usage), Now = erlang:system_time(second), janus_usage:record(#{ts => Now, agent_key_id => null, model_id => null, provider_id => null, provider_key_id => null, protocol => openai_chat, status => 200, prompt => 3, completion => 4, latency_ms => 50}), timer:sleep(1500), {janus_usage:totals(Now - 60, Now + 60), janus_usage:series(Now - 60, Now + 60, hour), janus_usage:breakdown(key, Now - 60, Now + 60), janus_usage:recent(5)}.'"
```
Expected: totals map with `requests => 1, prompt_tokens => 3, completion_tokens => 4`, one series bucket, one breakdown row with `name => null`, one recent row. Clean up: `janus_db_conn:query("DELETE FROM usage_events", []).`

- [ ] **Step 3: Commit**

```bash
git add apps/janus_core/src/janus_usage.erl
git commit -m "Add usage rollup queries (totals, series, breakdowns, recent)"
```

---

### Task 5: Proxy capture — non-streaming path

Approach: stash a per-request context in the process dictionary at proxy entry; enrich it once a route is picked; record at every terminal `handle_upstream` clause. Latency = monotonic span from proxy entry to terminal clause.

**Files:**
- Modify: `apps/janus_http/src/janus_http_proxy.erl`

- [ ] **Step 1: Stash context at proxy entry**

In `handle/5` (line ~15), first line of the function body:

```erlang
handle(ClientProto, Agent, Body, Req, State) ->
    put(janus_usage_ctx, #{
        started => erlang:monotonic_time(microsecond),
        agent => Agent,
        client_proto => ClientProto
    }),
    case thoas:decode(Body) of
```

- [ ] **Step 2: Enrich context when a route is picked**

In `do_proxy/7`, immediately after `{ok, Route} ->` (line ~93):

```erlang
                {ok, Route} ->
                    usage_ctx_route(Route),
                    case provider_protocol(Route) of
```

Add the helper near `key_target/1`:

```erlang
usage_ctx_route(Route) ->
    case get(janus_usage_ctx) of
        undefined -> ok;
        Ctx -> put(janus_usage_ctx, Ctx#{route => Route})
    end.
```

- [ ] **Step 3: Add the `track/3` helper (internal section, next to `key_target/1`)**

```erlang
key_id_of(#{provider_key := #{id := Kid}}) -> Kid;
key_id_of(_) -> null.

track(Status, Route, Usage) ->
    case get(janus_usage_ctx) of
        undefined ->
            ok;
        #{started := Started, agent := Agent, client_proto := Proto} ->
            LatencyMs =
                erlang:convert_time_unit(
                    erlang:monotonic_time(microsecond) - Started,
                    microsecond,
                    millisecond
                ),
            janus_usage:record(#{
                ts => erlang:system_time(second),
                agent_key_id => maps:get(id, Agent, null),
                model_id => maps:get(model_id, Route, null),
                provider_id => maps:get(provider_id, Route, null),
                provider_key_id => key_id_of(Route),
                protocol => Proto,
                status => Status,
                prompt => maps:get(prompt, Usage, 0),
                completion => maps:get(completion, Usage, 0),
                latency_ms => LatencyMs
            })
    end.
```

- [ ] **Step 4: Record on the non-stream success clause**

In `handle_upstream` final 2xx clause (line ~266):

```erlang
handle_upstream(ClientProto, ProviderProto, {ok, Status, Headers, RespBody}, Route, Translate, Req, State) ->
    _ = note_key_success(Route),
    _ = note_route_success(Route),
    _ = track(Status, Route, usage_or_undef(janus_usage_parse:from_response_body(ProviderProto, RespBody))),
    reply_upstream_body(ClientProto, ProviderProto, Status, Headers, RespBody, Translate, Req, State);
```

Add (next to `track/3`):

```erlang
usage_or_undef(undefined) -> #{};
usage_or_undef(U) -> U.
```

- [ ] **Step 5: Record on non-2xx upstream statuses and transport errors**

Add a `track` call to each remaining terminal `handle_upstream` clause (status known; usage empty):

- `401` clause: `_ = track(401, Route, #{}),` after `note_auth_failure`
- `403` clause: `_ = track(403, Route, #{}),`
- `429` clause: `_ = track(429, Route, #{}),`
- `>= 500` clause: `_ = track(Status, Route, #{}),`
- `>= 400` catch-all: `_ = track(Status, Route, #{}),`
- `{error, crashed}` clause: `_ = track(500, Route, #{}),`
- `{error, Reason}` clause: `_ = track(case Reason of provider_disabled -> 503; _ -> 502 end, Route, #{}),`

Pattern for each: insert the `_ = track(...)` line next to the existing `_ = note_*` / `_ = release_route_inflight` lines (a no-op when the ctx is absent, so dashboard-only or test flows are unaffected).

- [ ] **Step 6: Compile + full eunit**

```bash
docker exec janus-local sh -c 'cd /app/.worktrees/dashboard-polish && REBAR_BASE_DIR=/app/_build ./rebar3 as dev eunit'
```
Expected: all tests pass (proxy still compiles; existing translate tests green).

- [ ] **Step 7: Commit**

```bash
git add apps/janus_http/src/janus_http_proxy.erl
git commit -m "Track usage on non-streaming proxy paths"
```

---

### Task 6: Streaming coverage

Two parts: (a) inject `stream_options.include_usage` into upstream OpenAI chat streams so the terminal usage chunk always arrives; (b) capture a bounded head+tail of every SSE stream and parse usage at stream end.

**Files:**
- Modify: `apps/janus_http/src/janus_http_proxy.erl`

- [ ] **Step 1: Inject `include_usage` for native OpenAI chat streams**

In `dispatch/7`, replace the `{true, _} ->` clause body:

```erlang
        {true, _} ->
            {Body2, Map2} = maybe_inject_stream_usage(ClientProto, WantStream, Body, Map),
            call_native(ClientProto, ProviderProto, Route, Body2, Map2, WantStream, Req, State);
```

Add the helper (internal section):

```erlang
%% Ask OpenAI-compatible upstreams to always emit the terminal usage
%% chunk on streams (clients receive it too — it is spec-compliant).
maybe_inject_stream_usage(openai_chat, true, Body, Map) ->
    Map2 = maps:update_with(
        <<"stream_options">>,
        fun
            (SO) when is_map(SO) -> SO#{<<"include_usage">> => true};
            (_) -> #{<<"include_usage">> => true}
        end,
        #{<<"include_usage">> => true},
        Map
    ),
    {thoas:encode(Map2), Map2};
maybe_inject_stream_usage(_, _, Body, Map) ->
    {Body, Map}.
```

- [ ] **Step 2: Capture head+tail during the stream drain**

In the streaming success clause (line ~208), replace the `Drain(fun(Chunk) -> ... end)` callback:

```erlang
    case
        Drain(fun(Chunk) ->
            capture_usage_chunk(Chunk),
            ok = cowboy_req:stream_body(Chunk, nofin, Req2)
        end)
    of
        ok ->
            ok = cowboy_req:stream_body(<<>>, fin, Req2),
            _ = note_key_success(Route),
            _ = note_route_success(Route),
            _ = track(Status, Route, stream_usage(ClientProto)),
            {ok, Req2, State};
        {error, Reason} ->
            _ = track(Status, Route, stream_usage(ClientProto)),
            SafeReason = sanitize_upstream_error(Reason),
            ...existing error body unchanged...
```

Add the helpers (internal section):

```erlang
-define(USAGE_HEAD_BYTES, 4096).
-define(USAGE_TAIL_BYTES, 16384).

capture_usage_chunk(Chunk) ->
    case get(janus_usage_head) of
        undefined ->
            put(janus_usage_head, binary:part(Chunk, 0, min(byte_size(Chunk), ?USAGE_HEAD_BYTES)));
        _ ->
            ok
    end,
    Tail0 = case get(janus_usage_tail) of
        undefined -> <<>>;
        T0 -> T0
    end,
    Tail1 = <<Tail0/binary, Chunk/binary>>,
    Size = byte_size(Tail1),
    Tail2 = case Size > ?USAGE_TAIL_BYTES of
        true -> binary:part(Tail1, Size - ?USAGE_TAIL_BYTES, ?USAGE_TAIL_BYTES);
        false -> Tail1
    end,
    put(janus_usage_tail, Tail2).

stream_usage(ClientProto) ->
    Head = case get(janus_usage_head) of
        undefined -> <<>>;
        H -> H
    end,
    Tail = case get(janus_usage_tail) of
        undefined -> <<>>;
        T -> T
    end,
    erase(janus_usage_head),
    erase(janus_usage_tail),
    usage_or_undef(janus_usage_parse:from_sse(ClientProto, Head, Tail)).
```

- [ ] **Step 3: Compile + full eunit**

```bash
docker exec janus-local sh -c 'cd /app/.worktrees/dashboard-polish && REBAR_BASE_DIR=/app/_build ./rebar3 as dev eunit'
```
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add apps/janus_http/src/janus_http_proxy.erl
git commit -m "Capture token usage on streaming paths (incl. OpenAI include_usage injection)"
```

---

### Task 7: Dashboard API — `/api/usage/*`

**Files:**
- Modify: `apps/janus_dashboard/src/janus_dashboard_api.erl`

- [ ] **Step 1: Add routes** (next to the catalog & audit routes, ~line 122)

```erlang
%% usage statistics
route(<<"GET">>, [<<"usage">>, <<"summary">>], Req) ->
    with_session(Req, fun(_Csrf) -> handle_usage_summary(Req) end);
route(<<"GET">>, [<<"usage">>, <<"events">>], Req) ->
    with_session(Req, fun(_Csrf) -> handle_usage_events(Req) end);
```

- [ ] **Step 2: Add handlers** (next to `handle_models_get/1`)

```erlang
handle_usage_summary(Req) ->
    Qs = maps:from_list(cowboy_req:parse_qs(Req)),
    Range = maps:get(<<"range">>, Qs, <<"24h">>),
    {From, To, Bucket} = usage_window(Range),
    reply_json(
        200,
        #{
            range => Range,
            totals => janus_usage:totals(From, To),
            series => janus_usage:series(From, To, Bucket),
            by_key => janus_usage:breakdown(key, From, To),
            by_model => janus_usage:breakdown(model, From, To),
            by_provider => janus_usage:breakdown(provider, From, To)
        },
        Req
    ).

handle_usage_events(Req) ->
    Qs = maps:from_list(cowboy_req:parse_qs(Req)),
    Limit =
        case maps:get(<<"limit">>, Qs, <<"50">>) of
            Bin when is_binary(Bin) ->
                try
                    min(200, max(1, binary_to_integer(Bin)))
                catch
                    _:_ -> 50
                end;
            _ ->
                50
        end,
    reply_json(200, #{events => janus_usage:recent(Limit)}, Req).

usage_window(<<"7d">>) -> {now_sec() - 7 * 86400, now_sec(), day};
usage_window(<<"30d">>) -> {now_sec() - 30 * 86400, now_sec(), day};
usage_window(_) -> {now_sec() - 86400, now_sec(), hour}.

now_sec() ->
    erlang:system_time(second).
```

- [ ] **Step 3: Compile, hot-load, verify via curl**

```bash
docker exec janus-local sh -c 'cd /app/.worktrees/dashboard-polish && REBAR_BASE_DIR=/app/_build ./rebar3 as dev compile'
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'code:load_file(janus_dashboard_api).'"
# session cookie + GET both endpoints; expect totals map and []/rows
curl -s -c /tmp/cj.txt -X POST http://127.0.0.1:8090/api/session -H 'Content-Type: application/json' -d '{"password":"dev"}'
CK=$(grep janus_dashboard_session /tmp/cj.txt | awk '{print $NF}')
curl -s -b "janus_dashboard_session=$CK" 'http://127.0.0.1:8090/api/usage/summary?range=24h'
curl -s -b "janus_dashboard_session=$CK" 'http://127.0.0.1:8090/api/usage/events?limit=5'
```
Expected: JSON with `totals`/`series`/`by_*` keys (empty arrays are fine), `{"events":[...]}`.

- [ ] **Step 4: Commit**

```bash
git add apps/janus_dashboard/src/janus_dashboard_api.erl
git commit -m "Expose /api/usage/summary and /api/usage/events"
```

---

### Task 8: SPA — Usage page

**Files:**
- Create: `apps/janus_dashboard/spa/src/pages/usage.tsx`
- Modify: `apps/janus_dashboard/spa/src/main.tsx` (add route)
- Modify: `apps/janus_dashboard/spa/src/components.tsx` (add nav item)
- Modify: `apps/janus_dashboard/spa/src/pages/shared.tsx` (add shared types)

- [ ] **Step 1: Shared types** (append to `pages/shared.tsx`)

```tsx
export type UsageTotals = {
  requests: number
  prompt_tokens: number
  completion_tokens: number
  errors: number
  avg_latency_ms: number
  p95_latency_ms: number
}
export type UsagePoint = { bucket: string; requests: number; prompt_tokens: number; completion_tokens: number }
export type UsageRow = { id: number | null; name: string | null; requests: number; prompt_tokens: number; completion_tokens: number; last_ts: number }
export type UsageEvent = {
  ts: number
  key_prefix: string | null
  model: string | null
  provider: string | null
  protocol: string
  status: number
  prompt_tokens: number
  completion_tokens: number
  latency_ms: number | null
}
export type UsageSummary = {
  range: string
  totals: UsageTotals
  series: UsagePoint[]
  by_key: UsageRow[]
  by_model: UsageRow[]
  by_provider: UsageRow[]
}

export function fmtNum(n: number) {
  return n.toLocaleString("en-US")
}

export function fmtBucket(bucket: string, range: string) {
  // "2026-10-04T13:00" → "13:00" for 24h, "10-04" for longer ranges
  return range === "24h" ? bucket.slice(11, 16) : bucket.slice(5, 10)
}

export function fmtTs(ts: number) {
  const d = new Date(ts * 1000)
  const pad = (n: number) => String(n).padStart(2, "0")
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
}
```

- [ ] **Step 2: The page** — structure (full code in executing session; outline contract below):

- Range `Select` in `CardAction` (24h / 7d / 30d) driving `api("/usage/summary?range=" + range)`; separate `api("/usage/events?limit=50")` for the drill-down.
- Stat cards row: **Requests** (`fmtNum(totals.requests)`), **Tokens in** (`fmtNum(totals.prompt_tokens)`), **Tokens out** (`fmtNum(totals.completion_tokens)`), **Errors** (count + `%` of requests), **p95 latency** (`ms`), all in the existing 6-col stat-grid pattern from `dashboard.tsx` (icons: `Activity`, `ArrowDownToLine`, `ArrowUpFromLine`, `CircleAlert`, `Timer`).
- Chart card: stacked `BarChart` of `prompt_tokens` + `completion_tokens` per bucket (`stackId="t"`, colors `var(--color-chart-1)` / `var(--color-chart-2)`), `XAxis dataKey` = `fmtBucket`, `ChartTooltip`, plus a thin `Bar` for requests? No — requests get their own small `BarChart` in a second card beside it (2-col grid like dashboard tables).
- Three breakdown tables in a 3-col grid (`xl:grid-cols-3`, one card each): **Per agent key** (prefix or `(deleted)`), **Per model**, **Per provider** — columns: name, requests, tokens in+out (`fmtNum(pin + pout)`), share bar (a `div` width % of max requests, `bg-primary/15`).
- Recent requests card: table Time (`fmtTs`), Key, Model, Provider, Status (colored text: 2xx `text-success`, 4xx `text-warning`, 5xx `text-destructive`), In, Out, Latency.
- Loading skeletons, `ErrorFlash`, empty state "No usage recorded yet — stats appear after the first proxied request."
- Route: `const usageRoute = createRoute({ getParentRoute: () => authLayout, path: '/usage', component: Usage })`, lazy import like the other pages.
- Nav entry in `NAV` after Dashboard: `{ to: "/usage", icon: Activity, label: "Usage" }` (`Activity` from lucide-react).

- [ ] **Step 3: Typecheck + build**

```bash
cd apps/janus_dashboard/spa && npx tsc -b && npm run build
```
Expected: clean build.

- [ ] **Step 4: Visual check** (vite dev on :3100 against the live backend; screenshot the page in both themes)

- [ ] **Step 5: Commit**

```bash
git add apps/janus_dashboard/spa/src
git commit -m "Add Usage stats page (cards, series charts, key/model/provider breakdowns, recent)"
```

---

### Task 9: End-to-end verification with real traffic

**Files:** none (verification only)

- [ ] **Step 1: Hot-load every new/changed module into the live node**

```bash
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval '[code:load_file(M) || M <- [janus_usage_parse, janus_usage, janus_http_proxy, janus_dashboard_api]], whereis(janus_usage) =:= undefined andalso element(2, janus_usage:start_link()), ok.'"
```
(`janus_usage` is not supervised in the running node — start it manually for verification; on a real redeploy the supervisor starts it.)

- [ ] **Step 2: Mint a throwaway agent key and make one non-stream + one streaming call**

```bash
# create key (dashboard API, CSRF), capture the full key once
# POST /v1/chat/completions model=deepseek-chat, max_tokens=1  (non-stream)
# same with "stream": true                                       (stream)
```
Then check `GET /api/usage/events?limit=5`: two rows, second row (stream) should carry prompt/completion tokens thanks to the injected `include_usage`. Non-stream row has status 200 + latency.

Note: this spends a negligible amount of real upstream quota (1-token completions). Revoke the throwaway key afterwards via `DELETE /api/keys/:id`.

- [ ] **Step 3: Verify the page renders the data** (both themes), verify 24h/7d/30d ranges respond.

- [ ] **Step 4: Final `npm run build` + commit any stragglers; report**

---

## Self-review notes

- Spec coverage: capture (T5/T6), storage + retention (T1/T3), rollups (T4), API (T7), page (T8), per-key + per-model + per-provider + provider_key column (T4/T5), streaming (T6), latency avg/p95 (T4/T5), drill-down (T4 `recent` + T8), both DBs (T1/T4 dialect branches). 
- `janus_usage` write path tolerates the DB being down (insert result ignored; buffer is bounded by flush cadence — a permanently failing DB would grow the buffer; acceptable for v1, log line on flush error is a fine follow-up).
- Events with `agent_key_id = null` happen only for contexts where the agent id is missing — in practice auth always provides it.
- Type consistency: proxy event keys match `janus_usage:record/1` expectations; `janus_usage_parse` return shape matches `track/3` consumption.
