# Janus

Erlang/OTP LLM gateway (data plane) — OpenAI + Anthropic agent faces, modality
endpoints, in-process LB/failover, `janus-auto` virtual router, ETS hot catalog,
and a **master / worker** OTP dispatch cluster.

The operator UI lives in a **separate** repo:
the [dashboard](../dashboard/) in this repository
(Python FastAPI + SPA). This release exposes a read-only admin plane
(`:8090`) for that dashboard to poll (`/stats`, `/stats/sched`, `/metrics`).

## Status

**Production multi-node cluster (operator-owned).** Past the early single-node
phase: one master front door plus execution workers over inet_tls dist;
catalog/Postgres on the master only; empty or failed pool ⇒ **local fallback**
on the master (not 503-by-default). Scheduler v2.1 health + RTT selection,
per-worker capacity, and wire compression (internal hop + unary upstream
gzip) are enabled in production; geo / probe / unary-fallback and the
upstream **stream** gzip knob remain opt-in.

Out of scope by design (not maturity gaps): public SLO/on-call pack, org RBAC,
provider-dialect adapters. Day-to-day ops: local E2E gate → rolling
`deploy_prod.sh` → read-only prod smoke. Worker join/undrain is ops
(`skills/fleet-node-ops/SKILL.md`); the dashboard Nodes page is **observation
only** (gateways registered; workers appear from master `/stats/sched`).

Working today:

- Chat family: `POST /v1/chat/completions`, `/v1/responses`, `/v1/messages`
  (native passthrough + SSE; cross-protocol translate including streaming
  when `translate.tools` / `translate.responses` knobs are on)
- Modality (default-off knobs): `/v1/images/generations`, `/v1/audio/speech`,
  `/v1/audio/transcriptions`, `/v1/videos` (video stays **master-local**)
- `GET /v1/models`, `/healthz`, `/readyz`
- Provider inventory sync → `provider_models`, public names + `model_routes`
- Secrets encryption, agent API keys, per-key quotas, LB cooldowns / auth
  failure handling
- `janus-auto` (tiers + optional geo / auto-tier reorder)
- Master/worker pool: hello admission, sticky drain/undrain, capacity,
  dispatch + local fallback, `GET /stats/sched` workers view
