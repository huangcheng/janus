# Janus Auto Router — 设计规格 v2.5

状态：v2.5（六轮评审修订；历史见 REVIEW-v2.md）

> v2.4 → v2.5 变更：
> ① 规则重排：总量检查（→flagship）先于 prompt 段检查（→big），规则重编号
>    （原 3b 升为现规则 3，原 3/4 顺延为 4/5）
> ② `media_allowance` 计数封顶 `max_media_parts`（默认 10），防媒体 part 堆砌
> ③ 辅表键含 `Kind`，容量超限改 FIFO 无条件淘汰（语义确定、成本有界）
> ④ 信号量释放写入 `after` 保证；负缓存措辞与分键空间对齐
作者：ZCode 会话 · 2026-10-03

> v2.3 → v2.4 变更：
> ① 正负缓存分键空间（`{pos,Hash}` / `{neg,Hash}`），judge 偶发失败不再
>    覆盖既有成功决策（修五轮）
> ② 缓存 key 增加 `max_out_bucket`；judge 输入附输出预算档位行——不同
>    输出需求的请求不再共享结论（修五轮）
> ③ 规则 4 总窗口语义注明共享窗口假设与部署者调参出口

> v2.2 → v2.3 变更：
> ① 新增规则 3b：`est_total > big_ctx_tokens → flagship`——含 max_out 的
>    总量超 big 档时上旗舰（修四轮：max_out 溢出 big 窗口）
> ② 规则 4（fast）改为"定向 hard、可用性 soft"：fast 档不可用时按 soft
>    语义降级 default_tier，不再直接 404（修四轮：短请求可用性）
> ③ est_total 计入 `media_allowance = 非文本 part 数 × media_token_allowance`
>    （默认 4096/part），多模态硬上限恢复效力（修四轮：多模态 est 失真）
> ④ 决策缓存 value 携带 judge_model 名，读取时不匹配当前配置即 miss
>    （修四轮：换 judge 后旧决策"幽灵命中"）
> ⑤ 400 响应体定义为 OpenAI 兼容 `invalid_request_error` 格式
> ⑥ messages 畸形输入显式定义：整体 pass → 模型未知 404，无上游透传
> ⑦ 未配置 max_ctx_tokens 时的容量防线说明（各档阈值 + 规则 3b 即完整防线）

## 1. 目标 / 非目标

**目标**：`janus-auto` 虚拟模型——按请求特征自动路由到 fast / big / flagship
三档真实模型，复用现有 models / routes / LB 结构，档位与判分模型全部由部署者指派。

**非目标**：计费与成本反馈学习、流式转发改造、跨档位授权控制（§2.2）、
视觉/音频等专项路由档（统一并入 flagship 硬约束）。

## 2. 核心原则

### 2.1 网关对 provider 世界零假设

- judge 由用户指派（catalog 任一模型），无默认值；档位模型列表由用户指派；
- 未指派 judge ⇒ rules-only；judge 失败 ⇒ 降级 rules-only 行为；
- 模型窗口大小等能力元数据 Janus **不知道也不猜测**——容量保护只依赖用户
  配置的阈值（§4、§8），不依赖模型清单。

### 2.2 授权模型：key 是身份，不是配额（定案，不再复议）

agent key 默认可访问所有模型；`api_key_models` 是可选粗过滤，**只对客户端
请求的原始模型名生效**，改写后不二次校验。唯一的 mitigation（§8 启动校验）：
检测到任何 key 配置了非全量授权且白名单包含虚拟模型名时，打一次 warn，
提示该 key 经由虚拟模型可触达其白名单之外的模型。

### 2.3 路由器自身永不制造 5xx

`janus_auto:maybe_route/2` 函数体整体 try/catch：内部任何**意外异常**降级为
`pass` + rate-limited warn。可预期的失败（档位未配置、judge 不可用等）一律以
**返回值**传递（`{ok, Target}` | `pass` | `{error, no_route}`），不走异常通道。
路由器范围之外的异常（HTTP handler 自身、上游转发）行为与普通模型一致，
不属于本承诺范畴。

## 3. 请求流水线

