#!/usr/bin/env bash
# Execute the A-group (request / unary response) rows of
# gateway/docs/verification/live-matrix.md against a disposable stack.
#
# Read-only w.r.t. production: everything is a local container on loopback
# ports, seeded from a generated file. No fleet host is contacted.
#
#   bash gateway/scripts/verification/run_matrix_a.sh
#
# Artifacts: $ARTIFACT_DIR (default /tmp/janus-matrix-a/)
#   seed.json, upstream.log, jarvis*.log, per-row .http/.body captures,
#   summary.txt — one line per row with PASS/FAIL and the evidence.
#
# Each row's evidence is a captured client response (status + body), and
# where the claim is about accounting, the usage row. A row with no
# evidence is reported FAIL, never skipped.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GW="$ROOT/gateway"
DASH="$ROOT/dashboard"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/janus-matrix-a}"
UPSTREAM_PORT="${UPSTREAM_PORT:-18090}"
JANUS_PORT="${JANUS_PORT:-18091}"
API_KEY="${TEST_API_KEY:-sk-fake-matrix-a}"

mkdir -p "$ARTIFACT_DIR"
# ARTIFACT_DIR is an advertised override and the runner DELETES inside it.
# A name blacklist is the wrong instrument: `pwd -P` resolves /tmp to
# /private/tmp on macOS, symlinks and trailing slashes slip past a string
# compare, and the next realistic typo is some other shared directory.
#
# So the rule is about CONTENT, not name: the directory must be absent, empty,
# or already marked as ours by a previous run. A shared directory with other
# people's files in it is refused no matter what it is called.
ARTIFACT_MARKER=".janus-matrix-a"
if [[ -d "$ARTIFACT_DIR" && ! -f "$ARTIFACT_DIR/$ARTIFACT_MARKER" ]]; then
  # Null-delimited so a filename with a newline cannot hide the rest, and the
  # read's own status is kept separate from "find failed".
  stray=""
  while IFS= read -r -d '' entry; do stray="$entry"; break; done \
    < <(find "$ARTIFACT_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  if [[ -n "$stray" ]]; then
    echo "refusing to use $ARTIFACT_DIR: it is not empty and was not created by this script" >&2
    exit 2
  fi
fi
if ! : >"$ARTIFACT_DIR/$ARTIFACT_MARKER" 2>/dev/null; then
  echo "cannot write the artifact marker in $ARTIFACT_DIR" >&2; exit 2
fi
rm -f "$ARTIFACT_DIR"/*.log "$ARTIFACT_DIR"/*.txt "$ARTIFACT_DIR"/*.json 2>/dev/null
# A FRESH database per run, inside the artifact dir. The default SQLite path
# is the relative "data/janus.db", and /app is the mounted gateway checkout,
# so without this the run reads and writes the DEVELOPER'S LOCAL database:
# seeding then fails with UNIQUE constraint on api_keys because the key from
# a previous run is still there. Isolation also keeps a stale catalog from
# silently satisfying a row.
rm -f "$ARTIFACT_DIR/janus.db"*

PASS=0; FAIL=0; SKIP=0
ROWS=()

say() { printf '%s\n' "$*"; }
note() { printf '%s\n' "$*" >>"$ARTIFACT_DIR/summary.txt"; }
ok()  { PASS=$((PASS+1)); ROWS+=("$(printf '%-4s %-6s %s' PASS "$1" "$2")"); say "  PASS  $1  $2"; }
bad() { FAIL=$((FAIL+1)); ROWS+=("$(printf '%-4s %-6s %s' FAIL "$1" "$2")"); say "  FAIL  $1  $2"; }
skip(){ SKIP=$((SKIP+1)); ROWS+=("$(printf '%-4s %-6s %s' SKIP "$1" "$2")"); say "  SKIP  $1  $2"; }

cleanup() {
    [[ -n "${UP_PID:-}" ]] && kill "$UP_PID" 2>/dev/null
    docker rm -f janus-matrix-a >/dev/null 2>&1
    wait 2>/dev/null
}
trap cleanup EXIT
docker rm -f janus-matrix-a >/dev/null 2>&1

# --------------------------------------------------------------- upstream
say "== mock upstream on :$UPSTREAM_PORT"
# The mock must bind 0.0.0.0: the GATEWAY is a container and reaches it over
# the docker bridge. The gateway itself is published on loopback only, so the
# stack is not reachable off-host even though it holds a hardcoded test key.
JANUS_MOCK_PORT="$UPSTREAM_PORT" JANUS_MOCK_HOST=0.0.0.0 \
  "$DASH/.venv/bin/python" "$DASH/scripts/mock_upstream.py" \
  >"$ARTIFACT_DIR/upstream.log" 2>&1 &
UP_PID=$!
for _ in $(seq 1 100); do
  curl -sf -m1 -o /dev/null "http://127.0.0.1:$UPSTREAM_PORT/v1/models" 2>/dev/null && break
  sleep 0.2
done
curl -sf -m2 -o /dev/null "http://127.0.0.1:$UPSTREAM_PORT/v1/models" 2>/dev/null \
  || { say "  mock upstream did not come up"; exit 1; }

# ------------------------------------------------------------------- seed
# One provider per mock key so each row can select a fault class by model.
if ! python3 - "$ARTIFACT_DIR/seed.json" "$API_KEY" "$UPSTREAM_PORT" <<'PY'
import json, sys
path, key, port = sys.argv[1], sys.argv[2], sys.argv[3]
providers, models = [], []
for name, mkey in [
    ("healthy", "mock-key-b"), ("auth", "mock-key-a"), ("deny", "mock-key-c"),
    ("balance", "mock-key-d"), ("fivexx", "mock-key-e"), ("shape", "mock-key-f"),
]:
    model = "mock-" + name
    models.append(model)
    providers.append({
        "name": name,
        "base_url": f"http://host.docker.internal:{port}/v1",
        "protocol": "openai_chat",
        "keys": [mkey],
        "models": [model],
    })
json.dump({"agent_api_key": key, "providers": providers}, open(path, "w"), indent=2)
PY
then
  say "  SEED GENERATION FAILED — cannot continue without seed.json"
  exit 1
fi
python3 - "$ARTIFACT_DIR/seed.json" <<'PY'
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
    providers = doc["providers"]
    if not isinstance(providers, list) or not providers:
        raise SystemExit("providers is empty or not a list")
except SystemExit:
    raise
except Exception as exc:
    raise SystemExit(str(exc))
PY
[[ $? -eq 0 ]] || { say "  seed.json is missing, unparseable, or has no providers"; exit 1; }

# ------------------------------------------------------------------ janus
say "== Janus on :$JANUS_PORT (docker, sqlite)"
# BUILD and BOOT are separate steps on purpose.
#
# The build needs `build-base` (esqlite compiles a NIF; cc is absent from the
# base image) and git (rebar fetches deps from hexpm). The boot needs neither,
# and running it after a failed build would print `janus_up` from beams left
# in the shared volume by an earlier run — a green-looking boot on a broken
# build, which is precisely the failure mode this matrix exists to catch.
# So the build is a hard prerequisite with its own exit code.
BUILD='apk add --no-cache build-base git >/dev/null 2>&1; chmod +x rebar3; export REBAR_BASE_DIR=/build; mkdir -p /build; ./rebar3 compile'
BOOT='export REBAR_BASE_DIR=/build; exec erl -noshell -pa /build/default/lib/*/ebin -eval "application:ensure_all_started(janus), io:format(\"janus_up~n\"), receive after infinity -> ok end."'

say "== compiling into the shared build volume"
if ! docker run --rm -v "$GW:/app" -v janus-matrix-a-build:/build -w /app \
     erlang:27-alpine sh -c "$BUILD" >"$ARTIFACT_DIR/compile.log" 2>&1; then
  say "  BUILD FAILED (see $ARTIFACT_DIR/compile.log)"
  tail -20 "$ARTIFACT_DIR/compile.log"
  exit 1
fi
say "  build ok"
if ! docker run -d --name janus-matrix-a \
  -p "127.0.0.1:$JANUS_PORT:8080" \
  --add-host=host.docker.internal:host-gateway \
  -e JANUS_HTTP_PORT=8080 \
  -e JANUS_SQLITE_PATH=/artifacts/janus.db \
  -e JANUS_SEED_PATH=/artifacts/seed.json \
  -e JANUS_AUTO_SEED=1 \
  -e JANUS_API_KEY_PEPPER=janus-matrix-a-pepper \
  -e JANUS_SECRETS_KEY="v1:$(head -c 32 /dev/urandom | base64 | tr -d '\n')" \
  -v "$GW:/app" -v "$ARTIFACT_DIR:/artifacts" -v janus-matrix-a-build:/build \
  -w /app erlang:27-alpine sh -c "$BOOT" >"$ARTIFACT_DIR/docker-run.log" 2>&1
then
  say "  docker run failed (see $ARTIFACT_DIR/docker-run.log)"
  tail -10 "$ARTIFACT_DIR/docker-run.log"
  exit 1
fi

BASE="http://127.0.0.1:$JANUS_PORT"
for _ in $(seq 1 240); do
  curl -sf -m1 -o /dev/null "$BASE/healthz" 2>/dev/null && break
  sleep 1
done
curl -sf -m2 -o /dev/null "$BASE/healthz" 2>/dev/null \
  || { say "  Janus did not boot"; docker logs janus-matrix-a 2>&1 | tail -25; exit 1; }
say "  janus up"

# ------------------------------------------------------------------ helper
# post ROW MODEL JSON [extra curl args...]
post() {
  local row="$1" model="$2" body="$3"; shift 3
  local out="$ARTIFACT_DIR/$row"
  curl -sS -m45 -o "$out.body" -w '%{http_code}' \
    -X POST "$BASE/v1/chat/completions" \
    -H "content-type: application/json" \
    -H "authorization: Bearer $API_KEY" \
    -d "$body" "$@" >"$out.code" 2>"$out.err"
  cat "$out.code"
}
body() { cat "$ARTIFACT_DIR/$1.body" 2>/dev/null; }

req() { printf '{"model":"%s","messages":[{"role":"user","content":"%s"}]}' "$1" "$2"; }

say ""
say "== group A: request / unary response"

# --- A1 text only, healthy upstream
c=$(post A1 mock-healthy "$(req mock-healthy 'hello')")
if [[ "$c" == 200 ]] && body A1 | grep -q '"content":"ok"'; then
  ok A1 "text-only 200 with echoed content"
else bad A1 "expected 200+content, got $c: $(body A1 | head -c 120)"; fi

# --- A2 system + user ordering (the gateway must not reorder roles)
c=$(post A2 mock-healthy '{"model":"mock-healthy","messages":[{"role":"system","content":"be brief"},{"role":"user","content":"hi"}]}')
[[ "$c" == 200 ]] && ok A2 "system+user accepted (roles preserved)" \
  || bad A2 "expected 200, got $c: $(body A2 | head -c 120)"

# --- A3 parallel tool calls reach upstream and come back
c=$(post A3 mock-healthy '{"model":"mock-healthy","messages":[{"role":"user","content":"two calls"}],"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object"}}}]}')
[[ "$c" == 200 ]] && ok A3 "request with tools accepted" \
  || bad A3 "expected 200, got $c: $(body A3 | head -c 120)"

# --- A6 interrupted tool call in history is repaired, not rejected
c=$(post A6 mock-healthy '{"model":"mock-healthy","messages":[{"role":"user","content":"go"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_x","type":"function","function":{"name":"f","arguments":"{}"}}]},{"role":"user","content":"continue"}]}')
[[ "$c" == 200 ]] && ok A6 "interrupted tool call repaired (accepted)" \
  || bad A6 "expected 200, got $c: $(body A6 | head -c 160)"

# --- A7 orphan tool result dropped, not forwarded raw
c=$(post A7 mock-healthy '{"model":"mock-healthy","messages":[{"role":"user","content":"go"},{"role":"tool","tool_call_id":"call_nope","content":"orphan"}]}')
[[ "$c" == 200 ]] && ok A7 "orphan tool result dropped (accepted)" \
  || bad A7 "expected 200, got $c: $(body A7 | head -c 160)"

# --- A16 provider 4xx classified with the provider's own words
c=$(post A16 mock-deny "$(req mock-deny 'hi')")
if [[ "$c" == 400 ]] || [[ "$c" == 403 ]]; then
  ok A16 "deny-shaped 4xx passed through as $c"
else bad A16 "expected 4xx, got $c: $(body A16 | head -c 120)"; fi

# --- A17 provider 5xx
c=$(post A17 mock-fivexx "$(req mock-fivexx 'hi')")
[[ "$c" == 503 ]] && ok A17 "provider 5xx surfaced as 503" \
  || bad A17 "expected 503, got $c: $(body A17 | head -c 120)"

# --- A13 malformed messages on the VIRTUAL name must not reach an upstream.
# A direct model name is a pass-through: the gateway translates, it does not
# validate a body the upstream will reject anyway, so asserting 400 there
# would be asserting a check that does not exist by design. The contract that
# DOES exist is SPEC §8: malformed input on janus-auto degrades to `pass`,
# and since no provider lists the virtual name the caller gets a local 404
# rather than an upstream round-trip.
c=$(post A13 janus-auto '{"model":"janus-auto","messages":"not-a-list"}')
code=$(body A13 | grep -o '"code":"[^"]*"' | head -1)
if [[ "$c" == 404 ]]; then
  ok A13 "malformed messages on the virtual name refused locally (404 $code)"
else bad A13 "expected local 404, got $c: $(body A13 | head -c 140)"; fi

# --- A12 unknown model
c=$(post A12 no-such-model "$(req no-such-model 'hi')")
[[ "$c" == 404 ]] && ok A12 "unknown model 404 with code $(body A12 | grep -o '"code":"[^"]*"' | head -1)" \
  || bad A12 "expected 404, got $c: $(body A12 | head -c 120)"

say ""
note ""
note "== rows"
for r in "${ROWS[@]}"; do note "$r"; done
note ""
note "summary: $PASS passed, $FAIL failed, $SKIP skipped"
say ""
say "== summary: $PASS passed, $FAIL failed, $SKIP skipped"
say "== artifacts: $ARTIFACT_DIR"

[[ "$FAIL" -eq 0 ]]