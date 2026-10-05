# Janus next phase — design spec

Status: draft (pi-audit round 9; translate-only created clock)
Date: 2026-10-05
Repos: `Janus` (data plane) + `janus-dashboard` (management plane)

This document records the next work after the 2026-10-05 audit-fix
commits (`a57feba` gateway, `8d41e18` dashboard). It is a design spec,
not an implementation plan. Round-1 pi-audit consensus (7/7 GO WITH
FIXES) is folded in here.

## 1. Goal / non-goals

**Goal:** three operator-owned nodes can run **plain-text** Cursor / Claude
Code style **streaming** clients across Chat↔Messages mismatches
(tools/vision on the translate path stay 400). Operators see **live
request health per node**. Windows/local eunit runs in a **prebuilt
image** that never hits `dl-cdn.alpinelinux.org`.

**Non-goals (explicit):**

- Re-embedding the dashboard into the Erlang release
- Gateway-to-gateway traffic load balancing (Caddy / DNS stays in front)
- Multi-writer configuration (dashboard remains the sole catalog writer)
- Kubernetes operators, auto-discovery of nodes
- Vision / multimodal translate
- Streaming translate involving `openai_responses`
- **Streaming tool_calls / tool_use** (Phase 1 A is text + thinking
  only; those constructs `translate_unsupported` → 400 **before**
  upstream, same as vision)
- Agent RPM/TPM quotas (Phase 2)
- Changing listings vs Router bindings (catalog model stays)

The data plane stays a **pure gateway**: route, translate, LB, adjudicate.
Management logic stays in `janus-dashboard`.

## 2. Current state (baseline)

Working:

- Native passthrough Chat / Responses / Messages, including SSE when
  client protocol equals provider protocol
- Non-stream cross-protocol translate (text + basic tools);
  Anthropic `thinking` → OpenAI `reasoning_content`
- Catalog ETS + generation NOTIFY, listings + bindings, `janus-auto`
- Usage events in Postgres; dashboard Usage page
- Split dashboard; `:8090` `/stats` + `/stats/logs`

Broken or incomplete relative to this spec:

- `dispatch/7` in `janus_http_proxy.erl` returns **400
  `stream_requires_native_protocol`** when `stream=true` and protocols
  differ. Cursor/Claude Code almost always stream.
- `GET /stats` does **not** emit dashboard SPEC fields
  `requests_total` / `requests_failed` (`janus-dashboard/docs/SPEC.md`
  §2.4). Node health can show generation but not live error rate.
- Local Windows compile uses `erlang:27-alpine` + `apk add build-base`.
  Default Alpine CDN hangs; the **release** Dockerfile already rewrites
  apk to `mirrors.aliyun.com`, but ad-hoc `docker run erlang:27-alpine
  apk add …` does not. GitHub CI uses `erlef/setup-beam` (not Alpine),
  so CI green ≠ laptop green. `AGENTS.md` already says
  `docker build --target build -t janus-build:test` then **no-mount**
  `docker run`; that command is not what people actually run, and the
  `build` stage today is a **prod release**, not eunit.
- Production deploy checks generation loosely; gitleaks is CI-only
  (pre-commit hook skipped when the binary is missing).

## 3. Approaches considered

| | Approach | Trade-off |
|---|----------|-----------|
| A | **Streaming only** | Users feel the win; operators still blind; Windows eunit still flaky |
| B | **Ops only** | Sleep-at-night ops; Cursor still cannot hit Anthropic providers via Chat SSE |
| C | **Phase 1 bundle (chosen)** — Chat↔Messages streaming translate + node counters + prebuilt test image; small deploy hygiene | Three independent PRs; together they match “industrial enough for us” |

Phase 2 (quotas, LB explain, auto-router audit headers) **must not
start** until Phase 1 is green on the local E2E gate.

**Dual-repo rule:** Slice A TEST-FLOWS and Slice D `deploy_prod.sh`
live in `../janus-dashboard`. Each is a **paired PR** with the gateway
change; a Janus-only merge does not close the slice.

## 4. Phase 1 — four shippable slices

### 4.1 Slice A: streaming Chat ↔ Anthropic Messages translate

**Problem.** Native SSE already works. Mixed protocol + `stream:true`
is rejected before the adapter.

