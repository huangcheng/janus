# Review v2.5 by deepseek-v4.1-flash (deepseek-v4-1-flash-260910)

_26.7s · completion_tokens=4000_

我们需要回答用户。用户要求第七轮终审审查 v2.5，严格审查 A 仍存在缺陷或 v2.1 新引入问题；B 遗漏边界；C 具体可执行改进建议。判定标准只有影响正确性、安全性、可用性、成本才算缺陷；风格、措辞、假想极端不计。若无实质问题 PASS 并简述。每部分最多 5 条，中文。

我们需要仔细审查设计规格。前六轮修复声称。需要找实质问题。作为资深分布式/LLM基础设施。需要精确。

我们先通读规格。重点找正确性/安全性/可用性/成本缺陷。

规格 v2.5 有：
- 目标虚拟模型路由 fast/big/flagship。
- 原则零假设。
- 授权 key 全模型，仅原始模型名过滤，虚拟名可绕白名单。有 warn only。这可能是安全问题？但他们定案不再复议。但终审？可能与安全相关。不过 §2.2 定案。但规则说 key 默认可访问所有模型，api_key_models 可选粗过滤只对原始模型名生效，改写后不二次校验。如果 key 白名单只含 janus-auto，请求 janus-auto 可路由到不在白名单模型。这是设计选择，已有 warn。如果用户配置白名单以为隔离，安全漏洞。他们定案。但审查标准安全性。但第六轮可能已讨论。我们可提？可能算缺陷但已被“定案，不再复议”。作为终审，如果历史已定不再复议，可能不重复。但可提如果仍实质。但是用户说前两轮关键缺陷已修复，审查仍存在的。我们可以提但仍可能重复。尽量找新缺陷。

核心：规则优先级与容量。

规则 0 est_total > max_ctx_tokens -> 400。est_total = prompt_est + media_allowance + tools_est + max_out。max_out 默认 4096。如果 max_ctx_tokens 配置了但 < big_ctx_tokens 忽略。规则 3 est_total > big_ctx_tokens -> flagship。规则 4 (prompt_est+tools_est)*1.2 > big_ctx_tokens -> big。规则 5 est_total < fast_ctx_tokens 且 no tools 且 msg<=3 -> fast。否则 judge。

问题：规则 4 条件 `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` -> big，但规则 3 先检查 `est_total > big_ctx_tokens` -> flagship。如果 prompt+tools 段超 big 但 est_total 不超 big（因为 max_out 小甚至 0? max_out 默认 4096，est_total = prompt+tools+max_out+media，所以如果 prompt+tools> big， est_total 必 > big，因为 max_out>=? 如果 max_out=0 可能 est_total = prompt+tools。但 max_out 默认 4096，无法为0? 用户可显式 max_tokens=0? max_out 取 max_completion_tokens ?? max_tokens ?? 4096。如果 max_tokens=0，则 max_out=0。此时如果 (prompt+tools)*1.2 > big 但 prompt+tools <= big，则 est_total <= big 可能。规则 4 -> big。若 prompt+tools 本身 > big，则 est_total > big 规则 3 -> flagship。因此规则 4 实际只在 prompt+tools > big/1.2 且 prompt+tools+max_out+media <= big 时命中。这意味着规则 4 把带余量的 prompt+tools 在 0.833*big 到 big 之间路由到 big，防止 max_out 加入后超？可是规则 3 已经用 est_total 总量。这个规则 4 可能导致可用性问题：如果 prompt+tools = 0.85*big, max_out=小, est_total=0.85*big+4096 <= big，则规则4 -> big。big 档总窗口 big_ctx_tokens，请求总 est <= big，ok。如果 prompt+tools > big? 规则3 flagship。

但注意规则 3 使用 est_total > big_ctx_tokens -> flagship。规则 4 使用 ×1.2 余量只乘 prompt+tools。若 prompt+tools + max_out <= big，但 prompt+tools*1.2 > big，则去 big。这可能是安全的：big 总窗口能容纳实际 est_total。余量可能保守。没问题。

