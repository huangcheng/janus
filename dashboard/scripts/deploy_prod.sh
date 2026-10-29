#!/usr/bin/env bash
# Build, gate on the LOCAL e2e suite, then deploy to the three
# production nodes and run a READ-ONLY smoke check.
#
#   bash scripts/deploy_prod.sh             # full pipeline
#   bash scripts/deploy_prod.sh --skip-gate # deploy without rerunning the local gate
#   bash scripts/deploy_prod.sh --smoke-only# skip deploy, only the read-only smoke
#   bash scripts/deploy_prod.sh --code-only # force code-only verification (uptime window)
#   bash scripts/deploy_prod.sh --plan      # DRY RUN: print the deploy plan (topology
#                                           # leader, followers, lock state, images)
#                                           # and EXIT 0 — no SSH required, no mutation
#   bash scripts/deploy_prod.sh --init-topology aliyun ...  # first-run bootstrap of the
#                                           # operator-side topology mirrors (H3-D7)
#   bash scripts/deploy_prod.sh --force-lock ...  # break-glass past a held deploy lock
#                                           # (audited; see F4.1)
#
# ---- bare-metal runtime dispatch (spec
# docs/superpowers/specs/2026-10-15-bare-metal-deploy.md, Task 3:
# B-D5 + B-D8) ----
# Per-node runtime comes from the INVENTORY (the janus repo's
# deploy/inventory.env — ONE canonical file both repos resolve; NO
# inventory file at all = pure docker fleet, today's pipeline, zero
# change). When an inventory is present it is the SINGLE WRITER for
# per-node runtime/role (B-D5: the H3-D7 topology keeps only the
# leader pointer; drift between the two leaders REFUSES — a promote
# updates both in one scripted step). Dispatch per node:
#   runtime=docker  today's path unchanged (docker save | ssh load,
#                   compose up -d --force-recreate)
#   runtime=bare    rsync the release tarball (-> $JANUS_BARE_PREFIX/
#                   gw/<sha>/) + `current` symlink swap + systemctl
#                   restart janus-gw; FIRST bare deploy on a node (no
#                   janus-gw unit) runs the janus repo's
#                   a fresh bare bootstrap (env + TLS + unit). Compose
#                   actions are HARD-REFUSED for bare nodes (F1 layer
#                   2). Same deploy lock, same topology, same
#                   mmdb/backup integration (the bare leader's mmdb
#                   lands in $JANUS_BARE_PREFIX/shared/geo/ — where the
#                   F2-generated envfile already points JANUS_MMDB_PATH).
#   dashboard       the leader runs the BARE dashboard only when it is
#                   runtime=bare AND inventory JANUS_DASH_BARE=true
#                   (the Task-1/2 seam): scripts/build_bare_dashboard.sh
#                   payload + scripts/install_bare_dashboard.sh. Any
#                   other leader keeps the docker dashboard image path.
# Pre-ship gate (B-D8): when ANY inventory node is bare, this run's
# artifacts (its own shas) boot in throwaway containers first —
# janus-repo scripts/verify_bare.sh + scripts/verify_bare_dashboard.sh
# here — and a failure REFUSES the ship. Skipped entirely for
# docker-only fleets.
#
# Topology + deploy lock (spec 2026-10-15-maturity-hardening H3-D7,
# H3-D3, H4-D1, F4.1): the LEADER host is read from the operator-side
# topology file (scripts/lib/janus_topology.sh — $JANUS_TOPOLOGY_FILE,
# else ~/.janus/topology, else /opt/janus-ci/topology; never a silent
# leader default — REFUSES with a --init-topology hint when missing).
# Before anything ships: (0) the named leader must answer a healthz
# probe over SSH (a topology naming a fenced/dead leader refuses with a
# promote-in-progress hint — H3-D7 limbo guard), and (1) the REPLICATED
# deploy_locks row CAS lock is acquired on the leader's Postgres
# (deploy:<this-host>, TTL 4h, released in an EXIT trap) so a CI deploy
# and a manual deploy can never interleave; a held lock refuses with the
# current holder. Exit codes: 2 topology missing/invalid, 3 leader
# probe dead, 4 lock held.
#
# GeoLite2 (master only): step 3b runs scripts/ensure_master_mmdb.sh
# when JANUS_MAXMIND_ACCOUNT_ID + JANUS_MAXMIND_LICENSE_KEY are set
# (or in ${TEMP}/janus_prod_secrets.json). Skip with JANUS_DEPLOY_SKIP_MMDB=1.
# If settings.sched.geo=true and mmdb_present is still false after recreate,
# the deploy HALTS.
#
# Rule (AGENTS.md "Verification"): this repo ships NO test suites —
# pages are verified by browsing them, APIs by curl live-checks. The
# deploy's own net is the migration-verified rolling rollout below plus
# the read-only curl smoke in step 8; production is never mutated by
# verification.
#
# Observability-depth deploy note (2026-10): ship the gateway BEFORE the
# dashboard — migration 021 adds usage_events.failover_reason/trace_id +
# usage_events_trace_id_idx, and the dashboard's timeline API reads those
# columns (it probes and degrades gracefully on a pre-021 schema, but the
# pinned order keeps the surface complete from the first request). At
# current volume the migration's plain CREATE INDEX takes a sub-second
# write lock; if usage_events ever grows to millions of rows, pre-build
# the index on the leader BEFORE the rolling deploy:
#
#   CREATE INDEX CONCURRENTLY IF NOT EXISTS usage_events_trace_id_idx
#     ON usage_events (trace_id);
#
# The migration's IF NOT EXISTS then no-ops against the pre-built index.
#
# Slice D — post-restart follower verification (gateway repo docs/
# superpowers/specs/2026-10-05-next-phase-design.md §4.4), inserted
# between the leader migration check and the dashboard/smoke steps:
#
#   * Ship class. `--code-only` forces code-only; otherwise it is
#     auto-detected from the marker file ${TEMP:-/tmp}/
#     janus_last_deploy_head (the gateway repo HEAD recorded after each
#     successful deploy). Marker present AND `git diff <marked>..HEAD --
#     apps/janus_core/priv config` empty (no config, priv/catalog, or
#     schema-migration changes — migrations live under
#     apps/janus_core/priv/migrations) means the ship cannot change the
#     catalog: code-only. Missing/unreadable marker or any such diff
#     means a full generation wait (safe default).
#
#   * Generation mode (config ships). BEFORE any image is shipped or
#     any node restarts, the script captures gen0 from the dashboard DB
#     (config_meta.config_generation). After the topology LEADER is
#     healthy and its migration is verified, the LEADER generation is
#     captured once via /stats and MUST be >= gen0 (catalog applied).
#     Followers then need generation > gen0 OR == captured leader
#     generation. The deploy itself never writes config.
#
#   * Follower wait. After both followers (followers) restart and
#     pass /healthz, each is polled on /stats every
#     JANUS_DEPLOY_POLL_INTERVAL seconds (default 2) in PARALLEL under
#     one shared JANUS_DEPLOY_WAIT_DEADLINE second budget (default 300).
#     Success requires the per-class condition on TWO CONSECUTIVE polls:
#       - generation mode: follower generation > gen0 OR == captured
#         leader generation (catalog re-applied after restart);
#       - code-only mode: EVERY node (leader included) uptime_sec <
#         seconds since script start AND docker inspect Image id matches
#         the shipped janus:dashboard id.
#     Transient HTTP errors (non-200, timeouts) retry until the
#     deadline; HTTP 401 is a hard failure. Node stats endpoints come
#     from gateway_nodes (stats_host, stats_port) on the leader Postgres
#     (stats_host may be a bare host or a full origin with scheme);
#     missing stats_host for any fleet host HALTS unless
#     JANUS_DEPLOY_STATS_VIA_SSH=1. Direct HTTP is tried first and falls
#     back to `ssh <host> curl http://127.0.0.1:48090/stats` when direct
#     fails. JANUS_DEPLOY_STATS_VIA_SSH=1 forces ssh mode.
#
#   * Follower hard-halt. On deadline/401 for followers, logs are saved
#     and the deploy HALTS before the dashboard ship (no rollback, no
#     skip) — the same contract as the leader. A deliberate
#     drift-tolerant run may set JANUS_DEPLOY_ALLOW_FOLLOWER_DRIFT=1:
#     it continues to step 7 + smoke but still exits non-zero at the
#     end. Leader /stats failure always hard-halts. Empty
#     JANUS_STATS_TOKEN at the wait stage hard-halts immediately.
#
#   * Worker followers (JANUS_ROLE=worker) have no host /stats face —
#     verification is master /stats/sched registration (JSON parse), not
#     generation. Mis-detecting them as masters burns the 300s budget on
#     a port that does not exist (workers also lack curl for the
#     docker-exec fallback).
#
#   * A host whose compose also defines the co-located `janus-worker`
#     (the MW conversion, scripts/deploy_mw_prod.sh) recreates that
#     service in the same rollout and asserts BOTH node names in the
#     registration check — the `janus` container env describes only the
#     master, so the second worker used to be invisible to it.
#
#   * On a fully successful deploy the gateway HEAD is (re)written to
#     the marker file for the next run's ship-class detection.
#
# Credentials: exports JANUS_DASH_PASSWORD / JANUS_STATS_TOKEN /
# JANUS_AK or falls back to %TEMP%/janus_prod_secrets.json +
# janus_prod_agent_key.txt laid down by the original deployment.
set -euo pipefail
cd "$(dirname "$0")/.."

SCRIPT_START="$(date +%s)"  # code-only ships compare uptime_sec against this
LAST_DEPLOY_HEAD="${TEMP:-/tmp}/janus_last_deploy_head"

GATE=1; SMOKE_ONLY=0; CODE_ONLY=0; PLAN=0; FORCE_LOCK=0; INIT_TOPOLOGY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-gate) GATE=0 ;;
    --smoke-only) SMOKE_ONLY=1; GATE=0 ;;
    --code-only) CODE_ONLY=1 ;;
    --plan) PLAN=1; GATE=0 ;;
    --force-lock) FORCE_LOCK=1 ;;
    --init-topology) INIT_TOPOLOGY="${2:-}"; shift ;;
    --init-topology=*) INIT_TOPOLOGY="${1#--init-topology=}" ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

# Stats-wait tuning. Defaults preserve the spec'd 2s poll / 300s budget;
# the env overrides exist so an offline harness can exercise the loops
# quickly and are not intended for production use.
POLL_SEC="${JANUS_DEPLOY_POLL_INTERVAL:-2}"
WAIT_DEADLINE="${JANUS_DEPLOY_WAIT_DEADLINE:-300}"
case "$POLL_SEC" in ''|*[!0-9]*) POLL_SEC=2 ;; esac
case "$WAIT_DEADLINE" in ''|*[!0-9]*) WAIT_DEADLINE=300 ;; esac
[ "$POLL_SEC" -ge 1 ] 2>/dev/null || POLL_SEC=2
[ "$WAIT_DEADLINE" -ge 1 ] 2>/dev/null || WAIT_DEADLINE=300

GW_SRC="$(cd ../janus 2>/dev/null && pwd || true)"
if [ -z "$GW_SRC" ]; then GW_SRC="$(dirname "$(pwd)")/janus"; fi

# ---- v2.1 C.3 build provenance: refuse a dirty gateway tree, stamp
# the git SHA into the image (build-arg -> LABEL + ENV -> /stats/sched
# git_sha). The 2026-10-10 incident image was built from a tree with
# UNCOMMITTED code that passed `git diff --quiet` — `git status
# --porcelain` (empty REQUIRED) is the gate; JANUS_DEPLOY_ALLOW_DIRTY=1
# is the loud, deliberate emergency escape.
GW_SHA="$(git -C "$GW_SRC" rev-parse HEAD 2>/dev/null || true)"
if [ -z "$GW_SHA" ]; then
  echo "WARNING: cannot resolve gateway HEAD (not a git tree?) — stamping JANUS_GIT_SHA=unknown" >&2
  GW_SHA="unknown"
fi
GW_DIRTY="$(git -C "$GW_SRC" status --porcelain 2>/dev/null || true)"
if [ -n "$GW_DIRTY" ] && [ "${JANUS_DEPLOY_ALLOW_DIRTY:-0}" != "1" ]; then
  if [ "$PLAN" -eq 1 ]; then
    echo "WARNING (--plan): gateway tree is DIRTY — a real deploy would refuse:" >&2
    printf '%s\n' "$GW_DIRTY" >&2
  else
    echo "FAIL: refusing to deploy — gateway tree is DIRTY (git status --porcelain non-empty):" >&2
    printf '%s\n' "$GW_DIRTY" >&2
    echo "      commit/stash first, or set JANUS_DEPLOY_ALLOW_DIRTY=1 for a deliberate, LOUD override." >&2
    exit 1
  fi
fi
if [ -n "$GW_DIRTY" ] && [ "$PLAN" -eq 0 ]; then
  echo "WARNING: JANUS_DEPLOY_ALLOW_DIRTY=1 — building an UNCOMMITTED tree (sha=$GW_SHA + local edits):" >&2
  printf '%s\n' "$GW_DIRTY" >&2
fi
echo "gateway provenance: JANUS_GIT_SHA=$GW_SHA"

# ---- topology + deploy lock (H3-D7 / H3-D3 / H4-D1 / F4.1) ----
# shellcheck source=scripts/lib/janus_topology.sh
source scripts/lib/janus_topology.sh
# shellcheck source=scripts/lib/janus_deploy_lock.sh
source scripts/lib/janus_deploy_lock.sh

# ---- inventory path (resolved EARLY: it is the source of truth for the
# default fleet below; the per-node validation block further down
# re-sources the same file). CANONICAL file: the JANUS repo's
# deploy/inventory.env — ONE file both repos resolve (Task 3
# consolidation; the dashboard repo's own deploy/inventory.env is a
# legacy fallback, never a second writer).
INV="${JANUS_INVENTORY:-}"
if [ -z "$INV" ]; then
  for _cand in "$GW_SRC/deploy/inventory.env" "deploy/inventory.env"; do
    if [ -f "$_cand" ]; then INV="$_cand"; break; fi
  done
fi

# The fleet (SSH aliases). Leader comes from the operator-side topology
# file — NEVER a hardcoded leader default; followers are every other
# fleet host.
#
# Fleet source (2026-10-22): with JANUS_DEPLOY_HOSTS unset the default is
# DERIVED from the inventory's declared JANUS_NODE_* alias= values, in
# declaration order (= rollout order). The inventory is already the
# SINGLE WRITER for per-node runtime/role (B-D5), so it also owns fleet
# membership: the old hardcoded default drifted from the live fleet (it
# still named hosts that serve no janus container) and every unscoped run
# refused with "fleet hosts missing from the inventory". The hardcoded
# list survives ONLY as the documented last resort for a no-inventory
# (pure docker) fleet; JANUS_DEPLOY_HOSTS always wins when set (explicit
# scope).
LEGACY_DEFAULT_HOSTS="leader-1"
inventory_fleet_aliases() {  # $1 = inventory file -> space-separated alias= list, file order
  local f="$1" v spec alias out=""
  # Sourced inside this command substitution's subshell only: the
  # caller's shell is not polluted, and the validation block below
  # re-sources the file with its own checks.
  # shellcheck disable=SC1090
  . "$f" >/dev/null 2>&1 || {
    echo "FAIL: cannot source the inventory $f — it is the source of truth for the default fleet" >&2
    return 1
  }
  for v in $(grep -oE '^(export )?JANUS_NODE_[A-Za-z0-9]+=' "$f" | sed 's/^export //; s/=$//' | grep -v '^JANUS_NODE_ADDR_'); do
    spec="${!v:-}"
    alias="$(printf '%s' "$spec" | tr ';' '\n' | sed -n 's/^alias=//p' | head -n1)"
    if [ -z "$alias" ]; then
      echo "FAIL: inventory $v carries no alias= — cannot derive the default fleet from $f" >&2
      return 1
    fi
    # Space-separated single line: the callers test membership with
    # `case " $ALL_HOSTS "` and iterate it unquoted.
    out="$out $alias"
  done
  printf '%s' "${out# }"
}
if [ -n "${JANUS_DEPLOY_HOSTS:-}" ]; then
  ALL_HOSTS="$JANUS_DEPLOY_HOSTS"
