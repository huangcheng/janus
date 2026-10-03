# Review by minimax-m3 (MiniMax-M3)

_69.6s · completion_tokens=4000_

<think>Let me carefully review this design specification for the Janus Auto Router. I need to evaluate it as a senior distributed systems / LLM infrastructure engineer and identify:

A. Critical defects (will cause failures or incorrect behavior)
B. Engineering risks and missing edge cases
C. Specific actionable improvement suggestions

Let me go through the spec section by section.

**Section 1: Goals/Non-goals**
- Explicitly defers cost feedback (bandit), per-user differentiation, streaming changes, multimodal-specialized routing
- Says v1 is rules-only identification, no separate vision tier
- But Rule #1 in section 4 routes multimodal to flagship

**Section 2: Core constraint - zero assumptions about provider world**
- Judge model must be assigned by user
- Tier model lists must be assigned by user
- No judge = rules-only mode
- Judge failure = rules-only fallback, never 5xx

**Section 3: Request pipeline**
- Pipeline looks reasonable

**Section 4: Rule gate**
- Image input → flagship
- ctx_tokens > big_ctx_tokens → big
- Marker phrases → flagship
- No tools + ctx_tokens < fast_ctx_tokens + messages ≤ 3 → fast
- Else → judge; no judge → default_tier

**Critical issue here**: ctx_tokens estimation is "messages content byte total ÷ 3". This is rough but OK for the stated purpose of "magnitude correctness."

But wait - if user message is 60000 tokens total but each individual message is short, Rule 4 (messages ≤ 3) could still match and route to fast. That might be wrong - but actually messages ≤ 3 with ctx_tokens < fast_ctx_tokens means total < 8000 tokens, so probably OK.

Wait, the rule says "messages ≤ 3" not "tokens ≤ threshold". So if a user sends 3 messages but each is 5000 tokens, that's 15000 tokens. Rule 2 wouldn't trigger (>60000), Rule 4 wouldn't trigger (ctx_tokens > 8000), so it goes to judge or default_tier. Actually wait, the rule says ctx_tokens < fast_ctx_tokens AND messages ≤ 3, so if ctx_tokens is 15000, fast_ctx_tokens is 8000, so 15000 > 8000, Rule 4 doesn't trigger. OK that's fine.

But Rule 3 about markers - "末条用户消息含升档标记" - this is a very broad sweep. Any casual user saying "think harder" or "深度思考" gets flagship. This is a known attack vector for prompt injection - but this is acknowledged in non-goals (no cost feedback).

**Section 5: Judge**
- Input: ~200 token English classification prompt + system first 256 chars + last user message first 1200 chars
- max_tokens=16, temperature=0, stream=false
- Execution: janus_lb:pick_route → janus_providers_openai:chat_completions
- spawn + receive after timeout
- Parse: lowercase, take first matching word

**Critical issues here**:
1. **Erlang `receive after` timeout pattern**: Spec says "外层 spawn + `receive after judge_timeout_ms`". This is the classic anti-pattern in Erlang - using spawn + receive from a mailbox for async timeout, instead of proper supervision or async patterns. Better to use `gen_server:call` with timeout, or proper async/await. But more importantly:
2. **The judge call goes through `janus_providers_openai:chat_completions`** - this is a synchronous HTTP call. Spawning it doesn't make it non-blocking. The link/monitor semantics aren't specified. If the spawned process crashes, will it bring down the parent? The spec says "路由器自身 crash → chat handler 已有 try/catch → 500". But the spawned process is separate; what catches its errors?
3. **Judge input truncation**: "system 前 256 字符 + 末条用户消息前 1200 字符". This is character count, not token count. For non-ASCII (Chinese), this can be wildly off. 256 characters of Chinese could be many tokens, or 256 English chars could be ~60 tokens. The judge may not get enough context.
4. **Judge input only includes last user message, not conversation history**: The judge has no idea what the conversation is about beyond that. This is probably acceptable for tier routing but worth noting.
5. **The judge prompt is hardcoded "约 200 token 的英文分类指令"** - what is the actual prompt? Not specified. This is a key design decision.

