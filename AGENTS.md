# Janus — Agent Instructions

Janus is an Erlang/OTP LLM gateway (data plane) with a Python/React
management plane in `dashboard/`. Most feature work touches both.


## Iron rules for this repository

This is a PUBLIC repository. NEVER commit user-specific or
deployment-specific content — no server IPs, domains, host names,
cloud names, SSH details, registry paths, private key material, or
the contents of `deploy/inventory.env`. The inventory file is
gitignored BY DESIGN; only its `.example` twin is committed, and the
example must contain placeholder values only. Before every commit,
check the diff for anything that names a real machine, provider
account, or operator identity — if a change needs fleet specifics to
work, those specifics belong in an env file or the dashboard
database, not in git.

## Core ideas

- **The gateway translates; it does not judge.** The data plane
  speaks standard protocols (OpenAI Chat/Responses, Anthropic
  Messages, the standard modality endpoint shapes) on both sides and
  translates between them. No provider-dialect adapters — a provider
  without standard-shaped endpoints does not ride the gateway.
- **Master / worker.** The master owns the front door, the catalog
  (Postgres → ETS) and the LB. Workers execute provider I/O and send
  stream chunks back as messages. Empty pool, dispatch failure, or a
  pre-first-byte worker loss falls back to master-local execution.
  In-flight worker loss aborts (`worker_lost`, no mid-stream retry).
- **Everything hot.** Config flows dashboard → Postgres on the
  master → generation bump → hot reload through persistent_term.
  Never edit `sys.config` on servers; never require a restart to
  change a knob.
- **Fail closed, fail LOUD, fail with the provider's own words.**
  Untranslatable shapes get precise, distinct 400s. Terminal failure
  rows carry the upstream's error message. Shape-class failures
  capture a structural fingerprint (never content) —
  `gateway/docs/design/shape-sentinel.md`.
- **Repair agent histories at the door.** Interrupted tool calls get
  a synthesized `[tool call interrupted - no result]`; orphan results
  (ids matching no call) are dropped; every known malformation that
  strict upstreams reject is normalized before dispatch.

## Working conventions

- All comments, docs, and commit messages in English. Respond in the
  user's language.
- Before writing complex code, list the failure modes to guard
  against and the invariants to preserve; only then write the code.
- New capability families ship behind settings knobs, ALL default
  off; the operator flips them. Knob-off paths keep their legacy
  error behavior.
- Catalog is ETS rebuilt from Postgres; `enabled` columns are
  SMALLINT 0/1 — normalize on read, write 1/0 in SQL (never `true`).
- `#{}` matches EVERY map — use `map_size/1` for emptiness checks.
- Cowboy listeners run `idle_timeout => 300_000`; upstreams may take
  60s+ to first byte.
- Migrations live in `gateway/apps/janus_core/priv/migrations/` and
  run automatically at gateway boot; additive only, rolling-deploy
  safe.
- Deployment: `dashboard/scripts/deploy_prod.sh` (docker or bare
  metal per node — two independent paths, no migration between
  them). Fleet specifics live ONLY in `gateway/deploy/inventory.env`
  (gitignored; see the `.example`).

## Verification

- Static gates: `rebar3 fmt --check` + `rebar3 compile` (CI runs
  exactly these two).
- Runtime behavior is verified LIVE against a real stack (real
  Postgres, real upstreams, curl + browser), never asserted in
  checked-in test suites.
- Production is never mutated by verification: read-only curl and
  browsing only.
