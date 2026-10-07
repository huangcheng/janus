---
model: minimax-cn/MiniMax-M3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: minimax-m3
---

**Verdict:** GO WITH FIXES — shape is right, but probe fingerprint, body-cap/image-budget mismatch, missing rollback migration, and log-redaction gap must be tightened before implementation.

**Critical risks**
1. **Probe fingerprint (§4.3) is brittle.** Body-text allowlist for `questions`/`input`/Decisions codes will false-positive on generic 400s (billing, malformed JSON). Replace with a structural probe: POST a Decisions-shaped body, require 200, and fingerprint **response** shape (`answers[]`/`id` pattern), not request-key echo.
2. **Body cap vs inline images (§1, D12).** Decisions is inline-base64-only; a single 4K image is ~5–8 MiB base64, so the 10 MiB cap effectively allows one image per call. Operators will hit 413 unexpectedly. Document the per-image budget and the single-image ceiling.
3. **Log redaction gap (§4.3).** Probe redaction is specified; normal traffic is not. 10 MiB bodies with base64 images and decision prompts will leak via cowboy access logs. Add: only `request_id + model + endpoint + status` survive.
4. **No rollback migration.** "Never reverse CHECK" is fine, but if the feature is killed, an orphan enum value remains forever. Add `drop_openai_decisions_from_protocol_check` as a contingency migration.
5. **Grants widening (D10) is underspecified.** An api_key granted to a chat name can probe Decisions. At minimum log cross-face attempts distinctly (not just errors) so operators can detect probing.

**Contradictions / stale claims**
- D11 ("replay authoritative; live Luna optional soak") vs TF-D.1 ("live file required for prod gate") read inconsistently. Pick one. Recommend: replay local + CI; live required for prod `--smoke`.
- §4.3 "200 probes may bill" is vague — mandate **minimal input** (one short question, empty `input`) and show estimated cost in the UI warning.
- D2 vs §4.5 wording overlaps; collapse into a single sentence.

**Missing first-ship requirements**
- 429 pass-through + dedicated metric, no retry.
- Translation-matrix doc entry: Decisions has zero pairs.
- Mixed-fleet boot behavior when some nodes have new beams and others don't — explicit `no_route` + loud startup warning, not silent drop.
- Operator docs reference (PROVIDERS.md or equivalent).
- Streaming hints beyond JSON `stream:true` (e.g., `Accept: text/event-stream`).
- `org` / `project` header propagation list — spec mentions only `Authorization` and `x-request-id`.

**Architecture / design notes**
- LB candidate-set filter (§4.5) is the correct layer — keep it.
- Decision input shape: text-only vs text+images mixed is undocumented in §2; clarify.
- Hard-block Decisions in janus-auto tier pickers (§4.5) is right, but **bound** keys to a Decisions listing should also surface a UI warning.

**Top 5 concrete edits**
1. Replace probe body-text allowlist with structural 200/sentinel-response fingerprint.
2. Unify D11 and TF-D.1 wording (replay local; live prod gate).
3. Add Decisions body redaction policy for normal traffic logs.
4. Add `drop_openai_decisions_from_protocol_check` migration for feature-kill rollback.
5. Mandate minimal-input probe + UI estimated-cost warning; add 429 metric and pass-through spec.
