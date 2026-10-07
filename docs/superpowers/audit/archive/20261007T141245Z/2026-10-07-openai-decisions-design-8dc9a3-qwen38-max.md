---
model: alibaba/qwen3.8-max
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: qwen38-max
---

**Verdict:** GO WITH FIXES — scope containment is solid, but the failover boundary, upstream URL join, name-collision billing, and write-gate semantics must be pinned before implementation.

**2. Critical risks**
- D15 "pre-send" is undefined. Misclassifying gun connect/TLS/submit/response timeouts permits post-send failover → **double billing** on Luna. Define pre-send strictly as "before the request is handed to gun"; everything after returns the error, no retry.
- D10 grants: confirmation is UI-only, and nothing addresses a Decisions listing **named identically to an existing chat listing** — every key granting that name silently gains a second, differently-billed face. Warn on name collision, not just grant intersection.
- `OpenAI-Organization`/`OpenAI-Project` pass-through is punted ("do not invent"): if the chat faces already forward them, divergence bills Decisions to the default org. Pin parity with existing OpenAI faces now.
- Probe: which listing/model is probed when many exist is unspecified; cooldown is per-provider, but multi-admin races or per-listing probing multiplies billable calls.

**3. Contradictions / stale claims**
- D9 worded globally ("before **any** `wrong_modality` path") conflicts with the invariant that chat-family calls naming a non-chat listing emit `wrong_modality`. Scope D9 to the Decisions face.
- §4.3 forwards to `{base_url}/decisions`, but the guide endpoint is `/v1/decisions`; whether base_url carries `/v1` is never pinned, and no test asserts the final upstream URL.
- `blocked_no_listing` doesn't say whether **disabled** listings count.

**4. Missing first-ship requirements**
- TFs for the 413 cap on the Decisions face, a post-send failure (D15), the readyz write gate, and a chat face hitting a Decisions-only name (`wrong_modality` regression).
- Upstream (gun) request timeout for normal calls — Cowboy idle 300s alone doesn't cover it; Luna + large image can exceed gun defaults.
- Name for the 429 passthrough metric; migration number + sqlite flat copy per repo convention.
- `/readyz` listener port (8080 vs 8090) and its auth.

**5. Architecture/design notes**
- Preamble "extract or copy carefully": choose extract. Copying guarantees drift, and the SSE-creep TF then tests symptoms, not causes.
- Write gate at ≥1 advertising node opens while followers still roll → user-visible intermittent `no_route`; require all ready nodes or document the window explicitly in ops copy.
- The shared eligibility predicate is right; LB/dispatch/auto must import it, never re-derive.

**6. Top 5 concrete edits**
1. D9: "On the Decisions face, eligibility runs before `wrong_modality`; chat-family `wrong_modality` unchanged" + TF-D.8 assertion.
2. §4.3: state the exact upstream URL rule; eunit asserts the full URL for base_url with/without `/v1` and trailing slash.
3. D15: define pre-send = before gun request submission; enumerate timeout/reset classification; add post-send-failure TF.
4. Write gate: require all ready nodes to advertise (or document the no_route window); pin `/readyz` port + auth.
5. Probe: pick the probed listing (first enabled), count only enabled listings for `blocked_no_listing`, name the 429 metric, set per-call upstream timeout.
