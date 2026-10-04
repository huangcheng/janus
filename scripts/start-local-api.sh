#!/usr/bin/env bash
# Compile and run Janus from source in WSL (SQLite + dashboard on :8090).
set -euo pipefail
cd /mnt/f/Janus
ENV_FILE="${JANUS_LOCAL_ENV:-/mnt/f/Janus/data/local.env}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "missing $ENV_FILE — copy scripts/local.env.example" >&2
  exit 1
fi
sed -i 's/\r$//' "$ENV_FILE"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
mkdir -p data
chmod +x rebar3
./rebar3 as dev compile
./rebar3 as dev release
exec _build/dev/rel/janus/bin/janus foreground
