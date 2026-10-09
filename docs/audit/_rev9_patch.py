import io

p = 'docs/superpowers/plans/2026-10-08-native-distribution.md'
s = io.open(p, encoding='utf-8').read()

def rep(old, new, tag):
    global s
    assert old in s, tag
    s = s.replace(old, new, 1)

# --- Rev header ---
rep('# Native Erlang Distribution for the Janus Fleet — SPEC (rev 8)',
    '# Native Erlang Distribution for the Janus Fleet — SPEC (rev 9)', 'title')
rep('**Rev 8 — operator enhancement "full Erlang power":**',
    '''**Rev 9 — pi-audit round 1 (7/7 GO WITH FIXES) applied:**
> F.3 restated as RESIDUAL TRUST (erpc has no server-side MFA ACL —
> any cert+cookie peer can execute anything; the enum constrains only
> the admin-token HTTP surface, and Part 0.6 now discloses fleet-wide
> execution as the steal consequence); erpc error contract fixed
> (call/5 RAISES — wrapper catches undef/noconnection/timeout and
> aggregates per-node; unknown names 400 locally, never fanned);
> quota gossip is ADVISORY-ONLY in v1 (mirrors + /stats, never
> consumed by the pick — Slice-Q limits are per-node so cross-node
> merge is undefined; the earlier-shed idea is withdrawn, F.6
> rewritten to observability + no-behavior-change); quota heartbeat
> TTL 6 s (3× cadence), ≥50%-used publish filter, 2-evaluation
> hysteresis on the 80% crossing, WindowId bucket alignment rule;
> cache_put gets its own TTL class (≤ 300 s), per-sender entry cap
> (4 096), JudgeModel-must-match-local-config drop, replay-TTL
> extension accepted and bounded; lb_cool_clear gains a
> {lb_cool_purge, Target} fleet retraction (mirror rows keyed by
> other senders live to TTL otherwise); the lease no longer gates the
> quota publisher (every node publishes its own rows; dual-publish is
> bounded by the filter+cap) — v1 lease duty is observability +
> phase-4 readiness; :8090 boundary change (read-only → idempotent
> fleet commands) is called out for operator sign-off.
> **Rev 8 — operator enhancement "full Erlang power":**''', 'rev9')

# --- B2 quota rewrite ---
rep('''**Quota counters (Slice Q fleet view).** Each node publishes, on a
**2 s coalesced heartbeat** (and immediately on a counter crossing
80% of its limit), `{quota, AgentKeyId, WindowSec, {Used, Limit},
2_000}` per (agent key, window) it has local evidence for. Receivers
upsert per-(sender, key, window). Consumption at pick time uses
`max(local, highest live remote)` — a key hot on ANY node is shed
earlier fleet-wide — but enforcement stays local and the Part B
last-resort rule applies verbatim: a remote quota row never creates a
hard reject where local evidence would allow, and would-be-empty
candidate sets ignore remote rows. TTL 2 s (one heartbeat); partition
degrades to today's per-node counters. Row cap 8 192/sender as Part B.''',
'''**Quota counters — ADVISORY-OBSERVABILITY ONLY in v1.** Slice-Q
limits are PER-NODE (the operator's Slice Q spec); a cross-node merge
is semantically undefined (per-node budgets make remote rows
non-authoritative; shared budgets would need a sum, not a max, plus
exactly-once accounting nobody has). v1 therefore: each node
publishes `{quota, AgentKeyId, WindowId, WindowSec, {Used, Limit},
6_000}` on a **2 s coalesced heartbeat** for keys at **≥ 50 % of
limit** (plus an edge-latched publish when a counter crosses 80 % —
2 consecutive evaluations, latency-coalescer discipline); receivers
upsert per-(sender, key, window) into a `janus_fleet_remote_quota`
mirror that is **read by /stats and /metrics ONLY — the pick path
never consults it**. Behavior with the fleet on is therefore
byte-identical to today (the F.6 gate asserts exactly that);
fleet-aware early shedding is deferred to a spec revision that first
defines budget ownership. TTL 6 s = 3× cadence (jitter margin; the
2 s == TTL flicker is the bug this avoids). **WindowId =
floor(epoch_seconds / WindowSec)** — a pure bucket index, not an
expiry timestamp: receivers compute their own current WindowId and
drop mismatches (clock skew ± s vs ≥ 60 s buckets is immaterial).
Row cap 8 192/sender.''', 'quota')

