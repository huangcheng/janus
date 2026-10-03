# Auto Router Spec — 七模型评审综合报告

评审模型：MiniMax-M3 · MiMo v2.6-pro · StepFun step-5-preview · Qwen3.8-max ·
DeepSeek v4.1-flash（Ark）· GLM-5.3（智谱 coding plan）· Kimi k3
原始评审：`reviews/*.md`（逐字保留）· 日期：2026-10-03

## 共识发现（按提及模型数排序）

### A. 关键缺陷

| # | 缺陷 | 提及 | 共识修法 |
|---|---|---|---|
| A1 | **缓存先于规则门，key 不含 ctx_tokens / 图片 / tools 体积**——确定性规则被缓存绕过：同文本先短后有图/长上下文 → 命中旧档 → 上游溢出或视觉请求打到非视觉模型 | 7/7 | 流水线重排为**规则门 → 缓存 → judge**；规则零成本无需缓存；缓存只存 judge 结论，key 含 ctx 分桶、图片位、tools 指纹 |
| A2 | **§2 "永不 5xx" 与 §9 "crash → 500" 自相矛盾** | 4/7 | `maybe_route` 整体 try/catch，异常降级 `pass` + warn 日志 |
| A3 | **judge 超时不杀进程、不取消**：进程/连接泄漏、迟到回复污染调用方邮箱（须唯一 Ref 选择性接收）、无熔断 → judge 抖动时每请求 +1.5s | 5/7 | monitor + 超时 kill；唯一 Ref 选择性接收；30s 负缓存；连续 N 失败熔断 60s |
| A4 | **token 估算 bytes/3 对中文系统性低估**（1 汉字 ≈ 1~2 token ≠ 1 token）→ 长中文请求塞进小模型溢出；且未计 tools schema 与 max_tokens 输出预留 | 5/7 | CJK 字符 ×1.5、ASCII ÷4 分段估算；比较阈值加 20% 安全余量；计入 tools 与 max_tokens |
| A5 | **空档回退 flagship→big→fast 静默烧钱**：fast 档配置错误 → 全量静默升旗舰，且仅 debug 日志不可见 | 4/7 | 取消跨档升级；档空 → default_tier → 仍空返回带明确错误码的 404/503；空档启动时 error 日志 |
| A6 | **自引用无防护**：judge_model 或 tiers 填入 `janus-auto` → 无限递归 | 4/7 | 启动校验拒绝虚拟名出现在 judge/tiers；judge 请求注入内部标记旁路路由 |
| A7 | **授权语义未声明**：key 只授 janus-auto 实际可触达档位内全部模型，model_allowed 被旁路 | 3/7 | 规格显式声明"虚拟模型 = 档位并集授权"，或改写后再校验（二选一，需定夺） |
| A8 | **janus-auto 自身 routes 作兜底池语义错误**：转发上游时携带虚拟名 → 真实 provider 必 404 | 1/7 | 删除该兜底，或强制其 routes 配 upstream_model_id |
| A9 | **phash2 碰撞**（默认 2^27 域，4096 条时碰撞率可观）+ §6 "会话粘性"声称不成立（key 含末条消息，每轮必变） | 3/7 | `phash2/2` 扩域至 2^28+ 或 crypto hash；修正 §6 表述为"同请求重试粘性" |

### B. 其他风险（择要）

- 升档标记裸子串匹配：代码块/引用/否定句误触发（"don't think harder"）；大小写未定义
- judge 提示注入：用户消息可操纵判分结果（升档烧钱）——与 markers 同级风险，需 system 隔离 + 输出白名单校验
- 流式请求 TTFB 最多 +1.5s（judge 串行），规格未向部署者预警
- 改写后 max_tokens / 温度等参数未按目标模型钳制
- 多节点部署缓存独立 → 同会话跨节点档位漂移
- judge 把用户 prompt 送第三方模型的合规/隐私问题未声明
- 观测仅 debug 日志，错误路由与成本漂移线上不可见

## 评审过程备注

- qwen3.8-max 开思考模式时 300s 超时（评审任务思考链过长），`enable_thinking:false` 后 35s 完成；
- Kimi k3 要求 `temperature=1`（API 限制）；
- 响应均触顶 4000 max_tokens（k3 3856、M3 4000）——思考型模型的可见输出被 thinking 占用，正文实际短于上限。

## 结论

Spec 的整体架构（虚拟模型 + 档位指派 + 双模式降级）获全部模型认可；
但 A1–A6 六项必须修正后才能实施，A7/A9 需要产品决策。下一步：出 SPEC v2。
