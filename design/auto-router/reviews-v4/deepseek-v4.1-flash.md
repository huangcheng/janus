# Review v2.2 by deepseek-v4.1-flash (deepseek-v4-1-flash-260910)

_24.0s · completion_tokens=4000_

我们被要求作为资深分布式系统与 LLM 基础设施工程师，对 Janus Auto Router 设计规格 v2.2 进行第四轮评审。需要严格审查：A. 仍然存在的缺陷或 v2.1 新引入的问题；B. 遗漏的边界情况；C. 具体可执行的改进建议。判定标准：只有影响正确性、安全性、可用性、成本的问题才算缺陷；风格偏好、措辞、假想的极端场景（现实中不会发生或影响可忽略）不计为问题。如果没有实质问题，请明确输出 PASS 并简述理由。每部分最多 5 条，用中文。

我们需要仔细阅读规格。前几轮可能已经修复了一些问题。现在我们要找出仍然存在的实质缺陷，注意不要提出风格或极端场景。每部分最多5条。

首先，理解整个设计。这是一个虚拟模型 `janus-auto`，根据请求特征路由到 fast / big / flagship 三个档位。规则门决定硬约束，判分区用可选的 judge 模型进行软决策。有缓存、熔断、并发控制等。

我们需要检查正确性、安全性、可用性、成本。

让我们逐节分析。

### 1. 目标/非目标
非目标包括计费与成本反馈学习、流式转发改造、跨档位授权控制（§2.2）、视觉/音频等专项路由档（统一并入 flagship 硬约束）。这些是明确的非目标，不应作为缺陷。

### 2. 核心原则
#### 2.1 网关对 provider 世界零假设
- judge 由用户指派，无默认值；档位模型列表由用户指派；
- 未指派 judge ⇒ rules-only；judge 失败 ⇒ 降级 rules-only 行为；
- 模型窗口大小等能力元数据 Janus 不知道也不猜测——容量保护只依赖用户配置的阈值。

这里说“judge 失败 ⇒ 降级 rules-only 行为”，但在后续流程中，judge 失败是 default_tier（soft），而不是 rules-only 行为？需要看：规则未决的请求进入判分区，如果未指派 judge，则 default_tier（soft）。judge 失败也降级为 default_tier。但“rules-only 行为”是指什么？可能是指只依赖规则，但规则已经决定了的请求不会进判分区。对于进入判分区的请求，如果没有 judge，就会走 default_tier。这算不算 rules-only？可能算是。但描述有细微差别：未指派 judge ⇒ rules-only；judge 失败 ⇒ 降级 rules-only 行为。实际代码中，未指派 judge 直接 default_tier，而 judge 失败也是 default_tier。所以一致。但“rules-only”可能意味着不调用 judge，只走规则。对于规则未决的请求，rules-only 就是 default_tier。没问题。

#### 2.2 授权模型
- key 是身份，不是配额；api_key_models 只对原始模型名生效，改写后不二次校验。唯一的 mitigation 是启动校验 warn。这被明确为定案，不再复议。所以不应作为缺陷提出，除非有严重安全漏洞，但已经定案。

#### 2.3 路由器自身永不制造 5xx
- maybe_route/2 整体 try/catch，意外异常降级为 pass + warn。可预期失败以返回值传递。
- 路由器范围之外的异常不属于承诺。

这看起来合理。但注意：如果 try/catch 捕获了所有异常，可能会隐藏错误，但设计如此。

### 3. 请求流水线
- ① 名字精确匹配
- ② features
- ③ 规则门 → {tier, hard} | {error, request_too_large} | 进入判分区
- ④ 判分区：未指派 judge → default_tier（soft）；熔断开启 → default_tier（soft）；judge 并发已满 → default_tier（soft，不计失败）；负缓存命中 → default_tier（soft）；决策缓存命中 → tier（soft）；judge 调用 → tier（soft）；失败 → default_tier
- ⑤ tier → 目标模型名（§8 解析规则，返回值式失败）
- 返回值联合类型：{ok, Target} | pass | {error, no_route} | {error, request_too_large}
- hard/soft 区分：规则门结论硬约束，目标档不可用不允许降级到 default_tier，直接 no_route；判分区结论软估计，允许降级。

