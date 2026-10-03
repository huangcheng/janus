# Janus Auto Router — 设计规格 v2

状态：v2（吸收七模型评审结论，见 REVIEW.md）
作者：ZCode 会话 · 2026-10-03

> v1 → v2 变更摘要：
> ① 流水线重排：规则门先于缓存，缓存只存 judge 结论（修 A1）
> ② `maybe_route` 全量 catch 降级，兑现"永不 5xx"（修 A2）
> ③ judge 加固：monitor+kill、唯一 Ref 选择性接收、负缓存、熔断（修 A3）
> ④ token 估算改为 CJK/ASCII 分段 + 余量 + 计入 tools/max_tokens（修 A4）
> ⑤ 取消跨档回退：档空 → default_tier → 明确错误（修 A5）
> ⑥ 启动校验拒绝自引用（修 A6）
> ⑦ 授权定案：key 默认可访问所有模型，改写后不二次校验（定案 A7）
> ⑧ 删除 janus-auto 自身 routes 兜底池（修 A8）
> ⑨ 缓存哈希扩域；"会话粘性"表述修正为"重试粘性"（修 A9）

## 1. 目标 / 非目标

**目标**：提供 `janus-auto` 虚拟模型——按请求特征自动路由到 fast / big / flagship
三档真实模型，复用现有 models / routes / LB 结构，档位与判分模型全部由部署者指派。

**非目标**：计费与成本反馈学习、流式转发改造、多模态专项路由档、
**跨档位授权控制**（见 §2）。

## 2. 核心原则

### 2.1 网关对 provider 世界零假设

部署者用什么上游、有没有便宜小模型，Janus 一概不知：

- 判分小模型（judge）由用户指派（catalog 中任一模型），无默认值；
- 档位模型列表由用户指派；
- 未指派 judge ⇒ rules-only 模式（功能完整）；
- judge 超时/失败/不可解析 ⇒ 降级为 rules-only 行为。

### 2.2 授权模型：key 是身份，不是配额（定案）

Provider 和模型是**动态资产**：订阅过期删一家 provider、新模型发布加一条路由，
都是日常操作。因此 agent key 默认可访问所有模型；`api_key_models` 仅作为可选的
粗过滤，且**只对客户端请求的原始模型名生效**。auto-router 改写后的目标模型
不做二次授权校验——不存在"越权"概念，也就没有旁路问题。

### 2.3 路由器永不制造 5xx

`maybe_route` 全体包 `try/catch`：内部任何异常（ETS 缺表、配置格式错、
二进制匹配失败）一律降级为 `pass`（按普通模型处理）+ rate-limited warn 日志。
§9 失败语义表与该承诺一致，不自相矛盾。

## 3. 请求流水线（v2 重排）

```
POST /v1/chat/completions  model="janus-auto"
  ├─ model_allowed 检查（对原始名，见 §2.2）
  ├─ janus_auto:maybe_route(ModelName, ReqMap)     ← 整体 try/catch
  │    ├─ ① 特征提取 features(ReqMap)（确定性，μs 级）
  │    ├─ ② 规则门 rules_gate(Features) → tier 或 进入判分区
  │    │     （规则结果永不写缓存、永不读缓存）
  │    ├─ ③ 判分区：
  │    │     ├─ judge 熔断开启中？ → default_tier
  │    │     ├─ 负缓存命中（30s）？ → default_tier
  │    │     ├─ 决策缓存命中（TTL 300s，仅存 judge 结论）→ tier
  │    │     └─ judge 调用（monitor + 超时 kill）→ tier / 失败→ default_tier
  │    └─ ④ tier → 模型名（用户指派列表 ∩ catalog，按序取首个可用）
  └─ 改写 body.model → 目标模型 → 既有 proxy 链路（不变）
```

**规则门永远先于缓存**：图片/超长上下文这类硬约束不允许被任何缓存绕过。

## 4. 特征提取与规则门

特征 `features(ReqMap)`：

- `ctx_tokens`：分段估算（见 §5）
- `has_images`：任一 message content parts 含 `image_url` / `input_image`
- `has_tools`：请求含非空 `tools`
- `marker_hit`：末条用户消息含升档标记（双方 lowercase，ASCII 词边界匹配，
  CJK 直接子串；标记表可配）
- `msg_count`

规则门（优先级自上而下，全部确定性）：

| # | 条件 | 去向 |
|---|---|---|
| 1 | `has_images` | `flagship`（档位表由用户保证含视觉模型，启动校验会提醒） |
| 2 | `ctx_tokens × 1.2 > big_ctx_tokens` | `big` |
| 3 | `marker_hit` | `flagship` |
| 4 | `not has_tools` 且 `ctx_tokens < fast_ctx_tokens` 且 `msg_count ≤ 3` | `fast` |
| 5 | 其余 | 判分区（rules-only 时 → `default_tier`） |

## 5. Token 估算（v2 分段）

```
cjk_chars   = 统计 CJK 码点数
other_bytes = 其余字节数
ctx_tokens  = ceil(cjk_chars × 1.5 + other_bytes / 4)
           + tools schema 字节 ÷ 4     （工具定义计入上下文）
           + max_tokens                 （输出预留）
```

- 中文按 1 汉字 ≈ 1.5 token（现代 tokenizer 上界），英文按 4 bytes/token；
- 规则 2 比较时再乘 1.2 安全余量——宁可误升 `big`，不可溢出小模型窗口；
- 多模态 parts 的 base64 不计入字节数（`has_images` 已由规则 1 处理）。

