# Review v2.1 by kimi-k3 (k3)

_78.9s · completion_tokens=4000_

Let me carefully review this v2.1 spec. Claims: N1-N8 fixed. Need to find remaining defects.

Let me analyze each area:

**A. Remaining defects:**

1. **Rule 3 vs Rule 5 contradiction / big vs flagship capacity**: Rule 3: `(prompt_est+tools_est)×1.2 > big_ctx_tokens` → big (hard). But if prompt exceeds big's context window, sending to big will fail upstream! Rule 3 says "if too big for big's window, go to big" — that's wrong. Logically, if the prompt exceeds big_ctx_tokens, it should go to flagship (which presumably has a larger window), not big. Unless flagship has smaller window... The spec says "flagship 窗口由部署者保证 ≥ big" (rule 2 note). So if prompt > big_ctx_tokens, big can't handle it; flagship should. This is a real correctness bug: oversized requests routed to big will get upstream 400s. Wait — re-read: rule 3 sends to big when prompt×1.2 > big_ctx_tokens. Since big_ctx_tokens is big's total window, this means the prompt alone already exceeds the window — routing to big guarantees failure. Should be flagship. This is a genuine defect.

2. **Marker priority vs multimodal**: rule 1 has_multimodal → flagship; rule 2 marker → flagship. Both to flagship, fine.

3. **Cache written only on judge reply path**: In §6.2 diagram, "命中缓存写回" — the cache writeback happens on {Ref, Tier} path. Fine.

4. **Negative cache key issue**: negative cache uses same structure with Tier = neg. But if the request was previously cache-hit with tier=big, then judge fails later... Actually neg cache write overwrites decision cache entry for same key? A request that failed judge writes neg entry, overwriting possibly valid cached tier. Actually can a request have both? If decision cache hits, judge is never called, so no failure. If cache misses, judge called, fails → neg written. No conflict per-request. But: if judge call fails for request A with key K, neg entry for K (30s). Later judge recovers; a different request with same key K gets neg hit → default_tier even though judge is fine. That's the intended sticky semantics, fine.

5. **Rule 5 `prompt_est < fast_ctx_tokens` — doesn't include tools or max_out**: `not has_tools` already, but est could exceed fast window due to max_out=4096 default + prompt near fast_ctx. E.g., fast_ctx_tokens=8000, prompt_est=7900, max_out=4096 → est_total=11900 > 8000. Routed to fast, upstream rejects or truncates. Rule 5 should compare est_total (or prompt+max_out×margin) against fast_ctx_tokens. This is a real defect: rule 5 only checks prompt_est < fast_ctx_tokens ignoring output budget. Similarly rule 3 checks prompt+tools against big window but ignores max_out — prompt could be under threshold but prompt+max_out > big window → routed into judgment zone, possibly to big, overflow. Actually rule 3 only routes to big; if under, goes to judgment zone where judge might pick big with insufficient window. The margin semantics inconsistent. At minimum rule 5 is buggy: msg_count ≤ 3 and prompt < 8000 but max_out default 4096 could overflow an 8k window model. This is a genuine correctness issue.

6. **Cache key collision → cross-tier contamination**: phash2 with 2^28, 4096 entries, collision ~3e-5 claimed — that's per-pair birthday? With 4096 entries, expected collisions ≈ 4096²/(2·2^28) ≈ 0.03, so ~3% chance of at least one collision... Actually 16.7M/268M ≈ 0.062 → ~6% probability of at least one colliding pair. And 2^28 = 268M; 4096²/2 = 8.4M; 8.4M/268M ≈ 0.031 → ~3% chance. A collision causes a wrong tier from a different request — cost/capability impact but bounded. They call it "accepted" design choice. It's disclosed, so not a defect per their criteria? The spec says "这是设计选择而非缺陷". I'll skip or mention lightly. Actually stated probability ~3e-5 is per pair? Eh. Could flag the probability math is understated but they "accept" it — impact is wrong tier occasionally, cost only. Low priority, maybe mention.

7. **Cache key includes HasMM but rule gate handles multimodal before cache — fine, defensive.**

