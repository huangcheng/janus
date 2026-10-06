# Usage Statistics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record token usage + latency for every proxied agent request (streaming included), persist it in `usage_events`, and present per-key / per-model / per-provider / per-provider-key statistics on a new Usage page in the dashboard.

**Architecture:** The data-plane proxy (`janus_http_proxy`) already carries every request's identity (agent key, model, route, provider key) and every response's usage payload. We hook its terminal paths, parse usage with a pure parser module, buffer events in a `janus_usage` gen_server (janus_core) that batch-inserts into a new `usage_events` table, and expose rollups through `/api/usage/*` to a React page. Streaming coverage: inject `stream_options.include_usage` into upstream OpenAI streams and parse usage from a bounded head+tail capture of the SSE stream.

**Tech Stack:** Erlang/OTP (gen_server, cowboy, thoas, esqlite/epgsql), SQLite + Postgres migrations, React + TanStack Router + Tailwind v4 + shadcn/ui + recharts.

**Agreed scope (from brainstorm):** full streaming coverage · agent keys + provider-key column · token counts only (no cost) · aggregates + ~30-day raw retention + recent-requests drill-down · latency avg/p95 · both DB backends.

**Revision history:**
- rev 1: initial plan.
- rev 2: 7-model audit (7/7 GO WITH FIXES, `docs/audit/archive/2026-10-04-r3-usage-stats/`). Fixes written as an A1–A10 addendum.
- rev 3 (this document): second audit round (6/7 GO WITH FIXES, 1 NO-GO on structure — addendum-vs-task divergence) folded **inline**. Tasks below are the single source of truth; no addendum applies.
- rev 4: third audit round (7/7 GO WITH FIXES) folded inline: working event filters with 400-on-invalid, total read path (no badmatch→500), real `?`-literal guard test + insert/chunk eunit, genuine-zero vs absent usage distinction, avg latency split by stream + success-only `unreported`, mailbox back-pressure guard with atomics counter, throttled drop logs, `erlang:ceil` p95 offset, regex usage fallback for oversized terminal SSE events, bounded chunk-list tail capture, 15s terminate-flush budget, `writer.alive` + `ts_from`/`ts_to` in the API, zero-filled chart buckets.
- rev 5 (this document): fourth audit round (6/7 GO WITH FIXES, 1 NO-GO on a duplicate test function) folded inline: duplicate `no_qmark_literals_test` removed, SSE genuine-zero collapse removed (symmetric with body parser + regression test), `trim_tail` made O(1) amortized with byte+chunk caps, drop counter created in `init/1` (no hot-path persistent_term put), mailbox guard applied to malformed casts too, `_ = stream_body` (disconnect-safe), avg null-on-empty, provider/provider_key ts indexes, disconnect note, title de-versioned, test counts corrected, proxy-helper eunit (trim/injection), duplicate-name preflight for the API module.

**Key file facts an implementer must know:**
- DB facade: `janus_db_conn:query(Sql, Params)` returns `{ok, Rows} | {error, Reason}` (rows are tuples; it does **not** return affected-row counts — see Task 4 sweep). `janus_db_conn:backend()` returns `postgres | sqlite`. `?` placeholders must be rewritten to `$N` for postgres.
- Migrations: `apps/janus_core/priv/migrations/NNN_name.{postgres|sqlite}.sql`, run by `janus_migrate:run/0`. Existing: `001`, `002` (postgres-only), `003` — next is `004`.
- Agent meta (from `janus_catalog:lookup_api_key/1`): `#{id, prefix, key_hash, enabled, model_ids}`.
- Route map (from `janus_lb:pick_route/2`): `#{model_id, provider_id, provider_key := #{id := KeyId}, ...}`.
- Auth happens before the proxy: unauthorized requests never reach it and are intentionally not counted. `no_route` / `model_not_found` rejects happen before a route exists and are also not counted in v1.
- JSON lib is `thoas` (in janus_core's `.app.src` applications).
- The proxy runs inside the cowboy request process; the process dictionary is a safe per-request scratch pad **provided keys are erased at request entry** (cowboy reuses the process across HTTP/1.1 keep-alive requests). Use the `janus_usage_*` prefixed keys only.
- On the native streaming path `ClientProto == ProviderProto` by construction (translate paths force `stream = false`), so keying injection on `ClientProto` is exact; SSE bytes are always provider-dialect and the parser is deliberately dialect-agnostic.
- Live verification loop (established in this worktree): compile in container `janus-local` with `docker exec janus-local sh -c 'cd /app/.worktrees/dashboard-polish && REBAR_BASE_DIR=/app/_build ./rebar3 as dev compile'`, then hot-load with `docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'code:load_file(M).' "` (cookie file `/root/.erlang.cookie` = `janus` already written).

---

### Task 1: Migration — `usage_events` table

Retention is **31 days** so the 30-day range selector never sweeps rows mid-window.

**Files:**
- Create: `apps/janus_core/priv/migrations/004_usage_events.sqlite.sql`
- Create: `apps/janus_core/priv/migrations/004_usage_events.postgres.sql`

- [ ] **Step 1: SQLite migration**

```sql
-- Data-plane usage events: one row per proxied agent request.
-- Token columns are NULL when the upstream did not report usage
-- (distinguishable from a real zero).
CREATE TABLE IF NOT EXISTS usage_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,               -- unix seconds
    agent_key_id INTEGER REFERENCES api_keys (id) ON DELETE SET NULL,
    model_id INTEGER REFERENCES models (id) ON DELETE SET NULL,
    provider_id INTEGER REFERENCES providers (id) ON DELETE SET NULL,
    provider_key_id INTEGER REFERENCES provider_keys (id) ON DELETE SET NULL,
    protocol TEXT NOT NULL,            -- openai_chat | openai_responses | anthropic_messages
    stream INTEGER NOT NULL DEFAULT 0 CHECK (stream IN (0, 1)),
    status INTEGER NOT NULL,           -- upstream HTTP status; 502 mid-stream/upstream failure,
                                       -- 503 provider_disabled, 500 gateway crash
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    latency_ms INTEGER                 -- end-to-end proxy span (full drain for streams)
);

CREATE INDEX IF NOT EXISTS usage_events_ts_idx ON usage_events (ts);
CREATE INDEX IF NOT EXISTS usage_events_key_ts_idx ON usage_events (agent_key_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_model_ts_idx ON usage_events (model_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_provider_ts_idx ON usage_events (provider_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_pkey_ts_idx ON usage_events (provider_key_id, ts);
```

- [ ] **Step 2: Postgres migration**

```sql
CREATE TABLE IF NOT EXISTS usage_events (
    id BIGSERIAL PRIMARY KEY,
    ts BIGINT NOT NULL,
    agent_key_id BIGINT REFERENCES api_keys (id) ON DELETE SET NULL,
    model_id BIGINT REFERENCES models (id) ON DELETE SET NULL,
    provider_id BIGINT REFERENCES providers (id) ON DELETE SET NULL,
    provider_key_id BIGINT REFERENCES provider_keys (id) ON DELETE SET NULL,
    protocol TEXT NOT NULL,
    stream SMALLINT NOT NULL DEFAULT 0,
    status INTEGER NOT NULL,
    prompt_tokens BIGINT,
    completion_tokens BIGINT,
    latency_ms INTEGER
);

CREATE INDEX IF NOT EXISTS usage_events_ts_idx ON usage_events (ts);
CREATE INDEX IF NOT EXISTS usage_events_key_ts_idx ON usage_events (agent_key_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_model_ts_idx ON usage_events (model_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_provider_ts_idx ON usage_events (provider_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_pkey_ts_idx ON usage_events (provider_key_id, ts);
```

- [ ] **Step 3: Run migrations on the live dev node and verify preconditions**

```bash
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'janus_migrate:run().'"
# table exists:
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'janus_db_conn:query(\"SELECT name FROM sqlite_master WHERE name = ''usage_events''\", []).'"
# SQLite FK enforcement state (SET NULL is inert without it — if off, do not rely on FK actions; document):
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'janus_db_conn:query(\"PRAGMA foreign_keys\", []).'"
# parent FK targets exist in the SQLite lineage (provider_keys lives in 001, so this must return rows):
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'janus_db_conn:query(\"SELECT name FROM sqlite_master WHERE name IN (''api_keys'', ''models'', ''providers'', ''provider_keys'') ORDER BY name\", []).'"
```
Expected: `{ok,[{<<"usage_events">>}]}` for the first check; note the PRAGMA result (if `0`, SET NULL is inert on SQLite — acceptable for v1, record it in the plan's self-review); 4 rows for the parent check. For Postgres (optional lane): confirm parent `id` columns are `BIGINT`-compatible before applying.

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
- Anthropic SSE: `message_start` event nests usage under **`message`** (carries `input_tokens`); final `message_delta` carries cumulative `output_tokens`. Anthropic also reports `cache_creation_input_tokens` / `cache_read_input_tokens` **outside** `input_tokens` — add them to the prompt count when present.
- OpenAI chat SSE final chunk: `data: {"choices": [], "usage": {"prompt_tokens": N, "completion_tokens": M}}`

Strategy: decode every `data:` event in the head+tail capture, normalize each usage map to `{prompt, completion}`, and take the **max** of each (usage is cumulative in both dialects; OpenAI emits one terminal usage event). Caveat, documented for operators: a provider emitting **per-chunk deltas** in `message_delta` would be under-reported (Anthropic proper is cumulative). All functions are pure and total — failures return `undefined`, never raise on the data-plane hot path. The head/tail split may cut a `data:` line; partial lines simply fail to decode and are skipped (the terminal usage event is ~200 bytes, so a 16KB window lands inside it only in pathological cases).

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

anthropic_cache_tokens_test() ->
    B = <<"{\"usage\":{\"input_tokens\":5,\"output_tokens\":9,"
           "\"cache_creation_input_tokens\":100,\"cache_read_input_tokens\":50}}">>,
    ?assertEqual(#{prompt => 155, completion => 9},
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

anthropic_message_start_nesting_test() ->
    Head = <<"data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":17,\"output_tokens\":1}}}\n\n">>,
    ?assertEqual(#{prompt => 17, completion => 1},
                 janus_usage_parse:from_sse(anthropic_messages, Head, <<>>)).

responses_sse_tail_test() ->
    Tail = <<"event: response.completed\n"
             "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":8,\"output_tokens\":6}}}\n\n">>,
    ?assertEqual(#{prompt => 8, completion => 6},
                 janus_usage_parse:from_sse(openai_responses, <<>>, Tail)).

empty_sse_test() ->
    ?assertEqual(undefined, janus_usage_parse:from_sse(openai_chat, <<>>, <<"data: [DONE]\n\n">>)).

genuine_zero_usage_test() ->
    B = <<"{\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":0}}">>,
    ?assertEqual(#{prompt => 0, completion => 0},
                 janus_usage_parse:from_response_body(openai_chat, B)).

genuine_zero_sse_test() ->
    Tail = <<"data: {\"choices\":[],\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":0}}\n\n"
             "data: [DONE]\n\n">>,
    ?assertEqual(#{prompt => 0, completion => 0},
                 janus_usage_parse:from_sse(openai_chat, <<>>, Tail)).

