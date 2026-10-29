#!/usr/bin/env bash
# Place/refresh GeoLite2-City.mmdb on a master host and wire compose+.env.
#
#   bash scripts/ensure_master_mmdb.sh aliyun
#
# Host path:  /opt/stacks/janus/geo/GeoLite2-City.mmdb
# In-container: JANUS_MMDB_PATH=/var/lib/janus/geo/GeoLite2-City.mmdb
# Volume:       ./geo:/var/lib/janus/geo  (rw on janus + dashboard —
#               Maintenance "Refresh GeoLite2" writes; gateway reloads).
#
# Credentials (deploy-time fetch): JANUS_MAXMIND_ACCOUNT_ID +
# JANUS_MAXMIND_LICENSE_KEY (or MAXMIND_* / ${TEMP}/janus_prod_secrets.json).
# Operators can also save Account ID + License Key on Maintenance
# (settings.maxmind, license encrypted); that path does not need env.
# Integrity: JANUS_GEOLITE2_MMDB_SHA256 (optional) is enforced by the
# fetch (fail closed on mismatch); with it unset the install is reported
# as UNVERIFIED. The installed copy is always sha256-compared to the fetch.
# Refresh failure with an existing file → warn and keep serving stale.
set -euo pipefail

HOST="${1:-}"
if [ -z "$HOST" ]; then
  echo "usage: $0 <ssh-host>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# LOCAL python (Windows hosts expose `python`, not `python3` — the
# deploy gate runs from Git Bash; server-side heredocs below use the
# aliyun image python3 and are unaffected).
PY3="$(command -v python3 || command -v python || true)"
FETCH="$ROOT/scripts/fetch_geolite2_mmdb.sh"
STACK="/opt/stacks/janus"
HOST_MMDB="$STACK/geo/GeoLite2-City.mmdb"
CTR_MMDB="/var/lib/janus/geo/GeoLite2-City.mmdb"

# Resolve credentials (env wins; secrets file fills gaps). Never print values.
prod_secret() {
  local k="$1"
  "$PY3" - "$k" <<'PY'
import json, os, sys
p = os.path.join(os.environ.get("TEMP", "/tmp"), "janus_prod_secrets.json")
try:
    print(json.load(open(p)).get(sys.argv[1], "") or "")
except Exception:
    print("")
PY
}
ACCOUNT_ID="${JANUS_MAXMIND_ACCOUNT_ID:-${MAXMIND_ACCOUNT_ID:-$(prod_secret MAXMIND_ACCOUNT_ID)}}"
LICENSE_KEY="${JANUS_MAXMIND_LICENSE_KEY:-${MAXMIND_LICENSE_KEY:-$(prod_secret MAXMIND_LICENSE_KEY)}}"
export JANUS_MAXMIND_ACCOUNT_ID="$ACCOUNT_ID"
export JANUS_MAXMIND_LICENSE_KEY="$LICENSE_KEY"

if [ -z "$ACCOUNT_ID" ] || [ -z "$LICENSE_KEY" ]; then
  # Header contract: "Refresh failure with an existing file -> warn and
  # keep serving stale." Missing credentials are a refresh failure —
  # when the master already serves an mmdb, DEGRADE to a warning and
  # continue (the deploy must not block on an optional refresh);
  # hard-fail only when there is no file at all (geo would boot-refuse
  # with JANUS_SCHED_GEO=1 and no mmdb).
  if ssh -o BatchMode=yes "$HOST" "test -s '$HOST_MMDB'" 2>/dev/null; then
    echo "WARN: MaxMind credentials missing — keeping the EXISTING mmdb on $HOST (stale-serve)" >&2
    exit 0
  fi
  echo "FAIL: MaxMind credentials missing (JANUS_MAXMIND_ACCOUNT_ID + JANUS_MAXMIND_LICENSE_KEY)" >&2
  echo "      Add them to the deploy env or ${TEMP:-/tmp}/janus_prod_secrets.json" >&2
  exit 1
fi

LOCAL_TMP="$(mktemp "${TMPDIR:-/tmp}/GeoLite2-City.XXXXXX.mmdb")"
cleanup() { rm -f "$LOCAL_TMP"; }
trap cleanup EXIT

echo "== GeoLite2: fetch locally then install on $HOST =="
if ! bash "$FETCH" "$LOCAL_TMP"; then
  # Stale-ok: if remote already has a file, leave it.
  if ssh -o BatchMode=yes "$HOST" "test -s '$HOST_MMDB'"; then
    echo "WARNING: MaxMind refresh failed — keeping existing $HOST:$HOST_MMDB" >&2
  else
    echo "FAIL: MaxMind fetch failed and no existing mmdb on $HOST" >&2
    exit 1
  fi
