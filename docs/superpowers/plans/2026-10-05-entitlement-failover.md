# Key Entitlement Matrix + In-Request Key Failover — SPEC

> **For implementers:** this document is the single source of truth; two
> audit rounds are folded inline. All comments, commits, and docs in English.

**Goal.** A provider key may only access a subset of the provider's model
catalog (verified in production: DashScope lists 262 models, third-party
families activated on only 1 of 3 pool keys; Ark lists 135, 15 callable;
zhipu coding-plan keys only work on the coding endpoint). Today the LB
picks keys blind and learns by failing requests: the failed request is
returned to the client, the key cools down, the NEXT request benefits.
This spec replaces that with (1) a per-(key, model) entitlement matrix
maintained by cheap probes plus conservative traffic learning, and (2)
in-request key failover so a key-scoped upstream failure never reaches
the client while another usable key exists.

**Architecture boundary.** The matrix is dashboard-owned (repo
`janus-dashboard`): the dashboard is the ONLY writer of
`key_entitlements`; the gateway is reader-only via the existing catalog
bundle/generation-poll mechanism. The gateway never writes
management-plane tables; it reports evidence through usage events.

---

## Part A — Entitlement matrix (management plane, dashboard)

### A.1 Data model

Dashboard `ensure_schema` (like `gateway_nodes`):

```sql
CREATE TABLE IF NOT EXISTS key_entitlements (
    provider_key_id BIGINT NOT NULL REFERENCES provider_keys (id) ON DELETE CASCADE,
    model_name      TEXT  NOT NULL,   -- listing name; '__key__' = key-level row
    status          TEXT  NOT NULL CHECK (status IN ('ok','deny','balance','unknown','broken')),
    http_status     INTEGER,
    error_code      TEXT,                    -- provider-native code when known
    checked_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),  -- evidence time (NOT fold time)
    source          TEXT  NOT NULL DEFAULT 'probe' CHECK (source IN ('probe','traffic')),
    escalated       BOOLEAN NOT NULL DEFAULT FALSE, -- set after 3 consecutive input_shape re-probes; only non-premarked rows can escalate
    PRIMARY KEY (provider_key_id, model_name)
);

-- The '__key__' row is the BROKEN-KEY carrier: probe-abort 401/403
-- evidence (A.2) writes status='broken' with model_name='__key__'; it
-- ships in the Part B carrier with deny's TTL window and makes C.1's
-- "skip known-broken keys" implementable. Secret updates delete it
-- (A.1 clears all rows AND bumps the generation so gateways drop the
-- stale broken mark immediately).
```

Semantics and lifetimes (hard rules — consumers enforce by `checked_at`):
- `ok` — key MAY call the model (last evidence 2xx). Dashboard-side
  staleness: re-probed after 3 days (1h if input_shape-flagged).
- `deny` — provider said the key lacks entitlement (classified per
  A.2). Valid **24h**, then consumers treat as `unknown` (a
  provider-side re-enable must self-heal within a day; the starvation
  loop — excluded keys get no traffic, so traffic can never heal them —
  is why deny TTL is short and healing is probe-driven, not
  traffic-driven).
- `balance` — key authenticates but lacks quota (429 billing class).
  Valid **1h**, then `unknown`. A topped-up key returns to the pool
  within an hour without operator action.
- `unknown` — no fresh evidence; eligible for routing. No row = never
  seen; expired row = consumer-downgraded at read time (Part B
  windows). The probe runner writes `unknown` rows lazily on first
  coverage; nothing else writes them.
