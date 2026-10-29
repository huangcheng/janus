#!/usr/bin/env bash
# Build the bare-metal gateway release tarball (spec
# 2026-10-15-bare-metal-deploy Task 1, B-D1/B-D6/F3). ONE documented
# command:
#
#   bash scripts/build_bare_release.sh
#
# What it does:
#   1. Resolves the glibc builder image: the digest-pinned
#      JANUS_BARE_BUILDER from deploy/inventory.env when present
#      (production duty — the floor it ACTUALLY built against is
#      recorded in builder-facts-<sha>.txt and verified at switch time),
#      otherwise builds the Dockerfile `bare-builder` stage (Debian
#      glibc erlang:27; NEVER the alpine/musl stages).
#   2. Runs `rebar3 as prod release` (+ `rebar3 as prod tar` as the
#      vanilla-path proof that a tarball lands in _build/prod/rel/),
#      then swaps the relx start script: bin/janus -> bin/janus.real,
#      bin/janus.wrap -> bin/janus (the F5c wrapper renders vm.args /
#      TLS via etc/janus_vm_args.sh before exec'ing the real script).
#   3. Tars the release to bare-artifacts/gw/janus-bare-<sha>.tar.gz
#      and records builder-facts-<sha>.txt next to it (F3 provenance:
#      verify_bare.sh reads the floor from THAT
#      file, never from a hand-kept inventory claim).
#
# Provenance (06e M2/M14): the build bind-mounts the WORKING TREE, so an
# uncommitted change would compile into a release named and stamped as
# HEAD. A dirty tree under apps/, config/, scripts/ or the rebar files is
# REFUSED; JANUS_BARE_ALLOW_DIRTY=1 marks the artefact `-dirty` instead
# (filename, JANUS_GIT_SHA and tree_state= in the facts) — the switch and
# verify_bare.sh refuse such an artefact.
#
# Cache discipline: the builder runs with its OWN named volume
# (janus-bare-ebin-otp27) — NEVER janus-ebin-otp27, which holds musl
# beams from the eunit image. Recreate the volume when rebar.lock,
# rebar.config, or the OTP version changes:
#   docker volume rm janus-bare-ebin-otp27
#
# Mount discipline matches the documented eunit command: only apps/,
# config/, scripts/, and the rebar files are mounted (the image owns
# /usr/local/bin/rebar3 and the warm hex cache; the repo root is
# never bind-mounted over /app).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Windows hosts: pwd -W gives docker -v the Windows-style path it wants.
ROOT_W="$(cd "$ROOT" && pwd -W 2>/dev/null || pwd)"

VOL=janus-bare-ebin-otp27
BUILDER_TAG=janus-bare-builder:local
OUT_DIR="$ROOT/bare-artifacts/gw"

# Inventory is OPTIONAL here: its only use is the builder digest pin.
INV="${JANUS_INVENTORY:-$ROOT/deploy/inventory.env}"
if [ -f "$INV" ]; then
  # shellcheck disable=SC1090
  . "$INV"
fi

# M2/M14: never name/stamp a dirty tree as HEAD.
DIRTY=""
TREE_STATE=clean
if [ -n "$(git -C "$ROOT" status --porcelain -- apps config scripts rebar.config rebar.lock)" ]; then
  if [ "${JANUS_BARE_ALLOW_DIRTY:-0}" = 1 ]; then
    DIRTY="-dirty"
    TREE_STATE=dirty
    echo "== WARNING: dirty working tree — stamping the artefact '$DIRTY' (JANUS_BARE_ALLOW_DIRTY=1); it is NOT shippable"
  else
    echo "FAIL: working tree is dirty under apps/, config/, scripts/, rebar.config or rebar.lock — commit first (JANUS_BARE_ALLOW_DIRTY=1 builds a clearly marked, non-shippable local artefact)" >&2
    exit 1
  fi
fi

SHA="$(git -C "$ROOT" rev-parse --short HEAD)${DIRTY}"
GIT_SHA="$(git -C "$ROOT" rev-parse HEAD)${DIRTY}"
TARBALL="janus-bare-${SHA}.tar.gz"
FACTS="builder-facts-${SHA}.txt"

# --- 1. builder image (pin first, stage fallback) ------------------------
if [ -n "${JANUS_BARE_BUILDER:-}" ]; then
  RUN_IMAGE="$JANUS_BARE_BUILDER"
  echo "== builder: pinned inventory image $JANUS_BARE_BUILDER (glibc floor ${JANUS_BARE_BUILDER_GLIBC:-?}, libcrypto ${JANUS_BARE_BUILDER_LIBCRYPTO:-?})"
