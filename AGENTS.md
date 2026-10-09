# Janus — Agent Instructions

Erlang/OTP LLM gateway (data plane). Its management plane lives in the
**sibling repo `../janus-dashboard`** (Python FastAPI + React SPA): most
feature work touches both. All comments, docs, and commit messages in
English. Respond in the user's language (Chinese → Chinese).

## Why Erlang (operator lock — 2026-10-09)

OTP was chosen so we can run a **master / worker** cluster:

- **Master** (front door) accepts the client, owns DB/catalog/LB pick,
  builds the upstream job, streams bytes back to the client.
- **Worker** runs provider I/O and sends **chunks as messages** back to
  the master immediately (streams are not one-shot RPC returns).
- **Local fallback:** if the worker pool is empty, dispatch fails, or
  pre-stream ack misses the deadline, the master executes upstream
  itself (single-node and “cluster shrank to the door” share this path).
- Catalog/keys live on the **master only**; workers do not poll Postgres.
  Optional **provider-affinity** dispatch prefers workers by region or
  `providers.affinity_node`.
- Dist does **not** move TCP `accept` across hosts. Supervisors stay
  **local**; cross-node awareness is `nodedown` + process monitors.
- **Video** (`janus_m_video` / `/v1/videos`) stays **master-local** on
  first ship — no worker dispatch for video jobs.

Target design:
`docs/superpowers/specs/2026-10-09-master-worker-otp-dispatch-design.md`.

**Boot roles:** unset or `JANUS_ROLE=master` → master; `JANUS_ROLE=worker`
requires `JANUS_MASTER_NODE`. Unknown role refuses boot. Workers skip agent
`:8080`; `docker-entrypoint.sh` wires inet_tls dist to the master (see
`skills/fleet-node-ops/SKILL.md`).

**Legacy (transitional):** `janus_fleet` signal bus (cool/latency mirrors
across **full** gateways) is not the long-term capacity model. Peers joined
only via signal-fleet **never** enter `janus_worker_pool` without worker
hello. Do not extend signal-fleet as “the” cluster story; keep it runnable
until cutover. `JANUS_FLEET_ENABLED` is separate from worker dist.

## Layout

- `apps/janus` — root release app (`JANUS_ROLE=master|worker`)
- `apps/janus_core` — DB (epgsql/esqlite via `janus_db_conn`), ETS catalog
  (`janus_catalog`), LB (`janus_lb`), usage writer (`janus_usage`), seed
- `apps/janus_http` — Cowboy listeners (:8080 agent API, :8090 read-only
  admin `/stats` + `/metrics`), protocol translate (`janus_protocol_translate`,
  SSE state machines for all translatable pairs), `janus_auto` (janus-auto
  adjudicator), modality plugins (`janus_modality` shared plumbing +
  `janus_m_images` / `janus_m_audio_speech` / `janus_m_audio_asr` /
  `janus_m_video` behind one cowboy front door `janus_http_modality`,
  `janus_multipart` RFC 7578 parser, `janus_jvid` HMAC job-id codec).
  Real captured wire fixtures: `apps/janus_http/test/fixtures/`
  (`sse/` transcripts, `probes/` provider replies) — eunit consumes
  these; never invent frames.
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
   real-stack gate (step count grows with TEST-FLOWS.md): real Postgres + real gateway + real upstream).
   Gate spans E.* (entitlement/failover/translation incl. knob matrix
   E.7-E.14), M.* (modality: real minimax image, real mimo TTS/ASR,
   knob default-off), TF-1..11. Production is NEVER mutated by tests —
   only the read-only smoke (`run_test_flows.py --smoke`) runs there
   (S.8 /metrics skips when stats_host is container-network-only).
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
  docker run --rm -e HEX_MIRROR -e HEX_CDN -v F:/Janus/apps:/app/apps -v F:/Janus/config:/app/config -v F:/Janus/rebar.config:/app/rebar.config -v F:/Janus/rebar.lock:/app/rebar.lock -v janus-ebin-otp27:/app/_build -w /app janus-build:test sh -c 'rebar3 fmt --check && rebar3 eunit'
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

- **Master / worker (target):** public entry and catalog on master;
  workers are execution-only over OTP dist; empty pool ⇒ **local fallback**
  on master (not 503-by-default). In-flight worker loss ⇒ abort
  `worker_lost` (no retry). See §Why Erlang and the master-worker spec.
- **Pure gateway**: no business logic beyond routing/LB/adjudication
  (and job dispatch to workers) on the data plane; management logic
  belongs in the dashboard repo. Workers must stay thinner than masters.
- **Standard protocols only**: the data plane speaks OpenAI
  Chat/Responses, Anthropic Messages, and the OpenAI-standard modality
  endpoint shapes (/v1/images/generations, /v1/audio/speech,
  /v1/audio/transcriptions, /v1/videos). NO provider-dialect adapters
  (operator decision 2026-10-07) — a provider without standard-shaped
  endpoints does not ride the gateway. One grandfathered exception:
  the minimax T2I translator; the category is frozen.
- Config flows dashboard → Postgres on the **master** → generation bump
  → master hot-reload (never edit `sys.config` by hand on servers; the
  `settings` table overrides it via `janus_config:distribute_settings`
  → persistent_term — direct PT writes, NOT gen_server casts: consumers
  may not be started yet at boot). Workers do **not** poll provider/key
  catalog; job messages carry what they need.
- Settings/cross-process values that must survive start order go through
  persistent_term, not name-registered casts.
- Catalog is ETS rebuilt from DB; `enabled` columns are SMALLINT 0/1 —
  normalize to booleans on read, write 1/0 in SQL (never `true`).
- Feature knobs (settings keys → persistent_term, ALL default off,
  flipped by the operator on the Providers page): `translate.tools` /
  `translate.responses` gate the cross-protocol stream translations;
  `modality.{image,tts,asr,video,computer}` gate the modality
  endpoints (503 `modality_disabled` when off). Knob-off must keep its
  legacy 400/503 path working (gate asserts both regimes).
- usage_events carries `modality/units/outcome/cache_read_input_tokens`
  (migration 010/012); modality plugins record units = images n / TTS
  chars; video lifecycle lives in `video_jobs` (migration 011).
- Streaming toward a responses-protocol PROVIDER is pre-flight 400
  (`stream_pair_untranslatable` — Phase 3 not built); a chat-family
  call naming a non-chat listing is rejected locally (`wrong_modality`)
  — EXCEPT a chat/Responses call naming an openai_decisions-ONLY
  listing, which is `protocol_requires_native` (Decisions is its own
  native face; never `wrong_modality`).
- SSE parser: chunk-fragmentation-safe (pending event lines re-encoded
  into the leftover — regression eunit drives real fixtures at chunk
  size 7 and byte-at-a-time; fragmented MUST equal whole).
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
- `docs/superpowers/plans/*.md` — audited specs (usage stats,
  auto-router, observability metrics, full protocol translation,
  modality gateway). `docs/audit/SYNTHESIS.md` + archive hold the
  multi-model audit rounds behind them; `tools/` holds the provider
  probe/capture scripts (read keys from the operator temp env file,
  never committed). Target cluster:
  `docs/superpowers/specs/2026-10-09-master-worker-otp-dispatch-design.md`.
  Worker join / undrain / redacted dry-run:
  `skills/fleet-node-ops/SKILL.md` (transitional signal-fleet steps
  included; never dashboard scrape APIs for join automation). Dashboard
  Nodes = observation only.
