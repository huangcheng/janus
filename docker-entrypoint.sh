#!/bin/sh
# Janus release entrypoint: renders fleet-mode vm.args + TLS optfile
# before exec'ing the release (spec 2026-10-08 Part A). Fleet knob off
# => today's boot exactly (cookie written to ~/.erlang.cookie).
set -eu
REL_DIR="/opt/janus"
VM_ARGS="$REL_DIR/releases/*/vm.args"
NODE_NAME="${JANUS_NODE_NAME:-janus@127.0.0.1}"
COOKIE="${JANUS_ERLANG_COOKIE:-}"
JANUS_ROLE_NORM="$(printf '%s' "${JANUS_ROLE:-master}" | tr '[:upper:]' '[:lower:]')"
IS_WORKER=false
case "$JANUS_ROLE_NORM" in
  master) ;;
  worker) IS_WORKER=true ;;
  *)
    echo "janus: unknown JANUS_ROLE=$JANUS_ROLE (use master or worker)" >&2
    exit 1
    ;;
esac

# Worker dist: explicit master long name + fleet-grade cookie (32 random bytes).
if [ "$IS_WORKER" = true ]; then
  if [ -z "${JANUS_MASTER_NODE:-}" ]; then
    echo "janus: JANUS_ROLE=worker requires JANUS_MASTER_NODE" >&2
    exit 1
  fi
  case "$JANUS_MASTER_NODE" in
    *@*) ;;
    *)
      echo "janus: JANUS_MASTER_NODE must be a long node name (name@host), got '$JANUS_MASTER_NODE'" >&2
      exit 1
      ;;
  esac
  if [ -z "$COOKIE" ]; then
    echo "janus: JANUS_ROLE=worker requires JANUS_ERLANG_COOKIE (≥64 hex chars)" >&2
    exit 1
  fi
  case "$COOKIE" in
    *[!0-9a-fA-F]*)
      echo "janus: JANUS_ROLE=worker requires JANUS_ERLANG_COOKIE as hex (≥64 chars)" >&2
      exit 1
      ;;
  esac
  if [ "${#COOKIE}" -lt 64 ]; then
    echo "janus: JANUS_ROLE=worker requires JANUS_ERLANG_COOKIE ≥64 hex chars (32 random bytes)" >&2
    exit 1
  fi
  MASTER_PEER="$JANUS_MASTER_NODE"
  if [ -z "${JANUS_FLEET_PEERS:-}" ]; then
    JANUS_FLEET_PEERS="$MASTER_PEER"
  else
    _found=false
    _old_ifs=$IFS
    IFS=,
    for _p in $JANUS_FLEET_PEERS; do
      if [ "$_p" = "$MASTER_PEER" ]; then
        _found=true
        break
      fi
    done
    IFS=$_old_ifs
    if [ "$_found" = false ]; then
      JANUS_FLEET_PEERS="${JANUS_FLEET_PEERS},${MASTER_PEER}"
    fi
  fi
  export JANUS_FLEET_PEERS
fi

# Cookie: always render -setcookie + write ~/.erlang.cookie (chmod 600).
if [ -z "$COOKIE" ]; then
  # Standalone: generate once, keep in /var/lib/janus so restarts are stable.
  CFILE=/var/lib/janus/.erlang.cookie.gen
  if [ ! -f "$CFILE" ]; then
    COOKIE=$(tr -dc 'A-Za-z0-9_-' < /dev/urandom | head -c 32 || true)
    umask 077; echo "$COOKIE" > "$CFILE"
  else
    COOKIE=$(cat "$CFILE")
  fi
fi
printf '%s' "$COOKIE" > "${HOME:-/tmp}/.erlang.cookie" 2>/dev/null || \
  printf '%s' "$COOKIE" > "/var/lib/janus/.erlang.cookie"
chmod 600 "${HOME:-/tmp}/.erlang.cookie" 2>/dev/null || true
COOKIE_ARG="-setcookie $COOKIE"

FLEET_PORT="${JANUS_FLEET_DIST_PORT:-25672}"
TLS_DIR="${JANUS_FLEET_TLS_DIR:-/var/lib/janus/fleet}"

# inet_tls dist for signal-fleet mesh OR master/worker pool (worker hello only).
DIST_TLS=false
if [ "$IS_WORKER" = true ] || [ "${JANUS_FLEET_ENABLED:-false}" = "true" ]; then
  DIST_TLS=true
fi

