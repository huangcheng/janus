# Janus next phase — design spec

Status: draft (awaiting review)
Date: 2026-10-05
Repos: `Janus` (data plane) + `janus-dashboard` (management plane)

This document records the next work after the 2026-10-05 audit-fix
commits (`a57feba` gateway, `8d41e18` dashboard). It is a design spec,
not an implementation plan.

## 1. Goal / non-goals

**Goal:** take the current “usable early production” gateway to a
state where three operator-owned nodes can run Cursor / Claude Code
style **streaming** clients across protocol mismatches, operators can
see **live request health per node**, and Windows/local CI can run
**eunit without hanging on Alpine package fetch**.

**Non-goals (explicit):**

- Re-embedding the dashboard into the Erlang release
- Gateway-to-gateway traffic load balancing (Caddy / DNS stays in front)
- Multi-writer configuration (dashboard remains the sole catalog writer)
- Kubernetes operators, auto-discovery of nodes
- Vision / multimodal translate
- Streaming translate involving `openai_responses`
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
  so CI green ≠ laptop green.
- Production deploy checks generation loosely; gitleaks is CI-only
  (pre-commit hook skipped when the binary is missing).

## 3. Approaches considered

| | Approach | Trade-off |
|---|----------|-----------|
| A | **Streaming only** — unlock mixed-protocol SSE, leave stats/test image | Users feel the win; operators still blind; Windows eunit still flaky |
| B | **Ops only** — counters + prebuilt test image, keep 400 on stream translate | Sleep-at-night ops; Cursor still cannot hit Anthropic providers via Chat SSE |
| C | **Phase 1 bundle (recommended)** — Chat↔Messages streaming translate + node counters + prebuilt test image; small deploy hygiene | Three independent subsystems in one *phase*, each shippable as its own PR; together they match the “industrial enough for us” bar |

**Chosen: C**, sequenced as three PRs so any one can land without the
others. Phase 2 (quotas, LB explain, auto-router audit headers) is
specified below but **must not start** until Phase 1 is green on the
local E2E gate.

## 4. Phase 1 — three shippable slices

### 4.1 Slice A: streaming Chat ↔ Anthropic Messages translate

**Problem.** Native SSE already works. Mixed protocol + `stream:true`
is rejected before the adapter.

**Scope (in):**

- Bidirectional SSE bridge:
  - Client `openai_chat` ↔ provider `anthropic_messages`
  - Client `anthropic_messages` ↔ provider `openai_chat`
- Text deltas, finish/stop reasons, usage on the terminal event
- Thinking: Anthropic `content_block_delta` type `thinking_delta` (and
  full `thinking` blocks) map to OpenAI `delta.reasoning_content`
  (same convention as non-stream translate)
- Basic tools: `tool_calls` / `tool_use` deltas **only if** the
  existing non-stream translator already supports that pair. If a
  construct is `translate_unsupported` today, streaming it stays
  unsupported (400), not a new tool protocol.

**Scope (out):**

- Any path involving `openai_responses`
- Vision / image parts (keep current reject)
- Buffering the entire upstream body then emitting fake SSE (must be
  true incremental; first-byte latency stays Cowboy
  `idle_timeout => 300_000`)

**Architecture.**

```
client SSE  ←→  janus_protocol_translate:translate_sse_chunk/3
                      ↑ drain callback (already used for native)
provider SSE
```

- Keep `call_adapter(..., #{stream => true})` for the **provider**
  protocol (upstream is always native-shaped).
- Replace the `{false, true}` 400 branch in `dispatch/7` with a
  translate-stream path **only** for the two Chat↔Messages pairs.
  Other mismatched pairs still 400 `stream_requires_native_protocol`.
- New pure functions (eunit **first**, production-shaped binaries):
  - `sse_events(Iolist) -> {Events, Rest}` — parse SSE, hold partial frames
  - `translate_sse(ClientProto, ProviderProto, Event) ->
        {ok, [ClientEvent]} | skip | {error, translate_unsupported}`
- State in the Cowboy handler process (same as today’s
  `janus_usage_head` / tail): leftover bytes, open content-block
  index, whether an assistant role/chunk was opened.
- Client disconnect: same as native — drain error → `track(502)`,
  cooldown, do not crash the handler.
- Usage: reuse `capture_usage_chunk` on **provider** bytes, then
  `janus_usage_parse` for the provider protocol (already keyed that
  way). Do not parse translated client SSE for tokens.

**Error handling.**

