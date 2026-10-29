#!/usr/bin/env bash
# Daily leader Postgres + .env generation-set backup (age-encrypted).
# Spec §5.3 — run on the leader node via janus-backup.timer.
# H3-D7/H4 (spec 2026-10-15-maturity-hardening): the leader host comes
# from the operator-side topology — REFUSE when it is missing (never
# silently default to the leader). On the leader node the timer context has
# no operator-side FILE: set JANUS_TOPOLOGY_FILE or JANUS_TOPOLOGY_LEADER
# in /opt/stacks/janus/janus-backup.env to the current leader (the
# authoritative mirrors stay at the deploy origins: dev-box
# ~/.janus/topology + runner /opt/janus-ci/topology).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/janus_backup_common.sh
source "${SCRIPT_DIR}/lib/janus_backup_common.sh"
# shellcheck source=lib/janus_topology.sh
source "${SCRIPT_DIR}/lib/janus_topology.sh"

load_backup_env
acquire_lock

require_cmd docker
require_cmd age
require_cmd openssl
require_cmd python3
require_cmd flock

# ---- topology guard (H3-D7): who is the leader? ----
LEADER="$(topology_read)" || die 2 "no topology file found — refusing to guess the leader (bootstrap from a deploy origin: deploy_prod.sh --init-topology <host>; on-node timer: set JANUS_TOPOLOGY_FILE/JANUS_TOPOLOGY_LEADER in janus-backup.env)"
_log "topology: leader=$LEADER (source: $(topology_source))"
# ---- demoted-node guard (H3-D7) ----
# The topology speaks SSH aliases, so this node must name itself.
# JANUS_BACKUP_NODE_ALIAS (janus-backup.env) wins; otherwise derive the alias
# from the local hostname against the host inventory (topology leader +
# JANUS_FOLLOWER_HOSTS) and FAIL CLOSED when the hostname matches neither —
# an unidentifiable node cannot prove it is the leader, and a stale timer on
# a demoted node must never upload a "leader" backup under the same stem.
HOST_SHORT="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
HOST_FQDN="$(hostname -f 2>/dev/null || true)"
_node_matches() { # $1=topology alias; rc 0 when a local hostname form equals it
  local alias="$1" h
  for h in "$HOST_SHORT" "$HOST_FQDN" "${HOST_FQDN%%.*}"; do
    [[ -n "$h" && "$h" == "$alias" ]] && return 0
  done
  return 1
}
NODE_ALIAS="${JANUS_BACKUP_NODE_ALIAS:-}"
NODE_ALIAS_SRC="JANUS_BACKUP_NODE_ALIAS"
if [[ -z "$NODE_ALIAS" ]]; then
  NODE_ALIAS_SRC="derived from local hostname"
  if _node_matches "$LEADER"; then
    NODE_ALIAS="$LEADER"
  else
    IFS=',' read -r -a _KNOWN_NODES <<<"${JANUS_FOLLOWER_HOSTS:-}"
    for h in ${_KNOWN_NODES[@]+"${_KNOWN_NODES[@]}"}; do
      h="$(echo "$h" | xargs)"
      [[ -n "$h" ]] || continue
      if _node_matches "$h"; then
        NODE_ALIAS="$h"
        break
      fi
    done
  fi
fi
if [[ -z "$NODE_ALIAS" ]]; then
  die 2 "cannot determine this node's topology alias (hostname '${HOST_SHORT:-?}' matches neither the topology leader '$LEADER' nor JANUS_FOLLOWER_HOSTS='${JANUS_FOLLOWER_HOSTS:-<unset>}') — set JANUS_BACKUP_NODE_ALIAS in /opt/stacks/janus/janus-backup.env (documented in scripts/janus-backup.env.example) so a demoted node cannot back up as the leader"
fi
if [[ "$NODE_ALIAS" != "$LEADER" ]]; then
  die 2 "topology leader is '$LEADER' but this node is '$NODE_ALIAS' — move the backup timer to the leader (post-promote role swap, H3-D7)"
