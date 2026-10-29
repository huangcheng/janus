# Janus Dashboard

Management plane for the [Janus](../) LLM
gateway. Python FastAPI backend + React SPA (TanStack Router, shadcn/ui).

Janus is the data plane (Erlang/OTP master/worker cluster). This repo is the
sole config writer and operator UI against the shared Postgres catalog, plus
read-only health / scheduler observation of gateway nodes.

## Status

**Production management plane** for the live multi-node Janus cluster
(past the early single-node / embedded-dashboard phase). Owns provider and
key CRUD, model routes, `janus-auto` router config, usage rollups, audit,
and Nodes observation (registered **gateways** + **workers** scraped from
master `GET /stats/sched`).

Workers are **not** registered here — they hello into the master’s OTP pool
(see the deployment runbooks).
Day-to-day ship path: local E2E gate → `scripts/deploy_prod.sh` → read-only
prod smoke. Production is never mutated by tests.

## Quick start

```bash
cp .env.example .env  # fill in required vars
pip install -e .
uvicorn app.main:app --host 0.0.0.0 --port 8091
# open http://localhost:8091
```

Required at startup (fail-closed — see the table in
[Environment variables](#environment-variables) for every optional knob,
default, and the deploy/inventory surface): `JANUS_DB_PASSWORD`,
`JANUS_DASHBOARD_PASSWORD`, `JANUS_JWT_SECRET`, `JANUS_SECRETS_KEY`,
`JANUS_API_KEY_PEPPER`, `JANUS_STATS_TOKEN`.

## Environment variables

One canonical reference for every variable the dashboard and its tooling
read. Sources of truth: `app/config.py` + `app/egress.py` (backend),
`spa/src/` (build flags), this repo's `scripts/`, and the fleet inventory
(canonical file `../janus/deploy/inventory.env`, annotated template
`../janus/deploy/inventory.env.example`). Gateway-side runtime env
(`janus-gw.env` on each node) is documented in the
the [gateway README](../gateway/README.md) §Environment variables.

### Dashboard backend runtime (`.env`)

Read once at startup. Invalid values fall back to the default with a
startup warning — a typo never silently widens a retention window or
disables auth.

| Variable | Default | Purpose |
|---|---|---|
| `JANUS_DB_HOST` / `JANUS_DB_PORT` / `JANUS_DB_USER` / `JANUS_DB_NAME` | `localhost` / `5432` / `janus` / `janus` | Shared Postgres (the same one the gateways use) |
| `JANUS_DB_PASSWORD` | **required** | Postgres password |
| `JANUS_DASHBOARD_PASSWORD` | **required** | Login password |
| `JANUS_JWT_SECRET` | **required** | JWT signing (persist across restarts) |
| `JANUS_SECRETS_KEY` | **required** | JSEC keyring `k1:<base64-32-bytes>` — must equal the gateway's (provider key encryption) |
| `JANUS_API_KEY_PEPPER` | **required** | HMAC pepper — must equal the gateway's (agent key hashing) |
| `JANUS_STATS_TOKEN` | **required** | Default bearer token for gateway `/stats` + `/stats/sched` polling; per-gateway `stats_token` (encrypted at rest) overrides it per node |
| `JANUS_SESSION_TTL_SEC` | `604800` (7 days) | JWT lifetime |
| `JANUS_LOGIN_MAX_FAILS` / `JANUS_LOGIN_LOCKOUT_SEC` | `5` / `900` | Per-IP login lockout (see `JANUS_TRUSTED_PROXIES`) |
| `JANUS_DASHBOARD_HOST` / `JANUS_DASHBOARD_PORT` | `0.0.0.0` / `8091` | uvicorn bind |
| `JANUS_NODE_HEALTH_INTERVAL_SEC` | `10` | Node health + sched scrape + log-pull interval |
| `JANUS_MODEL_SYNC_INTERVAL_SEC` | `21600` (6 h) | Background provider `/models` refresh |
| `JANUS_UPSTREAM_TLS_VERIFY` | `peer` | TLS verification for provider calls the dashboard itself makes (`none` disables — never in prod) |
| `JANUS_DASH_EGRESS_POLICY` | unset (off) | `on` = egress-token policy: stats polling to non-loopback hosts must use that node's own encrypted `stats_token`, not the global one |
| `JANUS_TRUSTED_PROXIES` | unset | Comma list of proxy IPs trusted for `X-Forwarded-For`; unset keys the login lockout on the direct peer (behind caddy every operator shares one bucket — `main.py` warns at startup) |
| `JANUS_PROBE_MAX_CALLS` / `JANUS_PROBE_DAILY_CALLS` | `1000` / `5000` | Entitlement-probe call budgets (per run / per day) |
| `JANUS_PROBE_TIMEOUT_SEC` / `JANUS_PROBE_SPACING_MS` / `JANUS_PROBE_WALL_SEC` | `15.0` / `150` / `600` | Entitlement-probe pacing |
| `JANUS_ENTITLEMENT_HEALING_INTERVAL_SEC` | `900` | Entitlement healing loop interval |
| `JANUS_MAXMIND_ACCOUNT_ID` / `JANUS_MAXMIND_LICENSE_KEY` | unset | MaxMind credentials for the GeoLite2-City refresh (`scripts/fetch_geolite2_mmdb.sh`) |
| `JANUS_MMDB_PATH` | `/var/lib/janus/geo/GeoLite2-City.mmdb` | GeoLite2 database path (must match the master gateway mount) |
| `JANUS_REORDER_LOOP` | `1` | Auto-router tier reorder loop; `0`/`false`/`off` = hard kill switch |
| `JANUS_REORDER_LEADER_NODE` | unset | Which registered gateway the reorder loop polls for stats (default: lowest-id enabled node) |
| `JANUS_ALERT_WEBHOOK_URL` | unset | http(s) only, no userinfo; unset or invalid = record-only mode (events still land in `alert_events` and on the dashboard card) |
| `JANUS_ALERT_RULES_DISABLED` | unset | Comma-separated rule names — **never disable `node_unreachable`**: a dead gateway would go silently unnoticed |
| `JANUS_ALERT_ERROR_RATE_PCT` / `JANUS_ALERT_ERROR_RATE_MIN_TOTAL` | `20.0` / `20` | Error-rate alert threshold and minimum sample size |
| `JANUS_ALERT_FOR_CYCLES` / `JANUS_ALERT_REFIRE_COOLDOWN_SEC` | `2` / `1800` | Cycles an alert must hold + refire cooldown |
| `JANUS_AUDIT_RETENTION_DAYS` / `JANUS_LOG_RETENTION_DAYS` / `JANUS_ALERT_RETENTION_DAYS` / `JANUS_OPS_RETENTION_DAYS` | `90` / `14` / `30` / `14` | Nightly retention sweeps (`app/maintenance.py`, checked hourly; open episodes and unfinished runs are never pruned; `POST /api/maintenance/prune` runs one pass on demand — 409 `maintenance_busy` while a sweep holds the advisory lock) |
| `JANUS_LB_COOLDOWN_MS` | `5000` | Seed estimate for snapshot-seeded cool episodes (mirror of the gateway's default cool window) |
| `JANUS_CONFIG_BACKUP_MAX_BYTES` | `4194304` (4 MiB) | Config-backup body cap: export emits over-cap documents, restore rejects anything above the cap |

### SPA build flags (compile-time)

| Flag | Default | Purpose |
|---|---|---|
| `VITE_FLAG_MODEL_PRICES` | off | "Model prices" card on the Providers page (hidden by default) |

`VITE_FLAG_*` is the feature-flag convention: absent = off, and a change
requires a rebuild (`cd spa && npm run build`).

### Deploy & inventory (`scripts/`)

**Inventory resolution** (every bare-metal script in both repos, same
order): `$JANUS_INVENTORY` (explicit) → `../janus/deploy/inventory.env`
(canonical, gitignored) → `deploy/inventory.env` in this repo (legacy
fallback). No inventory at all = pure docker fleet (deploy keeps the
docker path). Keep exactly one real file — a second copy drifts and the
deploy refuses on leader/runtime disagreement.

Inventory keys (annotated contract: `../janus/deploy/inventory.env.example`):

| Key | Example | Purpose |
|---|---|---|
| `JANUS_NODE_<NAME>` | `'alias=leader-1;role=leader;runtime=bare;py3=3.13;stacks_dir=/opt/janus/stack'` | Per-node record — **single quotes** (the file is sourced); `runtime` selects the docker vs bare path (two independent paths, no migration) |
| `JANUS_NODE_ADDR_<NAME>` | `203.0.113.10` | Reachable address for dist dialing (compose DNS does not resolve from bare processes) |
| `JANUS_MASTER_REF` | `nodea` | Which `JANUS_NODE_<NAME>` key is the leader (migration leader) |
| `JANUS_BARE_PREFIX` / `JANUS_BARE_USER` | `/opt/janus` / `janus` | Bare tree root; systemd `User=` |
| `JANUS_DIST_PORT` | `25672` | Dist port the docker path published (port-free probes + env generation) |
| `JANUS_GW_PORTS` | `8080,8090` | Agent + admin ports the bare gateway binds itself (unit's port-free `ExecStartPre` probe) |
| `JANUS_DASH_PORT` | `8091` | uvicorn port caddy proxies |
| `JANUS_GW_SERVICE` / `JANUS_DASH_SERVICE` | `janus` / `dashboard` | Compose service names (label-filter stop) |
| `JANUS_DB_ENDPOINT` | `127.0.0.1:5432` | Reachable (non-compose-DNS) Postgres endpoint for bare processes |
| `JANUS_DB_ENV_KEYS` | `JANUS_DB_HOST,JANUS_DB_PORT` | Env keys carrying the DB address; the env generator rewrites them shape-aware, last |
| `JANUS_BARE_BUILDER` (+ `_GLIBC` / `_LIBCRYPTO`) | digest pin + `2.36` / `libcrypto.so.3` | Digest-pinned Erlang builder + its glibc floor claims (`scripts/verify_bare.sh` checks each target node meets the floor before shipping) |
| `JANUS_PY_BUILDER_<X_Y>` | digest pin | Digest-pinned python wheelhouse builder per minor (e.g. `JANUS_PY_BUILDER_3_13`); the bare-dashboard build refuses floating tags |
| `JANUS_DASH_BARE` | `false` | `true` = the dashboard runs bare. `install_bare_dashboard.sh` requires it — explicit intent; a still-running compose dashboard is stopped at cutover (teardown, not a coordinated flip) |

Operator overrides for `scripts/deploy_prod.sh` (env of the machine you
deploy from):

| Variable | Default | Purpose |
|---|---|---|
| `JANUS_DEPLOY_HOSTS` | derived from `../janus/deploy/inventory.env` (`JANUS_NODE_*` `alias=` values, declaration order); fallback: the declared leader only | Fleet host list. hosts without a `JANUS_NODE_` record are never fleet hosts and are dropped even when named explicitly |
| `JANUS_DEPLOY_SHIP` | `git` | Ship mode: `git` = nodes pull and build locally; anything else ships tarballs |
| `JANUS_DEPLOY_PLATFORM` | `linux/amd64` | Docker image platform (prod nodes are x86_64; the local gate always builds native arch) |
| `JANUS_DEPLOY_ALLOW_DIRTY` | `0` | `1` ships a dirty tree (stamped unshippable) |
| `JANUS_DEPLOY_ALLOW_FOLLOWER_DRIFT` | `0` | Follower commit-drift escape hatch |
| `JANUS_DEPLOY_ACK_INTERNAL` | unset | sha256 ack of the enumerated internal-egress provider list, printed by the halt itself; per-deploy, never a permanent export |
| `JANUS_DEPLOY_STATS_VIA_SSH` | `0` | `1` scrapes node stats over ssh port-forwards instead of direct stats_hosts |
| `JANUS_DEPLOY_POLL_INTERVAL` / `JANUS_DEPLOY_WAIT_DEADLINE` | `2` / `300` | Wait-loop poll seconds / shared deadline budget |
| `JANUS_DEPLOY_LOCK_TTL` / `JANUS_DEPLOY_LOCK_HOLDER` | `14400` / hostname | Deploy advisory-lock TTL + holder id |
| `JANUS_DEPLOY_PIP_INDEX` / `JANUS_DEPLOY_NPM_REGISTRY` | `https://pypi.org/simple (or a regional mirror)` / `https://registry.npmjs.org (or a regional mirror)` | Package mirrors for CN-hosted builds |
| `JANUS_DEPLOY_PYTHON` | unset | Force the interpreter for the leader-side dashboard build |
| `JANUS_DASH_GIT_REMOTE` | unset | Override the git remote nodes clone the dashboard from |
| `JANUS_ALLOW_UNPINNED_BUILDER` | `0` | Dev/CI escape for floating builder tags — the payload is stamped not shippable |
| `JANUS_ALLOW_BARE_LINUX_WHEELS` | `0` | Allow unpinned Linux wheel sources in the wheelhouse |

Backup tooling (`scripts/backup_leader.sh`, `restore_leader.sh`,
`verify_backup.sh`) reads its own documented set — see
`scripts/janus-backup.env.example`.

### Gateway runtime env

Each node's `janus-gw.env` (`JANUS_ROLE`, `JANUS_MASTER_NODE`,
`JANUS_FLEET_PEERS`, `JANUS_FLEET_PEER_PORTS`, `JANUS_WORKER_REGION`, …)
is the gateway's surface — consolidated in the
the [gateway README](../gateway/README.md) §Environment variables.

## Architecture

```
FastAPI Dashboard (1 instance)              Janus master (+ workers)
+-------------------------------+         +---------------------------+
| SPA (React)                   |         | Master: accept + catalog  |
| FastAPI backend               |--write->| Postgres (shared)         |
|   /api/auth/*                 |         | ETS catalog / LB / auto   |
|   /api/providers/*            |         | Worker pool (OTP dist)    |
|   /api/models/*               |         +---------------------------+
|   /api/keys/*                 |                    ^
|   /api/router/*               |                    | hello / jobs
|   /api/nodes/*                |--poll-->| Master :8090 /stats       |
|   /api/usage/*                |         |          /stats/sched     |
|   /api/sync, /catalog/reload  |         | Workers: egress only      |
|   /api/audit, /api/logs       |         +---------------------------+
+-------------------------------+
         |
    Shared Postgres
  (config + gateway_nodes registry)
```

## Features

- **Dashboard** — high-level health and usage charts
- **Providers & keys** — CRUD, encrypted provider keys (JSEC), modality /
  translate knobs (default off), region / affinity fields for scheduling
- **Agent keys** — create (shown once), enable/disable, revoke, quotas
- **Router** — `janus-auto` tiers / bindings / geo+autotier controls
- **Nodes** — register/remove **gateway** instances; poll `/stats` +
  `/stats/sched`; show Workers table (observation only — do not register
  workers as gateways)
- **Usage** — rollups and event log from `usage_events`
- **Logs** — proxied gateway log tails
- **Audit log** — management-plane actions
- **Model sync** — poll provider `/models`, upsert listings
- **Catalog reload** — generation bump + `NOTIFY` for hot reload on master
- **JWT auth** — no cookies = no CSRF surface; per-IP lockout behind trusted proxies
- **Deploy** — `scripts/deploy_prod.sh` (migration-verified rolling
  rollout + read-only curl smoke). No test suites ship with this repo:
  verification is browser + curl live-checks (see AGENTS.md)

## Gateway observation

Each **gateway** (typically the master) exposes token-authenticated admin
endpoints on `:8090`. The dashboard polls them on an interval and caches
last-good `/stats/sched` per gateway id.

```
GET /stats
Authorization: Bearer {token}

{
  "generation": 42,
  "ready": true,
  "backend": "postgres",
  "uptime_sec": 3600,
  "routes_cooling": 2,
  "requests_total": 12345,
  "requests_failed": 67,
  "models_serving": 12
}
```

```
GET /stats/sched
Authorization: Bearer {token}

# workers[] + fleet + scheduler counters (schema additive)
```

`GET /api/nodes` assembles `{nodes, workers, fleet, scraped_at}` for the SPA
Nodes page. See `docs/SPEC.md` §5.5 for merge rules (`via`, last-good cache,
fleet pick).

### Log persistence

After each node's successful health poll, a single-flight puller task drains
that node's `:8090 /stats/logs` ring (2000 entries = the ring cap, so one
pull captures everything the ring holds) into the dashboard-owned
`gateway_log_events` table. Dedup is a per-node high-water mark with
`ON CONFLICT DO NOTHING` as backstop; a gateway restart (ring-index reset)
is detected via `started_at`/idx regression and resets the mark, so restarts
never double-insert or go silent. Persisted visibility lags emission by at
most one poll interval (`JANUS_NODE_HEALTH_INTERVAL_SEC`, default 10s).

`GET /api/logs` reads this DB view by default; `?source=live` keeps the
original pass-through (merge every enabled node's in-memory ring, with
synthesized `log_fetch_failed` / no-token events for unreachable nodes — in
DB mode node-down visibility is the `node_unreachable` alert, see the
warning in the alerting knobs above). Pull failures log and bump counters
only; they never touch health state or alerting. Rows age out via the
retention sweeper (`JANUS_LOG_RETENTION_DAYS`).

### Request timeline

`GET /api/usage/timeline` reconstructs one client request's per-attempt
timeline from `usage_events` (requires gateway migration 021 for
`trace_id`). Exactly one query parameter:

- `request_ref` — the gateway-minted 32-hex ref (128-bit random, one per
  client request, shared by its retry/failover legs), or
- `trace_id` — the W3C trace-id (32 lowercase hex; semantics in the gateway
  README's Observability section).

The response is the terminal summary (status, model, key prefix, end-to-end
latency — the terminal row's `latency_ms`; non-terminal attempt rows record
0) plus every attempt row: ts, status, `error_code`, `failover_reason`,
protocol/stream, and the echoed `x-request-id`. Auth-gated like every
`/api` route.

Two resolution semantics to know:

- **`?trace_id=` resolves only after the terminal row lands.** It looks up
  the most recent *terminal* usage row with that trace-id, so an in-flight
  request (terminal row not yet written) 404s `timeline_not_found` — retry
  once the request completes.
- **Trace-ids are client-controllable and reusable.** A client that reuses
  one trace-id across requests makes `?trace_id=` resolve whichever matching
  request's terminal row is newest — potentially another request's timeline.
  The endpoint is operator/auth-gated, so this is a confusion risk rather
  than a data-exposure one; use `request_ref` for an exact lookup.

## Verification & deploy

No unit or E2E test suites — verification is live (see AGENTS.md for the
full doctrine):

- **Pages** — browse them with real clicks (built-in agent browser first,
  Tencent BrowserSkill `bsk` as fallback); keep screenshots as evidence.
- **APIs** — `curl` against the running stack (local stack: docker
  `janus-pg`/`janus-gw`/`janus-judge` + `uvicorn app.main:app --port 8091`).

```bash
# Production: ship gateway + dashboard → read-only curl smoke
bash scripts/deploy_prod.sh
bash scripts/deploy_prod.sh --smoke-only  # read-only smoke only
```

Sibling gateway checkout expected at `../janus` (see
this repository). Worker-role
followers are verified via master `/stats/sched` registration, not agent
`:8080`.

## Development

```bash
pip install -e ".[dev]"
bash scripts/lint_all.sh   # static checks for every language (ruff, tsc, bash -n, ...)
ruff check app/

# SPA
cd spa && npm install && npm run dev  # vite on :3000, proxies /api
npm run build  # outputs to spa/dist, served by FastAPI in production
```

## Docker

```bash
docker build -t janus-dashboard .
docker run -d --name janus-dashboard \
  -e JANUS_DB_HOST=postgres.internal \
  -e JANUS_DB_PASSWORD=secret \
  -e JANUS_DASHBOARD_PASSWORD=admin \
  -e JANUS_JWT_SECRET=jwt-secret \
  -e JANUS_SECRETS_KEY=k1:base64key \
  -e JANUS_API_KEY_PEPPER=pepper \
  -e JANUS_STATS_TOKEN=stats-token \
  -p 8091:8091 janus-dashboard
```

## Docs

- `docs/SPEC.md` — management-plane contracts
- the [gateway README](../gateway/README.md) — data-plane status,
  master/worker, metrics
