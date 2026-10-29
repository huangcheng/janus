#!/usr/bin/env bash
# deploy_fleet.sh — generic rolling deploy for bare-metal Janus gateway nodes.
#
# Standalone: lives in the gateway repo, needs only the inventory file and
# ssh access. Ships NOTHING but the gateway release (no dashboard, no local
# gate — compose those yourself; this script does one job safely).
#
# Every hard gate below exists because its absence once broke production:
#   stamp-or-refuse    a stale tarball once shipped under a new sha's name
#   wipe-before-extract layering a new release over an old tree left mixed
#                      binaries that answered /stats with the WRONG git_sha
#   env keyring gate   a truncated base64 (missing '=') once passed Erlang's
#                      lenient decoder and broke every strict consumer
#   ssh retries        transient sshd resets once aborted deploys mid-step
#   bash -c remote     root login shells are not always bash (zsh globs)
#   verify-then-roll   a node that boots the wrong sha halts the rollout
#                      instead of quietly serving old code
#
# Usage:
#   scripts/deploy_fleet.sh [--sha <commit>] [--nodes a,b,c] [--build-on <alias>]
#                           [--skip-build] [--rollback] [--dry-run]
#                           [--force-lock] [--allow-dirty]
#
#   --sha <commit>    commit to deploy (default: this repo's HEAD)
#   --nodes <list>    inventory aliases (default: every runtime=bare node)
#   --build-on <a>    build the release once on node <a>, relay the tarball
#                     to the others (for nodes without git or docker)
#   --skip-build      reuse the artifact already on each node for this sha
#   --rollback        flip every node back to the sha recorded at rollout
#                     start (the state file this run wrote)
#   --dry-run         print the plan, change nothing
#   --force-lock      break a stale deploy lock (audited)
#   --allow-dirty     permit a dirty working tree (still refuses unknown sha)
#
# Exit codes: 0 ok; 2 usage/inventory error; 3 lock held; 4 node failure
# (rollout aborts; nodes already flipped stay on the new sha — re-run or
# --rollback).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---- defaults -------------------------------------------------------------
SHA_ARG="" NODES_ARG="" BUILD_ON="" SKIP_BUILD=0 ROLLBACK=0 DRY=0 FORCE=0 DIRTY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) SHA_ARG="${2:?}"; shift 2 ;;
    --sha=*) SHA_ARG="${1#*=}"; shift ;;
    --nodes) NODES_ARG="${2:?}"; shift 2 ;;
    --nodes=*) NODES_ARG="${1#*=}"; shift ;;
    --build-on) BUILD_ON="${2:?}"; shift 2 ;;
    --build-on=*) BUILD_ON="${1#*=}"; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --force-lock) FORCE=1; shift ;;
    --allow-dirty) DIRTY=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ---- inventory (the ONLY place fleet specifics live) ----------------------
INV="${JANUS_INVENTORY:-${REPO_ROOT}/deploy/inventory.env}"
[ -f "${INV}" ] || { echo "FAIL: inventory not found: ${INV}" >&2; exit 2; }
# shellcheck disable=SC1090
. "${INV}"
: "${JANUS_BARE_PREFIX:?JANUS_BARE_PREFIX missing in inventory}"
: "${JANUS_BARE_USER:?JANUS_BARE_USER missing in inventory}"
: "${JANUS_MASTER_REF:?JANUS_MASTER_REF missing in inventory}"
PREFIX="${JANUS_BARE_PREFIX}"; BUSER="${JANUS_BARE_USER}"
STATE_DIR="${TEMP:-/tmp}/janus-deploy-fleet"

die() { echo "FAIL: $*" >&2; exit "${2:-4}"; }
note() { echo "   $*"; }

# ---- resolve the sha (never deploy an unknown commit) --------------------
cd "${REPO_ROOT}"
if [ -n "${SHA_ARG}" ]; then
  SHA="$(git rev-parse --verify --quiet "${SHA_ARG}^{commit}" || true)"
  [ -n "${SHA}" ] || die "cannot resolve --sha ${SHA_ARG} in this repo" 2
else
  SHA="$(git rev-parse HEAD 2>/dev/null || true)"
  [ -n "${SHA}" ] || die "not a git repo and no --sha given" 2
