#!/usr/bin/env bash
# verify_bare (spec 2026-10-15-bare-metal-deploy B-D8, gateway half):
# boots the bare release tarball in ONE throwaway glibc container on
# the build host against a THROWAWAY sqlite DB — no prod secret ever
# leaves the fleet (the REAL chat assertion is the prod read-only
# smoke against the bare node before the next flip, not this).
#
# Assertions:
#   1. crypto/ssl eval smoke: `bin/janus eval` THROUGH the F5c
#      wrapper ensures crypto+ssl actually STARTED on the running
#      node — loading the crypto NIF and the TLS stack; `versions`
#      alone proves nothing (F3). (This relx's `eval` pings the node
#      first, so the smoke runs post-boot; the hidden-node eval
#      connection also exercises epmd + cookie.)
#   2. the wrapper really rendered vm.args: the file is compared against
#      the EXACT configuration janus_vm_args.sh emits for this
#      container's env (M16) — a default `-name janus@127.0.0.1` from
#      the shipped config/vm.args can never satisfy it.
#   3. healthz 200 on the agent plane.
#   4. one sqlite-backed catalog read: /v1/models with the seeded
#      agent key lists the seeded model.
#   5. the admin plane's /stats/sched with the configured token:
#      git_sha equals the builder facts' git_sha (provenance) and the
#      workers key is present — the surface the switch's own exit
#      assertion depends on (06e L5).
#
# Provenance (06e M2/M14): builder-facts-<sha>.txt MUST ship beside the
# tarball. A missing facts file, a tarball/facts sha mismatch, a `-dirty`
# name or tree_state=dirty is refused before a container is started.
#
# Usage: bash scripts/verify_bare.sh [tarball]
#   tarball defaults to the newest bare-artifacts/gw/janus-bare-*.tar.gz
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARBALL="${1:-}"
if [ -z "$TARBALL" ]; then
  TARBALL="$(ls -t "$ROOT"/bare-artifacts/gw/janus-bare-*.tar.gz 2>/dev/null | head -n 1 || true)"
fi
[ -n "$TARBALL" ] && [ -f "$TARBALL" ] || { echo "FAIL: no tarball (run scripts/build_bare_release.sh first)" >&2; exit 1; }
TARBALL_DIR="$(cd "$(dirname "$TARBALL")" && pwd)"
TARBALL_W="$(cd "$(dirname "$TARBALL")" && pwd -W 2>/dev/null || pwd)/$(basename "$TARBALL")"
TARBALL_SHA="$(basename "$TARBALL" .tar.gz | sed 's/^janus-bare-//')"

# --- provenance (M2/M14): mandatory, not decorative ---------------------
FACTS="$TARBALL_DIR/builder-facts-$TARBALL_SHA.txt"
facts_get() { sed -n "s/^$2=//p" "$1" | head -n1 | tr -d "'\""; }
case "$TARBALL_SHA" in
  *-dirty) echo "FAIL: $(basename "$TARBALL") was built from a DIRTY tree — rebuild from a clean commit" >&2; exit 1 ;;
esac
[ -f "$FACTS" ] || { echo "FAIL: missing builder facts $FACTS (provenance is not optional — rebuild with scripts/build_bare_release.sh)" >&2; exit 1; }
FACT_SHA="$(facts_get "$FACTS" git_sha)"
FACT_TREE="$(facts_get "$FACTS" tree_state)"
FACT_IMAGE="$(facts_get "$FACTS" builder_image)"
FACT_GLIBC="$(facts_get "$FACTS" builder_glibc)"
[ -n "$FACT_SHA" ] || { echo "FAIL: $FACTS has no git_sha" >&2; exit 1; }
case "$FACT_SHA" in
  "$TARBALL_SHA"*) : ;;
  *) echo "FAIL: $FACTS records git_sha=$FACT_SHA but the tarball is $(basename "$TARBALL")" >&2; exit 1 ;;
esac
case "$FACT_TREE" in
  ""|clean) : ;;
  *) echo "FAIL: $FACTS records tree_state=$FACT_TREE — a dirty-tree artefact must never ship" >&2; exit 1 ;;
