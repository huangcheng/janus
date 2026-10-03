# Review by mimo-v2.6-pro (mimo-v2.6-pro)

_137.6s · completion_tokens=4000_

Let me analyze this design spec for an LLM gateway auto-router. I need to find critical flaws, engineering risks/edge cases, and concrete improvements.

Let me think hard about the design.

**Critical flaws:**

1. **Cache key doesn't include the full request content but only system 前256 + 末条用户前512.** But more importantly, the cache key in section 6 says `phash2({system 前 256 末条用户前 512, tools 是否存在})` — but rules gate uses `ctx_tokens` (total bytes) and message count. So a request with same system prefix + same last user message prefix but wildly different total size (e.g., one with 100k tokens of history vs 1k) would hit the same cache entry — the cached tier could be wrong. That's a correctness bug: cache bypasses rules gate entirely (① before ②). Actually more critical: cache is checked BEFORE rules gate. So a request that would be rule-gated (e.g., has image → flagship) could hit cache from an earlier non-image request with same hash, and get the wrong tier. Also cache key ignores images. So rule #1 (image → flagship) can be violated by cache. That's a real correctness bug.

Also: cache key doesn't include ctx_tokens, so rule 2 & 4 could be violated. And cache key collision across different content — phash2 is a 27-bit hash by default (phash2/1 gives 2^27 range), collision probability non-trivial at 4096 entries but ok-ish; but phash2 is not cryptographic and user-controllable — an attacker could craft collisions to force wrong routing. Minor.

The cache stores decision and skips rules — should cache only judge decisions, or apply rules gate first then cache.

2. **ctx_tokens estimation: bytes/3.** "中英混合保守估计" — actually Chinese UTF-8 is 3 bytes per char, and ~1 char ≈ 0.6-1 token for Chinese in modern tokenizers. English ~4 bytes/token. So bytes/3 underestimates English token counts significantly (by ~3x) and overestimates... hmm, bytes/3: English 4 bytes per token → bytes/3 overestimates English tokens by 33%; Chinese 3 bytes/char, ~1.5 chars per token maybe → bytes/3 ≈ 1 token per char, overestimates. Actually it's "conservative" in overestimating. But wait — the direction matters for rules: overestimating ctx → more requests go to big (rule 2), fewer to fast (rule 4). The real problem: it ignores images entirely (image tokens can be hundreds-thousands per image), ignores tools definitions (which can be huge JSON schemas — often 5-20k tokens), ignores reasoning tokens, and ignores messages overhead. Tools JSON can blow up the actual token count massively while rule 4 says "no tools → fast" — that's consistent. But rule 2's ctx estimate ignoring tool schemas means a request with 50KB of tool schemas + small messages estimated as small → fast tier, but actual context is huge. Actually rule 4 requires no tools, so tools requests go to judge/default. But rule 2 threshold check still uses underestimated ctx for tool-heavy requests → they fall to "其余" → judge/default_tier. Not catastrophic.

But bigger: **rule 3 marker check uses "末条用户消息"** and it's checked before rule 4 and rule 5. Fine. But rule 3 doesn't check if the marker is in a tool result or code block... minor.

Actually the ordering: rule 1 image → flagship; rule 2 big ctx → big; rule 3 marker → flagship; rule 4 → fast; else judge. Note rule 3 comes after rule 2, so a huge context with ultrathink → big not flagship. Might be intended.

3. **Judge response parsing: "取 fast | big | flagship 首个匹配词"** — substring matching on lowercased text. Problem: "flagship" contains... no. But "fast" is a substring of "fastest", "breakfast"; "big" is a substring of "bigger", "thinking"? no. But the judge is asked to output one word; if it outputs "big (flagship)" etc. Order of matching matters: if it checks "fast" first in "flagship"? "flagship" doesn't contain "fast". But "big" is a substring of "flagship"? no. However if the model outputs a reasoning like "this is not big, it's fast" the first match is "big" → wrong. Also if the classifier outputs a full sentence, substring matching is fragile. Should use strict whitelist of exact trimmed token match, with strict output format (e.g., single token enum), and validate.

Also: judge uses `janus_lb:pick_route` — but what if the judge model itself is inside one of the tiers? No problem. But judge is called with `janus_providers_openai:chat_completions` directly, bypassing the pipeline — no retry, no fallback across judge's own routes, no circuit breaker. If the judge route fails, it's a failed decision → default. Fine per spec.

But **the spawn + receive after**: the spawned process is not linked/monitored; if it completes after timeout, it leaks (mailbox? no, the spawned process sends to parent then parent already moved on — the message lands in the handler's mailbox and could be picked up by a later `receive`!). This is a classic Erlang bug: a late judge response message will pollute the process mailbox and could be mistakenly consumed by another `receive after` in the same handler (e.g., another downstream call with a selective receive, or worse, the proxy's own receive). Must use a unique ref in the message and flush, or use a monitored call with `receive {Ref, Result} -> ...` selective receive which won't steal other messages. If they use selective receive with a unique reference, late messages are only leaked garbage that never matches — acceptable but unbounded mailbox growth if many timeouts. Should also demonitor/kill the spawned process.