elif [ -n "$INV" ] && [ -f "$INV" ]; then
  ALL_HOSTS="$(inventory_fleet_aliases "$INV")" || exit 2
  if [ -z "$ALL_HOSTS" ]; then
    # Inventory present but declares no node: keep today's behaviour —
    # the validation block below then refuses, naming every fleet host
    # that the inventory fails to cover.
    ALL_HOSTS="$LEGACY_DEFAULT_HOSTS"
  fi
else
  ALL_HOSTS="$LEGACY_DEFAULT_HOSTS"
fi
# Excluded hosts (operator instruction, 2026-10-22): `contabo` was torn
# down (it hosted the CI Actions runner, uninstalled + deregistered that
# day; a shared runner) and non-janus hosts run unrelated containers —
# neither serves a gateway container, so they are NEVER fleet hosts. The
# filter runs AFTER resolution so neither a stale inventory secret nor an
# explicit JANUS_DEPLOY_HOSTS scope can quietly put them back into a
# rollout: the drop is reported on stderr instead.
EXCLUDED_HOSTS="contabo vultr"
for _ex in $EXCLUDED_HOSTS; do
  case " $ALL_HOSTS " in
    *" $_ex "*)
      echo "   note          : $_ex excluded from the fleet (no gateway container there) — dropped from [$ALL_HOSTS]" >&2
      _kept=""
      for _h in $ALL_HOSTS; do
        [ "$_h" = "$_ex" ] || _kept="$_kept $_h"
      done
      ALL_HOSTS="${_kept# }"
      ;;
  esac
done
if [ -n "$INIT_TOPOLOGY" ]; then
  _existing="$(topology_read 2>/dev/null || true)"
  if [ -z "$_existing" ]; then
    echo "== 0. TOPOLOGY BOOTSTRAP (--init-topology $INIT_TOPOLOGY) =="
    topology_write_leader "$INIT_TOPOLOGY" || exit 2
    LEADER="$INIT_TOPOLOGY"
  elif [ "$_existing" = "$INIT_TOPOLOGY" ]; then
    LEADER="$_existing"   # idempotent re-init
  else
    echo "FAIL: --init-topology $INIT_TOPOLOGY but the topology already names leader '$_existing'." >&2
    echo "      Changing the leader is the H3 promote path (the promote script writes both" >&2
    echo "      mirrors under the deploy lock) — not --init-topology. Fix the mirrors by hand only" >&2
    echo "      as a documented break-glass." >&2
    exit 2
  fi
else
  LEADER="$(topology_read)" || exit 2   # topology_read prints the refuse message
fi
case " $ALL_HOSTS " in
  *" $LEADER "*) : ;;
  *)
    echo "FAIL: topology leader '$LEADER' is not one of the fleet hosts ($ALL_HOSTS)" >&2
    exit 2 ;;
esac
FOLLOWERS=""
for _h in $ALL_HOSTS; do [ "$_h" = "$LEADER" ] || FOLLOWERS="$FOLLOWERS $_h"; done
FOLLOWERS="${FOLLOWERS# }"
echo "topology: leader=$LEADER ($(topology_source)), followers=[$FOLLOWERS]"

# ---- bare-metal inventory (spec 2026-10-15-bare-metal-deploy §0/B-D5) ----
# CANONICAL file: the JANUS repo's deploy/inventory.env — ONE file both
# repos resolve (Task 3 consolidation; the dashboard repo's own
# deploy/inventory.env is a legacy fallback, never a second writer). The
# path was resolved ABOVE (the fleet default is derived from it).
# NO inventory file at all = pure docker fleet: today's pipeline, zero
# change (graceful degradation). When an inventory IS present it is
# the SINGLE WRITER for per-node runtime/role: every fleet host must
# be covered by a JANUS_NODE_<NAME> (matched by alias=), runtimes must
# be docker|bare, and the inventory's role=leader node must AGREE with
# the topology leader (drift means the promote script's scripted xact
# did not run — refuse, never guess). Compose actions are HARD-REFUSED
# for runtime=bare nodes (F1 layer 2).
INVENTORY_PRESENT=0
declare -A NODE_RUNTIME=() NODE_INVNAME=()
BARE_NODES="" DOCKER_NODES="$ALL_HOSTS"
BARE_PREFIX="" BARE_USER="" BARE_AGENT_PORT=8080 BARE_ADMIN_PORT=8090
DASH_BARE_SEAM=false DASH_BARE_SHIP=0
GW_TARBALL="" BARE_SHA_DIR="" DASH_PAYLOAD=""
# Git-ship-only knobs (B-D5): the git-ship branch further down assigns
# these, but the NON-git path reads them as well — under `set -u` the
# unguarded reads aborted a bare deploy whenever that branch was skipped
# ("SKIP_LOCAL_BUILD: unbound variable", 2026-10-22). `: "${VAR:=...}"`
# is a no-op default; the branch's own assignment stays authoritative.
: "${SKIP_LOCAL_BUILD:=}"
: "${UNIT_DST_ON_NODE:=/etc/systemd/system/janus-gw.service}"
if [ -n "$INV" ] && [ -f "$INV" ]; then
  INVENTORY_PRESENT=1
  # shellcheck disable=SC1090
  . "$INV"
  _inv_leader="" _leader_count=0
  for _var in $(grep -oE '^(export )?JANUS_NODE_[A-Za-z0-9]+=' "$INV" | sed 's/^export //; s/=$//' | grep -v '^JANUS_NODE_ADDR_'); do
    _spec="${!_var:-}"
    _alias="$(printf '%s' "$_spec" | tr ';' '\n' | sed -n 's/^alias=//p' | head -n1)"
    _role="$(printf '%s' "$_spec" | tr ';' '\n' | sed -n 's/^role=//p' | head -n1)"
    _rt="$(printf '%s' "$_spec" | tr ';' '\n' | sed -n 's/^runtime=//p' | head -n1)"
    case "$_rt" in docker|bare) ;;
      *)
        echo "FAIL: inventory ${_var} has runtime='${_rt}' (must be docker|bare) — fix $INV" >&2
        exit 2 ;;
    esac
    case " $ALL_HOSTS " in
      *" $_alias "*)
        if [ -n "${NODE_RUNTIME[$_alias]+x}" ]; then
          echo "FAIL: inventory lists alias '$_alias' more than once ($INV) — one JANUS_NODE_* per fleet host" >&2
          exit 2
        fi
        NODE_RUNTIME["$_alias"]="$_rt"
        NODE_INVNAME["$_alias"]="${_var#JANUS_NODE_}"
        if [ "$_role" = leader ]; then _inv_leader="$_alias"; _leader_count=$((_leader_count + 1)); fi
        ;;
      *) : ;;  # node outside this deploy's fleet (e.g. JANUS_DEPLOY_HOSTS subset): informational only
    esac
  done
  _uncovered=""
  for _h in $ALL_HOSTS; do
    [ -n "${NODE_RUNTIME[$_h]+x}" ] || _uncovered="$_uncovered $_h"
  done
  if [ -n "$_uncovered" ]; then
    echo "FAIL: fleet hosts missing from the inventory:$_uncovered" >&2
    echo "      the inventory ($INV) is the SINGLE WRITER for per-node runtime (B-D5) — add" >&2
    echo "      JANUS_NODE_<NAME> alias= entries for every fleet host, or remove the file" >&2
    echo "      entirely for a pure docker fleet." >&2
    exit 2
  fi
  if [ "$_leader_count" -ne 1 ] || [ "$_inv_leader" != "$LEADER" ]; then
    echo "FAIL: inventory leader ('${_inv_leader:-none}', $_leader_count leader role(s)) != topology leader '$LEADER' — drift." >&2
    echo "      A promote updates the topology mirrors AND the inventory role fields in ONE" >&2
    echo "      scripted step (B-D5/H3-D7) — run the promote path; never resolve drift by hand." >&2
    exit 2
  fi
  BARE_NODES="" DOCKER_NODES=""
  for _h in $ALL_HOSTS; do
    if [ "${NODE_RUNTIME[$_h]}" = bare ]; then BARE_NODES="$BARE_NODES $_h"; else DOCKER_NODES="$DOCKER_NODES $_h"; fi
  done
  BARE_NODES="${BARE_NODES# }"; DOCKER_NODES="${DOCKER_NODES# }"
  if [ -n "$BARE_NODES" ]; then
    BARE_PREFIX="${JANUS_BARE_PREFIX:-}"
    BARE_USER="${JANUS_BARE_USER:-}"
    if [ -z "$BARE_PREFIX" ] || [ -z "$BARE_USER" ]; then
      echo "FAIL: bare nodes ([$BARE_NODES]) but JANUS_BARE_PREFIX/JANUS_BARE_USER missing in $INV (refuse-on-missing, spec §0)" >&2
      exit 2
    fi
    _ports="${JANUS_GW_PORTS:-8080,8090}"
    BARE_AGENT_PORT="${_ports%%,*}"
    BARE_ADMIN_PORT="$(printf '%s' "$_ports" | cut -d, -f2)"
    [ -n "$BARE_ADMIN_PORT" ] || BARE_ADMIN_PORT=8090
  fi
  DASH_BARE_SEAM="${JANUS_DASH_BARE:-false}"
  if [ "${NODE_RUNTIME[$LEADER]:-docker}" = bare ] && [ "$DASH_BARE_SEAM" = true ]; then
    DASH_BARE_SHIP=1
  fi
  echo "inventory: $INV"
  printf 'runtimes :'
  for _h in $ALL_HOSTS; do printf ' %s=%s' "$_h" "${NODE_RUNTIME[$_h]}"; done
  echo
  if [ -n "$BARE_NODES" ]; then
    echo "bare fleet: [$BARE_NODES] — rsync ship + systemctl restart; compose actions REFUSED (F1 layer 2)"
  fi
  if [ "$DASH_BARE_SEAM" = true ] && [ "$DASH_BARE_SHIP" -eq 0 ]; then
    echo "JANUS_DASH_BARE=true but the leader $LEADER is runtime=docker — the dashboard stays on the docker path until the leader flips"
  fi
fi

# Runtime helpers (B-D5). node_runtime answers "" for uncovered hosts —
# callers treat everything non-bare as docker (the no-inventory default).
node_runtime() {  # $1 = fleet host -> docker|bare
  if [ "$INVENTORY_PRESENT" -eq 1 ] && [ -n "${NODE_RUNTIME[$1]+x}" ]; then
    printf '%s' "${NODE_RUNTIME[$1]}"
  else
    printf docker
  fi
}
is_bare() { [ "$(node_runtime "$1")" = bare ]; }
refuse_compose() {  # $1 = host, $2 = action — F1 layer 2 hard refuse
  if is_bare "$1"; then
    echo "FAIL: refusing compose action '$2' on $1 — inventory runtime=bare (F1 layer 2," >&2
    echo "      spec 2026-10-15-bare-metal-deploy). Bare nodes roll via rsync + systemctl" >&2
    echo "      first deploy: the roll step bootstraps the unit directly (no migration exists)." >&2
    exit 1
  fi
}
# Runtime-aware leader healthz probe (the lib's topology_probe_leader
# only knows the docker-published 48080 + in-container faces; a BARE
# leader binds the inventory JANUS_GW_PORTS directly).
probe_leader_healthz() {  # $1 = host
  if is_bare "$1"; then
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$1" \
      "curl -s -m 3 http://127.0.0.1:$BARE_AGENT_PORT/healthz >/dev/null 2>&1 ||
       systemctl is-active --quiet janus-gw" >/dev/null 2>&1
  else
    topology_probe_leader "$1"
  fi
}

# ---- pre-flight (H3-D7 probe + F4.1 lock): SHIP paths only (never in
# --plan — a plan is read-only and must not acquire/mutate anything) ----
if [ "$SMOKE_ONLY" -eq 0 ] && [ "$PLAN" -eq 0 ]; then
  echo "== 0. PRE-FLIGHT: leader probe + deploy lock =="
  if ! probe_leader_healthz "$LEADER"; then
    echo "FAIL: PRE-FLIGHT leader probe — '$LEADER' did not answer healthz over SSH." >&2
    echo "      If a master promote is (or was) in progress, the topology may name a fenced or" >&2
    echo "      dead leader (H3-D7 limbo): verify the topology mirrors ($(topology_source)) and" >&2
    echo "      either wait for the promote to finish or repair the topology. Refusing to ship." >&2
    exit 3
  fi
  echo "   leader $LEADER: healthz OK"
  DEPLOY_LOCK_HOLDER_ID="deploy:${JANUS_DEPLOY_LOCK_HOLDER:-$(hostname -s 2>/dev/null || hostname)}"
  DEPLOY_LOCK_TTL_SEC="${JANUS_DEPLOY_LOCK_TTL:-14400}"   # 4h: gate (~2h) + build + ship + waits
  if [ "$FORCE_LOCK" -eq 1 ]; then
    _cur="$(deploy_lock_status 2>/dev/null || true)"
    _cur_holder="$(printf '%s' "$_cur" | cut -d'|' -f1)"
    case "$_cur" in FREE*|UNREADABLE*)
      echo "AUDIT: --force-lock requested but the deploy lock is not held ($_cur) — nothing to break" ;;
    *)
      deploy_lock_force_release "$_cur_holder" || exit 1 ;;
    esac
  fi
  deploy_lock_acquire "$DEPLOY_LOCK_HOLDER_ID" "$DEPLOY_LOCK_TTL_SEC" || _lrc=$?
  case "${_lrc:-0}" in
    0) : ;;
    4)
      echo "FAIL: deploy lock is held by another deploy or promote (F4.1). If the holder is stale/dead," >&2
      echo "      wait for TTL expiry ($DEPLOY_LOCK_TTL_SEC s backstop) or break glass with --force-lock (audited)." >&2
      exit 4 ;;
    *) exit 1 ;;
  esac
  deploy_lock_release_on_exit() {
    deploy_lock_release || true
  }
  trap deploy_lock_release_on_exit EXIT
fi

# H1 (F4.1 hardening): the lock is re-asserted at every phase boundary.
# A single acquire with a fixed expires_at can be outlived by a slow run
# (gate + CN mirror + waits); once the row expires the CAS lets a second
# deploy take it over, so continuing to roll nodes without a re-assert is
# exactly when two deploys overlap. Renewal both extends our TTL and
# proves the row is still ours — a lost lock aborts before more nodes
# are touched. No-op for --plan / --smoke-only (no lock is held).
renew_deploy_lock() {  # $1 = phase label
  [ -n "${DEPLOY_LOCK_HOLDER:-}" ] || return 0
  deploy_lock_renew "$DEPLOY_LOCK_TTL_SEC" || {
    echo "FAIL: deploy lock renewal failed at '$1' — this deploy no longer owns the lock;" >&2
    echo "      another deploy may have taken it over after TTL expiry. Aborting BEFORE touching more nodes." >&2
    exit 5
  }
}

