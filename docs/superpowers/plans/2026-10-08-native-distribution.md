# Native Erlang Distribution for the Janus Fleet — SPEC (rev 4)

> **For implementers:** single source of truth once ratified. All
> comments, commits, and docs in English. Status: DRAFT — audit round 4.
>
> **Rev 4 folds xray round 3** (1 GO, 4 GO WITH FIXES, deepseek worker
> infra-failed again with no verdict; panel confirmed 5/5 that all
> round-1/2 folds are present and coherent, zero NO-GO blockers; all
> required fixes were in the Part A identity/bring-up layer + two gate
> steps):
> - Split A resolved by VERIFICATION against the official SSL
>   distribution guide + the OTP 27 `inet_tls_dist` beam: inbound
>   enforcement is a handshake-time **`verify_fun`** (the optfile
>   supports `{verify_fun, {fun Mod:F/3, Init}}`; the post-handshake
>   `ssl:peercert`-on-dist-socket claim is dropped — no such public
>   API exists). Optfile format corrected to the documented
>   `[{server, Opts}, {client, Opts}]` tuples.
> - Client-side identity check is AUTOMATIC and per-connection: OTP
>   adds `{server_name_indication, atom_to_list(TargetNode)}` on
>   connect and runs `pkix_verify_hostname` against it (doc + beam
>   verified) — so certs carry SAN dNSName = the FULL node name
>   `janus@<host>`. This dissolves round-2's IP-vs-DNS SAN split
>   (uniform recipe) and round-3's "static single-host check vs
>   two-peer mesh" failure (no static `customize_hostname_check` at
>   all) and the bare-IP-SNI concern (SNI is `janus@ip`, never a bare
>   IP literal).
> - Added `net_kernel:allow/1` (kernel-level node-name allowlist,
>   documented as cert-backed with `verify_peer`).
> - kimi's boot-breaker: the six distribution vm.args lines and the
>   optfile render are CONDITIONAL on `JANUS_FLEET_ENABLED=true` —
>   the entrypoint renders vm.args; knob-off output is byte-equivalent
>   to today; F.5 asserts `init:get_argument(proto_dist) == error`.
> - Membership: the join mechanism is named — per-peer
>   `net_kernel:connect_node/1` connector loop (required under
>   `-connect_all false`; also the F.4 rejoin path).
> - `/stats.fleet` read path stated: PT knob + `whereis` +
>   `pg:get_members` + tolerant ETS helpers — never a call into a
>   possibly-parked `janus_fleet`.
> - minimax's epmd corrections (`Creation ∈ {1,2,3}`; `address_please`
>   delegates to `inet:getaddr/1|/3`); F.5 unsound "LB-state reset"
>   alternative removed; optfile name unified; F.1 checks tcp AND
>   tcp6; rollout `nodes: []` note; 3/60 s tripwire ops note.

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
   expire on the receiver's monotonic clock. Per-sender rows are also
   dropped eagerly on `pg` leave, but that event lags `net_ticktime`
   (60 s) — **TTL expiry is the correctness mechanism, eager delete is
   an optimization**.
2. **Stale remote state outliving recovery** — every signal is
   self-expiring (lazy expiry on read + a 30 s sweeper, same discipline
   as `janus_lb` cooldowns). No replay, no persistence.
3. **Clock skew across clouds** — signals carry *durations*
   (`ttl_ms`), never absolute wall timestamps; expiry is computed
   against the receiver's monotonic clock.
4. **Message storms** — per-request events are forbidden on the
   distribution channel. Cooldown/recovery events are rare by
   definition; latency state is coalesced (boundary-crossing events
   with 2-evaluation hysteresis + 5 s heartbeat-if-degraded, bounded by
   degraded route count × nodes).
5. **Cluster down at boot** — node starts standalone exactly as today;
   cluster join is retried in background and never blocks the release.
   `janus_fleet:init/1` is crash-free by construction: any misconfig
   (bad peers list, missing certs) yields an idle standalone state plus
   an error log, never an init crash.