- `ok` rows never ship to gateways (absence = eligible), so their
  TTLs govern the DASHBOARD only: `input_shape`-flagged `ok` rows are
  re-probe candidates after **1h**; plain `ok` rows after 3 days.
  Escalation rule (circuit breaker): an `input_shape` row that yields
  `input_shape` again on 3 consecutive re-probes sets
  `escalated=true` (the schema's stable_input_shape marker) and LEAVES
  the healing queue — inherent shape
  mismatch must not burn probe budget forever. Traffic evidence re-admits it in v1 already: any 200 on that
  (key, model) promotes the row back to plain `ok` (A.3); deny-shaped
  traffic evidence additionally re-admits once E.1 lands. The healing loop
  (A.4) is the enforcement owner for these, same as deny/balance.
- Upserts are timestamp-guarded (`ON CONFLICT ... DO UPDATE WHERE
  excluded.checked_at > key_entitlements.checked_at`). Both writers are
  dashboard processes, so one DB clock arbitrates; traffic rows stamp
  the usage-event timestamp and the refresher processes events
  newest-first per (key, model) under a 1h watermark — replayed old
  events never outrank fresher evidence (skew tolerance = the scan
  window).
- Key lifecycle: creating a key inserts `unknown` rows lazily on first
  probe. Updating a key's SECRET immediately DELETES ALL of that key's rows
  (and bumps the generation — row deletion must propagate)
  (ok included — a new secret may belong to a different account, and
  stale evidence of either polarity must not survive the swap) and
  queues a re-probe bootstrap. Weight-only updates touch nothing.
  While a re-probe is queued the key is row-less = unknown =
  eligible; request-time 401 on it fails over as usual. Deleting a key
  cascades its rows away.

### A.2 Probe runner

`POST /api/providers/{id}/keys/{key_id}/probe` (single key) and
`POST /api/providers/{id}/probe` (all keys). Single-flight per provider
(Postgres advisory lock — see Pacing below). Endpoint requires the standard dashboard JWT
(probes spend real money; audited per batch).

Classification is a shared module (`entitlement_class.py`) used by both
the probe runner and the traffic refresher — ONE classifier, specced
once (per provider when known):

1. **Provider-native error codes first** (exact-match table, seeded
   from production evidence; extend per provider):
   - DashScope: `400` + body `"code":"ProductNotActivated"`-class /
     text containing `未开通` or `not activated` → deny; 429 body
     `Arrearage`/`balance` class → balance.
   - Ark: `400` or `404` + `InvalidEndpointOrModel` → deny (Ark returns
     this as 400 too — do not assume 404). 429 billing class → balance.
   - zhipu: `429` + `1113` (balance/资源包) → balance; `400` with
     model-not-exist class → deny.
2. **Entitlement regex fallback** (multi-language): deny only on
   explicit activation/entitlement wording, anchored —
   `product (is )?not activated|products? not activated|未开通|not
   entitled|product.*未开通` — never the bare `product.*not.*activate`
   (it matches "activation not required"). The phrases `no permission` and
   `unsupported operation for this model` are NOT deny evidence by
   themselves (they fire on input-shape and content-policy paths);
   they classify as `ok` + `error_code='input_shape'`.
3. **Default for unclassifiable 400/404**: `ok` +
   `error_code='input_shape'` — fail-open. A false `ok` costs one
   failover attempt; a false `deny` removes a good key entirely (the
   worse failure, per the uni-api precedent).

Full classification matrix:
- 2xx → `ok`.
- 401/403 → KEY-LEVEL failure: upsert the `__key__` row
  (`status='broken'`, http_status recorded), abort the whole probe for
  that key, audit `entitlement.key_broken`, leave prior rows
  untouched, and bump the generation. Broken keys: carrier TTL window
  24h (rides with deny); the healing loop re-probes broken rows aged
  ≥ 22h FIRST (priority above balance — a dead key poisons every
  model). Broken keys are never fail-open candidates; when a pool is
  ALL-broken the request terminates with the broken evidence error.
- 429 rate-limit class → skip this model, halve in-flight for 30s
  (backoff), continue.
- 5xx/timeout → skip, retry once, leave prior state.

Probe request shape follows the provider's configured protocol
(openai_chat → POST {base}/chat/completions Bearer;
anthropic_messages → POST {base}/v1/messages with x-api-key AND the
required `anthropic-version: 2023-06-01` header): `max_tokens=1`, one
"hi" user message, non-stream, 15s timeout, JSEC-decrypted key, direct
to upstream (NOT via the gateway — the LB would pick another key).

Single-flight across dashboard replicas uses a Postgres advisory lock
(`pg_try_advisory_lock(...)` keyed on provider id, same pattern as
model sync). Advisory lock is the single mechanism.

Pacing & budget: per key, sequential over listings with 150ms spacing
(probe concurrency 1 per key, 2 keys in parallel per provider, and
never more than the provider's known RPM if lower); the batch ABORTS at
`JANUS_PROBE_MAX_CALLS` (per-batch hard stop, default 1000) or 10
minutes wall time, whichever first. Truncation priority when capped:
models bound on the Router first, then remaining listings
alphabetically — the cap cuts the tail, never the bound set. On 429
rate-class, pause that provider's probe for 30s (probes share rate
pools with live traffic). One `bump_generation` per batch (never per
row).

Budget economics (two explicit knobs):
- `JANUS_PROBE_MAX_CALLS` — per-batch hard stop (above).
- `JANUS_PROBE_DAILY_CALLS` — per-PROVIDER daily budget (default
  5000) shared across sync/bootstrap/healing, with a RESERVED healing
  share (≥ 25%): bootstrap may consume up to 75%/day; the healing
  loop can always spend its share, so a DashScope day-one bootstrap
  (786 calls) cannot starve balance/deny recovery. When the daily
  budget is exhausted mid-queue, priority order balance > deny > ok
  decides what survives.
- Listings matched by `premark_input_shape` codes rows are marked
  `ok+input_shape` WITHOUT an upstream call and never enter the
  hourly loop (see A.2 premark).
- `POST /api/providers/{id}/probe` (all keys) is ASYNC: validates,
  enqueues, returns `202 {queued}`; the SPA polls the matrix.
  Per-key probe stays synchronous (bounded ~2–4 min).

Classification single-sourcing: `entitlement_codes(provider,
match_status, code_keyword, outcome)` is a dashboard table seeded ONCE
by SQL migration from production evidence (the recorded DashScope/
Ark/zhipu classes) and thereafter managed ONLY through the dashboard
admin API (list/create/update/delete; every write bumps the
generation, RESETS `escalated` on affected rows and re-queues them,
validates regex rows — compiled, length-capped — and records a
`key_scoped_balance` flag per provider); BOTH the dashboard's Python classifier and the gateway's
retry-time Erlang classifier only READ it, and the carrier (Part B)
distributes it to gateways. `outcome='premark_input_shape'` rows name
modality families (image/audio/…): the probe runner does NOT call the
upstream for premarked listings — it writes `ok+input_shape` locally,
spending zero probe budget. The table is the single source of
truth — no classifier owns rules, no second copy exists. The regex
fallback patterns live in the SAME table (`match_status='regex'`
rows), scoped to the provider's error `code`/`message` fields only
(never whole response bodies — echoed request/prompt text inside a
message must not classify). The seed ALSO carries the 429 dual-class
rows (rate vs balance keywords per provider) — the same table drives
probe, refresher, and retry-time classification, so an unlisted
provider defaults both to rate-class (retry, no cooldown), never
balance.

Response: `{ok: N, deny: M, balance: K, skipped: S}` per key + audit
`entitlement.probe` with counts.

### A.3 Traffic refresher (dashboard, conservative v1)

Evidence source: usage events (written by the gateway per attempt, see
C.1). **v1 restriction: traffic evidence may only PROMOTE to `ok`**
(status 200 → ok, timestamp = event ts). Deny/balance demotion from
traffic is forbidden until usage events carry `error_code` (Part E
prerequisite) — status-only 400 cannot distinguish deny from
input-shape, the exact bug this spec exists to fix.

Trigger: opportunistically after usage-event polling (dashboard), and
`POST /api/entitlements/refresh` for manual runs. Scan window: last
1h of usage events, watermark-guarded (events older than the row's
current `checked_at` never overwrite — see A.1 upsert rule).

### A.4 Sync + bootstrap integration

Three triggers, one background queue (non-blocking, same pacing rules):
1. After `/api/models/sync`: delete entitlement rows whose
   `model_name` no longer exists in the provider's listings (vanished
   upstream), then probe keys with no row for the new catalog.
