#!/usr/bin/env bash
# Restore a leader generation set. Spec §5.4.
#
# Usage:
#   RESTORE_CONFIRM=yes AGE_IDENTITY_FILE=... \
#     ./restore_leader.sh janus-backups/2026/10/janus-20261008T031500Z
#   (stem prefix without .dump.age / .env.age / .manifest.json)
#
# Exit discipline: a non-zero pg_restore exit is FATAL (a half-restored
# leader must not be declared ok). RESTORE_ALLOW_PG_RESTORE_ERRORS=1
# tolerates a warnings-only exit; step 9b then verifies table presence +
# schema_migrations/config_meta population independently.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/janus_backup_common.sh
source "${SCRIPT_DIR}/lib/janus_backup_common.sh"

load_backup_env

# --- step 0 ---
if [[ "${RESTORE_CONFIRM:-}" != "yes" ]]; then
  die 16 "set RESTORE_CONFIRM=yes"
fi

REL_PREFIX="${1:-}"
[[ -n "$REL_PREFIX" ]] || die 1 "usage: restore_leader.sh <cold-prefix-stem>  e.g. janus-backups/2026/10/janus-UTC"

require_cmd docker
require_cmd age
require_cmd openssl
require_cmd python3
require_cmd flock

[[ -n "${AGE_IDENTITY_FILE:-}" && -f "$AGE_IDENTITY_FILE" ]] || die 1 "AGE_IDENTITY_FILE required"
acquire_lock

WORKDIR="$(mktemp -d /tmp/janus-restore.XXXXXX)"
STAGED_ENV=""
DUMP_PLAIN=""

# Always shred plaintext secrets/dump on exit (success or fail).
on_exit() {
  if [[ -n "${STAGED_ENV:-}" && -e "${STAGED_ENV:-}" ]]; then
    shred_file "$STAGED_ENV"
  fi
  if [[ -n "${DUMP_PLAIN:-}" && -e "${DUMP_PLAIN:-}" ]]; then
    shred_file "$DUMP_PLAIN"
  fi
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap on_exit EXIT

_log "restore start prefix=$REL_PREFIX"

# --- step 1: fetch three objects ---
DUMP_AGE="${WORKDIR}/dump.age"
ENV_AGE="${WORKDIR}/env.age"
MANIFEST="${WORKDIR}/manifest.json"
set +e
download_cold "${REL_PREFIX}.dump.age" "$DUMP_AGE"
ec1=$?
download_cold "${REL_PREFIX}.env.age" "$ENV_AGE"
ec2=$?
download_cold "${REL_PREFIX}.manifest.json" "$MANIFEST"
ec3=$?
set -e
if [[ $ec1 -ne 0 || $ec2 -ne 0 || $ec3 -ne 0 ]]; then
  die 10 "incomplete generation set (dump=$ec1 env=$ec2 manifest=$ec3)"
fi
[[ -s "$DUMP_AGE" && -s "$ENV_AGE" && -s "$MANIFEST" ]] || die 10 "incomplete generation set (empty object)"

# --- step 2: age-decrypt .env → staging ---
STAGED_ENV="${WORKDIR}/staged.env"
set +e
age -d -i "$AGE_IDENTITY_FILE" -o "$STAGED_ENV" "$ENV_AGE"
age_ec=$?
set -e
if [[ $age_ec -ne 0 ]]; then
  # age fail before usable staging — shred any partial
  shred_file "$STAGED_ENV"
  STAGED_ENV=""
  die 11 "age decrypt .env.age failed"
fi
chmod 600 "$STAGED_ENV"

fail() {
  # shred plaintext then exit with code (10/12/13/14/15/17/18/19/20)
  local code="$1"
  shift
  _log "ERROR ($code): $*"
  shred_file "${STAGED_ENV:-}"
  STAGED_ENV=""
  shred_file "${DUMP_PLAIN:-}"
  DUMP_PLAIN=""
  exit "$code"
}

# Decrypt dump (after staging exists — dump age fail must shred)
DUMP_PLAIN="${WORKDIR}/dump.Fc"
set +e
age -d -i "$AGE_IDENTITY_FILE" -o "$DUMP_PLAIN" "$DUMP_AGE"
age_dump_ec=$?
set -e
[[ $age_dump_ec -eq 0 ]] || fail 11 "age decrypt dump.age failed"

# --- step 3: secrets_generation_id ---
MAN_SID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["secrets_generation_id"])' "$MANIFEST")"
ENV_SID="$(env_get JANUS_SECRETS_GENERATION_ID "$STAGED_ENV")"
[[ "$ENV_SID" == "$MAN_SID" ]] || fail 12 "secrets_generation_id mismatch env=$ENV_SID manifest=$MAN_SID"

