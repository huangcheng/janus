# Review v2.2 by mimo-v2.6-pro (mimo-v2.6-pro)

_110.3s · completion_tokens=4000_

Let me analyze this v2.2 spec carefully, looking for real defects affecting correctness, security, usability, or cost.

Key areas to check:

1. **Rule 0 ordering with rule 2/1**: max_ctx_tokens check comes before everything. But note: `est_total` includes `max_out` which defaults to 4096. What if the request doesn't set max_tokens? Then est_total = prompt_est + tools_est + 4096. If max_ctx_tokens is set to something smaller than 4096 + prompt, could reject legit requests. But that's config semantics.

2. **Rule 4 uses `est_total < fast_ctx_tokens`** - but Rule 3 check uses `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` which is checked before rule 4. If prompt+tools × 1.2 > big_ctx_tokens, request goes to big. So a request with small prompt but huge max_tokens (max_out) could pass rule 3 but est_total could exceed fast_ctx_tokens, so it wouldn't hit rule 4, falling to judge. That's fine.

3. **Rule 2 (marker) can route to flagship even if est_total > max_ctx_tokens** - wait, rule 0 is first so request_too_large would fire first. Good.

But wait: what if `est_total > max_ctx_tokens` but the request is a legitimate long-context request? The config says max_ctx_tokens should be >= big_ctx_tokens, but big_ctx_tokens is a "total window" semantic... Actually big_ctx_tokens is 60000 and max_ctx_ctx_tokens must be >= it. So a request with prompt_est + tools_est × 1.2 > big_ctx_tokens but est_total still < max_ctx_tokens could route to big. Fine.

4. **Rule 3 with multimodal**: has_multimodal bypasses rule 3. But what if multimodal request has huge prompt? Rule 1 sends to flagship without capacity check. Flagship is supposed to have largest window (deployment responsible).

5. **Cache key `prompt_est_bucket`**: uses `prompt_est div 4096`. But features include `max_out` which varies. Two requests with same prompt bucket but different max_out share cache entries. Could route one to fast when it needed big based on max_out. Wait, but rule 4 uses `est_total = prompt_est + tools_est + max_out`. So max_out is a hard-rule factor. If the rule would send it to fast/big, cache isn't consulted. Cache is only consulted after rules 1-4 don't fire. In the "judge decision" path, does max_out matter? The judge looks at system + last user prefix, not max_out. So the judge decision itself doesn't depend on max_out. So sharing cache across max_out values is consistent with judge input. But wait, the judge sees truncated content - the cache key includes prompt_est_bucket which is different from what judge sees. This is documented as approximate reuse. OK.

Actually wait - if rules 3/4 don't fire and request goes to judge, rules were checking capacity. After judge says "big", but then tier resolution happens. So the judge decision isn't a capacity decision. max_out doesn't matter for judge. OK.

6. **Marker detection on empty/no user message**: `marker_hit = false`, `LastUserPrefix = <<>>`, `judge 输入以 (no user message) 占位`. But if judge sees "(no user message)", what does it decide? Fall back to default_tier. But cache key uses `LastUserPrefix = <<>>`. So multiple different requests (different systems, same tools, same bucket) would share cache. But this is documented approximate reuse.

Actually - what if there are MULTIPLE user messages and one has marker but not the last? The spec says "末条 user 角色消息" for marker check. So markers in earlier user messages don't count. This might be intentional (last user instruction is what matters).

7. **Rule 3 `(prompt_est + tools_est) × 1.2 > big_ctx_tokens`** - this is for big tier capacity. But what if prompt_est + tools_est is much larger than big_ctx_tokens? Like > 2x? Still goes to big. But if big's window is only big_ctx_tokens, it will fail at provider. This is deployment responsibility.

8. **Judge worker race - spawn_monitor + Ref tagging**: 
```
{Pid, MonRef} = spawn_monitor(fun() -> ... {Ref, Tier} end)
receive
  {Ref, Tier} -> demonitor flush
  {'DOWN', MonRef, ...} -> failure
after timeout -> kill + demonitor flush
end
```

Issue: After the worker sends `{Ref, Tier}` successfully, it terminates normally. This emits `'DOWN'` message. If the `receive` picks up `{Ref, Tier}` first and demonitors with [flush], the DOWN is flushed. Good.

But what if DOWN arrives BEFORE the Ref message? That can't happen - worker sends Ref message before terminating (implied).

Wait, what if worker crashes AFTER sending `{Ref, Tier}` but before returning? Then DOWN with non-normal reason. But the caller already received the Ref message and demonitored with flush, which removes the queued DOWN. So DOWN won't be processed. Good.

But there's a subtle issue: if `exit(Pid, kill)` in timeout, the DOWN might already be in the queue? No, kill is immediate but DOWN is queued after. `demonitor(MonRef, [flush])` after kill - this flush removes DOWN if it was queued. But what if DOWN arrives AFTER the demonitor? That's possible: kill -> process is killed -> sends DOWN -> but demonitor already done. Actually `demonitor/2` with `[flush]` removes the message if it's in the mailbox. If DOWN is delivered after demonitor, is it filtered?

