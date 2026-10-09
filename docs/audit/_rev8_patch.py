import io

p = 'docs/superpowers/plans/2026-10-08-native-distribution.md'
s = io.open(p, encoding='utf-8').read()

def rep(old, new, tag):
    global s
    assert old in s, tag
    s = s.replace(old, new, 1)

rep('# Native Erlang Distribution for the Janus Fleet — SPEC (rev 7)',
    '# Native Erlang Distribution for the Janus Fleet — SPEC (rev 8)', 'title')

rep('''**Goal.** The three production gateways (aliyun leader, jdcloud +
tencent followers) behave as one Erlang cluster for *ephemeral runtime
signals*''',
'''**Rev 8 — operator enhancement "full Erlang power":** adds Part F
(erpc fleet command channel with a CLOSED command enum + pg leader
lease) and pulls the former phase-3 payloads (quota gossip, judge
decision-cache sharing) into scope as Part B2 — all under the same
Part 0 failure-mode discipline. The non-goals list is amended, not
overturned: mnesia/global/raft stay out; cross-node REQUEST
forwarding stays out (the data plane never proxies agent traffic
through a peer); what is added is remote code execution for
control-plane commands and self-expiring advisory payloads only, with
remote spawn explicitly rejected (F.3).

**Goal.** The three production gateways (aliyun leader, jdcloud +
tencent followers) behave as one Erlang cluster for *ephemeral runtime
signals*''', 'goal')

rep('''**Non-goals.** No mnesia, no `global`, no cross-node request
forwarding/proxying, no distributed config writes, no hot code
upgrades, no Raft/consensus.''',
'''**Non-goals.** No mnesia, no `global`, no cross-node request
forwarding/proxying (agent traffic NEVER transits a peer), no
distributed config writes, no hot code upgrades, no Raft/consensus.
Remote execution (Part F) is a CLOSED enum of control-plane commands —
never arbitrary module:function:args, never secrets, never agent
payloads.''', 'non-goals')

