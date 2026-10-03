# Review v2.5 by minimax-m3 (MiniMax-M3)

_84.5s · completion_tokens=4000_

<think>Let me carefully review this v2.5 specification. The user asks me to identify:
A. 仍然存在的缺陷或 v2.1 新引入的问题 (Remaining defects or new issues introduced in v2.5)
B. 遗漏的边界情况 (Missed edge cases)
C. 具体可执行的改进建议 (Specific actionable improvement suggestions)

The criterion is: only correctness, safety, usability, cost issues count. Style preferences, wording, hypothetical extreme scenarios don't count.

Let me go through systematically:

**Section 2.2 - Authorization Model**
- The model says `api_key_models` only filters on original model name, not rewritten. But wait - looking at the pipeline, the check happens BEFORE `maybe_route`. So if someone requests `janus-auto`, the check is on `janus-auto`. The warning says: if a key has whitelist including virtual name, the key can reach models outside its whitelist via the virtual model. This is acknowledged as a "mitigation" not a fix.
- Issue: There's an actual safety/correctness concern here. If a user has an agent key with whitelist `["gpt-4", "janus-auto"]`, and the virtual router routes to `claude-opus`, the api_key_models check passes (only on `janus-auto`), then the request gets forwarded to claude-opus. The §2.2 explicitly acknowledges this. This is by design per "key is identity, not quota" - so it's intentional. The warning is the only mitigation.
- This is intentional but worth noting as a security trade-off.

**Section 3 - Pipeline: `pass` path on malformed messages**
- The spec says malformed messages → `pass` → existing `model_not_found` 404. But if someone requests `janus-auto` with malformed messages, returning `model_not_found` (404) is somewhat confusing. The error message says model_not_found but actually the model exists, it's just that we couldn't parse the messages. 
- However, this is more of a usability/UX issue, not a correctness issue. A client requesting `janus-auto` with malformed messages would get a 404, which is at least safe (no upstream leak).

