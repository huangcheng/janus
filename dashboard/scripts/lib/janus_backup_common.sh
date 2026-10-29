#!/usr/bin/env bash
# Shared helpers for backup_leader.sh / restore_leader.sh.
# Spec: janus docs/superpowers/specs/2026-10-08-leader-backup-restore-design.md (rev 6)
# shellcheck shell=bash

set -euo pipefail

JANUS_STACK_DIR="${JANUS_STACK_DIR:-/opt/stacks/janus}"
JANUS_ENV_FILE="${JANUS_ENV_FILE:-${JANUS_STACK_DIR}/.env}"
JANUS_BACKUP_HOT_DIR="${JANUS_BACKUP_HOT_DIR:-/var/backups/janus}"
JANUS_BACKUP_LOCK="${JANUS_BACKUP_LOCK:-/var/lock/janus-backup.lock}"
JANUS_BACKUP_LOG_DIR="${JANUS_BACKUP_LOG_DIR:-/var/log/janus-backup}"
JANUS_COMPOSE_PROJECT_DIR="${JANUS_COMPOSE_PROJECT_DIR:-${JANUS_STACK_DIR}}"
JANUS_POSTGRES_CONTAINER="${JANUS_POSTGRES_CONTAINER:-postgres}"
JANUS_PG_USER="${JANUS_PG_USER:-janus}"
JANUS_PG_DB="${JANUS_PG_DB:-janus}"
JANUS_GATEWAY_SERVICE="${JANUS_GATEWAY_SERVICE:-janus}"
JANUS_DASHBOARD_SERVICE="${JANUS_DASHBOARD_SERVICE:-dashboard}"
PEPPER_CANARY_SALT="janus-pepper-canary-v1"

_log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[$ts] $*" >&2
  mkdir -p "$JANUS_BACKUP_LOG_DIR"
  echo "[$ts] $*" >>"${JANUS_BACKUP_LOG_DIR}/backup.log"
}

die() {
  local code="$1"
  shift
  _log "ERROR ($code): $*"
  exit "$code"
}

alert() {
  local msg="$1"
  _log "ALERT: $msg"
  if [[ -n "${JANUS_BACKUP_ALERT_URL:-}" ]]; then
    # 06a L9: an incoming-webhook URL is a bearer capability. Feed it to
    # curl as a --config stream so neither the URL nor the JSON body is in
    # argv (readable via ps / process-argv logs for the 10s the alert lives).
    curl -sS -m 10 --config <(printf 'url = "%s"\n' "$JANUS_BACKUP_ALERT_URL") \
      -H 'Content-Type: application/json' \
      --data-binary @- >/dev/null 2>&1 \
      <<<"$(python3 -c 'import json,sys; print(json.dumps({"text":sys.argv[1]}))' "$msg")" \
      || _log "alert POST failed"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die 1 "missing command: $1"
}

load_backup_env() {
  local f="${JANUS_BACKUP_ENV_FILE:-/opt/stacks/janus/janus-backup.env}"
  if [[ -f "$f" ]]; then
    # Preserve critical process env across source (do not let a compromised
    # janus-backup.env clobber PATH / SSH agent).
    local _save_path="$PATH"
    local _save_ssh="${SSH_AUTH_SOCK:-}"
    local _save_ld="${LD_LIBRARY_PATH:-}"
    # shellcheck disable=SC1090
    set -a
    # shellcheck disable=SC1090
    source "$f"
    set +a
    PATH="$_save_path"
    export PATH
    if [[ -n "$_save_ssh" ]]; then export SSH_AUTH_SOCK="$_save_ssh"; else unset SSH_AUTH_SOCK || true; fi
    if [[ -n "$_save_ld" ]]; then export LD_LIBRARY_PATH="$_save_ld"; else unset LD_LIBRARY_PATH || true; fi
  fi
}

acquire_lock() {
  mkdir -p "$(dirname "$JANUS_BACKUP_LOCK")"
  exec 9>"$JANUS_BACKUP_LOCK"
  if ! flock -n 9; then
    die 1 "backup/restore lock held: $JANUS_BACKUP_LOCK"
  fi
}

shred_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  if command -v shred >/dev/null 2>&1; then
    shred -u "$f" 2>/dev/null || rm -f "$f"
  else
    rm -f "$f"
  fi
}

# Disk free bytes on path's filesystem.
disk_free_bytes() {
  local path="$1"
  df -PB1 "$path" 2>/dev/null | awk 'NR==2{print $4}'
}

# B13 backup: free >= 5× db_size
assert_backup_disk() {
  local db_size="$1"
  local free
  mkdir -p "$JANUS_BACKUP_HOT_DIR"
  free="$(disk_free_bytes "$JANUS_BACKUP_HOT_DIR")"
  local need=$((db_size * 5))
  if [[ -z "$free" || "$free" -lt "$need" ]]; then
    die 17 "backup disk short: free=${free:-?} need>=${need} (5× db_size=${db_size})"
  fi
}

