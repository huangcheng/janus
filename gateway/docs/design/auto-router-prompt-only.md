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

**Correction, from review.** An earlier draft said `big_ctx_tokens` stays
"as the tier-sizing hints the judge is told about". That is false: no judge
path carries any threshold (`judge_input/1` is sys/first/user/shape/budget;
`judge_decisions_body/3` criteria are fixed strings; `do_local_judge`'s body
has no such key). The thresholds were never visible to the judge.

That exposes a real hole in "delete the gate". `too_big` and `prompt_big`
are not only routing decisions — together they are the **only** code path
guaranteeing an oversized request reaches a tier that can serve it. Remove
them and a 150k-token request is judged like any other. If the verdict is
`fast` (or if `judge_backend=off`, which is the dashboard default, so every
request takes `default_tier`), `resolve_soft` routes it to a fast model and
the provider answers with a context-overflow 4xx. The request had a correct
answer available; the router now produces an upstream error instead.

So the size signal has to survive the gate's removal, in one of two forms:

- **(a) keep a size-to-tier floor**: a request whose `est_total` exceeds
  `big_ctx_tokens` may not be routed below **`flagship`**, and one exceeding
  `max_ctx_tokens` is refused as `request_too_large`. This is not a task
  judgment, it is a capability bound — a tier is a promise about context,
  and a judge's opinion cannot widen it.

  `est_total` is `prompt_est + media_allow + tools_est + max_out`
  (`janus_auto.erl:558`), **not** `prompt_est + tools_est`. An earlier
  revision of this document narrowed it, which would have stopped refusing
  output-heavy and media-heavy requests — a regression against today's
  behaviour, since `too_big` fires on `est_total` (`:867`). The floor uses
  the same quantity the rule it replaces used.

  The floor demands **`flagship`**, not `big`, for the same reason: the rule
  it replaces is `{Est > Big, {flagship, hard}, too_big}` (`:867`) — a
  request over `big_ctx_tokens` went to *flagship*. An earlier revision
  floored to `big`, one tier weaker than the rule it claims to preserve, so
  a 61k-token request would have been floored into a tier whose window is
  the boundary it already crossed. Same quantity in, same tier out.
- **(b) feed the sizes to the judge** and let it honour them.

Chosen: **(a)**, because it is deterministic, it needs no prompt compliance,
and it keeps working when the judge is down. The gate's task-complexity
rules (`fast`, `marker`) are still deleted; only the two capacity rules
survive, renamed to say what they are.

**The floor must resolve HARD.** A floor that raises the verdict to `big`
and then goes through `resolve_soft/3` is not a floor: `resolve_soft`
silently falls back to `default_tier` when the raised tier has no member, so
`big=[]` with `default_tier=fast` yields fast anyway — the exact
provider context-overflow this section exists to prevent. The capacity floor
therefore resolves through `resolve_hard/3` (`:1577`): if the tier it
demands has no available member, the answer is `{error, no_route}`, not a
downgrade.

This is also why the floor is exempt from §1a's "everything is soft" rule,
and the exemption is principled rather than convenient: a judged verdict is
an estimate and may be downgraded, a capacity bound is a constraint and may
not.

**One deliberate difference from the rule it replaces.** Today a hard verdict
whose tier has no member usable *by this request* falls back to the default
tier when a stream/vision constraint is present (`janus_auto.erl:449-457`) —
"serving the default tier beats failing with `no_route`". The capacity floor
does **not** take that fallback: it returns `no_route`.

The asymmetry is intentional. That fallback exists because a protocol
mismatch is not the request's fault — the tier is fine, just not for this
transport. A capacity overflow is different: the default tier provably
cannot hold the request, so falling back produces a guaranteed upstream
error instead of a local, honest one. Stricter than today, and the failure
table says so.

This is the one place where "only the judge decides" is narrowed, and it is
narrowed for a reason a judge cannot be trusted with: an LLM does not know
the context window of the model it is choosing.

### 1a. What `decide/3` becomes

The gate's removal is a rewrite of `decide/3`, not a deletion, and the
shape of that rewrite is part of this design.

Today `decide/3` (`janus_auto.erl:403`) dispatches on `rules_gate/2`'s
result: `{error, request_too_large}` → the too-large arm; `judge_zone` →
the judge arm; two rule arms for hard and soft verdicts. Removing the gate
removes the two rule arms entirely. What remains:

1. **capacity refusal** first: `est_total > max_ctx_tokens` → the
   `too_large` decision. No judge call, because no tier could serve the
   request.
2. **judge** otherwise.
3. **capacity floor** applied to the verdict: if `est_total >
   big_ctx_tokens`, the effective tier is `max(Verdict, flagship)` and it is
   resolved through `resolve_hard/3`. This applies whatever the judge said —
   `fast`, `big` or `flagship` — because the floor is a constraint on the
   *request*, not a correction of the *verdict*. A `big` verdict on a 61k
   request is exactly as wrong as a `fast` one. An earlier revision hardened
   only the raise-from-`fast` case, which left a soft path: judge says
   `big`, `est_total > big_ctx`, every `big` member down → `resolve_soft`
   → default tier → the overflow the floor exists to prevent.

`est_total` in all three, never `prompt_est + tools_est` (§1, correction).

**Two invariants the rewrite must preserve**, both stated because both
have already been broken once in this file's history:

- **The 6-tuple.** `decide/3` returns
  `{Result, Origin, Tier, Target, Decided, Shape}` and the caller reads
  `element(5, …)` and `element(6, …)` unconditionally. A prior change
  returned a 4-tuple on one path; `element/2` raised `badarg`, and
  `maybe_route/3`'s catch-all swallowed it into a silent degradation to
  `pass` — the router stopped routing with one warning as its only trace
  (`janus_auto.erl:487`). Every clause must return the same arity. The
  existing `decision_tuple_arity_test/0` (`:3304`) drives `rules_gate/2`
  directly and is deleted with the gate; it must be rewritten against the
  new `decide/3` (judge, floor, too-large, disabled) rather than dropped —
  it is the regression test for the bug above.
- **No new return tuple.** An earlier revision introduced
  `{error, disabled}` as a `maybe_route/3` return. There is no such value:
  the union is `{ok, …} | pass | {error, no_route} | {error,
  request_too_large}` (`janus_auto.erl:114-118`), and `proxy_model/7`'s
  `case` has **no catch-all** (`janus_http_proxy.erl:368-436`), so an
  unlisted fifth value raises `case_clause` → 500. A disabled model
  therefore returns the existing `{error, no_route}`, which the proxy
  already maps to 404 `no_route`. No new tuple, no new proxy clause.

**Hard-tier semantics change, and this must be recorded.** The gate could
return a *hard* verdict: `resolve_hard` failing meant `no_route`, and
`SPEC.md` §3/§8 say a hard verdict whose tier is unavailable must not
downgrade. With the gate gone, every judged verdict is resolved **soft**:
`resolve_soft` silently falls back to `default_tier` when the judged tier
has no available member. So "flagship, all flagship members down" now
yields a fast model that succeeds, where it used to yield `no_route`.

That is a deliberate trade — a judged verdict is an estimate, not a
constraint, so downgrading beats failing — but it is a semantic change to
`SPEC.md` and must be listed as an amendment, not left implicit.

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

The label check is **case-insensitive**, matching `parse_tier/1`, which
lowercases the verdict before comparing. A prompt that says "Fast / Big /
Flagship" is accepted; treating the check as case-sensitive would refuse a
prompt that works perfectly.

The label check exists because a prompt that never names a tier invites a
verdict the parser must discard (`parse_tier` returns an unrecognised word),
which degrades to the default tier with no error. Refusing at write time
turns a silent misroute into a 400 at the dashboard.

### 4. Prompt changes invalidate the decision cache

`cache_key/2` takes `_Cfg` today — deliberately unused. It gains the prompt
hash as its first element, which means the argument becomes load-bearing and
the parameter is renamed `Cfg`.

**Correction, from review:** it has ONE call site, `janus_auto.erl:886`
inside `judge_tier/2`. An earlier draft said two; the local-judge path
receives `Hash` as a parameter from `judge_tier/2` and never calls
`cache_key/2` itself. So the change is local to one function.

The hash is NOT recomputed per request: `normalized/0` memoises the whole
`#acfg{}` in `persistent_term`, keyed by `phash2(Raw)`, so the digest is
computed once per config generation and travels in the record as a
`prompt_hash` field. A 4 KB string hashed on every request would be
avoidable work on the hot path.

Four sites must be updated:

1. `#acfg{}` record definition — new `judge_prompt` and `prompt_hash` fields.
2. `validate/1` — read `judge_prompt`, compute `prompt_hash`.
3. `default_cfg/0` — build both, because it is the fallback `snapshot/0`
   returns when the settings read fails and the base record `validate/1`
   starts from.