**Section 6: Decision cache**
- Key: phash2 of system first 256 + last user first 512 + tools presence
- Value: {Tier, ExpiresAt}
- Lazy expiry on read
- Cleanup when > 4096 rows

**Critical issues**:
1. **Cache key includes "system 前 256" but only the prefix, not last user message at 1200 chars**. There's inconsistency: cache uses 512 chars, judge uses 1200 chars. Why different? Probably for cache key size efficiency.
2. **TTL 300s means if user comes back with similar request within 5 min, gets same tier**. This is fine for caching but might cause stale routing if user needs escalate.
3. **No cache invalidation on tier config change** - if admin changes tier config, cached entries remain. But this is "deployment decision" so probably OK.
4. **The cleanup is "if table > 4096 rows do a sweep"** - what does sweep mean? How does it pick which entries to remove? Random? LRU? Not specified. If random, hot entries might get evicted; if LRU, need access tracking (not specified).
5. **phash2 collisions** - different requests map to same tier, generally OK for routing decisions
6. **No consideration of cache poisoning** - if user sends "ultrathink" once, all subsequent similar requests in 5 min go to flagship even if they're trivial

**Section 7: Configuration**
- model, judge_model, tiers, default_tier, thresholds, timeouts, cache_ttl, markers
- Tier model resolution: "不在 catalog / 无路由 则跳过该候选"
- Tier empty fallback: flagship → big → fast → still 404
- Virtual model itself is a normal models row, its routes can serve as "fallback LB pool"

**Issues**:
1. **Tier fallback order**: flagship → big → fast. This is "expensive to cheap" order. If flagship is empty, you fall back to big, then fast. But you wanted flagship (because user said "深度思考"), you downgrade to fast (cheapest). Is that the right behavior? Shouldn't big be preferred over flagship in fallback? Actually it's probably the right order - "if I can't give the user what they asked for, give them the best I can". OK probably correct.
2. **But** the fallback is documented as "整档为空时按 flagship→big→fast 顺序回退". This means if the user wanted fast but the tier list is empty, they get flagship. That's surprising - a request that explicitly wants cheap gets routed to expensive! This contradicts the spirit of auto-routing. Should be: try requested tier first, then escalate up if needed.
3. **The virtual model's own routes are described as "所有档位全空时的兜底 LB 池"** - this is conflating the virtual model as a routing entity with its own routes. The virtual model IS the auto-router; it has no routes of its own in the auto-routing sense. This section is confusing.
4. **Configuration is in sys.config**, not in DB. So tier reconfiguration requires redeploy. Roadmap mentions dashboard UI for this.

**Section 8: Modules and integration**
- janus_auto.erl with maybe_route/2, features/1, rules_gate/1, judge/2, cache_*
- ETS lazy table creation, "参照 janus_dashboard_session, 无需监督树子进程"
- Modify janus_http_chat:proxy_chat/5

**Issues**:
1. **ETS without supervisor**: "参照 janus_dashboard_session, 无需监督树子进程" - this means ETS table is created at startup and never supervised. If the owning process dies, ETS table ownership is inherited by nothing or crashes. Need to specify ownership (e.g., give_away to a long-lived process or use named table with no owner).
2. **No mention of how to handle janus_auto being loaded as a module on cold start** - module loading order, dependency on janus_lb, janus_providers_openai
3. **"features/1 / rules_gate/1 / judge/2 / cache_*"** are described as "纯函数为主, 便于 eunit". But `judge/2` does HTTP calls, so it's not pure. `cache_*` does ETS writes. Only `features/1` and `rules_gate/1` are likely pure.
4. **body.model rewrite timing** - "改写 body.model → 目标模型 → 既有 proxy 链路". This means after rewriting, the proxy goes through the same pipeline. If the resolved target model is also a virtual model (like another janus-auto variant?), infinite loop. Probably the spec assumes targets are always real models.

