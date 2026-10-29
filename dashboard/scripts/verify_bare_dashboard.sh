#!/usr/bin/env bash
# verify_bare_dashboard.sh — B-D8 dash half (spec
# 2026-10-15-bare-metal-deploy Task 2): boots the built dashboard
# payload in ONE throwaway python container on the build host, installs
# from the shipped wheelhouse --no-index (F5b: zero egress — the
# container runs with --network none), and asserts the app actually
# serves. No prod secret ever leaves the fleet.
#
# THROWAWAY DB — honest deviation from the B-D8 wording: that bullet
# was written for the GATEWAY (which has a sqlite path). The dashboard
# is Postgres-only (asyncpg, app/database.py) and has a designed
# unconfigured-DB boot path (app/main.py lifespan: warns "not fully
# configured", skips pool init, keeps serving). This verify boots that
# path — NO database at all, no credentials — which is the same
# hermeticity the sqlite wording buys: nothing prod is touched, and
# the assertions below do not depend on a DB.
#
# Assertions (all inside the one container, verdict = its exit code):
#   1. venv install --no-index --find-links wheels/ of the project's
#      OWN WHEEL by name + setuptools/wheel (F7 install shape)
#   2. import precedence: `app` resolves to the PAYLOAD tree, not the
#      venv site-packages copy (the prod unit's WorkingDirectory
#      invariant — the runtime code is always the shipped tree)
#   3. boot-time config-backup schema self-check passes (the app
#      REFUSES to boot without docs/schemas/ in the payload — proof
#      the payload carries it)
#   4. /api/health 200 {"status": "ok"}
#   5. SPA catch-all: GET / serves the built index.html (spa/dist
#      landed in the payload)
#   6. login round-trip with a TEST password env: wrong -> 401,
#      correct -> 200 {token}, token -> GET /api/auth/session 200
#      {valid: true} (auth fail-closed + JWT mint + verify, no DB)
#
# Usage: bash scripts/verify_bare_dashboard.sh [payload-dir]
#   payload-dir defaults to the newest bare-artifacts/dash/dash-*/
#
# Builder image: the FIRST inventory minor's JANUS_PY_BUILDER_<PY3>
# pin when present (F7 digest discipline), else the floating
# python:<minor> (dev/CI convenience — the same fallback
# build_bare_dashboard.sh warns about).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "verify_bare_dashboard: FAIL: $*" >&2; exit 1; }
note() { echo "== $*"; }

PAYLOAD="${1:-}"
if [ -z "$PAYLOAD" ]; then
  PAYLOAD="$(ls -dt "$ROOT"/bare-artifacts/dash/dash-* 2>/dev/null | head -n 1 || true)"
fi
[ -n "$PAYLOAD" ] && [ -d "$PAYLOAD" ] || die "no payload (run scripts/build_bare_dashboard.sh first)"
PAYLOAD="$(cd "$PAYLOAD" && pwd)"
[ -f "$PAYLOAD/app/main.py" ] || die "$PAYLOAD is not a dash payload (no app/main.py)"
[ -d "$PAYLOAD/wheels" ] || die "$PAYLOAD has no wheels/"
PAYLOAD_W="$(cd "$PAYLOAD" && pwd -W 2>/dev/null || pwd)"

# ---------------------------------------------------------- builder ------
INV="${JANUS_INVENTORY:-}"
if [ -z "$INV" ]; then
  # Canonical file FIRST (Task 3 consolidation): the janus repo's
  # deploy/inventory.env is the ONE file both repos resolve; this
  # repo's deploy/inventory.env is a LEGACY fallback only.
  for cand in "$ROOT/../janus/deploy/inventory.env" "$ROOT/deploy/inventory.env"; do
    [ -f "$cand" ] && INV="$cand" && break
  done
fi
MINOR=""
if [ -n "$INV" ] && [ -f "$INV" ]; then
  # shellcheck disable=SC1090
  . "$INV"
  for var in $(grep -oE '^(export )?JANUS_NODE_[A-Za-z0-9]+=' "$INV" | sed 's/^export //; s/=$//' | grep -v '^JANUS_NODE_ADDR_'); do
    v="${!var:-}"
    py="$(printf '%s' "$v" | tr ';' '\n' | grep -m1 '^py3=' | sed 's/^py3=//')"
    [ -n "$py" ] && MINOR="$py" && break
  done
fi
[ -n "$MINOR" ] || MINOR="3.13"
KEY="JANUS_PY_BUILDER_$(printf '%s' "$MINOR" | tr '.' '_')"
PIN="${!KEY:-}"
if [ -n "$PIN" ] && ! printf '%s' "$PIN" | grep -qE 'sha256:0+$'; then
  VERIFY_IMAGE="$PIN"
  note "verify image: pinned $VERIFY_IMAGE"
