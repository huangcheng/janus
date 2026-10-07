---
model: kimi-for-coding/k3
target: 2026-10-07-openai-decisions-design-r6-target.md
slug: kimi-k3
---

**Verdict:** GO WITH FIXES — the spec is unusually rigorous (precedence, D15 falsifiability, write gate), but header-forwarding policy, upstream read deadlines, and write-gate TOCTOU gaps need pinning before D13.

## Critical risks

- **Header policy underspecified.** D17 strips `OpenAI-Organization`/`OpenAI-Project`, but nothing states the general rule: is forwarding allowlist or denylist? If denylist, client `Authorization`, `Cookie`, `X-Api-Key`, `X-Forwarded-For` could leak upstream, and the client `Authorization` must be explicitly replaced with the stored provider key (implied "same as probe" but never stated). This is the highest-severity hole.
- **Upstream read deadline missing.** Only 60 s *first-byte* is pinned. A slow-drip body hangs the handler until Cowboy's 300 s `idle_timeout`, holding a 10 MiB buffered request in memory. Pin a total deadline.
- **Write gate is point-in-time; catalog polling is continuous.** After the gate passes, (a) a node can roll back / a new old-beam node can join and still receive the Decisions row via DB poll. Fail-closed row-skip limits blast radius to `no_route`, but the spec should say so explicitly. (b) Follower `:8080/readyz` must be reachable from the dashboard host cross-WAN — rollout step 5 verifies leader only; if followers aren't reachable, every create blocks.
- **D15 vs gun connection reuse.** "Before any request byte is written" is ambiguous with pooled connections: a stale pool entry can fail *after* headers were handed to gun. Define the signal precisely (e.g., `gun:await_up` / stream-ref error before `gun:headers` ack) or TF-D.15 can't be made deterministic.
- **Memory:** full-body 10 MiB buffer × concurrent connections has no stated concurrency bound.

## Contradictions / stale claims

- **D8 (no face knob) vs AGENTS.md house rule** that new surfaces ship with default-off knobs. Kill switch is per-provider `enabled=0`, which differs operationally from one global 503 knob. Exemption needs explicit rationale.
- Error table omits `request_too_large` (413) though D12 defines it; `upstream_response_too_large`/`upstream_timeout` are listed. Make one canonical code list.
- Gates say "Merge/CI: D11" but "implementation start: D13" — nothing may merge before D13, so D11-as-CI-gate is vacuous until then; clarify D11 replays *inside* the impl PR.

## Missing first-ship requirements

- Explicit Authorization-replacement + forwarded-header allowlist.
- Total upstream deadline and abort/close semantics when response exceeds 4 MiB mid-stream (don't buffer unboundedly first).
- Rate/size guard for concurrent 10 MiB buffers.
- Write-gate re-validation story for nodes joining *after* a Decisions provider exists.

## Architecture notes

- Fail-closed eligibility split and disjoint precedence table are strong; TF-D.13/14 cover the subtle row-5-vs-6 edge (other-protocol name + disabled Decisions route) — keep both.
- Probe design (transactional cooldown, separate accounting, classifier pending O2) is sound.
- `protocols` captured at listener start is static — fine, document it.

## Top 5 concrete edits

1. Add a "Forwarded headers" subsection: allowlist, Authorization always replaced with provider key, strip list incl. D17 headers.
2. Pin total upstream deadline (e.g., 120 s) alongside the 60 s first-byte timeout; specify mid-body abort on 4 MiB cap.
3. Write gate: state the post-write TOCTOU behavior (straggler/old nodes fail closed to `no_route`) and add follower-readyz reachability verification to rollout before dashboard deploy.
4. D15: define the pre-send signal in gun terms (pool-stale failure counts as pre-send, retryable once) so TF-D.15 is deterministic.
5. Fix the error-code table (add `request_too_large`/413, 405) and add one line justifying the D8 knob exemption against the default-off house rule.
