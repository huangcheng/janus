# shellcheck shell=sh
# scripts/lib/janus_vm_args.sh — Janus vm.args / TLS dist renderer.
#
# Extracted from docker-entrypoint.sh (spec 2026-10-15-bare-metal-deploy
# F5c): ONE renderer sourced by BOTH the container entrypoint and the
# bare release wrapper (relx overlay ships this file inside the tarball
# at etc/janus_vm_args.sh — a post-extract hand patch would silently
# fork on every <sha> swap).
#
# Contract:
#   - Sourcing this file has NO side effects (pure function library).
#   - janus_vm_render <release_dir> performs the whole render exactly
#     as docker-entrypoint.sh did inline (byte-identical outputs):
#       * JANUS_ROLE validation (master|worker, refuse unknown)
#       * worker prereqs: JANUS_MASTER_NODE long name + hex cookie >=64,
#         JANUS_FLEET_PEERS augmented with the master peer (exported)
#       * cookie: -setcookie + /var/lib/janus/.erlang.cookie (0600),
#         standalone gen-once state at /var/lib/janus/.erlang.cookie.gen
#       * inet_tls dist decision (worker | JANUS_FLEET_ENABLED |
#         JANUS_FLEET_PEERS) -> ERL_FLAGS export:
#         -proto_dist inet_tls -start_epmd false -epmd_module
#         janus_fleet_epmd -connect_all false -ssl_dist_optfile
#         <rel>/config/fleet_ssl_dist.runtime.config -kernel
#         inet_dist_listen_min/max <JANUS_FLEET_DIST_PORT>
#       * dev-only JANUS_FLEET_GEN_TLS=1 self-signed CA (local e2e)
#       * ssl_dist_optfile render (tlsv1.2, verify_fun janus_fleet_tls)
#       * VM tuning: JANUS_NET_TICKTIME (10-120), JANUS_ZDBBL
#         (128-65536) — invalid values DROP with a warning, never an
#         unbootable node; rendering is IDEMPOTENT (vm.args is
#         regenerated from scratch each boot)
#   - POSIX sh only (busybox-safe): the container entrypoint runs on
#     alpine; the bare wrapper runs on Debian glibc hosts.
#
# Knob enumeration (F5c implementation gate — every knob the
# entrypoint writes today): JANUS_ROLE, JANUS_MASTER_NODE,
# JANUS_ERLANG_COOKIE, JANUS_COOKIE_DIR, JANUS_FLEET_PEERS, JANUS_NODE_NAME,
# JANUS_FLEET_ENABLED, JANUS_FLEET_GEN_TLS, JANUS_FLEET_DIST_PORT,
# JANUS_FLEET_TLS_DIR, JANUS_NET_TICKTIME, JANUS_ZDBBL, ERL_FLAGS
# (appended). Emitted files: /var/lib/janus/.erlang.cookie (0600),
# <rel>/config/fleet_ssl_dist.runtime.config,
# <rel>/releases/*/vm.args (-name, -setcookie, +K true, -A 64, optional
# net_ticktime/+zdbbl).

# Normalize JANUS_ROLE; prints "master" or "worker", exits 1 on
# anything else (same message the entrypoint always printed). Empty and
# whitespace-only values mean "unset" (master), matching janus_role.erl.
janus_vm_role() {
  case "$(printf '%s' "${JANUS_ROLE:-}" | tr -d ' \t\r\n' | tr '[:upper:]' '[:lower:]')" in
    "" | master) printf '%s\n' master ;;
    worker) printf '%s\n' worker ;;
    *)
      echo "janus: unknown JANUS_ROLE=${JANUS_ROLE:-} (use master or worker)" >&2
      exit 1
      ;;
  esac
}

