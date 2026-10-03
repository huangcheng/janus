# Review v2 by deepseek-v4.1-flash (deepseek-v4-1-flash-260910)

_24.0s · completion_tokens=4000_

我们被要求审查 v2 设计规格。这是第二轮评审。需要重点审查：A. 仍然存在的缺陷或 v2 新引入的问题；B. 遗漏的边界情况；C. 具体可执行的改进建议。每部分最多 5 条，直接给结论和理由，不客套。用中文。

我们需要分析这个规格。首先理解整个设计。它描述了一个自动路由器，虚拟模型 janus-auto，根据请求特征路由到 fast/big/flagship 三个档位。有规则门、judge 小模型可选、缓存、熔断、负缓存等。

v2 声称修复了 v1 的多个缺陷：
① 规则门先于缓存，缓存只存 judge 结论（修 A1）
② maybe_route 全量 catch 降级，兑现"永不 5xx"（修 A2）
③ judge 加固：monitor+kill、唯一 Ref 选择性接收、负缓存、熔断（修 A3）
④ token 估算改为 CJK/ASCII 分段 + 余量 + 计入 tools/max_tokens（修 A4）
⑤ 取消跨档回退：档空 → default_tier → 明确错误（修 A5）
⑥ 启动校验拒绝自引用（修 A6）
⑦ 授权定案：key 默认可访问所有模型，改写后不二次校验（定案 A7）
⑧ 删除 janus-auto 自身 routes 兜底池（修 A8）
⑨ 缓存哈希扩域；"会话粘性"表述修正为"重试粘性"（修 A9）

我们需要审查是否还有缺陷，v2 新引入的问题，遗漏边界，改进建议。

我们逐部分分析。

## 1. 目标/非目标
目标：自动路由到 fast/big/flagship。非目标：计费与成本反馈学习、流式转发改造、多模态专项路由档、跨档位授权控制。

问题？非目标说"跨档位授权控制"不做，在 §2.2 授权模型定案。但这里可能有隐患：如果 key 默认可访问所有模型，改写后不二次校验，那么用户可能通过 janus-auto 访问原本被 api_key_models 限制的模型？但规格说 api_key_models 仅对原始模型名生效，所以如果用户原始请求是 janus-auto，而 janus-auto 不在限制内，那么改写后可以访问任何模型。这可能导致权限提升：如果管理员想限制某 key 只能访问特定模型，但允许访问 janus-auto，那么该 key 可以通过 janus-auto 路由到任何 tier 模型。规格说"不存在越权概念"，但这是有争议的。不过这已经被定案为设计决策。审查可能指出：这可能导致安全边界模糊，如果部署者期望 api_key_models 作为安全控制。但规格明确说 key 是身份不是配额，所以可能不是缺陷，而是设计选择。但我们可以提为风险。

## 2. 核心原则
### 2.1 零假设
### 2.2 授权模型
### 2.3 永不制造 5xx
这里说 maybe_route 全体 try/catch，内部任何异常降级为 pass。但是，如果 maybe_route 内部异常，降级为 pass，即按普通模型处理。但是模型名是 "janus-auto"，如果 pass，那么后续 proxy 链路会尝试将 janus-auto 作为真实模型去查找 routes。如果 janus-auto 没有 routes（v2 删除了自身 routes 兜底池），那么会怎样？§8 说"虚拟模型不需要自身 routes；models 表一行仅用于 /v1/models 展示（修 A8）"。那么如果 pass，即不进行路由改写，请求的 model 仍然是 "janus-auto"，proxy 会尝试路由到 janus-auto 模型，但 janus-auto 没有 routes，所以会失败，返回 404 或 5xx？这与"永不 5xx"承诺矛盾。因为 maybe_route 异常时降级为 pass，但 pass 意味着按普通模型处理，而 janus-auto 没有真实路由，最终会 no_route 错误。虽然可能不是 5xx，而是 404，但"永不制造 5xx"可能指的是不返回 5xx，但 404 也是错误。而且如果内部异常，用户得到 404，这也不是成功处理。规格说"降级为 pass（按普通模型处理）+ rate-limited warn 日志"，但按普通模型处理 janus-auto 会因为没有 routes 而失败。这是一个严重问题：v2 删除了 janus-auto 自身 routes 兜底池（修 A8），但 pass 降级需要有一个兜底路由才能工作。否则异常时用户收到错误。这可能是 v2 新引入的问题，因为 v1 可能有兜底池，v2 删除了。所以需要指出：pass 降级语义与删除自身 routes 矛盾，导致异常时请求无法完成，违反"永不制造 5xx"精神。除非 pass 意味着直接返回错误？但规格说按普通模型处理，普通模型需要 routes。所以这是一个缺陷。

