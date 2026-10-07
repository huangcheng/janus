---
model: mimo/mimo-v2.6-pro
target: 2026-10-07-openai-decisions-design-target.md
slug: mimo-v26-pro
---

**Verdict:** GO WITH FIXES — the fail-closed native-passthrough design is sound, but fleet rollout safety of the protocol enum, O2/O3 ambiguity, and probe/usage contracts need pinning before planning.

**2. Critical risks**
- Mixed-version fleet: the migration (aliyun as leader) inserts `openai_decisions` rows into shared Postgres while followers still run old code; `janus_catalog` rebuild or LB normalization may crash or misroute on nodes lacking the atom. §9 never addresses forward-compat.
- Only `providers.protocol` CHECK is named. `usage_events.protocol`, seed allow-lists, and dashboard validators may carry their own constraints — un-migrated ones fail writes at runtime (failure mode 6 covers only one table).
- Probe contract: "minimal `POST /decisions`" needs `model` + `questions[]` (a real, billable beta call); "200 or documented error" is too loose — 401 vs 404/400 must be distinguished or a broken path reads as success.
- O3 (separate provider/key rows per face) duplicates key management and probes for one OpenAI account and splits cost attribution across rows.

**3. Contradictions / stale claims**
- §4.5 permits "or reuse `translate_unsupported`" while O2 "prefers" a new code; TF-D.2 accepts either 400 **or** `no_route` — the fail-closed contract is non-deterministic.
- §9.5 allows a "recorded mock" fallback — violates the repo's real-upstream E2E rule and the "never invent frames" fixture rule.
- §2 "no output-token charge" is beta pricing that may change; §5.1 says don't hardcode it, yet no dashboard cost task exists.

**4. Missing first-ship requirements**
- Dashboard pricing/cost entry for input-only Decisions semantics (absent from §6 table).
- Behavior when `janus-auto` candidate sets contain *only* Decisions routes (which error?).
- Rejection 400s counted in metrics/classify with protocol label.
- `usage_events` `units`/`outcome` semantics for Decisions (§5.1 covers tokens only).
- Rollback if OpenAI's beta wire or model id changes (`gpt-6-luna` single-model dependency).

**5. Architecture notes**
- Reject-before-translate in `dispatch` is the right seam; keep reject predicates pure and eunit-first as §7 says.
- D3 (`/v1/models` inclusion) is OpenAI-aligned but an agent-UX trap: clients will call listed names on chat and get 400. Consider a faces hint in the models payload or explicit docs, else support load.

**6. Top 5 concrete edits**
1. Pin O2 as a single code `protocol_requires_native`; delete the "or reuse…"/"or no_route" alternatives everywhere (§4.5, TF-D.2).
2. Add §4.8 "fleet rollout safety": unknown-protocol tolerance in catalog normalize, or gate via a default-off settings knob (repo convention).
3. Pin the probe: exact minimal body (`gpt-6-luna`, one predicate question) and success predicate with specific HTTP codes.
4. Replace the mock fallback in §9.5 with real Luna or mark-pending.
5. Add dashboard cost semantics + `units`/`outcome` mapping to §5/§6 and O1's capture to the plan's first task.
