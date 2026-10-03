# Review v2.1 by minimax-m3 (MiniMax-M3)

_81.0s · completion_tokens=4000_

<think>The user is asking me to do a third-round review of the v2.1 design specification for "Janus Auto Router". They've explicitly stated that the previous two rounds' key issues (cache bypass rule gate, judge process/DOWN message leakage, Chinese token underestimation, cross-tier fallback, self-reference, hard conclusion degradation, parsing ambiguity, cleanup structure) were all claimed to be fixed in v2.1.

My task is to strictly review:
A. Still-existing defects or v2.1 newly introduced issues
B. Missed edge cases
C. Specific executable improvement suggestions

Standard: Only issues affecting correctness, safety, usability, cost count as defects. Style preferences, wording, hypothetical extreme scenarios don't count.

Output: Each section max 5 items, in Chinese.

If no substantive issues, output PASS with brief reasoning.

Let me carefully read through the v2.1 spec looking for real issues:

**§2.1 网关对 provider 世界零假设**
- judge 由用户指派，没有默认值；档位模型列表由用户指派 — OK
- 未指派 judge ⇒ rules-only — OK
- judge 失败 ⇒ 降级 rules-only 行为 — OK

**§2.2 授权模型**
- agent key 默认可访问所有模型 — OK
- api_key_models 只对客户端请求的原始模型名生效 — OK
- 这是 §2.2 的关键设计选择：key 通过虚拟模型可触达白名单之外的模型

**§2.3 路由器自身永不制造 5xx**
- 整体 try/catch — OK

**§3 请求流水线**
- ① 名字精确匹配 — OK
- ② features(ReqMap) — OK
- ③ 规则门 → {tier, hard} 或进入判分区 — OK
- ④ 判分区 — OK
- ⑤ tier → 目标模型名 — OK

Wait — 规则结论永不读写缓存（第③步）。这是 N2/N-? 修复。但等等：判分区的规则是缓存判分结果。如果规则门命中 hard tier 直接走，没有缓存。但判分区会读决策缓存（300s）。这里需要确认：规则门 hard 命中会进入判分区吗？不会，因为 hard 命中直接结束。但等等，规则门 hard 是 "返回 {tier, hard}"，这意味着它直接跳到第⑤步，不进入判分区。OK。

但是 soft tier 在判分区里走，可能命中决策缓存。这是设计选择。

**§4 特征提取**

- prompt_est：ASCII 字节数 ÷ 4；其余全部码点 ×1.5
  - 这是一个估算方法。但 "其余全部码点（CJK、韩文、emoji、一切非 ASCII）按码点数 × 1.5" — 这里有个细节：对于一个 CJK 字符，它的 UTF-8 编码是 3 字节，phash2 是码点数 × 1.5 = 1.5 tokens。实际 CJK token 通常是 1-2 tokens per character，平均约 1.5。所以估算 OK。
  - 但 ASCII 字节 ÷ 4 = 字节/4 tokens（这是 GPT 系的 BPE 估算），而 CJK ×1.5 是按码点数。这两个分母不同，是不是要小心？对于一个混合的 prompt：
    - "hello 世界" — 5 ASCII 字节 = 1.25 tokens，2 CJK 码点 = 3 tokens，总 4.25 tokens
    - 实际可能是 2 (hello) + 2-4 (世界) = 4-6 tokens。看起来 OK。
  - 但是 — 在 prompt_est 的描述里说 "分段估算" — 这意味着要把字符串拆分为 ASCII 段和非 ASCII 段分别估算。这是一个合理的算法。

- tools_est：JSON 编码后的字节 ÷ 4 — 简化估算
- max_out：max_completion_tokens ?? max_tokens ?? 4096

- has_multimodal：任一 message 的 content parts 中存在 type 非纯文本的 part — 好的检测

- has_tools：请求含非空 tools 列表 — OK

- marker_hit：末条 user 消息文本（拼接其全部文本 part）含标记
  - 双方 lowercase
  - ASCII 标记做词边界匹配
  - CJK 标记直接子串
  - "don't think harder" 反例 — 这是一个 word boundary 测试

等等，这里有个问题：marker_hit 是基于末条 user 消息。但有些用例里，用户可能把标记放在 system 消息或更早的 user 消息里？设计选择 — 文档说"末条"，是显式约束。

但还有一个问题：末条 user 消息不一定存在。如果只有 system 消息 + assistant 消息呢？`has_tools` 等会怎样处理？

