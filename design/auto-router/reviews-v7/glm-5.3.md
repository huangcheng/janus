# Review v2.5 by glm-5.3 (glm-5.3)

_70.1s · completion_tokens=4000_

Let me carefully review this v2.5 design spec for the Janus Auto Router. This is the 7th round of review (final review). I need to check:

A. Remaining defects or new issues introduced in v2.1+ (well, they said v2.5)
B. Missed edge cases
C. Concrete actionable improvements

Only issues affecting correctness, security, availability, cost count. Style preferences, wording, hypothetical extreme scenarios don't count. If no substantive issues, output PASS.

Let me go through the document carefully.

## Section 2.2 Authorization model

- agent key default access all models; `api_key_models` is optional coarse filter, only effective for the original model name requested by client, no re-check after rewrite. Mitigation: warn at startup if any key has non-full authorization and whitelist contains virtual model name.

This was "定案，不再复议" (settled, not to be revisited). So I shouldn't re-raise this even though there's a security consideration — it's been decided over six rounds. Actually wait — is there still a real security issue? The concern: a key with api_key_models = [janus-auto] can reach ALL models through the virtual model. That's documented with a warn. It's declared settled. Re-raising would violate the review's spirit. OK.

## Section 3 Pipeline

- Rule 0 check: est_total > max_ctx_tokens → 400.
- Note: rule 0 happens "先于一切路由规则". Fine.

- Decision cache: 300s TTL. Negative cache 30s.

## Section 4.1 features

- prompt_est: ASCII bytes ÷ 4; all other codepoints (CJK etc.) × 1.5.
- media_allowance: min(non-text parts count, max_media_parts) × media_token_allowance (default 4096/part, max_media_parts default 10).
- tools_est: JSON bytes ÷ 4
- max_out: max_completion_tokens ?? max_tokens ?? 4096
- est_total = prompt_est + media_allowance + tools_est + max_out
- has_multimodal: any part with type != "text"
- marker_hit: last user role message text contains marker (word boundary for ASCII, substring for CJK)
- msg_count: messages array length

Input robustness: messages must be list of maps, content binary or part list; otherwise pass.

**Edge case**: What about media_allowance when max_media_parts caps at 10 — each part gets 4096 tokens; a request with 10 images → 40960 tokens allowance. With big_ctx_tokens = 60000, est_total = prompt + 40960 + tools + 4096. That could exceed 60000 → rule 3 → flagship. OK, that's bounded. But what if flagship window is also exceeded? Rule 0 only fires if max_ctx_tokens configured. If not configured, "容量防线" says rule 3 + rule 4 + flagship ≥ big guarantee. But the request may exceed flagship's actual window too! E.g., est_total = 200k tokens, big_ctx_tokens = 60000, flagship actual window = 128k. Rule 3 sends it to flagship → upstream 400 error from provider. That's pass-through of upstream error — the spec says this is by design? "容量保护只依赖用户配置的阈值...不依赖模型清单" — the deployer must configure thresholds. Hmm, but if max_ctx_tokens is undefined, there's no hard upper bound, and requests bigger than flagship will fail at the upstream. Is that a defect? The spec explicitly says "未配置 max_ctx_tokens 时，容量保护由规则 3 + 规则 4 + 部署者保证的 flagship ≥ big 共同构成完整防线——任何请求至多到达 flagship 档,不会缺档拦截。" The claim is "requests at most reach flagship tier". But if flagship is 128k and request is 200k, it gets a 400 from the provider (or whatever). The design acknowledges this is deployer's responsibility via thresholds. Since §7 startup validation: "max_ctx_tokens 已配置但 < big_ctx_tokens ⇒ error + 忽略该上限" — so max_ctx_tokens ≥ big_ctx_tokens enforced. But there's no validation that max_ctx_tokens relates to flagship's actual window (Janus doesn't know). This is a documented limitation of "zero assumptions" principle. I think this is acceptable per design; not a new defect. The behavior is: oversized requests fail at provider with provider's error, same as sending directly. Availability impact but consistent with design principles. I'll consider whether to mention as edge case. Maybe worth noting: without max_ctx_tokens, media-heavy requests capped at 10×4096=40960 + prompt + 4096 could still overflow flagship. But deployer sets thresholds. Borderline. Actually let me think about the default config: max_ctx_tokens => undefined by default. Default big_ctx_tokens 60000. So by default, a request with est_total 500k goes to flagship and fails upstream. The user gets a provider 400 instead of a clean 400. Impact: availability/cost — negligible cost, error message slightly different. Given "zero assumptions" is a stated core principle, this is deliberate. I'd rank it low; maybe mention in B as an edge case with suggestion to encourage configuring max_ctx_tokens or validate. Actually the spec already says §8: "未配置 max_ctx_tokens 时的容量防线说明". So they've documented it. I'll skip or briefly mention.

