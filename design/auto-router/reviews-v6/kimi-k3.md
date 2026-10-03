# Review v2.4 by kimi-k3 (k3)

_75.4s · completion_tokens=4000_

Let me carefully review v2.4. The claims: positive/negative cache split keyspace, max_out in key and judge input, rule 4 total window semantics. Review for remaining defects.

Let me go through carefully.

**Cache keyspace issue**: The key is `{pos, Hash}` / `{neg, Hash}`. But the negative cache value is "Tier 记为 neg" in §6.2, while §5 says split keyspace. Fine, consistent enough.

Wait — a real issue: negative cache now shares the same key Hash, and positive entry shadows negative. But the negative cache TTL is 30s. The read order: positive first, then negative. OK.

**Key Hash includes max_out_bucket and prompt_est_bucket but the negative cache is "失败特征"** — negative cache keyed by same hash. That's fine.

**Issue A1: marker_hit case — marker rule 2 goes to flagship hard, but the cache key subset.** Fine.

**Potential issue: `prompt_est div 4096` bucket and `max_out div 4096`** — the judge input "Output budget: <=2k / <=8k / >8k" uses different bucketing (2k/8k thresholds) than the cache key's `max_out div 4096` (4k buckets). So two requests with the same judge input (e.g., max_out 5000 vs 7000, both "<=8k") would get different cache keys — that's just cache misses, no correctness issue. Conversely, same bucket div 4096 → same key, and judge input same line — consistent. Not a defect, maybe a note. Actually wait: max_out 4000 vs 8000 → buckets 0 vs 1, different keys, judge input both "<=8k" — same input, different keys, harmless. max_out 2000 vs 3000 → bucket 0 both, judge input "<=2k" vs "<=8k"? 3000 > 2048 so "<=8k". Same key, different judge input! So two requests with same cache key would hit judge with different inputs, but the cached decision from the first is reused for the second. This is within the "子集摘要" design choice already acknowledged. So not a defect per their stated design.

**Real issue: rule 3b vs rule 2 priority.** Rule 2 (marker) → flagship. Rule 3b est_total > big_ctx → flagship. Both flagship. Rule 3 → big hard. Rule 3b comes after rule 3. Order fine.

**Rule 3 and rule 3b interaction**: Rule 3: (prompt+tools)*1.2 > big_ctx → big. But if prompt+tools*1.2 > big_ctx, then est_total > big_ctx likely too (since est_total ≥ prompt+tools+4096... actually est_total = prompt + media + tools + max_out, max_out ≥ ... well max_out could be 0? max_out defaults 4096 if not given; if user gives max_tokens=0? Edge). If both rule 3 and rule 3b could trigger, rule 3 first → big. But wait — if (prompt+tools)*1.2 > big_ctx, the request's prompt+tools alone exceeds big window by 20%, plus output — it would overflow big's window! Sending to big is wrong; should be flagship. Rule 3 is checked BEFORE 3b, so such requests go to big even though they can't fit. Hmm, but is that realistic? rule 3 says prompt*1.2 > big_ctx means prompt > big_ctx/1.2 ≈ 0.83 * big_ctx. Then est_total = prompt + max_out ≥ 0.83*big_ctx + max_out. With max_out default 4096 and big_ctx 60000: 0.83*60000=50000, +4096 = 54096 < 60000. So fits within big. Actually rule 3's threshold with 1.2 margin implies prompt fits in big with room. est_total = prompt + max_out; prompt ≤ big_ctx/1.2 means prompt*1.2 > big_ctx boundary... hmm the condition is prompt*1.2 > big_ctx, i.e., prompt > 0.833*big_ctx. est_total = prompt + media + tools + max_out could exceed big_ctx when prompt is just above 0.833 big_ctx and max_out is large. E.g., big_ctx=60000, prompt=51000 (51000*1.2=61200>60000 → rule 3 fires → big), max_out=20000 → est_total=71000 > 60000. Rule 3 fires first, routes to big, but total exceeds big's window → upstream overflow error. This is a genuine ordering defect: rule 3b should be checked before rule 3, or rule 3's target should also be gated by est_total. Actually the fix: check 3b before 3. If est_total > big_ctx → flagship; else if prompt*1.2 > big_ctx → big. Since est_total > big_ctx whenever prompt alone > big_ctx... no wait prompt*1.2 > big_ctx doesn't imply est_total > big_ctx. So reordering 3b before 3 would catch the overflow case and still send big when it fits. This is defect A1.

