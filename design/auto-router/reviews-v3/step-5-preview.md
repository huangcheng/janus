# Review v2.1 by step-5-preview (step-5-preview)

_55.9s · completion_tokens=4000_

用户要求我作为资深分布式系统与LLM基础设施工程师，对一份名为"Janus Auto Router — 设计规格 v2.1"的设计文档进行第三轮评审。前两轮的关键缺陷声称已在v2.1全部修复。

我需要严格审查：
A. 仍然存在的缺陷或 v2.1 新引入的问题；
B. 遗漏的边界情况；
C. 具体可执行的改进建议。

判定标准：只有影响正确性、安全性、可用性、成本的问题才算缺陷；风格偏好、措辞、假想的极端场景（现实中不会发生或影响可忽略）不计为问题。

每部分最多5条，用中文。

首先，我需要通读并理解整个设计文档。

文档概述：
- Janus Auto Router 是一个虚拟模型，根据请求特征自动路由到 fast/big/flagship 三档真实模型。
- 复用现有 models/routes/LB 结构。
- 核心原则：网关对provider世界零假设；授权模型key是身份不是配额；路由器自身永不制造5xx。

请求流水线：
1. model_allowed检查（对原始名）
2. janus_auto:maybe_route/2，整体try/catch
3. 名字精确匹配（binary全等）
4. features提取
5. 规则门（优先级：多模态>marker>容量>max_ctx>fast规则>判分区）
6. 判分区（judge相关逻辑）
7. tier→目标模型名解析

特征提取：
- prompt_est: ASCII字节÷4，非ASCII按码点×1.5
- tools_est: JSON编码后字节÷4
- max_out: max_completion_tokens ?? max_tokens ?? 4096
- est_total = prompt_est + tools_est + max_out
- has_multimodal: content parts中有非text类型
- has_tools: 非空tools列表
- marker_hit: 末条user消息含标记
- msg_count: messages数组长度

规则门：
1. has_multimodal -> flagship (hard)
2. marker_hit -> flagship (hard)
3. (prompt_est+tools_est)×1.2 > big_ctx_tokens -> big (hard)
4. est_total > max_ctx_tokens -> 400 (hard)
5. not has_tools 且 prompt_est < fast_ctx_tokens 且 msg_count ≤ 3 -> fast (hard)
6. 其余 -> 判分区 (soft)

决策缓存：
- 双表结构：主set + 辅ordered_set
- Key: phash2({SysPrefix, LastUserPrefix, ToolsFp, HasMM, prompt_est_bucket}, 2^28)
- SysPrefix: 所有system消息文本按序拼接取前256字符
- LastUserPrefix: 末条user消息文本前1200字符
- ToolsFp: JSON编码tools的phash2
- HasMM: has_multimodal
- prompt_est_bucket: prompt_est div 4096
- Value: {Tier, ExpiresAt}, TTL 300s
- 容量4096，清扫最多128条

Judge：
- 可选，用户指派
- system指令英文，约120 token，强约束输出格式
- user内容：system前256 + 末条user前1200
- 请求体：max_tokens:200, temperature:0, stream:false
- 执行：spawn_monitor，一次性gun连接，owner即judge worker
- 并发信号量：atomics实现，默认8
- 负缓存：失败特征写30s TTL
- 熔断：按judge_model分状态，连败5次熔断60s，只计实际调用失败
- 解析：取输出最后一个非空行，按空白切词，取首个命中白名单的词；该行无命中则回退全文首个独立白名单词

配置：
- model, judge_model, tiers, default_tier, big_ctx_tokens(60000), fast_ctx_tokens(8000), max_ctx_tokens, judge_timeout_ms(1500), judge_max_inflight(8), cache_ttl_sec(300), markers

启动校验：
- judge_model或tier候选==虚拟模型名 -> error + 视为未配置
- default_tier ∉ keys(tiers) -> error + 回退rules-only
- 数值非正等 -> error + 用默认值
- tier候选不在catalog -> warn
- 整档为空且可能被规则命中 -> error
- 受限key含虚拟名 -> warn

