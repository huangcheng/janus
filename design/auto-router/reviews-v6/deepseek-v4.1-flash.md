# Review v2.4 by deepseek-v4.1-flash (deepseek-v4-1-flash-260910)

_19.7s · completion_tokens=4000_

我们需要回答用户：第六轮评审，v2.4 声称修复前两轮关键缺陷（正负缓存分键、max_out 入 key 与 judge 输入、总窗口语义注释、以及此前全部历史问题）。要求严格审查 A 仍然存在的缺陷或 v2.1 新引入的问题；B 遗漏边界情况；C 具体可执行改进建议。判定标准：只有影响正确性、安全性、可用性、成本才算缺陷；风格偏好、措辞、假想极端场景不计。如果没有实质问题，明确输出 PASS 并简述理由。每部分最多5条，中文。

我们需要审查这个设计规格 v2.4。需要识别真正的缺陷。注意是第六轮评审，前两轮关键缺陷已修复。需要仔细阅读全部。我们要找仍然存在的正确性/安全性/可用性/成本问题，遗漏边界。最多5条每部分。可能是发现没有实质问题？但需要深入分析。

让我们仔细阅读规格。

Janus Auto Router：虚拟模型 janus-auto，根据请求特征路由到 fast/big/flagship。复用现有 models/routes/LB。判定模型用户指派。

核心原则：
2.1 网关对 provider 零假设：judge 用户指派，无默认值；档位模型列表用户指派；未指派 judge => rules-only；judge 失败 => 降级 rules-only 行为；模型窗口大小等能力元数据不知道也不猜测——容量保护只依赖用户配置阈值。
2.2 授权模型：key 是身份不是配额。agent key 默认可访问所有模型；api_key_models 可选粗过滤，只对客户端请求的原始模型名生效，改写后不二次校验。唯一 mitigation 启动校验：检测到任何 key 配置了非全量授权且白名单包含虚拟模型名时，warn。
2.3 路由器自身永不制造 5xx：maybe_route 整体 try/catch，内部意外异常降级 pass + rate-limited warn。可预期失败以返回值传递。路由器范围之外异常与普通模型一致。

3 请求流水线：
POST /v1/chat/completions model="janus-auto"
├─ model_allowed 检查（对原始名，§2.2）
├─ janus_auto:maybe_route(ModelName, ReqMap) 整体 try/catch
│  ├─ ① 名字精确匹配：ModelName =:= 虚拟名（binary 全等，不支持后缀变体）
│  ├─ ② features(ReqMap)（确定性，μs 级）
│  ├─ ③ 规则门 → {tier, hard} | {error, request_too_large} | 进入判分区
│  │     （规则结论永不读写缓存；规则 0 的超限检查先于一切路由）
│  ├─ ④ 判分区（仅规则未决的请求进入）：
│  │     ├─ 未指派 judge → default_tier（soft）
│  │     ├─ 熔断开启（该 judge_model）→ default_tier（soft）
│  │     ├─ judge 并发已满（信号量）→ default_tier（soft，不计失败）
│  │     ├─ 负缓存命中（30s）→ default_tier（soft）
│  │     ├─ 决策缓存命中（300s）→ tier（soft）
│  │     └─ judge 调用（§6）→ tier（soft）；失败 → default_tier
│  └─ ⑤ tier → 目标模型名（§8 解析规则，返回值式失败）
└─ {ok, Target} → 改写 body.model → 既有 proxy 链路（不变）
   {error, no_route} → 404（错误体注明 auto-router tier unconfigured）
   {error, request_too_large} → 400（OpenAI 兼容错误体）
   pass → 按普通模型处理（未配置或意外降级）

返回值联合类型... hard/soft 区分... hard 规则结论不可降级，soft 可降级。

4 特征提取与规则门。
4.1 features:
- prompt_est：分段估算（仅 prompt 文本部分）
  - ASCII 字节数 ÷ 4；其余全部码点（CJK、韩文、emoji、一切非 ASCII）按码点数 × 1.5
  - 文本 part 计入上述估算