fi
_log "node alias=$NODE_ALIAS (source: $NODE_ALIAS_SRC)"
# Leader health probe (H3-D7): the local Postgres must answer before we
# dump — a fenced/dying leader refuses here instead of producing a
# partial snapshot silently.
pg_exec 'SELECT 1;' >/dev/null || die 3 "leader ($LEADER) Postgres not answering (promote in progress? H3-D7) — refusing to back up"
# The dump is validated with the CONTAINER's client: the runbook installs no
# host postgresql-client, and a host pg_restore older than the server major
# could reject the archive header with a message that blames the dump (M4).
docker exec "$JANUS_POSTGRES_CONTAINER" pg_restore --version >/dev/null 2>&1 \
  || die 1 "container '$JANUS_POSTGRES_CONTAINER' provides no pg_restore — cannot validate the dump (the standard postgres image ships it)"

HOT="$JANUS_BACKUP_HOT_DIR"
mkdir -p "$HOT" "$JANUS_BACKUP_LOG_DIR"
STEM="janus-$(utc_stem)"
WORKDIR="$(mktemp -d "${HOT}/.work.XXXXXX")"
ENV_NEW=""
cleanup() {
  shred_file "${WORKDIR}/dump.Fc" 2>/dev/null || true
  shred_file "${WORKDIR}/env.plain" 2>/dev/null || true
  if [[ -n "${ENV_NEW:-}" ]]; then
    shred_file "$ENV_NEW" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

_log "backup start stem=$STEM"

# --- disk precheck (db size) ---
DB_SIZE="$(docker exec "$JANUS_POSTGRES_CONTAINER" psql -U "$JANUS_PG_USER" -d "$JANUS_PG_DB" -t -A -c \
  "SELECT pg_database_size(current_database());" | tr -d '[:space:]')"
[[ "$DB_SIZE" =~ ^[0-9]+$ ]] || die 1 "cannot read db size"
assert_backup_disk "$DB_SIZE"

# --- canary + pre-dump counts (maturity-hardening H5-D1) ---
# Canary row lands INSIDE this dump; verify_backup.sh restores the dump
# into a throwaway container and asserts the row round-trips. sha covers
# host+ts so a restore cannot accidentally count a foreign canary.
CANARY_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CANARY_HOST="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
CANARY_SHA="$(printf '%s%s' "$CANARY_HOST" "$CANARY_TS" | openssl dgst -sha256 -hex | awk '{print $NF}')"
pg_exec "CREATE TABLE IF NOT EXISTS backup_canaries (ts timestamptz NOT NULL, sha text NOT NULL);" >/dev/null
# values travel as psql -v variables, never interpolated into SQL text (L3)
pg_exec_v "INSERT INTO backup_canaries (ts, sha) VALUES (:'ts'::timestamptz, :'sha');" \
  -v ts="$CANARY_TS" -v sha="$CANARY_SHA" >/dev/null

# Pre-dump counts of the four key tables, stored beside the dump as
# <stem>.counts.json (part of the generation set); verify_backup.sh
# asserts restore counts stay within 10% of these. stem/taken_at/host ride
# in the same document so the drill can bind the snapshot to its stem (L6).
COUNTS_JSON="$(pg_exec_v "SELECT json_build_object('stem', :'stem', 'taken_at', :'taken_at'::timestamptz, 'host', :'host', 'counts', json_build_object('providers', (SELECT count(*) FROM providers), 'provider_models', (SELECT count(*) FROM provider_models), 'api_keys', (SELECT count(*) FROM api_keys), 'models', (SELECT count(*) FROM models)))::text;" \
  -v stem="$STEM" -v taken_at="$CANARY_TS" -v host="$CANARY_HOST")"
COUNTS_FILE="${HOT}/${STEM}.counts.json"
printf '%s\n' "$COUNTS_JSON" >"$COUNTS_FILE"
_log "canary sha=${CANARY_SHA:0:12}... counts->${STEM}.counts.json"

# --- dump ---
DUMP_PLAIN="${WORKDIR}/dump.Fc"
docker exec "$JANUS_POSTGRES_CONTAINER" pg_dump -U "$JANUS_PG_USER" -d "$JANUS_PG_DB" -Fc --no-owner --no-privileges \
  >"$DUMP_PLAIN"
# Archive validated by the CONTAINER's pg_restore over stdin (M4): a host
# binary is not provisioned by the runbook, and "missing binary" must not be
# reported as "bad dump" (the preflight above already ruled that out).
docker exec -i "$JANUS_POSTGRES_CONTAINER" pg_restore --list <"$DUMP_PLAIN" >/dev/null \
  || die 1 "the container's pg_restore cannot read the fresh dump archive — pg_dump wrote a truncated/corrupt archive"

# --- age dump ---
mapfile -t AGE_ARGS < <(age_recipients_args)
DUMP_AGE="${HOT}/${STEM}.dump.age"
age -e "${AGE_ARGS[@]}" -o "$DUMP_AGE" "$DUMP_PLAIN"
shred_file "$DUMP_PLAIN"

# --- age env ---
[[ -f "$JANUS_ENV_FILE" ]] || die 1 "missing $JANUS_ENV_FILE"
ENV_PLAIN="${WORKDIR}/env.plain"
cp "$JANUS_ENV_FILE" "$ENV_PLAIN"
chmod 600 "$ENV_PLAIN"
ENV_AGE="${HOT}/${STEM}.env.age"
age -e "${AGE_ARGS[@]}" -o "$ENV_AGE" "$ENV_PLAIN"

# Mint JANUS_SECRETS_GENERATION_ID on first backup if absent (atomic .env replace)
SID="$(env_get JANUS_SECRETS_GENERATION_ID "$JANUS_ENV_FILE")"
if [[ -z "$SID" ]]; then
  SID="sg-$(utc_stem)-$$"
  _log "minting JANUS_SECRETS_GENERATION_ID=$SID into live .env"
  # 06a M6: the temp MUST live in the target directory. The old temp lived
  # under /var/backups, so `mv` onto /opt/stacks could cross a filesystem and
  # degrade to copy+truncate of the live secrets file. Same-dir temp +
  # os.replace() is a real rename(2), preserving the live file's owner/mode.
  ENV_NEW="$(mktemp "${JANUS_ENV_FILE}.new.XXXXXX")"
  python3 - "$JANUS_ENV_FILE" "$ENV_NEW" "$SID" <<'PY'
import os, sys

env_path, tmp, sid = sys.argv[1], sys.argv[2], sys.argv[3]
with open(env_path, "rb") as src:
    st = os.fstat(src.fileno())
    data = src.read()
with open(tmp, "wb") as out:
    out.write(data)
    if data and not data.endswith(b"\n"):
        out.write(b"\n")
    out.write(b"JANUS_SECRETS_GENERATION_ID=" + sid.encode("utf-8") + b"\n")
    out.flush()
    os.fsync(out.fileno())
# cp -p semantics, tightened: never widen the documented root-600 .env.
os.chmod(tmp, (st.st_mode & 0o777) & ~0o077)
try:
    os.chown(tmp, st.st_uid, st.st_gid)
except OSError:
    pass  # not root: keep the invoking user
os.replace(tmp, env_path)
PY
  ENV_NEW=""
  cp "$JANUS_ENV_FILE" "$ENV_PLAIN"
  age -e "${AGE_ARGS[@]}" -o "$ENV_AGE" "$ENV_PLAIN"
fi

# Round-trip decrypt-verify .env.age (keys present)
if [[ -z "${AGE_IDENTITY_FILE:-}" ]]; then
  _log "WARN: AGE_IDENTITY_FILE unset — skipping round-trip decrypt verify (set for full verify)"
else
  RT="$(mktemp "${WORKDIR}/rt.XXXXXX")"
  age -d -i "$AGE_IDENTITY_FILE" -o "$RT" "$ENV_AGE" || die 11 "age round-trip decrypt failed"
  for k in JANUS_SECRETS_KEY JANUS_API_KEY_PEPPER JANUS_SECRETS_GENERATION_ID; do
    v="$(env_get "$k" "$RT")"
    [[ -n "$v" ]] || die 1 "round-trip env missing $k"
  done
  shred_file "$RT"
fi

PEPPER="$(env_get JANUS_API_KEY_PEPPER "$JANUS_ENV_FILE")"
[[ -n "$PEPPER" ]] || die 1 "JANUS_API_KEY_PEPPER missing in .env"
PEPPER_HASH="$(pepper_canary_hash "$PEPPER")"

# --- migrations + generation ---
MIGS_JSON="$(pg_exec "SELECT COALESCE(json_agg(version ORDER BY version), '[]'::json) FROM schema_migrations;")"
GEN="$(pg_exec "SELECT config_generation FROM config_meta WHERE id = 1;" | tr -d '[:space:]')"
[[ "$GEN" =~ ^[0-9]+$ ]] || die 1 "config_generation missing or non-numeric (got '${GEN:-empty}')"
PG_VER="$(docker exec "$JANUS_POSTGRES_CONTAINER" psql -U "$JANUS_PG_USER" -d "$JANUS_PG_DB" -t -A -c 'SHOW server_version_num;' | tr -d '[:space:]')"
printf '%s' "$MIGS_JSON" >"${WORKDIR}/migs.json"

# --- image digests ---
GW_IMG="$(compose images -q "$JANUS_GATEWAY_SERVICE" 2>/dev/null | head -1 || true)"
DASH_IMG="$(compose images -q "$JANUS_DASHBOARD_SERVICE" 2>/dev/null | head -1 || true)"
[[ -n "$GW_IMG" ]] || GW_IMG="$(docker inspect -f '{{.Image}}' "$(compose ps -q "$JANUS_GATEWAY_SERVICE")" 2>/dev/null || true)"
[[ -n "$DASH_IMG" ]] || DASH_IMG="$(docker inspect -f '{{.Image}}' "$(compose ps -q "$JANUS_DASHBOARD_SERVICE")" 2>/dev/null || true)"

GW_FORM=""; GW_DIGEST=""; DASH_FORM=""; DASH_DIGEST=""
if [[ -n "$GW_IMG" ]]; then
  IFS='|' read -r GW_FORM GW_DIGEST <<<"$(image_digest_for "$GW_IMG")"
fi
if [[ -n "$DASH_IMG" ]]; then
  IFS='|' read -r DASH_FORM DASH_DIGEST <<<"$(image_digest_for "$DASH_IMG")"
fi

GW_GIT="$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$GW_IMG" 2>/dev/null || true)"
DASH_GIT="$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$DASH_IMG" 2>/dev/null || true)"

