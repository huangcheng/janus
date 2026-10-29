#!/usr/bin/env bash
# Backup restore drill (maturity-hardening H5-D1/D2, spec
# docs/superpowers/specs/2026-10-15-maturity-hardening.md): restore the
# LATEST leader backup into a THROWAWAY Postgres container on the LOCAL
# machine (docker --rm, removed in an EXIT trap) — never a prod host,
# never ssh. "An unverified backup is no backup."
#
# Failure modes guarded against (repo rule 2 — written before the code):
#   F1 silently dead backup job -> stale dump passes unnoticed.
#      Guard: freshness assert, age <= JANUS_VERIFY_FRESHNESS_DAYS (8,
#      weekly cadence + slack). Age is the OLDER of (dump mtime,
#      stem-encoded backup time) so a re-copied old artifact cannot look
#      fresh. Fail-fast BEFORE spending restore time.
#   F2 corrupt/truncated dump. Guard: age decrypt must succeed,
#      pg_restore --list must parse, and the backup_canaries row written
#      by backup_leader.sh must round-trip (count >= 1).
#   F3 dump restores but the catalog drifted (empty/wrong DB). Guard:
#      counts of providers/provider_models/api_keys/models within 10% of
#      the pre-dump snapshot (<stem>.counts.json, H5-D1).
#   F4 drill touches production. Guard: the only thing created is a
#      fixed-name throwaway container (--rm; rm -f in EXIT trap); a
#      pre-existing container under that name is removed ONLY if it runs
#      a postgres image; no ssh, no prod host is resolved; the age
#      identity is used read-only.
#   F5 restore hangs forever (pull stall, dead container). Guard:
#      bounded pg_isready wait (60s) + pg_restore under `timeout` with
#      the <20 min wall-time budget (assertion (c)).
#   F6 secrets sprawl. Guard: the dump (provider key ciphertext inside)
#      lives in a mode-700 workdir, plaintext shredded on exit; the
#      throwaway container credentials are fixed non-secret values;
#      nothing secret is printed.
#
# Usage:
#   AGE_IDENTITY_FILE=/path/to/identity \
#   JANUS_BACKUP_ENV_FILE=/opt/stacks/janus/janus-backup.env \
#     ./scripts/verify_backup.sh [--dir DIR] [--stem janus-YYYYMMDDTHHMMSSZ]
#
#   --dir DIR   verify the newest janus-*.dump.age under DIR (default:
#               JANUS_VERIFY_BACKUP_DIR, else the cold store from the
#               backup env, else JANUS_BACKUP_HOT_DIR)
#   --stem S    verify exactly this stem (default: newest found)
#   --keep      keep the throwaway container after the run for debugging
#               (it is still removed by the next run)
#
# Result line (PASS/FAIL) appends to ${JANUS_BACKUP_LOG_DIR}/verify.log —
# the same log family the backup staleness alerting reads (H5-D2: a
# failure is a WARN via JANUS_BACKUP_ALERT_URL, not a page).
#
# Weekly cadence (H5-D2): this used to be an ops-owned cron on the
# contabo runner, which was uninstalled + deregistered on 2026-10-22 —
# nothing schedules the check today, and the dashboard repo deliberately
# has NO GitHub workflow for it. The crontab shape below is the template
# to re-register on the tencent CI host (adapt the paths):
#   17 3 * * 1 JANUS_BACKUP_ENV_FILE=/opt/janus-ci/janus-backup.env \
#     AGE_IDENTITY_FILE=/opt/janus-ci/age/janus-backup-identity.txt \
#     /opt/janus-ci/janus-dashboard/scripts/verify_backup.sh \
#     >>/var/log/janus-backup/verify.log 2>&1
#
# CURRENT STATE (verified 2026-10-23, see docs/DEPLOY.md §6): the H5
# pipeline is NOT provisioned anywhere — no janus-backup.env and no age
# identity exist on any host, including the CI host the template above
# names — so this script cannot run as shipped. What actually protects
# data today is the legacy `janus-pg-backup.timer` on the aliyun leader
# (daily 03:30, plain /opt/janus/backups/pg/janus-*.dump, 14 days) and
# THAT format this script does not accept (it needs *.dump.age plus
# AGE_IDENTITY_FILE and <stem>.counts.json). Two ways out, both operator
# decisions: provision H5 as designed, or add a plain-dump mode here.
# The legacy dumps were proven restorable on 2026-10-23 by a manual drill
# (evidence: /tmp/memoh_bench/backup_drill/RESULT.md).
#
# Knobs (env): JANUS_VERIFY_PG_IMAGE (default postgres:16-alpine, or
# postgres:<major>-alpine derived from the manifest), 
# JANUS_VERIFY_FRESHNESS_DAYS (8), JANUS_VERIFY_RESTORE_BUDGET_S (1200),
# JANUS_VERIFY_PG_CONTAINER (janus-verify-pg).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/janus_backup_common.sh
source "${SCRIPT_DIR}/lib/janus_backup_common.sh"

