# Review by kimi-k3 (k3)

_129.9s · completion_tokens=3856_

Let me review this LLM gateway auto-router spec critically. Key areas:

**A. Critical defects (cause failures/wrong behavior):**

1. **Judge recursion risk**: judge calls `janus_lb:pick_route` → `chat_completions` — but if judge model is also routed through proxy_chat or if judge_model itself is set to `janus-auto` (deployment misconfiguration), infinite recursion. Also the judge call path: does it re-enter the auto router? Spec says it calls providers directly, so probably fine, but if judge_model happens to be the virtual model name, no guard mentioned.

2. **Judge failure → default_tier contradicts §2**: §2 says judge failure degrades to rules-only behavior, §3/§9 say judge failure → default_tier. These differ — rules-only means rule 5 says "no judge → default_tier", so actually consistent-ish. But §5 says "解析失败 = 降级" and §3 step ③ says "失败 → default_tier". Minor inconsistency. Actually the bigger issue: §9 "路由器自身 crash → 500" contradicts §2 "永不因路由器导致 5xx". If maybe_route crashes, the whole request 500s — that IS router-induced 5xx. Spec explicitly accepts 500 on crash, violating its own core constraint. Defect.

3. **Cache key only uses last user message + system prefix** — ignores the rest of conversation. Two requests in same session where last message is similar but context grew hugely (e.g., long history with short question) will hit cache and route to fast despite needing big. Cache key ignores ctx_tokens — a request with 100k context and short last message vs 1k context same last message collide. Wrong routing. Should include ctx bucket in key.

4. **Cache key truncated system prompt** — phash2 of system first 256 chars; different models' system prompts sharing first 256 chars collide → cross-tenant/privacy? Not privacy, but wrong routing across different agents sharing prefix. Also tools presence only boolean — different tools ignored.

5. **ctx_tokens = bytes/3 estimation with UTF-8**: Chinese chars are 3 bytes each, so bytes/3 underestimates English (English ~4 bytes/token, so /3 overestimates English tokens). Mixed. They say error acceptable for rules. But rule 2 `ctx_tokens > 60000` routing to big — if underestimate, requests exceeding actual context window get routed to fast model that can't fit → provider 4xx errors. Estimation error directly causes failures. Also multimodal content, base64 images inflate bytes massively — image parts counted in byte total? Rule 1 catches images first, so ok. But also `max_tokens` not considered.

6. **Cache TTL 300s sticky**: after cache hit, tier fixed even if rules would now route differently (context grew). Cache key doesn't include ctx so this is same as #3.

7. **Markers matching case sensitivity / false positives**: "仔细分析" substring matching — matches inside code or quoted text. Minor. Case: "Ultrathink"? Judge output lowercase but marker matching not specified lowercase.

8. **Default tier fallback direction**: tier empty fallback flagship→big→fast — if default_tier=fast and fast is empty, fallback goes to flagship first — expensive and possibly wrong. Also §13 asks. It's a design question not defect.

9. **Judge spawn + receive after**: spawned process leak — after timeout, the judge process continues running, consuming provider quota and when it finishes sends message to... dead mailbox? The caller has moved on. The late judge result isn't cached (spec says cache only successful?). Actually does failed/timeout judge write cache? Not specified. Also spawned process holding connection; repeated timeouts = unbounded process accumulation under load. Need to kill on timeout or monitor. This is a real defect.

10. **Cache phash2 collisions**: phash2 is not collision-resistant; different requests same hash → wrong tier. Acceptable but should note. Also ETS table concurrency — race between check and insert fine. The ">4096 rows then sweep" — unbounded growth between sweeps if writes slow; also table is local per-node (fine).

11. **Rule 1: multimodal → flagship, but tier list "由用户保证含视觉模型"** — if user assigns non-vision model to flagship, requests fail. Zero-assumption principle broken implicitly. Risk not defect.

