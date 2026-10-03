# Review v2.4 by step-5-preview (step-5-preview)

_51.7s · completion_tokens=4000_

Let me carefully review this v2.4 spec as a senior distributed systems/LLM infrastructure engineer. This is the sixth round of review. The user claims that previous critical defects (positive/negative cache key separation, max_out in key and judge input, total window semantics annotation, and all historical issues) have been fixed in v2.4. I need to strictly review:
A. Remaining defects or problems newly introduced in v2.1 (wait, they said v2.4 but mention v2.1? Actually they mean v2.4)
B. Missed edge cases
C. Specific executable improvement suggestions

The standard: only issues affecting correctness, security, availability, cost count as defects. Style preferences, wording, hypothetical extreme scenarios (won't happen in reality or negligible impact) don't count.

If there are no substantive issues, output PASS and briefly explain.

Max 5 items per section, in Chinese.

Let me analyze the document carefully.

First, let me understand the architecture:
- `janus-auto` virtual model routes to fast/big/flagship tiers
- Rules-based gate and judge-based classification
- Decision caching with positive/negative separation
- Circuit breaking, semaphore, etc.

Let me look for potential issues.

**Issue 1: Cache key vs. actual routing decision consistency**

The cache key includes `{SysPrefix, LastUserPrefix, ToolsFp, HasMM, prompt_est_bucket, max_out_bucket}`.
But the routing decision also depends on `msg_count` (for rule 4), `marker_hit`, `has_tools`, etc.

Wait, rule 5 is "其余 -> judge区". So the cache is only for judge decisions. Rule 4 has `msg_count ≤ 3` condition. But the judge doesn't know `msg_count` - actually judge input doesn't include `msg_count`. And cache key doesn't include `msg_count`. So two requests with different `msg_count` could have same cache key and share the same judge decision. Is this a problem? Actually the spec says "缓存 key 是 judge 输入的子集摘要：不同输入可能共享结论（近似复用），这是设计选择而非缺陷——judge 本身也只看同样截断的前缀". So this is acknowledged and claimed as acceptable.

But wait: rule 4 is checked BEFORE judge. Only requests that fall into rule 5 (judge zone) can have cache entries. Rule 4 doesn't go to judge. So for cache, msg_count isn't relevant because if rule 4 applied, it wouldn't go to judge. But what if msg_count affects whether rule 4 applies? Two requests with same cache key but different msg_count: one might hit rule 4, the other rule 5. The one hitting rule 4 wouldn't read/write judge cache. The one hitting rule 5 would. But if the one hitting rule 5 reads a cache entry written by... actually rule 4 requests don't write cache. So no conflict.

But there's a subtle issue: `has_tools` affects rule 4. Rule 4: `not has_tools` AND `est_total < fast_ctx_tokens` AND `msg_count ≤ 3` → fast. Otherwise → judge. So `has_tools` affects whether we go to judge. But cache key includes `ToolsFp` which is the full fingerprint of tools. Two requests could have same `ToolsFp` (same tools) but different `has_tools`? No, if `ToolsFp` is derived from non-empty tools, then same `ToolsFp` means same tools, so `has_tools` is same. But `ToolsFp` could be empty/hash of empty? The spec says `ToolsFp` is "JSON 编码 tools 的 phash2/1（全量指纹，非计数）". If tools is empty/undefined, they might both have same hash. So `has_tools` is implicitly in key via ToolsFp. OK.

Actually wait, `prompt_est_bucket` is `prompt_est div 4096`. Rule 4 checks `est_total < fast_ctx_tokens` which includes `prompt_est + media_allowance + tools_est + max_out`. Different requests with same `prompt_est_bucket` and `max_out_bucket` could have different actual `prompt_est` (within 4096 range) and thus different `est_total`. But again, rule 4 is separate from judge cache.

Hmm, but rule 3: `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` → big. This is a hard rule. And rule 3b: `est_total > big_ctx_tokens` → flagship. These are hard rules that don't consult cache.

The judge cache is written only for rule 5 zone requests. So cache reads should only happen for rule 5 zone. But is the cache key guaranteed to distinguish between requests that hit different rules? No, but cache is only consulted for rule 5. So it's fine.

Wait, is there a hard/soft issue with cache? "规则结论永不读写缓存" - that's stated. So rules never read/write cache. Good.

**Issue 2: Positive cache entry doesn't include rule metadata - but should it?**

Actually the judge result `Tier` is cached. When read from cache, the spec says "决策缓存命中（300s）→ tier（soft）". So cache hit gives a soft tier. Fine.

**Issue 3: Negative cache key uses same features but different namespace `{neg, Hash}`.**

"读取顺序：先查正条目，命中且未过期即用；仅当无有效正条目时才查负条目"

Wait, this means if there's an expired positive entry, we then check negative. But what happens if there's a valid positive AND a valid negative? We check positive first, use it. If positive is expired, we check negative. The negative might be older (30s TTL) but still valid. So we use negative. Fine.

But what if positive is valid but negative was written later? Since positive is only written after successful judge, and negative after failure. If positive is valid, it means judge succeeded at some point. Negative can't overwrite positive because different key space. But could negative be written after positive, meaning judge later failed? Yes. But then positive would expire at its own time (300s), and negative (30s) would expire earlier. So negative written later but shorter TTL. If judge failed recently (after positive was written), we'd have positive (valid, newer than negative? no, positive is older). Actually: t=0 positive written (TTL 300). t=100 judge fails for same-ish key, negative written (TTL 30). At t=150: positive still valid (300 > 150), negative valid (30 > 50? 150-100=50 > 30, negative expired). So positive wins. At t=110: positive valid, negative valid (10 < 30). Reading positive first → use positive. Correct: we prefer the successful decision over the transient failure. This matches "judge 成功后写正条目即自然遮蔽负条目".

**Issue 4: The judge worker snapshot mechanism.**

"judge worker 启动时对 `judge_model` 做快照，其结果回写（负缓存/连败计数）携带该快照的 model 名；若与当前配置不一致，回写直接丢弃"

This is good. But what about the cache write? "命中缓存写回" in the success path. Does the cache write also include the judge model name? Value is `{Tier, JudgeModel, ExpiresAt}`. Does the worker pass the snapshot judge model to the cache? It should, to be consistent. The spec says "结果回写（负缓存/连败计数）携带该快照的 model 名" but doesn't explicitly mention the positive cache write. But value includes JudgeModel, so likely it does. But let me check: The judge worker returns `{Ref, Tier}`. The caller (HTTTP handler) then writes to cache? "命中缓存写回" is listed in the handler's success path. Wait, the handler receives `{Ref, Tier}` and then "命中缓存写回". But the handler doesn't know the judge model snapshot. Unless the worker's reply includes it. Actually the spec says worker sends `{Ref, Tier}`. Then handler writes cache with what JudgeModel? The current configured one? If config changed between worker spawn and reply, then the handler would write with the new judge model name, but the actual decision was made by the old judge. That's a bug.

Wait, the spec says: "judge worker 启动时对 `judge_model` 做快照，其结果回写（负缓存/连败计数）携带该快照的 model 名；若与当前配置不一致，回写直接丢弃". This mentions negative cache and circuit breaker counters, but does NOT mention the positive decision cache. If the worker's success reply goes back to the handler, and the handler writes the positive cache entry, the handler might use the *current* judge_model config (if it doesn't snapshot). Or the handler might not even be the one who decides judge_model.