2. Key insert or SECRET update: bootstrap / re-probe that key.
3. Scheduled healing loop (independent of sync — the starvation-loop
   closer), every 15 minutes, ONE global queue with priority
   balance > deny > ok (a topped-up key must never wait behind stale
   deny sweeps). `balance` healing is KEY-SCOPED where safe: when
   `entitlement_codes.key_scoped_balance` is true for the provider
   (balance is account state), ONE canary probe per key updates ALL of
   that key's balance rows; otherwise per-row re-probe. `deny` rows aged ≥ 22h and
   `ok` rows older than 3 days (1h when input_shape-flagged, unless
   `escalated`/stable) re-probe per row. The refresher also enqueues a key-scoped balance canary when usage
   rows show repeated 429s on a key whose matrix rows are all `ok`
   (status-only heuristic — safe because it triggers a PROBE, never a
   demotion). Trigger-priority when the per-provider DAILY budget (A.2's
   `JANUS_PROBE_DAILY_CALLS`, with the enforced ≥25% healing share)
   runs short: balance > deny > ok, and each trigger is HARD-capped
   at its share (bootstrap ≤75% of the daily total) — reservations
   are counters, not aspirations. Excluded keys receive no traffic and
   traffic learning never heals them; this loop is their only refresh
   path. Secret-updated keys' rows were already cleared at write time
   (A.1) and ride the same queue. Daily counters persist in a
   `probe_budget_counters(provider, day, calls)` table so restarts
   and replicas cannot reset them.