### 2.3 说 §9 失败语义表一致。我们看 §9：未配置 auto_router → maybe_route 恒 pass（一次 map 查询开销）。但同样，如果未配置 auto_router，那么 janus-auto 模型存在吗？如果存在，但没有 auto_router 配置，pass 后也会 no_route。所以这里也有同样问题。

## 3. 请求流水线
整体 try/catch。规则门先于缓存。判分区：熔断->负缓存->决策缓存->judge。然后 tier->模型名。

问题：步骤④ "tier → 模型名（用户指派列表 ∩ catalog，按序取首个可用）"。这里"可用"如何定义？是否检查模型是否在 catalog？如果候选列表为空，则回退 default_tier。但是，如果候选列表中的模型在 catalog 中但实际 provider 不可用（比如 provider 宕机），是否会尝试下一个？规格说"按序取首个可用"，但没有定义"可用"的检测机制。是仅检查 catalog，还是实时健康检查？如果是仅检查 catalog，那么可能选中一个当前不可用的模型，导致请求失败。但这是现有 LB 的职责？可能 proxy 链路会处理。但这里说"用户指派列表 ∩ catalog，按序取首个可用"，可能意味着只取第一个存在的，不探测健康。这是可以接受的，因为后续 LB 会重试？需要看现有结构。但可以提为遗漏边界：如果目标档所有模型在 catalog 中但都不可用，如何回退？规格说"目标档候选全不可用 → default_tier 档重试一次"。但"全不可用"如何判定？是 catalog 中不存在，还是请求时失败？如果只是 catalog 不存在，那么如果存在但请求失败，不会触发回退到 default_tier，而是直接返回错误。这可能与"永不制造 5xx"有冲突。但也许 proxy 层有重试。需要明确。

## 4. 特征提取与规则门
特征：ctx_tokens, has_images, has_tools, marker_hit, msg_count。
规则门：
1 has_images -> flagship
2 ctx_tokens * 1.2 > big_ctx_tokens -> big
3 marker_hit -> flagship
4 not has_tools 且 ctx_tokens < fast_ctx_tokens 且 msg_count <= 3 -> fast
5 其余 -> 判分区

