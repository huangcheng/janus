#!/bin/sh
# Janus release entrypoint: renders fleet-mode vm.args + TLS optfile
# before exec'ing the release (spec 2026-10-08 Part A). Fleet knob off
# => today's boot exactly (cookie written to ~/.erlang.cookie).
# Master/worker pool: inet_tls when role=worker OR JANUS_FLEET_ENABLED
# OR JANUS_FLEET_PEERS is set (master listens for worker hello without
# starting signal-fleet children).
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
      echo "janus: JANUS_ROLE=worker requires JANUS_ERLANG_COOKIE as hex (≥64 hex chars)" >&2
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

# inet_tls: worker join, signal-fleet, or master with explicit peer list
# (master/worker pool without JANUS_FLEET_ENABLED).
DIST_TLS=false
if [ "$IS_WORKER" = true ] || [ "${JANUS_FLEET_ENABLED:-false}" = "true" ] || [ -n "${JANUS_FLEET_PEERS:-}" ]; then
  DIST_TLS=true
fi

# Build Erlang peer-list term for verify_fun init state (binaries).
# SAN verify requires the remote leaf's dNSName ∈ this list.
peer_bin_list() {
  _out=""
  _old_ifs=$IFS
  IFS=,
  for _p in $1; do
    _p=$(printf '%s' "$_p" | tr -d ' \t\r\n')
    [ -z "$_p" ] && continue
    # Reject chars that would break <<\"...\">> interpolation in the
    # ssl_dist_optfile (operator-controlled env, but fail closed).
    case "$_p" in
      *[!A-Za-z0-9_.@-]*)
        echo "janus: invalid JANUS_FLEET_PEERS entry '$_p' (allowed: A-Za-z0-9_.@-)" >&2
        exit 1
        ;;
      *@*) ;;
      *)
        echo "janus: JANUS_FLEET_PEERS entry must be name@host, got '$_p'" >&2
        exit 1
        ;;
    esac
    if [ -z "$_out" ]; then
      _out="<<\"$_p\">>"
    else
      _out="$_out, <<\"$_p\">>"
    fi
  done
  IFS=$_old_ifs
  printf '[%s]' "$_out"
}

if [ "$DIST_TLS" = true ]; then
  if [ "$IS_WORKER" = false ] && [ -n "${JANUS_ERLANG_COOKIE:-}" ] && [ "${#JANUS_ERLANG_COOKIE}" -lt 16 ]; then
    echo "janus: dist TLS enabled but JANUS_ERLANG_COOKIE too short" >&2; exit 1
  fi
  # Dev-only CA generation (local e2e): self-signed fleet CA + per-node certs.
  # SAN = this node + JANUS_FLEET_PEERS (full long names). Dual-node harness
  # should mount a shared CA instead — GEN_TLS per container creates distinct CAs.
  if [ "${JANUS_FLEET_GEN_TLS:-0}" = "1" ] && [ ! -f "$TLS_DIR/node.pem" ]; then
    set +e
    mkdir -p "$TLS_DIR"
    NODE_HOST="${NODE_NAME#*@}"
    SAN_SRC="$NODE_NAME"
    if [ -n "${JANUS_FLEET_PEERS:-}" ]; then
      SAN_SRC="${NODE_NAME},${JANUS_FLEET_PEERS}"
    fi
    SAN_HOSTS="$(echo "$SAN_SRC" | tr ',' '
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
  # ssl_dist_optfile requires fun Mod:Func/Arity (not MFA — MFA is
  # legacy -ssl_dist_opt only). Init state = peer long-name binaries.
  PEER_ERL="$(peer_bin_list "${JANUS_FLEET_PEERS:-}")"
  OPTFILE="$REL_DIR/config/fleet_ssl_dist.runtime.config"
  mkdir -p "$(dirname "$OPTFILE")"
  # fail_if_no_peer_cert is server-only — OTP 27 rejects it on client opts
  # ({option,server_only,fail_if_no_peer_cert}) and aborts the handshake.
  # Prefer tlsv1.2 for dist: OTP 27 inet_tls_dist + verify_fun has hit
  # case_clause on {unknown, State} under tlsv1.3 in dual-node hello.
  # TODO(dist-tls13): re-enable tlsv1.3 when that OTP path is fixed/verified.
  cat > "$OPTFILE" <<CONF
[{server, [{verify, verify_peer},
           {fail_if_no_peer_cert, true},
           {cacertfile, "$TLS_DIR/ca.pem"},
           {certfile, "$TLS_DIR/node.pem"},
           {keyfile, "$TLS_DIR/node-key.pem"},
           {versions, ['tlsv1.2']},
           {verify_fun, {fun janus_fleet_tls:verify/3, $PEER_ERL}}]},
 {client, [{verify, verify_peer},
           {cacertfile, "$TLS_DIR/ca.pem"},
           {certfile, "$TLS_DIR/node.pem"},
           {keyfile, "$TLS_DIR/node-key.pem"},
           {versions, ['tlsv1.2']},
           {server_name_indication, disable},
           {verify_fun, {fun janus_fleet_tls:verify/3, $PEER_ERL}}]}].
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
