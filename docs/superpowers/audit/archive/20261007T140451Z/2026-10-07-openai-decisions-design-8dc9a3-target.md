# OpenAI Decisions API — design spec

Status: draft (xray round-3 candidate — rounds 1–2 GO WITH FIXES folded)  
Date: 2026-10-07  
Repos: `Janus` (data plane) + `janus-dashboard` (management plane)  
Upstream: https://developers.openai.com/api/docs/guides/decisions (public beta)  
Audits:  
- round 1: `docs/superpowers/audit/2026-10-07-openai-decisions-design-synthesis.md`  
- round 2: `docs/superpowers/audit/2026-10-07-openai-decisions-design-8dc9a3-synthesis.md`

Design spec only. Implementation follows a clean `xray doc` GO + user OK.

## 1. Goal / non-goals

**Goal:** Native passthrough `POST /v1/decisions` on the existing agent proxy
(auth, catalog, LB, usage, metrics) — no invented Decisions semantics on
other protocols.

**Non-goals:**

- Translate matrix or system-prompt polyfill for Decisions
- Emulating probability / confidence / score distributions
- `janus-auto` targeting Decisions
- Streaming Decisions in v1
- Face knob `decisions.enabled` (agent faces have none; modality knobs stay modality-only)
- Dual-protocol provider rows / catalog `face` tags / per-face grants in v1
- Changing `/v1/models` to carry protocol hints (stays name-union)

**Locked decisions:**

| # | Decision |
|---|----------|
| D1 | Fourth agent face on `janus_http_proxy` |
| D2 | Fail closed unless provider protocol is `openai_decisions` |
| D3 | Listings appear in `GET /v1/models` (name union, no face hint) |
| D4 | No polyfill / no translate clauses |
| D5′ | Error **precedence** (revises single-code-only D5): see §4.5 |
| D6 | One protocol per provider row |
| D7 | `prefer_proto` ≠ Decisions eligibility |
| D8 | No face enable knob |
| D9 | Never `wrong_modality` for Decisions wrong-face |
| D10 | Grants by public **name**; wrong-face still fail-closed; grant-widening is accepted risk (§4.4) |
| D11 | TF-D.1 authoritative regime = **replay** of committed fixture; live Luna optional soak |
| D12 | Body cap stays **10 MiB** (`?MAX_BODY`); oversized → **413** same envelope as other faces |
| D13 | Guide-excerpt fixture committed now; sanitized **live** fixture is ship gate for production TF-D.1/D.6 field asserts |

## 2. Upstream contract

**Guide (2026-10-07):** `POST /v1/decisions`; model `gpt-6-luna` (beta);
`model` + `input` + `questions[]`; answers `predicate`|`choice`|`score`|`refusal`;
images = inline base64 only; no Decisions-only models list API; input-oriented pricing on this endpoint.

**Committed shape corpus (not live):**
`apps/janus_http/test/fixtures/probes/openai_decisions.guide-excerpts.json`
— illustrative `answers` excerpts from the OpenAI guide for eunit + local
mock replay.

**Live fixture (ship gate):**
`apps/janus_http/test/fixtures/probes/openai_decisions.json` — sanitized
live capture. **Required before** calling TF-D.1/D.6 “production-green”
and before pinning usage field names beyond null-safe rules. Redaction
acceptance: strip `Authorization`, org/project/account ids, billing-
identifying headers; gitleaks clean. Until on disk: local e2e may replay
**guide excerpts** via mock upstream only; do not claim live conformance.

**Usage parse (until live pin):** `usage` optional. If absent → null tokens
+ metric/log `janus_usage_missing{protocol="openai_decisions"}`. If present
→ map only recognized token keys; never fabricate zeros for missing keys.
Do **not** assert `input_tokens`/`output_tokens` names until live fixture.

## 3. Approach

Chosen: **A** — fourth agent face on `janus_http_proxy`. Rejected: modality
plugin; translate-matrix stubs.

## 4. Architecture

### 4.1 Protocol

Atom/string: `openai_decisions`. Normalize beside the three existing.
No translate request/response clauses for any Decisions pair.
Unknown protocol in catalog on **old** beams: `normalize_protocol`
returns error and catalog load **skips** that provider row (log +
continue) — must not crash mid-rollout.

### 4.2 Handler `janus_http_decisions`