if [ "$DIST_TLS" = true ]; then
  if [ "$IS_WORKER" = false ] && [ -n "${JANUS_ERLANG_COOKIE:-}" ] && [ "${#JANUS_ERLANG_COOKIE}" -lt 16 ]; then
    echo "janus: JANUS_FLEET_ENABLED=true but JANUS_ERLANG_COOKIE too short" >&2; exit 1
  fi
  # Dev-only CA generation (local e2e): self-signed fleet CA + per-node certs
  # with SANs from JANUS_FLEET_PEERS. Production mounts a real PKI dir.
  if [ "${JANUS_FLEET_GEN_TLS:-0}" = "1" ] && [ ! -f "$TLS_DIR/node.pem" ]; then
    # Dev-only self-signed fleet CA + per-node cert (SANs from peers).
    # Tolerant block: any failure falls through to the file check below
    # which reports exactly what is missing.
    set +e
    mkdir -p "$TLS_DIR"
    NODE_HOST="${NODE_NAME#*@}"
    # SAN = FULL peer node names — janus_fleet_tls:verify/3 checks
    # SAN against the configured peer list verbatim (ocr high: host-only
    # SANs never match). No process substitution: busybox ash lacks it.
    SAN_HOSTS="$(echo "${JANUS_FLEET_PEERS:-$NODE_NAME}" | tr ',' '
' | sort -u | sed 's/^/DNS:/' | paste -sd, -)"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TLS_DIR/ca-key.pem" -out "$TLS_DIR/ca.pem" -days 3650 -subj "/CN=janus-fleet-ca" >/dev/null 2>&1
    openssl req -newkey rsa:2048 -nodes -keyout "$TLS_DIR/node-key.pem" -out "$TLS_DIR/node.csr" -subj "/CN=$NODE_HOST" >/dev/null 2>&1
    printf 'subjectAltName=%s
extendedKeyUsage=serverAuth,clientAuth
' "$SAN_HOSTS" > "$TLS_DIR/san.ext"
    openssl x509 -req -in "$TLS_DIR/node.csr" -CA "$TLS_DIR/ca.pem" -CAkey "$TLS_DIR/ca-key.pem" -CAcreateserial -out "$TLS_DIR/node.pem" -days 3650 -extfile "$TLS_DIR/san.ext" >/dev/null 2>&1
    rm -f "$TLS_DIR/node.csr" "$TLS_DIR/san.ext"
    set -e
  fi
  for f in ca.pem node.pem node-key.pem; do
    if [ ! -f "$TLS_DIR/$f" ]; then
      echo "janus: TLS dist requires $TLS_DIR/$f (set JANUS_FLEET_TLS_DIR or JANUS_FLEET_GEN_TLS=1)" >&2
      exit 1
    fi
  done
  OPTFILE="$REL_DIR/config/fleet_ssl_dist.runtime.config"
  mkdir -p "$(dirname "$OPTFILE")"
  cat > "$OPTFILE" <<CONF
[{server, [{verify, verify_peer},
           {fail_if_no_peer_cert, true},
           {cacertfile, "$TLS_DIR/ca.pem"},
           {certfile, "$TLS_DIR/node.pem"},
           {keyfile, "$TLS_DIR/node-key.pem"},
           {versions, ['tlsv1.3','tlsv1.2']},
           {verify_fun, {janus_fleet_tls, verify, []}}]},
 {client, [{verify, verify_peer},
           {fail_if_no_peer_cert, true},
           {cacertfile, "$TLS_DIR/ca.pem"},
           {certfile, "$TLS_DIR/node.pem"},
           {keyfile, "$TLS_DIR/node-key.pem"},
           {versions, ['tlsv1.3','tlsv1.2']},
           {verify_fun, {janus_fleet_tls, verify, []}}}]}.
CONF
  EXTRA="-proto_dist inet_tls -start_epmd false -epmd_module janus_fleet_epmd -connect_all false -ssl_dist_optfile $OPTFILE -kernel inet_dist_listen_min $FLEET_PORT inet_dist_listen_max $FLEET_PORT"
  export ERL_FLAGS="${ERL_FLAGS:-} $EXTRA"
fi

# Render node name + cookie into vm.args (release reads RELX_REPLACE vars
# only conditionally; sed the file directly — deterministic).
for f in $VM_ARGS; do
  {
    echo "-name $NODE_NAME"
    echo "$COOKIE_ARG"
    echo "+K true"
    echo "-A 64"
  } > "$f"
done
exec "$REL_DIR/bin/janus" foreground
