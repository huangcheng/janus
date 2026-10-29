#!/usr/bin/env bash
# Convert production from 3× signal-fleet gateways to master/worker OTP:
#   aliyun  — master (agent :8080) + co-located worker (docker DNS)
#   tencent — worker only
#   jdcloud — worker only
#
# Prerequisites: SSH Host aliases aliyun/tencent/jdcloud in ~/.ssh/config.
# No local test gate (test suites removed 2026-10-18); verify via browser + curl live-checks.
# Rotates fleet cookie (≥64 hex) + regenerates shared CA leaves with SANs
# for all four long names. Artifacts under /tmp/janus-mw-deploy-<ts>/
# (never prints cookie/PEM bodies).
# Takes the shared deploy lock (scripts/lib/janus_deploy_lock.sh) for the
# whole run, so it never interleaves with deploy_prod.sh or a second
# operator, and renews it at every phase boundary. Runs a read-only
# pre-flight (step 0) before the first host mutation; it accepts no
# arguments and has no --plan/--dry-run.
#
# Dist exposure: the compose publishes :25672. Unless JANUS_MW_DIST_BIND
# pins the publish to one host address, the mapping is the historical bare
# "25672:25672", i.e. 0.0.0.0 — see the pre-flight warning and
# skills/fleet-node-ops/SKILL.md ("never expose dist to 0.0.0.0/0").
set -euo pipefail
cd "$(dirname "$0")/.."

GW_SRC="${JANUS_GW_SRC:-${JANUS_SRC:-../janus}}"
SHIP_PLATFORM="${JANUS_DEPLOY_PLATFORM:-linux/amd64}"
# Host address to publish the fleet dist port on. Empty = keep the old bare
# mapping (docker binds 0.0.0.0); an IPv4 value pins the publish so the port
# is not world-reachable. The correct peer-facing address differs per host
# (public vs private interface), so this is one operator-chosen address, not
# a computed one; the peer firewall/SG state is not visible from here.
DIST_BIND="${JANUS_MW_DIST_BIND:-}"
if [ "$DIST_BIND" = "0.0.0.0" ]; then DIST_BIND=""; fi
ART="${JANUS_MW_DEPLOY_ART:-/tmp/janus-mw-deploy-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$ART/tls" "$ART/logs"
chmod 700 "$ART"

MASTER_HOST=aliyun
MASTER_IP="${JANUS_MW_MASTER_IP:?set JANUS_MW_MASTER_IP}"
TENCENT_IP="${JANUS_MW_WORKER_IP:?set JANUS_MW_WORKER_IP}"
JDCLOUD_IP="${JANUS_MW_WORKER2_IP:?set JANUS_MW_WORKER2_IP}"
# DNS hostname required: IP literals skip /etc/hosts, so a co-located
# worker cannot hairpin to janus@<public-ip>. External workers resolve
# <public origin> → MASTER_IP via public DNS.
MASTER_DNS="${JANUS_MW_MASTER_DNS:?set JANUS_MW_MASTER_DNS}"
MASTER_NODE="janus@${MASTER_DNS}"
OLD_MASTER_NODE="janus@${MASTER_IP}"
# Co-located worker: dotted docker hostname (OTP -name rejects bare names).
# Listens on 25672 inside the docker network only — NOT published to host
# (static janus_fleet_epmd is single-port; host IP:25672 stays the master).
W_ALIYUN_HOST=janus-worker.aliyun.mw
W_ALIYUN_NODE="janus@${W_ALIYUN_HOST}"
W_TENCENT_NODE="janus@${TENCENT_IP}"
W_JDCLOUD_NODE="janus@${JDCLOUD_IP}"

ALL_NODES="${MASTER_NODE},${OLD_MASTER_NODE},${W_ALIYUN_NODE},${W_TENCENT_NODE},${W_JDCLOUD_NODE}"
WORKER_PEERS="${W_ALIYUN_NODE},${W_TENCENT_NODE},${W_JDCLOUD_NODE}"

log() { echo "$*" | tee -a "$ART/harness.log"; }

# M2 (review): once the ship retags janus-gw:latest, the pre-deploy image id
# and the fleet/env/compose backup are the ONLY rollback material. Every
# failure after the capture points at the recorded recipe instead of leaving
# the operator to archaeology on three hosts. Driven from the EXIT trap so a
# `set -e` abort is covered too, not just the explicit `die` paths.
rollback_hint() {
  [ -s "$ART/prev-image-aliyun" ] || [ -s "$ART/prev-image-tencent" ] || [ -s "$ART/prev-image-jdcloud" ] || return 0
  log "ROLLBACK: previous image ids + fleet/env/compose backups recorded — recipe: $ART/rollback.txt"
  local h
  for h in aliyun tencent jdcloud; do
    [ -s "$ART/prev-image-$h" ] || continue
    log "   $h: prev-image $(cat "$ART/prev-image-$h") backup $(cat "$ART/backup-dir-$h" 2>/dev/null || echo '?')"
  done
}

die() { log "FAIL: $*"; exit 1; }

