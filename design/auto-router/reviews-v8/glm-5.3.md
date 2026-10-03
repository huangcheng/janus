# Review v2.5-final by glm-5.3 (glm-5.3)

_69.7s · completion_tokens=4000_

Let me carefully review this design spec v2.5 for the Janus Auto Router. This is the 8th review round, and the claim is that all previous critical defects have been fixed. I need to check:

A. Remaining defects or new issues introduced in v2.5
B. Missing edge cases
C. Concrete actionable improvement suggestions

Let me go through the spec systematically.

## Key changes in v2.5:
1. Rule reordering: total check (→flagship) before prompt-segment check (→big), renumbered rules
2. `media_allowance` count capped at `max_media_parts` (default 10)
3. Auxiliary table key includes `Kind`, capacity overflow changed to unconditional FIFO eviction
4. Semaphore release written into `after` guarantee; negative cache wording aligned with split key space

Let me analyze each part carefully.

### §4.1 features extraction

- `prompt_est`: ASCII bytes ÷ 4; all other codepoints (CJK, Korean, emoji, all non-ASCII) × 1.5 per codepoint
- `media_allowance`: min(non-text parts count, max_media_parts) × media_token_allowance (4096/part, max 10 parts)
- `tools_est`: JSON-encoded tools bytes ÷ 4
- `max_out`: max_completion_tokens ?? max_tokens ?? 4096
- `est_total = prompt_est + media_allowance + tools_est + max_out`

Wait — the media cap at 10 parts. Each part gets 4096 tokens allowance. So max media_allowance = 10 × 4096 = 40960 tokens. 

Hmm, but there's an issue here: what if the actual media is much larger? E.g., a video part could be huge. The spec acknowledges: "封顶后的极端媒体体量由 HTTP 层既有的请求体上限（`?MAX_BODY` 10MB）兜底，不会无限放大转发". Actually the concern about "不会无限放大转发" is about forwarding — the request body is forwarded as-is, so the body cap bounds the actual bytes. The token estimate is for routing decisions. If actual media tokens exceed the allowance, then est_total may underestimate. But since big_ctx_tokens is typically 60000 and flagship is presumably larger, the underestimate is bounded by (actual media tokens - 40960). For a 10MB body of base64 image data, that's ~7.5MB decoded, image tokens could be substantial but the max_ctx_tokens rule 0 might not catch it. However, this is a deliberate design tradeoff with the body cap bounding the worst case, and the downstream provider will error if over the window. This is arguably acceptable — the spec explicitly documents the tradeoff. Is this a real defect? The consequence: a request with many large images could be routed to big tier where it exceeds the model window, causing upstream 4xx/5xx. But the provider returns its own error, which passes through. Availability impact bounded; the deployment assumption is flagship has the largest window but even flagship might not accept it. I think this is a documented tradeoff, borderline. The spec says "宁可高估触发上限" — wait, capping actually under-estimates if actual media tokens > allowance. The original v2.3 wording said "宁可高估触发上限，不做 provider 级精确计费" — with the cap, it's no longer conservative (高估) for extreme cases. But the body cap argument is reasonable. I'd mention it as a minor note maybe, but per the review criteria "假想的极端场景（现实中不会发生或影响可忽略）不计为问题" — 10MB of images is possible but the consequence is an upstream error for that request, pass-through. Marginal. Maybe mention as B (edge case) briefly.

### marker definition

`marker_hit`: last user message text, lowercase both sides; ASCII markers word-boundary matched, CJK substring. Configurable. "don't think harder" negative example covered in tests.

### Input robustness

Malformed messages → pass → existing model_not_found 404. OK.

Wait — one thing: "content 为 binary 或 part 列表" — what about content being null? OpenAI API allows content: null for assistant messages with tool_calls. If messages include an assistant message with content: null and tool_calls, is that "malformed"? The validation says content must be binary or part list. content: null is common in agentic workloads (assistant tool call messages). If treated as malformed → pass → 404 for a perfectly legitimate request. That's an availability defect! Let me check: "content 为 binary 或 part 列表、`tools` 字段缺失或为合法数组（`null`/字符串等畸形一律视为无 tools）；不满足（`null` 元素、字符串消息等畸形输入）⇒ `maybe_route` 直接返回 `pass`".