# ---- prod credentials (SKIPPED in --plan: a plan is read-only and must
# run on hosts without prod secrets — the CI runner first-ship dry run) ----
if [ "$PLAN" -eq 0 ]; then
# (the secrets JSON at ${TEMP:-/tmp}/janus_prod_secrets.json is read
# inline by prod_env below; AGENT_KEY_FILE feeds the JANUS_AK export)
AGENT_KEY_FILE="${TEMP:-/tmp}/janus_prod_agent_key.txt"
# Windows exposes python.exe as `python`; macOS/Linux as `python3`.
PY3="$(command -v python3 || command -v python || true)"
prod_env() { "$PY3" - "$1" <<'PY'
import json, os, sys
p = os.path.join(os.environ.get("TEMP", "/tmp"), "janus_prod_secrets.json")
try:
    print(json.load(open(p))[sys.argv[1]])
except Exception:
    print("")
PY
}
export JANUS_DASH="${JANUS_DASH:-https://gw.example.invalid}"
export JANUS_DASH_PASSWORD="${JANUS_DASH_PASSWORD:-$(prod_env DASH_PASSWORD)}"
export JANUS_STATS_TOKEN="${JANUS_STATS_TOKEN:-$(prod_env STATS_TOKEN)}"
export JANUS_AK="${JANUS_AK:-$(cat "$AGENT_KEY_FILE" 2>/dev/null || true)}"
if [ -z "$JANUS_DASH_PASSWORD" ] || [ -z "$JANUS_STATS_TOKEN" ] || [ -z "$JANUS_AK" ]; then
  echo "missing prod credentials (JANUS_DASH_PASSWORD / JANUS_STATS_TOKEN / JANUS_AK)"; exit 1
fi
# Keyring for decrypting per-node stats tokens (dashboard .env). Not a
# credential for production — only used locally by node_stats_token.
if [ -z "${JANUS_SECRETS_KEY:-}" ] && [ -f .env ]; then
  JANUS_SECRETS_KEY="$(grep '^JANUS_SECRETS_KEY=' .env | cut -d= -f2- || true)"
fi
fi  # end PLAN=0 credentials guard

# Local e2e gate removed (2026-10-18): the repo no longer ships a test
# suite — pages are verified by browsing them and APIs by curl live-checks
# (AGENTS.md "Verification"). The deploy's own safety net is the
# migration-verified rolling rollout below plus the read-only curl smoke
# in step 8. --skip-gate is accepted and ignored for muscle memory.
if [ "$GATE" -eq 1 ]; then
  echo "== 1. LOCAL GATE: skipped (removed 2026-10-18; verification is browser + curl live-checks) =="
fi

wait_gateway_healthy() {  # $1 = host, $2 = timeout seconds
  # Role-aware: masters publish 48080->8080 on the host; WORKERS
  # publish only the dist port (agent :8080 skipped by design) —
  # fall back to the in-container healthz, then the docker
  # healthcheck status (the container carries one). BARE nodes
  # (B-D5) bind the inventory JANUS_GW_PORTS directly: masters answer
  # healthz on the agent port; bare workers publish nothing by design,
  # so an ACTIVE unit is their success signal (pool registration is
  # asserted separately by wait_worker_registered).
  local h="$1" t="${2:-90}" i=0
  if is_bare "$h"; then
    local role
    role="$(node_role "$h" 2>/dev/null || echo unknown)"
    while [ "$i" -lt "$t" ]; do
      if ssh "$h" "curl -s -m 2 http://127.0.0.1:$BARE_AGENT_PORT/healthz >/dev/null 2>&1" 2>/dev/null; then
        return 0
      fi
      if [ "$role" = worker ] \
         && ssh "$h" 'systemctl is-active --quiet janus-gw' 2>/dev/null; then
        return 0
      fi
      sleep 2; i=$((i+2))
    done
    return 1
  fi
  while [ "$i" -lt "$t" ]; do
    if ssh "$h" 'curl -s -m 2 http://127.0.0.1:48080/healthz >/dev/null 2>&1 ||
         docker exec janus curl -s -m 2 http://127.0.0.1:8080/healthz >/dev/null 2>&1 ||
         [ "$(docker inspect --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" janus 2>/dev/null)" = "healthy" ]' 2>/dev/null; then
      return 0
    fi
    sleep 2; i=$((i+2))
  done
  return 1
}

# ================== Slice D: stats verification helpers ==================

# Local JSON parser for /stats bodies (jq is not assumed to exist).
# Windows venv layouts ship Scripts/python.exe; macOS/Linux bin/python.
if [ -n "${JANUS_DEPLOY_PYTHON:-}" ]; then
  PY="$JANUS_DEPLOY_PYTHON"
elif [ -x ./.venv/Scripts/python.exe ]; then
  PY=./.venv/Scripts/python.exe
else
  PY=./.venv/bin/python
fi

stats_field() {  # $1 = JSON body, $2 = key; prints value or nothing
  printf '%s' "$1" | "$PY" -c 'import json,sys
try:
    d = json.loads(sys.stdin.read() or "{}")
    v = d.get(sys.argv[1])
    sys.stdout.write("" if v is None else str(v))
except Exception:
    pass' "$2" 2>/dev/null || true
}

# Sets SHIP_CLASS to "config" or "code-only". Anything that cannot be
# proven code-only falls back to the full generation wait.
detect_ship_class() {
  if [ "$CODE_ONLY" -eq 1 ]; then SHIP_CLASS="code-only"; return 0; fi
  if ! command -v git >/dev/null 2>&1 \
     || ! git -C "$GW_SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    SHIP_CLASS="config"; return 0
  fi
  if [ ! -f "$LAST_DEPLOY_HEAD" ]; then
    SHIP_CLASS="config"; return 0  # no previous-deploy marker: safe default
  fi
  local marked
  marked="$(head -n1 "$LAST_DEPLOY_HEAD" 2>/dev/null || true)"
  if [ -z "$marked" ] \
     || ! git -C "$GW_SRC" rev-parse --verify --quiet "${marked}^{commit}" >/dev/null 2>&1; then
    SHIP_CLASS="config"; return 0  # unreadable/gone marker: safe default
  fi
  # apps/janus_core/priv covers the catalog priv payload AND
  # priv/migrations/postgres (new schema migrations); config covers
  # sys.config + vm.args. Any change there can bump the generation.
  # The shipped image is built from the WORKING TREE, so uncommitted
  # edits to these paths must classify as config too (a committed-ref
  # diff alone would silently skip the generation wait).
  local committed dirty
  committed="$(git -C "$GW_SRC" diff --name-only "${marked}" HEAD -- apps/janus_core/priv config 2>/dev/null || true)"
  dirty="$(git -C "$GW_SRC" status --porcelain -- apps/janus_core/priv config 2>/dev/null || true)"
  if [ -z "$committed" ] && [ -z "$dirty" ]; then
    SHIP_CLASS="code-only"
  else
    SHIP_CLASS="config"
  fi
}

leader_psql() {  # $1 = SQL; prints psql -t -A rows from the LEADER Postgres
  # Single seam: topology_psql (SSH to the topology leader's postgres
  # container; JANUS_DEPLOY_PG overrides for local proofs).
  topology_psql "$1"
}

# NODE_STATS is "name|stats_host|stats_port|stats_token_hex" per enabled
# gateway_nodes row (token field empty when the node uses the global one).
node_stats_field() {  # $1 = node name, $2 = host | port | token
  printf '%s\n' "$NODE_STATS" | awk -F'|' -v n="$1" -v f="$2" \
    '$1 == n { print (f == "host" ? $2 : (f == "port" ? $3 : $4)); exit }'
}

# node_stats_token NODE_NAME -> prints the node's own stats token
# (decrypted from the hex JSEC envelope via the dashboard keyring in
# .env) or falls back to the global JANUS_STATS_TOKEN.
node_stats_token() {
  local hex tok
  hex="$(node_stats_field "$1" token)"
  if [ -n "$hex" ] && [ -n "${PY:-}" ]; then
    tok="$(JANUS_SECRETS_KEY="${JANUS_SECRETS_KEY:-}" "$PY" -c '
from app.crypto import decrypt
import sys
try:
    sys.stdout.write(decrypt(bytes.fromhex(sys.argv[1])).decode())
except Exception:
    sys.exit(1)
' "$hex" 2>/dev/null || true)"
    if [ -n "$tok" ]; then printf '%s' "$tok"; return 0; fi
    echo "   WARN: per-node token for $1 undecryptable; using global token" >&2
  fi
  printf '%s' "${JANUS_STATS_TOKEN:-}"
}

stats_url() {  # $1 = stats_host (bare host or full origin), $2 = port, $3 = path
  local h="$1"
  case "$h" in
    http://*|https://*)
      while [ "${h%/}" != "$h" ]; do h="${h%/}"; done
      printf '%s%s\n' "$h" "$3" ;;
    *) if [ -n "$2" ]; then printf 'http://%s:%s%s\n' "$1" "$2" "$3"
       else printf 'http://%s%s\n' "$1" "$3"; fi ;;
  esac
}

# stats_probe MODE SSHHOST URL TOKEN -> sets PROBE_CODE (000 = transport
# error) and PROBE_BODY. MODE "direct" curls URL locally; MODE "ssh"
# curls 127.0.0.1:48090 on SSHHOST (loopback admin-plane face; the
# data plane sits on 48080 and has no /stats route).
# SSH mode reads JANUS_STATS_TOKEN from the node's /opt/stacks/janus/.env
# (same source the container itself uses) so a stale/mismatched local
# deploy-host token cannot false-401 a healthy leader right after recreate.
stats_probe() {
  local out="$1" host="$2" url="$3" tok="${4:-$JANUS_STATS_TOKEN}" code
  PROBE_CODE="000"; PROBE_BODY=""
  if [ "$out" = "ssh" ]; then
    if is_bare "$host"; then
      # Bare (B-D5): no docker-published 48090 / in-container face.
      # Loopback admin plane on the inventory port; token from the
      # generated EnvironmentFile (same source the unit runs under).
      # H3: the token goes to curl on STDIN (-H @-) so it never appears
      # in curl's argv (readable by any local user via ps/proc).
      out="$(ssh "$host" 'STATS=$(sed -n "s/^JANUS_STATS_TOKEN=//p" '"$BARE_PREFIX"'/env/janus-gw.env 2>/dev/null); printf "Authorization: Bearer %s\n" "$STATS" | curl -s -m 5 -w "\n%{http_code}" -H @- http://127.0.0.1:'"$BARE_ADMIN_PORT"'/stats' 2>/dev/null || true)"
    else
    # Masters publish 48090->8090 on the host; WORKERS do not
    # (dist port only) — fall back to the in-container admin
    # listener for worker-role followers. Token comes from the remote
    # .env so it matches the running container regardless of what the
    # deploy host has exported.
    # Strip surrounding quotes — Docker env-file load does; bare grep|cut does not.
    # H3: stdin (-H @-) on both attempts, host argv and container argv.
    out="$(ssh "$host" 'STATS=$(grep ^JANUS_STATS_TOKEN= /opt/stacks/janus/.env | cut -d= -f2- | tr -d "\"'\''"); printf "Authorization: Bearer %s\n" "$STATS" | curl -s -m 5 -w "\n%{http_code}" -H @- http://127.0.0.1:48090/stats 2>/dev/null || { printf "Authorization: Bearer %s\n" "$STATS" | docker exec -i janus curl -s -m 5 -w "\n%{http_code}" -H @- http://127.0.0.1:8090/stats; }' 2>/dev/null || true)"
    fi
  else
    # H3: pipe the header instead of passing it as an argv element.
    out="$(printf 'Authorization: Bearer %s\n' "$tok" | curl -s -m 5 -w '\n%{http_code}' -H @- "$url" 2>/dev/null || true)"
  fi
  case "$out" in
    *$'\n'*)
      code="${out##*$'\n'}"      # curl -w appends the code after the body
      case "$code" in
        [0-9][0-9][0-9]) PROBE_CODE="$code"; PROBE_BODY="${out%$'\n'*}" ;;
      esac ;;
  esac
}

# node_stats_once SSHHOST STATS_HOST STATS_PORT -> 0 when an HTTP response
# arrived (PROBE_CODE/PROBE_BODY set), 1 on transport failure. Uses and
# updates STATS_MODE (direct|ssh): direct is tried first (unless forced
# or the node has no usable record) and the probe falls back to ssh.
node_stats_once() {
  local host="$1" shost="$2" sport="$3" tok url
  tok="$(node_stats_token "$host")"
  # Loopback stats_hosts (the bare-era default) are only reachable
  # FROM that node: skip the doomed direct probe from the deploy host.
  case "$shost" in
    127.0.0.1|localhost|::1|"[::1]") STATS_MODE="${STATS_MODE:-ssh}" ;;
  esac
  if [ "${STATS_MODE:-direct}" != "ssh" ] && [ -n "$shost" ]; then
    url="$(stats_url "$shost" "$sport" /stats)"
    stats_probe direct "$host" "$url" "$tok"
    if [ "$PROBE_CODE" != "000" ]; then return 0; fi
    # direct HTTP from the deploy host failed: fall back to ssh
  fi
  stats_probe ssh "$host" "" "$tok"
  if [ "$PROBE_CODE" != "000" ]; then STATS_MODE=ssh; return 0; fi
  return 1
}

require_stats_inventory() {
  local h shost missing="" workers=""
  if [ "${JANUS_DEPLOY_STATS_VIA_SSH:-0}" = "1" ]; then return 0; fi
  if [ -z "$(printf '%s' "$NODE_STATS" | tr -d '[:space:]')" ]; then
    echo "FAIL: no enabled gateway_nodes rows (no stats_host); set JANUS_DEPLOY_STATS_VIA_SSH=1 to force ssh loopback"
    exit 1
  fi
  # Topology since the bare worker fleet: only REGISTERED gateways expose an
  # admin plane. The leader must always have a row; a follower with no row is
  # a worker (no :8090) — verified via the master's /stats/sched pool, so it
  # is not a stats-inventory gap.
  for h in $ALL_HOSTS; do
    if ! printf '%s\n' "$NODE_STATS" | awk -F'|' -v n="$h" '$1 == n { found=1 } END { exit !found }'; then
      if [ "$h" = "$LEADER" ]; then
        missing="$missing $h"
      else
        workers="$workers $h"
      fi
      continue
    fi
    shost="$(node_stats_field "$h" host)"
    if [ -z "$shost" ]; then missing="$missing $h"; fi
  done
  [ -z "$workers" ] || echo "   stats inventory: no gateway row for worker-role followers:$workers (verified via master /stats/sched)"
  if [ -n "$missing" ]; then
    echo "FAIL: missing stats_host for:$missing — halt (JANUS_DEPLOY_STATS_VIA_SSH=1 to override)"
    exit 1
  fi
}

verify_node_image() {  # $1 = host, $2 = container (default janus)
  local h="$1" c="${2:-janus}" rid tagid
  # Compare NODE-SIDE: the running container's image id vs the node's
  # janus-gw:latest tag target. Cross-machine id comparison against the
  # local GW_IMAGE_ID is unsound: buildkit-built images re-import with a
  # different id on the node (orbstack/docker-driver save -> classic
  # overlayfs load), which false-FAILs an otherwise correct rollout.
  rid="$(ssh "$h" "docker inspect -f '{{.Image}}' '$c'" 2>/dev/null | tr -d '[:space:]' || true)"
  tagid="$(ssh "$h" "docker image inspect -f '{{.Id}}' janus-gw:latest" 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -z "$rid" ] || [ -z "$tagid" ]; then
    echo "FAIL: $h cannot inspect the $c container or the janus-gw:latest tag"
    collect_node_logs "$h"
    exit 1
  fi
  if [ "$rid" != "$tagid" ]; then
    echo "FAIL: $h $c container image '$rid' != node janus-gw:latest '$tagid'"
    collect_node_logs "$h"
    exit 1
  fi
}

collect_node_logs() {  # $1 = node (ssh host); sets DEPLOY_LOG_DIR on first use
  if [ -z "${DEPLOY_LOG_DIR:-}" ]; then
    # L1: mktemp -d creates 700, so captured journalctl/docker logs (they
    # contain gateway output) are not readable by other local users.
    DEPLOY_LOG_DIR="$(mktemp -d "${TEMP:-/tmp}/janus-deploy-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX" 2>/dev/null)" \
      || DEPLOY_LOG_DIR="$(mktemp -d)"  # ${TEMP} not writable: any local 700 dir beats losing logs
  fi
  # Runtime-aware (B-D5, F6): bare nodes log to journald, not docker.
  if is_bare "$1"; then
    ssh "$1" 'journalctl -u janus-gw -n 200 --no-pager 2>/dev/null; journalctl -u janus-gw-local -n 100 --no-pager 2>/dev/null; journalctl -u janus-dash -n 100 --no-pager 2>/dev/null'       >"$DEPLOY_LOG_DIR/$1.log" 2>/dev/null || true
  else
    ssh "$1" 'docker logs --tail 200 janus' >"$DEPLOY_LOG_DIR/$1.log" 2>/dev/null || true
  fi
}