# --- step 4: disk ---
DB_SIZE="$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["db_size_bytes"]))' "$MANIFEST")"
mkdir -p "$JANUS_BACKUP_HOT_DIR"
FREE_BYTES="$(disk_free_bytes "$JANUS_BACKUP_HOT_DIR")"
NEED_BYTES=$((DB_SIZE * 3 + 1073741824))
if [[ -z "$FREE_BYTES" || "$FREE_BYTES" -lt "$NEED_BYTES" ]]; then
  fail 17 "restore disk short: free=${FREE_BYTES:-?} need>=${NEED_BYTES}"
fi

# --- step 5: postgres major ---
MAN_PG="$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1]))["postgres_version"]))' "$MANIFEST")"
compose up -d "$JANUS_POSTGRES_CONTAINER" >/dev/null
for _ in $(seq 1 60); do
  docker exec "$JANUS_POSTGRES_CONTAINER" pg_isready -U "$JANUS_PG_USER" >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$JANUS_POSTGRES_CONTAINER" pg_isready -U "$JANUS_PG_USER" >/dev/null 2>&1 \
  || fail 18 "postgres not ready after 60s"
LIVE_PG="$(docker exec "$JANUS_POSTGRES_CONTAINER" psql -U "$JANUS_PG_USER" -d postgres -t -A -c 'SHOW server_version_num;' 2>/dev/null | tr -d '[:space:]' || true)"
[[ -n "$MAN_PG" && "$MAN_PG" =~ ^[0-9]+$ ]] || fail 18 "cannot read manifest postgres version (got '${MAN_PG:-empty}')"
[[ -n "$LIVE_PG" && "$LIVE_PG" =~ ^[0-9]+$ ]] || fail 18 "cannot read live postgres version (got '${LIVE_PG:-empty}')"
# Compare major: version_num / 10000
man_major=$((MAN_PG / 10000))
live_major=$((LIVE_PG / 10000))
[[ "$man_major" -eq "$live_major" ]] || fail 18 "postgres major mismatch manifest=$MAN_PG live=$LIVE_PG"

# --- step 6: floors ---
G_MANIFEST="$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["settings_generation"]))' "$MANIFEST")"
G_LEADER=""
G_FOLLOWERS=""
set +e
G_LEADER="$(pg_exec "SELECT config_generation FROM config_meta WHERE id = 1;" 2>/dev/null | tr -d '[:space:]')"
[[ "$G_LEADER" =~ ^[0-9]+$ ]] || G_LEADER="$(stats_generation 2>/dev/null || true)"
[[ "$G_LEADER" =~ ^[0-9]+$ ]] || G_LEADER=""
max_f=0
if [[ -z "${JANUS_FOLLOWER_HOSTS+x}" ]]; then
  _log "WARN: JANUS_FOLLOWER_HOSTS unset — defaulting to the inventory followers"
fi
IFS=',' read -r -a FOLLOWERS <<<"${JANUS_FOLLOWER_HOSTS:-worker-1}"
for h in "${FOLLOWERS[@]}"; do
  h="$(echo "$h" | xargs)"
  [[ -n "$h" ]] || continue
  fg="$(follower_stats_generation "$h" 2>/dev/null || true)"
  if [[ "$fg" =~ ^[0-9]+$ ]] && [[ "$fg" -gt "$max_f" ]]; then
    max_f="$fg"
  fi
done
[[ "$max_f" -gt 0 ]] && G_FOLLOWERS="$max_f" || G_FOLLOWERS=""
set -e

FLOOR="$G_MANIFEST"
USED="G_manifest=$G_MANIFEST"
if [[ -n "$G_LEADER" && "$G_LEADER" -gt "$FLOOR" ]]; then FLOOR="$G_LEADER"; USED="$USED G_leader=$G_LEADER"; elif [[ -n "$G_LEADER" ]]; then USED="$USED G_leader=$G_LEADER"; fi
if [[ -n "$G_FOLLOWERS" && "$G_FOLLOWERS" -gt "$FLOOR" ]]; then FLOOR="$G_FOLLOWERS"; USED="$USED G_followers=$G_FOLLOWERS"; elif [[ -n "$G_FOLLOWERS" ]]; then USED="$USED G_followers=$G_FOLLOWERS"; fi
TARGET=$((FLOOR + 1))
_log "floor=$FLOOR target=$TARGET inputs: $USED"

