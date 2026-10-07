# OpenAI Decisions API — design spec

Status: draft (xray round-5 candidate — r1–r4 GO WITH FIXES folded)  
Date: 2026-10-07  
Repos: `Janus` + `janus-dashboard`  
Upstream guide: https://developers.openai.com/api/docs/guides/decisions  
Audits under `docs/superpowers/audit/2026-10-07-openai-decisions-design*`

Design only. **Implementation start** requires D13 live fixture on disk
(plan task 0). Design GO may rely on the guide + guide-excerpt fixture.

## 1. Goal / non-goals

**Goal:** Native passthrough `POST /v1/decisions` on the existing agent
proxy. No polyfill / translate matrix.

**Non-goals:** translate/polyfill; janus-auto Decisions targets;
streaming; face enable knob; dual-protocol rows; `/v1/models` face
hints; per-face grants; auto-stamping OpenAI’s full `/models` catalog
onto Decisions providers; inventing `OpenAI-Organization` /
`OpenAI-Project` header passthrough (not present on existing OpenAI
faces today — **do not add** in v1).

**Locked (D1–D16):**

| # | Decision |
|---|----------|
| D1 | Fourth agent face on `janus_http_proxy` |
| D2 | Fail closed unless provider protocol is `openai_decisions` |
| D3 | Name in `/v1/models` union; no protocol hint |
| D4 | No translate / polyfill |
| D5′ | Precedence §4.5 |
| D6 | One protocol per provider row |
| D7 | `prefer_proto` ≠ eligibility |
| D8 | No face knob |
| D9 | Eligibility before `wrong_modality`; never emit `wrong_modality` for Decisions wrong-face |
| D10 | Grants by name; confirm on **every** listing-add / grant-write under Decisions providers |
| D11 | Guide/live **replay** gates **merge/CI** |
| D12 | Decisions `?MAX_BODY = 10 MiB` (face-local define); 413 = existing `request_too_large`; ~1 large inline image ceiling documented in ops |
| D13 | Sanitized live `openai_decisions.json` required before **implementation start** and before production claims |
| D14 | Decisions providers: manual listings only (no enabled auto-sync stamp) |
| D15 | Failover only on **TCP/TLS establishment failure**; never after request bytes start; Decisions opts out of post-send `failover_decide` retries (proxy change **in scope**) |
| D16 | Handler preamble: **extract** shared auth/body/request-id helper used by Responses + Decisions (TF proves Decisions has no SSE/translate deps) |

## 2. Upstream + fixtures

Guide facts as previously (endpoint, luna, input/questions/answers,
inline images, no Decisions models API).

| Fixture | Role |
|---------|------|
| `…/probes/openai_decisions.guide-excerpts.json` | Merge/CI eunit + mock replay (D11) |
| `…/probes/openai_decisions.json` | **Plan task 0 / D13** — sanitized live capture before coding the face |

Redaction for live file: strip auth/org/project/account/billing headers;
replace base64 image bytes; size cap; gitleaks + CI redaction assert.

**Usage:** null-safe until D13. Metrics:
`janus_usage_missing{protocol="openai_decisions"}`,
`janus_usage_unmapped{protocol="openai_decisions"}` (alert if >0 on
billable traffic; allowlist ships same deploy). Nested usage: allow one
level; pin keys from live fixture.

## 3. Approach

**A** — fourth agent face. Shared preamble module (D16).

## 4. Architecture

### 4.1 Protocol

`openai_decisions` atom/string. Old beams skip unknown protocol rows
(log). Mid-rollout: route only to nodes that can serve (LB/catalog on
each node); mixed fleet may `no_route` on old nodes — ops doc required.

### 4.2 Handler + errors

`POST /v1/decisions` only; other methods **405**.

| Code | HTTP | Exact message |
|------|------|----------------|
| `protocol_requires_native` | 400 | `model is not available on this protocol face` |
| `stream_not_supported` | 400 | `decisions does not support streaming` |

Envelope: `{"error":{"message":"…","type":"janus_error","code":"…"}}`.

**Request pipeline order:** auth → grant check → body size (413) →
JSON parse → stream/`Accept: text/event-stream` guard → proxy pick.

### 4.3 Forward, failover, probe, write gate

**Forward:** `{base}/decisions` via shared path-join. Rewrite `model` to
the **same** upstream listing target used on the live path. Forward
unknown JSON fields. Upstream non-2xx: status + body **verbatim**;
forward `Retry-After` on 429; metric
`upstream_requests_total` / dedicated
`decisions_upstream_429_total` as appropriate. Mint `x-request-id` if
absent; always echo. No org/project headers (D non-goal).

**Failover (D15):** In `failover_decide` for `ClientProto =
openai_decisions`: allow repick **only** when the attempt failed at
TCP/TLS connect (no HTTP status). Any HTTP response or mid-body
failure → return to client, no second upstream. Scope includes teaching
the proxy to distinguish connect-fail vs post-send if not already
signaled. Regression TF required.

**Logs:** request_id, model, endpoint, status, latency only.

**Probe:**

```json
{
  "model": "<exact forward-path rewrite target for selected listing>",
  "input": "ping",
  "questions": [{
    "type": "predicate",
    "name": "probe_ok",
    "instructions": "Is this a connectivity probe? Answer with low confidence."
  }]
}
```

- Zero listings → `blocked_no_listing` (no POST).
- One-shot ~10 s; **DB** `providers.last_probe_at` (or sibling table)
  transactional cooldown **≥5 min**; **per-day budget** (default 20
  probes/provider/day) + audit log of probe calls.