load_backup_env

# ---- result log + verdict funnel (H5-D2, 06a M7) ----
# Defined BEFORE the first check and used by every early abort, so a drill
# that cannot run (missing python3/docker/age, lost identity, failed
# docker pull/run, full /tmp) still writes a FAIL line and raises the
# webhook alert. Only a usage error (exit 2) skips the verdict — that is
# operator CLI misuse, not a drill result.
VERDICT_EMITTED=0
verify_log_append() {
  local line="$1"
  mkdir -p "$JANUS_BACKUP_LOG_DIR" 2>/dev/null || true
  printf '%s\n' "$line" >>"${JANUS_BACKUP_LOG_DIR}/verify.log" 2>/dev/null \
    || echo "(WARN: cannot append ${JANUS_BACKUP_LOG_DIR}/verify.log)" >&2
}

# Early terminal failure: print reason, log, alert (WARN wording), exit 1.
fail_verify() {
  local msg="$1"
  VERDICT_EMITTED=1
  echo "ASSERT FAIL: $msg" >&2
  _log "ASSERT FAIL: $msg"
  verify_log_append "$(date -u +%Y-%m-%dT%H:%M:%SZ) FAIL stem=${STEM:-?} — ${msg}"
  alert "WARN janus backup verify FAILED (stem=${STEM:-?}): $msg"
  exit 1
}

# LOCAL python (Windows hosts expose `python`, not `python3` — same
# portability idiom as scripts/ensure_master_mmdb.sh).
PY3="$(command -v python3 || command -v python || true)"
[[ -n "$PY3" ]] || fail_verify "missing command: python3 (or python)"

for _cmd in docker age timeout; do
  command -v "$_cmd" >/dev/null 2>&1 || fail_verify "missing command: $_cmd"
done

FRESH_DAYS="${JANUS_VERIFY_FRESHNESS_DAYS:-8}"
BUDGET_S="${JANUS_VERIFY_RESTORE_BUDGET_S:-1200}"
VCTR="${JANUS_VERIFY_PG_CONTAINER:-janus-verify-pg}"
VUSER="janus"
VPASS="janus-verify-throwaway" # fixed non-secret: throwaway container only
VDB="janus"

STEM_RE='^janus-[0-9]{8}T[0-9]{6}Z$'
SRC_DIR="${JANUS_VERIFY_BACKUP_DIR:-}"
WANT_STEM=""
KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) SRC_DIR="$2"; shift 2 ;;
    --stem)
      WANT_STEM="$2"
      [[ "$WANT_STEM" =~ $STEM_RE ]] || {
        echo "usage: $0 [--dir DIR] [--stem janus-YYYYMMDDTHHMMSSZ] [--keep]" >&2
        exit 2
      }
      shift 2
      ;;
    --keep) KEEP=1; shift ;;
    *) echo "usage: $0 [--dir DIR] [--stem janus-...] [--keep]" >&2; exit 2 ;;
  esac
done