# --- step 7–8: ensure DB + restore ---
# Hard prerequisite: POSTGRES_DB=janus in compose (createdb if missing).
set +e
docker exec "$JANUS_POSTGRES_CONTAINER" createdb -U "$JANUS_PG_USER" "$JANUS_PG_DB" 2>/dev/null
set -e

RESTORE_ARGS=(-U "$JANUS_PG_USER" -d "$JANUS_PG_DB" --no-owner --no-privileges)
if [[ "${RESTORE_MODE:-}" == "clean" ]]; then
  RESTORE_ARGS+=(--clean --if-exists)
fi
# 05c-H1: a non-zero pg_restore exit means at least one object failed.
# Swallowing it and falling through to the migration check declares a
# half-restored leader "restore ok" — the migration set can be complete
# while the data is not. Fatal by default; the positive verification in
# step 9b is the second, independent gate. RESTORE_ALLOW_PG_RESTORE_ERRORS=1
# is the explicit warnings-only override (e.g. restoring over an existing
# DB without RESTORE_MODE=clean); even then step 9b still runs.
set +e
docker exec -i "$JANUS_POSTGRES_CONTAINER" pg_restore "${RESTORE_ARGS[@]}" <"$DUMP_PLAIN"
PG_RESTORE_RC=$?
set -e
if [[ $PG_RESTORE_RC -ne 0 ]]; then
  if [[ "${RESTORE_ALLOW_PG_RESTORE_ERRORS:-0}" == "1" ]]; then
    _log "WARN: pg_restore exit $PG_RESTORE_RC tolerated (RESTORE_ALLOW_PG_RESTORE_ERRORS=1) — positive verification below decides"
  else
    fail 20 "pg_restore failed (exit $PG_RESTORE_RC) — refusing to declare a partial restore OK (warnings-only override: RESTORE_ALLOW_PG_RESTORE_ERRORS=1)"
  fi
fi

# --- step 9: migrations ⊆ ---
python3 - "$MANIFEST" "$JANUS_POSTGRES_CONTAINER" "$JANUS_PG_USER" "$JANUS_PG_DB" <<'PY' || fail 13 "migrations check failed"
import json, subprocess, sys
man = json.load(open(sys.argv[1]))
container, user, db = sys.argv[2], sys.argv[3], sys.argv[4]
want = set(man["schema_migrations"])
raw = subprocess.check_output([
    "docker", "exec", container, "psql", "-U", user, "-d", db, "-t", "-A", "-c",
    "SELECT version FROM schema_migrations ORDER BY version;"
], text=True)
have = {ln.strip() for ln in raw.splitlines() if ln.strip()}
missing = sorted(want - have)
if missing:
    print("missing migrations:", missing, file=sys.stderr)
    sys.exit(1)
extra = sorted(have - want)
if extra:
    print("extras (forward migrations / clean mode):", extra, file=sys.stderr)
print("migrations ok; restored=", len(have), "manifest=", len(want))
PY

# --- step 9b: positive restore verification (05c-H1) ---
# The migration check above proves a SUBSET of schema_migrations; it
# cannot prove data actually landed (a half-restored DB can carry a
# complete migrations table). Assert the core tables exist AND that
# schema_migrations/config_meta are populated as the manifest says,
# before anything declares success or starts the gateway on it.
python3 - "$MANIFEST" "$JANUS_POSTGRES_CONTAINER" "$JANUS_PG_USER" "$JANUS_PG_DB" <<'PY' || fail 20 "positive restore verification failed"
import json, subprocess, sys
man = json.load(open(sys.argv[1]))
container, user, db = sys.argv[2], sys.argv[3], sys.argv[4]
CORE = ("providers", "provider_models", "api_keys", "models",
        "config_meta", "schema_migrations")
def psql(sql):
    return subprocess.check_output([
        "docker", "exec", container, "psql", "-U", user, "-d", db, "-t", "-A", "-c", sql
    ], text=True)
have_tables = {ln.strip() for ln in psql(
    "SELECT table_name FROM information_schema.tables WHERE table_schema='public';"
).splitlines() if ln.strip()}
missing_tables = [t for t in CORE if t not in have_tables]
if missing_tables:
    print("core tables missing after restore:", missing_tables, file=sys.stderr)
    sys.exit(1)
want = set(man["schema_migrations"])
have_migs = int(psql("SELECT count(*) FROM schema_migrations;").strip() or 0)
if have_migs < len(want):
    print("schema_migrations rows=%d < manifest migrations=%d" % (have_migs, len(want)), file=sys.stderr)
    sys.exit(1)
