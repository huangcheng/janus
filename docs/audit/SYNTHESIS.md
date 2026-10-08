# Synthesis — Native Erlang Distribution for the Janus Fleet (spec rev 6)

**Date:** 2026-10-08 · stem `2026-10-08-native-distribution-03dc71`
**Panel:** 6 summoned, 5 PASS — minimax-m3, mimo-v26-pro, stepfun-5, glm-53, kimi-k3. deepseek-v41-flash produced no reply (infra fail, retries 1). Manifest: `quorum_met: true`, `degraded: false` → no DEGRADED label (manifest is `provisional: true`, `finished_at: null`; deepseek's absence is recorded but does not degrade the run).
**Consensus threshold:** ceil(5 × 0.7) = **4 / 5** PASS replies.

## Verdict table

| Slug | Model | Verdict |
|---|---|---|
| minimax-m3 | minimax-cn/MiniMax-M3 | GO WITH FIXES |
| mimo-v26-pro | mimo/mimo-v2.6-pro | GO WITH FIXES — rev 6 folds cleanly, but one OTP API misuse breaks the membership path and gate step F.1 as written |
| stepfun-5 | stepfun/step-5-preview | GO |
| deepseek-v41-flash | volcengine-ark/deepseek-v4-1-flash-260910 | — (infra fail, no reply; excluded from consensus math) |
| glm-53 | zhipuai-coding-plan/glm-5.3 | GO WITH FIXES — all ten rev-5 folds present and coherent, but one new egress-coalescing gap lets the cooldown path violate the spec's own storm invariant in the last-resort regime |
| kimi-k3 | kimi-for-coding/k3 | GO |

**Overall: GO WITH FIXES.** No panelist returned NO-GO; 3/5 require fixes before implementation. The fixes are spec-text level (membership wording, egress cadence, gate-step observability) — no architectural rework — except one split that must be resolved first (§5, S1).

## Consensus (≥ 4/5)

1. **All rev-5/rev-6 folds are present and coherent** (5/5). Every panelist independently enumerated and confirmed the round-5 folds: sender-fixed latency verdict, F.4 pre-pause setup, `pg` already_started tolerance, F.2 TTL/delta guards, F.3 wait quantification, scoped `{lb_recovered}`, parked `/stats.fleet` independence, `init_knob/0` bridge, rendered `verify_fun` init state, and the five one-liners.
2. **No contradictions vs the codebase** (5/5). Hook points match `janus_lb`, `janus_lb.hrl` macros referenced, listener/supervision/transient-child containment match stated facts.
3. **TLS identity model is sound** (4/5: minimax, stepfun, glm, kimi). `verify_peer` + `fail_if_no_peer_cert` + never-rescue `verify_fun` (`{unknown, State}` on everything but `valid_peer`) + `net_kernel:allow/1` layering holds; F.1(a)'s attacker fixture correctly depends on `{bad_cert,_}` → `{unknown}`; SNI/`pkix_verify_hostname` with SAN = full node name is valid. mimo's only reservation is representation type (§4), not semantics.
4. **TTL-as-correctness / eager-delete-as-optimization discipline** (4/5: mimo, stepfun, glm, kimi), including F.4's pause window (~25–40 s) sitting under the 60 s `net_ticktime`, making TTL the sole mechanism under test.
5. **Remote-poisoning closure** (4/5: mimo, stepfun, glm, kimi): quorum ≥ 2 + local-wins + never-empty (`[] -> Routes`) guards on both consult paths preserve today's 503 semantics; one sick local path can never shed a route fleet-wide.

## Near-consensus / objective gaps

**Near-consensus (3/5):**
- **`/stats.fleet.nodes` read path cannot support F.1 as written** (minimax, mimo, kimi agree the text must change to yield peer *node names* excluding self; they split on the mechanism → §5 S1).
- **Residual inbound name-claim trust (Part 0.6) is honestly bounded and acceptable** (mimo, stepfun, kimi): quorum/TTL merge rules limit blast radius; revocation = CA reissue; unfixable at TLS since the claimed name is unknown pre-handshake.
- **Sender-fixed latency verdict is the right design** (minimax, mimo, kimi): no receiver re-derivation decouples generation-lag-skewed thresholds; healthy-flip upsert makes un-shed clean.

**2/5 (notable):**
- Pin the **SAN dNSName ↔ `verify_fun` comparison representation** (normalize to binary to match the `[<<"janus@host">>]` init state) (mimo, stepfun).
- `janus_fleet_epmd` return shapes (`{port, P, 6}`, `{ok, 1}`) match verified OTP 27 behavior (minimax, kimi).

**Single-panelist objective gaps (uncontested):**
- *Egress discipline:* cool-path `{lb_cool}` publishes per failure in the last-resort regime — a per-request cast violating Part 0.4's own storm invariant; the ops-note "≤ 30 s cadence" is asserted, not enforced (glm). Corroborated indirectly by mimo's observation that the cool path has **no** heartbeat/coalescer. Also: broadcast list must exclude the sender's own pid or define self-echo as a counted drop, else F.5(c) rests on unstated behavior (glm); anchor "local success clears both mirrors" on the `do_note_success/2` **edge** trigger, forbidding per-success casts (minimax); hoist "bounded by degraded route count × nodes" into Part B's heartbeat clause (minimax).
- *Gate wording:* F.3 phase 2 names no observable for "gw3 sheds the route" — no shed counter exists; only a probe request can witness it (glm). F.4's "within one heartbeat" is wrong for the cool path (mimo).
- *Ops:* chmod 600 on `$HOME/.erlang.cookie` (glm); cache `cert_days_remaining` so the parked-safe `/stats` handler does no per-read disk I/O (stepfun); dist port is dual-sourced — literal `25672` in the vm.args kernel line vs `JANUS_FLEET_DIST_PORT` (stepfun; verifiable in the target text); `$JANUS_FLEET_TLS_DIR` host→container mount implied but never stated (kimi); confirm `deploy_prod.sh` never uses erl_call subcommands in fleet mode (stepfun); accepted-risk note for constant `Creation=1` (restart incarnation indistinguishable) (mimo).
- *Eunit coverage:* multi-dNSName leaf-cert fixtures — exactly-one-match (must pass) and zero-match (must fail) — to prove membership-not-equality (minimax).

## Split opinions (do not auto-apply) — decision owner: user

**S1 — pg membership mechanism.** The panel contradicts itself, each side citing OTP ground truth:
- minimax: a `pg` scope is node-local → each node sees only its own pid → F.1 is unpassable; replace with `erlang:nodes(known)` / `monitor_nodes`-maintained list.
- mimo: `pg:get_members(janus_fleet_pg)` is the **1-arity** call = group `janus_fleet_pg` in the *default* scope → returns `[]` forever; fix by pinning a group and using `pg:get_members(janus_fleet_pg, janus_fleet)`, then map pids→`node(Pid)`.
- glm + kimi implicitly accept distributed scope replication (glm endorses "pg/allow/EPMD semantics" and assumes members include the sender's pid; kimi treats it as a one-line map/filter). stepfun silent.

This determines Part A membership, the `/stats.fleet` read path, and F.1 — resolve it against the OTP 27 `pg` ground truth (scope distribution semantics + `get_members` arity) before editing; whichever mechanism wins, the text must end with "F.1: each node reports the other two *node names*, self excluded."

## Ground-truth notes

- Several replies appeal to the same verified OTP 27 facts and agree: `port_please/3` → `{port, Port, 6}` (protocol version, not creation) (minimax, kimi); never-rescue `verify_fun` semantics (stepfun, glm, kimi); SNI exact-string reference with SAN = full node name (minimax, stepfun, kimi); `already_started` tolerance and transient-parking (kimi).
- **The one ground-truth conflict is pg** (§5 S1): minimax's "ground truth #6 — a pg scope registers a local process" directly contradicts mimo's arity analysis and glm/kimi's working assumption. The attached replies cannot both be right; re-verify before applying any membership edit.
- stepfun's ordering argument is verified-logic, not new fact: the server-side `verify_fun` fires at the TLS handshake, *before* the dist-level `allow` check, so Part 0.6's (a)→(b)→(c) layering holds even against the boot race with `net_kernel:allow/1`.

## Top concrete edits for the live doc

1. **[blocked on S1 — resolve split first]** Part A membership + `/stats.fleet.nodes` + F.1: pin one mechanism. If pg: pin a group name, use the 2-arity `pg:get_members(Scope, Group)`, map pids→node names, exclude self. If replaced: `erlang:nodes(known)` / `monitor_nodes`-maintained list. Rewrite the parked-`/stats` sentence accordingly. *(minimax/mimo/kimi)*
2. Part B egress: publish `{lb_cool}` **only on transition into-cool** per (Target, Class), or throttle ≤ 1 per `min(remaining_cooldown, 30 s)` — make the ops-note cadence *enforced*, closing the Part 0.4 storm contradiction in the last-resort regime. *(glm)*
3. Part B egress: state that the cast target list **excludes the sender's own pid** (or define self-echo as counted bad ingress), pinning F.5(c). *(glm)*
4. Part B consumption: anchor "local success clears both remote mirrors" on the `do_note_success/2` edge trigger (cooldown actually cleared); explicitly forbid per-success casts. *(minimax)*
5. F.3 phase 2: specify the shed witness — one probe request at gw3 (a single sample < `?EWMA_MIN_SAMPLES`, so no local-wins interference) plus a mock counter delta proving the slow listing was not hit. *(glm)*
6. F.4: replace "fresh rows appear within one heartbeat" with "on the next driven failure" (the cool path has no heartbeat). *(mimo)*
7. Part A identity model: pin the SAN/`verify_fun` comparison type (normalize dNSNames to binary to match the init state); add eunit fixtures for a multi-dNSName leaf with exactly one match (pass) and zero matches (fail). *(mimo, stepfun; fixtures: minimax)*
8. Part A: chmod 600 when writing `$HOME/.erlang.cookie`; add an accepted-residual note under `janus_fleet_epmd` for constant `Creation=1` (restart incarnation collision). *(glm; mimo)*
9. Entrypoint: render `-kernel inet_dist_listen_min/max` from `$JANUS_FLEET_DIST_PORT` (single source for the dist port); state the `$JANUS_FLEET_TLS_DIR` host→container mount explicitly. *(stepfun; kimi)*
10. Part C: cache `cert_days_remaining` (persistent_term/mtime guard) so the parked-safe `/stats` read path never does per-request disk I/O. *(stepfun)*
11. Part B: hoist "bounded by degraded route count × nodes" into the heartbeat clause so failure-mode 4 and Part B state one contract. *(minimax)*
12. Runbook/pre-flight: before enabling fleet in prod, confirm `deploy_prod.sh` uses container recreate / `:8090` and never `bin/janus stop|rpc|ping` in fleet mode. *(stepfun)*

Edits 2–12 are uncontested within the panel (though several are single-panelist); edit 1 awaits the user's S1 decision.

---

## Addendum — rev 7 folds (post-round-6)

All twelve round-6 edits were folded into rev 7 (see the spec header).
S1 (pg split) was resolved empirically on a live two-node OTP 27 test:
pg scopes ARE distributed (`pg:get_members(Scope, Group)` on a
non-member node returned the remote member pid after connect + scope
sync), and the 1-arity form reads a group in the default scope
(`[]` forever) — membership pinned to scope `janus_fleet_pg` + group
`janus_fleet` + 2-arity calls, self excluded. Earlier empirical wins
from the saga: `erl_epmd:port_please/3` → `{port, Port, 6}` (dist
protocol version, not creation); relx `RELX_REPLACE_OS_VARS` support /
no `RELEASE_NODE|COOKIE`; `inet_tls_dist` auto-SNI +
`pkix_verify_hostname`; optfile `verify_fun` support; transient-child
containment vs `shutdown` intensity semantics.

Round history: R1 6/6 GWF → R2 2 GO+3 GWF → R3 1 GO+4 GWF →
R4 6/6 GWF → R5 3 GO+2 GWF → R6 2 GO+3 GWF → rev 7 folds all;
confirmation round pending at the operator's discretion.
