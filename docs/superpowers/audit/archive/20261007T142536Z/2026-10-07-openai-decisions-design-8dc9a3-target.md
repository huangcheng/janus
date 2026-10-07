# OpenAI Decisions API — design spec

Status: draft (xray round-4 candidate — rounds 1–3 GO WITH FIXES folded)  
Date: 2026-10-07  
Repos: `Janus` + `janus-dashboard`  
Upstream: https://developers.openai.com/api/docs/guides/decisions  
Audits: `docs/superpowers/audit/2026-10-07-openai-decisions-design-synthesis.md` (r1),  
`…-8dc9a3-synthesis.md` (r2 archive + r3 manual)

Design only. Code after clean `xray doc` **GO** + user approval.

## 1. Goal / non-goals

**Goal:** Native passthrough `POST /v1/decisions` via existing agent proxy
(auth, catalog, LB, usage, metrics). No invented Decisions semantics on
other protocols.

**Non-goals:** translate/polyfill; janus-auto targets; streaming; face
enable knob; dual-protocol provider rows; `/v1/models` face hints;
per-face grants; auto-stamping OpenAI’s full chat model catalog onto a
Decisions provider.

**Locked:**

| # | Decision |
|---|----------|
| D1 | Fourth agent face on `janus_http_proxy` |
| D2 | Fail closed unless provider protocol is `openai_decisions` |
| D3 | Name appears in `/v1/models` union; no protocol hint field |
| D4 | No translate clauses / polyfill |
| D5′ | Error precedence table §4.5 (includes grant-deny) |
| D6 | One protocol per provider row |
| D7 | `prefer_proto` is not Decisions eligibility |
| D8 | No `decisions.enabled` face knob |
| D9 | Protocol-eligibility filter runs **before** any `wrong_modality` path; Decisions wrong-face never emits `wrong_modality` |
| D10 | Grants by name; adding Decisions enables **billable** calls for that name; UI confirms grant intersection |
| D11 | **Merge/CI green** = fixture **replay** (guide excerpts → then live file when present) |
| D12 | Body cap **10 MiB**; document ~1 large inline image ceiling; 413 = existing `request_too_large` |
| D13 | **Production claims** require sanitized live `openai_decisions.json` |
| D14 | Decisions providers: **no auto-sync stamp** of `/models` into callable listings |
| D15 | Native POST: failover **only pre-send**; never after bytes sent; no proxy retry |

## 2. Upstream + fixtures

**Guide:** `POST /v1/decisions`; `gpt-6-luna` (beta); `model` + `input`
(string **or** user messages with `input_text` and/or `input_image`) +
`questions[]`; answer types predicate/choice/score/refusal; images =
inline base64 only; no Decisions-only models API.

**Fixtures:**

| File | Role |
|------|------|
| `apps/janus_http/test/fixtures/probes/openai_decisions.guide-excerpts.json` | Guide `answers` shapes; eunit + local mock replay (D11) |
| `apps/janus_http/test/fixtures/probes/openai_decisions.json` | Sanitized **live** capture (D13). Redact: Authorization, org/project/account ids, billing headers, **replace/strip base64 image bytes**, cap file size. gitleaks clean. |

**Usage parse:** until live pin — null-safe only. Absent `usage` →
`janus_usage_missing{protocol="openai_decisions"}`. Present but no
recognized token keys (flat or one nesting level) →
`janus_usage_unmapped{protocol="openai_decisions"}` + null tokens. Never
fabricate zeros. Field names pinned only after live fixture.

## 3. Approach

**A** — fourth agent face. Not modality plugin; not translate matrix.

Shared **handler preamble** (extract or copy carefully): auth,
`?MAX_BODY`, JSON-only, `x-request-id`, classify — so Responses SSE /
translate cannot leak into Decisions by evolution. TF asserts Decisions
handler has no SSE/translate deps.

## 4. Architecture

### 4.1 Protocol + old beams

Atom/string `openai_decisions`. Normalize + seed + dashboard validators.
No translate pairs.

Old beams: unknown protocol row → skip (log), no crash. Mid-rollout:
old nodes may `no_route` while new nodes serve Decisions — **accepted**;
document for ops. Transient candidate-set divergence across nodes OK.

### 4.2 Handler

`POST /v1/decisions` → `janus_http_decisions` →
`proxy:handle(openai_decisions, …)`. Non-POST → **405**.

