# 2026-11-05 — master boot crash loop, and two ceilings that never moved

Three distinct defects reached production in one afternoon. Each one was
invisible to the pipeline that shipped it, and each one is now pinned by a
gate that fails if it comes back.

## 1. `undef` on master boot — the fleet half-died

**Symptom.** After a routine release, four workers came up clean and the
master entered a restart loop. `janus_config` never started, so the node
served nothing.

```
{undef,[{janus_http_sup,idle_timeout_ms,[],[]}]}
```

**Cause.** A commit added `janus_config:refresh_http_idle_timeout/0`, which
calls `janus_http_sup:idle_timeout_ms/0`. That function had only ever been
called from its own module, where no export is required, so it was not
exported. Erlang resolves remote calls at RUNTIME: it compiled, every test
passed, and the call failed only when a master executed that path.

Workers never run `publish_catalog`, so they never reach it — which is why
the rollout looked half-successful.

**Why nothing caught it.**

| Layer | Why it was blind |
|---|---|
| compiler | does not check remote export/arity |
| EUnit (237 cases) | `/1` was exported and tested; `/0` was local-only |
| code review | sees only files the commit **touched**; the *called* module was an old file |
| dialyzer | needs a PLT; CI does not build one |

**Fix.** Export it, with a comment saying it must stay exported, plus a
test that calls it **from another module** so deleting the export goes red.

**Gate added.** `gateway/scripts/verification/check_remote_exports.escript`
walks every app source and checks each `mod:fun(...)` against that module's
real exports. Arity comes from the AST via `erl_syntax` — a text heuristic
cannot distinguish an exported `/1` from a missing `/0`, which is exactly
what this incident needed. It runs in CI before EUnit.

Verified by reconstruction, not assertion: removing the export makes the
gate print the failing call; restoring it passes.

## 2. Stream ceiling could not be raised

**Symptom.** A long agent turn streamed 141,960 characters of reasoning and
was cut at exactly 600.0s with `upstream stream exceeded the total time
budget`, provider healthy and sending data throughout.

**Cause.** The 600s stream total was a compiled constant. Its own comment
said a legitimately longer generation shape would need "a configurable
knob, not a bigger constant" — this was that shape. A TOTAL budget cannot
tell "still thinking" from "stuck"; the inactivity deadline (180s) already
draws that line.

**Fix.** `stream_timeout_ms/0` reads `translate.stream_total_timeout_ms`
on every call, defaulting to 600_000. Ordering `inactivity < total` is
enforced at the READ site, not only in the dashboard, because the settings
row can be written by a direct edit or an ops script.

## 3. The transport ceiling ignored the setting — twice

**Symptom.** Even with the knob at 1,800,000, streams still died at exactly
1200.0s.

**Cause 1.** The first attempt refreshed the listener with
`cowboy:set_env(Ref, idle_timeout, V)`. That function writes into the
protocol options' **`env` sub-map**, but `idle_timeout` is a TOP-LEVEL
option. The write went where Cowboy never reads, the reload logged
success, and the ceiling never moved.

**Cause 2.** The fix for cause 1 was only exercised after a settings row
was edited directly with SQL. That does not bump `config_generation`, so
`do_reload/2` skipped and no refresh ran at all. The dashboard PUT bumps it
automatically; a manual edit must bump it too.

**Fix.** Replace the value on the protocol options themselves through
`ranch:set_protocol_options/2`, with the listener refs named once in
`janus_http_sup:listener_refs/0` so the refresh and `/stats` cannot drift.
A failed write now logs and returns an error instead of reporting success —
the original bug was a silent no-op, and repeating that shape inside the
fix was the wrong trade.

`/stats.stream_budgets` now reports what the **running listener** honours:

```json
{ "total_ms": 2400000, "inactivity_ms": 180000,
  "keepalive_ms": 15000, "http_idle_timeout_ms": 4800000 }
```

Two incidents were diagnosed with a stopwatch before this existed.

## Operating notes

- Raising the stream ceiling needs **both** a settings write **and** a
  `config_generation` bump. Use `PUT /api/settings/translate` (bumps
  automatically) rather than SQL.
- Verify with `/stats.stream_budgets`, not by timing a stream.
- Known-bad tag `7268001…` is listed in the private inventory; the deploy
  and rollback scripts refuse it.

## What is still upstream's problem

`qwen3.8-flash` spends its whole budget reasoning and can reach
`response.incomplete` with no answer text; `dashscope` also closes long
requests with `GOAWAY app_requested` around 535s. Those are model/capacity
limits, not gateway limits — the gateway no longer cuts the stream, and
`qwen3.8-max` completes the same tasks normally.