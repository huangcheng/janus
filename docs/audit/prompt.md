# Role
Audit the attached Janus **design spec** only. Do not write code. Do not call tools.

Janus = Erlang/OTP 27 LLM gateway: Cowboy :8080 agent API / :8090 read-only admin (`/stats`, `/metrics`); ETS catalog rebuilt from leader Postgres with generation-poll hot-reload; `janus_lb` gen_server owns per-target cooldown ETS (`cooldown_ms/1`, lazy expiry, read_concurrency) plus latency EWMA shedding (`degraded_filter/4` never empties the candidate set; `latency_fun/1` treats entries older than `?EWMA_STALE_MS` as no-data); `janus_core_sup` one_for_one intensity 5/10s; vm.args hardcodes `-name janus@127.0.0.1`, cookie absent; the shipped relx start script SUPPORTS `RELX_REPLACE_OS_VARS` templating and passes through `-proto_dist`/`-start_epmd`/`-epmd_module`/`-kernel`/`-connect_all` lines, does NOT honor `RELEASE_NODE`/`RELEASE_COOKIE`. Fleet: **aliyun** = Postgres + dashboard + gateway leader; **jdcloud** / **tencent** = follower gateways polling leader Postgres over WAN; secrets in `/opt/stacks/janus/.env`; deploy = rolling via `janus-dashboard/scripts/deploy_prod.sh`; knobs default-off via persistent_term; sibling-repo E2E gate (docker compose) driven by TEST-FLOWS.md; repo rule: pure logic gets eunit FIRST with production-shaped fixtures, everything else is E2E-only.

**Verified OTP 27 ground truths (established against the official SSL "Using TLS for Erlang Distribution" guide and the live `inet_tls_dist` beam — do NOT re-dispute without contradicting evidence):**
1. `-ssl_dist_optfile` format is `[{server, Opts}, {client, Opts}]`; server opts feed `ssl:handshake/3`, client opts `ssl:connect/4`; fun values use `fun Mod:F/Arity` syntax (file is consulted, not compiled).
2. `{verify_fun, {fun Mod:verify/3, InitState}}` IS supported in the optfile (guide's own example), called per cert chain event with `(OtpCert, Status, State)` returning `{valid, State'}` / `{fail, Reason}` / `{unknown, State'}`.
3. On connect, `inet_tls_dist` automatically adds `{server_name_indication, atom_to_list(TargetNode)}` and verifies the server cert against that per-connection reference (`pkix_verify_hostname` — present in the OTP 27 beam) — i.e. client-side identity vs the exact dialed node name is built in.
4. `net_kernel:allow/1` exists and, with `verify_peer` + `fail_if_no_peer_cert`, enforces a node-name allowlist at the dist handshake.
5. There is NO public API to extract the TLS socket / peer cert of an established dist connection post-handshake; `erl_epmd` OTP 27 exports include `port_please/2,/3`, `address_please/3`, `listen_port_please/2`, `register_node/2,/3`, `names/0,/1`, `start/0`, `stop/0`; `{port, Port, Creation}` requires Creation ∈ {1,2,3}; OTP supervisor intensity exhaustion exits with `shutdown`, and `transient` children are NOT restarted on `shutdown`.

Attached = **rev 4** of "Native Erlang Distribution for the Janus Fleet" (3-node cluster, `inet_tls` mutual TLS 1.3, pinned port 25672, EPMD-less via custom `erl_epmd` module, `-connect_all false`, explicit `net_kernel:connect_node/1` connector loop, `pg` broadcast, advisory self-expiring LB signals into per-sender `duplicate_bag` ETS mirrors with quorum/local-wins merge, knob `JANUS_FLEET_ENABLED` default OFF with CONDITIONAL vm.args rendering, `net_kernel:allow/1` + handshake `verify_fun` SAN-membership + certs with SAN = full node name, `/stats.fleet` read path that never calls into the gen_server, TF-F.1–F.5 gate with 3 gateway containers).

**Round-1 was 6/6 GWF, round-2 2 GO + 3 GWF, round-3 1 GO + 4 GWF (deepseek worker infra-failed twice, never produced a verdict). Every prior fold was confirmed present and coherent by the following round's panel; rev 4 additionally folds ALL round-3 findings** (listed in the rev-4 header: verify_fun inbound mechanism replacing the impossible post-handshake claim; optfile tuple format; automatic per-connection SNI/node-name verification replacing the static `customize_hostname_check`; SAN = full node name `janus@<host>` dissolving the IP/DNS split; conditional vm.args render fixing the knob-off boot-breaker; `net_kernel:connect_node/1` connector loop named; `/stats.fleet` parked-safe read path; epmd Creation/arity corrections; F.1 rewritten negative cases (a: non-fleet CA refused, b: SAN∉peers refused at handshake, c: name∉allow refused at dist handshake); F.5 `proto_dist`-absent boot assertion + ordering fix; tcp+tcp6 EPMD check; rollout `nodes: []` note; tripwire ops note).

**Verdict rules for this re-audit:**
- Prefer **GO** if the folded items are actually present/coherent in the live text and only nitpicks remain.
- **GO WITH FIXES** only for NEW correctness holes — distribution-layer impossibilities, hot-path breakage, gate steps that cannot pass as written, security holes that defeat mutual TLS.
- **NO-GO** only if the design cannot work as written.
- Do not re-litigate folded items or the verified ground truths above without citing the exact live-text line and the contradicting evidence.

# Output (exact format required)
1. **Verdict:** GO / GO WITH FIXES / NO-GO — one sentence (this exact `Verdict:` line is required; put the token immediately after `Verdict:**`)
2. Critical risks (cite spec section) or "None"
3. Contradictions vs the codebase or "None"
4. First-ship gaps or "None"
5. Design notes (brief)
6. If GO: "None — ready for implementation plan." Else ≤5 concrete edits.

Under 400 words. Be skeptical and specific.
