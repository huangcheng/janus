# Janus — Agent Instructions

Erlang/OTP LLM gateway (data plane). Its management plane lives in the
**sibling repo `../janus-dashboard`** (Python FastAPI + React SPA): most
feature work touches both. All comments, docs, and commit messages in
English. Respond in the user's language (Chinese → Chinese).

## Layout

- `apps/janus` — root release app
- `apps/janus_core` — DB (epgsql/esqlite via `janus_db_conn`), ETS catalog
  (`janus_catalog`), LB (`janus_lb`), usage writer (`janus_usage`), seed
- `apps/janus_http` — Cowboy listeners (:8080 agent API, :8090 read-only
  admin `/stats`), protocol translate, `janus_auto` (janus-auto adjudicator)
- `apps/janus_providers` — upstream adapters (OpenAI/Anthropic over gun)
- `apps/janus_dashboard/` — **stale leftover, dashboard moved out**; ignore it
- `../janus-dashboard/` — FastAPI backend (`app/`), SPA (`spa/`),
  **all test/deploy tooling** (`scripts/`), `docs/TEST-FLOWS.md`

## Testing — THE RULES (user-mandated)

1. **Never write unit tests after writing code.** E2E is the sole test
   mechanism. Exception: pure parsers/logic may get eunit **written
   first**, with production-shaped fixtures (JSON-decoded binary keys,
   Postgres SMALLINT 0/1, driver tuples) — never hand-idiomatic shapes.
2. Before writing complex code (or testing a system in isolation),
   **first list the failure modes to guard against** and the invariants
   to preserve; only then write the code.
3. **All testing is LOCAL** (`bash ../janus-dashboard/scripts/e2e_local.sh`,
   47-step real-stack gate: real Postgres + real gateway + real upstream).
   Production is NEVER mutated by tests — only the read-only smoke
   (`run_test_flows.py --smoke`) runs there.
4. **Browser-test the UI** (all pages/features via real clicks), not just
   APIs. Built-in browser tools or `browser-use`; screenshots saved to a
   durable path and referenced when reporting.
5. E2E runs must end with **verifiable, repeatable artifacts** (logs,
   screenshots, the PASS/FAIL list) saved durably (e.g. `/tmp/...` or a
   vault note) and referenced in commit messages.
6. Nothing is "done" until the local gate is green. Fixture realism rule:
   bugs this project shipped (binary-vs-atom keys, SMALLINT booleans,
   open-map `case M of #{}`) all came from unrealistic fixtures.

## Build & deploy

- Compile/eunit in a container (Windows host Erlang is broken; local
  `_build` gets stale — build in Docker). The only documented commands:

  ```bash
  docker build --target test -t janus-build:test .
  docker run --rm -v F:/Janus/apps:/app/apps -v F:/Janus/config:/app/config -v F:/Janus/rebar.config:/app/rebar.config -v F:/Janus/rebar.lock:/app/rebar.lock -v janus-ebin-otp27:/app/_build -w /app janus-build:test sh -c 'rebar3 fmt --check && rebar3 eunit'
  ```

  Never bind-mount the repo root over `/app` (the image owns
  `/usr/local/bin/rebar3` and the warm hex cache under
  `/root/.cache/rebar3`); mount only `apps/`, `config/`, and the rebar
  files, with `_build` on the named volume. Recreate the volume
  (`docker volume rm janus-ebin-otp27`) when `rebar.lock`,
  `rebar.config`, or the OTP version changes, else stale beams. The
  `test` stage never hits `dl-cdn.alpinelinux.org` (Aliyun apk mirror
  inside the image). CI runs the same image without mounts
  (`eunit-docker` job).
- Deploy = `bash ../janus-dashboard/scripts/deploy_prod.sh` (from the
  dashboard repo): rebuild → run local gate → rolling rollout (aliyun is
  the migration leader; followers only after its migration is verified)
  → read-only smoke. Migrations run automatically at gateway boot
  (`janus_db_conn` init); add new ones under
  `apps/janus_core/priv/migrations/{postgres,sqlite}/` + flat copies.
- Production: janus.noveo.cn (aliyun, gateway+dashboard+Postgres),
  janus.kleos.cn (jdcloud), janus.misthios.cn (tencent); all secrets on
  servers under `/opt/stacks/janus/.env` (root 600). Never commit keys;
  gitleaks hook should be installed.

## Architecture invariants

- **Pure gateway**: no business logic beyond routing/LB/adjudication on
  the data plane; management logic belongs in the dashboard repo.
- Config flows dashboard → shared Postgres → generation bump → gateways
  poll & hot-reload (never edit `sys.config` by hand on servers; the
  `settings` table overrides it via `janus_config:distribute_settings`
  → persistent_term — direct PT writes, NOT gen_server casts: consumers
  may not be started yet at boot).
- Settings/cross-process values that must survive start order go through
  persistent_term, not name-registered casts.
- Catalog is ETS rebuilt from DB; `enabled` columns are SMALLINT 0/1 —
  normalize to booleans on read, write 1/0 in SQL (never `true`).
- Cowboy listeners set `idle_timeout => 300_000` — upstreams may take
  60s+ to first byte; the default 60s kills handlers (bodiless 502).
- Agent model surface = union of all provider listings
  (`/v1/models`), bound models, and the `janus-auto` virtual model;
  unbound listings are directly callable (`pick_listing_route`).
- janus-auto tiers (fast/big/flagship) are **mutually exclusive** and
  validated against Router bindings; the judge may be any listing.
- Cross-protocol translate surfaces anthropic thinking blocks as
  `reasoning_content`; `case Map of #{}` matches EVERY map — use
  `map_size/1` for emptiness checks.
- eunit for `janus_usage` boots the real gen_server (stateful modules
  are tested live, not just pure helpers).

## Read before touching

- `../janus-dashboard/docs/TEST-FLOWS.md` — the E2E flows + authoring rules
- `docs/SCHEMA_ETS_CONTRACT.md`, `../janus-dashboard/docs/SPEC.md`
- `docs/superpowers/plans/*.md` — audited specs (usage stats, auto-router)
