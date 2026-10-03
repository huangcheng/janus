# Review v2.2 by qwen3.8-max (qwen3.8-max)

_41.0s · completion_tokens=1842_

# Janus Auto Router v2.2 评审报告

## A. 仍然存在的缺陷或新引入的问题

1. **规则 0 与规则 4 的 `max_ctx_tokens` 语义不一致（可用性/正确性）**
   规则 0 仅在“配置了该上限”时生效，若未配置则跳过；但规则 4 硬编码比较 `est_total < fast_ctx_tokens`。如果部署者未配置 `max_ctx_tokens`，一个 `est_total = 50000`（大于 `fast_ctx_tokens=8000`）的请求会绕过规则 0，在规则 3 中因 `(prompt+tools)*1.2 <= 60000` 未被拦截，最终落入规则 4 因不满足 `< 8000` 而进入判分区。这本身没问题，但如果部署者期望 `max_ctx_tokens` 是全局保护伞却忘了配，规则 4 的比较就成了唯一的容量防线。**建议**：明确文档说明未配置 `max_ctx_tokens` 时，系统最大容忍窗口即为各档位阈值，或者将规则 0 改为强制依赖 `big_ctx_tokens` 作为兜底硬上限。

2. **Judge worker 快照竞态修复引入的“幽灵成功”（成本/可用性）**
   三轮④修复规定：worker 启动时快照 `judge_model`，若回写时发现配置已切换，则丢弃负缓存和连败计数写入。这意味着旧模型调用**成功**时，决策缓存（300s TTL）依然会按旧 key 写入。新模型上线后，前 300s 内相同特征的请求会命中旧模型的决策缓存，导致新 judge 模型无法立即生效。**建议**：配置切换时应主动清空决策缓存表，或缓存 value 中携带 `judge_model` 版本，读取时校验一致性。

3. **`{error, request_too_large}` 的 HTTP 映射缺乏标准错误体结构（可用性）**
   规格仅说“handler 映射 400”，但未定义 400 响应体的 JSON 结构。OpenAI 兼容 API 客户端对 400 有固定解析预期（如 `{error: {message, type, code}}`）。若返回非标准格式，会导致客户端 SDK 抛出解析异常而非正常的业务错误。**建议**：明确规定 400 响应体遵循 OpenAI `invalid_request_error` 格式。

4. **多模态请求的 `est_total` 严重失真导致规则 0 误杀或漏放（正确性）**
   规则 0 用 `est_total > max_ctx_tokens` 做硬拦截，但 §4.1 明确规定非文本 part 字节不计入 `prompt_est`。一张 20MB 的图片 `est_total` 可能只有几百 token。这导致规则 0 对多模态请求形同虚设（漏放超大请求给上游导致 5xx），或者如果部署者为了防图片把 `max_ctx_tokens` 调得极小，又会误杀纯文本长请求。**建议**：规则 0 应增加独立的 `max_multimodal_bytes` 检查，或在文档中严厉警告 `max_ctx_tokens` 无法保护多模态带宽。

## B. 遗漏的边界情况

1. **`messages` 数组包含非 map 元素或 content 为非 list/binary 的畸形结构**
   §4.1 定义了空 messages 的防御，但未定义 `messages: [null, 123, "string"]` 等畸形输入。Erlang 在遍历提取 `LastUserPrefix` 或计算 `has_multimodal` 时若直接 pattern match `#{role := <<"user">>, content := Content}`，遇到非 map 元素会抛出 `badmatch` 或 `function_clause`。虽然 §2.3 的 try/catch 会兜底为 `pass`，但这会将恶意畸形请求直接透传给上游 proxy，可能引发更深层的崩溃。**建议**：在 `features/1` 入口处加一层 `is_list(Messages) andalso lists:all(fun is_map/1, Messages)` 的快速校验，失败直接返回 `{error, invalid_messages}`。

2. **`tools` 字段存在但非 list 类型**
   类似地，若客户端传入 `"tools": "invalid"`，`tools_est` 尝试 JSON 编码或遍历时可能异常。需明确 `has_tools` 和 `tools_est` 对非 list 类型的防御性处理（视为无 tools）。

3. **极端 Token 估算溢出**
   虽然 Erlang 整数是任意精度，不会像 C 那样整型溢出，但若客户端传入一个几 GB 的纯 ASCII 字符串，`byte_size / 4` 会产生巨大的整数。后续与 `fast_ctx_tokens` 比较虽安全，但在 ETS 缓存 key 计算 `phash2` 或日志打印时可能造成 CPU/内存尖峰。**建议**：在特征提取阶段对单条 message 长度设置一个合理的物理上限（如 10MB），超限直接拒绝。

4. **`marker_hit` 的正则/词边界 ReDoS 风险**
   规格提到“ASCII 标记做词边界匹配”。如果使用正则表达式实现 `\bmarker\b`，且 markers 可配置，恶意用户可能配置或触发复杂的正则回溯。需确认底层使用的是安全的词边界算法（如基于字符分类的手动扫描）而非通用正则引擎。

## C. 具体可执行的改进建议

1. **统一缓存 Key 构造中的截断边界条件**
   §5 提到 `SysPrefix` 取前 256 字符，`LastUserPrefix` 取前 1200 字符。需明确这里的“字符”是 Unicode Codepoint 还是 UTF-8 Byte。如果是 Codepoint，`binary:part/3` 会在多字节字符中间截断导致非法 UTF-8，进而影响后续 `phash2` 或 judge 输入。建议统一使用 `string:slice/3` 或明确截断到合法的 UTF-8 边界。

2. **优化 Judge Worker 信号量获取的公平性**
   §6.2 提到 `atomics` 实现全局 in-flight 计数。在高并发下，简单的 `atomics:compare_exchange` 自旋可能导致 CPU 浪费或饥饿。建议使用带超时的 `ets:update_counter` 配合 write_concurrency，或者明确信号量满时的行为是立即降级（当前设计）而非阻塞等待，并在文档中强调“满即降级”以管理预期。

3. **细化熔断器的恢复机制**
   §6.2 规定“连续 5 次失败 → 熔断 60s；任一次成功清零”。但在熔断期间，所有请求直接走 default_tier，不会有新的 judge 调用产生，因此“任一次成功清零”在熔断期内不可能发生。需明确是 60s 后自动半开（Half-Open）放行一次探测，还是 60s 后直接重置计数器。建议采用标准的 Half-Open 状态机。

4. **为 `default_tier` 解析失败提供明确的 fallback**
   §7 tier 解析第 2 步：soft 档不可用 → default_tier 档重试。但如果 `default_tier` 本身（如 fast）的所有候选模型也全部下线，此时返回 `no_route`。建议在启动校验中增加一条：若 `default_tier` 的所有候选模型均不在 catalog 或不可用，直接阻止服务启动或发出 critical alert，因为这意味着任何 soft 路由都会必然失败。

5. **补充 `stream: true` 请求的路由兼容性说明**
   §6.1 强制 judge 请求 `stream: false`，这是正确的。但主请求（被路由的请求）可能是 `stream: true`。需在规格中明确声明：路由决策发生在流式传输开始之前（仅改写 body.model），因此主请求的 stream 属性不受 judge 同步调用的影响，避免实施者产生混淆。

---
**结论**：v2.2 修复了前三轮的核心逻辑漏洞，整体架构趋于成熟。但上述指出的 **A1（规则 0 缺失兜底）、A2（缓存幽灵命中）、B1/B2（畸形消息防御）** 属于影响正确性与可用性的实质问题，需在 v2.3 中修复。暂不 PASS。