Let me now hunt for real defects.

### Defect hunting

1. **Rules ordering: rule 2 (marker) before rule 3 (total capacity)**. If est_total > big_ctx_tokens AND marker_hit → flagship (rule 2). Same destination as rule 3, so ordering between 2 and 3 doesn't change outcome for those two. But rule 2 before rule 3 — marker → flagship. If est_total > flagship window, fail upstream — same as above. OK.

Wait, actually — v2.5 change ① says "总量检查（→flagship）先于 prompt 段检查". So order is 0,1,2,3,4,5. Rule 2 (marker) before rule 3. Marker → flagship. Fine.

2. **Rule 4 semantics**: `(prompt_est + tools_est) × 1.2 > big_ctx_tokens` → big. Note: this doesn't include media_allowance or max_out. If prompt+tools ≤ big but prompt+tools+max_out+media > big → rule 3 catches (est_total > big). If est_total ≤ big_ctx_tokens → could still be > fast... fine.

But wait — is there a hole between rule 4 and rule 3? Rule 3: est_total > big_ctx_tokens → flagship. Rule 4: (prompt+tools)×1.2 > big_ctx_tokens → big. If prompt+tools is large but est_total ≤ big (because... wait est_total = prompt + media + tools + max_out ≥ prompt+tools, so if (prompt+tools)×1.2 > big, then prompt+tools > big/1.2, est_total ≥ prompt+tools. est_total could be ≤ big while (prompt+tools)*1.2 > big. Then → big. And big's window = big_ctx_tokens (total). est_total ≤ big fits. OK consistent.

3. **max_out default 4096**: fine.

4. **max_completion_tokens ?? max_tokens**: if both null → 4096. OK.

Edge: what if client passes max_tokens = 0 or negative? Or absurdly large like 1,000,000? max_out = 1,000,000 → est_total huge → rule 0 (if configured) → 400; else rule 3 → flagship → upstream rejects or streams long. max_out_bucket = 1000000 div 4096. Fine, not a defect.

What if max_tokens is not an integer (e.g., string "4096") or null explicitly? "?? 4096" — presumably null-coalescing. If it's a float or string, features might crash → caught by try/catch → pass. Minor. Not a defect worth raising? Input validation for max_tokens not specified; but overall try/catch fallback covers. OK.

5. **Cache key**: phash2 with 2^28 domain; includes SysPrefix, LastUserPrefix, ToolsFp, HasMM, prompt_est_bucket, max_out_bucket. Missing: msg_count? media parts count? marker state? Rules already handle marker/multimodal before judge, so those never reach judge. msg_count affects rule 5 only (fast), which bypasses judge too. Within judge region, requests with same prefix/buckets share decision — documented as "近似复用...设计选择而非缺陷". OK.

Hmm wait — one subtle issue: `prompt_est_bucket = prompt_est div 4096`. Two requests with prompt_est 4095 and 4096 → different buckets → different keys → two judge calls. Fine. Requests 0..4095 same bucket. That's coarse but deliberate.

6. **Negative cache and semaphore skip**: negcache hit → default_tier; does negcache hit count toward breaker? No — "负缓存命中与信号量跳过既不计入也不清零". OK per v2 fix.

7. **Semaphore release guarantee**: "获取后在 after 块中保证释放（正常回复、DOWN、超时三条路径都归还）". Hmm — where is the semaphore acquired? Let's look at the flow: 判分区 order: 未指派 judge → default; 熔断 → default; 并发已满（信号量）→ default（soft，不计失败）; 负缓存命中 → default; 决策缓存命中 → tier; judge 调用.

So semaphore acquisition happens after negcache check? Order listed: 未指派 judge, 熔断, 信号量满, 负缓存, 决策缓存, judge. If semaphore is acquired BEFORE checking decision cache, then a cache hit would still consume a semaphore slot briefly — released in after. The listed order suggests check semaphore fullness before cache lookups. Actually the order presented is the sequence of checks: circuit breaker → semaphore (if full → default) → negcache → cache → judge call. If you check semaphore before cache, and acquire it... spec says "获取后在 after 块中保证释放". The pseudocode in 6.2 shows caller receive with after judge_timeout_ms — the "after 块" here is Erlang's `after` timeout clause, plus the demonitor flush paths. As long as acquire→release is bracketed, fine.

But one potential leak: if semaphore acquired by the HTTP handler process, and then... the acquire and release are in the same receive structure with three exit paths. What if an exception occurs between acquire and receive (e.g., ETS cache write error, or the spawn_monitor fails)? spawn_monitor could fail if process limit reached ({error, ProcessLimit}?) Actually spawn_monitor doesn't fail typically, it can raise if max processes reached. Then the acquire isn't released? The whole maybe_route is wrapped in try/catch → pass, but the semaphore slot would leak. Hmm — is this realistic? If node is at process limit, spawn fails, slot leaks. Each leaked slot reduces judge concurrency until restart. But at process limit, judges can't run anyway. Marginal. The spec says release guaranteed on the three paths (reply, DOWN, timeout). A crash between acquire and entering receive isn't covered but maybe_route's try/catch means the process survives (it's the caller's try/catch). Actually the semaphore release "在 after 块中保证" — if implemented as try/after in code (Erlang `try ... after Release end`), it would cover exceptions too. The spec text says "获取后在 after 块中保证释放（正常回复、DOWN、超时三条路径都归还）" — the parenthetical enumerates three paths, but "after 块" in Erlang semantics covers exceptions. I'd accept this as fine. Not a defect.

8. **Judge worker uses gun one-off connection with owner = worker; caller kills worker on timeout**. gun connection owner death → cleanup. Fine.

One subtle thing: worker sends {Ref, Tier} then... after sending, the worker exits normally (fun ends). Caller demonitors with flush. OK.

But wait — what if worker sends {Ref, Tier} but caller already timed out and killed it (race)? Then reply lost; caller already on failure path. Fine. What if the DOWN arrives before {Ref, Tier}? Monitor DOWN after normal exit — caller demonitor flush removes. Order: worker sends message then exits; caller receives {Ref, Tier} first (mailbox order: send happens-before exit, messages from same process arrive in order... {Ref,Tier} from worker, DOWN from monitor (from runtime). Erlang guarantees signals from the same sender ordering, but DOWN comes from the runtime on behalf of the process — actually DOWN is sent when the process exits, and message send before exit means {Ref,Tier} delivered before DOWN in practice... There's a subtlety: erlang:demonitor(MonRef, [flush]) after receiving {Ref,Tier} flushes a possibly-queued DOWN. OK, spec handles with flush. Good.

9. **Circuit breaker per judge_model; config switch race: worker snapshots judge_model; writebacks tagged with snapshot model; if mismatch with current config, discard.** Good.

But: the decision cache value carries JudgeModel — read mismatch → miss. Good.

Negative cache entry: {neg, Hash} — does it carry JudgeModel? §5 says value for main table is {Tier, JudgeModel, ExpiresAt}. The neg entry — stored as separate key {neg, Hash} in same main table? "主表 set：{Hash => ...}" but then "正决策存 {pos, Hash}，负缓存存 {neg, Hash}". So main table keys are {pos,Hash} and {neg,Hash}. Value for pos = {Tier, JudgeModel, ExpiresAt}. What's the value for neg? Presumably {JudgeModel, ExpiresAt} or {neg, JudgeModel, ExpiresAt}? The spec doesn't explicitly say neg entries carry JudgeModel for invalidation on judge switch. If neg entries don't carry the judge model name, then after switching judge_model, old negative cache entries (from the old judge's failures) remain valid for 30s and skip judging with the new judge. Impact: 30s of sticky default_tier after a judge switch — negligible? The spec fixed "幽灵命中" for positive decisions with JudgeModel check, and circuit breaker state resets on judge change (per-model state). The neg cache 30s TTL is short. But for consistency: if the fix rationale was "更换 judge 后旧决策不会幽灵命中污染新模型的前 300s", the same logic applies to neg for 30s. Minor consistency gap, impact ≤30s of conservative default_tier routing — cost-only, small. Is it worth listing? It's a real inconsistency; the spec explicitly aligned "负缓存措辞与分键空间对齐" in v2.5 change ④. Hmm. I could raise it as a low-severity B item. Actually wait — does the neg writeback path also carry the snapshot model check? "其结果回写（负缓存/连败计数）携带该快照的 model 名；若与当前配置不一致，回写直接丢弃" — yes, the worker's writeback carries snapshot model and is discarded on mismatch. But that's about racing workers during switch. The stored neg entry — when read 20s later with new judge — does the read check model? Not specified. Given pos check exists, symmetric check for neg is cheap. Impact: after judge switch, up to 30s of default_tier for previously-failing hashes. Cost-only, bounded, tiny. Might be worth one line in B or C. Borderline per "影响可忽略不计" rule. 30s bounded, cost impact negligible. I'd fold it into C as a consistency suggestion rather than a defect.

10. **FIFO eviction with secondary ordered_set {Seq, Kind, Hash}**. Write both tables in same transaction? ETS has no transactions; two separate ETS tables — write to set then to ordered_set (or vice versa). Crash between → inconsistency (entry in one table but not other). Single-node, sequential ops in same process — a crash between two ets:insert calls is essentially impossible unless node dies (then everything gone). Fine.

Capacity: ">4096 时从辅表头部无条件删除对应主表条目直至回到 4096，单次清扫至多处理 128 条". Wait — capacity 4096, insert makes 4097, evict 1 → back to 4096. When would you need to evict more than 128 at once? After restart or if previous sweep capped at 128: if inserts outpace sweeps... Each insert adds 1, sweep removes excess up to 128 per insert. Excess can never exceed 128+1 because each insert triggers a sweep. Actually if sweep processes at most 128 per single write, and each write adds 1, backlog can grow: write 1, evict up to 128. Backlog grows only if... each write adds 1 and evicts up to 128 ≥ 1 needed. So backlog never grows. The 128 cap is just a latency bound. Fine.

Edge: does the 4096 capacity count pos and neg entries together? "容量 >4096" — the aux table holds both kinds; presumably total. Neg entries (30s TTL) also occupy capacity and evict pos entries (FIFO — neg written later, so pos evicted first — actually oldest evicted first regardless of kind). Fine, bounded.

Hmm — one thing: the TTL lazy expiry. Entries expired but not swept still occupy capacity until FIFO evicts them. With TTL 300s and steady traffic, cache recycles in ~4096 requests. Bounded. Fine.

11. **Rule 5**: `not has_tools 且 est_total < fast_ctx_tokens 且 msg_count ≤ 3` → fast (定向 hard/可用性 soft). Note est_total includes max_out (default 4096) and media_allowance. fast_ctx_tokens default 8000. So prompt < 8000-4096-tools. OK.

Multimodal requests: has_multimodal → rule 1 flagship first. So rule 5's media component only via... has_multimodal is true whenever non-text part exists, so rule 5 requests have media_allowance = 0? Not exactly — media