Also judge call: `spawn` without `spawn_monitor` — if judge crashes, the outer process waits full 1500ms then times out; fine but slow. Should monitor and get immediate DOWN.

4. **Tier fallback order flagship→big→fast** — cost blowup: if flagship is misconfigured/unavailable, all traffic silently goes to the most expensive tier. Also the reverse: the fallback when "整档为空" happens at config resolution time or per request? If per-request at runtime (route pick failure), then a transient LB failure of flagship candidates causes silent upgrade to flagship? No wait, fallback order flagship→big→fast when the *target* tier is empty — if target is fast and fast is empty, fall to flagship first = cost explosion. That's a major cost bug. The spec's own question 4 acknowledges this. Should be: fallback to the nearest tier in cost order, or fail fast (400/404) rather than silently routing to flagship. At minimum default fallback should be toward cheaper, and definitely not "flagship first" for a fast-intended request.

Also "tiers 内模型名解析失败（不在 catalog / 无路由）则跳过该候选" — silent skip of misconfiguration; no warning at boot. Should validate config at startup and log errors.

5. **模型名改写后的鉴权/审计/计量问题**: body.model is rewritten to target model. Then key-based model_allowed was checked only for `janus-auto`. So an agent key authorized only for `janus-auto` can reach `flagship` models it isn't authorized for. That's a security/authz bypass: the spec explicitly says "agent key 只需授予虚拟模型" — meaning users of janus-auto can reach any underlying model regardless of their own permission. In a multi-tenant gateway with per-model ACLs, this is an authz hole. Depends on their threat model; the design says config is by deployer, but per-key model allowlists exist ("agent key"). If some keys are restricted to cheap models for cost control, janus-auto becomes a bypass to flagship. This is a genuine critical flaw unless keys are only ever granted virtual models. Should at least enforce that target model is in the union allowed for the key, or document that janus-auto grants superset, or check after rewrite.

Also: audit logs / usage tracking now record the target model? If rewritten before proxy, then logs show real model — good. But if metrics/keys rate-limit by model, janus-auto requests are counted under target model or virtual? Ambiguous.

6. **Streaming**: non-goal says "流式转发改造" is not a goal, but the router must handle `stream: true` requests. The judge is called with stream=false — fine. But the rewrite happens before proxy, so streaming is unaffected. OK. But what about `stream_options` etc. Fine.

But there's an important one: **the cache key and rules use the request body, but with streaming responses and partial... no.**

7. **图片检测**: rule 1 detects multimodal parts. But `content` can be a string or array of parts; also image_url can be base64 data URIs — the ctx estimation counts base64 bytes as tokens! A 1MB base64 image → 333k "tokens" → rule 2 → big, not flagship. Wait rule 1 comes first (image → flagship) so it's fine for the tier, but ctx_tokens is wildly wrong and this gets logged/used in cache? Also cache key hashing content with base64 blobs → the phash2 over huge binaries is expensive-ish. And the decision cache key uses "末条用户前 512" — two different images with same prefix collide → wrong cache hit. Fine, already noted.

Also: `system` may be a list of parts (multimodal system) in some providers. Edge case.

8. **`maybe_route` 零开销 pass**: it checks the model name; but where is it inserted? "resolve_model 前插入 maybe_route" — but model_allowed check uses the original name. Fine.

9. **ETS cache: no bound on memory per entry? 4096 rows cap with sweep — sweep when >4096 on write. If writes are rare and reads many, table can stay at 4096 with stale entries — fine. But no eviction policy beyond TTL lazy expiry + full sweep at 4096. Table unbounded between sweeps? Sweep happens on write when >4096, so max ~4096+1. OK. But multiple nodes: cache is per-node, decisions differ per node → "会话粘性" broken across a multi-node LB/fleet. If Janus runs in a cluster, different nodes make different decisions for identical requests → inconsistent behavior and upstream prompt cache misses. That's an important omission.

10. **Judge prompt injection**: the judge input includes system 前256 + user message前1200 chars — user content can instruct the judge to output "flagship" (prompt injection → cost amplification / abuse). A user writing "ultrathink" already forces flagship per rule 3, so it's not a new capability, but injection lets users force flagship for cost abuse or force fast for… whatever. Should treat judge output as advisory and cap, or at least note adversarial input. Given markers already allow escalation, it's a known behavior. But a malicious user could make the judge output invalid → degrade to default (fast) which may be intended. Mention as risk.

11. **`max_tokens=16` judge + temperature=0**: fine. But no `n`, no stop. OK.

12. **Failure semantics: "路由器自身 crash → chat handler 已有 try/catch → 500"** — contradicts the stated constraint "永不因路由器导致 5xx"! Section 2 says router must never cause 5xx; section 9 says crash → 500. Contradiction — and a 500 on the data plane is exactly what they promised to avoid. Should catch inside maybe_route and return `pass`/default tier instead of letting it bubble.

