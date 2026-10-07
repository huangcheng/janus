---
model: mimo/mimo-v2.6-pro
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: mimo-v26-pro
---

**Verdict:** GO WITH FIXES — sound design, but the probe-OK ambiguity, the 60 s first-byte timeout vs. AGENTS idle reality, and pre-connect body buffering's DoS surface need pinning before implementation starts.

**2. Critical risks**
- Memory DoS: 10 MiB request + 4 MiB response fully buffered per concurrent call (~14 MiB) before any grant/eligibility rejection that matters. No concurrency cap or per-connection memory budget is specified.
- `provider_probe_state.in_flight` has no lease/crash-recovery semantics: a dashboard job that dies mid-probe leaves the provider permanently unprobed (cooldown is transactional, in_flight is not).
- D15's "fails before any request byte is written" is not falsifiable at gun level — gun may have flushed headers before the error surfaces. Name the exact gun event/state you treat as pre-send, or the regression TF is unfalsifiable.
- `GET :8080/readyz` becomes an unauthenticated surface on the agent port; "accepted" is asserted, not argued. Note that healthz exposes existence only while this exposes full protocol capability — fingerprinting aid.

**3. Contradictions / stale**
- Probe OK: "200 and `answers` is a JSON **array** (may contain only `refusal` entries)" vs. "Empty/`answers` missing → inconclusive." Is `[]` OK or inconclusive? Pick one.
- 60 s first-byte timeout is called "align AGENTS idle reality," but AGENTS explicitly says upstreams may take 60 s+ to first byte (hence `idle_timeout` 300_000). 60 s contradicts that and will misclassify slow-but-healthy answers as `upstream_timeout`.
- D12 "reject chunked oversize before upstream" is redundant with "full body buffered before upstream connect" — one mechanism, two claims.

**4. Missing first-ship requirements**
- No migration IDs/files for `provider_probe_state` and the CHECK extension (AGENTS requires migrations under `apps/janus_core/priv/migrations/{postgres,sqlite}/` + flat copies; sqlite path is unmentioned).
- `protocols` captured at listener start goes stale on handler hot-upgrade/beam swap without listener restart — define recapture or accept explicitly.
- Probe budget `20/day`: `day_utc` rollover and multi-replica dashboard race behavior unspecified.
- Nothing states where the sanitized fixture's base64-image replacement shape comes from (D13 gate depends on it).

**5. Architecture notes**
- Pipeline reads the full body (step 2) before grant check (step 4): a grant-denied caller still costs 10 MiB of read. Cheap fix: hoist a `Content-Length` pre-check above body read.
- Precedence table §4.5 is genuinely disjoint and D9's same-commit AGENTS/TF updates remove the `wrong_modality` naming collision — good. Keep TF-D.13 as the regression lock.

**6. Top 5 concrete edits**
1. Resolve `[]`-vs-empty probe ambiguity in §3 (one sentence).
2. Raise or justify the 60 s first-byte timeout (e.g. 180 s) and reconcile with AGENTS idle_timeout.
3. Specify `in_flight` lease expiry (e.g. 5 min) and job concurrency model.
4. Name the exact gun signal counting as pre-send fail in D15.
5. Add migration IDs for `provider_probe_state` + CHECK, including the sqlite copy.