8. **Cache key uses SysPrefix of all system messages — fine.**

9. **Negative cache and decision cache share the same table/key space — a neg entry (30s) then judge recovers and succeeds for same key: writes decision entry. Fine.**

10. **Stampede / concurrent judge for same key**: multiple concurrent identical requests all miss cache and all invoke judge — no single-flight. With judge_max_inflight=8, a burst of identical requests consumes inflight slots. Usability/cost issue; worth flagging as improvement (single-flight). Moderate.

11. **judge_timeout kill: exit(Pid, kill) but gun connection — owner death cleanup, ok. But `demonitor` after kill: they demonitor [flush] after exit kill — DOWN may not have arrived yet; flush only removes already-queued messages. After demonitor, no more DOWN delivered — monitor removed. OK since demonitor before receive ends... Actually sequence: after timeout → exit(Pid,kill), demonitor(MonRef,[flush]). demonitor removes monitor so no future DOWN. Fine. But there's a race: {Ref, Tier} message could arrive after timeout branch entered — it stays in caller mailbox! The worker might send {Ref, Tier} just as caller times out; caller does exit kill + demonitor flush, but the {Ref, Tier} message is in the mailbox and never flushed → mailbox leak (N1 claimed fixed but only DOWN flushed, not the late {Ref,Tier} reply). exit(Pid,kill) — if the message was already sent before kill, it remains in caller's mailbox. This is a real mailbox leak in timeout path! The fix: after timeout, also flush {Ref, _} messages. This is a genuine N1 residual defect. Good catch.

12. **Rule 4 max_ctx_tokens ordering**: rule 3 routes >big window to big (hard) before rule 4 checks max_ctx. If max_ctx_tokens configured and request between big_ctx and max_ctx, rule 3 fires → big → fails upstream. Should check rule 4 first, and rule 3 should target flagship. Same root issue as #1.

13. **Rule 3 hard no-downgrade to big when big unavailable**: fine per N2.

14. **`est_total` for rule 4 only — fine.**

15. **prompt_est non-ASCII ×1.5: CJK chars ~1 token/char, ×1.5 overestimates CJK. Conservative, fine.**