The phrase "`null` 元素" refers to messages array containing null elements. But what about a valid message map whose `content` is null? In OpenAI format, assistant messages with tool_calls often have content: null. Also tool role messages have string content. If features/1 requires content to be binary or part list, then content: null (a legitimate, extremely common pattern in tool-use workflows) would be classified malformed → pass → 404. Hmm, but wait — the spec says malformed ⇒ pass ⇒ treated as unknown model ⇒ 404 model_not_found. So a legit agentic request with assistant content:null would get 404. That's a real availability defect for a router that explicitly supports tools routing (has_tools, rule 4 considers tools_est).

Actually let me re-read: "`features/1` 入口校验 messages 为 map 列表、content 为 binary 或 part 列表". Strictly, null content is not binary nor part list. The intent might be that missing content key or null is tolerated, but as written it's ambiguous. I should flag this as a defect/edge case: content: null (assistant tool_calls) and possibly missing content field must be treated as empty text, not malformed. This is a real-world common case. Good catch for B or A.

Also, tool role messages: content is string — fine. Function role legacy — fine.

### §4.2 rules

Rule 0: est_total > max_ctx_tokens (only if configured) → 400. Note: startup validation says max_ctx_tokens configured but < big_ctx_tokens ⇒ error + ignore the limit. So max_ctx_tokens ≥ big_ctx_tokens guaranteed (60000). OK.

Rule 1: has_multimodal → flagship (hard)
Rule 2: marker_hit → flagship (hard)
Rule 3: est_total > big_ctx_tokens → flagship (hard)
Rule 4: (prompt_est + tools_est) × 1.2 > big_ctx_tokens → big (hard)
Rule 5: not has_tools ∧ est_total < fast_ctx_tokens ∧ msg_count ≤ 3 → fast (directed hard / availability soft)
Rule 6: else → judge zone (soft)

Check ordering: Rule 3 (total > big) before rule 4 (prompt segment > big). v2.5 fixed the ordering issue. Now if est_total > big_ctx → flagship. If est_total ≤ big_ctx but (prompt+tools)×1.2 > big_ctx → big. Consistent.

Wait, potential issue: rule 4 uses ×1.2 margin on prompt+tools compared against big_ctx_tokens which is a *total window* semantic. So prompt+tools alone approaching the total window (÷1.2 = 83%) triggers big. Fine.

But consider: est_total > big_ctx triggers flagship (rule 3). But what if est_total ≤ big_ctx yet the request would overflow big model's actual window? That's deployer's threshold responsibility. Fine.

Rule 2 marker → flagship: "flagship 窗口由部署者保证 ≥ big" — noted.

Rule 5: est_total < fast_ctx_tokens — total including max_out (default 4096). fast_ctx_tokens default 8000. So prompt+tools+media < 8000-4096=3904 with default max_out. Fine.

Now an edge: rule 5 requires not has_tools. Tool-carrying short requests go to judge zone (or default_tier if no judge). Default_tier default is fast — with tools! If fast tier models don't support tools... but that's deployer config. The spec says default_tier => fast by default; judge zone soft → default_tier fast for tool requests under no judge. A fast model without tool support would error upstream. Hmm — but tiers are deployer-assigned; deployer should assign tool-capable models. Janus makes zero assumptions about model capabilities (§2.1). So it can't know. Borderline; config guidance could mention. Not a defect per criteria? It could cause errors for a default config where fast tier models lack tool support. But deployer assigns tiers; the catalog is theirs. I'd call it a doc note at most. Actually wait — rules-only mode with tools: any request with tools can never hit rule 5, goes judge zone → default_tier (fast). If the deployment's fast tier is e.g. gpt-4o-mini, tools are supported. Minor. Skip or minor mention.

### Rule interaction: rule 2 (marker → flagship) placed before rule 0? No — rule 0 is first ("先于一切路由规则"). Good: oversized marker request → 400 not flagship overflow. Good.