| Code | HTTP | Exact message |
|------|------|----------------|
| `protocol_requires_native` | 400 | `model is not available on this protocol face` |
| `stream_not_supported` | 400 | `decisions does not support streaming` |

Envelope: `{"error":{"message":"…","type":"janus_error","code":"…"}}`
(parity with other Janus local rejects; 413 keeps existing
`request_too_large` shape).

Stream reject **before** proxy if `"stream": true` **or**
`Accept` contains `text/event-stream`.

Malformed JSON / 413 / stream-guard precedence: body read limits first
(413), then JSON parse, then stream guard, then proxy.

### 4.3 Forwarding, failover, logs, probe

**Forward:** `{base_url}/decisions` (shared path-join; test `/v1` +
trailing slash). Rewrite `model` to upstream listing name; forward
unknown JSON fields; pass upstream status/body **verbatim** on
non-2xx (native passthrough — no Janus wrap of upstream errors).
Propagate `x-request-id`. Pass through `OpenAI-Organization` /
`OpenAI-Project` if client sent them (same policy as other OpenAI faces
if already implemented; else out of scope = do not invent).

**Failover / retry (D15):**  
- Pre-send connect failure → may fail over to another
  `openai_decisions` route.  
- After request bytes sent → **no** failover, **no** retry; return
  upstream/error to client.  
- Explicit suppression of any shared-proxy retry for this face.  
- Pass through **429** with dedicated metric bump; no retry.

**Normal-traffic logs:** retain only request_id, model, endpoint,
status, latency — **never** full body / base64.

**Probe (dashboard API, server-side):**

Provisional request body (confirm vs live capture; do not change shape
without fixture update):

```json
{
  "model": "<listing.upstream_model_id or listing.name>",
  "input": "ping",
  "questions": [
    {
      "type": "predicate",
      "name": "probe_ok",
      "instructions": "Is this a connectivity probe? Answer with low confidence."
    }
  ]
}
```

- One-shot, ~10 s, **no retry**, stored provider key, cooldown ≥60 s
  between probes per provider (anti-billing-abuse).
- **Zero listings** → UI/API state `blocked_no_listing` (do not POST).
- Outcomes:
  - **OK:** HTTP **200** whose JSON has **`answers` array** (structural)
  - **Bad key:** 401 / 403
  - **Not Decisions:** 404 / 405 without model-not-found ambiguity → not Decisions
  - **Inconclusive:** 5xx, timeout, connect error, **any 400**, 404
    model-not-found body, or 200 without `answers`
- Until live fixture confirms otherwise: **never** treat 400 as OK.
- UI warns: successful 200 probe **bills** Luna Decisions (minimal input).

**Write gate (server-side):** `POST/PUT` provider with
`protocol=openai_decisions` rejected unless ≥1 ready gateway node
advertises Decisions. **Advertisement:** each gateway includes
`"protocols":["openai_chat","openai_responses","anthropic_messages","openai_decisions",…]`
in **`GET /readyz`** JSON once beams support the face. Dashboard polls
nodes’ `/readyz` (existing node list). No “operator confirms” bypass in
v1 API.

### 4.4 Listings (D14) + grants

**Decisions provider inventory:**

- **Do not** run auto `/models` sync into **enabled** listings for
  `openai_decisions` rows (would stamp the entire OpenAI chat catalog).
- Operator **manually adds** listing names (e.g. `gpt-6-luna`) on that
  provider. Optional later: sync into **disabled** rows requiring
  explicit enable — v1 ships **manual-only**.

**`/v1/models`:** name union as today.

**Same-name dual face:** eligibility filter §4.5; ETS keys per
`SCHEMA_ETS_CONTRACT.md` (provider_id + name inventory).

**Grants:** by name. Dashboard when creating Decisions provider: if any
new listing name intersects existing `api_key_models` grants, show
confirmation that those keys can now make **billable** Decisions calls.

### 4.5 Eligibility + precedence (D5′)

Shared predicate used by LB candidate-set, dispatch, and auto filter
(single function — no drift).

| Situation | Outcome |
|-----------|---------|
| Agent key lacks grant for name | existing grant deny (unchanged; **before** face errors) |
| Unknown name (no routes) | `no_route` |
| Face-correct routes, all disabled | `provider_disabled` |
| Face-correct, all cooling / no key | existing cooling/key errors |
| Name only on other protocol(s) | 400 `protocol_requires_native` |
| Eligible routes | pick among those only |

