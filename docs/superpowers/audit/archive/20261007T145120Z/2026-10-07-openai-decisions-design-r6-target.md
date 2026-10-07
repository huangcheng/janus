# OpenAI Decisions API — design spec

Status: draft (xray round-6 candidate — r1–r5 folded; objective G1–G3 fixed)  
Date: 2026-10-07  
Repos: `Janus` + `janus-dashboard`  
Guide: https://developers.openai.com/api/docs/guides/decisions  
Audits: `docs/superpowers/audit/2026-10-07-openai-decisions-design*`

**Gates:**  
- **Merge/CI:** guide-excerpt replay (D11)  
- **Implementation start + production claims:** sanitized live fixture D13  
- **No billable prod traffic** until O1 usage keys pinned from D13  

## 1. Goal / non-goals

Native passthrough `POST /v1/decisions`. No translate/polyfill.

Non-goals: polyfill; auto Decisions; streaming; face knob; dual-protocol
rows; `/v1/models` face hints; per-face grants; auto-stamp full OpenAI
`/models` onto Decisions; **forwarding** client `OpenAI-Organization` /
`OpenAI-Project` (strip if present — spoofing risk).

## 2. Locked decisions

| # | Decision |
|---|----------|
| D1 | Fourth agent face on proxy |
| D2 | Fail closed unless provider protocol `openai_decisions` |
| D3 | `/v1/models` name union, no face hint |
| D4 | No translate clauses |
| D5′ | Disjoint precedence §4.5 |
| D6 | One protocol per provider row |
| D7 | `prefer_proto` ≠ eligibility |
| D8 | No face enable knob |
| D9 | Chat/Responses naming Decisions-only listing → `protocol_requires_native` (not `wrong_modality`); **AGENTS.md + existing TFs updated in same commit** |
| D10 | Grant confirm on provider create, **every listing-add**, **every intersecting grant-write**; audit who accepted |
| D11 | Guide-excerpt replay = merge/CI only |
| D12 | Decisions handler `?MAX_BODY = 10*1024*1024`; full body buffered **before** upstream connect; 413 `request_too_large` |
| D13 | Live sanitized fixture before implementation start |
| D14 | Manual listings only on Decisions providers |
| D15 | Failover only if attempt fails **before any request byte is written** (gunup/connect); any HTTP status, mid-body fail, or **first-byte timeout** → no failover; Decisions opts out of post-send retries in `failover_decide`; **chat/Responses/Anthropic failover byte-identical** (regression TFs) |
| D16 | Extract shared preamble module in **this** change; Responses regression TF (auth/body/request-id unchanged) |
| D17 | Strip client `OpenAI-Organization` / `OpenAI-Project` on Decisions face |
| D18 | Stream reject **only** on body `"stream": true` (not `Accept: text/event-stream`) |

## 3. Upstream + fixtures

Guide shapes as before. Input may be text and/or inline base64 images.

| File | Gate |
|------|------|
| `apps/janus_http/test/fixtures/probes/openai_decisions.guide-excerpts.json` | D11 merge/CI |
| `apps/janus_http/test/fixtures/probes/openai_decisions.json` | D13 impl-start + prod |

Redaction: auth/org/project/account/billing headers; strip/replace base64;
size cap; gitleaks + CI assert.

**Usage:** Until O1 from D13 — null-safe;
`janus_usage_missing` / `janus_usage_unmapped` (alert if unmapped >0).
One nesting level allowed. **No billable prod** until O1 pinned.

## 4. Architecture

### 4.1 Protocol / migration / mixed fleet

- Atom `openai_decisions`; CHECK extended on migration leader boot.
- **Old beams:** `normalize_protocol` unknown → skip row (must have
  catch-all; TF). They never **write** Decisions rows (write gate).
- CHECK does not “reject reads”; it constrains inserts after migration.
- **Mixed fleet:** no cross-node routing inside Janus; external LB may
  hit old node → agent sees existing **`no_route`** (or catalog skip).
  Ops note ships with exact string. D2 still holds per-node.

