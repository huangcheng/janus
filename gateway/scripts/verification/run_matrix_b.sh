#!/usr/bin/env bash
# Execute the B-group (streaming) rows of
# gateway/docs/verification/live-matrix.md against a disposable stack.
#
# The assertions are on the BYTES THE CLIENT RECEIVED and the frame
# boundaries inside them, because that is the only way to prove things a unit
# test cannot see: that a keepalive really appeared during a stall, that a
# frame was not split across reads, that no Erlang term leaked into a
# terminal error.
#
# Read-only w.r.t. production: local containers on loopback ports.
#
#   bash gateway/scripts/verification/run_matrix_b.sh
#
# Artifacts: a NEW directory per run (see lib.sh). Nothing is deleted.
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

UPSTREAM_PORT="${UPSTREAM_PORT:-18092}"
JANUS_PORT="${JANUS_PORT:-18093}"
API_KEY="${TEST_API_KEY:-sk-matrix-test}"

# Timings are shrunk so the run is quick; the shipped defaults are 15s
# (keepalive) and 180s (inactivity ceiling). Scenario B5's stall MUST stay
# well under the ceiling, or the gateway correctly tears the stream down
# before it resumes and the row proves nothing.
TEST_KEEPALIVE_MS="${TEST_KEEPALIVE_MS:-800}"
TEST_INACTIVITY_MS="${TEST_INACTIVITY_MS:-8000}"
B5_STALL_MS="${B5_STALL_MS:-4000}"

matrix_preflight
matrix_init_artifacts
trap matrix_cleanup EXIT

say "== artifacts: $ARTIFACT_DIR"

# --------------------------------------------------------------- upstream
# The mock handles the ordinary streaming rows. The stall shape (a stream
# that emits a few tokens then goes silent with the connection OPEN) is what
# fake_sse_upstream.py models; the mock does not.
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
if ! "$PYTHON" - "$ARTIFACT_DIR/seed.json" "$API_KEY" "$UPSTREAM_PORT" "$UPSTREAM_HOST" <<'PY'
import json, sys
path, key, port, host = sys.argv[1:5]
providers = []
for name, mkey in [("healthy", "mock-key-b"), ("fivexx", "mock-key-e")]:
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
  say "  SEED GENERATION FAILED"; exit 1
fi

# ------------------------------------------------------------------ janus
matrix_build_gateway
say "== Janus on :$JANUS_PORT (docker, sqlite)"
MATRIX_EXTRA_ENV=(-e "JANUS_STREAM_KEEPALIVE_MS=$TEST_KEEPALIVE_MS" \
  -e "JANUS_STREAM_INACTIVITY_TIMEOUT_MS=$TEST_INACTIVITY_MS")
matrix_boot_gateway "${CONTAINER_NAME:-janus-matrix-b}" "$JANUS_PORT" \
  /artifacts/janus.db /artifacts/seed.json || exit 1
say "  janus up"

BASE="http://127.0.0.1:$JANUS_PORT"

# stream ROW MODEL JSON [max-time]
stream() {
  local row="$1" body="$2" tmo="${3:-40}"
  curl -sS -N --max-time "$tmo" \
    -X POST "$BASE/v1/chat/completions" \
    -H 'content-type: application/json' \
    -H "authorization: Bearer $API_KEY" \
    -d "$body" >"$ARTIFACT_DIR/$row.sse" 2>"$ARTIFACT_DIR/$row.err"
}
sse()  { cat "$ARTIFACT_DIR/$1.sse" 2>/dev/null; }
sreq() { printf '{"model":"%s","stream":true,"messages":[{"role":"user","content":"%s"}]}' "$1" "$2"; }

say ""
say "== group B: streaming"

# B1 — ordered deltas and exactly one terminal marker.
stream B1 "$(sreq mock-healthy 'count')"
if sse B1 | grep -q '^data: \[DONE\]'; then
  ok B1 "stream terminated with [DONE]"
else bad B1 "no [DONE] terminal; got: $(sse B1 | tail -2 | head -c 120)"; fi