但规则 5: `not has_tools` 且 `est_total < fast_ctx_tokens` 且 msg_count <=3 -> fast。注意 strict `<`，如果等于 fast_ctx_tokens 则不 fast，进入 judge。小问题。规则 0/3b。可用性。

容量防线：规则 3 flagship 当 est_total > big_ctx_tokens。但没有检查 est_total 是否 > flagship_ctx_tokens，因为零假设不知道 flagship 窗口。部署者保证 flagship ≥ big。但 max_ctx_tokens 可选。如果没配置 max_ctx_tokens，请求 est_total 可以任意大（比如 1M），规则 3 只要求 > big -> flagship，但 flagship 也不一定够。规格说旗舰窗口由部署者保证 ≥ big，但没保证 ≥ 任意大。容量保护由规则 3 + 规则 4 + 部署者保证 flagship ≥ big 构成完整防线——任何请求至多到达 flagship 档，不会缺档拦截。但旗舰窗口可能小于请求 est_total。没有 max_ctx_tokens 时无法知道旗舰窗口，无法拦截，会发到上游导致上游错误（可能 400/5xx）。这不是路由器自身 5xx？上游错误。但是容量保护？他们说零假设，依赖用户配置阈值。但 `big_ctx_tokens` 是总窗口语义，`flagship` 只是比 big 大？配置中没有 flagship_ctx_tokens。规则 3 只要 > big 就去 flagship，哪怕 est_total 巨大。若旗舰窗口也小于 est_total，上游拒绝。如果用户不配置 max_ctx_tokens，容量保护不完整。他们声称“容量保护由规则3+规则4+部署者保证 flagship ≥ big 共同构成完整防线——任何请求至多到达 flagship 档，不会缺档拦截。” 但“不会缺档拦截”不等于请求不超旗舰窗口。若 est_total > flagship 窗口，上游失败。但零假设：Janus 不知道窗口，不能防。可以建议配置 max_ctx_tokens 应设为旗舰窗口。但可选。这可能是可用性缺陷? 但设计承认可选。他们的总述说有完整防线，实际上不完整除非 max_ctx_tokens 配置。是否实质？可能。六轮已讨论。可能算遗漏边界：未配置 max_ctx_tokens 时超大请求会打到 flagship 上游，若超过旗舰实际上游报错，不是路由器制造5xx，但可用性。建议：若未配置 max_ctx_tokens，应该基于 big_ctx_tokens 推断? 不行。或者要求部署者配置旗舰窗口或 max_ctx_tokens。但零假设。可以提。

另一个重要问题：规则 2 marker_hit -> flagship hard。规则 0 先检查 est_total > max_ctx_tokens -> 400。所以超长 marker 请求 400。可以。

规则 1 multimodal -> flagship hard。规则 0 若配置 max_ctx 且 est_total 超，则 400。多模态不一定超。

规则 4 `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` -> big hard。但注意 `max_out` 可能很大，如果 est_total <= big 但 prompt+tools*1.2 > big，去 big。总 est_total 包括 max_out，所以如果 est_total <= big，big 能容纳。OK。

问题：规则 5 使用 `est_total < fast_ctx_tokens`，但 fast 档“定向 hard / 可用性 soft”：正常时直接落 fast；fast 档不可用时按 soft 语义降级 default_tier。但是规则 5 是 hard 结论？它说定向 hard/可用性 soft。实现中 hard/soft 区分：规则门结论是硬约束，其目标档不可用时不允许降级到 default_tier——直接 no_route；判分区软估计允许降级。然后 §8 表：规则 5 fast 档不可用 -> 按 soft 语义降级 default_tier。所以规则 5 特殊：hard 条件但可用性 soft。可以。

问题：`default_tier` 若等于 fast，但 fast 不可用，soft 降级 default_tier 再试一次，可能同一档？如果规则 5 目标 fast 不可用，降级 default_tier，如果 default_tier=fast，再试一次同一个不可用档，然后 no_route。这有点浪费但无害。如果 default_tier 是 big，可能 big 可用。OK。

