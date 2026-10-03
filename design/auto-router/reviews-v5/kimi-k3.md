# Review v2.3 by kimi-k3 (k3)

_89.2s · completion_tokens=4000_

Let me review v2.3 carefully for remaining defects.

Key areas:

1. **Rules 3 and 3b ordering / semantics**: Rule 3: `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` → big. Rule 3b: `est_total > big_ctx_tokens` → flagship. est_total includes prompt_est + media + tools + max_out. If est_total > big_ctx_tokens, typically (prompt+tools)×1.2 > big? Not necessarily. Consider prompt+tools = 0.8×big. Then (prompt+tools)×1.2 = 0.96×big < big → rule 3 doesn't fire. max_out = 4096 default. est_total = 0.8big + 4096 > big? If big=60000, 48000+4096=52096 < 60000. So rule 3b needs est_total > big. OK.

But wait — rule 3 sends to `big` when prompt+tools alone exceed big window. But est_total ≥ prompt+tools+max_out... if prompt+tools×1.2 > big, then prompt+tools > big/1.2, and est_total = prompt+tools+max_out which might exceed big too → rule 3b would send to flagship. But rule 3 is listed before 3b, so rule 3 fires first → big. Is that correct? If prompt+tools alone is 0.84×big, plus max_out 4096 → est_total may be < big → fits big. But if prompt+tools = 0.9×big, ×1.2 = 1.08big > big → rule 3 → big; but est_total = 0.9big + max_out could be < big still (0.9×60000+4096=58096 < 60000). OK borderline. If prompt+tools = 0.95big: ×1.2 = 1.14 > big → big, est_total = 57000+4096 = 61096 > 60000 → should be flagship but rule 3 sends to big first → request exceeds big's total window! That's a defect: rule ordering means rule 3 can shadow rule 3b. Actually if rule 3 fires when (p+t)×1.2 > big, and est_total = p+t+max_out > big as well, the request is routed to big whose total window can't fit it. Rule 3b should be checked before rule 3, or rule 3's condition should be `big_ctx_tokens < est_total ≤ ...` Hmm. Actually the intended logic: rule 3 routes to big when prompt alone exceeds... wait, rule 3's purpose is: prompt+tools large → not fast, route big. But if total exceeds big's window, must go flagship. Since rule 3 has higher priority, requests where (p+t)×1.2 > big AND est_total > big get mis-routed to big → overflow. Correct fix: check rule 3b (est_total > big → flagship) before rule 3, or make rule 3 condition `(p+t)×1.2 > big AND est_total ≤ big`. This is a real correctness defect (v2.3's new rule 3b is shadowed).

Wait, but is it possible rule 3 fires but est_total ≤ big? (p+t)×1.2 > big means p+t > big/1.2 ≈ 0.833big. est_total = p+t+max_out+media. With max_out 4096 and big=60000: p+t > 50000. est_total > 54096 — could be < 60000 or > 60000. So yes overlap exists. Defect confirmed.

Actually also consider: rule 3b placed after rule 3 — if est_total > big but (p+t)×1.2 ≤ big, rule 3b catches → flagship. Fine. But the shadowing case above routes to big incorrectly. So recommendation: evaluate 3b before 3, or rule 3 sends to big only when est_total ≤ big_ctx_tokens.

2. **Rule 4 and fast tier semantics**: rule 4 uses est_total < fast_ctx_tokens. fast_ctx_tokens is total window. OK. Rule 4 hard targeting, soft availability — fixed.

But note: judge never sees short requests — documented tradeoff. OK.

3. **Cache key collision / HasMM**: fine.

4. **Cache: decision cache stores Tier but not the resolved target; tier resolution per-read — fine.**

5. **Value includes JudgeModel — but rules-based decisions never cached, only judge. OK.**

6. **Negative cache key same as decision cache?** "负缓存（失败特征写 30s TTL 条目，与决策缓存同结构，Tier 记为 neg）" — does negative cache value also carry judge_model? If judge fails and writes neg entry, then operator switches judge model — neg entry ghost-hit for 30s causing default_tier even though new judge might work. Minor, 30s. Not a defect worth listing? Could mention as minor. Actually §6.2 says "回写直接丢弃" if snapshot mismatch — the neg cache write carries model name and is dropped if config changed. But reading: does neg cache read check judge model? Value = {Tier, JudgeModel, ExpiresAt} presumably same structure, and read mismatched → miss. If neg uses same structure it inherits the check. OK.

7. **400 error body: OpenAI compatible — fine.**

8. **Malformed messages → pass → model_not_found 404.** Hmm: a malformed request to model "janus-auto" returns "model_not_found" 404 which is misleading but acceptable? They explicitly defined it. Edge: what if the virtual model name is in models table (it is, for /v1/models display) — then pass → treated as normal model "janus-auto" → it has no routes (A8) → what happens? §8 says "messages 畸形 → pass → 既有 model_not_found 404". But the virtual model IS in the models table. If pass-through proceeds, proxy would look up routes for janus-auto, find none → presumably 404 no route or something. The spec claims model_not_found 404. Is the behavior actually model_not_found? Since the model row exists in models table (§7 step 4: "虚拟模型是 models 表普通一行（仅用于 /v1/models 展示），无自身 routes"), a pass-through request would find the model exists but has no routes → error would be "no route available" not "model_not_found". Inconsistency between §4.1/§8 claim (model_not_found 404) and §7 (model exists in models table). This is a minor spec inconsistency — could count as availability/correctness of error semantics. Worth listing as minor defect: either the error is not model_not_found, or malformed requests get routed to... Actually wait — would the proxy attempt upstream forwarding? No routes → error. The claim "不会透传给上游" holds. But the error type mislabeled. Minor.

9. **prompt_est for marker/judge vs cache**: fine.

10. **est_total overflow of max_ctx check**: Rule 0 only when configured. If max_ctx_tokens undefined, capacity relies on rules 3/3b + flagship≥big. But what if flagship's window < est_total? Deployment guarantee. OK.

11. **Rule 2 marker → flagship hard; if flagship unavailable → no_route 404**. A user typing "think harder" on a deployment without flagship tier configured → 404. That's intended hard semantics. OK, but "整档为空且可能被规则命中 ⇒ error（一次性）" startup check warns.

12. **Rule 3 condition uses big_ctx_tokens but routes to big; what if big tier not configured but flagship is?** hard no_route. Hmm — rule 3 hard to big; big unavailable → no_route, not escalate to flagship. Is that a defect? A request that fits big could be served by flagship (which is guaranteed ≥ big). Hard constraint here is capacity, not "must be exactly big". Routing to flagship would be safe (larger window). Denying with 404 when flagship could serve reduces availability. Similarly rule 3b→flagship is the top, fine. Rule 1 multimodal → flagship only (design: multimodal only flagship). Rule 2 marker → flagship. For rule 3, big unavailable but flagship available: arguably should escalate to flagship (cost worse but availability better). This could be a legitimate improvement suggestion. Is it a defect? Availability impact: deployment without big tier (only fast+flagship) — all medium-large requests 404. Startup check only errors if tier empty "且可能被规则命中" — it logs error but requests still fail at runtime. I'd list as improvement: hard capacity rules should allow upward escalation (big→flagship) since window guarantee is monotonic; hard means "no downward degrade", not "no upward". Actually hard semantics in N2 fix: "容量/模态/显式意图不允许降级到 default_tier" — escalation isn't downgrade. So suggesting big-unavailable→flagship fallback is reasonable improvement.

13. **Cache key includes prompt_est_bucket div 4096 but not max_out**: two requests identical prefix but different max_tokens (e.g., 100 vs 16000) → same cache key. But rules gate first: max_out affects est_total; if both reach judge region (rule 5), est_total < big_ctx and not fast... rule 4 requires est_total < fast and msg_count≤3. So a request with huge max_out stays in judge region if est_total ≥ fast or msg_count>3. Cached tier decision doesn't depend on max_out, but tier decision is about task difficulty — max_out doesn't change difficulty. Both requests passed rule 0/3b capacity checks anyway (re-evaluated per request, rules not cached). So fine — rules are never cached, so capacity always enforced. OK.

14. **Cache key doesn't include model-of-tools? ToolsFp included. HasMM included. OK.**

15. **Judge input: "system 前 256 字符 + 末条 user 消息前 1200 字符" — ignores middle messages; multi-turn context ignored. Design choice (subset digest acknowledged). Fine.**

16. **max_out default 4096**: with est_total rule 4 fast: est_total includes max_out 4096 default; fast_ctx 8000 → prompt must be < 3904. OK.

17. **Rule 3b & max_ctx interplay**: max_ctx ≥ big enforced (else ignored). Rule 0 catches est_total > max_ctx. Requests with big < est_total ≤ max_ctx → flagship. Good.

18. **media_allowance: counts non-text parts × 4096. But rule 1 has_multimodal → flagship anyway (hard), so media allowance in est_total matters only for rule 0 ordering... Rule 0 before rule 1: multimodal request with est_total > max_ctx → 400 rather than flagship. Intended ("先于一切路由"). Fine. But since all multimodal goes flagship anyway, media_allowance only affects rule 0. OK consistent.

19. **tools_est JSON bytes ÷ 4 — fine.**

20. **Cache: 写入两表同笔 — but negative cache entries also in same table with Tier=neg; decision cache read "tier (soft)" — need to distinguish neg entries on read; presumably handled. Fine.

21. **Sweep: capacity >4096, sweep from辅表 head, check expiry, delete — but if head entries not expired and table full, sweep stops at 128 and then what? Insert anyway exceeding capacity? Unspecified. Minor; bounded memory? If all 4096 entries fresh and new writes keep coming, table grows unboundedly? "容量 >4096 时从辅表头部取出条目检查过期并双表删除，单次至多 128 条" — if entries not expired, are they deleted anyway (eviction) or kept? "检查过期并双表删除" ambiguous: delete only if expired? If kept, capacity exceeded → unbounded growth until entries expire (TTL 300s, max 300s worth of writes — bounded by rate×300). Actually bounded by TTL since entries expire eventually; but memory could spike with high write rate. Minor; probably evict oldest regardless (LRU-ish). Not a big deal. Could mention as minor.

22. **atomics semaphore: increment then check > max → decrement and skip; kill path must decrement. Worker killed via exit(Pid, kill) — who decrements? If counter incremented by caller before spawn, and worker decrements at end, kill means decrement never runs → leak → semaphore permanently full → judge permanently skipped (availability degradation). Need careful spec: decrement in caller after receive/timeout. The spec doesn't say where decrement happens. This is a real robustness gap worth mentioning — judge_max_inflight leak would silently disable judge forever (falls to default_tier, availability of judge feature). List as defect (B: missing boundary).

23. **demonitor flush on success path: ok.**

24. **spawn_monitor + exit(Pid,kill): DOWN may arrive after timeout flush — flushed. OK. But race: worker sends {Ref, Tier} just as timeout fires; caller does exit+flush, then proceeds failure path, but the {Ref,Tier} message remains in mailbox — not flushed! demonitor flush only removes DOWN messages, not the {Ref,Tier} tuple. Stale {Ref, Tier} lingers in HTTP handler's mailbox. Ref unique per request so it won't match future receives, but mailbox grows by one message per timed-out judge — in a long-lived connection process (HTTP handler may be short-lived per request in cowboy — each request has its own process, so fine). If handler is per-request process, message dies with process. Probably fine but worth noting? In cowboy each request is a process; process ends after response. So negligible. Skip or minor.

Actually also on success path: worker process exits normally after sending; DOWN flushed. Fine.

25. **Judge timeout kill: gun connection owner-death cleanup — fine.**

26. **Rule 4: msg_count ≤ 3 includes system — fine.**

27. **marker word-boundary: "don't think harder" test — word boundary matching on ASCII: "think harder" inside "don't think harder" still matches as phrase with word boundaries! The test name says 反例 — meaning "don't think harder" should NOT hit? That's odd — the phrase "think harder" appears in it. Maybe the 反例 is about substring like "think harderly"? Hmm, the test asserts... unclear. Not a spec defect per se; marker semantics inherently blunt. Skip.

28. **400 vs 404 for malformed: pass → 404 model_not_found — but model exists (in models table). As noted in #8, inconsistency. Also: what does normal proxy do with a model in models table but no routes? Likely 404/502? Spec claims model_not_found — questionable. Also a malformed request could instead be handled more correctly with 400 invalid_request. Improvement suggestion: malformed messages → 400 rather than fake pass → confusing 404. Actually they chose pass to reuse existing behavior. But the mismatch with §7 (model row exists) makes the claimed error wrong. List.

29. **est_total vs rule 0 when max_ctx configured but flagship window smaller than max_ctx — deployer responsibility. OK.**

30. **Rule 3b shadow — my #1 — the strongest defect.**

31. **has_multimodal detection includes "一切非 {type:text} 的 part" — content as binary vs list validated. OK.**

32. **Negative cache write on judge failure keyed by request features — a transient judge outage poisons... no wait, neg cache → default_tier for that feature for 30s; but breaker handles global. Fine.**

33. **熔断按 judge_model 名 — but if two different endpoints share model name... fine.**

34. **配置指纹重算缓存校验 — ok.**

35. **stats counters — ok.**

36. **Decision cache stores tier from judge; if tiers config changed (e.g., flagship list emptied), cached tier still resolves at read time per §7 — resolution per-read, fine. But cached tier "fast" from judge, fast unavailable → soft → default. OK.**

37. **Rule ordering: rule 2 (marker → flagship) before rule 3/3b — marker on huge request → flagship even if est_total > max_ctx? No — rule 0 first. If max_ctx undefined and est_total enormous with marker → flagship hard, may overflow flagship. Deployer guarantee. OK.**

38. **Rule 4 uses est_total < fast_ctx_tokens; est_total includes max_out default 4096 — good.**

39. **One more: rule 3 condition `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` — note media_allowance excluded because multimodal already rule 1. Fine. But est_total in 3b includes media — but multimodal requests never reach 3b (rule 1). So media in est_total only relevant for rule 0. Slight redundancy, fine.**

40. **Judge max_tokens 200 for reasoning models — reasoning tokens can exceed 200 easily → judge always fails for reasoning models. Noted "容纳思考型 judge 的前置 token" — 200 is arguably too small but configurable? Not configurable. Minor/known.

41. **Cache read JudgeModel mismatch → miss — good. But decision cache write: does it stamp judge model at decision time (snapshot) — yes presumably.

42. **Negative cache ghost: neg entries also carry JudgeModel? Spec: "Value：{Tier, JudgeModel, ExpiresAt}" for decision cache; neg cache "与决策缓存同结构" — so yes. Good.

43. **The semaphore: "满则跳过 → default_tier，不计失败" — fine.**

44. **Rule 3b new — shadowing issue (#1) is the key finding.**

45. **Rule 3's hard target big: but what if big tier configured but its models have smaller window than big_ctx_tokens — zero-assumption, deployer. OK.**

46. **msg_count includes all roles — a 2-message convo with huge system... est catches. fine.**

47. **prompt_est "ASCII 字节数 ÷ 4；其余码点×1.5" — code points vs bytes: need decoding; malformed UTF-8? Spec doesn't define behavior for invalid UTF-8 binaries in content. features could crash → caught by try/catch → pass. Fine per §2.3.

48. **400 error body fixed format; but message hardcodes max_ctx_tokens name. fine.**

Also check: **rule 0 with max_ctx < big is ignored (startup)** — then a request with est
