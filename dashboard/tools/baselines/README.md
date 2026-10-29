# Gateway performance baselines (H6)

Committed baselines are reference points, never gates.

## What is in here

One JSON artifact per hardware class, produced by
`tools/bench_gateway.py` against the LOCAL stack (mock upstream
only — deterministic, zero billable traffic, zero production access):

| file | hardware class |
|------|----------------|
| `2026-10-15-win-dev.json` | Windows dev box (this repo's daily-driver machine) |
| `<date>-runner.json` | CI host hardware class — the self-hosted runner moved between cloud providers (old runner uninstalled + deregistered 2026-10-22); not yet recorded, see below |

Targets recorded: `healthz`, `models_list`, `chat_unary`,
`chat_stream_ttfb`, `chat_stream_total` — median/p95/mean/min/max ms,
per-target `rps`, request/error counts, and hardware context
(platform, cpu count). Every request opens a fresh connection; the
baseline is comparative (same tool on both sides of a diff), not an
absolute throughput claim.

## How to re-bench

Prerequisite: a running local stack (docker janus-pg/janus-gw/janus-judge + dashboard :8091)
boots it (gateway :8080, dashboard :8091, mock upstream :8099 —
`JANUS_MOCK_PORT` honored) and LEAVES IT RUNNING; the bench then runs
against the idle stack after the gate exits:

```bash
# Windows dev box (repo venv)
./.venv/Scripts/python.exe tools/bench_gateway.py \
    --class win-dev \
    --out tools/baselines/$(date +%F)-win-dev.json

# Linux/macOS
./.venv/bin/python tools/bench_gateway.py \
    --class <hw-class> \
    --out tools/baselines/$(date +%F)-<hw-class>.json
```

Notes:

- The tool is self-seeding and idempotent: it mints an ephemeral agent
  key (deleted on exit) and ensures its own `mock-bench` provider
  (healthy `mock-key-b` only — no failover variance) plus a
  `mock-bench-model` binding. It never touches the gate's
  `mock-failover` fixtures or any production system.
- Defaults (8 workers, 200 reqs, 20 warmup per target) are deliberate:
  the box also runs docker. Keep them identical when re-benching — the
  diff tool warns when `params` differ.
- If the gateway source under test lives in a worktree, boot the stack
  with `JANUS_GW_SRC=/f/Janus/.worktrees/<branch>` after booting the stack manually
  (same env override the harness documents).

### Recording the CI-host baseline

Not automatable from a dev box: it needs a local stack booted on the CI
host itself (the original runner this section was written for was
uninstalled and deregistered on 2026-10-22; the CI host has since moved). For
whoever has that host:

```bash
ssh <ci-host> 'cd <janus-dashboard checkout> \
  && <boot the local stack: janus-pg/janus-gw/janus-judge + dashboard :8091> \
  && ./.venv/bin/python tools/bench_gateway.py --class runner \
       --out tools/baselines/$(date +%F)-runner.json'
```

Then commit the resulting JSON back. Baselines are per hardware class
(H6-D2): never diff a `win-dev` artifact against a `runner` one.

## How to diff (and the never-gate rule)

```bash
python tools/bench_diff.py tools/baselines/2026-10-15-win-dev.json <new>.json
```

- `bench_diff.py` ALWAYS exits 0. CI NEVER fails on perf numbers
  (H6-D2: no flaky thresholds); the `!` markers on >25% moves are
  reading aids, not verdicts.
- When a PR touches a hot path — gateway `proxy` / `session` /
  `providers_http` / `pool` (Erlang modules), or anything on the
  request path they share — re-bench on the same hardware class and
  PASTE THE DIFF TABLE into the PR description. A human reads it;
  a machine does not gate on it.
- Expect noise: small (±10%) wobble on a shared dev box is normal.
  Sustained, reproducible shifts in `chat_stream_ttfb` p95 or
  `chat_unary` median are the signal worth investigating.
