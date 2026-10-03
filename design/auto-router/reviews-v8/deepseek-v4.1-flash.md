# Review v2.5-final by deepseek-v4.1-flash (deepseek-v4-1-flash-260910)

_24.4s · completion_tokens=4000_

我们需要回答用户：第八轮终审，严格审查 v2.5，目标确认无实质问题。前两轮关键缺陷声称已修复。要求：A 仍然存在的缺陷或 v2.1 新引入问题；B 遗漏边界情况；C 具体可执行改进建议。判定标准：只有影响正确性、安全性、可用性、成本的问题才算缺陷；风格偏好、措辞、假想极端场景不计。如果没有实质问题，明确输出 PASS 并简述理由。每部分最多 5 条，中文。

我们需要作为资深分布式系统与 LLM 基础设施工程师审查。要判断是否有实质缺陷。需要仔细阅读规格，找逻辑漏洞。可能很多历史问题已被修复，但也许仍有隐藏问题。我们要诚实：如果没有实质问题，PASS。但先仔细找。

设计 v2.5。关键点：

- 虚拟模型 janus-auto 路由到 fast/big/flagship。
- 规则门优先级：0 max_ctx_tokens 超限 400；1 multimodal -> flagship hard；2 marker -> flagship hard；3 est_total > big_ctx_tokens -> flagship hard；4 (prompt_est+tools_est)*1.2 > big_ctx_tokens -> big hard；5 not has_tools and est_total < fast_ctx_tokens and msg_count <=3 -> fast (定向 hard / 可用性 soft)；6 判分区 soft。
- features 提取：prompt_est ASCII bytes/4, 非 ASCII 码点*1.5。media_allowance min(non-text parts, max_media_parts)*4096。tools_est tools JSON bytes/4。max_out。est_total=prompt+media+tools+max_out。has_multimodal any non-text part。marker_hit 末条 user 消息文本拼接含标记。msg_count。输入健壮性畸形 -> pass。
- 容量防线：未配置 max_ctx_tokens 时，规则 3（est_total 总量）+ 规则 4（prompt+tools 段）+ 部署者保证 flagship ≥ big 完整防线。任何请求至多到 flagship，不会缺档拦截。
- 规则 5 使用 est_total < fast_ctx_tokens，且 no tools, msg_count <=3。但 fast_ctx_tokens 默认 8000，big_ctx_tokens 60000。规则 3/4 先判，所以若 est_total > big 会 flagship。若 est_total <= big 但 (prompt+tools)*1.2 > big 则 big。若 est_total < fast 且 no tools 且 msg_count <=3 -> fast。否则判分区。注意规则 4 条件：仅 prompt+tools 段超阈、总量未超 big 时落 big。但是否可能 prompt+tools*1.2 > big 而 est_total <= big？是的因为 max_out 可能 0？max_out 默认 4096，所以 est_total >= prompt+tools+4096。如果 (prompt+tools)*1.2 > 60000，则 prompt+tools > 50000，est_total > 54096，仍 <=60000，规则4 触发 big。但 prompt+tools > 50000 且 max_out 4096，est_total 约 54096，小于 big 60000，所以 big 可以容纳 prompt+tools+max_out? big_ctx_tokens 是总窗口，big 窗口 60000，prompt+tools 50000 + max_out 4096 = 54096 < 60000，可以放 big。为什么规则4要 prompt+tools*1.2 > big? 余量 20% 用于安全。OK。

- 规则 5：fast_ctx_tokens 总窗口语义，但只检查 est_total < fast_ctx_tokens，msg_count <=3，no tools。若 est_total < fast，则 prompt+tools+max_out < fast。OK。

- 硬/软：规则 hard 目标档不可用 -> no_route，不降级。规则 5 特殊：定向 hard / 可用性 soft：正常直接 fast；fast 不可用时按 soft 降级 default_tier。规则 0 是 error request_too_large。规则 1/2/3/4 hard 不降级。规则 5 可降级。

潜在问题：