[[ -n "${AGE_IDENTITY_FILE:-}" && -f "${AGE_IDENTITY_FILE:-}" ]] \
  || fail_verify "AGE_IDENTITY_FILE required (backup age identity)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/janus-verify-backup.XXXXXX")" \
  || fail_verify "cannot create a workdir under ${TMPDIR:-/tmp} (disk full or not writable)"
chmod 700 "$WORKDIR" || fail_verify "cannot chmod 700 the workdir $WORKDIR"
DUMP_AGE="${WORKDIR}/dump.age"
DUMP_PLAIN="${WORKDIR}/dump.Fc"
COUNTS_FILE="${WORKDIR}/counts.json"
MANIFEST_FILE="${WORKDIR}/manifest.json"
CTR_UP=0
cleanup() {
  if [[ "$CTR_UP" == "1" ]]; then
    if [[ "$KEEP" == "1" ]]; then
      _log "keeping throwaway container $VCTR (--keep)"
    else
      docker rm -f "$VCTR" >/dev/null 2>&1 || true
    fi
  fi
  shred_file "$DUMP_PLAIN" 2>/dev/null || true
  rm -f "$DUMP_AGE" 2>/dev/null || true
  rm -rf "$WORKDIR" 2>/dev/null || true
}
# M7 backstop: any abort that bypasses fail_verify/verdict (set -e exits,
# killed pull, docker run failure) still reports FAIL + alerts instead of
# leaving the weekly drill silently unverified.
on_exit() {
  local rc=$?
  cleanup || true
  if [[ "$rc" -ne 0 && "$VERDICT_EMITTED" != "1" ]]; then
    local msg="drill aborted before a verdict (rc=$rc) — see stderr above"
    echo "FAIL stem=${STEM:-?} — $msg" >&2
    verify_log_append "$(date -u +%Y-%m-%dT%H:%M:%SZ) FAIL stem=${STEM:-?} — $msg" || true
    alert "WARN janus backup verify ABORTED (stem=${STEM:-?}, rc=$rc) — the drill did not reach a PASS/FAIL verdict" || true
  fi
}
# A killed drill (cron timeout, Ctrl-C) must still produce FAIL + alert:
# turn INT/TERM into a normal exit so the EXIT trap above runs.
trap 'exit 130' INT TERM
trap on_exit EXIT

_log "verify start (freshness=${FRESH_DAYS}d budget=${BUDGET_S}s)"

# ---- locate the latest backup artifact ----
declare -a CANDS=() # "stem|where|path-or-rel"

add_dir_candidates() { # $1=dir $2=where-tag (absolute paths)
  local d="$1" where="$2" p s
  [[ -d "$d" ]] || return 0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    s="$(basename "$p")"
    s="${s%.dump.age}"
    [[ "$s" =~ $STEM_RE ]] || continue
    CANDS+=("${s}|${where}|${p}")
  done < <(find "$d" -type f -name 'janus-*.dump.age' 2>/dev/null || true)
}

add_rel_candidates() { # rel paths on stdin; $1=where-tag
  local where="$1" p s
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    s="$(basename "$p")"
    s="${s%.dump.age}"
    [[ "$s" =~ $STEM_RE ]] || continue
    CANDS+=("${s}|${where}|${p}")
  done
}

if [[ -n "$SRC_DIR" ]]; then
  add_dir_candidates "$SRC_DIR" "dir"
elif [[ -n "${JANUS_BACKUP_RCLONE_REMOTE:-}" ]]; then
  rclone lsf -R --files-only "$JANUS_BACKUP_RCLONE_REMOTE" 2>/dev/null | add_rel_candidates "rclone" || true
elif [[ -n "${JANUS_BACKUP_S3_BUCKET:-}" ]]; then
  _aws_env aws s3 ls "s3://${JANUS_BACKUP_S3_BUCKET}/janus-backups/" --recursive 2>/dev/null \
    | awk '{ k=$4; for (i=5; i<=NF; i++) k=k" "$i; print k }' \
    | add_rel_candidates "s3" || true
