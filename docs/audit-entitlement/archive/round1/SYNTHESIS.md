# SYNTHESIS — Round 1 (2026-10-05, audit-entitlement)

Prompt corrected after round-0 contamination (parallel session's prompt/target collided in docs/audit/; this round ran from docs/audit-entitlement/ with the right pair). 7/7 replies, all on-target.

## Verdict table

| model | verdict |
|---|---|
| minimax-m3 | GO WITH FIXES |
| mimo-v26-pro | GO WITH FIXES |
| stepfun-5 | GO WITH FIXES |
| qwen38-max | GO WITH FIXES |
| deepseek-v41-flash | GO WITH FIXES |
| glm-53 | GO WITH FIXES |
| kimi-k3 | GO WITH FIXES |

Overall: **GO WITH FIXES (7/7)** — no NO-GO. Round-0 (mixed prompt) additionally
produced substantive findings from 5 models; both sets folded below.

## Consensus (≥5 of 7) — applied to the spec

1. **Write ownership contradiction** (6: stepfun,kimi,qwen,deepseek,glm,mimo): A.1
   claimed the gateway writes `source='traffic'` rows; A.3/Part C say otherwise.
   → Matrix writes are dashboard-only; the gateway is reader-only. A.1 rewritten.
2. **Traffic deny-learning unimplementable today** (6): usage_events carries no
   error text; status-only 400 cannot distinguish deny from input-shape (the exact
   uni-api bug). → v1 traffic learning promotes `ok` ONLY; deny-from-traffic is
   gated on an explicit prerequisite: usage_events.error_code capture (migration +
   gateway write path) — specced as its own task.
3. **Deny-regex false positives / language** (7): English-only regex; "no
   permission"/"unsupported operation" often input-shape; Ark returns 400
   InvalidEndpointOrModel (not 404). → Classification switched to
   provider-documented error CODES first, regex second (multi-language fixtures);
   ambiguous 400 → `input_shape` (fail-open), never deny; per-provider fixture
   vectors added to the test plan.
4. **Balance starvation** (7): balance excluded up to 7d with no refresh; topped-up
   key stays dark. → balance TTL 1h → auto `unknown`; deny TTL 24h → `unknown`;
   traffic 429-balance demotes ok→balance; probe re-check endpoint.
5. **Latency budget** (6): worst case (attempts+1)×TTFB vs idle_timeout/client
   budgets. → shared wall-clock deadline `failover_max_budget_ms` (default 90s),
   5xx retry consumes the same budget, jitter 100–300ms between attempts.
6. **Attempt accounting** (5): off-by-one in C.1 guard; 5xx envelope ambiguity;
   same-request repick. → total upstream calls ≤ failover_max_attempts; provider
   retry inside budget; per-request attempted-set dedupe.
7. **Knob delivery** (7): via `settings` table → persistent_term (repo invariant),
   not sys.config.
8. **Key rotation staleness** (7): secret rotation keeps rows; new key = all
   unknown. → key update/delete invalidates that key's rows; key insert triggers
   bootstrap probe.
9. **Probe blowback & bump storms** (7): pacing, 429-rate backoff, one
   bump_generation per batch (not per row); sequential-vs-5-in-flight contradiction
   resolved (per key sequential over listings; ≤2 keys in parallel).
10. **Zero-eligible-keys path** (5): undefined. → fail-open single attempt ignoring
    the matrix (logged + counted) — stale advisory data must not cause total outage.
11. **Per-attempt usage rows semantics** (6): add `attempt` column; only the
    terminal row bills/aggregates; failed attempts are operator-visibility.

## Strong minority (4/7, factually verified — applied)

- Carrier SQL shipped `ok` rows then discarded; sqlite dialect variant; boot
  tolerance for a missing table (query tolerant → empty matrix, logged once).

## Split opinions (NOT applied — for the user)

- glm: default failover_max_attempts < 3 on streaming-heavy fleets (kept default 3).
- minimax/glm: non-idempotent retry risk after upstream commit — accepted tradeoff,
  documented (bounded to 5xx/transport, one retry).

## Applied where

docs/superpowers/plans/2026-10-05-entitlement-failover.md — Parts A–D rewritten
inline (single source of truth; no addendum). Round-0 invalid replies kept in
archive/round0-mixedprompt/ with README.