# Worker prereqs (JANUS_MASTER_NODE long name + hex cookie >=64) and
# JANUS_FLEET_PEERS augmentation. Prints the augmented peer list on
# stdout (caller exports it); no output for the master role.
janus_vm_worker_peers() {
  [ "$1" = worker ] || return 0
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
  _jva_master_peer="$JANUS_MASTER_NODE"
  if [ -z "${JANUS_FLEET_PEERS:-}" ]; then
    printf '%s\n' "$_jva_master_peer"
    return 0
  fi
  _jva_found=false
  _jva_old_ifs=$IFS
  IFS=,
  for _jva_p in $JANUS_FLEET_PEERS; do
    if [ "$_jva_p" = "$_jva_master_peer" ]; then
      _jva_found=true
      break
    fi
  done
  IFS=$_jva_old_ifs
  if [ "$_jva_found" = false ]; then
    printf '%s\n' "${JANUS_FLEET_PEERS},${_jva_master_peer}"
  else
    printf '%s\n' "$JANUS_FLEET_PEERS"
  fi
}

# Resolve the cookie: $COOKIE when provided, else generate ONCE and
# keep in /var/lib/janus so restarts are stable. Prints the cookie.
janus_vm_resolve_cookie() {
  if [ -n "$COOKIE" ]; then
    printf '%s\n' "$COOKIE"
    return 0
  fi
  _jva_cfile=/var/lib/janus/.erlang.cookie.gen
  # The gen-once state lives beside the published cookie. Create the private
  # dir first: a bare node only guarantees $PREFIX, so /var/lib/janus may not
  # exist and an unguarded redirect would abort the whole render under `set -e`
  # (review 06e M17). An unwritable path warns and falls back to a per-boot
  # cookie — vm.args always carries -setcookie, so boot still works; the
  # operator should set JANUS_ERLANG_COOKIE for a stable cluster cookie.
  if [ ! -f "$_jva_cfile" ] && mkdir -p "$(dirname "$_jva_cfile")" 2>/dev/null; then
    COOKIE=$(tr -dc 'A-Za-z0-9_-' < /dev/urandom | head -c 32 || true)
    ( umask 077; printf '%s\n' "$COOKIE" > "$_jva_cfile" ) 2>/dev/null || true
  fi
  if [ -f "$_jva_cfile" ]; then
    COOKIE=$(cat "$_jva_cfile")
  else
    echo "janus: WARNING: cannot persist dist cookie state at $_jva_cfile; using a per-boot cookie (-setcookie in vm.args still authenticates this boot)" >&2
    COOKIE=$(tr -dc 'A-Za-z0-9_-' < /dev/urandom | head -c 32 || true)
  fi
  chmod 600 "$_jva_cfile" 2>/dev/null || true
  printf '%s\n' "$COOKIE"
}

# inet_tls dist on: worker, signal-fleet enabled, or explicit peers.
# Prints true/false.
janus_vm_dist_tls() {
  if [ "$1" = worker ] || [ "${JANUS_FLEET_ENABLED:-false}" = "true" ] || [ -n "${2:-}" ]; then
    printf '%s\n' true
  else
    printf '%s\n' false
  fi
}

# Build the Erlang peer-list term for the ssl_dist_optfile verify_fun
# init state (binaries). SAN verify requires the remote leaf's dNSName
# in this list. Exits 1 on entries that would break <<"...">>
# interpolation (operator-controlled env, fail closed).
janus_vm_peer_bin_list() {
  _jva_out=""
  _jva_old_ifs=$IFS
  IFS=,
  for _jva_p in $1; do
    _jva_p=$(printf '%s' "$_jva_p" | tr -d ' \t\r\n')
    [ -z "$_jva_p" ] && continue
    case "$_jva_p" in
      *[!A-Za-z0-9_.@-]*)
        echo "janus: invalid JANUS_FLEET_PEERS entry '$_jva_p' (allowed: A-Za-z0-9_.@-)" >&2
        exit 1
        ;;
      *@*) ;;
      *)
        echo "janus: JANUS_FLEET_PEERS entry must be name@host, got '$_jva_p'" >&2
        exit 1
        ;;
    esac
    if [ -z "$_jva_out" ]; then
      _jva_out="<<\"$_jva_p\">>"
    else
      _jva_out="$_jva_out, <<\"$_jva_p\">>"
    fi
  done
  IFS=$_jva_old_ifs
  printf '[%s]' "$_jva_out"
}

