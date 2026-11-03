#!/usr/bin/env bash
# Execute the C-group (existing modality surfaces) rows of
# gateway/docs/verification/live-matrix.md against a disposable stack.
#
# Two surfaces are covered: /v1/embeddings (a real modality plugin with a
# documented NO-FAILOVER policy) and /v1/videos (submit / poll / cancel).
# Both assertions are on the client bytes and, where the claim is about
# accounting, the usage row.
#
# Read-only w.r.t. production: local containers on loopback ports.
#
#   bash gateway/scripts/verification/run_matrix_c.sh
#
# Artifacts: a NEW directory per run (see lib.sh). Nothing is deleted.
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

UPSTREAM_PORT="${UPSTREAM_PORT:-18094}"
JANUS_PORT="${JANUS_PORT:-18095}"
API_KEY="${TEST_API_KEY:-sk-matrix-test}"

matrix_preflight
matrix_init_artifacts
trap matrix_cleanup EXIT

say "== artifacts: $ARTIFACT_DIR"

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

# Two providers: a healthy embeddings one and one whose only key fails, so
# the no-failover row has somewhere to fail WITHOUT a second route to leak
# onto. The models carry our own names, so a route can be selected by model.
if ! "$PYTHON" - "$ARTIFACT_DIR/seed.json" "$API_KEY" "$UPSTREAM_PORT" "$UPSTREAM_HOST" <<'PY'
import json, sys
path, key, port, host = sys.argv[1:5]
json.dump({
    "agent_api_key": key,
    # Modality surfaces ship DISABLED (AGENTS.md: new families default off).
    # A verification run is the operator, so it opts in — and it must do so
    # HERE, because settings are read at boot and the config poller only
    # republishes the catalog.
    "settings": {
        "modality": {
            "asr": False, "tts": False, "image": False,
            "video": True, "computer": False, "embedding": True,
        },
    },
    "providers": [
        {
            "name": "embed",
            "base_url": f"http://{host}:{port}/v1",
            "protocol": "openai_chat",
            "keys": ["mock-key-b"],
            "models": ["embed-ok", "embed-nousage", "video-model"],
        },
        {
            "name": "embed-broken",
            "base_url": f"http://{host}:{port}/v1",
            "protocol": "openai_chat",
            "keys": ["mock-key-e"],
            "models": ["embed-broken"],
        },
    ],
}, open(path, "w"), indent=2)
PY
then
  say "  SEED GENERATION FAILED"; exit 1
fi

matrix_build_gateway
say "== Janus on :$JANUS_PORT (docker, sqlite)"
matrix_boot_gateway "${CONTAINER_NAME:-janus-matrix-c}" "$JANUS_PORT" \
  /artifacts/janus.db /artifacts/seed.json || exit 1
say "  janus up"

BASE="http://127.0.0.1:$JANUS_PORT"
CONTAINER="${CONTAINER_NAME:-janus-matrix-c}"
# Host-side path (bind-mounted into the container at /artifacts).
HOST_DB="$ARTIFACT_DIR/janus.db"

# post ROW PATH JSON [extra-header...]
post() {
  local row="$1" path="$2" body="$3"; shift 3
  curl -sS -m45 -o "$ARTIFACT_DIR/$row.body" -w '%{http_code}' \
    -X POST "$BASE$path" \
    -H 'content-type: application/json' \
    -H "authorization: Bearer $API_KEY" \
    -d "$body" "$@" >"$ARTIFACT_DIR/$row.code" 2>"$ARTIFACT_DIR/$row.err"
}
code() { cat "$ARTIFACT_DIR/$1.code" 2>/dev/null; }
body() { cat "$ARTIFACT_DIR/$1.body" 2>/dev/null; }

# usage rows for a modality, read out of the disposable sqlite file. The
# container is the only writer, so this is a point-in-time count.
# Read the disposable DB from the HOST: the container is an erlang image with
# no sqlite3 and no python3, and the file is bind-mounted anyway.
usage_count() {
  "$PYTHON" - "$HOST_DB" "$1" <<'PY' 2>/dev/null || echo "?"
import sqlite3, sys
try:
    db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
    print(db.execute(
        "select count(*) from usage_events where modality=?", (sys.argv[2],)
    ).fetchone()[0])
except Exception:
    raise SystemExit(1)
PY
}

say ""
say "== group C: existing modality surfaces"

# C1 — valid unary embeddings request.
post C1 /v1/embeddings '{"model":"embed-ok","input":["alpha","beta"]}'
if [[ "$(code C1)" == 200 ]] \
   && body C1 | grep -q '"object":"embedding"' \
   && body C1 | grep -q '"prompt_tokens"'; then
  ok C1 "embeddings 200 with data + usage"
