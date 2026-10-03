# Review v2 by glm-5.3 (glm-5.3)

_81.9s · completion_tokens=4000_

让我仔细分析这份 v2 设计规格。这是第二轮评审，上一轮的关键缺陷声称已修复。我需要：

A. 仍然存在的缺陷或 v2 新引入的问题（最多 5 条）
B. 遗漏的边界情况（最多 5 条）
C. 具体可执行的改进建议（最多 5 条）

让我逐条深挖。

## 一、检查 v1 缺陷修复情况

### 修 A1：规则门先于缓存
流水线重排后：①特征 → ②规则门 → ③判分区（缓存仅在此）。
看起来修了。但注意规则门的条件包含 `ctx_tokens`、`has_images`、`has_tools`、`marker_hit`、`msg_count`。缓存 key 是 `{system前256, 末条用户前512, tools指纹, has_images, ctx_tokens div 4096}`。
- `msg_count` 不在缓存 key 中！规则 4 依赖 `msg_count ≤ 3`。如果两个请求有相同的 system/末条用户消息/has_images/ctx 分桶，但 msg_count 不同（比如 1 vs 10），且都落到判分区……等等，如果 msg_count ≤ 3 且 ctx 小且无 tools → fast（不进判分区）。如果 msg_count = 10，则可能进判分区，judge 说 big。然后另一个请求 msg_count = 2、ctx_tokens 略大（超过 fast_ctx_tokens）→ 不命中规则 4，进判分区 → 缓存命中 big。这本身不是 bug——缓存命中的结果是 judge 的结论，judge 只看到末条用户消息，本来就不感知 msg_count。但从语义上讲，同一个用户输入在长会话 vs 短会话中理想档位可能不同。缓存 key 不含 msg_count 本来就是 judge 特征子集的问题。不过更严重的是：`marker_hit` 不在缓存 key！规则 3 marker_hit → flagship，不进判分区，所以 marker 请求不会被缓存污染。但是反过来：一个带 marker 的请求走规则 → flagship；一个不带 marker 的相同文本请求进判分区 → judge → 写缓存。之后另一个带 marker 的请求？marker 检查在缓存之前，仍然走规则 → flagship。OK，缓存读只发生在判分区，规则门在前，所以规则门特征（has_images、ctx 分桶、marker、msg_count、tools）差异不会导致规则结果被缓存绕过——因为规则先执行。缓存 key 里冗余计入 has_images 和 ctx 分桶是"防御性"，其实没必要但不有害。
等等，还有一个问题：缓存 key 含 `ctx_tokens div 4096`，而规则 2 用 `ctx_tokens × 1.2 > big_ctx_tokens`。ctx_tokens 跨越 4096 边界的两个请求可能一个走 big（规则 2），一个进判分区。规则先执行所以没有绕过问题。缓存 key 的 ctx 分桶使得估算误差导致的分桶抖动只会导致缓存 miss，不会错误命中。可以接受。

真正的问题：**`marker` 变更后缓存不失效**——不，marker 不影响 judge 结论的适用性，因为 judge 结论基于内容。OK。

