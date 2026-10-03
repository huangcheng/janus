# Review v2.2 by kimi-k3 (k3)

_113.5s · completion_tokens=4003_

Let me carefully review v2.2 for remaining defects.

Let me walk through the rules:

Rule 0: est_total > max_ctx_tokens → 400. Only when configured, and validated ≥ big_ctx_tokens.

Rule 3: (prompt_est + tools_est) × 1.2 > big_ctx_tokens → big. Note: big_ctx_tokens semantics is "总窗口" (prompt+tools+output). But rule 3 compares prompt+tools × 1.2 against the total window, not est_total × 1.2. If prompt+tools = big_ctx_tokens/1.2 ≈ 0.833×big_ctx, and max_out = 4096, est_total could be less than big_ctx_tokens — OK. But consider: prompt+tools × 1.2 ≤ big_ctx_tokens, so not routed to big by rule 3; but est_total = prompt+tools+max_out could still exceed big_ctx_tokens (since max_out up to 4096, or actually max_out can be arbitrarily large — client could set max_tokens = 50000). Then request goes to judging zone, might get routed to big tier whose window is big_ctx_tokens — overflow! Wait: rule 3 only catches prompt+tools > big_ctx/1.2. But a request with prompt+tools just under the threshold and huge max_out could exceed big's total window. The 1.2 margin is supposed to cover max_out: 1.2 factor means margin = 0.2×(prompt+tools) ≥ max_out? Not guaranteed — max_out default 4096 but configurable by client arbitrarily. E.g., big_ctx=60000, prompt=40000, max_out=20000: 40000×1.2=48000 ≤ 60000 → not rule 3; est_total=60000... borderline. prompt=45000, max_out=20000: 54000≤60000, est_total=65000 > 60000 → exceeds big window but goes to judging zone, could be routed to big. So rule 3 doesn't fully protect big tier window when max_out is large. This is a real defect: est_total should be compared for the big rule too, or max_out should be capped. Actually v2.1→v2.2 fix ② changed rule 5→4 to est_total < fast_ctx_tokens but rule 3 still uses (prompt_est+tools_est)×1.2. Inconsistent semantics: rule 4 uses est_total but rule 3 uses prompt+tools only. That's a genuine remaining defect — a request can exceed big_ctx_tokens total window yet be judged/routed to big. Severity: correctness/capacity protection. Counts.

Also max_out unbounded: client sets max_tokens = 10^9 → est_total huge → rule 0 catches if max_ctx_tokens configured; if not configured, rule 3: prompt small ×1.2 < big_ctx → rule 4: est_total not < fast → judging zone → judge could route to fast! A request with max_tokens=1,000,000 and tiny prompt: has no tools, est_total = huge, rule 4 fails (est_total not < fast), goes to judging zone; judge decides based on content, could say "fast" → routed to fast tier with max_tokens=1M — upstream provider will likely clamp or error. Hmm, is that realistic? max_tokens is usually clamped by provider. The router doesn't clamp max_out. The est_total for rule 4 uses it, good. But judging zone routing ignores est_total entirely — judge routes purely on content. So a small prompt with giant max_tokens goes to judge → maybe fast tier → provider clamps or 400s. This is a defect-ish: features are computed but est_total not used in judging zone to force big. Actually, should there be a rule: est_total > big_ctx_tokens → big/flagship? Rule 3 is the proxy but with wrong semantics as noted. I'll fold these: rule 3 should use est_total (or compare est_total × something), and judging zone has no capacity floor based on est_total. Also max_out should be clamped to a sane cap for estimation (e.g., min(max_out, some cap)). I can make this one or two items.