else
  echo "== builder: no JANUS_BARE_BUILDER pin — building the Dockerfile bare-builder stage (dev/CI convenience; production must pin)"
  build_args=()
  [ -z "${APT_MIRROR:-}" ] || build_args+=(--build-arg "APT_MIRROR=$APT_MIRROR")
  [ -z "${HEX_MIRROR:-}" ] || build_args+=(--build-arg "HEX_MIRROR=$HEX_MIRROR")
  [ -z "${HEX_CDN:-}" ] || build_args+=(--build-arg "HEX_CDN=$HEX_CDN")
  docker build --target bare-builder "${build_args[@]}" -t "$BUILDER_TAG" "$ROOT"
  RUN_IMAGE="$BUILDER_TAG"
fi

mkdir -p "$OUT_DIR"
docker volume inspect "$VOL" > /dev/null 2>&1 || docker volume create "$VOL" > /dev/null

# --- 2. release build + wrapper swap + tar (inside the builder) ----------
run_args=()
[ -z "${HEX_MIRROR:-}" ] || run_args+=(-e "HEX_MIRROR=$HEX_MIRROR")
[ -z "${HEX_CDN:-}" ] || run_args+=(-e "HEX_CDN=$HEX_CDN")
# MSYS_NO_PATHCONV/MSYS2_ARG_CONV_EXCL (scoped to this one command,
# Windows Git Bash only) keep container-absolute args like -w /app
# and vol:/app/_build from being rewritten to host paths.
# B-D6 cross-arch: production nodes are x86_64; an arm64 artefact
# built natively on Apple Silicon boots to "Exec format error" (seen
# live 2026-10-19, rolled back). Target amd64 by default. --platform is
# passed ONLY when the image's arch differs — containerd-backed daemons
# treat --platform as a pull hint and try the registry for a local
# image instead of using it.
TARGET_PLATFORM="${JANUS_BARE_PLATFORM:-linux/amd64}"
IMG_ARCH="$(docker image inspect "$RUN_IMAGE" --format '{{.Architecture}}' 2>/dev/null || echo unknown)"
WANT_ARCH="${TARGET_PLATFORM#linux/}"
if [ "$IMG_ARCH" != "$WANT_ARCH" ]; then
  run_args+=(--platform "$TARGET_PLATFORM")
fi

MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker run --rm \
  "${run_args[@]}" \
  -e JANUS_GIT_SHA="$GIT_SHA" \
  -v "$ROOT_W/apps:/app/apps" \
  -v "$ROOT_W/config:/app/config" \
  -v "$ROOT_W/scripts:/app/scripts" \
  -v "$ROOT_W/rebar.config:/app/rebar.config" \
  -v "$ROOT_W/rebar.lock:/app/rebar.lock" \
  -v "$ROOT_W/rebar3:/app/rebar3" \
  -v "$VOL:/app/_build" \
  -v "$ROOT_W/bare-artifacts/gw:/out" \
  -w /app \
  "$RUN_IMAGE" sh -eu -c '
    chmod +x rebar3
    rebar3 as prod release
    # Vanilla-path proof (B-D1): the plain relx tarball lands in
    # _build/prod/rel/ before the wrapper swap below.
    rebar3 as prod tar
    rm -f _build/prod/rel/*.tar.gz _build/prod/rel/janus/*.tar.gz
    rel=_build/prod/rel/janus
    test -x "$rel/bin/janus" || { echo "missing relx start script" >&2; exit 1; }
    # Belt-and-braces: a CRLF-carried wrapper/lib (Windows checkout
    # missing the .gitattributes eol rules) would exec-format-error
    # on the node — strip \r at build time.
    tr -d "\r" < "$rel/bin/janus.wrap" > "$rel/bin/janus.wrap.lf"
    mv "$rel/bin/janus.wrap.lf" "$rel/bin/janus.wrap"
    tr -d "\r" < "$rel/etc/janus_vm_args.sh" > "$rel/etc/janus_vm_args.sh.lf"
    mv "$rel/etc/janus_vm_args.sh.lf" "$rel/etc/janus_vm_args.sh"
    mv "$rel/bin/janus" "$rel/bin/janus.real"
    mv "$rel/bin/janus.wrap" "$rel/bin/janus"
    chmod +x "$rel/bin/janus"
    # Stamp the git sha the docker ENV used to carry (Dockerfile ARG
    # JANUS_GIT_SHA): janus_build reads os:getenv at BOOT -> persistent_term
    # -> /stats/sched git_sha, which the deploy verify_bare_node matches
    # against the shipped sha. Without this stamp every bare release
    # reports unknown and the deploy verification hard-fails.
    sed -i "1a export JANUS_GIT_SHA='"${GIT_SHA}"'" "$rel/bin/janus"
    # Bundled TLS runtime (RHEL-family OpenSSL lacks the SM4 ciphers
    # crypto.so resolves at load): resolve the sonames through ldconfig
    # instead of hardcoding x86_64-linux-gnu (L7) — an arm64/multiarch
    # builder would otherwise bundle the wrong objects or nothing at all.
    mkdir -p "$rel"/lib/compat
    for lib in libcrypto.so.3 libssl.so.3; do
      src="$(ldconfig -p | grep -E "(^|[[:space:]])$lib[[:space:]]" | head -n1 | sed -n "s/.*=> //p")"
      [ -n "$src" ] && [ -f "$src" ] || { echo "FAIL: $lib not found by ldconfig in the builder" >&2; exit 1; }
      cp -L "$src" "$rel/lib/compat/"
      [ -s "$rel/lib/compat/$lib" ] || { echo "FAIL: bundled $lib is empty" >&2; exit 1; }
    done
    tar -czf "/out/janus-bare-'"${SHA}"'.tar.gz" -C _build/prod/rel janus
    {
      echo "builder_image='"${RUN_IMAGE}"'"
      echo "git_sha='"${GIT_SHA}"'"
      echo "tree_state='"${TREE_STATE}"'"
      echo "builder_glibc=$(ldd --version | head -1 | sed -e "s/.*) //")"
      # libcrypto soname claim: the crypto NIF (crypto.so) is what
      # actually links libcrypto at runtime (beam.smp does not).
      echo "builder_libcrypto=$(ldd "$rel"/lib/crypto-*/priv/lib/crypto.so 2>/dev/null | sed -n -e "s/.*\(libcrypto\.so\.[0-9]*\).*/\1/p" | head -n1)"
      # Human-readable proof lines (the key=value lines above are what
      # verify_bare.sh parses it).
      ldd --version | head -1
      ldd "$rel"/lib/crypto-*/priv/lib/crypto.so 2>/dev/null | grep libcrypto || true
    } > "/out/builder-facts-'"${SHA}"'.txt"
  '

