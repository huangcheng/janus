# Janus Auto Router — Configurable Local Decision Judge

Status: **v1.3.1 — implementation-ready** (pi-audit r1–r4; no remaining ≥5/7 critical blockers)  
Parent: [SPEC.md](SPEC.md) v2.5  
Date: 2026-10-14  
Audit artifacts: `docs/audit/` (repo root; gitignored)

## 1. Goal / Non-goals

**Goal.** Configurable `janus-auto` judge backends:

| `judge_backend` | Behavior |
|---|---|
| `off` | Rules-only → soft `default_tier` |
| `online` | Existing chat judge (`judge_model`) |
| `local` | Loopback System One sidecar + lazy weight download |

**Non-goals.** BEAM inference; cross-cloud judge; training; Kev/OpenDecider packaging (same HTTP later); changing parent rules/hard-soft/tiers; local abstain/margin; extra fallback cost throttles beyond online semaphore.

## 2. Principles

1. Router never invents 5xx (parent §2.3).
2. Gateway is a thin HTTP client to a colocated sidecar.
3. Lazy download (Octop-style); agent path never waits on pulls.
4. Cache identity = `local:<artifact>:<sha12>` of weights **snapshotted at decide-call open**; pos-write uses that snapshot (not a later healthz).
5. Sidecar binds `127.0.0.1` only; masters only; no off-loopback publish.
6. `:8090` stays read-only. Ensure = gateway → loopback on settings apply (§7).

## 3. Config

```json
{
  "judge_backend": "off",
  "judge_model": null,
  "local_judge": {
    "endpoint": "http://127.0.0.1:8191",
    "artifact": "laya-multilingual",
    "artifact_url": null,
    "artifact_sha256": null,
    "timeout_ms": 800,
    "local_max_inflight": 8,
    "ensure_generation": 0
  }
}
```

| Field | Default | Notes |
|---|---|---|
| `judge_backend` | `off` | unknown → `off` + error log |
| `judge_model` | null | required for `online`; optional fallback for `local`; ≠ virtual name |
| `endpoint` | `http://127.0.0.1:8191` | loopback only; store **literal** after normalize |
| `artifact` | `laya-multilingual` | |
| `artifact_url` | null | allowlisted; requires sha256 |
| `artifact_sha256` | null | else sidecar map pin = effective sha |
| `timeout_ms` | `800` | abandon budget; enable only if measured p95 has headroom |
| `local_max_inflight` | `8` | dedicated; not shared with online |
| `ensure_generation` | `0` | bump via settings PUT to re-ensure |
| `cache_name` | derived | always `local:<artifact>:<sha12>`; not operator-free-form in v1 |

**Compat:** absent `judge_backend` → `online` if `judge_model` set else `off`. Local requires explicit `judge_backend=local`.

**Loopback predicate** (Python + Erlang + shared fixture vectors): accept only canonical `127.0.0.1` and `::1` after normalize; map `localhost`→`127.0.0.1` at write; reject other DNS, `127.0.0.0/8` beyond `.1` optional tighten to **only** `127.0.0.1`/`::1` (v1.3: **only these two**).

**Validation:** non-loopback → reject write / gateway `off`. `artifact_url` without sha or non-allowlisted host → reject. Re-validate fallback `judge_model` on distribute; if invisible → fallback absent (keep backend local).

**Labels:** non-empty tier lists only. All tiers empty → skip judge → `default_tier`.

## 4. Judge-zone pipeline

Rules gate first; hard hits never call judge.

```
local path:
  snapshot identity I = local:<artifact>:<sha12> from readiness cache
       (if not ready / sha missing → fallback; see not-ready gate)
  if breaker open (not half-open probe) → fallback
  if inflight full → fallback (no breaker bump)
  decide with I frozen for this call
  200 + tier ∈ labels → pos_write(I); clear breaker fails
  503 exact {downloading:true}|{ready:false} → fallback; no breaker
  other fail → breaker_fail++; fallback; no neg-write
```

**Fallback:** online once if `judge_model` set (online semaphore/breaker apply); else `default_tier`. Online inflight full → `default_tier`.  
**No pos-write on fallback. No neg-write from local backend.**

### 4.1 Breaker (mandatory)

5 consecutive non-exempt fails → skip 60s. **Half-open:** after 60s exactly one probe (inflight slot reserved); success closes; fail re-opens 60s. Exempt: exact 503 bodies above, not-ready gate skip, inflight-full.

### 4.2 Readiness + not-ready gate

- Initial: **not-ready**.
- Poll `/healthz` every **5s**, timeout **1s**; two consecutive poll failures → not-ready.
- `contract_version ≠ 1` or healthz sha ≠ configured effective sha → not-ready + `error`.
- **Not-ready skip gate:** if not-ready for **N=12** consecutive polls (~60s) → skip local attempts for **K=60s** (no decide HTTP), then one probe poll; independent of decide-breaker. Prevents permanent-broken sidecar from taxing every request with decide RTT.
- Hot path never calls healthz.

### 4.3 Inflight

Dedicated atomics, default 8.

## 5. Sidecar

