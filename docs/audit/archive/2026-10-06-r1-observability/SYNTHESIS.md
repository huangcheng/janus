# Observability plan audit, round 1 — multi-model synthesis

Date: 2026-10-06
Models (via `pi`): MiniMax-M3, mimo-v2.6-pro, step-5-preview, qwen3.8-max, deepseek-v4-1-flash, glm-5.3, kimi-k3
Raw replies: docs/audit/*.txt
Target: `docs/superpowers/plans/2026-10-06-observability-metrics-request-ids.md` rev 1

## Verdicts

| Model | Verdict |
|---|---|
| kimi-k3 | GO WITH FIXES — le_bin function_clause; float counter; bucket order; Req threading |
| minimax-m3 | GO WITH FIXES — bucket sort, HELP lines, info type, XFF doc, per-node scrape |
| mimo-v26-pro | GO WITH FIXES — naming mismatch, hex casing, ETS owner/init, mapper drift |
| stepfun-5 | GO WITH FIXES — float update_counter badarg, naming, pdict erase, per-node jobs |
| qwen38-max | GO WITH FIXES — hot-path crash, string:join badarg, duplicate TYPE, zero-series gap |
| glm-53 | GO WITH FIXES — gate-breaking naming, bucket order, dashboard task missing |
| deepseek-v41-flash | GO WITH FIXES — naming, ~g precision, init idempotency, status_class catch-all |

**Overall: GO WITH FIXES (7/7).** Architecture endorsed unanimously (ETS registry with update_counter default tuple, pure renderer, terminal-path hook, sanitized ids, shared admin auth). The findings are contract/exposition-level; two would have failed my own E2E gate (naming mismatch) or crashed the data plane on the first request (float sum, integer buckets).

## Consensus (≥5 models) — fixed in rev 2

1. **Series naming contradiction (7/7).** Renderer emitted `janus_requests`; gate/Grafana expect `_total`/`_seconds`. → Locked naming contract; call sites register `requests_total`/`upstream_requests_total`/`request_duration_seconds`; tests assert exact strings.
2. **Bucket ordering (6/7).** Lexicographic binary sort breaks `histogram_quantile`. → numeric sort, `+Inf` pinned last, exact-output eunit with the full bucket set.
3. **Float/integer ETS bumps (5/7).** `update_counter` is integer-only; float `hist_sum` risks badarg on the hot path. → histogram sums stored as integer microseconds, ÷1e6 at render.
4. **Scrape config per-node (5/7).** One job per node with per-node token files (multi-node counters are node-local; Grafana sums across instances; never sum LB gauges).
5. **`~g` float precision + formatting** → `float_to_binary(F, [short])` everywhere.

## Near-consensus (fixed in rev 2)

- **`le_bin/1` crashed on integer buckets** (hot path 500) — buckets are now all floats with precomputed rendered binaries.
- **Zero-series gap on fresh scrape** (gate step 2 failed by design) — gate asserts `janus_build_info` first; request-series assertions happen after the call.
- **HELP lines + one TYPE per family + deterministic family order** — renderer groups by family, emits HELP once, sorts families.
- **`string:join` on binaries** → `lists:join/2`.
- **Idempotent `init/0` + tid cached in persistent_term** (no per-bump `ets:info`, restart-safe).
- **try/catch on every bump** — observability never crashes the data plane.
- **`status_class` catch-all → `unknown`** (no silent 2xx).
- **Shared `janus_http_classify`** — one path→endpoint/protocol mapper for proxy + auth + models (no drift).
- **Lowercase hex ids** (`encode_hex` is uppercase) + gate regex alignment.
- **Auth rejects**: single funnel verified (`janus_http_auth:unauthorized`), gains a `janus_agent_reject`-style warning log with `request_id` (metrics never carry id labels).
- **`/v1/models` labeled `protocol="none"`** (not a fake `openai_chat`); double-count verified absent (separate handler, not proxied).
- **Placeholder-gauge hack + dead `Base` binding** removed; the writer-dropped counter appends as a real counter row.
- **Dashboard repo task added** (`/api/usage/events` exposes `request_id`; SPA column) — gate step 6 depends on it.
- **E2E robustness**: poll-wait for the async usage row; stream echo asserted; log check via `/stats/logs` substring.
- **Request-id pdict survival**: `handle/5`'s erase list must not gain `janus_request_id`/`janus_req_path` — called out explicitly.
- **LB stats exported as gauges** (`janus_lb_stat{counter=...}`) — an LB gateway without failover metrics was the best "missing" catch.

## Dismissed after review

- **Loopback auth behind Caddy** — the check reads the socket peer, never headers; documented instead of changed.
- **`statistics(wall_clock)` "destructive read"** — it resets nothing; non-issue.
- **Cowboy 404s (no route) carry no request id** — accepted, documented.
- **CREATE INDEX boot lock** — table is small at this scale; migration ledger dedupes the non-idempotent ALTER.

## Applied to doc

All items folded into `docs/superpowers/plans/2026-10-06-observability-metrics-request-ids.md` as rev 2 (rewritten, fixes inline). Round 2 runs next.
