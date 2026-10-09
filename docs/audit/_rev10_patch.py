import io
p = 'docs/superpowers/plans/2026-10-08-native-distribution.md'
s = io.open(p, encoding='utf-8').read()
def rep(old, new, tag):
    global s
    assert old in s, tag
    s = s.replace(old, new, 1)

rep('# Native Erlang Distribution for the Janus Fleet — SPEC (rev 9)',
    '# Native Erlang Distribution for the Janus Fleet — SPEC (rev 10)', 'title')
rep('**Rev 9 — pi-audit round 1 (7/7 GO WITH FIXES) applied:**',
    '''**Rev 10 — pi-audit round 2 (7/7 GO WITH FIXES) folds:** replay
> exception cross-referenced INTO Part 0.2; cache_put replay bound
> made enforceable (per-(sender,Hash) first_seen; expires_at ≤
> first_seen + 2×TTL); quota WindowId boundary rule (accept current
> AND previous bucket); erpc wrapper pinned as
> `try erpc:call(...) catch C:R -> {error,C,R}` with common classes
> documented (undef/noconnection/timeout — F.7 paused peer expects
> `timeout`, not `noconnection`); F.1 command registry pins exact
> M:F:A per name + `function_exported` precheck + strict local arg
> validation (lb_cool_clear target shape) + per-command timeouts
> (fleet_status 1 s/peer, nudge 10 s); ingress byte clamps
> (AgentKeyId ≤ 128 B, Hash = exact 64-hex-char digest); quota
> publishes top-N (32) hottest keys per cycle + aggregate mirror cap
> 8 192/sender across ALL mirrors; `{lb_cool_purge}` + quota +
> cache_put shapes added to the ingress enum; nodedown purge scope =
> ALL signal mirrors (cache_put entries TTL-only — a peer's cached
> decisions remain valid after its death); decision-cache writes via
> an exported janus-auto API, never cross-owner raw ETS; entrypoint
> pre-flight (knob on ⇒ TLS dir/optfile/certs exist, else loud
> exit); F.6 comparison binding pinned single-listing + TF-F.8
> (cache_put round-trip) added; lease `expires_in_ms` →
> `next_check_in_ms`; goal scrubbed of "(phase 3)" wording.
> **Rev 9 — pi-audit round 1 (7/7 GO WITH FIXES) applied:**''', 'rev10')

rep('''self-expiring (lazy expiry on read + a 30 s sweeper, same discipline
   as `janus_lb` cooldowns). No replay, no persistence.''',
'''self-expiring (lazy expiry on read + a 30 s sweeper, same discipline
   as `janus_lb` cooldowns). No persistence. Replay is forbidden on
   every signal EXCEPT one accepted, bounded deviation: a replayed
   `cache_put` extends its entry by at most one TTL, and the enforced
   per-(sender,Hash) bound is `expires_at <= first_seen + 2xTTL` (B2).''', 'p02')

rep('''upsert per-(sender, key, window) into a `janus_fleet_remote_quota`
mirror that is **read by /stats and /metrics ONLY''',
'''upsert per-(sender, key, window) into a `janus_fleet_remote_quota`
mirror — a sender's row for the CURRENT **or PREVIOUS** WindowId is
accepted (bucket-boundary races make a strict match flicker at the
edge; older buckets drop) — that is **read by /stats and /metrics ONLY''',
    'widx')

rep('''on a **2 s coalesced heartbeat** for keys at **≥ 50 % of
limit**''',
'''on a **2 s coalesced heartbeat** for the **top-32 hottest keys ≥ 50 %
of limit** (per-cycle publish cap; AgentKeyId clamped ≤ 128 bytes at
ingress)''', 'topn')

rep('''rules on top of the Part B validation: TTL clamped to its OWN class
(≤ 300 s — the generic ≤ 30 s clamp does not apply);''',
'''rules on top of the Part B validation: Hash must be an exact
64-hex digest; per-(sender, Hash) `first_seen` tracking enforces the
replay bound `expires_at <= first_seen + 2xTTL` (a replying peer
cannot extend an entry past two lifetimes); TTL clamped to its OWN
class (≤ 300 s — the generic ≤ 30 s clamp does not apply);''',
    'cpu2')