# Dev-only self-signed CA + node leaf (local e2e, JANUS_FLEET_GEN_TLS=1):
# SAN = this node + peers as full long names. A dual-node harness
# should mount a shared CA instead — GEN_TLS per container creates
# distinct CAs. No-op when node.pem already exists.
janus_vm_gen_tls() {
  _jva_tls_dir="$1"
  _jva_node="$2"
  _jva_peers="${3:-}"
  [ -f "$_jva_tls_dir/node.pem" ] && return 0
  set +e
  mkdir -p "$_jva_tls_dir"
  _jva_host="${_jva_node#*@}"
  _jva_san_src="$_jva_node"
  if [ -n "$_jva_peers" ]; then
    _jva_san_src="$_jva_node,$_jva_peers"
  fi
  _jva_san_hosts="$(echo "$_jva_san_src" | tr ',' '
' | sort -u | sed 's/^/DNS:/' | paste -sd, -)"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$_jva_tls_dir/ca-key.pem" -out "$_jva_tls_dir/ca.pem" -days 3650 -subj "/CN=janus-fleet-ca" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -keyout "$_jva_tls_dir/node-key.pem" -out "$_jva_tls_dir/node.csr" -subj "/CN=$_jva_host" >/dev/null 2>&1
  printf 'subjectAltName=%s
extendedKeyUsage=serverAuth,clientAuth
' "$_jva_san_hosts" > "$_jva_tls_dir/san.ext"
  openssl x509 -req -in "$_jva_tls_dir/node.csr" -CA "$_jva_tls_dir/ca.pem" -CAkey "$_jva_tls_dir/ca-key.pem" -CAcreateserial -out "$_jva_tls_dir/node.pem" -days 3650 -extfile "$_jva_tls_dir/san.ext" >/dev/null 2>&1
  rm -f "$_jva_tls_dir/node.csr" "$_jva_tls_dir/san.ext"
  set -e
}

# Render the TLS dist optfile (tlsv1.2, mutual verify via
# janus_fleet_tls:verify/3 with the peer long-name binaries as init
# state). fail_if_no_peer_cert is server-only — OTP 27 rejects it on
# client opts and aborts the handshake.
janus_vm_write_ssl_optfile() {
  _jva_optfile="$1"
  _jva_tls_dir="$2"
  _jva_peer_erl="$3"
  mkdir -p "$(dirname "$_jva_optfile")"
  cat > "$_jva_optfile" <<CONF
[{server, [{verify, verify_peer},
           {fail_if_no_peer_cert, true},
           {cacertfile, "$_jva_tls_dir/ca.pem"},
           {certfile, "$_jva_tls_dir/node.pem"},
           {keyfile, "$_jva_tls_dir/node-key.pem"},
           {versions, ['tlsv1.2']},
           {verify_fun, {fun janus_fleet_tls:verify/3, $_jva_peer_erl}}]},
 {client, [{verify, verify_peer},
           {cacertfile, "$_jva_tls_dir/ca.pem"},
           {certfile, "$_jva_tls_dir/node.pem"},
           {keyfile, "$_jva_tls_dir/node-key.pem"},
           {versions, ['tlsv1.2']},
           {server_name_indication, disable},
           {verify_fun, {fun janus_fleet_tls:verify/3, $_jva_peer_erl}}]}].
CONF
}