1. 规则 2 marker_hit -> flagship hard，但 marker 检测在末条 user 消息。如果请求含 tools 或 multimodal，规则 1 先于规则 2，multimodal -> flagship 也 OK。如果 marker_hit 且 est_total > max_ctx_tokens，规则 0 先 -> 400。OK。

2. 规则 3 est_total > big_ctx_tokens -> flagship。但 est_total 包含 max_out。如果 max_out 很大（比如用户设置 max_tokens 极大，比如 1e9），est_total 可能超过 max_ctx_tokens? 若配置了 max_ctx_tokens 且 < big，被忽略。若 max_ctx_tokens 未配置，规则 3 会送 flagship。但 flagship 也可能容纳不了超大 max_out？容量防线说部署者保证 flagship >= big。但 est_total 可能大于 flagship 窗口？规格没有检查 flagship 窗口，因为不知道模型元数据。如果用户 max_tokens 设得比 flagship 窗口还大，路由到 flagship 后上游可能返回错误。但这属于 provider 层容量，Janus 不知道模型窗口，非缺陷？但设计目标容量保护只依赖配置阈值。未配置 max_ctx_tokens 时，若 est_total 超过 flagship 窗口，没有拦截。但这是用户配置 max_ctx_tokens 的职责。规格已说明未配置 max_ctx_tokens 时防线至多到 flagship。可能算遗漏？但之前评审可能接受。

3. media_allowance 封顶 max_media_parts 默认 10。但如果非文本 part 数超过 10，media_allowance 封顶为 10*4096=40960。HTTP 层请求体上限 10MB 兜底。但 10MB 的 base64 图片可能解码后很大，但作为 token 估算封顶。如果非文本 part 数量很多但每个都很小，封顶防止堆砌。OK。但封顶可能导致低估极端多模态请求（例如 100 张图片，每张 1MB，est_total 只算 40960 token，可能小于 max_ctx_tokens，实际请求体 100MB? 但 HTTP MAX_BODY 10MB 兜底，所以最多 10MB。10MB base64 图片可能约 7.5MB 二进制，token 化后可能很多。media_allowance 封顶 40960 token，可能低估。但规格说“宁可高估触发上限，不做 provider 级精确计费”。这里封顶是限制高估？其实封顶是防止高估导致所有多模态都超限？但可能低估实际 token。不过 HTTP 层 10MB 兜底，不会无限放大转发。是否正确性/成本问题？可能造成上游模型上下文超限返回错误，但这不是 Janus 5xx，是上游错误。但用户请求可能被路由到 big/flagship，即使实际超窗口。但 Janus 不知道模型窗口，只能依赖配置。所以非实质？可能。

4. 缓存 key 使用 `erlang:phash2(..., 268435456)` 2^28 域，容量 4096，碰撞概率 ~3e-5。但缓存 key 是哈希，碰撞可能导致不同请求共享错误 tier。虽然概率低，但 3e-5 对于大量请求可能发生。但规格接受。是否安全？若不同请求碰撞，可能路由到错误档位，影响成本/质量。但概率可接受，且缓存 300s。不过 phash2 不是加密哈希，可能容易碰撞？但 2^28 域，4096 条目，生日碰撞约 4096^2/(2*2^28)=约 3.1e-5，是的。这算可接受？历史上可能讨论过。不计为缺陷？

5. 缓存 key 包含 `prompt_est_bucket` 和 `max_out_bucket`，但 `prompt_est` 用于 key 的 bucket 是 div 4096。judge 输入包含 system 前 256、末条 user 前 1200、输出预算档位。但 key 中 `LastUserPrefix` 是末条 user 文本前 1200 字符，和 judge 输入一致。但 key 中 `SysPrefix` 是 all system 拼接前 256，judge 输入也是 system 前 256。OK。ToolsFp 全量指纹，但 judge 输入没有 tools 内容？规格 judge 输入：system 前 256 + 末条 user 前 1200 + 输出预算档位。它没有包括 tools 内容，但 key 包含 ToolsFp。这意味着包含不同 tools 的请求会得到不同缓存 key，但 judge 实际看不到 tools，可能给出相同 tier。这是安全/正确性？缓存 key 是 judge 输入的超集，导致缓存命中率降低，但不会错误共享。OK。但 judge 本身不知道 tools，可能调度不优，但设计选择。

