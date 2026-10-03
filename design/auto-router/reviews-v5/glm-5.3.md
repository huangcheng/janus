# Review v2.3 by glm-5.3 (glm-5.3)

_62.1s · completion_tokens=4000_

让我仔细分析这份 v2.3 设计文档，这是第五轮评审。我需要找出仍然存在的缺陷、遗漏的边界情况，以及具体可执行的改进建议。

让我逐个部分审查：

## 1. 规则门的逻辑分析

规则优先级：
- 0: est_total > max_ctx_tokens → 400
- 1: has_multimodal → flagship (hard)
- 2: marker_hit → flagship (hard)
- 3: (prompt_est + tools_est) × 1.2 > big_ctx_tokens → big (hard)
- 3b: est_total > big_ctx_tokens → flagship (hard)
- 4: not has_tools 且 est_total < fast_ctx_tokens 且 msg_count ≤ 3 → fast (定向 hard/可用性 soft)
- 5: 其余 → 判分区

让我思考边界情况：

### 规则 3 与 3b 的交互问题

规则 3: `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` → big
规则 3b: `est_total > big_ctx_tokens` → flagship

考虑一个情况：prompt_est + tools_est 很大（超过 big），但有 multimodal → 规则 1 先命中 → flagship。OK。

考虑：规则 3 命中 → big。但如果 est_total > big_ctx_tokens 也同时成立呢？规则 3 先于 3b，所以会去 big。但等等，规则 3 命中条件是 `(prompt_est + tools_est) × 1.2 > big_ctx_tokens`，意味着 prompt 部分×1.2 已超 big 窗口。而 est_total = prompt_est + media + tools + max_out ≥ prompt_est + tools_est。如果 (prompt+tools)×1.2 > big，那么 est_total 是否 > big？

(p+t)×1.2 > big ⟹ p+t > big/1.2。est_total = p+t+media+max_out ≥ p+t + 4096 (max_out 默认)。

不一定 est_total > big。例如 big = 60000，p+t = 50001（×1.2 = 60001.2 > 60000 命中规则 3），但 est_total = 50001 + 0 + 4096 = 54097 < 60000，不命中 3b。这时去 big。但是 p+t = 50001 + 输出 4096 = 54097 < 60000，big 档装得下吗？big_ctx_tokens 语义是总窗口 60000。prompt+tools+output = 54097 < 60000，OK 装得下。

但考虑另一个方向：规则 3 用 ×1.2 余量，而规则 3b 不用余量。规则 3b 命中时 est_total > big_ctx_tokens，即 p+t+m+o > big。这些去 flagship。部署者保证 flagship ≥ big。OK。

反过来：一个请求 p+t = 49000，media = 8000（2个part），max_out = 8192。est_total = 49000 + 8000 + 8192 = 65192 > 60000 → 3b → flagship。OK。

再看：p+t = 49000，×1.2 = 58800 < 60000 不命中规则 3。media = 0，max_out = 16384。est_total = 65384 > 60000 → 3b → flagship。OK，max_out 溢出的修复生效。

再看规则 3 命中但 est_total 未超 big：p+t = 55000 ×1.2 = 66000 > 60000 → big。max_out = 4096，media = 0。est_total = 59096 < 60000 不命中 3b。去 big。big 窗口 60000，实际 p+t+max_out = 59096 < 60000 OK。但注意：规则 3 的 ×1.2 是"prompt 生成膨胀"的余量（假设 completion 会引用 prompt 内容？），这里只保证 p+t+o < big。好像合理。

但是等等，有个细节问题：规则 3 命中去 big，但规则 3 的条件 (p+t)×1.2 > big 意味着如果输出膨胀 20%，big 就装不下。但这是设计取舍——×1.2 就是余量。可以接受。

### 规则 3b 与规则 3 顺序问题

规则 3 在 3b 之前。如果两者同时命中（p+t×1.2 > big 且 est_total > big），则规则 3 优先 → big。但 est_total > big 意味着 p+t+m+o > big。去 big 的话，big 窗口可能装不下！

例：p+t = 55000（×1.2 = 66000 > 60000 命中规则 3），max_out = 8192，media = 0。est_total = 63192 > 60000 也命中 3b。但规则 3 先命中 → big！big 窗口 60000 装不下 63192。这是一个真实缺陷：规则 3b 应该在规则 3 之前，或者规则 3 命中后还需检查 est_total ≤ big_ctx_tokens。

等等，让我重新读规则表。优先级自上而下：0, 1, 2, 3, 3b, 4, 5。所以规则 3 先于 3b。当两者都命中时，规则 3 生效 → big。

这正是四轮评审修复的"max_out 溢出 big 窗口"问题——但修复方式（新增 3b 放在 3 之后）没有完全修复：当 p+t 已经很大（命中规则 3）且 max_out/media 也大时（est_total 超 big），请求仍会去 big 并可能溢出 big 窗口。

具体数字：big_ctx_tokens = 60000。p+t = 50001 → ×1.2 = 60001.2 > 60000，命中规则 3。max_out = 16384（客户端明确要求长输出）。est_total = 66385 > 60000 命中 3b 但永远不会被评估。请求 → big，窗口 60000 < 66385。上游可能报错或截断。

