#!/usr/bin/env bash
# install_bare_dashboard.sh <node> — install + start the BARE-METAL
# dashboard on the LEADER node (spec 2026-10-15-bare-metal-deploy
# Task 2: B-D3/B-D7 dash half + F2/F4b/F5b/F7 dash discipline).
#
# Bare-path dashboard installer. Docker and bare are TWO INDEPENDENT
# paths — there is no runtime switch and no migration; the janus repo's
# switch_runtime.sh was DELETED on purpose (2026-10-18 doctrine).
# JANUS_DASH_BARE=true is explicit operator intent for the bare
# dashboard: if a compose dashboard container is still running it gets
# stopped at cutover (teardown of the docker half, port-conflict
# guard), and on a fresh bare node there is simply nothing to stop.
#
# INVENTORY CONTRACT (spec §0; ONE canonical file: the JANUS repo's
# deploy/inventory.env, whose committed EXAMPLE template lives there
# — Task 3 consolidation: both repos resolve that ONE file.
# Resolution order here: --inventory, $JANUS_INVENTORY,
# ../janus/deploy/inventory.env (canonical), deploy/inventory.env in
# this repo (LEGACY fallback only)):
#   JANUS_NODE_<NAME>     'alias=...;role=leader;runtime=...;py3=X.Y;stacks_dir=...'
#                         — role MUST be leader (spec §4: Task 2 runs
#                         on the leader); py3 selects the venv
#                         interpreter + the wheelhouse cross-check
#   JANUS_BARE_PREFIX     bare tree root ($PREFIX/dash/<sha>/ payload)
#   JANUS_BARE_USER       systemd User= (B-D7)
#   JANUS_DASH_PORT       the uvicorn port caddy proxies (dual-bind
#                         probe target)
#   JANUS_DASH_SERVICE    compose dashboard service NAME (label-filter
#                         stop + caddy gate match)
#   JANUS_DB_ENDPOINT     reachable (non-compose-DNS) Postgres (F4b)
#   JANUS_DB_ENV_KEYS     env keys carrying the DB address — the
#                         generated EnvironmentFile rewrites them,
#                         shape-aware, LAST (discrete *_HOST/*_PORT
#                         pair members, else DSN/URL in place)
#   JANUS_DASH_BARE       MUST be true (explicit intent — the bare
#                         path is independent; a compose dashboard, if
#                         present, is stopped at cutover)
#
# ORDER (abort-safe: NOTHING destructive until the payload is proven;
# the compose dashboard is stopped only after the proof — 06b M2):
#   PRE (payload proof — the compose dashboard keeps serving):
#     1. inventory + node resolve; role=leader enforced; runtime!=bare
#        warns (sequencing §4: the leader's gateway flips first)
#     2. JANUS_DASH_BARE=true verified (hard refusal — no accidental
#        bare install)
#     3. payload sanity: app/, spa/dist/index.html, docs/schemas/
#        config-backup-v1.schema.json, pyproject.toml, wheels/,
#        wheels-manifest.txt (sha256 manifest, verified against the
#        shipped tree before any pip step), BUILD-FACTS.txt py_minors
#        covers the node's py3. NO PAYLOAD = NO REAL INSTALL (H1)
#     4. python<py3> (e.g. python3.11) present on the node — PREREQ FAILURE, never a
#        silent install (B-D7)
#     5. F2 env generation from the node's compose DASHBOARD service
#        (env_file + inline environment merged inline-wins, ${VAR}
#        resolved against env_file + project .env with abort-on-
#        unresolved, mmdb volume-path rewrite, DB endpoint rewrite
#        LAST shape-aware, compose DB port publish check) + unit render
#     6. F7 wheelhouse tag floor: every wheel's manylinux floor <= the
#        node's glibc (F3 floor check mirrored); linux_x86_64 tags
#        refuse (unrepaired build — see build_bare_dashboard.sh)
#     7. caddy upstream verify-first gate (facts-6): read the caddy
#        config under the node's stacks_dir and REFUSE while an
#        upstream still names the compose service DNS name — once the
#        service is disabled that name stops resolving; re-point
#        caddy at the host-reachable JANUS_DASH_PORT first. Caddy
#        config not found OR not readable under stacks_dir = cannot
#        verify = refuse (--skip-caddy-gate after a manual check)
#     8. ship the payload (tar over ssh) -> $PREFIX/dash/<sha>/ then
#        verify wheels-manifest.txt ON THE NODE and build the venv
#        (python<py3> -m venv venv; pip install --no-index
#        --find-links wheels/ janus-dashboard setuptools wheel —
#        F5b zero egress, F7 own-wheel-by-name). Any failure here
#        aborts with the compose dashboard still serving.
#     9. EnvironmentFile -> $PREFIX/env/janus-dash.env (root:<user> 0640)
#   EXECUTE (destructive swap, last):
#    10. dual-bind guard: JANUS_DASH_PORT must be FREE (probe), and a
#        still-running compose dashboard container is stopped WITH the
#        F1 discipline (restart policy captured -> state file written
#        BEFORE the mutation -> docker update --restart=no -> docker
#        stop verified)
#    11. unit install from deploy/janus-dash.service.template ->
#        /etc/systemd/system/janus-dash.service; daemon-reload; enable
#    12. `current` symlink swap -> <sha>
#    13. start + assert systemctl is-active + /api/health
#
# Idempotent: same-sha re-runs refresh the tree, no-op the venv
# install, re-render the unit, and only restart when needed.
#
# Options:
#   --payload <dir>       local payload dir (build_bare_dashboard.sh
#                         output, name dash-<sha>). REQUIRED for every
#                         real install (fail closed, H1): the payload
#                         checks — shape, BUILD-FACTS py3 coverage,
#                         wheelhouse manylinux/glibc floor and the
#                         wheels-manifest integrity chain — only run
#                         against it. The same dir may be supplied in
#                         $JANUS_DASH_PAYLOAD_DIR (--payload wins).
#                         Not needed with --dry-run.
#   --allow-no-payload    escape: no payload; refresh the tree named by
#                         $PREFIX/dash/current in place (idempotent
#                         re-run). PAYLOAD CHECKS ARE SKIPPED — verify
#                         the installed tree by hand first (H1)
#   --dry-run             print the resolved plan, mutate nothing
#   --local               simulation: node-side commands run LOCALLY
#                         (no ssh); systemd steps print-only unless
#                         --with-systemd
#   --with-systemd        (with --local) actually run systemctl
#   --skip-caddy-gate     proceed when the caddy config cannot be found
#                         or read (verify-first escape AFTER a manual
#                         check)
#   --prefix <dir>        override JANUS_BARE_PREFIX (simulation)
#   --stacks-dir <dir>    override the node's stacks_dir (simulation)
#   --inventory <file>    override the inventory file
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  # Header only: from line 2 down to the first code line — no magic
  # line number to re-tune whenever the option list grows.
  sed -n '2,/^set -euo pipefail/p' "${BASH_SOURCE[0]}" \
    | grep '^#' | sed 's/^# \{0,1\}//'
  exit 2
}

