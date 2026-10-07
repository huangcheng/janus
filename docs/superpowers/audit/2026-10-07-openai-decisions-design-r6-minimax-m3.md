---
model: minimax-cn/MiniMax-M3
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: minimax-m3
---

**Verdict:** GO WITH FIXES

**Critical risks**

- **D15 timeout contradicts AGENTS.md**: gun first-byte timeout 60 s while AGENTS notes "upstreams may take 60s+ to first byte". A slow-but-legit upstream will trip `upstream_timeout` before any byte lands.
- **D10 grant UX is a footgun**: confirm-on-every-listing-add forces an N-click flow for a 50-model provider. Needs batch/face-level grant with per-listing audit.
- **Write gate is a hard org-wide block**: a single stale heartbeat (>60 s) on any node blocks *all* Decisions provider creates org-wide. No per-node exemption, no "≥N ready" quorum.
- **Upstream 5xx body forwarded verbatim** can leak provider internals. Should map 5xx to a generic envelope; only 4xx + 429 body forwards.
- **D14 manual-only listings + no bulk-add**: first-ship must document at least a CSV/JSON bulk import for manual listings, else operators will push back.
- **Header policy underspecified**: only OpenAI-Org/Project are stripped. What about client `User-Agent`, custom `X-*`, or upstream vendor headers? Define allowlist/denylist.

**Contradictions / stale**

- "Old beams never write Decisions rows" relies entirely on the dashboard write gate. Catalog seed code or future maintenance paths could still insert — needs a DB-level CHECK guard or explicit migration ordering note.
- `/readyz` `protocols` is captured at listener start (snapshot); write gate treats it as live. Document staleness window.
- D13 fixture is hard-gated for O1/O2, but probe results ("inconclusive until O2") can lock providers indefinitely during a 5xx storm — operator UX trap.

**Missing first-ship**

- Per-provider rate/cost cap (token-only cost UI is observability, not gating).
- Metric for `protocol_requires_native` rate to surface client misconfig.
- Collision check vs existing `janus_error` codes.
- Probe `day_utc` rollover behavior for `probes_today`.
- gunup auto-retry policy before failover kicks in — silent today.
- Forwarded-headers allowlist (User-Agent, x-request-id echo, idempotency keys).

**Architecture / design notes**

- D16 shared preamble extraction in the same change couples Responses regression risk; consider feature-flagged landing.
- Auto-router exclude-Decisions-routes must run after name resolution, not before, or `janus-auto` on `/v1/decisions` precedence (row in §4.5) is unreachable.
- Mixed fleet mitigation: external-LB→old-node returns `no_route`; capture the exact string in `/stats` so SREs can grep.

**Top 5 concrete edits**

1. Replace 60 s gun timeout with ≥120 s (or AGENTS-aligned) and cite upstream TTFB data.
2. Soften write gate: block only if *zero* nodes ready; per-node reason; quorum option.
3. Batch grant-confirm on listing-add (one dialog per provider+face; per-listing audit row).
4. Map upstream 5xx to generic envelope; forward 4xx body only after header scrub.
5. Pin D15 boundary: "failover permitted iff zero bytes received AND gun-up/connect error"; clarify 1-byte timeout = no failover.