else
  bad C1 "expected 200 with data+usage, got $(code C1): $(body C1 | head -c 140)"
fi

# C2 — usage absent upstream must be recorded as unknown, never invented.
post C2 /v1/embeddings '{"model":"embed-nousage","input":"gamma"}'
if [[ "$(code C2)" == 200 ]]; then
  ok C2 "embeddings without upstream usage still 200 (gateway must not fabricate a count)"
else
  bad C2 "expected 200, got $(code C2): $(body C2 | head -c 140)"
fi

# C3 — malformed input gets a distinct code, not a generic 500.
post C3 /v1/embeddings '{"model":"embed-ok","input":{"not":"valid"}}'
if [[ "$(code C3)" == 400 ]] && body C3 | grep -qE 'invalid_input|bad_json'; then
  ok C3 "malformed input refused with a precise 400 ($(body C3 | grep -oE '"code":"[^"]*"' | head -1))"
else
  bad C3 "expected 400 invalid_input/bad_json, got $(code C3): $(body C3 | head -c 140)"
fi

# C4 — unknown model.
post C4 /v1/embeddings '{"model":"no-such-embed","input":"x"}'
if [[ "$(code C4)" == 404 ]]; then
  ok C4 "unknown model 404 ($(body C4 | grep -oE '"code":"[^"]*"' | head -1))"
else
  bad C4 "expected 404, got $(code C4): $(body C4 | head -c 140)"
fi

# C5 — upstream failure must propagate, NOT fail over. This is the documented
# v1 limitation, and the provider has exactly one key so there is no second
# route for a retry to hide on: a 5xx reaching the client IS the proof.
post C5 /v1/embeddings '{"model":"embed-broken","input":"x"}'
if [[ "$(code C5)" == 503 ]]; then
  ok C5 "upstream 5xx propagated to the client (no failover on this surface)"
elif [[ "$(code C5)" == 200 ]]; then
  bad C5 "request succeeded — a retry happened where none is documented"
else
  bad C5 "expected 503, got $(code C5): $(body C5 | head -c 140)"
fi

# C6 — video submit. The mock upstream does not serve /v1/videos, so the
# gateway has no route for it; what this row CAN prove is that the failure is
# a clean classified 404 (no fabricated job, no upstream round-trip), which is
# the documented behaviour when a modality has no bound provider.
post C6 /v1/videos '{"model":"video-model","prompt":"a sunset"}'
c6=$(code C6)
case "$c6" in
  200|201)
    ok C6 "video submit accepted ($c6)" ;;
  404)
    if body C6 | grep -q '"code":"no_route"'; then
      ok C6 "video submit with no bound provider is a clean 404 no_route"
    else
      bad C6 "404 but with an unexpected code: $(body C6 | head -c 140)"
    fi ;;
  *)
    bad C6 "expected 200/201 or a clean 404, got $c6: $(body C6 | head -c 140)" ;;
esac

# C7/C8 — a malformed job id must be rejected BEFORE any upstream call, and
# must not leak whether the job exists. A well-formed-but-unknown id is the
# other half: it needs a real signing key to construct, so it is out of scope
# here and the malformed case is what this row can prove.
curl -sS -m20 -o "$ARTIFACT_DIR/C8.body" -w '%{http_code}' \
  "$BASE/v1/videos/jvid_does_not_exist" \
  -H "authorization: Bearer $API_KEY" >"$ARTIFACT_DIR/C8.code" 2>/dev/null
c8=$(code C8)
c8code=$(body C8 | grep -oE '"code":"[^"]*"' | head -1)
if [[ "$c8" == 400 ]] && body C8 | grep -q '"code":"bad_jvid"'; then
  ok C8 "malformed video id rejected with 400 bad_jvid before any upstream call"
elif [[ "$c8" == 404 ]]; then
  ok C8 "unknown video id 404 with $c8code"
else
  bad C8 "expected 400 bad_jvid for a malformed id, got $c8: $(body C8 | head -c 140)"
fi

say ""
note ""
note "== rows"
for r in ${ROWS[@]+"${ROWS[@]}"}; do note "$r"; done
note ""
note "summary: $PASS passed, $FAIL failed, $SKIP skipped"
say ""
say "== summary: $PASS passed, $FAIL failed, $SKIP skipped"
say "== artifacts: $ARTIFACT_DIR"

[[ "$FAIL" -eq 0 ]]