Bind `127.0.0.1` only. Compose: **`network_mode: "service:janus"` only** (delete host-publish alternative).

- `GET /healthz` → ready, downloading, artifact, artifact_sha256, contract_version=1, error  
- `POST /admin/ensure` body `{artifact, artifact_url?, artifact_sha256?, ensure_generation}`; header `x-janus-judge-token` **required** — if `JANUS_JUDGE_TOKEN` unset/empty, sidecar **rejects all ensure** (fail-closed). 202 immediate if downloading; 200 if ready.  
- `POST /v1/decide` — same token required (fail-closed). Prefixes ≤256/≤1200 code points (gateway truncates). Inference deadline ≤ `timeout_ms−100`. Workers ≤ `local_max_inflight`. Never log prefixes at info.  
- Decide 200 may echo `artifact_sha256`; gateway still stamps frozen I from call-open.

## 6. Gateway

`janus_auto` owns normalize, decide client, breaker, readiness poller (single writer), snapshot counters: `local_ok|fail|fallback_online|fallback_default|skip_breaker|skip_not_ready|inflight_full|fallback_online_fail|skip_not_ready_gate`.

On settings apply with `backend=local`: async loopback ensure (does not block distribute). Ensure backoff: exponential, cap 5 attempts per generation, jitter.

## 7. Ensure plane (locked — single path)

1. Dashboard `PUT settings.auto_router` (existing), optionally bump `ensure_generation`.  
2. Master gateway distributes settings (existing).  
3. `janus_auto` async `POST http://127.0.0.1:8191/admin/ensure` with token.  
4. UI reads readiness from snapshot/`/stats` (8090 read-only).

No ensure on 8090/8080. No dashboard dial to `:8191`. No SSH.

## 8. Failure table

| Scene | Behavior |
|---|---|
| off | default_tier |
| local ok | soft + pos(I) |
| exempt 503 / not-ready | fallback; no breaker |
| not-ready gate open | fallback; no decide HTTP |
| other local fail | breaker++; fallback; no neg |
| fallback online ok | soft; no pos |
| fallback shed/fail | default_tier |
| token missing | sidecar rejects ensure/decide; gateway sees fail → fallback |

## 9. Deploy

- `janus-judge` + `network_mode: service:janus` + volume + `JANUS_JUDGE_TOKEN` + healthcheck.  
- Masters on regional hosts; CN mirror allowlist.  
- Homogeneous sha across fleet peers recommended when fleet cache on (misses if divergent — by design).

## 10. Observability

Debug reasons as counters above + parent reasons. Propagate request trace id on decide when present.

## 11. Testing

- eunit first: loopback fixtures (both langs); no pos-on-fallback; no local neg; half-open; not-ready gate; identity frozen at call-open; ensure backoff.  
- Sidecar: CI fixture ≤50MB + golden labels in `sidecars/janus_judge/testdata/`.  
- E2E: real container; stop sidecar → fallback; Router toggle screenshot. No prod mutation.

## 12. Rollout

Ship idle sidecar → gateway/settings → dashboard → measure p95 → enable per cloud.

## 13. Locked decisions

Full stack; soft fallback; Laya multilingual pinned sha; loopback per master; ensure via settings→gateway→loopback; no pos on fallback; no local neg; 8090 read-only; compose `network_mode: service:janus` only; token fail-closed.

## 14. Wire formats (normative)

All JSON; `Content-Type: application/json`. Auth header on ensure + decide: `x-janus-judge-token: <JANUS_JUDGE_TOKEN>`.

### 14.1 `GET /healthz` → 200

```json
{
  "ready": false,
  "downloading": true,
  "artifact": "laya-multilingual",
  "artifact_sha256": "hex64_or_null",
  "contract_version": 1,
  "error": null
}
```

Exempt decide 503 bodies are objects where `downloading===true` **or** `ready===false` (field match, not byte-identical stringify).

### 14.2 `POST /admin/ensure`

Request:

```json
{
  "artifact": "laya-multilingual",
  "artifact_url": null,
  "artifact_sha256": null,
  "ensure_generation": 3
}
```

Response 200 `{ "ready": true, "artifact_sha256": "…" }` · 202 `{ "downloading": true }` · 401 missing/wrong token · 500 `{ "error": "…" }`.

### 14.3 `POST /v1/decide`

Request:

```json
{
  "system_prefix": "…",
  "user_prefix": "…",
  "out_budget": "Output budget: <=2k tokens",
  "labels": ["fast", "big"]
}
```

Response 200:

```json
{
  "tier": "fast",
  "scores": { "fast": 0.71, "big": 0.29 },
  "artifact_sha256": "hex64"
}
```

`scores` and `artifact_sha256` optional; gateway identity stamp remains the call-open readiness snapshot (`I`). 401 token fail → gateway treats as local fail (breaker++). 503 with §14.1 exempt fields → no breaker bump.

### 14.4 Golden fixtures

`sidecars/janus_judge/testdata/` ships ≤50MB weights + `golden.json` mapping `{system_prefix,user_prefix,labels} → tier` for eunit/sidecar CI.
