# Native Erlang Distribution for the Janus Fleet — SPEC (rev 7)

> **For implementers:** single source of truth once ratified. All
> comments, commits, and docs in English. Status: DRAFT — round-6 folds
> applied; confirmation round pending.
>
> **Rev 7 folds xray round 6** (2 GO, 3 GO WITH FIXES, deepseek worker
> infra-fail; zero NO-GO across the saga; all prior folds confirmed
> present and coherent 5/5):
> - **S1 (pg split) resolved empirically** with a live two-node OTP 27
>   test: pg scopes ARE distributed (a non-member node sees the remote
>   member pid after `connect_node` + scope sync;
>   `pg:get_members(sc, grp)` → `[<remote pid>]`, `node(Pid)` works),
>   AND mimo's arity bug is confirmed (`pg:get_members/1` reads a GROUP
>   in the default scope → `[]` forever). Membership is pinned to
>   scope `janus_fleet_pg` + group `janus_fleet` + 2-arity
>   `pg:get_members/2`, pids→node names, self excluded everywhere.
> - Cool-path storm closure (glm): `{lb_cool}` is published ONLY on
>   transition into-cool (no unexpired row existed for the target) —
>   one publish per cooldown episode per (Target, Class); the cadence
>   note is now enforced, not asserted.
> - Broadcast self-echo pinned: the cast target list excludes `self()`.
> - Mirror-clear-on-local-success anchored on the `do_note_success/2`
>   EDGE (a cooldown row actually existed and was cleared) — per-success
>   casts explicitly forbidden.
> - F.3 phase-2 shed witness = one probe request at gw3 (a single
>   sample < `?EWMA_MIN_SAMPLES`, no local-wins) + mock counter delta
>   proving the slow listing was not hit; F.4 recovery assertion = "on
>   the next driven failure" (the cool path has no heartbeat).
> - SAN comparison pinned to binaries (init state is a list of
>   binaries; dNSNames normalized before membership check); eunit
>   fixtures for a multi-dNSName leaf (exactly-one match passes, zero
>   matches fail).
> - One-liners: entrypoint renders `-kernel inet_dist_listen_min/max`
>   from `$JANUS_FLEET_DIST_PORT` (single source) and chmods
>   `~/.erlang.cookie` 600; `$JANUS_FLEET_TLS_DIR` host→container mount
>   stated; `cert_days_remaining` cached (PT + cert-file mtime guard —
>   no per-request disk I/O); constant `Creation=1` accepted-residual
>   note; heartbeat bound hoisted into Part B; runbook pre-flight
>   noting `deploy_prod.sh` uses compose recreate + `/healthz`, never
>   erl_call subcommands.

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
   as `janus_lb` cooldowns). No replay, no persistence. Latency
   signals carry the sender's own `Verdict` — a healthy flip
   overwrites the row, so remote shedding can never outlive the
   sender's recovery (Part B).
3. **Clock skew across clouds** — signals carry *durations*
   (`ttl_ms`), never absolute wall timestamps; expiry is computed
   against the receiver's monotonic clock.
4. **Message storms** — per-request events are forbidden on the
   distribution channel. Cooldown publishes fire ONLY on the
   transition into-cool (one per episode per (Target, Class));
   recovery events are rarer still; latency state is coalesced
   (boundary-crossing events with 2-evaluation hysteresis + 5 s
   heartbeat-if-degraded, bounded by degraded route count × nodes).
5. **Cluster down at boot** — node starts standalone exactly as today;
   cluster join is retried in background and never blocks the release.
   `janus_fleet:init/1` is crash-free by construction: any misconfig
   (bad peers list, missing certs) yields an idle standalone state plus
   an error log, never an init crash. One deliberate exception: knob
   on AND `JANUS_ERLANG_COOKIE` unset ⇒ the entrypoint refuses to boot
   (loud exit), because a per-node random cookie would silently
   standalone the fleet.
