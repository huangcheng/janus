# Review v2.3 by step-5-preview (step-5-preview)

_60.5s · completion_tokens=4000_

用户要求我作为资深分布式系统与 LLM 基础设施工程师，对 `Janus Auto Router` 设计规格 v2.3 进行第五轮评审。

历史背景：
- 前两轮的关键缺陷已在 v2.3 声称修复。
- 需要严格审查：A. 仍然存在的缺陷或 v2.1/v2.3 新引入的问题；B. 遗漏的边界情况；C. 具体可执行的改进建议。
- 判定标准：只有影响正确性、安全性、可用性、成本的问题才算缺陷。风格偏好、措辞、假想的极端场景不计为问题。
- 如果没有实质问题，明确输出 PASS。
- 每部分最多 5 条，用中文。

我需要仔细阅读 v2.3 文档，找出真正影响系统的缺陷。

文档结构：
1. 目标/非目标
2. 核心原则
3. 请求流水线
4. 特征提取与规则门
5. 决策缓存
6. Judge
7. 配置
8. 失败语义总表
9. 观测
10. 隐私
11. 测试计划
12. Roadmap

让我逐节分析可能的问题：

**规则 0 和 3b 交互 / 容量防线**
- 规则 0: `est_total > max_ctx_tokens` → 400，仅当配置了该上限。
- 规则 3: `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` → big
- 规则 3b: `est_total > big_ctx_tokens` → flagship
- 规则 4: `not has_tools` 且 `est_total < fast_ctx_tokens` 且 `msg_count <= 3` → fast (定向 hard，可用性 soft)

问题：
- 规则 4 说"定向 hard / 可用性 soft"。如果 fast 档不可用，降级到 default_tier。但 default_tier 是 `fast`（见 §7 配置）。如果 fast 档不可用，降级到 default_tier 也是 fast，然后会再次失败。文档说"fast 档不可用时按 soft 语义降级 default_tier（成本偏好不是可用性硬约束）"，但如果 default_tier 就是 fast，那降级无意义。不过 §8 说"规则 4 fast 档不可用 | 按 soft 语义降级 default_tier → 仍败则 no_route"，这逻辑上没错，但如果 default_tier=fast 且 fast 档列表为空或全不可用，那么会 no_route。这合理吗？规则 4 是"定向 hard"，意味着正常时直接落 fast，不降级到 default_tier；但可用性是 soft 的，所以如果 fast 不可用，降级到 default_tier。这个逻辑本身没问题。但如果 default_tier=fast 且 fast 档为空，那么 soft 判断下 tiers 配置启动校验会报错吗？§7 说"整档为空且可能被规则命中 ⇒ error（一次性）"。所以如果 fast 整档为空，启动就会报错。那如果 fast 有配置但全部不可用（运行时），降级到 default_tier=fast 又失败，最终 no_route。这是可接受的。

**规则 3 和 3b 的数学关系**
- 规则 3: `(prompt + tools) * 1.2 > big_ctx` → big
- 规则 3b: `(prompt + tools + media + max_out) > big_ctx` → flagship
- 如果 `max_out` 很大，est_total 很容易超过 big_ctx。比如 prompt+tools=50k, max_out=10k, big_ctx=60k, est_total=60k+，规则3不触发（50k*1.2=60k 不大于 60k），规则3b触发（60k+ > 60k）→ flagship。合理。
- 但注意规则 3 是 `>` 规则 3b 也是 `>`。优先级上 3 在 3b 前。如果 est_total > big_ctx 但 (prompt+tools)*1.2 <= big_ctx，会走 3b → flagship。这是 v2.3 修复的内容。

**marker_hit 降级问题**
- 规则 2: marker_hit → flagship，hard。如果 flagship 档不可用 → `{error, no_route}`，不降级。这是明确的。

**判分区和 default_tier 循环**
- 判分区（soft）不可用时降级到 default_tier。如果 default_tier 档也不可用 → no_route。这合理。

**缓存 Key 和 SysPrefix**
- `SysPrefix`: system 前 256 字符。
- `LastUserPrefix`: user 前 1200 字符。
- `ToolsFp`: full phash2。
- Key 是子集摘要。不同输入可能共享结论。文档说这是设计选择。
- 但 `sys_prefix` 只取前 256，如果 system 很长但后面不同，可能碰撞。文档说这是近似复用。作为缓存，这是可接受的，因为 judge 输入也只取了前 256+1200。所以没问题。

