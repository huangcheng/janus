# Capacity override and reservation integrity

## Origin

Two operational defects surfaced on the same fleet within one day. They
are documented together because they interact: the second makes the
first impossible to reason about.

**Defect 1 — capacity is a boot-time constant.** A worker declares
`JANUS_WORKER_CAPACITY` in its environment; the value rides the hello
into the master's member map and `reserve_loop/5` refuses a candidate
whose reservation count exceeds it. Changing it means editing `.env`
and recreating the container — a dispatch outage for a number an
operator may tune twice an afternoon, and the only remedy when a VPS is
resized in place (upward leaves capacity unused, downward over-admits).

**Defect 2 — reservations leak on ack timeout.** Observed live: a
worker reporting `inflight = 25` while its host sat at `load average
0.10` and 1% CPU. No 25 requests were running. `ack_miss` events were
arriving at 1–3 per minute on that node and every one of them leaves a
reservation behind. The counter therefore measures "jobs that were
dispatched and never acknowledged", not work in progress — and it is
the same counter the scheduler uses for load comparison and the
dashboard uses for the capacity cell.

The leak is not merely cosmetic. `reserve_loop/5` compares it against
capacity, so a node accumulates phantom load until it looks busy,
`sort_tier/2` demotes it on inflight, and the numbers an operator would
use to decide a capacity change are wrong. Fixing capacity without
fixing the counter would mean tuning a ceiling against a lying gauge.

## Part 1 — Operator-adjustable capacity

### Goals

- Change a worker's capacity from the dashboard: no redeploy, no
  container restart.
- Effective after the config poll (2 s) plus one flush window on a busy
  pool, and unconditionally within one tick on an idle one. The poll is
  the floor: a settings write reaches no node's memory before it.
- The declared value stays the default; an unset override changes
  nothing.
- Survives master restarts (Postgres, not memory).

### Storage and precedence

New settings key `worker_capacity`, a JSON object from worker long name
to integer ceiling:

```json
{ "janus@10.0.0.5": 48 }
```

Resolution, highest first:

1. `worker_capacity[node]` when present and valid.
2. The `capacity` the worker declared in its hello.
3. `infinity` when the worker declared nothing.

`declared_capacity` in this document always means the post-clamp value:
`normalize_capacity/2` maps 0/negative/garbage to **1** (with a
warning) and `undefined` to `infinity`, so a worker configured with `0`
declares `1`, not `0`, and "the declared value applies" on the read
path means `1`.

### Why settings, not a dashboard-local table

The worker note lives in a dashboard-owned table the gateway never
reads. That is the wrong precedent: an override written there would
persist in Postgres and reach the scheduler never.

The correct pipe is `janus_config:distribute_settings/1`. It requires
three additions, none optional:

1. A new clause in that function. Its shape is an explicit allow-list
   with a `(_) -> ok` catch-all, so a new key is consumed by nobody
   until the clause exists.
2. A `maybe_clear_absent/3` entry so deleting the whole row clears the
   in-memory override instead of leaving a stale one forever.
3. A dirty-poke into the pool, so republish does not wait for an
   unrelated worker event (see Read path). No such hook exists today:
   `distribute_settings/1` is a plain `lists:foreach` over settings
   rows writing `persistent_term`, and its only inbound path from the
   codebase is the `{sched, 2, {touched, Node}}` cast. The change adds
   a distinct inner tag plus its `handle_cast` clause; an unrecognised
   tag is dropped and counted by the existing catch-all, so the tag
   name must be added deliberately rather than guessed.

### Read path

Two functions emit a capacity and both must resolve the override, or
the feature appears broken exactly where the operator is looking:

| Function | Consumer |
|---|---|
| `build_snapshot/1` | `reserve_loop/5` via `candidate_capacity/2` — the enforced number |
| `v1_candidates/1` | the `pick_sync/1` path — **capacity-blind by construction**: `select/2` never calls `reserve_loop/5`, never touches `?RESERVE`, and never reads `capacity`. An override cannot be enforced there, and adding the key to its output would be dead data. Listed so the gap is recorded, not so it is "fixed" — adding enforcement there would change a path nothing in production routes through (`pick/1` reads `?SNAPSHOT` directly) |
| `workers_view/6` (member branch) | `/stats/sched` → `/api/nodes` → the dashboard cell being edited |

All three call one shared `effective_capacity/2`.

`workers_view/6` has a second, sticky-drained branch that hardcodes
`capacity => infinity` and `inflight => 0`. It is left alone: a
sticky-drained node takes no new work, so an override there is
meaningless. The requirement applies to the member branch.

