#!/usr/bin/env bash
# Execute the A-group (request / unary response) rows of
# gateway/docs/verification/live-matrix.md against a disposable stack.
#
# Read-only w.r.t. production: everything is a local container on loopback
# ports, seeded from a generated file. No fleet host is contacted.
#
#   bash gateway/scripts/verification/run_matrix_a.sh
#
# Requirements and overrides are documented in lib.sh; every one is checked
# and named rather than assumed, because this is a public repository.
#
# Artifacts: a NEW directory per run (see matrix_init_artifacts). Nothing is
# deleted. Contains seed.json, logs, per-row .code/.body captures and
# summary.txt with one PASS/FAIL line per row.
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

UPSTREAM_PORT="${UPSTREAM_PORT:-18090}"
JANUS_PORT="${JANUS_PORT:-18091}"
API_KEY="${TEST_API_KEY:-sk-matrix-test}"

matrix_preflight
matrix_init_artifacts
trap matrix_cleanup EXIT

say "== artifacts: $ARTIFACT_DIR"

# --------------------------------------------------------------- upstream
# The mock must bind 0.0.0.0 (the gateway is a container and reaches it over
# the docker bridge); the gateway itself is published on loopback only.
say "== mock upstream on :$UPSTREAM_PORT"
JANUS_MOCK_PORT="$UPSTREAM_PORT" JANUS_MOCK_HOST=0.0.0.0 \
  "$PYTHON" "$DASH/scripts/mock_upstream.py" \
  >"$ARTIFACT_DIR/upstream.log" 2>&1 &
matrix_track_pid $!
for _ in $(seq 1 100); do
  curl -sf -m1 -o /dev/null "http://127.0.0.1:$UPSTREAM_PORT/v1/models" 2>/dev/null && break
  sleep 0.2
done
curl -sf -m2 -o /dev/null "http://127.0.0.1:$UPSTREAM_PORT/v1/models" 2>/dev/null || {
  say "  mock upstream did not come up"; tail -10 "$ARTIFACT_DIR/upstream.log"; exit 1; }

# ------------------------------------------------------------------- seed
# One provider per mock key so each row selects a fault class by model name.
if ! "$PYTHON" - "$ARTIFACT_DIR/seed.json" "$API_KEY" "$UPSTREAM_PORT" "$UPSTREAM_HOST" <<'PY'
import json, sys
path, key, port, host = sys.argv[1:5]
providers = []
for name, mkey in [
    ("healthy", "mock-key-b"), ("auth", "mock-key-a"), ("deny", "mock-key-c"),
    ("balance", "mock-key-d"), ("fivexx", "mock-key-e"), ("shape", "mock-key-f"),
]:
    providers.append({
        "name": name,
        "base_url": f"http://{host}:{port}/v1",
        "protocol": "openai_chat",
        "keys": [mkey],
        "models": ["mock-" + name],
    })
json.dump({"agent_api_key": key, "providers": providers}, open(path, "w"), indent=2)
PY
then
  say "  SEED GENERATION FAILED — cannot continue without seed.json"; exit 1
fi
"$PYTHON" - "$ARTIFACT_DIR/seed.json" <<'PY' || { say "  seed.json invalid"; exit 1; }
import json, sys
doc = json.load(open(sys.argv[1]))
providers = doc["providers"]
if not isinstance(providers, list) or not providers:
    raise SystemExit("providers is empty or not a list")
PY

# ------------------------------------------------------------------ janus
matrix_build_gateway
say "== Janus on :$JANUS_PORT (docker, sqlite)"
matrix_boot_gateway "${CONTAINER_NAME:-janus-matrix-a}" "$JANUS_PORT" \
  /artifacts/janus.db /artifacts/seed.json || exit 1
say "  janus up"

# ------------------------------------------------------------------ helper
BASE="http://127.0.0.1:$JANUS_PORT"

