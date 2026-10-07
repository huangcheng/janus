# OpenAI Decisions API — design spec

Status: draft (pre–xray audit)  
Date: 2026-10-07  
Repos: `Janus` (data plane) + `janus-dashboard` (management plane)  
Upstream reference: https://developers.openai.com/api/docs/guides/decisions (public beta)

This is a **design spec**, not an implementation plan. It records product
decisions from the 2026-10-07 brainstorming thread. Implementation plans
come after this file is approved and `xray spec`-clean.

## 1. Goal / non-goals

**Goal:** Janus exposes OpenAI’s Decisions face as a **native passthrough**
agent endpoint so clients can call `POST /v1/decisions` through the
gateway with the same auth, catalog, LB, usage, and metrics plumbing as
Chat / Responses / Messages — without inventing Decisions semantics on
top of other protocols.

**Non-goals (explicit):**

- Full protocol **translate matrix** involving Decisions
  (chat ↔ Decisions, Responses ↔ Decisions, Anthropic ↔ Decisions)
- **Polyfill / system-prompt layer** that asks chat or Responses models
  to emit Decisions-shaped `answers[]` (not a gateway responsibility)
- Emulating Decisions probability / confidence / score distributions
- Stateful Decisions features beyond what OpenAI’s wire supports today
  (none documented as gateway-owned)
- Making Decisions a `janus-auto` adjudication target
- Streaming Decisions (OpenAI’s public guide shows non-stream
  `decisions.create` only; see §5.4)
- Claiming strict OpenAI SDK conformance for unrelated faces (out of scope)

**Product decisions already locked:**

| # | Decision |
|---|----------|
| D1 | Native passthrough only (approach: fourth agent face on existing proxy) |
| D2 | Fail closed unless provider protocol is Decisions-native |
| D3 | Decisions listings appear in `GET /v1/models` (OpenAI-aligned: one catalog; wrong endpoint fails at request time) |
| D4 | No system-prompt polyfill on other protocols |

## 2. What Decisions is (upstream facts)

From OpenAI’s Decisions guide (verified 2026-10-07):

- Endpoint: **`POST /v1/decisions`** (dedicated; not Chat or Responses)
- Public beta; currently only model id **`gpt-6-luna`**
- Request: `model` + `input` (string **or** user messages with
  `input_text` / `input_image`) + `questions[]`
- Question types: `predicate` → `probability`; `choice` → `choice` +
  `probabilities` + `confidence`; `score` → weighted `score` +
  `probabilities` + `confidence`; plus `refusal` answers
- Images: **inline base64 data URLs only** (no hosted HTTP URLs / `file_id`)
- Pricing (Luna on this endpoint): input-token oriented; guide states no
  output-token charge on `/v1/decisions` (distinct from Luna on chat/responses)
- OpenAI model catalog: same id may appear on multiple endpoints; clients
  choose the face. There is **no** separate Decisions models list API.

Janus implication: Decisions is a **new wire face + provider protocol**,
not a chat dialect and not a modality blob (`/v1/images/...`).

## 3. Approaches considered

| | Approach | Trade-off |
|---|----------|-----------|
| A | **Fourth agent face on `janus_http_proxy`** (chosen) | Reuses auth/LB/usage/metrics; touches protocol enum end-to-end |
| B | Modality-style `janus_m_decisions` side path | Duplicates plumbing; wrong abstraction (model catalog face) |
| C | Identity stubs inside `janus_protocol_translate` matrix | Implies a matrix we rejected; future foot-gun |

**Chosen: A.**

## 4. Architecture

### 4.1 Protocol atom

Wire / DB / catalog string: **`openai_decisions`**  
Erlang atom: **`openai_decisions`**

Normalize in `janus_protocol_translate:normalize_protocol/1` (and any
seed / dashboard validators) alongside the existing three.

**Do not** add `do_translate_request/3` or `do_translate_response/3`
clauses for Decisions × {chat, responses, anthropic}. Cross-protocol
pairs remain `{error, {translate_unsupported, _}}` / proxy hard-reject
**before** translate (preferred: reject in `dispatch` when either side
is Decisions and `ClientProto =/= ProviderProto`).