**Staleness is real.** `build_snapshot/1` runs in the pool gen_server;
`pick/1` reads a cached ETS row. Republish happens on `sched_flush`
only when dirty (≤ 250 ms, and a no-op when already dirty) or
unconditionally on the 30 s tick. A settings write marks nothing dirty,
so on a fully idle pool an override waits for the tick. The poke makes
the fast path real; without it the goal "next pick" is false and must
be deleted rather than aspired to.

### Dashboard

The `In-flight / Capacity` cell becomes editable. Two corrections to
the obvious approach:

- **Do not copy the note cell's error handling.** `saveNote` closes the
  editor before awaiting the fetch, so a failed save shows a toast with
  no revert. A capacity edit that silently fails is worse than no
  editor: the operator believes the host is protected when it is not.
- **The write path is a settings mutation.** Use the settings PUT
  shape: a transaction with `SELECT … FOR UPDATE`, merge in-transaction,
  then `bump_generation`. A read-modify-write without the lock loses
  another operator's edit of a different node in the same JSON object.

### Validation

Reject at write time with 400: non-integer, `< 1`, above an explicit
maximum, or a name that is not a well-formed Erlang long name.

The live member list is NOT a safe validation source: it excludes
drained-sticky and not-yet-hello'd workers, so an override written
before a worker's first hello would be wrongly rejected. Member
matching therefore happens at read time, where an unknown name is
ignored with a warning (and becomes effective if that worker later
joins).

Convert with `binary_to_existing_atom` only — the input is
operator-supplied and `list_to_atom` on it is an unbounded atom-table
fill vector.

At read time a malformed stored value is ignored with a warning and the
declared value applies; a bad row must not take a node out of rotation.

### Soft-cap holes (documented, not closed)

Capacity is not a hard cap. Two gaps predate this work and this spec
does not close them:

- **Affinity-pinned picks bypass it.** `reserve_loop/5` skips the check
  when the pick is pinned, so a lowered ceiling does not throttle
  pinned traffic.
- **Master-local fallback is uncapped.** Exhausting every candidate
  routes to local execution with no ceiling. Lowering a capacity
  therefore moves overflow onto the master rather than into a wall.

Both must be visible to the operator, because both change what "lower
the ceiling" actually buys.

## Part 2 — Reservation integrity

### The defect

Four paths release nothing and leave the reservation tracked until
purge. The comment on each states the intent as a deliberate policy
("spec Part 0.11"): the slot is kept because the worker may still
deliver.

| Path | Location | On timeout |
|---|---|---|
| Ack timeout | `wait_ack/2` → the `{error, ack_timeout}` branch | cancel, `flush_job`, execute locally, **no release** |
| Pre-first-byte timeout | `stream_preflight/6` → `after deadline_remaining(Deadline)` | cancel, `flush_job`, **no release** |
| Unary timeout | `remote_unary` → `after Timeout` | cancel, `flush_job`, **no release**, no fallback |
| Stream total timeout | `stream_drain_timeout/4` | cancel, `flush_job`, **no release** (its inactivity arm does release) |

Four, not three: the pre-first-byte arm leaks on the same path that a
live brownout exercises, so enumerating it is not bookkeeping.

`PURGE_AGE_MS` is 600 s and purge runs on the 30 s tick, so a slot can
stay phantom for up to ~630 s. On the live fleet this produced
`inflight = 25` on a host at `load average 0.10`, with `ack_miss`
arriving at 1–3/min and `reserve_purged` at 357.

The number is not cosmetic: it is the scheduler's load comparison input
(`live_snapshot/2` feeds `sort_tier/2` from `reserve_count_live/1`), the
capacity cell's numerator, and the admission counter `reserve_loop/5`
compares against capacity.

### Why the slot is kept (and where that reasoning stops)

Keeping the reservation is correct during the *late-ack window*: an ack
that merely lost the 5 s race means the job runs on both the node and
the master, and freeing the slot would let the node over-admit. The
policy is wrong only in duration — ten minutes is not a late ack, it is
an absent one.

### Two quantities, not one

A single counter cannot both account for the slot and exclude it from
the load figure. Reviews of the first draft of this section established
that the "mark it suspect and hide it from the load number" idea is
unsatisfiable against the current data model, because:

- `inflight` everywhere is the raw `?RESERVE` counter, not a scan of
  the tracked table;
- the tracked row is `{JobRef, {Node, ReservedAt, ProviderId,
  Internal}}` with **no process id**, so liveness is not derivable;
