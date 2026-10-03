# Review v2.4 by glm-5.3 (glm-5.3)

_66.8s · completion_tokens=4000_

Let me carefully review this design spec v2.4 for the Janus Auto Router. This is the 6th round of review. The previous rounds fixed:
- Round 5 fixes claimed: positive/negative cache key separation, max_out in cache key and judge input, rule 4 total window semantics annotation
- Round 4 fixes: rule 3b (est_total > big_ctx_tokens → flagship), rule 4 fast availability soft, media_allowance in est_total, cache value carries judge_model, 400 response body definition, malformed messages → pass, max_ctx_tokens capacity defense line

Let me go through the spec carefully looking for:
A. Remaining defects or newly introduced issues in v2.4
B. Missing edge cases
C. Concrete actionable improvements

Criteria: only issues affecting correctness, security, availability, cost count as defects. Style preferences, wording, hypothetical extreme scenarios don't count.

Let me analyze section by section.

## Section 3: Request pipeline

- Rule gate → judge zone. Rules conclusions never read/write cache. Rule 0's limit check precedes all routing.
- Judge zone: no judge → default_tier (soft); breaker → default_tier; inflight full → default_tier; negative cache hit (30s) → default_tier; decision cache hit (300s) → tier (soft); judge call → tier (soft); failure → default_tier.

Wait — one thing to check: in the judge zone, negative cache is checked before decision cache. Section 5 says: read order: first check positive entry, hit and not expired → use; only when no valid positive entry, check negative entry. But section 3 pipeline lists "负缓存命中（30s）→ default_tier" before "决策缓存命中（300s）→ tier". Hmm, this is a potential ordering inconsistency between §3 and §5. In §3, the pipeline shows negative cache check before decision cache check. In §5, it says read positive first, then negative. These two orderings produce the same behavior only when they don't both hit. Actually, if positive entry exists and valid, §5 uses it. If §3 checks negative first and it hits (within 30s), it goes default_tier even if positive entry exists.

With the pos/neg key separation fix (v2.4 change ①), judge success writes positive entry which "naturally shadows" the negative entry. But shadowing in the sense that read order checks positive first. If §3's pipeline order is literal (negative first), then a request that: judge failed at T=0 (negative entry written, expires T=30), judge succeeded earlier at T=-100 (positive entry valid until T=200)... wait, but can that happen? The hash is the same key. Sequence: T=-100 judge success → pos entry until T=200. T=0 judge fails (why would judge be called if pos entry valid? Because pos entry read happens at request time...). Hmm, actually if the pos entry is valid, the request wouldn't reach judge at all. So the negative entry would only be written when there was no valid pos entry. So coexistence of valid pos + valid neg for the same hash: after a failure writes neg at T=0, a success at T=5 writes pos. Now both exist: neg until T=30, pos until T=305. A request at T=10: §5 order → pos hit → tier. §3 order → neg hit → default_tier. These differ!

But wait — can a success happen at T=5 if the negative cache hit at T<5 causes default_tier without calling judge? Yes: requests at T=1, 2 hit negative cache → default_tier, no judge call. But requests arriving between T=0 and T=30... all hit negative cache. So no judge call until T=30. Unless — the negative cache is per-hash, and other hashes also fail. For the same hash, after failure, no judge calls for 30s. So the success at T=5 scenario can't happen for the same hash. Hmm, unless concurrency: two concurrent requests both miss cache, both call judge, one fails (writes neg), one succeeds (writes pos). Then both entries exist. Read order then matters: §5 says positive first → tier; §3 diagram says negative first → default_tier.

