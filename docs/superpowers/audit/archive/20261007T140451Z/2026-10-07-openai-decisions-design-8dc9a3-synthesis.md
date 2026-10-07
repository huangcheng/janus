# OpenAI Decisions design — audit round 3 synthesis (manual)

Date: 2026-10-07  
Note: master model wrote a broken tool-call stub; this file replaces it from the 7 panel replies.  
Panel: 7/7 PASS, all **GO WITH FIXES**. Quorum met.

## Overall

**GO WITH FIXES** (unanimous). Direction sound; blockers converge on probe contract, Decisions listing sync poisoning, failover/billing, write-gate advertisement, and D11/D13 wording.

## Consensus (≥5/7)

1. **Decisions providers must not auto-stamp full OpenAI `/models` catalog** as Decisions listings (sync poisoning). Manual listings and/or sync-disabled-until-confirm.
2. **Probe:** exact body; OK = structural **200 + `answers`**; unmatched 400 → `probe_inconclusive` until live allowlist; zero listings → blocked; no false-OK on generic 400.
3. **Failover only pre-send** (connect refuse); never after request bytes leave gateway (double-bill). Explicit retry suppression on Decisions face.
4. **Write gate must be server-side** with a **named** advertisement signal (not UI-only / “operator confirms” sole path).
5. **Release order** must match boot-time migrations (leader migrates at boot; followers after), not “CHECK before beams.”
6. **D11 vs D13:** replay gates merge/CI; live fixture gates production claims — say so explicitly.
7. **Grant copy:** widening enables **billable** Decisions success, not mere attempts; grant-deny precedes `protocol_requires_native`.
8. **Fixture redaction** must strip/replace base64 bodies; **usage_unmapped** when usage object present but unrecognized keys.
9. Document **10 MiB / inline-image budget**; normal-traffic log redaction for Decisions.

## Applied in subsequent spec revision

All of the above plus: protocol-eligibility before `wrong_modality`; upstream non-2xx passthrough verbatim; 405 classifiers; TF local-green vs production-green; probe cooldown; Accept: text/event-stream → stream_not_supported.