- media_allowance：非文本 part 数量 × media_token_allowance（默认 4096 token/part）——零假设下粗粒度媒体预算，使规则 0/3b 对多模态请求同样有界（宁可高估触发上限，不做 provider 级精确计费）
- tools_est：JSON 编码后的 tools 列表字节 ÷ 4
- max_out：max_completion_tokens ?? max_tokens ?? 4096（两字段名兼容，先取新名）
- est_total = prompt_est + media_allowance + tools_est + max_out（§4.2 阈值比较用）
- has_multimodal：任一 message 的 content parts 中存在 type 非纯文本的 part（image_url / input_image / input_audio / audio / video 及一切非 {type: "text"} 的 part）
- has_tools：请求含非空 tools 列表
- marker_hit：末条 user 角色消息文本（拼接其全部文本 part）含标记（双方 lowercase；ASCII 标记做词边界匹配，CJK 标记直接子串；标记表可配）。防御性定义：无 user 角色消息或 messages 为空 ⇒ marker_hit = false、LastUserPrefix = <<>>，judge 输入以 (no user message) 占位；此类请求不可能命中规则 2/5，自然落入判分区（rules-only 时走 default_tier）
- msg_count：请求 messages 数组长度（含 system，全部角色）

输入健壮性：features/1 入口校验 messages 为 map 列表、content 为 binary 或 part 列表；不满足（null 元素、字符串消息等畸形输入）⇒ maybe_route 直接返回 pass（debug 日志）——该请求随后按普通未知模型处理，返回既有 model_not_found 404，不会透传给上游。

4.2 规则门：
0 est_total > max_ctx_tokens（仅当配置了该上限） -> error request_too_large -> 400 hard，先于一切路由规则
1 has_multimodal -> flagship hard
2 marker_hit -> flagship hard（显式用户意图优先于容量规则；flagship 窗口由部署者保证 ≥ big）
3 (prompt_est + tools_est) × 1.2 > big_ctx_tokens -> big hard
3b est_total > big_ctx_tokens -> flagship hard——含 max_out 与媒体预算的总量超 big 档总窗时上旗舰（旗舰窗口由部署者保证 ≥ big，规则 2 注）
4 not has_tools 且 est_total < fast_ctx_tokens 且 msg_count ≤ 3 -> fast，定向 hard/可用性 soft：正常时直接落 fast；fast 档不可用时按 soft 语义降级 default_tier（成本偏好不是可用性硬约束）。总窗口比较基于 prompt+output 共享窗口的通用假设；输出上限独立的部署者可上调 fast_ctx_tokens
5 其余 -> 判分区 soft

容量防线总述：未配置 max_ctx_tokens 时，容量保护由规则 3 + 3b + 部署者保证 flagship ≥ big 共同构成完整防线——任何请求至多到达 flagship 档，不会缺档拦截。
已知设计取舍：规则 4 命中的短请求不进判分区（judge 永远看不到它们）——刻意成本取舍；部署者可调小 fast_ctx_tokens。
余量 ×1.2 只乘 prompt+tools，不乘 max_out；big_ctx_tokens / fast_ctx_tokens 语义为总窗口（prompt+tools+output）。

5 决策缓存：
- 双表结构：主 set {Hash => {Tier, ExpiresAt}}；辅 ordered_set {{Seq, Hash} => ok}；Seq 原子递增。写入两表同笔；容量 >4096 时从辅表头部（最旧）取出条目检查过期并双表删除，单次清扫至多 128 条——清扫成本 O(128) 有界，不做全表扫描
- Key：phash2({SysPrefix, LastUserPrefix, ToolsFp, HasMM, prompt_est_bucket, max_out_bucket}, 2^28)。SysPrefix 所有 system 角色消息文本按序拼接后取前 256 字符（无则空串）；LastUserPrefix 末条 user 消息文本前 1200 字符；ToolsFp JSON 编码 tools 的 phash2/1（全量指纹，非计数）；HasMM；prompt_est_bucket = prompt_est div 4096；max_out_bucket = max_out div 4096。
  - 缓存 key 是 judge 输入的子集摘要：不同输入可能共享结论（近似复用），设计选择而非缺陷——judge 本身也只看同样截断的前缀