12. **model_allowed check against janus-auto only** — agent key authorized for virtual model can then reach flagship models it wasn't authorized for. Authorization bypass: a key granted only `janus-auto` can invoke any model in tiers. This may be intended, but it's a privilege escalation path; if agent key restriction is meant to limit cost, auto router defeats it. Should be documented/explicit.

13. **Streaming**: non-goal says no streaming transform, but routing affects nothing about stream... fine. But judge sets stream=false; fine.

14. **Rule 4 requires no tools and ≤3 messages and <8000 tokens → fast; but rule 5 everything else judge; with no judge → default_tier=fast.** So a 59k-token complex task with tools goes to fast (default) in rules-only mode. Context window overflow → provider 400. That's a defect in rules-only mode: rule 2 sends >60k to big, but 8k–60k with tools defaults to fast which might be an 8k-context small model. Gateway has zero assumptions so can't know — but default_tier=fast combined with zero-knowledge of context windows = frequent upstream 4xx. Mitigation: default_tier should be configurable (it is) but default fast is dangerous.

15. **Timeout of judge adds latency on every non-cached middle request** — 1500ms on judge failure path. Risk.

16. **Cache on judge result but not on failure → repeated failing judge every request** — thundering herd on judge; no negative caching / circuit breaker. Defect-ish (availability of latency). If judge model is down, every request waits 1500ms. Should add circuit breaker.

17. **ETS ensure_table race** — lazy table creation races between processes; janus_admin_session pattern presumably handles. Minor.

18. **Decision cache value not namespaced by config changes** — if operator reassigns tiers, cached tier still valid (tier-level cache so fine actually — cache stores tier, not model). Good design actually.

19. **Cache key doesn't include model's messages beyond last user msg** — actually that's the point (session stickiness). But "相似请求稳定落同一档" — different sessions with same last message collide — privacy? No, only routing. OK.

20. **No concurrency protection on cache stampede** — minor.

21. **§6 key uses "system 前 256 末条用户前 512"** but §5 judge input uses last user first 1200 chars — inconsistency minor.

22. **No metrics until v2; only debug logs** — operability risk: routing invisible in prod. Risk.

23. **phash2 seed stability across nodes/versions**: phash2 differs across OTP versions? Actually phash2 is stable within version but range default; multi-node cluster caches independent anyway — fine.

24. **Rule ordering: rule 1 images → flagship even if request tiny** — fine per spec.

25. **Body rewrite: `model` field changed but other fields like `max_tokens` may exceed target model's limits** — no clamping. Risk.

26. **No logging of fallback when tier candidates skipped** — silent misconfig. Risk.

Structure: A. 关键缺陷 max 5, B. 风险/边界 max 5, C. 建议 max 5. Direct, Chinese.

Pick top defects:

A1. Crash → 500 contradicts "永不因路由器导致 5xx" core constraint. maybe_route must be wrapped in catch and degrade to pass/default.

A2. Judge spawned process leak on timeout: receive-after timeout abandons judge process; it keeps running, late reply lost, result never cached, connections/quota wasted; under judge-slowness, process pile-up. Need monitor/kill or async task with cache write.

A3. Cache key missing context size/tools detail → wrong sticky routing: same last message with 100k ctx hits cache entry made with 2k ctx → routes fast → upstream context overflow 4xx. Include ctx bucket in key or skip cache when rule 2 would trigger.

A4. Rules-only + default_tier=fast sends mid/large requests (8k–60k, with tools) to fast; with byte/3 token estimation error, real context may exceed small model window → upstream 400s. Estimation bytes/3 underestimates Chinese (~1 token/char = 3 bytes → 1 token per 3 bytes is roughly right for Chinese; overestimates English... wait: English 1 token ≈ 4 chars = 4 bytes, so bytes/3 gives 4/3 tokens per actual token → overestimate English by 33%. Chinese: 1 token ≈ 1-1.5 chars = 3-4.5 bytes → bytes/3 ≈ 1-1.5 tokens per token → underestimate Chinese. So Chinese-heavy large context underestimated → overflows.) Also rule 2 threshold comparison with estimate error.