# ---------------------------------------------------------------- args ---
NODE="" PAYLOAD="" DRY_RUN=false LOCAL=false WITH_SYSTEMD=false
SKIP_CADDY=false PREFIX_OVERRIDE="" STACKS_OVERRIDE="" INV_OVERRIDE=""
ALLOW_NO_PAYLOAD=false
while [ $# -gt 0 ]; do
  case "$1" in
    --payload) PAYLOAD="${2:?}"; shift ;;
    --allow-no-payload) ALLOW_NO_PAYLOAD=true ;;
    --dry-run) DRY_RUN=true ;;
    --local) LOCAL=true ;;
    --with-systemd) WITH_SYSTEMD=true ;;
    --skip-caddy-gate) SKIP_CADDY=true ;;
    --prefix) PREFIX_OVERRIDE="${2:?}"; shift ;;
    --stacks-dir) STACKS_OVERRIDE="${2:?}"; shift ;;
    --inventory) INV_OVERRIDE="${2:?}"; shift ;;
    -h|--help) usage ;;
    *) [ -z "$NODE" ] && NODE="$1" || usage ;;
  esac
  shift
done
[ -n "$NODE" ] || usage
# H1: the payload dir may also arrive from the environment — the one
# production caller pre-ships the tree and cannot thread --payload
# through its call. --payload still wins when both are given.
[ -n "$PAYLOAD" ] || PAYLOAD="${JANUS_DASH_PAYLOAD_DIR:-}"

die() { echo "install_bare_dashboard: FAIL: $*" >&2; exit 1; }
note() { echo "install_bare_dashboard: $*"; }

# ----------------------------------------------------------- inventory ---
INV="${INV_OVERRIDE:-${JANUS_INVENTORY:-}}"
if [ -z "$INV" ]; then
  # Canonical file FIRST (Task 3 consolidation): the janus repo's
  # deploy/inventory.env is the ONE file both repos resolve; this
  # repo's deploy/inventory.env is a LEGACY fallback only.
  for cand in "$ROOT/../janus/deploy/inventory.env" "$ROOT/deploy/inventory.env"; do
    [ -f "$cand" ] && INV="$cand" && break
  done
fi
[ -n "$INV" ] && [ -f "$INV" ] || die "inventory not found (populate deploy/inventory.env — see the janus repo's deploy/inventory.env.example, spec §0)"
# shellcheck disable=SC1090
. "$INV"

req() { # refuse-on-missing inventory key (spec §0)
  local v
  eval "v=\"\${$1:-}\""
  [ -n "$v" ] || die "inventory key $1 missing (populate $INV)"
  printf '%s' "$v"
}

NODE_VAR="JANUS_NODE_${NODE}"
NODE_SPEC="$(req "$NODE_VAR")"
node_field() { # node_field <alias|role|runtime|py3|stacks_dir>
  local f="$1" seg
  seg="$(printf '%s' "$NODE_SPEC" | tr ';' '\n' | grep -m1 "^${f}=" || true)"
  printf '%s' "${seg#*=}"
}
ALIAS="$(node_field alias)"
ROLE="$(node_field role)"
RUNTIME="$(node_field runtime)"
PY3="$(node_field py3)"
STACKS="${STACKS_OVERRIDE:-$(node_field stacks_dir)}"
[ -n "$ALIAS" ] || die "node $NODE: alias= missing in $NODE_VAR"
[ -n "$PY3" ] || die "node $NODE: py3= missing in $NODE_VAR"
[ -n "$STACKS" ] || die "node $NODE: stacks_dir= missing in $NODE_VAR"

PREFIX="${PREFIX_OVERRIDE:-$(req JANUS_BARE_PREFIX)}"
BARE_USER="$(req JANUS_BARE_USER)"
DASH_PORT="$(req JANUS_DASH_PORT)"
DASH_SERVICE="$(req JANUS_DASH_SERVICE)"
DB_ENDPOINT="$(req JANUS_DB_ENDPOINT)"
DB_ENV_KEYS="$(req JANUS_DB_ENV_KEYS)"
DASH_BARE="${JANUS_DASH_BARE:-false}"
COMPOSE_PROJECT="$(basename "$STACKS")"
DB_HOST="${DB_ENDPOINT%%:*}"
DB_PORT="${DB_ENDPOINT##*:}"
ENVFILE="$PREFIX/env/janus-dash.env"
STATE_FILE="$PREFIX/dash/switch-state.env"
UNIT_DST="/etc/systemd/system/janus-dash.service"

[ "$ROLE" = leader ] || die "node $NODE: role=$ROLE — the bare dashboard installs on the LEADER only (spec §4)"
[ "$RUNTIME" = bare ] || note "WARNING: node $NODE inventory runtime=$RUNTIME (docker) — this node is on the docker path; if a compose dashboard runs there it will be stopped at cutover; proceeding on operator intent"

# -------------------------------- explicit bare intent (d4) ---------------
if [ "$DASH_BARE" != true ]; then
  die "inventory JANUS_DASH_BARE=$DASH_BARE — set it to true to install the bare dashboard (explicit intent; this stops the compose dashboard '$DASH_SERVICE' if one is running)"
fi
note "JANUS_DASH_BARE=true verified — the bare path owns the dashboard; any compose dashboard container is stopped at cutover"

