Writing the round-2 synthesis artifact next to the panel replies.

Consensus math: N_pass = 7 → threshold = ceil(7 × 0.7) = **5**. Quorum met, not degraded — no DEGRADED label needed.

<tool_call>
<function=write_file>
<path>F:\Janus\docs\superpowers\audit\2026-10-07-openai-decisions-design-8dc9a3-synthesis.md</path>
<content># OpenAI Decisions API design spec — audit round 2 synthesis

Date: 2026-10-07
Target: `2026-10-07-openai-decisions-design-8dc9a3-target.md`
(source: `docs/superpowers/specs/2026-10-07-openai-decisions-design.md`)
Panel: 7/7 PASS, quorum 5 met, not degraded.
Consensus threshold: ≥ 5/7 (ceil(7 × 0.7)).

Models: minimax-m3 (minimax-cn/MiniMax-M3), mimo-v26-pro (mimo/mimo-v2.6-pro),
stepfun-5 (stepfun/step-5-preview), qwen38-max (alibaba/qwen3.8-max),
deepseek-v41-flash (volcengine-ark/deepseek-v4-1-flash-260910),
glm-53 (zhipuai-coding-plan/glm-5.3), kimi-k3 (kimi-for-coding/k3).

## Verdicts

| Slug | Verdict |
|------|---------|
| minimax-m3 | GO WITH FIXES — sound, but ship blocked on live wire capture + pin-downs |
| mimo-v26-pro | GO WITH FIXES — routing sound; models-sync stamping contradicts D2; error/stream contract ambiguous |
| stepfun-5 | GO WITH FIXES — routing/mirror-boundary strong; fixture gating, pricing/units, metric checks lack specificity |
| qwen38-max | GO WITH FIXES — routing sound; listing discovery, probe classification, fixture hygiene need pinning |
| deepseek-v41-flash | GO WITH FIXES — architecture sound; upstream wire contract unverified; usage/models/probe pins premature |
| glm-53 | GO WITH FIXES — face/isolation sound; 5 spec-level pins must land before plan |
| kimi-k3 | GO WITH FIXES — shape sound; block ship on sanitized fixture, deploy ordering, tightened contracts |

**Overall: GO WITH FIXES** (unanimous 7/7). No panel demanded NO-GO; all
blockers converge on the same fix list below.

## Consensus (≥ 5/7)

**C1 — Fixture capture is a ship gate, not just "plan task 0" (7/7).**
TF-D.1/TF-D.6 are unrunnable without
`apps/janus_http/test/fixtures/probes/openai_decisions.json`; parser/usage
correctness is guide-only until then. The TF-D.1 regime (live Luna vs replay
of captured fixture) must be pinned in-spec; panel leans replay-as-stable-gate
with live optional.

**C2 — Probe "400 = Decisions validated" is unsafe (5/7: stepfun-5, qwen38-max,
deepseek-v41-flash, glm-53, kimi-k3).** A generic/proxy 400 masquerades as
provider validation. OK-class requires a Decisions-specific fingerprint
(error body cites `questions`/`input`, or an OpenAI error-code allowlist
pinned from the task-0 capture).

**C3 — D10 grant-by-name widening is a real auth-UX/billing risk that must be
documented, not silent (6/7: all but glm-53).** Adding a Decisions row later
activates already-granted names on the new face without re-consent; a listed
name can 400 `protocol_requires_native` on the wrong face with no
discoverable reason. Accepted-risk record + operator/docs copy required.

**C4 — Models-list / listing discovery is under-pinned or contradictory
(6/7: mimo-v26-pro, stepfun-5, qwen38-max, deepseek-v41-flash, glm-53,
kimi-k3).** Sub-findings differ, same gap:
- §2 says there is no Decisions models-list API, yet §4.4 stamps every
  synced listing with the row protocol (mimo: sync poisoning; qwen: if
  upstream `/v1/models` omits Luna, the row has zero callable models).
- `/v1/models` unions by name while routing is per-protocol; the
  name→protocol→row resolution step is never specified (stepfun, kimi).
- Same-name dual rows (D6) vs catalog/ETS keying is unverified (glm, mimo).

## Near-consensus / objective gaps

