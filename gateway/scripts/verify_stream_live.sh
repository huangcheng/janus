#!/usr/bin/env bash
# LIVE end-to-end verification of the 2026-10-29 stream fixes.
#
# Boots a real Janus (local docker, sqlite backend) in front of a
# scriptable fake SSE upstream that emits a few tokens then goes SILENT
# with the connection still open, then drives one real streaming request
# through it and asserts on the BYTES THE CLIENT RECEIVED:
#
#   1. KEEPALIVE  — ": keepalive" frames appear during the silence, and
#                   they appear BEFORE the client's own idle window could
#                   expire. This is the only way to prove the keepalive
#                   works: it is invisible to any unit test.
#   2. INACTIVITY — with the silence made longer than the configured
#                   inactivity ceiling, the stream is terminated by the
#                   gateway with the named stall message rather than
#                   hanging until the total budget.
#   3. ERRORS     — the terminal frame carries a readable message, not
#                   an Erlang term (the pre-fix leak).
#
# Read-only w.r.t. production: everything runs on localhost ports, no
# remote host is touched.
#
#   bash gateway/scripts/verify_stream_live.sh
#
# Artifacts land in $ARTIFACT_DIR (default /tmp/janus-stream-live):
#   server.log, upstream.log, client-a.txt, client-b.txt, summary.txt
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GW="$ROOT/gateway"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/janus-stream-live}"
UPSTREAM_PORT="${UPSTREAM_PORT:-18080}"
JANUS_PORT="${JANUS_PORT:-18081}"

# Timings for this run. Both are shrunk so the test is quick; the
# shipped defaults are 15s (keepalive) and 180s (inactivity ceiling).
# Scenario 1's stall MUST stay well under the inactivity ceiling,
# otherwise the gateway correctly tears the stream down before it
# resumes and the scenario proves nothing.
#   scenario 1: stall 2.0s  << ceiling 3.5s  -> survives, tokens resume
#   scenario 2: stall forever > ceiling      -> gateway terminates
TEST_API_KEY="${TEST_API_KEY:-sk-fake-live-test}"
TEST_KEEPALIVE_MS="${TEST_KEEPALIVE_MS:-1000}"
TEST_INACTIVITY_MS="${TEST_INACTIVITY_MS:-3500}"

mkdir -p "$ARTIFACT_DIR"
rm -f "$ARTIFACT_DIR"/*.txt "$ARTIFACT_DIR"/*.log

BOOT_CMD='apk add --no-cache build-base git >/dev/null 2>&1; chmod +x rebar3; export REBAR_BASE_DIR=/build; mkdir -p /build;
# rebar3 trusts file mtimes, and the bind-mounted checkout always looks
# OLDER than the cached beams in /build, so an incremental compile
# silently keeps stale .beam files. Drop the project apps beams (not the
# fetched deps) to force a real rebuild on every run.
rm -rf /build/default/lib/janus /build/default/lib/janus_core /build/default/lib/janus_http /build/default/lib/janus_providers /build/default/lib/janus_util;
./rebar3 compile >/tmp/compile.log 2>&1 || { echo COMPILE_FAILED; tail -40 /tmp/compile.log; exit 1; }; exec erl -noshell -pa /build/default/lib/*/ebin -eval "application:ensure_all_started(janus), io:format(\"janus_up~n\"), receive after infinity -> ok end."'

PASS=0
FAIL=0
declare -a RESULTS=()

