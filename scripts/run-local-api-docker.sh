#!/bin/sh
# Runs inside erlang:27-alpine with /app = Janus checkout.
set -eu
cd /app
if [ -f /etc/apk/repositories ]; then
  sed -i 's#https://dl-cdn.alpinelinux.org#https://mirrors.aliyun.com#g' /etc/apk/repositories
fi
apk add --no-cache git build-base >/tmp/apk.log 2>&1 || {
  cat /tmp/apk.log
  exit 1
}
chmod +x rebar3
./rebar3 as dev compile
./rebar3 as dev release
exec _build/dev/rel/janus/bin/janus foreground