elif [[ -n "${JANUS_BACKUP_COLD_DIR:-}" ]]; then
  add_dir_candidates "${JANUS_BACKUP_COLD_DIR}/janus-backups" "cold"
else
  add_dir_candidates "$JANUS_BACKUP_HOT_DIR" "hot"
fi

BEST=""
if [[ -n "$WANT_STEM" ]]; then
  for c in ${CANDS[@]+"${CANDS[@]}"}; do
    if [[ "${c%%|*}" == "$WANT_STEM" ]]; then BEST="$c"; fi
  done
  [[ -n "$BEST" ]] || fail_verify "stem $WANT_STEM not found in any source"
else
  for c in ${CANDS[@]+"${CANDS[@]}"}; do
    if [[ -z "$BEST" || "${c%%|*}" > "${BEST%%|*}" ]]; then BEST="$c"; fi # stems sort lexicographically (UTC)
  done
  [[ -n "$BEST" ]] || fail_verify "no janus-*.dump.age found (source: dir/rclone/s3/cold/hot)"
fi
IFS='|' read -r STEM SRCWHERE SRCPATH <<<"$BEST"
_log "artifact stem=$STEM source=$SRCWHERE path=$SRCPATH"

# ---- materialize dump + counts (+manifest) into the workdir ----
rm -f "$MANIFEST_FILE"
case "$SRCWHERE" in
  dir | cold | hot)
    [[ -f "$SRCPATH" ]] || fail_verify "dump vanished: $SRCPATH"
    MTIME_EPOCH="$(stat -c %Y "$SRCPATH")"
    cp -f "$SRCPATH" "$DUMP_AGE"
    COUNTS_SRC="${SRCPATH%.dump.age}.counts.json"
    [[ -f "$COUNTS_SRC" ]] || fail_verify "counts snapshot missing beside dump ($COUNTS_SRC) — backup predates H5-D1 or incomplete generation set"
    cp -f "$COUNTS_SRC" "$COUNTS_FILE"
    MAN_SRC="${SRCPATH%.dump.age}.manifest.json"
    [[ -f "$MAN_SRC" ]] && cp -f "$MAN_SRC" "$MANIFEST_FILE" || true
    ;;
  rclone)
    BASE_REL="${SRCPATH%.dump.age}"
    download_cold "${BASE_REL}.dump.age" "$DUMP_AGE" || fail_verify "cold download failed: ${BASE_REL}.dump.age"
    download_cold "${BASE_REL}.counts.json" "$COUNTS_FILE" \
      || fail_verify "counts snapshot missing in cold store (${BASE_REL}.counts.json) — backup predates H5-D1 or incomplete generation set"
    download_cold "${BASE_REL}.manifest.json" "$MANIFEST_FILE" || rm -f "$MANIFEST_FILE"
    # rclone copy preserves the source modtime.
    MTIME_EPOCH="$(stat -c %Y "$DUMP_AGE")"
    ;;
  s3)
    BASE_REL="${SRCPATH%.dump.age}"
    download_cold "${BASE_REL}.dump.age" "$DUMP_AGE" || fail_verify "cold download failed: ${BASE_REL}.dump.age"
    download_cold "${BASE_REL}.counts.json" "$COUNTS_FILE" \
      || fail_verify "counts snapshot missing in cold store (${BASE_REL}.counts.json) — backup predates H5-D1 or incomplete generation set"
    download_cold "${BASE_REL}.manifest.json" "$MANIFEST_FILE" || rm -f "$MANIFEST_FILE"
    # aws s3 cp stamps download time; take the object's real Last-Modified.
    LASTMOD="$(_aws_env aws s3api head-object --bucket "$JANUS_BACKUP_S3_BUCKET" --key "$SRCPATH" --query LastModified --output text 2>/dev/null || true)"
    MTIME_EPOCH="$("$PY3" - "$LASTMOD" <<'PY'