## 6. Judge（可选，用户指派）

- **输入**：约 200 token 英文分类指令（含"仅输出一个词"的强约束与输出白名单
  说明，对用户内容做引号包裹隔离，降低提示注入面）+ system 前 256 字符 +
  末条用户消息前 1200 字符；
- **请求体**：`{model, messages, max_tokens: 200, temperature: 0, stream: false}`——
  max_tokens 提高到 200 以容纳思考型 judge 的前置 token；
- **执行**：`spawn_monitor` + 唯一 `Ref` 选择性接收（迟到的无关消息不会污染
  调用方邮箱）；超时即 `exit(kill)`——被杀进程的上游连接由 gun 自行回收；
- **解析**：响应文本小写化、去空白后，与白名单 `<<"fast">> | <<"big">> |
  <<"flagship">>` **精确全词匹配**（取最后一个匹配词，避免 "not flagship, big"
  误判）；解析失败 = 降级；
- **熔断**：连续 5 次失败/超时 → 60s 内跳过 judge 直走 `default_tier`；
- **负缓存**：失败结论写 30s TTL，同一特征不重复触发判分；
- judge 调用注入内部标记（进程字典/显式参数，非 HTTP 头），物理上不可能
  重入 `maybe_route`。

## 7. 决策缓存（v2：只缓存 judge 结论）

- **Key**：`erlang:phash2({system前256, 末条用户前512, tools指纹, has_images,
  ctx_tokens div 4096}, 268435456)`（2^28 域）——图片位与 ctx 分桶冗余计入，
  防御性隔离规则门特征；
- **Value**：`{tier, expires_at}`；读取惰性过期；
- **容量**：`ordered_set` + 写入时间戳，>4096 行时按最旧清扫（非全表扫描）；
- 语义是**重试粘性**（同请求/同特征重试不重复判分），不是会话粘性；
- 多节点各自独立缓存，v1 接受跨节点档位差异（仅影响成本分布，不影响正确性）。

## 8. 配置（`janus` app env，sys.config）

```erlang
{auto_router, #{
    model => <<"janus-auto">>,
    %% 全部由部署者指派
    judge_model => undefined,              %% undefined = rules-only
    tiers => #{ fast => [], big => [], flagship => [] },
    default_tier => fast,
    %% 可选调参
    big_ctx_tokens => 60000,
    fast_ctx_tokens => 8000,
    judge_timeout_ms => 1500,
    cache_ttl_sec => 300,
    markers => [<<"ultrathink">>, <<"think harder">>, <<"深度思考">>, <<"仔细分析">>]
}}
```

**启动校验（首次读取配置时执行，结果缓存）**：

- `judge_model` / 任一 tier 候选 == 虚拟模型名 ⇒ error 日志 + 该项视为未配置
  （杜绝自引用，修 A6）；
- tier 候选不在 catalog ⇒ warn 日志（列出缺失名）；
- 整档为空且该档可能被规则命中 ⇒ error 日志（一次性，不刷屏）；
- `default_tier` 档为空 ⇒ error 日志。

**回退语义（v2，修 A5）**：不跨档升级。目标档为空 → `default_tier`；
`default_tier` 也为空 → 404 `no_route`（错误体注明 "auto-router tier
unconfigured"，与普通 no_route 区分，便于运维定位）。
虚拟模型不需要自身 routes；models 表一行仅用于 `/v1/models` 展示（修 A8）。

## 9. 失败语义

| 场景 | 行为 |
|---|---|
| 未配置 auto_router | `maybe_route` 恒 `pass`（一次 map 查询的开销） |
| maybe_route 内部异常 | catch → `pass` + warn（§2.3） |
| judge 未指派 | rules-only；中间地带 → default_tier |
| judge 超时/HTTP 错/解析失败 | default_tier + 负缓存 30s + 计入熔断 |
| 熔断开启（连败 5 次） | 60s 跳过 judge |
| 目标档候选全不可用 | → default_tier 档重试一次 |
| default 档也不可用 | 404 no_route（带 auto-router 标注） |

## 10. 观测

- 路由决策日志：`logger:debug`，`{reason: rules|judge|cache|negcache|breaker|fallback,
  tier, target, ctx_tokens, elapsed_ms}`；**升级为指标**：ETS 计数器
  （每 tier 路由数 / judge 失败数 / 熔断次数 / fallback 次数），
  v1 即提供 `janus_auto:stats/0`，admin `/overview` 后续接入；
- judge 失败与空档：warn/error 日志，rate-limited。

## 11. 隐私与合规声明

judge 会把请求的 system 前 256 字符与末条用户消息前 1200 字符发送给用户
自己指派的判分模型。若判分模型为第三方托管服务，这构成部分用户内容的
出域——部署者自行评估；不指派 judge 则零出域（rules-only）。

## 12. 测试计划

- eunit：features（CJK/ASCII 分段估算、图片检测、marker 边界匹配）、
  规则优先级与 ×1.2 余量、judge 白名单精确匹配（含 "not flagship" 反例）、
  负缓存/熔断状态机、缓存 key 隔离（同文本不同 ctx 分桶不互串）、
  启动校验（自引用拒绝）、catch 降级、未配置 pass-through；
- Docker 冒烟：种子造模型 + 假 provider；janus-auto 请求断言落到
  default_tier 对应上游、改写后的 body.model 正确。

## 13. Roadmap（本期不做）

- admin UI 指派界面（models 加 tier 字段 + 下拉）；
- 会话粘性显式化（客户端透传会话 ID）；
- 路由统计接入 /overview 图表。