潜在问题：
- 规则 0 返回 {error, request_too_large}，它是在规则门中。但规则门也返回 {tier, hard} 或进入判分区。所以规则 0 是特例，返回 error。逻辑上没问题。
- 判分区中，决策缓存命中返回 tier（soft），但如果该 tier 不可用，会降级到 default_tier 再试。这符合 soft 语义。
- 但是，判分区中“负缓存命中 → default_tier（soft）”，然后会走 ⑤ tier 解析。如果 default_tier 也不可用，则 soft 降级逻辑会尝试 default_tier 档再试一次？实际上 ⑤ 中 soft 结论的目标档不可用 → default_tier 档再试一次；仍不可用 → no_route。如果结论已经是 default_tier，那么它会尝试 default_tier，如果不可用，还会再试一次 default_tier？这可能导致重复尝试，但最终 no_route。逻辑上没问题，但可能效率稍低。
- 关键：规则 0 的检查在规则门中，但规则门是在 features 之后。features 计算可能依赖 messages，如果 messages 为空，features 能处理吗？§4.1 中有防御性定义：无 user 角色消息或 messages 为空 ⇒ marker_hit = false, LastUserPrefix = <<>>，judge 输入以 (no user message) 占位；此类请求不可能命中规则 2/5，自然落入判分区。但 features 中的 prompt_est 计算：如果 messages 为空，prompt_est 怎么算？规格没有明确。如果 messages 为空，prompt_est 可能为 0，tools_est 为 0，max_out 默认 4096，est_total = 4096。规则 0 检查 est_total > max_ctx_tokens，如果 max_ctx_tokens 配置为小于 4096，则会返回 request_too_large。这可能不是大问题，但需要看是否合理。空 messages 可能是一个无效请求，但网关可能应该返回 400。不过规格没有说空 messages 是错误。这算边界情况吗？可能不算严重，但可以提。

- 另一个潜在问题：规则 3 的条件是 `(prompt_est + tools_est) × 1.2 > big_ctx_tokens`，则去 big。这意味着如果 prompt+tools 的估计值超过 big 窗口的 1/1.2 ≈ 83.3%，就认为需要 big。但 big_ctx_tokens 是总窗口，包括输出。这里只乘 prompt+tools，不乘 max_out，理由是修 N6。但规则 3 的目标是确保整个请求（prompt+tools+output）不超过 big 窗口。如果 prompt+tools 已经接近 big_ctx_tokens，加上 max_out 后可能超过 big 窗口。规则 3 只检查 prompt+tools 部分，如果 (prompt+tools)*1.2 > big_ctx_tokens，则路由到 big。但如果 (prompt+tools)*1.2 没超过 big_ctx_tokens，但加上 max_out 后超过了 big 窗口，那么请求会落入规则 4 或判分区。规则 4 检查 est_total < fast_ctx_tokens，如果 fast_ctx_tokens 远小于 big_ctx_tokens，那么这种请求可能进判分区，最终可能被分配到 fast 或 big？如果分配到 fast，但实际总长度可能超过 fast 窗口？但规则 4 已经检查了 est_total < fast_ctx_tokens，所以如果 est_total 包含 max_out，它已经检查了总长度不超过 fast 窗口。所以对于规则 4，没问题。对于判分区，judge 可能决定去 fast，但 est_total 可能超过 fast_ctx_tokens？不，规则 4 的条件是 est_total < fast_ctx_tokens 且 msg_count ≤ 3 且 not has_tools，如果不满足，则进入判分区。判分区可能决定去 fast，但此时 est_total 可能已经 >= fast_ctx_tokens。这是一个潜在问题：判分区可能将请求路由到 fast，但该请求的总 token 估计超过了 fast 窗口。规格中规则门是硬约束，判分区是软估计。但容量保护应该依赖于配置的阈值。§2.1 说“容量保护只依赖用户配置的阈值”。但是，如果判分区将请求路由到 fast，而 fast 窗口不足以容纳整个请求，那么会发生什么？fast 模型可能拒绝或截断。这算不算正确性问题？设计上，规则 4 已经确保了只有 est_total < fast_ctx_tokens 的请求才会被硬路由到 fast。但判分区可能将更大的请求路由到 fast。规格中没有说判分区不能将超过 fast_ctx_tokens 的请求路由到 fast。这是一个漏洞：判分区覆盖了规则 4 的条件，但可能做出与容量冲突的决策。例如，一个请求 est_total = 10000，fast_ctx_tokens = 8000，big_ctx_tokens = 60000。规则 0 检查 max_ctx_tokens（假设未配置或很大）。规则 1 无多模态，规则 2 无标记，规则 3: (prompt_est+tools_est)*1.2 > 60000? 可能不满足。规则 4: est_total < 8000? 不满足（10000 > 8000）。所以进入判分区。judge 可能认为这是一个简单的短请求，返回 fast。然后路由器将请求路由到 fast 模型。但 fast 窗口只有 8000，而请求估计总长度 10000，可能超过 fast 窗口。这会导致上游错误。规格中是否应该确保判分区的结果不违反容量约束？或者判分区应该只建议，容量硬约束仍然生效？目前，规则门是硬约束，判分区是软估计，但软估计的结果可能违反硬约束。这是一个正确性问题：容量保护被绕过。设计者可能认为 judge 会考虑长度？但 judge 输入只包含 system 前 256 字符和末条 user 消息前 1200 字符，它看不到完整的长度信息。所以 judge 无法知道 est_total。因此，判分区可能将超大请求路由到 fast。这是一个缺陷。

