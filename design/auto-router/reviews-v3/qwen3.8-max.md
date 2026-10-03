# Review v2.1 by qwen3.8-max (qwen3.8-max)

_37.0s · completion_tokens=1617_

# Janus Auto Router v2.1 第三轮评审报告

## A. 仍然存在的缺陷或 v2.1 新引入的问题

1. **信号量原子操作存在 TOCTOU 竞态（正确性/安全性）**
   §6.2 提到用 `atomics` 实现全局 judge in-flight 计数。如果实现为“先 `atomics:get` 判断是否 `< max`，再 `atomics:add`”，在高并发下会导致实际 inflight 突破上限，引发 judge 过载。必须使用 CAS 循环（`atomics:compare_exchange`）或 Erlang 26+ 的 `atomics:add_get` 来实现原子的条件递增。
2. **ETS 双表写入非原子导致清扫进程崩溃（可用性）**
   §5 规定“写入两表同笔”。但在 Erlang 中两次 `ets:insert` 无法跨表保证原子性。若主表写入成功、辅表写入前 Caller 进程崩溃（或调度延迟），辅表将缺失该 `Seq`。当容量 >4096 触发清扫时，从辅表取出的 `{Seq, Hash}` 去主表删除可能无影响，但**如果清扫逻辑依赖两表严格一致来定位最旧条目或进行级联删除**，可能导致死循环或异常。需明确清扫时的容错逻辑（如主表未命中则直接删辅表记录）。
3. **`phash2` 截断与碰撞导致缓存错误复用（正确性/成本）**
   §5 使用 `phash2(..., 2^28)` 作为 ETS Key。在 4096 容量下碰撞概率虽低（~3e-5），但随着请求量增加，不同特征（如完全不同的 prompt 前缀但碰巧 hash 相同）会命中同一个 Tier 缓存。由于这是软估计，可接受一定误差，但若 `prompt_est_bucket` 跨度大且 hash 碰撞，可能导致长文本请求被错误路由到 `fast` 档从而引发上游 400 报错。建议明确文档：缓存碰撞导致的误路由属于设计折衷。
4. **规则门 400 错误绕过 `maybe_route` 返回值契约（正确性）**
   §2.3 承诺 `maybe_route` 仅返回 `{ok, Target} | pass | {error, no_route}`。但 §4.2 规则 4 和 §8 规定 `est_total > max_ctx_tokens` 返回 400 `request_too_large`。这个 400 是如何通过 `maybe_route` 传递的？如果是 `{error, request_too_large}`，则 HTTP handler 必须有额外分支处理；如果是抛出异常，则会被 §2.3 的 `try/catch` 捕获并降级为 `pass`（导致超大请求穿透到上游，由上游报 5xx/400，违背了网关拦截初衷）。需明确 400 的返回数据结构。

## B. 遗漏的边界情况

1. **`messages` 数组为空或缺失 `user` 角色（可用性）**
   §4.1 提取 `LastUserPrefix` 依赖“末条 user 消息”。如果客户端发送合法的 API 请求但仅包含 `system` 和 `assistant` 消息（无 `user`），或者 `messages` 为空列表，特征提取代码若未做防御性匹配（如 `lists:last([M || M <- Msgs, role == user])` 失败），将导致 badarg 异常，进而被 §2.3 捕获降级为 `pass`。
2. **多模态 parts 嵌套或非标结构（可用性）**
   §4.1 检查 `type` 非纯文本。OpenAI 规范允许 `content` 为 string 或 array of parts。若客户端传入深度嵌套的 JSON、`content` 字段为 null、或 `parts` 内部缺少 `type` 字段，模式匹配可能抛出异常。需在 `features/1` 中对 `content` 解析增加 `try/catch` 或严格的安全访问宏。
3. **Judge 输出全为空行或仅含控制字符（可用性）**
   §6.3 规定取“最后一个非空行”。如果 judge 模型（尤其是小模型）返回全空格、`\n\n\n` 或不可见 Unicode 字符，按空白切词后列表为空。规格隐含了此情况走回退或解析失败，但应显式说明：切词结果为空列表等同于该行无命中，直接进入全文回退或降级。
4. **配置热更新期间的状态不一致（可用性）**
   §7 提到“配置变更时以配置指纹重算”。如果在计算新指纹并替换配置的瞬间，正在执行中的 judge worker 仍在使用旧 `judge_model`，而熔断器已经切换到了新模型的状态空间。这本身是设计预期（旧状态自然作废），但需确保旧 worker 超时后的负缓存不会错误地写入新状态的计数器中（通过绑定 worker 启动时的 model_name 快照来解决）。

## C. 具体可执行的改进建议

1. **提供原子获取并递增的信号量原语**
   针对 A1，建议在规格中明确给出信号量的实现伪代码：
   ```erlang
   acquire_semaphore(Ref, Max) ->
       case atomics:add_get(Ref, 1, 1) of
           Val when Val =< Max -> ok;
           _ -> atomics:sub(Ref, 1, 1), full
       end.
   ```
   避免实现者写出有 TOCTOU 漏洞的代码。
2. **统一 `maybe_route` 的错误返回元组**
   针对 A4，建议将规则 4 的返回值显式定义为 `{error, request_too_large}`，并在 §3 流水线和 §8 失败语义表中补充：HTTP handler 层对 `{error, request_too_large}` 映射为 400，对 `{error, no_route}` 映射为 404。确保不落入 `try/catch` 的 `pass` 兜底。
3. **明确 ETS 清扫的幂等性与容错**
   针对 A2，在 §5 补充一句：“清扫进程从辅表取出 `{Seq, Hash}` 后，执行 `ets:delete(MainTab, Hash)` 与 `ets:delete(AuxTab, {Seq, Hash})`。若主表已无该 Hash（因并发覆盖或哈希碰撞被提前淘汰），删除操作天然幂等，不影响正确性。”
4. **细化 `LastUserPrefix` 的空值处理**
   在 §4.1 和 §5 中明确：“若无 user 消息，`LastUserPrefix` 取空二进制 `<<>>`”。这不仅防止崩溃，还能让同类无 user 消息的请求共享缓存 key，符合重试粘性语义。
5. **Judge 注入防御的引号定界需转义**
   §6.1 提到“用户内容以引号定界包裹”。如果用户的 system/user 消息本身包含该定界引号（如 `"` 或 `'`），可能导致 prompt 结构破坏，甚至提示词注入。建议明确：“使用 XML 标签（如 `<user_content>...</user_content>`）替代引号定界”，这在 LLM 判分任务中抗注入能力远强于普通引号。
