#!/usr/bin/env bash
# janus_topology.sh — operator-side topology (leader host) resolution.
# Spec: docs/superpowers/specs/2026-10-15-maturity-hardening.md
#       H3-D7 (topology contract) + H4 (deploy pipeline plumbing).
#
# The topology names the CURRENT leader host. It lives OPERATOR-SIDE and
# DURABLY, mirrored at BOTH deploy origins — the dev-box ops path
# (~/.janus/topology) and the CI runner's persistent /opt/janus-ci/topology
# (a CI workspace file dies with a runner reimage; the /opt path does not)
# — and NEVER as an authoritative copy on a cluster node: a node-local
# copy goes stale exactly when a promote swaps roles. The H3 promote
# script writes BOTH mirrors before the DNS repoint (under the deploy
# lock); deploy/backup scripts REFUSE when no copy exists — never
# silently default to aliyun.
#
# File format (idempotent — one leader): comment header + one host line:
#     # <header comment>
#     aliyun
# A `leader=<host>` prefix is tolerated on read.
#
# Resolution order (first hit wins, no fallthrough past an existing file):
#   1. $JANUS_TOPOLOGY_FILE   — explicit file override (also the sanctioned
#      pointer for the on-leader backup timer: set it in janus-backup.env)
#   2. $JANUS_TOPOLOGY_LEADER — literal host value. For on-node contexts
#      (backup timer) where no operator-side FILE can exist: the value
#      rides the node's own janus-backup.env (node config — the topology
#      ARTIFACT still lives only at the deploy origins).
#   3. ~/.janus/topology      — dev-box ops mirror
#   4. /opt/janus-ci/topology — runner persistent mirror
#   else REFUSE: message to stderr + return 2 (H3-D7 refuse-guard).
#
# Functions:
#   topology_read                 -> prints leader host (rc 2 = refuse)
#   topology_source               -> prints which source resolved (or -)
#   topology_write_leader <host>  -> writes BOTH mirrors (best-effort
#                                    second; >=1 success = rc 0)
#   topology_probe_leader <host>  -> single-shot healthz probe over SSH
#                                    (BatchMode; rc 0 = healthy)
#   topology_psql <SQL>           -> THE single overridable psql seam:
#                                    JANUS_DEPLOY_PG set -> local
#                                    `docker exec $JANUS_DEPLOY_PG psql`
#                                    (local proofs / e2e stack); else SSH
#                                    to the topology leader's postgres
#                                    container. Users/db overridable via
#                                    JANUS_PG_USER / JANUS_PG_DB.
#                                    The SQL travels on STDIN (`psql -f -`):
#                                    no shell re-parses it, so quotes/
#                                    backticks reach psql verbatim, and
#                                    psql diagnostics stay on stderr.

# Mirror paths (the two deploy origins, H3-D7).
JANUS_TOPOLOGY_FILE="${JANUS_TOPOLOGY_FILE:-}"
JANUS_TOPOLOGY_LEADER="${JANUS_TOPOLOGY_LEADER:-}"
JANUS_TOPOLOGY_DEV_MIRROR="${JANUS_TOPOLOGY_DEV_MIRROR:-$HOME/.janus/topology}"
JANUS_TOPOLOGY_CI_MIRROR="${JANUS_TOPOLOGY_CI_MIRROR:-/opt/janus-ci/topology}"

# _topology_resolve -> prints "<host>\t<source>" for the winning source.
# A file that EXISTS is authoritative: malformed content refuses instead
# of falling through to another mirror (never silently default).
_topology_resolve() {
  local f="$JANUS_TOPOLOGY_FILE" line
  if [ -n "$f" ]; then
    if [ ! -f "$f" ]; then
      echo "topology: JANUS_TOPOLOGY_FILE=$f does not exist" >&2
      return 2
    fi
    line="$(_topology_parse "$f")" || return 2
    printf '%s\t%s\n' "$line" "$f"
    return 0
  fi
  if [ -n "${JANUS_TOPOLOGY_LEADER:-}" ]; then
    printf '%s\t%s\n' "$JANUS_TOPOLOGY_LEADER" 'JANUS_TOPOLOGY_LEADER'
    return 0
  fi
  for f in "$JANUS_TOPOLOGY_DEV_MIRROR" "$JANUS_TOPOLOGY_CI_MIRROR"; do
    if [ -f "$f" ]; then
      line="$(_topology_parse "$f")" || return 2
      printf '%s\t%s\n' "$line" "$f"
      return 0
    fi
  done
  return 2
}

# Parse one topology file -> prints the leader host. rc 2 when malformed.
_topology_parse() {  # $1 = file
  local f="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    case "$line" in leader=*) line="${line#leader=}" ;; esac
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *[!A-Za-z0-9._-]*)
        echo "topology: malformed leader line in $f: '$line'" >&2
        return 2 ;;
    esac
    printf '%s\n' "$line"
    return 0
  done <"$f"
  echo "topology: $f exists but carries no leader line" >&2
  return 2
}