6. 正负缓存分键空间：正决策 `{pos, Hash}`，负缓存 `{neg, Hash}`。读取顺序：先查正条目，命中且未过期即用；仅当无有效正条目时才查负条目（30s 内跳过判分走 default_tier）。judge 成功后写正条目即自然遮蔽负条目。但若正条目过期后，负条目可能还在（负 TTL 30s，正 300s）。读取时先查正，若正过期视为 miss，然后查负，如果负条目未过期（可能是在正条目写入之后写的？但正条目写入时不会删除负条目。假设某请求先失败写负 30s，后来 judge 成功写正 300s。正存在时优先。300s 后正过期，负条目早已过期（30s），所以不会影响。但若正条目写入后，又有 judge 失败写负？失败路径写负条目，但读取顺序先查正，正命中即用，负被遮蔽。OK。但如果正条目被 FIFO 淘汰，负条目可能还在？负 TTL 30s，正 TTL 300s，负更早过期。OK。

7. 辅表键含 `Kind`，容量超限改 FIFO 无条件淘汰。写序：先辅表后主表。容量 >4096 时从辅表头部（最旧）无条件删除对应主表条目直至回到 4096。单次清扫至多 128 条。注意：辅表 `ordered_set`，键 `{Seq, Kind, Hash}`，Seq 原子递增。FIFO 淘汰从头部删除。但是，如果先写辅表后写主表，在两步之间发生清扫，可能辅表里有新写的记录，但主表还没写。清扫时删除该辅表记录并尝试删除主表条目（不存在），然后主表写入又发生，导致主表有条目但辅表没有记录。这破坏了“主表条目必有辅记录可被淘汰”的保证。规格说“写序：先辅表后主表（ETS 无跨表事务；此序下孤儿只会出现在辅表——指向已过期/缺失主键，清扫时自然清除，主表条目必有辅记录可被淘汰）”。但这个写序下，如果辅表写入后、主表写入前，容量超限触发清扫，可能把刚写入的辅表记录淘汰掉，然后主表才写入，于是主表有条目但辅表无记录。这是竞态！因为 ETS 操作不是原子的跨表。单节点多进程并发。这个缺陷可能影响缓存淘汰：主表条目无法被辅表淘汰，可能永久残留直到 TTL 惰性过期？但主表读取惰性过期，TTL 300s，所以不会永久。但容量控制可能失效：主表可能超过 4096？因为辅表淘汰了记录，主表却新增，导致主表多于辅表。但容量检查在辅表上，主表可能增长。最坏情况：并发写入导致主表条目没有辅表记录，辅表容量保持 4096，主表可能超过 4096 但 TTL 300s 限制增长速率。如果高并发持续，主表可能显著超过 4096？但每次写主表前写辅表，辅表容量清扫会删除最旧。如果刚写的辅表记录被删，主表写入后成为无辅记录。后续写入会继续。辅表始终最多 4096，主表可能累积无辅记录条目，直到 TTL 过期。但 TTL 300s，高 QPS 下可能很多。这算缺陷吗？影响成本/内存？规格声称容量 >4096 时 FIFO 淘汰，确定性有界。但这个竞态破坏有界性。是否可以修复？比如写主表后写辅表，或者清扫时检查主表是否存在？但写序若改为主表后辅表，孤儿只在主表，难以淘汰。或者使用单表存元数据？这是实质缺陷？可能影响内存有界，但 TTL 300s 提供最终有界。如果 QPS 很高，300s 内可能积累大量条目超过 4096。但单次清扫至多 128 条，容量检查可能滞后。需要评估。