else
  ssh -o BatchMode=yes "$HOST" "mkdir -p '$STACK/geo' && chmod 755 '$STACK/geo'"
  # Atomic replace on the remote (scp to .new then mv).
  scp -q "$LOCAL_TMP" "$HOST:${HOST_MMDB}.new"
  ssh -o BatchMode=yes "$HOST" "mv -f '${HOST_MMDB}.new' '$HOST_MMDB' && chmod 644 '$HOST_MMDB'"
  # M5: the remote copy must be byte-identical to the fetched file (scp
  # corruption), and the "installed" line must state whether the artefact
  # is hash-verified instead of implying it via a byte count.
  LOCAL_SHA="$(sha256sum "$LOCAL_TMP" | awk '{print $1}')"
  REMOTE_SHA="$(ssh -o BatchMode=yes "$HOST" "sha256sum '$HOST_MMDB'" | awk '{print $1}')"
  if [ "$REMOTE_SHA" != "$LOCAL_SHA" ]; then
    echo "FAIL: $HOST:$HOST_MMDB sha256 $REMOTE_SHA != fetched $LOCAL_SHA — copy corrupted, refusing to report success" >&2
    exit 1
  fi
  EXPECTED_SHA="$(printf '%s' "${JANUS_GEOLITE2_MMDB_SHA256:-}" | tr 'A-F' 'a-f')"
  if [ -n "$EXPECTED_SHA" ] && [ "$REMOTE_SHA" != "$EXPECTED_SHA" ]; then
    echo "FAIL: $HOST:$HOST_MMDB sha256 $REMOTE_SHA != JANUS_GEOLITE2_MMDB_SHA256 $EXPECTED_SHA" >&2
    exit 1
  fi
  BYTES="$(ssh -o BatchMode=yes "$HOST" "wc -c < '$HOST_MMDB'" | tr -d '[:space:]')"
  echo "   $HOST: mmdb installed ($BYTES bytes, sha256 $REMOTE_SHA)"
  if [ -z "$EXPECTED_SHA" ]; then
    echo "WARN: $HOST: mmdb artefact is UNVERIFIED — JANUS_GEOLITE2_MMDB_SHA256 is not configured (only MaxMind magic + 1 MB size floor were checked)" >&2
  fi
fi

# Upsert JANUS_MMDB_PATH in remote .env (value never logged beyond the path).
ssh -o BatchMode=yes "$HOST" "python3 - <<'PY'
import os
from pathlib import Path
p = Path('$STACK/.env')
key, val = 'JANUS_MMDB_PATH', '$CTR_MMDB'
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
# M6: same-directory temp file + fsync + os.replace — a crash, a full
# disk or a killed ssh must never truncate the live .env (it carries
# every stack secret). Created 0600, given the live file's mode, then
# renamed over it; the pre-existing content stays intact until then.
mode = (p.stat().st_mode & 0o777) if p.exists() else 0o600
tmp = p.with_name(p.name + '.tmp')
fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as fh:
    fh.write('\\n'.join(out) + '\\n')
    fh.flush()
    os.fsync(fh.fileno())
os.chmod(str(tmp), mode)
os.replace(str(tmp), str(p))
print(f'env: JANUS_MMDB_PATH set (atomic, mode {mode:o})')
PY"

# Ensure compose mounts ./geo (rw) on master `janus:` and `dashboard:`
# (dashboard Maintenance refresh writes the file; gateway reloads locus).
ssh -o BatchMode=yes "$HOST" "python3 - <<'PY'
import os
from pathlib import Path
p = Path('$STACK/docker-compose.yml')
text = p.read_text().replace('./geo:/var/lib/janus/geo:ro', './geo:/var/lib/janus/geo')
needle = './geo:/var/lib/janus/geo'
lines = text.splitlines(keepends=True)

def _svc_header(stripped, service):
    prefix = f'  {service}:'
    return stripped == prefix or stripped.startswith(prefix + ' ') or stripped.startswith(prefix + '#')

def _svc_span(lines, service):
    # [start, end): the service's own block, bounded by the next service
    # (2-space key) or the next top-level map (column-0 key).
    start = None
    for i, line in enumerate(lines):
        if _svc_header(line.rstrip('\\n'), service):
            start = i
            break
    if start is None:
        return None
    for j in range(start + 1, len(lines)):
        s = lines[j].rstrip('\\n')
        if s.strip().startswith('#'):
            continue
        if ':' in s and (len(s) - len(s.lstrip(' '))) in (0, 2):
            return start, j
    return start, len(lines)

def ensure_volume(service, lines, needle):
    # Two-pass (H3): decide presence over the whole service block FIRST,
    # then insert only when absent. The single-pass scan set `has` as it
    # advanced, so a pre-existing ./geo mount below `    volumes:` was
    # never seen before the insert point and got duplicated every run.
    span = _svc_span(lines, service)
    if span is None:
        return lines, False
    start, end = span
    if any(needle in lines[i] for i in range(start + 1, end)):
        return lines, True
    out = list(lines)
    for i in range(start + 1, end):
        if out[i].rstrip('\\n') == '    volumes:':
            out.insert(i + 1, f'      - {needle}\\n')
            return out, True
    for i in range(start + 1, end):
        if out[i].rstrip('\\n').startswith('    networks:'):
            out.insert(i, '    volumes:\\n')
            out.insert(i + 1, f'      - {needle}\\n')
            return out, True
    return lines, False

lines, j = ensure_volume('janus', lines, needle)
lines, d = ensure_volume('dashboard', lines, needle)
if not j or not d:
    raise SystemExit(f'FAIL: could not ensure geo volume janus={j} dashboard={d}')

def _geo_mounts(service):
    span = _svc_span(lines, service)
    if span is None:
        return 0
    return sum(1 for i in range(span[0] + 1, span[1]) if needle in lines[i])

mounts = {svc: _geo_mounts(svc) for svc in ('janus', 'dashboard')}
if any(n != 1 for n in mounts.values()):
    raise SystemExit(f'FAIL: refusing to rewrite compose — geo mounts {mounts} (expected exactly 1 per service; an earlier run already duplicated it — remove the extra line by hand)')
tmp = p.with_suffix(p.suffix + '.tmp')
tmp.write_text(''.join(lines))
os.replace(str(tmp), str(p))
print(f'compose: janus_geo={j} dashboard_geo={d} geo_mounts={mounts}')
PY"

# Writable by container uid janus (100:101) so Maintenance refresh can replace.
ssh -o BatchMode=yes "$HOST" "chown -R 100:101 '$STACK/geo' && chmod 775 '$STACK/geo' && chmod 664 '$HOST_MMDB' && test -s '$HOST_MMDB' && ls -la '$HOST_MMDB'"
echo "   $HOST: ready (container path $CTR_MMDB after recreate)"