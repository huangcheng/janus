---
model: kimi-for-coding/k3
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: kimi-k3
---

**Verdict:** GO WITH FIXES — the design is thorough, but the request-pipeline ordering contradicts itself and the write gate couples management-plane writes to follower health without failure semantics.

**Critical risks**

- **Write-gate availability coupling (§4.3):** "requires every ready gateway node" to advertise on `:8080/readyz`. Unreachable-node semantics are undefined. If a follower is down, flapping, or behind a container-network-only path (precedent: S.8 `:8090` is container-only), all Decisions provider creation blocks fleet-wide. "Ready node" is circular (readyz defines readiness) and flap-prone. Also: is `/readyz` on `:8080` unauthenticated? The agent port is auth-bearing; the exemption path is unspecified.
- **Pipeline ordering bug (§4.2 vs §4.5):** pipeline says `auth → grant check → body size → JSON parse → stream guard`. Grant check needs the model name from the parsed body — it cannot precede JSON parse. D5′ requires grant deny *before* stream errors, but stream/Accept can only be fully evaluated post-parse too (the `stream` field is in-body). Order as written is unimplementable.
- **D12 vs D16 tension:** face-local `?MAX_BODY = 10 MiB` (the `?` reads like an unresolved macro, not a literal define) must plumb through the D16 shared preamble — unless the shared helper takes a per-face limit parameter, D16 extraction will silently regress the limit to whatever chat/responses use today. Current global limit is never stated.
- **D15 ambiguity:** gun's failure reasons don't cleanly separate "TCP/TLS connect failed" from "send failed after 0 bytes acked" under TLS early-data/ALPN edge cases; "request bytes start" needs a precise definition (first `gun:data` ack? headers sent?) or the regression TF can't assert it.
- **Probe budget storage unspecified:** per-day budget (20/day) and cooldown live in DB, but no table named, no TZ for "day", no transactional claim across concurrent probe clicks. 200-probes bill real money; the bill-surfacing UI is one clause.

**Contradictions / stale claims**

- D5′ "Unknown name → no_route" sits after stream guard, but unknown-name determination needs the parsed body — same ordering bug.
- `janus_usage_missing` alert "ships same deploy" — no owner, no alert rule location (which repo, which scrape config).

**Missing first-ship requirements**

- No per-face rate limit / cost ceiling for agent callers; Decisions calls with 10 MiB inline images are the most expensive payload class on the gateway.
- Upload-side timeout: existing gun timeouts were tuned for chat-size bodies; no statement on 10 MiB upload budget.
- O1 deadline "with D13 capture" but nothing re-verifies eunit fixtures against the live capture once it lands.

**Architecture notes**

- readyz-from-registered-routes is the right instinct; heartbeat-into-Postgres (nodes self-report protocol set, dashboard reads DB) would decouple the gate from cross-cloud reachability entirely.
- Per-route auto exclusion (D5′/D7) is clean and preserves dual-face chat routing.

**Top 5 concrete edits**

1. Fix pipeline to `auth → size → parse → grant → stream guard → eligibility → pick`; re-order the D5′ table to match.
2. Replace dashboard→`:8080` fan-out with node heartbeats in Postgres (or define unreachable = block with explicit operator override + timeout ≤2 s).
3. State the current global body limit; make D16's shared helper take a per-face max-body parameter.
4. Define D15's connect-fail boundary precisely (TLS handshake complete = post-connect) and name the gun error terms matched.
5. Specify probe budget table, day-boundary TZ, and who ships the usage-missing alert rule + allowlist entries.