6. **Forged/malformed ingress** — defense in depth, outermost first:
   (a) TLS: peer cert must chain to the fleet CA (`verify_peer` +
   `fail_if_no_peer_cert`); (b) handshake `verify_fun`: peer cert SAN
   must be ∈ the configured peer node names — forged/out-of-set certs
   never complete the handshake; (c) `net_kernel:allow/1`: the claimed
   node name must be ∈ the configured peers — enforced at the dist
   handshake, cert-backed per the SSL distribution guide; (d) signal
   layer: `{janus_fleet, 1, _}` tag + exact tuple shapes + claimed
   sender ∈ peers ∧ ≠ self, else dropped and counted. **Residual
   trust (precise):** outbound impersonation is closed (client verifies
   cert against the exact dialed node name automatically); inbound, a
   stolen fleet key for node X can additionally CLAIM node Y's name at
   the dist handshake — accepted and bounded: signal merge rules limit
   blast radius (quorum, self-limiting TTLs), and revocation = CA
   reissue. Anything failing (a)–(d) is dropped and counted.
7. **Mixed versions during rolling deploy** — every message is tagged
   `{janus_fleet, 1, Payload}`; unknown tags/shapes are dropped and
   counted, so old and new nodes coexist.
8. **Split-brain picks / remote poisoning** — impossible by
   construction: (a) remote *cooldown* signals are honored from a
   single sender but are **self-limiting** (a cooled sender stops
   generating failures on that target, so it never re-publishes; rows
   expire ≤ 30 s); (b) remote *latency-degraded* verdicts shed a route
   only when **≥ 2 distinct live senders** hold unexpired rows — one
   node with a sick local path can never shed a route fleet-wide;
   (c) **fresh local evidence strictly wins**: a target with fresh,
   sufficiently-sampled local healthy EWMA is never remote-shed;
   (d) remote shedding mirrors `degraded_filter`'s never-empty rule —
   if the shed would empty the candidate set, it is a no-op (applies
   to BOTH the latency post-filter and the remote-cool consult; a
   single-route binding never hard-503s from remote evidence alone,
   and the ignored case is counted); (e) a node only ever *adds*
   remote advisory state; it never overrides local evidence — and a
   local success on a target clears that target's remote mirror rows
   (both tables), making local-wins literal; (f) the system
   self-heals: senders that shed a route stop sampling it, their local
   EWMA goes stale (`?EWMA_STALE_MS`), heartbeats stop, remote rows
   TTL out — unless the route is genuinely sick, in which case
   continued publishing is correct.
9. **Port exposure** — distribution listens on one pinned TCP port
   (25672), TLS 1.3 only, security-grouped to peer IPs. **EPMD does not
   run at all**: `-start_epmd false` + a custom static `-epmd_module`
   (Part A); port 4369 is never bound (gate-asserted in F.1 over both
   `/proc/net/tcp` and `/proc/net/tcp6`). Connections are explicit-only
   (`-connect_all false`): no transitive mesh if an unexpected node
   ever appears.
10. **Cookie/cert compromise** — cookie alone is never sufficient:
    TLS client certs are mandatory (the cookie is always exchanged per
    OTP, TLS or not — we keep it as a second factor). Cookie is a new
    `JANUS_ERLANG_COOKIE` secret in `/opt/stacks/janus/.env` (charset
    `[A-Za-z0-9_-]{32}` — vm.args tokenization breaks on shell/erl
    metacharacters); rotation = new value + rolling recreate. Cert
    rotation/revocation: Part A PKI.
11. **Mirror owner crash on the pick path** — mirror ETS is owned by
    `janus_fleet`; if it dies, reads must not `badarg` the `janus_lb`
    pick: ALL mirror reads go through `janus_fleet` read helpers that
    treat a missing table as empty (cluster down ≡ today). Tables are
    recreated in `janus_fleet:init/1` (a restart therefore discards
    ≤ 30 s of mirrored state — benign, self-replenishing).