**媒体预算和 est_total**
- `media_allowance = 非文本 part 数 × media_token_allowance`（默认 4096）。
- 问题：如果一个请求有 100 个图片 parts，est_total 会 +400k。这会触发规则 3b → flagship。但真实的图片 token 数可能远小于 4096，或者因 provider 而异。文档说"零假设下的粗粒度媒体预算，宁可高估触发上限，不做 provider 级精确计费"。这会导致大量多模态请求被推到旗舰（成本），但这是设计取舍，且规则 1 `has_multimodal` 直接 flagship，所以这个高估只是影响规则 0/3b。对于规则 0，可能过早触发 400。例如 max_ctx_tokens=128000，prompt=1000，max_out=4096，10 张图 → est_total=1000+40960+4096=46056，远不到 128k。只有大量图片才会。这个"零假设"高估虽然粗糙，但不会造成正确性问题，只是可用性/成本。不过规则 1 已经把所有多模态都 hard 到 flagship 了，所以 `media_allowance` 只在没有多模态时... 等等，`has_multimodal` 定义是"任一 message content parts 中存在 type 非纯文本的 part"。所以只要有图片，has_multimodal=true，规则 1 直接 flagship。那 media_allowance 在规则 0/3b 中的作用是什么？规则 0 先于一切。如果 est_total > max_ctx_tokens，即使 has_multimodal 也会直接 400。所以 media_allowance 影响的是：没有多模态时？不，没有多模态时 media_allowance=0。它影响的是：已经触发规则 1 的请求是否被规则 0 拦截。这是合理的，因为硬上限必须对所有请求生效。但"非文本 part 数 × 4096"可能严重高估真实 token 消耗，导致某些大上下文多模态请求被过早 400。这是可用性问题。例如 10 张图真实 10k token，但预算 40k，可能把请求从 big 推到 flagship 或触发 400。但规则 1 已经所有多模态都到旗舰了，所以不会从 big 推到旗舰。唯一影响是触发 400 的阈值。例如 max_ctx=128000，prompt+tools+text=100k，2 张图真实 2k，总 102k < 128k，但 est_total=100k+8k+4k=112k，还是 <128k。只有图片很多或 max_out 很大时才可能。这不是缺陷，是 documented tradeoff。

**max_out 默认值**
- `max_out` 默认 4096。如果用户没设置，假设 4096。这合理。

**规则 4 和判分区**
- 短请求（无 tools，est_total < fast_ctx，msg<=3）直接 fast，不进判分区。
- 文档说这是成本取舍。

**规则 3b 和 4 的顺序**
- 规则 3b 在规则 4 前。所以如果 est_total > big_ctx，直接 flagship（hard），不会走 fast。即使 msg_count<=3 且 not has_tools。这是正确的，因为 est_total > big_ctx 意味着总窗口超出 big，必须 flagship。

**配置校验**
- `max_ctx_tokens` 已配置但 < `big_ctx_tokens` ⇒ error + 忽略该上限。合理。
- 但 `max_ctx_tokens` 未配置时，容量防线由规则 3 + 3b + 部署者保证 flagship ≥ big 构成。这意味着如果部署者没配 max_ctx_tokens，一个 prompt=1000, max_out=100000 的请求，est_total=104k > big_ctx(60k)，规则 3b → flagship。然后如果 flagship 实际窗口只有 32k，会溢出。文档说"部署者保证的 flagship ≥ big"，但没说保证 flagship ≥ max_out。不过 big_ctx_tokens 语义为总窗口（prompt+tools+output），所以如果 big_ctx=60k，那么 est_total>60k 就上旗舰，旗舰窗口必须 >= 部署者配置的 big_ctx 才能容纳规则 3b 的请求？等等，规则 3b 只是路由，实际转发后如果旗舰窗口 < est_total，上游会报错。文档 §4.2 注："flagship 窗口由部署者保证 ≥ big"。这句话可以解读为：部署者要保证旗舰实际能处理 >big_ctx 的请求。所以这不是设计缺陷，而是把责任交给部署者。

**judge worker 和配置切换竞态**
- 文档说 worker 启动时快照 judge_model，回写丢弃不一致。这很好。

**judge 解析反例**
- 测试计划说："复述指令反例（'valid outputs: fast big flagship' 应取末行规则失败后回退 fast？——用例：输出末行无白名单词 + 全文首个=fast 场景）"
- 解析规则：取最后一个非空行，按空白切词，取首个命中白名单的词；该行无命中则回退对全文首个独立白名单词。
- 如果模型输出："The valid outputs are: fast, big, flagship." 最后一行没有 fast/big/flagship？等等，"fast, big, flagship" 这一行含有它们。按空白切词，"fast," 带逗号，算白名单词吗？"全词小写比较"，"fast," != "fast"。所以不算。全词匹配要求切词后精确等于。这个解析器是否有逗号边界问题？测试计划明确提到"复述指令反例"，说明他们意识到了。但文档没有说如何处理标点。Erlang 实现时需要确保标点被剥离。如果实现用 `string:tokens` 或空白切割，"fast," != "fast"。这可能是一个解析缺陷。测试计划说"应取末行规则失败后回退 fast？"，实际上如果末行是 "Valid outputs: fast big flagship"，切词后是 ["Valid", "outputs:", "fast", "big", "flagship"]，那么"fast"是独立词，会命中。测试用例写的是"复述指令反例"可能指模型输出指令内容。这更多是实现细节，不一定算设计缺陷。

**HTTP handler 对 error 的映射**
- `{error, request_too_large}` → 400
- `{error, no_route}` → 404
- `pass` → 普通模型处理

**error 体格式**
- 400 体定义了。
- 404 体？文档说"注明 auto-router tier unconfigured/unavailable，与普通 model_not_found 区分"。但没有给出具体 JSON 格式。这是遗漏吗？§8 说"错误体均注明..."。这算轻微遗漏，但不影响正确性/安全性/可用性/成本，只是措辞/格式细节。

