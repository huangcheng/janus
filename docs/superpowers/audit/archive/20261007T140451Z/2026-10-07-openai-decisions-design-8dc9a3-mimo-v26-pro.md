---
model: mimo/mimo-v2.6-pro
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: mimo-v26-pro
---

**Verdict:** GO WITH FIXES — the fail-closed routing and error-precedence design is sound, but the live-fixture gate, probe fingerprint allowlist, and failover/billing interaction need closing before implementation.

**2. Critical risks**
- **Double-billing beyond retry:** "no automatic retry" covers retries, but not LB failover on connect/5xx-class errors for a POST that may have reached upstream. Specify: failover only before first byte sent to upstream; after dispatch, surface the error.
- **Probe classification gaps:** the 400-fingerprint allowlist is "finalized from live capture," and probe uses the listing's upstream name. A manually-added listing with a wrong upstream id yields 404 → falsely "Not Decisions," silently marking a good provider bad. Add a `probe_inconclusive` class for 404 whose body is a generic model-not-found.
- **Sync poisoning mechanism is asserted, not built:** §8 lists "sync poisoning chat listings as Decisions," but nothing states that a Decisions provider's `/models` sync must be filtered or confirmed. Pin the rule: sync only stamps rows on that provider row; Decisions-capable ids require operator confirmation (or no auto-sync for Decisions rows).
- **Write gate is UI-only unless enforced server-side:** dashboard gate can be bypassed via direct API. State that the gate lives in the API write path, keyed on gateway generation advertisement.
- **Error envelope drift:** the table fixes `type: janus_error`, but 413 uses the existing `request_too_large` envelope and other faces use OpenAI-shaped errors. Agent clients parse these; confirm envelope parity with Responses' existing error shape (param/type fields), or say explicitly it is intentionally different.

**3. Contradictions / stale claims**
- §2 "do not assert token names until live fixture" vs §5 dashboard cost readouts shipping before the live file exists — cost code must ship null-safe but not field-pinned; O1 status should say which code is frozen.
- D11/D13: replay is "authoritative regime" while the live file is the production ship gate — §7 TF-D.1 mixes both; a reader can mark TF-D.1 green pre-live. Split "local-green" vs "production-green" explicitly per flow.
- Guide excerpts are beta (`gpt-6-luna`, public beta); committed excerpts may churn — version-stamp the fixture with capture date and re-verify at rollout step 2.

**4. Missing first-ship requirements**
- 10 MiB cap vs inline-base64 images: image-heavy Decisions payloads will 413; document or raise per-face.
- No prod validation path: `--smoke` mutates nothing, so Decisions is never exercised live pre-launch; add one operator-run live TF-D.1 in prod as a launch checklist item.
- Eunit for old-beam `normalize_protocol` skip (rollout safety) is not listed in §7.
- No rate/abuse handling note for 200-billing probes.

**5. Architecture notes**
- The dual-face eligibility filter at candidate-set build plus dispatch second line is the right belt-and-suspenders. Keep the predicate a single shared function so LB, dispatch, auto, and Router hard-block cannot drift.
- `/v1/models` name union without hints (D3) is defensible but pushes wrong-face 400s to runtime; acceptable since messages are exact and stable.

**6. Top 5 edits**
1. Add "failover only pre-dispatch" to §4.3 passthrough.
2. Extend probe outcomes with 404-model-not-found → inconclusive; freeze fingerprint allowlist source.
3. Add server-side write gate + Decisions sync-filter rule to §4.3/§4.4.
4. Split TF-D.* into local-green vs production-green columns; require prod live TF-D.1 checklist item.
5. Pin error envelope parity with the Responses face; confirm `request_too_large` 413 shape matches the table's `type`/`code`.