tier解析：
1. hard结论目标档：候选按序取catalog中在售且LB可选的首个；全部不可用 -> {error, no_route}
2. soft结论目标档：同上；全部不可用 -> default_tier再试；仍不可用 -> {error, no_route}
3. 虚拟模型是models表普通一行，无自身routes

失败语义总表：列出了各种场景。

现在我需要寻找缺陷、边界情况、改进建议。

让我仔细思考可能存在的问题：

**A. 仍然存在的缺陷或 v2.1 新引入的问题：**

1. **规则门与缓存交互的语义问题（规则3与est_total）**：
   - 规则3是 `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` → `big` (hard)
   - 规则4是 `est_total > max_ctx_tokens` → 400
   - 如果 big_ctx_tokens 配置为 60000（示例值），而 max_ctx_tokens 未配置。
   - 假设 prompt_est+tools_est = 50000，×1.2=60000，不超过60000，所以不会去big。
   - est_total = 50000 + max_out。如果 max_out 默认4096，est_total=54096。
   - 但是，如果 max_out 很大，比如用户设置 max_completion_tokens=100000，est_total=150000。
   - 如果 max_ctx_tokens 配置了，比如 100000，会触发400。
   - 但是，规则3只乘prompt+tools，不乘max_out。这意味着一个请求有50000的prompt和50000的max_out，est_total=100000+。如果max_ctx_tokens=100000，会400吗？est_total=100000 > 100000? 不，等于。
   - 等等，规则3是决定路由档位的。如果 prompt_est+tools_est=40000，×1.2=48000 < 60000，规则3不触发，进入判分区或fast?
   - 规则5: not has_tools 且 prompt_est < fast_ctx_tokens(8000) 且 msg_count ≤ 3 → fast。所以如果有tools或prompt_est >= 8000，不会去fast，进入判分区。
   - 问题在于：规则3只检查是否超过big_ctx_tokens来决定去big。但如果prompt_est+tools_est 介于 fast_ctx_tokens 和 big_ctx_tokens 之间，且不满足规则5（比如有tools），会进入判分区。judge可能会选择big或fast。如果judge选择fast，但prompt_est > fast_ctx_tokens，这有问题吗？fast_ctx_tokens是总窗口。如果prompt_est > fast_ctx_tokens，请求在fast模型上可能会溢出。但是规则3只在 prompt_est+tools_est > big_ctx_tokens 时才强制去big。也就是说，如果 prompt_est+tools_est 在 fast_ctx_tokens 和 big_ctx_tokens 之间，规则3不触发，请求进入判分区，judge可能选择fast。这似乎是个缺陷？但是judge是软估计，允许降级。而且规则5是hard规则：not has_tools 且 prompt_est < fast_ctx_tokens 且 msg_count ≤ 3 → fast。如果有tools，prompt_est < fast_ctx_tokens，msg_count ≤ 3，会进入判分区而不是fast。然后judge可能选big或flagship，也可能选fast。如果judge选fast，且prompt_est接近fast_ctx_tokens，会不会溢出？这是一个潜在问题，但可能不是严重缺陷，因为fast_ctx_tokens是总窗口，prompt_est<tokens，但加上max_out可能超过。
   
   等等，规则3的语义是：如果 prompt+tools 超过 big_ctx_tokens 的1.2倍，去big。这是强制去big。但如果 prompt+tools 超过 fast_ctx_tokens 但没超过 big_ctx_tokens，规则3不触发。然后规则5要求 prompt_est < fast_ctx_tokens 且 not has_tools 且 msg_count ≤ 3 才去fast。所以如果 prompt_est >= fast_ctx_tokens 或有tools，会进入判分区。判分区可能去fast。这意味着fast可能收到超过其窗口的请求。不过这是"软估计"路径，且judge被设计成会选择合适档位。但严格来说，如果fast_ctx_tokens是总窗口，任何进入fast的请求 est_total 应该 <= fast_ctx_tokens？不，fast_ctx_tokens只是配置阈值，不是硬上限（除了规则5）。
   
   实际上，规则5是唯一确保去fast的hard规则。判分区去fast是soft的，意味着允许。这是设计选择。所以这可能不算缺陷。

