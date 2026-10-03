# Auto Router Spec v2 — 七模型二轮评审综合

评审模型同首轮（M3 / MiMo v2.6-pro / step-5-preview / qwen3.8-max /
deepseek-v4.1-flash / glm-5.3 / kimi-k3）。原始输出：`reviews-v2/*.md`。

## 一、首轮缺陷修复确认

| 首轮编号 | 结论 |
|---|---|
| A1 缓存绕过规则门 | ✅ 7/7 确认流水线重排正确；缓存只存 judge 结论成立 |
| A2 crash→500 矛盾 | ✅ 基本确认；kimi 补充：wrapper 之外的 model_allowed/body 改写异常仍会 500，措辞需覆盖"入口整体" |
| A3 judge 泄漏 | ⚠️ 大体修复；**新发现 DOWN 消息泄漏**（见 N1） |
| A4 中文低估 | ✅ 分段估算获认可；**max_tokens 语义引入新歧义**（见 N6） |
| A5 跨档回退 | ⚠️ 取消升级正确，但**硬结论兜底语义残留**（见 N2） |
| A6 自引用 | ✅ 启动校验 + 内部标记获认可 |
| A8 兜底池 | ✅ 已删 |
| A9 哈希/粘性 | ✅ 2^28 域碰撞率 ~3e-5 可接受；"重试粘性"表述认可 |

## 二、v2 新发现（高优先，实施前必修）

| # | 缺陷 | 发现者 | 修法 |
|---|---|---|---|
| N1 | **monitor DOWN 消息邮箱泄漏**：选择性接收 `{Ref, Result}` 永不消费 `{'DOWN', Ref, process, Pid, Reason}`，长期运行邮箱单调增长 | step-5（独家） | 正常收到回复后 `erlang:demonitor(Ref, [flush])`；超时路径 kill 后同样 flush |
| N2 | **规则硬结论落入 default_tier 兜底**：图片→flagship 而 flagship 空、长文→big 而 big 空，降级 default_tier=fast ⇒ 上游 400 溢出/不支持图片。规则门结论是硬约束，失败应直接返回带标注 404；**只有 judge 结论才允许降级** | glm-5.3、kimi-k3 | §9 区分 `rule-tier` 与 `judge-tier` 两种失败语义 |
| N3 | **"取最后一个匹配词"系统性误判**：分类指令本身含白名单词，小模型复述指令时最后一个词常为 flagship ⇒ 系统性偏向旗舰 | glm-5.3 | 改为"输出最后一行中的独立白名单词；无则取全文首个"；或 judge 输出格式定为首 token |
| N4 | **负缓存与熔断计数互相打架**：负缓存命中不经过 judge，连败 5 次可能永远凑不齐；语义未定义 | qwen3.8-max | 明确：连败计数只累计**实际发起的 judge 调用**失败；负缓存命中不计入也不清零 |
| N5 | **ordered_set "按最旧清扫"不可实现**：ordered_set 按 key 排序非时间序，找最旧需全表扫 | qwen、minimax | 双表结构：主表 `{Hash, Tier, Exp}` + 辅表 `{{Ts, Hash}}` ordered_set 取最旧；或写入时顺带记序号 |
| N6 | **max_tokens 语义歧义 + 双重放大**：`big_ctx_tokens` 指 prompt 窗口还是总窗口未定义；max_tokens 计入后再 ×1.2 导致大 max_tokens 请求必升 big；`max_completion_tokens` 字段未覆盖；缺失时取值未定义 | step-5、glm-5.3、kimi-k3 | 明确语义为"总窗口"；余量只乘 prompt 部分；兼容两字段名；缺失按 4096 默认 |
| N7 | **404 生成路径与 catch 边界模糊**：tier 空若以异常形式抛出会被 catch 吞成 `pass`，最终返回泛型 no_route 而非带 auto-router 标注的错误 | step-5、kimi-k3 | tier 解析失败以**返回值** `{error, no_route}` 传递，不走异常通道 |
| N8 | **A7 定案缺 mitigation**：定案不翻案，但配了 `api_key_models` 限制且白名单含 janus-auto 的 key，授权被静默扩大 | kimi、glm | 启动/重载校验：检测到此类 key 组合打一次 warn；admin UI 文案注明 |

## 三、中优先边界（v2.1 一并处理或列入已知限制）

- 非 CJK 非 ASCII（韩文/emoji）按 ÷4 低估 1.3–2.7×，1.2 余量兜不住（mimo）
- ctx 超过**所有**档位窗口时应显式 4xx "request too large"，而非丢给 big 让上游报错（mimo）
- marker 优先级在规则 2 之后：超长+marker → big 而非 flagship，与用户显式意图相悖；flagship 窗口通常 ≥ big，marker 提到规则 2 之前更合理（mimo，可辩论）
- judge 无并发上限：故障期放大系数 = 并发数 × 1500ms，建议 in-flight 信号量（glm）
- 音频等其他多模态 parts 无 has_images 等价规则，base64 又不计入 → 估算盲区（glm、minimax）
- 更换 judge_model 后熔断态未定义是否重置（mimo）
- 启动校验补：`default_tier ∈ keys(tiers)`、阈值/judge_timeout 为正数（minimax）
- system 多条/缺失时取哪条未定义；judge 截断 1200 与缓存 key 截断 512 的不一致需注释说明（glm、step）
- judge HTTP 连接 one-shot 还是池化未说明，影响 kill 后回收语义（step、qwen）
- `janus-auto:suffix` 类模型名约定不支持，需在文档注明精确匹配（kimi）

## 四、结论

v2 的核心结构（规则先于缓存、双模式降级、不跨档升级、自引用防护）获全票确认；
新问题集中在**实现细节层的语义未定义**（DOWN 清理、硬结论失败语义、解析规则、
状态机交互、清扫结构），无架构级返工。建议出 v2.1 增量修订：N1–N8 必修，
中优先项择半数入已知限制清单。
