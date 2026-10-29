#!/usr/bin/env bash
# Live boot inside erlang:27-alpine (bind-mount repo at /app).
set -euo pipefail
cd /app
chmod +x rebar3
./rebar3 compile
export JANUS_SQLITE_PATH="${JANUS_SQLITE_PATH:-/app/data/janus.db}"
export JANUS_SNAPSHOT_DIR="${JANUS_SNAPSHOT_DIR:-/app/data/snapshots}"
export JANUS_SEED_PATH="${JANUS_SEED_PATH:-/app/data/seed.providers.json}"
export JANUS_AUTO_SEED="${JANUS_AUTO_SEED:-1}"
export JANUS_API_KEY_PEPPER="${JANUS_API_KEY_PEPPER:-janus-local-pepper}"
if [ -z "${JANUS_SECRETS_KEY:-}" ]; then
  JANUS_SECRETS_KEY="v1:$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
  export JANUS_SECRETS_KEY
fi
rm -f "$JANUS_SQLITE_PATH"
exec erl -noshell -pa _build/default/lib/*/ebin -eval '
application:ensure_all_started(janus),
io:format("janus_up port=~p~n", [application:get_env(janus, http_port, 8080)]),
receive after infinity -> ok end.
'