修复建议：在判分区得出结论后，应该再次应用容量检查。例如，如果 judge 返回 fast，但 est_total >= fast_ctx_tokens，则应该强制升级到 big 或允许降级？或者，在 ⑤ tier 解析之前，对 soft 结论的目标档也应用容量检查：如果目标档的容量阈值 < est_total，则不允许该档，转而尝试下一个安全的档位。但规格中没有这样的逻辑。这是一个重要缺陷。

- 规则 5 被改为 `est_total < fast_ctx_tokens`？等等，表格中规则 4 是 `not has_tools` 且 `est_total` < `fast_ctx_tokens` 且 `msg_count ≤ 3` → fast。规则 5 是其余 → 判分区。所以进入判分区的请求可能 est_total 大于 fast_ctx_tokens，但小于 big_ctx_tokens（因为规则 3 没命中）。judge 可能返回 fast，导致容量溢出。这确实是一个问题。

- 另外，规则 3 的条件是 `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` → big。如果这个条件不满足，意味着 prompt+tools 的 1.2 倍不超过 big 窗口。但总请求包括 max_out。如果 max_out 很大，est_total 可能超过 big 窗口。例如，big_ctx_tokens = 60000，prompt_est+tools_est = 40000，max_out = 30000，est_total = 70000。规则 3 检查 (40000)*1.2 = 48000 > 60000? 否。所以不路由到 big。规则 4 检查 est_total < fast_ctx_tokens? 70000 < 8000? 否。进入判分区。judge 可能返回 fast 或 big。如果返回 big，但 est_total=70000 > big_ctx_tokens=60000，也会超过 big 窗口。规则 0 检查 est_total > max_ctx_tokens，如果 max_ctx_tokens 未配置或很大，则不会拦截。所以，即使 judge 返回 big，也可能超过 big 窗口。这是一个更普遍的问题：规则门没有确保 est_total 不超过 big_ctx_tokens。规则 3 只检查了 prompt+tools 的 1.2 倍，没有考虑 max_out。设计者可能认为 big_ctx_tokens 是总窗口，所以应该检查 est_total 是否超过 big_ctx_tokens？但规则 3 的目的是什么？如果 (prompt_est+tools_est)*1.2 > big_ctx_tokens，则说明 prompt+tools 太大，需要 big 档？这逻辑有点奇怪：big_ctx_tokens 是 big 档的总窗口。如果 prompt+tools 的 1.2 倍已经超过 big 窗口，那么总请求肯定超过 big 窗口，应该被拒绝或需要更大的窗口。但设计中没有更大的档，旗舰档可能窗口更大？但规格没有说旗舰档窗口更大，只说“flagship 窗口由部署者保证 ≥ big”。所以旗舰档至少不小于 big。如果 (prompt+tools)*1.2 > big_ctx_tokens，那么总请求可能超过 big，但旗舰档可以容纳。所以路由到 flagship 是合理的。但规则 3 却路由到 big，而不是 flagship！这是一个严重的逻辑错误。