问题：判分区 soft 结论的 tier 不可用 -> default_tier 档再试一次；仍不可用 -> no_route。如果 default_tier 等于原 tier，重复试？tier 解析候选按序取 catalog 中在售且 LB 可选的首个。如果原 tier 全部不可用，再试 default_tier 相同则仍不可用。可以优化但不缺陷。

缓存：主表 set，辅表 ordered_set，容量 >4096 时从辅表头部无条件删除对应主表条目直至回到 4096，单次清扫至多处理 128 条。问题：如果容量超过 4096 很多（比如 10000），单次清扫至多 128 条，那么容量可能持续超过上限，多次写入逐步清理？但每次写入只清 128，可能永远追不上？如果写入快，容量无界增长？需要分析。辅表条目在每次写时插入，主表写入同笔。容量检查 `>` 4096 时删除头部直到回到 4096 或处理 128 条。如果一次插入后容量为 4097，删 1 条即可。但如果因为并发批量插入，容量达到 10000，单次清扫最多 128，留下 9872 > 4096。后续每次写入再清 128，但每次也插入一条，净减 127（如果每次触发清扫）。最终会降到 4096，大约 (10000-4096)/127=46 次写入后。可能短暂超限但最终收敛。但如果持续高并发，每次写入插入1清128，容量会下降。不是无界。但如果清扫只删除辅表条目，主表可能未删？删除对应主表。OK。但是“单次清扫至多处理 128 条”在容量超限很多时不能立即回到 4096，导致内存短暂超限，可接受？也许。

但是关键：FIFO 淘汰语义：辅表键 `{{Seq, Kind, Hash} => ok}`，Seq 原子递增。有序集按 term 排序。Erlang ordered_set 按 Erlang term order。键是 `{Seq, Kind, Hash}`，Seq 是整数原子递增。所以头部最旧。OK。但 Kind 在第二位置；如果 Seq 相同？Seq 原子递增唯一，不会相同。所以 Kind 不影响排序。OK。

缓存 key：`erlang:phash2({SysPrefix, LastUserPrefix, ToolsFp, HasMM, prompt_est_bucket, max_out_bucket}, 268435456)`。2^28 域。容量 4096 碰撞概率 ~3e-5? 生日碰撞概率 n^2/(2N) = 4096^2/(2*2.68e8) = 16.7e6 / 5.36e8 ≈ 0.031 = 3.1%，不是 3e-5。他们计算错了？2^28 = 268,435,456。4096^2/(2*268M)=16,777,216 / 536,870,912 = 0.03125，即 3.1%。不是 3e-5。3e-5 是 4096/2^28 ≈ 1.5e-5 单条碰撞？或者 4096/2^28 = 1.526e-5。他们说是碰撞概率 ~3e-5，可能指单次插入与现有条目碰撞概率 = 4096/2^28 ≈ 1.5e-5，但任意碰撞概率 3%。如果缓存容量 4096，哈希碰撞会导致不同请求共享错误决策。发生概率 3% 在满容量。这影响正确性/成本：可能把需要 flagship 的请求路由到 fast（如果缓存 key 碰撞）。但 key 包含前缀、tools 指纹、hasMM、buckets。不同输入可能共享结论是设计选择。但哈希碰撞是意外。3% 任意碰撞概率不低。虽然哈希碰撞后 value 被覆盖？主表 key 是 Hash，若碰撞，后写覆盖。读取时命中错误 tier。概率 3% 满容量。这对正确性有影响。他们声称 3e-5，低估 1000 倍。这是一个实质缺陷：哈希域太小或容量太大。可以建议提高 phash2 范围到 2^32 或使用完整 key 而非 phash2，或用 dict 主键为元组而非 hash，避免碰撞。但 ETS 主键可以用完整 key，容量 4096，无需 hash。为什么用 phash2？内存？完整 key 含前缀 256+1200 约 1.5KB，4096 条约 6MB，可接受。用 phash2 节省内存但碰撞。可改为主键完整 key 或 2^32 phash2。这个很明确。需要计入 A。