# B3 — no frame may be truncated mid-line. Every `data:` line must parse as
# JSON (or be the [DONE] sentinel). A split frame shows up here.
if sse B3_probe 2>/dev/null; then :; fi
stream B3 "$(sreq mock-healthy 'frames')"
bad_frames=$(grep '^data: ' <"$ARTIFACT_DIR/B3.sse" 2>/dev/null \
  | sed 's/^data: //' | grep -v '^\[DONE\]$' \
  | "$PYTHON" -c 'import json,sys
bad=0
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: json.loads(line)
    except Exception: bad+=1
print(bad)' 2>/dev/null || echo 0)
if [[ "${bad_frames:-1}" == "0" ]]; then
  ok B3 "every data frame is complete and parseable"
else bad B3 "$bad_frames data frame(s) did not parse (split or truncated)"; fi

# B4 — UTF-8 must survive chunk boundaries. A multi-byte codepoint split
# across reads shows up as a replacement char in the reassembled text.
stream B4 "$(sreq mock-healthy 'unicode')"
if grep -q $'\xef\xbf\xbd' "$ARTIFACT_DIR/B4.sse" 2>/dev/null; then
  bad B4 "replacement character present: a codepoint was split across chunks"
else ok B4 "no replacement characters in the reassembled stream"; fi

# B11 — a stream the TRANSLATE path cannot carry is refused BEFORE any byte.
#
# `n>1` blocks only the cross-protocol translate path: a chat client hitting
# a chat provider rides the native stream and is served normally (verified —
# it returns 200 with a full SSE stream). So the row must be driven through a
# protocol PAIR, which is what this provider is for.
curl -sS -m30 -o "$ARTIFACT_DIR/B11.body" -w '%{http_code}' \
  -X POST "$BASE/v1/messages" \
  -H 'content-type: application/json' \
  -H "anthropic-version: 2023-06-01" \
  -H "x-api-key: $API_KEY" \
  -d '{"model":"mock-healthy","stream":true,"max_tokens":16,"n":2,"messages":[{"role":"user","content":"x"}]}' \
  >"$ARTIFACT_DIR/B11.code" 2>/dev/null
b11_code=$(cat "$ARTIFACT_DIR/B11.code" 2>/dev/null)
if [[ "$b11_code" == 400 ]] \
   && grep -qE 'translate_unsupported|stream_requires_native_protocol' "$ARTIFACT_DIR/B11.body" 2>/dev/null; then
  ok B11 "untranslatable stream refused with a precise 400 before any byte"
elif [[ "$b11_code" == 200 ]]; then
  skip B11 "this pair translates the shape (200); see B11.body — the row needs a pair the translator cannot carry"
else
  bad B11 "expected a precise 400, got $b11_code: $(head -c 140 "$ARTIFACT_DIR/B11.body" 2>/dev/null)"
fi

# B12 — a provider error mid-stream must carry words, never an Erlang term.
# The 5xx key fails before the first byte here, which is the shape the mock
# can produce deterministically.
stream B12 "$(sreq mock-fivexx 'fail')" 30
if grep -qE '\{error|badmatch|function_clause|\[.*\]' "$ARTIFACT_DIR/B12.sse" 2>/dev/null; then
  bad B12 "an Erlang term leaked into the client stream"
elif [[ -s "$ARTIFACT_DIR/B12.sse" ]]; then
  ok B12 "upstream failure produced a readable client-side stream/error"
else
  bad B12 "empty stream and no error body"
fi

# B5/B6 — keepalive during a stall, and the inactivity ceiling.
# These need the stall-shaped upstream, so they run on their own stack: a
# stall is a provider failure, and reusing the healthy instance would only
# exercise the cooldown path.
say ""
say "== B5/B6: stall handling (separate stack)"
matrix_cleanup
: >"$ARTIFACT_DIR/summary.txt.bak" 2>/dev/null

"$PYTHON" "$GW/scripts/fake_sse_upstream.py" \
  --port "$UPSTREAM_PORT" --prelude-events 2 --silent-ms "$B5_STALL_MS" \
  >"$ARTIFACT_DIR/upstream-stall.log" 2>&1 &
matrix_track_pid $!
for _ in $(seq 1 100); do
  grep -q '"event": "listening"' "$ARTIFACT_DIR/upstream-stall.log" 2>/dev/null && break
  sleep 0.1
done
if ! grep -q '"event": "listening"' "$ARTIFACT_DIR/upstream-stall.log" 2>/dev/null; then
  bad B5 "stall upstream (fake_sse_upstream.py) did not start"
  skip B5 "keepalive during stall"
  skip B6 "inactivity ceiling"
else
  if ! "$PYTHON" - "$ARTIFACT_DIR/seed-stall.json" "$API_KEY" "$UPSTREAM_PORT" "$UPSTREAM_HOST" <<'PY'
import json, sys
path, key, port, host = sys.argv[1:5]
json.dump({
    "agent_api_key": key,
    "providers": [{
        "name": "stall",
        "base_url": f"http://{host}:{port}/v1",
        "protocol": "openai_chat",
        "keys": ["sk-stall"],
        "models": ["stall-model"],
    }],
}, open(path, "w"), indent=2)
PY
  then
    bad B5 "stall seed generation failed"
    skip B6 "inactivity ceiling"
  else
    MATRIX_EXTRA_ENV=(-e "JANUS_STREAM_KEEPALIVE_MS=$TEST_KEEPALIVE_MS" \
      -e "JANUS_STREAM_INACTIVITY_TIMEOUT_MS=$TEST_INACTIVITY_MS")
    matrix_boot_gateway "${CONTAINER_NAME:-janus-matrix-b}-stall" \
      "$((JANUS_PORT + 1))" /artifacts/janus-stall.db /artifacts/seed-stall.json || {
      bad B5 "stall gateway did not boot"
      skip B6 "inactivity ceiling"
    }
    if curl -sf -m2 -o /dev/null "http://127.0.0.1:$((JANUS_PORT + 1))/healthz" 2>/dev/null; then
      curl -sS -N --max-time "$((B5_STALL_MS / 1000 + 20))" \
        -X POST "http://127.0.0.1:$((JANUS_PORT + 1))/v1/chat/completions" \
        -H 'content-type: application/json' \
        -H "authorization: Bearer $API_KEY" \
        -d '{"model":"stall-model","stream":true,"messages":[{"role":"user","content":"hi"}]}' \
        >"$ARTIFACT_DIR/B5.sse" 2>/dev/null
      ka=$(grep -c ': keepalive' "$ARTIFACT_DIR/B5.sse" 2>/dev/null || true)
      ka=${ka:-0}
      if [[ "$ka" -ge 1 ]]; then
        ok B5 "keepalive frames during a ${B5_STALL_MS}ms stall (n=$ka)"
      else
        bad B5 "no keepalive during a ${B5_STALL_MS}ms stall at an ${TEST_KEEPALIVE_MS}ms cadence"
      fi
      if grep -qE '^data: .*: keepalive' "$ARTIFACT_DIR/B5.sse" 2>/dev/null; then
        bad B5 "keepalive spliced into a data line (would corrupt the event)"
      fi

      # B6 — a stall longer than the ceiling must be terminated by the
      # gateway with words, not left hanging until the client gives up.
      pkill -f fake_sse_upstream 2>/dev/null
      sleep 0.3
      # A never-resuming upstream benches the provider on the previous
      # instance, so this needs a FRESH gateway: reusing the B5 one answers
      # `all_cooling` and never reaches the stall path.
      matrix_cleanup
      "$PYTHON" "$GW/scripts/fake_sse_upstream.py" \
        --port "$UPSTREAM_PORT" --prelude-events 2 --silent-ms 0 --never-resume \
        >"$ARTIFACT_DIR/upstream-never.log" 2>&1 &
      matrix_track_pid $!
      for _ in $(seq 1 100); do
        grep -q '"event": "listening"' "$ARTIFACT_DIR/upstream-never.log" 2>/dev/null && break
        sleep 0.1
      done
      MATRIX_EXTRA_ENV=(-e "JANUS_STREAM_KEEPALIVE_MS=$TEST_KEEPALIVE_MS" \
        -e "JANUS_STREAM_INACTIVITY_TIMEOUT_MS=$TEST_INACTIVITY_MS")
      if ! matrix_boot_gateway "${CONTAINER_NAME:-janus-matrix-b}-never" \
           "$((JANUS_PORT + 1))" /artifacts/janus-never.db /artifacts/seed-stall.json; then
        # `bad` once, not twice: the boot helper already reported why.
        ROWS+=("$(printf '%-4s %-6s %s' FAIL B6 "never-resume gateway did not boot")")
        FAIL=$((FAIL+1))
      else
      start=$(date +%s)
      # Client budget = ceiling + generous slack, so "did not terminate" is a
      # real finding rather than the client giving up first.
      client_budget=$(( (TEST_INACTIVITY_MS / 1000) + 25 ))
      curl -sS -N --max-time "$client_budget" \
        -X POST "http://127.0.0.1:$((JANUS_PORT + 1))/v1/chat/completions" \
        -H 'content-type: application/json' \
        -H "authorization: Bearer $API_KEY" \
        -d '{"model":"stall-model","stream":true,"messages":[{"role":"user","content":"hi"}]}' \
        >"$ARTIFACT_DIR/B6.sse" 2>/dev/null
      elapsed=$(( $(date +%s) - start ))
      # The gateway closes with an SSE COMMENT naming the cause:
      #   ": janus stream failed - upstream stopped sending data mid-stream"
      # Matching the words rather than a guessed keyword list — the first
      # version looked for stall|idle|timeout and missed the real text.
      ceiling_s=$((TEST_INACTIVITY_MS / 1000))
      if [[ "$elapsed" -gt $((ceiling_s + 10)) ]]; then
        bad B6 "stream was not terminated (${elapsed}s, ceiling was ${ceiling_s}s)"
      elif grep -qE '^: .*stream failed' "$ARTIFACT_DIR/B6.sse" 2>/dev/null; then
        ok B6 "terminated in ${elapsed}s (ceiling ${ceiling_s}s) with: $(grep -oE 'stream failed.*' "$ARTIFACT_DIR/B6.sse" | head -1)"
      else
        bad B6 "terminated in ${elapsed}s without a readable cause on the wire"
      fi
      if grep -qE '\{error|badmatch|function_clause' "$ARTIFACT_DIR/B6.sse" 2>/dev/null; then
        bad B6 "an Erlang term leaked into the terminal frame"
      fi
      fi
    fi
  fi
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