这是 A 类缺陷 #1：规则 3 与 3b 同时命中时，规则 3 优先导致 est_total > big 的请求仍落入 big 档，四轮修复的"max_out 溢出"问题只修了一半。修复：交换顺序（3b 在 3 前）或规则 3 附加条件 est_total ≤ big_ctx_tokens。

其实最简单的修复：规则 3 改为 `(p+t)×1.2 > big 且 est_total ≤ big_ctx_tokens` → big；否则若 est_total > big → flagship。或者直接把 3b 放在 3 前面。

等等，再想一下：3b 放前面会不会误伤？3b 命中条件 est_total > big。若 3b 在前，est_total > big 的都去 flagship（flagship ≥ big 保证），不会误伤规则 3 场景——flagship 装得下。而 est_total ≤ big 但 (p+t)×1.2 > big 的去 big（p+t+o ≤ est_total ≤ big，装得下，即使生成膨胀 20% 也有……等等，膨胀 20% 的话 p+t+o 可能超过 est_total 吗？生成的内容不需要在窗口里重新计费……实际上生成 token 是另外算的。总上下文 = prompt + completion ≤ window。est_total 估算 p+t+o，如果实际 completion 是 o 的 1.2 倍，可能溢出。但这是所有档位共同的估算误差，×1.2 是对这种不确定性的防御，只对 prompt 部分乘是因为……好，这个设计取舍在文档里说明了）。

所以 3b 前置是干净修复。这确实是 A 类缺陷。

### 规则 4 的 est_total 包含 max_out 影响 fast 判定

规则 4: `not has_tools` 且 `est_total < fast_ctx_tokens` 且 `msg_count ≤ 3` → fast。

est_total 含 max_out（默认 4096）。fast_ctx_tokens 默认 8000。一个短请求 prompt_est = 100，无 tools，msg_count = 2，但客户端明确设置 max_tokens = 5000。est_total = 100 + 0 + 0 + 5000 = 5100 < 8000 → fast。OK 装得下。

但如果 fast_ctx_tokens = 6000，max_tokens = 8000（客户端想要长输出），est_total = 8100 > 6000 → 不命中规则 4 → 判分区。judge 可能判 fast → fast 档 6000 窗口装不下 8100！判分区 soft 结论只依赖 judge 或 default_tier，不检查容量。

等等，判分区的结论会不会也检查窗口？看文档：判分区结论 soft，tier 解析只检查可用性不检查容量。judge 输出 fast/big/flagship，如果 judge 判 fast 而实际 est_total > fast_ctx_tokens，fast 档装不下。上游报错或截断。

这是 A 类缺陷 #2：判分区（规则 5/judge）结论缺少容量下限校验——judge 判 fast 但 est_total 超过 fast 档窗口时直接落 fast，可能溢出。规则 4 有 est_total < fast_ctx_tokens 检查，但 judge 的 fast 结论没有对应检查。修复：judge 结论为 fast 时校验 est_total ≤ fast_ctx_tokens（或 big），否则升到 big；同理 judge 判 big 时校验 est_total ≤ big_ctx_tokens。

其实再想想：进入判分区的请求是规则 3/3b 未命中的，即 (p+t)×1.2 ≤ big 且 est_total ≤ big。所以 est_total ≤ big_ctx_tokens 有保证（要么 3b 未命中……等等，3b 未命中即 est_total ≤ big_ctx_tokens，对）。所以判分区请求的 est_total ≤ big_ctx_tokens。因此 judge 判 big 是安全的（big 装得下）。但 judge 判 fast 呢？est_total 可能 > fast_ctx_tokens（比如 10000），fast 档 8000 装不下。judge 只看到 system 256 + user 1200 字符前缀，不知道 est_total。判 fast → 溢出。

类似地 default_tier = fast 时：进入判分区的请求 est_total 可达 big_ctx_tokens（60000），规则 3/3b 未命中就判分区，若无 judge → default_tier = fast！一个 59000 token 的请求（p+t 未超 50000，est_total = 59096 ≤ 60000）无 judge 时走 rules-only → default_tier = fast。fast 档默认 8000 窗口，59096 装不下！这是严重缺陷。

等等，让我重新捋：rules-only 时，未指派 judge → default_tier（soft）。哪些请求进入判分区？规则 0/1/2/3/3b/4 都未命中。规则 4 未命中可能是：有 tools、或 est_total ≥ fast_ctx_tokens、或 msg_count > 3。所以一个 est_total = 59096 的无 tools 请求：规则 3？p+t = 55000，×1.2 = 66000 > 60000 命中规则 3 → big。好。换个例子：p+t = 45000，media = 0，max_out = 14096。est_total = 59096 ≤ 60000（3b 未命中）。p+t ×1.2 = 54000 ≤ 60000（规则 3 未命中）。无 multimodal、无 marker、not has_tools 但 est_total = 59096 > 8000 = fast_ctx_tokens → 规则 4 未命中 → 判分区 → 无 judge → default_tier = fast！