2. **max_out 默认值 4096 与规则3的关系**：
   - max_out 默认4096。est_total = prompt_est + tools_est + max_out。
   - 规则3只乘 prompt+tools。规则4比较 est_total 与 max_ctx_tokens。
   - 如果 max_completion_tokens 和 max_tokens 都未设置，max_out=4096。
   - 但是，如果请求的 max_output_tokens（或其他字段名）实际很大，但估算只取4096？不，max_completion_tokens ?? max_tokens ?? 4096。这是请求中用户指定的。如果用户没指定，provider可能有自己的默认值（如模型的最大输出）。但文档说"兼容 max_completion_tokens；缺省 4096"。这意味着Janus假设provider在未指定时也输出最多4096？或者这只是一个安全默认值。这可能导致对实际需求的低估。不过这是有意的估算。

3. **缓存Key的SysPrefix与LastUserPrefix长度不一致问题**：
   - SysPrefix: 所有system消息文本前256字符。
   - LastUserPrefix: 末条user消息文本前1200字符。
   - 在Judge输入中，system也是前256字符，user是前1200字符。所以一致。
   - 但是缓存Key使用SysPrefix和LastUserPrefix的拼接/摘要。如果两个请求有相同的前1200字符但后续不同，它们会共享缓存。文档说这是近似复用，设计选择。没问题。

4. **ordered_set清扫的Seq与Hash问题**：
   - 辅表是 `{{Seq, Hash} => ok}`。
   - Seq是原子递增序号。
   - 当容量>4096时，从辅表头部（最旧）取出条目检查过期并双表删除。
   - 单次清扫至多128条。
   - 问题：如果大量请求涌入，Seq不断增长。ETS的ordered_set键是{Seq, Hash}，这没问题。但是，从辅表"头部"取出最旧条目。如果第1条是过期的，删掉；如果第1条未过期，因为它是"最旧"的，后面的应该都未过期？不对，ETS写入是先写主表再写辅表，或者同笔？ETS没有事务。如果两个进程/请求几乎同时写入，Seq是原子递增的，但主表和辅表的写入顺序可能不同。不过因为是ETS，写入过程可能会交错。但即使如此，头部最旧的Seq对应最早的插入。如果最早的未过期，后面的应该都未过期（因为TTL相同，写入时间差不多）。等等，TTL是从写入时间开始算的。如果最早的未过期，后面的写入时间更晚，过期时间更晚，所以确实都未过期。因此一旦遇到未过期条目就可以停止清扫。这看起来是OK的。但"单次清扫至多处理128条"——如果前128条都过期，删完就停。如果第一条未过期，是不是也应该立即停？文档说"从辅表头部（最旧）取出条目检查过期并双表删除"。如果第一条未过期，是否继续检查第二条？由于ordered_set按Seq排序，如果第一条未过期，最优策略是停止。文档没明确说遇到未过期就停止，但"最旧"逻辑暗示了。不过即使继续检查128条，成本有界，也没问题。

5. **规则门优先级与判分区入口问题**：
   - 规则2: marker_hit -> flagship (hard)。规则3在规则2之后。文档说"marker优先级提到容量规则之前"。
   - 如果marker_hit且has_multimodal，规则1先触发，没问题。
   - 如果marker_hit且prompt_est+tools_est > big_ctx_tokens，规则2先触发，去flagship。这符合"显式用户意图优先于容量规则"。