12. **Flapping fleet must not kill siblings** — `janus_fleet` runs
    under its own supervisor subtree (`janus_fleet_sup`), registered
    with `janus_core_sup` as a **`transient`** child, and only when the
    knob is on. OTP semantics: a supervisor that exhausts its restart
    intensity exits with reason `shutdown`; `transient` children are
    not restarted on `shutdown`. A crash loop therefore parks the fleet
    subtree (logged loudly) until the next deploy/restart — catalog/
    DB/usage siblings are never restarted. The 3/60 s intensity is a
    deliberate tripwire: any restart burst parks the whole fleet
    rather than risking the node (ops note).

## Part 0.1 — Invariants

- Request path never blocks on distribution: all sends are casts
  (knob-checked via persistent_term first, `catch`-guarded); all
  receives write local ETS; picks read local ETS only.
- Local fresh evidence strictly wins over any remote signal, on both
  the cooldown and latency paths (Part 0.8c/e are literal).
- Distribution disabled ⇒ byte-identical behavior: the fleet
  distribution lines enter vm.args ONLY when the knob is on (Part A);
  knob-off boots with `proto_dist` absent (`init:get_argument(proto_dist)
  == error`, gate-asserted in F.5) and `/stats` carries no `fleet` key.
- No DB schema changes; no Postgres writes from this feature.
- Knob defaults OFF; enabling is per-node env, not a DB setting
  (peer identity is deployment-specific, not catalog data).
- All new pure logic (TTL clamp/merge, coalescer + hysteresis, ingress
  validation, epmd mapping, quorum post-filter, verify_fun SAN
  membership) is eunit-first with production-shaped fixtures per repo
  rules.

---

## Part A — Cluster bring-up (`janus_fleet`, new module in janus_core)

Per-node env (compose env / `/opt/stacks/janus/.env`, not sys.config
edits on hosts):

```
JANUS_FLEET_ENABLED=false            # knob; default off
JANUS_NODE_NAME=janus@<node public DNS name, or IP>   # vm.args var
JANUS_FLEET_PEERS=janus@a,janus@b    # static peers; small fleet, no discovery
JANUS_FLEET_DIST_PORT=25672          # pinned dist port
JANUS_FLEET_TLS_DIR=/opt/stacks/janus/fleet    # ca.pem node.pem node-key.pem
JANUS_ERLANG_COOKIE=<[A-Za-z0-9_-]{32}>        # NEW .env key (net-new plumbing)
```

**vm.args rendering (entrypoint, conditional — round-3 kimi fix):**
the release start script supports `RELX_REPLACE_OS_VARS` and passes
through `-proto_dist`/`-start_epmd`/`-epmd_module`/`-kernel`/
`-connect_all` lines, but does NOT honor `RELEASE_NODE`/
`RELEASE_COOKIE`, and env substitution is condition-free (all
verified). Therefore the entrypoint RENDERS the effective vm.args:

- Always: today's lines unchanged, with `-name ${JANUS_NODE_NAME}`
  (default `janus@127.0.0.1`) and `-setcookie ${JANUS_ERLANG_COOKIE}`
  substituted.
- ONLY when `JANUS_FLEET_ENABLED=true`, append the fleet block:

```
-proto_dist inet_tls
-start_epmd false
-epmd_module janus_fleet_epmd
-connect_all false
-kernel inet_dist_listen_min 25672 inet_dist_listen_max 25672
-ssl_dist_optfile /opt/janus/config/fleet_ssl_dist.runtime.config
```

- Knob-off rendered vm.args is byte-equivalent to today's distribution
  behavior (plain `inet_tcp`, loopback name, cookie from
  `~/.erlang.cookie` — which the entrypoint writes on every node from
  the same env value, generated random `[A-Za-z0-9_-]{32}` when unset,
  so `bin/janus rpc`/`remote_console`/`stop` keep working).