### A.5 UI

- Provider row: per-key chip `k1#12 · 231/262 ok` + Probe / Probe all.
- Matrix read endpoint: `GET /api/entitlements?provider_id=` powers
  the badge UI; the async provider-wide probe returns `202 {queued}`
  and the SPA polls this endpoint.
- Listing rows: badge `ok N/K` / `partial n/K` (amber, tooltip) /
  `deny 0/K` (grey) / no badge (unknown). A listing that is
  deny-marked for EVERY key of its provider is additionally flagged
  `stale-listing?` (likely renamed/removed upstream — Ark's
  InvalidEndpointOrModel class hits here), nudging the operator to
  re-sync rather than debug fail-open churn.
- Bind-time validation (dashboard-side, on POST /models/{id}/routes):
  binding a `deny 0/K` listing → 400 `entitlement_denied` with the
  matrix evidence; `partial` → binds, response carries a warning field
  (`warnings: ["model ok on 1/3 keys for provider X"]`) the SPA shows.

---

## Part B — Catalog distribution (gateway, read side)

Carrier added to the catalog bundle. The query MUST be tolerant of a
missing table (dashboard-created; a gateway may boot before the
dashboard has ever run): fetch wrapped — on undefined-table error,
return an empty list and log once at warning. Both dialect variants
ship as gateway migrations? No — the table stays dashboard-owned; the
carrier is read-only SQL:

```sql
-- postgres: per-status TTL windows (deny 24h, balance 1h). The SQL is
-- the ONLY TTL enforcement point — gateway reads are fresh by
-- construction; nothing re-checks checked_at gateway-side.
SELECT provider_key_id, model_name, status
FROM key_entitlements
WHERE (status IN ('deny','broken') AND checked_at > now() - interval '24 hours')
   OR (status = 'balance' AND checked_at > now() - interval '1 hour')
```

The carrier also ships `entitlement_codes` for the retry-time
classifier:

```sql
SELECT provider, match_status, code_keyword, outcome FROM entitlement_codes
```

The dashboard bumps the generation on every codes-table write, so
seed edits reach gateways on the normal poll. An empty/missing codes
table is a defined state (fully fail-open classification, see C.1's
429 rule). `ok`
rows are never shipped — absence = eligible, matching the LB
convention. POSTGRES-ONLY BY DESIGN: the matrix and codes tables are
created by the dashboard (which requires Postgres); a gateway on the
SQLite backend runs permanently matrix-less — same fail-open path as
a missing table. No sqlite DDL exists for these tables on purpose.

`janus_catalog` stores `deny_keys: #{{ProviderId, ModelName} =>
#{KeyId => deny | balance | broken}}` — keyed by provider AND model
(listing names collide across providers; key ids are globally unique
but the exclusion must not leak across a name collision). ModelName
here is the UPSTREAM-sent name: janus-auto resolves its target model
to the listing name before `do_proxy`, so the lookup is exact. Both the
candidate list AND the deny map come from ONE generation snapshot
captured at `dispatch/7` entry and threaded through every per-attempt
pick — attempts within one request never mix generations even if a
reload lands mid-request (per-request reads are otherwise lock-free).
The deny map keys MUST be the listing name actually sent upstream
(binary match; the binary-vs-atom bug class).

`balance` entries ride the same map; the LB treats them as excluded
too, but their 1h TTL (A.1) bounds the exclusion.

Zero-eligible-keys fallback: when the pre-filter leaves NO candidate
key for a model, the pick IGNORES the matrix for a single attempt
(fail-open, `janus_entitlement_failopen` counter + warning log). The
matrix is advisory; stale data must not cause total outage.

---

## Part C — In-request key failover (gateway)

### C.1 Retry loop

`dispatch/7` wraps the current single attempt:

```
attempted = #{} (key ids tried this request)
deadline  = now + failover_max_budget_ms  (default 45000; ceiling 180000)
loop:                                    // first call unconditional
  Route = pick(candidates minus cooling minus attempted minus deny-map;
               if that empties the pool and failover_failopen_used == false,
               set the flag and pick any non-cooling, non-attempted key —
               candidates for the fail-open pick come from the SAME entry
               snapshot, never a fresh catalog read; AT MOST ONE
               fail-open attempt per request)
  Result = call_upstream(Route)   // parsed request Map retained and
                                 // re-marshalled per attempt; prior gun
                                 // subscription cancelled before re-pick
  mark Route's key attempted; track(Result) → usage row with
  request_ref (one UUID per loop) and is_terminal set below.
  case classify(Result) of
    retry_key when key_retries < failover_max_attempts
                and now < deadline
                and remaining candidates exist ->
        jitter 100–300ms; note_failure/cooldown as today; loop
    pool_reuse when pool_reuse_used == 0 and now < deadline ->
        pool_reuse_used+1; loop        // reserved slot OUTSIDE the
                                       // key budget (deadline-gated);
                                       // when attempted == pool, the
                                       // pick reuses the cooldown-EXPIRED,
                                       // least-recently-used attempted key
                                       // (never the one that just failed)
    _ -> terminal
```

- The FIRST call is unconditional and may itself exceed the budget
  (45s budget + 60s TTFB = 105s for a healthy-but-slow upstream);
  that is by design — no-failover clients lose nothing versus today.
- Attempt accounting: the FIRST call is unconditional; the knob bounds
  RETRIES after it (`0` = first attempt only, no failover — no
  off-by-one). Key calls ≤ 1 + failover_max_attempts; the single
  provider retry is a reserved extra slot so three key failures cannot
  starve it (total ≤ max_attempts + 2 calls).
- `failover_max_budget_ms` gates attempt STARTS; a call begun inside
  the deadline may run to its TTFB timeout, and an error attempt also
  collects a CLASSIFICATION body — capped at 30s / 64KB (only the
  code/message fields matter; the full body is never needed pre-reply).
  Worst-case wall = budget + TTFB(60s, the gun `?TTFB_MS`) +
  classification-body cap(30s) + jitter. Ceiling formula:
  `idle_timeout(300s) − 60 − 30 − 30 margin = 180s`. The 45s default is a compromise: it fits inside 60s client budgets
  but NOT 30s ones — callers on 30s budgets will sometimes abandon
  mid-failover and the spent upstream quota is wasted. Operators on
  tight client budgets lower the knob (accepting fewer retries); on
  generous ones raise it toward the ceiling.
- Mid-loop key deletion (route whose key vanished in a reload): the
  pick skips it like any absent candidate; note_failure on a missing
  key id is already a no-op in janus_lb.
- Jitter 100–300ms before each retry. Concurrent-burst damping is
  the existing per-key cooling (each failed key immediately leaves the
  candidate set for subsequent requests); no pool-level breaker in v1.
- Exhaustion contract: when the budget/candidates are exhausted, the
  error from the attempt with the highest `attempt` index is returned
  (unchanged error passthrough). Codes-table-empty 429s carry a
  minimum 10s cooldown even in the fail-open default (no zero-cooldown
  storming of balance-dead keys).
- Observability: /stats gains the fixed counters `requests_retried`,
  `failovers_won`, `failovers_exhausted`, `entitlement_failopen`,
  `broken_key_skips`, `pool_reuse_retries` (the renamed provider-slot
  path). Knob validation: `failover_max_attempts ∈ [0, 20]`;
  gateway apply-time additionally CLAMPS `failover_max_budget_ms` to
  the ceiling (settings validation is dashboard-side; the clamp is
  belt-and-suspenders against direct DB writes). Client disconnect mid-loop is an accepted limit:
  the loop is budget-bounded anyway; the next write to a dead socket
  fails silently as today.
- Crash guarantee: if the request process dies mid-loop, the usage
  refresher marks the newest FLUSHED row of that `request_ref`
  without a successor `is_terminal=true` after a grace window sized
  `ceiling(180s) + TTFB(60s) + margin(60s) = 300s` — linked to the
  ceiling so raising one raises the other; billing never
  double-counts. Accepted limit: rows still
  in janus_usage's 1s/100-row buffer at crash time are lost (bounded
  by the writer's documented caps); the backfill only sees flushed
  rows, so undercounting is possible only within that 1s window.
