# Review v2.5 by kimi-k3 (k3)

_114.2s · completion_tokens=4003_

Let me carefully review v2.5 as a final review round. The claimed fixes: rule reorder (total before prompt-segment), media part cap, FIFO eviction semantics, semaphore release in `after`, negative cache keyspace alignment.

Let me hunt for real defects.

**A. Remaining defects / newly introduced in v2.5:**

1. **Signal semaphore release "in `after` block" — where?** §6.2 says "获取后在 `after` 块中保证释放（正常回复、DOWN、超时三条路径都归还）". Ambiguity: `after` in Erlang `receive...after` only fires on timeout. If they mean try/after that's fine. The pseudocode shows the caller holds... actually who acquires the semaphore? If acquired by caller before spawn, and worker crashes... Actually spec says "获取后在 after 块中保证释放" — likely try...after. This was claimed fixed in v2.5 (④ 信号量释放写入 `after` 保证). OK.

But wait — a real issue: the semaphore is acquired, but the judge worker is spawned. If caller acquires semaphore then crashes (HTTP handler dies), semaphore leaks unless released in worker's after or monitor. Actually the pseudocode shows spawn_monitor happens; who acquires? Unclear. But "获取后在 after 块中保证释放" — if the caller acquires and the caller process is killed (e.g., connection close, timeout elsewhere), the atomics counter leaks permanently → judge permanently disabled after leaks accumulate. Need ownership: acquire in worker process, or use try/after in caller with cleanup. Since it's atomics (no owner tracking), any abnormal exit of the acquiring process leaks. This is a real correctness/availability issue. Should specify: semaphore acquired and released within same process's try/after, and the receive/timeout logic all inside that try.

