---
model: minimax-cn/MiniMax-M3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: minimax-m3
---

**Verdict:** GO WITH FIXES — design is right for first ship, but D15 proxy change, readyz derivation, probe budget, D13 sanitization, and upstream-error envelope need closing before D13 capture.

**Critical risks**

1. **D15 protocol branch in shared `failover_decide`** touches every protocol. No TF proves chat/responses/auto behavior is unchanged. Regression coverage required.
2. **Probe budget is daily only** (20/day, 5-min cooldown) — a misconfigured provider can burn budget in minutes; no per-hour cap.
3. **Write gate "all ready nodes advertise"** is too broad: blocks editing listing metadata (display_name, etc.) during partial outage. Exemption covers only `enabled=0`.
4. **Readyz protocols from "handler module presence"** is fragile under hot code reload; module loaded ≠ route registered. Pin to cowboy routing-tree snapshot at boot.
5. **D13 sanitization contract underspecified** — spec says "replace base64 image bytes; size cap; gitleaks" but no field-by-field redaction list, no request_id scrubbing, no model-ID policy. Gitleaks regex won't catch shape leaks.
6. **Upstream non-2xx forwarded verbatim** — Decisions clients expect JSON envelope; CDN HTML 502 / proxy 504 will break clients. Normalize or document as a known v1 limitation.

**Contradictions / stale claims**

- §1 non-goal "no janus-auto Decisions targets" vs §4.5 auto per-route filter: clarify whether janus-auto can route *through* Decisions listings.
- D16 "extract shared auth/body/request-id helper" is refactor scope but absent from deploy order and TF list; Responses/Decisions drift likely.
- "Probe ~10s" + 5-min cooldown implies max ~288/day; the daily cap (20) binds, not the cooldown. State explicitly.

**Missing first-ship requirements**

- Operator doc for mixed-fleet `no_route` window (acknowledged but not gated).
- Per-provider Decisions concurrency / rate-limit backoff (likely a shared gap — flag, even if shared).
- Rollback plan if D13 reveals contract drift between guide and live API.
- Path-join TF for trailing slashes / base URL variants (implicit only).

**Architecture / design notes**

- Pure passthrough + manual listings + precedence table are sound.
- §4.5 row conflates "name only on chat" and "name on disabled-Decisions + chat"; split or annotate.
- Forward-unknown-JSON is correct; pair with explicit TF.
- "Eligibility before `wrong_modality`" needs a TF proving chat client naming a Decisions-only listing still returns the wrong-modality error path (spec asserts but doesn't prove).

**Top 5 concrete edits**

1. Add **TF-D.failover-regression** over chat/responses/auto proving D15 doesn't change shared behavior.
2. Tighten probe: bind budget in code with TF; add per-hour cap; distinguish 404/405/400 outcomes; ship the classifier spec gated on D13 (O2).
3. Replace module-presence readyz with **cowboy routing-tree snapshot at boot**, exposed via `GET :8080/readyz`.
4. Define **D13 sanitization contract** (every replaced field, model-ID policy, request_id scrub, CI assert shape) before any capture work.
5. Decide **upstream-error envelope policy** (normalize to JSON or document verbatim-passthrough) with matching TF; cover CDN/proxy non-JSON 5xx explicitly.