- Committed-response rule, precisely: a request is committed once any
  byte is passed to `cowboy_req:reply/stream_reply/stream_body`.
  Scope: the streaming retry analysis covers the chat faces
  (openai_chat / anthropic_messages / their translate) — the only
  agent-facing surfaces in v1; embeddings/batch endpoints are out of
  scope and must set `no_failover` semantics when they exist.
  NON-STREAM replies forward only after the full body is collected
  and classified (one `cowboy_req:reply`) — so every pre-reply
  upstream state, including collected error-status bodies, is
  retryable. STREAM replies forward the status line at
  `stream_reply` — error-status streams never reach it (they take
  the collect_drain path, bounded by the existing TTFB/BODY
  constants), which is exactly why they remain retryable; a 2xx
  stream is committed from its first frame. 200-then-stall:
  committed at `stream_reply`; existing terminate paths apply.
- Deny-shaped 400/404 (the production failure this spec exists for)
  ARE retryable: classification reuses A.2's provider-native codes via
  the gateway-side copy of the code table (deny evidence in the
  response body), falling back to the entitlement regex.

Retryable classes:
- key-scoped: 401, 403, 429, deny-shaped 400/404 (A.2 classes).
  429 single rule (codes table drives probe, refresher, and here):
  BALANCE-class → cooldown the key (default 60s) and move on;
  RATE-class → retry another key, the throttled key's cooldown =
  max(Retry-After, 10s) so a burst does not bench a healthy key.
  Codes-table MISSING or EMPTY (gateway booted pre-seed) → every 429
  classifies rate (retryable, no cooldown) and every 400 as
  unclassifiable (retry-once): fully fail-open. Known-broken keys
  (`__key__` row in the carrier) are skipped from candidates
  entirely rather than retried.

Terminal classes:
- 2xx → success.
- 400s split by classifier state (consistent with test 8):
  - KNOWN input-shape (matches a codes-table `input_shape` row or a
    premarked modality listing) → TERMINAL, zero retries: the same
    request shape fails identically on every key.
  - KNOWN deny-shaped (codes-table deny row) → retry_key (the
    motivating case).
  - UNCLASSIFIED (no codes-table match at all — e.g. a deny wording
    from a provider missing seed rows) → ONE failover attempt on
    another key, then terminal: bounded cost, and the attempt's usage
    row is classifier feedback for the next codes-table update.
  - When failover is disabled (`failover_max_attempts=0`) there are
    NO retries of any kind, including the provider slot.
- 5xx / transport error → at most ONE provider retry (same budget),
  then return the best error. Non-idempotency note: a 5xx/timeout
  retry may duplicate upstream work if the first attempt committed;
  bounded to one retry, this is the standard tradeoff.
- streaming after the first client byte → unretryable; existing
  terminate-stream behavior. Error-status streams collected before any
  client byte (the existing `Status >= 400` collect_drain path —
  status is known before anything is sent) ARE retryable.

Usage rows: every attempt writes a row carrying `attempt` (1-based),
`request_ref` (UUID, groups the attempts of one client request), and
`is_terminal BOOLEAN` (true on exactly the final row). Dashboard
billing/aggregation counts `WHERE is_terminal` ONLY — token totals,
request volume, success rates; non-terminal rows are operator
visibility and entitlement evidence. Fail-open attempts write usage
rows and cooldowns like any other. Legacy rows backfill
`attempt=1, is_terminal=true`. The loop keeps only pdict state — no
new gen_server.

janus-auto: judge calls bypass the failover loop (judge already has
timeout/breaker semantics); the target-model `do_proxy` call runs WITH
failover — an explicit `no_failover` flag threads from the judge
caller into `dispatch/7`.

### C.2 Knobs

`janus.failover_max_attempts` (3) and `janus.failover_max_budget_ms`
(45000; validated ≤ 180000 = idle_timeout − TTFB − body-cap − margin at settings-write time) live in the
`settings` table and reach gateways via the persistent_term
distribution (repo invariant: cross-consumer config never via
gen_server casts; sys.config is the default source when no settings
row exists).

### C.3 Auto-router interplay

Unchanged from the current design (janus-auto resolves a target model;
`do_proxy` executes with failover).

---

## Part D — Testing (E2E-first)

