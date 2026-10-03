# Review v2.4 by minimax-m3 (MiniMax-M3)

_44.0s · completion_tokens=4000_

<think>Let me carefully review this v2.4 specification, focusing on:
A. Remaining defects or new issues introduced in v2.1 (since this is v2.4 based on v2.1)
B. Missing edge cases
C. Specific actionable improvement suggestions

The reviewer's judgment criteria: only correctness, safety, usability, and cost issues count as defects. Style preferences, wording, hypothetical extreme scenarios don't count.

Let me go through systematically:

**1. Rule 4 fast tier semantics issue**

Rule 4 says: "not has_tools AND est_total < fast_ctx_tokens AND msg_count ≤ 3" → fast (hard)

Wait, the design text says: "fast 档不可用时按 soft 语义降级 default_tier"

But then the hard/soft table marks Rule 4 as "定向 hard / 可用性 soft". 

Looking at the table in §8: "规则 4 fast 档不可用 | 按 soft 语义降级 default_tier"

So rule 4 has "directional hard, availability soft" semantics - meaning: if the request matches rule 4 conditions, it MUST go to fast (not big/flagship), but if fast is unavailable, it can fallback to default_tier.

But there's a subtle issue: the request goes to fast even if user has a marker (no - rule 2 runs first and is higher priority, so markers → flagship). So rule 4 is only hit when there's no marker, no multimodality, etc.

The issue I see: msg_count ≤ 3 — but `est_total < fast_ctx_tokens` uses `est_total` which includes `max_out`. So a short prompt + a long max_out will NOT trigger rule 4. Good.

But there's another issue: `est_total` for the rule 4 comparison uses `prompt_est + media_allowance + tools_est + max_out`. If a request has multimodal content (has_multimodal=true), it would already hit rule 1 → flagship. So in practice, rule 4 only sees text-only requests. media_allowance is 0. Good.

Hmm, wait - what about `prompt_est_bucket` vs `est_total_bucket` in cache key? The cache key includes `prompt_est_bucket` (prompt_est div 4096) and `max_out_bucket` (max_out div 4096), but NOT `tools_est` bucket or `media_allowance`. So if two requests differ only in tools size, they may share cache entry even when tools presence/size matters. But the cache key does include `ToolsFp` (full fingerprint of tools). And `HasMM`. So OK.

But wait - rule 4 also checks `not has_tools`. If tools presence changes, ToolsFp changes (different). Good. msg_count is NOT in cache key though. Two requests with same prompt, tools, multimodal flag, prompt_est_bucket, max_out_bucket but different msg_count could share cache entry. msg_count matters for rule 4 (≤3). Could this be a correctness issue? Yes, but it's a small one: a request with msg_count=4 would be in judge zone while msg_count=3 same prompt would route to fast. Different decisions. Cache miss is not catastrophic, just less optimal.

Actually wait - if cache says "fast" but the actual decision should be "judge", we'd route to fast without judge. That could be a correctness miss. Conversely, if cache says "big/flagship" (from judge) but rule 4 should have routed to fast. Either way it's suboptimal but cache is 300s and decisions are still mostly right. I'd note this as a minor issue.

**2. Cache key: msg_count not in key**

This is actually a concern. Let me think again:
- Rule 4: msg_count ≤ 3 → fast (no judge)
- msg_count > 3: skip rule 4, go to judge

If a 4-msg request gets cached as "big" from judge, and then a 3-msg request with identical other features comes in, it'll cache-hit as "big" and skip rule 4's fast routing. The 3-msg request should go to fast but goes to big.

This is a correctness issue: cache could route a fast-eligible request to a more expensive tier. Not catastrophic but it's a "rule 4 always wins for cache hits" issue.

Actually, this is essentially saying: the cache is a soft policy. Rule conclusions are not affected by cache (good - rules fire first). But cache affects judge decisions. So the 3-msg case would:
- Rule 4 fires (msg_count=3, no tools, est_total < fast) → fast (hard)
- Cache check happens in judge zone, but rule 4 already exited to fast, so cache irrelevant

