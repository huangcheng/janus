# Auto-router: prompt-only tiering

Supersedes the lexicon half of `auto-router-complexity.md` (A2), and the
rule gate it patched.

## Origin

`auto-router-complexity.md` fixed two real defects — the judge could not
see the conversation head (A1), and the cache key omitted judge-input
fields (A3) — but its third part, A2, added a **complexity lexicon**: a
settings knob listing words ("design", "架构", "并发") that, when matched,
diverted a request into the judge zone instead of the fast route.

That lexicon is the wrong instrument, for four reasons established in
review and in production:

1. **It is a keyword test answering a semantic question.** "帮我做个分布式
   锁" matches; "我们该怎么拆分这个服务" does not, though both are the same
   class of task. A list can never be complete, in any language.
2. **It shipped default-empty.** The repository's default-off discipline
   met a requirement that the feature work out of the box, and the
   compromise — an empty default plus a separately exported "recommended"
   list — satisfied neither. The capability was documented but absent, and
   the operator had to fetch the list from `/stats` and paste it by hand.
   A default-off family that does nothing when off is not a knob; it is
   dead code with a settings row.
3. **The list must be maintained forever.** Every new language, domain and
   idiom is an edit. That maintenance burden lands on whoever operates the
   gateway, who is the least equipped party to decide what "complex" means.
4. **It patched a symptom.** The lexicon existed only because the rule gate
   settled a request before the judge was consulted. Fixing the gate
   removes the reason for the lexicon entirely.

Meanwhile the production record shows what the gate actually costs. Over
24 hours: 21 `janus-auto` requests against ~2000 total. The router was
never the traffic path, so the gate's "keep the judge off the hot path"
argument was protecting a hot path that did not exist.

## Goals

- Tier selection is decided by a model reading the request, exactly once,
  for every `janus-auto` request.
- The judge's instruction is the **only** operator-editable surface for
  routing behaviour: built in by default, editable through the dashboard,
  effective without a release.
- `janus-auto` is a model that exists or does not exist, not a model that
  is advertised conditionally while remaining callable.