6. **Forged/malformed ingress** — defense in depth, outermost first:
   (a) TLS: peer cert must chain to the fleet CA (`verify_peer` +
   `fail_if_no_peer_cert`); (b) handshake `verify_fun`: peer cert SAN
   must be ∈ the configured peer node names, enforced on the
   `valid_peer` event with never-rescue semantics (Part A) — forged or
   out-of-set certs never complete the handshake; (c)
   `net_kernel:allow/1`: the claimed node name must be ∈ the
   configured peers — enforced at the dist handshake, cert-backed per
   the SSL distribution guide; (d) signal layer: `{janus_fleet, 1, _}`
   tag + exact tuple shapes + claimed sender ∈ peers ∧ ≠ self, else
   dropped and counted. **Residual trust (precise):** outbound
   impersonation is closed (client verifies cert against the exact
   dialed node name automatically); inbound, a stolen fleet key for
   node X can additionally CLAIM node Y's name at the dist handshake —
   accepted and bounded: signal merge rules limit blast radius
   (quorum, self-limiting TTLs), and revocation = CA reissue. Anything
   failing (a)–(d) is dropped and counted.
7. **Mixed versions during rolling deploy** — every message is tagged
   `{janus_fleet, 1, Payload}`; unknown tags/shapes are dropped and
   counted, so old and new nodes coexist.
8. **Split-brain picks / remote poisoning** — impossible by
   construction: (a) remote *cooldown* signals are honored from a
   single sender but are **self-limiting** (a cooled sender stops
   generating failures on that target; rows expire ≤ 30 s); (b) remote
   *latency-degraded* verdicts shed a route only when **≥ 2 distinct
   live senders** hold unexpired rows with `Verdict == degraded` — one
   node with a sick local path can never shed a route fleet-wide;
   (c) **fresh local evidence strictly wins**: a target with fresh,
   sufficiently-sampled local healthy EWMA is never remote-shed;
   (d) remote shedding mirrors `degraded_filter`'s never-empty rule —
   if the shed would empty the candidate set, it is a no-op (applies
   to BOTH the latency post-filter and the remote-cool consult; a
   single-route binding never hard-503s from remote evidence alone,
   and the ignored case is counted); (e) a node only ever *adds*
   remote advisory state; it never overrides local evidence — and a
   local success on a target (edge-triggered, Part B) clears that
   target's remote mirror rows (both tables, via cast — eventual under
   racing ingress, TTL-bounded), making local-wins literal; (f) the
   system self-heals: senders that shed a route stop sampling it,
   their local EWMA goes stale (`?EWMA_STALE_MS`), heartbeats stop,
   remote rows TTL out — unless the route is genuinely sick, in which
   case continued publishing is correct.
9. **Port exposure** — distribution listens on one pinned TCP port
   (25672 by default; single-sourced from `$JANUS_FLEET_DIST_PORT`),
   TLS 1.3 only, security-grouped to peer IPs. **EPMD does not run at
   all**: `-start_epmd false` + a custom static `-epmd_module`
   (Part A); port 4369 is never bound (gate-asserted in F.1 over both
   `/proc/net/tcp` and `/proc/net/tcp6`). Connections are
   explicit-only (`-connect_all false`): no transitive mesh if an
   unexpected node ever appears.
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
- Distribution disabled ⇒ **behavior-identical** single-node behavior:
  the fleet distribution lines enter vm.args ONLY when the knob is on
  (Part A); knob-off boots with `proto_dist` absent
  (`init:get_argument(proto_dist) == error`, gate-asserted in F.5) and
  `/stats` carries no `fleet` key. (The rendered file differs from
  today's textually — `-setcookie` is always rendered — but behavior
  is identical since the entrypoint writes the same value to
  `~/.erlang.cookie`.)