esac
# The stamped wrapper is the in-artefact copy of the facts' commit.
wrapper="$(mktemp)"
tar -xzOf "$TARBALL" janus/bin/janus > "$wrapper"
FACT_STAMP="$(sed -n "s/^export JANUS_GIT_SHA='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$wrapper")"
rm -f "$wrapper"
[ "$FACT_STAMP" = "$FACT_SHA" ] \
  || { echo "FAIL: janus/bin/janus is stamped '${FACT_STAMP:-<none>}', facts say $FACT_SHA — tarball and facts do not belong together" >&2; exit 1; }
echo "== provenance: $(basename "$FACTS") git_sha=$FACT_SHA tree=${FACT_TREE:-clean} glibc=${FACT_GLIBC:-?}"

INV="${JANUS_INVENTORY:-$ROOT/deploy/inventory.env}"
if [ -f "$INV" ]; then
  # shellcheck disable=SC1090
  . "$INV"
fi
# Same runtime floor class as the builder (glibc Debian + libcrypto 3):
# the facts' recorded builder image, unless the inventory pins one.
if [ -n "${JANUS_BARE_BUILDER:-}" ]; then
  VERIFY_IMAGE="$JANUS_BARE_BUILDER"
else
  VERIFY_IMAGE="${FACT_IMAGE:-erlang:27}"
fi

# M16: a container-resolvable but DISTINCTIVE node name + a fixed cookie
# make the rendered vm.args differ from the shipped default on -name,
# -setcookie and the %% comment lines.
VERIFY_NODE_NAME="janus@localhost"
VERIFY_COOKIE="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

