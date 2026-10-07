---
model: stepfun/step-5-preview
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: stepfun-5
---

**Verdict:** GO WITH FIXES — the fail-closed routing and error precedence are sound, but the probe contract, fixture redaction scope, and two mechanics (failover policy, gateway "advertisement") are under-specified for ship.

**Critical risks**
- Probe body is undefined — what JSON gets POSTed drives both billing and the fingerprint decision; a 200 probe may be a real billed call on a malformed payload. "May bill" is an unguarded cost leak.
- No-retry vs failover ambiguity: "no automatic retry" is right post-dispatch, but whether pre-connect failure may fail over to a second Decisions provider is unstated.
- Upstream failure map missing: timeout / connect error / 5xx toward a Decisions client has no envelope.
- D13 redaction covers headers/ids only; captured probes likely contain base64 image bodies and user content — PII and fixture-size risk.

**Contradictions / stale**
- Locked-decision row D5 ("revises single-code-only D5") is stale against D5′ used everywhere else.
- "Mirror from `janus_http_responses`" sits next to §8's "handler SSE creep" failure mode, yet no TF asserts the copy didn't carry SSE/translate.

**Missing first-ship**
- Probe request body + fingerprint allowlist frozen from the live capture.
- Explicit Decisions timeout/5xx envelope.
- Negative TF: `translate.tools` / `translate.responses` flips must not alter Decisions behavior.
- Old-beam TF: Decisions row present but unknown to old beams → `no_route`, no crash.
- Definition of how the gateway "advertises Decisions support" for the dashboard write gate.

**Architecture notes**
- Two-point filter (LB candidate-set + dispatch backstop) is the correct fail-closed shape.
- Handler copy is the main design smell: extract a shared preamble (auth, `?MAX_BODY`, JSON-only, `x-request-id`, classify) so Responses' SSE/translate cannot leak by evolution.
- Old-beam row skip is fine for the data plane but makes skipped Decisions rows invisible in admin/stats mid-rollout.

**Top 5 concrete edits**
1. Add the exact probe POST body plus the frozen fingerprint allowlist to §4.3.
2. State failover policy: none once POST is dispatched; pre-connect failure may fail over (§4.3/§4.6).
3. Extend D13 acceptance to strip base64/body payloads and cap fixture size.
4. Add TF-D.11 (translate-knob invariance) and TF-D.12 (old-beam `no_route`, no crash).
5. Specify the advertisement mechanism the write gate reads and its ordering against the generation bump (§6).