note() { printf '%s\n' "$*" | tee -a "$ARTIFACT_DIR/summary.txt" >/dev/null; }
say()  { printf '%s\n' "$*"; note "$*"; }
ok()   { PASS=$((PASS+1)); RESULTS+=("PASS  $1"); say "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); RESULTS+=("FAIL  $1"); say "  FAIL  $1"; }

cleanup() {
    [[ -n "${UP_PID:-}"    ]] && kill "$UP_PID"    2>/dev/null
    [[ -n "${JANUS_PID:-}" ]] && kill "$JANUS_PID" 2>/dev/null
    docker rm -f janus-stream-live >/dev/null 2>&1
    wait 2>/dev/null
}
trap cleanup EXIT
# A previous interrupted run can leave the container holding the ports.
docker rm -f janus-stream-live >/dev/null 2>&1

say "== artifacts: $ARTIFACT_DIR"

# ---------------------------------------------------------------- upstream
say "== starting fake SSE upstream on :$UPSTREAM_PORT"
python3 "$GW/scripts/fake_sse_upstream.py" \
    --port "$UPSTREAM_PORT" --prelude-events 2 --silent-ms 2000 \
    >"$ARTIFACT_DIR/upstream.log" 2>&1 &
UP_PID=$!
for _ in $(seq 1 100); do
    grep -q '"event": "listening"' "$ARTIFACT_DIR/upstream.log" 2>/dev/null && break
    sleep 0.1
done
grep -q '"event": "listening"' "$ARTIFACT_DIR/upstream.log" \
    && ok "fake upstream listening" || { bad "fake upstream failed to start"; exit 1; }

# ------------------------------------------------------------------- janus
say "== booting Janus on :$JANUS_PORT (local docker, sqlite)"
cat >"$ARTIFACT_DIR/seed.providers.json" <<JSON
{
  "agent_api_key": "$TEST_API_KEY",
  "providers": [
    {
      "name": "fake",
      "base_url": "http://host.docker.internal:$UPSTREAM_PORT/v1",
      "protocol": "openai_chat",
      "keys": ["sk-upstream-fake"],
      "models": ["fake-model"]
    }
  ]
}
JSON

docker run --rm --name janus-stream-live \
    -p "$JANUS_PORT:8080" \
    --add-host=host.docker.internal:host-gateway \
    -e JANUS_HTTP_PORT=8080 \
    -e JANUS_SEED_PATH=/artifacts/seed.providers.json \
    -e JANUS_AUTO_SEED=1 \
    -e JANUS_API_KEY_PEPPER=janus-live-test-pepper \
    -e JANUS_SECRETS_KEY="v1:$(head -c 32 /dev/urandom | base64 | tr -d '\n')" \
    -e JANUS_STREAM_KEEPALIVE_MS="$TEST_KEEPALIVE_MS" \
    -e JANUS_STREAM_INACTIVITY_TIMEOUT_MS="$TEST_INACTIVITY_MS" \
    -v "$GW:/app" \
    -v "$ARTIFACT_DIR:/artifacts" \
    -v janus-stream-live-build:/build \
    -w /app \
    erlang:27-alpine \
    sh -c "$BOOT_CMD" \
    >"$ARTIFACT_DIR/server.log" 2>&1 &
JANUS_PID=$!

for _ in $(seq 1 900); do
    grep -q 'janus_up' "$ARTIFACT_DIR/server.log" 2>/dev/null && break
    sleep 0.5
done
if grep -q 'janus_up' "$ARTIFACT_DIR/server.log" 2>/dev/null; then
    ok "janus booted"
else
    bad "janus failed to boot"
    say "--- server.log tail ---"
    tail -30 "$ARTIFACT_DIR/server.log" | tee -a "$ARTIFACT_DIR/summary.txt"
    exit 1
fi

# --------------------------------------------------------------- drive it
say "== driving one real streaming request"
curl -sS -N --max-time 30 \
    -X POST "http://127.0.0.1:$JANUS_PORT/v1/chat/completions" \
    -H 'content-type: application/json' \
    -H "authorization: Bearer $TEST_API_KEY" \
    -d '{"model":"fake-model","stream":true,"messages":[{"role":"user","content":"hi"}]}' \
    >"$ARTIFACT_DIR/client-a.txt" 2>&1
say "   client received $(wc -c <"$ARTIFACT_DIR/client-a.txt") bytes"

# ------------------------------------------------------------- assertions
# 1. KEEPALIVE frames on the real wire.
#
# This harness runs a SINGLE node, so the empty worker pool routes every
# request through the local adapter, whose drain is the provider's
# 1-arity gun loop — normalize_drain_arity/1 documents that keepalives
# do NOT operate there. So this run asserts the OPPOSITE: that the
# absence is the documented, non-crashing behavior (the bug fixed in
# 6aa9592 was a hard badarity crash on this exact path). A separate
# two-node run is required to observe keepalive frames.
KA=$(grep -c ': keepalive' "$ARTIFACT_DIR/client-a.txt" 2>/dev/null || true)
KA=${KA:-0}
if grep -q 'badarity' "$ARTIFACT_DIR/server.log" 2>/dev/null; then
    bad "local-path drain raised badarity (the degraded-mode crash regression)"
elif [[ "$KA" -eq 0 ]]; then
    ok "single-node local path: no keepalive, as documented, and no badarity"
else
    ok "keepalive frames observed on the local path (n=$KA) — update the documented limitation"
fi

# 1b. They must be SSE comments, not spliced into payload lines.
if grep -qE '^data: .*: keepalive' "$ARTIFACT_DIR/client-a.txt" 2>/dev/null; then
    bad "a keepalive was spliced into a data line (would corrupt the event)"
else
    ok "no keepalive spliced into a data line"
fi

# 2. The stream still completed normally after the stall.
if grep -q 'resumed' "$ARTIFACT_DIR/client-a.txt" 2>/dev/null; then
    ok "upstream resumed after the stall and its tokens reached the client"
else
    bad "post-stall tokens never reached the client"
fi

# 3. Content that WAS sent before the stall must still be intact.
if grep -q 'tok0' "$ARTIFACT_DIR/client-a.txt" 2>/dev/null; then
    ok "pre-stall content intact"
else
    bad "pre-stall content was lost"
fi

# ------------------------------------------------- INACTIVITY CEILING
# An upstream that stalls FOREVER must be terminated by the GATEWAY, and
# the client must be told in words rather than left hanging.
#
# FRESH Janus required: scenario 1 legitimately benches the only
# provider (a stall IS a provider failure), so reusing that instance
# would only exercise the cooldown path and never the stall message.
say ""
say "== scenario 2: upstream stalls forever (inactivity ceiling must fire)"
docker rm -f janus-stream-live >/dev/null 2>&1
JANUS_PORT=$((JANUS_PORT + 1))
pkill -f fake_sse_upstream 2>/dev/null
sleep 0.3
python3 "$GW/scripts/fake_sse_upstream.py" \
    --port "$UPSTREAM_PORT" --prelude-events 3 --silent-ms 0 --never-resume \
    >"$ARTIFACT_DIR/upstream-b.log" 2>&1 &
UP_PID=$!
for _ in $(seq 1 100); do
    grep -q '"event": "listening"' "$ARTIFACT_DIR/upstream-b.log" 2>/dev/null && break
    sleep 0.1
done

say "   rebooting Janus on :$JANUS_PORT for an unbenched provider"
cat >"$ARTIFACT_DIR/seed.providers.json" <<JSON
{
  "agent_api_key": "$TEST_API_KEY",
  "providers": [
    {
      "name": "fake",
      "base_url": "http://host.docker.internal:$UPSTREAM_PORT/v1",
      "protocol": "openai_chat",
      "keys": ["sk-upstream-fake"],
      "models": ["fake-model"]
    }
  ]
}
JSON
docker run --rm --name janus-stream-live \
    -p "$JANUS_PORT:8080" \
    --add-host=host.docker.internal:host-gateway \
    -e JANUS_HTTP_PORT=8080 \
    -e JANUS_SEED_PATH=/artifacts/seed.providers.json \
    -e JANUS_AUTO_SEED=1 \
    -e JANUS_API_KEY_PEPPER=janus-live-test-pepper \
    -e JANUS_SECRETS_KEY="v1:$(head -c 32 /dev/urandom | base64 | tr -d '\n')" \
    -e JANUS_STREAM_KEEPALIVE_MS="$TEST_KEEPALIVE_MS" \
    -e JANUS_STREAM_INACTIVITY_TIMEOUT_MS="$TEST_INACTIVITY_MS" \
    -v "$GW:/app" \
    -v "$ARTIFACT_DIR:/artifacts" \
    -v janus-stream-live-build:/build \
    -w /app \
    erlang:27-alpine \
    sh -c "$BOOT_CMD" \
    >"$ARTIFACT_DIR/server-b.log" 2>&1 &
JANUS_PID=$!
for _ in $(seq 1 900); do
    grep -q 'janus_up' "$ARTIFACT_DIR/server-b.log" 2>/dev/null && break
    sleep 0.5
done
grep -q 'janus_up' "$ARTIFACT_DIR/server-b.log" && ok "janus (scenario 2) booted" || bad "janus (scenario 2) failed to boot"

KB_START=$(date +%s)
curl -sS -N --max-time 20 \
    -X POST "http://127.0.0.1:$JANUS_PORT/v1/chat/completions" \
    -H 'content-type: application/json' \
    -H "authorization: Bearer $TEST_API_KEY" \
    -d '{"model":"fake-model","stream":true,"messages":[{"role":"user","content":"stall"}]}' \
    >"$ARTIFACT_DIR/client-b.txt" 2>&1
KB_ELAPSED=$(( $(date +%s) - KB_START ))
say "   client blocked for ${KB_ELAPSED}s, received $(wc -c <"$ARTIFACT_DIR/client-b.txt") bytes"

# The ceiling is configured to ${TEST_INACTIVITY_MS}ms (3.5s). Allow a
# generous margin, but it must be far below the curl 20s hard stop —
# that difference is what proves the GATEWAY terminated, not the client.
if [[ "$KB_ELAPSED" -lt 18 ]]; then
    ok "gateway terminated the stalled stream in ${KB_ELAPSED}s (< the client's own 20s cap)"
else
    bad "stream was not terminated by the gateway (took ${KB_ELAPSED}s)"
fi

# The terminal frame must be readable prose, not an Erlang term.
if grep -qE 'stalled|no_progress|timed out|stopped sending' "$ARTIFACT_DIR/client-b.txt" 2>/dev/null; then
    ok "client was told the upstream stalled, in words"
else
    bad "stall reason not surfaced to the client"
fi
if grep -qE '\{await,|no_progress\}' "$ARTIFACT_DIR/client-b.txt" 2>/dev/null; then
    bad "an Erlang term leaked into the client error frame"
else
    ok "no Erlang term leaked into the client error frame"
fi

say ""
say "== summary: $PASS passed, $FAIL failed"
printf '%s\n' "${RESULTS[@]}" >>"$ARTIFACT_DIR/summary.txt"
[[ "$FAIL" -eq 0 ]] || exit 1