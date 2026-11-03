#!/usr/bin/env bash
# Shared scaffolding for the live-matrix runners.
#
# Sourced, not executed: `source "$(dirname "$0")/lib.sh"`.
#
# Everything here is host-neutral on purpose — this is a public repository,
# so no runner may encode one machine's layout. Each requirement is checked
# and named rather than assumed, and every path/name is overridable.
#
# Provided after sourcing:
#   $ROOT $GW $DASH        repo paths
#   $PYTHON                interpreter that can import fastapi+uvicorn
#   $ERLANG_IMAGE          image used to build and run the gateway
#   $BUILD_VOLUME          docker volume for rebar output
#   $ARTIFACT_DIR          a NEW per-run directory (nothing is ever deleted)
#   say ok bad skip        reporting helpers (counters PASS/FAIL/SKIP, ROWS)
#   matrix_preflight       verify docker/curl/python/fastapi before use
#   matrix_init_artifacts  resolve ARTIFACT_DIR (mktemp or timestamped subdir)
#   matrix_cleanup         remove only containers this run created

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GW="$ROOT/gateway"
DASH="$ROOT/dashboard"

PYTHON="${PYTHON:-python3}"
ERLANG_IMAGE="${ERLANG_IMAGE:-erlang:27-alpine}"
BUILD_VOLUME="${BUILD_VOLUME:-janus-matrix-build}"
UPSTREAM_HOST="${UPSTREAM_HOST:-host.docker.internal}"

# Extra -e args for matrix_boot_gateway. An array, so a value containing
# spaces cannot be word-split into a mangled docker command line.
MATRIX_EXTRA_ENV=()

PASS=0; FAIL=0; SKIP=0
ROWS=()
CREATED_CONTAINERS=()
UP_PIDS=()

say()  { printf '%s\n' "$*"; }
note() { printf '%s\n' "$*" >>"$ARTIFACT_DIR/summary.txt"; }
ok()   { PASS=$((PASS+1)); ROWS+=("$(printf '%-4s %-6s %s' PASS "$1" "$2")"); say "  PASS  $1  $2"; }
bad()  { FAIL=$((FAIL+1)); ROWS+=("$(printf '%-4s %-6s %s' FAIL "$1" "$2")"); say "  FAIL  $1  $2"; }
skip() { SKIP=$((SKIP+1)); ROWS+=("$(printf '%-4s %-6s %s' SKIP "$1" "$2")"); say "  SKIP  $1  $2"; }

# Fail with a specific message rather than somewhere downstream.
matrix_preflight() {
  local missing=""
  command -v docker >/dev/null 2>&1 || missing="$missing docker"
  command -v curl   >/dev/null 2>&1 || missing="$missing curl"
  command -v "$PYTHON" >/dev/null 2>&1 || missing="$missing $PYTHON"
  if [[ -n "$missing" ]]; then
    echo "missing required command(s):$missing" >&2
    echo "see the Requirements block at the top of this script" >&2
    exit 2
  fi
  docker info >/dev/null 2>&1 || {
    echo "docker is installed but the daemon is not reachable" >&2; exit 2; }
  "$PYTHON" -c 'import fastapi, uvicorn' >/dev/null 2>&1 || {
    echo "$PYTHON cannot import fastapi+uvicorn, which the mock upstream needs." >&2
    echo "install them, or point PYTHON at an interpreter that has them:" >&2
    echo "  pip install 'fastapi>=0.115' 'uvicorn[standard]>=0.32'" >&2
    exit 2; }
  docker image inspect "$ERLANG_IMAGE" >/dev/null 2>&1 ||
    echo "note: $ERLANG_IMAGE is not present locally; docker will pull it"
}

# A NEW directory per run. Nothing is ever deleted, so nothing needs a guard:
# the earlier design (reuse a caller-supplied dir, clear it first) produced
# four separate bypasses and is gone.
matrix_init_artifacts() {
  if [[ -n "${ARTIFACT_DIR:-}" ]]; then
    while [[ "$ARTIFACT_DIR" == */ && "$ARTIFACT_DIR" != "/" ]]; do
      ARTIFACT_DIR="${ARTIFACT_DIR%/}"
    done
    mkdir -p "$ARTIFACT_DIR" 2>/dev/null || {
      echo "cannot create ARTIFACT_DIR=$ARTIFACT_DIR" >&2; exit 2; }
    local base run_dir old_umask
    base="$(cd "$ARTIFACT_DIR" && pwd -P)" || {
      echo "cannot resolve ARTIFACT_DIR=$ARTIFACT_DIR" >&2; exit 2; }
    [[ -n "$base" ]] || { echo "ARTIFACT_DIR resolved to empty" >&2; exit 2; }
    run_dir="$base/run-$(date +%Y%m%d-%H%M%S)-$$"
    old_umask="$(umask)"
    umask 077
    if ! mkdir "$run_dir" 2>/dev/null; then
      umask "$old_umask"
      echo "refusing to reuse an existing run dir: $run_dir" >&2; exit 2
    fi
    umask "$old_umask"
    ARTIFACT_DIR="$run_dir"
  else
    ARTIFACT_DIR="$(mktemp -d -t janus-matrix-XXXXXX)" || {
      echo "cannot create a temp artifact dir" >&2; exit 2; }
  fi
  : >"$ARTIFACT_DIR/summary.txt"
}