但规格 v2.5 变更 ③ 说“辅表键含 Kind，容量超限改 FIFO 无条件淘汰（语义确定、成本有界）”。他们可能认为写序保证主表条目必有辅记录。但并发下这个保证不成立，因为写辅表后、写主表前，另一个进程可能执行清扫删除辅表记录。清扫是“容量 >4096 时从辅表头部删除”。如果刚插入的辅表记录是最新（Seq 最大），FIFO 从头部删除最旧，不会删除刚插入的，除非辅表已满且刚插入后容量 >4096，此时从头部删除最旧，刚插入的在尾部，不会被删。所以刚插入的辅表记录不会被淘汰，因为 FIFO 删除最旧。但如果在写辅表前辅表已满 4096，插入新记录后容量 4097，触发清扫，从头部删除最旧（不是刚插入的），直到回到 4096。刚插入的记录保留。然后写主表。所以这个竞态不会删除刚插入的辅表记录，因为新记录 Seq 最大在尾部。FIFO 删除头部最旧。所以刚写的辅表记录会保留。OK，那写序保证主表条目有辅记录。但还有另一个竞态：主表写入后，辅表记录可能被后续清扫淘汰（因为它是旧的），同时主表条目被删除？清扫会删除辅表头部最旧记录，并删除对应主表条目。如果该主表条目已经因为 TTL 过期被惰性删除，或者被其他路径删除，没关系。如果主表条目还在，删除它。所以同步。没有无辅记录的主表条目。但有没有可能辅表记录被淘汰时，主表条目尚未写入？不会，因为先写辅表后写主表，淘汰从头部最旧，新记录在尾部，不会在写入前被淘汰。除非容量清扫一次删除 128 条，如果新记录在头部？不可能，Seq 递增，新记录 Seq 最大，ordered_set 按键排序，键是 {Seq, Kind, Hash}，Seq 大在尾部。所以新记录安全。OK，这个竞态不成立。但还有一个：写辅表成功，写主表失败（比如 ETS 表不存在？），辅表孤儿，主表没有。清扫时删除辅表记录，尝试删除主表条目（不存在），OK。所以写序合理。容量有界？辅表最多 4096+可能插入时短暂 4097，清扫至多 128，但清扫后回到 4096。如果高并发同时插入，可能超过 4096 很多？因为容量检查是 >4096 时触发清扫，删除至多 128 条。如果同时插入 1000 条，每个都可能看到容量 >4096 并尝试清扫，但删除操作可能重叠。最终辅表可能超过 4096？比如当前 4096，1000 个进程同时插入，都看到 4097，都触发清扫，每个删除 128 条最旧，总共删除很多，但插入也很多。由于删除最旧，辅表可能保持在 4096 左右。最坏可能超过 4096 一些，但不会无限。有界。成本有界。OK。

8. 信号量释放保证：获取后在 after 块中保证释放（正常回复、DOWN、超时三条路径都归还）。但规格代码里 `after judge_timeout_ms -> exit(Pid, kill), demonitor...` 没有显示信号量获取/释放的位置。它说获取后在 after 块中保证释放。但 spawn_monitor 是获取信号量之后？如果 spawn_monitor 自身失败（系统极限）直接走失败路径，是否释放信号量？需要确保。它说 spawn_monitor 自身失败（系统极限）直接走失败路径（同超时语义）。但信号量是在 spawn_monitor 之前获取的吗？如果是，spawn_monitor 失败时是否释放？代码没显示。可能遗漏。但规格文字说“获取后在 after 块中保证释放（正常回复、DOWN、超时三条路径都归还）；spawn_monitor 自身失败（系统极限）直接走失败路径（同超时语义）”。如果 spawn_monitor 失败发生在 after 块内部？通常 after 块在 receive 之后，spawn_monitor 在 try 内部？需要具体。可能不是实质。

9. 熔断状态按 judge_model 名分别维护：更换 judge_model 配置 = 新状态空间，旧状态自然作废。但配置切换竞态：judge worker 启动时对 judge_model 做快照，其结果回写携带快照 model 名；若与当前配置不一致，回写直接丢弃。这个处理
