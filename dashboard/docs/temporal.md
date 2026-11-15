# Temporal control plane (dashboard)

Optional Portunus-style Temporal stack for periodic dashboard jobs.
Erlang / `janus_model_sync` is unchanged.

## Jobs

| Schedule id | Workflow | Interval |
|---|---|---|
| `model-sync` | `ModelSyncWorkflow` | `settings.model_sync.interval_sec` (default 21600; `0` = manual only → schedule deleted) |
| `geoip-mmdb` | `GeoIpMmdbRefreshWorkflow` | `JANUS_GEOIP_MMDB_INTERVAL_SEC` (default 604800 = 7 days); skipped while MaxMind creds unset |

Next candidate (scaffold only): entitlement healing (`app.entitlements._healing_loop`).

## Enable

1. Bring up the overlay (from the directory that holds the main dashboard compose):

```bash
docker compose -f docker-compose.yml -f deploy/docker-compose.temporal.yml --profile temporal up -d
```

CN fleets: mirror Temporal images to Huawei SWR first (operator
`mirror_temporal.sh`), then override image refs via env — e.g.
`TEMPORAL_AUTO_SETUP_IMAGE`, `TEMPORAL_UI_IMAGE`,
`TEMPORAL_POSTGRES_IMAGE`, `JANUS_DASHBOARD_IMAGE` — so compose never
pulls `temporalio/*` from Docker Hub.

2. Set on the **dashboard** service (and keep the same DB / secrets / geo volume on `janus-worker`):

- `TEMPORAL_HOST=temporal:7233`
- optional: `TEMPORAL_NAMESPACE`, `TEMPORAL_TASK_QUEUE` (default `janus-control`)
- optional: `JANUS_GEOIP_MMDB_INTERVAL_SEC`
- optional OTEL (same collector as the gateway): `OTEL_EXPORTER_OTLP_ENDPOINT`,
  `OTEL_RESOURCE_ATTRIBUTES`; worker defaults `OTEL_SERVICE_NAME=janus-worker`
  (dashboard client uses `janus-dashboard`). `OTEL_SDK_DISABLED=true` skips export.

3. Recreate the dashboard so lifespan ensures Schedules and **skips** the asyncio model-sync loop.

Manual paths stay in-process: `POST /api/sync`, `POST /api/maintenance/mmdb/refresh`.

## Worker

Same dashboard image, different command:

```text
python -m app.temporal.worker
```

(or console script `janus-worker` when the package scripts are on `PATH`).

The worker must reach Postgres and, for geoip, write `JANUS_MMDB_PATH` then call the master’s `/stats/mmdb/reload`.

If the dashboard uses `extra_hosts` (or another alias) so `stats_host`
resolves to the gateway, give the worker the **same** mapping — the
worker does not share the dashboard container’s `/etc/hosts`.

## Operator UI

- SPA: **Workflows** (`/workflows`)
- API: `GET /api/temporal/status`, `/api/temporal/workflows`, `/api/temporal/workflows/{id}`

When `TEMPORAL_HOST` is unset the page shows “Not configured”; the dashboard keeps its legacy asyncio sync loop.
