# Auto-router: judging task complexity, not message size

## Origin

The auto-router decides a tier in two stages: a deterministic rule gate over
request *shape* (estimated tokens, message count, tool presence, marker
words), then — only for the requests the gate does not settle — an LLM
judge that reads the request's text.

Measured live, the second stage rarely gets to matter, and when it does it
is looking at the wrong thing:

| Request | Routed to | Expected |
|---|---|---|
| "帮我设计一个支持多副本一致性的分布式锁方案" | `deepseek-v4.1-flash` (fast) | flagship |
| "python 的 len 函数怎么用" | `deepseek-v4.1-flash` (fast) | fast |
| "ultrathink 帮我设计分布式锁" | `qwen3.8-max` (flagship) | flagship |
| messages `[hi, hello, ok, yes, continue]` | `deepseek-v4-1-flash` (fast) | big or flagship |
| "查一下天气" + one tool | `deepseek-v4.1-flash` (fast) | fast |

Two distinct failures produce that table.

**Failure A — the gate settles before the judge is asked.** A request with
`est_total < fast_ctx_tokens`, no tools and `msg_count =< 3` takes the fast
tier unconditionally. A one-sentence request for a distributed-lock design
is exactly that shape. The judge never sees it, so no amount of judge
improvement would change its verdict.

**Failure B — the judge reads only the last thing said.** `judge_input/1`
builds the prompt from `sys_prefix` (256 bytes) plus `last_user` (1200
bytes). In an agent loop the last user message is frequently `continue`,
`ok`, or a tool result, while the task statement sits many turns back. The
judge answers honestly about the fragment it was shown.

Both failures are structural: the system has no signal for *task*
complexity, only for *text* size and *last utterance*.

## Goals

- A request whose text states a complex task reaches a tier that can serve
  it, regardless of how few tokens it uses.
- A request deep in an agent conversation is judged on the conversation's
  shape, not only on its final fragment.
- Cost rises where complexity is real, and only there.
- An operator can see what the judge saw and why it decided, for any
  request.

## Non-goals

- Replacing the rule gate. Its cheap deterministic decisions (oversize,
  explicit marker) stay. Note that multimodal is NOT one of them any more:
  the code stopped hard-pinning images to flagship and lets the vision
  capability flag filter members inside whichever tier the size rules pick.
  `SPEC.md` §4.2 rule 1 still lists multimodal as a hard pin and is stale
  against the code.
- Making every request pass through the judge. The cost argument in
  `SPEC.md` stands: the gate exists to keep the judge off the hot path for
  obvious cases. This document narrows *which* cases are obvious.
- Guaranteeing correctness. The judge is an LLM; a wrong verdict remains
  possible. The goal is to give it the information it would need.
- Automatic tuning of thresholds from observed traffic.

## This document amends SPEC.md

`gateway/design/auto-router/SPEC.md` is the authoritative design record and
currently states, in §4.2's "已知设计取舍", that rule-5 requests
*deliberately* never reach the judge and that the operator lever is
`fast_ctx_tokens`. That trade-off was made on the assumption that a token
threshold tracks task difficulty. The live measurements in Origin are the
counter-evidence: a 20-token request for a distributed-lock design and a
20-token request for `len()` are indistinguishable by length, so
`fast_ctx_tokens` cannot separate them however it is tuned.

This document therefore amends SPEC.md §4.1 (features gain the lexicon
signal **and the `first_user` / tool-call-count fields A1 needs**, neither
of which `features/1` extracts today), §4.2 (rule 5's rationale and the lexicon's precedence), §5 (cache
key composition), §6.1 (judge input), and §10 (the judge now receives a
second user message — a privacy-surface change that must be stated there).
Those sections are updated in the same commit as the implementation.

## Design

### A1. Judge the head of the conversation as well as the tail

**All three judge body builders** must change, not just the chat one. The
codebase has three, and each currently carries the same two tail-only
fields:

| Builder | Backend |
|---|---|
| `judge_input/1` | chat (`/v1/chat/completions` face) |
| `judge_decisions_body/3` | online **decisions** |
| the body built inside `do_local_judge` | local judge sidecar (`/v1/decide`) |