- The optfile render (from a release-shipped template, substituting
  `JANUS_FLEET_TLS_DIR` and the peer set) happens only in fleet mode —
  knob-off never references cert paths.

**TLS optfile (format per the official SSL distribution guide —
`[{server, Opts}, {client, Opts}]` tuples flowing into
`ssl:handshake/3` / `ssl:connect/4`; funs as `fun Mod:F/A`):**

```erlang
[{server, [{verify, verify_peer},
           {fail_if_no_peer_cert, true},
           {cacertfile, "<TLS_DIR>/ca.pem"},
           {certfile,   "<TLS_DIR>/node.pem"},
           {keyfile,    "<TLS_DIR>/node-key.pem"},
           {versions, ['tlsv1.3']},
           {verify_fun, {fun janus_fleet_tls:verify/3, []}}]},
 {client, [{verify, verify_peer},
           {cacertfile, "<TLS_DIR>/ca.pem"},
           {certfile,   "<TLS_DIR>/node.pem"},
           {keyfile,    "<TLS_DIR>/node-key.pem"},
           {versions, ['tlsv1.3']}]}].
```

**Identity model (verified against the OTP 27 SSL distribution guide
+ `inet_tls_dist` beam):**

- Client side (dialer): OTP automatically adds
  `{server_name_indication, atom_to_list(TargetNode)}` on connect and
  `pkix_verify_hostname`-checks the server cert against it — a
  per-connection reference, so the two-peer mesh needs NO static
  `customize_hostname_check`. Consequence: **node certs are issued
  with SAN dNSName = the full node name `janus@<host>`** (e.g.
  `janus@jdcloud.example.internal`). One uniform recipe for DNS and
  IP hosts — the SNI/reference is `janus@ip`, never a bare IP literal
  (RFC 6066 concern does not apply; both ends are OTP, and the
  reference match is exact-string).
- Server side (acceptor): `verify_peer` + `fail_if_no_peer_cert`
  (fleet-CA membership), plus `verify_fun =
  janus_fleet_tls:verify/3` which extracts the peer cert's SANs and
  requires ≥ 1 dNSName ∈ configured peer node names — forged or
  out-of-set certs fail the handshake. The pure SAN-extraction /
  membership function is eunit-first with real generated cert
  fixtures. (No post-handshake `ssl:peercert` on dist connections —
  OTP exposes no such public API; verify_fun IS the inbound
  mechanism.)
- Kernel layer: `janus_fleet` calls `net_kernel:allow(Peers)` at
  bring-up — the claimed node name must be in the peer set at the dist
  handshake (cert-backed per the guide when `verify_peer` is on).

**`janus_fleet_epmd`** (new, eunit-first; callback surface verified
against OTP 27 exports): `start/0` → `{ok, Pid}` (no-op process),
`stop/0` → `ok`, `register_node/2` → `{ok, 1}` (Creation ∈ {1,2,3} —
static 1, no daemon), `port_please/3` (`/2` shims with a 5 s timeout)
→ `{port, JANUS_FLEET_DIST_PORT, 5}` for any
`janus@<configured-peer-host>`, `{error, noport}` otherwise;
`address_please/3` → delegates to `inet:getaddr/1` / `/3`;
`listen_port_please/2` → `{ok, JANUS_FLEET_DIST_PORT}`; `names/1` →
`{ok, []}` (no EPMD to enumerate). No EPMD process ever runs.

**Membership (round-3 fix — the join mechanism is explicit):**
`janus_fleet`'s connector loop calls `net_kernel:connect_node/1` for
each configured peer at bring-up, retries with jittered backoff, and
re-runs on `nodedown` — REQUIRED under `-connect_all false` (nothing
forms the first edge otherwise; this is also the F.4 rejoin path).
Membership itself: `pg` scope `janus_fleet` — each node's
`janus_fleet` pid joins; broadcast = `pg:get_members` +
`catch`-guarded casts. `net_kernel:monitor_nodes(true)` drives
nodeup/nodedown handling. `net_ticktime` stays 60 s: WAN jitter must
not cause phantom node-downs; signal TTLs (seconds) handle staleness
far faster than tick detection needs to.