But wait — marker → flagship even if est_total > big_ctx? Both go flagship anyway. Fine.

Multimodal → flagship: if est_total > max_ctx → 400 first. Good.

### §5 Decision cache

Key: phash2({SysPrefix, LastUserPrefix, ToolsFp, HasMM, prompt_est_bucket, max_out_bucket}, 268435456).

Hmm — the key does NOT include msg_count or other features used by rule 5? Wait, cache is only consulted in the judge zone (rule 6), where rule 5 already failed (has_tools or est_total ≥ fast_ctx or msg_count > 3). The judge decides among fast/big/flagship. The cache key includes the main judge inputs: SysPrefix (256), LastUserPrefix (1200), ToolsFp, HasMM (defensively false), prompt_est_bucket, max_out_bucket. Judge input also includes output budget line derived from max_out — included via max_out_bucket. OK consistent.

Note: judge input includes system prefix + last user prefix + budget line; cache key includes those plus ToolsFp and prompt bucket (judge doesn't see tools JSON itself... wait, does the judge see tools? §6.1: user content = system 前 256 + 末条 user 前 1200 + output budget line. ToolsFp not in judge input but in cache key — that makes cache key finer than judge input, which is safe (fewer false shares) though it reduces hit rate. Fine.

TTL 300s, lazy expiry. Value {Tier, JudgeModel, ExpiresAt} — miss on judge mismatch. Good.

pos/neg split key space. Write order: aux first, then main. Capacity > 4096 → FIFO evict from aux head unconditionally deleting corresponding main entry. Aux key {Seq, Kind, Hash}. Eviction: "从辅表头部（最旧）无条件删除对应主表条目直至回到 4096；单次清扫至多 128 条".

Hmm: aux is ordered_set keyed {Seq, Kind, Hash}. First key is oldest. Delete corresponding main entry: main key is {Kind, Hash}? "主表 `set`：`{Hash => {Tier, ExpiresAt}}`" — wait, main table key is Hash, but pos/neg split key space says positive decisions stored {pos, Hash}, negative {neg, Hash}. So main table key presumably {Kind, Hash} (the spec says "辅表 ... `Kind` ... （与主表完整键一致）" — aux key {Seq, Kind, Hash} where {Kind, Hash} matches the main table key. So main table key is {Kind, Hash}. The §5 opening line "{Hash => {Tier, ExpiresAt}}" is slightly stale notation but clarified later. Minor wording inconsistency, not a defect.

FIFO eviction: unconditional delete of main entries until back to 4096. Bounded work: 128 per sweep. If capacity grows fast (e.g., burst), sweeps happen per insert? Each insert checks capacity > 4096 → sweep up to 128. Insert rate bounded by judge call rate (judge_max_inflight 8, timeout 1500ms) — actually cache writes happen on judge success; judge throughput bounded by semaphore. Fine.

Potential issue: "主表条目必有辅记录可被淘汰" — write order aux-first ensures main entries always have aux records. But: an entry written to aux, then main write fails?? In Erlang ETS within one process, ets:insert failing is virtually impossible (only on table gone). Fine.

Negative cache TTL 30s but stored in main table with the pos/neg kind. Value for neg: {default?, ...}? The value stores {Tier, JudgeModel, ExpiresAt}. For neg entries Tier is presumably default_tier marker. JudgeModel snapshot — neg entries carry judge model name, and read misses on mismatch. OK.

One subtlety: FIFO eviction is unconditional — evicting a still-fresh pos entry that's being heavily reused? That's just cache performance, not correctness. Fine.

Another subtlety: negative entries occupy the same 4096 capacity; under failure storms, neg entries (30s TTL) could flood the cache and evict pos entries — combined with breaker (5 consecutive fails → 60s breaker), impact bounded. Not a correctness issue.

### §6.2 judge execution

Semaphore: acquired before spawn; released in after block on all three paths. Let me check the code sketch:

```
receive
  {Ref, Tier} -> demonitor flush; write cache;
  {'DOWN',...} -> fail path
after judge_timeout_ms ->
  exit(Pid, kill), demonitor flush, fail path
end
```

The after block: "获取后在 `after` 块中保证释放（正常回复、DOWN、超时三条路径都归还）". Hmm — the semaphore release is guaranteed "in the after block" — but in Erlang, the `after` clause of receive only executes on timeout. To guarantee release on all paths you'd need try/after around the receive. The spec says "信号量释放写入 `after` 保证" — presumably meaning try ... after ... end wrapping. The wording "在 `after` 块中保证释放（正常回复、DOWN、超时三条路径都归还）" — they claim all three paths release. If implemented as receive with after-timeout clause only, the normal-reply and DOWN paths wouldn't go through the timeout clause — they'd need explicit release too. The spec asserts the guarantee; implementation detail. Acceptable — the design states the guarantee. But wait — what if the caller process (HTTP handler) itself crashes/gets killed while waiting (e.g., client disconnect kills handler)? Then semaphore never released → leak → eventually permanent judge skip (semaphore full → all requests default_tier — availability of judge feature degrades, cost impact: more requests to expensive default tier... actually default_tier fast, cheap). The caller is an HTTP handler process; if the client closes the connection, does the handler die? In many Erlang HTTP servers, the handler finishes the request regardless; gun-based proxy may monitor. If handler dies between semaphore acquire and release, leak. With atomics-based counting, leaked slots never return → after 8 leaks, judge permanently disabled until restart. Is this a realistic scenario? Handler crash mid-judge-wait: possible but rare (the receive is a tight window; handler death usually comes from timeout logic or upstream errors). Hmm — a more likely path: handler has its own overall request timeout shorter than judge_timeout? judge_timeout 1500ms is short. Client disconnect killing handler mid-wait: Cowboy handler processes typically don't die immediately on disconnect (they may finish). It's a hypothetical edge; impact: judge disabled, system still routes via default_tier (available). Cost impact slight. The spec could add a safety: semaphore slots leased with timestamp, periodic reclaim, or use the worker process death to release (worker holds the lease and releases on exit — better: acquire inside worker? But skip decision needs acquiring before spawn). Alternative: acquire in caller but also have worker release on abnormal termination? Can't after death. Could wrap in try/catch in caller; but process kill (exit signal from supervisor/client) can't be caught. Rate: rare. I'd flag as B (edge case) with suggestion: lease-with-TTL reclaim or periodic reconciliation of in-flight counter (e.g., track {caller pid monitor} and release on caller DOWN). Actually simpler: monitor from a janus_auto process to caller... complexity. Or: bound the damage — the semaphore is per-node global; a leaked slot permanently reduces capacity. A cheap fix: store acquisition timestamp in an ETS and have a periodic sweeper expire leases older than judge_timeout_ms × 2. Worth suggesting.

Actually wait — there's a subtle issue: the DOWN path. `spawn_monitor` worker: worker does gun:open (owner = worker), calls chat_completions. On success sends {Ref, Tier} then exits normally → DOWN arrives after. Caller on {Ref, Tier} does demonitor(flush) — flushes the queued DOWN. Good (N1 fixed).

Timeout path: exit(Pid, kill) — brutal kill, untrappable. gun connection owner-dead cleanup. demonitor flush. Good.

One more: after receiving {Ref, Tier}, is the worker guaranteed to have exited? Worker sends message then ends. If worker hangs after sending (e.g., cleanup)... it just ends; fine. If worker sends {Ref, Tier} then crashes — fine.

Race: timeout fires exactly as worker sends reply → exit(kill) may kill before/after send; if reply was already delivered, receive picks {Ref, Tier} first (mailbox order — DOWN vs reply ordering: reply sent before process exit, so reply arrives before DOWN; receive without pattern for DOWN inside timeout clause... The after clause triggers only when no matching message within timeout; if reply arrived, normal path. If timeout expires and reply arrives during exit(Pid,kill) processing... reply already in mailbox? receive already committed to after clause; demonitor(flush) doesn't flush {Ref, Tier} (not a monitor signal) — so a late reply sits in mailbox harmlessly (leaked message, negligible). And kill prevents further work. Semaphore released in after. Fine.

### §6.3