### 4.2 Agent route

| Path | Handler | Client proto passed to proxy |
|------|---------|------------------------------|
| `POST /v1/decisions` | `janus_http_decisions` (new; mirror `janus_http_responses`) | `openai_decisions` |

Auth: Bearer agent key (same as Chat/Responses).  
Body size limit: same class as Responses (`?MAX_BODY`).  
Request id: echo `x-request-id` like other agent endpoints.

Cowboy route registration in `janus_http_sup.erl`.  
Classify: `janus_http_classify` → `endpoint => decisions`,
`protocol => openai_decisions`.

### 4.3 Provider catalog

- Migration: extend `providers.protocol` CHECK to include
  `'openai_decisions'` (Postgres + SQLite flat + tree copies).
- Dashboard: `PROTOCOLS` / `JanusProtocol` / labels / OpenAI preset
  endpoint map gain `openai_decisions` → typically
  `https://api.openai.com/v1` (same host as chat/responses; path chosen
  by gateway when forwarding).
- Seed / entitlements / provider key probe: Decisions providers are
  probed with a minimal `POST {base}/decisions` (not chat/completions).

Upstream forward path: `{provider.base_url}/decisions` (after
normalizing trailing slash), Authorization from provider key — same
pattern as chat → `/chat/completions`, responses → `/responses`,
messages → `/messages`.

### 4.4 Model surface (`GET /v1/models`)

Per D3 / OpenAI:

- Decisions provider listings sync into `provider_models` and may be
  bound or called by listing name like other protocols.
- They **appear** in agent `GET /v1/models` (subject to existing
  `api_key_models` grants).
- Listing in `/v1/models` **does not** imply the name is valid on every
  face — only that the catalog knows it.

### 4.5 Routing and fail-closed rules

LB already supports `prefer_proto` for streaming same-protocol bias.
Decisions inherits the same preference for **all** Decisions client
requests (stream or not): prefer `openai_decisions` routes.

**Hard rules:**

1. **Decisions client + non-Decisions provider** → **400**
   `protocol_requires_native` (or reuse `translate_unsupported` with a
   stable message). Never translate.
2. **Non-Decisions client + Decisions-only route pick** → **400** same
   class. Do not forward a Chat body to `/v1/decisions` or invent a
   reshape.
3. Prefer filtering Decisions routes out of Chat/Responses/Messages
   picks when **any** same-face route exists; when the **only** routes
   for a name are Decisions, wrong-face clients still get (2), not a
   silent polyfill.
4. **`janus-auto`:** must **never** select `openai_decisions` routes.
   Auto issues chat-shaped judge/target calls. Dashboard Router tier
   pickers should exclude or warn on Decisions listings (management
   plane). Gateway defense-in-depth: skip Decisions protocol in auto
   candidate sets.

### 4.6 Proxy behavior (native path)

When `ClientProto =:= ProviderProto =:= openai_decisions`:

- Passthrough request JSON (rewrite `model` to upstream listing name
  as today).
- Non-stream HTTP POST to upstream `/decisions`.
- Return upstream status + body (error reshape only as for other native
  faces — do not invent Decisions error envelopes).
- No SSE translate path required for v1.

### 4.7 Streaming

OpenAI’s published Decisions examples are non-stream. For v1:

- If client sends `"stream": true`, **400**
  `stream_not_supported` (Decisions face) — fail closed rather than
  ignoring.
- Do not add Decisions to `stream_translate_*` machinery.

If OpenAI later documents Decisions SSE, a follow-up spec owns that.

## 5. Usage, metrics, entitlements

### 5.1 Usage rows

- `protocol` column stores `openai_decisions`.
- Token parse: reuse / extend `janus_usage_parse` to read a top-level
  `usage` object if present (`input_tokens` / `output_tokens` or
  OpenAI’s published Decisions usage fields once pinned against a live
  response). If upstream omits usage, record null/absent tokens — do
  **not** invent counts.
- Cost semantics stay operator/dashboard-side; do not hardcode Luna’s
  “input-only” price in the gateway.

### 5.2 Metrics

