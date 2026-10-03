# Review by step-5-preview (step-5-preview)

_60.0s · completion_tokens=4000_

用户要求我作为资深分布式系统与 LLM 基础设施工程师，评审一个 LLM 网关的自动路由设计规格。需要输出三部分：
A. 关键缺陷（会导致故障或错误行为的）
B. 工程风险与遗漏的边界情况
C. 具体可执行的改进建议

每部分最多 5 条，直接给结论和理由，不要客套话。用中文。

我需要仔细分析这个设计规格，找出其中的问题。

先通读一遍设计：

目标：提供 janus-auto 虚拟模型，按请求特征自动路由到 fast/big/flagship 三档真实模型。

核心约束：网关对 provider 世界零假设。judge 必须由用户指派，档位模型列表必须由用户指派。未指派 judge 则 rules-only。judge 失败自动降级。

流水线：
1. model_allowed 检查（对 janus-auto）
2. maybe_route：
   - 决策缓存命中（内容哈希，TTL 300s）→ tier
   - 规则门（确定性，0ms）→ tier 或进入判分
   - judge（仅当用户已指派）→ tier；失败 → default_tier
   - tier → 具体模型名（用户指派列表 ∩ catalog 在售，LB 择路）
3. 改写 body.model → 目标模型 → 既有 proxy 链路

规则门：
1. 含图片输入 → flagship
2. ctx_tokens > big_ctx_tokens (60000) → big
3. 末条用户消息含升档标记 → flagship
4. 无 tools 且 ctx_tokens < fast_ctx_tokens (8000) 且消息数 ≤ 3 → fast
5. 其余 → judge；无 judge 时 default_tier

ctx_tokens 估算：messages 内容字节总量 ÷ 3

Judge：
- 输入：约 200 token 英文分类指令 + system 前 256 字符 + 末条用户消息前 1200 字符
- 请求体：{model=judge 路由, max_tokens=16, temperature=0, stream=false}
- 执行：janus_lb:pick_route → janus_providers_openai:chat_completions，外层 spawn + receive after judge_timeout_ms (1500ms)
- 解析：响应文本小写化，取 fast | big | flagship 首个匹配词；解析失败 = 降级

决策缓存：
- Key：phash2({system 前 256 末条用户前 512, tools 是否存在})
- Value：{Tier, ExpiresAt}；读取时惰性过期；写入时若表 > 4096 行做一轮清扫
- 意义：同会话重复请求不再判分，且天然近似"会话粘性"

配置：
- model => <<"janus-auto">>
- judge_model => undefined
- tiers => #{fast => [], big => [], flagship => []}
- default_tier => fast
- big_ctx_tokens => 60000
- fast_ctx_tokens => 8000
- judge_timeout_ms => 1500
- cache_ttl_sec => 300
- markers => [...]

tiers 内模型名解析失败则跳过；整档为空时按 flagship → big → fast 顺序回退（都空则维持现状 404 no_route）

虚拟模型本身是 models 表普通一行，其自身 routes 可作为"所有档位全空时的兜底 LB 池"。

模块：
- janus_auto.erl
- maybe_route/2
- features/1 / rules_gate/1 / judge/2 / cache_*
- ETS 惰性建表
- 修改 janus_http_chat:proxy_chat/5：resolve_model 前插入 maybe_route

失败语义：
- 未配置 auto_router：pass
- judge 未指派：rules-only
- judge 超时/HTTP错/解析失败：同上
- 目标档候选全不可用：档间回退 flagship→big→fast → 仍失败则 404 no_route
- 路由器自身 crash：chat handler 已有 try/catch → 500

观测：logger.debug

测试计划：eunit + Docker 冒烟

现在找缺陷：

A. 关键缺陷（会导致故障或错误行为）：