```
POST /v1/chat/completions  model="janus-auto"
  ├─ model_allowed 检查（对原始名，§2.2）
  ├─ janus_auto:maybe_route(ModelName, ReqMap)     ← 整体 try/catch（§2.3）
  │    ├─ ① 名字精确匹配：ModelName =:= 虚拟名（binary 全等，不支持后缀变体）
  │    ├─ ② features(ReqMap)（确定性，μs 级）
  │    ├─ ③ 规则门 → {tier, hard} | {error, request_too_large} | 进入判分区
  │    │     （规则结论永不读写缓存；规则 0 的超限检查先于一切路由）
  │    ├─ ④ 判分区（仅规则未决的请求进入）：
  │    │     ├─ 未指派 judge → default_tier（soft）
  │    │     ├─ 熔断开启（该 judge_model）→ default_tier（soft）
  │    │     ├─ judge 并发已满（信号量）→ default_tier（soft，不计失败）
  │    │     ├─ 负缓存命中（30s）→ default_tier（soft）
  │    │     ├─ 决策缓存命中（300s）→ tier（soft）
  │    │     └─ judge 调用（§6）→ tier（soft）；失败 → default_tier
  │    └─ ⑤ tier → 目标模型名（§8 解析规则，返回值式失败）
  └─ {ok, Target} → 改写 body.model → 既有 proxy 链路（不变）
     {error, no_route} → 404（错误体注明 auto-router tier unconfigured）
     {error, request_too_large} → 400（OpenAI 兼容错误体：
       `{"error":{"message":"estimated context exceeds max_ctx_tokens",
        "type":"invalid_request_error","code":"request_too_large"}}`）
     pass → 按普通模型处理（未配置或意外降级）
```

**返回值联合类型**：`{ok, Target} | pass | {error, no_route} |
{error, request_too_large}`——可预期失败全部走返回值，`try/catch` 只兜意外
异常（§2.3）。HTTP handler 对两个 error 分别映射 404 / 400。

**hard/soft 区分是 N2 的修复核心**：规则门结论是硬约束（容量/模态/显式意图），
其目标档不可用时不允许降级到 default_tier——直接 `no_route`；判分区结论是
软估计，允许降级。

## 4. 特征提取与规则门

### 4.1 features(ReqMap)

- `prompt_est`：分段估算（仅 prompt 文本部分）
  - ASCII 字节数 ÷ 4；**其余全部码点（CJK、韩文、emoji、一切非 ASCII）按码点数 × 1.5**
  - 文本 part 计入上述估算
- `media_allowance`：`min(非文本 part 数, max_media_parts)` × `media_token_allowance`
  （默认 4096 token/part，`max_media_parts` 默认 10——防堆砌媒体 part 操纵估算；
  封顶后的极端媒体体量由 HTTP 层既有的请求体上限（`?MAX_BODY` 10MB）兜底，
  不会无限放大转发）——零假设下的粗粒度媒体预算，使规则 0/3b 对多模态
  请求同样有界（宁可高估触发上限，不做 provider 级精确计费）
- `tools_est`：JSON 编码后的 tools 列表字节 ÷ 4
- `max_out`：`max_completion_tokens` ?? `max_tokens` ?? 4096（两字段名兼容，先取新名）
- `est_total = prompt_est + media_allowance + tools_est + max_out`（§4.2 阈值比较用）
- `has_multimodal`：任一 message 的 content parts 中存在 type 非纯文本的 part
  （`image_url` / `input_image` / `input_audio` / `audio` / `video` 及一切
  非 `{type: "text"}` 的 part）
- `has_tools`：请求含非空 `tools` 列表
- `marker_hit`：**末条 user 角色消息**文本（拼接其全部文本 part）含标记
  （双方 lowercase；ASCII 标记做词边界匹配，CJK 标记直接子串；标记表可配）。
  **防御性定义**：无 user 角色消息或 messages 为空 ⇒ `marker_hit = false`、
  `LastUserPrefix = <<>>`，judge 输入以 `(no user message)` 占位；此类请求
  不可能命中规则 2/5 的 fast 规则，自然落入判分区（rules-only 时走 default_tier）
- `msg_count`：请求 messages 数组长度（含 system，全部角色）

