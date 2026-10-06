# Observability plan audit, round 5 — multi-model synthesis

Date: 2026-10-06 (round 5)
Models (via `pi`): MiniMax-M3 (retry), mimo-v26-pro, step-5-preview, qwen3.8-max, deepseek-v4-pro, glm-5.3, kimi-k3
Raw replies: docs/audit/*.txt (round 4: docs/audit/archive/2026-10-06-r4-observability/)
Target: `docs/superpowers/plans/2026-10-06-observability-metrics-request-ids.md` rev 5

## Verdicts

| Model | Verdict |
|---|---|
| kimi-k3 | GO WITH FIXES — new bad-bound partition drops +Inf from every histogram (self-breaking) |
| minimax-m3 | GO WITH FIXES — wants count-first observe order; per-request tid caching; ops docs |
| mimo-v26-pro | GO WITH FIXES — +Inf partition bug; ascending bumps break gate monotonicity assert |
| stepfun-5 | GO WITH FIXES — +Inf partition bug; descending order; renderer impurity (logger) |
| qwen38-max | GO WITH FIXES — +Inf partition bug; strong_rand_bytes unguarded; crypto dep missing |
| deepseek-v4-pro | GO WITH FIXES — +Inf partition bug; handler to_bin non-total; maps:fold sloppy |
| glm-53 | GO WITH FIXES — ascending-bump monotonicity race; 413 contradiction; Route/LatencyMs verify |

**Overall: GO WITH FIXES (7/7).** One bug dominated: my rev-5 "drop unparseable bounds" fix partitions `+Inf` out as `invalid` (it never parses as a float) — every histogram would render without its mandatory `+Inf` bucket, failing the plan's own byte-exact tests. 5/7 caught it independently. The bump-order question split the panel (minimax: count-first; mimo/stepfun/glm/qwen: +Inf-first-descending) — resolved for the majority direction (+Inf → descending ladder → sum → count last), which preserves bucket monotonicity AND `count ≤ +Inf` at every interleaving; exact `count == +Inf` is asserted only at quiescence (ETS has no multi-key transaction).

## Fixed in rev 6

- `+Inf` whitelisted before the validity partition + the partition drops silently (renderer purity restored — no logger inside `render`).
- Observe order: `+Inf`, descending ladder, `_sum`, `_count` last; comment claims only what's true.
- Gate: `+Inf ≥ _count` with quiescence note; tokenless `/stats` 401 regression; 401 full-label-set assert; streamed-call usage-row `request_id` assert (process-boundary risk); SPA column browser-verified (rule 4).
- `crypto` added to `janus_http.app.src` (the admin auth's `hash_equals` worked only via cowboy's transitive dep) + `generate/0` guarded with a `unique_integer` fallback.
- Handler `to_bin` delegates to the registry's total one (now exported); LB skip-warning batched one-per-scrape.
- Task 4 commit list includes `janus_http_stats.erl`; 413 wording disambiguated (handler body-limit excluded, proxy `request_too_large` counted); concurrent-observe final-consistency eunit; token-rotation + Grafana-provisioning ops notes.
- `janus_lb:stats/0` verified cumulative-for-boot-lifetime by reading `janus_lb.erl` (ETS stats map, increments only) — the `_total` counter TYPE is pinned to that source read.

## Dismissed after review

- **minimax's count-first order** — contradicts the other four; count>+Inf is the worse transient. Majority direction adopted.
- **minimax's "encode_hex is lowercase by default"** — it is uppercase by default; the `string:lowercase` wrap stays.
- **Per-request tid caching in pdict** — 19 `ets:whereis`/request is sub-µs; not worth the lifecycle complexity.
- **Renderer calling `janus_metrics:buckets()`** — same-app coupling to the canonical ladder is intentional (no drift possible).

## Applied to doc

All items folded into `docs/superpowers/plans/2026-10-06-observability-metrics-request-ids.md` as **rev 6** (committed `1d7ea49`). Round 6 runs for final approval.