Rule 0 ordering vs rule 1/2: est_total > max_ctx → 400 even for multimodal/marker requests. max_ctx_tokens ≥ big_ctx_tokens but flagship may have a *larger* window than big! Rules 1/2 route to flagship, whose window might be much larger than max_ctx. Rule 0 now rejects requests that flagship could handle (if flagship window > max_ctx_tokens). Validation says max_ctx ≥ big_ctx but flagship could be 200k while big is 60k; a 100k multimodal request gets 400 despite flagship handling it. Hmm — is that a defect? The doc says rule 0 is "硬上限必须对多模态/marker/超长请求同样生效" — deliberate design decision (fix 三轮① explicitly moved it before all rules). It's a stated tradeoff. But there's an inconsistency: if max_ctx_tokens ≥ big_ctx_tokens is required, but multimodal goes to flagship which may exceed max_ctx... Actually rule 0 only rejects est_total > max_ctx; if flagship window > max_ctx, requests between max_ctx and flagship window get 400 even though they could be served. That's a documented deliberate choice though ("先于一切路由规则"). It's arguably a design decision. But one could note: if the deployer intends max_ctx as global hard cap, fine. I'll possibly skip or mention as minor. Actually the validation "max_ctx ≥ big_ctx" but rule 3 uses big_ctx as the threshold for routing to big — requests with prompt+tools in (big_ctx/1.2, ...) route to big tier. If big tier model's actual window is big_ctx_tokens and max_ctx ≥ big_ctx... fine.

Wait, another: rule 0's max_ctx_tokens vs flagship: marker/multimodal requests with est_total between big_ctx and max_ctx are allowed and routed to flagship — fine if flagship ≥ max_ctx. But nothing validates flagship window ≥ max_ctx. Janus doesn't know windows (§2.1). Deployer's responsibility. Not a defect per their model.

Rule 4: `not has_tools 且 est_total < fast_ctx_tokens 且 msg_count ≤ 3` → fast, hard. If fast tier unavailable → no_route (hard, no fallback). Short trivial request gets 404 because fast tier models all down, even though big could serve. Hmm — is hard classification for rule 4 appropriate? Rules 1-3 are capacity/modality constraints — hard makes sense. Rule 4 is a cost optimization ("short requests go cheap"), not a correctness constraint — treating it as hard means unavailability of fast tier causes no_route for trivial requests that big could trivially serve. That's arguably a usability defect: rule 4's conclusion should be soft. v2.2 table lists rule 4 as hard. The doc's own rationale for hard: "容量/模态/显式意图" — rule 4 is none of those; it's a cost routing. I'd flag: rule 4 should be soft (fall back to default_tier when fast unavailable). Real usability impact: fast models list empty/down → all short requests 404 despite big/flagship healthy. Startup check "整档为空且可能被规则命中 ⇒ error" warns, but runtime unavailability (LB all down) still possible. Counts as defect B-ish.

Cache: key includes SysPrefix (all system messages concatenated first 256 chars) but judging zone input is "system 前 256 字符" — consistent. Decision cache stores Tier from judge. But note: decision cache is consulted only in judging zone; the cache key doesn't include anything about... fine.

Negative cache + decision cache share structure with Tier=neg. Reading: negcache hit → default_tier. But decision cache lookup order: negative cache checked before decision cache (per pipeline). Fine.

Cache key uses phash2 2^28 — collision means wrong-tier reuse; accepted design.

Judge worker snapshot: worker snapshots judge_model at start; writes carry snapshot. But what about the decision cache write — normal success writes Tier keyed by request hash; that's model-independent-ish, fine.

Config switch race for breaker: breaker state keyed by judge_model name. If config switches from model A to model B then back to A, A's old breaker state resumes — acceptable.

Signal semaphore: atomics global counter. Judge worker spawn — who decrements? Failure paths decrement presumably. Not specified but impl detail.

Rule 2 marker: "末条 user 角色消息" — marker in earlier user message ignored. Deliberate.

Feature: has_multimodal detection — "一切非 {type:"text"} 的 part" — includes type "image_url" with empty? fine.

prompt_est: "ASCII 字节数 ÷ 4；其余码点 ×1.5" — mixing units: bytes vs codepoints; for UTF-8 CJK char is 3 bytes counted as 1.5 tokens — actual ~1 token per CJK char; overestimate ok.

