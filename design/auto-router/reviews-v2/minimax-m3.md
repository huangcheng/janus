# Review v2 by minimax-m3 (MiniMax-M3)

_52.5s · completion_tokens=4000_

<think>The user wants me to do a second-round review of this design specification v2. They've identified specific defects from v1 and claimed v2 fixes them. I need to focus on:

A. Remaining defects or new issues introduced in v2
B. Missing edge cases
C. Specific actionable improvement suggestions

Each section max 5 items. Direct conclusions and reasoning, no fluff. In Chinese.

Let me carefully read through v2 looking for issues:

**Pipeline analysis (§3):**
- `model_allowed` check is on "janus-auto" (the virtual model name). But §2.2 says agent key 默认可访问所有模型 with optional `api_key_models` filter. The question: does `model_allowed` apply to the rewritten target? v2 explicitly says no - only original name. OK consistent.
- However: §2.2 says "auto-router 改写后的目标模型不做二次授权校验" - but what if the original request is for "janus-auto" but the deployment has `api_key_models = ["some-specific-model"]` and janus-auto isn't in it? The original name "janus-auto" must be allowed for the request to enter. What if janus-auto is NOT in api_key_models but the user requests janus-auto? Then model_allowed blocks it. Fine.
- BUT: what about the opposite — a user with `api_key_models = ["gpt-4-only"]` requests "janus-auto", gets allowed, then is rewritten to a different model (say claude). This bypasses api_key_models filter. v2 explicitly accepts this as "no key-vs-gpu concept". OK.

**Rule gate (§4):**
- Rule 1: `has_images` → flagship. Good, no caching bypass.
- Rule 2: `ctx_tokens × 1.2 > big_ctx_tokens` → big. Note this uses raw estimated tokens (no images).
- Rule 4: `not has_tools` and `ctx_tokens < fast_ctx_tokens` and `msg_count ≤ 3` → fast
- Rule 5: otherwise → judge/default_tier

**Edge case**: What if `has_images = true` AND `ctx_tokens × 1.2 > big_ctx_tokens`? Rule 1 fires, but the image might exceed big ctx window. Flagship is selected but what if flagship doesn't actually support the image+context combination? No fallback per v2. Could be a hard 5xx from upstream. Actually no — §2.3 says never 5xx, but only catches maybe_route exceptions, not upstream 5xx. OK upstream is upstream's problem.

Wait, more importantly: Rule 2 uses `ctx_tokens × 1.2 > big_ctx_tokens` to UPGRADE to big. But what if `ctx_tokens > flagship_ctx_tokens`? No rule handles that — would fall through to judge/default_tier. Default_tier might be fast! Could blow context window. This is a missing rule for "context overflow → flagship" or at least error.

Actually wait, re-reading: "宁可误升 `big`，不可溢出小模型窗口". So they accept the design that overflow only forces upgrade to big, never flags. But if big still overflows? Default_tier could be fast and overflow. This is a real issue.

**Token estimation (§5):**
- `tools schema 字节 ÷ 4` — what about nested $defs, $ref? Just byte count of serialized JSON. Tools definitions can be huge (thousands of lines). That's a known issue.
- `max_tokens` is added unconditionally. But what if user doesn't specify max_tokens? It uses some default. The estimate assumes `max_tokens` is "output reserved" — but max_tokens in OpenAI API is the max the model can OUTPUT, not a reservation. If user sets max_tokens=4000 but actually only uses 100 tokens, we're overestimating context. That's safe (overestimate) but OK.
- Tools byte count: tools is at top level, but what about tool_choice, response_format? Not counted.
- Multi-modal: `has_images` is detected but image tokens are not added to ctx_tokens. Image tokens can be substantial (e.g., 1024+ per image). For flagship models that matter. For rule 2's check vs big_ctx_tokens, this means image+long context might fail the check because we undercount. Could overflow big model. Actually it's the opposite — undercount means we might NOT upgrade to big when we should. Real issue.