Wait, let me re-read the pipeline. Rules fire first (§3 step ③). Rule 4 → fast (hard). Cache is only consulted in step ④ (judge zone). So if rule 4 fires, cache doesn't apply. msg_count only matters when rule 4 condition is borderline. But cache and rule decisions don't overlap because rule conclusions always come first.

OK so msg_count not in cache key is fine. Cache only applies to requests that would have gone to judge anyway.

But wait - there's still a subtle issue: rule 4 has `msg_count ≤ 3` AND `est_total < fast_ctx_tokens`. Different msg_count → different routing decisions. But since rules fire before cache, this is OK.

However, there's another issue: rules fire BEFORE cache check. So rule 4 hit → fast. Rule 4 miss → judge zone. In judge zone, cache could short-circuit. So requests going to judge can be cached. That's fine.

But what if a request goes to judge zone (not rule 4), gets cached as "fast", and later the same request (in judge zone still) gets cached as "fast"? Rule 4 would route to fast anyway. Same outcome. OK.

What if a request goes to judge zone (rule 4 misses), gets cached as "big", and then rule 4 should still not fire because msg_count>3. Same outcome (big). OK.

So msg_count not in cache key is not a real issue.

**3. prompt_est_bucket precision**

`prompt_est_bucket = prompt_est div 4096`. So requests with prompt_est between 4096-8191 share a bucket. Two requests differing only by 1 token in prompt might hash differently because phash2 of the tuple will differ in the integer value. So buckets are a separate identifier; it's not actually a bucketing mechanism. Wait, the value of `prompt_est_bucket` in the tuple is an integer; the integer is exact. So two requests with prompt_est=4096 and prompt_est=4097 get `prompt_est_bucket=1` and `prompt_est_bucket=1` (same!).

Oh, this IS a bucketing. So prompt_est differs by <4096 → same bucket. Two requests with very similar prompt lengths might hash differently due to SysPrefix/LastUserPrefix/ToolsFp/HasMM. So the bucket just reduces cache fragmentation, not correctness. Good.

**4. Decision cache key vs negative cache key**

v2.4 separates `{pos, Hash}` and `{neg, Hash}`. Reading: first check pos, then neg. Writing: positive decisions overwrite positive only; negative decisions write negative only. Two separate sets or one set with tagged key?

Looking at §5: "正决策存 `{pos, Hash}`，负缓存存 `{neg, Hash}`". This looks like one ordered_set with tuple keys. Reading order: "先查正条目，命中且未过期即用；仅当无有效正条目时才查负条目".

Issue: when judge succeeds, only positive is written. Negative entries naturally TTL out. But if a request previously failed (negative cached) and then succeeds, the negative entry stays around for 30s blocking subsequent positive misses? No - the read order checks positive FIRST. If positive exists (just written), it's used. Negative is only consulted if positive miss.

But what about this scenario:
1. Request X → judge fails → negative cached for 30s
2. Within 30s → request X → negative hit → default_tier
3. Within 30s → operator switches judge_model
4. Now judge_model config changes; negative cache says "Tier=neg, JudgeModel=oldJudge". Old negative still says "skip judge". So during those 30s, judge won't run.

But wait - the negative cache stores JudgeModel too (looking at value: `{Tier, JudgeModel, ExpiresAt}`). The read logic: "读取时 `JudgeModel` 与当前配置不符即视为 miss". So a negative cached entry with old JudgeModel → miss. Good.

OK, but here's an edge case: what if positive and negative both exist for same Hash (different JudgeModels)?
- Read: check positive. If positive exists with current JudgeModel → use. Otherwise check negative with current JudgeModel. Otherwise miss.
- This is correct.

**5. Negative cache under signal/breaker**

§6.2: "信号量满则跳过 judge → default_tier，**不计失败、不计熔断**"
§6.2: "负缓存命中（30s）与 default_tier 走 default_tier"
§5: "信号量跳过既不计入也不清零"

OK these are consistent.

**6. Rule 0 priority over judge timeout**