From Erlang docs: `erlang:demonitor(MonRef, [flush])` - "The monitor is removed... and the 'DOWN' message is removed from the message buffer if present." If DOWN hasn't been delivered yet, it might still arrive.

Actually, `demonitor(MonRef)` returns true and removes the monitor. Once demonitored, future DOWN messages from that monitor won't be delivered. But if DOWN was already in-flight... Erlang guarantees that after demonitor/2 returns, no DOWN for that reference will be delivered. Actually I'm not sure about this guarantee.

From Erlang docs: "If the monitor is already removed, no DOWN message will be received". And with flush option, any already-queued DOWN is removed. So after demonitor with flush, no more DOWN for that ref. Good.

But there's still a potential issue: what if the timeout fires but the worker JUST completed successfully and sent {Ref, Tier} but it's still in the mailbox? Then we `exit(Pid, kill)` (but process is already dead or finishing), `demonitor flush` (removes DOWN), but the {Ref, Tier} message is still in the mailbox unprocessed. The caller returns to the "failure path" but the mailbox has an orphan {Ref, Tier} message. This could pollute future receives in the same process.

But since Ref is `make_ref()` unique, and the caller's future receives won't match this Ref, it just becomes mailbox garbage. If the HTTP handler process is long-lived (connection reuse?), this could accumulate. But typically handler processes are per-request. This is minor and probably not a defect.

Actually this is a real concern for correctness if the handler process handles multiple requests. But if each request spawns its own judge worker and does its own receive, the orphan message would just sit there forever if the process is long-lived. If it's a per-request process, it dies.

9. **Signal semaphore not decremented on worker crash**: The spec says "全局 judge in-flight 计数上限 judge_max_inflight（默认 8，atomics 实现）". Who decrements? Presumably the worker decrements when done, or the caller decrements. If the worker crashes (killed), who decrements?

Looking at the code flow, this isn't specified. If the worker is killed due to timeout, does the in-flight counter decrement? This needs explicit specification.

Actually, if the caller increments before spawn and decrements after receiving Ref or DOWN or timeout, this is clean. But if worker increments/decrements itself, then kill would leak. This needs to be explicit.

Hmm, this is a potential leak of semaphore slots. If 8 requests all timeout and are killed, and the counter doesn't decrement, then future requests skip judge forever (until restart). This is a real availability issue.

Wait, let me re-read: "并发信号量：全局 judge in-flight 计数上限 judge_max_inflight（默认 8，atomics 实现）；满则跳过 judge → default_tier，不计失败、不计熔断"

It doesn't specify the decrement path. This is a real gap.

10. **Cache collision with `prompt_est_bucket`**: 2^28 hash space, 4096 entries, collision ~3e-5. But the key doesn't include `max_out`. Two requests same prompt bucket but different max_out would share cache. But rules would already have fired if capacity matters. So in the judge path, this is consistent. OK.

11. **`est_total = prompt_est + tools_est + max_out`** - this is used in rule 0 and rule 4. But `prompt_est + tools_est` is used in rule 3. The ×1.2 multiplier is only on prompt+tools in rule 3. So a request with prompt=55000, tools=0, max_out=4096: est_total=59096. If big_ctx_tokens=60000 and max_ctx_tokens=100000:
- Rule 3: 55000*1.2=66000 > 60000 → big. Hard.
- But est_total 59096 < 60000. So actual content fits in big's window.

Wait, the ×1.2 is a margin. So rule 3 fires when prompt alone with margin would exceed big. But if prompt is 55000 and max_out is 4096, total is 59096 which fits big. Why route to big with rule 3? Because 55000*1.2 = 66000, meaning even with 20% margin for context length estimation error, prompt alone could exceed big's window. So routing to big is safer.

But wait, what if prompt is 55000 and max_out is 20000? est_total = 75000. Rule 3: 55000*1.2 = 66000 > 60000 → big. But big's window is only 60000, so est_total 75000 > 60000 will overflow. This is a problem!

The rule 3 fires on prompt+tools with margin, but doesn't consider max_out. If max_out is huge, the request could overflow big's window even though rule 3 fires.

Wait, but rule 0 fires first: `est_total > max_ctx_tokens`. If max_ctx_tokens is set to say 100000, and est_total is 75000, rule 0 doesn't fire. Then rule 3 fires, routing to big. But big has 60000 window, so it fails.

Actually rule 3 should either consider max_out in the capacity check, or there should be a rule that routes to flagship when est_total > big_ctx_tokens.

Hmm wait, but flagship might also have a limited window. The spec says "flagship 窗口由部署者保证 ≥ big". So flagship >= big's window, but could still overflow.

This is a real gap: **requests with large max_out can pass rule 3 (which only checks prompt+tools) and route to big, overflowing big's window**.

Actually wait, let me re-read rule 3: `(prompt_est + tools_est) × 1.2 > big_ctx_tokens`. This doesn't include max_out. So if prompt+tools is small but max_out is huge, rule 3 doesn't fire.

