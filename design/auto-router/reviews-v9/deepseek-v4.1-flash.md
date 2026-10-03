# Targeted re-review by deepseek-v4.1-flash

_25.2s_

让我仔细审查这份 v2.5 设计规格，重点核对上轮两个修订：

1. **双表写序微竞态**：改为有界软容量语义（孤儿受 TTL 封顶，4096 为软目标，每第 64 次清扫附带全表对账删除无辅记录的过期主表条目）
2. **信号量所有权与 caller 崩溃泄漏**：获取移入 worker fun 内部，获取失败 worker 自行退出并发 skip 标记，计数与 worker 生命周期严格绑定

我需要验证这些修订是否真的解决了问题，以及是否引入新问题。

## 逐一审查

### 修订一：双表写序微竞态

原问题：先写辅表，再写主表，若期间插入容量清扫，辅表行被淘汰，主表条目成为孤儿，逃过 FIFO，导致主表无限增长。

修订后的语义：
- 明确为"有界软容量语义"
- 孤儿受 TTL 300s 惰性过期封顶
- 4096 为软目标而非硬上界
- 每第 64 次清扫附带全表对账，删除无辅记录的过期主表条目

让我验证这个是否成立。

孤儿主表条目的增长率：在 TTL 窗口（300s）内的写入量。写入量 = 请求率 × 缓存写比率。假设每秒 N 次写入，300s 内最多 300N 个孤儿。这确实有界，但"有界"的界是 300N，可能很大。

但等等——关键是孤儿主表条目仍然受 TTL 惰性过期约束。所以孤儿不是永久泄漏，只是在其 TTL 之前无法被 FIFO 清除。但实际上，主表条目的 TTL 是 300s，那么在最坏情况下，主表大小 = 4096（正常）+ 300s 内的写入量（孤儿）。

不过，实际上，读取时会惰性过期。但孤儿条目如果没有被读取，就不会被惰性删除。全表对账每 64 次清扫做一次，会删除"无辅记录的过期主表条目"。

这里有个问题：全表对账只删除**过期**的主表条目（"删除无辅记录的过期主表条目"）。如果一个孤儿条目未过期，且无辅记录，那么它不会被对账删除，也不会被 FIFO 删除（因为辅记录已丢）。它只能等 TTL 过期后由下一次对账删除。所以它最多存在 300s + 到下一次对账的时间。这仍然有界。

但让我想想：这个"对账"的时机。每第 64 次清扫做一次全表对账。如果清扫频率低，对账也低。但对账只处理过期条目，过期条目本来读取时也会惰性过期……不对，读取惰性过期只对**被访问的 key** 有效。如果孤儿条目不被访问，读取不会触发它的过期。

所以设计依赖对账来清理。对账每 64 次清扫一次。清扫由容量超限触发（> 4096）。如果孤儿导致容量持续超限，清扫会频繁触发，对账也会频繁。OK。

但还有一个更微妙的问题：**对账本身是否会与写序竞态产生新的孤儿？** 对账是"删除无辅记录的过期主表条目"。这是删除主表条目，不会创建孤儿。OK。

另一个问题：全表对账的成本。4096 行，每 64 次清扫一次。摊销成本"可忽略"。每次清扫最多 128 条 FIFO 删除，那么第 64 次清扫时需要扫描全表 4096 条。这个摊销是可以接受的。

那么，孤儿主表条目会不会**无限积累**（在 TTL 内）？考虑极端情况：写序竞态每次恰好插入清扫。理论上每次写入都可能产生孤儿。但实际概率很低（微竞态）。且即使产生，也受 TTL 约束。

我认为这个修订**解决了原问题**：从"无界泄漏"变为"有界（TTL 封顶）"。语义明确为软容量是有意的设计选择。这是可接受的。

但我要检查：有没有引入新问题？

**新问题检查**：对账"删除无辅记录的过期主表条目"——如何判断"无辅记录"？需要遍历辅表构建集合，或查辅表。如果对每次主表条目的判断都查一次辅表，那就是 4096 次 O(1) 查询（ordset lookup）。OK。但如果需要在一次遍历中同时判断，则是 O(n) 查询。可接受。

