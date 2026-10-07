---
model: volcengine-ark/deepseek-v4-1-flash-260910
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: deepseek-v41-flash
---

**Verdict:** GO WITH FIXES — the shape is sound, but D15's failover signal is likely unimplementable as written and two "disjoint" claims are not disjoint.

**1. Critical risks**
- **D15 vs gun pooling.** "Fails before any request byte is written (gunup/connect)" is only clean on a *fresh* socket. On a pooled/reused gun connection there is no connect step; the POST is written immediately and failures arrive asynchronously, indistinguishable from post-send errors. Without a concrete error class the "falsifiable" claim is false and the shared-proxy change can silently retry after send — exactly the non-idempotent hazard.
- **Timeout contradiction.** §4.2/§4.3 set a **60 s first-byte timeout** "align[ing] AGENTS idle reality," but AGENTS.md says `idle_timeout => 300_000` precisely because *upstreams may take 60 s+ to first byte*. 60 s kills legitimate slow calls other faces allow.
- **Precedence not disjoint.** Rows 5 and 6 can both match (name has face-correct routes all disabled *and* other-protocol routes enabled). §4.5 claims disjointness; there is no tie-break.
- **Kill switch after rollback.** Rollback says disable providers, then roll back gateway; but the *old* dashboard enum "rejects new writes, existing rows display as unknown protocol read-only" — so it may be unable to flip `enabled=0`. Kill switch must remain reachable.
- **Probe billability.** Probe uses stored provider keys and burns provider quota; "no billable prod until O1" doesn't say whether probes count. Also grant-confirm on "every intersecting grant-write" needs non-interactive semantics or it breaks API-driven grant automation.

**2. Contradictions / stale claims**
- 60 s vs 300 s (above).
- `provider_probe_state` vs "listing" terminology; "lowest `provider_models.id`" names a table never otherwise referenced.
- "413 `request_too_large`" but no pinned status for `upstream_response_too_large` (502?).
- D18 rejects only `"stream": true`; behavior for `"stream":1`/`"true"`/query param unstated.

**3. Missing first-ship**
- `Allow` header on 405; `x-request-id` mint/echo/collision policy across faces.
- Chunked (no Content-Length) counting for both 10 MiB and 4 MiB caps; gzip accounting.
- Dashboard heartbeat cadence — 60 s freshness will flap if heartbeat interval ≥60 s; serialized 3 s/node readyz makes creates slow on 3 nodes.
- Readyz auth decision is accepted, but readyz endpoint ownership/migration is unlisted.

**4. Architecture notes**
- D16 unbundling: a shared auth/body/request-id preamble is the highest-blast-radius change here, yet only TF-D.20 (Responses) guards it. Add chat + Anthropic preambles regressions, or defer D16.
- Old-beam skip = silent catalog loss in mixed fleet; document the resulting `no_route` window as expected, and ensure the write gate holds it shut.

**5. Top 5 edits**
1. Define D15's pre-send signal concretely (or force fresh connections / disable failover on pooled conns).
2. Reconcile 60 s with `idle_timeout 300_000`; state per-face timeout policy.
3. Add explicit tie-break to §4.5 rows 5–7.
4. Pin statuses for `upstream_response_too_large`/`upstream_timeout`, 405 `Allow`, and chunked cap counting.
5. State probe billability under the O1 gate and prove the kill switch works post-dashboard-rollback.
