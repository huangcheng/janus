# Industrial operator gateway — Phase 2 design spec

Status: draft (xray 6/6 GO WITH FIXES folded — rev 2)  
Date: 2026-10-08  
Repos: `Janus` (data plane) + `janus-dashboard` (management plane)  
Parent: `docs/audit/2026-10-08-industrial-grade-gap-review.md` (rev 3, north-star **A**)  
xray: `docs/audit/2026-10-08-industrial-operator-phase2-design-synthesis.md`  
Supersedes stub: `docs/superpowers/specs/2026-10-05-next-phase-design.md` §5 (that section should point here).

Design spec only — implementation plans after this revision.

---

## 1. Goal / non-goals

**Goal:** Operator-owned multi-node Janus can **enforce per-agent-key quotas**, **explain LB cooldowns** on the admin plane, and **surface janus-auto routing** via a response header — without Redis, org RBAC, guardrails, or dialect adapters.

**Success:**

1. Key with `rpm_limit=2` → third post-auth admission in the same node minute gets **429** + `Retry-After`; `NULL` limits never quota-429.
2. `GET :8090/stats` includes bounded **`lb_cooldowns`** snapshot (no `pick_route`).
3. **2xx** `janus-auto` responses carry  
   `x-janus-route: <model>;tier=<tier>;origin=<origin>`  
   never inside `choices` / body; header **absent** on direct listings and on auto 4xx/5xx.

**Non-goals:** global quota fairness; USD enforcement; client attribution; SLO/OTel packs; video TF-M; teams/RBAC/cache/guardrails/dialects/K8s; gateway↔gateway LB; quotas on `:8090` or `/healthz`/`/readyz`.

Pure gateway: route, translate, LB, adjudicate, **admit**. CRUD in dashboard.

---

## 2. Prerequisites / baseline

Phase 1 from `2026-10-05-next-phase-design.md` green. Do not regress E.* / M.1–M.7 / TF-11.

**Current reality:**

- `api_keys`: `id, prefix, key_hash, enabled, created_at` — no quota cols.
- Catalog ETS + generation poll default **2000 ms** (`janus_config.erl`).
- Auth → agent map; LB cooldowns node-local; `cooling_count/0` + `stats/0` already on `/stats`.
- Cooldown targets today: `{provider_key, Id}`, `{route, ModelId, ProviderId}`, `{provider, Id}` (`janus_lb.erl`).
- `janus_auto` origins (grep-verified): `rules`, `fallback`, `no_judge`, `breaker`, `cache` (pos hit), `negcache`, `inflight`, `judge`, `judge_fail`, `judge_timeout`.
- Next migration: **014**.

---

## 3. Failure modes / invariants

| # | Invariant |
|---|-----------|
| F1 | `NULL` limits → never quota-429; **admit short-circuits with no ETS write** |
| F2 | Admit **after** auth, **before** upstream gun; **before** failover loop; **exactly once** per client request (pdict/`request_id` guard) |
| F3 | Quota 429 still echoes `x-request-id`; bumps `requests_total` |
| F4 | Streaming: one RPM at admit; no per-chunk RPM |
| F5 | Failover inner attempts do not re-admit / re-charge RPM |
| F6 | Quota ETS **not** rebuilt by `janus_catalog`; owned by `janus_core` app master (or dedicated child started from it). Catalog reload updates **limits on new admits** only; in-flight agent maps keep admit-time limits |
| F7 | Cooldown snapshot read-only; no `pick_route` / `pick_listing_route` |
| F8 | `x-janus-route` only on janus-auto **2xx** |
| F9 | Header emit: model sanitized — replace `/` with `_`; allow `[A-Za-z0-9._:;=-]`; strip CR/LF; reject emit if empty after sanitize |
| F10 | Unlimited keys: no new response fields, no quota 429 (not “bit-identical latency”) |
| F11 | Mig 014 before any node runs new SELECT (aliyun leader first) |
| F12 | RPM counts post-auth admissions into proxy/modality handlers, including local 400s after admit. Pre-auth 401: no. |