Mirror from `janus_http_responses` **only:** agent auth, `?MAX_BODY`
(10 MiB), JSON-only, `x-request-id` resolve/echo, call
`janus_http_proxy:handle(openai_decisions, …)`.  
**Do not** copy Responses SSE, translate knobs, or Responses rejects.

Classify: `endpoint=decisions`, `protocol=openai_decisions`.

**Error envelopes** (two codes, literal messages):

| Code | HTTP | Message (exact) |
|------|------|-----------------|
| `protocol_requires_native` | 400 | `model is not available on this protocol face` |
| `stream_not_supported` | 400 | `decisions does not support streaming` |

```json
{"error":{"message":"<exact from table>","type":"janus_error","code":"<code>"}}
```

413 oversized body: existing Janus `request_too_large` envelope (same as
Responses).

Stream guard: in handler **before** proxy — `"stream": true` →
`stream_not_supported`.

### 4.3 Catalog, migration, probe, passthrough

- Migration: CHECK add `openai_decisions` (PG + SQLite copies). Seed +
  dashboard `PROTOCOLS` / labels / OpenAI preset →
  `https://api.openai.com/v1`.
- **Release order:** (1) gateway CHECK on all nodes (2) new beams
  (3) generation bump (4) dashboard enum/probe UI (5) operators create
  Decisions providers. Dashboard **write gate:** reject creating
  `openai_decisions` providers until gateway generation/min-version
  advertises Decisions support (or operator confirms fleet upgraded).
- Rollback: `enabled=0` on Decisions providers; never reverse CHECK.
- SQLite: follow existing CHECK-alteration pattern used by prior
  migrations (table rebuild if required by that pattern).
- Forward: `{base_url}/decisions` via shared path-join; cover `/v1` +
  trailing-slash in tests.
- **Passthrough:** forward unknown request JSON fields; rewrite `model`
  to upstream listing name; pass through upstream status + body; propagate
  gateway `x-request-id` upstream as today for other faces; **no automatic
  retry** on native Decisions POST (double-billing).
- **Probe:** one-shot, ~10 s deadline, **no retry**, use **stored
  provider-row key**, model = **listing’s upstream model name** (no raw
  `gpt-6-luna` fallback). Log redaction: no key, no base64 bodies.
  - OK: **200**, or **400** whose body **fingerprints Decisions**
    (mentions `questions` / `input` / Decisions-shaped error codes —
    allowlist finalized from live capture)
  - Bad key: **401** / **403**
  - Not Decisions: **404** / **405**
  - Inconclusive: **5xx** / timeout / connect → `probe_inconclusive`
    (distinct UI class; not “not Decisions”)
  - 200 probes may bill; UI warns.

### 4.4 Models list, listing discovery, grants

**Discovery:**

1. Sync `GET {base}/models` as today; stamp each inventory row with
   **provider-row protocol**.
2. If upstream omits Decisions-capable ids, operator **manually adds**
   listing names on that Decisions provider (dashboard inventory add) —
   same as any provider with incomplete sync.
3. Do **not** stamp chat-synced names as Decisions without a Decisions
   provider row.

**`/v1/models`:** one entry per public name (existing union). No protocol
field on the wire (D3).

**Same-name dual rows (D6):** catalog/ETS keep listings keyed by
`(provider_id, name)` inventory and routes by model/listing pick keys
per `SCHEMA_ETS_CONTRACT.md`. Agent name may collide in the union;
`pick_listing_route` / bound routes apply **protocol eligibility**
(§4.5) so chat never selects Decisions routes and vice versa.

**Grants (D10) + accepted risk:** `api_key_models` by name. Adding a
Decisions provider for a name already granted widens which faces that
key can **attempt**; wrong face still 400. Operator docs one-liner:
“Grant is by model name across faces; wrong-face calls get
`protocol_requires_native`; adding a Decisions row does not require
re-grant but enables Decisions calls for that name.”

### 4.5 Fail-closed routing and error precedence (D5′)

**LB candidate-set filter (primary):**

- Client Decisions → only `openai_decisions` routes
- Client chat/responses/messages → exclude `openai_decisions`

**Dispatch second line:** either side Decisions and protocols differ →
`protocol_requires_native` before translate.

**Empty / miss precedence** (aligns with existing faces):

| Situation | Error |
|-----------|--------|
| Unknown name (no routes any protocol) | existing `no_route` (same as today) |
| Face-correct routes exist but all disabled | existing `provider_disabled` |
| Face-correct routes exist but all cooling / no usable key | existing `all_cooling` / key errors |
| Name exists only on **other** protocol(s) | **400 `protocol_requires_native`** |
| Name has eligible face routes | pick among those only |