**Scope (in):** text deltas, thinking/`reasoning_content`, stop/finish
reasons, **synthesized usage on the client stream**, true incremental
drain (no whole-body buffer). Bidirectional:

- Client `openai_chat` ↔ provider `anthropic_messages`
- Client `anthropic_messages` ↔ provider `openai_chat`

**Scope (out):** `openai_responses`; vision/image parts; **streaming
tools** (`tool_calls`, `tool_use`, `input_json_delta`). Those stay
400 `translate_unsupported` on the **request** leg before gun opens.

#### 4.1.1 Request leg (before upstream)

1. `translate_request(Client, Provider, Map)` as today, with
   `stream => true` on the provider map.
2. If `{error, {translate_unsupported, Msg}}` (image, tools, etc.) →
   **400 before** `call_adapter`. No drain, no 200 headers.
3. Request `n` present and not `1` → 400 before upstream. Response
   `choices` length > 1 after 200 is mid-stream `invalid_request`.
4. Strip on the translate request: `metadata`, `cache_control`,
   array-form `system` (flatten to string as native translate already
   does). Client `stream_options` is ignored; gateway injects its own.
5. Provider `openai_chat` **and** client `anthropic_messages` only:
   inject `stream_options.include_usage = true`. Retry **exactly once**
   and **only** if the provider returns **400** before any 200
   (re-encode the already-translated body **without** `stream_options`).
   Never retry 401/5xx. Native Chat↔Chat never injects here. Provider
   `anthropic_messages`: no equivalent; usage from `message_start` +
   `message_delta`.
6. First byte before headers: existing gun receive timeout → 504,
   no SSE, no `finalize_sse`.
7. Chat client omitting `max_tokens`: synthesize Anthropic
   `max_tokens=4096` on the request leg (required field).

#### 4.1.2 Functions (pure, eunit first)

```
sse_events(Buffer, Chunk) ->
    {ok, Events, Rest} | {error, leftover_cap}
  %% Cap ?SSE_LEFTOVER_CAP = 1 MiB on byte_size(Buffer)+byte_size(Chunk)
  %% AND on any complete `data:` line. One constant, both checks.
  %% Skips `: ` comments; CRLF or LF; multiple events per Chunk.
  %% Rest is the incomplete tail (handler copies it to #sse_st.leftover).

  %% #{type => binary(), data => map() | binary()} for Anthropic
  %% (type from `event:` line; data JSON-decoded with binary keys)
  %% or #{type => <<"chunk">>, data => map()} / #{type => <<"done">>}
  %% for OpenAI. Rest is the incomplete tail.

-record(sse_st, {
    leftover = <<>> :: binary(),
    role_sent = false :: boolean(),
    %% Next Anthropic content-block index (monotonic; text↔thinking)
    next_block = 0 :: non_neg_integer(),
    block = undefined :: undefined | non_neg_integer(),
    block_kind = undefined :: undefined | text | thinking,
    %% OpenAI id / model copied from provider when present; created is
    %% always the gateway clock at first Chat client frame (Anthropic
    %% message_start has no created field).
    msg_id = undefined :: undefined | binary(),
    model = undefined :: undefined | binary(),
    created = undefined :: undefined | non_neg_integer(),
    %% Anthropic usage merge
    in_tokens = undefined :: undefined | non_neg_integer(),
    out_tokens = undefined :: undefined | non_neg_integer(),
    stop_reason = undefined :: undefined | binary(),
    finish_reason = undefined :: undefined | binary(),
    usage_sent = false :: boolean(),
    finish_sent = false :: boolean(),
    terminal_sent = false :: boolean()
}).

%% Every arm returns St (including the error arm — handler needs
%% usage_sent/finish_sent/terminal_sent for finalize). Bare `skip`
%% is forbidden. Frames may be [].
translate_sse(ClientProto, ProviderProto, Event, #sse_st{}) ->
    {ok, [ClientFrame :: iodata()], #sse_st{}}
  | {error, translate_unsupported, #sse_st{}}.

finalize_sse(ClientProto, Reason, #sse_st{}) ->
    {ok, [ClientFrame :: iodata()], #sse_st{}}
  %% Reason = normal
  %%        | {error, invalid_request | upstream, binary()}
  %%        | disconnect
  %% Exactly one terminal: Chat always last frame `data: [DONE]\n\n`;
  %% Anthropic client always last event `event: message_stop`.
  %% If terminal_sent already true, or Reason=disconnect, returns
  %% {ok, [], St} (frames discarded — socket cannot receive them).
  %% Reason=normal and terminal_sent=false:
  %%   Chat: pending finish chunk (default finish_reason=stop),
  %%         then at most one empty-choices usage chunk if any token
  %%         field is defined and not yet sent, then `[DONE]`.
  %%   Anthropic: if next_block==0, one empty text start+stop;
  %%         if stop not yet sent, `message_delta` with
  %%         `{type:message_delta, delta:{stop_reason}, usage}`
  %%         (default stop_reason=end_turn; omit usage object if
  %%         both token fields undefined); then `message_stop`.
  %%   If a mapping-table row already emitted the finish/usage,
  %%   finalize emits only the terminator (`usage_sent` /
  %%   `finish_sent` on St).
  %% gun:cancel is idempotent; only the handler process calls it.
```

