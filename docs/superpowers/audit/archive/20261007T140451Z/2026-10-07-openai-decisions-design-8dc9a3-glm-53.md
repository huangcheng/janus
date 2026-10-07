---
model: zhipuai-coding-plan/glm-5.3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: glm-53
---

**Verdict:** GO WITH FIXES — the design is coherent and fail-closed, but sync over-stamping, probe ordering, and an unpinned 400-fingerprint allowlist must be resolved in the doc before implementation.

**Critical risks**

1. **Sync over-stamping (§4.4):** a Decisions provider row syncing `GET {base}/models` stamps *every* OpenAI chat model as a Decisions listing. The LB's Decisions candidate set then includes models that will 400/404 upstream. §4.4.3 only forbids stamping *without* a Decisions row; it doesn't handle stamping *with* one.
2. **Probe chicken-and-egg (§4.3):** probe requires "listing's upstream model name", but a new Decisions provider has no listings until the operator manually adds them (no upstream Decisions list API). Probe-at-create will have nothing to send; blocked state undefined.
3. **400-fingerprint allowlist (§4.3):** "mentions `questions` / `input`" is too generic — `input` appears in nearly every OpenAI 4xx. The allowlist is deferred to a live capture that D13 says is *not* a design blocker, so a guessed allowlist could ship. §8 itself lists "probe false-OK on generic 400".
4. **Usage shape unpinned (§2/§5):** OpenAI's Responses API uses nested `input_tokens_details`; Decisions may too. "Map only recognized token keys" assumes flat keys — plan a depth-bounded extraction or the parser eunit locks the wrong shape.
5. **No-retry conflates cases (§4.3):** blanket "no automatic retry" also kills failover on *pre-flight connect failure*, which cannot double-bill.

**Contradictions / stale claims**

- Self-review "[x] Guide excerpt fixture on disk" is asserted, not evidenced; TF-D.1 replay depends on it.
- §5 "token-only cost" vs §2 "input-oriented pricing": where the dashboard gets beta-model prices is unaddressed.

**Missing first-ship requirements**

- The write gate reads "gateway generation/min-version advertises Decisions" — the advertisement mechanism is assumed, not specified (fallback "operator confirms" exists but the primary path doesn't).
- Non-POST methods on `/v1/decisions` (expected 404/405, unstated).
- Probe behavior with zero listings.

**Architecture/design notes**

- D5′ precedence table is sound; keeping `no_route` for fully-unknown names matches existing faces.
- 10 MiB cap + inline-base64-only images makes 413 far more user-visible here than on chat; document, don't raise yet.
- Old-beam catalog skip + release ordering is correctly designed.

**Top 5 concrete edits**

1. §4.4: synced listings on `openai_decisions` rows land **disabled** (operator confirms), or skip sync on Decisions rows entirely — manual listings only.
2. §4.3: define probe state `blocked_no_listing` until the first listing exists.
3. §4.3: fingerprint = Decisions-specific error codes / explicit `questions` references only; drop `input`; default unmatched 400s to `probe_inconclusive`.
4. §4.3: permit failover on pre-flight connect failure only; never after the request is sent.
5. §5 + §4.3: name the generation-advertisement mechanism (or make operator-confirm the sole v1 gate); allow one level of usage nesting, pinned by the live fixture.