- Wire compression: worker→master chunks/done bodies compress per-message
  (zlib, capability-gated) and unary upstream calls negotiate gzip — see
  [Wire compression](#wire-compression)
- Admin plane `:8090` — `/stats`, `/stats/sched`, `/stats/logs`, `/metrics`
  (per-node stats token or loopback)

## Cluster (master / worker)

| Role | Boot | Listens | Owns |
|------|------|---------|------|
| **Master** | unset or `JANUS_ROLE=master` | agent `:8080` + admin `:8090` | Postgres/SQLite catalog, LB pick, client accept, usage persist |
| **Worker** | `JANUS_ROLE=worker` + `JANUS_MASTER_NODE` | no public `:8080` | Upstream I/O; streams chunks back to master as messages |

Workers never poll the catalog. Peers joined only via the transitional
signal-fleet bus (`JANUS_FLEET_ENABLED`) do **not** enter `janus_worker_pool`
without a worker hello. Ops runbook: `skills/fleet-node-ops/SKILL.md`.
Design provenance / section→module map: `docs/superpowers/specs/README.md`.

## Quick start

**Compile/fmt via Docker on Windows** (host OTP may crash). The prebuilt
`tools`-stage image never touches `dl-cdn.alpinelinux.org` (Aliyun apk mirror
inside), so it works on China networks:

```bash
docker build --target test -t janus-build:test .
docker run --rm -e HEX_MIRROR -e HEX_CDN \
  -v "$PWD/apps:/app/apps" -v "$PWD/config:/app/config" \
  -v "$PWD/rebar.config:/app/rebar.config" -v "$PWD/rebar.lock:/app/rebar.lock" \
  -v janus-ebin-otp27:/app/_build -w /app janus-build:test \
  sh -c 'rebar3 fmt --check && rebar3 compile'
```

Do not bind-mount the repo root over `/app` (the image owns
`/usr/local/bin/rebar3` and the warm hex cache); recreate the named
volume (`docker volume rm janus-ebin-otp27`) when `rebar.lock`,
`rebar.config`, or the OTP version changes. Linux/macOS with OTP 27 +
gcc can use `./rebar3` directly.

### Local run (SQLite)

```bash
docker compose up janus janus-judge
# GET http://127.0.0.1:8080/healthz
```

`janus-judge` shares the gateway network namespace (`network_mode: service:janus`);
loopback `:8191` is not published on the host. Set the same `JANUS_JUDGE_TOKEN`
on gateway and sidecar (ensure/decide fail closed when empty). Local compose
defaults `JANUS_JUDGE_FIXTURE=1` (golden weights); set `JANUS_JUDGE_FIXTURE=0`
for real artifact download. Weight cache: volume `janus_judge_cache` at
`JANUS_JUDGE_CACHE` (`/var/lib/janus-judge`).

Required for real proxying (encrypt provider keys / hash agent keys):

```bash
JANUS_SECRETS_KEY=k1:<base64-32-bytes>
JANUS_API_KEY_PEPPER=<random>
```

Optional: `JANUS_STATS_TOKEN` so the standalone dashboard can poll `:8090`
remotely (without it, `/stats` is loopback-only).

### Postgres (shared catalog)

```bash
docker compose --profile postgres up
```

| Mode | When | Env |
|------|------|-----|
| **Postgres** | `JANUS_DB_URL` or `JANUS_DB_HOST` set | URL or `HOST` / `USER` / `PASSWORD` / `NAME` / `PORT` |
| **SQLite** | otherwise | `JANUS_SQLITE_PATH` (default `data/janus.db`) |

Hot path never queries SQL — ETS holds routes. Postgres is the shared
catalog on the **master**; workers do not open it for routing. Prefer one
writer for seed and model sync (`JANUS_AUTO_SEED`, `JANUS_MODEL_SYNC_*`);
extra masters (if any) can set `JANUS_MODEL_SYNC_INTERVAL_SEC=0` and omit seed.

## Environment variables

Consolidated reference for every OS env var the gateway reads at boot
(`os:getenv` across `apps/*/src`). Optional unless marked required.
"Truthy" = set to a non-empty true-ish value (`1` / `true` / `on`).
Runtime location per deploy path: docker compose env, or
`$JANUS_BARE_PREFIX/env/janus-gw.env` on bare nodes (systemd
`EnvironmentFile=`). Wire-compression app-env knobs (`JANUS_WIRE_ENC*`,
`JANUS_UPSTREAM_ENC*`) and local-judge knobs (`JANUS_JUDGE_FIXTURE`,
`JANUS_JUDGE_CACHE`) are application env — see Quick start and the Wire
compression section.

### Role & fleet (dist mesh)

| Variable | Default | Purpose |
|---|---|---|
| `JANUS_ROLE` | unset = master | `master` (accept + catalog + LB) or `worker` (upstream I/O only) |
| `JANUS_MASTER_NODE` | — **required on workers** | Master's long name, e.g. `janus@gw.example.com` |
| `JANUS_FLEET_ENABLED` | off | Truthy = enable the signal-fleet bus; workers do not enter `janus_worker_pool` without it |
| `JANUS_FLEET_PEERS` | unset | Comma-separated full long names — the static-EPMD peer allowlist (`janus_fleet_epmd`; whitespace-trimmed) |
| `JANUS_FLEET_DIST_PORT` | `25672` | This node's own dist **listen** port (e.g. tunnelled workers listen on `25671` and keep `25672` for the tunnel) |
| `JANUS_FLEET_PEER_PORTS` | unset | Per-peer **dial** port overrides, comma-separated `name=port`; `name` = full long name or alive prefix — e.g. `janus@gw.example.com=25672,janus=25672` dials the master via the local SSH tunnel's port |
| `JANUS_FLEET_TLS_DIR` | built-in default | Directory holding the fleet's inet_tls certs (`node.pem`, `node-key.pem`, CA); node-key must be `root:<janus-user>` 640 |
| `JANUS_WORKER_REGION` | unset | Region tag the worker's hello carries (`cn-beijing`, `eu-amsterdam`, `eu-lauterbourg`, …); shown on the dashboard Workers table — geo scheduling **narrows** by region, never excludes |
| `JANUS_WORKER_CAPACITY` | gateway default | Positive int = per-worker job capacity override |
| `JANUS_DRAIN_IDLE_MS` | `30000` | Idle time before a drained worker exits |

### Database

| Variable | Default | Purpose |
|---|---|---|
| `JANUS_DB_URL` | unset | Postgres DSN (takes precedence over HOST) |
| `JANUS_DB_HOST` (+ `USER`/`PASSWORD`/`NAME`/`PORT`) | unset → SQLite | Postgres connection (master) |
| `JANUS_DB_SSL_CA` | unset | CA bundle for TLS Postgres |
| `JANUS_SQLITE_PATH` | `data/janus.db` | SQLite fallback when no Postgres is configured |

### Secrets & admin auth

| Variable | Default | Purpose |
|---|---|---|
| `JANUS_SECRETS_KEY` | — **required** | JSEC keyring `k1:<base64-32-bytes>`; must equal the dashboard's (provider key encryption). **Python 3.14 strict-decodes base64 — keep the padding `=` intact in env files** |
| `JANUS_API_KEY_PEPPER` | — **required** | HMAC pepper for agent keys; must equal the dashboard's |
| `JANUS_STATS_TOKEN` | unset | Bearer token for the admin plane `:8090` (`/stats`, `/stats/sched`, `/stats/logs`, `/metrics`); rotating it means restarting the node and updating the dashboard's node record |

### Scheduling & geo (master)

| Variable | Default | Purpose |
|---|---|---|
| `JANUS_SCHED_GEO` | off | Truthy = force geo-aware scheduling on (also engages implicitly when `JANUS_SCHED_GEO_TEST_HOSTS` is set) |
| `JANUS_SCHED_REGIONS` | unset | Region set used by geo-aware tier selection |
| `JANUS_SCHED_GEO_TEST_HOSTS` | unset | host→region test overrides for geo resolution |
| `JANUS_SCHED_PROBE_FORCE` | off | Truthy = force a geo probe |
| `JANUS_SCHED_WORKER_GEO` | off | Truthy = enable worker-side geo discovery (see worker-geo vars) |
| `JANUS_SCHED_UNARY_FALLBACK` | off | Truthy = unary-hop fallback when streaming dispatch is unavailable |
| `JANUS_MMDB_PATH` | built-in default | GeoLite2-City `.mmdb` path (dashboard mirror: `/var/lib/janus/geo/GeoLite2-City.mmdb`) |
| `JANUS_LB_COOLDOWN_MS` | `5000` | Default route cool-down window after a failure |
| `JANUS_LB_AUTH_COOLDOWN_MS` | module default | Cool-down after auth failures on a route |

### Worker geo egress (workers)

| Variable | Default | Purpose |
|---|---|---|
| `JANUS_WORKER_GEO_SOURCES` | default chain | Ordered comma list of discovery layers; known tokens: `gw_echo`, `metadata`, `env`, `third_echo` |
| `JANUS_WORKER_GEO_METADATA_URL` | unset | Metadata-endpoint override |
| `JANUS_WORKER_GEO_IP_URL` | unset | IP-lookup endpoint override |
| `JANUS_WORKER_GEO_ECHO_URL` | unset | gw-echo endpoint override |
| `JANUS_WORKER_GEO_ECHO_CA_PATH` | unset | Custom CA for the echo endpoint |
| `JANUS_WORKER_GEO_IP_REFRESH_SEC` | module default | Refresh cadence for cached geo |

### Upstream & protocol

| Variable | Default | Purpose |
|---|---|---|
| `JANUS_UPSTREAM_TLS_VERIFY` | `peer` | Provider-call TLS verification; `none` disables (never in prod) |
| `JANUS_UPSTREAM_UA` | built-in UA | User-Agent for provider calls |
| `JANUS_ANTHROPIC_VERSION` | built-in default | `anthropic-version` header |
| `JANUS_ANTHROPIC_DEFAULT_MAX_TOKENS` | unset | Default `max_tokens` for the anthropic wire |
| `JANUS_ECHO_DIRECT` / `JANUS_ECHO_PROXY_HEADERS` | unset | Echo-endpoint behavior (direct mode / proxied header allowlist) |

### Seeding, sync & config

| Variable | Default | Purpose |
|---|---|---|
| `JANUS_AUTO_SEED` | off | Truthy = seed the catalog from the seed file at boot (leader only) |
| `JANUS_SEED_PATH` | `data/seed.providers.json` | Seed file location |
| `JANUS_MODEL_SYNC_ON_START` | off | Truthy = run model sync at boot |
| `JANUS_CONFIG_POLL_MS` | module default | Catalog poll fallback cadence (NOTIFY is the hot path) |

### Key snapshots

| Variable | Default | Purpose |
|---|---|---|
| `JANUS_SNAPSHOT_DIR` | module default | Snapshot directory |
| `JANUS_SNAPSHOT_MAX_AGE_SEC` | unset | Max age before a snapshot is considered stale |
| `JANUS_SNAPSHOT_RETAIN` | module default | How many snapshots to retain |

### Logging & misc

| Variable | Default | Purpose |
|---|---|---|
| `JANUS_LOG_LEVEL` | kernel logger level | Log level (atom, e.g. `info`) |
| `JANUS_LOG_DIR` | unset (stdout) | File-logging directory |
| `JANUS_LOG_BYTES` / `JANUS_LOG_FILES` | module defaults | Log rotation size / count |
| `JANUS_JUDGE_TOKEN` | unset | Shared secret master ↔ local judge (`:8191`, loopback only) — required when `judge_backend=local` |
| `JANUS_GIT_SHA` | release stamp | Informational; stamped by `scripts/build_bare_release.sh` |
| `JANUS_JVID_DEV_SECRET` | unset | Dev-only jvid secret — never set in prod |
| `JANUS_WIRE_ENC_CORRUPT_AFTER` | unset | Test seam (fault injection) — never set in prod |

## Planes

| Port | Plane | Purpose |
|------|-------|---------|
| **8080** | Data | Agent API (`/v1/*`), `/healthz`, `/readyz` (master only) |
| **8090** | Admin | Read-only `/stats`, `/stats/sched`, `/stats/logs`, `/metrics`, `/healthz` for the [dashboard](../dashboard/) |

Publish both on loopback and put Caddy (or similar) in front for TLS.
Dist (default `25672`) is peer `/32` only — never `0.0.0.0/0`.

## Agent endpoints

- `POST /v1/chat/completions` — OpenAI Chat
- `POST /v1/responses` — OpenAI Responses
- `POST /v1/messages` — Anthropic Messages (`Authorization: Bearer` preferred; `x-api-key` accepted, Bearer wins)
- `POST /v1/images/generations`, `/v1/audio/speech`, `/v1/audio/transcriptions`, `/v1/videos` — modality (knob-gated)
- `GET /v1/models`

Restricted agent keys (`api_key_models` name grants) only see those names
on `GET /v1/models` (bound Router models and unbound provider listings are
both grantable). `janus-auto` is unrestricted-only: scoped keys cannot
grant or call it.

Provider `protocol`: `openai_chat` | `openai_responses` | `anthropic_messages`
(plus modality-native listings). Same-protocol routes passthrough (including
SSE). Cross-protocol translate is gated by settings knobs (default off).
Streaming toward a responses-protocol **provider** remains
`stream_requires_native_protocol` (Phase 3 not built). Standard shapes only — no
provider-dialect adapters (one grandfathered exception: minimax T2I).

## Verification

No unit or E2E test suites (deleted 2026-10-18; see AGENTS.md
"Verification"):

1. **Static** — `rebar3 compile` + `rebar3 fmt --check` (CI runs both).
2. **Live** — run the release against real Postgres and drive it:
   pages in a browser, APIs with curl. The dashboard repo's AGENTS.md
   carries the shared doctrine.
3. **Publish + read-only smoke** — `bash ../janus-dashboard/scripts/deploy_prod.sh`
   ships gateway + dashboard with a migration-verified rolling rollout,
   then a read-only curl smoke. Production is never mutated by
   verification.

## Usage statistics

Every proxied request (streaming included) is recorded into `usage_events`:
token counts, upstream status, latency, modality/units/outcome, and
key/model/provider/provider-key ids (plus observability fields such as
`trace_id` / `failover_reason` where migrated). Rows are kept 31 days and
swept daily; the dashboard Usage page reads the rollups. Streams get the
terminal usage chunk via polite `stream_options.include_usage` injection —
disable with app env `janus_core.usage_inject_include_usage = false` if an
upstream rejects the field. Injection only fills an ABSENT knob: on native
chat routes a client-supplied `stream_options` passes through verbatim;
cross-protocol requests never carry it over — `include_usage` is injected
toward chat-protocol upstreams so translated streams still record tokens.

## Wire compression

Cross-DC hops stop paying full freight (spec
`docs/superpowers/specs/2026-10-12-wire-compression.md`, RATIFIED r5).
Two independent, additive layers — both **default off**, env-only:

| Layer | What compresses | Knob (both roles) |
|-------|-----------------|-------------------|
| **Internal hop** (PR1) | worker→master chunk payloads + unary done bodies — one independent zlib stream per message (`enc => zlib` tag; receiver decodes tag-driven) | `JANUS_WIRE_ENC=1` |
| **Upstream gzip** (PR2) | unary provider calls send `Accept-Encoding: gzip`; the response decodes in a per-stream capped inflate before any parser | `JANUS_UPSTREAM_ENC=1` |

Two-gate spelling: the master advertises decode capability in the hello
ack only when its own `JANUS_WIRE_ENC=1`; a worker compresses only when
its env is on **and** the current session's ack advertised. Any mix of
old/new nodes degrades to identity — never a broken decode. Measured on
real traffic (W.0, `docs/audit/wire-enc/W0-artifact.json`): stream
chunks 0.75–0.93 ratio, unary done bodies 0.22–0.78, ~6 µs/message CPU.

Tuning / safety:

- `JANUS_WIRE_ENC_LEVEL` (1–9, default 1; `0` ⇒ identity),
  `JANUS_WIRE_ENC_MIN_BYTES` (default 256), `JANUS_WIRE_ENC_MAX_INFLATE`
  (default 64 MiB, shared by both inflate sites — the decompression-bomb cap)
- `JANUS_UPSTREAM_ENC_STREAM=1` extends the upstream ask to **streaming**
  requests — default off: provider-side proxies may buffer gzip'd SSE
  flushes and destroy TTFB (enable only after a live TTFB probe)
- Corrupt/oversized payloads abort the job with client bytes identical
  to `worker_lost` (no new client handling); distinguishable via the
  `janus_wire_enc_inflate_fail` log, `usage_events.outcome =
  'wire_enc_inflate_fail'`, and the counters below. Unknown/compound
  upstream `Content-Encoding` is a provider contract violation riding
  the existing failover cascade — never parsed.
- Rollback: knob off + restart (stateless identity).

Runbook: `skills/fleet-node-ops/SKILL.md` (enable order, bake
thresholds, metrics to watch).

## Observability (Prometheus)

The admin plane exposes Prometheus text exposition at `GET :8090/metrics`.

```bash
curl -H "Authorization: Bearer $JANUS_STATS_TOKEN" http://127.0.0.1:8090/metrics
# on the node itself, with no token configured, loopback needs no header:
curl http://127.0.0.1:8090/metrics
```

**Auth** — same as `/stats`: `Authorization: Bearer $JANUS_STATS_TOKEN`.
With no token configured the fallback is **loopback-only**, decided from the
socket peer (`cowboy_req:peer/1`) — `X-Forwarded-For` is never consulted.
The admin plane must never be exposed through Caddy (or any proxy) without
the token. Example scrape config: [`docker/prometheus.yml`](docker/prometheus.yml).

**Series** (all names prefixed `janus_`; rendered by `janus_metrics_render`):

| Series | Type | Labels | Notes |
|--------|------|--------|-------|
| `requests_total` | counter | `endpoint`, `protocol`, `status_class` | Terminal client outcomes; early rejects counted, never timed |
| `upstream_requests_total` | counter | `provider`, `status_class` | Terminal outcomes by provider once a route is picked; failover inner attempts excluded |
| `request_duration_seconds` | histogram | `protocol`, `stream` (`0`/`1`) | Buckets 0.05–600s; proxied outcomes only |
| `lb_stats_total` | counter | `stat` | Cumulative `janus_lb:stats/0` counters |
| `usage_writer_dropped_total` | counter | — | Omitted when the writer is down (never a fabricated 0) |
| `usage_writer_buffered_rows` | gauge | — | Writer backlog |
| `catalog_generation` | gauge | — | Serving catalog generation |
| `catalog_ready` | gauge | — | 1 warm / 0 cold |
| `models_serving` | gauge | — | Models in the serving catalog |
| `lb_routes_cooling` | gauge | — | Node-scoped: LB routes in cooldown on this node |
| `uptime_seconds` | gauge | — | VM wall-clock uptime |
| `build_info` | untyped | `version` | Always 1 |
| `workers_available` / `sched_*` | gauge/counter | (see `/metrics`) | Worker pool + scheduler v2.1 surfaces; pair with `GET /stats/sched` |
| `wire_enc_chunks_total` / `wire_enc_bytes_total` | counter | `dir` (`out`/`in`), `enc` (`identity`/`zlib`; bytes also `plain`) | Wire compression partition (each message exactly one wire bucket; `plain` = pre-compression size of compressed messages) |
| `wire_enc_deflate_time_us_total` / `wire_enc_inflate_time_us_total` | counter | — | Compression CPU (worker deflate / master inflate) |
| `wire_enc_inflate_fail_total` | counter | — | Internal-hop inflate failures — the rollout gate requires 0 |
| `upstream_enc_unsolicited_total` | counter | `dir`, `enc` | Stream responses arriving gzip'd unrequested — provider/proxy flush-buffering TTFB risk signal |

Example PromQL:

```promql
sum by (endpoint, status_class) (rate(janus_requests_total[5m]))
histogram_quantile(0.95, sum by (le, protocol, stream) (rate(janus_request_duration_seconds_bucket[5m])))
sum by (provider) (rate(janus_upstream_requests_total{status_class=~"4xx|5xx"}[5m]))
max(janus_catalog_generation) != min(janus_catalog_generation)   # catalog drift between masters
```

**Label cardinality** is bounded by construction: label values come only
from closed enums and operator-defined provider names. Never add
request-id, key-id, or model labels.

**Counter semantics** — counters are node-local and reset to zero on
restart; always wrap in `rate()` and `sum` across `instance` for fleet
totals. An `uptime_seconds` drop to ~0 marks a restart.

**Duration semantics** — end-to-end request duration; for streams that
includes client drain. Early rejects bump `requests_total` but never
contribute a latency sample. Handler-entry 413 is excluded from metrics.

**Request ids** — inbound `x-request-id` is untrusted: echoed and stored on
usage rows, never assumed unique. Well-formed means 1–128 bytes of
`[A-Za-z0-9-_]`; anything else is replaced with `req_<16 lowercase hex>`.
Echo scope is the agent endpoints (chat family + models + modality); router
404s and the admin plane never echo.

**Trace context (W3C `traceparent`)** — every agent request resolves a trace
context once at handler entry (`janus_trace`):

- A well-formed inbound `traceparent` (exact version-`00` shape, lowercase
  hex, non-zero ids) is honored — its trace-id continues; anything else, and
  no header, mints a fresh trace-id. `tracestate` is never parsed, honored,
  or forwarded (outbound header lists are built from scratch — client
  headers never ride upstream).
- The 32-hex trace-id is echoed as `x-trace-id` on every response that
  reaches a handler: 2xx, streams, and local error replies (401/413/429,
  pre-flight 4xx) alike. Requests rejected by cowboy's own HTTP parser
  (malformed request-line/headers) return before handler entry and echo
  **neither** `x-trace-id` **nor** `x-request-id`.
- Each upstream attempt injects a fresh `traceparent`: the stable trace-id,
  a parent-id minted **per attempt** (retry/failover legs never share a span
  id), flags always `01` (the inbound sampling decision is not carried
  upstream). Master→worker dispatch carries only the trace-id; the parent-id
  is minted on the executing node. Only agent-serving paths inject: the
  model-sync inventory fetch (`janus_model_sync`'s `GET {base}/models`) and
  the worker geo-discovery echo/metadata calls carry no `traceparent`, and
  pool-issued probes mint a fresh, request-uncorrelated trace-id on the
  executing node.
- `GET /v1/models` is excluded (no upstream call, no usage row).
- The trace-id lands on `usage_events.trace_id` (migration 021) and powers
  the dashboard's request-timeline API (see the dashboard README).

**Log tail** — `GET :8090/stats/logs?limit=N` serves the node's in-memory
log ring (`janus_log_tail`: 2000 entries, level ≥ info; the ring index
resets at boot). The dashboard drains the full ring after each successful
health poll and persists it with at most one poll-interval (~10s) lag —
retention and query semantics live in the dashboard README.

**Grafana** — import [`docker/grafana-dashboard.json`](docker/grafana-dashboard.json)
(uid `janus-overview`) or provision it; pick the Prometheus datasource on
import (`DS_PROMETHEUS`).

**Alert rules** — an example Prometheus rule pack ships at
[`docker/prometheus-alerts.yml`](docker/prometheus-alerts.yml) (5xx burn
rate, p95 latency, persistent LB cooling, usage-writer drops, cold catalog,
catalog-generation drift, empty worker pool). Reference it from
`rule_files` in your prometheus.yml; its metric names are verified against
the `janus_metrics_render` registry as of that file's commit.

**Ops** — rotating `JANUS_STATS_TOKEN` means restarting the node and updating
the scrape / dashboard per-node token; do it rolling.

## Apps

| App | Role |
|-----|------|
| `janus` | Root release (`JANUS_ROLE=master\|worker`) |
| `janus_core` | DB, migrations, ETS catalog, LB, usage, worker pool/dispatch/wire, seed, model sync |
| `janus_http` | Cowboy data + admin planes, protocol translate, `janus-auto`, modality plugins, worker client |
| `janus_providers` | Upstream adapters (OpenAI / Anthropic-shaped HTTP over gun) |

## License

MIT