### 修 A2：crash 与 5xx 承诺矛盾
v2 声称 `maybe_route` 全体 try/catch，"永不 5xx"。但要检查：catch 的是 `maybe_route` 内部异常。如果 features 提取、ETS 读取、phash2 都在 catch 内，OK。但问题是：
1. **Erlang 的 try/catch 抓不住 exit 信号吗？** 抓得住。catch 也抓不住的是进程被 kill（brutal_kill）和 system limit 之类。monitor+kill 是对 judge 子进程的，不影响调用方。基本 OK。
2. 但 §2.3 说"内部任何异常一律降级 pass"。而 §8 说"目标档为空 → default_tier；default_tier 也为空 → 404 no_route"。404 是 4xx，不是 5xx，承诺"永不 5xx"字面上兑现。OK。
3. 慢是新的故障模式：judge 同步调用 1500ms 超时 + 熔断。请求延迟上界约 1500ms。这没违反 5xx 承诺但 v2 没提延迟预算。judge 慢时每个未熔断请求都要等满 1500ms 才降级——负缓存只对"同一特征"生效，不同请求特征不同，各自都要吃一次 1500ms 超时。连续 5 次失败才熔断，且熔断计数是全局还是 per-什么？熔断状态存哪？多节点各自独立。**熔断窗口内的并发请求**：高并发下熔断未触发前，N 个并发请求各挂一个 judge 子进程，各自 1500ms 超时，上游 judge 模型被打挂——这本身是 judge 自我 DDoS。v2 加了负缓存（同特征 30s），但不同用户请求特征几乎必然不同（末条用户前 512 字符），负缓存命中率极低。所以 judge 故障时的放大系数 = 并发数 × 1500ms。这算仍然存在的缺陷：**judge 故障时的尾延迟与进程放大没有全局限流**。熔断连败 5 次是串行累计还是并发计数？如果是全局计数器（ETS），并发下可能瞬间超过 5 个 in-flight。可以提"限制 judge 并发 in-flight 数（信号量）"。

### 修 A3：judge 加固
- monitor+kill、唯一 Ref 选择性接收——OK，迟到的 judge 响应消息不会污染邮箱。但被 kill 的 gun 连接"由 gun 自行回收"——gun 是 per-process 的？如果 judge 调用复用连接池，kill 的是调用进程，连接池的 owner 是别的进程，kill 调用进程不影响池。如果每次 judge spawn 新进程新建 gun 连接，kill 后连接是否关闭取决于 monitor/链接关系。规格没说 judge 调用进程是否 owner 连接。模糊但算细节。
- "被杀进程的上游连接由 gun 自行回收"——如果 judge 进程被 kill 而它持有 gun 连接的 owner 身份，gun 进程通常 link 到调用者？gun:open 的 owner 是调用进程，owner 死亡时 gun 进程收到 EXIT 会关闭连接。但如果用了共享池，则不涉及。这句描述含糊，但不算重大缺陷。
- "取最后一个匹配词，避免 'not flagship, big' 误判"——新问题！取最后一个匹配词：如果 judge 输出 "fast, then escalate to big because task looks complex"，取 big。这算合理启发式。但如果输出是 "big" 之后又输出 "flagship" 呢？歧义。更严重的是反向例子：白名单精确全词匹配 + 取最后一个，如果 judge 有思考前置（max_tokens 200 留给思考型 judge），思考文本里出现 "flagship" 就会误判。temperature 0 + max_tokens 200，思考型 judge 的前置 token 可能吞掉 200 预算，实际输出被截断，解析失败 → 降级，可接受。但思考文本中包含档位词的概率不低（分类指令里就有这些词！指令含输出白名单说明，judge 复述白名单 "valid outputs: fast/big/flagship" → 输出以白名单复述结尾？不，取最后一个匹配词，复述白名单时最后一个词是 flagship，误判为 flagship！）。这是 v2 新引入的问题：**指令里含白名单词 + "取最后一个匹配词"的组合，遇到 judge 复述指令（指令跟随不佳的小模型常见）会系统性偏向 flagship**。白名单匹配应该只取首词或首行，或者匹配输出末尾的 standalone 词。规格自称"精确全词匹配"，但没定义取哪个。它定义了：取最后一个。风险如上。