A1 as first drafted named only the first, which would have left the
decisions and local paths exactly as broken as Failure B. Each gains
the earliest user message alongside the latest:

```
system: "<sys_prefix>"
first_user: "<first user message, capped>"
last_user: "<last user message, capped>"
turns: <msg_count>
tool_calls: <count of assistant messages carrying tool calls>
out: <budget line>
```

The first user message is where an agent session states its goal; the last
is where it says what to do next. Judging a `continue` without the goal is
judging a pronoun.

Each field stays capped so the judge request cannot be ballooned by a
hostile client: the existing 1200-byte cap applies to each message, and the
turn/tool counts are integers.

### A2. Let the gate stop pre-empting the judge

Rule 5 currently routes `est_total < fast_ctx_tokens andalso msg_count =<
3 andalso not has_tools` straight to fast. That is the rule that swallowed
the distributed-lock request.

The change is a **complexity lexicon that routes the request into the
judge zone** rather than to fast. A short request that *names* a hard task
("design", "architecture", "trade-off", "why does", "refactor",
"concurrency", and their CJK equivalents "架构", "设计", "方案", "权衡",
"并发") is sent to the judge, which decides. It is not an automatic
flagship — a lexicon matches words, and "设计一个 hello world" is trivial,
so the lexicon is a filter into the judge, never a verdict.

**The `msg_count =< 3` ceiling in rule 5 is deliberately KEPT.** An earlier
draft of this document proposed dropping it. That was wrong twice over. A
one-line request has `msg_count = 1`, so the ceiling is not what excludes
it — the `est_total < fast_ctx` term and the absence of tools are. And
dropping the condition would make `IsFast` *easier* to satisfy, so more
requests would settle at the gate and the judge zone would **narrow**, not
widen: the opposite of this document's goal.

Precedence and scope, stated because both are easy to get wrong:

- The lexicon is evaluated in `rules_gate_1/2` **before** the `IsFast`
  term, so a lexicon hit prevents the fast route rather than competing
  with it.
- It scans **both the first and the last user message**, because the
  `continue` case states its complexity at the head, not the tail.
- Matching reuses `marker_hit/2`'s rules (lowercased; word-boundary for
  ASCII terms, substring for CJK) so the two tables behave identically.

The lexicon is a settings knob `complexity_terms` whose **default is
empty**, following the repository's default-off discipline for new
capability families: an upgrade must not silently widen the judge zone and
its spend. The list above is the documented recommended value, which an
operator copies into the setting to opt in.

### A3. Cache decisions on conversation shape, not just text

`cache_key/2` currently hashes `{sys_prefix, last_user, tools_fp, has_mm,
prompt_est div 4096, max_out div 4096}`.

`prompt_est div 4096` puts every request between 0 and 4095 estimated
tokens into the same bucket. Two conversations of wildly different extent
therefore share one cached decision, and a `continue` judged in a trivial
session primes the cache for a `continue` in a deep one for the whole TTL.

The key must gain **every field the decision now depends on**, not just a
turn bucket. A1 makes the verdict depend on `first_user` and the tool-call
count; a key that adds only `msg_count` would be actively worse than
today, because two sessions with the same `last_user` (`continue`), the
same system prefix, the same tool fingerprint and the same turn bucket
would share a verdict computed on a *different task*. Today the judge at
least saw identical input for both; after A1 it would not.

So the key gains:

- a fingerprint of `first_user`,
- `msg_count` bucketed (e.g. `msg_count div 8`),
- the tool-call count, bucketed,
- **`out_budget` — the derived budget LINE — replacing the
  `max_out div 4096` component.**

That last item fixes a defect that exists today, independently of this
document. The judge body already carries the output-budget line, whose
boundaries are `MaxOut = 2048` and `8192`; the key buckets `max_out div
4096`. The two do not line up: `max_out = 1000` and `max_out = 3000` share
a key bucket while producing *different* judge inputs, so the current cache
can already reuse a verdict computed from a different budget line. Keying
on the derived line makes the key and the body agree by construction.

The governing rule is stated as an invariant, not a list: **the cache key
is a superset of every field the judge input carries.** When A1 adds a
field to the judge body, it adds a component to the key in the same
change.

A deployment consequence the operator will see: this invalidates the whole
existing decision cache once. One TTL of cold cache on deploy.