**输入健壮性（六轮防畸形）**：`features/1` 入口校验 messages 为 map 列表、
content 为 binary 或 part 列表、`tools` 字段缺失或为合法数组（`null`/字符串等
畸形一律视为无 tools）；不满足（`null` 元素、字符串消息等畸形输入）⇒
`maybe_route` 直接返回 `pass`（debug 日志）——该请求随后按普通未知模型处理，
返回既有 `model_not_found` 404，**不会透传给上游**。

### 4.2 规则门（优先级自上而下）

| # | 条件 | 去向 | 性质 |
|---|---|---|---|
| 0 | `est_total > max_ctx_tokens`（仅当配置了该上限） | `{error, request_too_large}` → 400 | hard，**先于一切路由规则**——硬上限必须对多模态/marker/超长请求同样生效 |
| 1 | `has_multimodal` | `flagship` | hard |
| 2 | `marker_hit` | `flagship` | hard（显式用户意图优先于容量规则；flagship 窗口由部署者保证 ≥ big） |
| 3 | `est_total > big_ctx_tokens` | `flagship` | hard——含 max_out 与媒体预算的**总量**超 big 档总窗时上旗舰；必须先于规则 4（总量溢出比 prompt 段溢出更严重，先判总） |
| 4 | `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` | `big` | hard——仅 prompt+tools 段超阈、总量未超 big 时落 big |
| 5 | `not has_tools` 且 **`est_total`** `< fast_ctx_tokens` 且 `msg_count ≤ 3` | `fast` | **定向 hard / 可用性 soft**：正常时直接落 fast；fast 档不可用时按 soft 语义降级 default_tier（成本偏好不是可用性硬约束）。总窗口比较基于 prompt+output 共享窗口的通用假设（主流模型如此）；输出上限独立的部署者可上调 fast_ctx_tokens |
| 6 | 其余 | 判分区 | soft |

**容量防线总述**：未配置 `max_ctx_tokens` 时，容量保护由规则 3（est_total 总量）+ 规则 4（prompt+tools 段）+ 部署者保证的 `flagship ≥ big` 共同构成
完整防线——任何请求至多到达 flagship 档，不会缺档拦截。

**已知设计取舍**：规则 5 命中的短请求不进判分区（judge 永远看不到它们）——
这是刻意的成本取舍：短小请求默认走 fast，需要深度思考时由用户显式加标记
（规则 2）。部署者若不认可此取舍，可把 `fast_ctx_tokens` 调小（如 1000），
让更多请求进入判分区。

余量 ×1.2 **只乘 prompt+tools**，不乘 `max_out`（修 N6 双重放大）；
`big_ctx_tokens` / `fast_ctx_tokens` 语义为**总窗口**（prompt+tools+output）。

## 5. 决策缓存

- 双表结构（修 N5）：
  - 主表 `set`：`{Hash => {Tier, ExpiresAt}}`
  - 辅表 `ordered_set`：`{{Seq, Kind, Hash} => ok}`，`Seq` 为原子递增序号，
    `Kind` 为 `pos | neg`（与主表完整键一致）
  - **写序：先辅表后主表**；容量 >4096 时从辅表头部（最旧）**无条件**删除
    对应主表条目直至回到 4096（FIFO 语义，单次清扫至多 128 条，不做全表扫描）
  - **已知微竞态与容量语义（终审定案）**：辅表写入与主表写入之间若恰好插入
    一次容量清扫，该辅表行可能被先行淘汰，随后主表条目落地即无辅记录
    （逃过 FIFO）。影响有界：孤儿主表条目仍受 TTL 300s 惰性过期约束，
    增长率 ≤ TTL 窗口内写入量；因此 **4096 是软目标而非硬上界**。缓解：
    每第 64 次清扫附带一次全表对账（删除无辅记录的过期主表条目，4096 行
    摊销成本可忽略）。孤儿辅表行（先辅后主崩溃）无害，清扫自然清除