### 4.2 Handler pipeline (executable order)

1. Auth  
2. Read body with 10 MiB cap (**413** if over; reject chunked oversize
   before upstream)  
3. JSON parse (`invalid_json`)  
4. Grant check by `model` from body  
5. If `"stream": true` → `stream_not_supported`  
6. Proxy pick / eligibility  

Non-POST → **405**.  

| Code | Message |
|------|---------|
| `protocol_requires_native` | `client face <F> cannot call model that requires <P>` (F/P filled) |
| `stream_not_supported` | `decisions does not support streaming` |
| `upstream_response_too_large` | `upstream decisions response exceeds size limit` |
| `upstream_timeout` | `upstream decisions response timed out` |

Upstream response cap: **4 MiB** (answers are small). Gun request
timeout for Decisions: **60 s** to first byte (align AGENTS idle reality).

Envelope local rejects: `janus_error` as before. Upstream errors:
status+body verbatim except strip sensitive upstream headers; forward
`Retry-After` on 429; metric `decisions_upstream_429_total`.

### 4.3 Forward / D15 / probe / write gate

**Forward:** path-join `{base}/decisions`; rewrite `model` to listing
upstream id (same as probe); strip OpenAI-Org/Project; mint/echo
`x-request-id`; unknown JSON fields forwarded; logs =
id/model/endpoint/status/latency only.

**D15 signals (falsifiable):**  
- **Pre-send fail:** gun connection setup error before request headers
  written → may failover to another Decisions route.  
- **Terminal (no failover):** any HTTP status received; body stream
  error; **60 s first-byte timeout** → `upstream_timeout` to client.  
Shared-proxy change in scope; regression: other faces’ failover
unchanged.

**Probe:**

- Owner: dashboard server-side job using stored provider key.  
- Storage: table **`provider_probe_state`**
  `(provider_id PK, last_probe_at, probes_today, day_utc, in_flight)`.  
- Listing pick: lowest `provider_models.id` among enabled listings on
  that provider; model field = forward-path rewrite target.  
- Body: guide ping predicate (same as prior).  
- Cooldown **5 min** transactional; **20/day** budget; audit row without
  keys/bodies.  
- Timeout **60 s**.  
- OK: HTTP 200 and `answers` is a JSON **array** (may contain only
  `refusal` entries). Empty/`answers` missing → inconclusive.  
- 401/403 → bad key. **All** 400/404/405/5xx/timeout → inconclusive
  until O2.  
- Does **not** write agent `usage_events` (probe accounting separate).  
- UI: billable warning + remaining budget.

**Write gate:**

- Create/enable Decisions provider requires **every node** marked ready
  in dashboard registry (heartbeat freshness ≤60 s) to return
  `protocols` containing `openai_decisions` from **`GET :8080/readyz`**
  within **3 s** timeout per node.  
- `protocols` captured at cowboy listener start from handler modules
  registered for agent routes.  
- Unreachable/stale node → **block** with reason (fail closed).  
- Audited break-glass override (role + reason) for emergencies.  
- **Always allow** `enabled=0` / listing disable (kill switch).  
- Verify dashboard→`:8080/readyz` on **leader deploy** (before dashboard
  write UI opens). Unauthenticated disclosure of protocol list:
  **accepted** (same public health surface as healthz).

### 4.4 Listings / grants

Manual listings only. Grant confirm+audit on create, listing-add,
intersecting grant-write. Dual-face names: confirm may fire when
Decisions listing added even if chat already granted — intentional.

### 4.5 Precedence (disjoint)

| # | Situation | Outcome |
|---|-----------|---------|
| 1 | Auth fail | 401 |
| 2 | Grant deny | existing grant deny |
| 3 | `stream:true` | `stream_not_supported` |
| 4 | Unknown name (no routes any protocol) | `no_route` |
| 5 | After eligibility filter, zero routes and name exists only on other protocol(s) | `protocol_requires_native` |
| 6 | After filter, zero routes and name had face-correct routes all disabled | `provider_disabled` |
| 7 | After filter, zero routes and all cooling/no key | existing cooling/key errors |
| 8 | Else | pick among filtered routes |