**§4.2 规则门**

优先级：
1. has_multimodal → flagship hard
2. marker_hit → flagship hard
3. (prompt_est + tools_est) × 1.2 > big_ctx_tokens → big hard
4. est_total > max_ctx_tokens → 400 hard
5. not has_tools 且 prompt_est < fast_ctx_tokens 且 msg_count ≤ 3 → fast hard
6. 其余 → 判分区 soft

问题：
- 第 3 条规则：当容量超过 big 阈值时路由到 big。但如果请求同时含 multimodal（规则 1），会先匹配 multimodal → flagship。第 3 条只对纯文本/工具请求生效。OK。

- 第 5 条：当 prompt < fast_ctx_tokens 且 msg_count ≤ 3 且没工具时 → fast。但如果这是一个 deep reasoning 请求，用户没有标记，但 message 很短但确实需要深度思考？这就是为什么有判分区。但等等 — 判分区只在规则 6 (其余) 才进入。如果请求是单条 user "帮我深度分析这个问题"，prompt 短，没工具，msg_count = 2（系统+用户），会被规则 5 直接路由到 fast，没有判分！这可能是个问题。

等等，让我再读规则 5：
- not has_tools AND prompt_est < fast_ctx_tokens AND msg_count ≤ 3 → fast hard

这意味着短对话无工具的请求直接被路由到 fast，没有机会通过 judge 评估。这可能是个设计缺陷：对于短的、但需要深度思考的请求，会被强制路由到 fast。

但是文档说 "hard/soft 区分是 N2 的修复核心：规则门结论是硬约束（容量/模态/显式意图），其目标档不可用时不允许降级到 default_tier——直接 no_route"。规则 5 是 hard。它将 fast 视为短对话的硬约束。

这个设计的隐含假设是：fast = 短对话 = 浅任务。但实际上：
- 一个 100 字 prompt "写一个 Python 装饰器实现 LRU cache" — 短、无工具、单轮 — 规则 5 命中 fast
- 但这显然不是 fast 模型擅长的事

这是一个实质问题：规则 5 缺乏对任务复杂度的判断，仅依赖长度/工具/消息数。这会让大量短但复杂的请求错误路由到 fast。

但这是设计选择 vs 缺陷？这是 N2 修复的副作用 — 之前可能默认 tier（fast 或 big），现在规则 hard 强制 fast。在 v2 之前，可能这条规则是 soft？让我看一下 N2 的描述："规则硬结论失败 → 直接 404；仅 judge 结论允许降级 default_tier"。所以 v2.1 把所有规则门结论都视为 hard，包括规则 5。

这看起来是一个实质缺陷：规则 5 把 fast 当作短对话的硬默认，但短对话 ≠ 简单任务。这会导致成本问题（用户为 fast 付费但获得低质量回答）或正确性问题（任务不匹配模型能力）。

可能的修复：让规则 5 也是 soft（允许 judge 评估），或者引入复杂度启发式（比如代码关键词、数学关键词等）。

不过这是一个设计权衡，文档明确选择 hard。让我先标记，再看是否有更严重的问题。

- 第 4 条：est_total > max_ctx_tokens → 400 hard。这是 max_ctx_tokens 启用时才有意义。

- est_total 计算用的是 max_out（包括默认值 4096）。如果 max_out 默认是 4096，那么一个 100 字符 prompt + 0 tools + 4096 max_out = 4200 tokens。对于 fast_ctx_tokens = 8000 来说 < 8000，没问题。但对于 max_ctx_tokens 如果用户配置为 4000（比 4096 小），会拒绝！

等等，这是个微妙的问题：max_out 默认 4096，如果用户配置 max_ctx_tokens < 4096，那么几乎所有请求都会被 400。这是个配置陷阱。文档应该在配置校验里提示 max_ctx_tokens 必须 ≥ 默认 max_out (4096)。

**§5 决策缓存**

双表结构：
- 主 set：{Hash => {Tier, ExpiresAt}}
- 辅 ordered_set：{{Seq, Hash} => ok}

写入两表同笔；容量 >4096 时从辅表头部（最旧）取出条目检查过期并双表删除，单次清扫至多处理 128 条

OK，这是合理的。

Key：`erlang:phash2({SysPrefix, LastUserPrefix, ToolsFp, HasMM, prompt_est_bucket}, 268435456)`