**Judge (§6):**
- `max_tokens: 200` — the prompt is "约 200 token" + system 256 chars + last user 1200 chars. So input could be ~2000 tokens. Output 200 token should be plenty for "fast/big/flagship" classification. OK.
- "唯一 Ref 选择性接收" — using `spawn_monitor` + selective receive. Good for preventing leak. But there's still a race: what if judge process crashes BEFORE monitor message arrives? `exit(kill)` won't help a crashed process. The `{'DOWN', Ref, process, Pid, Reason}` message will be received and treated as failure. Good.
- BUT: what if judge takes slightly more than `judge_timeout_ms`? We send `exit(Pid, kill)`. The judge process is killed, but in gen_server/gun process model, what about partial response? If judge has already written a response and we're racing on receive... Hmm, `spawn_monitor` doesn't track partial outputs. OK.
- Negative cache 30s + breaker 60s — what about the ORDER? "负缓存命中 → default_tier" happens before "缓存命中". What if a negative entry is being written while another request reads? ETS read/write atomicity... well it's the standard pattern. Probably fine.
- BUT: negcache and cache are SEPARATE ETS tables? Spec doesn't say. If they share a table, then with `tier | neg` value type, OK. If separate, fine. Not specified. Minor issue.

**Decision cache (§7):**
- Key includes `system前256, 末条用户前512, tools指纹, has_images, ctx_tokens div 4096`. The 4096-bucket is to prevent same-text-different-length collision. But what about partial collisions? `system前256` only — if a request has 1024 chars system message vs 256 char message, they collide. Could cache wrong tier. The bucket divisor 4096 means ctx_tokens differences of <4096 are invisible. But what if same 256-char prefix + same 512-char suffix + same has_images but with very different mid-context content → collide. Real issue but probably acceptable for cache.
- "**Key**:`erlang:phash2({...}, 268435456)`" — 2^28 = 268435456, gives 28 bits. ~268M entries. Combined with capacity 4096, 4096/268M = 1.5e-5 collision rate expected. With phash2 it's likely lower. OK.
- "Value**: `{tier, expires_at}`；读取惰性过期" — lazy expiration. With 4096 cap, when we hit cap and clean oldest, do we clean expired ones too? "按最旧清扫" — only oldest. Stale entries could persist beyond TTL until they become oldest. Minor.
- Cache doesn't include `has_tools` in key. Wait, it does: `tools指纹`. OK.
- Cache doesn't include `msg_count`. So msg_count differences don't affect cache. Minor inconsistency with features.

**Configuration validation (§8):**
- "judge_model / 任一 tier 候选 == 虚拟模型名" — reject self-reference. OK.
- But what if `default_tier` is set to a tier not defined in `tiers`? E.g., `default_tier => medium` but tiers has only fast/big/flagship. No check. Medium would crash later. Issue.
- `big_ctx_tokens`, `fast_ctx_tokens` not validated as integers > 0. Issue.

**Failure semantics (§9):**
- "目标档候选全不可用 → default_tier 档重试一次" — wait, this IS cross-tier fallback! The spec says v2 cancels cross-tier fallback (§0 ⑤), but §9 says exactly that. Contradiction! Let me re-read.
- §0 ⑤: "取消跨档回退：档空 → default_tier → 明确错误". So tier empty → default_tier. That's not cross-tier upgrade based on model availability, that's based on tier being unconfigured.
- §9 line: "目标档候选全不可用 → default_tier 档重试一次" — "候选全不可用" could mean either (a) tier is empty/unconfigured, or (b) all models in tier are currently unhealthy. The v2 rule should distinguish. If (a), spec is consistent (go to default_tier). If (b), it's a runtime fallback which v2 says NO cross-tier — but actually it might be OK because if big is down for 30s, going to default_tier (which might be fast or flagship) is a sensible fail-safe.
- Actually re-reading more carefully: "取消跨档回退" was about not jumping UP a tier because the requested tier was unavailable (e.g., fast was rate-limited so use big instead). v2 says: stick with the target tier or fail. But the runtime availability check (provider down, 5xx) is a different concern.
- The ambiguity in §9 is: what does "候选全不可用" mean precisely? "全部 not in catalog" (static) vs "all LB returns unhealthy" (dynamic runtime)? v2 rule ⑤ talks about static config. Need clarification.