# --- 3. host-side assertions ---------------------------------------------
t="$OUT_DIR/$TARBALL"
[ -f "$t" ] || { echo "FAIL: $t not produced" >&2; exit 1; }
# Materialize the listing once: piping tar into an early-exiting grep
# under pipefail turns the member check into a spurious SIGPIPE 141.
list="$OUT_DIR/.tarlist-$SHA.txt"
tar -tzf "$t" > "$list"
for member in janus/bin/janus janus/bin/janus.real janus/etc/janus_vm_args.sh \
              janus/lib/compat/libcrypto.so.3 janus/lib/compat/libssl.so.3 \
              janus/releases/0.1.0/vm.args; do
  grep -qx "$member" "$list" || { echo "FAIL: tarball missing $member" >&2; exit 1; }
done
rm -f "$list"

# Provenance self-check (M2/M14): the facts file the switch will consume
# must exist, parse, and describe THIS artefact.
f="$OUT_DIR/$FACTS"
[ -s "$f" ] || { echo "FAIL: $f not produced" >&2; exit 1; }
grep -qE "^git_sha='?[0-9a-f]{7,}" "$f" || { echo "FAIL: $f has no git_sha" >&2; exit 1; }
grep -qE "^tree_state='?(clean|dirty)" "$f" || { echo "FAIL: $f has no tree_state" >&2; exit 1; }
grep -qE "^builder_glibc=[0-9]+\.[0-9]+" "$f" || { echo "FAIL: $f has no builder_glibc" >&2; exit 1; }
grep -qE "^builder_libcrypto=libcrypto\.so\.[0-9]+" "$f" || { echo "FAIL: $f has no builder_libcrypto" >&2; exit 1; }
# Materialize the wrapper before grep (pipefail + early-exiting grep =
# spurious SIGPIPE 141, the same trap the member check above avoids).
wrapper="$OUT_DIR/.wrapper-$SHA.txt"
tar -xzOf "$t" janus/bin/janus > "$wrapper"
# Quote-agnostic: the sed stamp has always emitted the sha UNQUOTED
# (the '"${GIT_SHA}"' breakout in the blob loses its single quotes to
# bash string delimiting — valid shell, env value identical); the check
# below originally grepped only the quoted form and failed every real
# build. Match either form.
grep -qE "JANUS_GIT_SHA='?${GIT_SHA}'?" "$wrapper" \
  || { echo "FAIL: janus/bin/janus is not stamped with $GIT_SHA" >&2; rm -f "$wrapper"; exit 1; }
rm -f "$wrapper"
[ -z "$DIRTY" ] || echo "== WARNING: DIRTY-TREE artefact $TARBALL — not shippable (verify_bare.sh refuses it)"

echo "== artifacts in $OUT_DIR:"
ls -l "$OUT_DIR"
echo "== facts:"
cat "$OUT_DIR/$FACTS"
echo "== OK: $TARBALL (wrapper at janus/bin/janus, real start script at janus/bin/janus.real, renderer at janus/etc/janus_vm_args.sh)"
echo "== provenance: $FACTS (git_sha=$GIT_SHA tree=$TREE_STATE) — ship it BESIDE the tarball: verify_bare.sh requires it"