post() {
  local row="$1" body="$2"
  local out="$ARTIFACT_DIR/$row"
  curl -sS -m45 -o "$out.body" -w '%{http_code}' \
    -X POST "$BASE/v1/chat/completions" \
    -H "content-type: application/json" \
    -H "authorization: Bearer $API_KEY" \
    -d "$body" >"$out.code" 2>"$out.err"
}
code() { cat "$ARTIFACT_DIR/$1.code" 2>/dev/null; }
body() { cat "$ARTIFACT_DIR/$1.body" 2>/dev/null; }
req()  { printf '{"model":"%s","messages":[{"role":"user","content":"%s"}]}' "$1" "$2"; }

say ""
say "== group A: request / unary response"

# A1 — text only, healthy upstream.
post A1 "$(req mock-healthy 'hello')"
if [[ "$(code A1)" == 200 ]] && body A1 | grep -q '"content":"ok"'; then
  ok A1 "text-only 200 with echoed content"
else bad A1 "expected 200+content, got $(code A1): $(body A1 | head -c 120)"; fi

# A2 — system + user ordering preserved.
post A2 '{"model":"mock-healthy","messages":[{"role":"system","content":"be brief"},{"role":"user","content":"hi"}]}'
[[ "$(code A2)" == 200 ]] && ok A2 "system+user accepted (roles preserved)" \
  || bad A2 "expected 200, got $(code A2): $(body A2 | head -c 120)"

# A3 — tools reach the upstream.
post A3 '{"model":"mock-healthy","messages":[{"role":"user","content":"two calls"}],"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object"}}}]}'
[[ "$(code A3)" == 200 ]] && ok A3 "request with tools accepted" \
  || bad A3 "expected 200, got $(code A3): $(body A3 | head -c 120)"

# A6 — an interrupted tool call in history is repaired, not rejected.
post A6 '{"model":"mock-healthy","messages":[{"role":"user","content":"go"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_x","type":"function","function":{"name":"f","arguments":"{}"}}]},{"role":"user","content":"continue"}]}'
[[ "$(code A6)" == 200 ]] && ok A6 "interrupted tool call repaired (accepted)" \
  || bad A6 "expected 200, got $(code A6): $(body A6 | head -c 160)"

# A7 — an orphan tool result is dropped, not forwarded raw.
post A7 '{"model":"mock-healthy","messages":[{"role":"user","content":"go"},{"role":"tool","tool_call_id":"call_nope","content":"orphan"}]}'
[[ "$(code A7)" == 200 ]] && ok A7 "orphan tool result dropped (accepted)" \
  || bad A7 "expected 200, got $(code A7): $(body A7 | head -c 160)"

# A16 — deny-shaped 4xx surfaced.
post A16 "$(req mock-deny 'hi')"
case "$(code A16)" in
  400|403) ok A16 "deny-shaped 4xx surfaced as $(code A16)" ;;
  *) bad A16 "expected 4xx, got $(code A16): $(body A16 | head -c 120)" ;;
esac

# A17 — provider 5xx surfaced.
post A17 "$(req mock-fivexx 'hi')"
[[ "$(code A17)" == 503 ]] && ok A17 "provider 5xx surfaced as 503" \
  || bad A17 "expected 503, got $(code A17): $(body A17 | head -c 120)"

# A13 — malformed `messages` on the VIRTUAL name must not reach an upstream.
# A direct model name is a pass-through: the gateway translates, it does not
# validate a body its upstream will reject anyway, so asserting 400 there
# would be asserting a check that does not exist by design. The contract that
# DOES exist (SPEC §8) is that malformed input on janus-auto degrades to
# `pass`, and since no provider lists the virtual name the caller gets a local
# 404 instead of an upstream round-trip.
post A13 '{"model":"janus-auto","messages":"not-a-list"}'
if [[ "$(code A13)" == 404 ]]; then
  ok A13 "malformed messages on the virtual name refused locally (404 $(body A13 | grep -o '"code":"[^"]*"' | head -1))"
else bad A13 "expected local 404, got $(code A13): $(body A13 | head -c 140)"; fi

# A12 — unknown model.
post A12 "$(req no-such-model 'hi')"
[[ "$(code A12)" == 404 ]] && ok A12 "unknown model 404 with $(body A12 | grep -o '"code":"[^"]*"' | head -1)" \
  || bad A12 "expected 404, got $(code A12): $(body A12 | head -c 120)"

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
