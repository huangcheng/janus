# Review by deepseek-v4.1-flash (deepseek-v4-1-flash-260910)

_29.2s · completion_tokens=4000_

We need answer as senior distributed systems / LLM infra engineer reviewing spec. Three parts: A 关键缺陷 (causes outage/wrong behavior), B 工程风险与遗漏边界, C 具体可执行改进建议. Max 5 each. Direct conclusions + reasons, Chinese. No fluff.

Let me analyze the spec deeply.

Key issues:

1. 决策缓存 key 设计：用 content hash of system前256 + 末条用户前512 + tools存在。问题：
   - 忽略 ctx_tokens（长上下文）和图片。规则门 #1 图片→flagship, #2 ctx>60000→big 是确定性的，但缓存命中优先于规则门（流水线 ① 在 ② 之前）。如果同一 system+末条消息，第一次短请求落 fast，后来加上长历史（同样的末条用户消息）→ 缓存命中 fast，但实际 ctx 很大应该 big。→ 错误路由，可能导致上游 context overflow 报错。这是实质缺陷：缓存命中在规则门之前，且 key 不含 ctx token 量级/图片/tools 内容。
   - 实际上 pipeline 顺序 ①cache ②rules 意味着规则门被缓存绕过。图片：第一条消息带图 → judge/flagship... 缓存 key 不含图片，若同一文本无图先被缓存 fast，然后同文本带图 → 命中 fast，视觉模型不可用 → 错误。严重。
   - tools 存在仅 bool，不同 tool schema 影响复杂度。

2. 字数÷3 估 token：对英文是 4 字节/token 左右，字节数÷3 高估 (英语 1 char = 1 byte, 1 token ≈ 4 chars → bytes/3 高估 33%)；中文 UTF-8 3 bytes/char，1 token ≈ 1-1.5 汉字 → 3 bytes/token ≈ 1 char/token，实际中文 1 token ≈ 0.6-0.7 汉字 → 约 4.5-5 bytes/token，所以 /3 低估约 35-40%。方向不一致导致阈值语义漂移；另外图片 base64 数据会算进字节数 → 图片请求会瞬间超过 60000 → 但规则 1 图片优先旗舰，OK，但若图片以 URL 形式则不算。还有：只算 messages 内容，未算 tools schema 字节（tools 定义可能几 KB）、max_tokens 输出预留。60000 阈值 vs 实际模型上下文窗口（如 128k）需要留输出预算 → 应该在 ctx_tokens 小于 window - max_tokens 时选择。硬编码 60000/8000 与实际 catalog 模型窗口无关联 → 可能把 100k 上下文的模型放进 big 档但请求 90k 超过其窗口。

3. Judge 同步阻塞在 proxy 请求路径上：1500ms 超时 + spawn + receive after。在最坏情况下每个未命中请求增加最多 1.5s 延迟，且 judge 本身也走 LB/HTTP，可能占满连接池/worker。更严重：如果 gateway 使用 Erlang 进程内 timeout，但既有 chat_completions 调用没有取消机制 → 超时后 judge 请求仍在飞，占用上游配额和连接，可能泄漏。需要说明 cancel/abandon 语义。另外 judge 与主请求串行，p99 延迟 = judge p99 + 主请求。

4. 降级语义混乱 & 失败语义表矛盾：
   - 第 3 节：judge 失败 → default_tier。第 2 节说 judge 失败→rules-only 行为。第 9 节又 "judge 超时/解析失败 → 同 default_tier"。rules-only 模式下中间地带 → default_tier，一致，但"降级为 rules-only 行为"含义不清；更关键：规则门 #5 "其余 → judge"，若 judge 失败落 default_tier，而 default_tier 默认 fast —— 这会把需要强模型的中间请求静默路由到快速小模型,导致质量灾难性下降且用户无感知。默认 default_tier=fast 且失败降级到 fast 是危险默认：fail-open 到最弱档。建议默认 big/或 fail-safe 到最强档？或者至少不要静默默认 fast。这里值得列为关键缺陷。

   还有：judge 失败无熔断→每个请求都付 1.5s 超时代价。需要 circuit breaker（连续失败后进入 rules-only 冷却期，如 60s）。