Handler owns `#sse_st{}`. Drain: `sse_events` then fold `translate_sse/4`;
write each fold immediately (no frame buffer). Copy `Rest` into
`#sse_st.leftover` each step (that field is the only leftover owner).
Drain EOF with `terminal_sent=false` calls `finalize_sse(..., normal, St)`.
`sse_events` leftover_cap (502) uses `?SSE_LEFTOVER_CAP` (1 MiB) on
Buffer+Chunk **and** any complete `data:` line. Empty `delta` /
Anthropic `model_delta` → `{ok, [], St}`.
`created` on Chat first chunk = gateway `erlang:system_time(second)`
(always; never copied from Anthropic).
OpenAI usage chunk: `id`/`object`/`created`/`model` from St, `choices: []`,
`usage.{prompt_tokens,completion_tokens}` (omit the chunk if both
undefined). Zero-content Anthropic face: `finalize_sse(normal)` emits `message_start`
if needed, then **one** empty text block start+stop (this is the only
exception to “do not open a block until first delta”), then
`message_stop`.
Response `n>1` (defensive: some OpenAI-compatible proxies emit extra
choices) is mid-stream **400** `invalid_request`.
Any `translate_sse` `{error, translate_unsupported, St}` **after 200**
is **502** (provider-origin); finalize uses that returned St.
`include_usage` only provider Chat + client Messages; retry 400 once
**without** calling `track` on the discarded attempt (same `do_proxy`,
same counters). `inc_total` at `do_proxy` enter is a no-op when
`janus_stats_inner` is already true.
DB usage row is `capture_usage_chunk` only. janus-auto inner `do_proxy`
does **not** `inc_total`/`inc_failed`; only the outer client-visible
`track` may bump failed. Same-protocol stream is byte-identical except
optional `x-accel-buffering: no`. Other mismatched pairs still 400
`stream_requires_native_protocol`.

#### 4.1.3 Normative event mapping

Stop reasons:

| Anthropic `stop_reason` | OpenAI `finish_reason` |
|-------------------------|------------------------|
| `end_turn` / `stop_sequence` | `stop` |
| `max_tokens` | `length` |
| `refusal` | `content_filter` |
| `pause_turn` | `stop` |
| `tool_use` | (out of scope — request already 400) |
| unknown | `stop` + log `janus_translate_sse_unknown_stop` |

Reverse (Chat → Anthropic): `stop`→`end_turn`, `length`→`max_tokens`,
`content_filter`→`refusal`, `tool_calls`→unsupported, unknown→`end_turn` + log.

**Provider Anthropic → client Chat** (upstream `event:` + JSON `data:`):

