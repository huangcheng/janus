# Role
Audit the attached Janus next-phase design spec only. Do not write
code. Do not call tools.

Janus is an Erlang/OTP LLM gateway (Cowboy data plane, ETS catalog,
in-process LB, OpenAI Chat/Responses + Anthropic Messages faces,
cross-protocol translate, janus-auto router) with a sibling Python
FastAPI + React dashboard writing shared Postgres. This spec proposes
Phase 1: streaming Chat↔Messages translate, /stats request counters, a
prebuilt Alpine test image (Aliyun apk mirror), and deploy
generation/token waits; Phase 2 quotas/LB explain/auto-route headers
are deferred.

# Required output format
1. Verdict: GO / GO WITH FIXES / NO-GO — one sentence
2. Critical risks (SSE translate contracts, mid-stream errors, Cowboy
   idle/disconnect, counter definitions vs dashboard SPEC, Docker/_build
   ABI, deploy generation wait, protocol compatibility)
3. Contradictions or stale claims
4. Missing requirements (error contracts, event mapping tables, counter
   semantics, image mount/ABI, E2E fixtures)
5. Architecture/design notes (handler process state, drain callbacks,
   atomics, catalog/LB invariants, dual-repo TEST-FLOWS)
6. Top 5 concrete edits

Under 450 words. Be skeptical and specific.

Verdict **GO** unless two sentences in the attached spec **contradict
each other** and §10 does not already pick a winner. Do not restate
§10. GO WITH FIXES requires quoting the contradictory sentences.
Typos, wish-list keepalives, entitlement-matrix/key-failover ideas,
and Phase 2 items are not remaining fixes. This document is **not**
an entitlement-matrix spec.