# Optional VM tuning lines (validated per spec F6 / Part D): integer +
# range checked; anything else drops with a warning and the OTP default
# applies (ticktime 60 s, zdbbl 1024 KB). The length guard keeps shell
# test arithmetic away from absurdly long "integers". Prints the
# newline-joined extra flags ("" when none).
janus_vm_extra_flags() {
  _jva_extra=""
  if [ -n "${JANUS_NET_TICKTIME:-}" ]; then
    _jva_nt_ok=false
    case "$JANUS_NET_TICKTIME" in
      *[!0-9]*|????????*) ;;
      *)
        if [ "$JANUS_NET_TICKTIME" -ge 10 ] && [ "$JANUS_NET_TICKTIME" -le 120 ]; then
          _jva_nt_ok=true
        fi
        ;;
    esac
    if [ "$_jva_nt_ok" = true ]; then
      _jva_extra="-kernel net_ticktime $JANUS_NET_TICKTIME"
    else
      echo "janus: ignoring JANUS_NET_TICKTIME='$JANUS_NET_TICKTIME' (integer 10-120 required; OTP default applies)" >&2
    fi
  fi
  if [ -n "${JANUS_ZDBBL:-}" ]; then
    _jva_zb_ok=false
    case "$JANUS_ZDBBL" in
      *[!0-9]*|????????*) ;;
      *)
        if [ "$JANUS_ZDBBL" -ge 128 ] && [ "$JANUS_ZDBBL" -le 65536 ]; then
          _jva_zb_ok=true
        fi
        ;;
    esac
    if [ "$_jva_zb_ok" = true ]; then
      if [ -z "$_jva_extra" ]; then
        _jva_extra="+zdbbl $JANUS_ZDBBL"
      else
        _jva_extra="$_jva_extra
+zdbbl $JANUS_ZDBBL"
      fi
    else
      echo "janus: ignoring JANUS_ZDBBL='$JANUS_ZDBBL' (integer 128-65536 required; OTP default applies)" >&2
    fi
  fi
  printf '%s' "$_jva_extra"
}