# --------------------------------------------------------- node access ---
run_node() { # run_node <cmd-string>: node-side POSIX sh (ssh, or local sim)
  if [ "$LOCAL" = true ]; then
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' bash -c "$1"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$ALIAS" "$1"
  fi
}
write_node() { # write_node <dest> <src-local> [mode]
  local dest="$1" src="$2" mode="${3:-}"
  local tmp="$dest.w7tmp.$$"
  # 06b M4: never touch the live file (the envfile carries every
  # dashboard secret). Stream into a same-directory temp created 0600
  # under umask 077, apply the final mode, then rename atomically — the
  # old `cat > $dest` truncated the live file and left it world-readable
  # until the chmod that followed.
  if [ "$LOCAL" = true ]; then
    mkdir -p "$(dirname "$dest")"
    ( umask 077; cat "$src" > "$tmp" ) || { rm -f "$tmp"; return 1; }
    [ -z "$mode" ] || chmod "$mode" "$tmp"
    mv -f "$tmp" "$dest"
  else
    run_node "mkdir -p '$(dirname "$dest")'"
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$ALIAS" "umask 077; cat > '$tmp'" < "$src" || return 1
    [ -z "$mode" ] || run_node "chmod $mode '$tmp'"
    run_node "mv -f '$tmp' '$dest'"
  fi
}
fetch_node_file() { # fetch_node_file <path> <local-dest>; fails when missing
  if [ "$LOCAL" = true ]; then
    [ -f "$1" ] || return 1
    cp "$1" "$2"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$ALIAS" "test -f '$1' && cat '$1'" > "$2" 2>/dev/null || return 1
  fi
  return 0
}
sysctl_cmd() { # systemd command (print-only in local sim without --with-systemd)
  if [ "$LOCAL" = true ] && [ "$WITH_SYSTEMD" != true ]; then
    note "  [sim] systemctl $*"
  else
    run_node "systemctl $*"
  fi
}

# ----------------------------------------------- payload + prereqs -------
SH=""
if [ -n "$PAYLOAD" ]; then
  [ -d "$PAYLOAD" ] || die "--payload $PAYLOAD is not a directory (build_bare_dashboard.sh output)"
  PAYLOAD="$(cd "$PAYLOAD" && pwd)"
  SH="$(basename "$PAYLOAD")"
  case "$SH" in dash-*) ;; *) die "payload dir name must be dash-<sha> (got $SH)";; esac
  [ -f "$PAYLOAD/app/main.py" ] || die "payload missing app/main.py"
  [ -f "$PAYLOAD/spa/dist/index.html" ] || die "payload missing spa/dist/index.html"
  [ -f "$PAYLOAD/docs/schemas/config-backup-v1.schema.json" ] || die "payload missing docs/schemas/config-backup-v1.schema.json (the app refuses to boot without it)"
  [ -f "$PAYLOAD/pyproject.toml" ] || die "payload missing pyproject.toml"
  [ -d "$PAYLOAD/wheels" ] || die "payload missing wheels/"
  [ -f "$PAYLOAD/wheels-manifest.txt" ] || die "payload missing wheels-manifest.txt — the wheelhouse integrity chain (H2) cannot be verified; rebuild with build_bare_dashboard.sh"
  ls "$PAYLOAD"/wheels/janus_dashboard-*.whl > /dev/null 2>&1 || die "payload wheels/ carries no janus_dashboard wheel"
  if [ -f "$PAYLOAD/BUILD-FACTS.txt" ]; then
    covered="$(sed -n 's/^py_minors=//p' "$PAYLOAD/BUILD-FACTS.txt")"
    if [ -n "$covered" ] && ! printf ' %s ' "$covered" | grep -q " $PY3 "; then
      die "node py3=$PY3 is NOT covered by the payload wheelhouse (py_minors=$covered) — rebuild with --py3 $PY3"
    fi
  fi
elif [ "$DRY_RUN" = true ]; then
  : # dry-run without a payload keeps the plan-only behaviour (no node reads)
elif [ "$ALLOW_NO_PAYLOAD" != true ]; then
  die "no payload supplied — a real install REQUIRES one: pass --payload <dir> or set JANUS_DASH_PAYLOAD_DIR (build_bare_dashboard.sh output, name dash-<sha>). Without it the payload-shape, BUILD-FACTS py3-coverage and wheelhouse manylinux/glibc gates never run (H1: the production caller used to skip all of them). Use --allow-no-payload only to refresh a tree already installed at \$PREFIX/dash/current, after verifying it by hand"
else
  SH="$(run_node "basename \"\$(readlink -f '$PREFIX/dash/current')\" 2>/dev/null" || true)"
  case "$SH" in dash-*) note "--allow-no-payload: refreshing the already-installed $SH (payload checks skipped)";; *)
    die "--allow-no-payload but no \$PREFIX/dash/current on node $NODE — pass --payload <dir> (build_bare_dashboard.sh output)";; esac
fi

# python<py3> presence (py3=3.11 -> python3.11): PREREQ FAILURE, never a silent install (B-D7)
note "prereq: python$PY3 on node $NODE"
if ! run_node "command -v python$PY3 > /dev/null 2>&1"; then
  die "python$PY3 not present on node $NODE — install it by the distro's supported path and record the decision in the inventory example (B-D7: absence is a PREREQ FAILURE, never a silent apt/dnf at switch time)"
fi
note "       python$PY3 present"

# ----------------------------------------------- F2: env generation -------
# Parses the node's compose file for the DASH service's env/volumes.
# Emits TAB records on stdout:
#   ENVFILE<TAB>path   INLINE<TAB>KEY=VAL   VOL<TAB>host<TAB>container
compose_service_records() { # <compose-file> <service>
  awk -v svc="$2" '
    function fail(m) { printf "compose_parse_error: %s\n", m > "/dev/stderr"; exit 3 }
    /^services:/ { insvc = 1; next }
    insvc && /^  [A-Za-z0-9_.-]+:[ ]*$/ {
      name = $0; sub(/^  /, "", name); sub(/:.*/, "", name)
      cur = (name == svc) ? 1 : 0
      sect = ""
      next
    }
    insvc && /^[^ ]/ { insvc = 0 }
    cur && /^    env_file:/ {
      val = $0; sub(/^    env_file:[ ]*/, "", val); sub(/[ ]*$/, "", val)
      if (val ~ /[|>]/) fail("env_file block scalar unsupported")
      gsub(/["'"'"']/, "", val)
      if (val != "") print "ENVFILE\t" val
      sect = "envfile"; next
    }
    cur && sect == "envfile" && /^      - / {
      val = $0; sub(/^      - [ ]*/, "", val); sub(/[ ]*$/, "", val)
      gsub(/["'"'"']/, "", val)
      if (val != "") print "ENVFILE\t" val
      next
    }
    cur && /^    environment:/ { sect = "env"; next }
    cur && sect == "env" && /^      - / {
      val = $0; sub(/^      - [ ]*/, "", val); sub(/[ ]*$/, "", val)
      if (val ~ /[|>]/) fail("environment block scalar unsupported")
      if (val !~ /^[A-Za-z_][A-Za-z0-9_]*=/) fail("environment list entry not KEY=VAL: " val)
      sub(/^["'"'"']/, "", val); sub(/["'"'"']$/, "", val)
      print "INLINE\t" val
      next
    }
    cur && sect == "env" && /^      [A-Za-z_][A-Za-z0-9_]*:/ {
      line = $0; sub(/^      /, "", line)
      key = line; sub(/:.*/, "", key)
      val = line; sub(/^[^:]*:[ ]*/, "", val)
      if (val ~ /[|>]/) fail("environment block scalar unsupported: " key)
      sub(/^["'"'"']/, "", val); sub(/["'"'"']$/, "", val)
      print "INLINE\t" key "=" val
      next
    }
    cur && /^    volumes:/ { sect = "vol"; next }
    cur && sect == "vol" && /^      - / {
      val = $0; sub(/^      - [ ]*/, "", val); sub(/[ ]*$/, "", val)
      sub(/^["'"'"']/, "", val); sub(/["'"'"']$/, "", val)
      if (val ~ /^type: *bind$/) fail("volumes long syntax (type: bind) unsupported — convert to short bind form or extend the parser (never silently skip a host dir)")
      # Dynamic regex string: a literal '/' inside a bracket expression is
      # rejected by BSD awk (macOS); the string form parses on both awks.
      if (val ~ ("^[.~/][^:]*:[^:]*(:.*)?$")) {
        host = val; sub(/:.*$/, "", host)
        cont = val; sub(/^[^:]*:/, "", cont); sub(/:.*$/, "", cont)
        print "VOL\t" host "\t" cont
      }
      next
    }
    cur && /^    [A-Za-z_]/ { sect = "" }
  ' "$1"
}