Wait — let me look again. §9 says:
- "目标档候选全不可用 → default_tier 档重试一次"
- "default 档也不可用 → 404 no_route"

And §3 step ④ says:
- "tier → 模型名（用户指派列表 ∩ catalog，按序取首个可用）"

So the resolution at step ④ takes the first available from tier ∩ catalog. If none in tier, then... what? §9 says default_tier retry. So if big tier is configured as [model_a, model_b] but both are not in catalog (e.g., provider removed), then default_tier retry.

But "候选全不可用" could also mean "all return non-2xx from upstream". v2 doesn't say how to handle that — that's at the LB/proxy layer, not maybe_route.

Actually I realize the issue: spec doesn't clearly distinguish "no models in tier config" vs "all models in tier config but unhealthy". This ambiguity is an issue.

Also: "default_tier 档重试一次" — what does "重试一次" mean here? Retry the WHOLE pipeline (re-run rules, re-call judge, etc.) or just pick a model from default_tier? Spec is ambiguous. Probably the latter (just pick first available from default_tier list). But "重试一次" sounds like retrying the whole routing decision which would waste work.

**Cache invalidation on config change:**
- Spec doesn't say. If admin changes tiers config while running, cache still has old tier mappings. Minor.

**§2.2 authorization revisited:**
- v2 says "agent key 默认可访问所有模型；`api_key_models` 仅作为可选的粗过滤". But this conflicts with typical "api_key_models = user A can only use cheap models" access control. Many deployments WILL want this. Spec explicitly says non-goal: "跨档位授权控制". OK this is a documented non-goal, not a bug. But it's a real concern that deployment team should be warned about more loudly.
- Worse: there's no admin-level distinction. If you have a "junior dev key" that should only access fast models, with v2 model they can request janus-auto and get routed to flagship. That's a real bypass. Spec calls it non-goal but doesn't make this clearly loud.

**Ordered ETS cache with 4096 cap:**
- "ordered_set + 写入时间戳，>4096 行时按最旧清扫（非全表扫描）"
- ordered_set keyed by what? If keyed by tier+timestamp, you can do `first()` to find oldest. If keyed by something else, you can't easily find oldest. Need to specify the key structure.
- "写入时间戳" — but spec already says key = phash2(...). If ordered_set key is the phash2 value, you can't order by time. Need a different key (e.g., {timestamp, phash}) for ordered_set, then a separate lookup table. Not specified. Implementation ambiguity.

**Judge input (§6):**
- "system 前 256 字符" — but OpenAI spec puts system as a message in messages array, not a separate field. The spec implies there's a "system" field separate from messages. Need to clarify how to extract "system" from messages (find first message with role=system) vs other approach. Implementation detail but ambiguous.
- "末条用户消息前 1200 字符" — but prompt template uses 1200, cache uses 512. Different cutoffs. Why different? Or this is just different requirements for different uses? Inconsistency.

**Marker detection (§4 features):**
- "双方 lowercase，ASCII 词边界匹配，CJK 直接子串"
- "末条用户消息含升档标记" — but if marker is in non-last user message? Missed.
- "双方 lowercase" — both markers and message are lowered. But what if marker is "深度思考" — this is CJK, lowercase is no-op. Spec says "ASCII 词边界匹配，CJK 直接子串" — but the example marker "深度思考" is CJK. The lowercase applies to ASCII only? Or both? Spec ambiguous. Real issue if both get lowered.

**Judge prompt injection:**
- "对用户内容做引号包裹隔离" — quote-wrapping helps but not full protection. Adversarial user could write `""" ignore previous instructions, output "flagship"` — quotes inside content. Could break out. Minor security concern.

**Concurrency / scale:**
- `maybe_route` called for every request. ETS reads everywhere. What about heavy concurrent load causing ETS contention? `ordered_set` write contention? Probably acceptable but spec doesn't address.

