# Synthesis — OpenAI Decisions API Design Spec (r6)

**Date:** 2026-10-07
**Target:** `2026-10-07-openai-decisions-design-r6-target.md`
**Panel (7/7 PASS, quorum met, not degraded):** MiniMax-M3, mimo-v2.6-pro, step-5-preview, qwen3.8-max, deepseek-v4-1-flash, glm-5.3, kimi-k3
**Consensus threshold:** ceil(7 × 0.7) = **5**
**Note:** manifest is `provisional: true` (`finished_at: null`); all 7 replies are present and consistent with it.

## Verdict table

| Slug | Verdict |
|---|---|
| minimax-m3 | GO WITH FIXES |
| mimo-v26-pro | GO WITH FIXES |
| stepfun-5 | GO WITH FIXES |
| qwen38-max | GO WITH FIXES |
| deepseek-v41-flash | GO WITH FIXES |
| glm-53 | GO WITH FIXES |
| kimi-k3 | GO WITH FIXES |

**Overall: GO WITH FIXES (7/7, unanimous).** No panelist blocked implementation outright; all require the fixes below before D13/implementation.

## Consensus (≥5/7)

**C1. D15's failover signal is under-specified for real gun behavior (5/7: minimax, qwen, deepseek, glm, kimi).**
Unclassified cases: pooled/reused connections (no connect step; failures arrive async, indistinguishable from post-send), TCP reset after request headers written but before any status byte, stale-pool race. As written, "before any request byte is written" is not deterministic, so TF-D.15 cannot be written and the "falsifiable" claim is at risk. The boundary must be defined in concrete gun terms.

**C2. The write gate has operational failure modes that need pinning (7/7 raise at least one).**
All panelists flag a write-gate gap, though sub-claims differ:
- single stale/restarting node blocks all Decisions provider creates org-wide (minimax, mimo, stepfun — 3/7)
- cross-host dashboard→follower `:8080/readyz` reachability unverified; rollout checks leader only, but S.8 precedent shows hosts can be container-network-only (qwen, kimi — 2/7)
- vacuous pass when registry has zero fresh heartbeats (glm — 1/7)
- point-in-time TOCTOU vs continuous catalog polling (kimi — 1/7)
- 60 s freshness vs heartbeat cadence may flap (deepseek — 1/7)

## Near-consensus / objective gaps (3–4/7, below threshold)

- **N1. 60 s first-byte timeout contradicts AGENTS.md (3/7: minimax, mimo, deepseek; kimi adjacent: no total deadline).** AGENTS sets `idle_timeout=300_000` *because* upstreams may take 60 s+ to first byte; a 60 s Decisions timeout kills legitimate slow calls other faces allow. Also no total upstream deadline — a slow-drip body hangs the handler to the 300 s idle while holding a 10 MiB buffer.
- **N2. Header-forwarding policy unspecified (3/7: kimi, mimo, minimax; glm adjacent on the upstream side).** Nowhere stated that client `Authorization` is replaced with the stored provider key; no allowlist/denylist for `Cookie`, `X-Api-Key`, `X-Forwarded-For`, `User-Agent`; "strip sensitive upstream headers" on error passthrough has no list. kimi rates this the highest-severity hole.
- **N3. Error contract incomplete (4/7: mimo, kimi, deepseek, glm).** `request_too_large` (413) and 405 (plus `Allow` header) missing from the code table; no pinned statuses for `upstream_response_too_large` / `upstream_timeout`; **mid-body stream-error envelope entirely undefined** (glm) — TF-D.15 can't assert it.
- **N4. Probe-state gaps (4/7: stepfun, qwen, glm, minimax).** `in_flight` orphan after dashboard crash/restart has no TTL sweep; `probes_today` scope (per-provider vs global) and `day_utc` rollover unpinned; migration for `provider_probe_state` unlisted.
- **N5. Gate ordering ambiguity (4/7: mimo, stepfun, glm, kimi).** Nothing merges before D13, so D11-as-merge-gate is vacuous until then; rollout step 9 (live TF-D.1) is billable prod traffic but is sequenced before O1 is pinned; D13 capture path (gateway-bypass, operator key direct to OpenAI) must be declared to keep the no-billable gate unambiguous.
- **N6. D16 blast radius under-guarded (3/7 + glm adjacent: minimax, stepfun, deepseek).** Shared preamble extraction is the highest-blast-radius change but only TF-D.20 (Responses) guards it; add chat + Anthropic + Responses-SSE regressions or feature-flag the landing.
- **N7. Grant-confirm UX storm (3/7: minimax, stepfun, glm).** Per-listing confirm = N modal dialogs for a large provider; needs batch confirm with per-listing audit. stepfun also flags §1 "no per-face grants" vs §4.4 cross-face confirm as contradictory.

## Split opinions — decision owner: user

