# Observability plan audit, round 8 — final synthesis

Date: 2026-10-06 (round 8 — final)
Models (via `pi`): MiniMax-M3, mimo-v26-pro, step-5-preview, qwen3.8-max, deepseek-v4-pro, glm-5.3, kimi-k3
Raw replies: docs/audit/*.txt (round 7: docs/audit/archive/2026-10-06-r7-observability/)
Target: `docs/superpowers/plans/2026-10-06-observability-metrics-request-ids.md` rev 8

## Verdicts

| Model | Verdict |
|---|---|
| kimi-k3 | GO WITH FIXES — ladder claim-vs-code; commit-list gap; stale "per bump" wording |
| minimax-m3 | GO WITH FIXES — ladder duplication; lb cardinality guard; fk_salvage test |
| mimo-v26-pro | GO WITH FIXES — ladder claim false; handler reads outside try; generate fallback try |
| stepfun-5 | GO WITH FIXES — ladder claim false; quiescence precondition on gate step 2 |
| qwen38-max | GO WITH FIXES — Proto label provenance; HistNames union; promtool install source |
| deepseek-v4-pro | GO WITH FIXES — promtool 3.x removed `check metrics` (pin <3); num_bin non-total |
| glm-53 | GO WITH FIXES — "functionally shippable; every remaining defect is claim-vs-code drift, none runtime-breaking" |

**Overall: GO WITH FIXES (7/7) — converged.** glm's line says it: nothing runtime-breaking remained. The round's findings were dominated by my own changelog claiming a fix (`buckets()` deriving from `?BUCKETS_DESC`) that the listing hadn't applied yet — applied for real in rev 9, along with the promtool pin and the last wording corrections.

## Disposition

All items folded into **rev 9** (committed). The audit loop is closed: eight rounds, every model's verdict was addressed and re-verified, and the last two rounds surfaced only claim-vs-code wording drift — the signal that the plan is done. **The loop was stopped here deliberately rather than running a ninth round against trivia.**

## The final plan

`docs/superpowers/plans/2026-10-06-observability-metrics-request-ids.md` — 10 tasks: migration 009, metrics registry (eunit-first), exposition renderer (eunit-first, byte-exact), `/metrics` handler + shared admin auth, counter hooks (proxy + auth + models + early rejects with double-count guard), request-id module + integration, dashboard read path, E2E gate steps (incl. promtool + histogram invariants), Grafana + scrape config + README ops, final gate + artifacts.

## What the 8 rounds actually fixed (the value of the loop)

Round 1: naming contract (`_total`/`_seconds`), numeric bucket order, float-in-ETS crash, hex casing. Round 2: hardcoded renderer families dropping a locked series, histogram comma-sequence returning only `_count`, stale-tid lifecycle. Round 3: non-total `to_bin`, gauge churn, early-reject coverage hole. Round 4: bump-order invariant, keep-alive leak of the count guard, `lb_stat` type split-brain. Round 5: `+Inf` partitioned out as an invalid bound (would have broken every histogram). Round 6: plan drift vs the real tree (migration 005→009, 15→16 columns, subdir layout, `require_agent/2` preservation). Rounds 7–8: splice artifacts + claim-vs-code drift.
