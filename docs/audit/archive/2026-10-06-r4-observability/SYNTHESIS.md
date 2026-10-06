# Observability plan audit, round 4 — multi-model synthesis

Date: 2026-10-06 (round 4)
Models (via `pi`): MiniMax-M3, mimo-v26-pro, step-5-preview, qwen3.8-max, deepseek-v4-pro (substituted for the flaky flash id), glm-5.3, kimi-k3
Raw replies: docs/audit/*.txt (round 3: docs/audit/archive/2026-10-06-r3-observability/)
Target: `docs/superpowers/plans/2026-10-06-observability-metrics-request-ids.md` rev 4

## Verdicts

| Model | Verdict |
|---|---|
| kimi-k3 | GO WITH FIXES — histogram bump order backwards; janus_req_counted keep-alive leak |
| minimax-m3 | GO WITH FIXES — lb_stat type vs reset semantics; bool01 SMALLINT; bad-bound coercion |
| mimo-v26-pro | GO WITH FIXES — lb_stat type contradiction; observe order comment overstates |
| stepfun-5 | GO WITH FIXES — no new correctness defects; contract contradiction on lb_stat |
| qwen38-max | GO WITH FIXES — atom-order family sort; upstream header clobber; promtool mandatory |
| deepseek-v4-pro | GO WITH FIXES — protocol repr split across paths; gate fragility on endpoint=other |
| glm-53 | GO WITH FIXES — lb_stat counter suffix fails promlint; skip-warning promised not shipped |

**Overall: GO WITH FIXES (7/7).** All confirmed the rev-4 fixes landed. No architectural objections. Findings are now single-file, small, and convergent: the `lb_stat` counter/gauge contradiction (7/7 mentioned the wording split), the histogram bump-order invariant (3/7), and the keep-alive leak of the double-count guard (kimi, precise).

## Consensus (≥3 models) — fixed in rev 5

1. **`lb_stat` type split-brain** (7/7) → renamed `janus_lb_stats_total{stat=...}`, counter (promlint-safe `_total`); naming contract, registry, handler, Grafana note all aligned (LB counters ARE summable; only per-node gauges are node-scoped).
2. **Histogram bump order** (3/7) — buckets → +Inf → sum → `_count` last; comment reworded to best-effort.
3. **`janus_req_counted` keep-alive leak** → erased in each handler `init/2` (authoritative per-request reset) + proxy entry.
4. **Missing non-integer LB skip warning** (5/7) → `logger:warning` on skip (per scrape).
5. **`bool01` SMALLINT** → `1|0|true` handled.
6. **Bad histogram bounds coerced to 0.0** → dropped with a warning.
7. **Gate scoping** (3/7) → token-carrying POST → 405; agent-plane `/metrics` → 404; `endpoint="other"` assertion scoped to feature traffic; `le=+Inf == _count` + monotonicity asserts; promtool parse-fails-gate / lint-advisory policy.
8. **Atom usort ≠ name order** → families sorted by `atom_to_binary`.
9. **init failure silence** → try/catch + `logger:error` (gateway still serves).
10. **`models_serving` duplication** → extracted to `janus_http_stats:models_serving/0`, shared by both handlers.
11. **Mixed-snapshot byte-exact eunit** added (9 renderer tests total).

## Dismissed after review

- **Explicit Path/ReqId params over pdict** — pdict is the module's established pattern (`janus_req_model` precedent); the gate's scoped assertions cover regressions. Kept.
- **Upstream `x-request-id` clobber** — the proxy's `filter_headers/1` passes only content-type; verified by construction + a plan note.
- **`active_requests` gauge** — deferred (leak-prone without full try/after coverage); documented follow-up.
- **Multi-node reachability topology** — README documents per-node scraping over internal network / token-fronted Caddy; federation is out of scope.

## Applied to doc

All items folded into `docs/superpowers/plans/2026-10-06-observability-metrics-request-ids.md` as **rev 5** (committed `c80ffe9`). Round 5 runs for final approval.
