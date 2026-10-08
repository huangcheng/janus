# Native Erlang Distribution for the Janus Fleet — SPEC (rev 11 — FINAL)

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

**Rev 11 (final) — rounds 1/2/4 all 7/7 GO WITH FIXES, converged at
> hygiene level:** erpc catch normalized (`error:{erpc,R} -> {error,R}`
first clause); cache_put first_seen tombstones GC at
first_seen + 2xTTL + 60 s grace; MFAs pinned for all four commands
(fleet_status -> janus_fleet:status/0; config_reload_nudge ->
janus_config:reload/0; catalog_cache_flush -> janus_catalog:flush/0;
lb_cool_clear -> janus_lb:cool_clear/1 NEW exported API);
lb_cool_purge published ONCE by the command originator only
(ingress-bounded like every signal); lease failover is TICK-based
(holder expiry on the 5 s tick, nodedown accelerates, not the
mechanism); "hottest" = highest Used/Limit ratio this cycle; the
8 192/sender cap is AGGREGATE across all mirrors (stated once);
fleet_status executes LOCALLY via direct call (no erpc to self);
Part C mirrors enum covers quota rows; gate order pinned
F.5-F.1-F.2-F.3-F.4-F.6-F.8-F.7 (pause-based last); F.6 fleet-off
control = pre-recreate measurement of the same binding; Target
byte-clamped at ingress; connector retry caps at 5 min then
log-only; cert-gen script on the rollout checklist; stale
expires_in_ms/(phase 3) wording scrubbed.
> **Rev 10 — pi-audit round 2 (7/7 GO WITH FIXES) folds:** replay
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
> **Rev 9 — pi-audit round 1 (7/7 GO WITH FIXES) applied:**
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
> **Rev 8 — operator enhancement "full Erlang power":** adds Part F
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
signals* — LB cooldowns, latency-degradation state, (phase 3) quota
counters and judge decision-cache entries — so a sick provider learned
about on one node is avoided by all nodes within ~100 ms instead of
each node paying its own learning tax (today: N failed/slow requests
per node before the local LB reacts).

**Non-goals.** No mnesia, no `global`, no cross-node request
forwarding/proxying (agent traffic NEVER transits a peer), no
distributed config writes, no hot code upgrades, no Raft/consensus.
Remote execution (Part F) is a CLOSED enum of control-plane commands —
never arbitrary module:function:args, never secrets, never agent
payloads. Postgres remains the sole authority for
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
   as `janus_lb` cooldowns). No persistence. Replay is forbidden on
   every signal EXCEPT one accepted, bounded deviation: a replayed
   `cache_put` extends its entry by at most one TTL, and the enforced
   per-(sender,Hash) bound is `expires_at <= first_seen + 2xTTL` (B2). Latency
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
   accepted and bounded **for SIGNAL ingress** (quorum,
   self-limiting TTLs), and revocation = CA reissue. **With Part F,
   the same stolen key additionally enables arbitrary remote code
   execution on peers (Erlang distribution has no MFA allow-list —
   F.3); the cert is the only real boundary.** Anything failing
   (a)–(d) is dropped and counted.
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
  exits non-zero with a loud error (Part 0.5). Same loud exit when
  knob on ∧ (TLS dir missing / optfile unwritable / any cert file
  unreadable) — fail fast at boot, never an idle cluster surprise.
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
  ALL signal mirrors (cool, latency, quota); cache_put entries are
  deliberately NOT purged (a departed peer's cached decisions remain
  valid; TTL ≤ 300 s is their bound) — documented as firing ≥ 60 s late (net_ticktime); TTL
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

## Part B2 — Quota gossip + judge decision-cache sharing (former phase 3, now in scope)

Both payloads ride the same `{janus_fleet, 1, _}` channel, mirrors,
TTLs, ingress validation, and local-wins discipline as Part B.