fi
SHA8="$(git rev-parse --short=8 "${SHA}")"
if [ "${DIRTY}" -ne 1 ] && [ -z "${SHA_ARG}" ] \
   && [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
  die "working tree dirty (uncommitted code once shipped as a 'clean' build); commit first or --allow-dirty" 2
fi
echo "== deploy_fleet: sha ${SHA8} (${SHA}) =="

# ---- node list from the inventory ----------------------------------------
ALL_NODES=""
node_field() { # $1=var-name $2=field
  printf '%s' "${!1}" | tr ';' '\n' | sed -n "s/^${2}=//p" | head -n1
}
mapfile -t NODE_VARS < <(grep -oE '^JANUS_NODE_[A-Za-z0-9]+=' "${INV}" | sed 's/=$//')
declare -A N_ALIAS N_ROLE N_RUNTIME
for v in "${NODE_VARS[@]}"; do
  spec="${!v}"
  alias="$(node_field "${v}" alias)"
  role="$(node_field "${v}" role)"
  runtime="$(node_field "${v}" runtime)"
  [ -n "${alias}" ] || die "${v} has no alias= field" 2
  [ -n "${runtime}" ] || die "${v} has no runtime= field" 2
  N_ALIAS["${alias}"]="${alias}"; N_ROLE["${alias}"]="${role}"
  N_RUNTIME["${alias}"]="${runtime}"
  ALL_NODES="${ALL_NODES} ${alias}"
done
MASTER_ALIAS="$(node_field "JANUS_NODE_${JANUS_MASTER_REF}" alias)"
[ -n "${MASTER_ALIAS}" ] || die "leader ${JANUS_MASTER_REF} missing alias" 2

if [ -n "${NODES_ARG}" ]; then
  TARGETS="$(echo "${NODES_ARG}" | tr ',' ' ')"
  # Doctrine: a node is runtime=docker OR runtime=bare, never both.
  # An explicit --nodes selection used to bypass the runtime filter
  # entirely — deploying bare units onto a docker node runs a
  # duplicate gateway under the SAME node name (the 2026-10-25
  # identity-flap incident). Hard-refuse the mix; docker nodes deploy
  # through the dashboard image pipeline, not this script.
  for a in ${TARGETS}; do
    [ "${N_RUNTIME[${a}]:-}" = "bare" ] || \
      die "node '${a}' is runtime=${N_RUNTIME[${a}]:-?} in inventory — this deployer is bare-only (docker nodes ship via the dashboard image pipeline); refusing to mix runtimes on one node" 2
  done
else
  TARGETS=""
  for a in ${ALL_NODES}; do
    [ "${N_RUNTIME[${a}]}" = "bare" ] && TARGETS="${TARGETS} ${a}"
  done
fi
for a in ${TARGETS}; do
  [ -n "${N_ALIAS[${a}]:-}" ] || die "node '${a}' not in inventory" 2
done
# leader first among the SELECTED targets only (--nodes is authoritative)
ORDERED=""
case " ${TARGETS} " in *" ${MASTER_ALIAS} "*) ORDERED="${MASTER_ALIAS}";; esac
for a in ${TARGETS}; do [ "${a}" != "${MASTER_ALIAS}" ] && ORDERED="${ORDERED} ${a}"; done
ORDERED="$(echo "${ORDERED}" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
[ -n "$(echo ${ORDERED})" ] || die "no bare nodes selected" 2
echo "   nodes (leader first): ${ORDERED}"

# ---- ssh helpers ----------------------------------------------------------
# ssh_run retries CONTROL commands (idempotent, output not consumed as
# data). Data-bearing pipes MUST use ssh_once: a retried data stream
# concatenates two partial outputs and silently corrupts the payload.
ssh_run() { # $1=alias, rest=script text
  local h="$1"; shift
  local try
  for try in 1 2 3; do
    if ssh -o BatchMode=yes -o ConnectTimeout=15 "${h}" "bash -c '$(printf '%s' "$*" | sed "s/'/'\\\\''/g")'"; then
      return 0
    fi
    echo "   ssh ${h} attempt ${try} failed — retrying in 5s" >&2
    sleep 5
  done
  return 1
}
ssh_once() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$1" "bash -c '$(printf '%s' "$2" | sed "s/'/'\\\\''/g")'"; }

# ---- deploy lock (Postgres row CAS via the leader) -----------------------
LOCK_HOLDER="fleet:$(hostname -s 2>/dev/null || hostname):$$"
lock_release() { ssh_run "${MASTER_ALIAS}" \
  "docker exec -i postgres psql -U janus -d janus -c \"DELETE FROM deploy_locks WHERE holder = '${LOCK_HOLDER}'\"" >/dev/null 2>&1 || true; }
