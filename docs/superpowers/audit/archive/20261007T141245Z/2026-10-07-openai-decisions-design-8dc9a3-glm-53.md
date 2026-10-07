---
model: zhipuai-coding-plan/glm-5.3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: glm-53
---

**Verdict:** GO WITH FIXES — the design is coherent and round-hardened, but grant enforcement, error-precedence ordering, and a write-gate rollback trap need edits before implementation.

**Critical risks**
1. **Grant widening via API bypass (D10):** the billable-calls confirmation is UI-only. Adding a listing named like an existing `api_key_models` grant through the provider API silently enables billable Decisions calls. Needs a server-side guard or an explicit accepted-risk note.
2. **Write-gate rollback trap:** the gate rejects *all* POST/PUT on `protocol=openai_decisions` providers when no node advertises the face. If gateways roll back (old beams skip the rows), operators cannot PUT `enabled=0` to kill the feature — the documented kill switch is unreachable. Gate must permit disable-only edits.
3. **Precedence gap:** §4.2 orders 413 → JSON → stream guard → proxy, but grant-deny lives inside §4.5. With `stream:true` + ungranted key, `stream_not_supported` wins over grant deny — is that intended? Unstated.
4. **404 sniffing fragility:** probe classifies 404 as "Not Decisions" vs "Inconclusive" by body shape; distinguishing endpoint-404 from `model_not_found` by body is brittle on a beta API.

**Contradictions / stale claims**
- D9 says only "Decisions wrong-face never emits wrong_modality"; §4.5's `protocol_requires_native` row seemingly applies to all faces. Does chat naming a Decisions-only listing now emit `protocol_requires_native` instead of legacy `wrong_modality`? Pin this; TF-D.13 must assert the reverse direction too.
- §4.5 row order implies grant-deny fires before `no_route` for unknown names — "unchanged" must be verified against actual existing ordering.

**Missing first-ship requirements**
- Non-POST 405 body shape (assume `janus_error` envelope — state it).
- Name for the dedicated 429 metric + assertion in the §5 pre-ship `/metrics` scrape.
- Write-gate re-close behavior on node loss (see risk 2).

**Architecture/design notes**
- Single shared eligibility predicate (no drift) is right; keep the probe classifier pure so eunit covers it fully.
- Pre-send-only failover (D15) means upstream header timeouts surface as client errors — an availability regression vs other faces; document in ops copy, don't hide it.
- `/readyz` protocols array is a cheap, correct advertisement mechanism.

**Top 5 concrete edits**
1. Add one full ordering line to §4.5: 413 → JSON parse → stream guard → grant deny → no_route/disabled/cooling → `protocol_requires_native`.
2. Write gate: allow `enabled=0` (disable-only) PUTs regardless of readyz advertisement.
3. Server-side listing-add grant-intersection check on Decisions providers (or documented accepted risk).
4. Pin chat→Decisions error code (`protocol_requires_native` vs `wrong_modality`) and extend TF-D.13.
5. Probe: default 404 to Inconclusive unless body explicitly indicates unknown endpoint; name the 429 metric and add it to the pre-ship checklist.