- `requests_total` / duration histograms gain endpoint label
  `decisions` and protocol `openai_decisions` (closed enums only —
  update classify + any dashboard expectations in TEST-FLOWS / SPEC).

### 5.3 Provider entitlements / test-key

Dashboard `entitlements.py` and provider test probes need a Decisions
branch: success = HTTP 200 (or documented OpenAI error that proves auth
+ route reachability — pin in implementation plan against a live
`gpt-6-luna` call).

## 6. Dashboard / dual-repo

Paired changes:

| Area | Change |
|------|--------|
| Gateway | Route, protocol, migration, proxy reject, usage/metrics, seed allow-list |
| Dashboard | Protocol enum + UI label, OpenAI preset, probe/entitlement, Router/auto warnings, TEST-FLOWS |

No Decisions translate knobs (unlike `tools-stream` / `responses-stream`).

## 7. Testing (acceptance)

Local E2E only (AGENTS.md). Suggested flows (names illustrative; final
numbers land in `janus-dashboard/docs/TEST-FLOWS.md` at plan time):

| Flow | Assert |
|------|--------|
| TF-D.1 | Provider `openai_decisions` + listing; `POST /v1/decisions` native 200 with `answers[]` |
| TF-D.2 | Same model name on `/v1/chat/completions` → 400 `protocol_requires_native` (or no_route if no chat route) |
| TF-D.3 | Chat-only model on `/v1/decisions` → 400 same class |
| TF-D.4 | Listing visible on `GET /v1/models` when granted |
| TF-D.5 | `stream: true` on Decisions → 400 |
| TF-D.6 | Usage row `protocol=openai_decisions` after D.1 |
| TF-D.7 | `janus-auto` never selects Decisions provider (unit or e2e with mixed catalog) |

Browser: Providers page shows protocol **OpenAI Decisions**; create
provider + probe. No translate knobs for Decisions.

Fixture realism: eunit only for pure helpers (classify, normalize,
reject predicates) with production-shaped binaries — not a fake
Decisions polyfill suite.

## 8. Failure modes to guard (pre-code)

1. Chat client silently hitting a Decisions upstream via fallback
   `prefer_proto` widening → **must 400**
2. Auto-router picking Luna Decisions listing → chat-shaped upstream
   call → **exclude protocol**
3. Translating Decisions through chat “for convenience” → **forbidden**
4. Assuming usage always present → null-safe parse
5. Treating Decisions as modality → wrong auth/LB path
6. Stale CHECK constraint blocking insert of `openai_decisions` providers
7. Docs/README claiming translate matrix includes Decisions

## 9. Rollout

1. Spec approval + `xray spec` clean (this document)
2. Implementation plan (`writing-plans`) with dual-repo tasks
3. Gateway migration + handler + reject paths
4. Dashboard enum + probe + TEST-FLOWS
5. Local e2e green with real OpenAI Decisions upstream (or recorded
   mock only if OpenAI unavailable — prefer real Luna for D.1)
6. Deploy via existing `deploy_prod.sh` gate; production smoke remains
   read-only (no mutating Decisions tests in `--smoke`)

## 10. Open points (pin before or during plan)

| ID | Question | Default if unresolved |
|----|----------|------------------------|
| O1 | Exact OpenAI Decisions response `usage` schema (live capture) | Parse best-effort; null if absent |
| O2 | Error code string: new `protocol_requires_native` vs reuse `translate_unsupported` | Prefer **new** code for clarity |
| O3 | Whether a single OpenAI provider row can be dual-protocol (chat + decisions) | **No** — one protocol per provider row (create a second provider or separate key row pointing at same base_url with `openai_decisions`) |
| O4 | Upstream path join if `base_url` already ends with `/v1` | Same helper as other faces |

## 11. Spec self-review checklist

- [x] No full translate matrix
- [x] No polyfill
- [x] `/v1/models` inclusion (D3)
- [x] Fail-closed wrong face
- [x] Dual-repo called out
- [x] janus-auto exclusion
- [x] Streaming stance for v1
- [x] Migration / dashboard enum
- [ ] Live usage schema pinned (O1 — deferred to plan with capture)
- [ ] xray audit applied (next step)
