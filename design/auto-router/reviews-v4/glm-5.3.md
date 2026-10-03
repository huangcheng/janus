# Review v2.2 by glm-5.3 (glm-5.3)

_70.7s · completion_tokens=4000_

让我仔细审查这个设计文档 v2.2。这是第四轮评审，前三轮的关键问题声称已修复。我需要找出仍然存在的缺陷、新引入的问题、遗漏的边界情况，以及给出可执行的改进建议。

让我系统地过一遍：

## 1. 规则 0 与 max_ctx_tokens 的交互

规则 0：`est_total > max_ctx_tokens` → 400。
启动校验：`max_ctx_tokens` 已配置但 < `big_ctx_tokens` ⇒ error + 忽略该上限。

等等，这里有个问题。校验是 `max_ctx_tokens < big_ctx_tokens` 时忽略上限。但应该是 `max_ctx_tokens < big_ctx_tokens` 报错。反过来想：如果 `max_ctx_tokens ≥ big_ctx_tokens`，那么规则 3（`(prompt_est + tools_est) × 1.2 > big_ctx_tokens` → big）会先于规则 0…… 不对，规则 0 先于一切。规则 0 先检查 `est_total > max_ctx_tokens`。

假设 `max_ctx_tokens = 100000`，`big_ctx_tokens = 60000`。一个请求 `est_total = 110000`，`prompt_est = 50000`。规则 0 触发：400。合理。

假设 `est_total = 70000`，`prompt_est + tools_est = 50000`，×1.2 = 60000 > 60000? 不大于（等于），那么规则 4：est_total 70000 > fast_ctx 8000，不命中。规则 5：判分区。judge 可能返回 fast？判分区结论是 soft，fast 档总窗口可能是……等等，这里有个关键问题：**judge 可以返回任意 tier，包括 fast，即使 est_total 超过 fast 档的实际容量**。

规则门只保证：
- est_total > max_ctx_tokens → 400
- prompt+tools 超过 big 阈值 ×1.2 → big（或 flagship，规则 1/2 优先）

但判分区/judge 可以把一个大请求（比如 est_total = 59000，没有超过 big 阈值规则）路由到 fast 档，而 fast 档模型实际窗口可能只有 8000（fast_ctx_tokens 语义是总窗口）。这会导致上游 400/上下文溢出错误。

不过文档说"容量保护只依赖用户配置的阈值，不依赖模型清单"，且判分区结论是 soft（软估计），允许降级。设计上 judge 是智能判断，judge 应该不会把长请求判成 fast……但 judge 只看 system 前 256 字符 + 末条 user 消息前 1200 字符，它不知道 est_total！judge 看不到请求长度信息。所以 judge 完全可能把一个 msg_count = 50、历史很长的对话判成 "fast"（因为末条 user 消息很短），然后 fast 模型收到一个 50 条消息的请求，超出其 8k 窗口。

等等，规则 4 要求 `msg_count ≤ 3` 且 est_total < fast_ctx_tokens 才走 fast（hard）。但规则 5 判分区没有对 fast 档的容量下限保护。判分区的输出可以是 fast/big/flagship 任意一个。如果 judge 判 fast，而 est_total = 50000（超过 fast 档实际窗口），请求会打到 fast 模型然后上游失败。

这是否算缺陷？在 v2.1 评审中提到"fast 档总窗口比较"已修复——规则 4 用 est_total < fast_ctx_tokens。但判分区路径没有这个保护。判分区进入条件是"未被规则 3 命中"，即 `(prompt+tools) × 1.2 ≤ big_ctx_tokens`，且 est_total ≤ max_ctx_tokens（若配置）。est_total 可能远超 fast 窗口。

