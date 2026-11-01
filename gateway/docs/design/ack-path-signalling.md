# Ack-path failure signalling

## Origin

`ack_miss` accumulated 99 events against 1261 dispatches (~7.9%) over a
day on the live fleet, all against one worker, with almost all of them
inside a rolling-deploy window. Investigating that rate found two
defects in the dispatch handshake. Neither is the sole cause of the
observed count, and this document says so rather than claiming a fix it
cannot prove — but both are real, both are cheap, and both make the
failure modes legible instead of silent.

### Defect 1 — the worker's rejection never reaches the waiter

A worker that has not finished its hello handshake refuses a job and
tells the master why:

```erlang
do_job(..., #state{hello = Hello}) when Hello =/= acked ->
    maybe_reject(JobRef, MasterSessionPid, not_acked)
```

`maybe_reject/3` sends `{janus_error, JobRef, #{code, message}}` to the
master's session process. The master is not listening for it:

```erlang
wait_ack(JobRef, WorkerNode) ->
    receive
        {janus_job_ack, JobRef, Pid} when is_pid(Pid) -> {ok, Pid}
    after 5000 ->
        {error, ack_timeout}
    end.
```

The rejection arrives in milliseconds, matches no clause, and waits
unread while the caller sits out the full five seconds. The job then
fails over to local execution — correctly — but the operator-visible
reason is `ack_timeout`, which describes a time problem that did not
happen.

`flush_job/1` does eventually consume the message on the timeout path,
so nothing leaks. What is wrong is the five seconds and the label: the
worker answered immediately and said why, and neither fact reaches the
operator.

A rejection that arrives *after* `flush_job/1` has run is a different
case and stays unresolved (open question below).

### Defect 2 — `send_job`'s failure branch is unreachable

```erlang
send_job(WorkerNode, JobMsg) ->
    try
        {janus_worker_dispatch, WorkerNode} ! JobMsg,
        ok
    catch
        _:_ -> {error, send_failed}
    end.
```

The `catch` cannot fire. A `!` to a `{Name, Node}` tuple returns the
message whether the node is reachable, the name is unregistered, or the
node does not exist at all — verified experimentally:

| Expression | Result |
|---|---|
| `{name, 'unreachable-node'} ! hello` | `hello` (dropped) |
| `erlang:send({name, Node}, M, [noconnect])`, node down | `noconnect` |
| `erlang:send({name, Node}, M, [noconnect])`, name missing | `ok` |

So the `send_failed` classification is dead code: it is 0 by
construction, not because sends never fail. A dispatch to a node the
mesh has lost is reported, five seconds later, as `ack_timeout`.

## Goals

- A worker's explicit rejection resolves the wait immediately, with the
  worker's own reason, instead of after the deadline.
- A dispatch to a node the master is not currently connected to resolves
  immediately through the existing `send_failed` path. This is a
  weaker claim than "undeliverable": the node may be alive and about to
  reconnect.
- The failure classification distinguishes: rejected by the worker,
  undeliverable, and genuinely unacknowledged.
- No behaviour change on the success path.

## Non-goals

- Eliminating `ack_timeout`. A worker that accepts the message and then
  fails to ack within the deadline is a real case and keeps its
  timeout.
- Detecting an unregistered process name on a reachable node. No
  primitive exposes that before delivery; `send/3 [noconnect]` only
  reports link loss. A message to a live node with no such name is
  silently dropped by design, and the ack deadline is the only backstop.
- Retrying a rejected job on a different worker. Rejection means the
  worker is not ready; local fallback is the existing, correct
  behaviour.

## Design

### Receiving the rejection

`wait_ack/2` gains a clause for the error the worker actually sends:

```erlang
receive
    {janus_job_ack, JobRef, Pid} when is_pid(Pid) -> {ok, Pid};
    {janus_error, JobRef, #{code := Code, message := Msg}} -> {error, {worker_rejected, Code, Msg}}
after Deadline -> {error, ack_timeout}
end
```

The job reference is matched, so an error for another job cannot be
consumed — the existing strict-ref discipline is preserved.

The caller then runs the same teardown as the timeout path — `mark_dead`,
`cancel_dispatch`, `flush_job` — with ONE deliberate difference:

| Path | Reservation | Why |
|---|---|---|
| `ack_timeout` | `sched_suspect` (phantom until purge) | the worker may still be running the job |
| `worker_rejected` | `sched_release` (freed now) | the worker never admitted it — dispatch returned unchanged, no session spawned |

The other two differences are the metric (`worker_rejected` instead of
`ack_miss`) and the latency (milliseconds instead of the deadline).