# The deploy lock is the REPLICATED Postgres row CAS shared with
# deploy_prod.sh and the promote path (F4.1): this script rewrites .env +
# compose and recreates services on three production hosts, so it must never
# interleave with a normal deploy, a promote, or another operator.
# topology_psql() (the lock's DB seam) resolves the leader from the operator
# topology; with none configured, step 0 defaults it to the conversion's own
# master.
# shellcheck source=scripts/lib/janus_topology.sh
source scripts/lib/janus_topology.sh
# shellcheck source=scripts/lib/janus_deploy_lock.sh
source scripts/lib/janus_deploy_lock.sh

# Node-side image checks. `docker save | docker load` preserves the config
# digest (the image id) on classic docker daemons, so every host must hold
# exactly the shipped GW_IMAGE_ID; a mismatch means the host kept an older
# artifact and would recreate from it. A buildkit/OCI re-import can rewrite
# the id, so JANUS_MW_ALLOW_IMAGE_ID_DRIFT=1 downgrades that one check to a
# loud WARN instead of a false FAIL.
verify_loaded_image() {  # $1 = host
  local h="$1" id
  id="$(ssh "$h" "docker inspect -f '{{.Id}}' janus-gw:latest" 2>/dev/null | tr -d '[:space:]' || true)"
  [ -n "$id" ] || die "$h: janus-gw:latest is missing after ship — the image load failed"
  if [ "$id" = "$GW_IMAGE_ID" ]; then
    log "   $h: loaded image id verified"
  elif [ "${JANUS_MW_ALLOW_IMAGE_ID_DRIFT:-0}" = "1" ]; then
    log "   WARN: $h: loaded image id '$id' != shipped '$GW_IMAGE_ID' (JANUS_MW_ALLOW_IMAGE_ID_DRIFT=1)"
  else
    die "$h: loaded image id '$id' != shipped '$GW_IMAGE_ID' — this host would recreate from a stale artifact"
  fi
}

# Same-host check after a recreate: the RUNNING container must be the node's
# janus-gw:latest tag target. Unlike verify_loaded_image this cannot
# false-fail on a re-imported id.
verify_node_image() {  # $1 = host, $2 = container (default janus)
  local h="$1" c="${2:-janus}" rid tagid
  rid="$(ssh "$h" "docker inspect -f '{{.Image}}' '$c'" 2>/dev/null | tr -d '[:space:]' || true)"
  tagid="$(ssh "$h" "docker image inspect -f '{{.Id}}' janus-gw:latest" 2>/dev/null | tr -d '[:space:]' || true)"
  { [ -n "$rid" ] && [ -n "$tagid" ]; } || die "$h: cannot inspect container '$c' or the janus-gw:latest tag"
  [ "$rid" = "$tagid" ] || die "$h: container '$c' runs image '$rid' != node janus-gw:latest '$tagid'"
  log "   $h: $c runs the shipped image"
}

# Does the host's compose file define <service>? The compose files here are
# script-owned and list top-level services at two-space indent, so a key
# match is exact; unlike `docker compose config --services` it cannot be
# tripped by the still-unpinned HOST_MASTER_IP placeholder on the first run.
host_has_service() {  # $1 = host, $2 = compose service
  ssh "$1" "grep -q '^  $2:' /opt/stacks/janus/docker-compose.yml" 2>/dev/null
}

