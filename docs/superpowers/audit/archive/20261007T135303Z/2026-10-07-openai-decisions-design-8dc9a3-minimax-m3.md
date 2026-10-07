---
model: minimax-cn/MiniMax-M3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: minimax-m3
---

**Verdict:** GO WITH FIXES — spec is sound but ships blocked on the live Decisions wire capture and several pin-downs that should not reach plan.

**Critical risks**
- §11 admits `[ ] Live fixture on disk`; TF-D.1 / TF-D.6 cannot run without `apps/janus_http/test/fixtures/probes/openai_decisions.json`. Project rule: "never invent frames." This is a ship-blocker, not a "plan task 0."
- §4.2 "stable English string ... pinned at implementation" punts the only stable contract SDK clients can match. Pin literal text now.
- §4.3 probe has no timeout, no retry policy, no 5xx classification. Should be one-shot with ~10s deadline; 5xx ≠ "not Decisions" (it is inconclusive).
- §4.4 grant-by-name (D10): operators expecting per-face grants will be surprised on multi-face names. Auth-UX risk worth a one-liner in operator docs.
- §5.2 additive `endpoint=decisions` / `protocol=openai_decisions` label values: silent breakage if any scrape / alert allow-lists values. Name scrapers, audit relabel rules before merge.

**Contradictions / stale claims**
- §7 eunit scope too narrow for project rule (parsers get eunit-first, fixtures written first). Decisions wire parser (success body, error envelope, usage null-safety) is exactly that case.
- §4.6 "passthrough JSON" never pins unknown-field forwarding or upstream 5xx / 429 / 4xx mapping.
- §4.3 404 / 405 class lumps 308 redirects and 5xx as "not Decisions"; misconfigured base URL can masquerade as a working probe.
- §9 dashboard release order vs gateway probes unstated; rolling deploy can leave windows where old gateway + new dashboard disagree.

**Missing first-ship requirements**
- MAX_BODY oversize 413 envelope shape not pinned.
- No upstream `x-request-id` propagation (only client echo is mentioned).
- No audit-log field shape for Decisions calls.
- No Prometheus relabel / alert-rule audit artifact path.
- No dashboard "duplicate provider for second face" UX — operators will demand it.
- No captured probe-outcome fixtures (401 / 403 / 200 / 404 / 5xx) for eunit-driven gates.

**Architecture / design notes**
- Mirror boundary (§4.2) and protocol-atom separation are correct; keeps translate / clamp risks out cleanly.
- janus-auto hard-block at both gateway and Router (§4.5) is the right belt-and-suspenders.
- Pin explicit release order: gateway migration → beams → dashboard enum → dashboard probe UI → operator enable.

**Top 5 concrete edits**
1. Move fixture capture from "plan task 0" to **ship-blocking** in §11; no-go without `openai_decisions.json` on disk.
2. Pin literal `protocol_requires_native` and `stream_not_supported` messages in §4.2 now.
3. Specify probe: 10s deadline, no retry, 5xx → `probe_inconclusive`, distinct from 404 / 405 / connect-error.
4. Expand eunit to cover the wire parser; commit probe-outcome frames per fixture realism rule.
5. Pin passthrough: forward unknown request fields; upstream 5xx passthrough, 429 no-retry, 4xx passthrough; propagate `x-request-id` upstream.
