---
model: mimo/mimo-v2.6-pro
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: mimo-v26-pro
---

**Verdict:** GO WITH FIXES — the spec is unusually disciplined, but a precedence contradiction, a narrow grant-widening guard, and the "merge without live fixture" escape hatch need closing before implementation.

**2. Critical risks**
- **Precedence conflict (auth UX):** §4.2 runs the stream guard *before* proxy, while D5′ says grant-deny is "before face errors." A `stream:true` request from an ungranted key can therefore get `stream_not_supported` — a feature-existence leak — instead of grant deny. Make `stream_not_supported` sit *after* grant check, or state the intended order explicitly.
- **Probe false "not Decisions":** the 404/405 classifier distinguishes "endpoint missing" from "model not found" by parsing upstream error bodies — shapes unpinned until D13. Default all 404/405 to *inconclusive* unless a fixture-matched body says otherwise; never let a misparse flip a non-Decisions endpoint to "Not Decisions" confidence.
- **Grant widening is guarded only at provider-create time.** Later actions — adding a listing name to an existing Decisions provider, or issuing a new key grant on an already-granted name — silently enable billable Decisions calls. Extend the confirm to every listing-add and grant-write path.
- **Server-side probe holds the stored provider key** with only a ≥60 s cooldown. Add per-day probe budget + audit log of probe invocations; cooldown alone is thin billing-abuse protection if the dashboard API is reachable by multiple operators.
- **Usage black hole:** merge-on-guide-only (rollout step 2) leaves O1 forever open → unmapped usage in prod, null cost rows on *billable* traffic. Make `janus_usage_unmapped > 0` a paged alert before launch.

**3. Contradictions / stale claims**
- §4.2 "stream guard before proxy" vs D5′ grant precedence (above).
- §4.3 "404/405 = Not Decisions" vs "404 model-not-found = Inconclusive" — same status, two outcomes, resolution mechanism unspecified.
- §6 step 2 ("merge on guide replay only") weakens D13's implied gate; §7 "Production-green (D13)" for TF-D.6 then has no defined field names to assert.

**4. Missing first-ship requirements**
- Owner + deadline for O1; rule that prod launch checklist requires the sanitized live fixture (not "when key available").
- Explicit statement that existing per-key rate limits/quotas apply to the Decisions face.
- Readyz advertisement must be verified on *all* fleet nodes before opening the write gate (≥1 is too weak given mixed-fleet `no_route` is user-visible).

**5. Architecture/design notes**
- Pre-send-only failover (D15) is right, but "pre-send" must be defined in gun terms (before request bytes are flushed); shared-proxy retry suppression deserves its own regression assertion.
- Verbatim upstream error passthrough vs wrapped local envelope is sound (`type: janus_error` disambiguates) — say so in ops copy.

**6. Top 5 edits**
1. Add a precedence row for "stream:true + no grant"; reorder §4.2 accordingly.
2. Move grant-widening confirm to all listing/grant writes.
3. Default 404/405 to inconclusive; require fixture-matched body to say otherwise.
4. Require D13 fixture before prod launch; alert on `janus_usage_unmapped`.
5. Define "pre-send" precisely + require all-nodes readyz before write gate opens.
