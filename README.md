# Janus

An Erlang/OTP LLM gateway with a built-in management plane: one front
door that speaks the OpenAI / Anthropic protocols to your agents and
translates to whatever each upstream provider actually supports.

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

- **Protocol translation matrix** — clients speak OpenAI Chat,
  OpenAI Responses, or Anthropic Messages; providers speak any of the
  three. Vision content, tool calls (including parallel calls,
  image-bearing results, interrupted calls) ride every translatable
  pair. Malformed agent histories are repaired at the door
  (placeholder tool results for interrupted calls, orphan-result
  dropping).
- **Master / worker cluster** — workers execute provider I/O and
  stream chunks back as messages; the master falls back to local
  execution when the pool is empty, dispatch fails, or a worker is
  lost before the first byte. In-flight loss aborts cleanly.
- **Modality gateway** — standard endpoint shapes for
  `/v1/images/generations`, `/v1/audio/speech`, `/v1/audio/transcriptions`,
  `/v1/videos`, `/v1/embeddings` over chat-family upstreams, each
  behind an operator knob (default off).
- **Usage accounting** — per-request, per-attempt rows in Postgres
  (or SQLite for single-node): tokens, cache reads, modalities,
  latency, failover reasons, and the provider's own error sentence
  on failures.
- **Shape sentinel** — when a provider rejects a request for its
  SHAPE, the gateway logs a structural fingerprint (roles + call-id
  pairing, never content) so the next unknown agent quirk
  self-documents. See `gateway/docs/design/shape-sentinel.md`.
- **Management plane** — FastAPI + React dashboard: providers/keys/
  models, routing, quotas, failures with upstream error detail,
  per-node fleet runtime observer, live knobs (hot-reloaded, no
  restarts).

## Repository layout

| Path | What it is |
|---|---|
| `gateway/` | Erlang/OTP release (data plane) — routes, translates, dispatches, accounts |
| `dashboard/` | FastAPI backend + React SPA (management plane) + all deploy tooling |

## Quick start

```bash
# 1. Postgres + gateway (docker compose, or see gateway/README.md for bare metal)
cp gateway/deploy/inventory.env.example gateway/deploy/inventory.env  # fill your fleet
docker compose -f gateway/docker-compose.yml up -d

# 2. Dashboard
cd dashboard && cp .env.example .env  # fill secrets
docker compose up -d
```

Seed a provider + key from a JSON file
(`JANUS_AUTO_SEED=1`, see `gateway/README.md` §Seeding), flip the
knobs you want on the Providers page, and point any OpenAI- or
Anthropic-compatible agent at the gateway.

## Documentation

- `gateway/README.md` — the full data-plane reference: protocols,
  endpoints, configuration, catalog model, master/worker deployment
- `dashboard/README.md` — management plane + fleet deploy pipeline
- `gateway/docs/design/shape-sentinel.md` — the failure-shape
  capture mechanism and how to extend it
- `docs/DEPLOY-WITH-AGENTS.md` — deployment field guide for
  operators and AI agents: single node, cluster, worker nodes,
  GeoLite2, and the pitfalls worth knowing in advance

## License

MIT — see [LICENSE](LICENSE).