PART_B2_F = '''## Part B2 — Quota gossip + judge decision-cache sharing (former phase 3, now in scope)

Both payloads ride the same `{janus_fleet, 1, _}` channel, mirrors,
TTLs, ingress validation, and local-wins discipline as Part B.

**Quota counters (Slice Q fleet view).** Each node publishes, on a
**2 s coalesced heartbeat** (and immediately on a counter crossing
80% of its limit), `{quota, AgentKeyId, WindowSec, {Used, Limit},
2_000}` per (agent key, window) it has local evidence for. Receivers
upsert per-(sender, key, window). Consumption at pick time uses
`max(local, highest live remote)` — a key hot on ANY node is shed
earlier fleet-wide — but enforcement stays local and the Part B
last-resort rule applies verbatim: a remote quota row never creates a
hard reject where local evidence would allow, and would-be-empty
candidate sets ignore remote rows. TTL 2 s (one heartbeat); partition
degrades to today's per-node counters. Row cap 8 192/sender as Part B.

**Judge decision-cache sharing (janus-auto).** On a LOCAL cache MISS
that is then fetched and cached, the node publishes
`{cache_put, Hash, Tier, JudgeModel, TTLms}` — miss-only (a hit never
publishes; no invalidation storm). Receivers write into their local
decision cache with the SAME TTL on their own clock (durations, never
absolutes — the clock-skew rule). Entries are pure
(tier + judge model name): idempotent, replay-safe; a poisoned entry
self-expires and its blast radius is one routing decision the judge
would have made anyway. Sender validity is the handshake-cert
boundary from Part 0.6 — no new trust surface.

## Part F — Full-power control plane: erpc fleet commands + pg leader lease

**F.1 Closed-enum fleet commands.** The admin plane (:8090,
token-authed as today) gains `POST /stats/fleet/command` with a
CLOSED command enum; each name maps to one exported, audited,
idempotent function — NEVER arbitrary MFA. v1 enum:

- `fleet_status` — read-only fan-out: each peer's
  `janus_fleet:status/0` (what /stats.fleet shows locally) gathered
  in one call.
- `config_reload_nudge` — `erpc:call(Peer, janus_config, reload, [])`
  (idempotent; makes the generation poll immediate after a dashboard
  write).
- `catalog_cache_flush` — the pure-local idempotent cache clears.
- `lb_cool_clear {target}` — clears that target's LOCAL cooldown row
  on every peer (operator un-stick; guards identical to Part B).

Mechanics: parallel `erpc:call(Peer, M, F, A, 5_000)` per peer;
results aggregated per node as `{ok, Result} | {error, Class,
Reason}`; a down peer is `{error, noconnection}` and PARTIAL SUCCESS
IS SUCCESS (advisory cluster — no quorum, ever). Every command is
audited locally (actor/command/per-node results). Version skew during
rolling deploys: an unknown command on an old node returns
`{error, undef}` per-node and is reported; nothing crashes.

**F.2 pg leader lease (no global, no Raft).** Guards cross-node
singleton duties — v1: de-duplicating the quota-heartbeat publisher
(a second publisher is only the Part-0.4-bounded storm, so dual-hold
is benign by construction; the lease is an optimization, never an
availability gate). Design: holder = the LOWEST node name among live
pg members (deterministic, zero election traffic); each node ticks a
5 s lease check; on holder `nodedown`, the next-lowest claims within
net_ticktime + 5 s. `/stats.fleet.lease` reports
`{holder, expires_in_ms}`; `fleet_lease_holder` metric is 1 on the
holder, 0 elsewhere. Split-brain dual-publish is accepted and bounded
(storm invariant), documented.

**F.3 Remote spawn is NOT exposed.** `spawn/4` on a peer, arbitrary
MFA over erpc, and node()-addressed sends of non-enum payloads are
REJECTED: a remote-execution backdoor across three clouds exceeds its
value. The F.1 enum is the entire remote-execution surface; growing
it requires a spec revision (auditable drift).

'''

rep('## Part C — Observability', PART_B2_F + '## Part C — Observability', 'partF')

rep('- `/metrics` gains `fleet_signals_tx_total`,',
    '''- `/metrics` gains `fleet_commands_total{command, outcome}`,
  `fleet_lease_holder` (1 on the holder, 0 elsewhere), and Part B's
  signal counters; `/stats.fleet` additionally reports the last 20
  fleet commands (ring, with per-node results) and
  `lease {holder, expires_in_ms}`.
- `/metrics` gains `fleet_signals_tx_total`,''', 'obs')

rep('''Phase 3 (separate spec revision, not implemented in v1): quota counter
gossip (~2 s cadence, documented approximation) and judge
decision-cache sharing (`{cache_put, Hash, Tier, JudgeModel, TTL}` on
miss only).''',
'''6. **F.6 quota gossip:** drive a key's traffic at gw1 only until
   its local counter crosses 80%; assert gw2's quota mirror shows the
   row within one heartbeat (≤ 3 s) AND a gw2 pick for that key sheds
   earlier than gw2's own local counter would justify (upstream mock
   counter deltas prove it); last-resort: with the key's only route
   healthy and zero local evidence at gw2, the single-sender row sheds
   nothing (visible in /stats only).
7. **F.7 fleet commands + lease:** `fleet_status` via gw1's admin
   plane returns all three nodes' fleet state in one call;
   `lb_cool_clear` removes a cooled target's row on ALL nodes;
   pausing the lease holder moves the lease to the next-lowest node
   within net_ticktime + 5 s (single holder observed); an unknown
   command name returns per-node `{error, undef}` with zero crashes.

Phase 4 (separate spec revision): dashboard-side video pending sweep
onto the lease; fleet-coordinated rolling-deploy drain; DNS-based
peer discovery if the fleet ever outgrows static peers.''', 'gate67')

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('spec enhanced to rev 8')