| Case | Behavior |
|------|----------|
| Unknown / extra SSE fields | skip event (do not 400 mid-stream) |
| Malformed JSON in `data:` | skip + log `janus_translate_sse_bad_json` |
| Mid-stream translate_unsupported (e.g. image) | stop drain, send one client error frame if none sent; else close; `track(400)` |
| Upstream 4xx with stream framing | existing `collect_drain` then non-stream error translate |
| Idle no bytes | Cowboy idle_timeout (unchanged) |

**Invariants.**

- Same-protocol `stream:true` path is byte-identical to today
  (no extra translate).
- Non-stream translate path unchanged.
- Never use `case Map of #{}` for emptiness; `map_size/1`.
- JSON keys in fixtures are binaries.

**Tests.**

- eunit: fixture SSE frames (OpenAI chunk, Anthropic
  `message_start` / `content_block_delta` / `message_delta` /
  `message_stop`) → expected client frames. Include thinking →
  `reasoning_content`. Include a split frame across two drain
  callbacks (partial `data:` line).
- Local E2E (TEST-FLOWS): new step under TF-6:
  **6.8** Chat client `stream:true` against an Anthropic-bound
  public name → SSE chunks + `[DONE]` (or Anthropic `message_stop`)
  and a usage row `stream=1`.
- Browser: not applicable (data plane).

### 4.2 Slice B: node request counters on `/stats`

**Problem.** Dashboard SPEC §2.4 already documents:

```json
"requests_total": 12345,
"requests_failed": 67
```

Gateway `janus_gateway_stats` does not emit them. SPA `Node.health`
already has optional `requests_total` / `requests_failed`.

**Scope (in):**

- Process-local **atomics** counters (pattern: `janus_usage` drop
  atomics in persistent_term), since boot:
  - `requests_total` — every request that passed agent auth and
    entered `do_proxy` / models list / health on the **data**
    listener is too broad. Count **proxied LLM calls only**
    (`janus_http_proxy` after auth + JSON parse succeeded, i.e. we
    attempted routing). `GET /v1/models` is not a request for this
    counter.
  - `requests_failed` — those calls whose recorded usage/track
    status is `>= 400` or adapter `{error, _}` / crash / mid-stream
    502. Auth 401s **before** proxy are **not** counted (not our
    upstream failure).
- `GET /stats` JSON adds `requests_total` and `requests_failed`
  as integers. Keep `usage` / `usage_writer`.
- Dashboard Nodes table shows the two numbers from the existing
  health poll spread (`**data`). No new API.

**Scope (out):**

- Prometheus / OpenTelemetry
- Cross-node aggregation (dashboard already polls N times)
- Reset/persist across VM restart (boot-relative is enough)

**Error handling.** Missing atomics ref (stats before proxy init) →
emit `0`. Never crash `/stats`.

**Tests.**

- eunit on a small `janus_http_stats` (or functions on
  `janus_gateway_stats`) with production-shaped maps; bump + read.
- Local E2E: after TF-6.1, `GET /stats` on that node has
  `requests_total >= 1`. A 404 unknown-model call increments
  `requests_failed`.

### 4.3 Slice C: prebuilt test/compile image (fix “apk hang”)

**Problem.** `apk` here is **Alpine Package Keeper**, not Android.
`erlang:27-alpine` has no `cc`; esqlite NIF needs `build-base`.
Fetching `dl-cdn.alpinelinux.org` from this network stalls. The
production `Dockerfile` already does:

```
sed -i 's#https://dl-cdn.alpinelinux.org#https://mirrors.aliyun.com#g' /etc/apk/repositories
apk add --no-cache git build-base
```

Ad-hoc `docker run erlang:27-alpine apk add …` does not, so local
eunit dies.

**Scope (in):**

- Extend the existing `Dockerfile` with a named stage `test` (or
  `build` reused): OTP 27, git, build-base, **aliyun apk mirror**,
  `rebar3 get-deps` + compile of default profile. Tag
  `janus-build:test`.
- Document in README the **only** local compile/eunit command:

  ```bash
  docker build --target test -t janus-build:test .
  docker run --rm -v F:/Janus:/app -w /app janus-build:test \
    sh -c './rebar3 fmt --check && ./rebar3 eunit'
  ```

  Local Windows: mount source at `/app` and a **named volume** for
  `/app/_build` so host `_build` (wrong ABI) never shadows the
  image. CI `eunit-docker` copies source into the image and does
  not mount.
- Optional: GitHub `ci.yml` stays on `setup-beam` (Linux runners
  have gcc). Add a **second** job `eunit-docker` that builds
  `--target test` so the image recipe cannot rot. Not a replacement
  for setup-beam.
