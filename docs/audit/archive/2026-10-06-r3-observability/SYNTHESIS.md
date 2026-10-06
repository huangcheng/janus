# Observability plan audit, round 3 — multi-model synthesis

Date: 2026-10-06 (round 3)
Models (via `pi`): MiniMax-M3, mimo-v26-pro, step-5-preview, qwen3.8-max, glm-5.3, kimi-k3
Raw replies: docs/audit/*.txt (round 2: docs/audit/archive/2026-10-06-r2-observability/)
Target: `docs/superpowers/plans/2026-10-06-observability-metrics-request-ids.md` rev 3

## Verdicts

| Model | Verdict |
|---|---|
| kimi-k3 | GO WITH FIXES — rev-2 items correctly resolved; stale tid docstrings + lb_stat type + missing registry eunit |
| minimax-m3 | GO WITH FIXES — uptime gauge math unverified; lb_stat label whitelist; active_requests suggestion |
| mimo-v26-pro | GO WITH FIXES — registry to_bin partial (silent series loss class); gate 405 precondition |
| stepfun-5 | GO WITH FIXES — fam_type counter default trap; requests_total coverage hole (early rejects) |
| qwen38-max | GO WITH FIXES — renderer partiality → 500; gauge value-sort churn; zero-fill drops unknown bounds |
| glm-53 | GO WITH FIXES — rev-2 findings confirmed resolved; stale wording + dangling auth-log field |
| deepseek-v41-flash | — (provider empty/failed 5× across both providers; excluded) |

**Overall: GO WITH FIXES (6/6).** Architecture is settled; every model confirmed the round-2 resolutions landed. Findings now cluster on: stale text (tid docstrings), one latent silent-loss path (`to_bin` non-total in the registry), early-reject counter coverage, and small renderer determinism/type details.

## Consensus (≥3 models) — fixed in rev 4

1. **Stale "persistent_term/cached tid" wording** (4/6) — purged from the module doc, Task 2 commit message, and self-review.
2. **Gate step 1 405 precondition** (3/6) — "POST with token → 405" (tokenless POST is 401; auth runs before method dispatch).
3. **Registry `to_bin/1` not total** (2/6, silent series loss) — list/float clauses + a label-normalization eunit with a charlist provider name.
4. **Gauge series sorted by value → churn** → sorted by labels; unregistered gauge families default TYPE gauge.
5. **Zero-fill drops bounds not in the current ladder** → union of ETS-present bounds + canonical ladder, numerically sorted, +Inf last.
6. **Early rejects uncounted** (`no_route`, invalid JSON, translate errors bypass `track/3`) → counted in `reply_err/6` with a `janus_req_counted` double-count guard (erased per request; set by `track/3`).
7. **Auth-reject log `request_id`** — Task 6 now owns it and lists `janus_http_auth.erl`.
8. **`lb_stat` typed counter** (cumulative semantics), `observe` bumps count/+Inf before lower buckets, handler render wrapped in try/catch → 500+log.
9. **Registry eunit moved before the module** (tests-first rule), uptime gauge assertion lives in the gate (not a fake eunit).
10. **Gate hardening**: label-set deltas (not exact +1), no `endpoint="other"` assertion, translate-path (`/v1/messages`) header echo, proxy-404 counting step, structured log-key assertion (not substring), optional `promtool check metrics`.
11. **Docs/schema hygiene**: `docs/SCHEMA_ETS_CONTRACT.md` gains the column; migration notes on index locking + gateway-before-dashboard deploy order.

## Dismissed after review

- **`active_requests` gauge** — disconnect-safe dec requires wrapping the whole handler in try/after; deferred as a documented follow-up rather than a leaky gauge.
- **`ets:info(Tid, size)` for models_serving** — the models table is dual-keyed (id + name), so size would double-count; the existing dedup approach stands.
- **NUL/tab/CR in request ids** — the charset allowlist already rejects them before any label/log use.

## Applied to doc

All items folded into `docs/superpowers/plans/2026-10-06-observability-metrics-request-ids.md` as **rev 4** (committed `6736dcd`). Round 4 runs for final approval.
