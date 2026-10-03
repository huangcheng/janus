# Review v2.5 by qwen3.8-max (qwen3.8-max)

_39.1s · completion_tokens=1824_

# Janus Auto Router v2.5 终审报告

## A. 仍然存在的缺陷或新引入的问题

1. **信号量“在 after 块中释放”的措辞与 Erlang 语义矛盾（正确性）**
   规范 §6.2 写道“获取后在 `after` 块中保证释放（正常回复、DOWN、超时三条路径都归还）”。Erlang 的 `receive ... after` 仅在**超时**时执行 `after` 分支，正常匹配 `{Ref, Tier}` 或 `{'DOWN', ...}` 不会进入 `after`。若实现者按字面意思只在 `after` 里写 `atomics:sub(...)`，正常返回和 DOWN 路径将永远不释放信号量，导致计数器单调递增至上限后永久跳过 judge。**建议**：明确改为“使用 `try ... after ... end` 包裹整个 receive，或在三个匹配分支及 after 中均执行释放”。

2. **规则 4 的阈值放大因子不对称导致容量防线缺口（正确性/安全性）**
   规则 3 比较 `est_total > big_ctx_tokens`；规则 4 比较 `(prompt_est + tools_est) × 1.2 > big_ctx_tokens`。假设 `big_ctx_tokens = 60000`，某请求 `prompt+tools = 49000`，`max_out = 4096`，`media = 0`。此时 `est_total = 53096 < 60000`（绕过规则 3），但 `49000 × 1.2 = 58800 < 60000`（绕过规则 4）。该请求落入判分区（soft），若 judge 返回 `fast`，实际总 token 53k 远超 fast 档容量，且因为是 soft 结论会被降级执行，造成上游 OOM 或截断。×1.2 仅乘 prompt 未包含 max_out，使得靠近边界的大输出请求逃逸了 hard 拦截。

3. **辅表 FIFO 淘汰未说明并发写入竞态（正确性）**
   辅表为 `ordered_set`，键含原子递增 `Seq`。多进程并发写入时，若两个进程同时发现 `size > 4096` 并各自从头部读取最旧条目进行删除，可能删除同一个条目后再次删除其他条目，或者由于 ETS `select` 的非事务性导致漏删。虽然单次清扫至多 128 条限制了爆炸半径，但在极高并发下缓存容量可能短暂失控或误删刚写入的新条目。需明确并发控制策略（如单进程负责 GC，或使用 `ets:update_counter` 配合排他逻辑）。

4. **`phash2` 碰撞导致的跨用户决策污染（安全性/成本）**
   缓存 Key 使用了 `phash2(..., 2^28)`，且输入特征不包含 API Key 或 User ID。不同用户的请求只要前缀摘要相同就会命中同一缓存。虽然规范称“这是设计选择”，但若恶意用户构造特定前缀触发 judge 得到 `flagship` 并写入正缓存，另一正常用户的相似请求会直接命中该 `flagship` 决策（soft 命中），导致成本异常升高。作为基础设施网关，缺乏租户隔离的缓存存在被定向投毒放大成本的风险。

5. **规则 5 降级 default_tier 时的循环依赖未定义（可用性）**
   规则 5 命中 fast 但不可用时降级到 `default_tier`。若部署者配置 `default_tier => fast`（如 §7 示例），则形成死循环或无限回退。规范未说明当 `target_tier == default_tier` 且不可用时的行为是立即 `no_route` 还是报错。

---

## B. 遗漏的边界情况

1. **`content: null` 或 `content: []` 的合法空消息**
   OpenAI 兼容 API 允许 `content` 为 `null`（例如纯 tool_calls 响应或某些 assistant 消息）。规范 §4.1 说“content 为 binary 或 part 列表；不满足 ⇒ pass”。若将合法的 `null` 视为畸形直接 pass 并返回 404，会导致正常的工具调用多轮对话被阻断。

2. **`max_media_parts` 封顶后的估算失真与规则 0 误杀**
   当非文本 part 数为 50 时，`media_allowance` 被封顶为 `10 × 4096 = 40960`。如果真实媒体 token 远大于此，`est_total` 将被严重低估，导致绕过规则 0/3 发给上游引发 400；反之，如果每个 part 很小（如 100 token），封顶计算仍按 4096 算，可能导致总 est 虚高触发规则 0 返回 400，拒绝合法请求。

3. **Judge 响应恰好为空字符串或全空白字符**
   §6.3 解析逻辑取“最后一个非空行”。若 judge 模型因某种原因（如 content_filter）返回空内容或仅包含换行符，切词后无白名单词，走解析失败降级。此路径虽被覆盖，但未明确是否计入“连败计数”从而意外触发熔断。

4. **配置热更新期间的 in-flight judge 状态撕裂**
   规范提到“judge worker 启动时快照 model 名，回写不一致则丢弃”。但如果 `judge_max_inflight` 或 `judge_timeout_ms` 在 worker 运行期间被热更新，worker 使用的仍是旧超时时间，而主线程的信号量上限已变，可能导致新旧配置交替期间的资源泄漏或超时行为不一致。

5. **`tools` 字段存在但为非数组类型（如 `tools: null` 或 `tools: "invalid"`）**
   `features/1` 校验了 messages，但未提及对 `tools` 字段的健壮性处理。若 `tools` 为非法类型，`JSON 编码后的字节 ÷ 4` 可能抛出异常，触发顶层 try/catch 降级为 pass，掩盖了本应返回 400 的客户端错误。

---

## C. 具体可执行的改进建议

1. **修正信号量释放的代码模式描述**
   将 §6.2 的描述改为明确的 Erlang 惯用法：
   ```erlang
   try
       receive ... after Timeout -> exit(Pid, kill), fail_path end
   after
       atomics:sub(SemRef, 1, 1)
   end.
   ```
   确保无论 receive 匹配哪个分支、是否抛异常、是否超时，信号量必定归还。

2. **统一规则 3 和规则 4 的余量计算基准**
   规则 4 的 `(prompt_est + tools_est) × 1.2` 建议改为 `(prompt_est + tools_est + max_out) × 1.2`，或者明确规则 4 仅用于拦截“prompt 极大但 max_out 极小”的请求，并在文档中给出数学证明其与规则 3 联合能覆盖所有越界组合，消除盲区。

3. **缓存 Key 引入租户/API Key 哈希盐**
   在 `phash2` 的元组中加入 `ApiKeyHash`（如 `phash2(ApiKey)` 的低几位），以极小的内存代价实现租户隔离，防止恶意用户通过构造特定 prompt 污染全局路由决策池。

4. **显式防御 default_tier 循环降级**
   在 §7 tier 解析步骤 2 中增加约束：“若 soft 目标档不可用，降级尝试 `default_tier`；若 `default_tier` 与初始目标档相同或仍不可用，立即返回 `{error, no_route}`，禁止二次回退。”

5. **完善畸形输入校验清单**
   在 §4.1 输入健壮性中补充：`content: null` 视为空字符串（0 token）；`tools` 若非 list 则视为空列表（0 token）并记录 warn；避免因为非核心字段的轻微畸形导致整个请求被当成未知模型 404 掉。