# Regenerate <rel_dir>/releases/*/vm.args from scratch (the Part D
# idempotency rule: pre-existing net_ticktime/+zdbbl lines from an
# older generation are REPLACED, never appended).
janus_vm_write_vm_args() {
  _jva_rel_dir="$1"
  _jva_node_name="$2"
  _jva_cookie_arg="$3"
  _jva_extra="$4"
  for _jva_f in "$_jva_rel_dir"/releases/*/vm.args; do
    {
      echo "-name $_jva_node_name"
      echo "$_jva_cookie_arg"
      echo "+K true"
      echo "-A 64"
      if [ -n "$_jva_extra" ]; then
        printf '%s\n' "$_jva_extra"
      fi
    } > "$_jva_f"
  done
}

# Main entry point (the old entrypoint body). Renders everything for
# the release rooted at <rel_dir> and exports JANUS_FLEET_PEERS /
# ERL_FLAGS. Does NOT exec anything — the caller execs the release.
janus_vm_render() {
  _jva_rel_dir="$1"
  NODE_NAME="${JANUS_NODE_NAME:-janus@127.0.0.1}"
  COOKIE="${JANUS_ERLANG_COOKIE:-}"

  _jva_role="$(janus_vm_role)"

  # Worker dist: explicit master long name + fleet-grade cookie, and
  # make sure the master is in the peer list.
  _jva_peers="$(janus_vm_worker_peers "$_jva_role")"
  if [ -n "$_jva_peers" ]; then
    JANUS_FLEET_PEERS="$_jva_peers"
    export JANUS_FLEET_PEERS
  fi

  # Cookie: always render -setcookie, and persist the cookie file 0600
  # in the fixed private dir (JANUS_COOKIE_DIR overrides; default
  # /var/lib/janus). Never fall back to a world-writable path such as
  # /tmp: HOME is unset (or /root, unwritable) in the runtime image, and
  # a cookie planted there authenticates the whole cluster. The file is
  # only a convenience for local erl/remsh — vm.args always carries
  # -setcookie — so a private dir that is not writable warns and keeps
  # booting, and a planted symlink is never followed.
  COOKIE="$(janus_vm_resolve_cookie)"
  _jva_cookie_dir="${JANUS_COOKIE_DIR:-/var/lib/janus}"
  _jva_cookie_file="$_jva_cookie_dir/.erlang.cookie"
  if [ -L "$_jva_cookie_file" ]; then
    echo "janus: WARNING: refusing to write dist cookie through symlink $_jva_cookie_file (vm.args still carries -setcookie)" >&2
  elif ! mkdir -p "$_jva_cookie_dir" 2>/dev/null; then
    echo "janus: WARNING: cannot create private cookie dir $_jva_cookie_dir; -setcookie in vm.args still authenticates the cluster" >&2
  elif ! ( umask 077; printf '%s' "$COOKIE" > "$_jva_cookie_file" ) 2>/dev/null; then
    echo "janus: WARNING: cannot write dist cookie $_jva_cookie_file; -setcookie in vm.args still authenticates the cluster" >&2
  elif ! chmod 600 "$_jva_cookie_file" 2>/dev/null; then
    echo "janus: WARNING: cannot chmod 600 $_jva_cookie_file; remove it or fix its permissions" >&2
  fi
  COOKIE_ARG="-setcookie $COOKIE"

  FLEET_PORT="${JANUS_FLEET_DIST_PORT:-25672}"
  TLS_DIR="${JANUS_FLEET_TLS_DIR:-/var/lib/janus/fleet}"

  # inet_tls: worker join, signal-fleet, or master with explicit peer
  # list (master/worker pool without JANUS_FLEET_ENABLED).
  _jva_dist_tls="$(janus_vm_dist_tls "$_jva_role" "${JANUS_FLEET_PEERS:-}")"

  if [ "$_jva_dist_tls" = true ]; then
    # Cookie binds the distributed cluster for both roles (spec N6:
    # shared cookie ≥32). Workers also enforce ≥64 hex via the role
    # boot path above.
    if [ -n "${JANUS_ERLANG_COOKIE:-}" ] && [ "${#JANUS_ERLANG_COOKIE}" -lt 32 ]; then
      echo "janus: dist TLS enabled but JANUS_ERLANG_COOKIE too short (<32)" >&2; exit 1
    fi
    if [ "${JANUS_FLEET_GEN_TLS:-0}" = "1" ]; then
      janus_vm_gen_tls "$TLS_DIR" "$NODE_NAME" "${JANUS_FLEET_PEERS:-}"
    fi
    for _jva_f in ca.pem node.pem node-key.pem; do
      if [ ! -f "$TLS_DIR/$_jva_f" ]; then
        echo "janus: TLS dist requires $TLS_DIR/$_jva_f (set JANUS_FLEET_TLS_DIR or JANUS_FLEET_GEN_TLS=1)" >&2
        exit 1
      fi
    done
    # ssl_dist_optfile requires fun Mod:Func/Arity (not MFA — MFA is
    # legacy -ssl_dist_opt only). Init state = peer long-name binaries.
    PEER_ERL="$(janus_vm_peer_bin_list "${JANUS_FLEET_PEERS:-}")"
    OPTFILE="$_jva_rel_dir/config/fleet_ssl_dist.runtime.config"
    janus_vm_write_ssl_optfile "$OPTFILE" "$TLS_DIR" "$PEER_ERL"
    EXTRA="-proto_dist inet_tls -start_epmd false -epmd_module janus_fleet_epmd -connect_all false -ssl_dist_optfile $OPTFILE -kernel inet_dist_listen_min $FLEET_PORT inet_dist_listen_max $FLEET_PORT"
    export ERL_FLAGS="${ERL_FLAGS:-} $EXTRA"
  fi

  VM_EXTRA="$(janus_vm_extra_flags)"
  janus_vm_write_vm_args "$_jva_rel_dir" "$NODE_NAME" "$COOKIE_ARG" "$VM_EXTRA"
}