Is this a real defect? It's an internal inconsistency between §3 and §5 that manifests only under concurrent racing judge calls on the same hash. Impact: one request gets default_tier instead of the judge-decided tier for up to 30s. That's a cost/quality minor blip. Is this "影响正确性、可用性、成本"? Marginally — a request routed to default_tier instead of the correct tier for 30s. It's a documentation inconsistency that could lead to implementation bugs. Given the strictness required ("假想的极端场景不计"), concurrent judge calls on the same hash are plausible (two identical requests arriving simultaneously, both miss cache). Actually wait, do concurrent requests to the same hash both call judge? There's no request coalescing mentioned — yes, both would call judge. This is a realistic scenario (user retries, parallel requests). So the §3 vs §5 read-order inconsistency is a genuine spec bug worth flagging. Severity: low-medium. It should be flagged as A (inconsistency introduced/exposed by the v2.4 pos/neg separation fix, since before the fix they shared a key and order didn't matter).

Let me double check §3: "④ 判分区（仅规则未决的请求进入）：... ├─ 负缓存命中（30s）→ default_tier（soft）├─ 决策缓存命中（300s）→ tier（soft）". Yes, negative before positive. §5: "读取顺序：先查正条目，命中且未过期即用；仅当无有效正条目时才查负条目". So the two sections contradict. One of them needs fixing — §5's order is the correct one (pos shadows neg). This is a legit finding.

## Section 4.1: features

- prompt_est: ASCII bytes ÷ 4; all other code points × 1.5.
- media_allowance: non-text parts × media_token_allowance (default 4096).
- tools_est: JSON bytes ÷ 4.
- max_out: max_completion_tokens ?? max_tokens ?? 4096.
- est_total = prompt_est + media_allowance + tools_est + max_out.

Question: negative or zero max_tokens? If client sends max_tokens: 0 or negative, bucket = 0 div 4096 = 0, est_total uses max_out = 0 or negative → could undercount. But providers reject invalid max_tokens anyway; and this only affects routing estimate. Minor. Also max_tokens could be huge (e.g., 100000) → est_total large → rule 3b flagship or rule 0 400. That's arguably correct behavior. Not a defect.

What about `n` parameter (multiple completions)? OpenAI n>1 multiplies output. Rare for chat completions; ignore. Not a defect per the criteria.

has_multimodal detection: any message content parts with type non-text. Includes type "text" only as text. What about content as string? Handled: content binary or part list.

marker_hit: last user message text, lowercase both, word boundary for ASCII, substring for CJK. Fine.

msg_count: messages array length. Fine.

Input robustness: features/1 validates messages is a list of maps, content binary or part list; else maybe_route returns pass → model_not_found 404. Hmm wait — is returning 404 for a malformed request to the virtual model the right behavior? The virtual model exists in the models table. A request with model="janus-auto" but malformed messages returns model_not_found 404? That's semantically odd — the model was found; the request body is malformed. OpenAI would return 400 invalid_request_error. The spec says pass → treated as normal model → since janus-auto is a models-table row without routes... wait, "虚拟模型是 models 表普通一行（仅用于 /v1/models 展示），无自身 routes（修 A8）". So pass on janus-auto → proxy chain → no routes → model_not_found-ish 404? Hmm, actually if the model row exists but no routes, what does the proxy do? Probably 404 or some "no upstream" error. The spec says "返回既有 model_not_found 404，不会透传给上游". The error message would be misleading (model not found when actually the body is malformed), but is that a correctness issue? It's an API-semantics issue: 404 model_not_found for a malformed body is wrong status semantics (should be 400). But the spec explicitly chose this (六轮防畸形) — it's a deliberate tradeoff documented. Hmm, but is it a defect? A client sending malformed messages gets "model not found" for a model that's in /v1/models. That's confusing but it's availability-neutral, security-neutral, cost-neutral. It's an API correctness nit. The instruction says only correctness/security/availability/cost issues count. Misleading error semantics for malformed input... borderline. I'd rate it low priority; maybe mention in B or C briefly. Actually wait — there's a subtlety: unconfigured auto_router → pass → model_not_found? No — if auto_router is unconfigured, maybe_route passes, and the request goes to proxy with model janus-auto which has no routes → 404. That's correct behavior (virtual model unconfigured). But for configured router with malformed messages, same 404. The distinction is documented. Fine, minor.

## Section 4.2: rules

Rule 0: est_total > max_ctx_tokens → 400. Hard. Precedes everything.

Rule 1: has_multimodal → flagship. Hard.

Rule 2: marker_hit → flagship. Hard.

Rule 3: (prompt_est + tools_est) × 1.2 > big_ctx_tokens → big. Hard.

Rule 3b: est_total > big_ctx_tokens → flagship. Hard.

Rule 4: not has_tools and est_total < fast_ctx_tokens and msg_count ≤ 3 → fast. Directed hard / availability soft.

Rule 5: else → judge zone. Soft.

Interaction check: Rule 3 vs 3b ordering. Rule 3 sends to big when prompt+tools ×1.2 > big_ctx. But what if est_total > big_ctx_tokens too (3b condition)? Rule 3 fires first → big. But est_total > big_ctx_tokens means the request might exceed big's window (est includes max_out). If rule 3 routes to big but the request actually exceeds big's total window, upstream big model will fail with context overflow. Rule 3b exists precisely to catch that — but rule 3 is checked first! Let's verify: Rule 3 condition: (prompt+tools)×1.2 > big_ctx. Rule 3b: est_total > big_ctx. If both hold, rule 3 wins → big. But est_total > big_ctx means the total (incl. max_out) exceeds big's total window — routing to big is wrong; should be flagship (3b). The ordering 3 before 3b defeats 3b whenever both conditions hold.

Wait, let me think again. If (prompt+tools)×1.2 > big_ctx, then since est_total = prompt+tools+media+max_out ≥ prompt+tools... is (prompt+tools)×1.2 > big_ctx implying est_total vs big_ctx? Not necessarily: ×1.2 amplification. E.g., prompt+tools = 55000, big_ctx = 60000: 55000×1.2 = 66000 > 60000 → rule 3 fires → big. est_total = 55000 + media 0 + max_out 4096 = 59096 < 60000 → 3b doesn't fire. OK so in this case rule 3's margin already covers output. Rule 3 has ×1.2 headroom for output (deliberately: ×1.2 applies to prompt+tools to leave room for output — the comment says "余量 ×1.2 只乘 prompt+tools，不乘 max_out（修 N6 双重放大）"... wait, that's about rule 3's own margin).

Hmm wait, actually let me reconsider. Rule 3: (prompt_est + tools_est) × 1.2 > big_ctx_tokens → big. When does 3 fire but 3b not? When est_total ≤ big_ctx but amplified prompt+tools > big_ctx. Since est_total = prompt+tools+max_out+media, and rule 3 amplifies by 1.2: rule 3 fires with est_total ≤ big_ctx requires prompt+tools > big_ctx/1.2 and prompt+tools+max_out+media ≤ big_ctx. E.g., big_ctx=60000: prompt+tools in (50000, 60000), plus max_out+media ≤ 60000−(prompt+tools). Possible: prompt+tools=51000, max_out=8000, est_total=59000 ≤ 60000. Rule 3 fires → big. est_total 59000 < 60000 window. Fine, fits.

Conversely, when does 3b fire but 3 not? prompt+tools ≤ big_ctx/1.2 = 50000, but est_total > 60000 — means max_out+media > 60000−50000 = 10000. E.g., max_tokens=60000. Then 3b → flagship. Good.

When do BOTH fire? prompt+tools > 50000 AND est_total > 60000. E.g., prompt+tools = 55000, max_out = 8000 → est_total = 63000 > 60000. Both fire. Rule order: 3 first → big. But est_total 63000 > big's 60000 window → request may overflow big model (assuming big_ctx_tokens accurately reflects the smallest big candidate's window). The request would fail upstream with context-length error. Should go flagship per 3b's intent.

