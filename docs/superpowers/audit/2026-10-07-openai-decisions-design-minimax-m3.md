---
model: minimax-cn/MiniMax-M3
target: 2026-10-07-openai-decisions-design-target.md
slug: minimax-m3
---

**Verdict:** GO WITH FIXES — sound framing, but several pins (probe semantics, reject site, dual-listing aggregation) must be sharpened before plan-time.

**Critical risks**

1. **Provider probe ambiguity (§4.3):** Naive 200-or-error check will mark wrong-protocol providers (e.g. OpenAI-compatible hosts that only serve `/chat/completions`) as valid Decisions providers if they 401 on `/decisions`. Must distinguish "route exists + auth reached" (401/403 with body) from "route missing" (404/405/connect-error).
2. **`prefer_proto` is bias, not filter (§4.5):** When only a Decisions route exists for a name, LB can still surface it to a chat client. "Filtering" must be a hard predicate in the route-table assembly, not a same-protocol preference.
3. **Dual-protocol provider row denied (O3):** Operator UX forces two distinct provider rows pointing at the same OpenAI base, with two keys. Same OpenAI key reused doubles rotation pain. Spec is silent on whether dashboard permits *key sharing* across two provider rows of the same base.
4. **`/v1/models` dual-listing (§4.4):** A model name bound on both chat and Decisions listings (two providers) — does `/v1/models` return one entry or two? Spec assumes existing aggregation is unchanged but never states it; dispatch-side fan-out is implied.
6. **Migration race (AGENTS.md polling gateways):** `providers.protocol` CHECK extension must be coordinated with catalog reload — followers polling mid-migration see old constraint and reject insert.

**Contradictions / stale**

- §5.1 says "reuse/extend `janus_usage_parse`"; AGENTS.md already says usage shape is OpenAI Chat/Responses/Anthropic. Decisions shape (O1) is not yet pinned — parser must be additive with null-safe fallbacks, not assumed.
- §4.5 rule 1 wording allows reusing `translate_unsupported`; O2 prefers a new code. Pick one and update the error registry referenced by dashboard mapping.

**Missing first-ship**

- Exact `MAX_BODY` number (not "same class as Responses").
- Multipart on `/v1/decisions`: spec implies JSON-only via OpenAI guide, must be stated + rejected explicitly (Janus already parses multipart elsewhere).
- Image data-URL size sanity limit relative to `MAX_BODY`.
- Pricing-field handling: null-tolerant cost calc for `openai_decisions` rows.
- Forwarding contract: pass-through for upstream 4xx/5xx, reshape only for gateway-injected 502/504.
- Audit-log entry per Decisions call (usage_events row with `modality` null).
- Captured probe fixture path: `apps/janus_http/test/fixtures/probes/openai_decisions.json`.

**Architecture notes**

- The reject predicate belongs in `janus_http_proxy:dispatch` *before* LB pick, not in `janus_protocol_translate` (which is a translate module).
- `janus-auto` exclusion is two tasks, not one: gateway candidate filter + dashboard Router UI — split in §4.5 rule 4.
- Streaming 400 code (`stream_not_supported`) is new vocabulary; add to error-code registry.

**Top 5 concrete edits**

1. §4.5: name the exact function (`janus_http_proxy:dispatch` / route-table assembly) that hard-filters Decisions routes for non-Decisions clients.
2. §4.3: pin probe as `POST /decisions`; accept 200 + 401-with-body; reject 404/405/connect-error.
3. §4.4: state that dual-listing names appear once in `/v1/models` per current aggregation; dispatch resolves by client endpoint.
4. §5.1: parser branch is additive + null-safe; pin captured fixture path.
5. §4.5 rule 4: split into gateway-side (candidate filter) + dashboard-side (Router UI) tasks.
