# Review v2.3 by minimax-m3 (MiniMax-M3)

_70.9s · completion_tokens=4000_

<think>Let me carefully review this v2.3 specification for the Janus Auto Router. The user has asked me to identify:

A. Remaining defects or v2.1-introduced issues
B. Missing edge cases
C. Specific actionable improvement suggestions

The user also notes that the previous round claimed v2.3 fixes all prior issues. I need to be strict and only count issues that affect correctness, safety, usability, or cost.

Let me go through the spec section by section carefully.

**§2.2 Authorization model**: 
- `api_key_models` only checks original model name, not rewritten name. This is acknowledged as a deliberate choice.
- The mitigation is a startup warning. Let me think... if a key has `api_key_models = [<<"janus-auto">>]` and the agent's auto-router routes to a model NOT in the original whitelist, it would bypass authorization. The warn at startup is good but the actual runtime bypass still exists.
- However, this is a deliberate design choice and the user said don't relitigate it ("定案，不再复议"). But there's a related edge case...

**§2.3 Router never makes 5xx**:
- The promise is good but the `pass` return for unconfigured/exception means it falls through to "normal model processing" which returns `model_not_found` 404. This is fine.

**§3 Pipeline**:
- Rule 0 check happens "先于一切路由规则" — good, but I need to verify the priority is correct.
- Wait, rule 0 is "est_total > max_ctx_tokens" → 400. But rule 3b is "est_total > big_ctx_tokens" → flagship. If max_ctx_tokens is configured and est_total > max_ctx_tokens but est_total ≤ big_ctx_tokens, that's impossible since max_ctx_tokens ≥ big_ctx_tokens (validated at startup). So rule 0 essentially never fires if it's > big_ctx_tokens because rule 3b already catches it. Actually, rule 0 fires for any tier — but the protection "if not configured" is via rules 3+3b. Wait, the spec says "未配置 max_ctx_tokens 时的容量防线说明（各档阈值 + 规则 3b 即完整防线）" — so the only case where rule 0 fires is when max_ctx_tokens is configured AND est_total > max_ctx_tokens. Since max_ctx_tokens ≥ big_ctx_tokens at validation, est_total > max_ctx_tokens implies est_total > big_ctx_tokens, so rule 3b would have caught it first. UNLESS max_ctx_tokens < big_ctx_tokens... but that's validated and rejected.
- Actually wait — there's a subtlety. Rule 3b fires BEFORE rule 4 (fast). So if est_total > big_ctx_tokens but prompt_est+tools_est is small enough that rule 3 doesn't fire, rule 3b fires and routes to flagship. That's correct.
- But wait, can est_total > max_ctx_tokens and yet no rule catches it? Let me trace: rule 0 is the highest priority, fires → 400. Good.

- **Issue**: The error body for 400 includes `"type":"invalid_request_error","code":"request_too_large"`. Is `code` a standard OpenAI field? Looking at OpenAI's actual API, they use `type` and `code` together sometimes (e.g., `"code":"context_length_exceeded"`). The spec invents `"code":"request_too_large"` — is this an actual OpenAI code? Let me think... OpenAI uses codes like `"context_length_exceeded"`. The custom code `"request_too_large"` might be invented. But the spec says "OpenAI 兼容 invalid_request_error 格式" — the format is compatible, the specific code may be custom. Minor, but worth noting if it affects client SDK compatibility.

**§4.1 features**:
- ASCII bytes ÷ 4: This is a rough approximation. ASCII chars are typically 1 byte each, and 1 token ≈ 4 chars. So this is correct for English text. But it's actually "ASCII bytes" not "ASCII chars" — for ASCII they're equivalent (1 byte = 1 char). OK.
- Non-ASCII codepoints × 1.5: This is quite low for CJK. GPT-style tokenizers typically tokenize CJK at 1-2 chars per token (sometimes 1:1 for common chars, sometimes 1:2 or worse). So 1.5× might underestimate CJK by 2x or more. But the spec says "宁可高估触发上限" — wait, it says "宁可高估" (rather overestimate) for media_allowance, not for text estimation. For text, 1.5× is probably an underestimate for CJK. This could cause est_total to be too small, allowing requests that exceed capacity through. **This is a correctness/safety issue** — but wait, the whole point is to over-estimate and trigger the cap. If we under-estimate CJK, we let oversized requests through to the model. This contradicts the "宁可高估" spirit.