# Resolve ${VAR} / ${VAR:-default} against KEY=VAL files; unresolved
# PLAIN ${VAR} aborts. python3 when present, awk fallback otherwise.
resolve_dollar() { # <input-file> <env-files...>
  local in="$1"; shift
  if command -v python3 > /dev/null 2>&1; then
    python3 - "$in" "$@" <<'PYEOF'
import re, sys
path = sys.argv[1]
env = {}
for f in sys.argv[2:]:
    try:
        with open(f, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if line.lstrip().startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                env[k.strip()] = v
    except OSError:
        pass
with open(path, encoding="utf-8", errors="replace") as fh:
    src = fh.read()
def sub(m):
    name, default = m.group(1), m.group(2)
    if name in env:
        return env[name]
    if default is not None:
        return default
    sys.stderr.write("unresolved ${%s} (checked env_file(s) + project .env)\n" % name)
    sys.exit(4)
sys.stdout.write(re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}", sub, src))
PYEOF
  else
    awk '
      function get(k,  i, line, key) {
        for (i = 2; i < ARGC; i++) {
          while ((getline line < ARGV[i]) > 0) {
            if (line ~ /^[ \t]*#/) continue
            key = line; sub(/=.*/, "", key)
            if (key == k) { close(ARGV[i]); return substr(line, length(key) + 2) }
          }
          close(ARGV[i])
        }
        return ""
      }
      # ONLY the input records are emitted — the env-file arguments
      # are read exclusively via get(); without this guard awk also
      # runs the main block over them and appends their lines to the
      # output (dup keys + raw env keys in the envfile).
      FILENAME == ARGV[1] {
        out = ""; s = $0
        while (match(s, /\$\{[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\}/)) {
          out = out substr(s, 1, RSTART - 1)
          tok = substr(s, RSTART, RLENGTH)
          name = tok; sub(/^\$\{/, "", name); sub(/(:-[^}]*)?\}$/, "", name)
          val = get(name)
          if (val == "") {
            if (tok ~ /:-/) { val = tok; sub(/^\$\{[A-Za-z_][A-Za-z0-9_]*:-/, "", val); sub(/\}$/, "", val) }
            else { printf "unresolved ${%s} (checked env_file(s) + project .env)\n", name > "/dev/stderr"; exit 4 }
          }
          out = out val
          s = substr(s, RSTART + RLENGTH)
        }
        print out s
      }
    ' "$in" "$@"
  fi
}

dsn_rewrite() { # <value> -> stdout; nonzero when no DSN shape matches
  local v="$1"
  if printf '%s' "$v" | grep -qE '@[^/:@]+:[0-9]+'; then
    printf '%s' "$v" | sed -E "s#@[^/:@]+:[0-9]+#@${DB_HOST}:${DB_PORT}#"
  elif printf '%s' "$v" | grep -qE '://[^/@:]+:[0-9]+'; then
    printf '%s' "$v" | sed -E "s#//[^/@:]+:[0-9]+#//${DB_HOST}:${DB_PORT}#"
  elif printf '%s' "$v" | grep -qxE '[A-Za-z0-9_.-]+:[0-9]+'; then
    printf '%s' "${DB_HOST}:${DB_PORT}"
  else
    return 1
  fi
}

GEN_DIR=""
# 06b L1: $GEN_DIR holds the fully merged dashboard env (every secret)
# plus project.env — remove it on every exit path. mktemp -d is 0700.
trap '[ -z "${GEN_DIR:-}" ] || rm -rf -- "$GEN_DIR"' EXIT
gen_envfile() { # writes merged+resolved+rewritten envfile to $GEN_DIR/janus-dash.env
  GEN_DIR="$(mktemp -d)"
  local compose="$STACKS/docker-compose.yml"
  fetch_node_file "$compose" "$GEN_DIR/compose.yml" \
    || fetch_node_file "$STACKS/docker-compose.yaml" "$GEN_DIR/compose.yml" \
    || die "no docker-compose.y[a]ml under $STACKS on node $NODE"
  compose="$GEN_DIR/compose.yml"

  local records
  records="$(compose_service_records "$compose" "$DASH_SERVICE")" \
    || die "could not parse service $DASH_SERVICE in $compose (unsupported YAML shape — extend the parser, never guess)"
  [ -n "$records" ] || die "service $DASH_SERVICE not found in $compose"

  local merged="$GEN_DIR/merged.env"
  : > "$merged"
  : > "$GEN_DIR/vols.txt"
  while IFS=$'\t' read -r kind payload; do
    case "$kind" in
      ENVFILE)
        fetch_node_file "$STACKS/$payload" "$GEN_DIR/envfile" \
          || die "env_file $STACKS/$payload (service $DASH_SERVICE) unreadable on node $NODE"
        grep -v '^[[:space:]]*#' "$GEN_DIR/envfile" | grep -v '^[[:space:]]*$' >> "$merged" || true
        ;;
      INLINE) printf '%s\n' "$payload" >> "$merged" ;;
      VOL) printf '%s\n' "$payload" >> "$GEN_DIR/vols.txt" ;;
    esac
  done <<EOF2