# Resilient file ship (live cutover 2026-10-16: aliyun's sshd RESETS
# long streams — a plain `cat | ssh` or streamed tar dies mid-file):
# split into chunks, scp each with retries, reassemble remotely,
# sha256-verify both sides.
ship_file() {  # <local-file> <host> <remote-path>
  local f="$1" h="$2" dst="$3" dir base chunk i n round
  [ -f "$f" ] || { echo "FAIL: ship_file: $f not found" >&2; return 1; }
  local want
  want="$(sha256sum "$f" | cut -d' ' -f1)"
  # Idempotent ship: when the remote file already matches (relayed by
  # hand or left by a previous run), skip the transfer entirely.
  if [ "$(ssh -o BatchMode=yes "$h" "sha256sum '$dst' 2>/dev/null | cut -d' ' -f1")" = "$want" ]; then
    return 0
  fi
  dir="$(mktemp -d)"; base="$(basename "$f")"
  for round in 1 2; do
    n=0
    # A previous failed attempt leaves stale remote parts that the
    # reassembly glob would swallow (observed live: sha mismatch after
    # a mid-ship reset). Clear them at the start of every round.
    ssh -o BatchMode=yes "$h" "rm -f '$dst'.part.*" 2>/dev/null || true
    split -b 8m -d "$f" "$dir/${base}." 2>/dev/null || true
    for chunk in "$dir/${base}."*; do
      n=$((n+1))
      ok=""
      for i in 1 2 3 4; do
        if scp -q "$chunk" "$h:$dst.part.$(basename "$chunk")"; then ok=1; break; fi
        sleep $((i * 5))
      done
      if [ -z "$ok" ]; then
        if [ "$round" = 2 ]; then
          echo "FAIL: ship_file: $h chunk $n failed in both rounds" >&2; rm -rf "$dir"; return 1
        fi
        echo "   ship_file: $h chunk $n reset x4 — restarting the file (round 2)" >&2
        break
      fi
    done
    # round completed without early break -> fall through to verify
    if [ -n "$ok" ]; then break; fi
  done
  ssh -o BatchMode=yes "$h" "cat '$dst'.part.* > '$dst' && rm -f '$dst'.part.* && sha256sum '$dst' | cut -d' ' -f1" >"$dir/remote.sha" 2>/dev/null
  printf '%s
' "$want" >"$dir/local.sha"
  diff -q "$dir/local.sha" "$dir/remote.sha" >/dev/null 2>&1     || { echo "FAIL: ship_file: sha mismatch for $dst on $h" >&2; rm -rf "$dir"; return 1; }
  rm -rf "$dir"
}

# GIT SHIP MODE (default): every node clones the janus repo at the
# deploy sha and builds the release LOCALLY (docker on the node, CN
# registry mirrors) — no artifact crosses hosts; git moves deltas.
# Per-node remote from the inventory (JANUS_NODE_GIT_<NAME>), else
# JANUS_GW_GIT_REMOTE, else https://github.com/YOUR_ORG/janus.git.
# JANUS_DEPLOY_SHIP=scp forces the chunked-scp fallback.
node_git_remote() {  # $1 = ssh host
  local inv="${NODE_INVNAME[$1]:-}" v="JANUS_NODE_GIT_${inv:-X}"
  printf '%s' "${!v:-${JANUS_GW_GIT_REMOTE:-https://github.com/YOUR_ORG/janus.git}}"
}

