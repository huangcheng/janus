# Deploying Janus with AI agents

A field guide for operators (and the agents assisting them) deploying
Janus single-node or as a master/worker cluster. Everything here was
learned the hard way on a live fleet; read it before improvising.

- [Single node](#single-node)
- [Cluster (master + workers)](#cluster-master--workers)
- [GeoLite2](#geolite2)
- [Known pitfalls](#known-pitfalls)
- [Post-deploy verification](#post-deploy-verification)

## Single node

One box runs everything: Postgres, the gateway (master role), the
dashboard. SQLite is the zero-config fallback but Postgres is the
production path (usage accounting, dashboard, migrations at boot).

Required environment (gateway container or bare service):

| Variable | Notes |
|---|---|
| `JANUS_SECRETS_KEY` | `key_id:base64` — AES-256 key for provider-key encryption. 32 bytes, base64. Missing = boot refuses. |
| `JANUS_API_KEY_PEPPER` | Pepper for agent-key hashing. Any non-empty string. |
| `JANUS_DB_HOST/_USER/_PASSWORD/_NAME` | Or `JANUS_DB_URL`. Absent = SQLite (`data/janus.db`) — fine to try, not for production. |

First boot with providers:

```bash
# seed.providers.json: { "agent_api_key": "sk-...", "providers": [
#   {"name": "acme", "base_url": "https://api.acme/v1", "protocol": "openai_chat",
#    "keys": ["sk-..."], "models": ["m-1"]} ] }
JANUS_AUTO_SEED=1 JANUS_SEED_PATH=/seed.providers.json
```

The agent surface is the union of provider listings and bound models;
binding is curation, not a precondition for calling.

**Knobs ship OFF.** `modality.image/tts/asr/video/embeddings` and
`translate.tools/responses/repair_tools` all default off — flip them
on the dashboard Providers page (hot reload, no restart). Calling a
modality endpoint with its knob off answers `503 modality_disabled`
by design.

Dashboard: separate container (see `dashboard/README.md`), needs
`JANUS_STATS_TOKEN` matching the gateway's admin token, and an
operator account via first-run setup.

## Cluster (master + workers)

- **Master**: `JANUS_ROLE` unset or `master`. Owns :8080 (agents),
  :8090 (admin stats), Postgres catalog, LB, protocol translation.
- **Worker**: `JANUS_ROLE=worker` + `JANUS_MASTER_NODE=<master node>`.
  Requires dist TLS material (`JANUS_FLEET_TLS_DIR`) and the SAME
  `JANUS_ERLANG_COOKIE` as the master. Workers skip :8080 entirely —
  `curl :8080/healthz` failing on a worker is correct, not a bug;
  check `docker inspect` health or the master's `/stats/sched`.
- Workers join by hello over the dist link; the master's
  `/stats/sched` `workers` array is the membership truth.
- **Local fallback is automatic**: empty pool, dispatch failure, or a
  pre-first-byte worker loss all degrade to master-local execution.
  You do not need a worker to run.
- **In-flight worker loss aborts** (`worker_lost`, no mid-stream
  retry — bytes already streamed cannot be unsent). Enable the
  pre-byte rescue via the `sched.unary_fallback` knob (covers unary
  AND stream-preflight loss).
- Worker sizing: 2 vCPU / 2 GB works, but see [memory pitfalls](#known-pitfalls).

## GeoLite2

Region-aware scheduling (`sched.geo=true`) needs the GeoLite2-City
mmdb. The failure modes are all deployment-shaped:

1. **The dashboard refresh button needs the geo volume mounted rw
   INTO THE DASHBOARD CONTAINER** at the same path the master reads
   (`JANUS_MMDB_PATH`). A missing mount answers
   `503 mmdb_volume_unavailable` — the message is the fix.
2. MaxMind credentials (`JANUS_MAXMIND_ACCOUNT_ID` /
   `JANUS_MAXMIND_LICENSE_KEY`) must be in the DASHBOARD's env, not
   just the gateway's.
3. The gateway mounts the same host path **read-only** — only the
   dashboard writes; the gateway re-loads via `/stats/mmdb/reload`
   after the download.
4. No credentials + stale file = **stale-serve** (deliberate): the
   gateway keeps routing with the old mmdb rather than refusing.

## Known pitfalls

- **Beam memory is a high-water mark, not live usage.** After a
  burst, allocator carriers stay resident: a healthy worker shows
  `mem_mb.total` ~50–120 MB while a bursty one plateaus at ~1–2 GB
  with `processes` and `binary` near zero. Guard rails: set a
  container `mem_limit` so growth OOMs the CONTAINER (seconds to
  heal) instead of the MACHINE; experiment with
  `ERL_FLAGS=+Muacul 512` to return empty carriers sooner. Watch the
  `mem_mb` split in `/stats/sched` — `binary`/`processes` growing
  across days is a real leak; a fat `total` with empty fields is
  just retained carriers.
- **Don't co-locate builds/apt with 2 GB workers.** A beam holding
  ~1 GB + a package manager needing a few hundred MB = machine-level
  OOM that takes SSH with it. Dev boxes should not be workers.
- **`up · no probe` on the Nodes page is display-only.** The
  dashboard's direct TCP probe to worker dist ports is dropped by
  locked-down security groups while the dist mesh (worker-initiated)
  is perfectly healthy. Trust `/stats/sched` membership.
- **Slow links**: worker acks/pings with multi-second RTT can trip
  the dashboard probe timeouts (raise
  `JANUS_WORKER_PROBE_INTERVAL_SEC`); carrier brownouts nodedown
  workers in pairs — the pre-byte fallback absorbs the request-side
  impact.
- **Streaming needs patience upstream**: listeners run
  `idle_timeout => 300_000`; first byte from a reasoning model can
  take 60 s+. Do not put a 30 s proxy timeout in front.
- **`enabled` columns are SMALLINT 0/1** if you edit the catalog by
  SQL — `true` is not valid.
- **Previous-response-id and other stateful Responses features are
  rejected** (`translate_unsupported`) — the gateway is stateless by
  design.
- **Malformed agent histories are repaired at the door** when
  `translate.repair_tools` is on (interrupted tool calls get a
  placeholder result; orphan results are dropped). Without it,
  strict upstreams 400 the whole request and the failure surfaces as
  `upstream_error` with the provider's sentence in the Failures page.

## Post-deploy verification

```bash
curl -fsS https://<host>/healthz                      # gateway alive
curl -fsS -H "Authorization: Bearer <agent-key>" \
     https://<host>/v1/models                         # catalog + auth
curl -fsS -H "authorization: Bearer <stats-token>" \
     http://<master>:8090/stats/sched | jq '.workers' # fleet + mem_mb
```

Then one real chat completion through each face you use (chat /
responses / messages), one modality endpoint per enabled knob, and
check the dashboard Failures page — errors there carry the upstream's
own message (`error_detail`), which is usually the whole diagnosis.