MANIFEST="${HOT}/${STEM}.manifest.json"
python3 - "$MANIFEST" "${WORKDIR}/migs.json" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CANARY_HOST" "$STEM" \
  "$DB_SIZE" "$PG_VER" "$GEN" "$GW_DIGEST" "$GW_FORM" "$DASH_DIGEST" "$DASH_FORM" \
  "$GW_GIT" "$DASH_GIT" "$SID" "$PEPPER_HASH" "${JANUS_BACKUP_AGE_RECIPIENTS}" \
  "$CANARY_TS" "$CANARY_SHA" <<'PY'
import json, sys
(
    path, migs_path, taken_at, host, stem, db_size, pg_ver, gen,
    gw_d, gw_f, dash_d, dash_f, gw_git, dash_git, sid, pepper_hash, recipients,
    canary_ts, canary_sha,
) = sys.argv[1:20]
with open(migs_path, encoding="utf-8") as f:
    raw = f.read().strip() or "[]"
migs = json.loads(raw)
doc = {
    "taken_at": taken_at,
    "host": host,
    "stem": stem,
    # 06a L6: the canary actually inserted INTO this dump, so the drill can
    # bind the restored row to this generation set instead of any row.
    "canary_ts": canary_ts,
    "canary_sha": canary_sha,
    "db_size_bytes": int(db_size),
    "postgres_version": pg_ver,
    "schema_migrations": migs,
    "settings_generation": int(gen),
    "gateway_sha256": gw_d,
    "gateway_digest_form": gw_f,
    "dashboard_sha256": dash_d,
    "dashboard_digest_form": dash_f,
    "gateway_git_sha": gw_git,
    "dashboard_git_sha": dash_git,
    "secrets_generation_id": sid,
    "pepper_canary_hash": pepper_hash,
    "age_recipients": [x.strip() for x in recipients.split(",") if x.strip()],
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, sort_keys=True)
    f.write("\n")