**Quota counters — ADVISORY-OBSERVABILITY ONLY in v1.** Slice-Q
limits are PER-NODE (the operator's Slice Q spec); a cross-node merge
is semantically undefined (per-node budgets make remote rows
non-authoritative; shared budgets would need a sum, not a max, plus
exactly-once accounting nobody has). v1 therefore: each node
publishes `{quota, AgentKeyId, WindowId, WindowSec, {Used, Limit},
6_000}` on a **2 s coalesced heartbeat** for the **top-32 hottest keys ≥ 50 %
of limit** (per-cycle publish cap; AgentKeyId clamped ≤ 128 bytes at
ingress) (plus an edge-latched publish when a counter crosses 80 % —
2 consecutive evaluations, latency-coalescer discipline); receivers
upsert per-(sender, key, window) into a `janus_fleet_remote_quota`
mirror — a sender's row for the CURRENT **or PREVIOUS** WindowId is
accepted (bucket-boundary races make a strict match flicker at the
edge; older buckets drop) — that is **read by /stats and /metrics ONLY — the pick path
never consults it**. Behavior with the fleet on is therefore
byte-identical to today (the F.6 gate asserts exactly that);
fleet-aware early shedding is deferred to a spec revision that first
defines budget ownership. TTL 6 s = 3× cadence (jitter margin; the
2 s == TTL flicker is the bug this avoids). **WindowId =
floor(epoch_seconds / WindowSec)** — a pure bucket index, not an
expiry timestamp: receivers compute their own current WindowId and
drop mismatches (clock skew ± s vs ≥ 60 s buckets is immaterial).
Row cap 8 192/sender.

**Judge decision-cache sharing (janus-auto).** On a LOCAL cache MISS
that is then fetched and cached, the node publishes
`{cache_put, Hash, Tier, JudgeModel, TTLms}` — miss-only (a hit never
publishes; no invalidation storm). Ingress applies cache_put-specific
rules on top of the Part B validation: Hash must be an exact
64-hex digest; per-(sender, Hash) `first_seen` tracking enforces the
replay bound `expires_at <= first_seen + 2xTTL` (a replying peer
cannot extend an entry past two lifetimes); TTL clamped to its OWN
class (≤ 300 s — the generic ≤ 30 s clamp does not apply); **JudgeModel
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
boundary from Part 0.6.

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
  on every peer AND broadcasts `{lb_cool_purge, Target}` (new signal:
  receivers delete EVERY sender's cool-row for that target from the
  mirror — operator override semantics; without the purge, mirror
  rows keyed by other senders would outlive the local clear to TTL,
  re-sticking the pick for ≤ 30 s). Audited like every command.

Mechanics: a **command registry** pins the exact `M:F:A` per enum
name (`function_exported` prechecked; args validated locally —
`lb_cool_clear` target shape checked before ANY fan-out; unknown
name → 400, no fan-out, counter-asserted). Fan-out is parallel
`erpc:call(Peer, M, F, A, Timeout)` with per-command timeouts
(fleet_status 1 s, nudge/flush/clear 10 s), wrapped as
`try erpc:call(...) catch error:{erpc, R} -> {error, R}; Class:Reason -> {error, Class, Reason} end`
(erpc raises `error:{erpc, Reason}` — normalized first; other classes pass through). Common classes: `undef` (version skew),
`noconnection` (peer down), `timeout` (peer PAUSED — TCP alive, no
answer; F.7 asserts this for a paused peer). A down peer is `{error, noconnection}`;
PARTIAL SUCCESS IS SUCCESS (advisory cluster — no quorum, ever).
Every command is audited locally (actor/command/per-node results).
Version skew during rolling deploys: a command an old node lacks
raises `undef` there → per-node `{error, undef}`, reported, nothing
crashes (eunit drives the wrapper with a deliberately-missing
function; the gate does not need a skewed cluster). **Boundary
change, operator sign-off:** :8090 goes from read-only to hosting
idempotent fleet commands — same token auth, every invocation
audited.

**F.2 pg leader lease (no global, no Raft).** v1 duty:
observability + phase-4 readiness ONLY — it does NOT gate the quota
publisher (quota rows are per-sender; every node publishes its own,
storm-bounded by the ≥50 % filter + row cap; a single-publisher
lease would blind the fleet to keys hot only on non-holders). The
first real duty lands in phase 4 (video pending sweep migration);
until then the lease is reported (`/stats.fleet.lease`,
`fleet_lease_holder`) and gate-asserted to converge, nothing more. Design: holder = the LOWEST node name among live
pg members (deterministic, zero election traffic); each node ticks a
5 s lease check; on holder `nodedown`, the next-lowest claims within
net_ticktime + 5 s. `/stats.fleet.lease` reports
`{holder, expires_in_ms}`; `fleet_lease_holder` metric is 1 on the
holder, 0 elsewhere; `/stats.fleet.lease` reports
`{holder, next_check_in_ms}`. Split-brain dual-publish is accepted and bounded
(storm invariant), documented.

**F.3 Residual trust, stated honestly.** Erlang distribution has NO
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
Growing the enum still requires a spec revision (auditable drift).

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
- `/metrics` gains `fleet_commands_total{command, outcome}`,
  `fleet_lease_holder` (1 on the holder, 0 elsewhere), and Part B's
  signal counters; `/stats.fleet` additionally reports the last 20
  fleet commands (ring, with per-node results) and
  `lease {holder, expires_in_ms}`.
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

6. **F.6 quota gossip (observability-only):** drive a key's traffic
   at gw1 until its local counter crosses 80%; assert (a) gw2's
   `/stats.fleet` quota mirror shows the row within one heartbeat
   (≤ 3 s), (b) gw2's pick behavior is BYTE-IDENTICAL to a control
   run with the fleet knob off (same upstream hit counts — the pick
   never consults the quota mirror), (c) stopping gw1's traffic → the
   row TTLs out within 6 s + sweeper. No shed is asserted anywhere
   (advisory-only is the spec).
6b. **F.8 cache_put round-trip:** with the SAME tier config on
   gw1/gw2 and janus-auto traffic driven at gw1 until a decision is
   fetched+cached (miss), assert gw2's local decision cache serves
   the same hash WITHOUT its own upstream miss (mock judge counter
   deltas); a cache_put whose JudgeModel ≠ gw2's configured judge is
   dropped+counted (visible in `fleet_bad_ingress_total`).
7. **F.7 fleet commands + lease:** `fleet_status` via gw1's admin
   plane returns all three nodes' fleet state in one call; an unknown
   command name → local 400, zero peers contacted (log-asserted);
   the F.6 comparison binding has exactly ONE listing (deterministic
   hit counts); `lb_cool_clear` removes a cooled target's LOCAL
   cooldown row on ALL nodes AND its mirror rows on all peers within
   the cast window (purge signal); a PAUSED peer's slot reads
   `{error, timeout}` (TCP alive, no answer) and the command still
   succeeds on the rest (partial-success-is-success); pausing the lease holder moves
   the lease to the next-lowest node within net_ticktime + 5 s
   (single holder observed); eunit drives the try/catch wrapper with
   undef/timeout/noconnection.

Phase 4 (separate spec revision): dashboard-side video pending sweep
onto the lease; fleet-coordinated rolling-deploy drain; DNS-based
peer discovery if the fleet ever outgrows static peers.

## Part E — Explicitly rejected alternative

Postgres/NOTIFY as the health bus: zero new machinery, but ~2 s
propagation (poll interval) and DB writes from the data plane for
ephemeral signals — rejected by the operator in favor of native
distribution. Recorded here so the trade-off is auditable.