**Section 9: Failure semantics**
- Unconfigured: pass through
- No judge: rules-only, middle ground → default_tier
- Judge fail: rules-only, debug log
- All candidates unavailable: flagship → big → fast → 404
- Router crash: chat handler try/catch → 500

**Issues**:
1. **"未配置 auto_router → maybe_route 恒 pass"** - but how do you "not configure"? Either the config key is missing or empty. Spec doesn't clarify.
2. **500 on router crash** - per Section 2, "永不因路由器导致 5xx". Conflict! Section 9 says router crash → 500. Need to clarify: internal errors should not surface as 5xx to clients; should fall back to default_tier or passthrough.

**Section 10: Observability**
- logger:debug per decision
- v2: ETS counters for /overview

**Issues**:
1. **debug-level logging means it's not visible in production** unless explicitly enabled. Routing decisions are a key signal - should be info-level at least, with debug for details.
2. **No metrics for cache hit/miss rate, judge success/failure rate, tier distribution** - these are critical for understanding whether the router is helping or hurting.

**Section 11: Test plan**
- eunit for features extraction, rule priority, judge parsing, cache TTL and cleanup, unconfigured passthrough
- Docker smoke: 2 models + fake provider

**Issues**:
1. **No load test / concurrency test for judge** - judge is synchronous and in request path. Under load, will judge become a bottleneck?
2. **No test for cache behavior under concurrent writes** - race conditions on cache cleanup
3. **No test for judge failure modes** (timeout, HTTP error, malformed response)
4. **No integration test for tier config changes** - what happens when tier config changes mid-flight?
5. **No test for tier empty / model-not-in-catalog fallback**

**Section 12: Roadmap**
- Dashboard UI, session stickiness, judge result stats

**Section 13: Open questions**
- 4 reasonable questions

Now let me synthesize my findings:

**A. Critical Defects (will cause failures or incorrect behavior)**

1. **Rule 4 (fast route) uses `< fast_ctx_tokens` AND `messages ≤ 3`** but this is AND. Combined with the rule ordering, a 3-message conversation totaling 7999 tokens goes to fast. But this also means a 1-message conversation with 7999 tokens (long system prompt) also goes to fast, which may not be intended. Actually the rule is OK, but more critically: what if a user has system prompt with 7000 tokens + 1 short question? Goes to fast, which may have a small context window. **FUNDAMENTAL ISSUE**: The fast tier may have a smaller context window than what the user needs! No check against model context limits.

2. **Fallback order is wrong semantically**: When flagship is requested but unavailable, you fall back to big, then fast. When fast is requested but unavailable, you also fall back to flagship. This means a request that should go to fast (cheap) gets flagship (expensive) if fast tier list is empty. This is a billing surprise / cost blowup vector. Should be: if explicit tier requested unavailable, prefer cheaper alternatives.

3. **ctx_tokens estimation is byte/3** - this is too coarse. A 9000-token request (which exceeds big_ctx_tokens for many models that have 8k context) would not trigger Rule 2 if it's < 18000 bytes per message. Actually wait, the rule is `> big_ctx_tokens` where big_ctx_tokens is 60000. So 9000 tokens < 60000, goes to other rules. Hmm but the rule is checking against big's threshold, not the actual model context. If the user's actual target model is fast with 8k context, sending 9000 tokens fails. This is a real issue: **no validation that the chosen tier's model can actually handle the input**.

4. **Judge timeout implementation is broken**: "外层 spawn + `receive after judge_timeout_ms`" with `janus_providers_openai:chat_completions` (which is synchronous HTTP). Spawning doesn't make HTTP non-blocking. The actual HTTP call still blocks. And if you receive after timeout, the spawned process keeps running, consuming upstream resources, generating billing on the judge model. Need proper async (e.g., httpc with async, or a separate process pool, or just use gen_server:call with timeout and link/monitor the worker).

5. **Cache poisoning / no escape hatch**: Once a request is cached as flagship for 300s, subsequent similar requests within the window go to flagship regardless. A user who sends "ultrathink" once, then sends 100 trivial follow-ups, all hit flagship for 5 minutes. This isn't a bug per se but a missing consideration. Also: **cache key uses phash2 which can collide** - low collision risk but worth noting. More importantly: **cache key includes "tools 是否存在" but no user/key/tenant context** - all users share the cache. Different users may have different rate limits, costs, etc.