让我们仔细看：规则 3: `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` → `big`。性质：hard。这意味着如果 prompt+tools 的估计值乘以 1.2 超过了 big 的窗口，路由器认为应该去 big。但 big 的窗口是 big_ctx_tokens，如果 prompt+tools 的 1.2 倍已经超过 big_ctx_tokens，那么总请求（加上 max_out）几乎肯定超过 big_ctx_tokens，big 模型无法处理。应该去 flagship（假设旗舰窗口更大）。但规则 3 却去 big。这会导致 big 模型溢出。除非 big_ctx_tokens 不是 big 模型的窗口，而是路由器用于判断是否升级到 big 的阈值？规格说：`big_ctx_tokens` / `fast_ctx_tokens` 语义为**总窗口**（prompt+tools+output）。所以 big_ctx_tokens 是 big 档的总窗口。如果 prompt+tools 的 1.2 倍 > big_ctx_tokens，那么总请求肯定超过 big 窗口。路由到 big 是错误的。应该路由到 flagship。这是 v2.2 中可能新引入或未修复的问题。

再看规则 4: `not has_tools` 且 `est_total < fast_ctx_tokens` 且 `msg_count ≤ 3` → fast。这检查了 est_total < fast_ctx_tokens，所以总长度在 fast 窗口内。合理。

规则 3 应该检查什么？可能是：如果 est_total 超过 fast_ctx_tokens 但不超过 big_ctx_tokens，则去 big。如果超过 big_ctx_tokens，则去 flagship。但规则 1 和 2 已经将多模态和标记的请求送到 flagship。规则 3 应该处理容量。正确的容量规则应该是：
- 如果 est_total > big_ctx_tokens → 需要 flagship（但 flagship 窗口是否保证？设计说 flagship 窗口由部署者保证 ≥ big，所以旗舰至少能容纳 big 窗口。但如果 est_total > flagship 窗口呢？没有检查。可能假设旗舰足够大。）
- 如果 est_total > fast_ctx_tokens 且 est_total <= big_ctx_tokens → 去 big。
- 如果 est_total <= fast_ctx_tokens 且无工具且 msg_count ≤ 3 → 去 fast。
- 否则判分区。

但目前的规则 3 是 `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` → big。这个条件实际上是：prompt+tools 的保守估计超过 big 窗口。这意味着总请求可能超过 big 窗口，应该去旗舰，而不是 big。所以规则 3 的目标档位错误。应该改为 flagship。这是一个严重的正确性缺陷。

可能设计者的意图是：如果 prompt+tools 的 1.2 倍 > big_ctx_tokens，说明请求很大，需要用 big 档？但 big 档的窗口就是 big_ctx_tokens，逻辑矛盾。也许 big_ctx_tokens 不是 big 模型的窗口，而是路由器配置的一个阈值，表示“超过这个就认为需要 big 档”。但规格明确说“big_ctx_tokens / fast_ctx_tokens 语义为总窗口”。如果它是总窗口，那么规则 3 的条件意味着请求的总窗口需求超过 big 窗口，所以应该去旗舰。因此，规则 3 的去向应该是 flagship，而不是 big。

但等等，规则 1 和 2 已经是 flagship。规则 3 可能是为了处理“没有多模态、没有标记，但上下文很大”的情况。如果上下文大到超过 big 窗口，应该去旗舰。所以规则 3 应该去 flagship。但当前是 big，这会导致 big 模型超限。这是一个明确的缺陷。

让我们检查规则优先级：
0: est_total > max_ctx_tokens → 400
1: has_multimodal → flagship
2: marker_hit → flagship
3: (prompt_est + tools_est) × 1.2 > big_ctx_tokens → big
4: not has_tools 且 est_total < fast_ctx_tokens 且 msg_count ≤ 3 → fast
5: 