**janus-auto:** exclude Decisions at candidate-set build; Router UI
hard-block; warn if a key is bound only to Decisions-capable public
names for auto (optional UX).

### 4.6–4.7 Native + streaming

Native path as §4.3. Idle timeout: Cowboy 300s class.  
Streaming: §4.2.

## 5. Usage / metrics / cost UI

- Protocol column `openai_decisions`.
- Metrics labels `endpoint=decisions`, `protocol=openai_decisions`.
- `janus_usage_missing`, `janus_usage_unmapped` as §2.
- Pre-ship: scrape `/metrics` after a Decisions call; assert labels;
  audit alert allowlists.
- Dashboard cost: token-only, null-safe; explain nulls; no modality units.
- Beta prices: operator-configured / null — gateway does not embed Luna $.

## 6. Dual-repo + release (boot migration)

| Gateway | Dashboard |
|---------|-----------|
| readyz protocols, route, LB/dispatch predicate, no-retry, usage/metrics, auto exclude, seed allow-list, migration CHECK | protocol enum, write gate vs readyz, probe, manual listing UX, grant confirm, Router block, TEST-FLOWS, SPEC, ops copy |

**Rollout (matches `deploy_prod.sh` / boot migrations):**

1. Spec GO + approval  
2. Live capture → sanitized fixture (D13) when key available; else merge
   on guide replay only  
3. Implementation plan  
4. **Aliyun (migration leader) deploy** new gateway (migration runs at
   boot) → verify CHECK + `/readyz` lists `openai_decisions`  
5. Follower gateways roll  
6. Dashboard deploy (write gate opens when nodes advertise)  
7. Operators create Decisions providers + manual listings  
8. Local e2e green; prod launch checklist = operator live TF-D.1 once
   (smoke stays read-only)  
9. Feature kill: `enabled=0` providers; optional later contingency
   migration to drop CHECK value if ever needed (not required to ship)

## 7. Testing

| Flow | Local-green (D11) | Production-green (D13) |
|------|-------------------|------------------------|
| TF-D.1 | Mock replay guide/live fixture → 200 + `answers` | Live Luna once on checklist |
| TF-D.2/3 | Exact `protocol_requires_native` | same |
| TF-D.4 | Grant include/exclude | same |
| TF-D.5 | `stream_not_supported` (+ Accept SSE) | same |
| TF-D.6 | Usage row; null OK on guide fixture | field names vs live fixture |
| TF-D.7 | Auto never picks Decisions | same |
| TF-D.8 | Other faces regression | same |
| TF-D.9 | Same-name dual-row face split | same |
| TF-D.10 | Manual Decisions listing callable | same |
| TF-D.11 | Translate knobs on/off do not change Decisions | same |
| TF-D.12 | Catalog with Decisions row + old normalize skip path / no crash | same |
| TF-D.13 | Protocol eligibility before wrong_modality | same |

Eunit: answers shapes, envelopes, usage null/unmapped, probe classifier
(200/400/401/403/404/405/5xx/inconclusive), LB eligibility, readyz
protocols, path-join.

Browser: protocol, probe states including `blocked_no_listing`, grant
confirm, Router hard-block.

## 8. Failure modes

Sync poisoning (mitigated D14), probe false-OK (mitigated structural
200), post-send failover double-bill (D15), write-gate bypass
(server-side readyz), grant silent billing (confirm UI), log base64
leak (redaction), handler SSE creep (preamble + TF), mixed-fleet
no_route vs 400 (documented).

## 9. Open

| ID | Status |
|----|--------|
| O1 live usage key names | Open until D13 fixture |
| All else | Closed in D1–D15 / tables above |

## 10. Self-review

- [x] r1–r3 consensus folded  
- [x] Manual listings only for Decisions  
- [x] Probe = 200+answers; 400 never OK until live says otherwise  
- [x] Pre-send failover only; readyz write gate  
- [x] Boot-migration rollout wording  
- [x] Grant-deny precedence; billable widening copy  
- [x] Guide fixture on disk  
- [ ] Live fixture (D13 — production gate)  
- [ ] xray **GO** (not GO WITH FIXES)