| # | Item | Count | Models |
|---|------|-------|--------|
| N1 | Fixture redaction checklist (strip `Authorization`, org/project/account ids, billing headers; gitleaks pass pre-commit) | 4/7 | qwen38-max, glm-53, kimi-k3, deepseek-v41-flash (redaction-adjacent) |
| N2 | Error contract: two distinct codes (`protocol_requires_native`, `stream_not_supported`), literal messages pinned in spec; §4.2 "with that code" is ambiguous vs §4.7/TF-D.5 | 4/7 | mimo-v26-pro, qwen38-max, kimi-k3 (codes) + minimax-m3 (message pinning) |
| N3 | Deploy ordering + dashboard write gate until all gateways run post-migration beams; old beams must skip unknown-protocol catalog rows, not crash | 4/7 | minimax-m3, mimo-v26-pro, qwen38-max, kimi-k3 |
| N4 | 10 MiB `?MAX_BODY` vs inline base64 images + unpinned 413 envelope | 4/7 | minimax-m3, mimo-v26-pro, glm-53, kimi-k3 |
| N5 | New TFs: sync output, same-name dual-row per-face routing, listing presence | 4/7 | mimo-v26-pro, stepfun-5, qwen38-max, glm-53 |
| N6 | No automatic retry on native POST (double-billing); probe one-shot with deadline; 5xx/timeout = inconclusive, not "not Decisions" | 3–4/7 | minimax-m3, glm-53, kimi-k3 (+deepseek-v41-flash for probe) |
| N7 | Usage field names (`input_tokens`/`output_tokens`) pinned prematurely — keep null-safe only until capture; `usage_missing` absent from §5.2 enum (needs metric name + always-null alerting) | 3/7 | deepseek-v41-flash, mimo-v26-pro, qwen38-max |
| N8 | Pre-ship metrics check must be a concrete scrape asserting `endpoint="decisions"` / `protocol="openai_decisions"` + audit of existing scrape/alert allowlists | 3/7 | minimax-m3, stepfun-5, kimi-k3 |
| N9 | Passthrough rules unpinned: unknown-field forwarding, upstream status/header/body mapping, `x-request-id` propagation upstream | 2/7 | minimax-m3, kimi-k3 |
| N10 | Probe hygiene: use stored provider-row key (not env), probe with the listing's upstream model name (drop raw `gpt-6-luna` fallback) | 2/7 each | deepseek-v41-flash, kimi-k3 (key); qwen38-max, glm-53 (model name) |
| N11 | Dashboard pricing/unit semantics for Decisions undefined (token-only vs `units`) | 1/7 | stepfun-5 |

## Split opinions (do not auto-apply) — decision owner: user

1. **Empty-set error semantics (2/7: mimo-v26-pro, glm-53 vs D5).**
   Empty eligible set → 400 `protocol_requires_native` conflates wrong-face
   with unknown-model and with face-correct-but-unroutable (disabled/
   unhealthy provider). Panel proposes precedence: unknown name →
   model-not-found (match other faces), face correct but no route → existing
   no-route error, else `protocol_requires_native`. This contradicts the
   locked D5 single-code contract — user decides.
2. **Face/protocol hint in `/v1/models` (deepseek-v41-flash, kimi-k3 and
   stepfun-5 adjacent).** Would change the D3 surface; user decides whether
   the union stays name-only with documented wrong-face 400s.
3. **Raise the Decisions body cap vs document 10 MiB (glm-53, kimi-k3).**
4. **Revisit per-face grants vs keep D10 + docs (implicit in C3).**
5. **Expand eunit beyond classify/normalize/LB predicates to the Decisions
   wire parser (minimax-m3).** See ground-truth note — the project rule
   supports this, but §7 pins a narrower scope; user decides.
6. Single-model items to triage: refusal-only 200 `outcome` class
   (qwen38-max); 300 s idle timeout vs long judgments (mimo-v26-pro);
   path-join contract tests for `/v1` bases / trailing slash (kimi-k3);
   non-Router dashboard pickers disambiguating Decisions-only names
   (glm-53); SQLite CHECK change "likely needs table rebuild" (kimi-k3 —
   unverified claim, confirm against the migration pattern).

## Ground-truth notes

