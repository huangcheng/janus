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
- Admin plane `:8090` — `GET /stats`, `GET /stats/logs` (token or loopback)

## Quick start

**Compile via Docker on Windows** (host OTP may crash). Linux/macOS with OTP 27 + gcc can use `./rebar3` directly.

```bash
docker pull erlang:27-alpine
docker run --rm -v F:/Janus:/app -w /app erlang:27-alpine \
  sh -c 'apk add --no-cache git build-base curl && chmod +x rebar3 && ./rebar3 get-deps && ./rebar3 compile'
```

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
| **8090** | Admin | Read-only `/stats`, `/stats/logs`, `/healthz` for [`janus-dashboard`](../janus-dashboard) |

Publish both on loopback and put Caddy (or similar) in front for TLS.

## Agent endpoints

- `POST /v1/chat/completions` — OpenAI Chat
- `POST /v1/responses` — OpenAI Responses
- `POST /v1/messages` — Anthropic Messages (`Authorization: Bearer` preferred; `x-api-key` accepted, Bearer wins)
- `GET /v1/models`

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

## Apps

| App | Role |
|-----|------|
| `janus` | Root release |
| `janus_core` | DB select, migrations, ETS config, LB, seed, model sync |
| `janus_http` | Cowboy data plane + admin stats plane, protocol translate, `janus-auto` |
| `janus_providers` | Upstream adapters (OpenAI / Anthropic-shaped HTTP) |

## License

MIT