一个具体例子：big_ctx_tokens = 60000，fast_ctx_tokens = 8000。请求 A：messages 有 20 条，prompt_est = 40000，无 tools，max_out = 4096。est_total ≈ 44096。规则 3：40000 × 1.2 = 48000 ≤ 60000 不触发。规则 4：est_total > 8000 不触发。进判分区。judge 只看到 system 256 + 末条 user 1200 字符，末条 user 是"好的，谢谢"这类短消息，judge 判 fast。然后 44096 token 的请求打到 fast 模型（8k 窗口）→ 上游上下文溢出错误 → 客户端收到错误。

这是真实的正确性/可用性问题。判分区结论缺少"est_total 不超 fast 窗口"的护栏。修复很简单：判分区结论为 fast 时检查 est_total < fast_ctx_tokens，否则提升为 big（或 default）。或者给 judge 输入加上长度特征。这个在之前几轮中似乎没有提到（前三轮提的是"fast 档总窗口比较"——规则 4 的比较从 prompt 改成 est_total，但 judge 路径的 fast 判定没有护栏）。

我认为这是一个实质缺陷：A 类。

## 2. 规则 3 的 ×1.2 与 max_out 的关系

规则 3：`(prompt_est + tools_est) × 1.2 > big_ctx_tokens` → big。这里比较对象是总窗口语义的 big_ctx_tokens，但左边没加 max_out。也就是说 prompt+tools = 50000，×1.2 = 60000，不超 60000，不加 max_out（4096 默认），实际 est_total = 54096 + 余量 20% = 64915 > 60000。可能溢出 big 窗口 → 应该去 flagship？但规则 3 只到 big。

等等，规则门里没有"prompt 超过 big 窗口 → flagship"的规则。如果 big 档模型窗口就是 60000，prompt+tools = 55000 × 1.2 = 66000 > 60000 → big。big 模型收到 prompt 55000 + max_out 4096 = 59096 ≤ 60000，OK。×1.2 的 20% 余量本来就是为了容纳 max_out？prompt 55000，余量 11000 > 4096 默认 max_out。但如果客户端显式设置 max_tokens = 16000，est_total = 71000 > 60000 窗口 → big 模型上游失败。

规则 3 只看 prompt+tools×1.2 不含 max_out（这是修 N6"双重放大"的结果——之前是 (prompt+tools+max_out)×1.2？现在改成只乘 prompt+tools，但完全去掉 max_out 是否矫枉过正？）。

考虑：prompt+tools = 55000，max_tokens = 32000（客户端显式要求长输出）。est_total = 87000。若 max_ctx_tokens 未配置（默认 undefined），规则 3：55000 × 1.2 = 66000 > 60000 → big。big 窗口 60000 < 87000 → 上游错误。规则 0 只在配置了 max_ctx_tokens 时生效，而 max_ctx_tokens 校验要求 ≥ big_ctx_tokens = 60000，所以即使配置了 max_ctx_tokens = 60000，est_total 87000 > 60000 → 400。这其实是把一个本可以走 flagship（比如 200k 窗口）的请求直接拒绝了。

更关键的问题：**没有规则把超 big 容量的请求路由到 flagship**。规则 1/2 到 flagship 的条件是多模态/marker，纯文本长请求最多到 big，超过 big 容量就直接 400（如果配了 max_ctx_tokens）或打到 big 然后上游失败（如果没配）。设计上"flagship 窗口由部署者保证 ≥ big"，那么合理的规则应该是：`est_total > big_ctx_tokens` → flagship（在 max_ctx_tokens 检查之后）。这个缺失在 v2.1/评审中好像没被指出。

嗯，等等——规则 3 是 `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` → big。语义是"接近 big 窗口就去 big"。但没有任何规则处理"超过 big 窗口"。判分区（规则 5）的 judge 可以判 flagship，但 judge 看不到长度。所以超长请求要么 400 要么失败。

