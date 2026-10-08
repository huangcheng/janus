# Slice Q — Agent-key quotas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce per-agent-key RPM / TPM / daily-token limits on the Janus data plane (per-node ETS), with dashboard CRUD for the three nullable limit columns.

**Architecture:** Migration 014 adds `rpm_limit`, `tpm_limit`, `daily_token_limit` on `api_keys`. Catalog loads them into agent maps. `janus_quota:admit/1` runs once after auth in `janus_http_preamble` and `janus_modality` (not `/v1/models`). Terminal `charge_tokens/4` runs from proxy `do_track` and modality `record_usage`. Unlimited (`NULL`) keys short-circuit with no ETS writes.

**Tech Stack:** Erlang/OTP ETS, epgsql/esqlite migrations, Cowboy, FastAPI keys router, sibling TEST-FLOWS (E.Q* added as stubs documenting acceptance).

**Spec:** `docs/superpowers/specs/2026-10-08-industrial-operator-phase2-design.md` §5.1 (rev 2)

## Global Constraints

- Pure gateway; no Redis; per-node counters only
- eunit **first** for `janus_quota` with production-shaped maps
- SMALLINT enabled stays 0/1; limits are INTEGER/BIGINT NULL
- Dual-repo: dashboard keys API paired; E2E E.Q* may land in a follow-up dashboard PR if gate wiring is large — document stubs in TEST-FLOWS
- Aliyun migrates 014 before followers run new SELECT

---

### Task 1: eunit + `janus_quota` module

**Files:**
- Create: `apps/janus_core/src/janus_quota.erl`
- Create: `apps/janus_core/test/janus_quota_tests.erl`

**Interfaces:**
- Produces: `ensure/0`, `admit/1`, `charge_tokens/4`, `retry_after_sec/1`

- [ ] Write failing eunit (NULL short-circuit, rpm exceed, charge idempotency, TPM lagging)
- [ ] Implement module
- [ ] Docker eunit green for this suite

### Task 2: Migration 014 + catalog/db

**Files:**
- Create: `priv/migrations/{postgres,sqlite}/014_api_key_quotas.sql` + flat copies
- Modify: `janus_db_conn.erl` SELECT, `janus_catalog.erl` Meta map, `SCHEMA_ETS_CONTRACT.md`

### Task 3: Wire admit + charge + 429

**Files:**
- Modify: `janus_http_preamble.erl`, `janus_modality.erl`, `janus_http_proxy.erl` `do_track`

### Task 4: Dashboard keys API

**Files:**
- Modify: `../janus-dashboard/app/routers/keys.py` (+ SPA only if trivial; else API-only first)
- Modify: `../janus-dashboard/docs/TEST-FLOWS.md` — E.Q1–E.Q9 stubs

### Task 5: Commit + `xray code` + ocr