Actually, let me reconsider. The note "宁可高估触发上限，不做 provider 级精确计费" applies to media_allowance. For text, no such note. For CJK at 1.5 tokens/char, this is roughly accurate for GPT-4 tokenizer (which tokenizes each CJK char as ~1-2 tokens). It's a coarse estimate. This is acknowledged as rough. Not necessarily a defect.

- `media_allowance` = non-text parts × 4096. For high-res images that cost more, or audio that's very long, 4096 might be too low. But this is the "宁可高估" — wait, no. 4096 is the allowance. If a high-res image actually costs 8000 tokens, we'd underestimate. Hmm. But the spec says "粗粒度媒体预算" and "宁可高估触发上限". If 4096 is lower than actual cost, we underestimate, allowing requests that exceed capacity. The direction should be "粗粒度高估" — but 4096 may not be high enough. For a 2048x2048 image, GPT-4o charges ~1105 high-detail tokens (low) up to 6380 (high detail). 4096 is in the middle. For audio, 1 minute at whisper = ~100s of tokens, but 10 hours of audio could be much more. The 4096 default is a rough per-part estimate. **Issue**: media_allowance may significantly underestimate audio/video costs. Should make this configurable or higher default.

Wait, actually let me re-read. "零假设下的粗粒度媒体预算". The value 4096 is a default that can be overridden via config. The issue is whether the default is reasonable. For an image: 4096 tokens might be OK as a median. For audio of unknown duration: 4096 might be way too low. But we don't know duration from the API. Acceptable as rough estimate, especially since this is an overestimate for images.

- **marker_hit** — only checks LAST user message text. What if the marker is in a system message? Or in a non-last user message? The spec says "末条 user 角色消息" — explicit design choice. Fine.

- **marker lowercasing**: "ASCII 标记做词边界匹配，CJK 标记直接子串". OK, but what about mixed markers like "Think 更深" where the ASCII part needs word boundary but is mixed with CJK? Unlikely edge case.

- **messages robust handling**: "整体 pass → 模型未知 404". Good — no upstream pass-through for malformed input.

**§4.2 Rule gate**:
- Rule 0 vs rule 3b priority: Rule 0 is "est_total > max_ctx_tokens" — only fires if max_ctx_tokens is configured. Rule 3b is "est_total > big_ctx_tokens". Order: rule 0 first → 400. If max_ctx_tokens not configured, rule 0 doesn't fire, rule 3b catches excess. OK.

- Rule 3: `(prompt_est + tools_est) × 1.2 > big_ctx_tokens → big`. This means if prompt+tools × 1.2 exceeds big window, route to big. But what if prompt+tools × 1.2 > max_ctx_tokens? Rule 0 should fire first. Let me check the priority: 0, 1, 2, 3, 3b, 4, 5. Rule 0 fires before rule 3. So if max_ctx_tokens is configured and prompt+tools×1.2 > max_ctx_tokens, we get 400. If max_ctx_tokens not configured, we get rule 3. OK.

- Wait, but rule 3 doesn't include max_out! It only considers prompt+tools×1.2. So a request with prompt=1000, tools=0, max_out=100000 would have rule 3: (1000+0)×1.2 = 1200, which is < big_ctx_tokens. Rule 3b: 1000+4096+0+100000 = 105096 > big_ctx_tokens → flagship. OK, that's caught by rule 3b. Good.

- But what about rule 4? "est_total < fast_ctx_tokens 且 msg_count ≤ 3 → fast". If est_total is huge but prompt is tiny and max_out is tiny... actually max_out defaults to 4096, so est_total ≥ 4096 + prompt_est. If fast_ctx_tokens = 8000, est_total ≤ 8000 means prompt ≤ ~4000 ASCII. That's a reasonable fast-tier limit.