import sys
from datetime import datetime, timezone
s = (sys.argv[1] or "").strip()
if not s:
    raise SystemExit(1)
if s.endswith("Z"):
    s = s[:-1] + "+00:00"
dt = datetime.fromisoformat(s)
if dt.tzinfo is None:
    dt = dt.replace(tzinfo=timezone.utc)
print(int(dt.timestamp()))
PY
)"
    [[ "$MTIME_EPOCH" =~ ^[0-9]+$ ]] || MTIME_EPOCH="$(stat -c %Y "$DUMP_AGE")"
    ;;
  *) fail_verify "unknown source '$SRCWHERE'" ;;
esac
[[ -s "$DUMP_AGE" ]] || fail_verify "dump artifact is empty: $SRCPATH"

# ---- assertion (d): FRESHNESS (fail fast, F1) ----
STEM_EPOCH="$("$PY3" - "$STEM" <<'PY'
import sys
from datetime import datetime, timezone
body = sys.argv[1][len("janus-"):]
print(int(datetime.strptime(body, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc).timestamp()))
PY
)"
NOW="$(date -u +%s)"
[[ "$MTIME_EPOCH" =~ ^[0-9]+$ ]] || fail_verify "cannot stat dump mtime"
# Conservative: the OLDER of mtime/stem decides (a re-copied artifact
# must not look fresh; clock skew cannot hide age).
EFFECTIVE_EPOCH="$MTIME_EPOCH"
if [[ "$STEM_EPOCH" -lt "$EFFECTIVE_EPOCH" ]]; then
  EFFECTIVE_EPOCH="$STEM_EPOCH"
fi
AGE_S=$(( NOW - EFFECTIVE_EPOCH ))
AGE_D="$(awk -v s="$AGE_S" 'BEGIN { printf "%.2f", s / 86400 }')"
FRESH_LIMIT_S=$(( FRESH_DAYS * 86400 ))
if (( AGE_S > FRESH_LIMIT_S )); then
  fail_verify "dump not fresh: stem=$STEM age=${AGE_D}d > ${FRESH_DAYS}d (backup job dead?)"
fi
_log "freshness ok stem=$STEM age=${AGE_D}d (mtime $(date -u -d "@$MTIME_EPOCH" +%FT%TZ 2>/dev/null || echo "?"))"

# ---- decrypt (F2) ----
age -d -i "$AGE_IDENTITY_FILE" -o "$DUMP_PLAIN" "$DUMP_AGE" || fail_verify "age decrypt failed (wrong identity or corrupt dump.age)"
chmod 600 "$DUMP_PLAIN"
DUMP_BYTES="$(wc -c <"$DUMP_PLAIN" | tr -d '[:space:]')"
_log "decrypted dump ${DUMP_BYTES} bytes"

# ---- image choice: manifest major when available (restore-compat) ----
PG_IMAGE="${JANUS_VERIFY_PG_IMAGE:-}"
if [[ -z "$PG_IMAGE" ]]; then
  PG_MAJOR=16
  if [[ -s "$MANIFEST_FILE" ]]; then
    MAN_PG="$("$PY3" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("postgres_version",""))' "$MANIFEST_FILE" 2>/dev/null || true)"
    if [[ "$MAN_PG" =~ ^[0-9]+$ ]] && (( MAN_PG / 10000 >= 12 )); then
      PG_MAJOR=$(( MAN_PG / 10000 ))
    fi
  fi
  PG_IMAGE="postgres:${PG_MAJOR}-alpine"
fi
_log "throwaway pg image=$PG_IMAGE"

# ---- throwaway container (F4: reserved name, postgres-only takeover) ----
OLD_IMG="$(docker inspect -f '{{.Config.Image}}' "$VCTR" 2>/dev/null || true)"
if [[ -n "$OLD_IMG" ]]; then
  case "$OLD_IMG" in
    *postgres*)
      _log "removing leftover $VCTR ($OLD_IMG) from an earlier drill"
      docker rm -f "$VCTR" >/dev/null
      ;;
    *)
      fail_verify "container name $VCTR is taken by non-postgres image '$OLD_IMG' — refusing (set JANUS_VERIFY_PG_CONTAINER)"
      ;;
  esac
