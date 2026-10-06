# Janus

Erlang/OTP LLM gateway — OpenAI + Anthropic agent faces, in-process LB/failover, `janus-auto` virtual router, ETS hot catalog.

The operator UI lives in a **separate** repo: [`janus-dashboard`](../janus-dashboard) (Python FastAPI + SPA). This release exposes a read-only admin plane for that dashboard to poll.

## Status

**Usable early production** for a small, operator-owned deployment (one or few nodes, known providers, eyes on it). Not yet industrial platform infrastructure (limited hot-path tests, multi-node ops still thin, no SLO/on-call story).

Working today:

- `POST /v1/chat/completions`, `/v1/responses`, `/v1/messages` (native passthrough + SSE; cross-protocol translate for non-stream text/tools)
- `GET /v1/models`, `/healthz`, `/readyz`
- Provider inventory sync → `provider_models`, public names + `model_routes` bindings
- Secrets encryption, agent API keys, LB cooldowns / auth failure handling
- `janus-auto` (when tiers are configured)
- Admin plane `:8090` — `GET /stats`, `GET /stats/logs`, `GET /metrics` (token or loopback)

## Quick start

**Compile/eunit via Docker on Windows** (host OTP may crash). The prebuilt `test` image never touches `dl-cdn.alpinelinux.org` (Aliyun apk mirror inside), so it works on China networks:

```bash
docker build --target test -t janus-build:test .
docker run --rm -e HEX_MIRROR -e HEX_CDN -v F:/Janus/apps:/app/apps -v F:/Janus/config:/app/config -v F:/Janus/rebar.config:/app/rebar.config -v F:/Janus/rebar.lock:/app/rebar.lock -v janus-ebin-otp27:/app/_build -w /app janus-build:test sh -c 'rebar3 fmt --check && rebar3 eunit'
```

Do not bind-mount the repo root over `/app` (the image owns
`/usr/local/bin/rebar3` and the warm hex cache); recreate the named
volume (`docker volume rm janus-ebin-otp27`) when `rebar.lock`,
`rebar.config`, or the OTP version changes. Linux/macOS with OTP 27 +
gcc can use `./rebar3` directly.

### Local run (SQLite)

```bash
docker compose up janus
# GET http://127.0.0.1:8080/healthz
```

Required for real proxying (encrypt provider keys / hash agent keys):

```bash
JANUS_SECRETS_KEY=k1:<base64-32-bytes>
JANUS_API_KEY_PEPPER=<random>
```

Optional: `JANUS_STATS_TOKEN` so the standalone dashboard can poll `:8090` remotely (without it, `/stats` is loopback-only).

### Postgres (multi-node catalog)

```bash
docker compose --profile postgres up
```

| Mode | When | Env |
|------|------|-----|
| **Postgres** | `JANUS_DB_URL` or `JANUS_DB_HOST` set | URL or `HOST` / `USER` / `PASSWORD` / `NAME` / `PORT` |
| **SQLite** | otherwise | `JANUS_SQLITE_PATH` (default `data/janus.db`) |

Hot path never queries SQL — ETS holds routes. Postgres is for a shared catalog across gateway nodes; SQLite is single-node / laptop. Prefer one writer for seed and model sync (`JANUS_AUTO_SEED`, `JANUS_MODEL_SYNC_*`); other nodes can set `JANUS_MODEL_SYNC_INTERVAL_SEC=0` and omit seed.

## Planes

| Port | Plane | Purpose |
|------|-------|---------|
| **8080** | Data | Agent API (`/v1/*`), `/healthz`, `/readyz` |
| **8090** | Admin | Read-only `/stats`, `/stats/logs`, `/metrics`, `/healthz` for [`janus-dashboard`](../janus-dashboard) |

Publish both on loopback and put Caddy (or similar) in front for TLS.

## Agent endpoints

- `POST /v1/chat/completions` — OpenAI Chat
- `POST /v1/responses` — OpenAI Responses
- `POST /v1/messages` — Anthropic Messages (`Authorization: Bearer` preferred; `x-api-key` accepted, Bearer wins)
- `GET /v1/models`

Restricted agent keys (`api_key_models` grants) only see those public names on `GET /v1/models`. `janus-auto` is a virtual model: unrestricted keys see it when any tier has members; scoped keys only see it if that name is itself a granted public model.

Provider `protocol`: `openai_chat` | `openai_responses` | `anthropic_messages`. Same-protocol routes passthrough (including SSE). Cross-protocol **translate** is non-stream only (text + basic tools); `stream: true` on a translate path returns `400 stream_requires_native_protocol`. Vision/multimodal translate is rejected in v1.

## Testing

Three layers, in the order they should fail:

1. **eunit** — `./rebar3 eunit`. Pure logic with PRODUCTION-shaped
   fixtures: JSON-decoded binary keys, Postgres SMALLINT 0/1 as the
   drivers return them, epgsql row tuples. A test written from the
   implementation's own idioms (atoms, booleans) tests the wrong code.