%% response.completed embeds the full response (>16KB); the tail keeps
%% only its end, so the data: line never decodes whole — the regex
%% fallback must still recover the trailing usage object.
responses_oversized_completed_test() ->
    Filler = binary:copy(<<"x">>, 20000),
    Tail = <<"...truncated...", Filler/binary,
             "\"usage\": {\"input_tokens\": 8, \"output_tokens\": 6, ",
             "\"output_tokens_details\": {\"reasoning_tokens\": 2}}}">>,
    ?assertEqual(#{prompt => 8, completion => 6},
                 janus_usage_parse:from_sse(openai_responses, <<>>, Tail)).
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
%%% Pure and total: all failures return `undefined`.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_usage_parse).

-export([from_response_body/2, from_sse/3]).

-spec from_response_body(atom(), binary()) ->
    #{prompt := non_neg_integer(), completion := non_neg_integer()} | undefined.
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
-spec from_sse(atom(), binary(), binary()) ->
    #{prompt := non_neg_integer(), completion := non_neg_integer()} | undefined.
from_sse(_Proto, Head, Tail) when is_binary(Head), is_binary(Tail) ->
    Blob = <<Head/binary, "\n", Tail/binary>>,
    Lines = binary:split(Blob, <<"\n">>, [global]),
    case lists:filtermap(fun data_line_usage/1, Lines) of
        [] -> usage_regex_fallback(Blob);
        Usages ->
            %% Any decoded usage object is a REAL report — even {0, 0}
            %% (symmetric with from_response_body/2).
            P = lists:max([maps:get(prompt, U, 0) || U <- Usages]),
            C = lists:max([maps:get(completion, U, 0) || U <- Usages]),
            #{prompt => P, completion => C}
    end;
from_sse(_, _, _) ->
    undefined.

%% Some terminal events (Responses response.completed embeds the whole
%% response and can exceed the tail window) never decode as one line —
%% but their trailing usage object survives. Extract the last
%% "usage":{...} fragment (one nesting level for *_details objects).
usage_regex_fallback(Blob) ->
    Pattern = <<"\"usage\"\\s*:\\s*(\\{(?:[^{}]|\\{[^{}]*\\})*\\})">>,
    case re:run(Blob, Pattern, [{capture, all_but_first, binary}, global]) of
        {match, Ms} ->
            case thoas:decode(lists:last(lists:flatten(Ms))) of
                {ok, U} when is_map(U) -> norm(U);
                _ -> undefined
            end;
        nomatch ->
            undefined
    end.

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

