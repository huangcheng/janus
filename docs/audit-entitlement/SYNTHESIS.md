# SYNTHESIS — Rounds 9–11 (final state, 2026-10-05/06)

## Verdict table (round 11)

| model | verdict |
|---|---|
| minimax-m3 | GO WITH FIXES |
| mimo-v26-pro | GO WITH FIXES |
| stepfun-5 | GO WITH FIXES |
| qwen38-max | GO WITH FIXES |
| deepseek-v41-flash | GO WITH FIXES |
| glm-53 | GO WITH FIXES |
| kimi-k3 | GO WITH FIXES |

All rounds 2–11: 7/7 GO WITH FIXES, zero NO-GO. ~90 distinct
consensus findings folded inline across 11 revisions. Rounds 9–11
folded: broken-key lifecycle (carrier + healing priority + never a
fail-open candidate + all-broken terminal), secret-rotation generation
bumps, codes-table admin ownership (write validation, escalated reset,
key_scoped_balance flag), balance canary qualification + 429 traffic
probe trigger, vanished-listing cleanup, knob validation + gateway
clamp, pool-reuse rename, aliasing statement, sqlite block removal,
matrix-less alarm, deploy order, request_ref index, first-call
overrun note, "last error" definition.

## Convergence assessment (why this is the pass state)

Round-over-round findings decayed: architecture failures (R1–3:
ownership, unimplementable learning, off-by-one, carrier TTL) →
lifecycle gaps (R4–6: ceiling math, broken carrier, budget economy) →
edge interactions (R7–8: 400 semantics split, escalated freeze) →
wording (R9–11: "in-process lock" phrasing survived three folds
because each fold script targeted a different sentence). Rounds 10–11
produced no new consensus ≥5/7; remaining items are split opinions
(e.g. minimax wants unclassified-400-as-unclassified; qwen wants the
same phrase as input_shape — mutually exclusive requests on identical
text) or restatements of accepted v1 limits the spec already
documents (no pool breaker; 45s vs 30s client budgets; unseeded
provider deny burns one retry until codes updated — each explicitly
accepted in-line with rationale).

Adversarial "be skeptical" prompts on a 500-line spec converge to a
noise floor of one-wording findings, not zero findings. 7/7 GO WITH
FIXES with every consensus item folded and splits preserved below is
the converged state of this document.

## Open splits for the user (NOT folded — decisions)

1. `failover_max_budget_ms` default: 45000 (compromise, current spec)
   vs 60–90s for slow upstreams (minimax, kimi) vs ≤30s for tight
   clients (glm). Runtime knob; default is a one-line change.
2. First-call TTFB exceeding the budget: accepted by design (spec
   states it); minimax would prefer a split first-call/retry budget.
3. Pool-level breaker: accepted absent in v1 (per-key cooling only);
   three models re-flag it each round — v1.1 candidate.
4. Traffic-based deny learning gated on E.1 (error_code capture) —
   stepfun suggests shipping E.1 in v1 instead of v1.1.

## Artifacts

- Spec: `docs/superpowers/plans/2026-10-05-entitlement-failover.md`
  (rev 8b231ccf + final wording fix)
- Raw replies: `archive/round1..round10/` (round0 = invalid
  prompt-contamination round, README explains)
- prompt.md unchanged since round 1 (comparability preserved)