# B13 restore: free >= db_size×3 + 1GiB
assert_restore_disk() {
  local db_size="$1"
  local free need
  mkdir -p "$JANUS_BACKUP_HOT_DIR"
  free="$(disk_free_bytes "$JANUS_BACKUP_HOT_DIR")"
  need=$((db_size * 3 + 1073741824))
  if [[ -z "$free" || "$free" -lt "$need" ]]; then
    die 17 "restore disk short: free=${free:-?} need>=${need}"
  fi
}

pepper_canary_hash() {
  local pepper="$1"
  printf '%s%s' "$PEPPER_CANARY_SALT" "$pepper" | openssl dgst -sha256 -hex | awk '{print $NF}'
}

env_get() {
  local key="$1" file="$2"
  python3 - "$key" "$file" <<'PY'
import sys
key, path = sys.argv[1], sys.argv[2]
value = ""
with open(path, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k.strip() == key:
            # Last match wins — dotenv/Docker Compose semantics (06a L5).
            # backup_leader.sh appends JANUS_SECRETS_GENERATION_ID to .env,
            # so a stale empty placeholder above the appended line must not
            # win (first-match would re-mint the SID on every run).
            value = v.strip().strip('"').strip("'")
print(value)
PY
}

compose() {
  (cd "$JANUS_COMPOSE_PROJECT_DIR" && docker compose "$@")
}

pg_exec() {
  docker exec "$JANUS_POSTGRES_CONTAINER" psql -U "$JANUS_PG_USER" -d "$JANUS_PG_DB" -t -A -c "$1"
}

# Same as pg_exec, with psql -v variables: callers pass values as
#   pg_exec_v 'SELECT ... :'ts' ...' -v ts="$value"
# so locally generated strings (hostname, stem, sha) are quoted by psql
# instead of being interpolated into SQL text (06a L3).
pg_exec_v() {
  local sql="$1"
  shift
  docker exec "$JANUS_POSTGRES_CONTAINER" psql -U "$JANUS_PG_USER" -d "$JANUS_PG_DB" -t -A "$@" -c "$sql"
}

utc_stem() {
  date -u +%Y%m%dT%H%M%SZ
}

image_digest_for() {
  # Prefer RepoDigest (repo@sha256:…); else image Id. Prints: FORM|VALUE
  local image="$1"
  python3 - "$image" <<'PY'
import json, subprocess, sys
img = sys.argv[1]
raw = subprocess.check_output(["docker", "inspect", img], text=True)
data = json.loads(raw)[0]
digests = data.get("RepoDigests") or []
if digests:
    # Prefer exact match on image name prefix when possible
    chosen = digests[0]
    for d in digests:
        if d.split("@", 1)[0] in img or img.split(":")[0] in d:
            chosen = d
            break
    print(f"RepoDigest|{chosen}")
else:
    print(f"Id|{data['Id']}")
PY
}

stats_generation() {
  # Best-effort: curl local :48090/stats (host-mapped admin) with bearer token.
  # Token stays in the environment (os.environ), never argv — not visible in ps.
  local token="${JANUS_STATS_TOKEN:-}"
  local url="${1:-http://127.0.0.1:48090/stats}"
  [[ -n "$token" ]] || return 1
  python3 - "$url" <<'PY'
import json, os, sys, urllib.request
url = sys.argv[1]
token = os.environ["JANUS_STATS_TOKEN"]
req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
try:
    with urllib.request.urlopen(req, timeout=5) as r:
        body = json.load(r)
    gen = body.get("generation")
    if gen is None:
        sys.exit(1)
    print(int(gen))
except Exception:
    sys.exit(1)
PY
}

follower_stats_generation() {
  local host="$1"
  # H1 (spec 2026-10-15): nodes carry PER-NODE stats tokens in their
  # own /opt/stacks/janus/.env — read the token FROM THE TARGET HOST
  # (the global JANUS_STATS_TOKEN is only valid on un-rotated nodes).
  # Resolved on the remote, then fed to curl on stdin (-H @-) — never argv.
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" \
    'tok=$(grep ^JANUS_STATS_TOKEN= /opt/stacks/janus/.env | cut -d= -f2-);
     [ -n "$tok" ] || exit 1;
     printf "Authorization: Bearer %s\n" "$tok" | curl -s -m 5 -H @- http://127.0.0.1:48090/stats' \
    2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d["generation"]))' 2>/dev/null
}

_aws_env() {
  # Always prefer backup-specific keys when set (endpoint or not).
  AWS_ACCESS_KEY_ID="${JANUS_BACKUP_S3_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}" \
    AWS_SECRET_ACCESS_KEY="${JANUS_BACKUP_S3_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}" \
    "$@"
}