**janus-auto:** gateway excludes Decisions at candidate-set build;
dashboard Router tier pickers **hard-block** Decisions listings.

### 4.6 Native path

Both sides `openai_decisions`: non-stream POST `/decisions` as §4.3.
Idle timeout: same Cowboy 300s class as other agent faces.

### 4.7 Streaming

Handler pre-proxy: `stream:true` → `stream_not_supported`. No stream-
translate integration.

## 5. Usage, metrics, dashboard cost

- Usage row `protocol=openai_decisions`; parse per §2; metric
  `janus_usage_missing` when 200 has no usage.
- Closed enums: `endpoint=decisions`, `protocol=openai_decisions` in
  classify + metrics docs + dashboard SPEC/TEST-FLOWS.
- **Pre-ship check:** scrape `/metrics` and assert both label values
  appear after a Decisions request; audit existing scrape/alert
  allowlists for closed-enum assumptions.
- Dashboard cost readouts: Decisions is **token-only**, null-safe; UI
  must not imply output-token charges when tokens are null; no
  modality `units` for Decisions.

## 6. Dual-repo

| Gateway | Dashboard |
|---------|-----------|
| Route, protocol, migration, LB filter, dispatch, usage/metrics, auto filter, seed, tolerant normalize | Enum/label/preset, write gate, probe UI, Router hard-block, error map, TEST-FLOWS, SPEC, operator grant copy |

## 7. Testing

| Flow | Assert |
|------|--------|
| TF-D.1 | Replay fixture (guide mock until live file exists; live file required for prod gate) → 200 + `answers` |
| TF-D.2 | Other-protocol-only name on chat → 400 `protocol_requires_native` + exact message |
| TF-D.3 | Chat-only name on decisions → same code/message |
| TF-D.4 | `/v1/models` grant include/exclude by name |
| TF-D.5 | `stream:true` → 400 `stream_not_supported` + exact message |
| TF-D.6 | Usage row protocol; tokens per fixture (null OK) |
| TF-D.7 | E2E: auto never picks Decisions |
| TF-D.8 | Regression: other faces unchanged with unrelated Decisions provider |
| TF-D.9 | Same-name dual-row: chat pick ≠ Decisions pick |
| TF-D.10 | Sync/operator listing appears under Decisions provider protocol stamp |

**Eunit (parser-first):** Decisions success `answers` shapes from guide
excerpts; error envelopes; usage null-safety; probe-outcome classifiers
(200/400-fingerprint/401/403/404/5xx); LB eligibility predicates;
classify/normalize. Production-shaped binaries only.

Browser: protocol label, probe classes, Router hard-block.

## 8. Failure modes

LB/dispatch leaks, auto pick, polyfill, usage fabrication, modality
misuse, dashboard write before fleet upgrade, same-name wrong pick,
handler SSE creep, probe false-OK on generic 400, native POST retry
double-bill, sync poisoning chat listings as Decisions.

## 9. Rollout

1. `xray doc` GO + user approval  
2. Operator live capture → sanitized `openai_decisions.json` (redaction + gitleaks)  
3. `writing-plans` dual-repo plan  
4. Gateway CHECK → beams → generation → dashboard write gate opens  
5. Implement + local e2e (replay then live)  
6. `deploy_prod.sh`; `--smoke` read-only (no Decisions mutations)

## 10. Open / closed

| ID | Status |
|----|--------|
| O1 usage field names | Open until live fixture; null-safe rules locked |
| O2–O4, S1–S3 | Closed as D5′–D13 / §4 |
| Empty-set precedence | Closed as D5′ table |
| `/v1/models` face hint | Closed: no |
| Body cap | Closed: 10 MiB + 413 |
| Eunit wire parser | Closed: yes (§7) |

## 11. Self-review

- [x] Round-1/2 consensus folded; splits closed in-spec  
- [x] Guide excerpt fixture on disk  
- [x] Exact error codes + messages  
- [x] Probe fingerprint / inconclusive / no-retry  
- [x] Listing discovery + dual-name + grant risk  
- [x] Deploy write gate + old-beam skip  
- [x] Metrics scrape assert + usage_missing  
- [ ] Live `openai_decisions.json` (operator key — ship gate, not design blocker for GO if D11/D13 accepted)  
- [ ] xray round 3 GO