Actually looking more carefully at §6.2:
```
Caller(HTTTP handler)              Judge worker (spawn_monitor)
  Ref = make_ref()                   gun:open(一次性连接, owner=本进程)
  {Pid, MonRef} = spawn_monitor(     chat_completions(...)
    fun() -> ... {Ref, Tier} end)      ← 唯一 Ref 标记回复
  receive
    {Ref, Tier} ->
        erlang:demonitor(MonRef, [flush]),   %% 清掉可能已排队的 DOWN
        命中缓存写回;
    {'DOWN', MonRef, process, _, _} ->
        失败路径（负缓存 + 计连败）
  after judge_timeout_ms ->
        ...
```

The "命中缓存写回" is done by the caller after receiving `{Ref, Tier}`. But the caller doesn't know the snapshot judge model. However, §5 says "Value：{Tier, JudgeModel, ExpiresAt}...读取时 JudgeModel 与当前配置不符即视为 miss". So the cache needs JudgeModel. The caller must write the judge model. If the caller reads "current config" when writing, and the worker used a snapshot, there's a race: worker used old judge, caller writes cache with new judge name. This corrupts the cache (labels old judge's decision with new judge's name).

Also the spec says in §6.2: "其结果回写（负缓存/连败计数）携带该快照的 model 名". This specifically says negative cache and circuit breaker counters carry the snapshot. It doesn't say positive cache carries the snapshot. This is an inconsistency/bug.

Actually, maybe "命中缓存写回" happens inside the worker? No, the comment says caller does it. The worker just sends `{Ref, Tier}`. So the positive cache write lacks the snapshot protection. This is a real bug: **positive cache write doesn't carry the judge model snapshot, unlike negative cache writes and circuit breaker updates.** If judge_model changes while a judge call is in flight, the old judge's decision could be cached under the new judge_model name, causing "ghost hit" garbage in the new judge's fresh cache window. Or conversely, it could be tagged with the old model and immediately miss (less harmful but still wrong).

Wait, if the caller reads current config at reply time and writes cache with current judge_model, then if config changed from A to B while worker (using A) was in flight, the decision from A gets cached with B. Then reads with B cache-hit and think B decided it. This is a correctness issue for cache attribution.

So Issue A1: Positive cache write race condition - success path writes cache with current judge_model config read from caller side, but decision was made with worker's snapshot. Since the spec explicitly protects negative cache and circuit breaker with snapshot model name, but NOT positive cache, this is an inconsistent gap.

Improvement: The worker should return `{Ref, Tier, JudgeModelSnapshot}` and the caller should use that snapshot for cache write; or the worker should write the cache itself.