4. The eunit fixture `cfg()` (`janus_auto.erl:3129`) — a full `#acfg{}`
   literal that stops compiling once the record grows.

Missing 1–4 fails at **compile time**, which is loud. The genuinely silent
failure is different and is the one to guard: `judge_prompt` must also enter
`Raw`, because `normalized/0` memoises on `phash2(Raw)`. If the prompt is
read from the record but not from `Raw`, the fingerprint does not change
when the prompt changes, the memoised `#acfg{}` is reused, and the new
prompt never takes effect — with no error anywhere.

**Fleet consequence.** `fleet_cache_put/4` shares decisions across nodes
keyed on the hash computed by the *sending* node. If two nodes carry
different prompts their hashes differ, so shared entries simply miss —
degradation, not corruption, and acceptable given the existing assumption
that fleet config is uniform. Stated here because it is a new way for
config drift to cost cache hits.

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
- a direct request for the configured model name does not route.

**Correction, from review.** An earlier draft justified this by claiming a
disabled `janus-auto` would "produce a provider-side error". That is
false. `maybe_route/3` returns `pass`, `direct_walk/1` also returns `pass`
for the virtual name, and `pick_listing_route/1` then finds no listing —
the client already gets a local **404 `no_route`**, and the literal name
never reaches an upstream (`janus-auto` is not a bound model and no
provider lists it). So shipping `enabled` changes *when* the 404 is
decided, not *what* the client sees.

The honest justification is smaller and still worth stating: with the gate
gone every request costs a judge call, so a disabled family must not spend
one on a model that is advertised as absent. And `/v1/models` and call
behaviour should agree — today the listing is already conditional on
`routable` while calls are not conditional at all.

**One 404 code for both states.** The proxy has no `model_not_found`: it
emits **`no_route`** (404) through `reply_err` (`janus_http_proxy.erl:417`,
`:2896`). A disabled call and an unconfigured one must produce the *same*
answer, or the two states become distinguishable by error code and the
"exists or does not exist" goal is only half met. The new clause therefore
reuses `no_route`; no new error code is introduced.

**Which faces this covers.** `proxy_model/7` is reached only from
`handle_body`, i.e. the chat, responses and Anthropic messages handlers.
Modality does not go through the router at all (`janus_modality:pick_route`
→ `janus_lb:pick_listing_route`) and needs no change. The Decisions face
bypasses `maybe_route/3` deliberately and answers 400
`protocol_requires_native` for the auto name regardless of `enabled`
(`janus_http_proxy.erl:151-170`) — also unchanged. An earlier draft
claimed the seam covered "modality"; it does not, and does not need to.

`enabled` is an **existence** switch, never a mutating one. Flipping it to
false preserves every other value — tier lists, judge model, prompt — in the
database untouched, so re-enabling restores the previous configuration
exactly. The dashboard hides those fields; it does not clear them.

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

### 7. Config compatibility

Deleting settings keys is a **two-way** break, because
`$defs.auto_router` in `config-backup-v1.schema.json` is
`additionalProperties: false` with
`required: [model, judge_model, tiers, default_tier, fast_ctx_tokens,
big_ctx_tokens, max_ctx_tokens, judge_timeout_ms, cache_ttl_sec, markers]`.

| Direction | Breaks because |
|---|---|
| old backup → new gateway | backup carries `markers` / `fast_ctx_tokens`, schema no longer allows them |
| new backup → old dashboard | backup lacks required keys **and** carries unknown ones (`enabled`, `judge_prompt`) — `additionalProperties: false` rejects both, independently |

Worse, restore writes the settings row **verbatim** rather than through
`put_auto_router`, so the `judge_prompt` validation in §3 is skipped on
restore and a bad prompt can enter the database through a backup file.

Required, and part of this work rather than a follow-up:

- **new → old is closed only by the exporter or the version field.** Bumping
  `$defs.auto_router` edits the *new* schema; an old dashboard still
  validates against the old one, so the edit does not help it. Two workable
  answers, and one must be chosen:
  - the exporter keeps emitting `markers` / `fast_ctx_tokens` with their
    legacy values, so a new backup still satisfies the old schema; or
  - bump the top-level `version`, so old code refuses cleanly as
    `unsupported_version` instead of failing with a property error.
  Chosen: **bump the top-level `version`**, and the bump rides **A** — not
  C — because A is the first release whose backups an old dashboard cannot
  read (`judge_prompt` violates `additionalProperties: false` there). A bump
  scheduled for C would leave A and B emitting payloads that fail on an old
  dashboard with exactly the property error §7 sets out to avoid.

  The bump is not free: `_version_gate` (`config_backup_restore.py:341`)
  refuses any version above 1, and the schema pins `"version": {"const":
  1}`. Both must widen to accept 1 **and** 2, or the new dashboard stops
  reading its own v1 backups — which would contradict the requirement above
  that old backups still load. This is named here because "bump the version"
  reads like a one-line change and is not.
- keep the deleted keys as **optional legacy** fields in the new schema
  (accepted on restore, ignored by the gateway) so old backups still load;
- add `enabled` and `judge_prompt` as optional fields with defaults, so an
  old backup restoring into new code leaves `enabled=false` and the built-in
  prompt, never an error;
- apply the same `judge_prompt` checks on the restore path, so a backup
  cannot carry a prompt the API would refuse. The restore path writes the
  settings row verbatim, so without this a backup file is a way to bypass
  every write-time check.
- apply the `enabled=true` + `judge_backend=off` refusal on the restore path
  too (§ Failure modes). Both checks ride **B**, together with `enabled` and
  the restore-path work they belong to.

**Upgrade order, stated because both orders break something:**

- dashboard first → the SPA PUTs `enabled` and `judge_prompt` to a gateway
  that drops unknown keys; the write "succeeds" and does nothing.
- gateway first → the old SPA PUTs without the new keys; if the gateway
  required them the write would 400, so they must be optional.

Therefore: **gateway first, with both new keys optional and defaulted**,
then dashboard. The SPA must not require what an older gateway cannot
accept.

## Failure modes

| Failure | Handling |
|---|---|
| Judge backend off / no judge model | default tier, `no_judge` origin (unchanged) |
| Judge returns an unrecognised word | `parse_failed`, fall back to soft resolve on the default tier |
| Judge unavailable (breaker open) | default tier, `breaker` origin (unchanged) |
| Prompt missing a tier label | refused at write time (400) |
| Prompt absurdly long | refused at write time (>4096) |
| `enabled=false` but a client calls `janus-auto` | 404 `no_route` (same code as unconfigured) |
| Every tier empty while `enabled=true` | `routable=false`; not advertised, and a call falls through to 404 as today |
| `enabled=true` with `judge_backend=off` | **refused at write time.** Every request would silently take `default_tier`, which contradicts this design's premise; the dashboard must not accept that combination |
| `judge_max_inflight` full | silent `inflight` → `default_tier`; now on the path of every request, not the remainder |
| Judge failure recorded in `negcache` (30 s) | every identical-hash request takes `default_tier` for 30 s, invisibly unless `decision_log` is on |
| Local path: not-ready gate / `inflight_full` / `exempt` | `local_fallback` → `default_tier`; the first draft's table listed only "breaker open" |
| Oversized request judged `fast` | prevented by the capacity floor in §1, which resolves **hard** |
| Floor demands `flagship`, but every `flagship` member is unavailable | `{error, no_route}` — not a silent downgrade to fast (§1) |
| Floor tier has members, but none usable by *this request* (stream/vision constraint) | `{error, no_route}`. Deliberately **stricter** than the rule it replaces, whose hard arms fall back to the default tier under a stream constraint (`janus_auto.erl:449-457`): a protocol mismatch is not the request's fault, a capacity overflow is, and falling back would turn a local honest error into a guaranteed upstream one (§1) |
| Restore bypasses prompt validation | rejected by §7's restore-path checks |
| Judge call cost | one flash-class call per `janus-auto` request; see the latency note below |

### Cost and latency, stated honestly

The first draft used the measured 21 `janus-auto` requests/day to dismiss
the cost argument. That inference is backwards: at 21 requests/day against a
300 s cache TTL, the positive cache almost never hits, so **essentially
every** `janus-auto` request pays a judge round trip and up to
`judge_timeout_ms` (1500 ms default) of added time-to-first-byte. The gate
was not merely idle — it was the only thing keeping that latency off the
path.

What changes when the gate goes:

| | Before | After |
|---|---|---|
| Judge calls | requests the gate did not settle | every request |
| Worst-case added TTFB | on that subset | 1500 ms, on all of them |
| Judge outage blast radius | that subset | every request |
| Cache reuse | high (gate absorbed the repeats) | low (each distinct prompt+shape misses) |

