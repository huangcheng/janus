# Janus next phase — design spec

Status: draft (pi-audit round 2)
Date: 2026-10-05
Repos: `Janus` (data plane) + `janus-dashboard` (management plane)

This document records the next work after the 2026-10-05 audit-fix
commits (`a57feba` gateway, `8d41e18` dashboard). It is a design spec,
not an implementation plan. Round-1 pi-audit consensus (7/7 GO WITH
FIXES) is folded in here.

## 1. Goal / non-goals

**Goal:** take the current “usable early production” gateway to a
state where three operator-owned nodes can run Cursor / Claude Code
style **streaming** clients across Chat↔Messages protocol mismatches,
operators can see **live request health per node**, and Windows/local
eunit runs in a **prebuilt image** that never hits
`dl-cdn.alpinelinux.org`.

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
3. Provider `openai_chat`: inject
   `stream_options.include_usage = true` (same helper as native
   `maybe_inject_stream_usage/4`). Provider `anthropic_messages`: no
   equivalent; usage is merged from `message_start` + `message_delta`.

#### 4.1.2 Functions (pure, eunit first)

```
sse_events(Buffer, Chunk) -> {Events, Rest}
  %% Buffer and Chunk are binaries. Events are
  %% #{type => binary(), data => map() | binary()} for Anthropic
  %% (type from `event:` line; data JSON-decoded with binary keys)
  %% or #{type => <<"chunk">>, data => map()} / #{type => <<"done">>}
  %% for OpenAI. Rest is the incomplete tail.

-record(sse_st, {
    leftover = <<>> :: binary(),
    role_sent = false :: boolean(),
    %% Anthropic block index currently open; undefined if none
    block = undefined :: undefined | non_neg_integer(),
    block_kind = undefined :: undefined | text | thinking,
    %% OpenAI id / model copied from message_start or first chunk
    msg_id = undefined :: undefined | binary(),
    model = undefined :: undefined | binary(),
    %% Anthropic usage merge
    in_tokens = undefined :: undefined | non_neg_integer(),
    out_tokens = undefined :: undefined | non_neg_integer(),
    terminal_sent = false :: boolean()
}).

translate_sse(ClientProto, ProviderProto, Event, #sse_st{}) ->
    {ok, [ClientFrame :: iodata()], #sse_st{}}
  | skip
  | {error, translate_unsupported}.

finalize_sse(ClientProto, Reason, #sse_st{}) ->
    {ok, [ClientFrame :: iodata()], #sse_st{}}
  %% Reason = normal | {error, binary()} | disconnect
  %% Exactly one terminal: Chat always last frame `data: [DONE]\n\n`;
  %% Anthropic client always last event `event: message_stop`.
  %% If terminal_sent already true, returns {ok, [], St}.
```

Handler process owns `#sse_st{}` (same process as
`janus_usage_head`). Drain callback: `sse_events` then fold
`translate_sse/4`; write frames with `cowboy_req:stream_body/3`.
Usage capture stays on **provider** bytes via `capture_usage_chunk`.

Other mismatched protocol pairs still 400
`stream_requires_native_protocol`. Same-protocol stream is
byte-identical (no translate).

#### 4.1.3 Normative event mapping

Stop reasons:

| Anthropic `stop_reason` | OpenAI `finish_reason` |
|-------------------------|------------------------|
| `end_turn` / `stop_sequence` | `stop` |
| `max_tokens` | `length` |
| `tool_use` | (out of scope — request already 400) |

**Provider Anthropic → client Chat** (upstream `event:` + JSON `data:`):

| Provider event | Client frames |
|----------------|---------------|
| `ping` | skip |
| `message_start` | first `data:` chunk: `id`, `object=chat.completion.chunk`, `model`, `choices[0].delta.role=assistant`; stash `usage.input_tokens` into `in_tokens` |
| `content_block_start` type `text` / `thinking` | skip (record `block_kind`); type `tool_use` or other → `{error, translate_unsupported}` |
| `content_block_delta` `text_delta` | `choices[0].delta.content` |
| `content_block_delta` `thinking_delta` | `choices[0].delta.reasoning_content` |
| `content_block_delta` `signature_delta` | skip (not required for Chat clients) |
| `content_block_stop` | skip |
| `message_delta` | map `stop_reason` → `choices[0].finish_reason`; stash `usage.output_tokens`; if usage known, emit a **separate** empty-choices chunk with `usage` `{prompt_tokens, completion_tokens}` |
| `message_stop` | `data: [DONE]\n\n` via `finalize_sse(..., normal, …)` |
| `error` | see §4.1.4 |

**Provider Chat → client Anthropic:**

| Provider event | Client frames |
|----------------|---------------|
| first chunk with `delta.role` or first content | `event: message_start` (id/model from chunk) then `event: content_block_start` index 0 type `text` |
| `delta.content` | `event: content_block_delta` `text_delta` |
| `delta.reasoning_content` | if current block is not thinking: close text block, `content_block_start` type `thinking`, then `thinking_delta`. **No `signature` field** (Phase 1: Anthropic clients that require signed thinking are unsupported; document) |
| empty-choices usage chunk | stash tokens; do not emit yet |
| `finish_reason` | `content_block_stop`, `event: message_delta` with mapped `stop_reason` + output usage, then `finalize_sse` → `message_stop` |
| `data: [DONE]` | skip if `terminal_sent`; else `finalize_sse` |
| `delta.tool_calls` | `{error, translate_unsupported}` |

`event:` lines are required on the Anthropic client face. Chat client
face is bare `data:` JSON + `[DONE]` — **never** `message_stop`.

#### 4.1.4 Mid-stream error / disconnect (headers already 200)

Once SSE headers are sent, HTTP status stays 200. **Single**
`finalize_sse` on every exit.

