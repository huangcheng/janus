# OpenAI Decisions API — design spec

Status: draft (xray round 2 candidate — round-1 GO WITH FIXES folded; splits closed)  
Date: 2026-10-07  
Repos: `Janus` (data plane) + `janus-dashboard` (management plane)  
Upstream reference: https://developers.openai.com/api/docs/guides/decisions (public beta)  
Audit round 1: `docs/superpowers/audit/2026-10-07-openai-decisions-design-synthesis.md`

This is a **design spec**, not an implementation plan. Product decisions
come from the 2026-10-07 brainstorming thread; C1–C8 and closed splits
(S1–S3) from xray round 1 are folded in below. Implementation plans
follow after a clean `xray doc` GO and user approval.

## 1. Goal / non-goals

**Goal:** Janus exposes OpenAI’s Decisions face as a **native passthrough**
agent endpoint so clients can call `POST /v1/decisions` through the
gateway with the same auth, catalog, LB, usage, and metrics plumbing as
Chat / Responses / Messages — without inventing Decisions semantics on
top of other protocols.

**Non-goals (explicit):**

- Full protocol **translate matrix** involving Decisions
- **Polyfill / system-prompt layer** that asks chat/Responses/Anthropic
  models to emit Decisions-shaped `answers[]`
- Emulating Decisions probability / confidence / score distributions
- Stateful Decisions features beyond OpenAI’s wire
- Making Decisions a `janus-auto` adjudication target
- Streaming Decisions in v1 (see §4.7)
- **Face-level enable knob** `decisions.enabled` (S1 closed: Decisions
  is an agent face like Chat/Responses/Messages, which have no such
  knob; modality knobs stay modality-only)
- Dual-protocol provider rows / per-face catalog `face` tags in v1
  (S2 closed: keep one protocol per provider row)
- Claiming strict OpenAI SDK conformance for unrelated faces

**Product decisions locked:**

| # | Decision |
|---|----------|
| D1 | Native passthrough only (fourth agent face on existing proxy) |
| D2 | Fail closed unless provider protocol is Decisions-native |
| D3 | Decisions listings appear in `GET /v1/models` |
| D4 | No system-prompt polyfill |
| D5 | Wrong-face error code = **`protocol_requires_native`** (both directions) |
| D6 | One protocol per provider row; dual-face OpenAI = two provider rows |
| D7 | `prefer_proto` is **not** the Decisions eligibility mechanism |
| D8 | No `decisions.enabled` face knob |
| D9 | Wrong-face never uses `wrong_modality` (S3) |
| D10 | `api_key_models` grants stay **by public model name**; protocol eligibility still blocks wrong face |

## 2. Upstream facts (guide + fixture gate)

**Guide facts** (docs read 2026-10-07):

- Endpoint: `POST /v1/decisions`
- Public beta; model id currently `gpt-6-luna`
- Request: `model` + `input` (string or user messages with
  `input_text` / `input_image`) + `questions[]`
- Answers: `predicate` / `choice` / `score` / `refusal` shapes as in
  the guide excerpts
- Images: inline base64 data URLs only
- No separate Decisions models-list API
- Guide pricing: input-oriented on `/v1/decisions`

**Live capture status:** an environment `OPENAI_API_KEY` was tried on
2026-10-07 and returned `invalid_api_key`; **no live fixture is
committed**. Plan task 0 (blocking before coding TF-D.1/D.6 parsers
beyond null-safe stubs) is: operator supplies a valid OpenAI key and
captures request+response to
`apps/janus_http/test/fixtures/probes/openai_decisions.json`. Until
then:

- Success body **must** include `answers` (array) per guide
- `usage` is **optional**; if present, parse OpenAI-shaped
  `input_tokens` / `output_tokens` (and ignore unknown keys); if
  absent, store null tokens and set `usage_missing` observability
- Do not invent `answers` or token counts

## 3. Approaches considered

| | Approach | Trade-off |
|---|----------|-----------|
| A | **Fourth agent face on `janus_http_proxy`** (chosen) | Reuses auth/LB/usage/metrics |
| B | Modality-style plugin | Wrong abstraction |
| C | Translate-matrix identity stubs | Rejected with D4 |

**Chosen: A.**

## 4. Architecture

### 4.1 Protocol atom

Wire / DB string and Erlang atom: **`openai_decisions`**.