1. **决策缓存 Key 设计缺陷导致错误路由**：缓存 Key 只包含 `system 前 256 字符 + 末条用户前 512 + tools 是否存在`，但规则门和 judge 的输入远不止这些。例如，请求 A 和请求 B 有相同的 system 和末条用户消息前缀，但 A 有图片输入（应 flagship），B 没有（可能 fast）。由于缓存 Key 不包含图片输入、消息数、完整 ctx_tokens、markers 等，会导致缓存命中时直接返回 tier，绕过规则门，造成错误路由。更严重的是，如果缓存的是 judge 结果，但后续请求虽然前缀相同，实际内容不同（比如末条用户消息前 512 相同但后面不同），也会错误复用。这会导致功能错误。

2. **ctx_tokens 估算严重偏差导致规则门误判**：`messages 内容字节总量 ÷ 3` 对于纯英文可能低估（英文平均 4 字符/token），对于中文可能高估（中文通常 1-2 字符/token），但这不是最严重的。最严重的是它包含了所有消息（包括 assistant 历史回复），而 LLM 的上下文窗口通常只计算输入 token，但这里把整个对话历史都算进去了。不过更关键的是，这个估算没有考虑 tools/function calling 的 schema 开销，也没有考虑图片 token（图片输入在规则 1 已经处理了，但 ctx_tokens 仍然包含图片的 base64 字节数，导致 ctx_tokens 虚高，可能错误触发 big 档）。实际上，如果请求包含图片，规则 1 已经路由到 flagship，但 ctx_tokens 的计算会把图片 base64 算进去，可能让其他没有图片但字节数大的请求误判。不过规则 1 优先，所以有图片一定 flagship。但没有图片时，base64 不存在。主要问题是 tools schema 可能很大，但不计入 messages 字节。等等，规格说 "messages 内容字节总量"，可能不包括 tools。但即使如此，用字节÷3 估算 token 对于代码、JSON 等可能偏差很大。不过这是"量级正确"可以接受。更关键的是：**规则 2 和规则 4 使用 ctx_tokens，但缓存 Key 不包含 ctx_tokens 或消息数**，所以两个 ctx_tokens 差异很大的请求可能共享缓存 key（如果 system 和末条用户前 512 相同），导致一个长请求命中短请求的缓存 tier。

3. **Judge 请求与用户请求共享连接/路由可能导致死锁或资源耗尽**：规格说 judge 使用 `janus_lb:pick_route` 和 `janus_providers_openai:chat_completions`，但没有说明是否复用了用户请求的进程或连接。如果 judge 是在 chat handler 进程中 spawn 的，并且 `receive after` 等待，这本身没问题。但 `janus_providers_openai:chat_completions` 如果是同步阻塞调用，在 spawn 的进程中调用也可以。然而，**没有限制 judge 的并发量**。如果大量请求同时进入 judge，会瞬间产生大量上游请求，可能打爆 judge 模型或耗尽网关连接池/进程。规格完全没有提到 judge 的并发控制、队列或熔断。

4. **档位回退顺序与成本/可用性直觉相反，且可能违反用户意图**：规格说整档为空时按 `flagship → big → fast` 顺序回退。这意味着如果用户配置了 fast 档但 big/flagship 为空，一个需要 big 的请求（ctx_tokens > 60000）会回退到 fast，而 fast 的 ctx_tokens 可能只有 8000，导致上游直接报错（context length exceeded）或截断。回退应该是向"能力更强"的档位回退（fast→big→flagship），而不是向更弱的档位回退。当前顺序是反的。

5. **虚拟模型 routes 作为兜底 LB 池与 tier 回退逻辑冲突**：规格说"虚拟模型本身是 models 表普通一行，其自身 routes 可作为'所有档位全空时的兜底 LB 池'"。但在失败语义中又说"目标档候选全不可用 → 档间回退 flagship→big→fast → 仍失败则 404 no_route"。如果虚拟模型自身有 routes，为什么不直接用这些 routes？这个兜底逻辑与 tier 回退逻辑关系不清。如果 tier 全空，应该走虚拟模型自身 routes，而不是 404。但失败语义说仍失败则 404，没有提到虚拟模型 routes 的启用条件。这会导致配置了虚拟模型 routes 但 tier 全空时行为不一致。

B. 工程风险与遗漏的边界情况：