### 修 A4：token 估算
cjk_chars × 1.5 + other_bytes/4 + tools/4 + max_tokens。
- 问题：`max_tokens` 计入 ctx_tokens。但规则 4（fast 档判定）用 `ctx_tokens < fast_ctx_tokens`，而规则 2 用 `ctx_tokens × 1.2 > big_ctx_tokens`。max_tokens 是输出预留，计入 ctx 后：客户端请求 max_tokens=4000 + 3000 token 上下文 → ctx_tokens=7000+，超过 fast_ctx_tokens=8000 吗？6000+4000×1?算一下：如果 max_tokens=8000，ctx_tokens ≥ 8000，规则 4 永不命中 fast！客户端设置大 max_tokens 是常见默认（有些 SDK 默认 4096 或不设）。不设 max_tokens 呢？`max_tokens` 字段缺失时按 0？规格没说缺失时的处理。如果客户端不传 max_tokens（OpenAI 新 API 用 max_completion_tokens），估算漏算输出预留，规则 2 的余量 1.2 是针对上下文的，输出不设限可能溢出。而且 OpenAI 兼容字段有两个：`max_tokens` 和 `max_completion_tokens`，v2 只提 max_tokens。
- 更关键的问题：**规则 2 的安全余量 ×1.2 乘在了含 max_tokens 的 ctx_tokens 上**。如果 max_tokens 本身就很大（例如 8k 输出 + 40k 上下文，big_ctx=60000），40k×1.2=48k < 60k，加 max_tokens 8k = 48k？顺序：ctx_tokens 已含 max_tokens，所以 (40k_ctx + 8k_max) × 1.2 = 57.6k < 60k → 不升档？但真实需求 48k < 60k，OK 不溢出。如果 (45k + 8k)×1.2 = 63.6k > 60k → big。真实 53k < 60k，误升可接受。溢出风险：模型窗口是 ctx+output 共享吗？取决于上游。保守方向正确。但 max_tokens 计入后 ×1.2 双重放大，会导致频繁误升 big——成本问题不是正确性问题。可以提。
- **`tools schema 字节 ÷ 4`**：JSON schema 的 token 密度其实不是 4 bytes/token——JSON 结构字符多，实际 ~3 bytes/token 甚至更碎，但 4 是保守低估吗？高估 token 意味着高估 ctx → 更容易升档（安全方向）。schema 用 ÷4 低估了 token 数（实际更碎），偏危险方向？JSON `{"type":"function",...}` 大量引号、括号，tokenizer 下每 token 平均可能 2-3 字符，÷4 低估。但还有 1.2 全局余量兜底。边缘可提，但价值低。
- base64 图片不计入字节数：多模态请求 content 里 image_url 通常是 URL 或 base64 data URI。规则 1 has_images → flagship。但如果图片在**非末条**历史消息中而末条是纯文本，has_images 检测是"任一 message content parts"，OK 全扫。但**音频** input_audio？视频？has_images 只查 image_url/input_image，audio parts 不计 → 音频请求被当纯文本路由，且音频 base64 不计入字节数（"多模态 parts 的 base64 不计入"——这句说的是多模态 parts 泛指还是仅图片？原文："多模态 parts 的 base64 不计入字节数（has_images 已由规则 1 处理）"——括号说明理由是规则 1，那音频 parts 的 base64 也不计入但没有规则兜底 → 音频内容被严重低估 token，可能落到 fast 并溢出。这是遗漏边界情况（B 部分）：非图片多模态。
- ctx_tokens div 4096 分桶在缓存 key：估算含 max_tokens 和 tools，意味着缓存 key 含这些，OK 一致。

### 修 A5：取消跨档回退
"目标档为空 → default_tier → 404 no_route"。
但注意 §9 表："目标档候选全不可用 → default_tier 档重试一次"。与 §8 一致。"候选全不可用"指 tier 配置了但 LB/健康检查全部 down。而"档为空"指配置为空列表。两种情况都归到 default_tier。
问题：**降级到 default_tier（fast）可能违反硬约束**。如果规则 2 判定需要 big（因为 ctx 大），而 big 档全不可用 → 降级 default_tier = fast（8000 ctx）→ 请求打到 fast 模型 → **上游 400 context length exceeded**。这不是 5xx，是上游返回的错误，但"永不 5xx"承诺下用户收到的是上游 4xx/失败——比 5xx 更糟，因为语义错误：明知会溢出还发送。v2 取消跨档"回退"（指降档省钱？A5 说"跨档回退烧钱"——v1 的回退是向上 fallback 到更贵模型），v2 的 default_tier 兜底在 big 空时仍然把大上下文请求塞给 fast。**规则门结论（big/flagship）失败时应直接报错而非塞 default_tier**，尤其 flagship 是图片硬约束——big 档空 + 图片请求 → default_tier=fast 的纯文本模型 → 上游报不支持图片。这条很实在：**规则门硬约束结果不应落入 default_tier 兜底**。v2 没区分"judge 结论"与"规则硬结论"的失败语义。这是仍然存在的缺陷（A 部分）。