Normalize in `janus_protocol_translate:normalize_protocol/1` and seed /
dashboard validators. **Do not** add any
`do_translate_request/3` / `do_translate_response/3` clauses for
Decisions pairs.

### 4.2 Agent route and handler boundary

| Path | Handler | Client proto |
|------|---------|--------------|
| `POST /v1/decisions` | `janus_http_decisions` | `openai_decisions` |

**Mirror boundary (explicit):** copy from `janus_http_responses` **only**
auth (`require_agent`), body size limit (`?MAX_BODY = 10 * 1024 * 1024`),
JSON-only body, `x-request-id` resolve/echo, and the
`janus_http_proxy:handle(Proto, …)` handoff. **Do not** copy Responses
SSE, translate knobs, `previous_response_id` rejects, or Responses-
specific stream gates into this handler.

Classify: `endpoint => decisions`, `protocol => openai_decisions`.
Include `/v1/decisions` in agent request-id echo scope.

Wrong-face **error body** (stable contract):

```json
{
  "error": {
    "message": "<stable English string>",
    "type": "janus_error",
    "code": "protocol_requires_native"
  }
}
```

Same envelope for `stream_not_supported` with that code. Message text
pinned at implementation to one string per code (both directions share
`protocol_requires_native`).

### 4.3 Provider catalog, migration, probe

- CHECK: add `'openai_decisions'` to `providers.protocol` (Postgres +
  SQLite flat + tree). Update seed allow-list + dashboard
  `PROTOCOLS` / `JanusProtocol` / labels. OpenAI preset:
  `openai_decisions` → `https://api.openai.com/v1`.
- **Rollout:** migrate **all** gateway nodes (CHECK + beams) **before**
  dashboard writes Decisions providers. Generation bump after catalog
  load. **Rollback = `enabled=0` on those providers**, never reverse DDL.
- Forward: `{base_url}/decisions` via existing path-join helper.
- **Probe:** `POST {base}/decisions`, minimal-cost JSON (short text
  `input`, one `predicate` question, model = operator’s listing name or
  `gpt-6-luna`). Outcome classes:
  - OK: **200**, or **400** JSON proving Decisions validated the body
  - Bad key: **401** / **403**
  - Not Decisions / unreachable: **404** / **405** / connect error  
  Probes that return 200 may bill Luna Decisions; UI copy must say so.

### 4.4 Models list and multi-face names

- Sync: existing `GET {base}/models` (or provider sync) stamped with
  **provider-row protocol**.
- `/v1/models`: one entry per public **name** (existing union).
- Same upstream id on chat + Decisions ⇒ two provider rows (D6);
  name may appear once in the union.
- Grants: **by name** (D10). A grant for `gpt-6-luna` authorizes the
  name on any face the catalog can route; **wrong face still 400
  `protocol_requires_native`** when no eligible protocol route exists.
  Per-face grants are a non-goal for v1.

### 4.5 Fail-closed routing

**LB candidate-set filter (primary):**

- Client `openai_decisions` → only `openai_decisions` provider routes
- Client chat / responses / messages → **exclude** `openai_decisions`
- Empty set → **400 `protocol_requires_native`**

**Dispatch second line:** if either side is `openai_decisions` and
`ClientProto =/= ProviderProto` → same 400 before translate.

`prefer_proto` unchanged for the other three faces’ streaming bias; not
used for Decisions eligibility.

**vs `wrong_modality`:** modality gate only on modality endpoints.
Decisions wrong-face uses **only** `protocol_requires_native` (D9).

**janus-auto:**

1. Gateway: exclude `openai_decisions` at auto candidate-set build
2. Dashboard: Router tier pickers **hard-block** Decisions listings

### 4.6 Native proxy path

When both sides are `openai_decisions`: passthrough JSON (rewrite
`model` to upstream listing name), non-stream POST `/decisions`, return
upstream status/body. No SSE. Upstream timeout: same Cowboy
`idle_timeout` class as other agent faces.

### 4.7 Streaming

In `janus_http_decisions` **before** `proxy:handle`: if `"stream": true`
→ **400 `stream_not_supported`**. No Decisions entries in stream-
translate machinery.

## 5. Usage, metrics, entitlements

### 5.1 Usage

- Store `protocol = openai_decisions`.
- After fixture capture: assert exact usage field names in TF-D.6.
- Until capture: additive null-safe parser — if `usage` missing, null
  tokens + `usage_missing` log/metric; if present, map known token
  fields only; never fabricate zeros for absent keys.