不过，有没有可能误删？如果一个主表条目**有**辅记录但辅记录还没写入（等等，写序是先辅后主，所以主表有记录时辅记录必已存在，除非辅记录被清扫淘汰）。所以"无辅记录"的主表条目要么是孤儿，要么是……没有其他情况。正常流程下主表条目都有辅记录。所以对账删除"无辅记录且过期"的条目是安全的。

嗯，但还有：对账删除的是"过期"主表条目。那"无辅记录但未过期"的主表条目怎么办？它们留到过期后由下一次对账删除。在下一次对账之前，它们占着容量。所以容量在 TTL 窗口内可能超过 4096。这是"软目标"语义，已明确声明。可接受。

所以修订一：**PASS**。

### 修订二：信号量所有权

原问题：caller 获取信号量，若 caller 在 spawn worker 后崩溃，信号量泄漏。

修订后：
- 获取在 worker 的 fun 内部执行
- worker 启动即尝试获取，失败则自行退出并发 `{Ref, skip}`
- 计数与 worker 生命周期严格绑定
- worker 内部用 `after` 保证释放
- `spawn_monitor` 自身失败走失败路径

让我验证。

现在流程是：
- caller spawn_monitor 一个 worker
- worker 内部第一个动作：acquire 信号量
- 失败：worker 发 `{Ref, skip}` 然后退出（worker 未持有信号量，无需释放）
- 成功：worker 持有信号量，执行 judge，finally release

**关键**：现在持有信号量的是 worker。如果 caller 崩溃，worker 是独立的进程（spawn_monitor 不链接），worker 会继续运行到结束，然后 `after` 释放信号量。所以 caller 崩溃不再泄漏信号量。✓

但如果 caller 崩溃，worker 会继续运行（做完 judge），然后发消息给已死的 caller。这消息发到死进程没关系。worker 正常退出并释放。✓

那么 worker 会不会**永远**不释放？不会，worker 有 gun 层超时（连接 5s / TTFB 60s），最坏 60s。且 worker 的 fun 内部 try/after 保证释放。✓

**新问题检查**：

1. **worker 的 acquire 竞态**：worker 启动即 acquire。如果同时多个 worker 启动，atomics 的 CAS 保证计数正确。OK。

2. **caller 超时后不 kill worker**：caller 超时（judge_timeout_ms 1500），放弃等待，demonitor + 排空。但 worker 还在跑（持有信号量），最长到 60s。这段时间内信号量被占用。设计承认"最坏持有信号量 60s；8 个槽位最多占用 60s 窗口"。这是可接受的自愈，但有个细节：如果大量请求持续超时，信号量会被慢 worker 长期占满，导致所有新请求都走 inflight_skip → default_tier。这会持续 60s 窗口直到熔断触发（连败 5 次 → 60s 熔断）。

   等等，仔细想：caller 超时会计"失败（负缓存 + 计连败）"。连续 5 次超时 → 熔断 60s。熔断后不再发起 judge（"熔断开启 → default_tier"），所以不会再 spawn worker。60s 后熔断解除，重试。如果 judge 仍挂死，再次 5 次超时 → 熔断。所以这是自愈的。✓

   但注意：熔断触发需要 5 次**连续**失败。如果中间有成功，清零。挂死的 judge 不会成功。所以会连续失败。✓