if [ "${DRY}" -ne 1 ]; then
  CUR="$(ssh_run "${MASTER_ALIAS}" \
    "docker exec postgres psql -U janus -d janus -t -A -c \"SELECT holder || '|' || (expires_at <= now()) FROM deploy_locks WHERE id = 1\"" || true)"
  case "${CUR}" in
    ""|"|t"|"|true") : ;;  # absent or expired
    *"|f"|*"|false")
      if [ "${FORCE}" -ne 1 ]; then
        echo "FAIL: deploy lock held by ${CUR%%|*} — --force-lock to break (audited)" >&2
        exit 3
      fi
      echo "   AUDIT: force-breaking lock held by ${CUR%%|*}" >&2 ;;
    *) : ;;
  esac
  ssh_run "${MASTER_ALIAS}" \
    "docker exec postgres psql -U janus -d janus -c \"INSERT INTO deploy_locks (id, holder, expires_at) VALUES (1, '${LOCK_HOLDER}', now() + interval '2 hours') ON CONFLICT (id) DO UPDATE SET holder = EXCLUDED.holder, acquired_at = now(), expires_at = EXCLUDED.expires_at WHERE deploy_locks.expires_at <= now()\"" >/dev/null
  trap lock_release EXIT
fi

# ---- build (node-local git) or relay --------------------------------------
BUILDER="${JANUS_BARE_BUILDER:-erlang:27}"
build_on_node() { # $1=alias -> prints tarball path on that node
  local h="$1" var="JANUS_NODE_GIT_$(echo "$1" | tr 'a-z' 'A-Z')"
  local remote="${!var:-${JANUS_GW_GIT_REMOTE:-}}"
  [ -n "${remote}" ] || die "no git remote for ${h} (set ${var} or --build-on)" 2
  ssh_run "${h}" "
    set -e
    mkdir -p ${PREFIX}/src
    if [ ! -d ${PREFIX}/src/janus/.git ]; then git clone -q '${remote}' ${PREFIX}/src/janus; fi
    cd ${PREFIX}/src/janus
    git fetch -q origin '${SHA}' || git fetch -q origin
    git checkout -q --detach '${SHA}'
    [ \"\$(git rev-parse HEAD)\" = '${SHA}' ] || { echo 'checkout mismatch' >&2; exit 1; }
    JANUS_BARE_BUILDER='${BUILDER}' bash scripts/build_bare_release.sh >/tmp/fleet-build.log 2>&1 \\
      || { tail -5 /tmp/fleet-build.log >&2; exit 1; }
    ls -1 \"\${PWD}\"/bare-artifacts/gw/janus-bare-${SHA8}.tar.gz
  " || die "build failed on ${h}"
}

RELAY_TARBALL=""
if [ "${ROLLBACK}" -ne 1 ] && [ "${SKIP_BUILD}" -ne 1 ] && [ -n "${BUILD_ON}" ]; then
  echo "== building once on ${BUILD_ON} =="
  RELAY_TARBALL="$(build_on_node "${BUILD_ON}")"
  note "artifact: ${RELAY_TARBALL}"
  [ "${DRY}" -eq 1 ] || ssh_run "${BUILD_ON}" "md5sum '${RELAY_TARBALL}'" | awk '{print $1}' > "${STATE_DIR}/relay.md5"
fi

ship_and_extract() { # $1=alias — extract the sha's tarball into every tree
  local h="$1" trees tb
  [ "${N_ROLE[${h}]}" = "leader" ] && trees="${PREFIX}/gateway ${PREFIX}/worker" || trees="${PREFIX}/worker"
  if [ "${h}" = "${BUILD_ON}" ]; then
    # the builder node uses its own artifact in place — no relay loop
    tb="${RELAY_TARBALL}"
  elif [ -n "${RELAY_TARBALL}" ]; then
    # chunked relay: each chunk is its own file (a retry overwrites the
    # chunk cleanly); end-to-end md5 is the authority.
    ssh_run "${h}" "rm -rf /tmp/fleet-relay-* && mkdir -p /tmp/fleet-relay"
    local n=0 ok=0
    while :; do
      n=$((n + 1))
      for try in 1 2 3; do
        if ssh_once "${BUILD_ON}" "dd if='${RELAY_TARBALL}' bs=4M skip=$((n-1)) count=1 2>/dev/null | base64 -w0" \
            | base64 -d | ssh_once "${h}" "cat > /tmp/fleet-relay/part-${n}"; then ok=1; break; fi
        echo "   relay chunk ${n} to ${h} attempt ${try} failed — retrying" >&2
        sleep 3
      done
      [ "${ok}" -eq 1 ] || die "relay chunk ${n} to ${h}"
      if [ "$(ssh_run "${h}" "stat -c%s /tmp/fleet-relay/part-${n}")" = "0" ]; then
        ssh_run "${h}" "rm -f /tmp/fleet-relay/part-${n}"; break
      fi
    done
    ssh_run "${h}" "cat /tmp/fleet-relay/part-* > /tmp/janus-bare-${SHA8}.tar.gz && rm -rf /tmp/fleet-relay && md5sum /tmp/janus-bare-${SHA8}.tar.gz" \
      | awk '{print $1}' > "${STATE_DIR}/got-${h}.md5"
    cmp -s "${STATE_DIR}/relay.md5" "${STATE_DIR}/got-${h}.md5" || die "relay md5 mismatch on ${h}"
    tb="/tmp/janus-bare-${SHA8}.tar.gz"
  else
    tb="$(ssh_run "${h}" "ls -1 ${PREFIX}/src/janus/bare-artifacts/gw/janus-bare-${SHA8}.tar.gz 2>/dev/null | head -1")"
    [ -n "${tb}" ] || die "no artifact for ${SHA8} on ${h} (run without --skip-build / --build-on)"
  fi
  for tree in ${trees}; do
    ssh_run "${h}" "
      set -e
      rm -rf ${tree}/${SHA8}
      mkdir -p ${tree}/${SHA8}
      tar -xzf '${tb}' -C ${tree}/${SHA8} --strip-components=1
      chown -R ${BUSER}:${BUSER} ${tree}/${SHA8}
      # STAMP-OR-REFUSE: the wrapper must carry the exact sha, else the
      # artifact is stale/mislabeled and must never reach 'current'.
      # (The rendered wrapper stamps UNQUOTED; accept either shape.)
      grep -qE \"JANUS_GIT_SHA='?${SHA}'?\" ${tree}/${SHA8}/bin/janus \\
        || { echo \"stamp mismatch in ${tree}/${SHA8}\" >&2; exit 1; }
    " || die "extract/verify failed on ${h} (${tree})"
  done
  note "${h}: extracted + stamp-verified into ${trees}"
}

# ---- env keyring gate (strict decode BEFORE any restart) -----------------
keyring_gate() { # $1=alias
  ssh_run "$1" "
    f=${PREFIX}/env/janus-gw.env
    [ -f \"\${f}\" ] || exit 0
    python3 - <<'PY'
import base64, re, sys
line = [l for l in open('/opt/janus/env/janus-gw.env') if l.startswith('JANUS_SECRETS_KEY=')]
if not line: sys.exit(0)
v = line[0].split('=', 1)[1].strip()
ok = any(len(base64.b64decode(p.split(':', 1)[1], validate=True)) == 32
         for p in v.split(',') if ':' in p)
sys.exit(0 if ok else 1)
PY
    [ \$? -eq 0 ] || { echo 'JANUS_SECRETS_KEY fails strict base64 decode (truncated?)' >&2; exit 1; }
  " || die "keyring gate failed on $1 — fix the env file before restarting"
}

# ---- flip + restart + verify ---------------------------------------------
flip_node() { # $1=alias
  local h="$1" trees units
  [ "${N_ROLE[${h}]}" = "leader" ] && trees="${PREFIX}/gateway ${PREFIX}/worker" || trees="${PREFIX}/worker"
  units="janus-gw"
  ssh_run "${h}" "[ -e /etc/systemd/system/janus-gw-local.service ] && echo local || true" | grep -q local && units="${units} janus-gw-local"
  # record the pre-flip state for --rollback ("<alias> <tree> <prev>")
  for tree in ${trees}; do
    prev="$(ssh_run "${h}" "readlink ${tree}/current 2>/dev/null || true")"
    echo "${h} ${tree} ${prev}" >> "${STATE_DIR}/rollback-${SHA8}.txt"
  done
  [ "${DRY}" -eq 1 ] && { note "${h}: DRY — would flip ${trees} -> ${SHA8} and restart ${units}"; return 0; }
  for tree in ${trees}; do
    ssh_run "${h}" "ln -sfn ${SHA8} ${tree}/current" || die "flip failed ${h} ${tree}"
  done
  # keyring gate: refuse to restart onto a broken env file
  keyring_gate "${h}"
  for u in ${units}; do
    ssh_run "${h}" "systemctl restart ${u}" || die "restart ${u} failed on ${h}"
  done
  sleep 5
  for u in ${units}; do
    # Restart=on-failure may need a second boot (dist reconnect race);
    # poll through the crash-restart window instead of sampling once.
    ok=""
    for i in $(seq 1 15); do
      st="$(ssh_run "${h}" "systemctl is-active ${u}" || true)"
      [ "${st}" = "active" ] && { ok=1; break; }
      sleep 3
    done
    [ -n "${ok}" ] || die "${u} not active on ${h} (last: ${st:-unreachable})"
  done
  verify_node "${h}"
  note "${h}: ${SHA8} live (${units})"
}

verify_node() { # $1=alias — the master /stats/sched must answer the sha
  local h="$1" i body
  for i in $(seq 1 30); do
    body="$(ssh_run "${MASTER_ALIAS}" \
      "T=\$(sed -n 's/^JANUS_STATS_TOKEN=//p' ${PREFIX}/env/janus-gw.env); curl -fsS -m 5 -H \"Authorization: Bearer \$T\" http://127.0.0.1:8090/stats/sched" || true)"
    [ -n "${body}" ] || { sleep 2; continue; }
    if printf '%s' "${body}" | grep -q "\"git_sha\":\"${SHA}\""; then
      # every worker on THIS host must be up on the new sha
      addr="$(grep -oE "^JANUS_NODE_ADDR_$(echo "${h}" | tr 'a-z' 'A-Z')=.*" "${INV}" | cut -d= -f2)"
      bad="$(printf '%s' "${body}" | grep -o "\"node\":\"[^\"]*\"" | grep -c "${addr}" || true)"
      [ "${bad:-0}" -ge 1 ] || { note "${h}: worker row not visible yet (master-only node?)"; return 0; }
      return 0
    fi
    sleep 2
  done
  die "verify: /stats/sched never reported ${SHA8} on ${MASTER_ALIAS} after ${h} restart"
}

# ---- rollback -------------------------------------------------------------
# The state file records "<alias> <tree> <prev-sha8>" per flip; rollback
# replays every line (flip back + restart), leader first, then verifies
# the pre-sha answers on /stats.
if [ "${ROLLBACK}" -eq 1 ]; then
  RB="$(ls -1t "${STATE_DIR}"/rollback-*.txt 2>/dev/null | head -1)"
  [ -n "${RB}" ] || die "no rollback state under ${STATE_DIR} (written at each rollout)" 2
  echo "== rolling back per ${RB} =="
  [ "${DRY}" -eq 1 ] && { cat "${RB}"; echo "== dry run — no changes =="; exit 0; }
  DONE_HOSTS=""
  while read -r h tree prev; do
    [ -n "${h}" ] && [ -n "${tree}" ] && [ -n "${prev}" ] || continue
    case " ${DONE_HOSTS} " in *" ${h} "*) ;; *)
      DONE_HOSTS="${DONE_HOSTS} ${h}" ;;
    esac
    ssh_run "${h}" "ln -sfn ${prev} ${tree}/current" || die "rollback flip failed ${h} ${tree}"
    note "${h}: ${tree} -> ${prev}"
  done < "${RB}"
  for h in ${DONE_HOSTS}; do
    ssh_run "${h}" "systemctl restart janus-gw; [ -e /etc/systemd/system/janus-gw-local.service ] && systemctl restart janus-gw-local || true" || true
    ssh_run "${h}" "systemctl is-active janus-gw" | grep -q active || die "rollback: janus-gw not active on ${h}"
    note "${h}: restarted on rollback target"
  done
  echo "== rollback done (verify /stats git_sha on the leader) =="
  exit 0
fi

# ---- plan / execute -------------------------------------------------------
mkdir -p "${STATE_DIR}"
echo "== plan =="
for h in ${ORDERED}; do
  role="${N_ROLE[${h}]:-follower}"
  echo "   ${h} (${role}, ${N_RUNTIME[${h}]})"
done
[ "${DRY}" -eq 1 ] && { echo "== dry run — no changes =="; exit 0; }

for h in ${ORDERED}; do
  echo "== ${h} =="
  if [ "${SKIP_BUILD}" -ne 1 ] && [ -z "${RELAY_TARBALL}" ]; then
    build_on_node "${h}" >/dev/null
    note "${h}: built ${SHA8}"
  fi
  ship_and_extract "${h}"
  flip_node "${h}"
done
echo "== deploy_fleet: ${SHA8} live on ${ORDERED} =="