问题：规则 1 无条件旗舰，即使图片是极小尺寸或无关。这可能导致成本过高。但这是设计选择。规则 2 使用 big_ctx_tokens 比较，但 fast_ctx_tokens 只在规则 4 中使用。规则 2 的条件是 ctx_tokens * 1.2 > big_ctx_tokens，这意味着如果 ctx 超过 big 的上下文窗口，则路由到 big？但 big 档的上下文窗口应该比 fast 大，比 flagship 小？这里 big_ctx_tokens 是 big 档的上下文限制？如果 ctx_tokens * 1.2 > big_ctx_tokens，说明请求超过了 big 的窗口，应该去 flagship 才对？但规则说去 big？这逻辑有问题。让我们仔细读：配置中有 `big_ctx_tokens => 60000, fast_ctx_tokens => 8000`。规则 2：`ctx_tokens × 1.2 > big_ctx_tokens` → `big`。这意味着如果估算 token 超过 big 的窗口（乘以余量），则路由到 big。但超过 big 窗口应该去更大的旗舰，而不是 big。这似乎反了。可能他们的意图是：如果超过 fast 窗口但没超过 big 窗口，则去 big？但规则 2 的条件是 `ctx_tokens × 1.2 > big_ctx_tokens`，这是超过 big 窗口。如果超过 big 窗口，应该去 flagship 才对。或者 big_ctx_tokens 是 fast 的上限？配置名是 big_ctx_tokens，应该是 big 档的窗口。那规则 2 把超过 big 窗口的请求发到 big，会导致溢出。而规则 4：`ctx_tokens < fast_ctx_tokens` 且无工具且消息少 → fast。那么中间地带（超过 fast 但不超过 big）会进入判分区，由 judge 决定。这似乎合理？但规则 2 的条件写的是 > big_ctx_tokens，即超过 big 窗口，那应该去旗舰。我认为这是逻辑错误：规则 2 应该是 `ctx_tokens × 1.2 > fast_ctx_tokens` → big？或者 `ctx_tokens × 1.2 > big_ctx_tokens` → flagship？需要检查。如果 big_ctx_tokens 是 big 档能处理的最大 token，那么超过它应该去 flagship。但规则 2 去了 big。这会导致请求超过 big 窗口，可能被上游拒绝或截断。这是一个严重缺陷。也许他们想表达：如果超过 fast 窗口但小于 big 窗口，去 big。但条件写错了。应该用 `fast_ctx_tokens` 作为阈值。让我们分析：规则 4：`not has_tools 且 ctx_tokens < fast_ctx_tokens 且 msg_count ≤ 3` → fast。这意味着小请求去 fast。规则 2：`ctx_tokens × 1.2 > big_ctx_tokens` → big。这意味着大请求去 big。那么中等请求（超过 fast 但小于 big）会进入判分区（规则 5）。但规则 2 把超大请求（超过 big）也发往 big，这是错的。应该有一个规则把超过 big 的发往 flagship。所以可能缺少规则：如果 ctx_tokens × 1.2 > big_ctx_tokens，应该去 flagship。而规则 2 可能是 `ctx_tokens × 1.2 > fast_ctx_tokens` → big。但规格明确写了 `> big_ctx_tokens`。这是一个明显的缺陷。可能是 v2 新引入的？v1 可能没有这个问题？需要指出。

另外，规则 1 图片去 flagship，但 flagship 可能没有视觉模型，启动校验只是提醒，不强制。如果旗舰档没有视觉模型，请求会失败。这是边界。

## 5. Token 估算
公式：cjk_chars * 1.5 + other_bytes / 4 + tools schema 字节 / 4 + max_tokens。注意：cjk_chars 是码点数，other_bytes 是其余字节数。但中文字符的 UTF-8 编码通常 3 字节，他们用码点数乘以 1.5 估算 token。其他字节除以 4。那么对于中英文混合，可能重复计算？比如中文字符的字节被算入 other_bytes 吗？他们定义：`cjk_chars = 统计 CJK 码点数`，`other_bytes = 其余字节数`。所以中文字符的字节数不包含在 other_bytes 中。那么 cjk_chars * 1.5 是估算 token。这合理。但是，对于非 CJK 的非 ASCII 字符（如俄语、阿拉伯语、emoji），它们会被算入 other_bytes，但每个字符可能占多个字节，除以 4 可能低估。例如 emoji 4 字节，按 1 token 算？可能可以。但更精确的 tokenizer 通常对非 ASCII 字符按字节或字符估算。这里可能低估某些语言。可以提为边界。

另外，`max_tokens` 直接加到 ctx_tokens。但 max_tokens 是输出预留，通常请求中 max_tokens 可能未指定，有默认值。如果未指定，是否用模型默认？规格没有说明。如果 max_tokens 缺失，可能为 0 或最大？需要明确。而且 `tools schema 字节 ÷ 4` 单独加，但 tools 可能包含大量 JSON，字节/4 可能低估，因为 JSON 中英文混合。可以接受。

规则 2 比较时再乘 1.2 安全余量。但上面公式已经加了 max_tokens。再乘 1.2 会重复保守。可以。