$records
EOF2

  # Merge: LAST occurrence wins — env_file lines first, INLINE later,
  # so inline wins verbatim (r3).
  local kv="$GEN_DIR/kv.env"
  awk -F= '{ k = $1; sub(/=.*/, "", k); seen[k] = NR; line[k] = $0 } END { for (k in seen) print line[k] }' "$merged" > "$kv"

  fetch_node_file "$STACKS/.env" "$GEN_DIR/project.env" || : > "$GEN_DIR/project.env"
  local resolved="$GEN_DIR/resolved.env"
  resolve_dollar "$kv" "$merged" "$GEN_DIR/project.env" > "$resolved"

  # Volume-path rewrite (dashboard reads the mmdb the gateway's F5
  # bootstrap stages at $PREFIX/shared/geo): container-only paths do
  # not exist bare — rewrite ONLY when the key is present.
  local final="$GEN_DIR/janus-dash.env"
  : > "$final"
  local key val
  # Whole-line reads, NOT `IFS='=' read`: with IFS='=' bash drops the
# trailing empty field, silently stripping a base64 '=' pad from values
# like JANUS_SECRETS_KEY=k1:...== (the py3.14 keyring then rejects it).
while read -r _line; do
  key="${_line%%=*}"
  val="${_line#*=}"
  [ -n "$key" ] || continue
    case "$key" in
      JANUS_MMDB_PATH) val="$PREFIX/shared/geo/$(basename "${val:-GeoLite2-City.mmdb}")" ;;
    esac
    printf '%s=%s\n' "$key" "$val" >> "$final"
  done < "$resolved"

  # DB endpoint rewrite — DELIBERATELY LAST (r5), SHAPE-AWARE via
  # JANUS_DB_ENV_KEYS (r6). app/config.py reads JANUS_DB_HOST /
  # JANUS_DB_PORT (discrete pair) — the inventory's key list drives
  # the rewrite, never hardcoded key names.
  local rew="$GEN_DIR/rew.env"
  : > "$rew"
  # Whole-line reads, NOT `IFS='=' read`: with IFS='=' bash drops the
# trailing empty field, silently stripping a base64 '=' pad from values
# like JANUS_SECRETS_KEY=k1:...== (the py3.14 keyring then rejects it).
while read -r _line; do
  key="${_line%%=*}"
  val="${_line#*=}"
  [ -n "$key" ] || continue
    if printf ',%s,' "$DB_ENV_KEYS" | grep -q ",$key,"; then
      case "$key" in
        *_PORT) val="$DB_PORT" ;;
        *_HOST) val="$DB_HOST" ;;
        *)
          if ! new_val="$(dsn_rewrite "$val")"; then
            die "DB key $key listed in JANUS_DB_ENV_KEYS is neither a *_HOST/*_PORT pair member nor a DSN/URL shape — fix the inventory"
          fi
          val="$new_val"
          ;;
      esac
    fi
    printf '%s=%s\n' "$key" "$val" >> "$rew"
  done < "$final"
  mv "$rew" "$final"

  # F4b: the endpoint port must be PUBLISHED by the compose deployment
  # when any DB key made it into the dash envfile (bridge container
  # IPs are unstable across recreates — never used).
  local db_seen="" k
  for k in $(printf '%s' "$DB_ENV_KEYS" | tr ',' ' '); do
    grep -qE "^${k}=" "$final" && db_seen=yes
  done
  if [ -n "$db_seen" ]; then
    # Compose file first, then the LIVE container: deployments exist
    # whose compose file omits the publish but the running container
    # has it (docker inspect PortBindings — same acceptance the janus
    # gateway switch grew). Either source satisfies F4b.
    if ! grep -E "^[[:space:]]*-[[:space:]]*[\"']?([^:]+:)?${DB_PORT}:[0-9]+" "$compose" > /dev/null; then
      # The DB stack may live outside $COMPOSE_PROJECT (separate
      # compose project per infra service). Probe the endpoint itself:
      # a live TCP dial proves the publish better than any file read.
      if run_node "bash -c '(exec 3<>/dev/tcp/${DB_HOST}/${DB_PORT})' 2>/dev/null || nc -z -w 3 ${DB_HOST} ${DB_PORT}"; then
        note "       DB port ${DB_PORT}: not in compose file, endpoint ${DB_HOST}:${DB_PORT} answers (live publish accepted)"
      else
        die "JANUS_DB_ENDPOINT port $DB_PORT is not published by any compose ports: rule (compose-network-only DB access) — add a publish rule (documented operator-approved compose change) before flipping the dashboard"
      fi
    fi
  fi
  if [ -s "$GEN_DIR/vols.txt" ]; then
    note "       dash bind mounts (context; shared dirs are provisioned by the gateway F5 bootstrap / ensure_master_mmdb.sh):"
    sed 's/^/         /' "$GEN_DIR/vols.txt"
  fi
}