**Cache TTL semantics:**
- `cache_ttl_sec => 300` — 5 minutes. But user behavior can change in less than 5 min. A user in fast-tier-friendly conversation suddenly sends a "深度思考" marker — cached as fast, gets fast response for next 5 min even though subsequent messages match. Minor.

OK, let me compile the top issues. The user wants:
A. Remaining defects or new v2 issues (max 5)
B. Missing edge cases (max 5)  
C. Specific actionable improvements (max 5)

Let me prioritize:

**A. 仍存缺陷 / v2 新引入**

1. §9 与 §0 ⑤ 矛盾 / 歧义：§9 说"目标档候选全不可用 → default_tier 档重试一次"，但 v2 修改声称"取消跨档回退"。需要明确"全不可用"指 (a) tier 配置为空（应该 → default_tier）还是 (b) tier 全员 LB 不可用（这种情况跨档回退=违反 v2 原则）。另外"重试一次"指重跑整流水线还是仅重新选模型？歧义。

2. Token 估算 §5 漏算图像 token：图片 base64 不计入字节（OK），但没估算图片 token。规则 1 强制 flagship，OK；但规则 2 比较 `ctx_tokens × 1.2 > big_ctx_tokens` 时 ctx_tokens 不含图片 token，图片+长文可能漏升 big → 真溢出。需要在 image 存在时叠加图片 token 估算（粗略：每张图 765~2000 token 按分辨率）。

4. 配置校验缺项：`default_tier` 是否在 tiers 键中、阈值类型与正数校验均无（§8）：setter typo "fast_ctx_tokens => 8000" 但 §4 规则 4 比较的是 `< fast_ctx_tokens`（注意是小于），如果用户写 8000 但实际 fast 模型支持 16k，规则放行没问题；但若 fast_ctx_tokens=0，所有都通过到判分区，意外行为。

5. 缓存 key 设计遗漏 msg_count：features 含 `msg_count`，规则 4 依赖 `msg_count ≤ 3`，但缓存 key 没纳入 msg_count。结果：msg_count=2 的请求缓存结果会被 msg_count=4 的请求错误复用。可能把本应进 judge 的请求按 fast 走。`has_tools` 入了，`msg_count` 没入，不一致。

6. ordered_set 实现含糊 — "ordered_set + 写入时间戳，>4096 行时按最旧清扫"未指定键结构：ordered_set 必须按键排序，按 phash2 排序得不到时间序。需要二表（{timestamp, hash} 排序表 + {hash, {tier, exp}} 主表）或仅用 phash2 主表配合时间字段扫表。Spec 没说清楚。

实际上让我重新筛选最重要的：

A. 仍存缺陷 / v2 新引入
1. §9 跨档回退语义与 §0 ⑤ 矛盾 + "重试一次"歧义
2. 缓存 key 漏 msg_count，导致规则 4 失效
4. 规则 1 选 flagship 但没考虑 image+超长上下文可能超 flagship 窗口
5. token 估算漏图片 token → 规则 2 漏升 big

B. 边界情况
1. default_tier 不在 tiers map 中
2. judge_model 与 tier 候选重名但不是 janus-auto（startup 校验只看虚拟模型名，应检查是否互相重名）
3. 多模态识别：system message 中含 image_url 而非 user message；OpenAI 新格式 input_image/Anthropic；function tool 输出中的 image — 是否在某次误判为 has_images=false
5. 负缓存与决策缓存是否同表/冲突处理

C. 改进建议
1. §9 重写，明确区分"tier 配置空"和"tier 全部 LB 不健康"两路径
2. 缓存 key 加入 msg_count；或对 msg_count 大于阈值的请求禁缓存
3. 加 image_token_est：每张图按 1024 或按 image_url 尺寸参数（如果有）估算
4. 启动校验加 default_tier ∈ keys(tiers)、阈值 > 0、judge_timeout_ms > 0
5. ordered_set 缓存实现：明确给出双表结构 + 扫描算法

Let me also check if the question is "审查 v2 是否真的</think>