# `--add-host X:host-gateway` is Docker 20.10+; some runtimes reject it.
# It is opt-in so the runners work where the flag is unavailable.
matrix_add_host_args() {
  if [[ "${NO_HOST_GATEWAY:-0}" == "1" ]]; then
    ADD_HOST_ARGS=()
  else
    ADD_HOST_ARGS=("--add-host=$UPSTREAM_HOST:host-gateway")
  fi
}

# Refuse a name already in use rather than destroying whatever holds it:
# CONTAINER_NAME is caller-supplied.
matrix_claim_name() {
  local name="$1"
  if docker container inspect "$name" >/dev/null 2>&1; then
    echo "a container named $name already exists; set CONTAINER_NAME to something else" >&2
    exit 2
  fi
}

# Track the container the moment it exists, so a failure mid-run cannot leave
# a name collision behind for the next run.
matrix_track_container() {
  CREATED_CONTAINERS+=("$1")
}

matrix_track_pid() {
  UP_PIDS+=("$1")
}

matrix_cleanup() {
  local p c
  for p in "${UP_PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
  for c in "${CREATED_CONTAINERS[@]:-}"; do
    [[ -n "$c" ]] && docker rm -f "$c" >/dev/null 2>&1
  done
  wait 2>/dev/null
}

# Build the gateway once into a shared volume. Boot runs the beams afterwards;
# keeping them separate means a broken build cannot print a ready line from a
# previous run's leftovers.
matrix_build_gateway() {
  local build_cmd
  # `&&` chain, not `;`: if apk cannot install the toolchain the compile must
  # not proceed to fail later with "cc: not found", which reads as a source
  # problem. build-base compiles the esqlite NIF; git fetches hex deps.
  build_cmd='apk add --no-cache build-base git || exit 3; chmod +x rebar3 &&
    export REBAR_BASE_DIR=/build && mkdir -p /build && ./rebar3 compile'
  say "== compiling into the shared build volume"
  if ! docker run --rm -v "$GW:/app" -v "$BUILD_VOLUME":/build -w /app \
       "$ERLANG_IMAGE" sh -c "$build_cmd" >"$ARTIFACT_DIR/compile.log" 2>&1; then
    say "  BUILD FAILED (see $ARTIFACT_DIR/compile.log)"
    tail -20 "$ARTIFACT_DIR/compile.log"
    exit 1
  fi
  say "  build ok"
}

# Boot a gateway container and wait for /healthz.
#   $1 name  $2 host-port  $3 sqlite-url-path  $4 seed-file
matrix_boot_gateway() {
  local name="$1" port="$2" dbpath="$3" seed="$4" rc
  matrix_claim_name "$name"
  matrix_add_host_args
  matrix_track_container "$name"
  docker run -d --name "$name" \
    -p "127.0.0.1:$port:8080" \
    "${ADD_HOST_ARGS[@]}" \
    -e JANUS_HTTP_PORT=8080 \
    -e JANUS_SQLITE_PATH="$dbpath" \
    -e JANUS_SEED_PATH="$seed" \
    -e JANUS_AUTO_SEED=1 \
    -e JANUS_API_KEY_PEPPER="${MATRIX_PEPPER:-janus-matrix-pepper}" \
    -e JANUS_SECRETS_KEY="v1:$(head -c 32 /dev/urandom | base64 | tr -d '\n')" \
    "${MATRIX_EXTRA_ENV[@]}" \
    -v "$GW:/app" -v "$ARTIFACT_DIR:/artifacts" -v "$BUILD_VOLUME":/build \
    -w /app "$ERLANG_IMAGE" sh -c \
    'export REBAR_BASE_DIR=/build; exec erl -noshell -pa /build/default/lib/*/ebin \
     -eval "application:ensure_all_started(janus), io:format(\"janus_up~n\"), receive after infinity -> ok end."' \
    >"$ARTIFACT_DIR/$name.run.log" 2>&1
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    say "  docker run failed (rc=$rc, see $ARTIFACT_DIR/$name.run.log)"
    tail -10 "$ARTIFACT_DIR/$name.run.log"
    return 1
  fi
  local _
  for _ in $(seq 1 240); do
    curl -sf -m1 -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null && return 0
    sleep 1
  done
  say "  $name did not become healthy"
  docker logs "$name" 2>&1 | tail -25
  return 1
}