Eligibility filter: Decisions client ↔ only `openai_decisions` routes;
other clients exclude `openai_decisions`. Auto: exclude Decisions
**routes** (per-protocol), not names.

`janus-auto` as model on `/v1/decisions` → `protocol_requires_native`.

### 4.6–4.7

Native non-stream POST. No SSE path.

## 5. Metrics / cost / AGENTS

Labels `endpoint=decisions`, `protocol=openai_decisions`.  
`decisions_probe_total{outcome=…}`, `decisions_upstream_429_total`.  
Pre-ship scrape + allowlist.  
Dashboard protocol enum migration + validators + rollback note.  
Cost UI token-only null-safe.  
**AGENTS.md** `wrong_modality` bullet updated for Decisions-name case
in same PR as D9.

## 6. Rollout

1. Spec GO + approval  
2. D13 live capture  
3. Plan + implement (incl. D15/D16)  
4. Local e2e green  
5. Aliyun gateway deploy + readyz verify (dashboard reachability)  
6. Followers  
7. Dashboard deploy (write gate live)  
8. Ops create providers/listings  
9. Operator live TF-D.1 once (not scripted)  
10. Kill via `enabled=0`  

Rollback: disable providers; gateway rollback with Decisions rows =
old beams skip; dashboard old enum = reject new writes, existing rows
display as unknown protocol read-only.

## 7. Testing (enumerated)

| ID | Assert |
|----|--------|
| TF-D.1 | Replay fixture → 200 + `answers` array |
| TF-D.2 | Decisions-only name on chat → `protocol_requires_native` (message has faces) |
| TF-D.3 | Chat-only on decisions → same |
| TF-D.4 | `/v1/models` grant include/exclude |
| TF-D.5 | `stream:true` → `stream_not_supported`; Accept SSE alone OK |
| TF-D.6 | Usage row; null until O1; then exact keys |
| TF-D.7 | Auto never picks Decisions **route** |
| TF-D.8 | Other faces regression |
| TF-D.9 | Same-name dual-row face split |
| TF-D.10 | Manual listing callable |
| TF-D.11 | Translate knobs invariant |
| TF-D.12 | Old normalize skip / no crash |
| TF-D.13 | Eligibility before wrong_modality; chat→Decisions-only never wrong_modality |
| TF-D.14 | Rows 5–7 precedence variants |
| TF-D.15 | D15: no second upstream after HTTP status; connect-fail may failover; other faces unchanged |
| TF-D.16 | Write gate: missing advertisement / unreachable node blocks create; disable-only OK |
| TF-D.17 | Grant confirm on listing-add |
| TF-D.18 | 413 oversize; 405 non-POST; 429 + Retry-After passthrough |
| TF-D.19 | Upstream response >4 MiB → `upstream_response_too_large` |
| TF-D.20 | Responses preamble regression after D16 |

Eunit: guide answers; envelopes; usage null/unmapped; probe classifier;
eligibility; path-join; readyz protocols from handler registry.

## 8. Open (hard-gated)

| ID | Gate |
|----|------|
| O1 usage keys | D13; no billable prod until pinned |
| O2 not-Decisions 404 body | D13; until then all 404/405 inconclusive |

## 9. Self-review

- [x] G1 pipeline order fixed  
- [x] G2 CHECK vs old beams clarified  
- [x] G3 mixed-fleet = external LB + `no_route`  
- [x] D15 falsifiable; shared-proxy in scope  
- [x] Write-gate failure semantics + kill exemption  
- [x] Probe table/owner/budget pinned  
- [x] D9 AGENTS update called out  
- [x] Accept SSE not stream-trigger  
- [ ] D13 live fixture  
- [ ] xray **GO**