Failure modes enumerated first — this list IS the test plan. The local
e2e stack gains a mock OpenAI upstream (`scripts/mock_upstream.py` in
janus-dashboard): tiny FastAPI app, deterministic per-key behavior:

| mock mode | behavior |
|---|---|
| key A | 401 always |
| key B | 200 always |
| key C | deny-shaped 400 (`ProductNotActivated` body) |
| key D | 429 balance class |
| key E | 503 always |
| key F | input-shape 400 (`no permission` on this model shape) |

Flows (extend `run_test_flows.py --local`):
1. Probe classification: each mock mode → expected matrix row (A.2
   table), incl. deny-regex fixtures per provider (English + Chinese).
2. Probe aborts on key-level 401, reports, prior rows intact.
3. Matrix propagation: probe batch → ONE generation bump → gateway
   catalog sees deny entry.
4. Failover happy path (NO matrix loaded): pool [A, B] → request
   succeeds on attempt 2; two usage rows (`attempt` 1 and 2).
5. Failover exhaustion: pool [A, C, D] (all retryable-fail) → error
   returned once; usage row per attempt; no loop (attempt cap).
6. Deny-shaped 400 failover (the motivating case): pool [C, B] →
   succeeds on B; C marked cooling.
7. Provider-scoped 5xx: pool [E, B] → exactly one provider retry, then
   success or terminal error; budget respected.
8. Input-shape 400 terminal: pool [F, B] → NO retry (same shape would
   fail everywhere), immediate error.
9. Matrix pre-filter (matrix loaded): pool [C-marked-deny, B] → C is
   never picked (no usage row for C); succeeds first attempt on B.
10. Fail-open: all keys deny-marked, matrix stale → single fail-open
    attempt succeeds, counter incremented.
11. `failover_max_attempts=0` → single-attempt behavior.
12. Budget: mock TTFB ~2s, budget 5s → deadline cuts retries
    mid-sequence; last row has `is_terminal=true`.
13. Carrier TTL: deny row back-dated 25h and balance row 2h → neither
    ships; balance 30min old ships.
14. Bind validation: deny-0/K rejected; partial binds with warning.
15. Rotation: update key secret → re-probe queued under advisory lock.
16. Provider-retry reservation: 3 key failures with deadline remaining
    → reserved provider slot still fires; when attempted == pool the
    coolest key is reused.
17. Committed-200: mock 200-then-stall → no retry; stream terminates
    as today.
18. Budget ceiling: settings-write of 190000 is rejected (ceiling
    180000); at the ceiling with a full-TTFB final call + body-cap +
    jitter the handler still answers inside 300s (measured wall).
19. Crash-marking: kill the gateway mid-retry → refresher backfills
    `is_terminal` on the orphaned `request_ref` after the grace
    window.

---

## Part E — Prerequisites / follow-ups (explicit, cross-repo)

DEPLOY ORDER: E.3/E.4 (dashboard tables/aggregation) ship BEFORE E.2
(gateway usage columns) and Part C — the dashboard migration runs
first so gateways never fetch a half-state.

1. **usage_events.error_code** (gateway migration + capture at
   track-time, provider-native code parsed from the error body) —
   REQUIRED before traffic-based deny learning (A.3 v1 ships without
   it; ok-only).
2. usage_events gains `attempt SMALLINT`, `request_ref TEXT`,
   `is_terminal BOOLEAN` (one gateway migration, ships with Part C).
3. Dashboard aggregation counts `WHERE is_terminal` only; legacy rows
   backfill `attempt=1, is_terminal=true`.
4. New dashboard-owned table `entitlement_codes` (A.2), seeded once
   by SQL migration and distributed in the catalog carrier.
5. Usage-writer note: failover multiplies usage rows ≤ (attempts+1)
   per request; the existing janus_usage batch writer (1s/100-row
   flush, 10k buffer) absorbs this without change. The refresher's 1h
   scan uses the existing `usage_events_pkey_ts_idx` index; a
   `(request_ref)` index is added for crash-marking lookups.
6. Dashboard Nodes page flags any gateway reporting no matrix in
   /stats for >10 minutes while Postgres is up (matrix-less alarm —
   catches misconfigured backends).

## Out of scope (v1)

- Per-modality probe shapes beyond protocol (image/audio stay
  input_shape-classified).
- `/v1/models` entitlement annotation.
- Cross-provider failover (Router bindings provide it).
- Matrix history/charting.