**缓存幽灵命中**
- 修复了 judge_model 不匹配即 miss。

**规则 4 fast 可用性 soft**
- 如果 fast 档不可用，降级 default_tier。但如果默认 default_tier 就是 fast，且 fast 档列表为空，启动校验会 error 并回退 rules-only。如果 default_tier 是 big，那 fast 不可用 → big。这合理。

**决策缓存容量和 key 安全**
- key 用 phash2，域 2^28，容量 4096。碰撞概率 3e-5。接受。
- 但是 phash2 是基于 Erlang term 的 phash。不同 term 可能相同 hash。这不只是缓存误命中，而是不同请求 key 碰撞。但概率低。可以接受。

**est_total 计算**
- prompt_est: ASCII 字节数/4，其余码点数 × 1.5。这是估算。常见做法是英文~4 token/word，中文~1 token/char。1.5 倍偏高但安全。没问题。

**rules-only 和 default_tier**
- 未指派 judge → default_tier（soft）。
- 如果 default_tier 不可用 → no_route？§6.1 流程：未指派 judge → default_tier（soft）。然后 tier → 目标模型名。default_tier 不可用时按 soft 语义应降级... 等等，default_tier 是默认档，如果它不可用，doc §8 说"soft 档不可用 | default_tier 档重试 → 仍败则 no_route"。但对于"未指派 judge → default_tier"这个判断，它已经是 soft 了，如果 default_tier 不可用，就 no_route 吗？§3 流程写"未指派 judge → default_tier（soft）"，然后⑤ tier → 目标模型名（§8 解析规则，返回值式失败）。§8 解析规则 2 说 soft 结论全部不可用 → default_tier 档再试一次；仍不可用 → no_route。但如果判定本身就是 default_tier，那么再试一次还是 default_tier，仍失败则 no_route。逻辑一致。

**启动校验的时机**
- "启动/首次读取校验（结果缓存；配置变更时以配置指纹重算）" —— 这意味着校验是懒执行的，不是启动时。文档说"启动/首次读取校验"，可以理解为首次读取时。这没问题。

**规则 3b 与 max_out**
- est_total 包含 max_out。规则 3b: est_total > big_ctx → flagship。max_out 默认 4096。big_ctx 默认 60000。如果 prompt 55k, max_out 4096, est_total 59k < 60k，走 big。prompt 57k, max_out 4096, est_total 61k > 60k，走 flagship。实际请求 57k prompt + 4k output = 61k，如果 big 窗口 60k，确实装不下。正确。

**规则 3 与 max_out**
- 规则 3: (prompt + tools) * 1.2 > big_ctx → big。不包含 max_out。这意味着 prompt=45k, tools=5k, (50k)*1.2=60k，不触发规则3（这里假设 big_ctx=60k，条件是 >）。est_total=50k+4k+5k? 不，prompt+tools=50k，est_total=50k+max_out(4k)+media(0)=54k < 60k。如果 prompt=46k, tools=0, (46k)*1.2=55.2k < 60k，但 est_total=46k+4k=50k <60k。规则 3 的 ×1.2 余量是为了应对 prompt 估算误差，不放大 max_out。这很合理。

**潜在缺陷：规则 4 的 hard/soft 语义与 no_route**
- 规则 4 是"定向 hard / 可用性 soft"。正常时 fast；fast 不可用 → default_tier。
- 但如果 fast 可用，但 est_total 其实只比 fast_ctx 小一点点，而 big 档可用，为什么不降级到 big？因为规则 4 是 hard 定向 fast。可用性是 soft 的，意味着我们不因为 fast 不在而 no_route，但也不会因为"big 更适合"而降级。合理。

**潜在缺陷：多模态规则 1 和规则 0 的顺序**
- 规则 0 先于一切。如果一个多模态请求 est_total > max_ctx_tokens，返回 400 而不是路由到 flagship。这正确，因为硬上限必须生效。但注意规则 1 has_multimodal → flagship，不会到规则 0？不，§4.2 说规则 0"先于一切路由规则"。所以多模态超限 → 400。这是正确的。

**规则 3b 的 "flagship 窗口由部署者保证 ≥ big"**
- 如果 big_ctx_tokens 配置为 60k，flagship 实际上下文 32k。est_total=65k > 60k → flagship。上游溢出。文档把责任推给部署者。这算缺陷吗？系统设计应该尽量防止错误配置导致运行时失败。但文档 §7 有启动校验：`max_ctx_tokens` < `big_ctx_tokens` 报错，但没有校验旗舰实际窗口。因为 Janus 不知道模型窗口。所以只能依赖配置。可接受。

**观测和 stats**
- ETS 计数器在单节点。多节点 stats 不聚合。但文档说多节点各自独立，跨节点差异仅影响成本分布。所以 stats 单节点没问题。

**隐私**
- judge 调用会发送前缀内容。文档明确声明。没问题。

**配置变更竞态**
- judge_model 换配置时，熔断状态按名分别维护。旧 worker 回写丢弃。很好。

**