**max_out = 0 or negative**: user could set max_tokens = 0 or negative. est_total then lower; harmless. `max_completion_tokens ?? max_tokens ?? 4096` — in Erlang `??` undefined check. If max_completion_tokens present but null? Edge, ignore.

**Defect: negative cache and judge_model mismatch.** §5: value carries JudgeModel for positive entries, read-mismatch = miss. Negative entries written on failure — do they also carry judge model? §6.2 says negative cache Tier 记为 neg, and the config-switch race: worker carries snapshot model name; mismatch → drop writeback. So negative entries presumably also carry judge model? §5 says value `{Tier, JudgeModel, ExpiresAt}` for the decision cache generally. Probably fine.

**Defect candidate: negative cache on failure writes keyed by request hash — but failures are usually judge-level (provider down, timeout), not request-specific.** Negative caching per-request-hash means a judge outage produces negative entries scattered across keys; each new distinct request still attempts judge (until breaker kicks in at 5 consecutive failures). That's fine — breaker is the global guard. OK.

**But: positive entry shadows negative — after positive hit, negative never read. Fine.**

**Signal:** **Issue: cache read order with pos entry for a *different judge model*.** Positive entry with stale JudgeModel treated as miss → then check negative entry. Negative entry presumably also has JudgeModel — if neg entry from old judge, should also miss. Spec implies value carries JudgeModel generally. OK.

**Issue B: `marker_hit` on lowercase + word boundary for ASCII — "think harder" word boundary; fine.**

**Issue: Rule 0 with max_ctx_tokens configured but < big_ctx → ignored per startup validation. Then capacity defense is rules 3+3b. OK, documented.**