| Provider event | Client frames |
|----------------|---------------|
| `ping` | SSE comment `: ping\n\n` |
| `message_start` | first `data:` chunk: `id`, `object=chat.completion.chunk`, `created` (unix seconds), `model`, `choices[0].delta.role=assistant`; stash `usage.input_tokens` (omit if missing, never crash) |
| `content_block_start` type `text` / `thinking` | if the start object has non-empty `text`/`thinking`, emit that as the first delta; else `{ok, [], St}` with `block_kind` set. type `tool_use` or other → `{error, translate_unsupported}` |
| `content_block_delta` `text_delta` | `choices[0].delta.content` |
| `content_block_delta` `thinking_delta` | `choices[0].delta.reasoning_content` |
| `content_block_delta` `signature_delta` | `{ok, [], St}` |
| `content_block_stop` | `{ok, [], St}` |
| `message_delta` | finish-only chunk: `choices[0].finish_reason` mapped. Stash `usage.output_tokens` if present. **Usage is never on the finish chunk**; it is a later empty-choices chunk |
| then (after finish, when out_tokens known or on `message_stop`) | **order: finish chunk → at most one empty-choices usage chunk → `[DONE]`**. Omit usage chunk if both token fields undefined. Do not emit a second usage chunk if tokens were already sent |
| `message_stop` | if a usage chunk is still pending, emit it; then `finalize_sse(..., normal, …)` emits **only** `[DONE]` (no second usage chunk) |
| `error` (provider in-band) | §4.1.4 **502** `upstream` |

**Provider Chat → client Anthropic:**

| Provider event | Client frames |
|----------------|---------------|
| first provider chunk (role optional; also empty `delta` keepalive **after** start already sent → `{ok, [], St}`) | if `role_sent=false`: emit `event: message_start` (`message: {id` from chunk or synthesized `msg_`+8 hex, `type=message, role=assistant, model` from chunk or `<<"unknown">>`, `content=[], stop_reason=null, usage: {input_tokens: In or 0, output_tokens: 0}}`). Omit unlisted Anthropic fields (`sequence_number`, …). Do **not** open a content block until first text/thinking delta **except** the zero-content `finalize_sse(normal)` path |
| `delta.content` | if no block or `block_kind ≠ text`: `content_block_stop` if a block is open, then `content_block_start` `{type:text,text:""}` at `next_block++`, then `text_delta`. If the same chunk also has `reasoning_content`, process **content first**, then reasoning (one transition) |
| `delta.reasoning_content` | same transition into thinking (`content_block: {type:thinking,thinking:""}`). **No `signature`**. Document in README §Agent endpoints |
| any Chat chunk with a `usage` object (empty-choices **or** attached to a delta/finish chunk) | stash `prompt_tokens`→`in_tokens`, `completion_tokens`→`out_tokens`; do **not** emit `message_delta` yet |
| `finish_reason` | `content_block_stop` if open; delay `message_delta` until usage or `[DONE]` |
| usage or `[DONE]` after finish | `event: message_delta` JSON `{type:message_delta,delta:{stop_reason},usage:{input_tokens if known, output_tokens}}` then `finalize_sse` → **only** `message_stop` (usage already on this event). Do not rewrite `message_start` |
| `delta.tool_calls` | `{error, translate_unsupported}` → handler **502** |
| OpenAI in-stream `error` object | §4.1.4 **502** |

`event:` lines are required on the Anthropic client face. Chat client
face is bare `data:` JSON + `[DONE]` — **never** `message_stop`.
`translate_sse` never returns bare `skip`; use `{ok, [], St}`.

#### 4.1.4 Mid-stream error / disconnect (headers already 200)

Once SSE headers are sent, HTTP status stays 200. **Single**
`finalize_sse` on every exit.

| Case | Client Chat frames | Client Anthropic frames | `track` status |
|------|--------------------|-------------------------|----------------|
| Mid-stream `n>1` / client-attributable `invalid_request` | `data:{"error":{…,"type":"invalid_request_error"}}` then `[DONE]` | `event: error` `{type:error,error:{type:invalid_request_error,…}}` then `message_stop` | **400**; **cancel gun** |
| Provider-origin unsupported (`tool_use`/`tool_calls` after 200) or in-band `error` / drain failure | same JSON, **sanitized** (no URL/auth, ≤200 bytes) | `event: error` `{type:api_error,…}` then `message_stop` | **502** `upstream`; cancel gun |
| Client disconnect or `stream_body` `{error, closed}` | no further frames; `finalize_sse(disconnect)` internally | same | **502**; cancel gun; `track(502)` always calls `capture_usage_chunk` (tokens may be null) |
| Malformed provider JSON | `{ok, [], St}` + log `janus_translate_sse_bad_json` | same | no extra track |
| Cowboy `idle_timeout` | Cowboy **inactivity** 300s with no bytes on the request (including SSE). Not wall-clock of the whole request. Detection = `stream_body` error, EXIT, leftover cap, or gun timeout. Forward provider `ping` as client `: ping`. No extra timer | same | 502 only if gun/client dies |

