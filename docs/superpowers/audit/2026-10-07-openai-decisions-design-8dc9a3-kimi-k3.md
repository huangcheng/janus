---
model: kimi-for-coding/k3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: kimi-k3
---

**Verdict: GO WITH FIXES — design is sound and internally consistent, but the write-gate readiness semantics, probe cost/audit handling, and the D11/D13 gating sequence need tightening before implementation.**

## 2. Critical risks

- **Write-gate TOCTOU + "ready" ambiguity (§4.3):** "every ready gateway node" — what about a node that is down, mid-restart, or flapping at check time? Down-but-stale-image nodes would silently bypass the gate. TOCTOU: a node can advertise at check time and roll back before the first request lands. Define: check is advisory at write time, and the *data plane* must also fail closed per-request on nodes that can't serve (D2 covers this, but state it as the backstop).
- **Probe billing + audit leakage (§4.3):** "200 probes bill" — real money, automatic caller, default 20/day/provider. No per-probe cost estimate shown, no statement that audit logs exclude request bodies/keys. Probe body contains the rewrite target and instructions — fine, but the *response* (possibly with usage) must not land in the audit log verbatim.
- **Error-code UX collision (§4.5, D9):** `protocol_requires_native` now fires on *both* faces (chat client naming Decisions-only listing, and vice versa). Same code, opposite remediation. Message must name the client face and the required face, or debugging is miserable.
- **Alert/allowlist race (§2):** allowlist "ships same deploy" as the traffic-generating feature — alert can fire between gateway enable and allowlist landing. Gate the alert on a flag, not deployment order.

## 3. Contradictions / stale claims

- D11 gates **merge/CI** on replay, D13 gates **implementation start** on live capture — but §2 says merge replay uses the *guide-excerpt* fixture, so D11 effectively precedes D13. Fine, but the lock table conflates them; state explicitly: excerpt replay gates CI, live replay gates *production claims*, not merge.
- "One-shot ~10 s" probe vs Cowboy 300s idle and upstream 60s+ first-byte invariant — 10s may be under upstream worst case; a slow-but-healthy provider reads as timeout→inconclusive forever. Justify the 10s or make it configurable.
- §4.6 "no new 300s face-specific idle claim" — good, but probe timeout then *is* a face-specific deadline; reconcile.

## 4. Missing first-ship requirements

- **Existing-grant retroactivity:** grants written before this feature for a name that later gains a Decisions listing — confirm on listing-add (D10) covers it, but TF list lacks a test for the pre-existing-grant case.
- **Probe concurrency guard:** two operators clicking Probe simultaneously across cooldown window — DB transactional cooldown claimed; add unique/in-flight lock test.
- **Body-cap vs streaming-upload:** 10 MiB read fully before pick — confirm `janus_http` reads body with the cap *before* any upstream connect (failover classification depends on it).
- **Rollback of the protocol CHECK migration:** boot migration on leader; if rolled back, rows with `openai_decisions` violate old code — old beams skip unknown rows (§4.1), but the *dashboard* enum migration rollback story is unstated.

## 5. Architecture/design notes

- readyz derived from registered cowboy routes is correct — avoids hardcoded drift.
- D15 connect-only failover is the riskiest proxy change; the buffered-body invariant (above) is what makes connect-fail vs post-send cleanly separable — pin it.
- Per-route auto exclusion (D5′) is right; dual-face name in `/v1/models` union needs one eunit asserting no duplicate rows.

## 6. Top 5 concrete edits

1. Define write-gate "ready" precisely (healthz-fresh within N seconds; down nodes block, not skip) + state per-request fail-closed backstop.
2. Probe: document estimated cost/probe, forbid response-body persistence in audit log, make timeout configurable, add concurrency-lock TF.
3. `protocol_requires_native` message: include client face + required face.
4. Alert allowlist behind a config flag; alert inert until flag flips post-allowlist.
5. Split D11 into excerpt-replay (CI gate) vs live-replay (production gate); add TF for pre-existing-grant-then-Decisions-listing.