## 6. Judge
- 输入：约 200 token 英文分类指令 + system 前 256 字符 + 末条用户消息前 1200 字符。但注意，如果 system 消息很长，只取前 256 字符，可能丢失关键上下文。但这是权衡。
- 请求体：max_tokens: 200, temperature 0, stream false。
- 执行：spawn_monitor + 唯一 Ref 选择性接收，超时 exit(kill)。上游连接由 gun 自行回收。这里有个问题：exit(kill) 是立即终止进程，但 gun 连接可能不会被优雅关闭，可能会泄漏连接？他们声称由 gun 自行回收，但通常需要显式关闭。可以提。
- 解析：响应文本小写化、去空白后，与白名单精确全词匹配（取最后一个匹配词，避免 "not flagship, big" 误判）。取最后一个匹配词：如果响应是 "not flagship, big"，最后一个匹配是 big，所以判定为 big。但语义上 "not flagship, big" 意思是 "不是旗舰，是 big"，所以 big 正确。但如果响应是 "big, not flagship"，最后一个匹配是 flagship，会误判为 flagship。所以“取最后一个匹配词”策略并不总是避免否定误判。更好的做法是解析否定词或要求输出严格一个词。但规格说强约束仅输出一个词。所以如果遵守，没问题。但模型可能不遵守。可以提为风险。
- 熔断：连续 5 次失败/超时 → 60s 内跳过 judge 直走 default_tier。连续失败计数如何重置？成功一次就重置？规格未明确。可能是连续失败，成功则清零。合理。
- 负缓存：失败结论写 30s TTL，同一特征不重复触发判分。但负缓存的 key 是什么？应该是决策缓存的 key？如果是，那么成功也会缓存 300s。负缓存 30s。可以。
- judge 调用注入内部标记，物理上不可能重入 maybe_route。但如何保证？通过进程字典或显式参数。但 judge 请求是 HTTP 请求到自身或其他节点？如果是到外部 provider，不会重入。如果是到本网关的其他实例？可能。但标记是内部非 HTTP 头，所以外部无法伪造。可以。

## 7. 决策缓存
Key：`erlang:phash2({system前256, 末条用户前512, tools指纹, has_images, ctx_tokens div 4096}, 268435456)`。
问题：`ctx_tokens div 4096` 分桶，即每 4096 token 一桶。这可能导致不同 token 数的请求命中同一缓存，但 tier 可能因 token 数不同而不同。比如一个请求 10000 token，另一个 12000 token，分桶后可能在同一桶（10000 div 4096 = 2, 12000 div 4096 = 2），如果 judge 对前者判 big，对后者也可能判 big，但如果边界情况可能不同。不过有 1.2 余量规则门可能已经处理。但缓存 key 包含 ctx 分桶，而规则门在缓存之前，所以规则门会先决定 tier，不会走缓存。所以缓存只用于判分区的请求。判分区的请求是规则门未命中的，即中间地带。这些请求的 token 数可能都在 fast 和 big 之间。分桶可能造成轻微不精确，但影响成本分布，可以接受。
但是，缓存 key 使用了 `system前256` 和 `末条用户前512`，但没有包含 `has_tools` 和 `msg_count`？包含了 `tools指纹` 和 `has_images`，但没有 `msg_count`。如果两个请求 system 和末条用户相同，tools 相同，has_images 相同，ctx 分桶相同，但 msg_count 不同（比如一个 5 条消息，一个 10 条消息），judge 可能给出不同 tier。这会错误命中缓存。规格说"防御性隔离规则门特征"，但 msg_count 是特征之一，规则门规则 4 使用了 msg_count ≤ 3。如果请求因 msg_count 未命中规则 4 而进入判分区，缓存 key 却没有 msg_count，可能导致不同 msg_count 的请求共享缓存。这是一个遗漏。应该把 msg_count 或完整的消息列表指纹加入 key。可以提。

另外，缓存容量 4096 行，按最旧清扫。但 ordered_set 和写入时间戳，如何高效清扫？如果 >4096 行时按最旧清扫，需要维护顺序。可以。

多节点各自独立缓存，v1 接受跨节点档位差异。可以。

## 8. 配置
启动校验：首次读取配置时执行，结果缓存。
- 自引用拒绝：judge_model / 任一 tier 候选 == 虚拟模型名 ⇒ error 日志 + 该项视为未配置。
- tier 候选不在 catalog ⇒ warn。
- 整档为空且该档可能被规则命中 ⇒ error。
- default_tier 档为空 ⇒ error。

问题：启动校验在首次读取配置时执行，但 catalog 可能动态变化（新模型发布
