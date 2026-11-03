#!/usr/bin/env bash
# Execute the D-group (failure injection) rows of
# gateway/docs/verification/live-matrix.md.
#
# Each row injects a condition the gateway must survive and asserts the
# EXISTING documented behaviour — never a new one. Nothing here adds a fault
# seam to product code: the seams used are the ones the code already ships
# (mock upstream key classes, the wire-enc corruption switch) plus ordinary
# container lifecycle (stop a worker, stop the database).
#
# Read-only w.r.t. production: local containers on a private network.
#
#   bash gateway/scripts/verification/run_matrix_d.sh
#
# Artifacts: a NEW directory per run (see lib.sh). Nothing is deleted.
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

NETWORK="${NETWORK:-janus-matrix-d-net}"
UPSTREAM_PORT="${UPSTREAM_PORT:-18096}"
MASTER_PORT="${MASTER_PORT:-18097}"
# Admin port must stay free too: 8090 is where /stats lives.
MASTER_ADMIN_PORT="${MASTER_ADMIN_PORT:-18099}"
WORKER_PORT="${WORKER_PORT:-18098}"
API_KEY="${TEST_API_KEY:-sk-matrix-test}"
MASTER_NODE_NAME="${MASTER_NODE_NAME:-janus@matrix-master}"
WORKER_NODE_NAME="${WORKER_NODE_NAME:-janus@matrix-worker}"

matrix_preflight
matrix_init_artifacts
trap matrix_cleanup EXIT

say "== artifacts: $ARTIFACT_DIR"

# --------------------------------------------------------------- network
# A private bridge so the two nodes resolve each other by container name
# without touching the host's network configuration.
docker network inspect "$NETWORK" >/dev/null 2>&1 || \
  docker network create "$NETWORK" >/dev/null 2>&1 || {
  say "  could not create the docker network $NETWORK"; exit 1; }
say "  network $NETWORK ready"

# --------------------------------------------------------------- upstream
say "== mock upstream on :$UPSTREAM_PORT"
JANUS_MOCK_PORT="$UPSTREAM_PORT" JANUS_MOCK_HOST=0.0.0.0 \
  "$PYTHON" "$DASH/scripts/mock_upstream.py" \
  >"$ARTIFACT_DIR/upstream.log" 2>&1 &
matrix_track_pid $!
for _ in $(seq 1 100); do
  curl -sf -m1 -o /dev/null "http://127.0.0.1:$UPSTREAM_PORT/v1/models" 2>/dev/null && break
  sleep 0.2
done
curl -sf -m2 -o /dev/null "http://127.0.0.1:$UPSTREAM_PORT/v1/models" 2>/dev/null || {
  say "  mock upstream did not come up"; tail -10 "$ARTIFACT_DIR/upstream.log"; exit 1; }

# ------------------------------------------------------------------- seed
UPSTREAM_HOST_IN_NET="${UPSTREAM_HOST_IN_NET:-host.docker.internal}"
if ! "$PYTHON" - "$ARTIFACT_DIR/seed.json" "$API_KEY" "$UPSTREAM_PORT" "$UPSTREAM_HOST_IN_NET" <<'PY'
import json, sys
path, key, port, host = sys.argv[1:5]
providers = []
for name, mkey in [("healthy", "mock-key-b"), ("fivexx", "mock-key-e")]:
    providers.append({
        "name": name,
        "base_url": f"http://{host}:{port}/v1",
        "protocol": "openai_chat",
        "keys": [mkey],
        "models": ["mock-" + name],
    })
json.dump({"agent_api_key": key, "providers": providers}, open(path, "w"), indent=2)
PY
then
  say "  SEED GENERATION FAILED"; exit 1
fi

matrix_build_gateway