- **Rule 4's "定向 hard / 可用性 soft"**: This is tricky. Rule 4 fires → tries fast. If fast unavailable → fallback to default_tier (soft). But if default_tier is fast and fast is unavailable, we'd loop... actually "default_tier 档再试一次" is in §7 tier resolution. But what if default_tier IS fast and it's unavailable? We'd try default_tier (which is fast), fail, then return no_route. That seems right.

- **Issue**: Rule 4 explicitly says it doesn't enter the judge partition. "规则 4 命中的短请求不进判分区". This is documented as a deliberate cost trade-off. The user explicitly says don't relitigate previous round fixes. So this is a known trade-off, not a defect to flag.

**§5 Decision cache**:
- Key construction: SysPrefix + LastUserPrefix + ToolsFp + HasMM + prompt_est_bucket.
- HasMM is "防御性冗余，规则门先行使其实际恒为 false" — so it's always false in cache keys. This means a multimodal request would have has_multimodal=true at rules → flagship (rule 1), never entering judge. So HasMM in cache key is indeed always false. The defense is in case rules change later. OK.
- prompt_est_bucket: `prompt_est div 4096`. This means requests within 4096 token buckets share cache entries. Could lead to cache poisoning (one request's tier applies to another). But this is "近似复用" acknowledged as design choice. Fine.

- **Ghost hit fix**: value carries JudgeModel; mismatch → miss. Good.

- **TTL**: 300s. Cache invalidation on config change: "配置变更时以配置指纹重算" mentioned in §7 startup validation but not for cache. The cache uses lazy expiration only. If judge_model changes, new keys are generated with new JudgeModel in value → mismatch on read → miss. Old entries expire naturally. OK.

- **Multi-table cleanup**: "容量 >4096 时从辅表头部取出... 单次清扫至多处理 128 条". OK, bounded cost.

- **Issue**: When the cache is full and we're adding new entries, we trigger cleanup. But each write triggers a cleanup attempt? Let me re-read: "容量 >4096 时从辅表头部（最旧）取出条目检查过期并双表删除，单次清扫至多处理 128 条". It doesn't say "per write", but presumably cleanup happens on write when capacity exceeded. If many writes happen rapidly, we might repeatedly trigger cleanups. The 128 cap per cleanup is the bound. OK.

**§6 Judge**:
- Spawn_monitor pattern: Ref is unique per call. Worker writes {Ref, Tier} back. Caller matches Ref. Timeout exits worker. Both paths demonitor with flush. Good.
- **Issue**: gun:open is "一次性连接, owner=本进程". When we `exit(Pid, kill)`, gun's owner-death handling closes the connection. Good.
- But: spawn_monitor with fun() -> ... chat_completions() ... end. The fun captures variables from caller scope. If the caller exits before the worker (e.g., HTTP handler times out at gateway level), the worker becomes orphaned. But monitor handles this — when caller exits, {'DOWN', MonRef, process, Caller, Reason} arrives. But the receive already happened if caller was alive. Hmm.

Actually, there's a subtle issue: if the HTTP handler is killed (e.g., client disconnects), the worker continues. The spec says "monitors the worker". Wait, actually `spawn_monitor` from caller perspective: caller monitors the worker. So caller gets DOWN when worker exits. If caller exits first... the worker becomes unmonitored but keeps running until it finishes. This could leak workers. Not really a defect per the spec scope (router never makes 5xx), but a potential resource leak.

- **Semaphore**: "全局 judge in-flight 计数上限... 满则跳过 judge → default_tier, 不计失败、不计熔断". OK.

- **Negative cache**: 30s TTL. Good.

- **Circuit breaker**: "连败计数只累计实际发起的 judge 调用的失败". "配置切换竞态" — worker snapshots judge_model, results carry snapshot, mismatch → discard. Good.

- **Judge input privacy**: "system 前 256 字符与末条 user 消息前 1200 字符". Total ~1456 chars ≈ 500-1500 tokens depending on language. Sent to judge model. Privacy implication noted.

**§7 Config**:
- Startup validation comprehensive.
- **Issue**: `max_ctx_tokens` < `big_ctx_tokens` → "error + 忽略该上限". So if misconfigured, max_ctx_tokens is silently ignored. The error log helps, but the protection is then only at big_ctx_tokens level. This is documented behavior. Fine.

- **Issue**: `default_tier ∉ keys(tiers)` → error + 回退 rules-only. But rules-only might still need a default. Actually, rules-only means: rule 4 → fast, rules 1/2 → flagship, rules 3/3b → big/fallback. If no tiers are configured, all rules fail. OK.

- **Tier resolution**: hard target unavailable → no_route (no fallback). Soft target unavailable → default_tier retry → still fail → no_route. Good.

**§8 Failure semantics table**: Mostly consistent with the spec.

**§9 Observability**: stats counters listed.

**§10 Privacy**: judge sends content to external model. Noted.

**§11 Test plan**: Comprehensive.

Now let me identify real defects:

**Defect A1: Rule 4 boundary — fast_ctx_tokens ≤ 4096 ambiguity**

Rule 4 condition: `not has_tools` AND `est_total < fast_ctx_tokens` AND `msg_count ≤ 3` → fast.

But max_out defaults to 4096. So est_total ≥ max_out + prompt_est ≥ 4096. If fast_ctx_tokens is set to ≤ 4096 (e.g., 2000), then est_total < fast_ctx_tokens would never be true (since est_total ≥ 4096 always). The operator who wants short-only fast would set fast_ctx_tokens small, but it'd never trigger. **Real issue**: the default fast_ctx_tokens = 8000, so est_total < 8000 means prompt+tools+media+4096 < 8000 → prompt+tools+media < 4004. That's the intended "short request" range. OK.

But if operator sets fast_ctx_tokens < 4096, rule 4 dead. Not really a defect, just a config caveat.

**Defect A2: Rule 3 vs Rule 3b interaction with max_out**

Rule 3: `(prompt_est + tools_est) × 1.2 > big_ctx_tokens → big`.
Rule 3b: `est_total > big_ctx_tokens → flagship`.

If prompt+tools is small but max_out is huge (e.g., max_completion_tokens=100000), rule 3 doesn't fire (good), but rule 3b fires (good, → flagship).

What if prompt is moderate and max_out is moderate, such that (prompt+tools)×1.2 > big_ctx_tokens but est_total < big_ctx_tokens? That would mean prompt+tools > big_ctx_tokens/1.2, but prompt+tools+max_out < big_ctx_tokens. So max_out < big_ctx_tokens - (prompt+tools) < big_ctx_tokens - big_ctx_tokens/1.2 = big_ctx_tokens × 0.167. So max_out < ~10% of big_ctx_tokens. Possible but unusual. In this case, rule 3 fires → big (correct, since prompt+tools overflows big window). Rule 3b doesn't fire. So we'd go to big. Good.

What if prompt+tools > big_ctx_tokens? Then rule 3 → big. But big's window is big_ctx_tokens. We'd send a request whose prompt+tools already exceeds big_ctx_tokens to big — would fail. Actually, the spec says "big_ctx_tokens 语义为总窗口（prompt+tools+output）". So big_ctx_tokens is total. If prompt+tools > big_ctx_tokens, even max_out=0 doesn't fit. Rule 3 should arguably route to flagship instead. But rule 3b checks est_total > big_ctx_tokens, which would also be true (since prompt+tools > big_ctx_tokens implies est_total > big_ctx_tokens). Wait, rule 3b is checked AFTER rule 3 in the priority list! So rule 3 fires first → big. The request goes to big and fails.

Let me re-check the priority: 0, 1, 2, 3, 3b, 4, 5. So rule 3 fires before 3b. If (prompt_est + tools_est) × 1.2 > big_ctx_tokens → big. Rule 3b is "est_total > big_ctx_tokens → flagship". But if (prompt+tools)×1.2 > big_ctx_tokens, then prompt+tools > big_ctx_tokens/1.2. For rule 3b to also fire, we need prompt+tools+max_out+media > big_ctx_tokens. If prompt+tools = big</think>