5. 档位回退顺序 flagship→big→fast 与"整档为空"回退：第 7 节说整档为空按 flagship→big→fast 回退；第 9 节说目标档候选全不可用 → 档间回退 flagship→big→fast。方向是从先旗舰后省钱——与"省钱"目标相反，并且与 default_tier=fast 的默认不一致。更重要：档位回退会破坏路由语义（选 fast 的请求落到旗舰，成本暴涨 10-100x），而且这是静默的。成本失控风险。应该：要么明确失败 404/503 并让调用方重试，要么回退只往"能力不低于"方向（fast 档失败 → big），不能反向（flagship 需求落到 fast 会得到错误答案，静默降质）。

   另外"目标档候选全不可用"判断是"模型不在 catalog / 无路由"，判断时机为静态还是包含运行时上游健康？如果包含健康度，则 LB 已经做了；如果只是静态解析，那"不可用"应该由 LB 处理。

6. 虚拟模型自身 routes 作为兜底 LB 池 —— 语义重载：janus-auto 既是被改写的名字又被当作真实上游路由；如果 maybe_route 返回 pass 或 fallback，就会用 janus-auto 自身 routes。这可能导致无限循环（routes 指向 janus-auto 自身？）或非预期的档位绕过。需要明确禁止 janus-auto 出现在 tiers 列表里（自引用循环）。循环风险：tiers.fast 包含 "janus-auto" → 无限递归或反复。至少要有防护。

7. 请求体改写 + 流式：明确非目标说不改流式转发。改写 body.model 后走既有链路，若上游 400/404（模型名不存在），客户端看到错误——没有重试到档内下一个候选？规格说"各档候选模型名列表（按序尝试）"暗示有重试，但既有 proxy 链路是否支持非流式/流式重试？流式已经开始传输后无法重试。所以按序尝试在 stream=true 时只能对"连接建立前"失败生效。需要明确。

8. model_allowed 检查对原始名 janus-auto：OK。但改写后目标模型可能不在 agent key 的 allowed 列表中——如果 proxy 链路会再次做 model_allowed 检查（基于改写后的 body.model），则所有请求都被拒绝；若不再检查，则授权模型被绕过（key 只需 janus-auto 就能访问任意档位模型，包括旗舰 GPT/Claude Opus）——这是权限/成本控制的旁路。需要明确只检查原始名一次，并说明这是有意的（可用性优先）还是需要 tiers ⊆ allowed。

9. 缓存 key 使用 term hash (phash2) 未加盐/未防碰撞且缓存无按 key 的失效；TTL 300s 内同一内容跨用户共享——多租户串扰？key 不含 key_id/tenant，A 用户的请求结果影响 B 用户路由。虽不是数据泄漏（只是 tier 决策），但会把 B 的请求送往 A 认为合适的档位。低成本但应加 tenant/路由到 key。

10. ETS 惰性建表无监督：表 owner 是调用进程（chat handler 进程）→ 该进程结束表就销毁。janus_dashboard_session 所谓的 ensure_table 模式必然是有 owner 进程或 heir。若在 chat handler 里创建，第一个请求进程结束表消失→缓存永不生效或每次重建，甚至并发 race（两个进程同时 create → badarg）。必须用 named table + heir 或放在 supervisor 下的 gen_server。这是会导致功能失效/崩溃的实质缺陷。

11. 规则门 #2: ctx > 60000 → big，但如果 big 档模型窗口小于请求，或者採用 cl100k 时实际更长。还有 #4 无 tools 且 ctx < 8000 且消息数≤3 → fast：多轮长对话（消息数>3）落 judge/default，默认 fast → 长会话每次都判分？不，有缓存。但缓存 key 用上次的消息，多轮里末条消息变化频繁，缓存命中率低 → judge 每次调用 1.5s。

12. 观测仅 debug：生产无法审计路由决策与成本，无指标，问题 12 说 v2 才加计数器。出现成本异常无法排查。至少应 error/info 级别的 ETS 计数器。