- ack-miss is not uniquely identifiable from the row — the two other
  timeout paths leave identical rows.

This spec therefore splits the accounting explicitly:

- **`?RESERVE` keeps its meaning: the admission slot.** It includes a
  pending reservation for its whole life, however the job ended. This
  preserves the over-admission protection.
- **A second per-node counter tracks *suspect* slots** — reservations
  whose owning job is known to be dead. The load figure becomes
  `inflight := reserve − suspect`.

`reserve_loop/5` continues to admit against `?RESERVE`, unchanged.

**Which number each consumer sees is the central decision of this
part, and it is per-consumer, not global:**

| Consumer | Reads | Why |
|---|---|---|
| `reserve_loop/5` (`:433-441`) | `?RESERVE` | Admission must stay conservative — over-admission takes a host down |
| `live_snapshot/2` → `sort_tier/2` | `reserve − suspect` | A node recovering from a dist hiccup must not be demoted for work that is already dead |
| `workers_view/6` (`:3315`) | `reserve − suspect` | The cell must show real work, since it is the number an operator tunes against |
| `reconcile_counters/2` | `?RESERVE` vs `expected_by_node/1` | Unchanged healing of the admission counter |

Two *different* functions need the subtraction, and conflating them is
the trap:

- `live_snapshot/2` already calls `reserve_count_live/1`, and that
  function has exactly one caller — so the sort path's subtraction goes
  there, leaving `sort_tier/2`'s key (`sort_key_plain/2`) untouched.
- `workers_view/6` calls `reserve_count/1`, which is ALSO used by
  `reconcile_counters/2` and by `node_drain_idle_ready/1` (whose
  `noninternal_tracked_empty/1` depends on it) — all of which must keep
  reading the raw counter. Putting the subtraction inside `reserve_count/1` would
  corrupt reconcile and drain-idle. `workers_view/6` therefore subtracts
  inline, or through a dedicated helper used only by it.

The spec names both sites because the obvious shortcut — one shared
loader — is exactly what breaks the other three callers.

The consequence of the split must be stated plainly rather than
papered over:

> `capacity_exhausted` still counts suspect slots. A node recovering
> from a dist hiccup can refuse new work while the dashboard shows a
> low load figure.

That is a deliberate trade: the alternative (admitting against
`reserve − suspect`) converts a phantom-load problem into an
over-admission problem, and over-admission is the failure that takes a
host down. Invariant 4 below is weakened accordingly.

### Who marks a slot suspect

The timeout paths already know the job is dead: each calls
`mark_dead/1` and `flush_job/1` immediately after cancelling. That
transition is the discriminator — not the row's age, and not a process
id that the row does not carry.

One of the three arms must be excluded: `stream_drain_timeout/4`'s
**inactivity** arm already calls `sched_release/1`, so its reservation
is gone before any suspect marking could apply. The suspect bump must
therefore be a no-op when the tracked row is absent, and only the four
non-releasing arms (ack timeout, pre-first-byte timeout, unary timeout,
stream total timeout) mark.

