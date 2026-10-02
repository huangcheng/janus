# Janus

Erlang/OTP LLM gateway — OpenAI + Anthropic faces, native cluster LB, admin UI.

## Status

Scaffold / early WIP. `/healthz` and `/v1/models` stub; chat/responses/messages return `501` until proxy work lands.

## Quick start

**Compile on this machine via Docker** — host Windows OTP/`erl` may crash (`ACCESS_VIOLATION`). No Erlang cluster is required for local compile or a single-node run.

```bash
docker pull erlang:27-alpine
docker run --rm -v F:/Janus:/app -w /app erlang:27-alpine \
  sh -c 'apk add --no-cache git build-base curl && chmod +x rebar3 && ./rebar3 get-deps && ./rebar3 compile'
```

Or use the image build:

```bash
docker compose build janus
```

### Local run (SQLite default)

If Postgres env vars are **not** set, Janus uses local SQLite (`./data/janus.db`). Prefer Docker for the BEAM on Windows:

```bash
docker compose up janus
# GET http://127.0.0.1:8080/healthz
```

On Linux/macOS with a working OTP install:

```bash
./rebar3 compile
./rebar3 shell
```

### Docker with optional Postgres

```bash
# SQLite (no DB sidecar)
docker compose up janus

# Shared Postgres for multi-node
docker compose --profile postgres up
```

## Database selection

| Mode | When | Env |
|------|------|-----|
| **Postgres** | `JANUS_DB_URL` or `JANUS_DB_HOST` set | `JANUS_DB_URL` or `JANUS_DB_HOST` / `USER` / `PASSWORD` / `NAME` / `PORT` |
| **SQLite** | otherwise | `JANUS_SQLITE_PATH` (default `data/janus.db`) |

Hot path never queries SQL — ETS holds routes. Postgres is for shared admin catalog across nodes; SQLite is for single-node / laptop.

## Agent endpoints (planned)

- `POST /v1/chat/completions` (OpenAI)
- `POST /v1/responses` (OpenAI)
- `POST /v1/messages` (Anthropic)
- `GET /v1/models`

## Apps

| App | Role |
|-----|------|
| `janus` | Root release application |
| `janus_core` | DB backend select, ETS config, LB |
| `janus_http` | Cowboy + agent HTTP API |
| `janus_providers` | Upstream adapters |
| `janus_admin` | Admin API + UI (later) |

## License

MIT