meta = int(psql("SELECT count(*) FROM config_meta WHERE id = 1;").strip() or 0)
if meta != 1:
    print("config_meta singleton row (id=1) missing after restore", file=sys.stderr)
    sys.exit(1)
print("restore verified: tables=%d migrations=%d config_meta=ok" % (len(have_tables), have_migs))
PY

# --- step 10: canaries ---
ROW_COUNT="$(pg_exec "SELECT count(*) FROM provider_keys;" | tr -d '[:space:]')"
if [[ "$ROW_COUNT" == "0" ]]; then
  if [[ "${RESTORE_ALLOW_EMPTY_KEYS:-0}" == "1" ]]; then
    _log "WARN: empty provider_keys allowed"
  else
    fail 15 "provider_keys empty"
  fi
else
  CT_HEX="$(pg_exec "SELECT encode(secret_ciphertext, 'hex') FROM provider_keys LIMIT 1;" | tr -d '[:space:]')"
  if ! python3 "${SCRIPT_DIR}/secrets_canary.py" --env-file "$STAGED_ENV" --ciphertext-hex "$CT_HEX"; then
    fail 14 "secrets key canary failed"
  fi
fi

PEPPER="$(env_get JANUS_API_KEY_PEPPER "$STAGED_ENV")"
MAN_PEPPER_HASH="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pepper_canary_hash"])' "$MANIFEST")"
if [[ "$ROW_COUNT" == "0" && "${RESTORE_ALLOW_EMPTY_KEYS:-0}" == "1" && "${RESTORE_SKIP_PEPPER_CANARY:-0}" == "1" ]]; then
  _log "WARN: pepper canary skipped (double opt-in)"
else
  [[ -n "$PEPPER" && "$PEPPER" =~ [^[:space:]] ]] || fail 14 "empty pepper"
  LIVE_HASH="$(pepper_canary_hash "$PEPPER")"
  [[ "$LIVE_HASH" == "$MAN_PEPPER_HASH" ]] || fail 14 "pepper canary mismatch"
fi

# --- step 11: image pin (before .env install) ---
check_image() {
  local role="$1"  # gateway|dashboard
  local service="$2"
  local man_digest man_form live
  man_digest="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$MANIFEST" "${role}_sha256")"
  man_form="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$MANIFEST" "${role}_digest_form")"
  [[ -n "$man_digest" ]] || { _log "WARN: no manifest digest for $role — skip pin"; return 0; }

  # Pre-pull when RepoDigest form
  if [[ "$man_digest" == *"@sha256:"* ]]; then
    docker pull "$man_digest" >/dev/null 2>&1 || true
  fi

  local img
  img="$(compose images -q "$service" 2>/dev/null | head -1 || true)"
  [[ -n "$img" ]] || img="$(docker inspect -f '{{.Image}}' "$(compose ps -q "$service" 2>/dev/null)" 2>/dev/null || true)"
  if [[ -z "$img" ]]; then
    if [[ "${RESTORE_ALLOW_IMAGE_MISMATCH:-0}" == "1" ]]; then
      _log "WARN: no local $role image; override set"
      return 0
    fi
    fail 19 "no local $role image for pin check"
  fi
  IFS='|' read -r live_form live_digest <<<"$(image_digest_for "$img")"
  if [[ "$live_digest" == "$man_digest" ]]; then
    _log "$role image pin OK ($live_form)"
    return 0
  fi
  # Cross-form: RepoDigest ends with the image Id's sha256 when both refer to the same image.
  local man_sha live_sha
  man_sha="${man_digest##*:}"
  live_sha="${live_digest##*:}"
  if [[ -n "$man_sha" && "$man_sha" == "$live_sha" ]]; then
    _log "$role image pin OK (sha match across forms man=$man_form live=$live_form)"
    return 0
  fi
  if [[ "$man_form" != "$live_form" ]]; then
    _log "WARN: $role digest forms differ (man=$man_form live=$live_form) — equality failed"
  fi
  if [[ "${RESTORE_ALLOW_IMAGE_MISMATCH:-0}" == "1" ]]; then
    _log "WARN: $role digest mismatch overridden live=$live_digest man=$man_digest"
    return 0
  fi
  fail 19 "$role image digest mismatch live=$live_digest man=$man_digest"
}

check_image gateway "$JANUS_GATEWAY_SERVICE"
check_image dashboard "$JANUS_DASHBOARD_SERVICE"

# --- step 12: install .env ---
install -m 600 "$STAGED_ENV" "$JANUS_ENV_FILE"
shred_file "$STAGED_ENV"
STAGED_ENV=""