- No hardcoded Luna prices in the gateway.

### 5.2 Metrics closed enums

| Dimension | New value | Update sites |
|-----------|-----------|--------------|
| `endpoint` | `decisions` | classify, metrics docs, dashboard SPEC/TEST-FLOWS |
| `protocol` | `openai_decisions` | same |

Additive labels; pre-ship check that scrapes accepting unknown labels
still work.

### 5.3 Entitlements UI

Surface probe outcome classes from §4.3; 400-validation ≠ provider down.

## 6. Dashboard / dual-repo

| Plane | Work |
|-------|------|
| Gateway | Route, protocol, migration, LB filter, dispatch reject, usage/metrics, auto filter, seed |
| Dashboard | Protocol enum/label/preset, probe, Router hard-block, error map, TEST-FLOWS, SPEC |

O3 ops cost: duplicate provider/key UX for chat+Decisions on one OpenAI
account — accepted; optional later “copy provider” helper is plan-nice-
to-have, not v1-required.

No translate knobs. No face enable knob (D8).

## 7. Testing

Local E2E only. Final ids in `TEST-FLOWS.md` (TF-N). Gates:

| Flow | Assert |
|------|--------|
| TF-D.1 | Native `POST /v1/decisions` → 200 + `answers` (live Luna or replay of captured fixture) |
| TF-D.2 | Decisions-only name on `/v1/chat/completions` → **400 `protocol_requires_native`** |
| TF-D.3 | Chat-only name on `/v1/decisions` → **400 `protocol_requires_native`** |
| TF-D.4 | Granted name on `/v1/models`; denied key omits it |
| TF-D.5 | `stream:true` → **400 `stream_not_supported`** |
| TF-D.6 | Usage row `protocol=openai_decisions`; token fields match fixture (null OK if fixture has no usage) |
| TF-D.7 | E2E: janus-auto mixed catalog never picks Decisions |
| TF-D.8 | Regression: other faces’ picks unchanged when an unrelated Decisions provider exists |

Browser: Providers protocol **OpenAI Decisions**; probe; Router cannot
add Decisions to auto tiers.

Eunit: classify, normalize, LB eligibility predicates only — production-
shaped binaries.

## 8. Failure modes

1. Wide candidate sets → Decisions upstream on chat → prevented by LB filter + dispatch
2. Auto picks Decisions → prevented both layers
3. Translate polyfill → forbidden
4. Fabricated usage zeros → forbidden
5. Modality path misuse → forbidden
6. Dashboard write before CHECK migration → sequenced in §9
7. Same-name multi-face wrong pick → eligibility filter
8. Handler accidentally grows Responses SSE/translate → mirror boundary §4.2

## 9. Rollout

1. Clean `xray doc` GO + user approval of this spec
2. **Plan task 0:** live fixture capture with valid OpenAI key →
   `apps/janus_http/test/fixtures/probes/openai_decisions.json`; pin
   usage field names for TF-D.6
3. `writing-plans` dual-repo implementation plan
4. Gateway CHECK migration on all nodes → generation bump
5. Handler + LB + dispatch + usage/metrics + auto filter
6. Dashboard enum/probe/Router block/TEST-FLOWS
7. Local e2e green
8. `deploy_prod.sh`; `--smoke` stays read-only (no Decisions mutations)

## 10. Open points

| ID | Status |
|----|--------|
| O1 | **Deferred to plan task 0** (capture) — parse contract already pinned null-safe in §2/§5.1 |
| O2 | **Resolved** — `protocol_requires_native` |
| O3 | **Resolved** — one protocol per row |
| O4 | **Resolved** — shared path-join helper |
| S1 | **Resolved** — no face knob (D8) |
| S2 | **Resolved** — no schema face tag in v1 |
| S3 | **Resolved** — no `wrong_modality` for this case (D9) |

## 11. Spec self-review

- [x] No translate matrix / polyfill / face knob
- [x] Hard LB eligibility + dispatch reject
- [x] Single wrong-face code + body shape
- [x] Probe / migration / multi-face / auto / usage / metrics pinned
- [x] Handler mirror boundary explicit
- [x] Grant-by-name + wrong-face still fail-closed
- [x] E2E-only TF-D.7; regression TF-D.8
- [x] Round-1 splits closed in-spec
- [ ] Live fixture on disk (plan task 0 — blocked on operator OpenAI key)
- [ ] xray round 2 GO