- Value：{Tier, JudgeModel, ExpiresAt}（TTL 300s，读取惰性过期；读取时 JudgeModel 与当前配置不符即视为 miss）
- 正负缓存分键空间：正决策存 {pos, Hash}，负缓存存 {neg, Hash}——偶然 judge 失败不会覆盖既有成功决策；读取顺序：先查正条目，命中且未过期即用；仅当无有效正条目时才查负条目（30s 内跳过判分走 default_tier）。judge 成功后写正条目即自然遮蔽负条目
- 语义为重试粘性；多节点各自独立，跨节点档位差异仅影响成本分布（档位映射在各自节点解析，正确性不受影响）

6 Judge（可选，用户指派）
6.1 输入与请求：
- system 指令（英文，约120 token）：任务分类说明 + 输出格式强约束 "Reply with exactly one word on the last line: fast or big or flagship" + 用户内容以引号定界包裹（降低注入面）
- user 内容：system 前 256 字符 + 末条 user 消息前 1200 字符 + 输出预算档位一行（Output budget: <=2k / <=8k / >8k tokens，来自 max_out 分档——长输出任务往往需要更强模型，judge 应知情）
- 请求体：{model, messages, max_tokens: 200, temperature: 0, stream: false}（200 上限容纳思考型 judge 的前置 token）

6.2 执行：
Caller(HTTP handler) 与 Judge worker spawn_monitor。
Ref = make_ref()
{Pid, MonRef} = spawn_monitor(fun() -> ... {Ref, Tier} end)
receive
  {Ref, Tier} -> erlang:demonitor(MonRef, [flush]), 命中缓存写回;
  {'DOWN', MonRef, process, _, _} -> 失败路径（负缓存 + 计连败）
after judge_timeout_ms ->
  exit(Pid, kill), erlang:demonitor(MonRef, [flush]), 失败路径
end
- 连接一次性 gun 连接，owner 即 judge worker：kill 后 gun owner-death 清理关闭连接，无池化状态残留
- 并发信号量：全局 judge in-flight 计数上限 judge_max_inflight（默认8，atomics 实现）；满则跳过 judge → default_tier，不计失败、不计熔断
- 负缓存：失败特征写 30s TTL 条目（与决策缓存同结构，Tier 记为 neg）；命中 -> default_tier
- 熔断：连败计数只累计实际发起的 judge 调用的失败（超时/HTTP 错/解析失败）；负缓存命中与信号量跳过既不计入也不清零；连续5次失败 -> 熔断60s；任一次成功清零。熔断状态按 judge_model 名分别维护：更换 judge_model 配置=新状态空间，旧状态自然作废。配置切换竞态：judge worker 启动时对 judge_model 做快照，其结果回写（负缓存/连败计数）携带该快照的 model 名；若与当前配置不一致，回写直接丢弃——过期 worker 的成败不会污染新模型的状态。

6.3 解析：取输出最后一个非空行，按空白切词，取其中首个命中白名单（fast/big/flagship，全词小写比较）的词；该行无命中则回退对全文首个独立白名单词；仍无 -> 解析失败（降级）。
指令要求"末行单独一个词"，正常输出只走第一段逻辑；回退段仅容错。

7 配置：
{auto_router, #{
  model => <<"janus-auto">>,
  judge_model => undefined,
  tiers => #{ fast => [], big => [], flagship => [] },
  default_tier => fast,
  big_ctx_tokens => 60000,
  fast_ctx_tokens => 8000,
  max_ctx_tokens => undefined,
  judge_timeout_ms => 1500,
  judge_max_inflight => 8,
  cache_ttl_sec => 300,
  media_token_allowance => 4096,
  markers => [...]
}}
启动/首次读取校验（结果缓存；配置变更时以配置指纹重算）：
- judge_model 或任一 tier 候选 == 虚拟模型名 ⇒ error + 该项视为未配置；
- default_tier ∉ keys(tiers) ⇒ error + 回退 rules-only；
- big_ctx_tokens / fast_ctx_tokens / judge_timeout_ms / cache_ttl_sec 非正数，或 judge_max_inflight < 1 ⇒ error + 该项用默认值；
- max_ctx_tokens 已配置但 < big_ctx_tokens ⇒ error + 忽略该上限（配置语义矛盾：硬上限不应低于 big 档容量阈值）；
- tier 候选不在 catalog ⇒ warn（列出缺失名）；
- 整档为空且可能被规则命中 ⇒ error（一次性）；
- 存在配置了非全量 api_key_models 且白名单含虚拟名的 key ⇒ warn 一次（§2.2）