# Node-side clone+build: fetches exactly $GW_SHA into $BARE_PREFIX/src/janus
# (persistent clone), builds the tarball in the node's own docker, prints
# the built tarball path.
node_build_gw_artifact() {  # $1 = ssh host
  local h="$1" url
  url="$(node_git_remote "$h")"
  ssh -o BatchMode=yes "$h" "set -e
    mkdir -p '$BARE_PREFIX/src'
    if [ ! -d '$BARE_PREFIX/src/janus/.git' ]; then
      git clone -q '$url' '$BARE_PREFIX/src/janus'
    fi
    cd '$BARE_PREFIX/src/janus'
    git fetch -q origin '$GW_SHA' || git fetch -q origin
    git checkout -q '$GW_SHA'
    JANUS_BARE_BUILDER=${JANUS_BARE_BUILDER:-erlang:27} bash scripts/build_bare_release.sh >/tmp/gw-build.log 2>&1 || { tail -5 /tmp/gw-build.log >&2; exit 1; }
    # Name the artifact for THIS checkout exactly. The old
    # 'ls janus-bare-*.tar.gz | tail -1' picked the alphabetically-last
    # tarball — a stale one whenever an older-sorted sha was built on
    # the node before (2026-10-18: 8dded584 shipped into 1f353955 dirs).
    _s=\$(git rev-parse --short HEAD)
    _t=\"\$PWD/bare-artifacts/gw/janus-bare-\$_s.tar.gz\"
    [ -f \"\$_t\" ] || { echo 'FAIL: expected artifact '\$_t' missing' >&2; exit 1; }
    echo \"\$_t\""
}

# Per-node release trees (live cutover 2026-10-16): the LEADER runs a
# co-located master + second worker process in TWO trees (separate
# vm.args — one tree per unit), a follower runs worker only.
node_bare_trees() {
  if [ "$1" = "$LEADER" ]; then
    printf '%s/gateway %s/worker' "$BARE_PREFIX" "$BARE_PREFIX"
  else
    printf '%s/worker' "$BARE_PREFIX"
  fi
}

# ---- B-D5 bare ship/roll helpers ----------------------------------------
# Steady-state bare rollout mirrors the docker image path's two phases:
# ship-only (step 3: unpack the tarball, NO symlink/restart), then roll
# (steps 4/5: `current` symlink swap + systemctl restart). Layout matches
# the bare layout convention exactly: $PREFIX/gw/<sha>/janus/ with
# `current` -> $PREFIX/gw/<sha>/janus, so the switch and the deploy agree
# on the tree they operate on.
bare_gw_unit_present() {  # $1 = host -> rc 0 unit exists
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$1" \
    'test -e /etc/systemd/system/janus-gw.service' >/dev/null 2>&1
}

ship_bare_gw_artifact() {  # $1 = host — node-side git build (default) or chunk-scp, then unpack
  local h="$1" tree tb
  if [ "${JANUS_DEPLOY_SHIP:-git}" = git ] && [ -n "$GW_SHA" ] && [ "$GW_SHA" != unknown ]; then
    tb="$(node_build_gw_artifact "$h")" || { echo "FAIL: $h: node-side git build failed" >&2; return 1; }
    for tree in $(node_bare_trees "$h"); do
      ssh -o BatchMode=yes "$h" "set -e; mkdir -p '$tree/$BARE_SHA_DIR'; tar -xzf '$tb' -C '$tree/$BARE_SHA_DIR' --strip-components=1; chown -R $BARE_USER:$BARE_USER '$tree/$BARE_SHA_DIR'" || { echo "FAIL: $h: extract into $tree failed" >&2; return 1; }
    done
    return 0
  fi
  ship_file "$GW_TARBALL" "$h" "/tmp/$(basename "$GW_TARBALL")"     || { echo "FAIL: $h: gateway tarball ship failed" >&2; return 1; }
  for tree in $(node_bare_trees "$h"); do
    ssh -o BatchMode=yes "$h" "mkdir -p '$tree/$BARE_SHA_DIR' && tar -xzf '/tmp/$(basename "$GW_TARBALL")' -C '$tree/$BARE_SHA_DIR' --strip-components=1 && chown -R $BARE_USER:$BARE_USER '$tree/$BARE_SHA_DIR'"       || { echo "FAIL: $h: extract into $tree failed" >&2; return 1; }
  done
}

roll_bare_gw() {  # $1 = host — symlink swap + systemctl restart (or fresh-node bootstrap)
  local h="$1" node
  # Idempotent TLS guard: inet_tls accepts only when the beam user can read
  # node-key.pem; any step that re-ships fleet TLS resets it to root-only and
  # the node floods "Invalid key file ... permission denied" (seen live
  # 2026-10-18). Enforce root:$BARE_USER 640 before every restart.
  ssh -o BatchMode=yes "$h" "chown root:$BARE_USER '$BARE_PREFIX'/shared/tls/node-key.pem 2>/dev/null; chmod 640 '$BARE_PREFIX'/shared/tls/node-key.pem 2>/dev/null; true"
  if ! bare_gw_unit_present "$h"; then
    node="${NODE_INVNAME[$h]}"
    STACKS_ON_NODE="${NODE_STACKS[$h]:-/opt/stacks/janus}"
    echo "   $h: no janus-gw unit — FRESH bare bootstrap (docker and bare are independent paths; there is no migration)"
    # Preconditions the ship step already satisfied: release tree unpacked
    # at $BARE_PREFIX/worker/<sha> (+ current symlink). This lays down the
    # remaining three: env file, fleet TLS, systemd unit.
    ssh -o BatchMode=yes "$h" "set -e
      test -s '$STACKS_ON_NODE/.env' || { echo 'no operator-seeded $STACKS_ON_NODE/.env (fleet env: cookie, master, peers, dist port)' >&2; exit 1; }
      install -d -m 755 '$BARE_PREFIX/env' '$BARE_PREFIX/shared/tls'
      install -m 640 -o root -g $BARE_USER '$STACKS_ON_NODE/.env' '$BARE_PREFIX/env/janus-gw.env'
      cp -a '$STACKS_ON_NODE'/fleet/*.pem '$BARE_PREFIX/shared/tls/' 2>/dev/null || true
      chown root:$BARE_USER '$BARE_PREFIX/shared/tls'/*.pem
      chmod 640 '$BARE_PREFIX/shared/tls'/*.pem
      install -m 644 /tmp/janus-gw.service.$$/unit '$UNIT_DST_ON_NODE' 2>/dev/null || true
    " || { echo "FAIL: $h: fresh bootstrap preflight failed" >&2; exit 1; }
    ship_file "$GW_SRC/deploy/janus-gw.service.template" "$h" "/etc/systemd/system/janus-gw.service"       || { echo "FAIL: $h: unit template ship failed" >&2; exit 1; }
    ssh -o BatchMode=yes "$h" "set -e
      chown -R $BARE_USER:$BARE_USER '$BARE_PREFIX/worker' '$BARE_PREFIX/shared'
      systemctl daemon-reload
      systemctl enable janus-gw >/dev/null 2>&1 || true
      systemctl restart janus-gw
      sleep 3
      systemctl is-active janus-gw"       || { echo "FAIL: $h: fresh bootstrap start failed (journalctl -u janus-gw)" >&2; exit 1; }
    return 0  # the wait/verify step below asserts pool registration + health
  fi

  local tree
  for tree in $(node_bare_trees "$h"); do
    # RELATIVE target: an absolute one dangles the moment the parent
    # dir is renamed (live cutover: mv gw -> worker broke every unit).
    ssh -o BatchMode=yes "$h" "ln -sfn '$BARE_SHA_DIR' '$tree/current'"
  done
  ssh -o BatchMode=yes "$h" "systemctl restart janus-gw"
  # The leader's co-located worker follows its master unit.
  if [ "$h" = "$LEADER" ]      && ssh -o BatchMode=yes "$h" 'test -e /etc/systemd/system/janus-gw-local.service' >/dev/null 2>&1; then
    ssh -o BatchMode=yes "$h" "systemctl restart janus-gw-local"
  fi
}

verify_bare_node() {  # $1 = host — the bare counterpart of verify_node_image
  local h="$1" active role sha token body
  active="$(ssh -o BatchMode=yes "$h" 'systemctl is-active janus-gw' 2>/dev/null || true)"
  if [ "$active" != active ]; then
    echo "FAIL: $h janus-gw not active (got '$active')"
    collect_node_logs "$h"
    exit 1
  fi
  role="$(node_role "$h")"
  if [ "$role" = worker ]; then
    echo "   $h: janus-gw active (worker role — pool registration asserted by the wait step)"
    return 0
  fi
  # Master: /stats/sched git_sha must equal the shipped GW_SHA (the
  # release stamps JANUS_GIT_SHA at build; janus_build -> persistent_term
  # -> /stats/sched). Token from the generated envfile — never logged.
  token="$(ssh -o BatchMode=yes "$h" "sed -n 's/^JANUS_STATS_TOKEN=//p' '$BARE_PREFIX/env/janus-gw.env' 2>/dev/null" || true)"
  body=""
  if [ -n "$token" ]; then
    for _ in $(seq 1 30); do
      # H3: the token is fed to the remote curl on stdin, never in argv.
      body="$(printf 'Authorization: Bearer %s\n' "$token" | ssh -o BatchMode=yes "$h" "curl -fsS -m 5 -H @- http://127.0.0.1:$BARE_ADMIN_PORT/stats/sched" 2>/dev/null || true)"
      [ -n "$body" ] && break
      sleep 2
    done
  fi
  if [ -z "$body" ]; then
    echo "FAIL: $h /stats/sched never answered on 127.0.0.1:$BARE_ADMIN_PORT"
    collect_node_logs "$h"
    exit 1
  fi
  sha="$(stats_field "$body" git_sha)"
  if [ "$sha" != "$GW_SHA" ]; then
    echo "FAIL: $h /stats/sched git_sha '$sha' != shipped $GW_SHA"
    collect_node_logs "$h"
    exit 1
  fi
  echo "   $h: janus-gw active, git_sha=$sha (matches shipped release)"
}

# GeoLite2 for a BARE leader: same credential contract + stale-serve
# degrade as scripts/ensure_master_mmdb.sh, but the file lands in the
# BARE shared tree ($JANUS_BARE_PREFIX/shared/geo/) that the
# F2-generated EnvironmentFile already points JANUS_MMDB_PATH at (the
# switch rewrote the compose bind path there). No compose/.env wiring
# exists on this path — the bare unit's env is the only consumer.
ensure_bare_leader_mmdb() {  # $1 = ssh host
  local host="$1" account license tmp mmdb rc=0
  account="${JANUS_MAXMIND_ACCOUNT_ID:-${MAXMIND_ACCOUNT_ID:-$(prod_env MAXMIND_ACCOUNT_ID)}}"
  license="${JANUS_MAXMIND_LICENSE_KEY:-${MAXMIND_LICENSE_KEY:-$(prod_env MAXMIND_LICENSE_KEY)}}"
  mmdb="$BARE_PREFIX/shared/geo/GeoLite2-City.mmdb"
  if [ -z "$account" ] || [ -z "$license" ]; then
    if ssh -o BatchMode=yes "$host" "test -s '$mmdb'" 2>/dev/null; then
      echo "WARN: MaxMind credentials missing — keeping the EXISTING bare mmdb on $host (stale-serve)" >&2
      return 0
    fi
    echo "FAIL: MaxMind credentials missing and no mmdb at $host:$mmdb" >&2
    return 1
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/GeoLite2-City.XXXXXX.mmdb")"
  if bash scripts/fetch_geolite2_mmdb.sh "$tmp"; then
    ssh -o BatchMode=yes "$host" "mkdir -p '$BARE_PREFIX/shared/geo'"
    scp -q "$tmp" "$host:${mmdb}.new"
    ssh -o BatchMode=yes "$host" "mv -f '${mmdb}.new' '$mmdb' && chown '$BARE_USER:$BARE_USER' '$mmdb' && chmod 664 '$mmdb' && wc -c < '$mmdb'"
    echo "   $host: bare mmdb installed at $mmdb"
  else
    if ssh -o BatchMode=yes "$host" "test -s '$mmdb'"; then
      echo "WARNING: MaxMind refresh failed — keeping existing $host:$mmdb" >&2
    else
      echo "FAIL: mmdb fetch failed and none exists at $host:$mmdb" >&2
      rc=1
    fi
  fi
  rm -f "$tmp"
  return "$rc"
}

# Captures the LEADER generation (read once, after its catalog apply).
# rc 0 = captured (LEADER_GEN set), 2 = sustained 401, 1 = deadline.
# A single 401 right after recreate is treated as transient (docker-proxy
# / admin listener race); only a sustained streak past AUTH_GRACE hard-fails.
capture_leader_generation() {
  local shost sport g deadline auth_hits=0
  local AUTH_GRACE=30
  if [ "${JANUS_DEPLOY_STATS_VIA_SSH:-0}" = "1" ]; then STATS_MODE=ssh; else STATS_MODE=direct; fi
  shost="$(node_stats_field "$LEADER" host)"
  sport="$(node_stats_field "$LEADER" port)"
  deadline=$(( $(date +%s) + WAIT_DEADLINE ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if node_stats_once "$LEADER" "$shost" "$sport"; then
      if [ "$PROBE_CODE" = "401" ]; then
        auth_hits=$((auth_hits + POLL_SEC))
        if [ "$auth_hits" -ge "$AUTH_GRACE" ]; then return 2; fi
      elif [ "$PROBE_CODE" = "200" ]; then
        auth_hits=0
        g="$(stats_field "$PROBE_BODY" generation)"
        case "$g" in
          ''|*[!0-9]*) : ;;  # unparseable body: transient, keep retrying
          *) LEADER_GEN="$g"; return 0 ;;
        esac
      else
        auth_hits=0
      fi
    fi
    sleep "$POLL_SEC"
  done
  return 1
}

# Worker-role followers (JANUS_ROLE=worker) publish no agent/admin
# ports on the host and their in-container /stats carries no
# generation (the catalog lives on the master). For those, the
# meaningful verification is: container healthy + REGISTERED in the
# master's pool (master /stats/sched workers array shows the node).
_janus_env() {  # $1 = ssh host, $2 = KEY, $3 = container (default janus) -> value (never trips set -e)
  # Runtime-aware source (B-D5): docker reads the container env;
  # bare reads the F2-generated EnvironmentFile the unit runs under
  # (same keys the switch materialized from the compose service).
  if is_bare "$1"; then
    ssh "$1" "sed -n 's/^$2=//p' '$BARE_PREFIX/env/janus-gw.env' 2>/dev/null" \
      | tr -d '[:space:]' || true
  else
    ssh "$1" "docker inspect '${3:-janus}' --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null" \
      | awk -F= -v k="$2" '$1 == k { print substr($0, index($0, "=") + 1); exit }' \
      | tr -d '[:space:]' || true
  fi
}

node_role() {  # $1 = ssh host -> master|worker|unknown
  local r
  r="$(_janus_env "$1" JANUS_ROLE)"
  case "$r" in
    master|worker) printf '%s' "$r"; return 0 ;;
  esac
  # SSH blip / inspect race: workers always set JANUS_MASTER_NODE;
  # masters do not. Prefer that over a port-listen heuristic (master
  # :48090 may not be bound yet right after recreate).
  if [ -n "$(_janus_env "$1" JANUS_MASTER_NODE)" ]; then
    printf '%s' worker
    return 0
  fi
  printf '%s' "${r:-unknown}"
}

worker_node_name() {  # $1 = ssh host -> the JANUS_NODE_NAME env
  _janus_env "$1" JANUS_NODE_NAME
}

# H3: a host can run a SECOND gateway container next to `janus` —
# `janus-worker`, created by scripts/deploy_mw_prod.sh on the master host.
# It is a separate container with its own JANUS_ROLE/JANUS_NODE_NAME, so the
# `janus` env can never describe it: reading only `janus` made it invisible
# to the registration check and left it on the previous artifact forever.
co_located_worker_name() {  # $1 = ssh host -> node name of a `janus-worker` container, if any
  if is_bare "$1"; then return 0; fi
  _janus_env "$1" JANUS_NODE_NAME janus-worker
}

# Node names this host must have UP in the master's pool: its own node when
# it is a worker, plus any co-located janus-worker. Empty = nothing to assert
# (a single-container master), which keeps the historical behaviour. The
# role is passed in when the caller already probed it (one less SSH round
# trip per wait iteration).
host_registration_names() {  # $1 = ssh host, $2 = known role (optional) -> space-separated node names
  local role="${2:-}" names="" co
  [ -n "$role" ] || role="$(node_role "$1")"
  if [ "$role" = "worker" ]; then
    names="$(worker_node_name "$1")"
  fi
  co="$(co_located_worker_name "$1")"
  if [ -n "$co" ] && [ "$co" != "$names" ]; then
    names="${names:+$names }$co"
  fi
  printf '%s' "$names"
}

# True when master's /stats/sched workers[] has {node: NAME, status: up}.
# JSON parse — grep on compact/"node":"x" used to miss spaced forms and
# could not bind status to the same entry.
sched_worker_up() {  # $1 = node name, $2 = sched JSON body
  local name="$1" body="$2"
  [ -n "$name" ] && [ -n "$body" ] || return 1
  printf '%s' "$body" | "$PY" -c '
import json, sys
name = sys.argv[1]
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    sys.exit(1)
for w in d.get("workers") or []:
    if isinstance(w, dict) and w.get("node") == name and w.get("status") == "up":
        sys.exit(0)
sys.exit(1)
' "$name" 2>/dev/null
}

fetch_master_sched() {
  local body
  # Read token from the leader's own env source — never interpolate
  # the deploy-host token into the remote argv (shell metacharacters
  # / drift vs remote). Runtime-aware (B-D5): docker leader = compose
  # .env + docker-published 48090; bare leader = generated
  # EnvironmentFile + the inventory admin port.
  if is_bare "$LEADER"; then
    body="$(ssh "$LEADER" 'STATS=$(sed -n "s/^JANUS_STATS_TOKEN=//p" '"$BARE_PREFIX"'/env/janus-gw.env 2>/dev/null); printf "Authorization: Bearer %s\n" "$STATS" | curl -s -m 5 -H @- http://127.0.0.1:'"$BARE_ADMIN_PORT"'/stats/sched' 2>/dev/null || true)"
  else
  body="$(ssh "$LEADER" 'STATS=$(grep ^JANUS_STATS_TOKEN= /opt/stacks/janus/.env | cut -d= -f2- | tr -d "\"'\''"); printf "Authorization: Bearer %s\n" "$STATS" | curl -s -m 5 -H @- http://127.0.0.1:48090/stats/sched' 2>/dev/null || true)"
  fi
  [ -n "$body" ] || return 1
  printf '%s' "$body"
}

wait_sched_nodes() {  # $1 = space-separated node names; stable-2-polls via master's pool
  local names="$1" body i n
  [ -n "$names" ] || return 1
  for i in 1 2; do
    body="$(fetch_master_sched)" || return 1
    for n in $names; do
      sched_worker_up "$n" "$body" || return 1
    done
    [ "$i" = "2" ] || sleep 3
  done
  return 0
}

wait_worker_registered() {  # $1 = ssh host; stable-2-polls via master's pool
  wait_sched_nodes "$(host_registration_names "$1")"
}

# H3: the compose service list is the source of truth for "this host runs a
# co-located gateway". A stopped/absent container would hide the drift while
# the next `compose up` resurrects it from whatever the tag holds, so the
# decision must not depend on the container being up.
has_co_located_worker() {  # $1 = ssh host — true when the compose defines janus-worker
  if is_bare "$1"; then return 1; fi
  [ "$(ssh "$1" 'cd /opt/stacks/janus 2>/dev/null && docker compose config --services 2>/dev/null' 2>/dev/null | grep -cx janus-worker || true)" = "1" ]
}

# H3: the co-located worker reaches the master through the `extra_hosts` pin
# `<public origin>:<master caddy-net IP>` (there is no docker DNS alias for
# the public name) and that address is ephemeral. A ship that recreates the
# master must refresh the pin BEFORE recreating the worker, or the worker
# resolves the dead address and never rejoins the pool. The pin is optional
# here (a future DNS-alias design has none) — absent = nothing to refresh.
pin_master_ip() {  # $1 = ssh host, $2 = master container IP
  local h="$1" ip="$2" n
  ssh "$h" "grep -q '${JANUS_MASTER_ORIGIN:-gw.example.invalid}:' /opt/stacks/janus/docker-compose.yml" 2>/dev/null || return 0
  ssh "$h" "sed -i 's#\(${JANUS_MASTER_ORIGIN:-gw.example.invalid}:\)[0-9A-Za-z_.-]*#\1$ip#' /opt/stacks/janus/docker-compose.yml" \
    || { echo "FAIL: $h cannot refresh the worker pin" >&2; exit 1; }
  n="$(ssh "$h" "grep -c '${JANUS_MASTER_ORIGIN:-gw.example.invalid}:$ip' /opt/stacks/janus/docker-compose.yml" 2>/dev/null || true)"
  [ "${n:-0}" = "1" ] || { echo "FAIL: $h pin refresh did not produce exactly one the public origin:$ip (got '${n:-none}')" >&2; exit 1; }
}

# H3: recreate the co-located worker (and refresh the master pin first on the
# leader). verify_node_image is the same-host check `janus` gets, so a stale
# worker cannot survive this rollout silently.
roll_co_located_worker() {  # $1 = ssh host
  local h="$1" cip=""
  refuse_compose "$h" "docker compose up -d --force-recreate janus-worker"
  if [ "$h" = "$LEADER" ]; then
    cip="$(ssh "$h" 'docker inspect -f "{{(index .NetworkSettings.Networks \"caddy-net\").IPAddress}}" janus' 2>/dev/null || true)"
    [ -n "$cip" ] || { echo "FAIL: $h cannot read the master's caddy-net address for the worker pin" >&2; exit 1; }
    pin_master_ip "$h" "$cip"
  fi
  ssh "$h" 'cd /opt/stacks/janus && docker compose up -d --force-recreate janus-worker >/dev/null 2>&1'
  verify_node_image "$h" janus-worker
  echo "   $h: co-located janus-worker recreated"
}

# Bounded registration wait for the leader's co-located worker. The leader
# is not a follower, so the step-6 follower wait never covers it; call this
# right after the leader's worker is recreated, before the followers roll.
wait_co_located_worker_registered() {  # $1 = ssh host
  local h="$1" deadline
  deadline=$(( $(date +%s) + WAIT_DEADLINE ))
  while :; do
    if wait_worker_registered "$h"; then return 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      collect_node_logs "$h"
      echo "FAIL: $h co-located janus-worker did not register in the master pool within ${WAIT_DEADLINE}s" >&2
      echo "      check the the public origin extra_hosts pin and: ssh $h docker logs --tail 80 janus-worker" >&2
      return 1
    fi
    sleep "$POLL_SEC"
  done
}

# Follower waiter: runs one per follower inside a subshell so both poll
# in parallel under the shared WAIT_DEADLINE_AT epoch. Writes its final
# outcome (OK | 401 | deadline) to $2 and always exits 0.
wait_follower() {
  local h="$1" resfile="$2"
  local shost sport stable=0 outcome=deadline now gen up window role name names
  if [ "${JANUS_DEPLOY_STATS_VIA_SSH:-0}" = "1" ]; then STATS_MODE=ssh; else STATS_MODE=direct; fi
  shost="$(node_stats_field "$h" host)"
  sport="$(node_stats_field "$h" port)"
  role="$(node_role "$h")"
  name="$(worker_node_name "$h")"
  # H3: computed ONCE — the poll loop must not spend 4 extra SSH calls per
  # iteration re-probing a role/co-located worker that cannot appear later.
  names="$(host_registration_names "$h" "$role")"
  printf '   %s: verify path role=%s node_name=%s\n' "$h" "$role" "${name:-—}" >&2
  if [ "$names" != "$name" ]; then
    printf '   %s: co-located worker must also be up in the pool: %s\n' "$h" "$names" >&2
  fi
  if [ "$role" = "worker" ]; then
    # Worker-role follower: verify registration in the master's pool.
    # Short healthy probe (10s) — step 5 already waited up to 90s.
    while :; do
      now="$(date +%s)"
      [ "$now" -lt "$WAIT_DEADLINE_AT" ] || break
      if wait_gateway_healthy "$h" 10 && wait_sched_nodes "$names"; then
        echo OK > "$resfile"; return 0
      fi
      sleep 3
    done
    echo deadline > "$resfile"
    return 0
  fi
  while :; do
    now="$(date +%s)"
    [ "$now" -lt "$WAIT_DEADLINE_AT" ] || break
    if node_stats_once "$h" "$shost" "$sport"; then
      if [ "$PROBE_CODE" = "401" ]; then outcome=401; break; fi
      if [ "$PROBE_CODE" = "200" ]; then
        if [ "$SHIP_CLASS" = "config" ]; then
          gen="$(stats_field "$PROBE_BODY" generation)"
          case "$gen" in
            ''|*[!0-9]*) stable=0 ;;
            *) if [ "$gen" -gt "$GEN0" ] || [ "$gen" -eq "$LEADER_GEN" ]; then
                 stable=$((stable + 1))
               else
                 stable=0
               fi ;;
          esac
        else
          up="$(stats_field "$PROBE_BODY" uptime_sec)"
          window=$(( now - SCRIPT_START ))
          case "$up" in
            ''|*[!0-9]*) stable=0 ;;
            *) if [ "$up" -lt "$window" ]; then
                 stable=$((stable + 1))  # container restarted inside this ship window
               else
                 stable=0
               fi ;;
          esac
        fi
        if [ "$stable" -ge 2 ]; then outcome=OK; break; fi
      else
        stable=0  # transient HTTP error: retry until the deadline
      fi
    else
      stable=0  # transport failed on both direct and ssh: retry
    fi
    sleep "$POLL_SEC"
  done
  printf '%s\n' "$outcome" >"$resfile"
}

# ---- --plan: DRY RUN — print the plan, exit 0. No SSH REQUIRED (probe
# and lock state are best-effort informational), no mutation, no gate,
# no credentials. Used by the CI deploy workflow's first-ship dry-run
# mode (H4: the runner has no prod SSH keys) and for pre-deploy review.
if [ "$PLAN" -eq 1 ]; then
  detect_ship_class
  LATEST_MIGRATION="$(ls "$GW_SRC/apps/janus_core/priv/migrations/postgres"/*.sql | sed 's#.*/##; s/\.sql$//' | sort | tail -1)"
  # M1: an empty glob makes the plan claim a migration set that does not
  # exist; refuse instead of printing "bundled up to ".
  [ -n "$LATEST_MIGRATION" ] || {
    echo "FAIL: no migrations found under $GW_SRC/apps/janus_core/priv/migrations/postgres — wrong GW_SRC or a checkout without migrations" >&2
    exit 1
  }
  echo "== DEPLOY PLAN (dry run — read-only, no production contact) =="
  echo "   topology      : leader=$LEADER source=$(topology_source)"
  printf '   followers     : %s (leader rolls first, migrations once)\n' "$FOLLOWERS"
  echo "   ship class    : $SHIP_CLASS"
  if [ "$INVENTORY_PRESENT" -eq 1 ]; then
    echo "   inventory     : $INV"
    printf '   runtimes      :'
    for _h in $ALL_HOSTS; do printf ' %s=%s' "$_h" "${NODE_RUNTIME[$_h]}"; done
    echo
    if [ -n "$BARE_NODES" ]; then
      echo "   bare ship     : [$BARE_NODES] — rsync tarball -> $BARE_PREFIX/gw/<sha>/ + current symlink swap + systemctl restart janus-gw"
      echo "   compose refuse: [$BARE_NODES] (F1 layer 2 — docker compose up/recreate is hard-refused for these nodes)"
      echo "   bare verify   : pre-ship gate runs verify_bare.sh$( [ "$DASH_BARE_SHIP" -eq 1 ] && printf ' + verify_bare_dashboard.sh' ) against THIS run's artifacts (B-D8); failure refuses the ship"
      for _h in $BARE_NODES; do
        _urc=0
        ssh -o BatchMode=yes -o ConnectTimeout=5 "$_h" 'test -e /etc/systemd/system/janus-gw.service' >/dev/null 2>&1 || _urc=$?
        case "$_urc" in
          0) echo "                   $_h: janus-gw unit present — steady-state rsync swap" ;;
          1) echo "                   $_h: janus-gw unit ABSENT — first deploy runs the fresh bare bootstrap (env + fleet TLS + unit; leader-last order enforced by the rollout)" ;;
          *) echo "                   $_h: unit presence unknown (SSH unavailable here — detected at ship time)" ;;
        esac
      done
      echo "   rollout order : bare nodes roll by symlink swap + systemctl restart (leader first, migrations at boot); docker nodes by compose recreate"
    fi
    if [ "$DASH_BARE_SHIP" -eq 1 ]; then
      echo "   dash ship     : leader $LEADER runs the BARE dashboard (JANUS_DASH_BARE=true) — build_bare_dashboard.sh payload + install_bare_dashboard.sh"
    elif [ "$DASH_BARE_SEAM" = true ]; then
      echo "   dash ship     : docker image path (JANUS_DASH_BARE=true but leader $LEADER is runtime=docker)"
    fi
  fi
  # (no inventory: pure docker plan — output intentionally unchanged, B-D5 graceful degradation)
  if [ -n "$GW_DIRTY" ]; then _dirty="YES (a real run refuses)"; else _dirty="no"; fi
  echo "   gateway       : JANUS_GIT_SHA=$GW_SHA dirty=$_dirty"
  echo "   migrations    : bundled up to $LATEST_MIGRATION"
  _gw_tb="$(ls "$GW_SRC"/bare-artifacts/gw/janus-bare-*.tar.gz 2>/dev/null | sort | tail -1 || true)"
  echo "   gateway tarball  : ${_gw_tb:-NOT BUILT yet (a real run builds it)}"
  _dash_pl="$(ls -dt bare-artifacts/dash/dash-* 2>/dev/null | head -1 || true)"
  echo "   dashboard payload: ${_dash_pl:-NOT BUILT yet (a real run builds it)}"
  if _lock="$(deploy_lock_status 2>/dev/null)"; then
    echo "   deploy lock   : $_lock"
  else
    echo "   deploy lock   : UNREADABLE (leader Postgres unreachable from here — informational in --plan)"
  fi
  if probe_leader_healthz "$LEADER"; then
    echo "   leader probe  : healthz OK"
  else
    echo "   leader probe  : UNREACHABLE (a real run REFUSES — promote-in-progress hint, H3-D7)"
  fi
  if [ -z "$BARE_NODES" ]; then
    echo "   rollout order : ship artifacts -> [$ALL_HOSTS] -> leader $LEADER recreate+migrate+verify"
    echo "                   -> followers ($FOLLOWERS) recreate+verify -> dashboard -> $LEADER -> read-only smoke"
  fi
  echo "   plan ok — nothing shipped, nothing locked"
  exit 0
