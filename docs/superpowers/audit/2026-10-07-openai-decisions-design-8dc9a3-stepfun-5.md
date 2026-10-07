---
model: stepfun/step-5-preview
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: stepfun-5
---

**Verdict:** GO WITH FIXES — the design is coherent and the gating discipline (D11/D13) is right, but probe ownership/accounting, write-gate failure semantics, and an unbounded upstream response read must be settled before implementation starts.

**Critical risks**
- Write gate never defines behavior for a node in the dashboard's node list that is *unreachable* or responds without `openai_decisions`. Fail-closed bricks provider creation for any dead node; fail-open lets half the fleet serve. No fallback exists if dashboard→`:8080` is firewall-blocked on a cloud — the feature becomes unenableable.
- Probe execution owner is undefined (gateway job vs. dashboard direct call). This decides who holds the provider key, who owns the ~10 s timeout, and whether probes write `usage_events` — yet "200 probes bill" implies they must be visible somewhere.
- The non-stream forward path reads the full upstream body; `?MAX_BODY` bounds the *request* only. A misbehaving upstream can stream indefinitely.
- D16 shared preamble must take max-body as a *parameter*; inheriting the proxy's global default silently breaks D12.

**Contradictions / stale claims**
- §4.5: "Eligible face routes all disabled → `provider_disabled`" contradicts "Disabled Decisions + no other protocol → `provider_disabled` **or** `no_route` per existing empty-set rules." Pick one rule.
- §4.3 hedges remain: "`last_probe_at` (or sibling table)" and "`upstream_requests_total` / dedicated `decisions_upstream_429_total` as appropriate" — pin both now, not at plan time.

**Missing first-ship requirements**
- Response byte ceiling + error code in the forward path.
- Dashboard-side grant name matcher (wildcards) must equal the gateway's — spec is silent; divergence here is a security hole.
- §7 waves at "TF-D.1…D.13 as before"; the plan must explicitly enumerate 413/405/`Retry-After`/429-metric cases.
- Confirm `/readyz` already exists on `:8080`; if new, ensure it leaks nothing (node identity is fine, versions are not).

**Architecture/design notes**
- Deriving `protocols` from live registered cowboy routes is the correct anti-staleness choice; old beams then naturally omit it.
- D15's connect-vs-post-send split needs an explicit "bytes observed" signal at the gun wrapper level; TF-D.15 plus a size-1/chunked fixture from the D13 capture for the full-body read is the right bar.
- One-level usage nesting pinned from D13 keys is fragile if token usage splits by sub-modality; define a documented fallback (whole-object sum).

**Top 5 concrete edits**
1. Pin probe owner (reuse existing gateway probe infra), its `usage_events` behavior (marker column or explicit no-write), and a unique-constraint cooldown table.
2. Write gate: fail closed on unreachable nodes, define a stale-node TTL grace, and require a security-group preflight on each cloud before step 9; extend TF-D.16 to cover the unreachable node.
3. Add an upstream response cap (e.g., 32 MiB) → new `upstream_response_too_large` row to the §4.2 table and pipeline.
4. §4.5: one rule — name exists but disabled → `provider_disabled`; name absent after filter → `no_route`. Delete the "or".
5. Dashboard grant matcher: share or mirror the gateway matcher with fixture-driven tests both directions; audit records the dashboard session actor, not the key name.