else
  VERIFY_IMAGE="python:$MINOR"
  note "verify image: WARNING — no real $KEY pin; floating $VERIFY_IMAGE (dev/CI convenience)"
fi

# The build's recorded minors must include the verify minor (the
# wheelhouse needs its cp-tagged wheels).
if [ -f "$PAYLOAD/BUILD-FACTS.txt" ]; then
  covered="$(sed -n 's/^py_minors=//p' "$PAYLOAD/BUILD-FACTS.txt")"
  if [ -n "$covered" ] && ! printf ' %s ' "$covered" | grep -q " $MINOR "; then
    die "verify minor $MINOR not covered by the payload wheelhouse (py_minors=$covered)"
  fi
fi

# ------------------------------------------------------ assert script ----
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/verify.py" <<'PYEOF'
"""In-container assertions for verify_bare_dashboard (B-D8 dash half)."""
import json
import sys
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8091"
PASSWORD = "verify-bare-dash-password"


def req(method, path, body=None, token=None):
    r = urllib.request.Request(BASE + path, method=method)
    if token:
        r.add_header("Authorization", "Bearer " + token)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, data, timeout=5) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


deadline = time.time() + 60
while True:
    try:
        status, body = req("GET", "/api/health")
        if status == 200:
            break
    except Exception:
        pass
    if time.time() > deadline:
        fail("/api/health never answered (see the uvicorn log above)")
    time.sleep(1)

health = json.loads(body)
if health.get("status") != "ok" or health.get("service") != "janus-dashboard":
    fail(f"/api/health wrong body: {health}")
print("PASS: /api/health -> " + body)

status, body = req("GET", "/")
if status != 200 or 'id="root"' not in body:
    fail(f"GET / did not serve the SPA shell (status {status})")
print("PASS: GET / serves the built SPA index.html")

status, body = req("POST", "/api/auth/login", {"password": "wrong-password"})
if status != 401:
    fail(f"wrong password returned {status}, expected 401 (fail-closed)")
print("PASS: wrong password -> 401")

status, body = req("POST", "/api/auth/login", {"password": PASSWORD})
if status != 200:
    fail(f"correct password returned {status}: {body}")
token = json.loads(body).get("token")
if not token:
    fail(f"login returned no token: {body}")
print("PASS: login -> token issued")

status, body = req("GET", "/api/auth/session", token=token)
if status != 200 or not json.loads(body).get("valid"):
    fail(f"session check with the minted token failed: {status} {body}")
print("PASS: GET /api/auth/session -> valid (login round-trip complete)")

print("VERIFY_OK")
PYEOF
VERIFY_W="$(cd "$WORK" && pwd -W 2>/dev/null || pwd)"

CTR="janus-verify-dash-$$"
note "verifying $(basename "$PAYLOAD") in $VERIFY_IMAGE (--network none, throwaway venv, NO database)"
# shellcheck disable=SC2030,SC2031
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker run --rm --name "$CTR" \
  --network none --platform linux/amd64 \
  -v "$PAYLOAD_W:/payload:ro" \
  -v "$VERIFY_W/verify.py:/verify.py:ro" \
  "$VERIFY_IMAGE" sh -eu -c '
    echo "== python $(python -V 2>&1), glibc: $(ldd --version | head -1)"
    python -m venv /tmp/v
    /tmp/v/bin/pip install --no-index --find-links /payload/wheels/ janus-dashboard setuptools wheel
    /tmp/v/bin/pip show janus-dashboard > /dev/null
    echo "PASS: venv install --no-index from the shipped wheelhouse (F5b)"
    cd /payload
    MODFILE="$(/tmp/v/bin/python -c "import app, sys; sys.stdout.write(app.__file__)")"
    case "$MODFILE" in
      /payload/app/__init__.py) echo "PASS: app resolves to the payload tree ($MODFILE)" ;;
      *) echo "FAIL: app resolved to $MODFILE — site-packages copy shadows the shipped tree"; exit 1 ;;
    esac
    export JANUS_DASHBOARD_PASSWORD="verify-bare-dash-password"
    export JANUS_JWT_SECRET="verify-bare-jwt-secret"
    /tmp/v/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port 8091 > /tmp/uvicorn.log 2>&1 &
    UVPID=$!
    trap "kill $UVPID 2>/dev/null || true; tail -40 /tmp/uvicorn.log" EXIT
    /tmp/v/bin/python /verify.py
    kill $UVPID 2>/dev/null || true
    trap - EXIT
  ' || { echo "---- container output above; uvicorn log tail follows ----" >&2; exit 1; }

note "verify_bare_dashboard OK: no-index install + import precedence + boot schema self-check + /api/health + SPA shell + login round-trip all green"
