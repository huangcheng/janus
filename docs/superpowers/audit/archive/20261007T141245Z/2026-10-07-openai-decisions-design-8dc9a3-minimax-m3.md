---
model: minimax-cn/MiniMax-M3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: minimax-m3
---

**Verdict: GO WITH FIXES**

### Critical risks
- **D13 contradiction.** Production claims require live fixture (§2), yet §6.2 lets merge proceed on guide replay only. Pick: live capture is required for `gpt-6-luna` claims; guide is dev-only. Pick the same in §11 self-review.
- **Pre-send failover boundary (D15) undefined.** "Bytes sent" is ambiguous. Define as `<wait> first byte of HTTP/1.1 request line + body via gun:request, in-scope = gun:open failure, out-of-scope = gun_response/headers. Without this, a race between gun connect-success and first-byte-sent is a double-bill window.
- **Probe bills Luna.** The probe sends a real question; even at 60 s cooldown, a loop/dash-precise-cadence misconfig racks up. UI text is insufficient. Add per-cap (per-day/N) and probe-call audit trail.
- **Grant widening (D10) silently allows billable Decisions.** Grant is by name; no per-key protocol face. A key with grant `gpt-6-luna` can now make billable Decisions AND chat. Either add per-grant face options, or document the explicit decision.
- **Image bytes redact.** Inline `input_image` base64 lands in body buffer. Verify no code path dumps request body mid-handler (413/stream-guard/JSON-parse paths).
- **READY write-gate SPOF.** If dashboard cannot reach any node, write gate is permanently blocked. Cache readyz result for N=60 s with TTL.

### Contradictions / stale
- §6.2 vs D13 (live gate vs guide-only merge).
- §8 lists "mixed-fleet no_route vs 400" as failure mode with no fix/ops entry.
- D14 "optional later: sync into disabled rows" has no scope/date.

### Missing first-ship
- Operator runbook with exact create-provider + manual listing steps + checklist link to TF-D.1.
- Rollback: dashboard-level kill switch (not per-provider only) for fleet-wide disable.
- Per-key per-provider rate limit for Decisions (separate from chat). Without it, null beta prices = unbounded burn.
- `providers_ledger_events` for write-gate/rejections (audit trail).
- Image/privacy guardrails.

### Architecture / design
- Shared handler preamble is right. Pin: classifier in `decide_route`/mime-level before body parsing.
- LB eligibility predicate is right.
- `/readyz` `protocols[]` ad is right; `protocols[]` label cardinality OK.
- `alg` 400/404 ambiguity in probe classifier (OpenAI returns 404 model-not-found): spec already excludes.

### Top 5 edits
1. Fix D13 contradiction: live fixture = merge gate; guide fixture = replay-only. Mirror in §11 self-review.
2. Define pre-send boundary in §5: `before first byte of HTTP/1.1 request line + body via gun:request, out-of-scope = gun_response/headers.
3. Add per-provider probe cap (per-day/N) + probe-call audit trail in dashboard.
4. Cache readyz result in dashboard for N=60 s with TTL; document fallback.
5. Add dashboard-level kill switch (separate from per-provider `enabled=0`) for fleet-wide disable.
