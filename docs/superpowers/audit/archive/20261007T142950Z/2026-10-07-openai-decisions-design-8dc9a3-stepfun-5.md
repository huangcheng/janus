---
model: stepfun/step-5-preview
target: 2026-10-07-openai-decisions-design-8dc9a3-target.md
slug: stepfun-5
---

**Verdict:** GO WITH FIXES — the spec is thorough, but D15 connect-fail detection, readyz precision, and a hard D13 abort gate must be nailed before code.

**Critical risks**

- **D15 mechanism absent:** no signal is named to split TCP/TLS-connect failure from post-send failure. In Erlang/gun this requires knowing whether request bytes were flushed; if the proxy lacks that flag, the assumption breaks. This is the riskiest unproven link.
- **D13 file missing:** probe classifiers and nested-usage parsing are designed around a capture that is not on disk. If real usage nesting exceeds one level or the answer envelope differs, post-GO redesign is likely.
- **Readyz “handler module presence” is too weak:** a node with the module loaded but catalog/DB not ready would falsely advertise `openai_decisions`, defeating the write gate.
- **10 MiB body cap:** base64 inline images carry ~33% overhead; multi-image requests may 413 in real use.

**Contradictions / stale claims**

- §4.5 says a chat client naming a Decisions-only listing emits `protocol_requires_native`, but does not state whether the chat face’s existing `wrong_modality` mapping is also rewritten. Cross-face contract change underspecified.
- “Local-green = D11 replay” with D13 absent means local e2e proves synthetic behavior only; production correctness waits for step 10 manual TF — say this plainly.
- Probe table choice (“`last_probe_at` (or sibling table)”) is stale indecision; pin it.

**Missing first-ship requirements**

- No TF asserting chat/Responses failover is unchanged after the D15 proxy edit.
- Readyz unreachable/flapping node behavior in the write gate is undefined (block vs skip).
- No per-request listing cooldown: a connect-fail repick can retry the same broken listing repeatedly, wasting client latency.
- Probe outcome strings must be a closed enum to avoid metric cardinality leaks.

**Architecture / design notes**

- `{base}/decisions` path-join must handle bases with and without a trailing `/v1`; assert no double slash.
- Grant confirmation on “every listing-add” risks dialog fatigue if operators bulk-add; batch per save.

**Top 5 concrete edits**

1. Add a D13 abort gate: if live capture shows usage nesting >1, envelope mismatch, or missing `answers` schema, stop and re-design.
2. Specify the D15 connect-vs-post-send signal explicitly (e.g., gun flush/state flag) and add TF-D.20 proving chat failover is unchanged.
3. Readyz must require route registered **and** DB/catalog ready; write-gate treats unreachable nodes as blocking.
4. Pin probe storage to a sibling table `decisions_probes` with an outcome enum; cooldown/budget query off it.
5. Batch grant confirmations per save; raise `MAX_BODY` to 25 MiB or document exact image pixel limits.