# --- cache_put rewrite ---
rep('''**Judge decision-cache sharing (janus-auto).** On a LOCAL cache MISS
that is then fetched and cached, the node publishes
`{cache_put, Hash, Tier, JudgeModel, TTLms}` — miss-only (a hit never
publishes; no invalidation storm). Receivers write into their local
decision cache with the SAME TTL on their own clock (durations, never
absolutes — the clock-skew rule). Entries are pure
(tier + judge model name): idempotent, replay-safe; a poisoned entry
self-expires and its blast radius is one routing decision the judge
would have made anyway. Sender validity is the handshake-cert
boundary from Part 0.6 — no new trust surface.''',
'''**Judge decision-cache sharing (janus-auto).** On a LOCAL cache MISS
that is then fetched and cached, the node publishes
`{cache_put, Hash, Tier, JudgeModel, TTLms}` — miss-only (a hit never
publishes; no invalidation storm). Ingress applies cache_put-specific
rules on top of the Part B validation: TTL clamped to its OWN class
(≤ 300 s — the generic ≤ 30 s clamp does not apply); **JudgeModel
must equal the local configured judge**, else the entry is dropped
and counted (rolling-deploy generation lag cannot poison cross-
version routing); a per-sender cache-entry cap of 4 096 (drop+count
beyond); writes are idempotent-upsert keyed by Hash. Receivers write
into their local decision cache with the SAME duration on their own
clock. Entries are pure (tier + judge name). **Replay extends an
entry's life by at most one TTL** — an accepted, bounded deviation
from "no replay" (the payload is beneficial-and-pure; a malicious
replayer extends a correct decision's cache hit, which is harmless).
Blast radius of a poisoned entry: duplicate upstream judge calls
within ≤ 300 s, self-expiring. Sender validity is the handshake-cert
boundary from Part 0.6.''', 'cacheput')

# --- F.1 erpc error contract + purge command ---
rep('''- `lb_cool_clear {target}` — clears that target's LOCAL cooldown row
  on every peer (operator un-stick; guards identical to Part B).''',
'''- `lb_cool_clear {target}` — clears that target's LOCAL cooldown row
  on every peer AND broadcasts `{lb_cool_purge, Target}` (new signal:
  receivers delete EVERY sender's cool-row for that target from the
  mirror — operator override semantics; without the purge, mirror
  rows keyed by other senders would outlive the local clear to TTL,
  re-sticking the pick for ≤ 30 s). Audited like every command.''',
    'coolclear')

rep('''Mechanics: parallel `erpc:call(Peer, M, F, A, 5_000)` per peer;
results aggregated per node as `{ok, Result} | {error, Class,
Reason}`; a down peer is `{error, noconnection}` and PARTIAL SUCCESS
IS SUCCESS (advisory cluster — no quorum, ever). Every command is
audited locally (actor/command/per-node results). Version skew during
rolling deploys: an unknown command on an old node returns
`{error, undef}` per-node and is reported; nothing crashes.''',
'''Mechanics: the enum is validated LOCALLY first (unknown name → 400,
no fan-out); fan-out is parallel `erpc:call(Peer, M, F, A, 5_000)`
per peer **wrapped in try/catch — erpc:call RAISES** (`undef`,
`noconnection`, `timeout` classes), it does not return error tuples;
the wrapper converts caught exits into per-node
`{error, Class, Reason}`. A down peer is `{error, noconnection}`;
PARTIAL SUCCESS IS SUCCESS (advisory cluster — no quorum, ever).
Every command is audited locally (actor/command/per-node results).
Version skew during rolling deploys: a command an old node lacks
raises `undef` there → per-node `{error, undef}`, reported, nothing
crashes (eunit drives the wrapper with a deliberately-missing
function; the gate does not need a skewed cluster). **Boundary
change, operator sign-off:** :8090 goes from read-only to hosting
idempotent fleet commands — same token auth, every invocation
audited.''', 'mech')

# --- F.2 lease duty ---
rep('''**F.2 pg leader lease (no global, no Raft).** Guards cross-node
singleton duties — v1: de-duplicating the quota-heartbeat publisher
(a second publisher is only the Part-0.4-bounded storm, so dual-hold
is benign by construction; the lease is an optimization, never an
availability gate).''',
'''**F.2 pg leader lease (no global, no Raft).** v1 duty:
observability + phase-4 readiness ONLY — it does NOT gate the quota
publisher (quota rows are per-sender; every node publishes its own,
storm-bounded by the ≥50 % filter + row cap; a single-publisher
lease would blind the fleet to keys hot only on non-holders). The
first real duty lands in phase 4 (video pending sweep migration);
until then the lease is reported (`/stats.fleet.lease`,
`fleet_lease_holder`) and gate-asserted to converge, nothing more.''',
    'lease')