topology_read() {
  local out rc=0
  out="$(_topology_resolve)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat >&2 <<EOF
topology: NO topology file found (H3-D7 refuse-guard: never defaulting to aliyun).
   looked for: JANUS_TOPOLOGY_FILE='${JANUS_TOPOLOGY_FILE:-}' (env),
                JANUS_TOPOLOGY_LEADER (env),
                $JANUS_TOPOLOGY_DEV_MIRROR (dev-box mirror),
                $JANUS_TOPOLOGY_CI_MIRROR (runner mirror)
   bootstrap first-run from a deploy origin:
       bash scripts/deploy_prod.sh --init-topology <leader-host> ...
   on-node backup timer: set JANUS_TOPOLOGY_FILE (or JANUS_TOPOLOGY_LEADER)
   in /opt/stacks/janus/janus-backup.env to the current leader.
EOF
    return "$rc"
  fi
  printf '%s\n' "${out%%$'\t'*}"
}
topology_source() {
  local out
  out="$(_topology_resolve 2>/dev/null)" || { echo '-'; return 0; }
  printf '%s\n' "${out#*$'\t'}"
}

# topology_write_leader <host> — write BOTH origin mirrors (mkdir -p;
# idempotent content = fixed comment header + the host line). The SECOND
# mirror is best-effort with a warning (e.g. dev box has no /opt/janus-ci
# perms; runner has no ~/.janus ops path): rc 0 when at least one mirror
# was written and read back correctly, rc 1 when both failed.
topology_write_leader() {
  local host="$1" wrote=0 f ok
  case "$host" in
    ''|*[!A-Za-z0-9._-]*)
      echo "topology: refusing to write malformed leader host '$host'" >&2
      return 1 ;;
  esac
  for f in "$JANUS_TOPOLOGY_DEV_MIRROR" "$JANUS_TOPOLOGY_CI_MIRROR"; do
    # Only create the mirror directory when its parent already exists —
    # never mkdir -p across an absent root (a dev box must not sprout
    # /opt/... inside its Git-Bash install tree; the runner's
    # /opt/janus-ci is operator-provisioned and persistent).
    local d
    d="$(dirname "$f")"
    if [ ! -d "$(dirname "$d")" ]; then
      echo "topology: WARN: skipping mirror $f (no $(dirname "$d") here — this mirror belongs to the other deploy origin)" >&2
      continue
    fi
    if ! mkdir -p "$d" 2>/dev/null; then
      echo "topology: WARN: cannot create $d (no perms) — skipping mirror $f" >&2
      continue
    fi
    {
      echo "# Janus deploy topology mirror — the CURRENT leader host (H3-D7)."
      echo "# Managed by scripts/lib/janus_topology.sh (bootstrap: deploy_prod.sh --init-topology <host>; promote writes both mirrors)."
      echo "$host"
    } >"$f" || { echo "topology: WARN: cannot write $f" >&2; continue; }
    ok="$(_topology_parse "$f" 2>/dev/null || true)"
    if [ "$ok" = "$host" ]; then
      echo "topology: wrote mirror $f -> leader=$host"
      wrote=1
    else
      echo "topology: WARN: read-back of $f failed" >&2
    fi
  done
  [ "$wrote" -eq 1 ] || { echo "topology: FAILED to write any mirror" >&2; return 1; }
  return 0
}

# topology_probe_leader <host> — single-shot healthz probe over SSH
# (BatchMode: fail fast, never prompt). Same probe set as the deploy's
# wait_gateway_healthy, but no retry loop: this is the PRE-FLIGHT gate
# (H3-D7: a topology naming a fenced/dead leader must refuse, not ship).
topology_probe_leader() {
  local h="$1"
  [ -n "$h" ] || return 1
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$h" \
    'curl -s -m 3 http://127.0.0.1:48080/healthz >/dev/null 2>&1 ||
     docker exec janus curl -s -m 3 http://127.0.0.1:8080/healthz >/dev/null 2>&1 ||
     [ "$(docker inspect --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" janus 2>/dev/null)" = "healthy" ]' \
    >/dev/null 2>&1
}

# topology_psql <SQL> — the single overridable psql seam against the
# LEADER's Postgres (same shape as deploy_prod.sh leader_psql: psql -t -A
# inside the postgres container). JANUS_DEPLOY_PG set => run LOCALLY via
# `docker exec $JANUS_DEPLOY_PG psql` (e2e stack / lock proofs, no SSH).
topology_psql() {
  local sql="$1" u="${JANUS_PG_USER:-janus}" db="${JANUS_PG_DB:-janus}" leader
  if [ -n "${JANUS_DEPLOY_PG:-}" ]; then
    printf '%s\n' "$sql" | docker exec -i "$JANUS_DEPLOY_PG" psql -U "$u" -d "$db" -t -A -f -
    return $?
  fi
  leader="$(topology_read)" || return 1
  # SQL (and the user/db names) go over stdin to `psql -f -`: the remote
  # shell sees only this fixed command line, so the statement is never
  # re-parsed by a second shell. stderr is deliberately NOT discarded —
  # callers can distinguish "psql failed" from "no rows" and show the
  # actual PostgreSQL diagnostic instead of a bare UNREADABLE.
  printf '%s\n' "$sql" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$leader" \
    "docker exec -i postgres psql -U '$u' -d '$db' -t -A -f -"
}
