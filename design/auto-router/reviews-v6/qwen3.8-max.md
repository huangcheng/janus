# Review v2.4 by qwen3.8-max (qwen3.8-max)

_38.9s · completion_tokens=1642_

# Janus Auto Router v2.4 评审报告

## A. 仍然存在的缺陷或新引入的问题

1. **负缓存与正缓存的遮蔽逻辑存在正确性漏洞（§5）**
   规格定义“读取顺序：先查正条目，命中且未过期即用；仅当无有效正条目时才查负条目”。若某特征此前 judge 成功写入了正缓存（TTL 300s），随后该特征的 judge 调用失败并写入负缓存（TTL 30s）。在负缓存生效的 30s 内，由于“先查正条目”，系统会**直接返回历史正决策，完全无视当前的负缓存**。这导致负缓存在面对已有正缓存的特征时彻底失效，违背了“judge 偶发失败不再覆盖既有成功决策”的设计初衷（防覆盖做到了，但防重试也做过了头，导致降级机制短路）。
   *影响：正确性、可用性。*

2. **Judge worker 进程泄漏风险（§6.2）**
   时序图显示 Caller 在 `after judge_timeout_ms` 时执行 `exit(Pid, kill)`。如果此时 Judge worker 恰好卡在 `gun:open`（DNS 解析阻塞）或尚未建立连接，`kill` 信号会终止 worker，但如果 gun 底层已经向 ETS 注册了某些状态，或者 `spawn_monitor` 的 worker 内部没有对 `gun:open` 做 try/catch 保护，强杀可能导致 gun 内部 socket 跟踪表残留孤儿记录。虽然是一次性连接，但在高并发超时场景下可能引发内存缓慢泄漏。
   *影响：安全性（资源泄漏）、可用性。*

3. **规则 4 的 hard/soft 混合语义实现矛盾（§4.2 & §7）**
   规则 4 定义为“定向 hard / 可用性 soft”，正常落 fast，不可用降级 default_tier。但在 §7 tier 解析中，“规则 hard 结论的目标档全部不可用 → `{error, no_route}`”。如果代码按“规则门输出带有 hard 标签”统一走硬约束分支，规则 4 会被错误地映射为 `no_route`；如果单独为规则 4 写分支，则破坏了“hard/soft 区分是 N2 修复核心”的统一抽象。规格未明确规则 4 在返回值联合类型中的具体标签（是特殊的 `{tier, hybrid}` 还是直接改写为 soft）。
   *影响：正确性。*

4. **多模态估算的极端放大效应（§4.1）**
   `media_allowance = 非文本 part 数 × 4096`。如果一个恶意或异常的请求包含 100 个极小的图片 part（如 1x1 像素 base64），`media_allowance` 将高达 409,600 tokens，直接触发规则 0 或 3b 导致 400 拒绝或被强制路由到旗舰模型。由于缺乏对 part 数量或总大小的上限约束，攻击者可通过构造大量微型 part 绕过正常的 prompt 长度限制，实施 DoS 或强制成本消耗。
   *影响：安全性、成本。*

---

## B. 遗漏的边界情况

1. **`max_out` 极大值导致的整型溢出或误判（§4.1）**
   客户端传入 `"max_completion_tokens": 999999999`。`est_total` 会瞬间膨胀。如果 Erlang 节点使用 32 位虚拟机（虽罕见但存在），大数运算可能异常；即使在 64 位下，极大的 `max_out` 会导致所有请求被规则 0 拦截（400），但用户实际发送的 prompt 极短。规格未说明是否需要对 `max_out` 设置一个合理的上限截断（cap）。

2. **`tools` 字段为非数组类型的畸形输入（§4.1）**
   规格仅提到 `messages` 畸形校验，未提及 `tools` 校验。如果客户端传入 `"tools": "invalid_string"` 或 `"tools": null`，`JSON 编码后的 tools 列表字节 ÷ 4` 可能会抛出异常或产生非预期结果，导致 `maybe_route` 意外 crash 从而触发 §2.3 的 catch -> pass。

3. **配置热更新时的状态不一致（§7）**
   规格提到“配置变更时以配置指纹重算”，但未说明在指纹切换的瞬间，正在 in-flight 的 judge 请求、ETS 中的旧缓存条目、以及基于旧 `fast_ctx_tokens` 计算出的规则结论如何平滑过渡。特别是如果新配置删除了某个 tier，而旧缓存中仍存有指向该 tier 的正缓存条目，读取时会发生什么？

4. **System 消息全为空字符串或非文本（§5 & §6.1）**
   如果 system 消息存在但 content 为空列表 `[]` 或纯图片 part，`SysPrefix` 为空串。这在缓存 key 和 judge 输入中是合法的，但可能导致不同意图的请求在 System 维度上发生哈希碰撞，过度依赖 User 前缀进行区分。

---

## C. 具体可执行的改进建议

1. **重构正负缓存的读取优先级逻辑（针对 A1）**
   修改 §5 的读取顺序：先查正条目和负条目。如果两者均存在且未过期，**以时间戳较新者为准**（或明确规定：负缓存存在时，即使正缓存未过期，也强制走 default_tier，直到负缓存 TTL 结束再恢复正缓存）。这样既防止了失败覆盖成功，又保证了近期失败能有效阻断重试。

2. **增加 `media_part` 数量上限截断（针对 A4）**
   在 §4.1 中明确规定：“非文本 part 数取 `min(实际数量, max_media_parts)`，默认 `max_media_parts = 10`”。防止通过堆砌无意义媒体 part 操纵 `est_total` 进行路由投毒或 DoS。

3. **明确规则 4 的内部表示法（针对 A3）**
   在 §3 流水线或 §4.2 中显式定义规则 4 的输出结构。建议将其定义为 `{tier, fast, soft_fallback}`，并在 §7 的 tier 解析第 1 步中明确指出：“对于 `soft_fallback` 标记的 tier，候选不可用时不返回 `no_route`，而是转入第 2 步的 default_tier 降级逻辑”。

4. **完善 `tools` 与 `max_out` 的防御性提取（针对 B1/B2）**
   在 §4.1 补充：“`tools` 若非 list 则视为空列表（0 token）；`max_out` 若大于 `max_ctx_tokens`（或设定的绝对上限如 128k），则截断至上限值参与 `est_total` 计算”。确保特征提取阶段不因客户端脏数据 panic。

5. **Judge worker 增加优雅退出兜底（针对 A2）**
   在 §6.2 的 worker `fun()` 内部包裹一层 `try...after`：`after` 块中显式调用 `gun:close(Conn)`（如果已建立）。Caller 端的 `exit(Pid, kill)` 改为 `exit(Pid, shutdown)`，给予 worker 几十毫秒清理 gun 状态的机会；仅在 `shutdown` 超时后才由 caller 执行 `kill`。
