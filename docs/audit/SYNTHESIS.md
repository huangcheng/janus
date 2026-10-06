# Modality-gateway plan audit — final synthesis

Date: 2026-10-07 (closed after 8 rounds)
Models (via `pi`): MiniMax-M3, mimo-v2.6-pro, step-5-preview, qwen3.8-max, deepseek-v4.1-flash, glm-5.3, kimi-k3
Target: `docs/superpowers/plans/2026-10-07-modality-gateway.md` (rev 1 → rev 9)
Raw replies: `docs/audit/archive/2026-10-07-r{1..8}-modality/` (r5 includes one format-violation retry per protocol)

## Verdicts (final round r8 / rev 8)

| Model | Verdict |
|---|---|
| kimi-k3 | GO WITH FIXES — "internally coherent on the hard problems (jvid codec, lazy emission, writer-owned finalization)" |
| minimax-m3 | GO WITH FIXES — "design coherent" |
| mimo-v2.6-pro | GO WITH FIXES — "wire/usage/commit semantics now mostly pinned" |
| stepfun-5 | GO WITH FIXES — "the plan is converged and disciplined" |
| qwen38-max | GO WITH FIXES — "R7 decisions are internally sound" |
| deepseek-v4.1-flash | GO WITH FIXES — "architecture is sound" |
| glm-5.3 | GO WITH FIXES — "rounds 1-7 closed the structural gaps" |

**Overall: GO WITH FIXES (7/7, eight consecutive rounds; every round's
findings applied in the next revision). Loop closed deliberately at
r8** — verdict language reached "converged and disciplined" with
remaining items being stale sentences and two micro-gaps (both applied
in rev 9: chunked-upload admission, two-table idempotency guard
order). Same convergence point as the observability (r8) and
translation (r11) loops; a ninth round would re-read prose.

## What the 8 rounds actually fixed

- **r1→r2 (architecture kill shots):** node-local video job registry
  was broken behind a 3-node LB → STATELESS self-routing HMAC jvids;
  per-route Cowboy idle_timeout does not exist → video wire is
  SSE-always with synthesized heartbeats; non-idempotent spend on
  failover → commit-point discipline + attempt budgets.
- **r3→r4 (contracts):** listings.modality column as the single
  modality source of truth; strict status codes (429 admission vs 413
  size vs response pass-through); TTS sends nothing before first
  upstream byte; ASR admission control + boundary-straddling
  multipart fixtures; pending=NULL→explicit status; computer-use
  hard-reject off native routes.
- **r5→r6 (wire + rows):** video wire contradiction resolved ONCE
  (async POST=JSON, sync POST=SSE hold, poll JSON/SSE-upgrade);
  terminal-result persistence (provider retention ≪ exp — video_jobs
  table); row model finalized (attempts keep is_terminal; lifecycle
  in video_jobs; ONE guarded terminal usage row); TTS commit =
  upstream accept; cowboy 2.12.0 pinned from rebar.lock (read_part
  settled, vendored parser deleted).
- **r7→r9 (endgame semantics):** sync-video ACCEPT = first upstream
  response byte with ABSOLUTE lazy emission; budgets relative to the
  listener (pre-accept 270s); same-mode pre-accept failover;
  single-statement dialect-portable CAS; dashboard backend as the
  single scheduler (no gateway leader election); chunked-upload
  admission; normative-references section pinned (OpenAI/Anthropic
  OpenAPI snapshots + real transport standards).

## Split opinions → recorded

- TTS billing (input chars vs output seconds): chars — consumed
  upstream regardless of output (r3).
- 429 vs 503 for admission: 429 + Retry-After (r3).
- Mode bridging (wait=true): deferred, non-goal (r1).

## Rejections (ground truth beats models)

- "per-route idle_timeout override": Cowboy has no such feature —
  verified against Cowboy 2.12 docs; the mechanism was removed, not
  argued.
- "47 vs 69 gate steps" style counts: TEST-FLOWS.md declared the only
  authority (carried from the translation loop).
- Repeated stale-reference claims in rounds after fixes landed were
  verified against the file before acting; several were noise.

## Final state

`2026-10-07-modality-gateway.md` rev 9 — M1 framework+images, M2
TTS+ASR, M3 video (sync+async, jvid codec, video_jobs persistence),
M4 computer use; A1-A8 decisions; normative references; test-surface
tasks T.1-T.3; ship units with default-off knobs per unblock.
Implementation-ready under AGENTS.md rules.