### A4. Observability: what the judge saw

Today the counters record *that* a judgment happened
(`judge_ok`, `judge_fail`, `poscache_hit`, …) but not what it decided or
from what input. A tier decision that surprises an operator is
undiagnosable without replaying the request.

The judge path records, in the request-scoped state the proxy already
carries:

- the tier chosen and the zone that chose it (gate rule number, or judge),
- for a judge verdict: the capped `first_user`/`last_user` lengths, the
  turn count and the tool-call count — the *shape* of the input, never its
  text,
- for a gate verdict: which rule fired.

The carrier is the per-request usage row the proxy already writes
(`janus_usage`), which gains fields rather than a new endpoint: the zone
and rule that chose the tier, and for a judge verdict the input shape
(lengths, turn count, tool-call count). The debug line at
`janus_auto.erl` already logs `reason/tier/target/est_total`; extending it
with the deciding rule keeps the log and the row consistent.

Text is never recorded — lengths and counts only, matching the shape
sentinel's structure-only discipline.

## Invariants

1. A request that reaches the judge is judged on a conversation-aware
   input, never on the last fragment alone.
2. The rule gate's deterministic verdicts (oversize → flagship, marker →
   flagship, explicit max-context reject) are unchanged.
3. Judge off, judge failure, breaker open, or semaphore full all still
   fall back to `default_tier` — availability never depends on the judge.
4. **The cache key is a superset of every field the judge input carries.**
   A decision is never reused for a request whose judge input would have
   differed — including the head-of-conversation message and the tool-call
   count, not merely the turn count.
5. Nothing in the judge input is unbounded: every text field is capped and
   every count is an integer.

## Failure modes to guard

| Failure | Behaviour |
|---|---|
| Lexicon word appears in a trivial request ("设计一个 hello world") | Judge is consulted and may still answer fast; the lexicon only widens the judge zone |
| Judge timeout / breaker open after A2 widens the zone | `default_tier`, unchanged; the widened zone makes this path hotter, which the operator must know |
| Cache-key change invalidates the whole existing cache on deploy | One TTL of cold cache; acceptable, and stated so nobody reads the metrics dip as a regression |
| A conversation grows past a `msg_count` bucket boundary mid-session | The next request re-judges; that is the intended behaviour, not a miss |
| Hostile client sends 100 turns of one word to reach a higher bucket | Every field is capped and the verdict is still the judge's; the cost is one extra judge call |
| First user message is enormous | Capped at the same 1200 bytes as the last; the cap is the defence |
| `judge_backend = off` in a deployment that enables the lexicon | Lexicon-gated requests land on `default_tier`. Documented; an operator choosing the judge off accepts it |
| `judge_backend = local` and the sidecar is not ready | `default_tier`, as today; the lexicon does not change the readiness gate |
| The task is stated mid-conversation, not in the first or last message | Not covered. A1 sees head and tail only; a task restated at turn 3 of 9 is missed. Accepted for now — a wider window costs more judge tokens per call |
| The decision-cache key and the judge body drift apart later | Prevented by the invariant, not by a test. A future field added to the body without the key is a review failure, and the invariant names it as one |

## Cost

The honest summary, since this is the whole point of the change:

- Today almost every request routes to fast, so the judge is lightly used.
- After A1+A2 more requests reach the judge, and some will be routed above
  fast. Both effects increase spend.
- A3 does not increase judge calls; it stops *wrong* answers from being
  reused.
- The operator's lever is unchanged: `fast_ctx_tokens` narrows or widens
  the gate, `judge_backend = off` removes the judge, `default_tier` sets
  where unresolved requests land. A2 adds `complexity_terms` as a third
  lever.

## Open questions

- Should the lexicon be a hard signal (direct to flagship, like a marker)
  or the soft one described here (into the judge zone)? The soft form is
  specified because a lexicon matches words, and "设计" appears in trivial
  requests too.
- Should the judge see *several* prior user turns, not just the first and
  last? Two is the cheap, symmetric choice; a window is more context at
  more cost.
- Does A2 belong behind a settings knob of its own, so an operator can
  widen the judge zone without editing the token thresholds? The spec
  leaves `complexity_terms` empty-able, which achieves the same thing.