- HasMM：has_multimodal（防御性冗余，规则门先行使其实际恒为 false）
  - 为什么是"实际恒为 false"？因为缓存只在判分区用，判分区只有规则 6 进入（即 not has_multimodal），所以 HasMM 恒为 false。这是一个"防御性冗余"，OK。

- 缓存 key 是 judge 输入的子集摘要
  - "不同输入可能共享结论（近似复用），这是设计选择而非缺陷"
  - 这是一个设计选择，OK。

但等等：prompt_est_bucket 是 prompt_est div 4096。这意味着 prompt_est 变化 < 4096 tokens 不会改变 cache key。这是个大问题：如果 prompt 长度变化小于 4096（比如 5000 vs 5500 tokens），会共享 cache 结论。但实际上 prompt 长度的微小变化通常不影响任务复杂度判断，所以这是 OK 的设计选择。

不过问题是：phash2 域 2^28 = 268435456，容量 4096 时碰撞概率 ~3e-5（生日悖论）。这是 OK 的。

**§6 Judge**

输入与请求 — OK
执行 — OK
并发信号量 — OK
负缓存 — OK
熔断：
- 连败计数只累计实际发起的 judge 调用的失败
- 负缓存命中与信号量跳过既不计入也不清零
- 连续 5 次失败 → 熔断 60s
- 任一次成功清零
- 熔断状态按 judge_model 名分别维护

等等，"任一次成功清零"：当熔断期间，是否有请求能成功调用 judge？熔断开启 → 所有 judge 调用 → default_tier。如果一次熔断开启，那 60s 内不会有 judge 调用，也就没有成功可清零。60s 后熔断关闭，下次调用 judge。如果成功 → 清零。如果失败 → 又开始计数。这是合理的。

但是有一个细节：当熔断开启后，如果用户修改 judge_model 配置，新 judge_model 状态空间独立（修中优先项），那原有的失败计数仍存在于旧 judge_model 的状态中，但永远不会再被访问。这是一点点内存浪费，但不严重。

**§6.3 解析**

取输出最后一个非空行，按空白切词，取其中首个命中白名单的词；该行无命中则回退对全文首个独立白名单词；仍无 → 解析失败。

等等：测试用例 "valid outputs: fast big flagship" — 文档描述："应取末行规则失败后回退 fast？——用例：输出末行无白名单词 + 全文首个=fast 场景"。

这看起来是文档在自问自答 — 用例模糊。实际测试用例应该是：输出 = "valid outputs: fast big flagship\nfast"，最后一非空行 = "fast"，OK。但如果输出 = "valid outputs: fast big flagship"（无换行），最后一非空行 = "valid outputs: fast big flagship"，按空白切词 = ["valid", "outputs:", "fast", "big", "flagship"]，首个白名单词 = fast。OK，回退段不触发。

但如果有这样输出："I think the answer is big, not flagship."（单行）— 按空白切词 = ["I", "think", "the", "answer", "is", "big,", "not", "flagship."]。注意 "big," 包含逗号！按"全词小写比较"，"big," != "big"，匹配失败。然后 "flagship." != "flagship"，匹配失败。回退段也无命中（因为 "big," 和 "flagship." 都不匹配）。等等，回退段是对"全文首个独立白名单词" — 但全文没有"fast"或"big"或"flagship"作为独立词。所以解析失败。

这是一个潜在问题：标点符号紧贴白名单词。文档说"全词小写比较" — 但"全词"如何定义？是不是按空白切词后做严格字符串比较？这需要更明确的定义。

如果"全词" = 严格字符串匹配（按空白切词后），那 "big," != "big"，匹配失败。如果"全词" = 在空白切词的 token 里去掉标点再比，那 "big," → "big"，匹配成功。

文档不够明确。这是一个实现模糊点，可能影响正确性。

**§7 配置**

启动校验：
- judge_model 或任一 tier 候选 == 虚拟模型名 ⇒ error 日志 + 该项视为未配置
- default_tier ∉ keys(tiers) ⇒ error + 回退 rules-only
- big_ctx_tokens / fast_ctx_tokens / judge_timeout_ms / cache_ttl_sec 非正数 ⇒ error + 默认值
- judge_max_inflight < 1 ⇒ error + 默认值
- tier 候选不在 catalog ⇒ warn
- 整档为空且可能被规则命中 ⇒ error
- api_key_models 白名单含虚拟名 ⇒ warn