**Issue 5: The cache read/write for decision cache is done by the handler, but §5 says "读取时 JudgeModel 与当前配置不符即视为 miss".**

When reading cache, if JudgeModel != current, treat as miss. But the cache is consulted before calling judge. If there's a judge in flight changing config, a race exists. But that's acceptable transient.

**Issue 6: est_total and rule 4 "定向 hard / 可用性 soft"**

Rule 4: `not has_tools` 且 `est_total < fast_ctx_tokens` 且 `msg_count ≤ 3` → fast, with "定向 hard / 可用性 soft".

The spec says: "fast 档不可用时按 soft 语义降级 default_tier（成本偏好不是可用性硬约束）".

But what if `default_tier` is also unavailable? Spec says "仍败则 no_route". Fine.

But there's a subtle issue: Rule 4 is described as "定向 hard / 可用性 soft". In the hard/soft distinction: "规则门结论...其目标档不可用时不允许降级到 default_tier——直接 no_route；判分区结论是软估计，允许降级。" Then rule 4 is an exception. In §8 table: "规则 4 fast 档不可用 | 按 soft 语义降级 default_tier → 仍败则 no_route". This is consistent.

But is there a problem with rule 4's total window assumption? It says "总窗口比较基于 prompt+output 共享窗口的通用假设（主流模型如此）；输出上限独立的部署者可上调 fast_ctx_tokens". This is a semantic note, not a defect.

However, consider a provider where output tokens are counted separately from input (e.g. some models have separate quotas). The spec mentions this as a known assumption with deployment note. Not a defect per instructions.

**Issue 7: Rule 3 uses `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` and rule 3b uses `est_total > big_ctx_tokens`.**

Rule 3b protects against max_out overflowing big window. But what if `max_out` is huge (e.g., 100k) and big_ctx_tokens is 60k, fast_ctx_tokens is 8k, and max_ctx_tokens is undefined? Then est_total > big_ctx_tokens → flagship. If flagship is configured with models that have ≥ big context, OK. If flagship has no models, no_route. Fine.

But what if `max_out` is smaller than actual needed and provider caps? Not our problem.

**Issue 8: `msg_count ≤ 3` in rule 4 includes system.**

`msg_count` is defined as "请求 messages 数组长度（含 system，全部角色）". Rule 4: `msg_count ≤ 3`. So one system + one user + one assistant = 3. Seems reasonable.

**Issue 9: Cache capacity monitoring and key hash size.**

`phash2` domain is 2^28, capacity 4096. Collision probability ~? For 4096 items, birthday bound. They say ~3e-5. Actually for two arbitrary keys colliding: 1/2^28 ≈ 3.7e-9. For 4096 items, expected collisions ~ n^2/(2*N) = 4096^2 / (2 * 268435456) = 16777216 / 536870912 ≈ 0.03125. So probability of at least one collision is ~3%. They say ~3e-5, which seems wrong. Wait maybe they mean probability of a specific key colliding with another existing key: 4096 / 2^28 ≈ 1.5e-5. Yes, that's per-key collision probability with existing entries. They wrote "碰撞概率 ~3e-5" which might mean per-key. Fine, acceptable.

But is `phash2` positive? Erlang `phash2/1` returns a non-negative integer < Range. Good.

**Issue 10: `SysPrefix` truncation to 256 characters - but content could be a part list.**

`SysPrefix`: "所有 system 角色消息的文本按序拼接后取前 256 字符". The features extraction requires content to be binary or part list. For system messages, content could be a list of parts with text parts. The text extraction concatenates text parts. Fine.

**Issue 11: `LastUserPrefix` truncation and cache key alignment.**

Spec says cache uses first 1200 chars, judge input uses first 1200 chars. This was fixed. Good.

**Issue 12: Tool fingerprint `ToolsFp` is full JSON encoding, but cache key includes it. This could be large but phash2 bounds it. Fine.**

**Issue 13: Cache stores `{Tier, JudgeModel, ExpiresAt}`. But when reading, we need to compare JudgeModel with current. What if `judge_model` is undefined (rules-only)? Then judge zone only happens when judge is assigned. If judge_model becomes undefined, any cache entries with some judge model would be treated as miss. But there shouldn't be cache entries if judge_model was always undefined. If it was previously defined and now undefined, old cache entries have JudgeModel = some model. Current is undefined → mismatch → miss. Good.

**Issue 14: Configuration validation - `max_ctx_tokens < big_ctx_tokens` ⇒ ignore max_ctx_tokens.**

What if `max_ctx_tokens` is configured but < `flagship` actual capability? We don't know flagship capability. Spec says "配置语义矛盾：硬上限不应低于 big 档容量阈值". This is reasonable.

**Issue 15: The judge system prompt is in English and says "Reply with exactly one word...". The user content wraps in quotes. Fine.**

But §6.1 says "user 内容：system 前 256 字符 + 末条 user 消息前 1200 字符 + 输出预算档位一行". Wait, this is sent as the *user message content* to the judge. But the system prompt itself describes the task. This is standard.

Is there an injection risk? The user content includes the raw user text (wrapped in quotes). If the user text contains the quote delimiter or