rep('''Mechanics: the enum is validated LOCALLY first (unknown name → 400,
no fan-out); fan-out is parallel `erpc:call(Peer, M, F, A, 5_000)`
per peer **wrapped in try/catch — erpc:call RAISES** (`undef`,
`noconnection`, `timeout` classes), it does not return error tuples;
the wrapper converts caught exits into per-node
`{error, Class, Reason}`.''',
'''Mechanics: a **command registry** pins the exact `M:F:A` per enum
name (`function_exported` prechecked; args validated locally —
`lb_cool_clear` target shape checked before ANY fan-out; unknown
name → 400, no fan-out, counter-asserted). Fan-out is parallel
`erpc:call(Peer, M, F, A, Timeout)` with per-command timeouts
(fleet_status 1 s, nudge/flush/clear 10 s), wrapped as
`try erpc:call(...) catch Class:Reason -> {error, Class, Reason} end`
— erpc RAISES; common classes: `undef` (version skew),
`noconnection` (peer down), `timeout` (peer PAUSED — TCP alive, no
answer; F.7 asserts this for a paused peer).''',
    'mech2')

rep('''`fleet_lease_holder` metric is 1 on the
holder, 0 elsewhere.'''
   , '''`fleet_lease_holder` metric is 1 on the
holder, 0 elsewhere; `/stats.fleet.lease` reports
`{holder, next_check_in_ms}`.''', 'lease2')

rep('''- On `nodedown` / `pg` leave: eagerly delete that sender's rows from
  BOTH mirrors''',
'''- On `nodedown` / `pg` leave: eagerly delete that sender's rows from
  ALL signal mirrors (cool, latency, quota); cache_put entries are
  deliberately NOT purged (a departed peer's cached decisions remain
  valid; TTL ≤ 300 s is their bound)''', 'ndown')

# entrypoint preflight
rep('''- Precondition: `JANUS_FLEET_ENABLED=true` ∧ cookie unset ⇒ entrypoint
  exits non-zero with a loud error (Part 0.5).''',
'''- Precondition: `JANUS_FLEET_ENABLED=true` ∧ cookie unset ⇒ entrypoint
  exits non-zero with a loud error (Part 0.5). Same loud exit when
  knob on ∧ (TLS dir missing / optfile unwritable / any cert file
  unreadable) — fail fast at boot, never an idle cluster surprise.''', 'pre')

# F.6/F.7 tweaks + F.8
rep('''7. **F.7 fleet commands + lease:**'''
   ,'''6b. **F.8 cache_put round-trip:** with the SAME tier config on
   gw1/gw2 and janus-auto traffic driven at gw1 until a decision is
   fetched+cached (miss), assert gw2's local decision cache serves
   the same hash WITHOUT its own upstream miss (mock judge counter
   deltas); a cache_put whose JudgeModel ≠ gw2's configured judge is
   dropped+counted (visible in `fleet_bad_ingress_total`).
7. **F.7 fleet commands + lease:**''', 'f8')
rep('''`lb_cool_clear` removes a cooled target's LOCAL cooldown row on
   ALL nodes AND its mirror rows on all peers within the cast window
   (purge signal); a peer down (paused) → its slot reads
   `{error, noconnection}` and the command still succeeds on the
   rest (partial-success-is-success);''',
'''the F.6 comparison binding has exactly ONE listing (deterministic
   hit counts); `lb_cool_clear` removes a cooled target's LOCAL
   cooldown row on ALL nodes AND its mirror rows on all peers within
   the cast window (purge signal); a PAUSED peer's slot reads
   `{error, timeout}` (TCP alive, no answer) and the command still
   succeeds on the rest (partial-success-is-success);''',
    'f7b')

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('rev 10 applied')
