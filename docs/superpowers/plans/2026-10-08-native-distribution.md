# Native Erlang Distribution for the Janus Fleet — SPEC (draft rev 1)

> **For implementers:** single source of truth once ratified. All
> comments, commits, and docs in English. Status: DRAFT — pending the
> usual audit rounds before any code.

**Goal.** The three production gateways (aliyun leader, jdcloud +
tencent followers) behave as one Erlang cluster for *ephemeral runtime
signals* — LB cooldowns, latency-degradation state, (phase 3) quota
counters and judge decision-cache entries — so a sick provider learned
about on one node is avoided by all nodes within ~100 ms instead of
each node paying its own learning tax (today: N failed/slow requests
per node before the local LB reacts).

**Non-goals.** No mnesia, no `global`, no cross-node request
forwarding/proxying, no distributed config writes, no hot code
upgrades, no Raft/consensus. Postgres remains the sole authority for
config/catalog; nothing in this spec changes the generation-poll
mechanism.

**Architecture boundary.** Distribution carries ONLY advisory,
self-expiring runtime signals node→fleet. Everything a node learns via
the cluster lands in *local ETS mirror tables* and decays by TTL; local
request-path evidence always wins over remote signals. The cluster
being down, partitioned, or disabled is indistinguishable from today's
single-node behavior.

---

## Part 0 — Failure modes first (project rule)

1. **WAN partition / tunnel flap** between clouds — must degrade to
   standalone, never to wrong answers: remote signals carry TTLs and
   are dropped when the sender leaves `pg` membership.
2. **Stale remote state outliving recovery** — every signal is
   self-expiring (lazy expiry on read, same discipline as
   `janus_lb` cooldowns). No replay, no persistence.
3. **Clock skew across clouds** — signals carry *durations*
   (`ttl_ms`), never absolute wall timestamps; expiry is computed
   against the receiver's monotonic clock.
4. **Message storms** — per-request events are forbidden on the
   distribution channel. Cooldown/recovery events are rare by
   definition; latency state is coalesced (boundary-crossing events +
   5 s heartbeat-if-changed, bounded by route count × nodes).
5. **Cluster down at boot** — node starts standalone exactly as today;
   cluster join is retried in background and never blocks the release.
6. **Forged/malformed ingress** — mutual-TLS distribution + strict
   shape validation at the single ingress function; anything else is
   dropped and counted.
7. **Mixed versions during rolling deploy** — every message is tagged
   `{janus_fleet, 1, Payload}`; unknown tags/shapes are dropped and
   counted, so old and new nodes coexist.
8. **Split-brain picks** — impossible by construction: a node only
   ever *adds* remote advisory state; it never deletes or overrides
   local evidence. Local failure/success always wins.
9. **Port exposure** — distribution listens on one pinned port,
   TLS-only, security-grouped to peer IPs. EPMD is not exposed
   (`-epmd_module` static ports or firewall 4369 to peers only).
10. **Cookie/cert compromise** — cookie alone is never sufficient:
    TLS client certs are mandatory; rotation = restart with new cert
    (rolling, followers first is wrong here — order irrelevant, all
    nodes are equal peers for this channel).

## Part 0.1 — Invariants

- Request path never blocks on distribution: all sends are casts;
  all receives write local ETS; picks read local ETS only.
- Distribution disabled or down ⇒ byte-identical behavior to today.
- No DB schema changes; no Postgres writes from this feature.
- Knob defaults OFF; enabling is per-node env, not a DB setting
  (peer identity is deployment-specific, not catalog data).
- All new pure logic (TTL merge, coalescer, ingress validation) is
  eunit-first with production-shaped fixtures per repo rules.

---

## Part A — Cluster bring-up (`janus_fleet`, new module in janus_core)

Per-node env (compose env, not sys.config edits on hosts):

```
JANUS_FLEET_ENABLED=false            # knob; default off
JANUS_FLEET_NODE_NAME=janus@<node public IP or DNS>
JANUS_FLEET_PEERS=janus@a,janus@b    # static peers; small fleet, no discovery
JANUS_FLEET_DIST_PORT=25672          # pinned; no EPMD dependence
JANUS_FLEET_TLS_CERT/KEY/CA=/opt/stacks/janus/fleet/*.{pem}
```

- vm.args stops hardcoding `-name janus@127.0.0.1`; name comes from
  `JANUS_FLEET_NODE_NAME` when enabled, else the loopback default
  (current behavior).
- Distribution driver: `inet_tls` with mutual verification
  (`verify_peer`, `fail_if_no_peer_cert`), TLS 1.3 only. Cookie still
  set (defense in depth) from the existing secrets file.