fi

# ================== pipeline ==================

FOLLOWER_VERIFY_FAILED=0

if [ "$SMOKE_ONLY" -eq 0 ]; then
  detect_ship_class
  renew_deploy_lock "post-gate / pre-build"
  echo "== 2. build ship artifacts (ship class: $SHIP_CLASS; docker nodes: [$DOCKER_NODES]; bare nodes: [$BARE_NODES]) =="
  # Prod nodes are x86_64. The gate above builds/runs the NATIVE arch
  # image (fast local e2e on Apple Silicon); the SHIP images are
  # cross-built here (QEMU on arm64, native on amd64 dev hosts).
  SHIP_PLATFORM="${JANUS_DEPLOY_PLATFORM:-linux/amd64}"

  # ---- B-D5 bare artifacts (built only when the inventory has bare nodes):
  # the gateway release tarball in the PINNED glibc builder (B-D1) and,
  # when the leader ships the bare dashboard (JANUS_DASH_BARE seam),
  # the wheelhouse payload (B-D3). Provenance: the artifacts carry THIS
  # run's shas — a pre-supplied artifact whose name doesn't match HEAD
  # refuses (same class as the v2.1 C.3 dirty-tree gate).
  if [ -n "$BARE_NODES" ]; then
    _gw_short="$(git -C "$GW_SRC" rev-parse --short HEAD)"
    if [ "${JANUS_DEPLOY_SHIP:-git}" = git ] && [ -n "${JANUS_GW_GIT_REMOTE:-}${JANUS_NODE_GIT_ALIYUN:-}${JANUS_NODE_GIT_JDCLOUD:-}${JANUS_NODE_GIT_TENCENT:-}" ]; then
      # Git ship: every node builds its own release from the repo at
      # $GW_SHA — no local artifact (and no local docker) needed. A
      # node whose build fails halts the deploy before any flip.
      BARE_SHA_DIR="$_gw_short"
      # STACKS_ON_NODE is per host: roll_bare_gw resolves it from
      # NODE_STACKS[$h] inside its own scope ($h is unbound here).
      UNIT_DST_ON_NODE="/etc/systemd/system/janus-gw.service"
      SKIP_LOCAL_BUILD=1
      echo "   git ship mode: nodes build $BARE_SHA_DIR themselves (no local artifacts)"
    fi
    GW_TARBALL=""
    if [ -z "$SKIP_LOCAL_BUILD" ]; then
    GW_TARBALL="${JANUS_DEPLOY_BARE_TARBALL:-}"
    if [ -n "$GW_TARBALL" ]; then
      if [ ! -f "$GW_TARBALL" ]; then
        echo "FAIL: JANUS_DEPLOY_BARE_TARBALL=$GW_TARBALL not found"; exit 1
      fi
      case "$GW_TARBALL" in
        *"janus-bare-$_gw_short.tar.gz") : ;;
        *)
          echo "FAIL: JANUS_DEPLOY_BARE_TARBALL=$GW_TARBALL does not match gateway HEAD short sha $_gw_short (stale artifact — provenance refusal, v2.1 C.3)" >&2
          exit 1 ;;
      esac
    else
      echo "   bare gateway release: building (janus repo scripts/build_bare_release.sh)"
      ( cd "$GW_SRC" && bash scripts/build_bare_release.sh ) \
        || { echo "FAIL: bare release build failed" >&2; exit 1; }
      GW_TARBALL="$GW_SRC/bare-artifacts/gw/janus-bare-$_gw_short.tar.gz"
    fi
    fi
    if [ -z "$SKIP_LOCAL_BUILD" ]; then
      [ -f "$GW_TARBALL" ] || { echo "FAIL: expected bare tarball at $GW_TARBALL" >&2; exit 1; }
    fi
    BARE_SHA_DIR="$_gw_short"
    echo "   bare gateway tarball: $GW_TARBALL (-> $BARE_PREFIX/gw/$BARE_SHA_DIR/)"
    if [ "$DASH_BARE_SHIP" -eq 1 ] && [ -n "$SKIP_LOCAL_BUILD" ]; then
      echo "   git ship mode: leader builds the dashboard payload itself"
    elif [ "$DASH_BARE_SHIP" -eq 1 ]; then
      _dash_short="$(git rev-parse --short HEAD)"
      DASH_PAYLOAD="${JANUS_DEPLOY_BARE_PAYLOAD:-}"
      if [ -n "$DASH_PAYLOAD" ]; then
        if [ ! -d "$DASH_PAYLOAD" ]; then
          echo "FAIL: JANUS_DEPLOY_BARE_PAYLOAD=$DASH_PAYLOAD not found"; exit 1
        fi
        case "$(basename "$DASH_PAYLOAD")" in
          "dash-$_dash_short") : ;;
          *)
            echo "FAIL: JANUS_DEPLOY_BARE_PAYLOAD=$DASH_PAYLOAD does not match dashboard HEAD short sha $_dash_short (stale payload — provenance refusal)" >&2
            exit 1 ;;
        esac
      else
        echo "   bare dash payload: building (scripts/build_bare_dashboard.sh)"
        bash scripts/build_bare_dashboard.sh \
          || { echo "FAIL: bare dash payload build failed" >&2; exit 1; }
        DASH_PAYLOAD="bare-artifacts/dash/dash-$_dash_short"
      fi
      [ -d "$DASH_PAYLOAD" ] || { echo "FAIL: expected dash payload at $DASH_PAYLOAD" >&2; exit 1; }
      echo "   bare dash payload: $DASH_PAYLOAD"
    fi
  fi

  if [ -n "$DOCKER_NODES" ] || [ "$DASH_BARE_SHIP" -eq 0 ]; then
    # janus-dashboard:latest ships docker whenever the dashboard does
    # not ride the bare seam (even on an all-bare GATEWAY fleet, the
    # compose dashboard is then the intended runtime, Task-1 d4).
    docker build --platform "$SHIP_PLATFORM" -t janus-dashboard:latest . >/dev/null
  fi
  if [ -n "$DOCKER_NODES" ]; then
    docker build --platform "$SHIP_PLATFORM" --build-arg JANUS_GIT_SHA="$GW_SHA" -t janus:dashboard "$GW_SRC" >/dev/null
  fi

  # ---- B-D8 pre-ship verify gate: when ANY inventory node is bare,
  # THIS run's artifacts boot in throwaway containers on the build host
  # (no prod secret leaves the fleet). verify_bare_dashboard runs only
  # when the dashboard ships bare this run (it is the dash payload's
  # gate). Failure refuses the ship. Skipped entirely for docker-only
  # fleets. (--plan lists the gate but does not execute it — a plan is
  # read-only and must run where no artifacts exist.)
  if [ -n "$BARE_NODES" ]; then
    if [ -n "${SKIP_LOCAL_BUILD:-}" ]; then
      echo "== 2b. B-D8 verify gate: SKIPPED (git ship — nodes build locally; a failed node build halts before any flip) =="
    else
    echo "== 2b. B-D8 verify gate: throwaway-container boot of this run's bare artifacts =="
    bash "$GW_SRC/scripts/verify_bare.sh" "$GW_TARBALL" \
      || { echo "FAIL: verify_bare.sh (B-D8) — refusing to ship" >&2; exit 1; }
    if [ "$DASH_BARE_SHIP" -eq 1 ]; then
      bash scripts/verify_bare_dashboard.sh "$DASH_PAYLOAD" \
        || { echo "FAIL: verify_bare_dashboard.sh (B-D8) — refusing to ship" >&2; exit 1; }
    fi
  fi

  # Migrations run automatically at gateway boot. The LEADER node
  # (the topology leader) restarts FIRST so pending migrations execute exactly once;
  # followers then boot against an already-migrated schema — no
  # concurrent-migration races across nodes.
  LATEST_MIGRATION="$(ls "$GW_SRC/apps/janus_core/priv/migrations/postgres"/*.sql | sed 's#.*/##; s/\.sql$//' | sort | tail -1)"
  # M1: empty LATEST_MIGRATION made the verification below compare '' to
  # '' and pass — the one gate that proves the leader is migrated became
  # a no-op. Refuse before any node restarts.
  [ -n "$LATEST_MIGRATION" ] || {
    echo "FAIL: no migrations found under $GW_SRC/apps/janus_core/priv/migrations/postgres — the leader migration gate cannot be verified" >&2
    exit 1
  }
  # The version is interpolated into a SQL literal below; a filename can
  # only be a migration version if it is plain [A-Za-z0-9_.-].
  case "$LATEST_MIGRATION" in
    *[!A-Za-z0-9_.-]*) echo "FAIL: unexpected migration version name '$LATEST_MIGRATION'" >&2; exit 1 ;;
  esac
  echo "   bundled migrations up to: $LATEST_MIGRATION"
  # v2.2 deploy order (migration 017 allow_internal): GATEWAY first
  # (migration at boot), dashboard second — the dashboard's
  # allow_internal write degrades gracefully on a missing column
  # (409 migration_pending, the pre-015 fallback pattern). Both images
  # roll in THIS deploy; the harness never writes through a
  # half-migrated stack.

  if [ -z "${JANUS_STATS_TOKEN:-}" ]; then
    echo "FAIL: JANUS_STATS_TOKEN is empty at the stats-wait stage; halting"
    exit 1
  fi
  if [ ! -e "$PY" ]; then
    echo "FAIL: $PY not found; cannot parse /stats JSON (set JANUS_DEPLOY_PYTHON)"
    exit 1
  fi
  NODE_STATS="$(leader_psql "SELECT name, stats_host, stats_port, stats_token_ciphertext FROM gateway_nodes WHERE enabled = true" || true)"
  require_stats_inventory

  # ---- v2.2 Part B: egress-token-policy pre-deploy assert ----
  # The knob is the SETTINGS-TABLE key dash.egress_policy (env
  # JANUS_DASH_EGRESS_POLICY is only the first-boot seed; the deploy
  # reads the SETTING). Refuse to deploy with the policy ON while any
  # NON-loopback-literal node lacks a per-node envelope. Classification
  # uses the SAME canonical loopback-literal rule as runtime
  # (app/egress.py is_loopback_literal — never is_internal_sockaddr,
  # never DNS).
  loopback_literal() {  # $1 = stats_host (bare host or http(s) origin)
    local h
    h="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$h" in
      http://*) h="${h#http://}" ;;
      https://*) h="${h#https://}" ;;
    esac
    h="${h%%/*}"
    h="${h##*@}"
    if [ "${h#\[}" != "$h" ]; then h="${h%%]*}"; h="${h#\[}";   # [v6]:port
    elif [ "$(printf '%s' "$h" | tr -cd ':' | wc -c)" -le 1 ]; then h="${h%%:*}"; fi
    case "$h" in
      127.0.0.1|::1|localhost|::ffff:127.0.0.1) return 0 ;;
      *) return 1 ;;
    esac
  }
  EGRESS_KNOB_ROW="$(leader_psql "SELECT value FROM settings WHERE key = 'dash.egress_policy'" || true)"
  case "$EGRESS_KNOB_ROW" in
    *'"enabled":true'*|*'"enabled": true'*|on) EGRESS_POLICY_ON=1 ;;
    *) EGRESS_POLICY_ON=0 ;;
  esac
  if [ "$EGRESS_POLICY_ON" = "1" ]; then
    bad_nodes=""
    while IFS='|' read -r n shost _sport stok; do
      [ -n "$n" ] || continue
      if [ -z "$stok" ] && ! loopback_literal "$shost"; then
        bad_nodes="$bad_nodes $n($shost)"
      fi
    done <<EOF