fi
docker pull "$PG_IMAGE" >/dev/null 2>&1 || docker pull "$PG_IMAGE" # retry once; real error surfaces
docker run --rm -d --name "$VCTR" \
  -e POSTGRES_USER="$VUSER" -e POSTGRES_PASSWORD="$VPASS" -e POSTGRES_DB="$VDB" \
  "$PG_IMAGE" >/dev/null
CTR_UP=1
for _ in $(seq 1 60); do
  docker exec "$VCTR" pg_isready -U "$VUSER" >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$VCTR" pg_isready -U "$VUSER" >/dev/null 2>&1 || fail_verify "throwaway postgres not ready after 60s"
_log "throwaway postgres up ($VCTR)"

# Dump integrity pre-check with the SAME client the container ships.
docker exec -i "$VCTR" pg_restore --list <"$DUMP_PLAIN" >/dev/null || fail_verify "pg_restore --list failed on decrypted dump (corrupt/truncated)"

# ---- restore + assertion (c): wall-time < budget (F5) ----
T0="$SECONDS"
RESTORE_RC=0
timeout "$BUDGET_S" docker exec -i "$VCTR" \
  pg_restore -U "$VUSER" -d "$VDB" --no-owner --no-privileges <"$DUMP_PLAIN" \
  || RESTORE_RC=$?
RESTORE_S=$(( SECONDS - T0 ))
declare -a FAILS=()
if [[ "$RESTORE_RC" == "124" ]]; then
  _log "pg_restore exceeded the ${BUDGET_S}s budget and was killed"
elif [[ "$RESTORE_RC" != "0" ]]; then
  # 05c-H1 parity: a non-zero pg_restore means at least one object (index,
  # constraint, trigger, function, extension) failed. Rows still load, so the
  # canary and row-count assertions below cannot see it — fail the drill.
  FAILS+=("pg_restore exit $RESTORE_RC — dump may be partially restored")
fi
_log "restore done in ${RESTORE_S}s (exit=$RESTORE_RC)"

if [[ "$RESTORE_RC" == "124" || "$RESTORE_S" -ge "$BUDGET_S" ]]; then
  FAILS+=("restore wall-time ${RESTORE_S}s >= budget ${BUDGET_S}s")
fi

# ---- assertion (a): canary round-trip (F2) ----
CANARY_N="$(docker exec "$VCTR" psql -U "$VUSER" -d "$VDB" -t -A -c \
  "SELECT count(*) FROM backup_canaries;" 2>/dev/null || true)"
if [[ "$CANARY_N" =~ ^[0-9]+$ ]] && (( CANARY_N >= 1 )); then
  _log "canary ok: $CANARY_N row(s)"
else
  FAILS+=("canary round-trip: expected >=1 backup_canaries row, got '${CANARY_N:-query failed}'")
  CANARY_N="ERR"
fi

# ---- assertion (b): four key tables within 10% of pre-dump snapshot (F3) ----
COUNTS_OUT="$("$PY3" - "$COUNTS_FILE" "$VCTR" "$VUSER" "$VDB" "$MANIFEST_FILE" 2>&1 <<'PY' || true
import json, subprocess, sys

counts_path, ctr, user, db, manifest_path = sys.argv[1:6]
REQUIRED = ["providers", "provider_models", "api_keys", "models"]
fails, parts = [], []
try:
    with open(counts_path, encoding="utf-8") as f:
        doc = json.load(f) or {}
    snap = doc.get("counts") or {}
except Exception as e:
    print(f"ASSERT FAIL counts snapshot unreadable ({counts_path}): {e}", file=sys.stderr)
    sys.exit(1)