Hold on — is that right? Let me re-read: "规则 3b：est_total > big_ctx_tokens → flagship——含 max_out 的总量超 big 档总窗时上旗舰（修四轮：max_out 溢出 big 窗口）". Yes, 3b's entire purpose is to catch requests whose total exceeds big's window. But with rule 3 evaluated first, any request where prompt+tools alone (×1.2) exceeds big_ctx goes to big regardless of est_total. The overlap region: prompt+tools ∈ (big_ctx/1.2, ...) and est_total > big_ctx. In that region, request routed to big with est_total > big_ctx → potential overflow.

Wait, but does ×1.2 headroom make this safe? Rule 3's ×1.2 is a safety margin (20% headroom over prompt+tools, intended to cover output). If prompt+tools = 55000 and the estimate is rough (ASCII ÷4 heuristic, CJK ×1.5), the actual prompt could be larger than estimated. The ×1.2 margin protects against estimation error. In the overlap case, est_total (with default max_out 4096 or explicit max_tokens) exceeds big_ctx, so the request genuinely doesn't fit (if max_tokens is honored by provider as reserved... actually most providers don't reserve max_tokens; a request with prompt 55000 + max_tokens 8000 against a 60000-window model will succeed as long as actual generation fits; providers validate prompt + max_tokens > context only for some providers... hmm).

Hmm, this is provider-dependent: many providers validate prompt_tokens + max_output ≤ context_window (Anthropic does; OpenAI historically errors if max_tokens exceeds remaining? OpenAI errors when prompt+max_tokens > context limit for completions; for chat completions OpenAI errors if prompt > context, and truncates/errs on generation overflow at runtime). The spec's model is "total window" semantics, and 3b was added in round 4 specifically because max_out overflow of big window was deemed a defect. So by the spec's own standard, the overlap region is mishandled: rule 3 takes precedence over 3b in exactly the cases 3b was created for.

Fix: reorder 3b before 3 (check est_total > big_ctx first → flagship; else check rule 3 → big). Since 3b → flagship is strictly "safer" (flagship window ≥ big guaranteed by deployer), firing 3b first is safe. So the ordering 3 → 3b is a genuine defect. Let me double-check the table: rows in order 0,1,2,3,3b,4,5 — "优先级自上而下". Yes, 3 before 3b. Defect confirmed.

Hmm wait, let me reconsider once more. Is it possible the authors intended rule 3's ×1.2 to be the margin such that if rule 3 fires, the deployment expects big to still handle it? The ×1.2 is applied to prompt+tools only. In overlap: prompt+tools=55000 (amplified 66000 > 60000). est_total=63000. If big model window = 60000, request needs prompt 55000 + output up to 8000 = 63000 > 60000. Providers that enforce prompt+max_tokens ≤ window will reject. So yes, 3b must fire first. Defect A1 (high priority — correctness of routing/capacity protection).

Actually, wait. Let me reconsider whether rule 3 even should exist independently. Rule 3 without media/max_out: (prompt+tools)×1.2 > big_ctx → big. With est semantics, est_total = prompt+tools+max_out+media. If we want "fits in big", condition should be est_total ≤ big_ctx. Rule 3 is essentially "prompt+tools alone nearly fills big window → big". Both 3 and 3b route upward; 3b routes higher. The correct composition: if est_total > big_ctx → flagship (3b); elif (prompt+tools)×1.2 > big_ctx → big (3); the amplification margin in 3 handles estimation error pushing near-window prompts up. So yes, swap order. Good finding.

## Rule 4 analysis

Rule 4: not has_tools and est_total < fast_ctx_tokens and msg_count ≤ 3 → fast. est_total includes max_out. fast_ctx = 800
