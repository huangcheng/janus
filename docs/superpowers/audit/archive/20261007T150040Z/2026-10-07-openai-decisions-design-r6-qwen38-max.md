---
model: alibaba/qwen3.8-max
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: qwen38-max
---

1. **Verdict:** GO WITH FIXES — close the buffering/memory, probe-ownership, and old-beam crash gaps before implementation starts.

2. Critical risks
- D12 buffers full 10 MiB bodies before connect with no concurrency cap: N×10 MiB heap is an OOM vector. Add an in-flight buffered-body cap and define the reject behavior.
- The 4 MiB upstream cap is unenforceable as written: if upstream→client is streamed and the cap trips mid-body, the client gets a truncated response with no envelope. Either buffer the upstream response or spell out abort semantics (what the client sees when `upstream_response_too_large` fires after bytes flowed).
- Old beams: the spec *assumes* `normalize_protocol` has a catch-all. If current code matches exhaustively, one Decisions row crashes the whole catalog build node-wide, not row-skip. Verify on the deployed beam before migration; TF-D.12 against new code proves nothing.
- D15 "before any request byte is written" is racy on reused gun connections (peer closes after headers, before body). Pin the exact observable signal.
- Break-glass write-gate override names "role + reason" but the role is unpinned (auth UX).

3. Contradictions / stale claims
- Probe owner is the dashboard calling upstream directly (§4.3), yet §5 lists `decisions_probe_total` among gateway metrics — the gateway never sees that traffic.
- Precedence rows 2 and 4 aren't disjoint: an unknown model has no grant, so grant-deny fires before `no_route` ever can. D5′ disjointness claim fails for the most common case.
- D9 changes a client-visible error contract on existing faces (`wrong_modality` → `protocol_requires_native`); only AGENTS.md/TFs are patched — external consumers keyed on the old message are unaddressed.

4. Missing first-ship requirements
- Body with no `model` field: grant check (pipeline step 4) is undefined; define the error.
- Does `GET :8080/readyz` already exist? AGENTS.md documents only :8090 admin routes; if new, it's a missing work item.
- Write gate presumes dashboard→:8080 reachability in every deployment; container-network-only setups block forever. Needs an ops prerequisite check and a distinct failure message.
- 60 s first-byte timeout equals the documented worst case ("60s+") — guaranteed flakes; make it configurable.
- D17 strips Org/Project but never states whether gateway injects provider-configured org; if the key requires it, every call 401s.
- TF-D.* registration in TEST-FLOWS.md is not called out.

5. Architecture/design notes
- Dashboard-side probes bypass the gateway, so live probes never exercise the forward path (header strip, model rewrite); only replay TF-D.1 covers the data plane. State that divergence explicitly.

6. Top 5 concrete edits
1. Add in-flight buffered-body cap + exhaustion behavior to D12.
2. Specify upstream-response buffering/abort at the 4 MiB cap and the client-visible outcome.
3. Fix precedence: define grant-deny vs `no_route` order for unknown models; make D5′ actually disjoint.
4. Verify the `normalize_protocol` catch-all on currently deployed beams before migration ships.
5. Re-home probe metrics (dashboard vs gateway) and pin break-glass role, missing-`model` error, and org-injection policy.