3. **超时后 worker 与 caller 的生命周期**：caller demonitor 了 worker（flush）。worker 变成"孤儿"（无 monitor，但 spawn_monitor 只是单向监控，worker 不依赖 caller）。worker 继续跑完，发 `{Ref, Tier}` 给 caller（已放弃，消息进 caller 邮箱？caller 还活着，但排空只做了一次 `after 0`）。**这里可能有邮箱残留**！

   让我仔细看：
   ```
   after judge_timeout_ms ->
       erlang:demonitor(MonRef, [flush]),
       receive {Ref, _} -> ok after 0 -> ok end,   %% 排空可能在途回复
       失败路径
   end
   ```
   
   排空只做一次（receive 匹配到一条即退出）。如果 worker 在 caller 超时后**稍晚**才发 `{Ref, Tier}`，此时排空的 `after 0` 已经因为邮箱空而跳过（`after 0` 立即返回）。然后 worker 发消息，进入 caller 邮箱，**残留**。

   消息格式 `{Ref, Tier}`，Ref 是唯一 make_ref。残留消息会永久留在 caller 邮箱（除非有人匹配）。caller 是 HTTP handler 进程，处理完这个请求后可能复用（keep-alive）或退出。如果复用，邮箱里堆积死消息，泄漏内存。

   等等，但设计说"无邮箱残留（选择性接收 + 显式排空双保险）"。这个说法**不成立**。显式排空只做一次 `after 0`，无法保证后续到达的消息被清掉。

   这是**新引入的问题**吗？让我看 v2.4 的超时处理。v2.4 是 "kill"。kill 会终止 worker，worker 的 after 会释放信号量……但 v2.4 的问题正是 kill 绕过 after 导致泄漏。所以 v2.4 用 kill。现在改为不 kill，引入了邮箱残留问题。

   实际上，超时后 worker 仍存活并发消息，这是必然的。要避免邮箱残留，需要：
   - worker 发消息前检查 caller 是否还想要（复杂）
   - caller 每次 receive 都带超时并持续排空（复杂）
   - 或者用不同的机制（如 ETS 传递结果而非消息）

   设计中的"排空双保险"实际上是一个 `after 0` 的单次排空，只能清掉**已经到达**的消息，无法清掉**超时后才到达**的消息。所以有邮箱残留风险。

   这个残留的严重性：每条残留是一个 2 元组（ref + tier atom）。Ref 是 make_ref 的引用（64-bit 或更大）。残留数量 = 超时次数。如果 judge 挂死，每次超时都残留一条。在熔断触发前最多 5 条（然后熔断 60s）。熔断期间不 spawn worker，无新残留。熔断解除后又 5 条。所以残留速率约 5 条 / 60s。对于长期存活的 handler 进程，会缓慢积累。但对短命的 handler 进程（每个请求一个进程），进程退出时邮箱自然清空。这取决于部署架构。

   呃，这是一个**真实的缺陷**。设计声称"无邮箱残留"，但机制不保证。

   不过，严重性取决于 handler 进程的生命周期。如果 HTTP handler 是 per-request 进程（常见），残留随进程退出消失，无害。如果 handler 是长驻进程（如某些连接池），则泄漏。

   我认为这值得指出。这是一个新引入的（或至少是修订没考虑到的）问题。

   实际上，等等，让我重新读。原 v2.4 用 kill，设计者认为 kill 有信号量泄漏。现在改为不 kill。但不 kill 就有邮箱残留。两者是 tradeoff。设计的"双保险"排空不足以消除残留。

   这是一个实质问题（影响可用性/内存）。