- An operator can see, per request, which tier was chosen and from what
  input shape (A4's carrier, unchanged).

## Non-goals

- Removing the judge. This document makes it the sole decision point.
- Guaranteeing a correct verdict. A wrong verdict remains possible; the
  goal is that the verdict is the model's, not a keyword list's.
- Re-introducing any deterministic routing signal, in any form.

## Design

### 1. One decision point

`rules_gate/2` and `rules_gate_1/2` are removed. Every `janus-auto` request
reaches the judge. The only pre-judge refusal retained is the hard
`max_ctx_tokens` oversize check, which is a **validity** check (the request
cannot be served by any tier) and not a routing decision — paying a judge
call to learn that a request exceeds every tier's context is waste, and the
answer is an error, not a tier.

Removed with the gate:

| Removed | Was |
|---|---|
| `complexity_terms` setting | keyword divert (A2) |
| `default_complexity_terms/0` | the recommended list nobody applied |
| `markers` setting | `ultrathink` forced flagship |
| rule names `marker` / `too_big` / `prompt_big` / `fast` | gate verdict labels |
| `fast_ctx_tokens` | the gate's fast threshold |

`big_ctx_tokens` and `max_ctx_tokens` stay: they remain the tier-sizing
hints the judge is told about and the validity bound respectively.

### 2. `markers` removal is a behaviour change

`markers` let a user type `ultrathink` to force flagship. It is removed
because, with the gate gone, keeping it would preserve exactly one
hard-coded path in a design whose premise is that no such path exists — and
because it is already defective:

`features/1` matches markers against `last_user` only. A user who writes
`ultrathink 帮我设计分布式锁` in turn 1 and says `继续` in turn 4 does not
match at turn 4. The same feature therefore works or not depending on which
turn the word appears in. `complexity_hit/2` was fixed for exactly this in
A1 (`first_user` orelse `last_user`); `markers` never was.

Consequences, stated for the changelog:

- `ultrathink` no longer forces flagship. The judge decides.
- Any user relying on it must instead rely on the judge, or on the
  operator adjusting the prompt.

**Removal order.** The marker counter cannot be added by the same release
that deletes the code path it counts. Removal is therefore two releases:

1. **Observe.** `markers` keeps its current behaviour; a new
   `marker_hit_total` counter records how often it fires. No routing change.
2. **Remove.** If the counter is still zero, remove `markers` in the next
   release. If it is not zero, stop and revisit — someone depends on it.

This document governs release 2. Release 1 is a one-line counter and is
included here only to define the sequence.

### 3. Operator-editable judge prompt

A new settings key `judge_prompt` (string) carries the instruction the
judge is given. Default is the built-in text; empty means "use the
built-in". It replaces the hard-coded `judge_prompt/0` return value on both
judge paths:

- the `chat` path builds its system message from it;
- the `decisions` path carries it as the `tier` question's `instructions`.

Validation, because a bad prompt makes the router silently wrong:

| Check | Refusal |
|---|---|
| length ≤ 4096 **bytes** | `prompt too long` |
| contains each configured tier label (`fast`, `big`, `flagship`) | `prompt must name every tier` |
| empty string | accepted; means built-in |

The limit counts UTF-8 **bytes**, not characters, because the value is sent
verbatim to the judge and the byte length is what the request carries. A
Chinese prompt costs ~3 bytes per character, so the effective character
budget is smaller; the dashboard shows a live byte counter beside the field
so the limit is visible before the write is refused. The bound is inclusive:
4096 bytes is accepted, 4097 refused.

The label check exists because a prompt that never names a tier invites a
verdict the parser must discard (`parse_tier` returns an unrecognised word),
which degrades to the default tier with no error. Refusing at write time
turns a silent misroute into a 400 at the dashboard.

### 4. Prompt changes invalidate the decision cache

`cache_key/2` takes `_Cfg` today — deliberately unused. It gains the prompt
hash as its first element, which means the argument becomes load-bearing and
the parameter is renamed `Cfg`. Both call sites (`judge_tier/2` and the
local-judge path) already have `Cfg` in scope.

The hash is NOT recomputed per request: `#acfg{}` is already memoised per
config generation by `normalized/0`, so the prompt is hashed once when the
record is built and the digest travels in it as a `prompt_hash` field. A
4 KB string hashed on every request would be avoidable work on the hot path.

Without this, an operator edits the prompt, requests keep hitting verdicts
cached under the old prompt for up to `cache_ttl_sec` (300 s default), and
the edit appears to do nothing — the operator edits again, still sees old
verdicts, and the feature looks broken. The invariant is: **the key is a
superset of everything that can change the verdict.** A3 established this
for the judge *input*; the prompt is judge input.

Cost: editing the prompt misses the whole cache once. That is correct and
desirable — the cached verdicts were produced by a different instruction.

### 5. `enabled` is an existence switch, not an advertisement switch

A new settings key `enabled` (boolean, **default false**) gates the whole
family. When false:

- `janus-auto` is absent from `/v1/models` (`auto_names/0` already keys on
  `routable`; `enabled` joins that condition);
- a direct request for the configured model name returns **404
  `model_not_found`**, not `pass`.

The second clause is the substantive one. Today `maybe_route/3` resolves an
unknown name to `pass`, and the proxy then treats `janus-auto` as a literal
upstream model name, producing a provider-side error. "Disabled" must mean
"does not exist", matching the fail-closed rule in `AGENTS.md`. A model
that is hidden but callable is worse than either state.

`enabled` is an **existence** switch, never a mutating one. Flipping it to
false preserves every other value — tier lists, judge model, prompt — in the
database untouched, so re-enabling restores the previous configuration
exactly. The dashboard hides those fields; it does not clear them.

The 404 is produced at one named seam so every face behaves identically:

- `maybe_route/3` gains a `{error, disabled}` return, chosen before any
  routing work when `Cfg#acfg.enabled =:= false` and the requested name is
  the configured auto model.
- `janus_http_proxy:proxy_model/7` translates `{error, disabled}` into the
  same 404 `model_not_found` envelope it already emits for an unknown model,
  so chat, responses, Anthropic and modality faces cannot diverge.

Returning `{error, disabled}` rather than `pass` is the point: `pass` would
send the literal name `janus-auto` upstream, and the client would get a
provider error instead of a 404.

### 6. Judging the task, and its size

The built-in prompt asks for one word from a fixed set, and says what each
means in terms of the *work*, not the word count:

```
You classify a coding request for an LLM gateway and reply with exactly
one word: fast, big, or flagship.

fast     — a lookup, a small edit, a question with one obvious answer.
big      — a task needing sustained reasoning or a large context, still
           bounded in scope.
flagship — a design, an architecture, a hard bug, a long multi-step plan,
           or a request where a wrong answer is expensive.

Judge the work the request asks for, not how many words it uses. A short
request can ask for a design. When the conversation shows an ongoing task,
judge that task. Reply with the word alone.
```

The input the judge sees is unchanged from A1/A3: `sys_prefix`,
`first_user`, `last_user`, `turns`, `tool_calls`, `out_budget` — text
truncated as before, counts as counts.

## Failure modes

| Failure | Handling |
|---|---|
| Judge backend off / no judge model | default tier, `no_judge` origin (unchanged) |
| Judge returns an unrecognised word | `parse_failed`, fall back to soft resolve on the default tier |
| Judge unavailable (breaker open) | default tier, `breaker` origin (unchanged) |
| Prompt missing a tier label | refused at write time (400) |
| Prompt absurdly long | refused at write time (>4096) |
| `enabled=false` but a client calls `janus-auto` | 404 `model_not_found` |
| Every tier empty while `enabled=true` | `routable=false`; not advertised, and a call falls through to 404 as today |
| Judge call cost | one flash-class call per `janus-auto` request; measured baseline 21/day |

## Observability

Unchanged from A4, with the gate labels gone:

- `janus_auto_decision` (INFO, gated by `decision_log`, default off) carries
  `decided` (`judge` / `default_tier` / `too_large` / cache and breaker
  origins) and `shape`.
- When `decision_log` is off, nothing is logged; `/stats` exposes
  `enabled` and `decision_log` so the operator can confirm both.

## Open questions

- Whether the label check (every tier named) is too strict for a prompt
  that names tiers by example rather than by word. Current answer: keep it
  strict; a prompt that does not name a tier cannot produce a parseable
  verdict, and the alternative is silent degradation.
- Whether `default_tier` is still meaningful once every request is judged.
  It remains the fallback for judge failure, so it is kept.
