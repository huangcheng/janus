# Janus plan audit — multi-model synthesis

Date: 2026-10-02  
Models (via `pi`): MiniMax-M3, MiMo v2.6 Pro, StepFun 5 Preview, Qwen3.8-Max, DeepSeek V4.1 Flash (Volcengine), GLM-5.3 (zhipuai-coding-plan), Kimi k3  
Raw replies: `docs/audit/*.txt` · snapshot: `docs/audit/target.md`

## Verdicts

| Model | Verdict |
|---|---|
| MiniMax-M3 | GO WITH FIXES — streaming translation, secrets, degraded boot need hardening |
| MiMo v2.6 Pro | GO WITH FIXES — retry/translation/secrets under-specified (schedule risk) |
| StepFun 5 Preview | GO WITH FIXES — translation scope, LB semantics, dual-DB adapter under-specified |
| Qwen3.8-Max | GO WITH FIXES — unsafe to ship before streaming fidelity / config sync / secrets |
| DeepSeek V4.1 Flash | GO WITH FIXES — mid-stream retry, translation, multi-node secrets underspecified |
| GLM-5.3 | GO WITH FIXES — retry, upstream HTTP client, cache-refresh unspecified |
| Kimi k3 | GO WITH FIXES — retry, translation scope, secrets under-specified |

**Overall: GO WITH FIXES (7/7).** No NO-GO. Architecture split (DB = config SoR, ETS = hot path) is endorsed; first-ship gaps are operational.

## Consensus (≥5 of 7)

1. **Retry only before first client byte (7/7).** Mid-stream “cool and retry next” duplicates/garbles SSE and tool calls. Contract: pre-flush retries only (bounded, e.g. ≤1); post-flush emit error event and terminate.
2. **NOTIFY is lossy — need generation + poll (7/7).** Every admin write bumps `config_generation`; NOTIFY carries it; periodic full poll catches missed events; atomic ETS table swap (never in-place mutate).
3. **Secrets / agent keys (7/7).** Shared `JANUS_SECRETS_KEY` on all nodes; encrypt provider secrets at rest; store **hashed** agent API keys (not plaintext); decide admin auth (cookie vs bearer); document rotation / missing-key boot failure; never return key material after write.
4. **Translation is the largest scope risk (7/7).** “Minimal tools” hides tool_call deltas, stop_reason mapping, system blocks, usage/errors. Need an explicit field/SSE mapping table + golden transcript fixtures; shrink v1 cross-protocol (several: chat↔messages only; defer `/v1/responses` cross-translate).
5. **Transport guarantees missing (6/7).** Name upstream HTTP client; connect/TTFB/stream-idle timeouts; max body size; client disconnect → cancel upstream; Cowboy SSE/`stream_body` notes.
6. **“Native cluster LB” overclaims (6/7).** As written, cool-downs/RR are **per-node**; Caddy only spreads. Rename to node-local LB + shared config; state N-node retry amplification as accepted or add jitter/half-open probe.
7. **Disk snapshot must not stay “optional” (5/7).** Cold start with DB down needs a defined trusted snapshot path (or refuse traffic).
8. **Observability in v1, not only hardening (5/7).** Request IDs, structured logs (channel, retries, upstream status), basic counters; `/healthz`/`/readyz`.
9. **Postgres+SQLite = dialect-aware migrations (5/7).** Same logical schema, not one SQL file for both; `janus_db` behaviour + per-dialect DDL.

## Near-consensus (4/7 — fix anyway)

- Rate limits appear in `api_keys` schema but “hardening” phase — either implement a minimal hot-path limiter in v1 or drop the column until later.
- Secret ownership: `providers.auth` vs `provider_keys` overlap — one clear table for secrets.
- Weight precedence: provider weight vs route override vs key RR needs one sentence.

## Split opinions (do not auto-apply)

- **SQLite in v1 runtime:** StepFun (and lean) — Postgres-only for v1, SQLite as local/dev preset only. Others keep dual backend. → User already chose configurable DB; keep dual backend, but make dialect-aware migrations explicit (consensus #9).
- **When to build translation:** DeepSeek/GLM want mapping+fixtures earlier (phase 2); plan puts admin UI before heavy translation. → Open decision: translate-before-admin vs admin-before-translate.
- **Upstream client:** gun vs hackney/req — pick in implementation spike, not by majority.
- **Responses state model:** passthrough only vs stored `previous_response_id` — defer full Responses semantics or document “stateless upstream only.”

## Ground-truth notes

- Scaffold at `F:/Janus` already exists (`repo-skeleton` completed); remaining phase-1 items belong under `schema-ets`, not “skeleton incomplete.”
- Dual DB was an explicit product choice (Postgres when env set, else SQLite) — do not delete SQLite from the plan based on one auditor.

## Applied to plan

Consensus edits folded into the live plan (see plan file): retry contract, config generation + poll, secrets/hashing, node-local LB naming, transport/observability first-ship, dialect-aware migrations, mandatory snapshot, Responses descope for cross-protocol, mapping-table requirement. Splits left open for the user.