6. **judge解析的"末行首个独立白名单词"与"回退全文首个"歧义**：
   - Test case提到："复述指令反例（"valid outputs: fast big flagship" 应取末行规则失败后回退 fast？——用例：输出末行无白名单词 + 全文首个=fast 场景）"
   - 如果输出是：
     ```
     Based on the instructions, valid outputs are:
     fast
     big
     flagship
     ```
     末行是flagship，所以解析为flagship。这是对的。
   - 如果输出是：
     ```
     valid outputs: fast big flagship
     ```
     末行（也是唯一行）包含fast, big, flagship。按"首个命中白名单"应该是fast。但文档的测试用例描述似乎有点混乱。让我看测试用例原文："valid outputs: fast big flagship" 应取末行规则失败后回退 fast？——用例：输出末行无白名单词 + 全文首个=fast 场景"
   - 这个描述有点自相矛盾。如果输出就是 "valid outputs: fast big flagship"，末行有白名单词，按规则应该取fast（首个）。不需要回退。测试用例可能是想说另一种情况。但这不是文档内容本身的问题。

7. **系统提示词拼接与隐私**：
   - SysPrefix: 所有system消息文本按序拼接。如果system消息很多，只取前256字符。
   - 在Judge输入中，system也是前256字符。
   - 隐私声明说judge发送system前256+user前1200。一致。

8. **连接语义与异常处理**：
   - judge worker 中 `gun:open(一次性连接, owner=本进程)`。如果 `gun:open` 本身失败（比如连接被拒），在worker中如果没有catch，worker会崩溃。那么caller收到'DOWN'消息，进入失败路径。这没问题。
   - 但是，如果worker在`spawn_monitor`之后、`gun:open`之前就崩溃了？比如配置读取失败。也会收到'DOWN'。也没问题。
   - 如果`gun:open`成功了，但后续某个调用异常，worker死，收到'DOWN'。也没问题。

9. **熔断状态按 judge_model 名分别维护**：
   - 文档说"更换 judge_model 配置 = 新状态空间，旧状态自然作废"。
   - 这意味着judge_model变更时，旧的有问题的连接不会影响新的。但"自然作废"可能意味着ETS中没有清理旧状态，只是查找新key。这不是问题。

10. **错误码400与no_route的区分**：
    - est_total > max_ctx_tokens → 400 request_too_large。
    - 如果max_ctx_tokens配置为小于fast_ctx_tokens？启动校验只检查非正数，没检查大小关系。比如max_ctx_tokens=1000, fast_ctx_tokens=8000。那么任何请求est_total>1000都会400，而fast规则5要求prompt_est<8000。这可能导致大量请求400。启动校验应该检查 max_ctx_tokens >= fast_ctx_tokens（如果配置了）。否则配置错误会导致可用性问题。这是一个遗漏的启动校验项。

11. **规则4与规则3的交互**：
    - 规则3: `(prompt_est+tools_est) × 1.2 > big_ctx_tokens` → big。
    - 规则4: `est_total > max_ctx_tokens` → 400。
    - 如果配置了 max_ctx_tokens，但它的值小于 big_ctx_tokens？比如 max_ctx_tokens=5000, big_ctx_tokens=60000。那么：
      - prompt+tools = 4000, max_out=4096, est_total=8096 > 5000 → 400。
      - 但prompt+tools=4000，即使×1.2=4800 < 60000，规则3不触发。请求被判到400。
      - 这可能合理（max_ctx_tokens是硬上限），但启动校验没比较它们。

12. **虚拟模型名匹配与路由**：
    - `maybe_route` 只对配置的虚拟名做binary全等匹配。
    - model_allowed 检查对原始名。
    - 文档说"虚拟模型是models表普通一行（仅用于/v1/models展示），无自身routes"。
    - 但是如果客户端请求 `janus-auto:suffix`，binary全等不匹配，会走pass，按普通模型处理。如果models表中没有 `janus-auto:suffix`，会返回model_not_found。这没问题，文档已注明。

13. **default_tier回退rules-only**：
    - 启动校验：`default_tier ∉ keys(tiers)` ⇒ error + 回退 rules-only。
    - 回退rules-only意味着judge_model也被忽略？还是只忽略default_tier