具体场景：big_ctx = 60000，flagship 是 200k 窗口模型，max_ctx_tokens 配了 150000。请求 prompt_est = 100000。规则 0：est_total ~104096 < 150000 不触发。规则 3：100000 × 1.2 = 120000 > 60000 → big。big 模型 60k 窗口收到 104k 请求 → 上游错误。规则 0 的 150000 上限形同虚设，因为 big 档根本装不下。这明显是缺陷：应该有 `est_total > big_ctx_tokens → flagship` 的规则（且启动校验 flagship 容量 ≥ big 的假设）。

不过文档说"flagship 窗口由部署者保证 ≥ big"（规则 2 注释），所以规则 3'：est_total > big_ctx_tokens → flagship 是安全且必要的。缺失这条导致超长请求失败。A 类缺陷。

其实等一下，让我重读规则 3。规则 3 的条件是 `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` → big。如果 prompt 很大，比如 100000，这个条件命中 → big。但如果这个条件不命中（prompt ≤ 50000），而 est_total（含大 max_out）超了 60000 呢？比如 prompt 50000，max_tokens 20000：est_total 70000 > 60000。规则 4 不命中。规则 5 → 判分区 → judge 看不到长度 → 判 fast/big。判 big → 上游失败（70000 > 60000）。判 fast → 更糟。

所以无论哪个分支，都缺"est_total 相对 big/flagship 容量的保护规则"。规则 0 只做全局拒绝（400），不做升级路由。这是系统性缺口。v2.1 → v2.2 修了"规则 5 改为 est_total < fast_ctx_tokens"，但没有对称地修"est_total 相对 big 的溢出保护"。A 类，正确性/可用性。

## 3. 决策缓存 key 中的 prompt_est_bucket 与 judge 路由 fast 的组合

缓存 key 包含 prompt_est_bucket（4096 粒度）。判分区输入 key 有长度桶，所以缓存在长度维度有区分。但 judge 本身不看长度。缓存命中返回 fast 的场景与上面 A2/A1 相同。

## 4. 规则 2 marker 优先于规则 0？

规则表说规则 0 先于一切。表格顺序：0 → 1 → 2 → 3 → 4。所以 est_total > max_ctx_tokens 的多模态/marker 请求会 400。合理（文档明确说了"硬上限必须对多模态/marker/超长请求同样生效"）。

## 5. max_out 默认 4096 的缺省与 est_total

`max_completion_tokens ?? max_tokens ?? 4096`。若客户端不设置，est_total 按 4096 算。若客户端设 0？max_tokens = 0 是合法的吗（比如只要 logprobs 不生成）？0 是数字，?? 取 0（只要字段存在）。est_total = prompt + 0。OK，无问题。

max_tokens 负数或超大？客户端设 max_tokens = 1000000：est_total 巨大 → 规则 0 400（若配置）或规则 3 → big（×1.2 不含 max_out，1000000 不影响规则 3！）→ big 模型窗口 60000 < prompt + 1000000 → 上游错误。又回到 A2：max_out 不参与 big/flagship 容量判断。不过客户端要求 1M 输出本来就可能失败，算边界。但 max_tokens = 16000 很常见（长文生成），prompt 30000：est_total 46000 < 60000 不触发任何保护 → 判分区 → judge 看 prompt 30000 的截断（256 + 1200 字符）→ 判 fast 或 big。判 fast → 8k 窗口炸；判 big → 46000 < 60000 OK 但假设 prompt 50000 + max_out 16000 = 66000 > 60000 → big 炸。所以 A1/A2 是真实高频场景。

## 6. 缓存清扫"检查过期并双表删除"逻辑

"容量 >4096 时从辅表头部（最旧）取出条目检查过期并双表删除，单次清扫至多处理 128 条"。问题：如果头部 128 条都未过期呢？表继续增长？下次写入又扫 128 条未过期 → 表无限增长（内存泄漏）。缺少强制驱逐（evict）。不过缓存量取决于流量和 key 多样性，4096 上限 + TTL 300s，如果 key 生成速率 > 4096/300s ≈ 13.6/s 且头部（最旧写入）条目……等等，TTL 300s，最旧条目至少 300s 后过期。写入速率 13.6/s 会在 300s 内写 4096 条。如果写入速率持续高于 13.6/s，表会超过 4096 且头部条目未必过期（写入即过期时间起算，最旧的条目是 300s 前写的；只要表龄足够，头部一定过期）。