**Supervision:** `janus_fleet_sup` (`one_for_one`, intensity 3 /
period 60 s) holds `janus_fleet` (gen_server); it appears in
`janus_core_sup`'s child list ONLY when the knob is on, with
`restart: transient` — containment per Part 0.12.

**`/stats.fleet` read path:** the admin handler reads the knob from
persistent_term, liveness from `whereis(janus_fleet)`, membership from
`pg:get_members`, and mirror contents via the tolerant ETS helpers —
NEVER a gen_server call into `janus_fleet` (a parked subtree must
still report itself: knob on, `status: down`, `nodes: []`).

**PKI:**

- Dedicated self-signed **fleet CA**, generated once by a new
  `janus-dashboard/scripts/fleet_cert_gen.sh` (openssl; CA + one cert
  per node, SAN dNSName = full node name per the identity model,
  13-month validity). Output delivered to `/opt/stacks/janus/fleet/`
  on each node (`root 600`) over the same SSH/scp channel
  `deploy_prod.sh` already uses. Never in git (gitleaks-covered
  paths). DNS node names are preferred for readability; IP hosts work
  identically under the uniform SAN recipe.
- Expiry: `/stats.fleet.cert_days_remaining`; rotate by re-running the
  script for one node + recreate its container (order irrelevant —
  all peers equal). Revocation = reissue CA + all node certs (fleet
  of 3, documented in the script's README block).

**Ops notes:** ad-hoc diagnostic sessions MUST start hidden and
connect explicitly (`erl -name debug@... -hidden -setcookie
$JANUS_ERLANG_COOKIE` then `net_kernel:connect_node/1`) so they never
mesh into the fleet or appear in `nodes()` / `pg`. During staged
rollout, the first enabled node reports `nodes: []` until the peers
get their real `JANUS_NODE_NAME`s — expected, not an alarm.

## Part B — LB health signals (the actual win)

New ETS mirrors owned by `janus_fleet`, both `duplicate_bag` keyed by
**target** with per-sender values; ingress performs a per-(sender,
target) **upsert** (delete sender's prior row for the target, insert
the new one), so each (sender, target) pair holds at most one row and
the row cap is meaningful:

- `janus_fleet_remote_cool` — `{Target, {SenderNode, ExpiresAtMono, Class}}`
- `janus_fleet_remote_lat` — `{Target, {SenderNode, ExpiresAtMono, EwmaMs, Samples}}`

Reads = `ets:lookup(Tab, Target)` → ≤ (peers) rows, filter unexpired —
O(#senders), stated honestly; all reads via `janus_fleet` helpers that
map missing table → `[]` (Part 0.11). `read_concurrency` on.

Egress (hooks in `janus_lb` — it necessarily gains one-line signal
hooks; all network/TLS/`pg` logic stays in `janus_fleet`. The "LB
unaware of the network" claim is dropped):

- Hook shape: persistent_term knob check, then
  `catch janus_fleet:publish(Msg)` — zero cost when off, no `badarg`
  on disconnect. Verified hook points (against `janus_lb.erl`):
  `do_note_failure/2` (after the local cooldown write),
  `do_note_success/2` (only when a cooldown was actually cleared),
  `do_note_latency/3` (boundary watcher).
- `note_failure` → `{lb_cool, Target, TTLms, Class}` with
  `TTLms = min(remaining_cooldown, 30_000)`. All cooldown classes
  propagate (auth on the shared upstream account is fleet-relevant).
  The 30 s cap vs longer `cooldown_ms/1` classes (e.g. auth) is an
  accepted **bounded re-learning tax**: coverage is extended only while
  the sender keeps failing and re-publishing; if the sender stops
  (route shed locally), the fleet re-learns at most one failure per
  node after expiry.
- `note_success` clearing a cooldown → `{lb_recovered, Target}`.
- Latency: publish `{lb_lat, Target, EwmaMs, Samples, 15_000}` only
  when the degraded/healthy verdict flips AND the new verdict persists
  for 2 consecutive `do_note_latency` evaluations (hysteresis), plus a
  5 s coalesced heartbeat while any route is locally degraded.
  (Per-request publish = design violation, failure mode 4.)

Ingress (`janus_fleet:handle_cast`):

- Validate `{janus_fleet, 1, _}` tag + exact tuple shapes; clamp
  `ttl_ms ≤ 30_000`; per-(sender,target) upsert; enforce a per-sender
  row cap (8 192) dropping + counting excess; validate claimed
  `SenderNode` ∈ configured peers ∧ ≠ self. Violations bump
  `fleet_bad_ingress_total`.
- Write with `ExpiresAtMono = now_mono + ttl_ms`.
- `{lb_recovered, Target}` deletes **only that sender's** row for the
  target (a node retracts only its own signals).
- On `nodedown` / `pg` leave: eagerly delete that sender's rows —
  documented as firing ≥ 60 s late (net_ticktime); TTL is the real
  cleanup.
- 30 s sweeper pass deletes expired rows even if never read.

Consumption (`janus_lb` read path):

- `is_cooling/3` additionally consults the remote-cool mirror (one
  `ets:lookup` per candidate via the tolerant helper): any single live
  sender's unexpired row marks the target cooling until expiry —
  **except** when that would remove the last available candidate:
  then the remote row is ignored for this pick and
  `fleet_remote_cool_last_resort_total` is counted (advisory-only,
  never a hard remote 503).
- Latency: remote verdicts feed a **post-filter** after the local
  `degraded_filter`: drop candidates with ≥ 2 distinct live senders
  holding unexpired degraded rows — UNLESS local fresh (non-stale per
  `?EWMA_STALE_MS`, `?EWMA_MIN_SAMPLES`) healthy EWMA exists for that
  target (local wins), and if the post-filter would empty the set,
  return the pre-filter set (never-shed-last, mirroring
  `degraded_filter`'s `[] -> Routes`). Absent local evidence: a
  single-sender remote verdict is recorded and visible in `/stats`
  but never sheds (defined absent-local behavior).
- A local success on a target clears that target's rows in BOTH
  remote mirrors (local evidence wins, literally). Local
  success/failure always overwrites local state immediately; nothing
  remote ever blocks a local recovery.

## Part C — Observability

- `/stats` gains `fleet` **only when the knob is on**:
  `{status: up|down, nodes: [connected...], signals_tx, signals_rx,
  dropped_bad_ingress, mirror_sizes, cert_days_remaining,
  mirrors: [{Target, SenderNode, cool|lat, expires_in_ms}...]}` —
  read-only via the Part A read path, bounded by the row caps
  (≤ peers × targets). The mirror rows exist so the TF-F.* gate
  asserts real state and operators can see exactly whose signal is in
  effect. The dashboard Nodes page can surface it later (separate SPA
  change, not in this spec).
- `/metrics` gains `fleet_signals_tx_total`,
  `fleet_signals_rx_total`, `fleet_bad_ingress_total`,
  `fleet_remote_cool_last_resort_total`, and mirror row-count gauges.
- Log lines: `janus_fleet_nodeup/nodedown`, `janus_fleet_ingress_drop`
  with sender + reason, throttled.

## Part D — Rollout & verification

Rollout: knob off by default. Enable on tencent alone → observe
`fleet.nodes` (`[]` until peers get real `JANUS_NODE_NAME`s — expected
during staging) + standalone behavior → jdcloud → aliyun. Rollback =
env off + recreate; nothing persists.

Local gate (multi-node, no prod): the e2e compose gains **janus-gw2
and janus-gw3** (same image, distinct names — three nodes so the
latency quorum is honestly testable) on the bridge network with
loopback-free distribution. Gate preconditions: the targeted binding
for F.2/F.3 MUST have ≥ 2 live listings (one sabotaged, one healthy
mock alternative), else "succeeds via the alternative" / "never hit"
are vacuous; **F.5 runs BEFORE F.2–F.4** so gw1 is in an unlearned LB
state for the comparison (`signals_rx` is cumulative — no mid-suite
"reset"). New TEST-FLOWS steps (TF-F.*):

1. **F.1 cluster forms + identity enforcement:** all three nodes
   report the other two in `/stats.fleet.nodes`; EPMD (4369) is not
   listening anywhere (`/proc/net/tcp` AND `/proc/net/tcp6` inside one
   container). Negative cases: (a) a fourth container presenting a
   non-fleet-CA cert is refused at the TLS handshake; (b) a fleet-CA
   cert whose SAN (`janus@intruder`) is outside the configured peer
   set is refused by the handshake `verify_fun`; (c) a node with a
   valid peer cert but a node name outside `net_kernel:allow` is
   refused at the dist handshake. All three: never appear in
   `fleet.nodes`/`pg`, counted in logs/counters.
2. **F.2 sick-route propagation:** point gw1 at the mock's 503 key,
   drive failures until cooled; then assert, in order: (a) gw2's
   `/stats.fleet.mirrors` shows the `{Target, gw1, cool, _}` row,
   (b) a gw2 request for a binding over that provider succeeds via
   the ALTERNATIVE route, (c) the mock's per-key counters prove the
   sick route was never hit by gw2.
3. **F.3 latency quorum:** slow-mock behind gw1 only → wait 2
   heartbeat windows (≥ 10 s) → assert gw2/gw3 `/stats.fleet.mirrors`
   shows the row but neither sheds (single-sender). Then slow-mock
   behind gw2 as well → assert gw3 sheds the route without any local
   slow samples, and unsheds after the senders recover + TTL.
4. **F.4 partition heals by TTL:** `docker pause` gw3 (TCP stays
   ESTABLISHED; nodedown will NOT fire in-window) → wait TTL + 2
   heartbeat windows → assert gw1/gw2 `/stats.fleet.mirrors` rows for
   gw3 expired (TTL expiry is the mechanism under test); unpause →
   the connector loop re-establishes (`net_kernel:connect_node/1` on
   its retry timer), fresh signals flow. Eager nodedown-delete
   correctness is covered by eunit on the pure delete fun, not by the
   gate (60 s tick budget is too slow for CI).
5. **F.5 knob off (runs first):** gw3 with
   `JANUS_FLEET_ENABLED=false` — (a) its `/stats` has no `fleet` key,
   (b) `init:get_argument(proto_dist) == error` on gw3 (no dist
   lines rendered; byte-equivalent boot behavior to today),
   (c) identical mock requests to gw1 ("fleet-on, standalone state" =
   peers configured, zero signals broadcast — asserted via gw1's
   `signals_rx == 0`) and gw3 return same status + same body modulo
   volatile fields (request id, timestamps) — the deterministic mock
   makes this comparable, (d) gw3 appears in no peer's `fleet.nodes`.

Phase 3 (separate spec revision, not implemented in v1): quota counter
gossip (~2 s cadence, documented approximation) and judge
decision-cache sharing (`{cache_put, Hash, Tier, JudgeModel, TTL}` on
miss only).

## Part E — Explicitly rejected alternative

Postgres/NOTIFY as the health bus: zero new machinery, but ~2 s
propagation (poll interval) and DB writes from the data plane for
ephemeral signals — rejected by the operator in favor of native
distribution. Recorded here so the trade-off is auditable.