| Case | Client Chat frames | Client Anthropic frames | `track` status |
|------|--------------------|-------------------------|----------------|
| `translate_unsupported` after 200 | `data:{"error":{"message":…,"type":"invalid_request_error"}}` then `[DONE]` | `event: error` + JSON `{type:error,error:{type,message}}` then `message_stop` | **400** |
| Drain/upstream failure | same error object, message sanitized | same | **502** |
| Client disconnect | no further frames | no further frames | **502**; **cancel gun** (do not wait idle_timeout) |
| Malformed provider JSON in `data:` | skip + log `janus_translate_sse_bad_json` | skip + log | no extra track |
| Idle no bytes | Cowboy `idle_timeout => 300_000` (unchanged). Long thinking with zero deltas is accepted as idle risk; no keepalive in Phase 1 | same | timeout path = 502 |

Do **not** wait for `collect_drain` on a translating 200 stream.
Unknown extra fields: skip.

#### 4.1.5 Tests

eunit **first**, binary JSON keys, split `data:` across two
`sse_events/2` calls:

- Anthropic `thinking_delta` → Chat `reasoning_content`
- Chat `delta.content` → Anthropic `text_delta` + envelope
- `ping` skip; malformed JSON skip
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
| Terminal `track(Status, …)` with Status ≥ 400 (404 unknown model, 400 translate_unsupported **before** headers, 502, 429, …) | 0 | +1 |
| Handler crash / `{'EXIT',_}` — `try … after` around `do_proxy` body | 0 | +1 if total already +1 |
| Client disconnect mid-stream (`track(502)`) | 0 | +1 (via track) |
| 401 missing/invalid key (never enters `do_proxy`) | 0 | 0 |
| 400 invalid JSON / missing model **before** `do_proxy` | 0 | 0 |

Do **not** overload `track/3` to also mean “total”. Total is
`janus_http_stats:inc_total()` at the one enter site; failed is
`inc_failed()` from `track/3` when Status ≥ 400 **and** from the
`after` crash path (guard: only if this request already counted
total — process dict flag `janus_stats_counted`).

Atomics: **not** process-local. Created once in `janus_http_app`
before Cowboy listeners (`persistent_term`, same pattern as
`janus_usage` drops). `/stats` reads integers; if ref missing
(should not happen after boot order) emit 0. Boot-relative; dashboard
error-rate may jump on restart — accepted, documented on the Nodes
UI as “since process start”.

E2E: after TF-6.1, that node `GET /stats` has `requests_total >= 1`.
A 404 unknown-model (authenticated) increments **both** total and
failed.

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

**Windows / laptop command (the only documented one):**

```bash
docker build --target test -t janus-build:test .
docker run --rm \
  -v F:/Janus:/app \
  -v janus-ebin-otp27:/app/_build \
  -w /app janus-build:test \
  sh -c './rebar3 fmt --check && ./rebar3 eunit'
```

Named volume `janus-ebin-otp27` is OTP-versioned so an OTP bump
does not mix beams. Host `_build` is shadowed.

CRLF: `rebar3 fmt --check` runs on mounted source. If fmt fails on
`\r`, the test image RUN installs `dos2unix` and the documented
command is
`find apps config -name '*.erl' -o -name '*.config' | xargs dos2unix`
only when `fmt --check` reports CR — prefer **git `core.autocrlf=false`
in this repo** (already `.gitattributes` where needed) over rewriting
files. Spec: if `fmt --check` fails solely due to CRLF, treat as
environment bug, not a product test fail; CI `eunit-docker` copies
source into the image (no mount) so it is the source of truth.

GitHub: keep `setup-beam` as primary. Add job `eunit-docker`:
`docker build --target test` then `docker run` **without** source
mount (compile already in the image) `./rebar3 eunit`. Aliyun mirror
inside the image; GitHub runners can reach it. If not, ARG
`APK_MIRROR` defaulting to Aliyun with CI override to Alpine CDN.

There is **no** `rebar3 get-deps` verb; compile fetches as needed.

### 4.4 Slice D: deploy / secret hygiene

Paired PR on `../janus-dashboard/scripts/deploy_prod.sh`.

After leader migration is verified, **before** shifting follower
traffic:

1. Probe each enabled node `GET {stats_url}/stats` with
   `Authorization: Bearer $JANUS_STATS_TOKEN`.
2. Poll every **2s**, deadline **300s** per node.
3. Success = `generation` equals leader’s generation on **two
   consecutive** polls (avoids a single racy read vs dashboard write).
4. Transient HTTP errors retry until deadline.
5. On deadline or 401/token-unhealthy: **halt** the script (do not
   rollback the leader; do not skip a dead follower). Exit non-zero.
6. If dashboard `JANUS_STATS_TOKEN` empty: halt immediately.

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
  translate, drain fold, `finalize_sse`, gun cancel on disconnect
- `../janus-dashboard/docs/TEST-FLOWS.md` — TF-6.8 / 6.8b

Phase 1 B:

- `apps/janus_http/src/janus_http_stats.erl` (new) +
  `janus_http_app.erl` init + `janus_gateway_stats.erl` read +
  `janus_http_proxy.erl` bump sites
- `../janus-dashboard/spa/src/pages/nodes.tsx`

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
   `./rebar3 eunit` succeeds on Windows without fetching
   `dl-cdn.alpinelinux.org`.
4. Deploy script halts if a follower generation is not equal-and-stable
   within 300s or stats token polls fail.

## 9. Order of work

1. Slice C (test image) — unblocks eunit
2. Slice A (streaming translate) — user-visible; paired TEST-FLOWS PR
3. Slice B (counters) — can parallel A after C
4. Slice D (deploy wait) — with the next production ship
5. Stop. New spec for Phase 2.