16. **marker word boundary for ASCII: "don't think harder"反例 in tests — they intend negation detection? Test says marker word boundary ("don't think harder" 反例) — meaning should NOT hit? "think harder" substring in "don't think harder" — word boundary matching would still match "think harder". The 反例 suggests they want it not to match, but the spec has no negation handling. Spec ambiguity: test expects non-match but rule says substring/词边界 match → would match. Inconsistency between spec §4.1 and test plan §11. Flag as ambiguity/defect. Actually maybe 反例 means test ensures boundary match works (e.g., "ultrathink" in "ultrathinker" shouldn't match). "don't think harder" — hmm, it contains "think harder" at word boundaries, so it matches per spec. If test expects no match, contradiction. Worth flagging as spec/test inconsistency.

17. **Signal量 atomics global — but "全局 judge in-flight" per node; multi-node — fine.**

18. **Cache stats: negative cache counts? fine.**

19. **judge parse: last non-empty line, first whitelisted word — "not flagship, big"反例: last line "not flagship, big" → first whitelist word = flagship (wrong, intent was big). Test lists this as 反例 — but per spec rule, first word on last line = flagship. So spec behavior conflicts with intent? The spec explicitly says "取该行首个命中白名单的词" — so "not flagship, big" → flagship. The test plan lists it as a 反例 presumably documenting that behavior. OK, disclosed.

20. **tier resolution: "catalog 中在售且 LB 可选的首个" — hard档 candidates ordered list; fine.**

21. **404 vs 400: no_route → 404. est_total > max_ctx → 400. fine.**

22. **Cache expiry check during sweep: "从辅表头部取出条目检查过期并双表删除" — sweep when capacity >4096 removes oldest 128 regardless of expiry? "取出条目检查过期并双表删除" — ambiguous: does it delete only expired, or delete oldest to enforce capacity? If only expired ones deleted, capacity could stay >4096 with live entries. Ambiguity in sweep semantics. Minor.

23. **msg_count includes system — fine.**

24. **default_tier configured but its tier list empty → soft fails → no_route. fine.**

25. **启动校验 "整档为空且可能被规则命中 ⇒ error" — but rules-only with default_tier empty → startup error only, runtime no_route. fine.**

26. **judge_model equals virtual name ⇒ 视为未配置 → rules-only. fine.**

27. **Self-reference via tier candidates = virtual name handled. good.**

28. **phash2 stability across node restarts — phash2 is stable for same term within a VM version; across upgrades may change — cache is ephemeral, fine.**

29. **Concurrency: cache write on judge success uses {Hash=>{Tier,Exp}} — race between neg write and success write; bounded, fine.**

30. **负缓存 key: same key as decision cache — but负缓存 written on failure of judge for a *specific* request; the negative is about judge health, not request content. Using content key means judge outage creates scattered neg entries across keys, each 30s — doesn't really suppress judge calls for *other* requests; breaker does that (5连败→60s). Negative cache per-content-key has weak effect: same retry within 30s suppressed — that's "重试粘性" intent. OK.

But subtle: negative cache hit → default_tier "soft" — fine.

31. **硬结论规则3的目标档 big：如果 big_ctx_tokens 实际语义是"big 档模型的总窗口"，超出即不可服务 → 应路由 flagship 或 400。再次确认这是核心缺陷。**

Also rule ordering: rule 4 (max_ctx check) after rule 3 — request exceeding both gets routed to big (rule 3) instead of 400. Rule 4 never reached for those. Defect: rule 4 should be before rule 3, or rule 3 target flagship.

32. **Rule 5 doesn't consider max_out as noted.** fast_ctx 8000, prompt 7000, max_out default 4096 → total 11000 > 8000 window. Defect.

Similarly rule 3's threshold uses prompt+tools only vs total window semantic — mixing semantics: big_ctx_tokens is total window but compared only to prompt+tools ×1.2 without max_out. prompt 50000 (<60000/1.2=50000 boundary), max_out 4096 → 54k < 60k OK. But prompt 49k, tools 0, max_out 16000 → est_total 65k > 60k window → goes judgment zone, judge might pick big → overflow. Inconsistent margin semantics (they fixed N6 double-counting but introduced window-semantics mismatch). The real fix: compare est_total against windows. Flag as one item combining rule 3/5 threshold semantic issues.

33. **Mailbox leak on timeout path (late {Ref,Tier}) — N1 residual.** Also on success path demonitor flush ok. Also spawn_monitor worker sending {Ref,Tier}: worker process dies after sending — DOWN flushed. OK.

Also: caller is HTTP handler process; late {Ref, Tier} with unique ref sits in mailbox forever (handler process may be long-lived? typically request process dies after response — leak bounded by process lifetime; if connection process reused (keep-alive handler), could accumulate). Still a defect to note: should flush {Ref,_} on timeout path.

34. **No single-flight / request coalescing — improvement suggestion.**

35. **marker on 末条 user 消息 only — fine, defined.**

36. **Cache key truncated prefixes: two different requests sharing first 1200 chars but diverging later get same tier — disclosed design.**

37. **judge input injection: quoted delimiters — ok.**

38. **Time units: ExpiresAt using monotonic? unspecified — minor; skip.**

39. **Sweep: ordered_set seq via atomic increment — on node restart resets; ETS ephemeral, fine. But Seq overflow — no.**

40. **stats/0 counters — fine.**

41. **"规则 3 hard 不降级": big unavailable → 404 even though flagship could serve. Hmm: rule 3 target big; if big tier unconfigured → no_route 404. But flagship (mandated ≥ big window) could serve it. Hard no-downgrade across tiers — but "upgrading" to flagship for capacity is safe. The N2 fix disallows fallback to default_tier (fast, smaller) — correct; but disallowing flagship for rule 3 causes availability loss. Given rule 3's target should be flagship anyway (item 1), this folds in.

42. **404 for hard unavailability vs 503 semantics — 404 odd but documented; skip.**

43. **Rules 1/2 target flagship; flagship empty → startup error + runtime 404. fine.**

44. **Judget timeout default 1500ms — adds latency on path; breaker/negcache mitigate. ok.**

45. **Cache TTL 300s decision stickiness: if judge was wrong for a content class, 300s of misrouting — cost only.**

Now prioritize:

**A. Defects (max 5):**

A1. Timeout path mailbox leak: late {Ref, Tier} not flushed (N1 residual). 
A2. Rule 3 routes oversized requests to big (target should be flagship), and rule 4 unreachable for requests > big window (ordering) — capacity correctness.
A3. Rule 5 window check ignores max_out/tools semantics — can route to fast when est_total exceeds fast window (fast_ctx_tokens is total window but compared to prompt only). Also rule 3 compares prompt+tools to total-window threshold without max_out — semantic mismatch.
A4. Cache sweep semantics ambiguous: "检查过期并双表删除" — if only expired deleted, capacity bound not enforced (live entries accumulate >4096 indefinitely... actually capacity check triggers sweep each write; if entries not expired and sweep deletes nothing, table grows unbounded? It processes oldest 128 and deletes only if expired → live old entries stay, size stays >4096, each subsequent write re-scans same 128 oldest — O(128) still but unbounded growth). Real defect/ambiguity.
A5. Spec/test inconsistency: "don't think harder" negation case — spec's substring/word-boundary match will hit; test expects 反例 non-match. Either spec needs negation handling or test wrong. Also marker case: CJK direct substring ok.

**B. Missed edge cases (max 5):**

B1. Concurrent identical requests: no single-flight → judge inflight slots consumed by duplicates; consider per-key in-flight dedup.
B2. phash2 collision probability misstated: with 4096 entries, P(≥1 collision) ≈ 3% (birthday), not 3e-5; collision yields wrong tier (cost). Accept but document correctly or enlarge hash domain/verify full key.
B3. messages with content as plain string vs parts; empty messages array; last message not user role (assistant prefill) — LastUserPrefix falls back to last user msg, defined? "末条 user 消息" — if none (all assistant), empty. Edge: no user message → features fine? msg_count etc. OK mention briefly.
B4. max_tokens: 0 or negative values; max_completion_tokens non-integer — startup validation covers config, but request-level fields unvalidated (garbage max_out skews est_total; e.g., max_tokens=10^9 → est_total huge → rule 3 → big... or with max_ctx configured → 400). Client-controlled max_tokens can force tier: attacker sets huge max_tokens to force big/flagship? Actually huge max_tokens → est_total > big threshold? Rule 3 uses prompt+tools only, so max_tokens doesn't affect rule 3. It affects est_total → rule 4 (400) only. And rule 5 uses prompt only. So max_tokens doesn't influence tier except 400. Hmm, so no tier manipulation via max_tokens. OK skip.
B5. Cache key doesn't include model-independent judge_model — cache shared across judge_model changes; breaker resets per model but decision cache from old judge persists 300s. Minor.
B6. judge worker crash before sending {Ref,Tier} → DOWN path fine. Caller itself dies (client disconnect) → worker lingers until reply/timeout, gun connection cleaned on worker exit. ok.
B7. Multi-node: fine, disclosed.

Also: negative cache uses same Hash space; a neg entry overwritten by decision entry and vice versa — fine.

Edge: `msg_count ≤ 3` includes system — fine.

Edge: 流式请求 stream:true — judge 调用 stream:false ok; main request streaming unaffected. fine.

Edge: marker in multimodal user message text parts — marker_hit computed on text parts; rule 1 fires first anyway.

Edge: 启动校验 cached by config fingerprint; hot config change of tiers while requests in flight — transient; skip.

**C. Improvements (max 5):**

C1. Fix timeout path: `receive {Ref,_} -> ok after 0 -> ok end` flush after kill (or use selective receive with flush).
C2. Rule gate restructure: rule 4 (max_ctx 400) first; rule 3 target flagship; rule 3/5 compare est_total (or prompt+tools+max_out×margin) against