Then rule 4: `est_total < fast_ctx_tokens`. If est_total is huge due to max_out, rule 4 doesn't fire.

Then rule 5: judge decides. Judge doesn't see max_out. Judge might say "fast". Then fast tier gets a request with est_total = 50000, but fast's window is 8000. Overflow.

Hmm but rules 3/4 are hard rules for capacity. Rule 5 is judge (soft). So the capacity protection is supposed to be in rules 3/4. But rule 3 misses max_out.

Wait, but rule 3 sends to big. Big's window is 60000. If est_total is 75000, big will overflow. But the spec says "big_ctx_tokens / fast_ctx_tokens 语义为总窗口（prompt+tools+output）". So big_ctx_tokens is the TOTAL window including output. But rule 3 only checks prompt+tools with 1.2x margin.

So rule 3's capacity check is: (prompt+tools)*1.2 > big_total_window. But if we have prompt=50000, max_out=10000, est_total=60000=big_ctx_tokens. Rule 3: 50000*1.2=60000, not > 60000, so rule 3 doesn't fire. Rule 4: est_total=60000 > fast_ctx_tokens, doesn't fire. Rule 5: judge. Judge might say fast. Fast window 8000. Overflow!

Actually the spec seems to say "rule 3 is for prompt+tools, not total". That's a design choice - allow big to be selected based on prompt, not total. But the issue is: after rule 3 doesn't fire, request can fall to judge which might pick fast, and fast's window is smaller.

Actually I think the design is: rules 3/4 do capacity routing. Rule 5 (judge) is for requests that are neither too big nor too small. The judge might pick big or flagship. The concern is: if judge picks fast for a request whose est_total exceeds fast window.

But rules 4 uses `est_total < fast_ctx_tokens` to route to fast. So requests exceeding fast window don't get routed to fast by rules. But judge could still pick fast.

Wait, after judge picks "fast", the request is routed to fast tier. But est_total might exceed fast window. Is there a check after judge?

Looking at the spec: no. Judge's decision is treated as soft and used directly. So a request with est_total = 50000 could be routed to fast by judge, and overflow fast's 8000 window.

This is a real issue! The judge doesn't know about capacity, and its decision isn't capacity-checked.

Actually wait, maybe the design intent is: after judge picks a tier, if the tier doesn't fit, the request fails at provider. That's the "上游转发" behavior. But that's a bad UX.

Or maybe: judge is only invoked when rules 1-4 don't fire. Rules 3/4 cover the boundary cases. So by the time we get to judge, est_total is < big_ctx_tokens/1.2 OR (est_total >= fast_ctx_tokens OR has_tools OR msg_count > 3).

Hmm wait, rule 3 doesn't fire means (prompt+tools)*1.2 <= big_ctx_tokens. Rule 4 doesn't fire means NOT(not has_tools AND est_total < fast_ctx_tokens AND msg_count <= 3). So it could have tools, or msg_count > 3, or est_total >= fast_ctx_tokens.

If est_total >= fast_ctx_tokens, judge might pick fast, which would overflow.

Actually I realize the judge is described as "soft estimation". The intent is that judge's tier selection is a heuristic and if the tier's capacity doesn't fit, the request fails at provider (existing behavior). But this seems like a real gap: judge can route to fast for a large request.

Wait, re-reading the design: "规则 5 短请求不进判分区" - this is a known design tradeoff. But what about long requests that go to judge? The judge doesn't see max_out or capacity, so its tier choice is purely content-based.

Maybe the design intent is: judge never routes to fast for long content because the judge sees 1200 chars of user message and would classify complex stuff as big/flagship. But that's not guaranteed.

I think this is a real issue: **judge's tier decision isn't capacity-checked**. A request with large est_total can be routed to fast by judge and overflow.

But actually, looking more carefully at rule 3 and 4:
- Rule 3 catches requests where prompt+tools is close to big window. Route to big.
- Rule 4 catches small simple requests. Route to fast.
- Rule 5 is everything else: mid-sized, or with tools, or long conversation.

For rule 5 cases, what's the est_total range? Could be anywhere from 0 to max_ctx_tokens (if configured). So judge could pick fast for a request with est_total = 100000.

Unless the intent is: after judge picks, we do capacity check? Not specified.

Actually let me re-read rule 4: "not has_tools 且 est_total < fast_ctx_tokens 且 msg_count ≤ 3" → fast. So requests with est_total >= fast_ctx_tokens don't go to fast via rules.

But judge can still route to fast. This seems like a real gap.

**However**, this may be intentional: the spec calls judge a "soft estimation" and says failures can happen at upstream. Let me not count this as a defect if it's intentional. But it's worth flagging.

Actually the more concerning case: what if judge routes a request to fast but est_total = 50000 and fast window is 8000? The request will fail at the fast provider with a context overflow. From user perspective, this is bad - they got a 4xx/5xx from upstream.

Wait, but this is "existing behavior for normal