# --- step 13: up services ---
compose up -d "$JANUS_DASHBOARD_SERVICE" "$JANUS_GATEWAY_SERVICE" >/dev/null

# --- step 14: force-set generation ---
pg_exec "UPDATE config_meta SET config_generation = ${TARGET} WHERE id = 1;"
LIVE_GEN="$(pg_exec "SELECT config_generation FROM config_meta WHERE id = 1;" | tr -d '[:space:]')"
[[ "$LIVE_GEN" == "$TARGET" ]] || die 1 "force-set generation failed live=$LIVE_GEN want=$TARGET"
_log "generation force-set to $TARGET (brief boot_load lag possible before poll)"

# --- step 15: followers ---
strip_leader_only_env() {
  # $1 = env file path → stdout without leader-only vars
  python3 - "$1" <<'PY'
import sys
path = sys.argv[1]
DROP_EXACT = {
    "JANUS_BACKUP_ENV_FILE", "AGE_IDENTITY_FILE",
    "JANUS_BACKUP_S3_ACCESS_KEY_ID", "JANUS_BACKUP_S3_SECRET_ACCESS_KEY",
    "JANUS_BACKUP_S3_BUCKET", "JANUS_BACKUP_S3_ENDPOINT",
    "JANUS_BACKUP_RCLONE_REMOTE", "JANUS_BACKUP_COLD_DIR",
    "JANUS_BACKUP_ALERT_URL", "JANUS_BACKUP_AGE_RECIPIENTS",
}
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            sys.stdout.write(line)
            continue
        k = s.split("=", 1)[0].strip()
        if k in DROP_EXACT or k.startswith("POSTGRES_") or k.startswith("JANUS_BACKUP_"):
            continue
        sys.stdout.write(line)
PY
}

for h in "${FOLLOWERS[@]}"; do
  h="$(echo "$h" | xargs)"
  [[ -n "$h" ]] || continue
  _log "restart follower $h"
  ssh -o BatchMode=yes "$h" "cd /opt/stacks/janus && docker compose restart ${JANUS_GATEWAY_SERVICE}" || _log "WARN: restart $h failed"
  sleep 2
  remote_sid="$(ssh -o BatchMode=yes "$h" "grep -E '^JANUS_SECRETS_GENERATION_ID=' /opt/stacks/janus/.env 2>/dev/null | cut -d= -f2- | tr -d '\"'" || true)"
  if [[ "$remote_sid" != "$MAN_SID" ]]; then
    _log "follower $h keyring id drift ($remote_sid != $MAN_SID) — rewriting .env"
    TMPF="$(mktemp "${WORKDIR}/follower-env.XXXXXX")"
    age -d -i "$AGE_IDENTITY_FILE" -o "$TMPF" "$ENV_AGE"
    if strip_leader_only_env "$TMPF" | ssh -o BatchMode=yes "$h" \
      'set -euo pipefail; cat > /opt/stacks/janus/.env.tmp; chmod 600 /opt/stacks/janus/.env.tmp; mv /opt/stacks/janus/.env.tmp /opt/stacks/janus/.env'; then
      shred_file "$TMPF"
      ssh -o BatchMode=yes "$h" "cd /opt/stacks/janus && docker compose restart ${JANUS_GATEWAY_SERVICE}" || {
        _log "WARN: follower $h restart after rewrite failed — nulling JANUS_SECRETS_GENERATION_ID fallback"
        ssh -o BatchMode=yes "$h" "sed -i 's/^JANUS_SECRETS_GENERATION_ID=.*/JANUS_SECRETS_GENERATION_ID=/' /opt/stacks/janus/.env; cd /opt/stacks/janus && docker compose restart ${JANUS_GATEWAY_SERVICE}" || true
      }
    else
      ssh -o BatchMode=yes "$h" 'rm -f /opt/stacks/janus/.env.tmp' || true
      shred_file "$TMPF"
      _log "WARN: follower $h .env rewrite failed; cleaned .env.tmp — skipping restart"
      continue
    fi
  fi
done

# --- step 16: smoke (curl live-check; test suite removed 2026-10-18) ---
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DASH_URL="${JANUS_DASH:-https://gw.example.invalid}"
for ep in "/api/health"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 15 "${DASH_URL}${ep}")"
  [[ "$code" == 200 ]] || die 1 "smoke ${ep} -> ${code}"
  _log "smoke ${ep} ok (200)"
done

_log "restore ok target_gen=$TARGET"
echo "OK generation=$TARGET"
