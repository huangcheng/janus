# Full Protocol Translation Matrix — Implementation Plan

> rev 12 (final) — audit rounds 1-11 applied; loop closed at
> convergence (r11: 7/7 "structurally sound and internally
> consistent", remaining items were clarifications). R11 applied: 2.4
> eunit/e2e split mirroring 1.4b/1.9, zero-frame failure flush rule
> per-family pinned, n>1 bug-fix path stays ungated (no post-hoc
> flip), anthropic input-token placement settled once, Phase-2
> rollback+soak one-liners. R10 summary:
> 1.9 prerequisites include 1.6a, dashboard hosts all three knobs
> (Phase-2/3 flip procedures gain their operator surface), tools knob
> declared the n>1 streaming-reject carrier + error precedence chain,
> non-stream n>1 evidence re-homed to the request-translate eunit, 2.3
> physically last after 2.4, 2.4 gains tools/vision/cap-error
> assertions, failure byte order pinned (usage chunk replaced on the
> wire), zero-frame failure flushes the skeleton first (corpus default),
> 4MiB total-content cap applies to every target. R9 summary:
> response.incomplete as a legal →responses terminal (C1), terminator
> wording once-per-TERMINATED-response, C4(b) split flushed vs
> never-flushed headers (plain HTTP error when SSE never started),
> chat error replaces the finish CHUNK while [DONE] stays transport,
> C5 granularity precise (text streams unless an open tool call
> interleaves; 4MiB reconstruction cap scoped to →responses; zero-args
> ≡ {}; deferral bounded by upstream cadence), degradation-payload
> schema numbered as 1.6a, 1.0 DONE adds failed/incomplete captures +
> the only two documented splice-built synthetic exceptions, 2.3 gets
> prerequisites + 2×2 knob-composition matrix, Phase-3 third knob
> named + checkbox order matches prose, 3.4 latency budget +
> 50×4MiB memory model. R8 summary:
> synthesized-id prefixes unified to jresp_/jmsg_/jfc_/jitem_
> everywhere (rev-8 left two schemes), kill switch split per unblock
> (stream_translate_tools_enabled / stream_translate_responses_enabled
> — single-knob cross-phase coupling was the r8 consensus defect), n>1
> transition note, lazy emission excludes skipped events, C1 responses
> row purged of invented-looking event names (corpus-only). R7 summary:
> C4 rewritten as the complete three-outcome rule (retry silent /
> all-fail one terminal / post-commit error-replaces-terminator),
> interleaved serialization = full-accumulate-emit-at-close with
> text-order eunit + 4MiB total-content cap, j-prefixed synthesized
> ids, failure never synthesizes success terminals + terminal-event
> degradation schema as its own pre-1.9 task, n>1 non-stream resolved
> by evidence rule, prefer_proto becomes a permanent lossy-pair
> native-preference with both-direction e2e, 1.0 capture done-criteria
> enumerated (vision/thinking/interleave/truncation/>64-calls/ping/
> zero-arg/multi-turn), 1.9 assertion list completed (vision, abort,
> retry-after-headers, n>1), 1.8b error counter + additive-only
> migration + TEST-FLOWS authoring in 1.8c, Phase-3 execution order
> fixed (soak last), r7 splits recorded with resolutions. R6 summary:
> stale 1.3→1.9 references + ship unit physically last in Phase 1,
> unified n>1 policy (cross-protocol + responses providers + janus-auto;
> knob-gated, native chat/anthropic unaffected), C4 header-flush +
> all-attempts-fail + ping-never-commits wording, corpus-authoritative
> responses event names + sequence_number monotonicity eunit (invented
> names deleted), canonical error struct + failure-usage +
> zero-data-frame rule + invalid_request_error map, cache-token
> per-direction rule + include_usage rejection fallback, interleaved
> tool-delta buffering + janus-namespaced synthesized ids,
> cap-exceed/client-abort tests, janus-auto + prefer_proto guards in
> 1.9, Phase-2 ship unit 2.3/2.3a + dual-direction E2E, 3.3 reworded
> as corpus extension, Phase-3 3.5 cleanup task. R5 summary:
> error frame REPLACES the success terminator (per-protocol rules) +
> error-type map, unknown/ping events skipped and never commit the
> stream, usage merge (anthropic input+output split) and include_usage
> scoped to chat upstreams, per-stream accumulation caps (256KiB/call,
> 64 calls, 1MiB total) with single decode-at-close, ship unit
> renumbered 1.9 with enumerated prerequisites + gateway-first
> DEFAULT-OFF knob + flip-after-smoke rollout, n>1 unified to
> n_unsupported everywhere cross-protocol (documented behavior
> change), usage-row translated/mapped-stop columns as the knob's
> observability, Phase-2 synthesized-id rules + sampling params,
> Phase-3 idle_timeout + mid-stream incomplete. R4 summary:
> unblock restructured as ONE ship unit (predicate removal + knob +
> e2e assertions + entitlement assertion, single commit — resolves the
> 1.3/1.4 ordering deadlock), mock fault-injection task, eunit vs e2e
> split for pre-unblock testing, per-tool-call 256KiB args cap (the
> parser's 1MiB leftover cap never bounded cross-event accumulation),
> terminator once per COMMITTED response, corpus normative for event
> order + documented message_start input_tokens=0 deviation,
> stream-side degradation channel in 1.6, Phase-3 request-side reverse
> translate + synthesized item-id rules + n>1→responses rejection,
> substrate applicability note. R3 summary:
> →chat usage wire order (finish→usage→[DONE], corpus authoritative),
> commit = first DATA frame (headers excluded), truncated-args-at-close
> error path, Phase-1 reordering (substrate 1.4-1.8 BEFORE unblock
> 1.3; knob e2e-tested), n>1 non-stream regression reverted,
> cache-token migration + dashboard knob UI + route-matrix warning
> moved into Phase 1, responses captures in 1.0, 3.2 eunit-first,
> item-id space noted. R2 summary:
> lazy skeleton emission (failover window vs eager message_start),
> message_start usage zeroing vs never-invent, stream-header
> impossibility (pre-commit headers only; degradations in terminal
> events), failure-event taxonomy incl. response.failed, four index
> spaces + terminal-signal invariant (fragments stream), single merged
> corpus with mock replay, global stream_translate_enabled knob ships
> WITH the unblock, tool_choice/parallel/stop request mappings,
> reasoning items in the responses skeleton, n>1 rejected on
> non-stream too, Phase-1 concurrency smoke.

> **For agentic workers:** implement task-by-task with checkboxes.
> Testing rules from AGENTS.md apply: eunit FIRST for pure event
> mapping (production-shaped fixtures = JSON-decoded binaries, real SSE
> line shapes), E2E gate for behavior, browser only for dashboard.

**Goal:** Make Janus a protocol-agnostic gateway: any client protocol
(openai_chat / openai_responses / anthropic_messages) × any provider
protocol × streaming and non-streaming × full request feature set
(tools, vision, structured output, reasoning). No "toy" 400s for
translatable requests.

## Current coverage (2026-10-06)

| client ↓ / provider → | chat | anthropic | responses |
|---|---|---|---|
| **chat** | native | req+stream (text+thinking only) | req only |
| **anthropic** | req+stream (text+thinking only) | native | req only |
| **responses** | req only | req only | native |

Streaming blocked cases (dispatch 400 today, with same-protocol route
preference as of today's fix): responses client + any non-responses
provider; tools/vision/n>1 on chat↔anthropic streams.

## Semantically impossible (documented, not faked)

- `n>1` streaming → anthropic provider (no multi-choice support):
  reject with `n_unsupported`, do not silently degrade.
- Anthropic `cache_control` → non-anthropic providers: strip; the
  `X-Janus-Dropped` header carries it on NON-STREAM replies, the
  terminal event + usage row on streams (C2 channel rule).
- Provider-side exclusive features (e.g. responses `previous_response_id`
  server state) → cross-protocol: strip with header; same-protocol native.

## Cross-cutting stream contracts (every pair, every phase)

**C1 Stream skeletons & terminators.** Each direction has a REQUIRED
event skeleton; the terminator is exact final bytes, emitted exactly
once per TERMINATED response (pre-commit retries emit nothing
client-visible at all). **Lazy emission:** no skeleton event is written
until the first CONTENT-bearing upstream event arrives (deltas,
blocks, finish events count; skipped events — pings, in_progress
refreshes — do NOT trigger emission) —
the failover window (C4) must not close on an eagerly-emitted
`message_start`/`response.created`.

| direction | skeleton | usage placement | terminator |
|---|---|---|---|
| →chat | role delta first, content/tool deltas, finish_reason chunk, then the usage-only chunk (empty `choices`, only when upstream reported usage) | usage-only chunk AFTER finish, BEFORE `[DONE]` — real OpenAI wire order; the corpus is authoritative | `data: [DONE]\n\n` |
| →anthropic | `message_start` (id/model) before any block — usage fields ZEROED here; real counts in `message_delta.usage` at the end | `message_delta` | `event: message_stop` frame |
| →responses | `response.created`, then per item: `output_item.added` → part/delta events → `output_item.done` (message items and reasoning/summary items; exact part + delta event NAMES from the 1.0 corpus — none invented here), `response.completed` — OR `response.incomplete` when the source
finished `length`/`max_tokens` (C2 map; both are legal terminals) |
the `usage` FIELD of the response object inside the terminal event |
`response.completed` or `response.incomplete` frame |

→responses must also emit reasoning/summary item framing when the
source stream carries thinking — exact event NAMES come from the 1.0
corpus (this plan deliberately invents none; `response.in_progress`
etc. included). The corpus is NORMATIVE for event order, exact names,
and `sequence_number` monotonicity (2.1 eunit asserts it strictly
increases across every emitted event); the C1 table is the
cross-family contract. Known deviation, documented once and final: native anthropic fills
real `input_tokens` in `message_start`; a translator cannot know them
at flush time — translated `message_start` carries input_tokens 0 and
ALL totals (input+output) land in `message_delta.usage`, verified
against the real Anthropic SDK in 1.4b (corpus fixtures encode this
shape; no other placement is considered).

**C2 Stop-reason & failure-event map (both ways).** `stop↔end_turn`,
`tool_calls↔tool_use`, `length↔max_tokens` (responses:
`incomplete(incomplete_details.reason=max_output_tokens)`),
`stop_sequence↔stop` (chat has no distinct stop_sequence reason — the
map is many-to-one, that direction is lossy by design),
`content_filter↔refusal`. Degradation signals (mapped stop, dropped
feature) go in a PRE-COMMIT response header for non-streaming
replies ONLY; on streams, headers are already committed —
degradations are recorded in the terminal event + usage row instead.
Failure events REPLACE the success finish (never append both):
→ chat emits `data: {"error":...}` then `[DONE]` — the error frame
replaces BOTH the finish_reason CHUNK and the usage chunk (on failure,
usage rides the usage row ONLY, never the wire); `[DONE]` remains the
transport terminator, still exactly once; → anthropic emits `event: error` ALONE
(no message_stop after an error); → responses emits `response.failed`
ALONE (no response.completed). Canonical error struct (internal): `{type, code, message}` —
serialized per target (chat: error JSON `type`/`code`; anthropic:
`error.type`/`error.message`; responses: `response.failed.error`).
Type map: anthropic `overloaded_error→server_error`,
`api_error→server_error`, `rate_limit_error→rate_limit`,
`invalid_request_error→invalid_request_error` (mid-stream variants
included); chat upstream non-2xx body `type` passes through when
present; responses failure `error.code` passes through. On failure the
usage row still records whatever the upstream reported (responses
`response.failed.usage`; anthropic `message_delta` before an error
still counts) — usage rides the usage row ONLY; a failure never
synthesizes a success terminal event. A failure before any
content frame still flushes the OPENING skeleton event first on
targets whose SDKs require it — corpus-verified per family:
→responses emits `response.created` then `response.failed`;
→anthropic emits `message_start` then `event: error`; →chat needs no
skeleton. Then error event + terminator + usage row as everywhere. The degradation payload
schema of terminal events (`x-janus-mapped-stop`, dropped
structured-output, cache_control drops) is eunit'd as its own
pre-1.9 task. Unknown upstream events
(incl. anthropic `event: ping`, response.in_progress refreshes) are
SKIPPED — they never trigger skeleton emission (C4) nor reach the
client; kimi corpus fixtures must contain pings to prove it.

**C3 Usage semantics.** Upstream usage arrives: chat = trailing chunk
(include_usage injection+retry — CHAT-PROTOCOL upstreams ONLY, never
send `stream_options` to anthropic/responses upstreams; composes with
1.8: knobs translate first, injection last); anthropic =
`message_start.input_tokens` + `message_delta.output_tokens` (MERGE
both into the single target usage event — dropping input tokens
corrupts billing); responses = `response.completed.usage`. Emit at
the pair's usage event (C1 table); upstream omission → tokens stay
null (existing `unreported` accounting) — never invent counts. Zeroed
`message_start` usage on →anthropic is framing, not a count: clients
read totals from `message_delta.usage`. Cache tokens: `cache_read_input_tokens`
survives only when the UPSTREAM is anthropic (recorded on the usage
row via 1.8b; cross-protocol it is dropped and counted in
`mapped_stop`-style degradation accounting). include_usage fallback:
when a chat upstream rejects `stream_options` (the existing
inject+retry already retries once), tokens stay null — unreported
accounting, never invented. eunit: non-zero, non-duplicated
input+output counts through every direction.
Per-attempt usage rows keep `stream=1`, `request_ref`, `attempt`.

**C4 Failover window (complete rule).** Commit point = the FIRST
client-visible DATA frame. Three outcomes: (a) attempt fails
pre-commit and another is tried → NOTHING client-visible is emitted
for the failed attempt (headers may have flushed; they are static by
design, C2, and are not the commit boundary); (b) every attempt fails pre-commit → if headers have NOT been
flushed (no stream_reply yet) a normal HTTP 4xx/5xx JSON error goes
out — no SSE at all; if headers HAVE flushed → ONE target-format
error event + terminator + terminal usage row (owed since the flush); (c) failure after
commit → C2 error frame REPLACES the success terminator. Retry is
legal only pre-commit; unknown events (ping etc., C2) never commit;
the retry-after-headers-flush proof is a 1.9 e2e assertion. After commit: terminate with the target-format
error event (C2) + terminator; a half-open tool block is closed by the
error event (no `content_block_stop`/finish for it — the error IS the
terminal signal); write the terminal usage row for the partial
attempt. Synthesized call ids must never repeat across attempts
(eunit-asserted). `sse_st` — including tool
accumulators — is per-attempt state; every retry starts a fresh
`translate_sse` state. No cross-attempt carryover, ever.

**C5 Tool-call invariants.** There are FOUR index/id spaces — chat
`tool_calls[i].index`, anthropic `content_block.index` (counts ALL
blocks incl. text), responses `output_item` identity (its own `id`
string space, e.g. `item_…`/`fc_…`), and tool call ids.
Maintain per-stream maps between them; never reuse one space's number
as another's. Synthesized id prefixes are janus-namespaced (`jresp_`/`jmsg_`/
`jfc_`/`jitem_`, 2.1) and collision-eunit-tested against replayed
upstream ids. Streaming granularity: TEXT fragments stream through immediately
UNLESS an open tool call interleaves (chat text between tool-call
fragments of an unclosed call) — only then is that text deferred to
its close point and emitted as a sequential block (anthropic has no
interleaving; text-order preservation eunit-asserted on 1.0's
interleaved transcripts incl. kimi thinking+tool_use). A tool call
with ZERO argument bytes is complete with `{}`. Caps: 256KiB/call,
64 calls, 1MiB total args, and a 4MiB total-content cap per stream
that applies to EVERY target (deferred text under interleaving must be
bounded on →chat/→anthropic too, not just →responses' full-object
reconstruction; 3.4's soak budgets 50×4MiB). Client-timeout risk while deferring: the deferral window is
bounded by the upstream's own stream cadence (cowboy idle_timeout
300s), and any upstream stall surfaces as C2 error, not a hang. Argument FRAGMENTS may stream through incrementally
(`input_json_delta` etc.); the invariant is on TERMINAL signals: never
emit a tool call's closing signal (`content_block_stop`, chat finish
with `tool_calls`, `output_item.done`) until the accumulated args are
complete JSON — a truncated tool call must not look finished.
Accumulation is bounded by NEW per-stream caps — 256KiB args per call
id, 64 calls per stream, 1MiB total args (exceed → C2 error path) —
the existing 1MiB parser leftover cap bounds a single event, NOT
cross-event accumulation. Completeness = ONE JSON decode after the
FULL binary concat at close time; never decode per-fragment (a UTF-8
sequence split across fragments would fake truncation — the exact
fixture-realism bug class AGENTS.md warns about). If args are invalid
JSON at close time (upstream bug or cut), do NOT deadlock or emit the
finish: take the C2 error path — target-format error event +
terminator + terminal usage row. Mapped-stop degradations on streams
are recorded in the terminal event payload (`x-janus-mapped-stop`
field) and the usage row, never in headers. Server-generated ids
pass through unchanged; synthesized ids are per-attempt, non-repeating
(C4). Multi-turn tool RESULTS (anthropic `tool_result` ↔ chat
`role:"tool"` ↔ responses function_call_output) translate on the
request side with the same fixture discipline.

**C6 Fixture realism.** ONE corpus, built by the capture harness
(1.0) and consumed by every phase: dashscope/volcengine (chat), kimi
(anthropic), OpenAI reference (responses), each file carrying
provider+date metadata; the E2E mock upstream REPLAYS these same
files (incl. usage-bearing ones), so gate assertions on non-zero
tokens run against realistic payloads. No hand-invented frames at any
phase. Refresh contract: re-capture when a provider ships API
changes. (3.3 extends the corpus, it does not create a second one.)

## Phase 1 — chat↔anthropic streaming: tools + vision

State machine extensions in `janus_protocol_translate` (sse_st gains
tool-call accumulator; content blocks with image parts pass through
translate on the REQUEST side already — extend STREAM reply side):

- [ ] 1.0 Capture harness: record real transcripts into
      `test/fixtures/sse/` with provider+date+endpoint provenance
      metadata. DONE = the corpus contains, per family (dashscope
      chat, kimi anthropic, OpenAI responses): plain text+usage,
      tool-call sequences, VISION (image-bearing), THINKING blocks,
      INTERLEAVED thinking/text/tool_use, at least one mid-stream
      TRUNCATED transcript, one >64-calls transcript (cap proof),
      ping-bearing (anthropic), zero-arg tool, empty-input, multi-turn
      tool RESULT histories (1.7), and responses `response.failed` +
      `response.incomplete` transcripts. Two DOCUMENTED synthetic
      exceptions (the only ones): the >64-calls and mid-stream
      truncated transcripts are CONSTRUCTED by splicing captured real
      frames, never invented wholesale. Phase 2 consumes the responses
      transcripts; every eunit in this plan runs on this corpus.
- [ ] 1.1 eunit (write first, on 1.0 fixtures): chat `tool_calls`
      delta sequence → anthropic `message_start` +
      `content_block_start(tool_use)` + `input_json_delta` +
      `content_block_stop` + `message_delta(tool_use)` +
      `message_stop` (full C1 skeleton); and the reverse (anthropic
      tool_use blocks → chat tool-index remap per C5, args assembly,
      final `finish_reason=tool_calls`).
- [ ] 1.2 eunit: image parts (chat `image_url` data URLs ↔ anthropic
      base64 source blocks) on the request translate path, stream and
      non-stream.

- [ ] 1.4a Mock fault-injection modes (before 1.9 lands): truncate
      stream at frame N, kill after first byte, fail pre-first-byte —
      deterministic, reused by 2.4. Without these the C4 window tests
      are untestable.
- [ ] 1.4b eunit (pre-unblock, runs against the not-yet-unblocked
      state machine directly): full C1 skeleton order, translated
      terminators, non-zero-token usage assembly, half-open-tool
      terminal behavior on mid-stream cut (C4), per-attempt id
      non-reuse, cap-exceed (args/calls/total) error paths, client-abort
      cleanup (no stuck inflight/leftover), 10-concurrent
      translated-stream smoke. The E2E versions of these assertions
      activate in 1.9's ship unit.
- [ ] 1.5 `n>1` — ONE rule, everywhere (subsumes 3.2b): any request
      with `n>1` is rejected `n_unsupported` on (a) ALL cross-protocol
      translate pairs, stream and non-stream — fanning out N billable
      upstream calls is a footgun and today's silent single-completion
      degrade is worse; (b) ANY route whose provider protocol is
      responses (the API has no `n`); (c) janus-auto virtual model
      requests (adjudication multiplicity is undefined). Same-protocol
      chat/anthropic natives keep native n>1. Non-stream evidence
      rule: 1.8's request-translate eunit suite FIRST characterizes
      today's behavior — if the
      translate silently degrades n>1 to one completion (expected),
      the reject ships UNGATED in 1.9 as a bug fix with a changelog
      note — and STAYS ungated (no post-hoc knob flip); if
      multi-completion genuinely works, the reject ships knob-gated
      from the start. The evidence suite decides BEFORE 1.9 commits.
      Streaming reject is always knob-gated; e2e asserts both regimes.
      Transition: the changelog names the behavior change explicitly,
      and the gate runs the new-reject assertion ONLY while the
      relevant knob is on (off = legacy path unchanged, asserted).

- [ ] 1.6a Terminal-event degradation payload schema (pre-1.9, the
      C2 mandate given a number): `x-janus-mapped-stop`,
      `x-janus-dropped` items (structured-output, cache_control), and
      the usage-row `mapped_stop` counter — one JSON schema, eunit
      roundtrip, consumed by 1.9's assertions.
- [ ] 1.6 Structured output: `response_format/json_schema` passes
      through when the target supports it; otherwise strip — non-stream
      replies note it in the `X-Janus-Dropped` header, STREAMS record
      it in the terminal event + usage row (C2: no degradation info in
      committed stream headers). eunit: both branches, both transports.
- [ ] 1.7 Multi-turn tool results: request-side translate of anthropic
      `tool_result` ↔ chat `role:"tool"` (and images inside results),
      eunit on captured multi-turn transcripts.
- [ ] 1.8 Request-side knobs: `tool_choice` (auto/none, required↔any,
      named↔tool{name}), `parallel_tool_calls`, chat `stop` ↔ anthropic
      `stop_sequences` — eunit on captured shapes before any stream
      work depends on them.
- [ ] 1.8b Usage-row extensions (one migration, postgres+sqlite +
      flat copies, shipped BEFORE 1.9): `cache_read_input_tokens`,
      `translated` SMALLINT 0/1, `mapped_stop` counter; writer +
      dashboard display; eunit with SMALLINT/binary fixtures. These
      columns are the knob's 3am dashboard — without them an operator
      cannot see translated-stream volume before flipping it. Also:
      translated-stream ERROR counter; the migration ships with a
      tested down path (or is additive-only, asserted). 1.8c also
      authors the TEST-FLOWS.md sections for 1.9 and 2.3 in the same
      commits as the gate steps (authoring rules live there).
- [ ] 1.8c Sibling-repo tasks (dashboard): settings UI that hosts ALL
      THREE knobs as they ship (`stream_translate_tools_enabled` in
      Phase 1; the responses knobs' controls land with 2.3/3.5 so
      2.3a's flip procedure has an operator surface from day one);
      move the per-model client-protocol route matrix warning (was
      2.5) HERE — the operational need exists the moment 1.9 unblocks
      streaming (1.9). The tools knob is also the CARRIER for the
      `n>1` streaming reject (one gate, stated once, asserted in 1.9);
      non-stream n>1 evidence lives with the REQUEST translate eunit
      (1.8's suite), not 1.4b's SSE suite. Error precedence when several
      apply: `no_route → entitlement → n_unsupported → translate` (404,
      403/entitlement, 400, 400 — asserted once in 1.9).
- [ ] 1.9 THE UNBLOCK SHIP UNIT (last task of Phase 1; one commit).
      Prerequisites, ALL landed first: 1.0-1.2, 1.4a/1.4b, 1.5, 1.6a,
      1.6, 1.7, 1.8, 1.8b (migration), 1.8c (dashboard UI). Cross-repo
      order: gateway deploys first with the knob DEFAULT OFF (zero
      behavior change), dashboard UI ships, then the operator flips
      the knob after gate+smoke — a rolling deploy never carries a
      default-on behavior change. The commit removes
      `has_non_text_content` / `has_tools` from
      `stream_translate_blocked`, ships `stream_translate_tools_enabled`
      (default off, hot-reloaded), and activates the e2e assertions:
      knob on → full translated tool streams (C1 order, non-zero
      usage); knob off → legacy 400; `n>1` stream → `n_unsupported`;
      structured-output strip → `X-Janus-Dropped` non-stream /
      terminal-event stream; entitlement/LB assertion (formerly-400ing
      tool stream still passes entitlement, one usage row per attempt,
      rows flagged `translated=1` with `mapped_stop` counter from
      1.8b); janus-auto cross-protocol streaming asserted under knob
      on AND off; prefer_proto guards BOTH ways (knob off keeps
      E.5/E.6 green; knob ON prefers the native route for a lossy
      pair); vision e2e (image-bearing request → translated stream →
      non-zero usage); non-stream n>1 reject per 1.5's evidence rule;
      client-abort cancels upstream (no orphan gun streams);
      retry-after-headers-flush switches upstreams; scaled soak 20
      concurrent translated streams (50 stays in 3.4).

## Phase 2 — responses client streaming translation

- [ ] 2.1 eunit: responses SSE event grammar
      (`response.created/output_item.added/output_text.delta/
      function_call_arguments.delta/output_item.done/response.completed`)
      ← chat chunks and ← anthropic events; bidirectional state machine
      (`translate_sse` gains responses target). Synthesized id rules
      live here and in C5: `jresp_`/`jmsg_`/`jfc_`/`jitem_` prefixes
      allocated from per-stream counters, collision-eunit-tested
      against replayed upstream ids — the only id scheme in the plan.
      Request-side owners: `max_output_tokens↔max_tokens`,
      temperature/top_p passthrough, `function_call_output` items
      (2.2 request grammar covers construction; eunit asserts the
      roundtrip against corpus fixtures).
- [ ] 2.2 Request translate: responses `input` (string / content array
      / function_call items) + `tools` + `tool_choice` → chat
      messages+tools and → anthropic system/messages/tool_use;
      `instructions` → system message; `reasoning` effort → provider
      thinking config where supported, else stripped+recorded;
      `previous_response_id`/`store` → stripped + recorded (server-side
      session state is a documented impossible).
      (Non-stream versions exist; extend + harden with fixtures.)
- [ ] 2.3 THE PHASE-2 SHIP UNIT (physically LAST task of Phase 2,
      after 2.4; one commit; mirrors 1.9's discipline): prerequisites
      1.0-corpus readiness (responses transcripts), 2.1, 2.2, and
      2.4's eunit halves.
      Removes the `openai_responses` gate from
      `stream_translate_blocked` under its OWN knob
      `stream_translate_responses_enabled` (default off → flip after
      gate+smoke). Knob-composition matrix is explicit and
      e2e-asserted (2×2): responses-knob on/off × tools-knob on/off —
      the four cells behave independently (no hidden coupling).
- [ ] 2.3a Phase-2 flip procedure: documented re-flip steps (gate
      green → deploy with knob off → dashboard smoke → flip → verify
      translated flag volume on the dashboard), mirroring 1.9 — plus
      ROLLBACK: flip off is the entire rollback (hot-reload, no
      redeploy), and a 10-concurrent Phase-2 soak rides the 2.3 gate
      (50-stream soak stays in 3.4).
- [ ] 2.4 eunit HALF (pre-2.3; the E2E halves of these assertions
      ACTIVATE inside 2.3's ship commit, same 1.4b/1.9 split):
      chat→responses AND anthropic→responses on corpus transcripts;
      event order, TOOLS translation (jfc_/jitem_ ids, four index
      spaces), VISION passthrough, 4MiB reconstruction-cap error path,
      terminator, usage row (stream=1, NON-ZERO token counts), and the
      C4 window (mid-stream upstream cut after first byte → target-
      format error event + terminal partial usage row, no retry).
- [ ] 2.5 (moved to 1.8c — dashboard route-matrix warning ships with
      the Phase 1 unblock, not after Phase 2.)

## Phase 3 — responses as PROVIDER + conformance suite

Execution order (checkboxes below are in this order; the soak is LAST,
after everything it measures exists): 3.3 corpus extension → 3.2a
request-side reverse → 3.2 reverse state machines → 3.2b/3.1 wiring →
3.5 ship unit → 3.4 soak.

- [ ] 3.3 EXTEND the 1.0 corpus (not a second corpus) with
      provider-side captures: responses-provider reply transcripts and
      chat/anthropic histories for 3.2a request construction; same
      manifest discipline; eunit consumes them — no hand-invented
      frames (AGENTS.md fixture-realism rule).
- [ ] 3.2a Request-side reverse translate: chat/anthropic history →
      responses `input` items (assistant `tool_calls` ↔ `function_call`
      with `call_id`, images, system) — corpus fixtures; call_id
      mapping rules use the C5 j-prefixed scheme (`jitem_`/`jfc_`),
      collision-eunit-tested against upstream ids.
- [ ] 3.2 chat/anthropic clients → responses provider, streaming +
      non-streaming — REVERSE state machines, eunit FIRST on the 1.0
      responses transcripts (mirrored direction), then wire.
- [ ] 3.2b (folded into 1.5's unified `n>1` rule — responses
      providers reject `n>1` at the adapter; no separate policy).
- [ ] 3.1 Provider adapter `openai_responses` upstream streaming
      (gun SSE, event relay into the translate pipeline).
- [ ] 3.5 THE PHASE-3 SHIP UNIT under the third knob
      `stream_translate_provider_responses_enabled` (same default-off
      discipline): removes any remaining responses-PROVIDER
      stream-block leg, e2e gate mirroring 1.9's assertions; adapter
      non-2xx errors from responses upstreams map through C2.
- [ ] 3.4 Load/soak (LAST): 50 concurrent translated streams; assert
      no leftover / memory growth in sse_st (caps hold; budget 50×4MiB
      worst-case reconstruction), TTFT p95 regression < 10% vs native;
      responses upstream adapter honors the 300s idle_timeout
      convention; mid-stream `response.incomplete` (not just terminal)
      maps per C2 (→chat finish_reason=length, →anthropic stop
      max_tokens).

## Route-preference substrate (shipped 2026-10-06)

`janus_lb:pick_route/pick_listing_route` accept `#{prefer_proto => P}`:
streaming translate-blocked requests prefer same-protocol routes and
fall back to all routes (400 diagnostic preserved). E.5/E.6 gate steps.
NOTE: as phases land, the blocked predicate shrinks (Phase 1 removes
tools/vision, Phase 2 the responses-client gate). The bias is NEVER
removed — it stays as a permanent SAME-PROTOCOL PREFERENCE for every
pair whose translation is still lossy (stop_sequence, cache_control,
reasoning fidelity) and for `n>1` forever; when both routes are
equally able, native wins (1.9 e2e asserts the native route is
preferred with the knob on). It is the permanent backstop for the
remaining impossibles.