### 修 A6：自引用
启动校验拒绝 judge_model/tier 候选 == 虚拟模型名。但还有间接自引用：tier 里配另一个虚拟模型？当前只有一个虚拟模型 janus-auto，但如果未来/部署者用 routes 把 janus-auto 指到别处？规格说虚拟模型不需要自身 routes。间接环：janus-auto 的 tier 里放了 provider X 的模型 M，而 M 的 route 又指回 janus 网关的 janus-auto？routes 支持指向另一个 Janus 实例的话可能环。边缘。低价值，可不提或并入建议。
另一个：**缓存配置校验结果**——"首次读取配置时执行，结果缓存"。热更新配置（sys.config 不会热更，但如果用 app env set 热更）后校验不重跑？"首次读取配置时执行，结果缓存"——如果运行时更新 app env，校验结果缓存导致旧校验。小问题。可提 B 或不提。

### 修 A7：授权定案
"key 默认可访问所有模型，api_key_models 只对原始名生效，改写后不二次校验"。
这是定案（产品决策），但存在实际风险：部署者用 api_key_models 限制某 key 只能访问便宜模型；客户端请求 janus-auto（如果 janus-auto 在该 key 白名单里），改写后可能路由到 flagship——**绕过了部署者的成本控制意图**。规格说"key 是身份不是配额"，但 api_key_models 功能存在就说明有人用它做限制，auto-router 使它失效且是静默失效。至少应该：janus-auto 是否在 api_key_models 白名单内可被发现（文档/日志），或提供配置项"改写后校验目标 ∈ key 白名单，不满足则降档而非 5xx"。这是仍然存在的设计缺陷（或有意的取舍但缺 mitigation）。上一轮已"定案"，我不该翻案？评审角度：定案为"不存在越权概念"，但这与 Janus 现有 api_key_models 语义冲突，至少要在文档/配置上给部署者逃生门。可以作为 A 部分一条：定案 A7 与 api_key_models 现有语义的静默冲突，建议至少提供可选的"tier 候选 ∩ key 白名单"过滤。嗯，但这算"翻案"吗？我可以说：定案本身可接受，但缺一个显式的部署者告知机制（比如启动时若检测到任何 key 配了 api_key_models 且包含 janus-auto，warn 一次）。这样不算推翻定案，是补 mitigations。

### 修 A8：删除自身 routes 兜底池
"models 表一行仅用于 /v1/models 展示"。OK。但这行 model 的 routes 为空，如果客户端直接 GET /v1/models 拿到 janus-auto，然后用某些字段（如 owned_by / max_tokens）？无所谓。OK。

### 修 A9：缓存哈希扩域、重试粘性
phash2 到 2^28 域，4096 行容量。OK。
问题：**末条用户前 512 + system 前 256 作为 key**——重试粘性要求"同请求重试不重复判分"。重试时请求体完全相同 → key 相同 → 命中。OK。但如果重试时客户端修改了 max_tokens（部分客户端重试会调整），ctx_tokens 变 → 分桶变 → miss → 再判分一次。可接受。
**前 512 字符截断的碰撞**：两个不同请求共享前缀（模板化 prompt、RAG 固定头）→ 同 key → 共享 judge 结论。这在"重试粘性"语义下变成了"前缀相同即粘"，缓存污染面扩大：攻击者或普通模板用户共享前缀会共享档位。判分区输入本来也是这些前缀（judge 只看前 1200 字符末条用户消息），所以 judge 结论本来就只基于前缀——缓存 key 与 judge 输入近似一致，语义自洽。不算缺陷，是设计选择。但要注意：**system 前 256 字符**——多 system message？取第一条 system 还是拼接？规格没说。messages 里可能没有 system（都在 user 里）。edge case。

## 二、找 v2 新引入的问题

1. **"取最后一个
