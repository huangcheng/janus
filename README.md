# Janus

An Erlang/OTP LLM gateway with a built-in management plane: one front door
that speaks the OpenAI / Anthropic protocols to your agents, and translates
to whatever each upstream provider actually supports.

```
                ┌────────────────────────────────────────────┐
  agents ──────▶│  master (front door)                       │
  (any client   │  auth · catalog · LB · protocol translate  │
   protocol)    │  usage accounting · shape sentinel         │
                └───────┬────────────────────┬───────────────┘
                        │ OTP distribution   │ local fallback
                ┌───────▼───────┐    ┌───────▼───────┐
                │ worker node   │    │ master-local  │
                │ provider I/O  │    │ execution     │
                └───────────────┘    └───────────────┘
```

The gateway translates; it does not judge. Both sides speak standard
protocols — a provider without standard-shaped endpoints does not ride the
gateway.

## What you get

- **Protocol translation matrix** — clients speak OpenAI Chat, OpenAI
  Responses, or Anthropic Messages; providers speak any of the three.
  Vision content and tool calls (parallel calls, image-bearing results,
  interrupted calls) ride every translatable pair. Malformed agent
  histories are repaired at the door: interrupted tool calls get a
  placeholder result, orphan results are dropped.
- **Master / worker cluster** — workers execute provider I/O and stream
  chunks back as messages. The master falls back to local execution when
  the pool is empty, dispatch fails, or a worker is lost before the first
  byte. In-flight worker loss aborts cleanly rather than retrying
  mid-stream.
- **Modality gateway** — standard endpoint shapes for
  `/v1/images/generations`, `/v1/audio/speech`, `/v1/audio/transcriptions`,
  `/v1/videos` and `/v1/embeddings` over chat-family upstreams, each behind
  an operator knob (default off).
- **Usage accounting** — per-request, per-attempt rows in Postgres (SQLite
  for a single node): tokens, cache reads, modalities, latency, failover
  reasons, and the provider's own error sentence on failures.
- **Shape sentinel** — when a provider rejects a request for its *shape*,
  the gateway logs a structural fingerprint (roles and call-id pairing,
  never content) so the next unknown agent quirk self-documents. See
  [`gateway/docs/design/shape-sentinel.md`](gateway/docs/design/shape-sentinel.md).
- **Everything hot** — routing, quotas, provider keys and the knobs behind
  new capabilities are dashboard settings: Postgres → generation bump →
  hot reload through `persistent_term`. No restart, no `sys.config` edit
  on a server.

## Endpoints

| Path | Protocol |
|---|---|
| `POST /v1/chat/completions` | OpenAI Chat |
| `POST /v1/responses` | OpenAI Responses |
| `POST /v1/messages` | Anthropic Messages |
| `GET /v1/models` | model list |
| `GET /v1/files`, `POST /v1/files` | file references materialized before dispatch |
| `POST /v1/images/generations`, `/v1/audio/speech`, `/v1/audio/transcriptions`, `/v1/videos`, `/v1/embeddings` | modality shapes (knob-gated) |
| `POST /v1/decisions`, `/v1/decide` | routing decisions |
| `GET /healthz` | liveness (port 8080; admin/stats plane on 8090) |

## Requirements

| Component | Version |
|---|---|
| Erlang/OTP | 27 (CI pins 27; the release builds on it) |
| rebar3 | 3.24+ |
| Python | 3.11+ (dashboard) |
| Node | 20+ (dashboard SPA) |
| Postgres | 16 recommended; SQLite works for a single node |

## Quick start

Two processes: the gateway, then the dashboard.

### 1. Gateway

`JANUS_SECRETS_KEY` and `JANUS_API_KEY_PEPPER` are **required** — boot
refuses without them, so generate them first:

```bash
# AES-256 keyring: key_id:base64, decoded must be exactly 32 bytes.
export JANUS_SECRETS_KEY="k1:$(head -c 32 /dev/urandom | base64)"
# Arbitrary pepper for agent-key hashing.
export JANUS_API_KEY_PEPPER="$(head -c 32 /dev/urandom | base64)"
```

The supported path is Docker — it is the only one that does not depend on
your host's C toolchain:

```bash
docker compose -f gateway/docker-compose.yml up -d   # 8080 + 8090 on loopback
docker compose -f gateway/docker-compose.yml logs -f janus
```

Running from a shell works too, but you need a working C compiler: the
SQLite backend is a NIF (`esqlite`), and a host where that NIF fails to
link will start the app with a broken DB rather than refuse.

```bash
cd gateway
./rebar3 compile
erl -noshell -pa _build/default/lib/*/ebin \
  -eval 'application:ensure_all_started(janus),
         io:format("janus up~n"),
         receive after infinity -> ok end.'
```

Omit `JANUS_DB_*` to use SQLite at `JANUS_SQLITE_PATH`; point them at
Postgres for anything beyond a single node.

### 2. Dashboard

The management plane runs from Python directly — it has no compose file:

```bash
cd dashboard
python -m venv .venv && . .venv/bin/activate
pip install -e .
cp .env.example .env          # fill in the required secrets
uvicorn app.main:app --host 0.0.0.0 --port 8091
# then open http://localhost:8091
```

Build the SPA first if `spa/dist` is absent:

```bash
cd dashboard/spa && npm ci && npm run build
```

### 3. Give it something to route

Seed a provider and an agent key from JSON (`JANUS_AUTO_SEED=1` picks up
`JANUS_SEED_PATH` at boot; the exact shape is in
[`gateway/README.md`](gateway/README.md)). Then flip the knobs you want on
the Providers page and point any OpenAI- or Anthropic-compatible agent at
`http://localhost:8080/v1`.

## Repository layout

| Path | What it is |
|---|---|
| `gateway/` | Erlang/OTP release (data plane) — routes, translates, dispatches, accounts |
| `dashboard/` | FastAPI backend + React SPA (management plane) + deploy tooling |
| `docs/` | operator-facing documentation |

## Documentation

| Document | Contents |
|---|---|
| [`gateway/README.md`](gateway/README.md) | data-plane reference: protocols, endpoints, configuration, catalog model, master/worker deployment, seeding |
| [`dashboard/README.md`](dashboard/README.md) | management plane and the fleet deploy pipeline |
| [`docs/DEPLOY-WITH-AGENTS.md`](docs/DEPLOY-WITH-AGENTS.md) | deployment field guide: single node, cluster, worker sizing, GeoLite2, and the pitfalls worth knowing in advance |
| [`gateway/docs/design/shape-sentinel.md`](gateway/docs/design/shape-sentinel.md) | the failure-shape capture mechanism and how to extend it |
| [`AGENTS.md`](AGENTS.md) | conventions for agents and contributors working in this repo |

## Operational notes

A few behaviours that surprise people on the first deploy. Full detail in
[`docs/DEPLOY-WITH-AGENTS.md`](docs/DEPLOY-WITH-AGENTS.md).

- **Long streams are expected.** Listeners run `idle_timeout => 300_000`
  and reasoning models can take a minute to first byte. Do not put a 30s
  proxy timeout in front of the gateway; the gateway itself reports a
  stalled upstream in the provider's own words rather than letting the
  client time out blind.
- **Beam memory is a high-water mark, not live usage.** After a burst the
  allocator keeps carriers resident, so a healthy worker can report a `total`
  far above its real RSS. Watch the `binary`/`processes` split instead of
  the total, and give small hosts a container `mem_limit` so growth OOMs
  the container rather than the machine.
- **Worker capacity is a concurrency cap.** Size it to the largest
  realistic fan-out (agents × parallel tool calls), not to average QPS.

## License

MIT — see [LICENSE](LICENSE).