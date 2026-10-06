# Full protocol-translation plan audit — final synthesis

Date: 2026-10-06 (closed after 11 rounds)
Models (via `pi`): MiniMax-M3, mimo-v2.6-pro, step-5-preview, qwen3.8-max, deepseek-v4.1-flash, glm-5.3, kimi-k3
Target: `docs/superpowers/plans/2026-10-06-full-protocol-translation.md` (rev 1 → rev 12)
Raw replies: rounds r1-r11 under `docs/audit/archive/2026-10-06-r*-translate/`

## Verdicts (final round, r11 / rev 11)

| Model | Verdict |
|---|---|
| kimi-k3 | GO WITH FIXES — "structurally sound and internally consistent; remaining defects are clarifications" |
| minimax-m3 | GO WITH FIXES — "five clarifications close it" |
| mimo-v2.6-pro | GO WITH FIXES — "contract layer now unusually precise" |
| stepfun-5 | GO WITH FIXES — "C1-C5 read implementable" |
| qwen3.8-max | GO WITH FIXES — "contracts and phasing discipline are sound" |
| deepseek-v4.1-flash | GO WITH FIXES — "implementable" |
| glm-5.3 | GO WITH FIXES — "near-complete" |

**Overall: GO WITH FIXES (7/7, eleven consecutive rounds). All agents
approved in every round; every round's findings were applied in the
next revision. The loop was closed deliberately at r11** — the same
convergence point the observability plan hit (r8 there): verdict
language had reached "structurally sound and internally consistent"
and the remaining findings had degraded from architecture → semantics
→ bookkeeping → wording clarifications, with each round generating
fresh micro-nits regardless (infinite-nit property of LLM auditors).
Rev 12 applied r11's clarification set; a twelfth round would review
prose, not design.

## What the 11 rounds actually fixed (the loop's value)

- **r1→r2**: invented the C1-C6 contract layer — per-direction stream
  skeletons + exact terminators, stop-reason/failure-event maps, usage
  semantics, failover window, tool-call invariants, corpus discipline.
- **r2→r3**: killed three self-contradictions (message_start usage vs
  never-invent; buffer-until-close vs incremental deltas; stream
  headers impossibility), pinned lazy emission + commit point.
- **r3→r5**: ship-unit discipline (predicate removal + knob + e2e in
  ONE commit, physically last), mock fault-injection, per-attempt
  state resets, real accumulation caps, fixture-realism ordering.
- **r5→r8**: error frame REPLACES terminators (per-protocol rules),
  usage merge across split anthropic events, include_usage scoping,
  interleaved-serialization granularity, j-prefixed id scheme, knob
  split per unblock, n>1 unified + evidence rule, corpus-authoritative
  event names + sequence_number, Phase ordering fixed everywhere.
- **r9→r12**: response.incomplete terminal, 4MiB global content cap,
  failure byte order pinned, skeleton-flush-before-error per family,
  dashboard operability for all three knobs, 2.4 eunit/e2e split.

## Consensus points applied (≥5/7, all rounds)

Terminator/usage semantics per pair (7/7 r1); tool-call index-space
invariants (7/7 r1); failover window + per-attempt state (5/7 r1);
fixture realism from real captures (5/7 r1); ship-unit ordering (5/7
r4); error-frame-replaces-terminator (5/7 r5); stale-reference +
knob-split bookkeeping (4-5/7 r6-r8).

## Split opinions → recorded decisions (not silently applied)

- Kill switch granularity: per-route (2/7 r1) → resolved as one knob
  per unblock phase, per-route deferred (r8 consensus).
- n>1 non-stream coupling: gated vs ungated vs own knob (3-way split
  r7) → resolved by evidence rule (r10), bug-fix path stays ungated.
- Structured output on anthropic: strip vs tool_use emulation (2/7
  r7) → strip documented; emulation optional later.

## Rejections (ground truth beats models)

- "E2E gate = 69 steps vs AGENTS.md 47 — one is stale" — both counts
  were stale by the time of reading; resolved by making TEST-FLOWS.md
  the only authority and updating AGENTS.md wording.
- Repeated claims of "stale 1.3 references" in rounds after they were
  fixed (auditors read rev N with rev N-1's complaints fresh); each
  was verified against the file before acting; fixed ones recorded as
  noise.

## Final state

`2026-10-06-full-protocol-translation.md` rev 12 — 26 tasks across 3
phases + C1-C6 contract layer + 3 ship units (1.9, 2.3, 3.5) each
with its own default-off knob, e2e assertions, and flip procedure.
Ready for implementation under AGENTS.md rules (eunit-first on real
captured transcripts, local gate, browser/API verification).