After error finalize: ignore further events (`terminal_sent`).
Streaming headers: `content-type: text/event-stream`,
`cache-control: no-cache`, `x-accel-buffering: no`. Native path:
add `x-accel-buffering: no` only if missing; do not otherwise change
bytes. `include_usage` injection **only** provider Chat + client
Messages; retry **exactly once** on pre-200 **400** only.
Do **not** `collect_drain` on a translating 200 stream.

#### 4.1.5 Tests

eunit **first**, binary JSON keys, split `data:` across two
`sse_events/2` calls:

- Anthropic `thinking_delta` → Chat `reasoning_content`
- Chat `delta.content` → Anthropic `text_delta` + envelope
- `ping` → `: ping`; malformed JSON `{ok, [], St}`
- Chat no-role first chunk still emits Anthropic `message_start`
- leftover > 1 MiB → 502 finalize
- `finalize_sse` twice → one terminator
- `finalize_sse` idempotent; Chat terminator always `[DONE]`
- tool_use / tool_calls → `{error, translate_unsupported}`

Local E2E (paired dashboard PR, `TEST-FLOWS.md`):

- **TF-6.8** Chat client `stream:true` against an Anthropic-bound
  public name (real upstream, same as TF-6.3/6.4). Assert **≥2**
  `data:` events, last non-empty terminator is `[DONE]`, usage row
  `stream=1` with tokens not both null when upstream reports them.
- **TF-6.8b** reverse: Anthropic Messages client `stream:true` against
  an OpenAI-chat-bound name; last event `message_stop`.
- Native TF-6.4 still green.

### 4.2 Slice B: node request counters on `/stats`

**Problem.** Dashboard SPEC §2.4 already documents
`requests_total` / `requests_failed`. Gateway does not emit them.
SPA `Node` type already has optional fields; the Nodes **table**
does not render them yet — Slice B **does** edit
`../janus-dashboard/spa/src/pages/nodes.tsx`.

**Count unit:** one **client LLM call** (after auth + JSON object
parse, entering `proxy_model` / `do_proxy`). Not `/v1/models`, not
`/healthz`, not per LB retry, not per janus-auto inner judge/target
(janus-auto = 1). Invariant: `requests_failed <= requests_total`.

**Bump sites (single funnel):**

| Event | total | failed |
|-------|-------|--------|
| Enter `do_proxy` after successful JSON map | +1 | 0 |
| Terminal `track(Status, …)` (outer only) | 0 | +1 if Status ≥ 400, **once**; `put(janus_stats_tracked, true)` |
| Handler crash `try … after` | 0 | +1 only if counted **and not** inner **and not** tracked **and not** failed |
| janus-auto inner judge/target `do_proxy` | 0 | 0 (inner `track` writes **usage rows only**; must **not** set `janus_stats_tracked` / `janus_stats_failed`) |
| Client disconnect (`track(502)`) | 0 | +1 via track (flag blocks double count) |
| 401 missing/invalid key (never enters `do_proxy`) | 0 | 0 |
| 400 invalid JSON **before** `do_proxy` | 0 | 0 |
| Authenticated unknown **model name** (lookup **inside** `do_proxy` after `inc_total`) | 0 (already +1) | +1 via `track(404)` |
| Pre-upstream `translate_unsupported` (tools/vision, still inside `do_proxy`) | 0 (already +1) | +1 via `track(400)` |

Do **not** overload `track/3` to also mean “total”. Total is
`janus_http_stats:inc_total()` at `do_proxy` enter, **before** model
resolution (`put(janus_stats_counted, true)` immediately after). Failed
is `inc_failed()` from the **outer** client-visible `track/3` when
Status >= 400 **and** `janus_stats_failed` is unset (then set it).
The crash `after` clause is a **fallback only**: bump failed iff
counted AND not inner AND not tracked AND not failed. A successful
`track(200)` sets `tracked` so `after` must **not** bump. Inner
janus-auto calls set `janus_stats_inner=true` **immediately before**
the inner `do_proxy` and **erase/restore** it in `after` so the outer
`track`/`after` still see the outer flags. Inner never `inc_failed`.
401/400-before-`do_proxy` must **not** call `track/3`. Atomics reset
when `janus_http_app` inits
(VM or app restart; hot code reload without re-init **keeps** counters).
Process-dict keys live on the **Cowboy handler process only**.
`/stats` emits `started_at` and `uptime_sec`. Nodes table is **per-node**.
If `requests_total < 10`, UI may show "—" for a derived rate; still
show raw counts **and** `started_at`. Recorded `track` after SSE 200
may be 400/502 while the wire status stays 200. SPEC §2.4 is the
**counted population** (after `do_proxy` entry), not all HTTP. Client
disconnect is recorded 502. FastAPI `/stats` proxy **passthrough**;
update `janus-dashboard/docs/SPEC.md` §2.4.