- No DB schema changes; no Postgres writes from this feature.
- Knob defaults OFF; enabling is per-node env, not a DB setting — a
  deliberate divergence from the settings-table pattern: peer identity
  is deployment-specific, not catalog data. The env→persistent_term
  bridge is owned by `janus_core_app` start, which calls
  `janus_fleet:init_knob/0` (reads `JANUS_FLEET_ENABLED` from env,
  writes the PT key) BEFORE `janus_core_sup` builds its child list;
  the child-list condition reads the same env var directly; hook-path
  knob checks read only the PT key.
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
JANUS_FLEET_DIST_PORT=25672          # pinned dist port (single source)
JANUS_FLEET_TLS_DIR=/opt/stacks/janus/fleet    # ca.pem node.pem node-key.pem
JANUS_ERLANG_COOKIE=<[A-Za-z0-9_-]{32}>        # NEW .env key; REQUIRED when fleet on
```

**vm.args rendering (entrypoint, conditional):** the release start
script supports `RELX_REPLACE_OS_VARS` and passes through
`-proto_dist`/`-start_epmd`/`-epmd_module`/`-kernel`/`-connect_all`
lines, but does NOT honor `RELEASE_NODE`/`RELEASE_COOKIE`, and env
substitution is condition-free (all verified). Therefore the
entrypoint RENDERS the effective vm.args:

- Always: today's lines unchanged, with `-name ${JANUS_NODE_NAME}`
  (default `janus@127.0.0.1`) and `-setcookie ${JANUS_ERLANG_COOKIE}`
  substituted; the entrypoint writes the same cookie value (chmod 600)
  to `$HOME/.erlang.cookie` on every node (standalone: generated random
  `[A-Za-z0-9_-]{32}`), keeping `bin/janus rpc`/`remote_console` alive
  in standalone mode.
- Precondition: `JANUS_FLEET_ENABLED=true` ∧ cookie unset ⇒ entrypoint
  exits non-zero with a loud error (Part 0.5).
- ONLY when `JANUS_FLEET_ENABLED=true`, append the fleet block (port
  rendered from `$JANUS_FLEET_DIST_PORT` — single source):

```
-proto_dist inet_tls
-start_epmd false
-epmd_module janus_fleet_epmd
-connect_all false
-kernel inet_dist_listen_min $PORT inet_dist_listen_max $PORT
-ssl_dist_optfile /opt/janus/config/fleet_ssl_dist.runtime.config
```

- The optfile render happens only in fleet mode: template shipped at
  `/opt/janus/config/fleet_ssl_dist.config.src`, rendered to
  `/opt/janus/config/fleet_ssl_dist.runtime.config` with
  `<TLS_DIR>` → `$JANUS_FLEET_TLS_DIR` (host dir bind-mounted into the
  container by compose — stated here so the deploy diff cannot drop
  it) and the peer list → the `verify_fun` init state (see identity
  model). Knob-off never references cert paths.

**Fleet-mode ops caveat:** with `-start_epmd false`, the
erl_call-based subcommands (`bin/janus stop|rpc|ping|remote_console`)
cannot resolve the node (erl_call speaks the EPMD protocol directly;
our Erlang-level epmd module does not apply to it). In fleet mode,
control ops go through the admin HTTP plane (`:8090`) and
`docker stop` / `docker exec`; the erl_call subcommands remain a
standalone-mode tool. Runbook pre-flight (verified): `deploy_prod.sh`
rolls nodes via `docker compose up -d --force-recreate` + `/healthz`
curls only — it never invokes erl_call subcommands, so fleet mode is
deploy-compatible as-is. Documented in the runbook.

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
           {verify_fun, {fun janus_fleet_tls:verify/3,
                         [<<"janus@hostB">>, <<"janus@hostC">>]}}]},
 {client, [{verify, verify_peer},
           {cacertfile, "<TLS_DIR>/ca.pem"},
           {certfile,   "<TLS_DIR>/node.pem"},
           {keyfile,    "<TLS_DIR>/node-key.pem"},
           {versions, ['tlsv1.3']}]}].
```