print(path)
PY

shred_file "$ENV_PLAIN"

# --- upload cold ---
YYYY="$(date -u +%Y)"
MM="$(date -u +%m)"
PREFIX="janus-backups/${YYYY}/${MM}"
for kind in dump.age env.age manifest.json counts.json; do
  case "$kind" in
    dump.age) src="$DUMP_AGE" ;;
    env.age) src="$ENV_AGE" ;;
    manifest.json) src="$MANIFEST" ;;
    counts.json) src="$COUNTS_FILE" ;;
  esac
  rel="${PREFIX}/${STEM}.${kind}"
  upload_cold "$src" "$rel"
  verify_cold_present "$rel" || die 1 "cold verify failed: $rel"
done

# Verify dump list via age decrypt to temp if identity present
if [[ -n "${AGE_IDENTITY_FILE:-}" ]]; then
  TMPD="$(mktemp "${WORKDIR}/dump-rt.XXXXXX")"
  age -d -i "$AGE_IDENTITY_FILE" -o "$TMPD" "$DUMP_AGE"
  # M4: same container client, read over stdin (no host pg_restore, no host
  # path visible to the container).
  docker exec -i "$JANUS_POSTGRES_CONTAINER" pg_restore --list <"$TMPD" >/dev/null \
    || die 1 "cold dump list-verify failed — the uploaded dump does not round-trip as a readable archive"
  shred_file "$TMPD"