Atomics: created once in `janus_http_app` before Cowboy listeners
(`persistent_term`). `/stats` reads integers; missing ref → 0.

E2E: TF-6.1 must be an **LLM call**. After it, that **serving** node
has `requests_total >= 1` and `failed <= total`. Authenticated 404
increments **both**. 401 neither. Streaming tools 400 inside `do_proxy`
increments both. janus-auto: total +1; inner judge 5xx with successful
fallback must **not** increment failed. TF-6.8/6.8b: Chat face **no**
`event:` lines; Anthropic first event is `message_start`, last is
`message_stop`, **no** `[DONE]`; eunit covers no-role first chunk.
Thinking-path E2E (TF-6.8c) is **optional**; required coverage is eunit.

### 4.3 Slice C: prebuilt test/compile image (fix “apk hang”)

`apk` = Alpine Package Keeper. Production `Dockerfile` `build` stage
already uses Aliyun apk mirror and produces a **release**. Slice C
adds a **`test` stage** (OTP 27, git, build-base, Aliyun mirror,
`COPY` apps + rebar, `./rebar3 compile` of the **default** profile).
Tag still `janus-build:test`. **Update `AGENTS.md`** so it no longer
says `--target build -t janus-build:test`.

The `test` stage **does not COPY host `_build`** (`.dockerignore`
already should exclude `_build`; add it if missing). `rm -rf _build`
at the start of the compile RUN if needed.

`COPY rebar3 /usr/local/bin/rebar3` in the `test` stage so mounts
cannot shadow the escript. Image `RUN` uses `rebar3 compile` (PATH).
`ARG HEX_MIRROR` at **build**; also warm the hex cache in the image
so a named `_build` volume does not force a first-run hex fetch.
Pre-fetch the `rebar3_fmt` plugin in that RUN.

**Windows / laptop command (the only documented one):**

```bash
docker build --target test -t janus-build:test .
docker run --rm \
  -v F:/Janus/apps:/app/apps \
  -v F:/Janus/config:/app/config \
  -v F:/Janus/rebar.config:/app/rebar.config \
  -v F:/Janus/rebar.lock:/app/rebar.lock \
  -v janus-ebin-otp27:/app/_build \
  -w /app janus-build:test \
  sh -c 'rebar3 fmt --check && rebar3 eunit'
```

Do **not** bind-mount the repo root over `/app`. Volume caches
`_build` only — **recreate** it (`docker volume rm janus-ebin-otp27`)
when `rebar.lock`, `rebar.config`, or OTP version changes, else stale
beams. `HEX_MIRROR` on **build and** run (China). Docker Desktop must
share the `F:` drive. `.gitattributes`: `*.erl *.hrl
*.config *.app.src rebar.config rebar.lock text eol=lf`. Slice C has
**no** dashboard PR.
CI `eunit-docker` copies source in (no mount). CRLF fmt failures on a
laptop mount are an environment bug.

GitHub: keep `setup-beam` as primary. Add job `eunit-docker`:
`docker build --target test` then `docker run` **without** source
mount (compile already in the image) `rebar3 eunit`. Aliyun mirror
inside the image; GitHub runners can reach it. If not, ARG
`APK_MIRROR` defaulting to Aliyun with CI override to Alpine CDN.

`rebar3 compile` fetches hex; `get-deps` is optional, not required.

### 4.4 Slice D: deploy / secret hygiene

Paired PR on `../janus-dashboard/scripts/deploy_prod.sh`.

After leader migration is verified, **before** shifting follower
traffic:

0. Record `gen0` from dashboard DB **before any ship action**. If the
   ship has **no config diff**, skip the generation wait (same as
   `--code-only`). Config ships bump generation. **Code-only** ships
   (`deploy_prod.sh --code-only`): token-auth `/stats` on every node
   **and** `uptime_sec` less than the ship window (script start→end,
   only for nodes whose image digest changed). `stats_url` comes from
   the dashboard node record. Bearer auth already exists.
1. Probe leader `GET {stats_url}/stats` with Bearer `JANUS_STATS_TOKEN`.
   Transient probe errors retry until the same 300s deadline. Capture
   **leader** generation **after catalog apply** (ETS rebuild done);
   do not re-read it every poll.
2. Poll followers every **2s**, deadline **300s**, **in parallel**.
3. Config ship: follower `generation` **> gen0** **or** equal to
   captured leader generation, stable on **two consecutive** polls
   **after that node's catalog apply**. `--code-only` / empty-diff
   uses the `uptime_sec` window instead.
4. Transient HTTP errors retry until deadline.
5. On deadline or 401: `docker logs --tail 200` of that node into
   `/tmp/janus-deploy-<UTC>/<node>.log`, then **halt** (no rollback,
   no skip). Schema migrations stay backward-compatible one version
   so a halted follower still boots.
6. Empty dashboard `JANUS_STATS_TOKEN`: halt immediately.

Document gitleaks local install (CI workflow already exists). No
schema changes.

## 5. Phase 2 — after Phase 1 E2E is green

No implementation until Phase 1 done. Each item is its own future spec.

### 5.1 Agent-key quotas (RPM / TPM / daily cap)

Per-node limits first (not global). Dashboard writes limits; gateway
429 + `retry-after`.

### 5.2 LB explainability (read-only)

Compact cooldown snapshot on `GET /stats`. Must not call `pick_route`
speculatively.

### 5.3 janus-auto audit trail

Response header
`x-janus-route: name;tier=fast;origin=rules`.
Do not put this inside `choices`.

## 6. Testing rules (project-wide)

- eunit **first** for parsers; binary JSON keys; no `case M of #{}`.
- Local E2E `../janus-dashboard/scripts/e2e_local.sh` is the gate.
- Windows compile/eunit **only** via Slice C image.
- Durable E2E artifacts (logs, PASS/FAIL list).

## 7. File touch map

Phase 1 A (Janus + paired dashboard):

- `apps/janus_http/src/janus_protocol_translate.erl`
- `apps/janus_http/test/janus_protocol_translate_tests.erl` (eunit first)
- `apps/janus_http/src/janus_http_proxy.erl` — request-leg stream
  translate, drain fold, `finalize_sse` in `try/after` after headers,
  gun cancel on disconnect
- `apps/janus_core/src/janus_usage_parse.erl` — confirm Anthropic SSE
  usage merge (`message_start` + `message_delta`); extend if TF-6.8
  tokens would otherwise stay null
- `../janus-dashboard/docs/TEST-FLOWS.md` — TF-6.8 / 6.8b

Phase 1 B:

- `apps/janus_http/src/janus_http_stats.erl` (new) +
  `janus_http_app.erl` init + `janus_gateway_stats.erl` read +
  `janus_http_proxy.erl` bump sites
- `../janus-dashboard/spa/src/pages/nodes.tsx`
- `../janus-dashboard/docs/SPEC.md` §2.4 + FastAPI stats passthrough

Phase 1 C:

- `Dockerfile` (`test` stage), `.dockerignore` if `_build` not ignored
- `README.md`, `AGENTS.md` (stage name + exact `docker run`)
- `.github/workflows/ci.yml` (`eunit-docker` job)

Phase 1 D:

- `../janus-dashboard/scripts/deploy_prod.sh`

## 8. Success criteria

1. TF-6.8 and TF-6.8b green locally; TF-6.4 still green.
2. `GET /stats` includes `requests_total` and `requests_failed` with
   `failed <= total`; Nodes table shows both.
3. Documented Slice C `docker build --target test` + named volume
   `rebar3 eunit` succeeds on Windows without fetching
   `dl-cdn.alpinelinux.org`.
4. Config ship: deploy script halts if a follower generation is not
   `> gen0` or leader-equal and stable within 300s, or stats token
   polls fail. `--code-only` uses the `uptime_sec` window instead.

## 9. Order of work

