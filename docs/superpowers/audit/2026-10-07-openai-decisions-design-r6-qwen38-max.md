---
model: alibaba/qwen3.8-max
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: qwen38-max
---

**Verdict:** GO WITH FIXES — two unclassified failure paths and one unverified cross-host dependency must be closed before implementation.

**Critical risks**

1. **D15 pre-status reset is unclassified.** Terminal bucket lists: HTTP status received, body-stream error, 60 s first-byte timeout. Pre-send bucket covers connect-setup failure. A TCP reset *after* headers written but *before* any status byte arrives fits neither bucket. This is a real gun failure mode; without a ruling the failover decision is implementation-defined.
2. **Write gate assumes cross-host `:8080/readyz` reachability.** Gateways span aliyun/jdcloud/tencent. Dashboard (aliyun) must reach followers' `:8080` over the public/private network. AGENTS.md notes S.8 `stats_host` is container-network-only; if `:8080` has the same restriction the write gate permanently blocks (fail-closed but functionally dead). No rollout step verifies this.
3. **Break-glass role unnamed.** "role + reason" without naming the RBAC role or audit table schema.
4. **Probe `in_flight` has no TTL.** Dashboard crash mid-probe leaves the flag set, silently consuming the 20/day budget or blocking future probes.
5. **Unauthenticated `readyz` drives a security gate.** Accepted as public surface, but a network-level spoof between dashboard and gateway could falsely advertise `openai_decisions` and unlock writes. Low likelihood, worth a one-line threat note.

**Contradictions / stale claims**

- D18 says reject only `"stream": true`; no ruling on `"stream": "true"` (string) or `1`. JSON truthiness is implementation-defined otherwise.
- Pipeline step 5 (stream check) fires before route lookup, so `stream:true` + nonsense model returns `stream_not_supported` not `no_route`. Precedence table agrees (§4.5 #3 < #4) but this UX is surprising; confirm intentional.

**Missing first-ship requirements**

- No TF for cross-host readyz reachability (rollout step 5 verifies aliyun only).
- No cleanup policy for stale `in_flight` probes.
- D10 audit: "who accepted" recorded where — table/schema unspecified.
- No rate limit on `/v1/decisions` itself beyond the 10 MiB body cap.

**Architecture notes**

- Mixed-fleet window between steps 5–6 (aliyun up, followers not) gives probabilistic `no_route` for Decisions calls via external LB. Ops note exists; window duration should be bounded.
- Probe picks lowest `provider_models.id`; if that upstream model is deleted, probe is permanently inconclusive. Consider operator-pinned probe model as fallback.

**Top 5 edits**

1. §4.3 D15: add "connection reset after request headers written, before status received" → terminal (no failover), matching the no-byte-written invariant.
2. Rollout: insert step 4.5 — verify dashboard→`:8080/readyz` on **all** hosts (aliyun, jdcloud, tencent); add TF-D.16b for cross-host gate.
3. `provider_probe_state`: add `in_flight` TTL (e.g., 90 s) with cleanup on read.
4. Write gate: name break-glass role explicitly (`admin`), specify audit row columns.
5. D18: define exact semantics — reject iff decoded JSON value is boolean `true`; all other values pass through to upstream.