tools_est: bytes÷4 — JSON of CJK tool descriptions underestimated? CJK in tools JSON: 3 bytes/char ÷4 = 0.75 tokens/char, actual ~1 — underestimate; minor inconsistency with prompt formula (prompt uses codepoints×1.5). Minor, affects est accuracy. Could mention as minor: tools_est should use same tokenizer as prompt. Impact: underestimation could under-route. Cost/correctness minor. Maybe include as a B item.

Rule 3 missing est_total semantics — as discussed, main defect A.

Also: rule 0 uses est_total but rule 3 uses prompt+tools×1.2. With max_ctx configured, requests with est_total > max_ctx are 400'd. But between rule 3 threshold and max_ctx: request with prompt+tools×1.2 > big_ctx → big hard; big tier window is big_ctx per deployer... prompt+tools can be up to big_ctx_tokens (since ×1.2 margin) plus max_out up to... est_total up to big_ctx + ... wait est_total = prompt+tools+max_out; rule 3 triggers when p+t > big_ctx/1.2 = 0.833×big_ctx. Then est_total can be up to 0.833×big_ctx×... no: p+t can be anything > threshold, even 0.99×big_ctx, plus max_out 4096 → est_total ≈ big_ctx + 4096 > big_ctx_tokens total window! So rule 3 routes to big a request that exceeds big's window (since big_ctx semantics is total window). The ×1.2 margin was supposed to absorb max_out, but margin = 0.2×(p+t) — for p+t near 0.833×big_ctx, margin headroom... Let me compute: routed to big when p+t > big_ctx/1.2. Worst overflow: p+t = big_ctx/1.2 + ε, est_total = big_ctx/1.2 + max_out. For overflow need big_ctx/1.2 + max_out > big_ctx → max_out > big_ctx/6 = 0.167×big_ctx. With big_ctx=60000, max_out > 10000 → overflow. Default max_out=4096 < 10000 OK, but client can set max_tokens=16384 → overflow while routed to big. And judge-zone requests with p+t ≤ 0.833×big_ctx: est_total can exceed big_ctx if max_out > big_ctx - (p+t). E.g., p+t=50000, max_out=15000 → est_total=65000>60000, judge may pick "big" → overflow. So consistent fix: compare est_total (with ×1.2 margin or not) against big_ctx_tokens, and/or clamp max_out used in estimation, and/or give judge-zone a capacity floor (est_total > X ⇒ force big/flagship). This is one solid defect (rule 3 / judging zone window protection inconsistent with the "总窗口" semantics they just fixed for fast). Definitely the top finding: the v2.2 fix ② applied total-window semantics to fast but not to big/judging path.

Also flagship window protection: rule 3 overflow (est_total > max big) → if max_ctx undefined, no upper protection at all: huge non-multimodal request without tools/marker: p+t×1.2 > big_ctx → big hard — but big can't hold it. If max_ctx configured → 400. Without max_ctx configured, no 400 and big gets overflowed. Should route to flagship when est_total > big_ctx? Doc doesn't. Defect: rule 3 should route such to flagship or 400; currently routes to big even when request exceeds big window. Real.

max_out default 4096 but unbounded client input — estimation DoS-ish? No, just numbers.

Rule 4 msg_count ≤ 3 and no tools — system+user+assistant = 3 ok.

Another: decision cache key includes prompt_est_bucket = prompt_est div 4096 — fine.

Judge input truncation 1200 chars vs cache LastUserPrefix 1200 — consistent now.

Parsing: "全文首个独立白名单词" fallback — could pick "fast" from instruction-echo; accepted.

§2.3: try/catch → pass; but {error, request_too_large} is a return value — fine.

Race: config read vs validation caching — fingerprint recompute; fine.

Breaker per judge_model name; state space switch — but the negative cache is keyed by request hash, not model; a negative entry written for model A failures persists after switching to B — writes with mismatched snapshot are dropped, but entries already written before the switch remain and apply to new model B for 30s. Minor, 30s TTL, negligible. Skip.

Signal semaphore "global" — not per model; switching judge model doesn't reset in-flight; fine.

