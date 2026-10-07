---
model: kimi-for-coding/k3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: kimi-k3
---

1. **Verdict:** GO WITH FIXES — the design is mature and failure-mode-aware, but several precedence/contract edges (auth-vs-413, "bytes sent", probe cooldown scope, readyz version skew) remain unpinned and will produce divergent implementations.

2. **Critical risks**
- **Probe billing abuse:** cooldown "≥60 s per provider" is unspecified as to enforcement point. If it's in dashboard process memory, a dashboard restart or second replica bypasses it, and each probe is a billable Luna call. Needs a DB-enforced (provider-keyed) last-probed-at check.
- **D15 "bytes sent" undefined:** with gun, headers may flush before the 10 MiB body finishes. "After request bytes sent" must mean *any* byte (headers included), else a mid-body failure could trigger a double-billing failover — exactly what D15 forbids.
- **429 handling half-specified:** passthrough + metric is defined, but whether a Decisions 429 feeds the existing LB cooling path is silent. Divergence here changes failover behavior materially.
- **Fixture base64 stripping:** "replace/strip base64 image bytes" — a structural probe classifier keyed on `answers` must still validate against the sanitized fixture; confirm redaction doesn't mutate `answers` shape.

3. **Contradictions / stale claims**
- §4.2 preamble order lists "auth, ?MAX_BODY …" but the precedence paragraph says body limits (413) run *first*. Unauthenticated oversized body → 401 or 413? Pick one.
- Stream guard: "before proxy if `stream:true` **or** Accept SSE", but precedence puts stream guard *after* JSON parse. Accept-SSE + malformed JSON → which error? TF-D.5 only covers the clean case.
- "TF asserts Decisions handler has no SSE/translate deps" — an E2E flow cannot assert absence of dependencies; that's a static (xref/compile) check. Miscategorized.

4. **Missing first-ship requirements**
- Dashboard handling of **old `/readyz`** (no `protocols` field) during mixed fleet: must fail closed — state it, plus capability cache TTL.
- Write-gate-closed UX: protocol dropdown disabled state is absent from the browser-test list.
- Per-face body cap mechanism: if existing `?MAX_BODY` ≠ 10 MiB, say how Decisions overrides it.
- Probe `model` field: "upstream_model_id **or** name" is ambiguous — pin precedence.
- No metric/alert for probe outcomes or a `janus_usage_unmapped` spike (first live traffic is exactly when field names get pinned).

5. **Architecture/design notes**
- Single eligibility predicate shared by LB/dispatch/auto is the right call; grant-deny before face errors is consistent with existing semantics.
- Boot-migration CHECK + old-beam-skip is sound; rollback story (old gateway, new CHECK value present) is covered by the skip-log path — good.
- Manual-only listings (D14) correctly kills the sync-poisoning class.

6. **Top 5 concrete edits**
1. One total precedence table: auth → 413 → JSON parse → stream guard (or whatever order chosen), covering Accept-only SSE + malformed JSON.
2. D15: define "bytes sent" = first byte incl. headers; state 429 → LB cooling yes/no.
3. Probe: DB-enforced per-provider cooldown; pin model field precedence; add probe-outcome metric.
4. Write gate: old readyz without `protocols` = fail closed; document capability cache TTL; add gate-closed browser flow.
5. Replace "TF asserts no SSE deps" with a static xref check; specify per-face 10 MiB cap mechanism vs existing `?MAX_BODY`.