4. **另一个问题**：worker 的 acquire 失败发 `{Ref, skip}`。caller 收到 skip 后 demonitor。但 worker 发完 skip 就退出了。caller 收到 skip 后 demonitor 是 OK 的（可能已经 DOWN，flush 掉）。OK。

   但顺序问题：worker acquire 失败，发 `{Ref, skip}` 并退出。`spawn_monitor` 会先投递 `{Ref, skip}` 再投递 `{'DOWN', ...}` 吗？还是可能 DOWN 先到？在 Erlang 中，消息投递顺序：同一对进程间保证顺序。worker 发 `{Ref, skip}` 然后退出产生 DOWN。这两个消息都发给 caller。worker→caller 的消息，以及 DOWN（也源于 worker）。Erlang 保证：从同一发送方到同一接收方的消息有序。`{Ref, skip}` 是 worker 发的，DOWN 是运行时发的（但代表 worker 死亡）。**顺序不保证**！因为 DOWN 是系统消息，可能先于用户消息到达。

   实际上，Erlang 的 monitor DOWN 消息与普通消息的相对顺序**不保证**。所以 caller 可能先收到 DOWN，走失败路径（负缓存 + 计连败），而 skip 消息随后到达，被……caller 的 receive 已经匹配 DOWN 退出，skip 进邮箱残留。

   这会导致：信号量跳过被误判为失败，计连败。连败 5 次可能误触发熔断。这是**语义错误**。

   嗯，这是个问题。设计 6.2 中 receive 的顺序：`{Ref, Tier}` | `{Ref, skip}` | `{'DOWN', ...}`。如果 DOWN 先到，走 DOWN 分支。skip 后到，残留（且被计为失败）。

   实际上，worker acquire 失败后发 skip 然后正常返回退出。进程正常退出也会生成 DOWN（monitor 收到 `{'DOWN', MonRef, process, _, normal}`）。所以 caller 会既收到 skip 又收到 DOWN。谁先？不保证。

   如果 caller 先收 skip：正确走 skip 路径，demonitor flush DOWN。✓
   如果 caller 先收 DOWN：走失败路径（错误！），然后 skip 残留。✗

   这是一个真实缺陷。需要 caller 在 DOWN 分支检查是否已有 skip（或 worker 用 exit reason 区分：skip 用特定退出码，caller 在 DOWN 里检查 reason）。设计没做这个。

   嗯，等等，实际上更仔细：Erlang 中信号（signals）包括消息和 exit/monitor 信号。文档说："The only guarantee is that signals from the same sender to the same receiver arrive in order." DOWN 由 runtime 发送，sender 严格来说是"worker 的终止"，而用户消息 sender 是 worker。这两个是不同的"发送者"（一个是被监控进程的正常消息，一个是 monitor 机制）。实际实现中，DOWN 消息是 runtime 在进程死亡后发出，而 `{Ref, skip}` 是进程死亡前发出。**Erlang 不保证 DOWN 在用户消息之后到达**，但实践中……

   实际上，根据 Erlang 文档和常见经验，这里确实存在竞态。有些实现会保证"进程死亡前发送的消息先于 DOWN"，但这不被规范保证。稳妥起见，worker 应该用 exit reason 传递 skip（`exit({skip, Ref})`），caller 在 DOWN 里检查 reason。

   所以这也是一个实质缺陷。

   嗯，不过我要谨慎。让我想想是否真的会出错。worker：
   ```erlang
   fun() ->
       case acquire() of
           false ->
               Caller ! {Ref, skip},
               exit(normal);   %% 或直接返回
           true ->
               ... release in after ...
               Caller ! {Ref, Tier}
       end
   end
   ```
   
   `Caller ! {Ref, skip}` 然后进程退出。caller 会收到 skip 消息和 DOWN 消息。Erlang 保证同一进程发送的消息有序，但 DOWN 由 runtime 代发，不是 worker 发的。根据 Erlang 官方文档和实现，用户消息与 DOWN 的相对顺序**没有保证**。实践中，大多数情况下 skip 先到（因为它在 exit 之前），但存在理论上的重排可能。

   标准做法是用 exit reason 传数据，这样 DOWN 里带 reason，caller 从 reason 判断，无需依赖消息顺序。

   所以设计应改为：skip 通过 `exit({skip, Ref})`，caller DOWN 分支处理。或者 caller 在 DOWN 分支也检查邮箱。

   这是值得指出的问题。

5. **worker 的 `{Ref, Tier}` 与 DOWN 顺序**：成功路径，worker 发 `{Ref, Tier}` 然后退出（正常）。同样竞态：caller 可能先收 DOWN（normal）再收 tier。但成功路径 caller 的 receive 三分支，如果先收 DOWN（normal），会走失败路径，把成功当失败！然后 tier 残留。

   这也是同一类问题。**更严重**，因为成功被判失败，计连败，且缓存写回没发生。

   哦不，这确实严重。所有 demo 都受影响。

   嗯，但实际上，实践中 worker 发消息后立即退出，DOWN 通常在消息之后处理。但规范不保证。

   等等，实际上我需要再想想。Erlang 的进程通信：当进程 A 向进程 B 发送消息，然后 A 退出，B 收到 monitor DOWN。B 的邮箱里消息顺序是：A 发的所有消息（有序），以及 DOWN。DOWN 和 A 的消息之间的顺序……

   根据 Erlang 内部实现，当进程退出时，monitor 的 DOWN 消息由 runtime 生成并发送。发送时机在进程真正终止之后。而 A 在终止前调用 `!` 发送的消息已经进入 B 的邮箱
