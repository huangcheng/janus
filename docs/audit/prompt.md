# Role
Audit the attached Janus implementation plan only. Do not write code. Do not call tools.

Janus = Erlang AI gateway (Cowboy :8080 agent API / :8090 admin; ETS catalog + generation hot-reload; janus_lb pick with prefer_proto; SSE translate state machines for chat protocols; failover loop with per-attempt usage rows (stream/request_ref/attempt/is_terminal); entitlement carrier + probes; sibling-repo E2E gate (TEST-FLOWS.md authoritative) with a deterministic mock upstream; dashboard SPA; three prod nodes). A separate, already-audited plan covers full chat-protocol translation (C1-C6 contracts, ship units with default-off knobs).

The attached plan extends Janus to full MODALITIES: image generation (sync), TTS (chunked binary out), ASR (multipart in), video generation (BOTH sync one-shot and async job modes under one canonical endpoint), computer use (beta-header passthrough over /v1/messages), as a modality PLUGIN architecture (endpoint + translator + renderer + usage unit + probe policy per modality), with usage_events gaining modality+units columns, per-modality default-off knobs, and per-route timeout overrides for long-blocking sync calls.

This is revision 8 of this plan (rounds 1-7 findings applied). Audit skeptically.

# Required output format
1. Verdict: GO / GO WITH FIXES / NO-GO — one sentence
2. Critical risks (SSE state-machine correctness, terminator/usage-event semantics under translation, request-grammar fidelity per protocol pair, fixture realism, phase ordering/dependency errors, interactions with failover + entitlement + LB, hot-path cost, backward-compat of unblocking the blocked predicate)
3. Contradictions or stale claims vs the described codebase
4. Missing first-ship requirements per phase
5. Architecture/design notes (state machine extension points, event mapping tables, error taxonomy)
6. Top 5 concrete edits (file-level or task-level)

Under 450 words. Be skeptical and specific.