13. 超时和 timeout 预算：judge_timeout_ms 1500 但没说明 judge 请求自身的连接/HTTP 超时，receive after 只是放弃等待，进程可能仍挂着（spawn 未链接，异常可能泄漏）。另外如果底层 chat_completions 是同步调用（不是 spawn 的），timeout 无意义。

14. 配置：tiers 为 sys.config 手配，改配置需要重启/重载策略未说明；多节点不一致？如果 gateway 多实例，sys.config 相同。OK。

15. 无 judge 且中间地带 → default_tier，那 rules-only 模式下所有中等复杂请求都落 fast（默认），等于大部分流量走 fast，与"自动路由"目标不符。default_tier 默认 fast 是省钱但同时是质量风险；建议默认 big 或强制用户显式指定。

16. 图像检测："请求含图片输入（multimodal parts）" 但要保证 tiers.flagship 有视觉模型 —— 用户保证。但如果 flagship 空 → 回退 big → fast 非视觉模型 → 上游 400。需要校验或返回明确错误。

17. 安全：judge 输入包含用户 system/消息前 256/1200 字符，发到第三方模型 —— 数据泄露/合规问题。用户内容被送往上游 judge 模型（可能是外部 API）。需要文档/开关。

18. markers 匹配是子串匹配，可能误触发（比如用户说"别 ultrathink 了"、代码里包含 "think harder"）；以及大小写/Unicode。而且末条用户消息可能很长，只对末条检查 ok。

19. 缓存清扫 "表 > 4096 行做一轮清扫" 在写路径上同步做全表遍历 → 延迟尖刺，且在 chat handler 进程做。应该抽样/分片/只在超限时按 TTL 批量删除或使用 ETS ordered_set 按过期时间排序。

20. Tier 到具体模型名的 LB 择路：既有 LB 是模型级还是 route 级？"tiers 内模型名解析失败则跳过"——解析发生在每请求，是否缓存解析结果，否则每请求查 catalog（DB?）增加延迟。

21. 请求重试与幂等：候选按序尝试，对非流式可以；但若第一个候选已经产生输出（stream 中断），不能重试。而且对上游 5xx 重试可能放大。

22. 404 no_route 语义：虚拟模型存在但档位全空时，最好返回明确错误码（例如 503 + 错误信息说明未配置 auto_router tiers），而不是 404，便于运维定位。

23. 缓存 TTL 300s + 内容哈希：同一 prompt 重复请求（比如自动化任务）一直走同一档，OK。但如果 judge 结果错误（judge 输出解析取"首个匹配词"，如果 judge 回答 "not fast but flagship" → 取到 fast，解析歧义）。解析应该要求严格输出或取最后一个词/精确匹配。这是实际错误路由。

24. temperature=0 + max_tokens=16，但 judge 模型可能是推理模型（会输出 thinking），16 token 不够 → 解析失败 → 降级。需要校验/更长 max_tokens 或 adapter。

25. 未定义 judge 模型的 model_allowed：judge 调用是否绕过 agent key 的模型授权？janus_lb:pick_route + providers_openai:chat_completions 直接调用，可能绕过鉴权 — 内部调用应该没问题，但需要说明。

26. 关键：流水线在 proxy_chat/5 中"resolve_model 前插入 maybe_route"，但 model_allowed 检查在 maybe_route 之前对原始名 —— 顺序 OK。但如果 maybe_route 之后没有对目标模型再做 allowed 检查（前面提过）。

27. `phash2` 碰撞概率：32-bit hash，4096 条目，碰撞概率 ~0.2%？birthday: 4096^2/(2*2^32) ≈ 0.2%。碰撞 → 错误 tier。用 crypto:hash 或保留完整 key 更稳妥。实际上 phash2 默认 range 2^27？phash2/1 返回 0..2^27-1。4e3 条，碰撞概率 (4096^2)/(2*2^27) = 6.25%。不小。应存储完整 key 或用更强哈希。

好，选最关键的。