1. **规则 1 图片输入检测不可靠**：规格说"请求含图片输入（multimodal parts）"，但没有定义如何检测。OpenAI API 的图片可以在 `messages[].content` 数组中（`type: image_url`），也可以在旧的 `messages[].content` 字符串中（base64 data URL），未来还可能有 `file` 类型。如果检测逻辑只检查特定字段，容易漏检或误判。漏检会导致图片请求被路由到非视觉模型，上游报错；误判会导致纯文本请求被路由到旗舰模型，成本浪费。

2. **markers 匹配的误伤风险**：规格说"末条用户消息含升档标记"，但没有说明是子串匹配还是词边界匹配。如果用户消息中包含"我不需要 ultrathink，简单回答即可"，子串匹配会误判为 flagship。需要明确匹配策略（如词边界、大小写、是否在代码块中匹配等）。

3. **Judge 输入截断导致分类错误**：Judge 输入只取 `system 前 256 字符 + 末条用户消息前 1200 字符`。如果用户意图在后半段（例如"请写一个复杂的分布式系统设计文档，要求..."，关键需求在 1200 字符后），judge 会误判为简单请求。同时，多轮对话中早期轮次的重要上下文被完全丢弃，judge 只能看到最后一句话，无法判断整体复杂度。

4. **缓存穿透与热点 Key 问题**：决策缓存 TTL 300s，但写入时若表 > 4096 行才清扫。如果缓存 key 分布不均（例如大量相同 system prompt 的请求），会导致某些 key 极热。更严重的是，**缓存没有考虑负缓存**（judge 失败时是否缓存失败结果？）。规格说 judge 失败 → default_tier，但没有说是否缓存这个 default_tier。如果不缓存，每次都会重复 judge 失败流程，增加延迟；如果缓存，则可能缓存了一个错误的 default_tier。

5. **ETS 惰性建表在分布式/多节点环境下的问题**：规格说"ETS 惰性建表（ensure_table 模式，参照 janus_dashboard_session，无需监督树子进程）"。如果 Janus 是多节点集群，ETS 表默认是节点本地的。决策缓存不会跨节点共享，导致同会话请求在不同节点上重复判分。规格没有说明是否接受这一点，也没有提到节点间缓存同步或一致性。此外，`ensure_table` 在并发首次访问时可能有竞态条件（两个进程同时建表）。

C. 具体可执行的改进建议：

1. **重新设计决策缓存 Key**：缓存 Key 必须包含所有影响路由决策的特征：`phash2({HasImages, CtxTokensBucket, MsgCount, HasTools, MarkersMatched, SystemHash, LastUserMsgHash})`。或者更简单地，在规则门之前计算一个完整的 `Features` 映射，用 `Features` 做缓存 Key。避免用原始内容片段做 Key，防止不同请求因共享前缀而错误命中。

2. **修正档位回退顺序为能力递增**：将回退顺序改为 `fast → big → flagship`。当目标档为空时，应向能力更强的档位回退，确保请求能被处理。同时，在回退到更强档位时，应记录 warning 日志，因为这意味着配置缺失。如果所有档位都空，再走虚拟模型自身 routes 或 404。

3. **Judge 增加并发限制与熔断**：使用 `jobs` 池或计数器限制同时在飞的 judge 请求数（如最大 10-20 个）。超过限制时直接降级为 rules-only/default_tier，避免打爆上游。同时增加简单的熔断：如果最近 N 次 judge 失败，则在 M 秒内跳过 judge 直接走规则/default_tier。

4. **明确图片检测与 markers 匹配规范**：图片检测应遍历 `messages[].content`，检查数组元素中 `type` 为 `image_url` / `image` / `input_image` 等，或字符串中的 `data:image/` base64 前缀。Markers 匹配应使用词边界正则（如 `\bultrathink\b`），并排除代码块（```...```）内的匹配，防止误伤。

5. **Judge 输入增加多轮上下文摘要或完整末条消息**：至少将"末条用户消息前 1200 字符"改为"末条用户消息完整内容（截断到 2000 字符）"，并增加 `对话轮次` 和 `是否存在代码` 等特征给 judge。如果必须截断，应在 prompt 中告知 judge "用户消息可能被截断，请基于可见部分判断"。