The peer list in the `verify_fun` init state is RENDERED from
`JANUS_FLEET_PEERS` by the entrypoint (so eunit fixtures pass the list
as the init state, exactly matching production).

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
  janus_fleet_tls:verify/3` with pinned chain semantics:
  - event `valid_peer` (the peer/leaf cert): extract SAN dNSNames,
    normalize to binaries, require ≥ 1 ∈ the init-state peer list
    (binaries) → `{valid, State}` else `{fail, san_not_in_peer_set}`;
  - every other event (`valid` for CA/intermediate certs,
    `{extension, _}`, `{bad_cert, _}`): return `{unknown, State}` —
    NEVER `{valid, _}`, so our fun can never rescue a failed path
    validation (a self-signed cert carrying a peer's SAN still dies at
    `unknown_ca`).
  - Eunit-first with real generated 2–3-cert chain fixtures, including
    the attacker fixture (non-fleet-CA cert carrying a configured
    peer's SAN — F.1(a) uses exactly this) and multi-dNSName leaf
    fixtures (exactly-one match passes; zero matches fail).
  - (No post-handshake `ssl:peercert` on dist connections — OTP
    exposes no such public API; verify_fun IS the inbound mechanism.)
- Kernel layer: `janus_fleet` calls `net_kernel:allow(Peers)` at
  bring-up — the claimed node name must be in the peer set at the dist
  handshake (cert-backed per the guide when `verify_peer` is on).

**`janus_fleet_epmd`** (new, eunit-first; env read via `os:getenv/1`
at dist-start — this module runs before `janus_fleet:init/1`):
`start/0` → `{ok, Pid}` (no-op process), `stop/0` → `ok`,
`register_node/2` and `/3` → `{ok, 1}` (Creation ∈ {1,2,3} — static
1, no daemon; accepted residual: a restart incarnation is
indistinguishable via Creation — harmless here because connections are
(re)built by the connector loop and no EPMD registrations exist to go
stale), `names/0` and `names/1` → `{ok, []}`,
`address_please/3` → delegates to `inet:getaddr/1` | `/3`,
`listen_port_please/2` → `{ok, JANUS_FLEET_DIST_PORT}`, and:

```
port_please/3 (/2 delegates to /3 with a 5 s timeout) ->
    {port, JANUS_FLEET_DIST_PORT, 6}   %% janus@<configured-peer-host>
    {error, noport}                    %% anything else