# -------------------------------------------- F7: wheelhouse tag floor ---
wheelhouse_floor_check() { # <payload-dir> <node-glibc>
  local dir="$1" glibc="$2" whl base tags platforms tok floor min
  [ -n "$glibc" ] || return 0
  for whl in "$dir"/wheels/*.whl; do
    [ -e "$whl" ] || continue
    base="$(basename "$whl" .whl)"
    tags="${base##*-}"
    platforms="$(printf '%s' "$tags" | cut -d- -f3-)"
    min=""
    case "$platforms" in
      *linux_x86_64*)
        # 06b L6: the build honours this escape; the installer must too,
        # or an operator who followed the build's documented remedy gets
        # a payload this script refuses.
        if [ "${JANUS_ALLOW_BARE_LINUX_WHEELS:-0}" = 1 ]; then
          note "WARNING: $(basename "$whl") is linux_x86_64-tagged — accepted via JANUS_ALLOW_BARE_LINUX_WHEELS=1 (F7: the builder digest is the compatibility guarantee)"
        else
          die "$(basename "$whl") is linux_x86_64-tagged (unrepaired in-container build — F7); the build gate should have caught this (set JANUS_ALLOW_BARE_LINUX_WHEELS=1 only if the build did)"
        fi
        ;;
    esac
    for tok in $(printf '%s' "$platforms" | tr '.' ' '); do
      floor=""
      case "$tok" in
        manylinux_2_*)
          # 06b L9: the token carries the arch suffix
          # (manylinux_2_17_x86_64), and the old form compared
          # "2.17.x86.64" — false-failing at glibc 2.17. The arch itself
          # may contain underscores (x86_64), so take the minor up to the
          # FIRST underscore after the version marker, then normalize
          # 2_17 to 2.17 BEFORE any -V compare (a raw "2_28" sorts after
          # "2.43").
          floor="${tok#manylinux_2_}"; floor="2.${floor%%_*}" ;;
        manylinux2014*) floor="2.17" ;;
        manylinux1*) floor="2.5" ;;
      esac
      [ -n "$floor" ] || continue
      if [ -z "$min" ] || [ "$(printf '%s\n%s\n' "$min" "$floor" | sort -V | head -n1)" = "$floor" ]; then
        min="$floor"
      fi
    done
    if [ -n "$min" ]; then
      [ "$(printf '%s\n%s\n' "$min" "$glibc" | sort -V | head -n1)" = "$min" ] \
        || die "$(basename "$whl") requires glibc >= $min but node $NODE has $glibc (F7 floor)"
    fi
  done
}

# ---------------------------------------- H2: wheelhouse integrity chain ---
# The build writes wheels-manifest.txt as a `sha256sum -c` file (hash +
# bare filename). Verify the SHIPPED tree against it BEFORE pip: the
# deploy pre-ships with cp -a/tar and chowns the tree before this
# script's root pip step, so build-to-install tampering has to be
# caught here — the builder's own hash was never consumed before.
wheelhouse_manifest_check() { # <payload dir as the NODE sees it>
  local dir="$1" n_file n_man
  run_node "test -f '$dir/wheels-manifest.txt'" \
    || die "$dir/wheels-manifest.txt is missing on node $NODE — the wheelhouse cannot be integrity-checked; refusing to install an unverified payload (rebuild and re-ship)"
  run_node "cd '$dir/wheels' && sha256sum -c --strict --quiet ../wheels-manifest.txt" \
    || die "wheelhouse under $dir does not match wheels-manifest.txt on node $NODE — corrupt or tampered payload; refusing to install (rebuild and re-ship)"
  # Every file in the wheelhouse must be listed: an EXTRA wheel shadows a
  # pinned one and an unlisted sdist would be built from source by pip.
  n_file="$(run_node "find '$dir/wheels' -maxdepth 1 -type f | wc -l" | tr -d '[:space:]')"
  n_man="$(run_node "awk 'END{print NR}' '$dir/wheels-manifest.txt'" | tr -d '[:space:]')"
  [ -n "$n_file" ] && [ "$n_file" = "$n_man" ] \
    || die "wheelhouse under $dir holds ${n_file:-?} files but wheels-manifest.txt lists ${n_man:-?} — an unlisted file (pip resolves it: a shadowing wheel or an sdist); remove $dir and re-ship the payload"
  note "       wheelhouse verified against wheels-manifest.txt ($n_file files, sha256)"
}

# ---------------------------------------------- caddy gate (facts-6) -----
caddy_gate() {
  local files f hits verified=0
  # LIVE configs only: skip the historical .bak/.broken copies that
  # accumulate next to /etc/caddy/Caddyfile — caddy never loads them.
  files="$(run_node "ls '$STACKS'/Caddyfile '$STACKS'/caddy.json /etc/caddy/Caddyfile 2>/dev/null || true")"
  if [ -z "$files" ]; then
    if [ "$LOCAL" = true ]; then
      note "  [sim] caddy gate: no Caddyfile under $STACKS (simulation) — skipped"
    elif [ "$SKIP_CADDY" = true ]; then
      note "WARNING: --skip-caddy-gate — no Caddyfile under $STACKS; the operator verified the caddy upstream by hand (facts-6)"
    else
      die "no Caddyfile found under $STACKS — cannot verify the caddy upstream still points at the compose dashboard DNS name (facts-6 verify-first). Re-point caddy at the host-reachable JANUS_DASH_PORT, or pass --skip-caddy-gate after verifying by hand"
    fi
    return 0
  fi
  for f in $files; do
    if ! fetch_node_file "$f" "$GEN_DIR/caddy.cfg"; then
      # 06b M3: a config that EXISTS but cannot be read is "cannot
      # verify", not "nothing to verify". The old `|| continue` let every
      # candidate be skipped and the gate pass having checked nothing.
      # Fail closed; the documented escape is --skip-caddy-gate.
      if [ "$LOCAL" = true ]; then
        note "  [sim] caddy gate: cannot read $f (simulation) — verification skipped"
        continue
      elif [ "$SKIP_CADDY" = true ]; then
        note "WARNING: --skip-caddy-gate — $f exists on $NODE but could not be read; the operator verified the caddy upstream by hand (facts-6)"
        continue
      else
        die "caddy config $f exists on node $NODE but could not be read — cannot verify the caddy upstream still points away from the compose dashboard DNS name (facts-6 verify-first). Fix node access, or pass --skip-caddy-gate after verifying by hand"
      fi
    fi
    verified=$((verified + 1))
    # reverse_proxy lines (+ lb `to` upstream lines) naming the compose
    # service as a bare host: once the service is disabled the DNS name
    # dies and caddy 502s.
    hits="$(grep -nE 'reverse_proxy|^[[:space:]]+to[[:space:]]' "$GEN_DIR/caddy.cfg" | grep -w "$DASH_SERVICE" || true)"
    if [ -n "$hits" ]; then
      die "caddy ($f) still proxies to the compose DNS name '$DASH_SERVICE': $(printf '%s' "$hits" | head -2). Once the service is disabled that name stops resolving — re-point the upstream at the host-reachable JANUS_DASH_PORT ($DASH_PORT) first (facts-6 verify-first gate)"
    fi
    note "       caddy: $f — no upstream names $DASH_SERVICE"
  done
  if [ "$verified" -eq 0 ]; then
    if [ "$LOCAL" = true ]; then
      note "  [sim] caddy gate: no readable Caddyfile under $STACKS (simulation) — skipped"
    elif [ "$SKIP_CADDY" = true ]; then
      note "WARNING: --skip-caddy-gate — caddy config(s) found ($files) but none could be read; the operator verified the upstream by hand (facts-6)"
    else
      die "caddy config(s) found under $STACKS ($files) but none could be read on node $NODE — cannot verify the upstream (facts-6 verify-first). Fix node access, or pass --skip-caddy-gate after verifying by hand"
    fi
  fi
}

# ------------------------------------------- unit render + probes --------
render_unit() { # -> $GEN_DIR/janus-dash.service
  local tpl="$ROOT/deploy/janus-dash.service.template"
  [ -f "$tpl" ] || die "missing $tpl"
  local pg_probe
  pg_probe="ExecStartPre=/bin/bash -c 'until (exec 3<>/dev/tcp/$DB_HOST/$DB_PORT) 2>/dev/null; do sleep 2; done'"
  sed -e "s#__JANUS_BARE_USER__#${BARE_USER}#g" \
      -e "s#__JANUS_BARE_PREFIX__#${PREFIX}#g" \
      -e "s#__DASH_PORT__#${DASH_PORT}#g" \
      -e "s#__PG_PROBE__#${pg_probe}#" \
      "$tpl" > "$GEN_DIR/janus-dash.service"
}

dash_container_name() {
  run_node "docker ps -a --filter label=com.docker.compose.service=$DASH_SERVICE --filter label=com.docker.compose.project=$COMPOSE_PROJECT --format '{{.Names}}' | head -n1"
}
dash_running() {
  [ "$(run_node "docker inspect -f '{{.State.Running}}' '$1'" 2>/dev/null)" = true ]
}

# ------------------------------------------------------------ plan -------
print_plan() {
  note "================ INSTALL PLAN ================"
  note "node                : $NODE (alias=$ALIAS role=$ROLE stacks=$STACKS py3=$PY3)"
  note "payload             : ${PAYLOAD:-<none>} -> $PREFIX/dash/${SH:-<sha>}"
  note "venv                : $PREFIX/dash/${SH:-<sha>}/venv (python$PY3, --no-index from wheels/)"
  note "envfile             : $ENVFILE (root:$BARE_USER 0640; DB rewrite -> $DB_ENDPOINT via [$DB_ENV_KEYS], LAST)"
  note "unit                : $UNIT_DST (uvicorn 0.0.0.0:$DASH_PORT, pg-probe $DB_ENDPOINT)"
  note "compose dash service: $DASH_SERVICE (project $COMPOSE_PROJECT) — stopped only after the payload is proven"
  if [ -f "${GEN_DIR:-}/janus-dash.env" ]; then
    note "generated envfile keys (values redacted):"
    cut -d= -f1 "$GEN_DIR/janus-dash.env" | sed 's/^/    /'
  fi
  note "================================================"
}

# ============================================================== main =====
note "install_bare_dashboard: node=$NODE (leader) py3=$PY3$([ "$DRY_RUN" = true ] && printf ' (dry-run)')$([ "$LOCAL" = true ] && printf ' (local simulation)')"

note "[1/9] F2 env generation + ALL validation (pre-mutation)"
gen_envfile
render_unit

note "[2/9] F7 wheelhouse tag floor vs node glibc"
NODE_GLIBC=""
if [ "$LOCAL" != true ]; then
  NODE_GLIBC="$(run_node "ldd --version 2>/dev/null | head -n1" | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
  [ -n "$NODE_GLIBC" ] && note "       node glibc: $NODE_GLIBC"
fi
if [ -n "$PAYLOAD" ] && [ -n "$NODE_GLIBC" ]; then
  wheelhouse_floor_check "$PAYLOAD" "$NODE_GLIBC"
  note "       wheelhouse manylinux floors ok"
elif [ "$LOCAL" = true ]; then
  note "  [sim] tag floor skipped (local simulation is not the target runtime)"
elif [ -n "$PAYLOAD" ] && [ "$DRY_RUN" != true ]; then
  die "no glibc reading from node $NODE (ldd --version output not parseable) — the F7 manylinux floor gate cannot run against this payload; refusing to install it unverified"
else
  note "       tag floor skipped (no payload — --allow-no-payload refresh-only run, or dry-run)"
fi

note "[3/9] caddy upstream verify-first gate (facts-6)"
caddy_gate

if [ "$DRY_RUN" = true ]; then
  # Plan-only path: the probe is a read; nothing is shipped or stopped.
  note "[4/9] dual-bind guard: port $DASH_PORT free + compose dashboard container"
  DASH_CTR="$(dash_container_name)"
  if [ -n "$DASH_CTR" ]; then
    if dash_running "$DASH_CTR"; then
      note "       DRY-RUN: would capture restart policy, docker update --restart=no, stop $DASH_CTR (verified), record $STATE_FILE"
    else
      note "       compose dashboard $DASH_CTR already stopped"
    fi
  else
    note "       no compose dashboard container (project $COMPOSE_PROJECT) — docker side already gone"
  fi
  print_plan
  note "dry-run complete: no writes, no stops, no starts. Steps 4-9 would execute in order."
  exit 0
fi

# 06b M2: ship + prove the payload BEFORE the destructive compose stop.
# The stop used to sit above these steps, so a failed transfer or pip
# install aborted with the only dashboard already down and its restart
# policy overwritten — no payload gate could prevent that ordering.
note "[4/9] shipping payload -> $PREFIX/dash/$SH"
run_node "mkdir -p '$PREFIX/dash/$SH'"
if [ -n "$PAYLOAD" ]; then
  # COPYFILE_DISABLE=1 (bsdtar/macOS): keep AppleDouble ._* metadata
  # sidecars out of the stream — they shadow the wheels-manifest.txt
  # count and fail the [5/9] H2 integrity check.
  if [ "$LOCAL" = true ]; then
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' COPYFILE_DISABLE=1 tar -cz -C "$PAYLOAD" . \
      | MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' tar -xz -C "$PREFIX/dash/$SH"
  else
    # M7: ConnectTimeout bounds the handshake, ServerAlive* a dead link
    # mid-transfer — a stalled ship must not block the deploy forever.
    COPYFILE_DISABLE=1 tar -cz -C "$PAYLOAD" . | ssh -o BatchMode=yes -o ConnectTimeout=10 \
      -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$ALIAS" "tar -xzf - -C '$PREFIX/dash/$SH'"
  fi
  # Defense in depth: any ._* that slipped through must not survive —
  # the wheelhouse file count gates the install.
  run_node "find '$PREFIX/dash/$SH' -name '._*' -delete"
fi

note "[5/9] wheelhouse integrity + venv (python$PY3, --no-index from wheels/ — F5b zero egress)"
# H2: no install step runs against an unverified wheelhouse — verify the
# SHIPPED tree first (covers the --allow-no-payload refresh path too).
wheelhouse_manifest_check "$PREFIX/dash/$SH"
VENV="$PREFIX/dash/$SH/venv"
VVER="$(run_node "'$VENV/bin/python' -V 2>&1" || true)"
if [ "$(run_node "test -x '$VENV/bin/python' && echo yes" || true)" = yes ] \
   && case "$VVER" in "Python $PY3"*) true ;; *) false ;; esac; then
  note "       venv exists for this sha ($VVER) — refreshing packages"
else
  run_node "python$PY3 -m venv '$VENV'"
fi
run_node "'$VENV/bin/pip' install --no-index --find-links '$PREFIX/dash/$SH/wheels/' janus-dashboard setuptools wheel"

note "[6/9] envfile install"
run_node "mkdir -p '$PREFIX/env' '$PREFIX/dash'"
write_node "$ENVFILE" "$GEN_DIR/janus-dash.env" 0640
if run_node "chown root:$BARE_USER '$ENVFILE'"; then
  :
elif [ "$LOCAL" = true ]; then
  note "  [sim] chown root:$BARE_USER skipped (local simulation)"
else
  die "chown root:$BARE_USER $ENVFILE failed"
fi
# Ownership: the payload tree + venv must be service-user readable —
# but $PREFIX/env stays ROOT-owned (never -R over it: F2 keeps the
# envfile root:<user> 0640 so the service user cannot replace its own
# env, and a user-owned env DIR would allow unlink+recreate).
if run_node "chown -R '$BARE_USER:$BARE_USER' '$PREFIX/dash' 2>/dev/null"; then
  note "       ownership -> $BARE_USER ($PREFIX/dash only; \$PREFIX/env stays root)"
elif [ "$LOCAL" = true ]; then
  note "  [sim] chown $BARE_USER skipped (local simulation)"
else
  die "chown -R $BARE_USER $PREFIX/dash failed on node $NODE"
fi

note "[7/9] dual-bind guard + compose dashboard stop (destructive — payload proven above)"
DASH_CTR="$(dash_container_name)"
ORIG_RESTART=""
write_switch_state() { # the rollback record: write it BEFORE any mutation
  {
    echo "node=$NODE"
    echo "sha=$SH"
    echo "dash_container=${DASH_CTR:-}"
    echo "restart_original=${ORIG_RESTART:-}"
    echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$GEN_DIR/switch-state.env"
  write_node "$STATE_FILE" "$GEN_DIR/switch-state.env"
}
if [ -n "$DASH_CTR" ]; then
  # Captured even when the container is stopped: the old flow only did
  # this while running and persisted it three steps later, so any abort
  # in between lost the restart policy.
  ORIG_RESTART="$(run_node "docker inspect -f '{{.HostConfig.RestartPolicy.Name}}{{if .HostConfig.RestartPolicy.MaximumRetryCount}}:{{.HostConfig.RestartPolicy.MaximumRetryCount}}{{end}}' '$DASH_CTR'")"
  write_switch_state
  if dash_running "$DASH_CTR"; then
    note "       stopping compose dashboard $DASH_CTR (F1 discipline: restart captured -> --restart=no -> stop verified)"
    run_node "docker update --restart=no '$DASH_CTR'"
    run_node "docker stop '$DASH_CTR'" > /dev/null
    for _ in $(seq 1 30); do
      dash_running "$DASH_CTR" || break
      sleep 2
    done
    dash_running "$DASH_CTR" && die "container $DASH_CTR still running after stop (dual-bind unverified)"
    note "       stopped (verified; original restart policy: $ORIG_RESTART -> $STATE_FILE)"
  else
    note "       compose dashboard $DASH_CTR already stopped"
  fi
else
  note "       no compose dashboard container (project $COMPOSE_PROJECT) — docker side already gone"
  write_switch_state
fi
# Re-install cutover: on an already-bare node the previous run's OWN unit
# holds $DASH_PORT. Step 9 restarts janus-dash onto the new tree, so
# stopping it here is the same brief cutover, not a second dashboard.
if [ "$LOCAL" != true ] && run_node "systemctl list-unit-files 2>/dev/null | grep -q '^janus-dash.service'" && run_node "systemctl is-active --quiet janus-dash"; then
  note "       bare janus-dash active from a previous install — stopping for cutover (step 9 restarts it)"
  run_node "systemctl stop janus-dash"
fi
if [ "$LOCAL" != true ]; then
  # 06b M1: the old filter was `sport = : $DASH_PORT` — iproute2 rejects the
  # space after the colon with a bison syntax error (exit 255, empty stdout),
  # so behind 2>/dev/null | grep -q . the guard could never fire and the
  # script printed "port free" regardless. The no-space form is the valid one.
  if run_node "ss -H -ltn 'sport = :$DASH_PORT' 2>/dev/null | grep -q ."; then
    die "port $DASH_PORT is still listening after the compose dashboard stop — refusing to dual-bind (identify the listener: ss -H -ltnp 'sport = :$DASH_PORT')"
  fi
  note "       port $DASH_PORT free"
fi

note "[8/9] unit install + daemon-reload + enable"
if [ "$LOCAL" = true ] && [ "$WITH_SYSTEMD" != true ]; then
  note "  [sim] install $UNIT_DST + daemon-reload + enable janus-dash (print-only; --with-systemd executes)"
  note "  [sim] rendered unit: $GEN_DIR/janus-dash.service (temp dir cleaned on exit)"
else
  write_node "$UNIT_DST" "$GEN_DIR/janus-dash.service"
  sysctl_cmd "daemon-reload"
  sysctl_cmd "enable janus-dash"
fi
run_node "ln -sfn '$PREFIX/dash/$SH' '$PREFIX/dash/current'"
note "       current -> $SH"

note "[9/9] start + assertions"
sysctl_cmd "restart janus-dash"
if [ "$LOCAL" = true ] && [ "$WITH_SYSTEMD" != true ]; then
  note "  [sim] print-only start — live assertions skipped (verify_bare_dashboard.sh proves the payload; the real node asserts below)"
else
  sysctl_cmd "is-active janus-dash" > /dev/null
  body=""
  for _ in $(seq 1 60); do
    # M7: a hung health endpoint must not stall the loop forever.
    body="$(run_node "curl -fsS --connect-timeout 3 --max-time 10 http://127.0.0.1:$DASH_PORT/api/health 2>/dev/null" || true)"
    [ -n "$body" ] && break
    sleep 2
  done
  [ -n "$body" ] || die "/api/health never answered on 127.0.0.1:$DASH_PORT (journalctl -u janus-dash -n 50)"
  printf '%s' "$body" | grep -q '"status": *"ok"' || die "/api/health answered without status=ok: $body"
  note "       /api/health ok: $body"
fi

note "INSTALL COMPLETE: node $NODE runs the bare dashboard ($SH, uvicorn 0.0.0.0:$DASH_PORT)"
note "rollback: docker start ${DASH_CTR:-<captured in $STATE_FILE>} (restore its restart policy from $STATE_FILE), systemctl disable --now janus-dash, set JANUS_DASH_BARE=false — returning to the docker path is its own fresh redeploy, not a flip"