A5. Judge recursion/self-reference: if judge_model = "janus-auto" (or tiers include virtual model name), judge call loops / routes to itself. No validation. Also tier lists could include the virtual model → infinite rewrite loop. Need config validation rejecting virtual name in judge/tiers.

Also cache on timeout not written → judge down = every request +1500ms latency, no circuit breaker. That's arguably defect too but I'll fold into A2 or put in B.

B risks:

B1. Authorization bypass: key with only janus-auto reaches flagship models — undocumented privilege/cost escalation; also billing attribution (non-goal but logs show target).

B2. No observability: debug logs only, no metrics; silent fallback for misconfigured tier lists ("解析失败则跳过" silently). v2 metrics too late.

B3. Judge-down = +1500ms on every mid request, no negative cache/circuit breaker; also judge cost unbounded (every unique request judged, cache only 300s).

B4. max_tokens / model-specific params not clamped to target model; stream flag passthrough fine but other params may be invalid for target.

B5. phash2 collisions + truncation: different system prompts sharing 256-char prefix collide; cross-agent wrong tier. Also markers substring matching false positives inside code blocks / quoted text; case sensitivity unspecified. Also multi-node: each node independent cache — fine but note.

B6. ETS sweep "when >4096 rows on write" — under low write volume, expired entries never reclaimed; race on ensure_table. Minor — maybe skip.

C improvements:

C1. Wrap maybe_route in try/catch → on crash, fallback to default tier or pass-through with warning log; honor "never 5xx".

C2. Config validation at boot: reject virtual model name appearing in judge_model/tiers; warn if tier lists empty or names not in catalog; fail-fast warnings in logs.

C3. Fix cache: include ctx bucket (e.g., floor(ctx/4096)) or only cache judge results (not rule results — actually rules are deterministic, caching them pointless... wait cache stores tier from any path? Pipeline: cache hit before rules. Rule results are deterministic & 0ms, no need to cache. Cache should only store judge outcomes; key should include everything judge saw + ctx bucket. Better: put rules_gate BEFORE cache? Rules are 0ms — run rules first, only cache judge path. That fixes A3 elegantly.)

C4. Judge hardening: use monitored task, kill on timeout; negative cache (e.g., 30s) or circuit breaker after N consecutive failures; log judge failures at warn with rate limit.

C5. Improve token estimation: per-content-type estimation (CJK chars /1.5, ASCII /4), cap multimodal parts, add max_tokens to effective ctx; make rule 2 comparison use conservative upper bound for routing-to-big (avoid overflow) — or include safety margin (e.g., ×1.2).

C6. Docs/explicit: document that auto-router keys bypass per-model model_allowed; optionally add per-tier allowlist check.

C7. default_tier guidance: recommend big as default or document risk; add `middle` tier? No — keep ≤5.

Pick 5 for C: catch-wrap, config validation, cache redesign (rules-first), judge hardening (kill+CB+neg cache), token estimation fix. Maybe fold authz into B only.

Format with headers A/B/C, numbered lists, concise reasons. Chinese. No fluff.

## A. 关键缺陷

1. **路由器 crash → 500 与核心约束自相矛盾。** §2 承诺"永不因路由器导致 5xx"，§9 却接受 crash 走 chat handler 的 try/catch 返回 500。`maybe_route` 内部任何 bug（ETS 表不存在、配置格式错、二进制匹配失败）都会把数据面打挂。必须在 `maybe_route` 自身边界做 catch，异常时降级为 pass/default_tier。

2. **judge 超时的 spawn 进程泄漏。** `spawn + receive after` 超时后调用方走人，judge 进程继续跑：占用上游连接与配额、late reply 丢进死信箱、结果永远不会写缓存。judge 抖动期间进程和连接会持续堆积。必须 monitor 并在超时后 kill，或由被遗弃的 judge 进程完成时补写缓存。