for t in REQUIRED:
    s = snap.get(t)
    if not isinstance(s, int):
        fails.append(f"{t}: missing from counts snapshot")
        parts.append(f"{t}=?/?")
        continue
    try:
        raw = subprocess.check_output(
            ["docker", "exec", ctr, "psql", "-U", user, "-d", db,
             "-t", "-A", "-c", f"SELECT count(*) FROM {t};"],
            text=True, stderr=subprocess.DEVNULL).strip()
        r = int(raw)
    except Exception:
        fails.append(f"{t}: restored count unreadable (table missing or restore broken)")
        parts.append(f"{t}=?/{s}")
        continue
    parts.append(f"{t}={r}/{s}")
    if s == 0:
        if r != 0:
            fails.append(f"{t}: snapshot 0 but restored {r} (outside 10%)")
    elif abs(r - s) * 10 > s:  # within 10% inclusive
        fails.append(f"{t}: restored {r} vs snapshot {s} (delta outside 10%)")

# 06a L6: bind the restored set to the manifest (when the artifact has one).
# The canary row the backup wrote INTO this dump must carry the manifest's
# sha, and the counts snapshot must name the manifest's stem — otherwise
# "PASS" certifies a dump that is not the one this generation set describes.
man = {}
try:
    with open(manifest_path, encoding="utf-8") as f:
        man = json.load(f) or {}
except Exception:
    man = {}
if isinstance(man, dict):
    if man.get("canary_sha"):
        try:
            got = subprocess.check_output(
                ["docker", "exec", ctr, "psql", "-U", user, "-d", db,
                 "-t", "-A", "-c",
                 "SELECT sha FROM backup_canaries ORDER BY ts DESC LIMIT 1;"],
                text=True, stderr=subprocess.DEVNULL).strip()
        except Exception:
            fails.append("canary sha: restored backup_canaries unreadable")
        else:
            if got != man["canary_sha"]:
                fails.append(
                    "canary sha: restored %s vs manifest %s"
                    % (got[:12] or "(none)", str(man["canary_sha"])[:12])
                )
    if man.get("stem") and doc.get("stem") and man["stem"] != doc["stem"]:
        fails.append(
            "stem mismatch: counts %s vs manifest %s" % (doc["stem"], man["stem"])
        )

for line in fails:
    print(f"ASSERT FAIL {line}", file=sys.stderr)
print(" ".join(parts))
sys.exit(1 if fails else 0)
PY
)"
COUNTS_PARTS=""
while IFS= read -r fl; do
  if [[ "$fl" == "ASSERT FAIL"* ]]; then
    FAILS+=("${fl#ASSERT FAIL }")
  elif [[ -n "$fl" ]]; then
    COUNTS_PARTS="$fl" # python prints the summary line last
  fi
done <<<"$COUNTS_OUT"
if [[ -z "$COUNTS_PARTS" ]]; then
  COUNTS_PARTS="counts=NOT-RUN"
  FAILS+=("counts comparison did not run (verifier error)")
fi

# ---- verdict ----
SUMMARY="stem=$STEM age=${AGE_D}d restore=${RESTORE_S}s canary=${CANARY_N} ${COUNTS_PARTS} pg=$PG_IMAGE size=${DUMP_BYTES}B"
if [[ "${#FAILS[@]}" -gt 0 ]]; then
  for f in "${FAILS[@]}"; do
    echo "ASSERT FAIL: $f" >&2
    _log "ASSERT FAIL: $f"
  done
  echo "FAIL ${SUMMARY} (${#FAILS[@]} assertion(s) failed)" >&2
  verify_log_append "$(date -u +%Y-%m-%dT%H:%M:%SZ) FAIL ${SUMMARY} — ${FAILS[*]}"
  alert "WARN janus backup verify FAILED: ${STEM} — ${FAILS[*]}"
  VERDICT_EMITTED=1
  exit 1
fi
echo "PASS ${SUMMARY}"
verify_log_append "$(date -u +%Y-%m-%dT%H:%M:%SZ) PASS ${SUMMARY}"
VERDICT_EMITTED=1
_log "verify ok $STEM"