- **Key**：`erlang:phash2({SysPrefix, LastUserPrefix, ToolsFp, HasMM,
  prompt_est_bucket, max_out_bucket}, 268435456)`（2^28 域；容量 4096 时碰撞
  概率 ~3e-5，接受）
  - `SysPrefix`：**所有** system 角色消息的文本按序拼接后取前 256 字符（无则空串）
  - `LastUserPrefix`：末条 user 消息文本前 **1200** 字符（与 judge 输入对齐，
    消除 v2 的 512/1200 不一致）
  - `ToolsFp`：JSON 编码 tools 的 `phash2/1`（全量指纹，非计数）
  - `HasMM`：`has_multimodal`（防御性冗余，规则门先行使其实际恒为 false）
  - `prompt_est_bucket`：`prompt_est div 4096`
  - `max_out_bucket`：`max_out div 4096`（输出预算入 key：不同输出需求的
    请求不共享结论）
  - 缓存 key 是 judge 输入的**子集摘要**：不同输入可能共享结论（近似复用），
    这是设计选择而非缺陷——judge 本身也只看同样截断的前缀
- **Value**：`{Tier, JudgeModel, ExpiresAt}`（TTL 300s，读取惰性过期；
  **读取时 `JudgeModel` 与当前配置不符即视为 miss**——更换 judge 后旧决策
  不会"幽灵命中"污染新模型的前 300s，四轮④修复）
- **正负缓存分键空间**（五轮修复）：正决策存 `{pos, Hash}`，负缓存存
  `{neg, Hash}`——偶然的 judge 失败**不会覆盖**既有成功决策；读取顺序：
  先查正条目，命中且未过期即用；仅当无有效正条目时才查负条目（30s 内
  跳过判分走 default_tier）。judge 成功后写正条目即自然遮蔽负条目
- 语义为**重试粘性**；多节点各自独立，跨节点档位差异仅影响成本分布
  （档位映射在各自节点解析，正确性不受影响）

## 6. Judge（可选，用户指派）

### 6.1 输入与请求

- system 指令（英文，约 120 token）：任务分类说明 + **输出格式强约束
  "Reply with exactly one word on the last line: fast or big or flagship"**
  + 用户内容以引号定界包裹（降低注入面）；
- user 内容：system 前 256 字符 + 末条 user 消息前 1200 字符 + 输出预算档位
  一行（`Output budget: <=2k / <=8k / >8k tokens`，来自 max_out 分档——
  长输出任务往往需要更强模型，judge 应知情）；
- 请求体：`{model, messages, max_tokens: 200, temperature: 0, stream: false}`
  （200 上限容纳思考型 judge 的前置 token）。

### 6.2 执行（进程与连接语义，修 N1/N4 + 中优先项）

```
Caller(HTTP handler)               Judge worker (spawn_monitor)
  Ref = make_ref()                   信号量 acquire（失败 → {Ref, skip} 自退）
  {Pid, MonRef} = spawn_monitor(     gun:open(一次性连接, owner=本进程)
    fun() -> ... {Ref, Tier} end)    chat_completions(...)
                                      ← 唯一 Ref 标记回复；try/after 保证
                                        归还信号量（一切正常/异常路径）
  receive
    {Ref, Tier} ->
        erlang:demonitor(MonRef, [flush]);
    {Ref, skip} ->
        erlang:demonitor(MonRef, [flush]),
        信号量跳过路径（soft，不计失败）;
    {'DOWN', MonRef, process, _, _} ->
        receive {Ref, _} -> ok after 0 -> ok end,   %% 对称排空在途回复
        失败路径（负缓存 + 计连败）
  after judge_timeout_ms ->
        %% 终审修正：不 kill——exit(kill) 会绕过 worker 的 after 造成
        %% 信号量配额泄漏；改为放弃等待并清尾巴
        erlang:demonitor(MonRef, [flush]),
        receive {Ref, _} -> ok after 0 -> ok end,   %% 排空可能在途回复
        失败路径（负缓存 + 计连败）
  end
```

**正缓存写回归属 worker（终审方案 A，qwen 放行条件）**：worker 在成功
解析后**自行**写 `{pos, Hash}` 条目（Hash 与 JudgeModel 在 spawn 时已通过
闭包注入，写回不依赖 caller 存活）。效果：caller 1.5s 超时放弃后，慢而
成功的 judge 结果仍会落正缓存——正条目按 §5 读取顺序天然遮蔽 caller 先行
写入的负条目，偶发慢请求不会造成该特征 30s 的大面积降级。
**选择性接收语义说明**：receive 各子句按模式匹配扫描整个邮箱，worker 的
`{Ref, Tier}` 即便在邮箱中排在 DOWN 之后也会被首个子句命中，不存在
"成功被判失败"；DOWN/超时路径的排空仅是回收在途垃圾消息的对称性措施。