# L1: `sed -i.bak` left the unredacted bytes in *.bak next to the log, so the
# retained artifact tree kept the cookie; the loop also skipped the rollout
# logs (they are *.txt). No backup, every retained file.
redact_logs() {
  local cookie="$1" f
  [ -z "$cookie" ] && return 0
  for f in "$ART"/logs/* "$ART"/harness.log; do
    [ -f "$f" ] || continue
    sed -i "s/${cookie}/<REDACTED_COOKIE>/g" "$f" 2>/dev/null || true
  done
}

# Lock renewal — same contract as deploy_prod.sh: extend OUR row and prove
# it is still ours at each phase boundary; abort BEFORE touching more nodes
# when another run took the lock over after TTL expiry.
renew_deploy_lock() {  # $1 = phase label
  [ -n "${DEPLOY_LOCK_HOLDER:-}" ] || return 0
  deploy_lock_renew "$DEPLOY_LOCK_TTL_SEC" || {
    log "FAIL: deploy lock renewal failed at '$1' — this run no longer owns the lock (TTL takeover, or leader Postgres unreachable). Aborting BEFORE touching more nodes."
    exit 5
  }
}

# ---- 0. pre-flight: inputs, inventory, lock (no host mutation) ----
log "== 0. pre-flight: inputs, inventory, deploy lock =="
[ "$#" -eq 0 ] || die "no arguments accepted (this script has no --plan/--dry-run); got: $*"
[ -d "$GW_SRC" ] || die "gateway source '$GW_SRC' not found (set JANUS_GW_SRC / JANUS_SRC)"
[ -f "$GW_SRC/docker-entrypoint.sh" ] || die "gateway source '$GW_SRC' has no docker-entrypoint.sh (the rollout bind-mounts it)"
for bin in docker gzip openssl ssh scp base64; do
  command -v "$bin" >/dev/null 2>&1 || die "pre-flight: required tool '$bin' is not on PATH"
done

# M2 (review M4): the compose below publishes the OTP dist port. Docker's
# published-port rules bypass host INPUT filtering (only DOCKER-USER is in
# the path), so a bare mapping is world-reachable unless the cloud security
# group pins it to the peer IPs. The fleet runbook
# (skills/fleet-node-ops/SKILL.md) says: "allow only peer /32 -> dist port
# (default 25672). Never expose dist to 0.0.0.0/0." The SG state is not
# visible from this host, so this is a loud pre-flight warning plus an
# operator pin — not a machine-verified guarantee (residual: firewall rules).
if [ -n "$DIST_BIND" ]; then
  case "$DIST_BIND" in
    *[!0-9.]*) die "JANUS_MW_DIST_BIND='$DIST_BIND' must be an IPv4 address (mapped as <addr>:25672:25672)" ;;
  esac
fi
if [ -z "$DIST_BIND" ]; then
  log "WARN: dist :25672 will be published as 0.0.0.0:25672:25672 on ALL THREE hosts."
  log "WARN: the fleet runbook forbids exposing dist to 0.0.0.0/0 — before the rollout"
  log "WARN: verify every cloud security group allows 25672 ONLY from the other two"
  log "WARN: node IPs (/32), or re-run with JANUS_MW_DIST_BIND=<host address>."
else
  log "   dist :25672: published on ${DIST_BIND} only (JANUS_MW_DIST_BIND)"
fi

# M5 (review): tencent/jdcloud become dist-only workers, so any host-local
# Caddy/DNS entry that still proxies 127.0.0.1:48080 there has no backend.
# Those host configs are in neither repo — an operator action, but it must
# be visible BEFORE anything mutates (the old script only said so at the end).
log "NOTE: after this run the follower origins stop serving local :8080."
log "NOTE: point their Caddy/DNS at the master (the master origin) BEFORE the rollout"
log "NOTE: all three hostnames serve gateway endpoints (see deploy topology docs)."

# Inventory = the SSH aliases plus the remote prerequisites this script uses
# (docker for every step, python3 for env_set, the bind-mounted sys.config).
for h in aliyun tencent jdcloud; do
  ssh -o ConnectTimeout=8 "$h" \
    'command -v docker >/dev/null && command -v python3 >/dev/null && test -d /opt/stacks/janus && test -f /opt/stacks/janus/.env && test -f /opt/stacks/janus/sys.config' \
    || die "pre-flight: '$h' unreachable or missing docker / python3 / /opt/stacks/janus/{.env,sys.config} (SSH inventory)"
  log "   $h: inventory OK"
done
# The conversion replaces the production master in place: refuse to start
# from a node that is not answering, so a failed run has a known-good
# reference point instead of an unknown one.
topology_probe_leader "$MASTER_HOST" \
  || die "pre-flight: $MASTER_HOST does not answer healthz — refusing to convert a node whose current state is already unknown"
log "   $MASTER_HOST: healthz OK"

DEPLOY_LOCK_HOLDER_ID="deploy:${JANUS_DEPLOY_LOCK_HOLDER:-$(hostname -s 2>/dev/null || hostname)}"
DEPLOY_LOCK_TTL_SEC="${JANUS_DEPLOY_LOCK_TTL:-14400}"   # 4h: build + ship + rollout + waits
# The lock row lives in the LEADER's Postgres. Default that to the master
# ONLY when no operator topology exists at all (env, explicit file, either
# mirror) — a configured topology always wins, and is then required to name
# this conversion's master.
if [ -z "${JANUS_TOPOLOGY_FILE:-}" ] && [ -z "${JANUS_TOPOLOGY_LEADER:-}" ] \
   && [ ! -f "$JANUS_TOPOLOGY_DEV_MIRROR" ] && [ ! -f "$JANUS_TOPOLOGY_CI_MIRROR" ]; then
  JANUS_TOPOLOGY_LEADER="$MASTER_HOST"
fi
_LOCK_LEADER="$(topology_read)" || die "pre-flight: no usable topology for the deploy lock (scripts/lib/janus_topology.sh)"
[ "$_LOCK_LEADER" = "$MASTER_HOST" ] \
  || die "pre-flight: topology leader '$_LOCK_LEADER' != this conversion's master '$MASTER_HOST' — convert against the current leader"
log "   deploy lock leader: $_LOCK_LEADER ($(topology_source))"
_lrc=0
deploy_lock_acquire "$DEPLOY_LOCK_HOLDER_ID" "$DEPLOY_LOCK_TTL_SEC" || _lrc=$?
case "$_lrc" in
  0) : ;;
  4)
    log "FAIL: deploy lock is held by another deploy or promote (F4.1). If the holder is stale, wait for TTL expiry (${DEPLOY_LOCK_TTL_SEC}s backstop) or break glass with deploy_prod.sh --force-lock."
    exit 4 ;;
  *) die "cannot acquire the deploy lock (leader Postgres on '$_LOCK_LEADER' unreachable?)" ;;
esac
# L3: the rotated cluster cookie and the fleet CA private key are live
# secrets inside the artifact tree — shred them on the way out, success or
# failure. Both the unlock and the shred live in ONE handler: a second
# `trap ... EXIT` would silently replace the lock release. A non-zero exit
# also emits the rollback material (M2), so `set -e` aborts get the recipe.
cleanup_on_exit() {
  local rc=$?
  deploy_lock_release || true
  [ "$rc" -eq 0 ] || rollback_hint
  local f
  for f in "$ART/.cookie.hex" "$ART/tls/ca-key.pem"; do
    [ -e "$f" ] || continue
    shred -u "$f" 2>/dev/null || rm -f "$f"
  done
}
trap cleanup_on_exit EXIT
log "   deploy lock: held by $DEPLOY_LOCK_HOLDER_ID (ttl ${DEPLOY_LOCK_TTL_SEC}s, released on exit)"

# ---- 1. cookie + shared fleet TLS (all SANs on every leaf) ----
log "== 1. generate cookie + fleet CA/leaves =="
COOKIE=$(openssl rand -hex 32 | tr -d '\n\r')
[ "${#COOKIE}" -eq 64 ] || die "cookie length ${#COOKIE} != 64"
printf '%s' "$COOKIE" >"$ART/.cookie.hex"
chmod 600 "$ART/.cookie.hex"
echo "cookie_hex_len=${#COOKIE}" >"$ART/cookie-meta.txt"

TLS="$ART/tls"
mkdir -p "$TLS"
cat >"$TLS/ca.cnf" <<'EOF'
[req]
distinguished_name = req_dn
x509_extensions = v3_ca
prompt = no
[req_dn]
CN = janus-mw-prod-ca
[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyCertSign,cRLSign
EOF
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TLS/ca-key.pem" -out "$TLS/ca.pem" \
  -days 3650 -config "$TLS/ca.cnf" >/dev/null 2>&1
SAN="subjectAltName=$(printf 'DNS:%s' "$ALL_NODES" | sed 's/,/,DNS:/g')"
printf '%s\nextendedKeyUsage=serverAuth,clientAuth\nbasicConstraints=CA:FALSE\n' "$SAN" >"$TLS/san.ext"
openssl req -newkey rsa:2048 -nodes \
  -keyout "$TLS/node-key.pem" -out "$TLS/node.csr" \
  -subj "/CN=janus-mw-prod" >/dev/null 2>&1
openssl x509 -req -in "$TLS/node.csr" \
  -CA "$TLS/ca.pem" -CAkey "$TLS/ca-key.pem" -CAcreateserial \
  -out "$TLS/node.pem" -days 3650 -extfile "$TLS/san.ext" >/dev/null 2>&1
chmod 600 "$TLS/ca-key.pem" "$TLS/node-key.pem"
rm -f "$TLS/node.csr" "$TLS/ca.cnf"
openssl x509 -in "$TLS/node.pem" -noout -ext subjectAltName >"$ART/tls-san.txt"
log "   SAN written to $ART/tls-san.txt"

# ---- 2. build + ship gateway image ----
log "== 2. build gateway image ($SHIP_PLATFORM) =="
renew_deploy_lock "image build"
# Provenance (review M1): the image used to be built with no JANUS_GIT_SHA,
# so every node answered /stats/sched with git_sha=unknown and a mixed-image
# fleet was undetectable. Mirror deploy_prod.sh: resolve the gateway HEAD,
# refuse a dirty tree unless JANUS_DEPLOY_ALLOW_DIRTY=1 (an uncommitted tree
# is not a provenance record), and stamp it into the image.
GW_SHA="$(git -C "$GW_SRC" rev-parse HEAD 2>/dev/null || true)"
if [ -z "$GW_SHA" ]; then
  log "   WARN: cannot resolve gateway HEAD (not a git tree?) — stamping JANUS_GIT_SHA=unknown"
  GW_SHA="unknown"
fi
GW_DIRTY="$(git -C "$GW_SRC" status --porcelain 2>/dev/null || true)"
if [ -n "$GW_DIRTY" ] && [ "${JANUS_DEPLOY_ALLOW_DIRTY:-0}" != "1" ]; then
  log "FAIL: refusing to build — gateway tree is DIRTY (git status --porcelain non-empty):"
  log "$(printf '%s\n' "$GW_DIRTY" | sed 's/^/      /')"
  log "      commit/stash first, or set JANUS_DEPLOY_ALLOW_DIRTY=1 for a deliberate, LOUD override."
  exit 1
fi
if [ -n "$GW_DIRTY" ]; then
  log "   WARN: JANUS_DEPLOY_ALLOW_DIRTY=1 — building an UNCOMMITTED tree (sha=$GW_SHA + local edits)"
fi
log "   gateway provenance: JANUS_GIT_SHA=$GW_SHA"
docker build --platform "$SHIP_PLATFORM" --build-arg JANUS_GIT_SHA="$GW_SHA" -t janus:dashboard "$GW_SRC" >/dev/null
GW_IMAGE_ID="$(docker inspect -f '{{.Id}}' janus:dashboard | tr -d '[:space:]')"
[ -n "$GW_IMAGE_ID" ] || die "cannot read the built image id"
log "   image id: $GW_IMAGE_ID"
docker save janus:dashboard | gzip -1 >"$ART/janus_deploy.tgz"

log "== 2b. capture rollback material (previous image, env, compose, fleet) =="
renew_deploy_lock "rollback material"
# M2 (review): the rollback material used to be created with `|| true` and
# with no record of the previous image, so a failure after the rollout had
# nothing to restore FROM. The running container's image id is the only
# handle on the previous artifact once step 3 retags janus-gw:latest, so it
# is captured BEFORE the ship, and a host whose capture fails is never
# mutated: no rollback material = no rollout.
capture_rollback() {  # $1 = host
  local h="$1" prev bdir
  prev="$(ssh "$h" "docker inspect -f '{{.Image}}' janus" 2>/dev/null | tr -d '[:space:]' || true)"
  [ -n "$prev" ] || die "$h: cannot read the running janus image id — no rollback material, refusing to roll"
  printf '%s\n' "$prev" >"$ART/prev-image-$h"
  # fleet/.env/compose: every copy must succeed and env/compose must be
  # non-empty — the old `|| true` made a partial/missing backup look like
  # success. The fleet lives in a subdir so restoring never copies env.bak
  # into the bind-mounted fleet dir.
  bdir="$(ssh "$h" 'mkdir -p /opt/stacks/janus/fleet
    ts=$(date +%Y%m%d-%H%M%S)
    d=/opt/stacks/janus/fleet.bak-$ts
    mkdir -p "$d/fleet" && cp -a /opt/stacks/janus/fleet/. "$d/fleet/" \
      && cp -a /opt/stacks/janus/.env "$d/env.bak" \
      && cp -a /opt/stacks/janus/docker-compose.yml "$d/compose.bak" \
      && [ -s "$d/env.bak" ] && [ -s "$d/compose.bak" ] && printf "%s\n" "$d"' 2>/dev/null)" \
    || die "$h: rollback backup failed (fleet/.env/docker-compose.yml) — refusing to mutate a host with no rollback path"
  [ -n "$bdir" ] || die "$h: rollback backup path empty"
  printf '%s\n' "$bdir" >"$ART/backup-dir-$h"
  log "   $h: previous image $prev, backup $bdir"
}
: >"$ART/rollback.txt"
{
  echo "# MW deploy rollback material — $ART — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# Order: restore the MASTER first, then the workers (reverse of the rollout)."
} >>"$ART/rollback.txt"
for h in aliyun tencent jdcloud; do
  capture_rollback "$h"
  prev="$(cat "$ART/prev-image-$h")"
  bdir="$(cat "$ART/backup-dir-$h")"
  {
    echo
    echo "## $h  (prev image $prev, backup $bdir)"
    echo "ssh $h 'cp -a $bdir/env.bak /opt/stacks/janus/.env && cp -a $bdir/compose.bak /opt/stacks/janus/docker-compose.yml'"
    echo "ssh $h 'cp -a $bdir/fleet/. /opt/stacks/janus/fleet/'"
    echo "ssh $h 'docker tag $prev janus-gw:latest'"
    echo "ssh $h 'cd /opt/stacks/janus && docker compose up -d --force-recreate janus'"
    if [ "$h" = aliyun ]; then
      echo "ssh aliyun 'cd /opt/stacks/janus && docker compose up -d --force-recreate janus-worker'"
    fi
  } >>"$ART/rollback.txt"
done
log "   rollback recipe: $ART/rollback.txt"

log "== 3. ship image to aliyun/tencent/jdcloud =="
renew_deploy_lock "image ship"
# A bare `wait` returns 0 whatever the children did, so collect the pids: a
# failed `docker load`/`docker tag` on one host was invisible, and that host
# then recreated from its PREVIOUS janus-gw:latest.
SHIP_PIDS=(); SHIP_HOSTS=()
for h in aliyun tencent jdcloud; do
  (cat "$ART/janus_deploy.tgz" | ssh "$h" \
    "docker load >/dev/null 2>&1 && docker tag janus:dashboard janus-gw:latest" \
    && log "   $h: image loaded") &
  SHIP_PIDS+=("$!"); SHIP_HOSTS+=("$h")
done
for i in "${!SHIP_PIDS[@]}"; do
  wait "${SHIP_PIDS[$i]}" || die "${SHIP_HOSTS[$i]}: image load/tag failed — that host still holds its previous image"
done
for h in aliyun tencent jdcloud; do
  verify_loaded_image "$h"
done

# ---- 4. install TLS + rewrite env/compose ----
install_tls() {
  local host="$1"
  # Directory must be traversable by the container `janus` user (uid in
  # image); 0700 root breaks TLS file probes at entrypoint.
  ssh "$host" 'mkdir -p /opt/stacks/janus/fleet && chmod 755 /opt/stacks/janus/fleet'
  scp -q "$TLS/ca.pem" "$TLS/node.pem" "$TLS/node-key.pem" "$host:/opt/stacks/janus/fleet/"
  # The fleet dir is a BIND mount, so Linux preserves the host owner/mode
  # inside the container — and the containers run as the unprivileged
  # `janus` user, NOT as the ssh/root account scp wrote these files as.
  # OTP 27 TLS dist refuses an unreadable keyfile before the first hello, so
  # a 0600 root-owned node-key.pem fails dist on EVERY converted node; 0644
  # makes it readable by the container user. ca-key.pem is never copied to
  # the nodes and stays 0600 here. Alternative: chown to the container uid,
  # which keeps 0600 but hard-codes the image's uid in this script.
  ssh "$host" 'chmod 644 /opt/stacks/janus/fleet/ca.pem /opt/stacks/janus/fleet/node.pem /opt/stacks/janus/fleet/node-key.pem'
}

# Upsert KEY=VAL in remote .env. Only the (non-secret) KEY name travels in
# argv; the VALUE is base64 on the ssh stdin. The remote python reads it from
# a descriptor duplicated BEFORE the heredoc replaces stdin — not from its
# environment — so /proc/<pid>/environ never holds the secret (review M3: the
# ps-safe stdin handshake still exported it into the python env).
env_set() {
  local host="$1" key="$2" val="$3"
  local kb64 vb64
  kb64=$(printf '%s' "$key" | base64 | tr -d '\n')
  vb64=$(printf '%s' "$val" | base64 | tr -d '\n')
  printf '%s\n' "$vb64" | ssh "$host" "KB64='$kb64' python3 - 3<&0 <<'PY'
import base64, os, pathlib
key = base64.b64decode(os.environ['KB64']).decode()
with os.fdopen(3) as fh:
    vb64 = fh.readline().strip()
if not vb64:
    raise SystemExit('env_set: empty value on stdin')
val = base64.b64decode(vb64).decode()
p = pathlib.Path('/opt/stacks/janus/.env')
text = p.read_text() if p.exists() else ''
out, seen = [], False
for line in text.splitlines():
    if line.startswith(key + '='):
        out.append(key + '=' + val)
        seen = True
    else:
        out.append(line)
if not seen:
    out.append(key + '=' + val)
p.write_text('\\n'.join(out) + '\\n')
p.chmod(0o600)
PY"
}

log "== 4. install TLS on all hosts =="
renew_deploy_lock "TLS install"
for h in aliyun tencent jdcloud; do
  install_tls "$h"
  log "   $h: fleet TLS installed"
done

log "== 5. rewrite env (master + workers) =="
renew_deploy_lock "env rewrite"
# Shared cookie + disable signal-fleet on every host.
for h in aliyun tencent jdcloud; do
  env_set "$h" JANUS_ERLANG_COOKIE "$COOKIE"
  env_set "$h" JANUS_FLEET_ENABLED "false"
  env_set "$h" JANUS_FLEET_DIST_PORT "25672"
  env_set "$h" JANUS_FLEET_TLS_DIR "/var/lib/janus/fleet"
done

# Master (aliyun)
env_set aliyun JANUS_ROLE "master"
env_set aliyun JANUS_NODE_NAME "$MASTER_NODE"
env_set aliyun JANUS_FLEET_PEERS "$WORKER_PEERS"
# Clear worker-only keys if previously set. No `-i.bak` (L2): step 2b's
# fleet.bak dir already holds the pre-deploy .env, and a stray .env.bak only
# multiplies the copies of every secret it contains.
ssh aliyun "sed -i -e '/^JANUS_MASTER_NODE=/d' -e '/^JANUS_WORKER_REGION=/d' -e '/^JANUS_WORKER_CAPACITY=/d' /opt/stacks/janus/.env"

# Co-located worker env file (separate from master .env). The cookie is
# appended from stdin — never in argv, where a local or remote `ps` reads it —
# and the remote python reads it from fd 3 (the ssh stdin duplicated before
# the heredoc), so no shell variable or process environment ever holds it.
printf '%s\n' "$COOKIE" | ssh aliyun "python3 - 3<&0 <<'PY'
import os
with os.fdopen(3) as fh:
    ck = fh.readline().strip()
if not ck:
    raise SystemExit('.env.worker: empty cookie on stdin')
p = '/opt/stacks/janus/.env.worker'
with open(p, 'a') as fh:
    fh.write('JANUS_ERLANG_COOKIE=%s\n' % ck)
os.chmod(p, 0o600)
PY"

# Remote workers
for pair in "tencent:${W_TENCENT_NODE}" "jdcloud:${W_JDCLOUD_NODE}"; do
  h="${pair%%:*}"
  node="${pair##*:}"
  env_set "$h" JANUS_ROLE "worker"
  env_set "$h" JANUS_NODE_NAME "$node"
  env_set "$h" JANUS_MASTER_NODE "$MASTER_NODE"
  env_set "$h" JANUS_FLEET_PEERS "$MASTER_NODE"
  # Workers need no catalog/DB — drop DB host so a misconfig cannot write.
  # No `-i.bak` (L2): step 2b already holds the pre-deploy .env; a .env.bak
  # here would keep the master's DB password on a worker.
  ssh "$h" "sed -i -e '/^JANUS_DB_HOST=/d' -e '/^JANUS_DB_PORT=/d' -e '/^JANUS_DB_USER=/d' -e '/^JANUS_DB_PASSWORD=/d' -e '/^JANUS_DB_NAME=/d' -e '/^JANUS_MODEL_SYNC_/d' /opt/stacks/janus/.env"
done

log "== 6. rewrite compose files =="
renew_deploy_lock "compose rewrite"
# Aliyun: master (+ dashboard unchanged) + co-located worker
ssh aliyun 'cat > /opt/stacks/janus/docker-compose.yml <<'\''YAML'\''
services:
  janus:
    image: janus-gw:latest
    pull_policy: never
    container_name: janus
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./sys.config:/opt/janus/releases/0.1.0/sys.config:ro
      - ./fleet:/var/lib/janus/fleet:ro
      - ./docker-entrypoint.sh:/docker-entrypoint.sh:ro
    networks: [caddy-net, db-net]
    ports:
      - "127.0.0.1:48080:8080"
      - "127.0.0.1:48090:8090"
      - "25672:25672"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8080/healthz >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }

  janus-worker:
    image: janus-gw:latest
    pull_policy: never
    container_name: janus-worker
    hostname: janus-worker.aliyun.mw
    # Map master DNS to the master container IP (refreshed at rollout).
    # IP literals cannot be overridden via /etc/hosts — master MUST be a DNS name.
    extra_hosts:
      - "${MASTER_DNS}:HOST_MASTER_IP"
    restart: unless-stopped
    env_file: .env.worker
    volumes:
      - ./sys.config:/opt/janus/releases/0.1.0/sys.config:ro
      - ./fleet:/var/lib/janus/fleet:ro
      - ./docker-entrypoint.sh:/docker-entrypoint.sh:ro
    networks:
      caddy-net:
        aliases: [janus-worker.aliyun.mw]
    # Dist only on the docker network — do NOT publish 25672 (master owns host :25672).
    healthcheck:
      test: ["CMD-SHELL", "pidof beam.smp >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }

  dashboard:
    image: janus-dashboard:latest
    pull_policy: never
    container_name: janus-dashboard
    restart: unless-stopped
    env_file: .env
    networks: [caddy-net, db-net]
    healthcheck:
      test: ["CMD-SHELL", "python -c \"import urllib.request;urllib.request.urlopen('\''http://127.0.0.1:8091/api/health'\'')\" || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 10s
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }

networks:
  caddy-net:
    external: true
  db-net:
    external: true
YAML'

# Remote workers: no agent ports, publish dist only
for h in tencent jdcloud; do
  ssh "$h" 'cat > /opt/stacks/janus/docker-compose.yml <<'\''YAML'\''
services:
  janus:
    image: janus-gw:latest
    pull_policy: never
    container_name: janus
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./sys.config:/opt/janus/releases/0.1.0/sys.config:ro
      - ./fleet:/var/lib/janus/fleet:ro
      - ./docker-entrypoint.sh:/docker-entrypoint.sh:ro
    networks: [caddy-net]
    ports:
      - "25672:25672"
    healthcheck:
      test: ["CMD-SHELL", "pidof beam.smp >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }

networks:
  caddy-net:
    external: true
YAML'
  log "   $h: worker compose written"
done

# M2 (review M4): pin the dist publish when the operator set a bind address.
# The mapping is written as the bare "25672:25672" above (docker binds
# 0.0.0.0), so rewrite exactly that one line per host and prove the rewrite
# landed — a silent no-op here would ship the world-reachable mapping while
# the operator believes it is pinned.
if [ -n "$DIST_BIND" ]; then
  for h in aliyun tencent jdcloud; do
    ssh "$h" "sed -i 's|^      - \"25672:25672\"\$|      - \"${DIST_BIND}:25672:25672\"|' /opt/stacks/janus/docker-compose.yml"
    ssh "$h" "grep -qx '      - \"${DIST_BIND}:25672:25672\"' /opt/stacks/janus/docker-compose.yml" \
      || die "$h: cannot pin the dist publish to ${DIST_BIND} (compose mapping not rewritten)"
  done
  log "   dist :25672 pinned to ${DIST_BIND} on all hosts"
fi

# Sync entrypoint from local gateway (image also has one; bind-mount overrides).
scp -q "$GW_SRC/docker-entrypoint.sh" aliyun:/opt/stacks/janus/docker-entrypoint.sh
scp -q "$GW_SRC/docker-entrypoint.sh" tencent:/opt/stacks/janus/docker-entrypoint.sh
scp -q "$GW_SRC/docker-entrypoint.sh" jdcloud:/opt/stacks/janus/docker-entrypoint.sh
ssh aliyun 'chmod +x /opt/stacks/janus/docker-entrypoint.sh'
ssh tencent 'chmod +x /opt/stacks/janus/docker-entrypoint.sh'
ssh jdcloud 'chmod +x /opt/stacks/janus/docker-entrypoint.sh'

log "== 7. rollout: master first, then workers =="
renew_deploy_lock "rollout"

# Refresh the co-located worker's pinned master address (extra_hosts). The
# master's caddy-net IP is EPHEMERAL: it must be re-pinned from the address
# the just-recreated master actually holds. The conversion-day sed only knew
# the HOST_MASTER_IP placeholder, so later runs left a stale IP behind and
# the worker could no longer resolve the master at all.
pin_master_ip() {  # $1 = host, $2 = master container IP
  ssh "$1" "python3 - '$2' <<'PY'
import re, sys
p = '/opt/stacks/janus/docker-compose.yml'
text = open(p).read()
new, n = re.subn(r'(janus\.master\.cn:)[0-9A-Za-z_.-]+', r'\g<1>' + sys.argv[1], text)
if n != 1:
    sys.exit('extra_hosts pin for the master origin not found (matches=%d) in %s' % (n, p))
open(p, 'w').write(new)
PY"
}

ssh aliyun 'cd /opt/stacks/janus && docker compose up -d --force-recreate --remove-orphans janus' \
  >"$ART/logs/aliyun-master-up.txt" 2>&1 || die "aliyun master recreate failed"
for i in $(seq 1 60); do
  if ssh aliyun 'curl -s -m 2 http://127.0.0.1:48080/healthz' >/dev/null 2>&1; then
    log "   aliyun master: healthy"
    break
  fi
  sleep 2
  [ "$i" -eq 60 ] && die "aliyun master healthz timeout"
done
verify_node_image aliyun janus

# The co-located worker is a second service in aliyun's compose project and
# must be recreated with the master: the normal ship path (deploy_prod.sh)
# only recreates `janus`, which leaves this worker on the conversion-day
# artifact forever.
if host_has_service aliyun janus-worker; then
  MASTER_CIP="$(ssh aliyun 'docker inspect -f "{{(index .NetworkSettings.Networks \"caddy-net\").IPAddress}}" janus' 2>/dev/null || true)"
  [ -n "$MASTER_CIP" ] || die "aliyun: cannot read the master's caddy-net address"
  pin_master_ip aliyun "$MASTER_CIP"
  log "   leader worker extra_hosts -> ${MASTER_DNS}:${MASTER_CIP}"
  ssh aliyun 'cd /opt/stacks/janus && docker compose up -d --force-recreate janus-worker' \
    >"$ART/logs/aliyun-worker-up.txt" 2>&1 || die "aliyun worker recreate failed"
  verify_node_image aliyun janus-worker
  log "   aliyun worker: recreated"
fi

for h in tencent jdcloud; do
  ssh "$h" 'cd /opt/stacks/janus && docker compose up -d --force-recreate --remove-orphans janus' \
    >"$ART/logs/${h}-up.txt" 2>&1 || die "$h recreate failed"
  verify_node_image "$h" janus
  log "   $h: worker recreated"
  # A host may also carry a co-located janus-worker (a second service in the
  # same project): recreate it when present, never leave it behind.
  if host_has_service "$h" janus-worker; then
    ssh "$h" 'cd /opt/stacks/janus && docker compose up -d --force-recreate janus-worker' \
      >"$ART/logs/${h}-worker-up.txt" 2>&1 || die "$h janus-worker recreate failed"
    verify_node_image "$h" janus-worker
    log "   $h: co-located janus-worker recreated"
  fi
done

log "== 8. wait for janus_workers_available >= 3 =="
renew_deploy_lock "worker registration wait"
# Token stays on the remote host and reaches curl on stdin (-H @-), never argv.
# L4: strip surrounding quotes — a quoted .env value produced `Bearer "…"`,
# a 401, and a 180 s "workers_available stuck" misdiagnosis of a healthy
# fleet. Same extraction as deploy_prod.sh:1054.
gauge=""
for i in $(seq 1 90); do
  body=$(ssh aliyun 'STATS=$(grep "^JANUS_STATS_TOKEN=" /opt/stacks/janus/.env | cut -d= -f2- | tr -d "\"'\''"); [ -n "$STATS" ] || exit 1; printf "Authorization: Bearer %s\n" "$STATS" | curl -s -m 5 -H @- http://127.0.0.1:48090/metrics' 2>/dev/null || true)
  gauge=$(printf '%s' "$body" | awk '
    /^janus_workers_available\{/ || /^janus_workers_available / {
      for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+(\.[0-9]+)?$/) { print int($i); exit }
    }')
  if [ -n "${gauge:-}" ] && [ "$gauge" -ge 3 ]; then
    log "   workers_available=$gauge (>=3) after ${i}s×2"
    break
  fi
  sleep 2
  if [ "$i" -eq 90 ]; then
    ssh aliyun 'docker logs --tail 80 janus' >"$ART/logs/aliyun-master.log" 2>&1 || true
    ssh aliyun 'docker logs --tail 80 janus-worker' >"$ART/logs/aliyun-worker.log" 2>&1 || true
    ssh tencent 'docker logs --tail 80 janus' >"$ART/logs/tencent-worker.log" 2>&1 || true
    ssh jdcloud 'docker logs --tail 80 janus' >"$ART/logs/jdcloud-worker.log" 2>&1 || true
    redact_logs "$COOKIE"
    die "workers_available stuck at '${gauge:-missing}' (want >=3); logs in $ART/logs"
  fi
done
echo "workers_available=$gauge" >"$ART/workers_available.txt"

log "== 9. capture /stats/sched snapshot (redacted) =="
ssh aliyun 'STATS=$(grep "^JANUS_STATS_TOKEN=" /opt/stacks/janus/.env | cut -d= -f2- | tr -d "\"'\''"); printf "Authorization: Bearer %s\n" "$STATS" | curl -s -m 5 -H @- http://127.0.0.1:48090/stats/sched' \
  >"$ART/stats-sched.json" 2>/dev/null || true
# Strip any accidental cookie substrings
redact_logs "$COOKIE"

log "== done =="
log "artifacts: $ART"
log "topology: master=$MASTER_NODE workers=$WORKER_PEERS"
log "NEXT: read-only curl live-check against the MW plane (see AGENTS.md Verification)"
log "ACTION REQUIRED: the follower origins no longer serve local :8080 —"
log "  point their Caddy/DNS entries at the master (the master origin) before the cutover"
log "  is announced. Rollback recipe (if needed): $ART/rollback.txt"
echo "$ART"
