---
name: fleet-node-ops
description: >-
  Join a Janus worker to a master over inet_tls dist, verify with a redacted
  dry-run, drain/undrain pool membership, and (transitional) signal-fleet mesh
  steps. Use when operating master/worker OTP dispatch or legacy fleet nodes.
---

# Fleet node operations

Master/worker dispatch is the target cluster model (spec
`docs/superpowers/specs/2026-10-09-master-worker-otp-dispatch-design.md`).
**Signal-bus fleet** (`JANUS_FLEET_ENABLED=true`) remains transitional: it does
not put peers into the worker pool (pool admission requires `janus_worker_hello`
ack). Do not extend signal-fleet as the long-term capacity story.

## Prerequisites

- Private fleet CA + per-node leaf certs (`ca.pem`, `node.pem`, `node-key.pem`)
  mounted at `JANUS_FLEET_TLS_DIR` (default `/var/lib/janus/fleet`).
- Leaf **SAN = full Erlang long names** (e.g. `DNS:janus@master.example`,
  `DNS:janus@worker.example`) — host-only SANs fail `janus_fleet_tls:verify/3`.
- Shared cookie: **≥32 random bytes** as hex (`openssl rand -hex 32` → 64 hex
  chars). Same value on master and every worker.
- Firewall: allow **only peer `/32` → dist port** (default `25672`). Never
  expose dist to `0.0.0.0/0`.
- Master runs with `JANUS_ROLE` unset or `master`; Postgres + agent `:8080`.
- Worker runs with `JANUS_ROLE=worker`, **no published `:8080`**, no catalog
  poll.

## Worker join (happy path)

1. **Issue cert** for the worker long name (`JANUS_NODE_NAME`, e.g.
   `janus@worker.site`). Include master long name in SAN if this node must accept
   inbound dist from master (typical dual-node layout).

2. **Pinhole** worker host: master `/32` → worker `25672/tcp`; master host:
   worker `/32` → master `25672/tcp`.

3. **Set env on the worker** (examples — substitute real names):

   ```bash
   JANUS_ROLE=worker
   JANUS_NODE_NAME=janus@worker.example
   JANUS_MASTER_NODE=janus@master.example
   JANUS_ERLANG_COOKIE=<64-hex-chars-from-openssl-rand-hex-32>
   JANUS_FLEET_TLS_DIR=/var/lib/janus/fleet
   # Optional: JANUS_WORKER_REGION=cn-east
   ```

   `docker-entrypoint.sh` merges `JANUS_MASTER_NODE` into `JANUS_FLEET_PEERS`,
   validates the hex cookie, and enables **inet_tls dist only** — it does **not**
   set `JANUS_FLEET_ENABLED` (no signal-fleet children on workers).

4. **Set env on the master** (dist + pool):

   ```bash
   JANUS_NODE_NAME=janus@master.example
   JANUS_ERLANG_COOKIE=<same-64-hex-as-workers>
   JANUS_FLEET_PEERS=janus@worker.example   # comma-separated peer long names
   JANUS_FLEET_TLS_DIR=/var/lib/janus/fleet
   ```

   Mount TLS before start. For local dev only: `JANUS_FLEET_GEN_TLS=1` with peers
   listing every long name that will connect.

5. **Start master**, then **start worker**. Wait until dist is up (nodes visible
   to each other).

6. **Confirm hello ack** on the master:
   - `janus_workers_available` on master `/metrics` ≥ 1, or
   - master logs: worker hello handled (ack, not sticky nack).

7. **Mandatory dry-run (non-stream)** through the **master** agent API (not the
   worker):

   ```bash
   curl -sS -o /tmp/janus-worker-join-dry-run.json -w '%{http_code}' \
     -H 'Authorization: Bearer <agent-key>' \
     -H 'Content-Type: application/json' \
     -d '{"model":"<small-chat-model>","messages":[{"role":"user","content":"ping"}],"stream":false}' \
     'http://127.0.0.1:8080/v1/chat/completions'
   ```

   Expect HTTP 2xx and a normal completion body. Confirm a usage row on master
   Postgres (worker relays `done` usage; master persists).

8. **Write verify artifact** (see Redaction below) under a durable path, e.g.
   `/tmp/janus-worker-join-<date>.txt`.

## Undrain (re-admit after sticky drain)

When a worker completes drain idle, the master records it in
`worker_sticky_drained`. Dist reconnect + auto-hello **nacks** until ops
undrain.

On the **master** node (remote shell or `rpc`):

```erlang
Worker = 'janus@worker.example',
ok = rpc:call('janus@master.example', janus_worker_pool, undrain, [Worker]).
```

Then on the worker: **re-send hello** (restart `janus_worker_dispatch` or
restart the container). Pool membership requires a fresh ack after undrain.

Verify: `/metrics` `janus_workers_available` increments; sticky nack stops.

## Drain (ops overview)

Worker-initiated drain stops **new** dispatch; in-flight jobs finish; after
30s idle with zero in-flight, master moves the node to sticky-drained. Hello
during drain may ack but the node stays non-dispatchable until undrain + re-hello.
Details: spec §3.4 / plan TF-13.6.

## Transitional signal-fleet join (legacy)

Only when intentionally running the **signal bus** (not worker pool capacity):

- Set `JANUS_FLEET_ENABLED=true` on **master** gateways that participate in the
  mesh.
- Same TLS + cookie + peer list discipline as above.
- Peers joined this way **never** enter `janus_worker_pool` without worker
  hello (N10).

Prefer master/worker env (`JANUS_ROLE=worker`) for new egress capacity.

## Redaction rules (N6)

Verify artifacts, tickets, and chat attachments must **never** contain:

- `JANUS_ERLANG_COOKIE`, `.erlang.cookie`, or cookie substrings.
- Private keys (`node-key.pem`, `ca-key.pem`) or PEM bodies.
- Agent/API bearer tokens, provider API keys, or `Authorization` header values.
- Job `headers` values or request `body` from worker wire messages (use
  `janus_worker_wire:redact_job/1` shape in logs if needed: keys only).

**Allowed in artifacts:** HTTP status codes, model id, node long names, region
tag, `janus_workers_available` gauge value, hello ack/nack **reason atoms**
(`drained`, `vsn`), timestamps, PASS/FAIL checklist lines.

Before attaching an artifact, grep for `Bearer `, `sk-`, `sk-ant-`, and your
cookie hex; redact or omit the file if matched.

## Failure cues

| Symptom | Likely cause |
|--------|----------------|
| Worker boot refused at entrypoint | Missing `JANUS_MASTER_NODE`, cookie not 64 hex, or unknown `JANUS_ROLE` |
| TLS / dist connect fail | SAN mismatch, wrong peer in `JANUS_FLEET_PEERS`, or firewall not `/32` |
| Hello nack `drained` | Sticky-drained; run undrain + worker re-hello |
| Dry-run OK but gauge 0 | Hello not acked yet; check master pool logs |
| Next request local-only | Empty pool / dispatch fail / ack deadline — master falls back locally (N3) |

## Related docs

- `AGENTS.md` — role invariants and fallback behavior
- `docs/superpowers/plans/2026-10-09-master-worker-otp-dispatch.md` — TF-13
- Dashboard Nodes page — scrape observation only; **do not** use dashboard APIs
  for join/undrain automation in this skill.