These are acceptable **because the traffic is 21 requests/day**, and the
counters to watch are `breaker_opened`, `inflight_skip`, `negcache_hit` and
`default_tier_used`. If `janus-auto` ever becomes a real traffic path, the
cost model must be revisited — this document does not claim it scales.

**`judge_timeout_ms` is also the request-path stall.** It is the `after`
timeout in `judge_call/5`, so a slow judge holds the request for the full
budget before falling back. The default is 1500 ms; with the gate gone that
is the *common* case rather than the remainder. The dashboard should
recommend a low value (≈300 ms) for this setting and say why: a tier
verdict is worth a few hundred milliseconds, not one and a half seconds.

## Observability

Unchanged from A4, with the gate labels gone:

- `janus_auto_decision` (INFO, gated by `decision_log`, default off) carries
  `decided` and `shape`. The `decided` values are `judge`, `capacity_floor`
  (the floor raised a verdict — the one case where the logged tier is not
  the judge's), `too_large`, `default_tier`, and the cache/breaker origins.
  Without a distinct `capacity_floor` label a floored decision looks like a
  judge verdict and the operator cannot tell the two apart.
- When `decision_log` is off, nothing is logged; `/stats` exposes
  `enabled` and `decision_log` so the operator can confirm both.

## Delivery

Both reviewers independently concluded this is too large for one change and
proposed the same split. Accepted, with the ordering they argued for: ship
the switch and the tunable surface *before* the behavioural change, so the
change arrives already gated and already tunable.

| Release | Contents | Risk |
|---|---|---|
| **A** | `marker_hit_total` counter (no behaviour change) + `judge_prompt` setting + `prompt_hash` in `cache_key` + validation + `judge_prompt` added to the backup schema + **top-level version bump to 2** (`_version_gate` and the schema's `const` widened to accept 1 and 2) | low in *routing* risk; not low in blast radius — the bump changes what every backup file claims |
| **B** | `enabled` switch + `no_route` on disabled + `/v1/models` + `enabled` in the backup schema + SPA | medium — touches every surface, but routing is unchanged while enabled |
| **C** | Gate removal + `complexity_terms` / `markers` / `fast_ctx_tokens` removal + capacity floor + `decide/3` rewrite + legacy-optional schema keys + SPEC amendments | high — the actual behavioural change |

Two bucketing corrections from review, because the first draft put all
schema work in B:

- `judge_prompt` breaks old-schema validation the moment it is written, so
  its schema entry must ride **A**, with the key itself. Schema and key
  ship together or the first backup taken after A is unrestorable.
- The legacy-optional treatment for `markers` / `fast_ctx_tokens` can only
  be written once those keys stop being required, which happens in **C**.
  Writing it in B would describe keys the gateway still uses.
- `marker_hit_total` is a precondition of C, so it rides **A** — it must be
  collecting data *before* C is prepared, not as part of C.
- the version bump rides **A**, not C, matching §7: A is the first release
  whose backups an old dashboard cannot read, so the version must change
  when the payload becomes unreadable, not three releases later.

**This document governs C.** A and B are described here because C depends on
them and the order is part of the design, not because they ship together.

C ships only after B has run long enough to confirm `marker_hit_total`
(§2) — the counter cannot be collected by the release that deletes it.

## Amendments to earlier documents

Removing the gate contradicts claims made elsewhere. Listed so the
contradiction is recorded rather than discovered:

- `gateway/design/auto-router/SPEC.md` §4.2 (rule table) and §8 (hard-tier
  resolution): rules 1/4/5 are removed; the hard/soft distinction collapses
  to soft for every judged verdict (§1a).
- `auto-router-complexity.md`: Non-goals #1 ("replacing the rule gate") is
  now a goal; A2 (`complexity_terms`) is deleted outright; its Invariant #2
  about the gate's cost role no longer applies.
- `worker-capacity-override.md`, `ack-path-signalling.md`: unaffected.

## Open questions

- Whether the label check (every tier named) is too strict for a prompt
  that names tiers by example rather than by word. Current answer: keep it
  strict; a prompt that does not name a tier cannot produce a parseable
  verdict, and the alternative is silent degradation.
- Whether `default_tier` is still meaningful once every request is judged.
  It remains the fallback for judge failure, so it is kept.