**TPM/daily (locked):** **lagging limiter**. Admit compares **already charged** tokens in the current bucket to the limit. A cold bucket / first huge request is **not** pre-empted. Charge only from terminal usage tokens (prompt+completion); null usage → charge **0**. Daily window = **UTC calendar day**.

**ASR admission vs RPM:** independent; both may 429.

---

## 4. Approaches

| | Approach | Decision |
|---|----------|----------|
| A | Redis shared | Rejected v1 |
| B | Per-node ETS | **Chosen** |
| C | Async usage-only admit | Rejected for RPM |

Phase 2b may add Postgres soft global caps.

---

## 5. Ship units

### 5.1 Slice Q — Quotas

#### Schema (014)

```sql
ALTER TABLE api_keys ADD COLUMN rpm_limit INTEGER;           -- NULL = unlimited
ALTER TABLE api_keys ADD COLUMN tpm_limit INTEGER;           -- NULL = unlimited
ALTER TABLE api_keys ADD COLUMN daily_token_limit BIGINT;    -- NULL = unlimited
```

Dashboard rejects `<= 0` when field present (400). Update `SCHEMA_ETS_CONTRACT.md`, `janus_db_conn` SELECT, catalog key maps, keys API/SPA. **No** ghost `daily_budget` field.

#### Module `janus_quota` (`janus_core`)

```erlang
admit(Agent) -> ok | {error, {quota, rpm | tpm | daily, RetryAfterSec :: pos_integer()}}.
%% Idempotent: charge once per RequestId
charge_tokens(RequestId, AgentKeyId, Prompt, Completion) -> ok.
```

- If all three limits `NULL`/absent → `ok` immediately (F1).
- RPM: atomic `update_counter`; admit iff `New =< Limit`. Document over-admit under extreme concurrency as at most a small burst past limit (no compensate-decrement race).
- TPM/daily on admit: if limit set and **current bucket >= limit** → 429 (lagging).
- `charge_tokens`: no-op if `RequestId` already charged (ETS set or pdict); add `max(0,Prompt)+max(0,Completion)` treating `null` as 0.
- **GC:** periodic (or on admit) delete RPM/TPM keys for buckets older than **2** windows; daily keys older than **2** UTC days.
- Ownership: tables created at `janus_core` app start; never cleared on catalog publish.
- Retry-After: rpm/tpm = seconds until bucket end ∈ `[1,60]`; daily = seconds until next UTC midnight ∈ `[1,86400]`.

#### Wire-up

- Single admit call site in shared post-auth preamble used by chat/messages/responses/decisions/modality — **outside** failover. Re-entry guarded.
- 429 body: existing client-face error helpers (`quota_rpm` / `quota_tpm` / `quota_daily`).
- Optional: `usage_events.outcome = <<"quota">>` only if a usage row is written for the reject — **v1: no usage row on quota 429** (admission reject, no spend). Metrics: bump `requests_total` only.
- `charge_tokens` from proxy terminal track + each modality finalize that records usage (exhaustive list at implement time). Usage-writer retry must not double-charge (request_id key).

#### Tests

eunit: NULL short-circuit; atomic admit; GC; Retry-After bounds; charge idempotency.

TEST-FLOWS:

| ID | Assert |
|----|--------|
| E.Q1 | Unlimited key never quota-429 |
| E.Q2 | `rpm_limit=1` → second admit 429 + Retry-After |
| E.Q3 | Local 400 after admit counts RPM |
| E.Q4 | Modality image path respects rpm |
| E.Q5 | New limit visible on **new** admits after catalog apply |
| E.Q6 | Failover multi-attempt → **one** RPM |
| E.Q7 | Upstream 5xx terminal null usage → RPM only, TPM/daily unchanged |
| E.Q8 | TPM lagging: after charge fills bucket, next admit 429 |
| E.Q9 | Daily rollover at UTC midnight (clock inject or long soak helper) |

---

### 5.2 Slice L — LB explain on `/stats`

```json
"lb_cooldowns": [
  {"target": "provider_key:12", "reason": "auth", "remaining_ms": 4100},
  {"target": "route:3:5", "reason": "http", "remaining_ms": 1200},
  {"target": "provider:2", "reason": "failure", "remaining_ms": 800}
]
```