# --- F.3 residual trust ---
rep('''**F.3 Remote spawn is NOT exposed.** `spawn/4` on a peer, arbitrary
MFA over erpc, and node()-addressed sends of non-enum payloads are
REJECTED: a remote-execution backdoor across three clouds exceeds its
value. The F.1 enum is the entire remote-execution surface; growing
it requires a spec revision (auditable drift).''',
'''**F.3 Residual trust, stated honestly.** Erlang distribution has NO
server-side MFA allow-list: ANY node holding the fleet cookie + a
valid peer cert can `erpc`/`spawn` ANY exported function on peers.
The F.1 enum closes only the admin-token HTTP surface — it is a
policy on what WE trigger, not a capability the system enforces. The
true boundary is the TLS peer cert (Part 0.6); a stolen fleet key
therefore means fleet-wide code execution, and Part 0.6's residual
paragraph is amended accordingly. This is the accepted cost of
native distribution; the mitigations are the closed HTTP enum (no
convenience foot-gun), audit on every command, CA revocation as the
kill switch, and the dist port being security-grouped to peer IPs.
Growing the enum still requires a spec revision (auditable drift).''',
    'f3')

# --- Part 0.6 residual amendment ---
rep('''   accepted and bounded: signal merge rules limit blast radius
   (quorum, self-limiting TTLs), and revocation = CA reissue. Anything
   failing (a)–(d) is dropped and counted.''',
'''   accepted and bounded **for SIGNAL ingress** (quorum,
   self-limiting TTLs), and revocation = CA reissue. **With Part F,
   the same stolen key additionally enables arbitrary remote code
   execution on peers (Erlang distribution has no MFA allow-list —
   F.3); the cert is the only real boundary.** Anything failing
   (a)–(d) is dropped and counted.''', 'p06')

# --- F.6 gate rewrite ---
rep('''6. **F.6 quota gossip:** drive a key's traffic at gw1 only until
   its local counter crosses 80%; assert gw2's quota mirror shows the
   row within one heartbeat (≤ 3 s) AND a gw2 pick for that key sheds
   earlier than gw2's own local counter would justify (upstream mock
   counter deltas prove it); last-resort: with the key's only route
   healthy and zero local evidence at gw2, the single-sender row sheds
   nothing (visible in /stats only).''',
'''6. **F.6 quota gossip (observability-only):** drive a key's traffic
   at gw1 until its local counter crosses 80%; assert (a) gw2's
   `/stats.fleet` quota mirror shows the row within one heartbeat
   (≤ 3 s), (b) gw2's pick behavior is BYTE-IDENTICAL to a control
   run with the fleet knob off (same upstream hit counts — the pick
   never consults the quota mirror), (c) stopping gw1's traffic → the
   row TTLs out within 6 s + sweeper. No shed is asserted anywhere
   (advisory-only is the spec).''', 'f6')

rep('''7. **F.7 fleet commands + lease:** `fleet_status` via gw1's admin
   plane returns all three nodes' fleet state in one call;
   `lb_cool_clear` removes a cooled target's row on ALL nodes;
   pausing the lease holder moves the lease to the next-lowest node
   within net_ticktime + 5 s (single holder observed); an unknown
   command name returns per-node `{error, undef}` with zero crashes.''',
'''7. **F.7 fleet commands + lease:** `fleet_status` via gw1's admin
   plane returns all three nodes' fleet state in one call; an unknown
   command name → local 400, zero peers contacted (log-asserted);
   `lb_cool_clear` removes a cooled target's LOCAL cooldown row on
   ALL nodes AND its mirror rows on all peers within the cast window
   (purge signal); a peer down (paused) → its slot reads
   `{error, noconnection}` and the command still succeeds on the
   rest (partial-success-is-success); pausing the lease holder moves
   the lease to the next-lowest node within net_ticktime + 5 s
   (single holder observed); eunit drives the try/catch wrapper with
   undef/timeout/noconnection.''', 'f7')

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('rev 9 applied')