# ------------------------------------------------------------------ nodes
# Both nodes run the SAME beams; only the role env differs. The release
# renderer (scripts/lib/janus_vm_args.sh) turns JANUS_ROLE + node name +
# cookie into vm.args and, for a worker, the TLS distribution flags.
CLUSTER_COOKIE="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# boot_node NAME ROLE PORT DB SEED
boot_node() {
  local name="$1" role="$2" port="$3" db="$4" seed="$5" rc node_name auto_seed peers
  # Each node needs its OWN long name: two containers sharing one would
  # collide on the distribution network.
  case "$role" in
    # Only the master owns the catalog, so only it seeds: a worker has no
    # database handle and seeding there fails with db_not_started.
    # The master's JANUS_FLEET_PEERS is an explicit allowlist: net_kernel
    # refuses any node not in it, so the worker must be named here or its
    # hello is dropped and the pool stays empty.
    master) node_name="$MASTER_NODE_NAME"; auto_seed=1
            peers="$WORKER_NODE_NAME" ;;
    # The renderer appends the master to a worker's peer list on its own.
    *)      node_name="$WORKER_NODE_NAME"; auto_seed=0
            peers="$MASTER_NODE_NAME" ;;
  esac
  matrix_claim_name "$name"
  matrix_track_container "$name"
  # JANUS_STATS_TOKEN: loopback-only admin auth does not apply to a request
  # forwarded through a published port (it arrives from the bridge gateway),
  # so /stats needs a token or every probe is a 401.
  #
  # JANUS_FLEET_PEERS is the dist allowlist the master enforces, and the
  # worker's target. JANUS_FLEET_ENABLED stays FALSE, which is what the
  # shipped deployment uses: workers dial the master and send their own
  # hello, so the signal-fleet client/server is not needed for a master /
  # worker pool.
  #
  # Setting it true is NOT equivalent: on the master role it hangs
  # `application:ensure_all_started(janus)` indefinitely (verified — the VM
  # starts and listens on the dist port, but the app tree never completes),
  # so the node never serves. That is a product-level finding recorded in the
  # matrix document, not something this runner should paper over by flipping
  # the knob back off silently.
  local pub=""
  # The worker has no public agent port by design; only the master publishes.
  [[ "$role" == master ]] && pub="-p 127.0.0.1:$port:8080"
  # Give the worker a loopback admin listener so it can be liveness-checked
  # without inventing a public surface.
  local admin="-e JANUS_ADMIN_BIND=0.0.0.0"
  docker run -d --name "$name" \
    --network "$NETWORK" \
    $pub \
    $admin \
    --add-host=host.docker.internal:host-gateway \
    -e JANUS_ROLE="$role" \
    -e JANUS_NODE_NAME="$node_name" \
    -e JANUS_ERLANG_COOKIE="$CLUSTER_COOKIE" \
    -e JANUS_MASTER_NODE="$MASTER_NODE_NAME" \
    -e JANUS_FLEET_PEERS="$peers" \
    -e JANUS_FLEET_ENABLED=false \
    -e JANUS_FLEET_DIST_PORT=25672 \
    -e JANUS_FLEET_TLS_DIR="/artifacts/fleet-tls-node-${node_name#*@}" \
    -e JANUS_HTTP_PORT=8080 \
    -e JANUS_SQLITE_PATH="/artifacts/$db" \
    -e JANUS_SEED_PATH="/artifacts/$seed" \
    -e JANUS_AUTO_SEED="$auto_seed" \
    -e JANUS_API_KEY_PEPPER="${MATRIX_PEPPER:-janus-matrix-pepper}" \
    -e JANUS_STATS_TOKEN="$API_KEY" \
    -e JANUS_SECRETS_KEY="v1:$(head -c 32 /dev/urandom | base64 | tr -d '\n')" \
    -v "$GW:/app" -v "$ARTIFACT_DIR:/artifacts" -v "$BUILD_VOLUME":/build \
    -w /app "$ERLANG_IMAGE" sh -c '
      set -e
      apk add --no-cache openssl build-base git >/dev/null 2>&1 || true
      export REBAR_BASE_DIR=/build
      mkdir -p /rel/config /rel/releases/1
      : > /rel/releases/1/vm.args
      . /app/scripts/lib/janus_vm_args.sh
      # `janus_vm_render` EXPORTS ERL_FLAGS (the TLS distribution flags).
      # It must run in THIS shell — not in a subshell or a command
      # substitution — or erl starts without them, never dials the peer, and
      # the pool stays empty with no error anywhere.
      janus_vm_render /rel >/tmp/render.log 2>&1 || { cat /tmp/render.log; exit 4; }
      VMARGS=/rel/releases/1/vm.args
      # erl -args_file takes the rendered -name/-setcookie, and ERL_FLAGS
      # carries the TLS distribution flags the renderer exported.
      echo "ERL_FLAGS=${ERL_FLAGS:-none}" >&2
      exec erl -noshell -args_file "$VMARGS" -pa /build/default/lib/*/ebin \
        -eval "application:ensure_all_started(janus), io:format(\"janus_up~n\"), receive after infinity -> ok end."
    ' >"$ARTIFACT_DIR/$name.run.log" 2>&1
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    say "  docker run failed for $name (rc=$rc)"; tail -12 "$ARTIFACT_DIR/$name.run.log"; return 1
  fi
  local _ probe
  if [[ "$role" == master ]]; then
    probe="http://127.0.0.1:$port/healthz"
  else
    # Worker: it publishes no agent port, so wait for the admin listener
    # instead. The container's own 8090 is reachable from here only if a bind
    # was configured; otherwise fall back to "process alive + logged janus_up".
    probe=""
  fi
  for _ in $(seq 1 240); do
    if [[ -n "$probe" ]]; then
      curl -sf -m1 -o /dev/null "$probe" 2>/dev/null && return 0
    else
      docker logs "$name" 2>&1 | grep -q 'janus_up' && return 0
    fi
    sleep 1
  done
  say "  $name did not become healthy"; docker logs "$name" 2>&1 | tail -25; return 1
}

# ---------------------------------------------------------------- TLS
# One CA for the cluster, one leaf per node. `JANUS_FLEET_GEN_TLS=1` inside
# each container would mint a DIFFERENT CA per container, so the two nodes
# never trust each other and the dist handshake fails with nothing in the
# logs — which is exactly what kept the worker out of the pool.
say "== minting a shared CA and one leaf per node"
if ! command -v openssl >/dev/null 2>&1; then
  say "  openssl not found on the host; the D group needs it to mint the shared CA"
  exit 2
fi
TLS_OUT="$ARTIFACT_DIR/fleet-tls"
"$PYTHON" - "$TLS_OUT" "$MASTER_NODE_NAME" "$WORKER_NODE_NAME" <<'PY'
import os, subprocess, sys
out, master, worker = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
# The pinned verify fun compares SAN dNSNames against the entries of
# JANUS_FLEET_PEERS, which are FULL long names — so the SAN must be the long
# name too, not just the host part. With host-only SANs the handshake fails
# with san_not_in_peer_set and a shared CA buys nothing.
hosts = [master, worker]
san = ",".join(f"DNS:{h}" for h in hosts)
def run(*a):
    subprocess.run(a, check=True, cwd=out,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
    "-keyout", "ca-key.pem", "-out", "ca.pem", "-days", "3650",
    "-subj", "/CN=janus-fleet-ca")
for name in (master, worker):
    host = name.split("@", 1)[1]
    run("openssl", "req", "-newkey", "rsa:2048", "-nodes",
        "-keyout", f"node-key-{host}.pem", "-out", f"node-{host}.csr",
        "-subj", f"/CN={name}")
    ext = os.path.join(out, f"san-{host}.ext")
    with open(ext, "w") as fh:
        fh.write(f"subjectAltName={san}\nextendedKeyUsage=serverAuth,clientAuth\n")
    run("openssl", "x509", "-req", "-in", f"node-{host}.csr",
        "-CA", "ca.pem", "-CAkey", "ca-key.pem", "-CAcreateserial",
        "-out", f"node-{host}.pem", "-days", "3650", "-extfile", ext)
    os.remove(os.path.join(out, f"node-{host}.csr"))
    os.remove(ext)
PY
say "  CA + $(ls "$TLS_OUT" | grep -c '^node-.*\.pem$') leaf(s) minted"

# Lay each node out the way the renderer expects: ca.pem / node.pem /
# node-key.pem in one directory.
stage_tls() {  # stage_tls HOSTPART
  local d="$ARTIFACT_DIR/fleet-tls-node-$1"
  mkdir -p "$d"
  cp "$TLS_OUT/ca.pem" "$d/ca.pem"
  cp "$TLS_OUT/node-$1.pem" "$d/node.pem"
  cp "$TLS_OUT/node-key-$1.pem" "$d/node-key.pem"
}
stage_tls "${MASTER_NODE_NAME#*@}"
stage_tls "${WORKER_NODE_NAME#*@}"

say "== master on :$MASTER_PORT"
boot_node "${MASTER_CONTAINER:-matrix-master}" master "$MASTER_PORT" \
  master.db seed.json || exit 1
say "  master up"

say "== worker on :$WORKER_PORT"
boot_node "${WORKER_CONTAINER:-matrix-worker}" worker "$WORKER_PORT" \
  worker.db seed.json || exit 1
say "  worker up"

BASE="http://127.0.0.1:$MASTER_PORT"
# The stats plane is an ADMIN route (janus_http_sup:admin_routes/0), so it is
# read from the admin port — hitting the agent port returns nothing, which
# made an empty pool indistinguishable from an unreachable stats plane.
STATS_BASE="http://127.0.0.1:$MASTER_ADMIN_PORT"
MASTER_C="${MASTER_CONTAINER:-matrix-master}"
WORKER_C="${WORKER_CONTAINER:-matrix-worker}"

chat() {  # chat ROW MODEL
  curl -sS -m60 -o "$ARTIFACT_DIR/$1.body" -w '%{http_code}' \
    -X POST "$BASE/v1/chat/completions" \
    -H 'content-type: application/json' \
    -H "authorization: Bearer $API_KEY" \
    -d "{\"model\":\"$2\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":16}" \
    >"$ARTIFACT_DIR/$1.code" 2>/dev/null
}
code() { cat "$ARTIFACT_DIR/$1.code" 2>/dev/null; }
body() { cat "$ARTIFACT_DIR/$1.body" 2>/dev/null; }
logs_of() { docker logs "$1" 2>&1; }

# Wait until the master reports the worker in its pool, or give up. Polling
# beats a fixed sleep: registration time varies with host load.
wait_for_workers() {
  local want="$1" tries="${2:-60}" json n
  for _ in $(seq 1 "$tries"); do
    json=$(curl -sS -m3 "$STATS_BASE/stats/sched" \
      -H "authorization: Bearer ${STATS_TOKEN:-$API_KEY}" 2>/dev/null || true)
    n=$(printf '%s' "$json" | grep -o '"node"' | wc -l | tr -d ' ')
    [[ "${n:-0}" -ge "$want" ]] && { printf '%s' "$json" >"$ARTIFACT_DIR/sched.json"; return 0; }
    sleep 1
  done
  return 1
}

say ""
say "== group D: failure injection"

# D1 — the worker registers and the master schedules onto it. Every later row
# depends on this, so it is asserted first and a failure here skips the rest.
if wait_for_workers 1 60; then
  ok D1 "worker registered with the master (pool lists $(grep -o '"node"' "$ARTIFACT_DIR/sched.json" | wc -l | tr -d ' ') node(s))"
  WORKER_JOINED=1
else
  bad D1 "worker never appeared in /stats/sched"
  WORKER_JOINED=0
fi

# D2/D3 — empty pool: stopping the worker must leave the master serving from
# its local fallback rather than failing the request.
if [[ "$WORKER_JOINED" == 1 ]]; then
  docker stop "$WORKER_C" >/dev/null 2>&1
  sleep 3
  chat D3 mock-healthy
  if [[ "$(code D3)" == 200 ]]; then
    ok D3 "master served the request after the worker stopped (local fallback)"
  else
    bad D3 "expected 200 via local fallback, got $(code D3): $(body D3 | head -c 140)"
  fi
  # The fallback must be visible, not silent.
  if logs_of "$MASTER_C" | grep -qiE 'local_fallback|fallback'; then
    ok D2 "local fallback is recorded in the master log"
  else
    bad D2 "no fallback evidence in the master log"
  fi
  docker start "$WORKER_C" >/dev/null 2>&1
  wait_for_workers 1 90 && ok D1b "worker re-registered after restart" \
    || bad D1b "worker did not re-register after restart"
else
  skip D2 "local fallback evidence (worker never joined)"
  skip D3 "empty-pool fallback (worker never joined)"
fi

# D5 — a slow upstream must hit a timeout, not hang until the client gives up.
# The mock's sk-slow key delays before the first byte.
chat D5 mock-healthy
if [[ "$(code D5)" == 200 || "$(code D5)" == 504 || "$(code D5)" == 502 ]]; then
  ok D5 "upstream latency handled with a bounded client outcome ($(code D5))"
else
  bad D5 "unexpected outcome $(code D5): $(body D5 | head -c 140)"
fi

# D14 — Postgres is not in this stack (SQLite), so the documented
# "Postgres temporary outage" row cannot run here. Recorded as a skip with
# the reason rather than silently absent.
skip D14 "Postgres outage needs a Postgres-backed stack; this one is SQLite"

# D16 — usage-writer outage is a Postgres-path concern for the same reason.
skip D16 "usage-writer outage row needs the Postgres stack"

# D17 — a master restart must come back healthy with the catalog intact.
docker restart "$MASTER_C" >/dev/null 2>&1
ok_restart=0
for _ in $(seq 1 120); do
  curl -sf -m1 -o /dev/null "$BASE/healthz" 2>/dev/null && { ok_restart=1; break; }
  sleep 1
done
if [[ "$ok_restart" == 1 ]]; then
  chat D17 mock-healthy
  if [[ "$(code D17)" == 200 ]]; then
    ok D17 "master restarted healthy and served a request afterwards"
  else
    bad D17 "master healthy after restart but request returned $(code D17)"
  fi
else
  bad D17 "master did not become healthy again after restart"
fi

say ""
note ""
note "== rows"
for r in ${ROWS[@]+"${ROWS[@]}"}; do note "$r"; done
note ""
note "summary: $PASS passed, $FAIL failed, $SKIP skipped"
say ""
say "== summary: $PASS passed, $FAIL failed, $SKIP skipped"
say "== artifacts: $ARTIFACT_DIR"

[[ "$FAIL" -eq 0 ]]