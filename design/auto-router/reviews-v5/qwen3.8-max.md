# Review v2.3 by qwen3.8-max (qwen3.8-max)

_30.9s · completion_tokens=1392_

# Janus Auto Router v2.3 评审报告

## A. 仍然存在的缺陷或新引入的问题

1. **规则 4 的 `est_total` 包含 `max_out`，导致短 prompt + 大输出被错误排除出 fast**
   规则 4 条件为 `est_total < fast_ctx_tokens`。若用户发送极短请求（如 "Hi"，prompt_est ≈ 1）但指定 `max_completion_tokens: 8000`，`est_total` ≈ 8001 > 8000，无法命中规则 4 而进入判分区甚至 big 档。fast 档本身具备处理 8000 token 输出的能力，仅因预估输出大就剥夺其路由资格，违背了规则 4 “成本偏好”的设计初衷，造成不必要的 judge 调用与成本上升。
2. **决策缓存 Key 缺失 `max_out`，导致不同输出长度请求发生“幽灵命中”**
   §5 缓存 Key 仅包含 `{SysPrefix, LastUserPrefix, ToolsFp, HasMM, prompt_est_bucket}`。两个输入完全相同但 `max_tokens` 分别为 100 和 16000 的请求会共享同一个缓存 Key。若前者先执行 judge 并缓存了 `fast`，后者将直接命中缓存走 `fast`，随后在真实转发时因超出 fast 模型上下文窗口而触发上游 400 错误。这破坏了正确性。
3. **信号量满降级 default_tier 存在级联压垮风险**
   §6.2 规定信号量满时跳过 judge 并降级到 `default_tier`（默认 fast）。在高并发下，若 judge 响应变慢导致信号量持续满载，所有原本应路由到 big/flagship 的复杂请求将全部涌向 default_tier（fast）。这可能导致 fast 档被重型请求压垮，引发全局可用性故障。
4. **负缓存与决策缓存的 Hash 碰撞会导致跨特征污染**
   使用 `phash2(..., 2^28)` 作为 ETS 主键，当表容量接近 4096 时碰撞概率约 3e-5。虽然文档认为可接受，但若碰撞发生在负缓存（Tier=`neg`）与普通决策缓存之间，一个失败的特征哈希会使另一个完全不同的合法请求被迫降级 30s；反之亦然。这在多租户高并发下影响可用性。

## B. 遗漏的边界情况

1. **`max_ctx_tokens` 配置小于 `fast_ctx_tokens` 时的逻辑漏洞**
   §7 启动校验拦截了 `max_ctx_tokens < big_ctx_tokens`，但未拦截 `big_ctx_tokens <= max_ctx_tokens < fast_ctx_tokens` 的情况。此时规则 4 命中的请求（`est_total < fast_ctx_tokens`）可能同时满足 `est_total > max_ctx_tokens`。由于规则 0 优先级最高，这些本应去 fast 的短请求会被直接返回 400，导致 fast 档实际不可达。
2. **`tools` 字段为非列表类型（如 map、null、字符串）时的崩溃**
   §4.1 定义 `tools_est` 为“JSON 编码后的 tools 列表字节 ÷ 4”，且畸形输入防线只显式提及了 messages 校验。若客户端传入 `"tools": {"invalid": true}`，对其进行 JSON 编码不会报错，但语义上并非工具列表，可能导致下游模型解析失败，或在估算时产生非预期值。
3. **末条 user 消息 content 为空数组 `[]` 时的 marker 提取**
   若 `content` 为合法的 part 列表但长度为 0（`[]`），拼接文本为空串。虽然 `marker_hit` 会安全返回 false，但若后续 judge 依赖该空串进行截断或拼接，需确认引号定界包裹逻辑（§6.1）处理空串时是否会产生格式歧义（如连续引号 `""` 被 judge 误解析）。
4. **Judge 进程在 `receive after` 超时后、被 `exit(Pid, kill)` 前的瞬间返回**
   §6.2 中，超时触发 `exit(Pid, kill)` 后执行 `demonitor(MonRef, [flush])`。若 worker 恰好在 kill 信号到达前将 `{Ref, Tier}` 发入 mailbox，flush 会将其丢弃。这虽保证了邮箱不泄漏，但该次成功的 judge 结果被白白浪费，未写入缓存，略微降低了缓存命中率。

## C. 具体可执行的改进建议

1. **规则 4 改用输入侧 token 评估**
   将规则 4 的条件从 `est_total < fast_ctx_tokens` 修改为 `(prompt_est + tools_est + media_allowance) < fast_ctx_tokens`（即剔除 `max_out`）。Fast 档的可用性应由输入大小决定，而非用户申请的输出上限。
2. **缓存 Key 增加 `max_out_bucket`**
   在 §5 的 hash tuple 中加入 `max_out div 4096`（或其他合适粒度），确保不同输出长度预期的请求获得独立的缓存条目，防止小输出请求的缓存结果误导大输出请求。
3. **信号量满时采用基于规则的 fallback 而非固定 default_tier**
   当 judge 信号量满时，不要无脑降级到 default_tier，而是执行一个轻量级的本地 fallback 规则（例如：若 `est_total > big_ctx_tokens` 则去 big，否则去 default_tier），避免将所有溢出流量倾泻到单一档位。
4. **缓存双写时增加 Tag 区分正负缓存**
   在辅表或主表的 Value 中显式区分 `decision` 和 `negative`，并在写入时检查是否覆盖。或者为负缓存使用独立的 ETS 表（TTL 仅 30s，容量极小），彻底消除正负缓存 Hash 碰撞导致的相互污染。
5. **补充 `max_ctx_tokens < fast_ctx_tokens` 的启动校验**
   在 §7 的启动校验中增加一条：若 `max_ctx_tokens` 已配置且 `< fast_ctx_tokens`，记录 error 并将其重置为 `fast_ctx_tokens` 或直接视为未配置，防止规则 0 误杀规则 4 的正常流量。