### Metrics

`dispatch_local_total` gains `worker_rejected` alongside `ack_miss`.
This is the point of the change: an operator reading the counter should
be able to tell "the worker said no" from "the worker never answered".

### Undeliverable dispatch

`send_job/2` uses `erlang:send/3` with `[noconnect]`:

```erlang
send_job(WorkerNode, JobMsg) ->
    case erlang:send({janus_worker_dispatch, WorkerNode}, JobMsg, [noconnect]) of
        ok -> ok;
        noconnect -> {error, send_failed};
        Other -> {error, send_failed}
    end.
```

This makes the existing `send_failed` branch reachable for the one case
it can actually detect: the master has no connection to that node. The
caller already handles it (release, note, local execution).

The `nosuspend` option is deliberately NOT used: the pool's mailbox is
not a bottleneck at this dispatch rate, and `nosuspend` would introduce
a new blocking classification (`{error, {nosuspend, _}}`) that this
change does not need.

### What stays the same

- The success path is byte-identical.
- **Totals do not fall; reasons shift.** A dist flap — which is exactly
  what a rolling deploy produces — will reclassify those dispatches from
  `ack_miss` to `send_failed`, and a not-yet-acked worker from
  `ack_miss` to `worker_rejected`. Both still end in local execution. Any
  dashboard or alert keyed on `ack_miss` must not read the drop as a
  fix; the new reasons carry the same volume.
- `ack_timeout` keeps its 5 s deadline and its `ack_miss` metric.
- Local fallback on every failure path is unchanged.
- Reservation handling is unchanged on `ack_timeout` and on
  `send_failed`, where Part 2 of `worker-capacity-override.md` covers the
  phantom-slot consequence.

  **A rejection is different and IS released immediately.** The worker
  never admitted the job — dispatch returned its state unchanged without
  spawning a session — so `sched_release/1` is safe here in a way it is
  not for a timeout, where the job may still be running on the node.
  Deferring a rejection to the 10-minute purge would leave a phantom slot
  for the very event class this document is about.

## Invariants

1. A rejection is consumed by the waiter for its own job ref only.
2. No path reports `ack_timeout` for a failure that was signalled
   explicitly.
3. `dispatch_local_total`'s dispatch-failure reasons (`send_fail`,
   `ack_miss`, `worker_rejected`, and the pick reasons) sum to the number
   of local fallbacks caused by dispatch problems. The Part-E reasons
   (`unary_fallback`, stream pre-byte fallback) are a different class and
   are excluded.
4. Every failure path still ends in local execution, never in a dropped
   request.

## Failure modes to guard

| Failure | Behaviour |
|---|---|
| Worker rejects (not acked, invalid job) | Waiter returns `{worker_rejected, ...}` immediately; `worker_rejected` counter; local execution |
| Master is not currently connected to the node | `erlang:send/3` returns `noconnect`; `send_failed` counter; local execution. A node mid-reconnect lands here even if it is healthy |
| Node reachable, name absent, no ack | Unchanged: `ack_timeout` after the deadline (undetectable, documented above) |
| Error message for a DIFFERENT job ref lands first | Not consumed by this waiter; its own ref still resolves it |
| Worker sends an error AFTER its ack | The ack wins and the wait returns; the error is then consumed by the `remote_unary`/`remote_stream` receive loops, which already match it as a job-level error. Only an error arriving after the job's done is unread, which is the existing behaviour |
| `erlang:send/3` raises | Not reachable with a well-formed `{atom(), node()}` dest — the pool only vends atom node names. The old `try/catch` would have degraded a malformed dest to `send_failed`; dropping it means such a bug crashes the session instead of hiding. Accepted: the module's other helpers swallow, and this one should not mask a programmer error |
| Handler dies between `send_job` and `wait_ack` | The rejection lands in a dead mailbox; the reservation is released only by the purge. No cross-request pollution (Cowboy spawns a fresh handler) |
| A `hello = nacked` worker rejects every job | Each rejection is fast and local-fallback'd; no loop, but the rate equals the dispatch rate to that node until it re-hellos |
| `cancel_dispatch` toward a rejecting worker | A no-op — the worker never admitted the job. Harmless |
| Metric label | `worker_rejected` is a new atom in an existing free-form counter, not a schema change |

## Open questions

- Should a `worker_rejected` miss count toward the same failure budget
  that demotes a node, or is a not-yet-acked worker a startup condition
  rather than a fault?
- The late-error-in-mailbox case leaves one message behind per such
  job. Is a periodic flush worth it, or is the volume too low to
  matter?