**Section 4.1 - `has_multimodal` and `features` defensive handling**
- The spec says content must be binary or part list. What about other valid OpenAI content shapes? E.g., `null` content, missing content, `content: []` empty array?
- An empty array `[]` would be neither binary nor a list of parts (it's an empty list, which IS a list). So technically a list. Need to check each element is a map with `type`. The spec doesn't say what happens if `content = []`. Edge case.
- What if `content` is a number or boolean? Spec says "binary or part list", other types → malformed → pass → 404. Seems OK.
- What if `messages` is missing entirely? `null` messages? → pass → 404. Reasonable.

**Section 4.1 - `prompt_est` calculation**
- "ASCII 字节数 ÷ 4；其余全部码点（CJK、韩文、emoji、一切非 ASCII）按码点数 × 1.5"
- This is a rough heuristic. For binary content (non-Unicode), what happens? Spec says "其余全部码点" which implies Unicode codepoints. Binary strings... Erlang handles them as bytes, so iterating codepoints on a binary gives the byte count for ASCII subset of bytes. For arbitrary binaries, this might give weird results. But realistically, content is UTF-8 text, so this is fine.
- One issue: the `prompt_est` is described as "仅 prompt 文本部分" (only prompt text portion). But what counts as "prompt"? Just user messages, or system + user + assistant? Looking at section 5, judge input is "system 前 256 字符 + 末条 user 消息前 1200 字符". So the routing decision should consider all messages that contribute to context length. The feature says `prompt_est` for "prompt 文本部分" - this is ambiguous. Does it include system messages? Tool messages? Assistant messages (multi-turn)?
- This is potentially a significant correctness issue. If `prompt_est` only counts user messages, multi-turn conversations with long assistant history would be severely underestimated, leading to routing to fast/big when flagship is needed.
- Looking more carefully: `est_total = prompt_est + media_allowance + tools_est + max_out`. If `prompt_est` is missing system + assistant history, the routing would be wrong for multi-turn requests.
- The judge input shows that system and last user are sent to judge, suggesting both matter for context. The features function should sum all message texts, not just user.

**Section 4.2 - Rule 4: `(prompt_est + tools_est) × 1.2 > big_ctx_tokens`**
- The "×1.2 只乘 prompt+tools，不乘 max_out" reasoning makes sense. But if `prompt_est` is just user messages (not system/assistant), then this comparison is wrong for multi-turn.
- Also: should assistant messages count? They're part of "prompt" in the conversation sense. Yes.

**Section 5 - Cache key construction**
- `LastUserPrefix`: last user message text first 1200 chars. Defensive: if no user message, `LastUserPrefix = <<>>`. So all messages without user role share the same key. This is OK since they all go to default_tier anyway.
- `SysPrefix`: all system messages concatenated, first 256 chars. What about a system message that's super long? Truncated to 256. OK.
- `ToolsFp`: phash2 of full JSON. Fine.
- `HasMM`: defensive redundancy. Spec acknowledges "规则门先行使其实际恒为 false" - so it's only false when reaching the cache. Then why include it in the key? It's noted as defensive redundancy. Fine.
- **Issue**: `prompt_est_bucket` uses `prompt_est div 4096`. But `prompt_est` is the text-only portion, while `est_total` includes media + tools + max_out. So if two requests have same `prompt_est_bucket` but vastly different `max_out_bucket` or media allowance, they'd hash to different keys (because max_out_bucket and tools_fp differ). OK.
- But wait: there's no `tools_est_bucket` in the key. So if a request has huge tools (50k tokens), the routing might pick fast for two requests with same prompt but different tools sizes. The tools change the routing decision (rule 4 includes tools), so they should hash differently. They do, via `ToolsFp`. So OK.

**Section 5 - "容量 >4096 时从辅表头部（最旧）无条件删除"**
- The 主表 is a `set` (not ordered_set), so iterating to find by Hash when deleting from 头部 requires a full scan per delete. The spec says "单次清扫至多处理 128 条" - 128 deletions × full scan of 4096 = lots of work. Actually `ets:take/2` on set might be more efficient. But this is performance, not correctness.
- Actually the concern: when we add to the ordered_set, we get an ordered key (by Seq). When we delete from 头部 of ordered_set, we get the oldest 128 Seq numbers. Then we need to delete from the main set by Hash. Each `ets:delete(set, Hash)` is O(1). So 128 deletes from set is O(128). Total cleanup is O(1) per add + O(128) once over cap. OK, no correctness issue.
- But: the spec says "辅表头部（最旧）" which means lowest Seq. ordered_set iteration is ordered. `ets:first/1` gives the smallest key. OK.

**Section 5 - Negative cache and TTL**
- Negative cache 30s, positive cache 300s. The spec says negative cache writes "失败特征写 30s TTL 的 `{neg, Hash}` 条目". But what about the order: when a request comes in, we check positive first, then negative. If positive is empty (first time), then negative is checked. If negative hit, skip judge. Good.
- But: when negative TTL expires, the next request re-tries judge. If judge fails again, write negative again. OK.
- Issue: if a request hits negative cache (default_tier), and the default_tier is unavailable, we get `no_route`. But the negative cache is for "judge failed" not "default_tier unavailable". OK, this is consistent.

**Section 6.1 - judge input has max_tokens: 200**
- "200 上限容纳思考型 judge 的前置 token" - 思考型 judge? Like chain-of-thought reasoning models? If the judge model is a reasoning model that burns 1000+ tokens thinking, max_tokens=200 might cut off the actual answer. The spec says "思考型 judge 的前置 token" but max_tokens in OpenAI API is the TOTAL output budget including reasoning tokens (in some implementations). If the judge is a reasoning model with 1500 reasoning tokens and then needs to output "fast", with max_tokens=200, it gets cut off before the answer.
- This is a real correctness issue if the deployment uses reasoning models as judges.

**Section 6.2 - Concurrency semaphore**
- "获取后在 `after` 块中保证释放（正常回复、DOWN、超时三条路径都归还）"
- The code shows the judge worker is spawned with spawn_monitor. The semaphore acquisition... where does it happen? The spec says "全局 judge in-flight 计数上限" - so it's global, not per-judge-worker. If acquisition happens before spawn, then release happens after. If after spawn, before receive, then release inside receive's after.
- Reading again: "judge 并发已满（信号量）→ default_tier（soft，不计失败）". So semaphore check happens before spawning the worker. Then after judge completes (or fails), release. The spec says "获取后在 after 块中保证释放" - but the after block in the receive. The acquisition is BEFORE the spawn_monitor? Or AFTER?
- Looking at the pseudocode: `Ref = make_ref()` → `spawn_monitor` → `receive ... after judge_timeout_ms`. The semaphore acquisition point isn't explicit in the code. But the after-block release is mentioned. So likely: acquire semaphore, spawn worker, receive, release in all branches.
- Edge case: what if acquire succeeds but spawn_monitor fails? Edge case for spawn failure. Erlang's spawn rarely fails, but if it did, we'd hold the semaphore. Minor robustness issue.

**Section 6.2 - demonitor flush**
- The spec says "demonitor 双路径都 flush". Pseudocode shows both branches call `demonitor(MonRef, [flush])`. Good.
- But wait: in the normal `{Ref, Tier}` branch, if the worker has already exited (and DOWN is in mailbox), the demonitor with flush removes it. If the worker is still alive but slow to send, we kill it? No, we don't kill on normal receive. But what if the worker is alive and processing, the Ref message arrives but the worker is still running (it sent the message then... what?). Looking again: worker does `chat_completions(...)` then sends `{Ref, Tier}` and exits. So normal completion: receive Ref, worker exits, DOWN arrives. Then demonitor flush removes the queued DOWN. OK.
- But what if worker crashes before sending Ref? Then DOWN arrives first (race), then no Ref. The receive matches DOWN, treats as failure. OK.

**Section 6.2 - judge worker exit handling**
- The worker does `gun:open(一次性连接, owner=本进程)` and `chat_completions(...)`. If the worker crashes (exception in HTTP), spawn_monitor sees DOWN with non-normal reason. The Caller receives DOWN, treats as failure. Good.
- But: if the worker is hung (e.g., gun stuck waiting for response), spawn_monitor doesn't detect it. The `after judge_timeout_ms` triggers `exit(Pid, kill)`. This sends kill signal. The `gun` connection owner is the worker, so killing it cleans up. OK.

**Section 6.2 - Circuit breaker per judge_model**
- "更换 judge_model 配置 = 新状态空间，旧状态自然作废". The judge worker startup takes a snapshot of judge_model. Result writes (neg cache, fail count) carry that snapshot's model name. If different from current config, discard. Good.
- But: how is the "current config" checked? It says "若与当前配置不一致，回写直接丢弃". This requires reading current config at write time. There's a race: config changes between worker start and write. But that's exactly what the snapshot semantics handle - we use the snapshot, not the current config, to decide. Wait, re-reading: "其结果回写（负缓存/连败计数）携带该快照的 model 名；若与当前配置不一致，回写直接丢弃". So we read current config at write time, compare to snapshot. If they differ, discard. This means: if config changes while a judge is in-flight, its result is discarded. This is correct behavior.

**Section 7 - Tier resolution**
- "全部不可用 → `{error, no_route}`（hard 不降级，修 N2）"
- "判分区 soft 结论的目标档：同上；全部不可用 → default_tier 档再试一次；仍不可用 → `{error, no_route}`"
- Issue: when default_tier is `fast` and we're doing rule 5 (fast soft) and fast is unavailable, we try default_tier (which is also fast). So we fail. The spec says this is the case: "规则 5 fast 档不可用 → 按 soft 语义降级 default_tier → 仍败则 no_route". So if `default_tier = fast`, rule 5 fail means no_route. Reasonable.
- But what if `default_tier` itself points to an empty tier list? Spec startup validation: "default_tier ∉ keys(tiers) ⇒ error + 回退 rules-only". So default_tier is always a valid key. And validation says "整档为空且可能被规则命中 ⇒ error（一次性）". So an empty tier should fail at startup. But what if validation passes (rule doesn't hit it) but at runtime default_tier is empty? E.g., default_tier=fast and rule 5 fast is the only consumer; if validation catches "rule 5 may hit fast and fast is empty", error at startup. OK.
- Issue: "判分区 soft 结论的目标档...全部不可用 → default_tier 档再试一次". This doesn't check if default_tier is the same as target tier. If judge says fast and fast is empty (or all unavailable) and default_tier is also fast, we'd loop. The spec doesn't explicitly forbid target == default_tier in this fallback. Minor inefficiency, not correctness.

**Section 4.1 - msg_count**
- "请求 messages 数组长度（含 system，全部角色）". OK.
- But: what about edge cases like messages=[]? Then msg_count=0, no user message, marker_hit=false. Rule 5 requires `msg_count ≤ 3` and `not has_tools` and `est_total < fast_ctx_tokens`. If messages=[] and est_total = 0 (no prompt) + 0 (no media) + 0 (no tools) + 4096 (default max_out) = 4096. 4096 < 8000 (default fast_ctx_tokens). msg_count=0 ≤ 3. So rule 5 fires, goes to fast.
- Is this intended? An empty messages request going to fast seems fine. The defensive definition says "无 user 角色消息或 messages 为空 ⇒ marker_hit = false, LastUserPrefix = <<>>". So empty messages is explicitly handled. OK.

**Section 5 - SysPrefix**
- "所有 system 角色消息的文本按序拼接后取前 256 字符（无则空串）"
- What about tool messages, assistant messages? They contribute to context but aren't in the cache key. This is the "key is judge input subset" design. Judge input is only system + last user. So cache key matches judge input. OK, consistent.

**Critical issue: Rule 1 (multimodal) before Rule 0 (capacity)**
- Wait, the spec says Rule 0 is "先于一切路由规则" and Rule 1 is multimodal. Let me re-read the order:
  - 0: est_total > max_ctx_tokens → 400
  - 1: has_multimodal → flagship
  - 2: marker_hit → flagship
  - 3: est_total > big_ctx_tokens → flagship
  - 4: prompt+tools > big → big
  - 5: fast conditions → fast
- So Rule 0 runs first. A multimodal request with est_total > max_ctx_tokens gets 400, not flagship. Reasonable - capacity exceeded.
- But Rule 1 (multimodal → flagship) is a hard rule. What if the multimodal request's est_total is between big_ctx_tokens and max_ctx_tokens? Rule 0 doesn't fire (no max_ctx_tokens configured or est_total below it), Rule 1 fires, goes flagship. The flagship model needs to handle the multimodal content. Spec says flagship window ≥ big, but doesn't guarantee flagship supports multimodal. Actually, since "视觉/音频等专项路由档（统一并入 flagship 硬约束）" is a non-goal, multimodal must be handled by flagship. The deployment is responsible for ensuring flagship supports multimodal. OK.

**Issue: marker_hit with multi-turn conversations**
- "末条 user 角色消息" - only the last user message is checked for markers. So a marker in an earlier user message (now in conversation history) wouldn't trigger Rule 2. This is intentional and reasonable.

**Section 4.2 - Rule 5: "est_total < fast_ctx_tokens"**
- If max_out is 4096 (default) and prompt is 0 and tools is 0, est_total = 4096. 4096 < 8000, fires fast. OK.
- But: max_out default is 4096, which means est_total minimum is 4096 even for empty requests. For prompts of just a few hundred tokens, est_total ≈ 4500, still < 8000, fires fast. OK.

**Section 7 - Startup validation: "judge_model 或任一 tier 候选 == 虚拟模型名"**
- Why forbid virtual model in tier list? Because that would create infinite recursion: janus-auto routes to janus-auto. Good.
- But also: tier candidates shouldn't be other virtual models (e</think>