Now §7 validation: "max_ctx_tokens 已配置但 < big_ctx_tokens ⇒ error + 忽略该上限". But what about max_ctx < fast_ctx? covered since fast < big presumably... Is fast_ctx < big_ctx validated? Not stated! If fast_ctx_tokens > big_ctx_tokens, rule ordering: rule 3 fires for big before rule 4 fast check... rule 4 checks est_total < fast_ctx — if fast_ctx=100000 > big_ctx=60000, a request with p+t small... rule 3 fires first when p+t×1.2 > 60000. est_total=70000, p+t=65000 → rule 3 → big. est_total 65000 with p+t=40000, max_out=25000 → not rule 3 (48000≤60000), rule 4: est_total < 100000, msg_count≤3, no tools → fast! A 65k request routed to fast tier. So missing validation fast_ctx_tokens < big_ctx_tokens. Also max_ctx vs flagship window unknown. Add: startup validation should require fast_ctx_tokens ≤ big_ctx_tokens. Real config-robustness defect (they added similar validations in v2.2 ⑤ but missed this one). Counts as B (missing boundary check) — arguably defect since config error leads to misroute.

Also msg_count — huge arrays: features iterates all messages; fine.

Marker matching "双方 lowercase" — binary lowercase of UTF-8 only ASCII-safe; fine.

Empty messages defense: marker_hit=false, falls to judging zone → judge gets "(no user message)" — judge call cost for an invalid request (messages empty is invalid per OpenAI API; would 400 anyway downstream). Minor: could 400 early. Skip or mention? OpenAI requires messages non-empty; the proxy will forward and provider 400s. Router sends to judge — wasted cost. Tiny. Maybe mention briefly in C.

CJK marker substring matching: "深度思考" substring — fine. ASCII word-boundary: "think harder" inside "don't think harder" — test expects not hit; word boundary on "think" start after space — the negation "don't" isn't detected; that's their chosen test case as "反例" — they accept it as hit? "marker 词边界（"don't think harder" 反例）" — ambiguous, whatever.

has_multimodal → flagship hard. But flagship unavailability → no_route 404 even though request could degrade... it's modality constraint, fine.

One more: judge itself calls chat_completions with model = judge_model — does that go through the same handler and could hit janus-auto if judge_model misconfigured to virtual name? Validation guards judge_model == virtual name → treated unconfigured. Good. But judge_model could be another auto-router-like virtual? Only one virtual presumably. Skip.

Judge call authorization: judge call internal — uses which key? Internal call bypasses auth presumably. Not specified; impl detail. Could note? Skip.

Negative cache counts failures per request hash — a single request that fails judge gets negcached; fine.

Rule 0 mapping 400: request_too_large even when max_ctx configured but flagship bigger — deliberate.

Decision cache write on {Ref, Tier} success path; but caller writes cache — the worker result {Ref, Tier} — fine.

Stats counters — fine.

Now compile findings:

A. Defects:
1. 规则 3 仍用 (prompt+tools)×1.2 而非 est_total，与"总窗口"语义不一致：p+t 接近 big_ctx/1.2 且 max_out 大（如 >big_ctx/6，默认4096 之外客户端可任意设）时，est_total 可超过 big_ctx_tokens 仍被硬路由到 big；判分区同样没有任何基于 est_total 的容量下限，judge 可能把 est_total > big_ctx 的请求判到 big/fast。v2.2 ②只给 fast 档补了总窗口比较，big 档与判分区漏了。建议：规则 3 改 est_total 比较（或 est_total > big_ctx → flagship/400），max_out 估算取 min(max_out, cap)。
2. 规则 4 性质为 hard：fast 档全部不可用时短请求直接 no_route 404，而 big/flagship 健康——规则 4 是成本优化非容量/模态约束，应为 soft（允许降级 default_tier/big）。可用性缺陷。
3. 启动校验缺 fast_ctx_tokens ≤ big_ctx_tokens：配置倒挂时规则优先级导致 est_total 达 big 量级的请求落入规则 4 路由 fast（上例 65k→fast）。与 v2.2 ⑤同类遗漏。

B. 遗漏边界：
4. tools_est 用 字节÷4，与 prompt 的"非ASCII码点×1.5"不一致：CJK 工具描述被低估（3