That's a good catch — direct internal contradiction.

13. **改写 body.model 之后**，若 target 模型名与虚拟名冲突？Or if tier lists contain "janus-auto" itself → infinite recursion! A deployer could put `janus-auto` in a tier list; then maybe_route rewrites to janus-auto and proxy re-routes... Actually the rewrite happens once in proxy_chat, then resolve_model → proxy. Would the rewritten request re-enter maybe_route? No — maybe_route is called once in the handler. But if the target model is janus-auto, resolve_model resolves to the virtual model whose routes are the "兜底 LB 池" → it'd route to... whatever. Not recursion but weird. Should validate tier lists don't contain the virtual model name. Minor.

14. **Cache TTL 300s + 会话粘性 claim**: "同会话重复请求不再判分" — but the cache key includes 末条用户消息前512, which changes every turn in a conversation! So "同会话重复请求" is false: each new user message → new hash → no cache hit. The claimed benefit (judge cost ≈ 0 for same session) is wrong. Only true for exact retries. This is a spec-level inconsistency between §6 claim and §6 key definition. Real issue: the cache key design fails its stated purpose. To get session stickiness you'd need a session id or hash of system+tools only (or prefix of first user message).

That's a strong point: the cache design doesn't deliver the stated value.

15. **rules-only mode missing**: rules gate's rule 5 → "其余 | judge；无 judge 时 default_tier". Fine.

16. **`ctx_tokens` for rule 2 uses total messages bytes/3 but excludes tools and images.** Also excludes the response max_tokens (context window usage includes output). If max_tokens=32k and ctx=50k → total 82k exceeds a 64k model → upstream error. Rule 2 should consider max_tokens too. Good edge case.

17. **没有处理 `max_tokens` / 输出长度需求**：routing should consider requested max_tokens (a long-completion request on fast tier may be slow/truncated). Edge case.

18. **无并发保护/竞态**: multiple concurrent identical requests all miss cache → all call judge → thundering herd; no single-flight. Cost spike. Minor but worth mentioning (judge cost).

19. **`phash2` 默认 range 2^27**：collision risk at scale; also cache key doesn't include the config version — if deployer changes tiers/markers/thresholds, stale cache entries persist up to TTL 300s. Should include a config hash/generation in the key or clear table on config change.

20. **多节点一致性** (as noted).

21. **`model_allowed` 检查对虚拟模型**，但 admin/key 授权粒度问题 (#5 above)。

22. **回退 404 no_route 行为**: 用户请求 janus-auto 得到 404 → confusing error message. Should return a clear 503/400 "auto router misconfigured" but spec says never 5xx... 404 is arguably fine but ambiguous.

23. **观测不足**: debug-level logs only — production at info level won't see routing decisions; no metric counters means you can't detect misrouting/cost drift. Should at least be a counter + info log on fallback/degradation. Also no way to attribute usage/cost to janus-auto vs. target model.

24. **Judge 超时 1500ms 加在每次冷请求的首 token 延迟上** — TTFT regression for all janus-auto requests on cache miss. Should have an overall latency budget / fallback to rules when the client expects fast. Also no mention of applying rules first then judge only for the ambiguous middle (which the rules gate does). But the ordering means judge latency is added to first token — worth noting: run judge concurrently? Or accept. Also the judge's own LB pick could pick a slow route.

25. **Erlang: `receive after` 在 spawn 后没 monitor** — covered.

26. **`features/1` 是纯函数但 `maybe_route` 与 ETS 混杂** — testability fine.

27. **图片检测但 v1 不选视觉档**：非目标说不单独选视觉档，但规则 1 把图片路由到 flagship 并假设 flagship 有视觉模型 — 如果 flagship 无视觉模型，请求失败（上游 400）。用户保证，但无校验。应校验 tier 候选中至少有一个支持 vision，或降级。Edge case.

28. **`markers` 匹配**：大小写、子串误报（"think harder" in code block or English prose "it's hard to think harder about..."），中文标记在英文上下文。false positive → flagship cost. Should require word boundaries/case-insensitive matching on last user message only. Also `ultrathink` might appear in a code sample. Cost risk.

29. **缓存写入即使 judge 失败**? Should not cache failures (or cache negative with short TTL to avoid hammering a broken judge). Spec doesn't say.

30. **无 judge 结果的置信度/阈值**：judge outputs 3 classes with max_tokens=16; no validation of the format; no retry.

Let me now pick the top 5 for each section.

**A. 关键缺陷（导致故障或错误行为）**

1. 决策缓存位于规则门之前且 key 不含 ctx_tokens/图片/tools 体积 → 缓存命中会绕过规则门，违反规则 1/2/4（图片→flagship、超长→big）。同一 system 前缀 + 同一 last user 前缀但完全不同的请求会命中同一 entry → 错档。必须规则门先行，或 key 纳入 ctx_tokens 与图片标志。

2. §2 "永不 5xx" 与 §9 "crash →
