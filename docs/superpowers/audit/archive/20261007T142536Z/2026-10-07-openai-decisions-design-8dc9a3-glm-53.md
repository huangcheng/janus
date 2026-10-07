---
model: zhipuai-coding-plan/glm-5.3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: glm-53
---

**Verdict:** GO WITH FIXES — sound architecture, but the write gate deadlocks the documented kill switch, and the rollout ordering contradicts the repo's deploy rule.

**Critical risks**
1. **Write gate vs feature kill (§4.3 vs §6.9):** the gate rejects `POST/PUT` on Decisions providers unless a node advertises the face. During rollback (old beams fleet-wide, nothing advertises), operators **cannot PUT `enabled=0`** — the kill switch is dead exactly when needed. Exempt disable-only mutations.
2. **Grant widening window (§4.4):** billing confirmation runs only "when creating Decisions provider." Later **manual listing additions** that intersect existing `api_key_models` grants silently enable billable calls — D10's promise has a hole.
3. **Probe 404 disambiguation:** "404 without model-not-found ambiguity → not Decisions" requires parsing upstream error bodies whose shape is unpinned until D13. Until the live fixture, a wrong-model 404 can be misreported as `not_decisions`. Classify all 404/405 as inconclusive until the body-shape check is fixture-pinned.
4. **Probe model field:** `listing.upstream_model_id or listing.name` is ambiguous; the forward path rewrites `model` to one canonical value. Probe must use the identical rewrite or it tests a different route than real traffic.
5. **Rollout order (§6):** step 8 "local e2e green" sits *after* aliyun deploy (step 4). Repo rule: `deploy_prod.sh` runs the local gate **before** rollout. Reorder.

**Contradictions / stale claims**
- §4.3 outcomes table splits 404 into "Not Decisions" vs "Inconclusive" by an unspecified body heuristic — same-status contradiction pending D13.
- D9/TF-D.13 cover only the Decisions face; behavior of a **chat/responses face naming a Decisions-only listing** (still `wrong_modality`? or `protocol_requires_native` with the same message?) is unspecified, yet TF-D.13 asserts deterministic precedence.
- §4.6 "Native path as §4.3. Idle timeout: Cowboy 300s class" — AGENTS invariants already mandate 300s on all listeners; sentence adds nothing, risks drift if read as face-specific.

**Missing first-ship requirements**
- Disable-path exemption under the write gate (risk 1).
- 429 passthrough: metric name and whether `Retry-After` is forwarded verbatim.
- Explicit statement that per-key abuse relies on existing key rate limits (probe cooldown covers provider-side only).
- Dashboard `/stats` + usage-UI protocol filters/allowlists accepting the new enum value.

**Architecture/design notes**
Single shared eligibility predicate (LB + dispatch + auto filter) is the right anti-drift move. No-knob (D8) + protocol-eligibility gate is coherent. Verbatim upstream errors + pre-send-only failover + no retry is correct for billing safety. Manual listings (D14) avoids catalog stamping — agree.

**Top 5 concrete edits**
1. §4.3 write gate: add "PUT that only sets `enabled=0` (or disables listings) is always allowed."
2. §4.4: run the grant-intersection confirmation on **every listing add**, not only provider creation.
3. §4.3 probe: until D13, 404/405 → inconclusive; pin the not-Decisions body check to the live fixture.
4. §4.3 probe body: "model = exactly the forward-path rewrite target."
5. §6: move "local e2e green" before the aliyun deploy step; add one line defining cross-face naming of a Decisions-only listing.