upload_cold() {
  # Uploads local file to cold. Prefers rclone remote, then aws s3, else cold dir copy.
  local src="$1"
  local rel="$2" # e.g. janus-backups/2026/10/janus-....dump.age
  if [[ -n "${JANUS_BACKUP_RCLONE_REMOTE:-}" ]]; then
    rclone copyto "$src" "${JANUS_BACKUP_RCLONE_REMOTE}/${rel}"
    return
  fi
  if [[ -n "${JANUS_BACKUP_S3_BUCKET:-}" ]]; then
    local args=(s3 cp "$src" "s3://${JANUS_BACKUP_S3_BUCKET}/${rel}")
    if [[ -n "${JANUS_BACKUP_S3_ENDPOINT:-}" ]]; then
      args=(--endpoint-url "$JANUS_BACKUP_S3_ENDPOINT" "${args[@]}")
    fi
    _aws_env aws "${args[@]}"
    return
  fi
  local cold="${JANUS_BACKUP_COLD_DIR:-}"
  [[ -n "$cold" ]] || die 1 "no cold store configured (set JANUS_BACKUP_S3_BUCKET, JANUS_BACKUP_RCLONE_REMOTE, or JANUS_BACKUP_COLD_DIR)"
  mkdir -p "$(dirname "$cold/$rel")"
  cp -f "$src" "$cold/$rel"
}

# Download one cold object. Returns 0 on success, non-zero on miss/fail.
# Does NOT call die — callers aggregate exit codes for the generation set.
download_cold() {
  local rel="$1"
  local dest="$2"
  if [[ -n "${JANUS_BACKUP_RCLONE_REMOTE:-}" ]]; then
    rclone copyto "${JANUS_BACKUP_RCLONE_REMOTE}/${rel}" "$dest"
    return
  fi
  if [[ -n "${JANUS_BACKUP_S3_BUCKET:-}" ]]; then
    local args=(s3 cp "s3://${JANUS_BACKUP_S3_BUCKET}/${rel}" "$dest")
    if [[ -n "${JANUS_BACKUP_S3_ENDPOINT:-}" ]]; then
      args=(--endpoint-url "$JANUS_BACKUP_S3_ENDPOINT" "${args[@]}")
    fi
    _aws_env aws "${args[@]}"
    return
  fi
  local cold="${JANUS_BACKUP_COLD_DIR:-}"
  if [[ -z "$cold" || ! -f "$cold/$rel" ]]; then
    return 10
  fi
  cp -f "$cold/$rel" "$dest"
}

verify_cold_present() {
  local rel="$1"
  local base="${rel##*/}" listing size_json bytes
  if [[ -n "${JANUS_BACKUP_RCLONE_REMOTE:-}" ]]; then
    # 06a H2: bucket-backed remotes resolve a missing object as an empty
    # prefix and exit 0, so `lsf >/dev/null` could never fail. Require the
    # exact object name, then a non-zero size.
    listing="$(rclone lsf --files-only "${JANUS_BACKUP_RCLONE_REMOTE}/${rel}")" || return 1
    grep -qxF -- "$base" <<<"$listing" || return 1
    if ! size_json="$(rclone size --json "${JANUS_BACKUP_RCLONE_REMOTE}/${rel}" 2>/dev/null)"; then
      _log "WARN: rclone cannot size ${rel} on this remote — existence verified, size not asserted"
      return 0
    fi
    bytes="$(python3 -c 'import json,sys; print(int(json.load(sys.stdin)["bytes"]))' <<<"$size_json")" || return 1
    (( bytes > 0 )) || return 1
    return 0
  fi
  if [[ -n "${JANUS_BACKUP_S3_BUCKET:-}" ]]; then
    # 06a H2: one HEAD gives both existence (non-zero exit when absent) and
    # size; `s3 ls` alone proved only that a key existed.
    local args=(s3api head-object --bucket "$JANUS_BACKUP_S3_BUCKET" --key "$rel" --query ContentLength --output text)
    if [[ -n "${JANUS_BACKUP_S3_ENDPOINT:-}" ]]; then
      args=(--endpoint-url "$JANUS_BACKUP_S3_ENDPOINT" "${args[@]}")
    fi
    bytes="$(_aws_env aws "${args[@]}" 2>/dev/null)" || return 1
    if [[ "$bytes" =~ ^[0-9]+$ ]] && (( bytes > 0 )); then
      return 0
    fi
    return 1
  fi
  [[ -s "${JANUS_BACKUP_COLD_DIR}/${rel}" ]]
}

age_recipients_args() {
  # JANUS_BACKUP_AGE_RECIPIENTS = comma-separated age public keys or recipient files
  local raw="${JANUS_BACKUP_AGE_RECIPIENTS:-}"
  [[ -n "$raw" ]] || die 1 "JANUS_BACKUP_AGE_RECIPIENTS required (≥2)"
  local IFS=','
  local -a parts=()
  # shellcheck disable=SC2206
  parts=($raw)
  local n=0
  local -a args=()
  local p
  for p in "${parts[@]}"; do
    p="$(echo "$p" | xargs)"
    [[ -n "$p" ]] || continue
    if [[ -f "$p" ]]; then
      args+=(-R "$p")
    else
      args+=(-r "$p")
    fi
    n=$((n + 1))
  done
  if [[ "$n" -lt 2 ]]; then
    die 1 "need ≥2 age recipients (got $n)"
  fi
  printf '%s\n' "${args[@]}"
}