再看缓存正负分键空间：正条目 `{pos, Hash}`，负 `{neg, Hash}`。容量 4096 是所有条目总和？辅表 ordered_set 包含 pos/neg。主表 set 键是 `{pos, Hash}`? 描述：主表 `set`：`{Hash => {Tier, ExpiresAt}}` 但后面正负分键空间：正决策存 `{pos, Hash}`，负缓存存 `{neg, Hash}`。可能主表键包含 Kind。变更③辅表键含 Kind。主表键应该也是 `{Kind, Hash}`。描述有点不一致但可理解。容量 4096 包括正负。OK。

缓存 TTL：正 300s，负 30s。负缓存命中 -> default_tier。正缓存命中 -> tier soft。读取顺序先正后负。如果正条目过期但负条目存在？正过期惰性删除？读取时发现过期视为 miss，是否删除正条目？未说明。如果正条目过期未删，负条目存在，会先查正，发现过期，然后查负命中。OK。但过期正条目仍占容量，直到 FIFO 淘汰。可以。

负缓存 key 是否与正相同 Hash？是。负缓存 30s 内跳过判分走 default_tier。如果正条目过期后，负条目仍有效？正 TTL 300s > 负 30s，通常负先过期。但如果 judge 成功后写正并自然遮蔽负。OK。

问题：缓存 key 包含 `prompt_est_bucket` 和 `max_out_bucket`，但 judge 输入包括 system 前 256 字符、末条 user 消息前 1200 字符、输出预算档位行。输出预算档位行来自 max_out 分档：`Output budget: <=2k / <=8k / >8k tokens`。缓存 key 使用 `max_out_bucket = max_out div 4096`。分档与 judge 输入分档不一致？judge 输入分档是三档：<=2k, <=8k, >8k。缓存 bucket 是每 4096 一档：0-4095, 4096-8191, ... 这样不同 max_out 可能共享缓存? 实际上缓存 key 更细，不是问题。但是 judge 输入输出预算档位行是否需要与缓存 key 对齐？如果两个请求 max_out 分别为 3000 和 5000，judge 输入档位不同（<=2k? 3000 >2k? 等等），缓存 key bucket 不同（0 vs 1），不会共享。如果 max_out 9000 和 12000，judge 输入都 >8k，但缓存 key bucket 2 vs 2? 9000 div 4096=2, 12000 div 4096=2，共享。judge 输入相同档位 >8k。OK。

但 `max_out` 默认 4096。规则 5 使用 est_total < fast_ctx_tokens，包含 max_out 默认 4096。如果 fast_ctx_tokens 默认 8000，短 prompt 无 tools msg<=3 可以 fast。OK。

问题：`marker_hit` 末条 user 角色消息。如果最后一条 user 消息 content 是多模态 part 列表，如何提取文本？拼接其全部文本 part。OK。但如果 content 是 binary。OK。大小写 lower。ASCII 标记词边界匹配，CJK 直接子串。标记表可配。词边界匹配实现？未详述。可能问题：`don't think harder` 反例。英文词边界要求前后非字母数字？Erlang 实现可能复杂。但测试计划有。

问题：`features/1` 畸形输入返回 pass。但 pass 后按普通模型处理，返回 model_not_found 404。如果请求 body.model 是 `janus-auto`，而虚拟模型在 models 表有一行用于 /v1/models 展示，但无 routes。pass 后按普通模型处理，会找到虚拟模型？他们 §7 说虚拟模型是 models 表普通一行（仅用于 /v1/models 展示），无自身 routes。如果 pass 后按普通模型处理，model_allowed 已通过，然后路由查找模型 janus-auto 存在但无 routes，会怎样？可能是 no_route 或 model_not_found？他们 §4 