- minimax-m3 cites two repo rules that check out against `AGENTS.md`:
  fixture realism ("never invent frames") and the eunit exception
  (pure parsers may get eunit written first with production-shaped
  fixtures). Both strengthen C1 and split item 5.
- No panel cites verified live wire facts — every Decisions wire shape is
  guide-derived, consistent with §2's own admission. Nothing in any reply
  contradicts the manifest (7/7 PASS) or the closed round-1 splits S1–S3.
- qwen38-max is both panelist and declared master model; `master: null` in
  manifest, so no separate master reply exists — nothing was double-counted.

## Top concrete edits for the live doc

1. **§2/§9/§11:** reclassify fixture capture from "plan task 0" to a
   ship-blocking acceptance criterion; keep the §11 checkbox unchecked until
   `openai_decisions.json` is on disk. Pin TF-D.1's authoritative regime as
   replay of the captured fixture (deterministic), live Luna optional. (C1)
2. **§2:** add fixture redaction acceptance criteria — strip
   `Authorization`, org/project/account ids, billing-identifying headers;
   gitleaks must pass before commit. (N1)
3. **§4.3:** probe with the listing's upstream model name (drop raw
   `gpt-6-luna` fallback); classify 400 as OK only when the error body
   carries a Decisions-specific fingerprint (field names or OpenAI
   error-code allowlist pinned from the capture); add ~10 s one-shot
   deadline, no retry; 5xx/timeout/connect → `probe_inconclusive`, distinct
   from 404/405; use the stored provider-row key and redact key/base64 body
   from probe logs. (C2, N6, N10)
4. **§4.2:** table two distinct codes — `protocol_requires_native` and
   `stream_not_supported` — each with its literal message pinned in the
   spec; keep one envelope shape; delete "with that code". (N2)
5. **§4.4:** resolve the listing-discovery contradiction: pin how Decisions
   listings are populated (Decisions-native allowlist sync and/or
   operator-seeded static fallback if upstream `/v1/models` omits Luna);
   describe name→protocol→row resolution (`pick_listing_route`) for
   same-name multi-face; add a CHECK against `SCHEMA_ETS_CONTRACT.md` that
   catalog/ETS keying tolerates one public name across two provider rows.
   Add TFs for all three. (C4, N5)
6. **§4.5 + D5:** surface the empty-set semantics split for user decision
   (see Splits #1); do not change unilaterally.
7. **§4.4/D10 + operator docs:** record grant-widening as an accepted risk;
   add one-liner operator copy explaining a granted, listed name can 400 on
   the wrong face and that adding a Decisions row widens existing grants.
   (C3)
8. **§9/§6:** add the dashboard write gate — no `openai_decisions` rows
   until all gateway nodes run post-migration beams (generation/min-version
   check); pin release order (gateway CHECK → beams → generation bump →
   dashboard enum → probe UI → operator enable); add rollout invariant +
   regression that old beams skip unknown-protocol catalog rows via a
   tolerant `normalize_protocol` clause instead of crashing. (N3)
9. **§4.2/§4.6:** pin body-limit policy for inline base64 images (document
   10 MiB or raise for Decisions) + 413 envelope; pin no automatic retry on
   the native POST (double-billing); pin passthrough details (forward
   unknown request fields, pass through upstream status/body, propagate
   `x-request-id` upstream). (N4, N6, N9)
10. **§5.1/§5.2:** drop `input_tokens`/`output_tokens` name pinning until
    capture — null-safe parse only; add `usage_missing` to the §5.2 enum
    with a metric name and alerting for permanently-null tokens; replace
    "scrapes accepting unknown labels still work" with a concrete pre-ship
    scrape asserting `endpoint="decisions"` / `protocol="openai_decisions"`
    plus an audit of existing scrape/alert allowlists. (N7, N8)
11. **§7:** expand eunit to the Decisions wire parser (success body, error
    envelope, usage null-safety) per the project's parser-first rule, with
    committed probe-outcome frames (200/400/401/403/404/5xx) — pending user
    sign-off on Split #5.
12. **§5.1/§6:** pin Decisions pricing/unit semantics for dashboard cost
    readouts (token-only, null-safe default) so first-ship stats don't
    silently show nulls with no explanation. (N11)
</content>
</function>
</tool_call>