$NODE_STATS
EOF
    if [ -n "$bad_nodes" ]; then
      echo "FAIL: dash.egress_policy is ON but non-loopback-literal node(s) lack per-node stats tokens:$bad_nodes"
      echo "      register per-node tokens first (skills/fleet-node-ops SKILL Part E rollout) or turn the policy off"
      exit 1
    fi
    echo "   egress token policy: ON (all non-loopback nodes carry per-node tokens)"
  else
    # Dormancy forcing function: loud banner every deploy while off.
    echo "   !! EGRESS TOKEN POLICY OFF — P0 FIX DORMANT: legacy stats_hosts keep receiving the global JANUS_STATS_TOKEN until dash.egress_policy is enabled (runbook Part E sets the deadline: the first deploy after per-node tokens are registered)."
  fi

  if [ -n "$DOCKER_NODES" ]; then
    GW_IMAGE_ID="$(docker inspect -f '{{.Id}}' janus:dashboard 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -z "$GW_IMAGE_ID" ]; then
      echo "FAIL: janus:dashboard image missing locally (gate must build it)"
      exit 1
    fi
    echo "   shipped gateway image id: $GW_IMAGE_ID"
  fi

  GEN0=""; LEADER_GEN=""
  if [ "$SHIP_CLASS" = "config" ]; then
    GEN0="$(leader_psql "SELECT config_generation FROM config_meta WHERE id = 1" | tr -d '[:space:]' || true)"
    case "$GEN0" in
      ''|*[!0-9]*)
        echo "FAIL: cannot read config_generation from the leader dashboard DB before ship (got '${GEN0}')"
        exit 1 ;;
    esac
    echo "   baseline gen0=$GEN0 (captured before ship)"
  fi

    fi
  renew_deploy_lock "pre-ship (step 3)"
  echo "== 3. ship gateway to all nodes (artifact only, no restart yet) =="
  # Docker nodes: image over docker save|load (today's path, B-D5).
  if [ -n "$DOCKER_NODES" ]; then
    docker save janus:dashboard | gzip -1 > "${TEMP:-/tmp}/janus_deploy.tgz"
    for h in $DOCKER_NODES; do
      (cat "${TEMP:-/tmp}/janus_deploy.tgz" | ssh "$h" \
        "docker load >/dev/null 2>&1 && docker tag janus:dashboard janus-gw:latest >/dev/null 2>&1" \
        >/dev/null 2>&1 && echo "   $h: image loaded") &
    done
    wait
    rm -f "${TEMP:-/tmp}/janus_deploy.tgz"
  fi
  # Bare nodes (B-D5): unpack the release tarball under its <sha> dir —
  # NO symlink swap, NO restart (that is the rollout step, leader
  # first). Serial on purpose: ~40 MB over ssh is seconds-scale (the
  # whole point of the bare path — G1) and strict error propagation
  # beats parallel fire-and-forget here.
  for h in $BARE_NODES; do
    ship_bare_gw_artifact "$h"
    echo "   $h: tarball unpacked -> $BARE_PREFIX/gw/$BARE_SHA_DIR/"
  done

  # GeoLite2-City mmdb on the MASTER only (spec Part A.1 / NOTICE). Must
  # land BEFORE recreate so settings.sched.geo=true becomes effective
  # (mmdb_present) instead of the Maintenance "Geo desired but MMDB missing"
  # soft-off. Workers need no mmdb. Credentials: JANUS_MAXMIND_ACCOUNT_ID +
  # JANUS_MAXMIND_LICENSE_KEY (or secrets JSON). Skip with
  # JANUS_DEPLOY_SKIP_MMDB=1 (loud); fail closed when geo is desired and
  # the file is still absent after ensure.
  if [ "${JANUS_DEPLOY_SKIP_MMDB:-0}" = "1" ]; then
    echo "WARNING: JANUS_DEPLOY_SKIP_MMDB=1 — skipping GeoLite2 fetch/wire on master" >&2
  elif is_bare "$LEADER"; then
    echo "== 3b. leader GeoLite2 mmdb ($LEADER, BARE shared tree) =="
    ensure_bare_leader_mmdb "$LEADER"
  else
    echo "== 3b. master GeoLite2 mmdb ($LEADER) =="
    bash scripts/ensure_master_mmdb.sh "$LEADER"
  fi

  # H1: the destructive phase. Re-assert ownership immediately before the
  # first node restart — a lock lost here must stop the rollout, not run
  # beside a concurrent deploy.
  renew_deploy_lock "leader rollout (step 4)"
  if is_bare "$LEADER"; then
    echo "== 4. leader rollout ($LEADER): BARE — current symlink -> $BARE_SHA_DIR + systemctl restart janus-gw =="
    roll_bare_gw "$LEADER"
    if ! wait_gateway_healthy "$LEADER"; then
      echo "FAIL: $LEADER gateway unhealthy after restart"
      collect_node_logs "$LEADER"
      cat "${DEPLOY_LOG_DIR}/$LEADER.log" 2>/dev/null | tail -30 || true
      exit 1
    fi
    verify_bare_node "$LEADER"
  else
    echo "== 4. leader rollout ($LEADER): recreate -> boot migrations -> verify =="
    refuse_compose "$LEADER" "docker compose up -d --force-recreate janus"
    ssh "$LEADER" 'cd /opt/stacks/janus && docker compose up -d --force-recreate janus >/dev/null 2>&1'
    if ! wait_gateway_healthy "$LEADER"; then
      echo "FAIL: $LEADER gateway unhealthy after restart"
      ssh "$LEADER" 'docker logs --tail 30 janus' 2>/dev/null || true
      exit 1
    fi
    verify_node_image "$LEADER"
    # H3: a host whose compose defines the co-located janus-worker must
    # recreate it as part of the SAME rollout — nothing else does, so it
    # used to keep the conversion-day artifact indefinitely. Registration is
    # asserted here (the leader is not a follower, so step 6 never covers it)
    # before any follower is touched.
    if has_co_located_worker "$LEADER"; then
      roll_co_located_worker "$LEADER"
      wait_co_located_worker_registered "$LEADER" || exit 1
      echo "   $LEADER: co-located janus-worker registered"
    fi
  fi
  # Postgres runs as the `postgres` container on the leader (janus-pg is the
  # LOCAL e2e container name — do not confuse them). Query through the
  # single psql seam (SQL on stdin, stderr kept) instead of interpolating
  # the value into a double-quoted remote command.
  APPLIED="$(leader_psql "SELECT version FROM schema_migrations WHERE version='$LATEST_MIGRATION';")" || {
    echo "FAIL: cannot read schema_migrations on $LEADER (psql diagnostic above)"
    exit 1
  }
  if [ "$APPLIED" != "$LATEST_MIGRATION" ]; then
    echo "FAIL: migration $LATEST_MIGRATION not applied on leader (got: '$APPLIED')"
    exit 1
  fi
  echo "   $LEADER: healthy, migration $LATEST_MIGRATION applied"

  # Soft-off detection: settings.sched.geo desired but mmdb still missing.
  GEO_DESIRED="$(leader_psql "SELECT COALESCE((value->>'geo')::text, 'false') FROM settings WHERE key = 'sched' LIMIT 1" | tr -d '[:space:]' || true)"
  if [ "$GEO_DESIRED" = "true" ] && [ "${JANUS_DEPLOY_SKIP_MMDB:-0}" != "1" ]; then
    MMDB_OK="$(fetch_master_sched \
      | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print("1" if d.get("mmdb_present") else "0")' 2>/dev/null || echo 0)"
    if [ "$MMDB_OK" != "1" ]; then
      echo "FAIL: settings.sched.geo=true but /stats/sched mmdb_present=false on $LEADER after recreate"
      echo "      check JANUS_MMDB_PATH mount + MaxMind credentials; see scripts/ensure_master_mmdb.sh"
      exit 1
    fi
    echo "   $LEADER: geo desired + mmdb_present=true"
  fi

  if [ "$SHIP_CLASS" = "config" ]; then
    # Capture rc explicitly — `else rc=$?` after `if fn` is unreliable across bash builds.
    capture_leader_generation
    rc=$?
    if [ "$rc" -eq 0 ]; then
      if [ "$LEADER_GEN" -lt "$GEN0" ]; then
        collect_node_logs "$LEADER"
        echo "FAIL: $LEADER /stats generation $LEADER_GEN < gen0 $GEN0 (catalog not applied); logs in ${DEPLOY_LOG_DIR}/$LEADER.log"
        exit 1
      fi
      echo "   leader generation=$LEADER_GEN (>= gen0=$GEN0)"
    else
      collect_node_logs "$LEADER"
      if [ "$rc" -eq 2 ]; then
        echo "FAIL: $LEADER /stats sustained 401 (check JANUS_STATS_TOKEN in remote /opt/stacks/janus/.env); node logs saved to ${DEPLOY_LOG_DIR}/$LEADER.log"
      else
        echo "FAIL: $LEADER generation not captured within ${WAIT_DEADLINE}s; node logs saved to ${DEPLOY_LOG_DIR}/$LEADER.log"
      fi
      exit 1
    fi
  fi

  renew_deploy_lock "follower rollout (step 5)"
  echo "== 5. follower rollout ($FOLLOWERS) =="
  for h in $FOLLOWERS; do
    if is_bare "$h"; then
      echo "   $h: BARE — current symlink -> $BARE_SHA_DIR + systemctl restart janus-gw"
      roll_bare_gw "$h"
      if wait_gateway_healthy "$h"; then
        verify_bare_node "$h"
        echo "   $h: healthy"
      else
        echo "FAIL: $h unhealthy"
        collect_node_logs "$h"
        exit 1
      fi
    else
      refuse_compose "$h" "docker compose up -d --force-recreate janus"
      ssh "$h" 'cd /opt/stacks/janus && docker compose up -d --force-recreate janus >/dev/null 2>&1'
      if wait_gateway_healthy "$h"; then
        verify_node_image "$h"
        # H3: same second-service rule as the leader (a follower normally has
        # none, but "wherever it exists" must hold on every host).
        if has_co_located_worker "$h"; then
          roll_co_located_worker "$h"
        fi
        echo "   $h: healthy"
      else
        echo "FAIL: $h unhealthy"
        exit 1
      fi
    fi
  done

  # ---- Slice D: parallel follower stats wait (both followers at once,
  # one shared deadline). On deadline/401 the node's docker logs are
  # captured and the deploy halts — no rollback, no skip. ----
  if [ "$SHIP_CLASS" = "config" ]; then
    echo "== 6. follower generation wait (parallel, ${WAIT_DEADLINE}s budget; need > gen0=$GEN0 or == leader=$LEADER_GEN, stable 2 polls) =="
    WAIT_NODES="$FOLLOWERS"
  else
    echo "== 6. restart verification via uptime_sec + image id (code-only, ${WAIT_DEADLINE}s budget, all nodes, stable 2 polls) =="
    WAIT_NODES="$ALL_HOSTS"
  fi
  RESULT_DIR="$(mktemp -d "${TEMP:-/tmp}/janus_deploy_wait.XXXXXX" 2>/dev/null)" || {
    # ${TEMP} not writable: any local 700 dir beats losing the verdicts.
    RESULT_DIR="$(mktemp -d)" || { echo "FAIL: cannot create a temp dir for follower results" >&2; exit 1; }
  }
  WAIT_DEADLINE_AT=$(( $(date +%s) + WAIT_DEADLINE ))
  # Collect each waiter's pid: a no-operand `wait` would discard every
  # background status, so a waiter killed before writing its verdict
  # would look like a missing file only. Per-pid wait + the "missing"
  # fallback below makes a dead waiter itself a failure.
  WAIT_PIDS=(); WAIT_HOSTS=()
  for h in $WAIT_NODES; do
    ( wait_follower "$h" "$RESULT_DIR/$h.res" ) &
    WAIT_PIDS+=("$!"); WAIT_HOSTS+=("$h")
  done
  for _wi in "${!WAIT_PIDS[@]}"; do
    _wrc=0
    wait "${WAIT_PIDS[$_wi]}" || _wrc=$?
    if [ "$_wrc" -ne 0 ] && [ ! -e "$RESULT_DIR/${WAIT_HOSTS[$_wi]}.res" ]; then
      printf 'waiter-exit-%s\n' "$_wrc" > "$RESULT_DIR/${WAIT_HOSTS[$_wi]}.res"
    fi
  done
  FAILED_NODES=""
  for h in $WAIT_NODES; do
    outcome="$(cat "$RESULT_DIR/$h.res" 2>/dev/null || echo missing)"
    if [ "$outcome" = "OK" ]; then
      echo "   $h: stats verified"
    else
      FAILED_NODES="$FAILED_NODES $h"
      collect_node_logs "$h"
      echo "FAIL: $h stats wait ended with '$outcome'; node logs saved to ${DEPLOY_LOG_DIR:-?}/$h.log"
    fi
  done
  if [ -n "$FAILED_NODES" ]; then
    # Leader appearing in WAIT_NODES (code-only ships) must stay hard-halt.
    case " $FAILED_NODES " in
      *" $LEADER "*)
        echo "FAIL: leader ($LEADER) stats wait failed — halting (no rollback)"
        exit 1
        ;;
    esac
    # H2: hard-halt by default (the documented contract above). The old
    # WARN-and-continue default let a fleet with one node on the old
    # artifact reach the dashboard ship + smoke; the explicit opt-out
    # still exits non-zero at the end (FOLLOWER_VERIFY_FAILED).
    if [ "${JANUS_DEPLOY_ALLOW_FOLLOWER_DRIFT:-0}" = "1" ]; then
      FOLLOWER_VERIFY_FAILED=1
      echo "WARN: follower verification failed for:$FAILED_NODES — continuing to dashboard ship + smoke (JANUS_DEPLOY_ALLOW_FOLLOWER_DRIFT=1; the run still exits 1)"
    else
      echo "FAIL: follower verification failed for:$FAILED_NODES — halting (no rollback, no skip)"
      echo "      (override for a deliberate drift-tolerant run: JANUS_DEPLOY_ALLOW_FOLLOWER_DRIFT=1)"
      exit 1
    fi
  fi

  # ---- v2.2 Part C: legacy-row egress retro-scan (knob-independent)
  # Runs AFTER the gateway containers rolled (migration 017 applied);
  # tolerates a missing allow_internal column (pre-column: base_url-only
  # report, no allow_internal conjunct). Providers whose base_url
  # resolves internal INSIDE THE GATEWAY CONTAINER NETWORK without
  # allow_internal are ENUMERATED and the deploy HALTS unless
  # JANUS_DEPLOY_ACK_INTERNAL=<sha256-of-this-enumeration> acknowledges
  # EXACTLY this list (a changed list re-halts — never a permanent
  # export). Resolution failure in the SCAN context is TREATED-INTERNAL
  # (fail-closed for the halt — a flaky resolver can only false-halt).
  # Nodes with non-loopback-literal stats_hosts lacking per-node
  # envelopes are REPORTED (warn) at every deploy while the egress
  # token policy is off.
  echo "== 6c. egress retro-scan (v2.2 Part B/C) =="
  # C1: FAIL CLOSED. Every step of this control is load-bearing: a
  # provider enumeration that never ran, an extractor that crashed, or a
  # classifier that failed must NOT look like "clean" — an empty result
  # is only meaningful when the step actually succeeded. DB errors stderr
  # is kept in $SCAN_TMP so the operator sees the cause.
  SCAN_TMP="$(mktemp -d "${TEMP:-/tmp}/janus_egress_scan.XXXXXX" 2>/dev/null)" || {
    echo "FAIL: egress retro-scan cannot create its work dir under ${TEMP:-/tmp} — failing closed" >&2
    exit 1
  }
  SCAN_ROWS=""
  if ! SCAN_ROWS="$(leader_psql "SELECT name, base_url, COALESCE(allow_internal, 0) FROM providers;" 2>"$SCAN_TMP/rows1.err")"; then
    # Pre-allow_internal-column leader: retry base_url-only. A failure of
    # BOTH projections is a failed scan, not an empty provider set.
    if ! SCAN_ROWS="$(leader_psql "SELECT name, base_url, 0 FROM providers;" 2>"$SCAN_TMP/rows2.err")"; then
      echo "FAIL: egress retro-scan could not read providers from $LEADER's Postgres — failing closed (the egress surface cannot be shown clean)" >&2
      sed 's/^/      /' "$SCAN_TMP/rows2.err" >&2 2>/dev/null || true
      rm -rf "$SCAN_TMP"
      exit 1
    fi
  fi
  printf '%s\n' "$SCAN_ROWS" > "$SCAN_TMP/rows.txt"
  # Host extraction via the dashboard's own helper (one rule set).
  _scan_rc=0
  "$PY" - "$SCAN_TMP" <<'SCANPY' >/dev/null 2>"$SCAN_TMP/extract.err" || _scan_rc=$?