Tier 解析：
1. 规则 hard 结论的目标档：候选按序取 catalog 中在售且 LB 可选的首个；全部不可用 → {error, no_route}
2. 判分区 soft 结论的目标档：同上；全部不可用 → default_tier 档再试一次；仍不可用 → {error, no_route}

等等！让我仔细看：tier 解析规则 1 和 2 都是"候选按序取 catalog 中在售且 LB 可选的首个"。但 §3 流水线里的 ⑤ 是 "tier → 目标模型名"，目标模型名是单一 model 名。这是怎么做的？

§7 没说清楚：是返回 tier 名还是实际 model 名？让我看 §3：
- ⑤ tier → 目标模型名（§8 解析规则，返回值式失败）
- {ok, Target} → 改写 body.model

所以 Target 应该是实际 model 名（字符串）。那 tier 是 fast / big / flagship，target 是该 tier 列表中的某个具体 model。

OK，那 §7 tier 解析规则说的"候选按序取"是 tier 列表中按配置的顺序。这合理。

但是 — 等等，hard 结论的目标档不可用时怎么办？规则 1：hard 直接 no_route。但是规则 1 的目标是 flagship。flagship 不可用时直接 404，即使有 default_tier (fast) 可用。这是 hard 不降级。

但是！这有个潜在问题：假设 markers 配置了，但 flagship 档配置为空或全部不可用，且 default_tier 是 fast。带 marker 的请求会被路由到 flagship，但 flagship 不可用 → 404。即使 fast 可用。这是 hard 的设计选择。

但是从用户角度看：用户配置了 marker，希望触发深度思考。如果 flagship 挂了，希望 fall back 到 big，而不是 404。这是可用性 vs 设计纯洁性的权衡。

不过这是设计选择 — N2 明确这个权衡。OK。

**§8 失败语义**

OK，看起来全面。

**§9 观测**
- ETS 计数器：每 tier 路由数、judge 成功/失败/超时数、熔断触发次数、信号量跳过数、no_route 次数
- "每 tier 路由数" — 等等，如果出现 hard no_route，那没有"路由数"？或者 no_route 单独算？这点文档不清。但从观测的角度看，no_route 单独列出应该就 OK 了。

**§10 隐私**

OK。

**§11 测试计划**

包含：
- judge 解析："not flagship, big" 反例
  - 等等，按 §6.3 解析规则：末非空行 = "not flagship, big"，按空白切词 = ["not", "flagship,", "big"]。首个白名单词 — "flagship," != "flagship"，"big" == "big"，匹配 → big。OK。

- "don't think harder" 反例 — 这是 marker 词边界测试。marker "think harder" 是 ASCII 词边界匹配。"don't think harder" — 单词 "think" 和 "harder" 是独立词，词边界匹配命中。

等等，这里有个 bug！如果用户写 "I don't think harder is a good idea"，词边界匹配 "think harder" — 但实际意图是不想用 think harder。这是 false positive。但这是 marker 设计的固有问题（用户用引号绕过），不算 router 的缺陷。

**§12 Roadmap**

OK。

现在让我整理一下我发现的实质问题：

**A. 仍然存在的缺陷或 v2.1 新引入的问题**

1. **规则 5 强制 fast 的设计过于激进** — 短对话无工具不一定 = 简单任务，会让大量短但需要深度思考的请求错误路由到 fast，且无判分机会。这是 N2 修复（hard 不降级）的一个副作用。

2. **max_ctx_tokens 配置陷阱** — 默认 max_out = 4096，如果用户配置 max_ctx_tokens < 4096，几乎所有请求都会被 400。启动校验应强制 max_ctx_tokens ≥ 4096（或文档明确说明）。

3. **§6.3 "全词"定义模糊** — "big,"（带逗号）是否匹配 "big"？文档未明确。这影响解析正确性。测试用例 "not flagship, big" 是个边界，但 "big,"（逗号紧贴）如何处理？

4. **§5 缓存 key 域 2^28 但容量只 4096，碰撞率 ~3e-5 实际偏高** — 等下，让我重算。生日攻击：n=4096, m=2^28=268M。碰撞概率 ≈ 1 - exp(-n^2/(2m)) ≈ n^2/(2m) ≈ 4096^2 / (2 × 268435456) ≈ 16777216 / 536870912 ≈ 0.031 = 3.1%。文档说 ~3</think>