6. **Conflict between Section 2 and Section 9**: Section 2 says "永不因路由器导致 5xx". Section 9 says router crash → 500. This is contradictory. Either router errors should be swallowed (degraded to default_tier or passthrough) or 500 is acceptable. Need to decide.

7. **ETS table ownership not specified**: "无需监督树子进程" with "参照 janus_dashboard_session". If janus_dashboard_session uses a named table with no owner, that's OK if the creating process is long-lived. But if anything calls ensure_table from a short-lived process, ownership transfers are problematic. Should use `heir` option or named table owned by a long-lived process.

**B. Engineering Risks and Missing Edge Cases**

1. **Judge call is in request path** - adds latency to every non-rule-resolved request. No batching. Under load, judge becomes bottleneck. No mention of how this interacts with concurrent requests.

2. **No rate limiting / circuit breaker on judge**: If judge is overloaded or down, every request waits the full timeout. Should add circuit breaker (open after N failures, fall back to rules-only for some period).

3. **Streaming interactions not addressed**: Pipeline doesn't mention streaming. The current chat handler supports streaming. Auto-router writes body.model and passes to proxy - presumably proxy handles streaming. But judge is non-streaming. If judge call hangs longer than expected and request is streaming, client sees nothing until judge completes. Should probably resolve tier before starting to stream.

4. **Context window validation missing**: Fast tier models often have 4k-8k context. If user sends 50k tokens and Rules 1-4 don't catch it, and judge picks fast (or it's default_tier), it goes to fast and fails at upstream. Should validate against target model's context window.

5. **Tool-call routing not considered**: Rule 4 excludes tools. But what if a tool call needs flagship (complex tool selection)? Just falls to judge/default. Could be wrong. Should consider tool complexity.

6. **No budget / rate-limit consideration**: Two users, same request, same cache key, one is rate-limited. Both go to flagship. Tier routing doesn't know about user quotas.

7. **Marker matching is substring** - "ultrathink" appears in "ultrathinking" or "my ultrathink journal". Probably intentional but worth noting.

8. **No authz on admin changes**: Tier config in sys.config means requires redeploy. Roadmap mentions dashboard UI - need RBAC story.

9. **phash2 returns 32-bit hash** - birthday paradox at ~65k entries. Cache table sized at 4096 means ~5% collision rate. Need bigger hash (sha, etc.) or live with it.

10. **No metrics**: No way to know if router is helping. Cache hit rate, judge failure rate, tier distribution all need to be queryable.

11. **Body rewrite after rule check but before proxy**: What if target model is another virtual model? Infinite loop possibility. Need to validate target is a real model.

12. **No explicit handling of multi-turn conversations where the conversation has grown**: Last message might be short but total context is huge. Rule 2 should catch this. OK probably fine.

13. **No consideration of non-English languages**: ctx_tokens byte/3 is even less accurate for non-ASCII (Chinese chars are ~3 bytes in UTF-8 but 1 token each). Judge prompt is English ("约 200 token 的英文分类指令"). Last user message is truncated to 1200 chars (not tokens). For Chinese users, 1200 chars = ~1200 tokens of Chinese, way more than 1200 English tokens. Asymmetric handling.

14. **Race condition on ensure_table**: Concurrent first calls to maybe_route from many processes might race on ensure_table. Should be idempotent (ETS init returns existing or new).

**C. Specific Actionable Improvements**

1. **Validate target model context window**: Add per-tier `max_input_tokens` config. If `ctx_tokens > max_input_tokens`, escalate to next tier (or fall through to judge). Don't blindly trust the rules.

2. **Fix tier fallback order**: Should be context-dependent. If user-requested tier is fast, fall back to big then flagship. If flagship, fall back to big then fast. In general: requested tier → adjacent tier (cheaper or more capable depending on intent) → 404.

3. **Replace spawn+receive</think>


