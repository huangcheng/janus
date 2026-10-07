---
model: minimax-cn/MiniMax-M3
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: minimax-m3
---

**Verdict:** GO WITH FIXES — scope and falsifiable gates are solid, but gun first-byte timeout, probe classifier, and precedence disjointness must be pinned before implementation starts.

**Critical risks**

1. **D15 "first-byte timeout" isn't gun-native.** gun has no first-byte timer; needs streaming read with deadline or `gun:await/3` body-loop with custom timeout. Spec says "60 s to first byte" but doesn't pin the mechanism. D16's shared-preamble refactor amplifies this — every face inherits the same gap.

2. **Probe classifier lumps two distinct cases as "inconclusive."** Empty `answers` array (success, possibly all refusals) vs missing `answers` field (genuinely inconclusive or upstream bug) — both 200, both inconclusive. Operators can't diagnose. Differentiate.

3. **Probe scheduling / budget race not pinned.** Who runs the job (cron, gen_server, dashboard worker)? Calendar UTC midnight vs 24 h sliding window? `in_flight` flag + UPSERT semantics unspecified; "transactional cooldown" only helps after the SELECT.

4. **§4.5 rows 5–6 are NOT disjoint.** Dual-protocol name with all Decisions routes disabled but chat routes present → row 5 today (`protocol_requires_native`). Spec intent is row 6 (`provider_disabled`). Add ordering or sub-clause.

5. **Cross-repo schema ownership for `provider_probe_state`** unspecified — dashboard vs core vs shared. Migration location must be pinned (single owner, one migration path).

**Contradictions / stale**

- "60 s to first byte (align AGENTS idle reality)" — AGENTS mandates 300 s cowboy idle. 60 s gun first-byte is tighter, not aligned. Either raise AGENTS or drop the claim.
- §4.6–4.7 placeholder ("Native non-stream POST. No SSE path.") — unfinished.
- TF-D.4 ("/v1/models grant include/exclude") ambiguous vs D3 (name union, no face hint). Specify what is being asserted.

**Missing first-ship**

- D17 strip OpenAI-Org/Project with no audit hook — log the strip event (model + stripped header names) even though keys/bodies never logged.
- Probe model rewrite target: if chosen listing later disabled but other Decisions listings enabled, probe silently probes a dead listing.
- Write gate: 3 nodes × 3 s sequential = 9 s create-provider block; specify parallel.
- D13 sanitization misses content scoping — base64 strip is partial; prompts/answers may carry PII; add a content-redaction rule.

**Top 5 concrete edits**

1. **Pin gun first-byte mechanism in D15** — specify `gun:await` timeout + body-loop read with `cancel` deadline; D16 preamble owns this uniformly across faces.
2. **Split empty-array vs missing-`answers` in probe classifier** — distinct outcomes, distinct UI/alert states.
3. **Fix precedence rows 5/6 disjointness** — e.g. "if any face-correct route exists (enabled or disabled) → row 6 path; else if name exists only on other protocols → row 5."
4. **Pin `provider_probe_state` schema owner + migration path** — single repo, single migration location, list in §3.
5. **Drop "align AGENTS idle reality"** or raise gun first-byte to 300 s — fix the cross-document drift before any code.