Marking rides the existing `{sched, 2, …}` cast class — addressed to
`?SERVER` (the `janus_worker_pool` gen_server), NOT the caller-side ETS
style that `release/1` uses. Each timeout arm casts
`{sched, 2, {suspect, JobRef}}` after `mark_dead/1`; the pool resolves
the job's node from the tracked row it still holds, bumps that node's
suspect counter, and keeps the row in place. A no-op when the row is
absent (the inactivity arm's case).

The `handle_cast` catch-all drops and counts unrecognised inner tags, so
the new tag must be added as an explicit clause — an unnamed tag is
safe but invisible in metrics.

### Releasing a suspect slot exactly once

The danger the reviews flagged is double-decrement: a suspect slot that
is later resolved by purge would free the reservation *and* leave the
suspect counter, driving the load figure negative and the node into
permanent over-admission. Two rules prevent it:

1. **The suspect counter is decremented in exactly the place the
   reservation is taken** — `take_and_maybe_decrement/1` is the single
   owner of both, so a slot cannot be freed without its suspect
   component being freed with it.
2. **Every row-shape site must be updated in the same change.** The
   4-element tuple is matched or constructed positionally at these
   places, and a fifth element silently breaks each one:

   | Site | Kind |
   |---|---|
   | `reserve_loop/5` tracked insert (`Internal => false`) | construct |
   | probe tracked insert (`Internal => true`) | construct |
   | `take_and_maybe_decrement/1` | match |
   | `node_tracked_refs/1` | match |
   | `purge_tracked/2` | match |
   | `expected_by_node/1` | match |
   | `noninternal_tracked_empty/1` | ETS match spec `{{'$1', {Node,'_','_',false}}, …}` — a 5-tuple makes the spec match nothing, so drain-idle reads "empty" and stalls |
   | `tracked_row/1`'s callers | match on the returned inner tuple — `tracked_row/1` itself does not |

   This enumeration is the highest-risk part of the change. An
   implementation that adds the field without walking all of them
   corrupts drain-idle and reconcile silently.

`reconcile_counters/2` heals `?RESERVE` toward `expected_by_node/1`;
the suspect counter needs the same treatment (or must be derived, not
stored) or the 30 s tick will drift it.

### Late acks

A late ack cannot resolve a timed-out reservation: `flush_job/1`
scrubbed the mailbox before this design ever runs. The first draft's
"a late ack still resolves it" was false and is removed. What a late
ack *can* do is arrive on a job whose reservation was released for
another reason (worker lost) — that path is unchanged.

### What this does not fix

- The timeout still routes to master-local execution on the ack path,
  which is uncapped. The master absorbs the work.
- A lost cancel can leave the worker executing a job the master
  considers dead. That already exists and is unchanged here.
- Suspect slots are plain ETS state and do not survive a master
  restart; after a restart they read as ordinary reservations until
  purge.

## Invariants

1. Removing an override restores the declared value exactly.
2. Admission stays atomic: `reserve_loop/5` keeps its
   increment-then-compare-then-rollback shape.
3. A malformed settings row leaves the fleet unchanged, with a warning.
4. Both masters resolve the override from the same Postgres row.
5. A reservation is freed exactly once, whether by release, cancel,
   timeout resolution, or purge — and its suspect component is freed in
   the same operation.
6. The load figure never goes negative.
7. **Weakened deliberately:** `capacity_exhausted` may be raised by
   suspect slots, because admission counts `?RESERVE` rather than
   `reserve − suspect`. Operators must read the two numbers together.

## Failure modes to guard

| Failure | Behaviour |
|---|---|
| Stored override is 0, negative, or non-integer | Ignored with a warning; declared value applies |
| Settings row deleted whole | `maybe_clear_absent` clears it; every node reverts |
| Settings row is malformed JSON | Whole key ignored; fleet unchanged |
| Override names a node that has since left | Ignored at read time (already rejected at write time) |
| Master restarts | Re-read from Postgres on boot |
| Dashboard write fails | Editor keeps the old value and reports it; no optimistic state |
| Override lowered below inflight | New picks refused and rolled back; in-flight requests never killed |
| …with every candidate exhausted | Uncapped master-local fallback — operator must be told |
| Affinity-pinned pick on an over-capacity node | Admitted anyway; a ceiling does not throttle pinned traffic |
| Override targets a sticky-drained node | Ignored; the node takes no new work regardless |
| Two operators edit different nodes concurrently | Serialised by `SELECT … FOR UPDATE` |
| Ack lost past the deadline | `flush_job` has already scrubbed it; the slot stays until purge, then is freed once (reservation and suspect together) |
| Suspect slot reaches purge | `take_and_maybe_decrement/1` frees reservation and suspect in the same operation — never twice |
| Suspect counter drifts | Healed on the same tick as `?RESERVE`, or derived rather than stored |
| Master restarts with suspect slots outstanding | They read as ordinary reservations (ETS is not persisted); purge frees them |
| Probe (Internal) row times out | Never marked suspect — it held no reservation to begin with |
| Lost cancel: worker finishes a job the master calls dead | Unchanged by this spec; the worker's report is dropped via `mark_dead` |
| Override raised above the declared value | Allowed — the operator may know the host was resized; no cap is invented |
| A pre-fix worker's hello still declares the old value | The override wins at read time, so version skew does not matter |

## Out of scope

- Automatic capacity tuning from observed load.
- Per-provider capacity.
- Rebalancing in-flight work when capacity shrinks.
- Closing the two soft-cap holes.
- Diagnosing why acks are late on a particular host. This spec makes
  the scheduler honest about a timeout; it does not eliminate the
  timeout.

## Open questions

- Should a capacity change pass the break-glass gate used by other
  live-routing mutations?
- Is the generic settings audit entry enough, or does this need one
  carrying previous and new value per node?
- For Part 2, should a suspect reservation be excluded from `inflight`
  only, or also from the dashboard's "dispatched" history? The former
  is required; the latter is a reporting choice.