3. **缓存 key 不含上下文规模，导致错误粘性路由。** key 只有 system 前 256 + 末条用户前 512 + tools 布尔。同一会话先发短消息（判到 fast），随后带上 100k 历史再问"继续"——命中缓存仍走 fast，直接上游 context overflow 4xx。规则门是 0ms 确定性逻辑，根本不需要缓存；应只对 judge 结果缓存，且 key 必须含 ctx 分桶。

4. **rules-only 模式下中间地带全落 `default_tier=fast`，叠加字节÷3 的估算误差，会把超长请求塞进小模型。** 中文场景 ÷3 系统性低估 token 数（1 token ≈ 1~1.5 汉字 ≈ 3~4.5 字节），59k 估算值的请求实际可能已超小模型窗口；规则 2 只拦 >60k 的，8k–60k 带 tools 的全进 fast。这是批量上游 400 的来源。

5. **无自引用防护：judge_model 或 tiers 列表可填入 `janus-auto` 本身。** 配置错误时 judge 调用或 body 改写形成无限路由循环，直到进程栈/超时爆炸。规格完全没有配置校验环节。

## B. 工程风险与遗漏边界

1. **授权与成本越权未声明。** agent key 只授予 `janus-auto`，实际可触达 tiers 里任意旗舰模型——model_allowed 检查被旁路。即便是有意设计，也必须显式写入规格，否则审计和成本归因会出事故。

2. **judge 不可用 = 每个中间请求 +1500ms。** 无负缓存、无熔断。judge 挂掉期间所有非缓存请求都吃满超时，p99 直接劣化；超时结果也不写缓存，同一请求反复触发判分，judge 成本无上限。

3. **配置错误静默吞掉。** tier 候选"解析失败则跳过"、整档为空走回退，全部只字不提日志级别；观测只有 debug 日志、计数器排期 v2。生产上档位配错名会静默路由到错误档位且无人察觉。

4. **phash2 截断碰撞 + 标记误匹配。** system 前 256 字符相同的两个不同 agent（同模板不同业务）共享缓存项互相污染档位；升档标记是裸子串匹配，用户消息里引用/代码块中出现 "ultrathink" 会被误升档，大小写规则未定义。

5. **目标模型的参数合法性未处理。** 改写 body.model 后 `max_tokens`、温度上限、stop 序列等可能超出目标模型能力；多节点部署下各节点缓存独立导致同会话跨节点档位漂移（与"会话粘性"意图相悖）。`max_tokens` 也未计入 ctx 估算。

## C. 改进建议

1. **流水线顺序改为：规则门 → 缓存 → judge。** 规则结果确定性且零成本，无需缓存；缓存只存 judge 结论，key 加入 `ctx_tokens div 4096` 分桶与 markers 命中位。一步到位消除 A3。

2. **`maybe_route` 整体包 try/catch，任何异常降级为 `default_tier`（或 pass）并 warn 日志。** 让 §2 的"永不 5xx"承诺真正成立。

3. **启动期配置校验（app start 或首次 ensure）：** 拒绝 judge_model/tiers 中出现虚拟模型名；tier 候选名不在 catalog 时启动即 warn（而非请求时静默跳过）；整档为空打 error。零假设 ≠ 零校验。

4. **judge 加固：** spawn 改为带 monitor 的 task，超时即 kill；连续 N 次失败触发熔断（如 60s 内跳过 judge 直走 default_tier）；超时/失败写短 TTL（30s）负缓存；judge 失败日志提到 warn 级并限频。

5. **token 估算改为保守上界并参与防溢出：** ASCII ÷4、CJK ÷1.5 分段估算，多模态 part 单独计权重，比较规则 2 时加上 20% 安全余量并把 `max_tokens` 计入；文档中将 `default_tier` 推荐值改为中间档（或至少在规格中写明 default=fast 的溢出风险由部署者承担）。