- Outcomes:
  - OK: **200** + JSON `answers` is a non-empty array **or** array of
    only `refusal` (still structural OK)
  - Bad key: 401/403
  - Inconclusive: **all 400/404/405**, 5xx, timeout, connect, 200
    without `answers`
  - “Not Decisions” body classifier: **deferred to D13** (O2)
- UI: 200 probes bill; show cooldown/budget remaining.

**Write gate (server-side):**

- Creating/updating a provider **to** `openai_decisions` (or enabling
  one) requires **every ready gateway node** in the dashboard’s node
  list to advertise `openai_decisions` on **`GET http://<agent_host>:8080/readyz`**
  (`protocols` array derived from **registered cowboy routes / handler
  module presence**, not a hardcoded string list).
- **Exempt:** mutations that only set `enabled=0` (or disable listings)
  — kill switch always works even if no node advertises.
- Dashboard→`:8080/readyz` reachability verified in rollout on each
  cloud (aliyun/jdcloud/tencent). Admin `:8090` is **not** the signal.

### 4.4 Listings + grants

Manual listings only (D14).  

Grant-intersection confirmation + audit (who accepted) on:
- provider create with Decisions protocol
- **every** listing add under Decisions
- **every** `api_key_models` grant write that intersects a Decisions
  listing name  

Copy: enables **billable** Decisions calls.

### 4.5 Precedence (D5′)

Shared eligibility predicate (LB + dispatch + auto). Auto exclusion is
**per-route protocol**, not per-name (dual-face names stay in auto via
chat routes).

| Situation | Outcome |
|-----------|---------|
| Auth fail | existing 401 |
| Grant deny for name | existing grant deny (**before** stream/face errors) |
| stream / SSE Accept | `stream_not_supported` |
| Unknown name | `no_route` |
| Eligible face routes all disabled | `provider_disabled` |
| Eligible face cooling / no key | existing cooling/key errors |
| Name only on other protocol(s), or only disabled Decisions + other protocol exists | **`protocol_requires_native`** (other-protocol routes are not eligible for Decisions client; for chat client naming Decisions-only listing → same code/message, not `wrong_modality`) |
| Disabled Decisions + no other protocol | `provider_disabled` or `no_route` per existing empty-set rules after filter |
| Eligible routes | pick |

### 4.6 Native path

Non-stream POST as §4.3. Per-attempt upstream deadline: gun/connect
timeouts already used by proxy (no new 300s face-specific idle claim —
global Cowboy idle applies).

## 5. Metrics / cost

Labels `endpoint=decisions`, `protocol=openai_decisions`.  
`decisions_probe_total{outcome=…}`.  
Pre-ship scrape assert + allowlist audit.  
Dashboard: token-only null-safe cost UI; protocol filters accept new enum
(dashboard migration/validator for protocol list).

## 6. Dual-repo + rollout

| Gateway | Dashboard |
|---------|-----------|
| readyz protocols from handlers, route, D15 failover opt-out, eligibility predicate, usage/probe metrics, auto per-route filter, CHECK migration, seed | protocol enum migration/validator, write gate vs :8080 readyz, listing UX, grant confirm+audit, probe DB cooldown/budget, Router hard-block, TEST-FLOWS, SPEC, ops mixed-fleet note |

**Order (matches `deploy_prod.sh`):**

1. Design GO + user approval  
2. **D13 live capture** (blocks implementation start)  
3. Implementation plan + code  
4. **Local e2e green**  
5. Aliyun leader gateway deploy (boot migration) → verify readyz  
6. Follower gateways  
7. Dashboard deploy  
8. Verify dashboard→each cloud `:8080/readyz`  
9. Operators create providers + listings (grant confirms)  
10. Operator-run live TF-D.1 once in prod (never scripted; smoke read-only)  
11. Kill: `enabled=0` (always allowed)

## 7. Testing

Local-green = D11 replay. Production-green = D13 + operator live once.

TF-D.1 … D.13 as before, plus:  
TF-D.14 disabled-Decisions + other-protocol same-name precedence  
TF-D.15 D15 no post-send failover / connect-fail may failover  
TF-D.16 write-gate blocks create when a ready node lacks advertisement;
disable-only still works  
TF-D.17 grant confirm on listing-add  
TF-D.18 translate knobs invariant  
TF-D.19 auto still routes dual-face **chat** side  

Eunit: guide answers, envelopes, usage null/unmapped, probe classifier
matrix (empty answers → inconclusive; refusal-only 200 → OK; 400/404/405
→ inconclusive), eligibility, path-join, readyz protocols derivation.

## 8. Open

| ID | Status |
|----|--------|
| O1 | Usage field names — owner: implementer; deadline: with D13 capture |
| O2 | Probe 404/405 “not Decisions” body classifier — gated on D13; until then all inconclusive |

## 9. Self-review

- [x] r4 W1–W4 + near-consensus applied  
- [x] Write-gate kill-switch exemption; all-nodes; :8080  
- [x] Grant confirm on listing-add/grant-write  
- [x] Probe DB cooldown/budget; 404/405 inconclusive  
- [x] D15 connect-only; proxy change in scope  
- [x] Org/Project: do not invent  
- [x] Local e2e before deploy  
- [x] D13 = implementation-start gate  
- [ ] Live fixture on disk  
- [ ] xray **GO**