**Issue: features malformed input → pass → model_not_found 404.** But wait — janus-auto is a real row in models table. Pass means "按普通模型处理" — the model name IS in the models table (it's a normal row for /v1/models display), but has no routes. So pass → treated as ordinary model janus-auto → lookup routes → none → what error? Spec says "既有 model_not_found 404". Hmm, v2.3⑥ says "整体 pass → 模型未知 404". But the model is in the models table! So would it be model_not_found or no-route upstream error? §7 says virtual model has no routes; pass → presumably the proxy fails to find a route → some error. The spec claims model_not_found 404. If models-table lookup succeeds but route lookup fails, the existing behavior might be a different error. This is a minor consistency concern but they assert "既有 model_not_found 404" — depends on existing system. Could flag as B: clarify that pass-through of malformed requests yields route-not-found vs model-not-found discrepancy. Marginal.

**A more significant issue: rule 4's `est_total < fast_ctx_tokens` uses est_total which includes media_allowance — but multimodal requests already routed by rule 1. OK.**

**msg_count ≤ 3 with est_total — fine.**

**Judge worker: `exit(Pid, kill)` then `demonitor(MonRef, [flush])` — kill is async; DOWN message flushed. OK.**

**Gun one-shot connection per judge call — cost: TLS handshake per call adds latency to judge_timeout_ms 1500. Connection setup within the timeout? If connect itself exceeds timeout, counted failure. Not a spec defect, but perf/cost: opening a new connection per judge call under inflight 8 could be slow; timeout includes connect. This is a real usability concern but maybe acceptable. Could mention in C suggestions: consider a small pool or account connect time.**

**Defect candidate: negative cache + breaker interplay when judge succeeds but parse fails — counted failure, negative cached. Fine.**

**Defect: `est_total > max_ctx_tokens` rule 0 — but max_ctx ignored if < big_ctx; and rule 0 checked "先于一切路由规则" including name match? Name match first (①). Fine.**

**Cost issue: prompt_est buckets div 4096 — adjacent prompts differing slightly fall in same bucket; fine.**

**Now the shadowing issue: positive cache write "即自然遮蔽负条目" — but read order says "先查正条目，命中且未过期即用；仅当无有效正条目时才查负条目". Positive entry TTL 300s; negative 30s. After judge success, pos written. If pos expires at 300s but neg entry... neg expires 30s anyway. Fine.**

**Real defect: negative cache 30s skip → default_tier, and "不计失败" — but breaker still counting? breaker counts actual judge calls only. OK.**

**Potential defect: judge timeout kill — worker killed, but the caller then does failure path including negative cache write and consecutive-failure count. But §6.2 snapshot race: writeback carries snapshot model name. Fine.**

**B-type: `HasMM` in cache key "实际恒为 false" — multimodal goes hard flagship via rule 1, never reaches judge. OK defensive.**

**B-type: requests without user message → LastUserPrefix empty, judge input placeholder. Cache key for all such requests with same sys prefix/buckets shared — fine.**

**Edge: streaming requests (stream: true)? Router doesn't care; it rewrites model and passes through. est includes max_out default 4096 if unset. OK. Non-target: streaming transformation.**

**Edge: `max_completion_tokens` set to huge value (e.g., 1e9) — est_total huge → rule 0 400 if configured; else 3b → flagship; flagship upstream may reject. But that's user error; upstream 400. Not a defect per criteria? Deployer can set max_ctx. Hmm, with no max_ctx configured, malicious/absurd max_tokens routes to flagship — capacity defense says "至多到达 flagship 档" — but flagship window may be exceeded → upstream error, acceptable (zero-assumption principle). OK.**

**Edge: rules 3 threshold ×1.2 only on prompt+tools, not media — media handled by 3b. Fine.**

**Now check claimed fix ②: cache key max_out_bucket + judge input budget line — consistent. Judge input line bucketing (2k/8k) vs cache bucket (4096) mismatch noted above — under "子集摘要" acknowledged. Not count.**

**Check fix ①: pos/neg split. One subtlety: the aux ordered_set for eviction stores `{Seq, Hash}` — but now keys are `{pos, Hash}` / `{neg, Hash}` tuples; the main table key is `{pos|neg, Hash}`. The aux table must store the full main key including pos/neg tag: `{{Seq, {PosNeg, Hash}} => ok}`. Spec says `{{Seq, Hash} => ok}` — ambiguous whether Hash includes the tag. Minor implementation clarity, not a correctness defect if Seq ordering still works. Could mention as C: specify aux key stores full primary key. Probably worth a C-level note since eviction needs to delete from main table — needs full key. It's a spec ambiguity that could cause implementation bug. I'd count as B (遗漏的边界/规格歧义).**

**Another check: "容量 >4096 时从辅表头部取出条目检查过期并双表删除，单次至多 128 条" — if entries not expired, deleted anyway? "取出条目检查过期并双表删除" — ambiguous: does it delete regardless or only expired? Original design presumably LRU-ish eviction. If only expired ones deleted and none expired, table keeps growing beyond 4096. Ambiguity — B-level note.**

Hmm, previous rounds presumably settled this; it's FIFO eviction. The wording "检查过期并双表删除" is ambiguous. Mention as C.

**Bigger: prompt_est estimate for CJK ×1.5 per codepoint — fine.**

**A: rule ordering 3 vs 3b — solid defect.**

**A2 candidate: rule 4 est_total < fast_ctx with max_out default 4096: fast_ctx 8000 → prompt must be < ~3900. Fine, documented.**

**A3 candidate: negative cache TTL 30s but "失败特征写 30s TTL 条目（与决策缓存同结构，Tier 记为 neg）" vs §5 split keyspace — §6.2 still says "Tier 记为 neg", slightly stale wording from before split. Now neg is encoded in the key, not Tier. Minor inconsistency (wording) — could be C-level. Since value `{Tier, JudgeModel, ExpiresAt}` — for neg entries Tier field unused/neg. Fine, C.**

**A real one: judge fallback parse — takes first whitelist word in last non-empty line; if last line is "The answer is flagship" → "The" no... first word hitting whitelist: words: The, answer, is, flagship → flagship. OK.**

**Cost issue: per-judge-call one-shot gun connection + spawn per eligible request — under high traffic, requests skip via inflight 8 → default. Fine.**

**Availability: judge_timeout 1500ms adds latency to uncached requests in judge path — inherent.**

**Security: prompt injection into judge — mitigated via quotes; acknowledged.**

**B: `marker_hit` only checks last user message; multi-turn where earlier message contains marker — design choice.**

**B: cache key ignores msg_count and judge path also ignores conversation history beyond last user msg — design.**

**Now check §7 validation: "max_ctx_tokens 已配置但 < big_ctx_tokens ⇒ error + 忽略" — then rule 0 inactive. But what if max_ctx < fast_ctx? Covered since fast < big presumably. Not validated that fast_ctx < big_ctx! If deployer sets fast_ctx_tokens > big_ctx_tokens, rule 4 could route a request to fast whose est_total exceeds big but is under fast — fine actually, fast档 gets bigger requests; and rule 3/3b use big_ctx. If fast_ctx > big_ctx, rule 4 condition est_total < fast_ctx could include est_total > big_ctx — but rule 3b (checked before 4) sends those to flagship first. Order: 3b before 4, so est_total > big_ctx never reaches rule 4. OK so fast_ctx > big_ctx is safe. fast_ctx > max_ctx? Rule 0 first. OK.

**B: fast_ctx vs big_ctx ordering not validated but harmless as shown.**

**A4 candidate: Rule 3b says flagship "窗口由部署者保证 ≥ big" — but est_total could exceed flagship too; upstream error accepted (zero assumption). Documented.**

**Negative cache and judge timeout: after timeout, exit kill; worker may have partially... fine.**

**Another A: 决策缓存 value JudgeModel mismatch → miss; but then negative entry from same old judge also stale — check says neg entries presumably carry JudgeModel too (same value structure). Spec §5 says value `{Tier, JudgeModel, ExpiresAt}` — for the main decision cache. §6.2 negative "与决策缓存同结构". OK consistent.**

**A: cache key includes SysPrefix of ALL system messages concatenated first 256 chars — but judge input only uses "system 前 256 字符" — presumably same. OK.**

**Now B-level: `max_out` — `max_completion_tokens ?? max_tokens ?? 4096`. If both present, new name wins — fine. If max_completion_tokens = null (JSON null → maybe atom null, not undefined) — `??` on null wouldn't fall through; est uses null → crash → caught by try/catch → pass. Edge, minor. Eh.**

**B: audio/video parts — media_allowance flat 4096 for video may grossly underestimate; but rule 1 multimodal → flagship hard anyway, and rule 0 uses allowance only for the cap check. Video underestimation → est_total under max_ctx → routes flagship → upstream handles. Acceptable per zero-assumption. Not count.**

**C suggestions:**
1. Reorder rule 3b before rule 3 (this is the fix for A1).
2. Clarify aux table stores full primary key `{pos|neg, Hash}`.
3. Clarify eviction semantics (delete vs only-if-expired).
4. Align §6.2 "Tier 记为 neg" wording with keyspace split.
5. Consider connection reuse/warm pool for judge or document per-call TLS overhead within timeout budget.

Also maybe: unvalidated relation fast_ctx > big_ctx harmless — skip.

**One more potential defect: rule 4 "定向 hard / 可用性 soft" — fast unavailable → default_tier. But if default_tier == fast (default config!), then fallback retries fast again → no_route. default_tier default is fast. If fast tier empty and rule 4 hits: hard target fast → unavailable → soft fallback default_tier=fast → same empty tier → no_route → 404. Meanwhile the request was tiny and big/flagship might be available. Is that a defect? The soft fallback semantics (§7 tier 解析 2): "全部不可用 → default_tier 档再试一次；仍不可用 → no_route". If default_tier == the failed tier, retry is a no-op. Should fallback skip the already-tried tier or try remaining tiers? For rule 4 with default config, a short request gets 404 despite big/flagship being configured. Deployer error partially (