1. Slice C (test image) — unblocks eunit
2. Slice A (streaming translate) — user-visible; paired TEST-FLOWS PR
3. Slice B (counters) — can parallel A after C
4. Slice D (deploy wait) — with the next production ship
5. Stop. New spec for Phase 2.

**Coordination with the entitlement-failover spec**
(`docs/superpowers/plans/2026-10-05-entitlement-failover.md`): its
Part C (in-request key failover) implements AFTER this Phase 1 —
Slice A redefines the proxy drain loop it must wrap. Interaction
points settled in that spec: (a) commit point = first translated
client frame, so pre-first-byte upstream errors stay retryable;
(b) the include_usage retry-once layers inside one failover attempt
(same key/listing, body rewrite), never consumes a failover slot;
(c) after Slice A the streaming candidate filter for janus-auto
tiers AND failover picks becomes request-feature-based (tools/vision
→ same protocol only; text+thinking → translate-capable), superseding
the blanket stream constraint; (d) Slice B counters count client
calls only — failover retries and the include_usage retry are inner
attempts of one counted call and never bump total/failed themselves.

## 10. Closed decisions (do not re-open)

These were raised in pi-audit rounds 1–4 and are **already specified**.
A later audit that restates them is not a remaining fix.

- Translate streaming is **plain text + thinking** only; tools on a
  mismatched protocol get 400. That is the goal.
- No gateway-origin keepalive timer. Forward provider `ping`. Cowboy
  `idle_timeout` is **inactivity** 300s.
- Disconnect: `finalize_sse(disconnect)` → `{ok, [], St}`; usage row
  written; recorded 502.
- After 200, `translate_unsupported` is always 502; 400 is only `n>1`
  / client-attributable `invalid_request`.
- Drain EOF → `finalize_sse(normal)`: Chat may emit one usage chunk
  then `[DONE]`; Anthropic usage is on `message_delta` then only
  `message_stop`. If usage already flushed, terminator only.
- Zero-content Anthropic: empty text block **only** inside
  `finalize_sse(normal)` when `next_block==0`.
- Anthropic client `message_delta` wire is `{type,delta,usage}`, not
  a nested `message` object.
- `translate_sse` error arm is `{error, translate_unsupported, St}`.
- `after` failed bump is fallback only; `track(200)` sets tracked so
  after does not bump.
- `#sse_st{}` includes `created`, `stop_reason`, `finish_reason`,
  `usage_sent`, `finish_sent`.
- Inner `janus_stats_inner` is put/erase around inner `do_proxy` only;
  `inc_total` is a no-op when inner is already true.
- **Translate** Chat-face `created` is always the gateway clock.
  Native Chat↔Chat does not rewrite `created`.
- Disconnect `track(502)` always calls `capture_usage_chunk` (nulls OK).
- Mid-stream `n>1` is a handler check (not `translate_sse` error arm);
  mid-stream gun timeout after 200 records 502.
- `n>1` after 200 is a defensive 400 (misbehaving proxy).
- `sse_events` error is `leftover_cap`; one 1 MiB constant; leftover
  owner is `#sse_st.leftover` copied from `Rest`.
- Usage **row** = `capture_usage_chunk`. Client SSE usage is display
  from `#sse_st{}`. Stash `usage` from **any** Chat chunk.
- Late `input_tokens`: do not rewrite `message_start`; put them on
  Anthropic `message_delta.usage` when known (both directions).
- No thinking `signature`. Omit extra Anthropic fields.
- `include_usage` only Chat-up + Messages-client; retry **400 once**.
- Chat→Anthropic `message_start` on first chunk (role optional);
  synthesize id/model; eunit for no-role.
- `max_tokens` default 4096 on Anthropic request leg.
- janus-auto inner `do_proxy` never `inc_total`/`inc_failed`; failed
  is the **client-visible** outcome only.
- `inc_total` before model lookup; 404 unknown-model both counters;
  JSON-missing-model before `do_proxy` neither.
- Volume wipe on lock/config/OTP; `rebar3` on PATH; HEX_MIRROR at
  build; hex cache in image; Docker Desktop shares `F:`.
- Empty config diff skips generation wait; `--code-only` uptime
  window only for changed image digests; `stats_url` from node row.
- Native bytes unchanged except optional `x-accel-buffering: no`.
- No `collect_drain` on translating 200. Thinking E2E optional.
- Phase 2 stays deferred.
