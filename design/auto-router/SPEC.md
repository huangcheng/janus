# Janus Auto Router — 设计规格

状态：草案（待确认后实施）
作者：ZCode 会话 · 2026-10-03

## 1. 目标 / 非目标

**目标**：提供 `janus-auto` 虚拟模型——按请求特征自动路由到 fast / big / flagship
三档真实模型，复用现有 models / routes / LB 结构，配置全部由部署者指派。

**非目标**：计费与成本反馈学习（bandit）、按用户差异化策略、流式转发改造、
多模态专项路由（v1 仅规则识别，不单独选视觉档）。

## 2. 核心约束：网关对 provider 世界零假设

部署者用什么上游、有没有便宜小模型，Janus 一概不知。因此：

- 判分小模型（judge）**必须由用户指派**（catalog 中任一模型），无默认值；
- 档位模型列表**必须由用户指派**，指向其 catalog 中的模型名；
- 未指派 judge ⇒ **rules-only 模式**（纯确定性规则，功能完整可用）；
- judge 超时 / 失败 / 不可解析 ⇒ 自动降级为 rules-only 行为，**永不因路由器导致 5xx**。

## 3. 请求流水线

```
POST /v1/chat/completions  model="janus-auto"
  ├─ model_allowed 检查（对原始名 janus-auto，agent key 只需授予虚拟模型）
  ├─ janus_auto:maybe_route(ModelName, ReqMap)
  │    ├─ ① 决策缓存命中（内容哈希，TTL 300s）→ tier
  │    ├─ ② 规则门（确定性，0ms）→ tier 或 进入判分
  │    ├─ ③ judge（仅当用户已指派）→ tier；失败 → default_tier
  │    └─ ④ tier → 具体模型名（用户指派列表 ∩ catalog 在售，LB 择路）
  └─ 改写 body.model → 目标模型 → 既有 proxy 链路（不变）
```

## 4. 规则门（确定性，优先级自上而下）

| # | 条件 | 去向 |
|---|---|---|
| 1 | 请求含图片输入（multimodal parts） | `flagship`（档位表由用户保证含视觉模型） |
| 2 | `ctx_tokens > big_ctx_tokens`（默认 60000） | `big` |
| 3 | 末条用户消息含升档标记（`ultrathink`、`think harder`、`深度思考`、`仔细分析`…，可配） | `flagship` |
| 4 | 无 tools 且 `ctx_tokens < fast_ctx_tokens`（默认 8000）且消息数 ≤ 3 | `fast` |
| 5 | 其余 | judge；无 judge 时 `default_tier` |

`ctx_tokens` 估算：messages 内容字节总量 ÷ 3（中英混合保守估计，误差可接受，
规则门只需量级正确）。

## 5. Judge（可选，用户指派）

- 输入：约 200 token 的英文分类指令 + system 前 256 字符 + 末条用户消息前 1200 字符；
- 请求体：`{model=judge 路由, max_tokens=16, temperature=0, stream=false}`；
- 执行：`janus_lb:pick_route` 选路 → `janus_providers_openai:chat_completions`，
  外层 spawn + `receive after judge_timeout_ms`（默认 1500ms）超时保护；
- 解析：响应文本小写化，取 `fast | big | flagship` 首个匹配词；解析失败 = 降级。

## 6. 决策缓存

- Key：`phash2({system 前 256 末条用户前 512, tools 是否存在})`；
- Value：`{Tier, ExpiresAt}`；读取时惰性过期；写入时若表 > 4096 行做一轮清扫；
- 意义：同会话重复请求不再判分（judge 成本≈0），且天然近似"会话粘性"——
  相似请求稳定落同一档，减少上游 prompt cache 失效。

## 7. 配置（`janus` app env，sys.config）

```erlang
{auto_router, #{
    model => <<"janus-auto">>,            %% 虚拟模型名（用户可改）
    %% ↓↓↓ 全部由部署者指派，网关零假设 ↓↓↓
    judge_model => undefined,              %% catalog 模型名；undefined = rules-only
    tiers => #{
        fast      => [],                   %% 各档候选模型名列表（按序尝试）
        big       => [],
        flagship  => []
    },
    default_tier => fast,
    %% 可选调参
    big_ctx_tokens => 60000,
    fast_ctx_tokens => 8000,
    judge_timeout_ms => 1500,
    cache_ttl_sec => 300,
    markers => [<<"ultrathink">>, <<"think harder">>, <<"深度思考">>, <<"仔细分析">>]
}}
```

`tiers` 内模型名解析失败（不在 catalog / 无路由）则跳过该候选；整档为空时
按 `flagship → big → fast` 顺序回退（都空则维持现状 404 `no_route`）。

虚拟模型本身是 models 表普通一行（便于 `/v1/models` 展示与 key 授权），
其自身 routes 可作为"所有档位全空时的兜底 LB 池"。

## 8. 模块与集成点

- 新增 `janus_core/src/janus_auto.erl`：
  - `maybe_route/2` — 入口；虚拟名不匹配返回 `pass`（零开销路径）
  - `features/1` / `rules_gate/1` / `judge/2` / `cache_*` — 纯函数为主，便于 eunit
  - ETS 惰性建表（`ensure_table` 模式，参照 janus_admin_session，无需监督树子进程）
- 修改 `janus_http_chat:proxy_chat/5`：resolve_model 前插入 `maybe_route`；
  body 的 `model` 字段改写为目标模型名后走既有链路。
- 无 DB schema 变更；无 admin API 变更。

## 9. 失败语义

| 场景 | 行为 |
|---|---|
| 未配置 auto_router | `maybe_route` 恒 `pass`，功能不存在 |
| judge 未指派 | rules-only；中间地带 → default_tier |
| judge 超时/HTTP 错/解析失败 | 同上（记 debug 日志） |
| 目标档候选全不可用 | 档间回退 flagship→big→fast → 仍失败则 404 no_route |
| 路由器自身 crash | chat handler 已有 try/catch → 500，不影响数据面其他模型 |

## 10. 观测

- 每次决策 `logger:debug`：`{reason: rules|cache|judge|fallback, tier, target, ctx_tokens}`；
- v2 再加 ETS 计数器进 /overview。

## 11. 测试计划

- eunit：features 提取（token 估算 / 标记 / 图片检测 / tools）、规则优先级、
  judge 输出解析、缓存 TTL 与容量清扫、未配置时 pass-through；
- Docker 冒烟：种子造 2 个模型 + 假 provider；请求 janus-auto（无 judge）→
  断言落到 default_tier 对应上游（或规则触发的档位），验证整链改写正确。

## 12. Roadmap（本期不做）

- admin UI 指派界面：models 表加 `tier` 字段 + 控制台下拉指派，替代 sys.config 手配；
- 会话粘性显式化（客户端透传会话 ID）；
- 判分结果回流统计（不做成本 bandit，仅可视化）。

## 13. 待确认

1. 虚拟模型默认名 `janus-auto` 是否 OK？
2. 三档命名 fast/big/flagship 是否够用（要不要加 `code` 专档）？
3. `big_ctx_tokens` 默认 60000、`fast_ctx_tokens` 默认 8000 的阈值量级是否符合预期？
4. 档位全空时的回退顺序 flagship→big→fast 是否符合直觉（还是应 fast 优先省钱）？
