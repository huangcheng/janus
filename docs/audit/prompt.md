# Role
Audit the attached Janus **design spec** only. Do not write code. Do not call tools.

Janus = Erlang/OTP 27 LLM gateway: Cowboy :8080 agent API / :8090 read-only admin (`/stats`, `/metrics`); ETS catalog rebuilt from leader Postgres with generation-poll hot-reload; `janus_lb` gen_server owns per-target cooldown ETS (`cooldown_ms/1`, lazy expiry, read_concurrency) plus latency EWMA shedding (`degraded_filter/4` never empties the candidate set; `latency_fun/1` treats entries older than `?EWMA_STALE_MS` as no-data); `janus_core_sup` one_for_one intensity 5/10s; vm.args hardcodes `-name janus@127.0.0.1`, cookie absent; the shipped relx start script SUPPORTS `RELX_REPLACE_OS_VARS` templating and passes through `-proto_dist`/`-start_epmd`/`-epmd_module`/`-kernel`/`-connect_all` lines, does NOT honor `RELEASE_NODE`/`RELEASE_COOKIE`; erl_call-based subcommands resolve via EPMD only. Fleet: **aliyun** = Postgres + dashboard + gateway leader; **jdcloud** / **tencent** = follower gateways polling leader Postgres over WAN; secrets in `/opt/stacks/janus/.env`; deploy = rolling via `janus-dashboard/scripts/deploy_prod.sh`; knobs default-off via persistent_term; sibling-repo E2E gate (docker compose) driven by TEST-FLOWS.md; repo rule: pure logic gets eunit FIRST with production-shaped fixtures, everything else is E2E-only.

**Verified OTP 27 ground truths (established against the official SSL "Using TLS for Erlang Distribution" guide, the live `inet_tls_dist` beam, and live-node experiments — do NOT re-dispute without contradicting evidence):**
1. `-ssl_dist_optfile` format is `[{server, Opts}, {client, Opts}]`; server opts feed `ssl:handshake/3`, client opts `ssl:connect/4`; fun values use `fun Mod:F/Arity` syntax.
2. `{verify_fun, {fun Mod:verify/3, InitState}}` IS supported in the optfile (guide's own example); events include `valid_peer` (leaf), `valid` (CA/intermediate), `{extension, _}`, `{bad_cert, _}`; returning `{valid, State}` on a `{bad_cert,_}` event RESCUES a failed path validation — hence the spec's never-`{valid}`-off-`valid_peer` rule.
3. On connect, `inet_tls_dist` automatically adds `{server_name_indication, atom_to_list(TargetNode)}` and verifies the server cert against that per-connection reference (`pkix_verify_hostname` in the OTP 27 beam).
4. `net_kernel:allow/1` exists and, with `verify_peer` + `fail_if_no_peer_cert`, enforces a node-name allowlist at the dist handshake.
5. **`erl_epmd:port_please/3` returns `{port, Port, Version}` where Version is the DISTRIBUTION PROTOCOL VERSION — empirically `6` on OTP 27** (live test: a registered node yields `{port, 34593, 6}`). Creation ∈ 1..3 belongs to `register_node`'s `{ok, Creation}` reply only. There is no public API for post-handshake peer-cert access on dist connections. OTP 27 `erl_epmd` exports include `port_please/2,/3`, `address_please/3`, `listen_port_please/2`, `register_node/2,/3`, `names/0,/1`, `start/0`, `stop/0`. A `pg` scope registers a local process under the scope name; `pg:start/1` on an existing scope returns `{error, {already_started, Pid}}`. Supervisor intensity exhaustion exits `shutdown`; `transient` children are NOT restarted on `shutdown`.

Attached = **rev 6** of "Native Erlang Distribution for the Janus Fleet" (3-node cluster, `inet_tls` mutual TLS 1.3, pinned port 25672, EPMD-less custom `erl_epmd` module returning `{port, Port, 6}`, `-connect_all false`, explicit connector loop, `pg` scope `janus_fleet_pg` with already_started tolerance, advisory self-expiring LB signals — cooldowns plus latency signals carrying the SENDER's `degraded|healthy` verdict — into per-sender `duplicate_bag` ETS mirrors with quorum/local-wins merge and never-empty guards, knob `JANUS_FLEET_ENABLED` default OFF with conditional vm.args rendering + loud cookie precondition + named env→PT bridge (`janus_fleet:init_knob/0` from `janus_core_app` start), `net_kernel:allow/1` + handshake `verify_fun` SAN-membership on `valid_peer` only with the peer list RENDERED into the verify_fun init state + certs with SAN = full node name, parked-safe `/stats.fleet` read path with status/nodes reported independently, TF-F.1–F.5 gate with explicit execution order F.5 → recreate gw3 → F.1 → F.2 → F.3 → F.4, F.4 drives gw3 to publish before the pause).

**Round history: R1 6/6 GWF → R2 2 GO + 3 GWF → R3 1 GO + 4 GWF → R4 6/6 GWF → R5 3 GO + 2 GWF (deepseek infra-flaky; zero NO-GO ever; every prior fold confirmed present+coherent by the following round).** Rev 6 folds ALL round-5 items (listed in the rev-6 header: sender-verdict field on the latency path with receiver re-derivation forbidden; F.4 pre-pause setup; pg already_started tolerance; F.2 TTL-window timing guard + counter deltas; F.3 phase-2 wait quantified; `{lb_recovered}` scoped to the cool table only; parked `/stats.fleet` status/nodes independence; named env→PT bridge; verify_fun init-state peer plumbing; one-liner sweep).

**Verdict rules for this re-audit:**
- Prefer **GO** if the folded items are actually present/coherent in the live text and only nitpicks remain.
- **GO WITH FIXES** only for NEW correctness holes — distribution-layer impossibilities, hot-path breakage, gate steps that cannot pass as written, security holes that defeat mutual TLS.
- **NO-GO** only if the design cannot work as written.
- Do not re-litigate folded items or the verified ground truths above without citing the exact live-text line and contradicting empirical evidence.

# Output (exact format required)
1. **Verdict:** GO / GO WITH FIXES / NO-GO — one sentence (this exact `Verdict:` line is required; put the token immediately after `Verdict:**`)
2. Critical risks (cite spec section) or "None"
3. Contradictions vs the codebase or "None"
4. First-ship gaps or "None"
5. Design notes (brief)
6. If GO: "None — ready for implementation plan." Else ≤5 concrete edits.

Under 400 words. Be skeptical and specific.