- Never document raw `apk add` in README again.

**Scope (out):**

- Replacing CI’s setup-beam as the primary job
- Publishing `janus-build` to GHCR unless it is cheap (optional
  follow-up; not required to close the hang)

**Tests.** `docker build --target test` succeeds; container
`./rebar3 eunit` exits 0 on a known-green tree.

### 4.4 Slice D (small, same phase): deploy / secret hygiene

Not a product feature. Do with C or immediately after:

- Install/document gitleaks pre-commit (CI workflow already exists).
- `deploy_prod.sh`: after leader migration, **wait until each
  follower `/stats.generation` equals leader** (timeout + fail)
  before shifting traffic. Read-only smoke already exists; this is
  the missing barrier.
- Confirm `JANUS_STATS_TOKEN` is set on dashboard **and** all three
  gateways (fail the deploy script if dashboard poll returns the
  “token required” unhealthy we added).

No schema changes.

## 5. Phase 2 — after Phase 1 E2E is green

Specified so it is not forgotten; **no implementation until Phase 1
done**. Each item is its own future spec.

### 5.1 Agent-key quotas (RPM / TPM / daily cap)

- Dashboard writes limits on `api_keys` (new columns or JSON).
- Gateway hot path: atomics or ETS sliding window per key id after
  auth; 429 with `retry-after`.
- Usage page already has `by_key`; this is **enforcement**.
- Failure modes: clock skew, multi-node (per-node limits first,
  not global — global needs Redis or Postgres; out of scope even
  for Phase 2 v1).

### 5.2 LB explainability (read-only)

- Extend `GET /stats` with a compact snapshot: cooldown targets +
  remaining ms, not full ETS dumps.
- Dashboard Nodes or Router: “why cooling / which key”.
- Must not call `pick_route` speculatively (already an invariant).

### 5.3 janus-auto audit trail

- On a successful auto route, expose `routed_to`, `tier`,
  `origin ∈ {rules, judge, fallback}` without breaking OpenAI /
  Anthropic JSON.
- Preferred: **response header** `x-janus-route: name;tier=fast;origin=rules`
  (clients ignore unknown headers). Optional echo inside usage
  `fields` only, not inside `choices` (would confuse agents).
- Restricted keys: header still OK; do not leak judge raw text.

## 6. Testing rules (project-wide)

Copied from `AGENTS.md`; all Phase 1 work obeys them:

- No unit tests written *after* production code. Parsers/SSE
  translate: eunit **first**, binary JSON keys, SMALLINT 0/1.
- Local E2E `../janus-dashboard/scripts/e2e_local.sh` is the
  acceptance gate. Production only read-only smoke.
- Compile/eunit on Windows via the Slice C image, never host OTP.
- Durable artifacts for E2E (logs, PASS/FAIL list).

## 7. File touch map (indicative)

Phase 1 A:

- `apps/janus_http/src/janus_protocol_translate.erl` — SSE parse +
  event translate
- `apps/janus_http/test/janus_protocol_translate_tests.erl` — eunit
  first
- `apps/janus_http/src/janus_http_proxy.erl` — `dispatch/7` branch
- `../janus-dashboard/docs/TEST-FLOWS.md` — TF-6.8

Phase 1 B:

- New small module or `janus_gateway_stats.erl` + bump from
  `janus_http_proxy.erl` `track/3`
- `spa/src/pages/nodes.tsx` — show the two numbers if still unused

Phase 1 C:

- `Dockerfile` (`test` stage)
- `README.md`
- `.github/workflows/ci.yml` (optional docker eunit job)

Phase 1 D:

- `../janus-dashboard/scripts/deploy_prod.sh`

## 8. Success criteria

Phase 1 is done when **all** of:

1. Chat `stream:true` to an Anthropic-bound name returns incremental
   SSE (local E2E TF-6.8 green).
2. Native same-protocol streaming still passes TF-6.4.
3. `GET /stats` includes `requests_total` and `requests_failed`;
   dashboard node row shows them.
4. `docker build --target test -t janus-build:test .` then
   `./rebar3 eunit` in that image succeeds on the Windows host
   without a raw `apk add` from `dl-cdn.alpinelinux.org`.
5. Deploy script refuses to continue if follower generation lags or
   stats token polls fail.

## 9. Order of work

1. Slice C (test image) — unblocks every later eunit on this machine
2. Slice A (streaming translate) — user-visible
3. Slice B (counters) — small, independent, can parallel with A
   after C
4. Slice D (deploy wait) — with the next production ship
5. Stop. New spec for Phase 2.