A 部分（关键缺陷，导致故障或错误行为）最多 5 条。选出最严重的：

A1. 缓存优先于规则门，且 key 不含图片/token 量级/tools 内容 → 同一文本先短后有图/长上下文时会命中错误 tier，导致上游 context overflow 或把带图请求打到无视觉模型。修：规则门（图片、ctx）永远先于缓存，或把 flags 纳入 key。
A2. ETS 惰性建表在 chat handler 进程（无 owner/监督）→ 表随首个请求进程退出而销毁 / 并发 create race / 每进程私有表；缓存要么失效要么 crash。需要 supervised owner 或 heir + named table。
A3. 失败降级方向错误：judge 失败 + 档空回退 → 静默落到 fast（default_tier=fast），把复杂请求发给最弱模型，质量事故且不可观测；档位回退旗舰→大→快是"先烧钱再降质"的双向错误。应确定"只允许向能力不低于原档回退"或显式失败，并让失败可见。
A4. 超时不是取消：spawn + receive after 放弃结果，但下游 judge HTTP 请求继续运行并占用连接/配额/上游计费；1500ms 串行叠加在主请求路径上，无熔断 → 上游 judge 挂了每个请求都 pay 1.5s。需要连接级取消/熔断。
A5. 授权语义破坏/自引用循环：改写后模型可能绕过 key 的 model_allowed（若不再校验）或全部拒绝（若再校验）；janus-auto 自身 routes 作兜底池，若 tiers 里出现 janus-auto 会无限循环。定义明确的授权规则和自引用防护。

也许把"A4"或"A5"替换成 ctx 估算错误？ctx 估算: bytes/3 中英偏差 ±35%，只算 messages 不含 tools/输出预留，60k 阈值与真实窗口无关联 —— 会误判 big/fast 边界，导致上游 400 context length exceeded。这也很关键。但 A 只 5 条。我需要挑对系统影响最大的。

我认为 A 应包含：缓存绕过规则门+key 缺陷；ETS 生命周期；降级/回退方向导致静默降质+成本失控；judge 超时非取消+无熔断（延迟与资源）；权限/自引用。ctx 估算放 B（风险/边界）。

嗯，A5 自引用循环确实是"会导致故障"。权限绕过是安全问题。合并成一条。

B 工程风险与边界（5 条）：
B1. ctx_tokens 估算 bytes/3 偏差（中英方向相反、未计 tools schema 与 max_tokens 输出预留、未与所选模型真实窗口关联）→ 边界误判；图片 base64 会污染估算。
B2. 缓存 key 用 phash2/1（默认 2^27 范围）+4096 条 → 碰撞率约 6%，错误 tier；且 key 不含 tenant/key_id → 跨用户串扰；写路径全表清扫 → 延迟尖刺。
B3. judge 输出解析用"首个匹配词"：judge 若输出 "not fast, flagship" 或解释性文本会错判；且 max_tokens=16 对推理型 judge 模型不够 → 频繁降级；无 judge 输出校验/重试。
B4. 多轮会话缓存命中率低（key 依赖末条用户消息），judge 频繁触发；所谓"会话粘性"不成立；且 TTL 300s 过期后的重新判分会产生 tier 抖动 → 上游 prompt cache 失效（与第 6 节声称相反）。
B5. markers 子串匹配误触发/绕过（大小写、Unicode、代码引用、否定句）；流式请求下候选重试不可行（已有输出无法重试）；tiers 解析每请求查 catalog 的开销；观测只有 debug 日志，无指标 → 线上无法发现错误路由与成本漂移。还有：judge 会把用户 prompt 送第三方（合规/泄漏）。

B 最多 5 条，得压缩。可以合并。

C 改进建议（具体可执行）最多 5 条：
C1. 重排流水线：规则门（图片/显式标记/ctx 超限）→ 缓存（key 含 rules 判定后的 tier 影响因素：tenant、模型名、图片存在、ctx 分桶、tools 指纹、marker 命中）→ judge。或用"缓存只存 judge 结果"，规则门每次重算。
C2. 让 judge 成为真正的异步/可取消：用