2. **Local E2E** — `bash ../janus-dashboard/scripts/e2e_local.sh` (from
   the dashboard repo) boots this release in Docker against a real
   Postgres and runs the full TEST-FLOWS suite with real upstream
   calls; it is the acceptance gate for every change. All testing is
   local — production data is never touched by tests.
3. **Publish + read-only smoke** — `bash ../janus-dashboard/scripts/
   deploy_prod.sh` reruns the local gate, ships the image to the three
   production nodes, then verifies production with a READ-ONLY smoke
   (health, nodes, generation sync, model surface, one real chat). No
   test ever mutates production state.

## Usage statistics

Every proxied request (streaming included) is recorded into `usage_events`: token counts, upstream status, latency, and the key/model/provider/provider-key ids. Rows are kept 31 days and swept daily; the dashboard's Usage page reads the rollups. Streams get the terminal usage chunk via polite `stream_options.include_usage` injection — disable with app env `janus_core.usage_inject_include_usage = false` if an upstream rejects the field.

## Observability (Prometheus)

The admin plane exposes Prometheus text exposition at `GET :8090/metrics`.

```bash
curl -H "Authorization: Bearer $JANUS_STATS_TOKEN" http://127.0.0.1:8090/metrics
# on the node itself, with no token configured, loopback needs no header:
curl http://127.0.0.1:8090/metrics
```

**Auth** — same as `/stats`: `Authorization: Bearer $JANUS_STATS_TOKEN`. With no token configured the fallback is **loopback-only**, decided from the socket peer (`cowboy_req:peer/1`) — `X-Forwarded-For` is never consulted, so a spoofed header cannot unlock it. The admin plane must never be exposed through Caddy (or any proxy) without the token: external Prometheus reaches nodes over the internal network, or through a Caddy host that requires the bearer token. Example scrape config (one job per node — stats tokens are per-node credentials): [`docker/prometheus.yml`](docker/prometheus.yml).

**Series** (all names prefixed `janus_`; rendered by `janus_metrics_render`):

| Series | Type | Labels | Notes |
|--------|------|--------|-------|
| `requests_total` | counter | `endpoint`, `protocol`, `status_class` | Terminal client outcomes; early rejects counted, never timed |
| `upstream_requests_total` | counter | `provider`, `status_class` | Terminal outcomes by provider once a route is picked (includes pre-upstream translate rejections); failover inner attempts excluded |
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

Example PromQL:

```promql
sum by (endpoint, status_class) (rate(janus_requests_total[5m]))
histogram_quantile(0.95, sum by (le, protocol, stream) (rate(janus_request_duration_seconds_bucket[5m])))
sum by (provider) (rate(janus_upstream_requests_total{status_class=~"4xx|5xx"}[5m]))
max(janus_catalog_generation) != min(janus_catalog_generation)   # catalog drift between nodes
```

**Label cardinality** is bounded by construction: label values come only from closed enums (`endpoint`, `protocol`, `status_class`, `stream`) and operator-defined provider names. Never add request-id, key-id, or model labels.

**Counter semantics** — counters are node-local (one ETS table per node) and reset to zero on restart; `rate()`/`increase()` handle resets, so always wrap counters in `rate()` and `sum` across `instance` for fleet totals. An `uptime_seconds` drop to ~0 marks a restart. `lb_stats_total` counters are cumulative and summable/rateable across nodes; only per-node gauges such as `lb_routes_cooling` are node-scoped. Series for a deleted provider stay in the exposition (orphaned, no longer increasing) until the node restarts. Float values may render in scientific notation (`1.0e7` is legal Prometheus text).

**Duration semantics** — the histogram measures end-to-end request duration; for streams that includes client drain (time until the client finishes reading). It covers proxied terminal outcomes only: early rejects (auth failures, `no_route`, `catalog_not_ready`, translate rejections) bump `requests_total` but never contribute a latency sample. The one exclusion from metrics entirely is the handler-entry 413 (oversize body), which replies before any counting.

**Request ids** — inbound `x-request-id` is untrusted client data: it is echoed back and stored on usage rows, but never assume uniqueness or authenticity. Well-formed means 1–128 bytes of `[A-Za-z0-9-_]`; anything else is ignored and replaced with a generated `req_<16 lowercase hex>`. Echo scope is the four agent endpoints (`/v1/chat/completions`, `/v1/responses`, `/v1/messages`, `/v1/models`); router 404s and the admin plane never echo.

**Grafana** — import [`docker/grafana-dashboard.json`](docker/grafana-dashboard.json) by hand (uid `janus-overview`) or provision it per your Grafana setup; pick the Prometheus datasource on import (`DS_PROMETHEUS`).

**Ops** — rotating `JANUS_STATS_TOKEN` means restarting the node and updating the scrape job's token file; do it rolling, one node at a time (each node's token file is independent).

## Apps

| App | Role |
|-----|------|
| `janus` | Root release |
| `janus_core` | DB select, migrations, ETS config, LB, seed, model sync |
| `janus_http` | Cowboy data plane + admin stats plane, protocol translate, `janus-auto` |
| `janus_providers` | Upstream adapters (OpenAI / Anthropic-shaped HTTP) |

## License

MIT