**超时不杀的代价分析（终审定案）**：被放弃的 worker 由 gun 层既有超时
（连接 5s / TTFB 60s）自然有界，最坏持有信号量 60s；judge 持续挂死时
8 个槽位最多占用 60s 窗口，随后连败 5 次触发 60s 熔断接管——自愈、
无泄漏、无邮箱残留（选择性接收 + 显式排空双保险）。

- 连接为**一次性** gun 连接，owner 即 judge worker：kill 后 gun owner-death
  清理关闭连接，无池化状态残留；
- **并发信号量**：全局 judge in-flight 计数上限 `judge_max_inflight`（默认 8，
  `atomics` 实现）；满则跳过 judge → default_tier，**不计失败、不计熔断**；
  **获取动作在 worker 的 fun 内部执行**（worker 启动即尝试获取，失败则
  自行退出并发送 `{Ref, skip}` 标记——caller 视为信号量跳过），
  使计数与 worker 生命周期严格绑定，caller 崩溃也不会泄漏配额；
  worker 内部以 `after` 保证释放（回复/DOWN/超时均归还）；
  `spawn_monitor` 自身失败（系统极限）直接走失败路径（同超时语义）
- **负缓存**：失败特征写 30s TTL 的 `{neg, Hash}` 条目；
  命中 → default_tier；
- **熔断**（修 N4 语义）：连败计数**只累计实际发起的 judge 调用**的失败
  （超时/HTTP 错/解析失败）；负缓存命中与信号量跳过**既不计入也不清零**；
  连续 5 次失败 → 熔断 60s；任一次成功清零。**熔断状态按 judge_model 名分别
  维护**：更换 judge_model 配置 = 新状态空间，旧状态自然作废（修中优先项）。
  **配置切换竞态**（三轮④）：judge worker 启动时对 `judge_model` 做快照，
  其结果回写（负缓存/连败计数）携带该快照的 model 名；若与当前配置不一致，
  回写直接丢弃——过期 worker 的成败不会污染新模型的状态。

### 6.3 解析（修 N3）

取输出**最后一个非空行**，按空白切词，取其中**首个**命中白名单
（`fast` / `big` / `flagship`，全词小写比较）的词；该行无命中则回退对全文
首个独立白名单词；仍无 → 解析失败（降级）。
指令要求"末行单独一个词"，正常输出只走第一段逻辑；回退段仅容错。

## 7. 配置（`janus` app env，sys.config）

```erlang
{auto_router, #{
    model => <<"janus-auto">>,
    judge_model => undefined,              %% undefined = rules-only
    tiers => #{ fast => [], big => [], flagship => [] },
    default_tier => fast,
    big_ctx_tokens => 60000,               %% 总窗口语义（prompt+tools+output）
    fast_ctx_tokens => 8000,
    max_ctx_tokens => undefined,           %% 可选硬上限；超过 → 400 request_too_large
    judge_timeout_ms => 1500,
    judge_max_inflight => 8,
    cache_ttl_sec => 300,
    media_token_allowance => 4096,
    max_media_parts => 10,
    markers => [<<"ultrathink">>, <<"think harder">>, <<"深度思考">>, <<"仔细分析">>]
}}
```

**启动/首次读取校验（结果缓存；配置变更时以配置指纹重算）**：

- `judge_model` 或任一 tier 候选 == 虚拟模型名 ⇒ error 日志 + 该项视为未配置；
- `default_tier ∉ keys(tiers)` ⇒ error + 回退 rules-only；
- `big_ctx_tokens` / `fast_ctx_tokens` / `judge_timeout_ms` / `cache_ttl_sec`
  非正数，或 `judge_max_inflight` < 1 ⇒ error + 该项用默认值；
- `max_ctx_tokens` 已配置但 < `big_ctx_tokens` ⇒ error + 忽略该上限
  （配置语义矛盾：硬上限不应低于 big 档容量阈值）；