```

The third element is the **distribution protocol version (OTP 27 =
6)**, NOT the EPMD creation — verified empirically on OTP 27:
`erl_epmd:port_please/3` on a live node returns `{port, Port, 6}`.
(Creation ∈ 1..3 belongs to `register_node`'s reply only.)

**Membership (S1 resolved empirically — live two-node OTP 27 test):**
pg scopes ARE distributed (a non-member node sees remote member pids
after `connect_node` + scope sync) AND the 1-arity
`pg:get_members/1` reads a GROUP in the default scope (always `[]`
here) — so the contract is pinned as: scope **`janus_fleet_pg`**,
group **`janus_fleet`**, all reads/writes 2-arity. The scope is
started in `janus_fleet:init/1` via `pg:start(janus_fleet_pg)`,
treating `{error, {already_started, _}}` as success (a transient
restart must not init-crash into the Part 0.12 tripwire); each node's
`janus_fleet` pid joins `pg:join(janus_fleet_pg, janus_fleet, self())`.
Broadcast: `[catch gen_server:cast(P, Msg) || P <- pg:get_members(
janus_fleet_pg, janus_fleet), P =/= self()]` — self-echo excluded.
`net_kernel:monitor_nodes(true)` drives nodeup/nodedown handling.
`net_ticktime` stays 60 s: WAN jitter must not cause phantom
node-downs; signal TTLs (seconds) handle staleness far faster than
tick detection needs to.

**Connector loop (required under `-connect_all false`):**
`janus_fleet` calls `net_kernel:connect_node/1` for each configured
peer at bring-up, retries with jittered backoff, and re-runs on
`nodedown` (this is also the F.4 rejoin path when a connection
actually dropped).

**Supervision:** `janus_fleet_sup` (`one_for_one`, intensity 3 /
period 60 s) holds `janus_fleet` (gen_server); it appears in
`janus_core_sup`'s child list ONLY when the knob is on, with
`restart: transient` — containment per Part 0.12.

**`/stats.fleet` read path:** the admin handler reads the knob from
persistent_term, `status` from `whereis(janus_fleet)` (`up`/`down`),
`nodes` from catch-guarded `pg:get_members(janus_fleet_pg,
janus_fleet)` mapped through `node(Pid)` with self excluded, and
mirror contents via the tolerant ETS helpers — NEVER a gen_server
call into `janus_fleet`. `status` and `nodes` are reported
INDEPENDENTLY (the pg scope outlives a parked `janus_fleet` and may
still list remote members; that is honest connectivity, not fleet
health). `cert_days_remaining` is cached in persistent_term guarded
by the cert file's mtime — no per-request disk I/O.

**PKI:**

- Dedicated self-signed **fleet CA**, generated once by a new
  `janus-dashboard/scripts/fleet_cert_gen.sh` (openssl; CA + one cert
  per node, SAN dNSName = full node name per the identity model,
  13-month validity; the script asserts the SAN bytes with
  `openssl x509 -text` before delivery). Output delivered to
  `$JANUS_FLEET_TLS_DIR` on each node (`root 600`) over the same
  SSH/scp channel `deploy_prod.sh` already uses, bind-mounted into
  the container by compose. Never in git (gitleaks-covered paths).
  DNS node names are preferred for readability; IP hosts work
  identically under the uniform SAN recipe.
- Expiry: `/stats.fleet.cert_days_remaining`; rotate by re-running the
  script for one node + recreate its container (order irrelevant —
  all peers equal). Revocation = reissue CA + all node certs (fleet
  of 3, documented in the script's README block).

**Ops notes:** ad-hoc diagnostic sessions MUST start hidden with the
full fleet flags (`-proto_dist inet_tls -ssl_dist_optfile <rendered
optfile> -epmd_module janus_fleet_epmd -start_epmd false -hidden
-setcookie $JANUS_ERLANG_COOKIE`) AND the debug node name must be
added to `net_kernel:allow` on the target for the session duration —
then connect explicitly with `net_kernel:connect_node/1`. (Plain
`erl -hidden` cannot dial a TLS-only, EPMD-less, allow-listed node.)
During staged rollout, the first enabled node reports `nodes: []`
until the peers get their real `JANUS_NODE_NAME`s — expected, not an
alarm. Sustained auth-class failures keep fleet coverage only while
the sender keeps failing (each NEW cooldown episode publishes once);
after the sender sheds the route and stops failing, remote rows expire
and each peer re-learns at most once (bounded re-learning tax).

## Part B — LB health signals (the actual win)

New ETS mirrors owned by `janus_fleet`, both `duplicate_bag` keyed by
**target** with per-sender values; ingress performs a per-(sender,
target) **upsert** (delete sender's prior row for the target, insert
the new one), so each (sender, target) pair holds at most one row and
the row cap is meaningful:

- `janus_fleet_remote_cool` — `{Target, {SenderNode, ExpiresAtMono, Class}}`
- `janus_fleet_remote_lat` — `{Target, {SenderNode, ExpiresAtMono, EwmaMs, Samples, Verdict}}`
  with `Verdict :: degraded | healthy`

Reads = `ets:lookup(Tab, Target)` → ≤ (peers) rows, filter unexpired —
O(#senders), stated honestly; all reads via `janus_fleet` helpers that
map missing table → `[]` (Part 0.11). `read_concurrency` on.

Egress (hooks in `janus_lb` — it necessarily gains one-line signal
hooks; all network/TLS/`pg` logic stays in `janus_fleet`. The "LB
unaware of the network" claim is dropped):

- Hook shape: persistent_term knob check, then
  `catch janus_fleet:publish(Msg)` — zero cost when off, no `badarg`
  on disconnect. Verified hook points (against `janus_lb.erl`):
  `do_note_failure/3` (after the local cooldown write),
  `do_note_success/2` (edge only — when a cooldown row actually
  existed and was cleared), `do_note_latency/3` (boundary watcher).
- `note_failure` → `{lb_cool, Target, TTLms, Class}` with
  `TTLms = min(remaining_cooldown, 30_000)`, published ONLY on the
  transition into-cool (no unexpired row existed for the target —
  `do_note_failure/3` already distinguishes this; extensions of an
  existing cooldown do not re-publish). One publish per cooldown
  episode per (Target, Class) — the storm invariant (Part 0.4) is
  enforced, not asserted. All cooldown classes propagate (auth on the
  shared upstream account is fleet-relevant). The 30 s cap vs longer
  `cooldown_ms/1` classes is the accepted bounded re-learning tax
  (Part A ops notes).
- `note_success` edge (cooldown cleared) → `{lb_recovered, Target}`
  — scoped to the sender's `janus_fleet_remote_cool` row ONLY; it
  never touches the latency mirror (latency recovery is signalled by
  a `healthy` verdict flip, below). Per-success casts are forbidden:
  no edge, no cast.
- Latency: publish `{lb_lat, Target, Verdict, EwmaMs, Samples,
  15_000}` where `Verdict :: degraded | healthy` is the sender's LOCAL
  verdict at publish time, fixed by the sender. Publishes happen when
  the verdict flips (both directions) AND the new verdict persists for
  2 consecutive `do_note_latency` evaluations (hysteresis), plus a 5 s
  coalesced heartbeat while any route is locally degraded — bounded by
  degraded route count × nodes (one contract, stated once).
  **Receivers never re-derive degradedness from EwmaMs** — the verdict
  travels with the signal (thresholds/factors are local and
  generation-lag-skewed). (Per-request publish = design violation,
  failure mode 4.)

Ingress (`janus_fleet:handle_cast`):

- Validate `{janus_fleet, 1, _}` tag + exact tuple shapes; clamp
  `ttl_ms ≤ 30_000`; per-(sender,target) upsert; enforce a per-sender
  row cap (8 192) dropping + counting excess; validate claimed
  `SenderNode` ∈ configured peers ∧ ≠ self. Violations bump
  `fleet_bad_ingress_total`.
- Write with `ExpiresAtMono = now_mono + ttl_ms`.
- `{lb_recovered, Target}` deletes **only that sender's** row in
  `janus_fleet_remote_cool` (a node retracts only its own signals;
  latency rows are unaffected).
- On `nodedown` / `pg` leave: eagerly delete that sender's rows from
  BOTH mirrors — documented as firing ≥ 60 s late (net_ticktime); TTL
  is the real cleanup.
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
  holding unexpired rows with `Verdict == degraded` — UNLESS local
  fresh (non-stale per `?EWMA_STALE_MS`, `?EWMA_MIN_SAMPLES`, both to
  be localized in `janus_lb.hrl`) healthy EWMA exists for that target
  (local wins), and if the post-filter would empty the set, return the
  pre-filter set (never-shed-last, mirroring `degraded_filter`'s
  `[] -> Routes`). Absent local evidence: a single-sender remote
  verdict is recorded and visible in `/stats` but never sheds (defined
  absent-local behavior).
- A local success on a target (the edge case above) clears that
  target's rows in BOTH remote mirrors (cast to `janus_fleet` —
  eventual under racing ingress, TTL-bounded; local evidence wins,
  literally). Local success/failure always overwrites local state
  immediately; nothing remote ever blocks a local recovery.

## Part C — Observability

- `/stats` gains `fleet` **only when the knob is on**:
  `{status: up|down, nodes: [node names...], signals_tx, signals_rx,
  dropped_bad_ingress, mirror_sizes, cert_days_remaining,
  mirrors: [{Target, SenderNode, cool|lat, Verdict?, expires_in_ms}...]}` —
  read-only via the Part A read path (parked-safe, cached cert age),
  bounded by the row caps (≤ peers × targets). The mirror rows exist
  so the TF-F.* gate asserts real state and operators can see exactly
  whose signal is in effect. The dashboard Nodes page can surface it
  later (separate SPA change, not in this spec).
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
are vacuous; F.5's comparison binding has exactly ONE listing
(deterministic route). **Execution order: F.5 → recreate gw3
fleet-on → F.1 → F.2 → F.3 → F.4** (`signals_rx` is cumulative — no
mid-suite reset; the recreate transition between F.5 and F.1 is an
explicit gate step). New TEST-FLOWS steps (TF-F.*):

1. **F.1 cluster forms + identity enforcement:** each node reports
   the other two peer NODE NAMES (self excluded) in
   `/stats.fleet.nodes`; EPMD (4369) is not listening anywhere
   (`/proc/net/tcp` AND `/proc/net/tcp6` inside one container).
   Negative cases: (a) a fourth container presenting a **non-fleet-CA
   cert carrying a configured peer's SAN** is refused at the TLS
   handshake (proves `verify_fun` never rescues a failed path
   validation); (b) a fleet-CA cert whose SAN (`janus@intruder`) is
   outside the configured peer set is refused by the handshake
   `verify_fun`; (c) a node with a valid peer cert but a node name
   outside `net_kernel:allow` is refused at the dist handshake. All
   three: never appear in `fleet.nodes`/`pg`, counted in
   logs/counters.
2. **F.2 sick-route propagation:** point gw1 at the mock's 503 key,
   drive failures until cooled; then, WITHIN the publish TTL (≤ 30 s —
   re-drive gw1 failures if the window slips; snapshot the mock's
   per-key counters before (b) so (c) is a delta): (a) gw2's
   `/stats.fleet.mirrors` shows the `{Target, gw1, cool, _}` row,
   (b) a gw2 request for a binding over that provider succeeds via
   the ALTERNATIVE route, (c) the counter delta proves the sick route
   was never hit by gw2.
3. **F.3 latency quorum:** traffic for the target binding is driven
   ONLY at gw1/gw2 (gw3 receives none until the probe → no local
   samples → no local-wins interference), CONTINUOUSLY through each
   window (senders keep sampling → EWMA stays fresh → heartbeats
   continue). Phase 1: slow-mock behind gw1 only → wait 2 heartbeat
   windows (≥ 10 s) → assert gw2/gw3 `/stats.fleet.mirrors` shows the
   `{_, gw1, lat, degraded, _}` row but neither sheds
   (single-sender). Phase 2: slow-mock behind gw2 as well → wait ≥ 2
   `do_note_latency` evaluations + one 5 s heartbeat window → shed
   witness at gw3: ONE probe request (a single sample <
   `?EWMA_MIN_SAMPLES` — no local-wins interference) returns from the
   fast listing AND the mock's counter delta proves the slow listing
   was not hit by gw3; then senders recover → healthy flip overwrites
   (or TTL) → gw3 unsheds.
4. **F.4 partition heals by TTL:** SETUP — drive a failing target at
   gw3 until gw1/gw2 `/stats.fleet.mirrors` show a live `{_, gw3, _,
   _, _}` row (else the step quantifies over an empty set). Then
   `docker pause` gw3 (TCP stays ESTABLISHED; nodedown will NOT fire
   in-window) → wait TTL + 2 heartbeat windows → assert gw1/gw2's
   gw3 rows expired (TTL expiry is the mechanism under test) →
   unpause → the existing connection resumes in place (ticks resume;
   no re-dial needed — re-dial via the connector loop covers the
   connection-actually-dropped case and is eunit/simulated, not gate)
   → drive gw3 into a fresh failure → fresh rows appear at gw1/gw2
   (the cool path has no heartbeat; recovery is asserted on the next
   driven signal).
5. **F.5 knob off (runs FIRST, see execution order):** gw3 with
   `JANUS_FLEET_ENABLED=false` — (a) its `/stats` has no `fleet` key,
   (b) `init:get_argument(proto_dist) == error` on gw3 (no dist
   lines rendered; behavior-identical boot to today), (c) gw1's
   `signals_rx == 0` BEFORE and AFTER the comparison drive (gw2 idle
   throughout — true under the deterministic single-listing mock),
   (d) identical mock requests to gw1 ("fleet-on, standalone state" =
   peers configured, zero signals broadcast) and gw3 return same
   status + same body modulo volatile fields (request id, timestamps),
   (e) gw3 appears in no peer's `fleet.nodes`.

Phase 3 (separate spec revision, not implemented in v1): quota counter
gossip (~2 s cadence, documented approximation) and judge
decision-cache sharing (`{cache_put, Hash, Tier, JudgeModel, TTL}` on
miss only).

## Part E — Explicitly rejected alternative

Postgres/NOTIFY as the health bus: zero new machinery, but ~2 s
propagation (poll interval) and DB writes from the data plane for
ephemeral signals — rejected by the operator in favor of native
distribution. Recorded here so the trade-off is auditable.
