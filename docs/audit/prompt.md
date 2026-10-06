# Role
Audit the attached Janus implementation plan only. Do not write code. Do not call tools.

Janus = Erlang AI gateway (Cowboy :8080 agent API; ETS catalog + generation hot-reload; janus_lb pick with prefer_proto; janus_protocol_translate holds request+reply translation incl. an SSE state machine for chat<->anthropic streams, text+thinking only, eunit 123; dispatch 400s stream translate-blocked requests with no same-protocol route; failover loop with per-attempt usage rows; sibling-repo E2E gate (TEST-FLOWS.md authoritative) with a deterministic mock upstream; dashboard SPA).

The attached plan targets FULL protocol translation: any client (openai_chat / openai_responses / anthropic_messages) x any provider x stream and non-stream x tools/vision/structured output. Three phases: (1) chat<->anthropic stream tools+vision, (2) responses-client stream translation both directions incl. request grammar, (3) responses-as-provider + conformance fixtures from real SSE transcripts. It documents semantic impossibles (n>1->anthropic, cache_control, previous_response_id) and a shipped route-preference substrate.

This is revision 11 of this plan (rounds 1-10 findings applied). Audit skeptically.

# Required output format
1. Verdict: GO / GO WITH FIXES / NO-GO — one sentence
2. Critical risks (SSE state-machine correctness, terminator/usage-event semantics under translation, request-grammar fidelity per protocol pair, fixture realism, phase ordering/dependency errors, interactions with failover + entitlement + LB, hot-path cost, backward-compat of unblocking the blocked predicate)
3. Contradictions or stale claims vs the described codebase
4. Missing first-ship requirements per phase
5. Architecture/design notes (state machine extension points, event mapping tables, error taxonomy)
6. Top 5 concrete edits (file-level or task-level)

Under 450 words. Be skeptical and specific.