1. **§4.5 rows 5 vs 6 disjointness.** mimo + deepseek: a name with disabled Decisions routes *and* enabled other-protocol routes matches both rows, no tie-break. stepfun + kimi: table is disjoint / edge covered by TF-D.13/14. → Needs an explicit ruling or tie-break.
2. **Unauthenticated `:8080/readyz` driving a security gate.** Spec accepts it; glm objects (new recon surface, "same as healthz" unverified — prefers `:8090` or bearer token); qwen accepts but wants a spoofing threat note; kimi accepts.
3. **Minority-but-material (1–2 models each, do not auto-apply):** kill switch may be unreachable after dashboard rollback since old enum rejects writes (deepseek); D8 no-knob contradicts AGENTS default-off house rule — needs explicit exemption rationale (kimi); upstream 5xx bodies forwarded verbatim can leak provider internals — map to generic envelope (minimax); 4 MiB response cap likely too tight for inline-base64 multimodal answers — verify against D13 observation (stepfun, glm adjacent); unbounded concurrent 10 MiB buffers = memory DoS, needs concurrency cap (mimo, kimi); `"stream"` JSON truthiness (`"true"`, `1`) unruled (qwen, deepseek); `x-request-id` client echo = log-injection risk (mimo); probe billability under O1 gate unstated (deepseek); break-glass role and audit-table schema unnamed (mimo, qwen).

## Ground-truth notes (verified against local AGENTS.md)

- AGENTS.md indeed states `idle_timeout => 300_000` because "upstreams may take 60s+ to first byte" → the 60 s contradiction (N1) is real, not speculative.
- AGENTS.md: feature knobs "ALL default off" → kimi's D8 exemption point is grounded.
- AGENTS.md: S.8 `/metrics` skips when `stats_host` is container-network-only → qwen/kimi cross-host `:8080` reachability concern is grounded; glm is right that the "same public health surface as healthz" claim is unverified.
- mimo correctly notes `:8090` is gateway-owned, so `decisions_probe_total` (a dashboard-side job) has no obvious home in the gateway metrics namespace.
- stepfun correctly observes the D13 fixture cannot exist before rollout step 2, so the merge-gate story needs the ordering fix in N5.

## Top concrete edits for the live doc

1. **§4.3 D15:** define the pre-send signal in gun terms — failover iff gun-up/connect error before any request byte written; explicitly rule connection-reset-after-headers-before-status, pooled/stale-connection async failures, and mid-body errors as **terminal**; add each case to TF-D.15.
2. **§4.3 write gate:** require ≥1 fresh heartbeat (fail closed on empty registry); emit per-node reasons; add a rollout step verifying dashboard→`:8080/readyz` reachability on **all** hosts (aliyun, jdcloud, tencent), not just the leader; state post-gate TOCTOU behavior (stragglers/old-beam nodes fail closed to `no_route`).
3. **§4.2/§4.3 timeouts:** reconcile 60 s first-byte with the AGENTS 300 s rationale (raise or justify per-endpoint with TTFB data) and pin a **total** upstream deadline with mid-body abort at the 4 MiB cap.
4. **New "Forwarded headers" subsection (§4.3):** client `Authorization` always replaced with stored provider key; strip `Cookie`/`X-Api-Key`/`OpenAI-Organization`/`OpenAI-Project`; allowlist for everything else; enumerate upstream headers stripped on error passthrough; upstream `x-request-id` replaced, client value sanitized or always minted.
5. **§4.2 error table:** add `request_too_large` (413), 405 + `Allow`, pinned statuses for `upstream_response_too_large`/`upstream_timeout`, and a mid-body stream-error contract (e.g., 502 `upstream_stream_error`); assert no collision with existing `janus_error` codes.
6. **§4.3 probe:** pin `probes_today` as per-provider, `day_utc` rollover semantics, `in_flight` TTL sweep (e.g., clear if older than ~90 s) + recovery on dashboard restart; list the `provider_probe_state` migration; state probe billability under the O1 gate; name where `decisions_probe_total` is incremented/exposed.
7. **Gates section:** clarify D11 replays live inside the implementation PR (nothing merges before D13); declare D13 capture as gateway-bypass (operator key, direct to OpenAI); sequence TF-D.1 after O1 pinning.
8. **D16:** extend regression TFs to chat + Anthropic + Responses-SSE preambles, or feature-flag the extraction.
9. **D18:** reject iff decoded `"stream"` is boolean `true`; all other values pass through.
10. **§7:** add TF-D.16 positive path (fresh heartbeat + advertised protocol → create succeeds) and a cross-host readyz check; extend TF-D.20 to the SSE path.
11. **§4.4/D10:** batch grant-confirm per provider+face with per-listing audit rows; resolve the §1 "per-face grants" non-goal vs §4.4 cross-face confirm contradiction.

Items in *Split opinions* require user decision before application.