import sys
sys.path.insert(0, ".")
from app import egress
tmp = sys.argv[1]
out_hosts, out_pairs = [], []
for line in open(f"{tmp}/rows.txt", encoding="utf-8", errors="replace"):
    parts = line.rstrip("\n").split("|")
    if len(parts) < 3 or not parts[0].strip():
        continue
    name, base_url, flagged = parts[0].strip(), parts[1].strip(), parts[2].strip()
    host = egress.host_of(base_url)
    if not host or flagged in ("1", "true"):
        continue
    out_pairs.append(f"{name}\t{host}")
    out_hosts.append(host)
open(f"{tmp}/pairs.tsv", "w", encoding="utf-8").write("\n".join(out_pairs) + "\n")
open(f"{tmp}/hosts.txt", "w", encoding="utf-8").write("\n".join(sorted(set(out_hosts))) + "\n")
SCANPY
  if [ "$_scan_rc" -ne 0 ]; then
    echo "FAIL: egress retro-scan host extraction failed (rc=$_scan_rc) — failing closed (the scan did not run)" >&2
    sed 's/^/      /' "$SCAN_TMP/extract.err" >&2 2>/dev/null || true
    rm -rf "$SCAN_TMP"
    exit 1
  fi
  # Resolve each unique host INSIDE the gateway's DNS context.
  # Runtime-aware (B-D5): a DOCKER leader resolves inside the gateway
  # container (busybox nslookup — verified present; bin/janus
  # eval/rpc cannot attach to the running distributed node). A BARE
  # leader resolves on the HOST — which is the bare gateway's ACTUAL
  # egress view: a compose-DNS-only name that answered inside the
  # container network now fails, classifies resolve-fail ->
  # treated-internal -> halt (fail-closed, and truthful: the bare
  # process could not reach it either). Skip line 1 (the resolver),
  # take every Address.
  : > "$SCAN_TMP/resolved.tsv"
  if [ -s "$SCAN_TMP/hosts.txt" ]; then
    while IFS= read -r SCAN_HOST; do
      [ -n "$SCAN_HOST" ] || continue
      SAFE_HOST="$(printf '%s' "$SCAN_HOST" | tr -cd 'A-Za-z0-9.:-')"
      [ -n "$SAFE_HOST" ] || continue
      OUT=""
      for _attempt in 1 2 3; do
        # </dev/null is ESSENTIAL: ssh inside a read-from-file
        # loop otherwise consumes the loop stdin (hosts.txt) — the
        # classic swallow bug; every host after the first got EOF.
        if is_bare "$LEADER"; then
          OUT="$(ssh "$LEADER" "getent hosts $SAFE_HOST 2>/dev/null | awk '{print \$1}' || nslookup $SAFE_HOST 2>/dev/null | awk '/^Address:/{n++; if (n>1) print \$NF}'" </dev/null)"
        else
          OUT="$(ssh "$LEADER" "timeout 8 docker exec janus nslookup $SAFE_HOST 2>/dev/null" </dev/null | awk '/^Address:/{n++; if (n>1) print $NF}')"
        fi
        [ -n "${OUT// /}" ] && break
        sleep 2
      done
      [ -n "${OUT// /}" ] || OUT="resolve_fail"
      printf '%s\t%s\n' "$SAFE_HOST" "${OUT:-SCAN_FAIL}" >> "$SCAN_TMP/resolved.tsv"
    done < "$SCAN_TMP/hosts.txt"
  fi
  # Classification via the dashboard module (IP literals classify with
  # no resolver call; ANY internal record => internal; failures treated
  # internal). One python call over the resolved table.
  _scan_rc=0
  "$PY" - "$SCAN_TMP" <<'SCANPY2' > "$SCAN_TMP/internal.txt" 2>"$SCAN_TMP/classify.err" || _scan_rc=$?
import re
import sys
sys.path.insert(0, ".")
from app import egress
tmp = sys.argv[1]
resolved = {}
for line in open(f"{tmp}/resolved.tsv", encoding="utf-8", errors="replace"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) >= 2:
        resolved[parts[0]] = parts[1]
for line in open(f"{tmp}/pairs.tsv", encoding="utf-8", errors="replace"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 2:
        continue
    name, host = parts[0], parts[1]
    addrs = resolved.get(host, "SCAN_FAIL")
    if addrs in ("resolve_fail", "SCAN_FAIL", ""):
        print(f"{name}|{host}|resolution-failed (treated-internal)")
        continue
    ips = [ip for ip in re.findall(r"[0-9a-fA-F:.]+", addrs) if ":" in ip or "." in ip]
    if not ips:
        print(f"{name}|{host}|no addresses (treated-internal)")
        continue
    verdicts = [egress.is_internal_sockaddr(ip) for ip in ips]
    if any(v is True for v in verdicts):
        print(f"{name}|{host}|{','.join(ips)}")
    elif any(v is not False for v in verdicts):
        print(f"{name}|{host}|unparseable {addrs} (treated-internal)")
SCANPY2
  if [ "$_scan_rc" -ne 0 ]; then
    echo "FAIL: egress retro-scan classification failed (rc=$_scan_rc) — failing closed; an unclassified surface is never 'clean'" >&2
    sed 's/^/      /' "$SCAN_TMP/classify.err" >&2 2>/dev/null || true
    rm -rf "$SCAN_TMP"
    exit 1
  fi
  INTERNAL_COUNT=0
  if [ -s "$SCAN_TMP/internal.txt" ]; then
    INTERNAL_COUNT="$(wc -l < "$SCAN_TMP/internal.txt" | tr -d '[:space:]')"
  fi
  if [ "$INTERNAL_COUNT" != "0" ]; then
    sort -u "$SCAN_TMP/internal.txt" > "$SCAN_TMP/internal.sorted" || cp "$SCAN_TMP/internal.txt" "$SCAN_TMP/internal.sorted"
    INTERNAL_COUNT="$(wc -l < "$SCAN_TMP/internal.sorted" | tr -d '[:space:]')"
    INTERNAL_SHA="$(sha256sum "$SCAN_TMP/internal.sorted" | awk '{print $1}')"
    echo "   !! egress retro-scan: $INTERNAL_COUNT provider(s) with internal/unresolvable base_url and NO allow_internal:"
    sed 's/^/      - /' "$SCAN_TMP/internal.sorted"
    if [ "${JANUS_DEPLOY_ACK_INTERNAL:-}" != "$INTERNAL_SHA" ]; then
      echo "FAIL: refusing to deploy past an unacknowledged internal-egress surface."
      echo "      ack EXACTLY this list for THIS deploy with:"
      echo "        JANUS_DEPLOY_ACK_INTERNAL=$INTERNAL_SHA bash scripts/deploy_prod.sh ..."
      echo "      (a changed list needs a fresh ack — never a permanent export)"
      rm -rf "$SCAN_TMP"
      exit 1
    fi
    echo "   acknowledged via JANUS_DEPLOY_ACK_INTERNAL (this deploy's list sha)"
  else
    echo "   egress retro-scan: no internal base_url without allow_internal (clean)"
  fi
  if [ "$EGRESS_POLICY_ON" != "1" ]; then
    # Knob-off legacy caveat: these nodes keep receiving the global
    # token until the policy flips; report at every deploy.
    while IFS='|' read -r n shost _sport stok; do
      [ -n "$n" ] || continue
      if [ -z "$stok" ] && ! loopback_literal "$shost"; then
        echo "   WARN (egress policy off): node $n stats_host=$shost has no per-node token — still using the global one"
      fi
    done <<EOF2
$NODE_STATS
EOF2
  fi
  rm -rf "$SCAN_TMP"

  renew_deploy_lock "dashboard ship (step 7)"
  if [ "$DASH_BARE_SHIP" -eq 1 ]; then
    echo "== 7. ship BARE dashboard to $LEADER (install_bare_dashboard.sh, payload $(basename "$DASH_PAYLOAD")) =="
    # The dashboard half of the JANUS_DASH_BARE seam: install_bare_
    # dashboard.sh re-verifies the seam key, regenerates the F2
    # envfile from the node's compose dashboard service, renders the
    # unit, ships the payload + venv (--no-index, F5b), swaps
    # $PREFIX/dash/current, restarts janus-dash, and asserts
    # /api/health. Idempotent per sha.
    # The installer verifies and ships the payload itself (06b H1): it runs
    # the F7 floor gate, the BUILD-FACTS py3-coverage check and the
    # payload-shape checks on the node before switching anything.
    if [ "${JANUS_DEPLOY_SHIP:-git}" = git ] && [ -n "${JANUS_DASH_GIT_REMOTE:-}" ]; then
      # Git mode: the LEADER clones the dashboard repo and builds the
      # wheelhouse payload LOCALLY (pip/npm via the CN mirrors the env
      # provides); no payload crosses hosts.
      echo "   leader git ship: clone+build dashboard payload on $LEADER"
      # The leader clone has no inventory; pass this run's distinct
      # target py minors (JANUS_NODE_* py3=) explicitly — without them
      # build_bare_dashboard refuses ("no target py3 minors"). The
      # digest-pinned builder images (JANUS_PY_BUILDER_<X_Y>=...) flow
      # from the local inventory for the same reason (F7/H2 pin gate).
      _py3_args=""
      for _m in $(sed -n "s/^JANUS_NODE_[A-Z0-9_]*='[^']*py3=\([0-9][0-9.]*\)[^']*'/\1/p" "$INV" 2>/dev/null | sort -u); do
        _py3_args="$_py3_args --py3 $_m"
      done
      _builder_env=""
      while IFS='=' read -r _k _v; do
        [ -n "$_v" ] && _builder_env="$_builder_env $_k='$_v'"
      done < <(grep -E '^JANUS_PY_BUILDER_[0-9]+_[0-9]+=' "$INV" 2>/dev/null)
      _dash_sha8="$(ssh -o BatchMode=yes "$LEADER" "set -e
        mkdir -p '$BARE_PREFIX/src'
        if [ ! -d '$BARE_PREFIX/src/janus-dashboard/.git' ]; then
          git clone -q '${JANUS_DASH_GIT_REMOTE}' '$BARE_PREFIX/src/janus-dashboard'
        fi
        cd '$BARE_PREFIX/src/janus-dashboard'
        git fetch -q origin && git checkout -q origin/main
        PIP_INDEX_URL='${JANUS_DEPLOY_PIP_INDEX:-https://mirrors.aliyun.com/pypi/simple/}'         NPM_CONFIG_REGISTRY='${JANUS_DEPLOY_NPM_REGISTRY:-https://registry.npmmirror.com}'         env $_builder_env bash scripts/build_bare_dashboard.sh $_py3_args >/tmp/dash-build.log 2>&1 || { tail -5 /tmp/dash-build.log >&2; exit 1; }
        basename \$(ls -dt bare-artifacts/dash/dash-* | head -1) | sed s/^dash-//" )" || { echo "FAIL: leader-side dashboard git build failed"; exit 1; }
      ssh -o BatchMode=yes "$LEADER" "set -e; ln -sfn dash-$_dash_sha8 '$BARE_PREFIX/dash/current'; mkdir -p '$BARE_PREFIX/dash'; [ -d '$BARE_PREFIX/dash/dash-$_dash_sha8' ] || cp -a '$BARE_PREFIX/src/janus-dashboard/bare-artifacts/dash/dash-$_dash_sha8' '$BARE_PREFIX/dash/'; chown -R $BARE_USER:$BARE_USER '$BARE_PREFIX/dash/dash-$_dash_sha8'"
    fi
    # 06b H1: run the installer WITH the payload so the node-side checks
    # actually execute. The installer ships it itself (tar|ssh), so the old
    # pre-ship here is gone — it would only double-transfer. Git mode has no
    # local payload dir, so it uses the installer's documented refresh-only
    # escape; a node-side --payload-remote resolver is the follow-up that
    # would let the validations run there too.
    if [ -n "${DASH_PAYLOAD:-}" ] && [ -d "${DASH_PAYLOAD:-}" ]; then
      JANUS_DASH_PAYLOAD_DIR="$DASH_PAYLOAD" bash scripts/install_bare_dashboard.sh "${NODE_INVNAME[$LEADER]}"
    else
      bash scripts/install_bare_dashboard.sh --allow-no-payload "${NODE_INVNAME[$LEADER]}"
    fi
  else
    echo "== 7. ship dashboard image to $LEADER =="
    # NO refuse_compose here, deliberately: this branch runs only when
    # DASH_BARE_SHIP=0, i.e. the JANUS_DASH_BARE seam is NOT armed for
    # this leader — per Task-1 deviation 4 / sequencing §4 the COMPOSE
    # dashboard service is then the intended runtime even on a
    # bare-GATEWAY leader (the F1 override disables the gw service
    # alone until the seam flips). F1 layer 2 refuses GATEWAY compose
    # actions (steps 4/5); the dashboard compose action is legal here.
    docker save janus-dashboard:latest | gzip -1 | ssh "$LEADER" \
      "docker load >/dev/null 2>&1; cd /opt/stacks/janus && docker compose up -d dashboard" >/dev/null 2>&1
    sleep 8
  fi
fi

echo "== 8. READ-ONLY production smoke (curl live-check) =="
# Replaces the old run_test_flows --smoke (suite deleted 2026-10-18).
# Read-only: health + authenticated GETs on both planes + the public
# model surface. No mutations, no chats, no metrics scrapes.
SMOKE_RC=0
smoke_fail() { echo "   FAIL $*"; SMOKE_RC=1; }
smoke_code() { curl -s -o /dev/null -w '%{http_code}' -m 15 "$@"; }

CODE="$(smoke_code "$JANUS_DASH/api/health")"
[ "$CODE" = 200 ] && echo "   ok   dashboard /api/health (200)" \
  || smoke_fail "dashboard /api/health ($CODE)"
SMOKE_JWT="$("$PY" - "$JANUS_DASH_PASSWORD" "$JANUS_DASH" <<'PY'
import json, sys, urllib.request
body = json.dumps({"password": sys.argv[1]}).encode()
r = urllib.request.Request(f"{sys.argv[2]}/api/auth/login", data=body,
                           headers={"content-type": "application/json"})
try:
    with urllib.request.urlopen(r, timeout=15) as resp:
        print(json.loads(resp.read()).get("token", ""))
except Exception:
    print("")
PY
)"
if [ -n "$SMOKE_JWT" ]; then
  echo "   ok   dashboard login (token issued)"
else
  smoke_fail "dashboard login"
fi
for ep in "api/overview" "api/nodes" "api/alerts" "api/models"; do
  CODE="$(smoke_code -H "authorization: Bearer $SMOKE_JWT" "$JANUS_DASH/$ep")"
  [ "$CODE" = 200 ] && echo "   ok   GET /$ep (200)" || smoke_fail "GET /$ep ($CODE)"
done
CODE="$(smoke_code -H "authorization: Bearer $JANUS_AK" "$JANUS_DASH/v1/models")"
[ "$CODE" = 200 ] && echo "   ok   GET /v1/models with agent key (200)" \
  || smoke_fail "GET /v1/models with agent key ($CODE)"

if [ "$SMOKE_ONLY" -eq 0 ]; then
  # Record this deploy's gateway HEAD for the next run's ship-class
  # detection. Only a fully successful pipeline updates the marker; a
  # failed deploy leaves the old one so the next run full-waits.
  if [ "$SMOKE_RC" -eq 0 ] && [ "$FOLLOWER_VERIFY_FAILED" -eq 0 ] \
     && git -C "$GW_SRC" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    git -C "$GW_SRC" rev-parse HEAD >"$LAST_DEPLOY_HEAD" 2>/dev/null || true
    echo "   recorded deployed gateway HEAD in $LAST_DEPLOY_HEAD"
  fi
fi

if [ "$SMOKE_RC" -ne 0 ]; then
  exit "$SMOKE_RC"
fi
if [ "$FOLLOWER_VERIFY_FAILED" -ne 0 ]; then
  echo "FAIL: deploy completed dashboard+smoke but follower verification failed earlier — exit 1"
  exit 1
fi
