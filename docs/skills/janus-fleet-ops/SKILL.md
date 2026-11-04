---
name: janus-fleet-ops
description: Operate a Janus gateway fleet — add or replace worker nodes, manage providers, models, routes and the auto-router, and inspect logs, failures and usage. Use when asked to deploy/change fleet nodes or to configure the gateway through the dashboard. Covers the external steps (inventory, env/TLS seeding, deploy scripts) that no API can reach, plus the dashboard MCP tools for everything else.
---

# Janus Fleet Ops

Two worlds, one workflow. The **external steps** (SSH to the target, seed
fleet env and TLS, run the deploy script) no dashboard API can perform —
you do them from the operator machine that owns the deploy scripts and the
gitignored inventory. Everything else — node registration, worker status,
providers, models, routes, auto-router, logs/failures/usage — goes through
the dashboard's **MCP server** rather than the UI. Prefer MCP tools over
driving the SPA with a browser: same audit trail, none of the clicking.

Never commit fleet specifics. Inventory paths, host names, IPs and secrets
live in `gateway/deploy/inventory.env` (gitignored by design); only its
`.example` twin is public. Production is verified read-only — curl and
browse, never mutate.

## Prerequisites

- Dashboard MCP is OFF by default. The operator enables it once:
  `PUT /api/settings/mcp?role=<role>&reason=<why>` with body
  `{"enabled": true, "confirmed": true}` (break-glass pair). While off,
  `/mcp/` answers 404 as if it did not exist — that is the designed
  fail-closed behavior, not an outage.
- Connect MCP clients to `https://<dashboard>/mcp/` (note the trailing
  slash) with header `Authorization: Bearer <operator JWT>`.

## Adding a worker node (the expensive operation)

1. **Inventory**: append `JANUS_NODE_<name>` and `JANUS_NODE_ADDR_<name>`
   records to `gateway/deploy/inventory.env` following
   `inventory.env.example` (`role=worker`, `runtime=docker|bare`,
   `stacks_dir`). Validate the record before saving — the file is sourced.
2. **Target host**: seed `<stacks_dir>/.env` (role=worker, node name,
   master node, peers, dist port, TLS dir, shared cookie/secrets — see
   gateway/README.md env tables) and the `fleet/*.pem` material. The
   one-time master/worker conversion script
   (`dashboard/scripts/deploy_mw_prod.sh`) shows the canonical key set.
3. **Deploy**: `dashboard/scripts/deploy_prod.sh` scoped via
   `JANUS_DEPLOY_HOSTS=<name>`, or `gateway/scripts/deploy_fleet.sh
   --nodes <aliases>` for bare-runtime nodes (a docker node in `--nodes`
   hard-refuses; use deploy_prod.sh there). First bare deploy on a host
   bootstraps env + TLS + the systemd unit itself.
4. **Join is automatic**: the worker dials the master and sends its hello.
   No dashboard registration exists for workers — membership truth is the
   master's `/stats/sched workers[]` (`node_sched` tool or
   `GET /api/nodes`). Watch for `status: "up"`; `sticky` means drained.
5. **Integrate**: `nodes_list` to confirm the worker surfaced with the
   right region/build; `worker_geo_refresh` if geo looks stale;
   `worker_note_set` for an operator remark. A NEW master/gateway row
   (rare) is `node_register` with the per-node stats token.

## Post-deploy verification (read-only)

- `https://<master>/healthz` and `/readyz` on :8080; `/v1/models` with an
  agent key. A worker's :8080 healthz failing is CORRECT — workers skip
  the agent plane.
- `node_sched` → `workers[]` entry `up`, region, git_sha.
- `failures_summary` and `logs_tail` for anything the join disturbed.
- Full runbook: `docs/DEPLOY-WITH-AGENTS.md`.

## Managing the catalog (all via MCP tools)

- Providers: `providers_list` / `provider_create` (key is write-only) /
  `provider_update` (affinity_node/region_tag only) / enable/disable /
  `provider_probe` (fire-and-forget 202 — outcome lands on the
  entitlements surface) / `provider_test_key`. `provider_delete`
  CASCADES: routes snapshotted, last-route models retired, tiers pruned.
  `provider_allow_internal` is break-glass (role/reason/confirmed).
- Models & routes: `model_create`, then `route_add` keyed by
  `(model_id, provider_id)`; `route_enable/disable/rebalance/delete`;
  `models_sync` to refresh listings.
- Auto-router: `auto_router_get/put` (partial merge; tier members must be
  bound models unless disabled), `auto_reorder_get/put` (break-glass —
  and this one bumps the config generation), `auto_reorder_tick` to force
  a pass.
- Fleet runtime: `fleet_command` (allowlisted: fleet_status, pool_ping,
  runtime_snapshot, worker_geo_refresh, lb_cool_clear,
  config_reload_nudge, catalog_cache_flush) — issued against a master
  row; pool_ping/worker_geo_refresh run there, the rest fan out.
- Break-glass tools take `role`, `reason` and `confirmed: true` — fill
  them honestly; they land in the audit trail.

## Observability

`usage_summary/spend/events/timeline`, `failures_summary/events`,
`logs_tail` (source=live merges node rings), `ops_events`, `node_logs`,
`node_metrics` (Prometheus text), `alerts_list/test`, `audit_recent` —
the audit trail is the record of everything you changed.

## Failure modes worth remembering

- Worker never shows `up`: check its `.env` master address, shared cookie
  and TLS dir first; then `node_logs` on the master for nacked hellos
  (`drained` = it was drained, `vsn` = version skew).
- `up · no probe` on the Nodes page is display-only (see known pitfalls in
  DEPLOY-WITH-AGENTS.md).
- `fleet_command` answering 409 `no_nodes` means no enabled gateway rows —
  register the master row first (`node_register`).
- Tool call answering HTTP 4xx JSON is the REST layer's own error contract
  surfacing verbatim — read it, do not retry blindly.