Rule 0 fires before all routing. est_total includes max_out. So a request that would be route to fast via rule 4 but has est_total > max_ctx_tokens → 400. Good.

But: max_out default is 4096 (line in §4.1). If max_ctx_tokens = 8000, fast_ctx_tokens = 8000. A request with prompt_est=3000, max_out=4096 → est_total = 7096, within fast. But what about prompt_est=0, max_out=4096? Still ok.

A request with prompt_est=4000, max_out=4096 → est_total = 8096 > max_ctx_tokens (if 8000) → 400. OK.

**7. Decision cache key missing tools count or has_tools explicit**

Wait, the key has `ToolsFp` (tools fingerprint). If tools changes, fingerprint changes. OK.

But: rule 3 = `(prompt_est + tools_est) × 1.2 > big_ctx_tokens`. Different tools → different tools_est → different tools_est fingerprint. Actually `tools_est` is in features but NOT in cache key. ToolsFp (phash of JSON) is. Two requests with same tools but different byte encodings → same fingerprint → same key. That's fine.

But: tools_est is not in cache key. If tools_est changes but JSON phash stays same (impossible if content differs, since phash2 is sensitive), no issue.

Hmm wait - is tools_est (numeric value) relevant to routing decisions? Yes: rule 3 uses it. ToolsFp captures tools content; if content differs, ToolsFp differs, different cache key. So tools are accounted for. Good.

**8. Rule 4 includes est_total vs prompt+tools only**

Rule 4: `not has_tools AND est_total < fast_ctx_tokens AND msg_count ≤ 3 → fast`.

est_total = prompt_est + media_allowance + tools_est + max_out.

If has_tools, rule 4 doesn't fire (not has_tools is required). So tools_est is 0 in rule 4 path. If has_multimodal, rule 1 fires first. So media_allowance is 0.

So rule 4 effectively compares: prompt_est + max_out < fast_ctx_tokens (with msg_count ≤ 3).

Hmm, this means if max_out is large (e.g., 8000) and prompt_est is 0, ratio = 8000, equal to fast_ctx_tokens (8000 default). The condition is `<`, so doesn't fire. Falls through to judge zone. OK.

If fast_ctx_tokens = 8000, max_out = 4096 (default), prompt_est = 3000: est_total = 7096 < 8000 → fast. OK.

**9. Major issue I see: Rule 4 semantics comment about est_total**

§4.2 says: "总窗口比较基于 prompt+output 共享窗口的通用假设（主流模型如此）；输出上限独立的部署者可上调 fast_ctx_tokens"

Wait, but est_total already includes max_out. So the assumption "shared window" is built into est_total. If a model has separate input/output windows, est_total would over-estimate. But that's the deployment's choice.

The comment seems contradictory: "共享窗口假设" but est_total = prompt + output (treated as one window). OK it's just saying the assumption underlying est_total. Fine.

**10. **Section 4.1: text part token estimation**

"ASCII 字节数 ÷ 4；其余全部码点（CJK、韩文、emoji、一切非 ASCII）按码点数 × 1.5"

What about a mixed string? "ASCII bytes div 4" plus "remaining codepoints × 1.5". So the function presumably computes: ASCII byte count / 4 + non-ASCII codepoint count * 1.5.

For pure ASCII "hello" (5 bytes), est = 5/4 = 1.25 → rounded? Not specified. For "你好" (2 codepoints), est = 0 + 2*1.5 = 3. Reasonable.

What about whitespace tokens? " " is ASCII, contributes 0.25. Many spaces = many tokens (real tokenizer agrees). OK.

What about code with lots of punctuation? ASCII, /4. OK.

What about numbers? ASCII, /4. OK.

Edge case: empty string? 0/4 = 0. OK.

What if a binary contains invalid UTF-8? It's binary, not unicode. We'd iterate bytes. Non-ASCII bytes treated as non-ASCII codepoints. 1 byte = 1 codepoint * 1.5 = 1.5. Slight over-estimate but OK.

**11. Marker detection with empty user messages**

§4.1: "防御性定义：无 user 角色消息或 messages 为空 ⇒ marker_hit = false、LastUserPrefix = <<>>"