tier 解析（返回值式失败）：
1. 规则 hard 结论的目标档：候选按序取 catalog 中在售且 LB 可选的首个；全部不可用 -> {error, no_route}（hard 不降级）
2. 判分区 soft 结论的目标档：同上；全部不可用 -> default_tier 档再试一次；仍不可用 -> {error, no_route}
3. 两种 no_route 错误体均注明 auto-router tier unconfigured/unavailable，与普通 model_not_found 区分
4. 虚拟模型是 models 表普通一行（仅用于 /v1/models 展示），无自身 routes；maybe_route 只对配置的虚拟名做 binary 全等匹配，不支持 janus-auto:suffix 类变体

8 失败语义总表：
未配置 auto_router -> pass
maybe_route 意外异常 -> catch -> pass + warn
规则 hard 档不可用（规则1/2/3/3b） -> error no_route，不降级
规则4 fast 档不可用 -> soft 降级 default_tier -> 仍败 no_route
messages 畸形 -> pass -> 既有 model_not_found 404，无上游透传
est_total > max_ctx_tokens（已配置且 >= big_ctx_tokens） -> 400
未指派 judge / 熔断 / 信号量满 / 负缓存 -> default_tier (soft)
judge 超时/HTTP 错/解析失败 -> default_tier + 负缓存30s + 计连败
soft 档不可用 -> default_tier 档重试 -> 仍败 no_route
意外异常波及 body 改写（路由器外） -> 与普通模型一致

9 观测...
10 隐私...
11 测试计划...
12 Roadmap...

现在需要审查。我们作为资深分布式系统与 LLM 基础设施工程师，第六轮评审。需要判断是否有影响正确性、安全性、可用性、成本的问题。之前的历史问题：正负缓存分键、max_out 入 key 与 judge 输入、总窗口语义注释、此前全部历史问题。v2.4 已修复这些。但可能还有遗漏。

让我们逐项分析。

潜在问题：

1. 规则 4 的 fast 条件使用 `est_total < fast_ctx_tokens`，但规则 3b 已经检查 `est_total > big_ctx_tokens`。如果 fast_ctx_tokens > big_ctx_tokens 配置？启动校验没有检查 fast_ctx_tokens <= big_ctx_tokens。如果 fast_ctx_tokens 大于 big_ctx_tokens，规则 3b 先于规则4：如果 est_total > big_ctx_tokens 则 flagship；否则 est_total <= big_ctx_tokens < fast_ctx_tokens，规则4可能命中。没问题。但如果 fast_ctx_tokens 配置大于 big_ctx_tokens，规则4可能把 est_total 在 big 和 fast 之间的请求路由到 fast？但规则3b先检查，如果 est_total > big_ctx_tokens 则去 flagship，不会到规则4。所以规则4只对 est_total <= big_ctx_tokens 生效。fast_ctx_tokens 大于 big 无实际影响。但启动校验未检查 fast_ctx_tokens <= big_ctx_tokens，不是正确性问题，因为规则顺序保护。

2. 规则 0 的 max_ctx_tokens 检查：est_total > max_ctx_tokens -> 400。max_ctx_tokens 已配置但 < big_ctx_tokens 时启动校验忽略该上限。但如果 max_ctx_tokens >= big_ctx_tokens，则规则0先于一切。这有一个问题：est_total 包含 media_allowance 和 max_out。如果 max_ctx_tokens 是硬上限，那么对于多模态，media_allowance = 非文本 part 数
