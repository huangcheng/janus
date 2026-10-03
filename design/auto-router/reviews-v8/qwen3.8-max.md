# Review v2.5-final by qwen3.8-max (qwen3.8-max)

_29.4s · completion_tokens=1201_

# Janus Auto Router v2.5 终审报告

经严格审查，v2.5 修复了前两轮指出的全部关键缺陷（规则重排、媒体封顶、FIFO 语义、信号量释放），整体架构成熟度极高。但仍发现以下影响正确性、可用性或安全性的实质问题：

## A. 仍然存在的缺陷或新引入的问题

1. **信号量 `after` 释放的竞态死锁（可用性/正确性）**
   §6.2 规定“获取后在 `after` 块中保证释放”。如果 Caller 成功获取信号量并 `spawn_monitor`，但 Caller 进程在收到 `{Ref, Tier}` 或 `DOWN` 之前**因外部原因崩溃**（如 HTTP handler 被客户端断开连接导致退出），Caller 的 `receive...after` 根本不会执行，信号量将永久泄漏，最终导致所有 judge 调用被跳过。
   *修复建议*：信号量的生命周期必须绑定到 Judge Worker 进程，或者由一个独立的 Monitor 进程负责回收；绝不能依赖 Caller 进程的 `after` 块。
2. **规则 0 与规则 3b 的硬上限矛盾（正确性）**
   §7 启动校验规定：若 `max_ctx_tokens < big_ctx_tokens` 则忽略该上限。这意味着当部署者未配置 `max_ctx_tokens` 时，规则 0 失效。此时若请求 `est_total > flagship_ctx_tokens`（flagship 的实际物理窗口），规则 3b 会将其路由至 flagship，随后被上游 provider 拒绝（400）。路由器未能实现“自身拦截超大请求”的承诺。
   *修复建议*：增加一条隐式规则或修改规则 3b，当 `est_total` 超过某个绝对硬上限（如 `flagship_ctx_tokens` 的配置项）时直接返回 `request_too_large`，而非无脑上旗舰。
3. **缓存 Hash 碰撞导致的跨会话降级（安全性/正确性）**
   §5 使用 `phash2(..., 2^28)` 作为 ETS 键。虽然单表 4096 容量下自然碰撞率低，但攻击者可刻意构造具有相同 Hash 的请求（Hash 输入均为截断文本，极易碰撞）。恶意短请求命中正常长请求的正缓存会导致错误路由；命中负缓存则导致合法请求被强制降级 default_tier 长达 30s。
   *修复建议*：在 Hash 计算中加入当前 API Key 的前缀或 Session ID，将碰撞域隔离在单用户内，防止跨租户投毒。

## B. 遗漏的边界情况

1. **多 System 消息的拼接顺序（正确性）**
   §5 定义 `SysPrefix` 为“所有 system 角色消息的文本按序拼接”。OpenAI API 允许 messages 数组中存在多个不连续的 system 消息。若客户端发送 `[sys_A, user_1, sys_B]`，按序拼接为 `A+B`。不同 LLM 对交错 system 消息的处理权重不同，简单线性拼接可能导致 judge 看到的上下文与实际模型看到的语义存在偏差。
2. **极端 max_out 导致的 est_total 溢出（可用性）**
   §4.1 中 `max_out` 默认值为 4096，但若客户端传入 `max_completion_tokens: 1000000000`，`est_total` 将变得极大，必然触发规则 0 或 3b。这属于客户端畸形参数，但规格未明确说明是否应对 `max_out` 设置一个合理的工程上限（如 128k）以防止特征提取阶段的整数运算异常或无意义的计算。
3. **Judge 响应为空或纯空白字符（可用性）**
   §6.3 解析逻辑取“最后一个非空行”。若 judge 返回空字符串或仅包含换行符，切词和匹配逻辑是否会抛出异常？规格未显式定义此边界下的行为（应明确归入“解析失败 → 降级”）。

## C. 具体可执行的改进建议

1. **信号量所有权转移**：将 `atomics` 信号量的获取动作移入 `spawn_monitor` 的 fun 内部（Worker 启动时尝试获取，失败则自行退出并向 Caller 发送特定标记），确保信号量计数与 Worker 生命周期严格绑定，彻底消除 Caller 崩溃导致的泄漏。
2. **引入 `flagship_ctx_tokens` 兜底**：在配置中新增 `flagship_ctx_tokens`（或复用 `max_ctx_tokens` 的默认值），使规则 0 始终生效，确保没有任何请求能逃逸出路由器的容量防线到达上游报错。
3. **防御性 Hash 加盐**：在 `erlang:phash2` 的元组中加入 `ApiKeyPrefix`（例如 API key 的前 8 个字节），成本极低，但能将蓄意 Hash 碰撞攻击的难度提升数个数量级。
4. **明确 max_out 钳制**：在 §4.1 中增加一句：“`max_out` 取值上限钳制为 `max_ctx_tokens`（若已配置）或 131072，防止客户端传入天文数字干扰估算”。
5. **补充空响应测试用例**：在 §11 eunit 计划中，为 judge 解析模块增加 `<<>>`、`<<"\n\n">>`、`<<"   ">>` 等纯空白输入的测试用例，断言其安全回退至 default_tier。