- `net_ticktime`: keep the 60 s default — WAN jitter must not cause
  phantom node-downs; signal TTLs (seconds) handle staleness far
  faster than tick detection needs to.
- `janus_fleet` is a gen_server under `janus_core_sup` (restart:
  `one_for_one`, transient restarts allowed, backoff via supervisor
  intensity — a flapping cluster must not nuke the node).
- Membership: `pg` scope `janus_fleet` — each node joins one member
  pid; broadcast = `pg:get_members` + cast. No custom overlay.

## Part B — LB health signals (the actual win)

New ETS mirrors owned by `janus_fleet` (not `janus_lb` — LB stays
unaware of the network):

- `janus_fleet_remote_cool` — `{Target, SenderNode, ExpiresAtMono, Reason}`
- `janus_fleet_remote_lat` — `{Target, SenderNode, EwmaMs, Samples, ExpiresAtMono}`

Egress (hooks in `janus_lb`, one-line casts, no behavior change when
disabled):

- `note_failure` → after local cooldown write, cast
  `janus_fleet:publish({lb_cool, Target, TTLms, Reason})` where TTLms =
  the computed cooldown window (already `cooldown_ms/1`).
- `note_success` clearing a cooldown → `{lb_recovered, Target}`.
- Latency: a *boundary watcher* in `janus_lb`'s `do_note_latency` —
  publish `{lb_lat, Target, EwmaMs, Samples}` only when the
  degraded/healthy verdict flips, plus a 5 s coalesced heartbeat while
  any route is degraded. (Per-request publish = design violation,
  failure mode 4.)

Ingress (`janus_fleet:handle_cast` from remote pids):

- Validate `{janus_fleet, 1, _}` tag + exact tuple shapes; else drop
  and bump `fleet_bad_ingress_total`.
- Write to the mirror with `ExpiresAtMono = now_mono + ttl_ms` and the
  sender's node. On `nodedown`/`pg` leave: delete that sender's rows
  eagerly (don't wait for TTL).

Consumption (`janus_lb` read path):

- `is_cooling/3` additionally consults `janus_fleet_remote_cool`
  (unexpired rows) — one extra `ets:lookup` per candidate, same
  read_concurrency discipline.
- `degraded_filter`'s EwmaFun merges local EWMA with remote mirrors:
  `max(local, max_remote)` — a route degraded anywhere is treated as
  degraded everywhere (conservative; remote samples decay out in
  30 s of silence).
- Local success/failure always overwrites local state immediately;
  remote rows never block a local recovery.

## Part C — Observability

- `/stats` gains `fleet`: `{enabled, nodes: [connected...],
  signals_tx, signals_rx, dropped_bad_ingress, mirror_sizes}` —
  read-only, rides the existing admin plane; the dashboard Nodes page
  can surface it later (separate SPA change, not in this spec).
- Log lines: `janus_fleet_nodeup/nodedown`, `janus_fleet_ingress_drop`
  with sender + reason, throttled.

## Part D — Rollout & verification

Rollout: knob off by default. Enable on tencent alone → observe
`fleet.nodes` + standalone behavior → jdcloud → aliyun. Rollback = env
off + recreate; nothing persists.

Local gate (multi-node, no prod): the e2e compose gains `janus-gw2`
(same image, second name) on the bridge network with loopback-free
distribution. New TEST-FLOWS steps (TF-F.*):

1. F.1 cluster forms: both nodes report each other in `/stats.fleet`.
2. F.2 sick-route propagation: point gw1 at the mock's 503 key, drive
   failures until cooled, assert gw2 sheds the same route *without*
   gw2 ever failing a request.
3. F.3 latency shedding propagation: slow-mock behind gw1; gw2's EWMA
   mirror reflects the degraded verdict within one heartbeat.
4. F.4 partition: `docker pause` gw2 past TTLs → gw1 drops gw2's
   mirror rows; unpause → rejoin, fresh signals flow. No stale shed.
5. F.5 knob off: gw2 with `JANUS_FLEET_ENABLED=false` — zero behavior
   delta vs today (byte-identical responses).

Phase 3 (separate spec revision, not implemented in v1): quota counter
gossip (~2 s cadence, documented approximation) and judge
decision-cache sharing (`{cache_put, Hash, Tier, JudgeModel, TTL}` on
miss only).

## Part E — Explicitly rejected alternative

Postgres/NOTIFY as the health bus: zero new machinery, but ~2 s
propagation (poll interval) and DB writes from the data plane for
ephemeral signals — rejected by the operator in favor of native
distribution. Recorded here so the trade-off is auditable.