But what about a request where the LAST user message is empty (e.g., just an image)? Then marker_hit = false (no markers in empty text), but has_multimodal = true → rule 1 → flagship. OK.

What if the last user message has only whitespace? marker_hit = false (no marker substring). Goes to judge zone (assuming rule 4 fails). Fine.

**12. Input robustness: messages validation**

"features/1 入口校验 messages 为 map 列表、content 为 binary 或 part 列表；不满足（null 元素、字符串消息等畸形输入）⇒ maybe_route 直接返回 pass"

What about deeply nested invalid structure, e.g., message is map but content is integer? Should validate content type too. The spec says "content 为 binary 或 part 列表" — so validation should check this. If validation fails, pass. Good.

What about a message with content = [] (empty list)? It's a part list (empty). Should be valid. But then text extraction has nothing. prompt_est = 0. OK.

What about content = null (explicitly null)? Spec says "binary or part list", null is neither → invalid → pass. OK.

What about a message missing the "role" field? role is required for routing. If role is missing or unknown, can't determine LastUserPrefix. Default behavior? Not explicitly stated. Should probably treat as malformed → return pass. Edge case.

**13. Judge spawn_monitor cleanup race**

§6.2: The receive after timeout does exit(Pid, kill) then demonitor with flush. But what about the original process being monitored - if Pid sends `{Ref, Tier}` right at the moment of kill, race condition?

Actually, the receive has:
```
receive
  {Ref, Tier} -> ...demonitor, flush
  {'DOWN', MonRef, ...} -> fail path
after timeout -> exit, demonitor, flush
end
```

If the judge process completes successfully just as timeout fires:
- exit(Pid, kill) is sent
- judge has already sent {Ref, Tier} via the monitor mechanism? No - monitor mechanism sends {'DOWN', ...} when process exits. The judge worker sends {Ref, Tier} via Erlang messaging to caller.
- So if judge sends {Ref, Tier} then exits normally → caller receives {Ref, Tier}, demonitors with flush (no DOWN queued), proceeds normally.
- If timeout fires before {Ref, Tier} arrives → exit(Pid, kill), demonitor with flush. Any DOWN in mailbox is flushed.
- Race where judge sends {Ref, Tier} at same instant as timeout fires: timeout wins (caller enters after clause), Pid is killed (but already sent message), demonitor flushes any DOWN.

Hmm, if judge sent `{Ref, Tier}` and Pid is killed, the message is in our mailbox. `demonitor(MonRef, [flush])` flushes DOWN messages but NOT data messages. So we'd lose the {Ref, Tier} reply. The after clause doesn't have access to {Ref, Tier} in mailbox.

This is a known Erlang idiom issue. The fix: after receiving 'DOWN' or timeout, scan mailbox for {Ref, Tier} first. The current code doesn't do this.

Actually wait, let me re-read:
```
after judge_timeout_ms ->
    exit(Pid, kill),
    erlang:demonitor(MonRef, [flush]),
    失败路径
end
```

If {Ref, Tier} is in mailbox but DOWN is not yet received, the after fires, kills Pid. The DOWN message would be queued momentarily. demonitor flushes it. But {Ref, Tier} remains in mailbox - we'd never process it. So if judge succeeds at exactly timeout, we treat as failure. Minor edge case.

Actually, a better idiom is:
```
receive
  {Ref, Tier} -> ...
  {'DOWN', MonRef, ...} -> fail
after Timeout ->
  exit(Pid, kill),
  receive
    {Ref, Tier} -> ... %% race window
  after 0 -> 
    demonitor(MonRef, [flush]),
    fail
  end
end
```

But this is an edge case. The judge timeout is 1500ms default, so the race window is microseconds. Could be ignored.

Actually this is a real correctness issue in edge cases. But probably acceptable as "very rare race".

**14. Negative cache value: Tier=neg vs Tier=default_tier**

§6.2 says negative cache value: "失败特征写 30s TTL 条目（与决策缓存同结构，Tier 记为 `neg`）"

So negative cache stores Tier=neg as a</think>