Actually §6.2 says "获取后在 `after` 块中保证释放（正常回复、DOWN、超时三条路径都归还）" — this covers the three receive paths but not caller death. Caller is HTTP handler; if the handler process dies mid-receive (client disconnect kill? typically cowboy doesn't kill handlers on disconnect... but timeouts/crashes possible), the atomics count leaks. Real but maybe low probability. Worth flagging: specify acquire inside worker with linked release, or caller try/after wrapping everything and note handler kill leakage; better: acquire in worker.

2. **FIFO eviction + cache key collision between pos and neg entries in main table**: Main table is `{Hash => ...}` set, but pos and neg entries both keyed by... The aux table key is `{Seq, Kind, Hash}` and "与主表完整键一致" — so main table keys are actually `{pos, Hash}` / `{neg, Hash}`? The text says 主表 `set`：`{Hash => {Tier, ExpiresAt}}` but then "辅表键含 Kind，容量超限改 FIFO 无条件淘汰" and "（与主表完整键一致）". Contradiction: main table shown as Hash-keyed but pos/neg split requires {Kind, Hash} keys. v2.5 ④ says "负缓存措辞与分键空间对齐" — they claim aligned, but §5 still writes 主表 `{Hash => {Tier, ExpiresAt}}`. If main table is keyed by bare Hash, pos and neg entries collide — writing neg would overwrite pos (the exact bug v2.4 fixed). This is a spec inconsistency: the main table key must be `{Kind, Hash}`. Minor wording but could be flagged as residual defect — actually they said v2.5 ④ aligned wording... but the bullet "主表 `set`：`{Hash => {Tier, ExpiresAt}}`" remains. Hmm, it says 辅表 `{{Seq, Kind, Hash} => ok}`，`Kind` 为 `pos | neg`（与主表完整键一致）— "与主表完整键一致" implies main table full key includes Kind. So the `{Hash => ...}` line is just shorthand/stale. Borderline; can mention as clarity issue but they asked only real defects. It could cause implementation error. I'll mention briefly.

3. **FIFO eviction of pos entries can evict a fresh positive entry while old neg entries exist** — FIFO unconditional eviction evicts oldest regardless of kind. Fine, deterministic. Not a defect.

4. **Cache key doesn't include tools_est / msg_count, and judge input subset** — stated as design choice. OK.

5. **Rule ordering issue: Rule 3 vs Rule 4 — v2.5 reordered total check before prompt-segment check.** Rule 3: est_total > big_ctx → flagship. Rule 4: (prompt+tools)×1.2 > big_ctx → big. Is this correct? If est_total ≤ big_ctx but prompt+tools×1.2 > big_ctx → big. Fine. But wait: can rule 4 fire while rule 3 didn't? prompt×1.2 > big but prompt + max_out + ... ≤ big? ×1.2 multiplier means prompt alone with margin exceeds big, but total without margin is under big. Yes possible (max_out small). Goes to big. But prompt×1.2 > big_ctx means prompt+margin exceeds big's window — sending to big could overflow if prompt alone near window. Actually the ×1.2 is a safety margin for estimation error; if prompt_est×1.2 > big_ctx, actual prompt may exceed big window → routing to big risks overflow. Should arguably go to flagship. Hmm: prompt_est×1.2 > big_ctx means the *estimated-with-margin* prompt exceeds the big window. Then sending to big is dangerous — but est could be overestimate. Design decision: with margin it exceeds → they send to big anyway. Actually wait, before v2.5 the order was rule 4 (prompt check → big) before rule 3 (total → flagship). They reordered claiming "总量溢出比 prompt 段溢出更严重". But now: prompt_est×1.2 > big_ctx while est_total ≤ big_ctx → big. If actual prompt > big window → overflow at big. Whereas sending to flagship would be safer. Is this a defect? The margin ×1.2 exists because prompt_est underestimates (ASCII÷4 etc.). If prompt_est×1.2 > big_ctx, there's real risk actual prompt tokens > big_ctx. Routing to big (whose window is big_ctx) risks provider rejection. Routing to flagship (≥ big window) doesn't help either if prompt > big_ctx ≈ flagship window? flagship ≥ big guaranteed, could be larger. Hmm, but if prompt alone exceeds big_ctx total window, then est_total = prompt + max_out + ... ≥ prompt_est, and prompt_est > big_ctx/1.2, not necessarily > big_ctx. So est_total might be ≤ big_ctx while actual prompt could exceed. Edge case; the safe route would be flagship for margin-violating prompt too, or 400 if max_ctx configured. I'd flag: rule 4 → big when the margin-adjusted prompt already exceeds big_ctx's total window is questionable; since prompt+output must fit, and prompt alone (with margin) > window, big cannot fit it — should be flagship (or rely on rule 3b... but est_total check uses un-margined prompt). Actually this is a genuine logical issue: rule 4's condition implies big likely can't hold the request, yet routes to big. Recommendation: rule 4 → flagship, or compare (prompt+tools)×1.2 + max_out vs big_ctx. Hmm but wait — was this flagged in prior rounds? The v2.5 reorder put total first; rule 4 remains → big. The reviewer should catch this: the ×1.2 margin branch to big only makes sense if big can still hold it. Let me think again: condition 4: (prompt_est+tools_est)×1.2 > big_ctx_tokens. Note big_ctx_tokens is *total window*. If prompt×1.2 > total window, then even the un-margined prompt could be up to > big_ctx/1.2... and actual prompt with 20% underestimate = > big_ctx. So the request cannot fit big's window under the pessimistic estimate → sending to big is wrong; flagship (larger window) is the safe target, or this condition is meant as "prompt segment alone is huge → definitely needs big not fast". Original design intent was probably "prompt exceeds fast, goes big". But comparing against big_ctx and routing to big is contradictory. Actually maybe intent: prompt×1.2 > big_ctx means it's a "big-context" request → big tier, with flagship reserved for total overflow. But if big's window = big_ctx and prompt×1.2 already exceeds it... yeah inconsistent. This is a legit defect to raise: rule 4 should target flagship or the comparison should be against a big-prompt budget < big window. Good catch for A.

Hmm, but wait: v2.3→v2.4 history says rule 3b was `est_total > big_ctx → flagship`. In v2.5 table, rule 3 is that. And rule 4 `(prompt_est+tools_est)×1.2 > big_ctx` → big. The concern: if est_total ≤ big_ctx (rule 3 didn't fire) but prompt×1.2 > big_ctx, then prompt_est > big_ctx/1.2 ≈ 0.83×big_ctx, and max_out etc. fill the rest. Actual prompt may be up to 1.5× underestimate... the ×1.2 accounts for that. So the design believes actual prompt could exceed big_ctx → but then est_total (using underestimated prompt_est + max_out) ≤ big_ctx is also suspect. Anyway, sending to big when margin-adjusted prompt exceeds big's whole window is a real risk of provider 400. I'll include as defect with suggested fix: rule 4 → flagship (or compare (prompt+tools)×1.2 against big_ctx − max_out, else flagship).

Hmm, but is this "假想的极端场景"? prompt near big window with small max_out is realistic (e.g., paste 55k tokens into 60k-window big with default max_out 4096: est_total = 55k+4k = 59k ≤ 60k → rule 3 no; 55k×1.2=66k > 60k → rule 4 → big. Actual prompt might be 62k > 60k window → provider rejects). Realistic enough. Counts as correctness/availability. Include.

6. **Rule 5 fast uses est_total < fast_ctx but without margin** — total window semantics, fine, documented.

7. **Semaphore + breaker + worker snapshot**: worker snapshots judge_model; if config changes mid-flight, results discarded — but the semaphore slot release still happens. OK.

8. **Negative cache TTL 30s vs positive 300s: pos entry read first, neg only if no valid pos.** OK.

9. **phash2 Hash collision between different inputs**: accepted design.

10. **Cache key missing `tools_est`**: design choice (subset digest). OK.

11. **Rule 0: est_total > max_ctx → 400. But flagship window may be smaller than max_ctx?** If max_ctx > flagship's actual window, requests between flagship window and max_ctx get routed to flagship and fail at provider. Janus zero-assumption; deployer responsibility. Documented-ish (capacity defense). Fine.

12. **`max_out` default 4096 when unset**: OK.

13. **Marker check on last user message only; injection?** fine.

14. **Judge input injection**: user content quoted; parse takes last line. OK.

15. **Concurrency: atomics semaphore global but breaker per judge_model — where stored?** Not specified but implementation detail.

16. **spawn_monitor + `after judge_timeout_ms` then exit(Pid, kill)**: if worker already sent {Ref, Tier} but caller in timeout branch? receive would have matched first. Race: message arrives just after timeout → demonitor flush doesn't remove {Ref, Tier}; caller mailbox retains {Ref,Tier} orphan message → mailbox leak per timed-out call. Actually the worker sends {Ref, Tier} then exits; caller in after-branch kills (no-op) and demonitors. The {Ref, Tier} message remains in caller's mailbox forever → leak in long-lived handler process. HTTP handler processes are short-lived (per request), so impact negligible. Hmm, cowboy handlers terminate after response. Negligible. Skip or mention? "影响可忽略" — skip.

17. **Demonitor flush in timeout path kills worker but worker may still be mid-gun-call; owner death cleans gun.** OK.

18. **FIFO eviction bounded 128 per sweep**: if writes outpace, table may exceed 4096 temporarily — bounded eventually. Fine.

19. **Aux table orphan entries**: when a pos entry expires (lazy) it's not removed from aux; aux keeps growing? Aux entries are removed only during capacity sweep. If main table has ≤4096 live entries but aux accumulates stale {Seq,Kind,Hash} for expired-then-rewritten entries: a rewrite of same Hash creates new Seq entry; old aux entry remains. Sweep deletes "对应主表条目" for old aux head — but old aux entry may reference a Hash whose current main entry is the *new* write (newer Seq). Unconditional FIFO delete would then evict a *fresh* main-table entry when sweeping the stale aux record! Is that handled? "从辅表头部（最旧）无条件删除对应主表条目" — if the same Hash was rewritten (new Seq), the old aux record still points to that Hash; sweeping it deletes the live new entry → premature eviction (correctness minor, cost only) AND the new aux record remains, later sweep deletes again (no-op). Worse: it breaks FIFO bounds? Table size still bounded since each sweep deletes. Impact: fresh entries evicted early → cache effectiveness reduced, not correctness. But it could be churn. Fix: aux value should store Seq in main table too, or sweep checks seq match. Simple fix: main table value includes Seq; sweep deletes only if seq matches. Worth flagging as B (boundary case) with low severity — affects cache hit rate (cost), arguably counts. I'll include in B.

Also neg entry {neg,Hash} and pos entry {pos,Hash} are distinct keys — fine with Kind in key.

20. **Rule 2 marker → flagship hard: "flagship 窗口由部署者保证 ≥ big"** fine.

21. **400 when max_ctx configured: hard 400 may reject requests that flagship could serve if max_ctx misconfigured > actual flagship window** — no, 400 only when est_total > max_ctx. Deployer sets max_ctx ≤ flagship window ideally. The startup check only validates max_ctx ≥ big_ctx. If big_ctx < max_ctx but max_ctx > flagship actual window → requests est_total in (flagship_window, max_ctx] route flagship and fail at provider. Deployer responsibility; zero-assumption principle. OK.

22. **信号量满 → default_tier 不计失败** fine.

23. **judge_timeout_ms default 1500 with max_tokens 200 thinking judge may exceed → frequent timeouts** — config issue, defaults; skip.

24. **features: prompt_est ASCII÷4 underestimates for some tokenizers; margin 1.2 only in rule 4; rule 0 and 3 use raw est_total** — rule 0 hard 400 without margin could 400 a request that actually fits (false positive) — acceptable? Or underestimate → pass oversized to flagship → provider 400. Zero-assumption tradeoff; margin discussion. est_total vs max_ctx without ×1.2: a request est 95% of max_ctx but actual 110% → routed flagship → provider rejects with its own error (acceptable, provider error propagates). Not a defect per se.

25. **v2.5 ① reorder: rule 3 before rule 4 — does rule 3 (est_total > big_ctx → flagship) shadow rule 4 correctly?** est_total includes max_out ≥ 4096 default. So any prompt > big_ctx − 4096 goes flagship. Rule 4 fires only when est_total ≤ big_ctx but prompt×1.2 > big_ctx → prompt ∈ (big_ctx/1.2, big_ctx − max_out − tools − media]. Nonempty only if max_out+tools+media < big_ctx − big_ctx/1.2 = big_ctx/6. With defaults 60k/6=10k, max_out 4k → prompt ∈ (50k, 56k) → big. Actual prompt could be up to ~1.5×? No—×1.2 is the inflation margin meaning actual ≈ est×up to 1.2. So actual prompt up to 67k > 60k window → big overflow. Confirms defect #5.

26. **Starter check "max_ctx < big_ctx → ignore"** — but what about max_ctx < flagship? unknown. fine.

27. **缓存 value 读取时 JudgeModel 不匹配即 miss — but neg entries also carry?** Neg entries presumably also keyed... The value spec `{Tier, JudgeModel, ExpiresAt}` for pos; neg value unspecified but presumably includes JudgeModel too — after judge change, old neg entries could suppress new judge calls for 30s. Minor; could flag: neg entry should also carry judge_model and be invalidated on mismatch — otherwise switching from a failing judge to a healthy one is still suppressed up to 30s by stale negcache. Impact: 30s availability delay, negligible-ish but real. The breaker is per-model (fixed), cache pos fixed, but neg not stated. Flag in B.

28. **Rule 5: msg_count ≤ 3 and est_total < fast_ctx — but has_multimodal already rule 1.** fine.

29. **`maybe_route` only matches binary full equality; model_allowed check on original name** fine.

30. **negative cache write on parse failure** — judge gave garbage → 30s default_tier for that Hash. fine.

31. **Semaphore acquire before or after cache checks?** Pipeline order: negcache → decision cache → judge. Semaphore "judge 并发已满 → default" listed before negcache in pipeline ④? Order listed: 未指派 → 熔断 → 信号量 → 负缓存 → 决策缓存 → judge. Checking semaphore before cache reads: if semaphore full, skips even a potential cache hit → default_tier despite cached decision! That's wrong order: cache hit is free and should be served regardless of inflight count. Pipeline lists 信号量 check before 负缓存/决策缓存. If implemented in that order, under judge load, requests with valid cached decisions degrade to default_tier unnecessarily — cost defect, availability of cache. But