fast 档窗口由部署者配置 fast_ctx_tokens = 8000 语义……等等，fast_ctx_tokens 是"总窗口语义"吗？文档说 `big_ctx_tokens / fast_ctx_tokens 语义为总窗口`。所以 fast 档模型窗口 = 8000。59096 token 请求发到 8000 窗口的模型 → 上游 400 错误。

这是 A 类重大缺陷 #2（把两个合并为一个：default_tier / judge 结论落 fast 时无 est_total ≤ fast_ctx_tokens 校验）。而且 default_tier 默认是 fast！长请求（5 万 token）在 rules-only 模式下全部砸到 fast 档 8000 窗口。

等等，我需要确认这个场景是否真实：rules-only 模式（judge 未指派），请求 p+t = 45000（约 18 万字节的英文），max_out = 16384。这在现实中会发生吗？会——用户上传长文档摘要请求很常见。est_total = 61384 > 60000 → 3b 命中 → flagship。好。那 p+t = 44000，max_out = 16384：est_total = 60384 > 60000 → 3b 命中。要构造 3b 未命中且规则 4 未命中的：est_total ≤ 60000 且 est_total > 8000（fast）。比如 p+t = 30000，max_out = 8192，est_total = 38192。规则 3：30000×1.2 = 36000 < 60000 未命中。规则 4：est_total 38192 > 8000 未命中。判分区 → rules-only → default_tier = fast（8000 窗口）。38192 token 请求进 8000 窗口 → 必然失败。

这是明确的正确性/可用性缺陷。修复：default_tier 落点及 judge 结论落 fast 时校验 est_total ≤ fast_ctx_tokens，否则升 big（big 已由 3/3b 保证装得下——等等 3b 未命中保证 est_total ≤ big，规则 3 未命中保证 (p+t)×1.2 ≤ big，所以 big 装得下 est_total）。或者 rules-only 时判分区结论用容量规则推导：est_total ≤ fast_ctx → fast，否则 big。

嗯，其实更简单的修复：判分区（soft 结论）落 fast 前检查 est_total ≤ fast_ctx_tokens，不满足升 big。这是边界校验遗漏。

### 规则 0 与 max_ctx_tokens 的联动

规则 0：est_total > max_ctx_tokens → 400。但只拦下了超过全局硬上限的。flagship 是最高档。如果 est_total ≤ max_ctx_tokens 但 > flagship 实际窗口呢？零假设：Janus 不知道模型窗口，部署者保证 max_ctx_tokens ≤ flagship 窗口。文档没有明说这个部署者义务，但"容量防线总述"说"任何请求至多到达 flagship 档"。规则 0 配置了的话防线成立。未配置 max_ctx_tokens 时，请求最大到达 flagship（3b 保证 est_total ≤ big ≤ flagship）。OK。

但有个问题：max_ctx_tokens 校验"已配置但 < big_ctx_tokens ⇒ error + 忽略该上限"。也就是部署者配 max_ctx = 50000 < big 60000 时，上限被忽略 → 无全局上限 → est_total 60000~无限 的请求全部去 flagship。flagship 窗口未知，可能 128000。一个 est_total = 200000 的请求：3b 命中（> 60000）→ flagship。flagship 若是 128000 窗口 → 溢出失败。但这是部署者配置错误（忽略上限后未重新配置），warn/error 提示了。设计上可接受？嗯，"error + 忽略该上限"意味着防线完全消失。更安全的做法是"忽略该上限"改为"error + 拒绝启动"或"取 min(两值)"……不过启动校验已经 error 日志。这个算 C 类建议，不算大缺陷，因为部署者收到 error 日志。但如果部署者不看日志……算了，这算轻微。

### 决策缓存的 key 碰撞问题

phash2 2^28 域，容量 4096，碰撞概率 ~3e-5。接受。但注意：碰撞后果是错误档位，影响成本不正确性。低概率可接受。

### 缓存 key 缺少 media/tool_choice 等

ToolsFp 覆盖 tools。msg_count 不在 key 里——判分区请求缓存 key = {SysPrefix, LastUserPrefix, ToolsFp, HasMM, prompt_est_bucket}。两个请求 user 前缀相同、prompt_est 相同 bucket（0-4095 差异）、但实际长度差 4000 → 结论复用。设计选择，文档已声明（"缓存 key 是 judge 输入的子集摘要……设计选择"）。可接受。

但等等：缓存 key 没有包含 max_out / media_allowance 的具体信息！prompt_est_bucket 只 bucket 了 prompt_est，media_allowance 是 est_total 的一部分但不在 key 里。两个请求：A 有 1 张图（media 4096），B 无图，其他相同。HasMM 不同 → key 不同。OK，HasMM 在 key 里。但 media_allowance 数量不同（1 图 vs 3 图）HasMM 都是 true → key 相同。judge 输入也不含图数（judge 只看文本前缀）。所以 A 和 B 的 judge 输入完全一样 → 结论一样 → 缓存复用无碍。OK 不是问题。

### 规则 4 的 msg_count ≤ 3 与 marker

规则 2 marker 优先于规则 4。marker 只检查末条 user 消息。msg_count ≤ 3 的短请求带