再检查一下每部分不超过 5 条。

A 部分：
1. 缓存 Key 设计缺陷（不包含图片、ctx_tokens、markers 等，导致错误命中）
2. ctx_tokens 估算未排除图片 base64 和 tools schema，导致规则 2/4 误判（虽然有图片走规则1，但 ctx_tokens 仍然包含图片字节，可能让无图片但字节大的误判；更重要的是缓存 key 不包含 ctx_tokens）
   等等，我需要更精确。ctx_tokens 估算问题：如果 messages 包含图片（base64），字节总量会极大，导致 ctx_tokens 虚高。规则 1 会路由到 flagship，所以不会错误路由。但如果图片在历史消息中，而当前请求是纯文本，ctx_tokens 仍然包含历史图片的 base64，导致虚高。这可能让一个实际很短的请求误判为 big。这是一个缺陷。
   另外，tools schema 不计入 messages，所以用了 tools 的请求 ctx_tokens 可能被低估，但规则 4 已经排除 tools。所以 tools 不是大问题。
   主要问题是历史图片 base64 导致 ctx_tokens 虚高。
3. Judge 无并发控制，可能打爆上游
4. 档位回退顺序反了（flagship→big→fast），应向能力强回退
5. 虚拟模型 routes 兜底逻辑与 tier 回退冲突/未定义

B 部分：
1. 图片检测逻辑未定义，易漏检/误判
2. Markers 子串匹配误伤（无词边界/代码块排除）
3. Judge 输入截断导致分类错误（只看末条前 1200 字符，丢失多轮上下文）
4. 缓存无负缓存/热点防护，judge 失败重复触发；ETS 无集群共享
5. ETS ensure_table 并发竞态 + 多节点缓存不一致

C 部分：
1. 缓存 Key 改用完整 Features 映射
2. 回退顺序改为 fast→big→flagship，并明确虚拟模型 routes 启用条件
3. Judge 增加并发限制 + 熔断
4. 明确图片检测与 markers 匹配规范（词边界、排除代码块）
5. Judge 输入改为完整末条消息（或至少 2000 字符）+ 增加轮次特征

让我再审视一下，确保结论直接、有理由、无客套话。

A1: 决策缓存 Key 仅含 system 前 256、末条用户前 512 和 tools 有无，缺失图片、ctx_tokens、消息数、markers 等路由特征。两个实质不同的请求会共享缓存，导致图片请求命中纯文本 tier 或长上下文请求命中短上下文 tier，属于正确性缺陷。
A2: ctx_tokens 估算把历史消息中的图片 base64 字节计入，且未区分文本与多模态 token。一个含图片历史的短文本请求会被虚高的 ctx_tokens 误推入 big 档，造成成本浪费或触发上游不必要限制。
A3: Judge 调用无并发上限、无队列、无熔断。高并发下瞬间大量 judge 请求会打爆 judge 模型或耗尽网关连接/进程，与"永不因路由器导致 5xx"目标矛盾。
A4: 档位回退顺序为 flagship→big→fast，即向更弱模型回退。一个超长上下文请求在 big 档为空时会落到 fast 档，几乎必然因上下文超限失败，属于可用性缺陷。
A5: 虚拟模型自身 routes 被定义为"所有档位全空时的兜底 LB 池"，但失败语义只描述 tier 回退后 404，未说明虚拟 routes 的触发条件与优先级，导致配置了兜底 routes 却仍返回 404 的行为不一致。

B1: 规则 1 的"含图片输入"未定义检测标准。OpenAI 兼容 API 中图片可存在于 content 数组的 image_url、旧式 data URL 字符串或未来 file 字段，漏检会将图片请求发往非视觉模型导致上游 400，误判则浪费旗舰模型成本。
B2: markers 匹配未说明是子串、词边界还是大小写不敏感，也未排除代码块。用户说"不需要 ultrathink"或粘贴含标记的代码时会被误升档。
B3: Judge 仅看 system 前 256 字符和末条用户前 1200 字符，完全丢弃多轮历史与完整当前请求。复杂度体现在对话前部