%% openai_responses nests usage under "response" (response.completed);
%% Anthropic message_start nests it under "message".
nested(Map) ->
    case maps:get(<<"response">>, Map, undefined) of
        R when is_map(R) -> norm(maps:get(<<"usage">>, R, #{}));
        _ ->
            case maps:get(<<"message">>, Map, undefined) of
                M when is_map(M) -> norm(maps:get(<<"usage">>, M, #{}));
                _ -> undefined
            end
    end.

norm(U) when is_map(U), map_size(U) > 0 ->
    Base = first_int(U, [<<"prompt_tokens">>, <<"input_tokens">>]),
    Cache =
        first_int(U, [<<"cache_creation_input_tokens">>]) +
            first_int(U, [<<"cache_read_input_tokens">>]),
    P = Base + Cache,
    C = first_int(U, [<<"completion_tokens">>, <<"output_tokens">>]),
    %% A usage object carrying any recognized key is a REAL report — even
    %% a genuine {0, 0} — and must not collapse to "unreported".
    case has_known_key(U) of
        true -> #{prompt => P, completion => C};
        false -> undefined
    end;
norm(_) ->
    undefined.

has_known_key(U) ->
    lists:any(
        fun(K) -> maps:is_key(K, U) end,
        [
            <<"prompt_tokens">>,
            <<"input_tokens">>,
            <<"completion_tokens">>,
            <<"output_tokens">>,
            <<"cache_creation_input_tokens">>,
            <<"cache_read_input_tokens">>
        ]
    ).

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
Expected: `All 12 tests passed.` (also run the full suite: `./rebar3 as dev eunit` — existing `janus_protocol_translate_tests` must stay green)

- [ ] **Step 5: Commit**

```bash
git add apps/janus_core/src/janus_usage_parse.erl apps/janus_core/test/janus_usage_parse_tests.erl
git commit -m "Add usage parser for provider bodies and SSE head/tail captures"
```

---

### Task 3: `janus_usage` — buffered writer + retention sweep

Failure-safety contract: every field has a default; a malformed event is dropped+counted, never crashes the server; inserts run as multi-row single statements (50 rows/chunk, atomic per chunk); on insert failure rows are lost **but always logged with count**; the buffer is capped (incoming events dropped past the cap, counted); `trap_exit` so `terminate/2` flushes; `q/2` is exception-safe.

**Files:**
- Create: `apps/janus_core/src/janus_usage.erl`
- Modify: `apps/janus_core/src/janus_core_sup.erl` (add child after `janus_lb`)
- Modify: `apps/janus_core/src/janus_core.app.src` (add `janus_usage` to `registered`)

- [ ] **Step 1: Write the gen_server (write path + sweep; read queries are Task 4)**

```erlang
%%%-------------------------------------------------------------------
%%% @doc Data-plane usage events: buffered writes and rollup queries.
%%%
%%% The proxy casts `record/1` on the request hot path; events are
%%% flushed to `usage_events` every second or every 100 buffered rows,
%%% whichever comes first. Rows older than 31 days are swept daily in
%%% 5000-row batches (31 > 30 so the 30-day range never loses rows
%%% mid-window). Dropped events (cap overflow, malformed, insert
%%% failure) are counted and logged — never silently lost.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_usage).

-behaviour(gen_server).

-export([start_link/0]).
-export([record/1, stats/0]).
-export([totals/2, series/3, breakdown/3, recent/2]).
-export([build_insert/2, chunk/2]). %% exported for eunit
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(FLUSH_MS, 1000).
-define(FLUSH_COUNT, 100).
-define(MAX_BUF, 10000).
-define(MAX_QUEUE, 8000).
-define(INSERT_CHUNK, 50).
-define(RETENTION_SEC, 31 * 86400).
-define(SWEEP_MS, 24 * 3600 * 1000).
-define(SWEEP_BATCH, 5000).
-define(PROTOS, [openai_chat, openai_responses, anthropic_messages]).

-record(state, {
    buf = [] :: [map()],
    buf_size = 0 :: non_neg_integer(),
    dropped = 0 :: non_neg_integer()
}).

%%%===================================================================
%%% API — write path
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Event keys (all optional; see build_insert for defaults):
%% ts, agent_key_id, model_id, provider_id, provider_key_id,
%% protocol, stream, status, prompt, completion, latency_ms.
%% Events lacking an integer status are dropped. Never raises.
%% When the writer's mailbox is saturated the event is dropped HERE
%% (counted via an atomics counter created in init/1 and shared with
%% stats/0) — the mailbox is the last unbounded resource, and this
%% keeps it bounded.
-spec record(map()) -> ok.
record(#{status := Status} = Ev) when is_integer(Status) ->
    guarded_cast({record, Ev});
record(Bad) ->
    guarded_cast({drop, Bad}).

guarded_cast(Msg) ->
    try
        case whereis(?SERVER) of
            undefined ->
                ok;
            Pid ->
                {message_queue_len, Q} = erlang:process_info(Pid, message_queue_len),
                case Q >= ?MAX_QUEUE of
                    true ->
                        atomics:add(drop_counter(), 1, 1),
                        logger:warning(#{what => janus_usage_drop, reason => mailbox_full});
                    false ->
                        gen_server:cast(?SERVER, Msg)
                end
        end,
        ok
    catch
        _:_ -> ok
    end.

%% The atomics ref is created once by init/1 (writer process) — this
%% accessor only READS persistent_term (no put from hot paths, no race).
drop_counter() ->
    persistent_term:get(janus_usage_drop_atomics).

dropped_external() ->
    try atomics:get(persistent_term:get(janus_usage_drop_atomics), 1)
    catch _:_ -> 0
    end.

%% {alive, buffered, dropped} — dropped is cumulative since boot
%% (gen_server drops + mailbox-saturated drops). alive comes from
%% whereis/1 (never a false negative during a long flush); the stats
%% call itself has a 1s timeout so a slow flush can't hang the reader.
-spec stats() -> map().
stats() ->
    Alive = whereis(?SERVER) =/= undefined,
    Base = #{alive => Alive, dropped => dropped_external()},
    try gen_server:call(?SERVER, stats, 1000) of
        M -> maps:merge(Base, M)
    catch
        _:_ -> Base#{buffered => 0}
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    %% Create the drop counter ONCE here (writer process); hot paths
    %% only read persistent_term, never put.
    persistent_term:put(janus_usage_drop_atomics, atomics:new(1, [{signed, false}])),
    _ = erlang:send_after(?FLUSH_MS, self(), flush),
    _ = erlang:send_after(60_000, self(), sweep),
    {ok, #state{}}.

handle_call(stats, _From, State) ->
    {reply,
        #{
            buffered => State#state.buf_size,
            dropped => State#state.dropped + dropped_external()
        },
        State};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

%% Cap overflow drops the INCOMING event (drop-newest, not drop-oldest):
%% the buffer drains in order and old rows are already on their way out.
%% The warning is throttled (first drop, then every 1000th) so a stalled
%% DB cannot flood the logs.
handle_cast({record, _Ev}, #state{buf_size = N} = State) when N >= ?MAX_BUF ->
    D = State#state.dropped + 1,
    case D rem 1000 of
        1 -> logger:warning(#{what => janus_usage_drop, reason => buffer_full, total => D});
        _ -> ok
    end,
    {noreply, State#state{dropped = D}};
handle_cast({record, Ev}, #state{buf = Buf, buf_size = N} = State) ->
    maybe_flush(State#state{buf = [Ev | Buf], buf_size = N + 1});
handle_cast({drop, Bad}, State) ->
    D = State#state.dropped + 1,
    case D rem 1000 of
        1 -> logger:warning(#{what => janus_usage_drop, reason => malformed_event, total => D});
        _ -> ok
    end,
    {noreply, State#state{dropped = D}};
handle_cast(_Other, State) ->
    {noreply, State}.

handle_info(flush, State) ->
    _ = erlang:send_after(?FLUSH_MS, self(), flush),
    {noreply, do_flush(State)};
handle_info(sweep, State) ->
    %% Sweep in a worker so the DELETE never blocks casts.
    _ = proc_lib:spawn(fun sweep/0),
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = do_flush(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

maybe_flush(#state{buf_size = N} = State) when N >= ?FLUSH_COUNT ->
    {noreply, do_flush(State)};
maybe_flush(State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal — writes
%%%===================================================================

do_flush(#state{buf = []} = State) ->
    State;
do_flush(#state{buf = Buf} = State) ->
    Cols =
        <<"(ts, agent_key_id, model_id, provider_id, provider_key_id, "
          " protocol, stream, status, prompt_tokens, completion_tokens, latency_ms)">>,
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
            chunk(lists:reverse(Buf), ?INSERT_CHUNK)
        ),
    State#state{buf = [], buf_size = 0, dropped = State#state.dropped + Failed}.

chunk(L, N) ->
    chunk(L, N, []).

chunk([], _N, Acc) ->
    lists:reverse(Acc);
chunk(L, N, Acc) ->
    {H, T} = safe_split(N, L),
    chunk(T, N, [H | Acc]).

safe_split(N, L) ->
    safe_split(N, L, []).

safe_split(0, Rest, Acc) ->
    {lists:reverse(Acc), Rest};
safe_split(_, [], Acc) ->
    {lists:reverse(Acc), []};
safe_split(N, [H | T], Acc) ->
    safe_split(N - 1, T, [H | Acc]).

build_insert(Cols, Rows) ->
    {ValuesSql, Params} =
        lists:foldl(
            fun(Ev, {SqlAcc, PAcc}) ->
                Ph = string:join(lists:duplicate(11, "?"), ", "),
                Params = [
                    maps:get(ts, Ev, erlang:system_time(second)),
                    int_or_null(maps:get(agent_key_id, Ev, null)),
                    int_or_null(maps:get(model_id, Ev, null)),
                    int_or_null(maps:get(provider_id, Ev, null)),
                    int_or_null(maps:get(provider_key_id, Ev, null)),
                    proto_bin(maps:get(protocol, Ev, openai_chat)),
                    bool_int(maps:get(stream, Ev, false)),
                    maps:get(status, Ev),
                    int_or_null(maps:get(prompt, Ev, null)),
                    int_or_null(maps:get(completion, Ev, null)),
                    int_or_null(maps:get(latency_ms, Ev, null))
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

int_or_null(N) when is_integer(N) -> N;
int_or_null(_) -> null.

proto_bin(P) when is_atom(P) ->
    case lists:member(P, ?PROTOS) of
        true -> atom_to_binary(P, utf8);
        false -> <<"openai_chat">>
    end;
proto_bin(P) when is_binary(P) ->
    case lists:member(P, [<<"openai_chat">>, <<"openai_responses">>, <<"anthropic_messages">>]) of
        true -> P;
        false -> <<"openai_chat">>
    end;
proto_bin(_) ->
    <<"openai_chat">>.

bool_int(true) -> 1;
bool_int(1) -> 1;
bool_int(_) -> 0.

sweep() ->
    Cutoff = erlang:system_time(second) - ?RETENTION_SEC,
    sweep_batch(Cutoff, 0).

%% janus_db_conn:query returns {ok, Rows}, not affected counts, so loop
%% on COUNT(*) — stop when nothing old remains. Log if the 100-batch
%% ceiling is hit (rows older than retention remain; visible, not silent).
sweep_batch(_Cutoff, 100) ->
    logger:warning(#{what => janus_usage_sweep_capped, batches => 100}),
    ok;
sweep_batch(Cutoff, Iter) ->
    case q(<<"SELECT COUNT(*) FROM usage_events WHERE ts < ?">>, [Cutoff]) of
        {ok, [{0}]} ->
            ok;
        {ok, [{_}]} ->
            _ = q(
                <<"DELETE FROM usage_events WHERE id IN "
                  "(SELECT id FROM usage_events WHERE ts < ? LIMIT 5000)">>,
                [Cutoff]
            ),
            sweep_batch(Cutoff, Iter + 1);
        {error, Reason} ->
            logger:warning(#{what => janus_usage_sweep_error, reason => Reason}),
            ok
    end.
```

Then the DB helpers (same shape as `janus_dashboard_store`, exception-safe):

```erlang
q(Sql, Params) ->
    try
        case janus_db_conn:backend() of
            postgres -> janus_db_conn:query(rewrite_pg(Sql), Params);
            _ -> janus_db_conn:query(Sql, Params)
        end
    catch
        Class:Reason -> {error, {Class, Reason}}
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

Note on `rewrite_pg`: it rewrites every `?` including inside string literals — **no usage SQL may contain a `?` literal** (enforced by the Task 4 eunit).

- [ ] **Step 2: Supervise in `janus_core_sup`**

Add a child spec right after the `janus_lb` child (mirroring its map shape). The 15000ms shutdown budget gives `terminate/2` room to flush a full buffer:

```erlang
                #{
                    id => janus_usage,
                    start => {janus_usage, start_link, []},
                    restart => permanent,
                    shutdown => 15000,
                    type => worker,
                    modules => [janus_usage]
                },
```

- [ ] **Step 3: Compile, hot-start on the live node, smoke-test the write path**

```bash
docker exec janus-local sh -c 'cd /app/.worktrees/dashboard-polish && REBAR_BASE_DIR=/app/_build ./rebar3 as dev compile'
# start UNLINKED (an eval's RPC process dies after the call; start_link would kill the server):
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'code:load_file(janus_usage), gen_server:start({local, janus_usage}, janus_usage, [], []), janus_usage:record(#{ts => erlang:system_time(second), agent_key_id => null, model_id => null, provider_id => null, provider_key_id => null, protocol => openai_chat, stream => false, status => 200, prompt => 1, completion => 2, latency_ms => 42}), timer:sleep(1500), janus_db_conn:query(\"SELECT protocol, status, prompt_tokens, completion_tokens, latency_ms FROM usage_events ORDER BY id DESC LIMIT 1\", []).'"
# malformed event must not kill the server:
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'janus_usage:record(#{}), timer:sleep(100), {whereis(janus_usage), janus_usage:stats()}.'"
```
Expected: `{ok,[{<<"openai_chat">>,200,1,2,42}]}`; then `{Pid,#{buffered := 0, dropped := 1}}` with `Pid =/= undefined`. Delete the smoke row: `janus_db_conn:query("DELETE FROM usage_events WHERE latency_ms = 42", []).`

- [ ] **Step 4: Commit**

```bash
git add apps/janus_core/src/janus_usage.erl apps/janus_core/src/janus_core_sup.erl apps/janus_core/src/janus_core.app.src
git commit -m "Add janus_usage buffered writer with failure-safe flush and 31-day batched sweep"
```

---

### Task 4: Rollup queries in `janus_usage` — TDD for SQL builders

All queries take `From`/`To` (unix seconds). Bucket labels are UTC ISO strings; the SPA renders them as UTC. p95 semantics: nearest-rank on both backends, `null` on empty windows, split by stream (non-stream = true call latency; stream = end-to-end duration).

**Files:**
- Modify: `apps/janus_core/src/janus_usage.erl` (implement the exported read functions)
- Test: `apps/janus_core/test/janus_usage_sql_tests.erl`

- [ ] **Step 1: Write the failing SQL-shape tests**

```erlang
-module(janus_usage_sql_tests).
-include_lib("eunit/include/eunit.hrl").

breakdown_orders_by_requests_test() ->
    ?assertMatch({_, _, _}, janus_usage:breakdown_dim(key)),
    {Col, _, _} = janus_usage:breakdown_dim(key),
    ?assertEqual(<<"ue.agent_key_id">>, Col).

%% Placeholders are bare `?`; a literal would appear as `'?` or `?'`.
%% Scan every SQL fragment the module emits (both breakdown joins and
%% name expressions) — rewrite_pg rewrites `?` inside literals blindly.
no_qmark_literals_test() ->
    Frags = lists:flatmap(
        fun(Dim) ->
            {_, Join, NameExpr} = janus_usage:breakdown_dim(Dim),
            [Join, NameExpr]
        end,
        [key, model, provider, provider_key]
    ),
    lists:foreach(
        fun(B) ->
            ?assertEqual(nomatch, binary:match(B, <<"'?">>)),
            ?assertEqual(nomatch, binary:match(B, <<"?'>">>))
        end,
        Frags
    ).

provider_key_name_has_no_qmark_test() ->
    {_, _, NameExpr} = janus_usage:breakdown_dim(provider_key),
    ?assertEqual(nomatch, binary:match(NameExpr, <<"?">>)).

build_insert_shape_test() ->
    {Sql, Params} = janus_usage:build_insert(
        <<"(a, b)">>,
        [#{status => 200, prompt => 1, stream => true}, #{status => 502}]
    ),
    %% 11 placeholders per row, one VALUES group per row.
    ?assertEqual(22, length(Params)),
    ?assertMatch(
        <<"INSERT INTO usage_events (a, b) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)">>,
        Sql
    ),
    %% row 2: status 502 present, prompt defaults to null (not 0).
    ?assertEqual(502, lists:nth(19, Params)),
    ?assertEqual(null, lists:nth(20, Params)).

chunk_test() ->
    ?assertEqual([[1, 2], [3]], janus_usage:chunk([1, 2, 3], 2)),
    ?assertEqual([], janus_usage:chunk([], 3)),
    ?assertEqual([[1]], janus_usage:chunk([1], 3)).
```

- [ ] **Step 2: Run tests, verify they fail** (module exports missing)

```bash
docker exec janus-local sh -c 'cd /app/.worktrees/dashboard-polish && REBAR_BASE_DIR=/app/_build ./rebar3 as dev eunit --module=janus_usage_sql_tests'
```

- [ ] **Step 3: Implement the queries** (append to `janus_usage.erl`, internal helpers at the bottom; export `breakdown_dim/1` for the tests)

```erlang
%%%===================================================================
%%% API — read path (called from the dashboard plane; runs in the
%%% caller's process, never in the writer's mailbox). Every function
%%% is total: a DB error logs and returns an empty aggregate instead
%%% of crashing the dashboard handler.
%%%===================================================================

-spec totals(integer(), integer()) -> map().
totals(From, To) ->
    Sql =
        <<"SELECT COUNT(*), COALESCE(SUM(prompt_tokens), 0), "
          "COALESCE(SUM(completion_tokens), 0), "
          "COALESCE(SUM(CASE WHEN status >= 400 THEN 1 ELSE 0 END), 0), "
          "COALESCE(AVG(CASE WHEN stream = 0 THEN latency_ms END), 0), "
          "COALESCE(AVG(CASE WHEN stream = 1 THEN latency_ms END), 0), "
          "COALESCE(SUM(CASE WHEN prompt_tokens IS NULL AND completion_tokens IS NULL "
          "AND status < 400 THEN 1 ELSE 0 END), 0) "
          "FROM usage_events WHERE ts >= ? AND ts < ?">>,
    case q(Sql, [From, To]) of
        {ok, Rows} ->
            {Req, Pin, Pout, Err, AvgNs, AvgS, Unrep} =
                one_row(Rows, {0, 0, 0, 0, 0, 0, 0}),
            #{
                requests => num(Req),
                prompt_tokens => num(Pin),
                completion_tokens => num(Pout),
                errors => num(Err),
                unreported => num(Unrep),
                avg_latency_ms => round(num(AvgNs)),
                avg_stream_ms => round(num(AvgS)),
                p95_latency_ms => p95(From, To, 0),
                p95_stream_ms => p95(From, To, 1)
            };
        {error, Reason} ->
            logger:warning(#{what => janus_usage_query_error, query => totals, reason => Reason}),
            #{
                requests => 0,
                prompt_tokens => 0,
                completion_tokens => 0,
                errors => 0,
                unreported => 0,
                avg_latency_ms => 0,
                avg_stream_ms => 0,
                p95_latency_ms => null,
                p95_stream_ms => null
            }
    end.

-spec series(integer(), integer(), hour | day) -> [map()].
series(From, To, Bucket) ->
    Expr = bucket_expr(Bucket),
    Sql = <<
        "SELECT ", Expr/binary, " AS b, COUNT(*), ",
        "COALESCE(SUM(prompt_tokens), 0), COALESCE(SUM(completion_tokens), 0) ",
        "FROM usage_events WHERE ts >= ? AND ts < ? GROUP BY b ORDER BY b"
    >>,
    case q(Sql, [From, To]) of
        {ok, Rows} ->
            [
                #{
                    bucket => to_bin(B),
                    requests => num(R),
                    prompt_tokens => num(P),
                    completion_tokens => num(C)
                }
             || {B, R, P, C} <- Rows
            ];
        {error, Reason} ->
            logger:warning(#{what => janus_usage_query_error, query => series, reason => Reason}),
            []
    end.

-spec breakdown(key | model | provider | provider_key, integer(), integer()) -> [map()].
breakdown(Dim, From, To) ->
    {Col, Join, NameExpr} = breakdown_dim(Dim),
    Sql = <<
        "SELECT ", Col/binary, ", ", NameExpr/binary, ", COUNT(*), ",
        "COALESCE(SUM(prompt_tokens), 0), COALESCE(SUM(completion_tokens), 0), ",
        "MAX(ts) ",
        "FROM usage_events ue ", Join/binary, " ",
        "WHERE ue.ts >= ? AND ue.ts < ? ",
        "GROUP BY ", Col/binary, ", ", NameExpr/binary, " ",
        "ORDER BY 3 DESC"
    >>,
    case q(Sql, [From, To]) of
        {ok, Rows} ->
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
            ];
        {error, Reason} ->
            logger:warning(#{what => janus_usage_query_error, query => {breakdown, Dim}, reason => Reason}),
            []
    end.

%% Filters: #{key_id => integer(), model_id => integer()} (both optional).
-spec recent(pos_integer(), map()) -> [map()].
recent(Limit, Filters) when is_integer(Limit), Limit > 0, Limit =< 200 ->
    {WhereExtra, Params0} = recent_filters(Filters),
    Sql = iolist_to_binary([
        <<"SELECT ue.ts, ak.prefix, m.name, p.name, ue.protocol, ue.stream, ue.status, "
          "ue.prompt_tokens, ue.completion_tokens, ue.latency_ms "
          "FROM usage_events ue "
          "LEFT JOIN api_keys ak ON ak.id = ue.agent_key_id "
          "LEFT JOIN models m ON m.id = ue.model_id "
          "LEFT JOIN providers p ON p.id = ue.provider_id "
          "WHERE 1=1 ">>,
        WhereExtra,
        <<" ORDER BY ue.ts DESC, ue.id DESC LIMIT ">>,
        integer_to_binary(Limit)
    ]),
    case q(Sql, Params0) of
        {ok, Rows} ->
            [
                #{
                    ts => num(Ts),
                    key_prefix => to_bin(K),
                    model => to_bin(M),
                    provider => to_bin(P),
                    protocol => to_bin(Proto),
                    stream => num(S),
                    status => num(St),
                    prompt_tokens => num_or_null(Pin),
                    completion_tokens => num_or_null(Pout),
                    latency_ms => num_or_null(Lat)
                }
             || {Ts, K, M, P, Proto, S, St, Pin, Pout, Lat} <- Rows
            ];
        {error, Reason} ->
            logger:warning(#{what => janus_usage_query_error, query => recent, reason => Reason}),
            []
    end.

recent_filters(Filters) ->
    lists:foldl(
        fun
            ({key_id, V}, {Sql, Params}) when is_integer(V) ->
                {<<Sql/binary, "AND ue.agent_key_id = ? ">>, Params ++ [V]};
            ({model_id, V}, {Sql, Params}) when is_integer(V) ->
                {<<Sql/binary, "AND ue.model_id = ? ">>, Params ++ [V]};
            (_, Acc) ->
                Acc
        end,
        {<<>>, []},
        maps:to_list(Filters)
    ).

-export([breakdown_dim/1]).
breakdown_dim(key) ->
    {<<"ue.agent_key_id">>, <<"LEFT JOIN api_keys ak ON ak.id = ue.agent_key_id">>, <<"ak.prefix">>};
breakdown_dim(model) ->
    {<<"ue.model_id">>, <<"LEFT JOIN models m ON m.id = ue.model_id">>, <<"m.name">>};
breakdown_dim(provider) ->
    {<<"ue.provider_id">>, <<"LEFT JOIN providers p ON p.id = ue.provider_id">>, <<"p.name">>};
breakdown_dim(provider_key) ->
    {<<"ue.provider_key_id">>,
     <<"LEFT JOIN provider_keys pk ON pk.id = ue.provider_key_id "
       "LEFT JOIN providers pp ON pp.id = pk.provider_id">>,
     <<"COALESCE(pp.name, 'unknown') || ' #' || CAST(ue.provider_key_id AS TEXT)">>}.

%% Nearest-rank p95 over rows with latency, split by stream flag.
%% Returns null on an empty window; total — never crashes on DB error.
p95(From, To, StreamFlag) ->
    case janus_db_conn:backend() of
        postgres ->
            case q(
                <<"SELECT percentile_disc(0.95) WITHIN GROUP (ORDER BY latency_ms) "
                  "FROM usage_events WHERE ts >= ? AND ts < ? AND latency_ms IS NOT NULL "
                  "AND stream = ?">>,
                [From, To, StreamFlag]
            ) of
                {ok, [{V}]} -> num_or_null(V);
                _ -> null
            end;
        _ ->
            case q(
                <<"SELECT COUNT(*) FROM usage_events "
                  "WHERE ts >= ? AND ts < ? AND latency_ms IS NOT NULL AND stream = ?">>,
                [From, To, StreamFlag]
            ) of
                {ok, [{0}]} ->
                    null;
                {ok, [{Count}]} when is_integer(Count), Count > 0 ->
                    %% erlang:ceil/1 returns an integer (safe as a bind param).
                    Offset = max(0, erlang:ceil(0.95 * Count) - 1),
                    case q(
                        <<"SELECT latency_ms FROM usage_events "
                          "WHERE ts >= ? AND ts < ? AND latency_ms IS NOT NULL AND stream = ? "
                          "ORDER BY latency_ms LIMIT 1 OFFSET ?">>,
                        [From, To, StreamFlag, Offset]
                    ) of
                        {ok, [{V}]} -> num_or_null(V);
                        _ -> null
                    end;
                _ ->
                    null
            end
    end.
```

Internal helpers (append):

```erlang
one_row([Row | _], _Default) -> Row;
one_row([], Default) -> Default.

num(N) when is_integer(N) -> N;
num(F) when is_float(F) -> round(F);
num(null) -> 0;
num(B) when is_binary(B) ->
    try binary_to_integer(B)
    catch _:_ -> (try round(binary_to_float(B)) catch _:_ -> 0 end)
    end;
num(_) -> 0.

num_or_null(null) -> null;
num_or_null(N) -> num(N).

to_bin(null) -> null;
to_bin(undefined) -> null;
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).

%% Bucket labels are UTC ISO strings on both backends.
bucket_expr(hour) ->
    case janus_db_conn:backend() of
        postgres ->
            <<"to_char(date_trunc('hour', to_timestamp(ts) AT TIME ZONE 'UTC'), 'YYYY-MM-DD\"T\"HH24:00')">>;
        _ ->
            <<"strftime('%Y-%m-%dT%H:00', ts, 'unixepoch')">>
    end;
bucket_expr(day) ->
    case janus_db_conn:backend() of
        postgres ->
            <<"to_char(date_trunc('day', to_timestamp(ts) AT TIME ZONE 'UTC'), 'YYYY-MM-DD\"T\"00:00')">>;
        _ ->
            <<"strftime('%Y-%m-%dT00:00', ts, 'unixepoch')">>
    end.
```

Note: `breakdown` rows whose FK was SET NULL arrive with `id = null`; the SPA renders those as `(deleted)`.

- [ ] **Step 4: Run all tests**

```bash
docker exec janus-local sh -c 'cd /app/.worktrees/dashboard-polish && REBAR_BASE_DIR=/app/_build ./rebar3 as dev eunit'
```
Expected: parser (13) + SQL-shape (5) + existing suites green.

- [ ] **Step 5: Smoke-test the queries on the live node**

```bash
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'code:load_file(janus_usage), Now = erlang:system_time(second), janus_usage:record(#{ts => Now, agent_key_id => null, model_id => null, provider_id => null, provider_key_id => null, protocol => openai_chat, stream => false, status => 200, prompt => 3, completion => 4, latency_ms => 50}), timer:sleep(1500), {janus_usage:totals(Now - 60, Now + 60), janus_usage:series(Now - 60, Now + 60, hour), janus_usage:breakdown(provider_key, Now - 60, Now + 60), janus_usage:recent(5, #{})}.'"
```
Expected: totals with `requests => 1, prompt_tokens => 3, completion_tokens => 4, unreported => 0, p95_latency_ms => 50, p95_stream_ms => null`; one series bucket. For the smoke row (all FK ids null) every breakdown returns one row with `id => null, name => null` — NULL concat is NULL in both dialects by design, and the SPA renders these as `(deleted)` ("no key captured" and "key deleted" share the label, same as the other three breakdowns).
Clean up: `janus_db_conn:query("DELETE FROM usage_events WHERE latency_ms = 50", []).`

- [ ] **Step 6: Commit**

```bash
git add apps/janus_core/src/janus_usage.erl apps/janus_core/test/janus_usage_sql_tests.erl
git commit -m "Add usage rollup queries (totals/p95 split by stream, series, 4 breakdowns, filtered recent)"
```

---

### Task 5: Proxy capture — non-streaming path

Approach: erase-then-stash a per-request context in the process dictionary at proxy entry; record at every terminal `handle_upstream` clause. Latency = monotonic span from proxy entry to terminal clause (end-to-end proxy span; for streams it is the full drain duration — the `stream` column marks these rows).

**Files:**
- Modify: `apps/janus_http/src/janus_http_proxy.erl`

- [ ] **Step 1: Erase + stash context at proxy entry**

In `handle/5` (line ~15), first lines of the function body:

```erlang
handle(ClientProto, Agent, Body, Req, State) ->
    erase(janus_usage_ctx),
    erase(janus_usage_head),
    erase(janus_usage_tail),
    put(janus_usage_ctx, #{
        started => erlang:monotonic_time(microsecond),
        agent => Agent,
        client_proto => ClientProto,
        stream => false
    }),
    case thoas:decode(Body) of
```

- [ ] **Step 2: Add the `track/3` helper + `bool_int/1` (internal section, next to `key_target/1`)**

```erlang
key_id_of(#{provider_key := #{id := Kid}}) -> Kid;
key_id_of(_) -> null.

bool_int(true) -> 1;
bool_int(_) -> 0.

%% Token counts default to null (= upstream did not report usage),
%% NOT 0 — a missing usage must stay distinguishable from a real zero.
track(_Status, Route, _Usage) when not is_map(Route) ->
    ok;
track(Status, Route, Usage) ->
    case get(janus_usage_ctx) of
        undefined ->
            ok;
        #{started := Started, agent := Agent, client_proto := Proto, stream := Stream} ->
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
                stream => bool_int(Stream),
                status => Status,
                prompt => maps:get(prompt, Usage, null),
                completion => maps:get(completion, Usage, null),
                latency_ms => LatencyMs
            })
    end.
```

- [ ] **Step 3: Mark stream context in `dispatch/7`**

In `dispatch/7`, right after `WantStream = janus_protocol_translate:wants_stream(Map),`:

```erlang
    case get(janus_usage_ctx) of
        undefined -> ok;
        Ctx0 -> put(janus_usage_ctx, Ctx0#{stream => WantStream})
    end,
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

Add a `track` call to each remaining terminal `handle_upstream` clause (usage empty → NULL token columns):

- `401` clause: `_ = track(401, Route, #{}),` after `note_auth_failure`
- `403` clause: `_ = track(403, Route, #{}),`
- `429` clause: `_ = track(429, Route, #{}),`
- `>= 500` clause: `_ = track(Status, Route, #{}),`
- `>= 400` catch-all: `_ = track(Status, Route, #{}),`
- `{error, crashed}` clause: `_ = track(500, Route, #{}),`
- `{error, Reason}` clause: `_ = track(case Reason of provider_disabled -> 503; _ -> 502 end, Route, #{}),`

(Synthetic 500/502/503 mark gateway-side failures; the status column is documented as "upstream HTTP status, or 502/503 for gateway-side failure" — error-rate stats group on `>= 400` and are unaffected.)

- [ ] **Step 6: Compile + full eunit**

```bash
docker exec janus-local sh -c 'cd /app/.worktrees/dashboard-polish && REBAR_BASE_DIR=/app/_build ./rebar3 as dev eunit'
```
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add apps/janus_http/src/janus_http_proxy.erl
git commit -m "Track usage on non-streaming proxy paths"
```

---

### Task 6: Streaming coverage

Two parts: (a) inject `stream_options.include_usage` into upstream OpenAI chat streams (respecting a client-set `stream_options` and an operator kill switch) so the terminal usage chunk always arrives; (b) capture a bounded head+tail of every SSE stream and parse usage at stream end. Injection note: on the native path `ClientProto == ProviderProto` by construction and translate paths force non-stream, so keying on `ClientProto` is exact; the SSE bytes are provider-dialect and the parser is dialect-agnostic.

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
%% chunk on streams. Skip when the client set its own stream_options
%% (respect explicit choices) or the operator disabled injection
%% (strict upstreams may 400 on unknown fields). The usage chunk is
%% spec-compliant and forwarded to the client like any other chunk.
maybe_inject_stream_usage(openai_chat, true, Body, Map) ->
    Inject = application:get_env(janus_core, usage_inject_include_usage, true),
    case {Inject, maps:get(<<"stream_options">>, Map, undefined)} of
        {true, undefined} ->
            Map2 = Map#{<<"stream_options">> => #{<<"include_usage">> => true}},
            {iolist_to_binary(thoas:encode(Map2)), Map2};
        _ ->
            {Body, Map}
    end;
maybe_inject_stream_usage(_, _, Body, Map) ->
    {Body, Map}.
```

(The upstream adapter re-encodes the request body from `Map` and sets its own `Content-Length`; the returned `Body2` is only for adapters that use the raw body.)

- [ ] **Step 2: Capture head+tail during the stream drain**

In the streaming success clause (line ~208), replace the `Drain(fun(Chunk) -> ... end)` callback and the `ok`/`{error,_}` outcomes:

```erlang
    case
        Drain(fun(Chunk) ->
            capture_usage_chunk(Chunk),
            %% `_ =`: a client disconnect makes stream_body fail; the
            %% drain surfaces it as {error, _} below (recorded as 502)
            %% instead of crashing the request process mid-callback.
            _ = cowboy_req:stream_body(Chunk, nofin, Req2)
        end)
    of
        ok ->
            ok = cowboy_req:stream_body(<<>>, fin, Req2),
            _ = note_key_success(Route),
            _ = note_route_success(Route),
            _ = track(Status, Route, stream_usage(ClientProto)),
            {ok, Req2, State};
        {error, Reason} ->
            %% Mid-stream failure: record 502, not the already-sent 200.
            _ = track(502, Route, stream_usage(ClientProto)),
            SafeReason = sanitize_upstream_error(Reason),
            _ = note_provider_failure(Route, SafeReason),
            _ = release_route_inflight(Route),
            logger:warning(#{
                what => janus_proxy_stream_error,
                reason => SafeReason,
                client_proto => ClientProto
            }),
            catch cowboy_req:stream_body(<<"\n">>, fin, Req2),
            {ok, Req2, State}
    end;
```

Add the helpers (internal section):

```erlang
-define(USAGE_HEAD_BYTES, 4096).
-define(USAGE_TAIL_BYTES, 16384).
-define(USAGE_TAIL_CHUNKS, 256).

capture_usage_chunk(Chunk) ->
    Head0 = case get(janus_usage_head) of
        undefined -> <<>>;
        H -> H
    end,
    case byte_size(Head0) < ?USAGE_HEAD_BYTES of
        true ->
            Need = ?USAGE_HEAD_BYTES - byte_size(Head0),
            Take = binary:part(Chunk, 0, min(byte_size(Chunk), Need)),
            put(janus_usage_head, <<Head0/binary, Take/binary>>);
        false ->
            ok
    end,
    %% Tail is a newest-first {Chunks, TotalBytes} tuple; prepending is
    %% O(1) and the refold only runs when a cap is exceeded (both caps
    %% bound the fold size, so per-chunk cost stays constant).
    case Chunk of
        <<>> ->
            ok;
        _ ->
            {Chunks0, Size0} = case get(janus_usage_tail) of
                undefined -> {[], 0};
                T0 -> T0
            end,
            put(janus_usage_tail, maybe_trim([Chunk | Chunks0], Size0 + byte_size(Chunk)))
    end.

maybe_trim(Chunks, Size) when Size =< ?USAGE_TAIL_BYTES ->
    case length(Chunks) =< ?USAGE_TAIL_CHUNKS of
        true -> {Chunks, Size};
        false -> {lists:sublist(Chunks, ?USAGE_TAIL_CHUNKS), Size}
    end;
maybe_trim(Chunks, _Size) ->
    %% Over the byte cap: refold newest-first, keeping whole chunks
    %% that fit (whole-chunk granularity; the parser tolerates the
    %% remaining partial first line).
    {Kept, Size} =
        lists:foldl(
            fun(C, {Acc, S}) ->
                case S + byte_size(C) =< ?USAGE_TAIL_BYTES of
                    true -> {[C | Acc], S + byte_size(C)};
                    false -> {Acc, S}
                end
            end,
            {[], 0},
            Chunks
        ),
    {lists:reverse(Kept), Size}.

stream_usage(ClientProto) ->
    Head = case get(janus_usage_head) of
        undefined -> <<>>;
        H -> H
    end,
    Tail = case get(janus_usage_tail) of
        undefined -> <<>>;
        {Chunks, _} -> iolist_to_binary(lists:reverse(Chunks))
    end,
    erase(janus_usage_head),
    erase(janus_usage_tail),
    usage_or_undef(janus_usage_parse:from_sse(ClientProto, Head, Tail)).
```

- [ ] **Step 3: Proxy-helper eunit** (export `maybe_trim/2` and `maybe_inject_stream_usage/4` for tests)

Create `apps/janus_http/test/janus_proxy_usage_tests.erl`:

```erlang
-module(janus_proxy_usage_tests).
-include_lib("eunit/include/eunit.hrl").

trim_under_cap_passthrough_test() ->
    ?assertEqual({[<<"c">>, <<"b">>], 2}, janus_http_proxy:maybe_trim([<<"c">>, <<"b">>], 2)).

trim_keeps_newest_within_byte_cap_test() ->
    C1 = binary:copy(<<"a">>, 8192),
    C2 = binary:copy(<<"b">>, 8192),
    C3 = binary:copy(<<"c">>, 8192),
    %% newest-first input, 24KB total -> keeps the two newest (16KB),
    %% result stored newest-first; stream_usage/1 reverses for bytes.
    ?assertEqual({[C3, C2], 16384}, janus_http_proxy:maybe_trim([C3, C2, C1], 24576)).

trim_chunk_count_cap_test() ->
    Chunks = lists:duplicate(300, <<"x">>),
    {Kept, _} = janus_http_proxy:maybe_trim(Chunks, 300),
    ?assertEqual(256, length(Kept)).

injection_absent_by_default_for_non_openai_test() ->
    ?assertEqual(
        {<<"{}">>, #{<<"stream">> => true}},
        janus_http_proxy:maybe_inject_stream_usage(
            anthropic_messages, true, <<"{}">>, #{<<"stream">> => true}
        )
    ).

injection_adds_include_usage_test() ->
    application:set_env(janus_core, usage_inject_include_usage, true),
    {Body2, Map2} = janus_http_proxy:maybe_inject_stream_usage(
        openai_chat, true, <<"{}">>, #{}
    ),
    ?assertEqual(#{<<"include_usage">> => true}, maps:get(<<"stream_options">>, Map2)),
    ?assert(is_binary(Body2)).

injection_respects_client_stream_options_test() ->
    application:set_env(janus_core, usage_inject_include_usage, true),
    Map = #{<<"stream_options">> => #{<<"include_usage">> => false}},
    ?assertEqual(
        {<<"{}">>, Map},
        janus_http_proxy:maybe_inject_stream_usage(openai_chat, true, <<"{}">>, Map)
    ).

injection_kill_switch_test() ->
    application:set_env(janus_core, usage_inject_include_usage, false),
    Map = #{},
    ?assertEqual(
        {<<"{}">>, Map},
        janus_http_proxy:maybe_inject_stream_usage(openai_chat, true, <<"{}">>, Map)
    ),
    application:set_env(janus_core, usage_inject_include_usage, true).
```

- [ ] **Step 4: Compile + full eunit**

```bash
docker exec janus-local sh -c 'cd /app/.worktrees/dashboard-polish && REBAR_BASE_DIR=/app/_build ./rebar3 as dev eunit'
```
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add apps/janus_http/src/janus_http_proxy.erl
git commit -m "Capture token usage on streaming paths (polite include_usage injection, head+tail parse)"
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
            ts_from => From,
            ts_to => To,
            totals => janus_usage:totals(From, To),
            series => janus_usage:series(From, To, Bucket),
            by_key => janus_usage:breakdown(key, From, To),
            by_model => janus_usage:breakdown(model, From, To),
            by_provider => janus_usage:breakdown(provider, From, To),
            by_provider_key => janus_usage:breakdown(provider_key, From, To),
            writer => janus_usage:stats()
        },
        Req
    ).

handle_usage_events(Req) ->
    Qs = maps:from_list(cowboy_req:parse_qs(Req)),
    Limit = qs_int(maps:get(<<"limit">>, Qs, undefined), 50, 1, 200),
    case usage_filters(Qs) of
        {error, Field} ->
            err(400, <<"bad_filter">>, <<Field/binary, " must be an integer">>, Req);
        Filters when is_map(Filters) ->
            reply_json(200, #{events => janus_usage:recent(Limit, Filters)}, Req)
    end.

%% Builds #{key_id => integer(), model_id => integer()} — the exact
%% shape recent/2's recent_filters/1 matches on (atom keys, int values).
usage_filters(Qs) ->
    lists:foldl(
        fun
            (_Pair, {error, _} = Err) ->
                Err;
            ({Param, Field}, Acc) ->
                case maps:get(Param, Qs, undefined) of
                    undefined ->
                        Acc;
                    Bin ->
                        case qs_int(Bin, undefined, 1, infinity) of
                            undefined -> {error, Param};
                            N -> Acc#{Field => N}
                        end
                end
        end,
        #{},
        [{<<"key_id">>, key_id}, {<<"model_id">>, model_id}]
    ).

qs_int(undefined, Default, _Min, _Max) -> Default;
qs_int(Bin, Default, Min, Max) when is_binary(Bin) ->
    try
        N = binary_to_integer(Bin),
        case Max of
            infinity -> max(Min, N);
            _ -> min(Max, max(Min, N))
        end
    catch
        _:_ -> Default
    end;
qs_int(_, Default, _Min, _Max) -> Default.

usage_window(<<"7d">>) -> {now_sec() - 7 * 86400, now_sec(), day};
usage_window(<<"30d">>) -> {now_sec() - 30 * 86400, now_sec(), day};
usage_window(_) -> {now_sec() - 86400, now_sec(), hour}.

now_sec() ->
    erlang:system_time(second).
```

Note: `qs_int/4` with `infinity` keeps validation total without inventing an upper bound for ids. **Pre-flight:** grep `janus_dashboard_api.erl` first — if `qs_int/4` or `now_sec/0` already exist under those names, reuse the existing ones instead of redefining (duplicate definitions are a compile error).

- [ ] **Step 3: Compile, hot-load, verify via curl**

```bash
docker exec janus-local sh -c 'cd /app/.worktrees/dashboard-polish && REBAR_BASE_DIR=/app/_build ./rebar3 as dev compile'
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'code:load_file(janus_dashboard_api).'"
curl -s -c /tmp/cj.txt -X POST http://127.0.0.1:8090/api/session -H 'Content-Type: application/json' -d '{"password":"dev"}'
CK=$(grep janus_dashboard_session /tmp/cj.txt | awk '{print $NF}')
curl -s -b "janus_dashboard_session=$CK" 'http://127.0.0.1:8090/api/usage/summary?range=24h'
curl -s -b "janus_dashboard_session=$CK" 'http://127.0.0.1:8090/api/usage/events?limit=5&key_id=1'
```
Expected: JSON with `totals` (incl. `unreported`, `p95_latency_ms`, `p95_stream_ms`), `series`, `by_key`, `by_model`, `by_provider`, `by_provider_key`, `writer`; events array (possibly empty).

- [ ] **Step 4: Commit**

```bash
git add apps/janus_dashboard/src/janus_dashboard_api.erl
git commit -m "Expose /api/usage/summary (4 breakdowns + writer stats) and /api/usage/events (filtered)"
```

---

### Task 8: SPA — Usage page

**Files:**
- Create: `apps/janus_dashboard/spa/src/pages/usage.tsx`
- Modify: `apps/janus_dashboard/spa/src/main.tsx` (add route)
- Modify: `apps/janus_dashboard/spa/src/components.tsx` (add nav item)
- Modify: `apps/janus_dashboard/spa/src/pages/shared.tsx` (add shared types + formatters)

- [ ] **Step 1: Shared types** (append to `pages/shared.tsx`)

```tsx
export type UsageTotals = {
  requests: number
  prompt_tokens: number
  completion_tokens: number
  errors: number
  unreported: number
  avg_latency_ms: number
  avg_stream_ms: number
  p95_latency_ms: number | null
  p95_stream_ms: number | null
}
export type UsagePoint = { bucket: string; requests: number; prompt_tokens: number; completion_tokens: number }
export type UsageRow = { id: number | null; name: string | null; requests: number; prompt_tokens: number; completion_tokens: number; last_ts: number }
export type UsageEvent = {
  ts: number
  key_prefix: string | null
  model: string | null
  provider: string | null
  protocol: string
  stream: number
  status: number
  prompt_tokens: number | null
  completion_tokens: number | null
  latency_ms: number | null
}
export type UsageSummary = {
  range: string
  ts_from: number
  ts_to: number
  totals: UsageTotals
  series: UsagePoint[]
  by_key: UsageRow[]
  by_model: UsageRow[]
  by_provider: UsageRow[]
  by_provider_key: UsageRow[]
  writer: { alive: boolean; buffered: number; dropped: number }
}

export function fmtNum(n: number) {
  return n.toLocaleString("en-US")
}

/** "2026-10-04T13:00" → "13:00" (24h) or "10-04" (7d/30d); buckets are UTC. */
export function fmtBucket(bucket: string, range: string) {
  return range === "24h" ? bucket.slice(11, 16) : bucket.slice(5, 10)
}

/** Unix seconds → "MM-DD HH:MM:SS" UTC (charts and tables share one clock). */
export function fmtTs(ts: number) {
  const d = new Date(ts * 1000)
  const pad = (n: number) => String(n).padStart(2, "0")
  return `${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`
}
```

- [ ] **Step 2: The page** — structure contract (full code written in the executing session):

- `Layout title="Usage" description="Token consumption and traffic across agent keys, models, and providers — times are UTC."`
- Range `Select` in `CardAction` (24h / 7d / 30d) driving `api("/usage/summary?range=" + range)`; separate `api("/usage/events?limit=50")` for the drill-down. Poll summary every 30s while the page is open.
- Stat cards row (6-col grid like the dashboard): **Requests** (`fmtNum(totals.requests)`), **Tokens in** (`fmtNum(totals.prompt_tokens)`), **Tokens out** (`fmtNum(totals.completion_tokens)`), **Errors** (`totals.errors` + share %), **p95 latency** (`totals.p95_latency_ms ?? "—"` + `ms`, subtitle "non-stream"), **p95 stream** (`totals.p95_stream_ms ?? "—"`, subtitle "end-to-end · client drain"). Icons: `Activity`, `ArrowDownToLine`, `ArrowUpFromLine`, `CircleAlert`, `Timer`, `TimerReset`. When `writer.dropped > 0`, show a warning badge on the Requests card: "N dropped since boot (writer)" — and if `writer.alive === false`, a destructive badge "writer down".
- When `totals.unreported > 0`, a one-line muted note under the cards: "N successful requests had no provider usage report (streams without a usage chunk)."
- Two charts in a 2-col grid: **Tokens (UTC)** — stacked `BarChart` of `prompt_tokens` + `completion_tokens` (`stackId="t"`, colors `var(--color-chart-1)` / `var(--color-chart-2)`); **Requests (UTC)** — `BarChart` of `requests` (color `var(--color-chart-1)`). `XAxis dataKey` = precomputed `label` from `fmtBucket`. Before charting, **zero-fill the buckets**: build the complete bucket sequence between `ts_from` and `ts_to` (hour or day steps, UTC) and merge the API rows into it so gaps render as 0, not as missing bars.
- Four breakdown cards in `xl:grid-cols-2`: **Per agent key** (prefix or `(deleted)` when name is null), **Per model**, **Per provider**, **Per provider key** — columns: name, requests, tokens (`fmtNum(pin + pout)`), and a share bar (`div` with width % of the max requests in that card, `bg-primary/15`).
- Recent requests card: table Time (`fmtTs` + "UTC"), Key, Model, Provider, Status (2xx `text-success`, 4xx `text-warning`, 5xx `text-destructive`; 502 from mid-stream failure is expected), Stream (a `~` glyph or `Zap` icon when `stream === 1`), In, Out (`"—"` for null), Latency.
- Loading skeletons, `ErrorFlash`, empty state: "No usage recorded yet — stats appear after the first proxied request."
- Route in `main.tsx`: lazy `Usage` like other pages; `const usageRoute = createRoute({ getParentRoute: () => authLayout, path: '/usage', component: Usage })` added to the tree.
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
git commit -m "Add Usage stats page (cards, UTC series charts, 4 breakdowns, recent drill-down)"
```

---

### Task 9: End-to-end verification with real traffic

**Files:** none (verification only)

- [ ] **Step 1: Hot-load every new/changed module into the live node**

```bash
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval '[code:load_file(M) || M <- [janus_usage_parse, janus_usage, janus_http_proxy, janus_dashboard_api]], case whereis(janus_usage) of undefined -> gen_server:start({local, janus_usage}, janus_usage, [], []); _ -> ok end.'"
```
(`janus_usage` is not supervised in the running node — start it **unlinked** for verification; the eval RPC process exits after the call and would take a linked server down. On a real redeploy the supervisor starts it.)

- [ ] **Step 2: Mint a throwaway agent key and make three calls**

```bash
# 1. create key via dashboard API (POST /api/keys with CSRF) — capture the full key once
# 2. non-stream: POST :8080/v1/chat/completions {"model":"deepseek-chat","max_tokens":1,"messages":[...]}
# 3. stream:     same with "stream": true
# 4. error row:  same body against a disabled/unknown route if available, else skip
```
Then `GET /api/usage/events?limit=5`: the non-stream row has `status = 200`, tokens, `stream = 0`; the stream row has `stream = 1` and **non-null** tokens (proving the injection + head/tail parse works); `GET /api/usage/summary?range=24h` counts both. If a cross-protocol route exists (e.g. an Anthropic-protocol provider bound), repeat once against it to prove dialect-agnostic parsing.

Note: this spends a negligible amount of real upstream quota (1-token completions). Revoke the throwaway key afterwards via `DELETE /api/keys/:id`; usage rows keep `agent_key_id` (SET NULL on delete, shows as `(deleted)`).

- [ ] **Step 3: Failure-safety probes on the live node**

```bash
# malformed event: server survives, dropped increments
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'janus_usage:record(#{}), timer:sleep(100), janus_usage:stats().'"
# sweep: back-date a row 32 days, trigger sweep via eval, assert it is gone
docker exec janus-local sh -c "/app/_build/dev/rel/janus/bin/janus eval 'Old = erlang:system_time(second) - 32*86400, janus_db_conn:query(\"INSERT INTO usage_events (ts, protocol, status) VALUES (\" ++ integer_to_list(Old) ++ \", ''openai_chat'', 200)\", []), janus_usage ! sweep, timer:sleep(1000), janus_db_conn:query(\"SELECT COUNT(*) FROM usage_events WHERE ts < \" ++ integer_to_list(erlang:system_time(second) - 31*86400), []).'"
```
Expected: `#{dropped := N>0}` after the malformed cast; `{ok,[{0}]}` after the sweep.

- [ ] **Step 4: Verify the page renders the data** (both themes, all three ranges). Optional Postgres lane (only if a Postgres dev instance exists): apply `004_usage_events.postgres.sql`, hot-verify `totals/series/breakdown/recent` + p95 `percentile_disc` there.

- [ ] **Step 5: Final `npm run build` + commit any stragglers; report**

---

## Self-review notes

- Spec coverage: capture (T5/T6), storage + retention (T1/T3), rollups (T4), API (T7), page (T8), per-key/model/provider/provider-key (T4/T8), streaming (T6), latency avg/p95 split by stream (T4/T8), drill-down with filters (T4/T7), both DBs (T1/T4 dialect branches), audit fixes (all inline, no addendum).
- `agent_key_id = null` happens only for contexts where the agent id is missing — in practice auth always provides it. FK `ON DELETE SET NULL` renders as `(deleted)` in the UI. If Task 1 Step 3 finds `PRAGMA foreign_keys` off on SQLite, SET NULL is inert there — rows keep their (now-dangling) ids and render as `(deleted)` via the LEFT JOIN anyway, so behavior is consistent.
- One global gen_server is the write funnel: per-cast cost is a map prepend; flush is a 50-row multi-row statement ~1/sec; buffer capped at 10k (drop-newest); the mailbox itself is bounded by the `record/1` queue-length guard (drops counted via atomics and surfaced in `writer.dropped`).
- p95 caveat for operators: a provider emitting per-chunk (non-cumulative) `message_delta` token deltas would be under-reported (Anthropic proper is cumulative).
- `usage_events.protocol` stores the client protocol; SSE parsing is dialect-agnostic, so provider dialect needs no column.
- Types end-to-end: proxy event keys ↔ `record/1` validation ↔ `build_insert` defaults ↔ migration columns (nullable tokens, `stream` flag) ↔ `recent/2` output ↔ SPA `UsageEvent` (all token/latency fields `number | null`).