- Encode from real tuples: `{provider_key,Id}` → `provider_key:<Id>`; `{route,M,P}` → `route:<M>:<P>`; `{provider,P}` → `provider:<P>`.
- Max **64** entries, highest `remaining_ms` first; total JSON array payload ≤ **8 KiB**; omit expired.
- `reason` = write-time `sanitize_cooldown_reason/1` (already on cooldown insert).
- Snapshot via bounded ETS traversal (document: `ets:match_object` / fold with early stop after enough live entries sorted) — **do not** full-sort unbounded table on every scrape if table is huge; prefer heap-select top-K.
- Additive; keep `routes_cooling` + `lb` counters.
- Dashboard: label **which node** the cooldowns belong to (existing node identity).

Tests: eunit truncation/encoding; TF-8.x cooldown via mock 401 storm; assert no route pick; payload bound.

---

### 5.3 Slice A — `x-janus-route`

**Format:** `x-janus-route: <model>;tier=<tier>;origin=<origin>`

- `<tier>` ∈ `fast` \| `big` \| `flagship`
- `<origin>` **closed** (from `janus_auto.erl`):  
  `rules` \| `fallback` \| `no_judge` \| `breaker` \| `cache` \| `negcache` \| `inflight` \| `judge` \| `judge_fail` \| `judge_timeout`
- Model: `/` → `_`; then charset filter; if empty → **omit header** (do not emit garbage).
- Emit only after successful auto resolution on **2xx** path (stream headers or JSON reply). Auto error paths: **absent**.
- Direct listing: **absent**.

Tests: eunit sanitizer (`/`, CR, LF, unicode); E.A1 auto 2xx has header; E.A2 direct model absent; E.A3 streamed auto has header on first response; E.A4 auto 4xx/5xx absent.

---

## 6. Phase 2b (pointer only)

USD pricing · client attribution · Postgres global soft quota · SLO alerts · video M.video.* — separate specs.

---

## 7. Order of work

1. **Migration 014 on aliyun** verified in `schema_migrations` before any follower runs new code that SELECTs new columns (rolling: migrate → then deploy code).
2. Slice Q (paired dashboard + E.Q*).
3. Slice L (can parallel Q **after** 014 if no shared-file conflict; stats-only otherwise parallel anytime).
4. Slice A (small; needs `janus_auto` origin export — no dependency on Q).
5. Stop.

---

## 8. File touch map

**Janus:** `014_api_key_quotas.sql` (+ flats); `janus_db_conn`; `janus_catalog` key fields; `janus_quota` + eunit; post-auth preamble; `janus_http_proxy` (charge + auto header); modality finalize charge sites; `janus_auto` (expose `{Name,Tier,Origin}`); `janus_lb:cooldowns_snapshot/0`; `janus_gateway_stats`; `SCHEMA_ETS_CONTRACT.md`; README.

**Dashboard:** keys API/SPA limits; `SPEC.md` stats; `TEST-FLOWS.md` E.Q* / TF-8.x / E.A*; stats passthrough.

---

## 9. Success criteria

1. Local gate green with new flows; prior E.* / M.1–M.7 / TF-11 green.
2. Unlimited keys: no quota 429; no `x-janus-route` on non-auto.
3. Rolling deploy: 014 leader-first; smoke still read-only.
4. `ocr review` on each slice commit.

---

## 10. Resolved open questions

| # | Resolution |
|---|------------|
| ASR slots vs RPM | Independent |
| Daily TZ | UTC |
| `origin=inflight` | Emitted |
| Auto errors | Header absent |
| Model `/` | Map to `_` |

---

## Changelog

| Rev | Change |
|-----|--------|
| 1 | Initial draft for xray |
| 2 | Fold xray 6/6: NULL short-circuit; once-admit; charge by request_id; TPM lagging; GC; real origins; real cooldown target encoding; Retry-After rules; E.Q6–Q9 / E.A4; payload bounds; drop bit-identical claim; mig-before-code order |