让我细想：条目写入时 ExpiresAt = now + 300。辅表按 Seq 排序，头部是最早写入的。表大小 > 4096 时扫头部 128 条。最早写入的条目如果表当前有 N 条且写入速率 r，则头部条目年龄 ≈ N/r。N = 4096+，r = 20/s → 头部年龄 ≈ 205s < 300s → 未过期 → 不删（文档说"取出条目检查过期并双表删除"——只删过期的？还是直接删？）。"从辅表头部（最旧）取出条目检查过期并双表删除"——听起来是检查过期才删。如果只删过期的，高写入速率下表无界增长（速率 > 13.6/s 时永远追不上）。20 req/s 判分区流量对网关很正常。300s × 20/s = 6000 条稳态超限，但每条很小，6000 条也就几百 KB。如果 200/s 呢？60000 条。仍不致命但违背"容量 4096"的声明，且逐次清扫 128 条全是未过期 → 无效功。

这算 B 类（遗漏边界）或 A 类？正确性不受影响（只是内存上限失效），成本影响中等。我认为算 B 类边界问题：高流量下无界增长，建议加 LRU 强制驱逐（头部未过期也删，或用带时间戳的 eviction）。实际上正确修复很简单：容量超限时直接删头部 128 条不管过没过期（FIFO 驱逐），语义上就是容量型缓存。或者保留过期检查但同时强制删最旧的至少 1 条。文档声称"双表结构（修 N5）"，可能上一轮就是这个语义。嗯，"检查过期并双表删除"如果语义是"检查（如果）过期（则）双表删除"，那未过期条目留在表里。这个歧义+潜在无界值得指出。B 类。

## 7. 规则 4 的 `msg_count ≤ 3` 与 system 消息

msg_count 含 system。一个请求 system + 1 user = 2 条。system + user + assistant + user = 4 条 → 不命中规则 4。OK，刻意的。

## 8. marker 匹配 lowercase：CJK 无大小写，OK。"think harder" 词边界匹配。"don't think harder" 反例测试覆盖了。标记表 "深度思考" 子串匹配——"不要深度思考" 也命中 → flagship。注入面/误触发，但这是 marker 类方案固有，测试有反例意识，算已知取舍，不列缺陷（现实影响小，用户显式加标记的语义）。嗯不过"不要深度思考"命中 flagship 只是成本问题，规则 2 hard → flagship。可忽略。

## 9. judge 快照与配置切换

worker 启动时快照 judge_model；回写（负缓存/连败）带快照 model 名；不一致则丢弃。看起来修好了。但成功路径呢？决策缓存写入是否也带快照？"命中缓存写回"——成功时写决策缓存 {Hash => Tier}。如果 judge_model 换了，旧 worker 的成功结果写入新模型下的决策缓存——决策缓存 key 不含 judge_model！换 judge_model 后，旧决策缓存条目（旧 judge 的结论）仍然有效 300s。这算污染吗？影响成本分布不影响正确性，TTL 300s 短暂。可忽略，不列。

但负缓存 key 呢？"负缓存：失败特征写 30s TTL 条目（与决策缓存同结构）"——同结构即同 key 空间。决策缓存（正）和负缓存写同一个表？key 相同（同一 Hash）？一个失败请求写 {Hash => {neg, ExpiresAt}}，30s 内同特征请求命中 neg → default_tier。但如果之前有个正决策 {Hash => {fast, ...}}（300s TTL），后来 judge 失败覆盖为 neg（30s TTL）→ 30s 后 neg 过期，缓存 miss → 重新 judge。合理。反过来 neg 先、正后：成功覆盖 neg。OK 无问题。

不过负缓存按 judge_model 隔离了吗？"
