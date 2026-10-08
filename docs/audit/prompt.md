# Role
Audit the attached Janus implementation spec only. Do not write code. Do not call tools.

Janus = Erlang/OTP LLM gateway (Cowboy :8080/:8090; ETS catalog + generation hot-reload; janus_lb cooldowns + EWMA latency shedding + Slice-Q per-node quotas; janus-auto adjudicator with decision cache; three prod nodes on different clouds behind one dashboard; deploys via docker compose recreate; sibling-repo E2E gate). The spec makes the three nodes ONE Erlang cluster over TLS distribution for advisory runtime signals (cooldowns, latency verdicts), quota gossip, judge decision-cache sharing, a closed-enum erpc fleet command channel, and a lowest-node pg leader lease — with local-wins, TTL-only, knob-off-identical discipline. Rev 10 = rev 9 + round-2 folds (replay bound enforced via first_seen+2xTTL, WindowId boundary acceptance, command registry with pinned MFAs + per-command timeouts + timeout-class for paused peers, top-32 quota publish cap, byte clamps, nodedown purge scope, entrypoint cert preflight, TF-F.8). Rounds 1-2 were 7/7 GO WITH FIXES each; verify folds and judge ship-readiness.

Audit skeptically with special attention to the NEW parts (B2, F, F.6/F.7) against: Erlang distribution reality (net_ticktime 60s detection, pg scope sync, erpc semantics incl. version-skew undef, -connect_all false non-transitive mesh, TLS dist handshake), the spec's own Part 0 failure modes (does every new payload inherit TTL/local-wins/last-resort/row-caps?), security surface (closed enum actually closed? lease split-brain bounded? command channel auth reuse?), and operational safety on three-cloud WAN.

# Required output format
1. Verdict: GO / GO WITH FIXES / NO-GO — one sentence
2. Critical risks (new-parts focus: quota gossip correctness at 2s cadence, cache_put replay/poison bounds, erpc command enum closure + authz, lease dual-hold blast radius, eunit/gate testability of F.6/F.7, WAN reality)
3. Contradictions or stale claims (vs Parts A-E or Erlang docs)
4. Missing first-ship requirements
5. Architecture/design notes
6. Top 5 concrete edits

Under 450 words. Be skeptical and specific.
