# Full Protocol Translation Matrix — Implementation Plan

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
- Anthropic `cache_control` → non-anthropic providers: strip + `X-Janus-Dropped` response header.
- Provider-side exclusive features (e.g. responses `previous_response_id`
  server state) → cross-protocol: strip with header; same-protocol native.

## Phase 1 — chat↔anthropic streaming: tools + vision

State machine extensions in `janus_protocol_translate` (sse_st gains
tool-call accumulator; content blocks with image parts pass through
translate on the REQUEST side already — extend STREAM reply side):

- [ ] 1.1 eunit (write first): chat `tool_calls` delta sequence →
      anthropic `content_block_start(tool_use)` + `input_json_delta` +
      `content_block_stop` frames; and the reverse (anthropic tool_use
      blocks → chat `tool_calls` index/id/args assembly, one final
      `finish_reason=tool_calls`). Fixtures = real captured SSE lines.
- [ ] 1.2 eunit: image parts (chat `image_url` data URLs ↔ anthropic
      base64 source blocks) on the request translate path, stream and
      non-stream.
- [ ] 1.3 Remove `has_non_text_content` / `has_tools` from
      `stream_translate_blocked`; keep `n_blocked` + responses-client
      gate only.
- [ ] 1.4 E2E gate steps: mock upstream emits tool-call SSE sequences in
      both wire formats; assert translated terminators + usage rows.
- [ ] 1.5 `n>1` handling: translate by issuing N upstream requests?
      NO — document: reject `n>1` on translate pairs (`n_unsupported`).

## Phase 2 — responses client streaming translation

- [ ] 2.1 eunit: responses SSE event grammar
      (`response.created/output_item.added/output_text.delta/
      function_call_arguments.delta/output_item.done/response.completed`)
      ← chat chunks and ← anthropic events; bidirectional state machine
      (`translate_sse` gains responses target).
- [ ] 2.2 Request translate: responses `input` (string / content array
      / function_call items) + `tools` → chat messages+tools and →
      anthropic system/messages/tool_use. (Non-stream versions exist;
      extend + harden with fixtures.)
- [ ] 2.3 Remove the `openai_responses` gate from
      `stream_translate_blocked` (chat/anthropic providers).
- [ ] 2.4 E2E: mock `/v1/responses` (native passthrough exists) +
      mock chat SSE → responses client stream; assert event order,
      terminator, usage row (stream=1, tokens set).
- [ ] 2.5 Dashboard: bind-time warning when a tier/model has NO route
      that can serve each client protocol streaming (surface the
      matrix per model on the Router page).

## Phase 3 — responses as PROVIDER + conformance suite

- [ ] 3.1 Provider adapter `openai_responses` upstream streaming
      (gun SSE, event relay into translate pipeline).
- [ ] 3.2 chat/anthropic clients → responses provider, streaming +
      non-streaming (reverse of Phase 2 state machines).
- [ ] 3.3 Conformance fixtures: capture REAL SSE transcripts per
      provider family (dashscope/volcengine/kimi), store under
      `test/fixtures/sse/`, drive eunit from them — no hand-invented
      frames (AGENTS.md fixture-realism rule).
- [ ] 3.4 Load/soak: 50 concurrent translated streams, assert no
      leftover/内存 growth in sse_st (leftover cap 1MiB holds).

## Non-goals

- Audio/realtime protocols (websocket) — separate spec if ever.
- Client-protocol multiplexing (one inbound → N upstreams) beyond
  existing janus-auto adjudication.

## Route-preference substrate (shipped 2026-10-06)

`janus_lb:pick_route/pick_listing_route` accept `#{prefer_proto => P}`:
streaming translate-blocked requests prefer same-protocol routes and
fall back to all routes (400 diagnostic preserved). E.5/E.6 gate steps.