- tier 候选不在 catalog ⇒ warn（列出缺失名）；
- 整档为空且可能被规则命中 ⇒ error（一次性）；
- 存在配置了非全量 `api_key_models` 且白名单含虚拟名的 key ⇒ warn 一次（§2.2）。

**tier 解析（返回值式失败，修 N7）**：

1. 规则 hard 结论的目标档：候选按序取 catalog 中在售且 LB 可选的首个；
   全部不可用 → `{error, no_route}`（hard 不降级，修 N2）；
2. 判分区 soft 结论的目标档：同上；全部不可用 → default_tier 档再试一次；
   仍不可用 → `{error, no_route}`；
3. 两种 no_route 的错误体均注明 `auto-router tier unconfigured/unavailable`，
   与普通 `model_not_found` 区分；
4. 虚拟模型是 models 表普通一行（仅用于 `/v1/models` 展示），**无自身 routes**
  （修 A8）；`maybe_route` 只对配置的虚拟名做 binary 全等匹配，不支持
  `janus-auto:suffix` 类变体（文档注明）。

## 8. 失败语义总表

| 场景 | 行为 |
|---|---|
| 未配置 auto_router | `pass`（一次 app-env 查询开销） |
| maybe_route 意外异常 | catch → `pass` + warn（§2.3） |
| 规则 hard 档不可用（规则 1/2/3/4） | `{error, no_route}`，不降级 |
| 规则 5 fast 档不可用 | 按 soft 语义降级 default_tier → 仍败则 no_route |
| messages 畸形（非 map 列表等） | `pass` → 既有 model_not_found 404，无上游透传 |
| est_total > max_ctx_tokens（已配置且 ≥ big_ctx_tokens） | `{error, request_too_large}` → 400（OpenAI 兼容错误体） |
| 未指派 judge / 熔断 / 信号量满 / 负缓存 | default_tier（soft） |
| judge 超时/HTTP 错/解析失败 | default_tier + 负缓存 30s + 计连败 |
| soft 档不可用 | default_tier 档重试 → 仍败则 no_route |
| 意外异常波及 body 改写（路由器外） | 与普通模型一致的既有行为 |

## 9. 观测

- 决策日志 `logger:debug`：`{reason: rules|judge|cache|negcache|breaker|
  inflight_skip|fallback|no_route, tier, target, est_total, elapsed_ms}`；
- ETS 计数器（`janus_auto:stats/0`）：每 tier 路由数、judge 成功/失败/超时数、
  熔断触发次数、信号量跳过数、no_route 次数；后续接入 admin `/overview`；
- judge 失败与空档：warn/error 日志，rate-limited。

## 10. 隐私与合规声明

judge 会把 system 前 256 字符与末条 user 消息前 1200 字符发送给部署者自己
指派的判分模型。判分模型为第三方托管服务时构成部分用户内容出域，部署者自行
评估；不指派 judge 则零出域（rules-only）。

## 11. 测试计划

- eunit：
  - features：ASCII÷4 + 非ASCII×1.5（含韩文/emoji 用例）、多模态 part 检测、
    marker 词边界（"don't think harder" 反例）、max_tokens 双字段与缺省；
  - 规则优先级（marker 先于容量）、×1.2 只乘 prompt 部分、max_ctx_tokens；
  - judge 解析：末行首个词、复述指令反例（"valid outputs: fast big flagship"
    应取末行规则失败后回退 fast？——用例：输出末行无白名单词 + 全文首个=fast
    场景）、"not flagship, big" 反例；
  - demonitor 双路径（进程正常结束 + 超时 kill 后邮箱零残留）；
  - 熔断/负缓存/信号量交互：负缓存命中不冲销连败、信号量跳过不计入、
    换 judge_model 状态重置；
  - 缓存：key 子集语义、双表清扫有界、TTL；
  - tier 解析：hard 不降级、soft 降级、返回值式 no_route；
  - 启动校验全套；未配置 pass-through；
- Docker 冒烟：种子模型 + 假 provider；断言 default_tier 落点、body.model
  改写、no_route 错误体标注。

## 12. Roadmap（本期不做）

- dashboard UI 指派界面（models 加 tier 字段 + 下拉 + 熔断/统计面板）；
- 会话粘性显式化（客户端透传会话 ID）；
- 路由统计接入 /overview 图表。