fi

# --- hot prune (always age out hot) ---
HOT_DAYS="${JANUS_BACKUP_HOT_RETENTION_DAYS:-3}"
[[ "$HOT_DAYS" =~ ^[0-9]+$ ]] || die 1 "JANUS_BACKUP_HOT_RETENTION_DAYS must be a whole number of days (got '$HOT_DAYS')"
# L2: no 2>/dev/null — a bad value or an unreadable hot dir must fail the run
# instead of silently stopping pruning until assert_backup_disk refuses.
PRUNED="$(find "$HOT" -maxdepth 1 -type f \
  \( -name 'janus-*.dump.age' -o -name 'janus-*.env.age' \
  -o -name 'janus-*.manifest.json' -o -name 'janus-*.counts.json' \) \
  -mtime +"$HOT_DAYS" -print -delete | wc -l)" \
  || die 1 "hot prune failed under $HOT (see the find error above)"
_log "hot prune: removed $(echo "$PRUNED" | tr -d '[:space:]') artefact(s) older than ${HOT_DAYS}d"

# --- cold prune (gated) ---
if [[ "${JANUS_BACKUP_COLD_PRUNE:-0}" == "1" ]]; then
  # L1: v1 has no cold-store deletion. Say so loudly instead of implying a
  # retention policy was applied; the example no longer advertises the knob.
  _log "WARN: JANUS_BACKUP_COLD_PRUNE=1 has NO EFFECT in v1 — nothing was deleted from the cold store (prune it manually after two green drills)"
else
  _log "cold prune skipped (JANUS_BACKUP_COLD_PRUNE=${JANUS_BACKUP_COLD_PRUNE:-0})"
fi

# --- success marker for staleness timer ---
date -u +%Y-%m-%dT%H:%M:%SZ >"${HOT}/last_success"
_log "backup ok stem=$STEM gen=$GEN size=$DB_SIZE"
echo "$STEM"