AGENT_KEY="sk-verify-agent-key"
CTR="janus-verify-bare-$$"
cleanup() { docker rm -f "$CTR" > /dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== verify_bare: $(basename "$TARBALL") in $VERIFY_IMAGE (throwaway sqlite)"
# MSYS_* guards: Windows Git Bash path rewriting for container paths.
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker run -d --name "$CTR" \
  -p 127.0.0.1::8080 -p 127.0.0.1::8090 \
  -e JANUS_SQLITE_PATH=/verify/janus.db \
  -e JANUS_SEED_PATH=/verify/seed.json \
  -e JANUS_AUTO_SEED=1 \
  -e JANUS_API_KEY_PEPPER=verify-bare-pepper \
  -e JANUS_SECRETS_KEY="v1:$(head -c 32 /dev/urandom | base64 | tr -d '\n')" \
  -e JANUS_STATS_TOKEN=change-me-verify-token \
  -e JANUS_NODE_NAME="$VERIFY_NODE_NAME" \
  -e JANUS_ERLANG_COOKIE="$VERIFY_COOKIE" \
  -v "$TARBALL_W:/tmp/janus-bare.tar.gz:ro" \
  "$VERIFY_IMAGE" sh -eu -c '
    mkdir -p /opt/janus /var/lib/janus /verify
    tar -xzf /tmp/janus-bare.tar.gz -C /opt
    cat > /verify/seed.json <<"SEED"
{"providers":[{"name":"verify-prov","base_url":"https://verify.invalid","protocol":"openai_chat","keys":["sk-verify-provider-key"],"models":["verify-model-a","verify-model-b"]}],"agent_api_key":"'"$AGENT_KEY"'"}
SEED
    exec /opt/janus/bin/janus foreground
  ' > /dev/null

# Give the container a moment, then surface early exits (eval smoke
# failure exits the container with code 9 before the listener boots).
sleep 2
if [ "$(docker inspect -f '{{.State.Running}}' "$CTR")" != "true" ]; then
  echo "FAIL: container exited early"; docker logs "$CTR" 2>&1 | tail -30; exit 1
fi
echo "eval-smoke: container still up (smoke passed inside boot)"

AGENT_PORT="$(docker port "$CTR" 8080/tcp | head -n1 | sed 's/.*://')"
ADMIN_PORT="$(docker port "$CTR" 8090/tcp | head -n1 | sed 's/.*://')"
echo "== agent plane host port: $AGENT_PORT (admin: $ADMIN_PORT)"

healthz=""
for _ in $(seq 1 90); do
  if body="$(curl -fsS -m 5 "http://127.0.0.1:$AGENT_PORT/healthz" 2>/dev/null)"; then
    healthz="$body"; break
  fi
  sleep 1
done
if [ -z "$healthz" ]; then
  echo "FAIL: healthz never green"; docker logs "$CTR" 2>&1 | tail -40; exit 1
fi
echo "healthz: $healthz"

# 1. crypto/ssl eval smoke through the wrapper against the RUNNING
#    node (loads the crypto NIF + TLS stack; also proves cookie +
#    epmd + loopback dist via the hidden eval node).
smoke="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker exec "$CTR" /opt/janus/bin/janus eval 'case {application:ensure_all_started(crypto), application:ensure_all_started(ssl)} of {{ok,_},{ok,_}} -> crypto_ssl_ok; E -> io:format("~p~n", [E]), exit(1) end.' 2>&1 || true)"
if printf '%s' "$smoke" | grep -q crypto_ssl_ok; then
  echo "eval-smoke: crypto+ssl started ($smoke)"
else
  echo "FAIL: crypto/ssl eval smoke"; printf '%s\n' "$smoke"; docker logs "$CTR" 2>&1 | tail -20; exit 1
fi

# 2. wrapper render evidence (M16): vm.args must be EXACTLY what
#    janus_vm_args.sh renders for the env this container was started
#    with. The release's shipped config/vm.args (`-name janus@127.0.0.1`
#    plus %% comments, no -setcookie) can never satisfy this.
EXPECTED_VM_ARGS="-name $VERIFY_NODE_NAME
-setcookie $VERIFY_COOKIE
+K true
-A 64"
rendered="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker exec "$CTR" sh -c 'cat /opt/janus/releases/*/vm.args' 2>/dev/null || true)"
if [ "$rendered" = "$EXPECTED_VM_ARGS" ]; then
  echo "vm.args: wrapper rendered the expected configuration (-name $VERIFY_NODE_NAME, -setcookie, +K/-A)"
else
  echo "FAIL: vm.args is not the expected rendered configuration"
  printf '%s\n' "--- expected ---" "$EXPECTED_VM_ARGS" "--- actual ---" "$rendered"
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker logs "$CTR" 2>&1 | tail -20
  exit 1
fi

# 4. sqlite-backed catalog read via /v1/models with the seeded agent key.
models="$(curl -fsS -m 10 -H "Authorization: Bearer $AGENT_KEY" "http://127.0.0.1:$AGENT_PORT/v1/models")"
if printf '%s' "$models" | grep -q 'verify-model-a'; then
  echo "catalog: /v1/models lists seeded verify-model-a (sqlite-backed read)"
else
  echo "FAIL: /v1/models missing seeded model"; printf '%s\n' "$models" | head -5; exit 1
fi

# 5. admin plane the switch's exit assertion relies on (L5): the token
#    only proves something when the listener actually serves it, and the
#    reported git_sha must be the commit the facts (and the tarball) name.
sched="$(curl -fsS -m 5 -H "Authorization: Bearer ${JANUS_STATS_TOKEN}" \
  "http://127.0.0.1:$ADMIN_PORT/stats/sched" 2>/dev/null || true)"
sha_re="\"git_sha\"[[:space:]]*:[[:space:]]*\"$FACT_SHA\""
if printf '%s' "$sched" | grep -qE "$sha_re" && printf '%s' "$sched" | grep -q '"workers"'; then
  echo "admin: /stats/sched 200, git_sha=$FACT_SHA (matches the facts) + workers"
else
  echo "FAIL: /stats/sched not served, or git_sha != $FACT_SHA / workers missing"
  printf '%s\n' "$sched" | head -5
  exit 1
fi

echo "== verify_bare OK: healthz + crypto/ssl + rendered vm.args + sqlite catalog + /stats/sched all green"
