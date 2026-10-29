#!/usr/bin/env bash
# build_bare_dashboard.sh — build the bare-metal DASHBOARD payload
# (spec 2026-10-15-bare-metal-deploy Task 2: B-D3 + F5b/F7 wheelhouse).
# ONE documented command:
#
#   bash scripts/build_bare_dashboard.sh
#
# Output: bare-artifacts/dash/dash-<git-sha>/ — the rsync payload
#
#   app/                  backend source (runtime import comes from
#                         here via WorkingDirectory, not site-packages)
#   spa/dist/             SPA, built ONCE (node-independent, B-D6)
#   docs/schemas/         config-backup JSON Schema — the app resolves
#                         it from Path(__file__).parent.parent/docs/
#                         schemas/ and REFUSES TO BOOT without it (the
#                         container image ships the same file; the
#                         spec's B-D3 payload list omits it — recorded
#                         as a deviation in the Task 2 report)
#   pyproject.toml        project metadata (the by-name own wheel is
#                         built from it, F7)
#   wheels/               wheelhouse for EVERY distinct target minor
#   wheels-manifest.txt   `sha256sum -c` format: sha256 + bare filename
#                         per wheel. install_bare_dashboard.sh verifies
#                         the SHIPPED wheelhouse against it before any
#                         pip step (H2 integrity chain)
#   BUILD-FACTS.txt       git sha, builder image + glibc per minor,
#                         py_minors covered (install-side cross-check)
#
# INVENTORY CONTRACT (spec §0 — ONE canonical file: the JANUS repo's
# deploy/inventory.env, whose committed EXAMPLE template is
# deploy/inventory.env.example THERE; do not keep a second copy here.
# Resolution order (Task 3 consolidation): $JANUS_INVENTORY, then
# ../janus/deploy/inventory.env (canonical), then deploy/inventory.env
# here as a LEGACY fallback only):
#   JANUS_NODE_<NAME>     ...;py3=<X.Y>;...  — the set of DISTINCT
#                         py3 minors across all nodes defines the
#                         wheelhouse builds (deduped, built once each)
#   JANUS_PY_BUILDER_<PY3>  digest-pinned python:<py3>@sha256:<64 hex>
#                         builder image for the minor (3.11 ->
#                         JANUS_PY_BUILDER_3_11). F7/H2: a floating
#                         python tag is the same failure class as the
#                         unpinned >= dependency ranges below —
#                         production MUST pin a digest, so the build
#                         DIES on any image reference without an
#                         @sha256: digest. That includes the floating
#                         python:<X.Y> fallback used when the key is
#                         missing or still the all-zero EXAMPLE
#                         placeholder. JANUS_ALLOW_UNPINNED_BUILDER=1 is
#                         the documented dev/CI override (the fallback
#                         stays available for local work); a payload
#                         built that way records the non-digest builder
#                         in BUILD-FACTS.txt and must never be shipped.
#                         The pinned digest is then the sole
#                         compatibility guarantee.
#
# WHEELHOUSE / auditwheel reality (F7, honest note):
#   `pip wheel` in the pinned linux/amd64 builder resolves BINARY
#   wheels from the index — pydantic-core / cryptography / asyncpg /
#   uvloop / httptools class deps publish manylinux wheels, and those
#   are simply copied (already glibc-floor-tagged by their upstream
#   build). An sdist that has to be built IN the container would land
#   `linux_x86_64`-tagged (links against the builder's glibc — exactly
#   the F7 failure). Handling: the builder detects linux-tagged wheels
#   and attempts `auditwheel repair` (auditwheel is NOT in python
#   images and its patchelf dependency is not pip-installable — the
#   attempt is best-effort and will normally NOT succeed); any
#   surviving linux_x86_64-tagged wheel FAILS the build unless
#   JANUS_ALLOW_BARE_LINUX_WHEELS=1 is set (operator accepts that the
#   pinned builder digest is the compatibility guarantee). The
#   node-side install additionally verifies every wheel's manylinux
#   floor <= the node's glibc (F3 floor check mirrored, F7) and the
#   shipped wheelhouse against wheels-manifest.txt (H2).
#
# PINNING STATUS (H2, honest note): the builder image (digest) and the
# wheelhouse-by-hash are now pinned — but the DEPENDENCY SET is not:
# pyproject.toml carries `>=` ranges and `pip wheel` resolves them from
# PIP_INDEX_URL at build time, because no hashed lock file is committed
# yet. A tampered/changed index still lands in the wheelhouse (the
# manifest records what landed, it cannot vouch for provenance). Fixing
# that needs `pip-compile --generate-hashes` (or `uv lock`) plus
# `--require-hashes`, which needs network at lock time — tracked as a
# follow-up, deliberately NOT attempted here.
#
# Options:
#   --py3 <X.Y>     add a target minor (repeatable; unioned with the
#                   inventory's per-node py3 values)
#   --spa-host-node build the SPA with the HOST node instead of the
#                   node:22-alpine container (fast path; the container
#                   build matches the shipped image exactly)
#   --skip-spa      reuse an existing spa/dist (iteration convenience)
#   --inventory <file>  override the inventory file
#
# Egress: builders need the pip index (and npm registry for the SPA);
# pass PIP_INDEX_URL / PIP_EXTRA_INDEX_URL / NPM_CONFIG_REGISTRY
# through the environment — the NODE install never needs egress (F5b:
# it installs --no-index from the shipped wheels/).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "build_bare_dashboard: FAIL: $*" >&2; exit 1; }
note() { echo "== $*"; }

# ---------------------------------------------------------------- args ---
EXTRA_PY3=() SPA_HOST_NODE=false SKIP_SPA=false INV_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --py3) EXTRA_PY3+=("${2:?}"); shift ;;
    --spa-host-node) SPA_HOST_NODE=true ;;
    --skip-spa) SKIP_SPA=true ;;
    --inventory) INV_OVERRIDE="${2:?}"; shift ;;
    -h|--help) sed -n '2,/^set -euo pipefail/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

# ------------------------------------------------------------ inventory ---
INV="${INV_OVERRIDE:-${JANUS_INVENTORY:-}}"
if [ -z "$INV" ]; then
  for cand in "$ROOT/../janus/deploy/inventory.env" "$ROOT/deploy/inventory.env"; do
    [ -f "$cand" ] && INV="$cand" && break
  done
fi
INVENTORY_MINORS=()
if [ -n "$INV" ] && [ -f "$INV" ]; then
  note "inventory: $INV"
  # shellcheck disable=SC1090
  . "$INV"
  # py3=X.Y from every JANUS_NODE_<NAME> (ADDR_ vars carry no fields)
  for var in $(grep -oE '^(export )?JANUS_NODE_[A-Za-z0-9]+=' "$INV" | sed 's/^export //; s/=$//' | grep -v '^JANUS_NODE_ADDR_'); do
    v="${!var:-}"
    py="$(printf '%s' "$v" | tr ';' '\n' | grep -m1 '^py3=' | sed 's/^py3=//')"
    [ -n "$py" ] && INVENTORY_MINORS+=("$py")
  done
else
  note "inventory: none found (build-side optional; target minors come ONLY from --py3)"
fi

# distinct minors, sorted
ALL_MINORS="$(printf '%s\n' "${INVENTORY_MINORS[@]}" "${EXTRA_PY3[@]}" 2>/dev/null | sort -u | grep -E '^[0-9]+\.[0-9]+$' || true)"
[ -n "$ALL_MINORS" ] || die "no target py3 minors (populate JANUS_NODE_* py3= in the inventory, or pass --py3 X.Y)"
note "target minors (deduped): $(echo "$ALL_MINORS" | tr '\n' ' ')"

# ----------------------------------------------------------- git / out ---
SHA="$(git -C "$ROOT" rev-parse --short HEAD)"
OUT="$ROOT/bare-artifacts/dash/dash-$SHA"
rm -rf "$OUT"
mkdir -p "$OUT/wheels"

# ------------------------------------------------------------- 1. SPA ----
if [ "$SKIP_SPA" = true ]; then
  [ -f "$ROOT/spa/dist/index.html" ] || die "--skip-spa but spa/dist/index.html missing"
  note "SPA: reusing existing spa/dist"
else
  note "SPA: building (once — node-independent, B-D6)"
  if [ "$SPA_HOST_NODE" = true ]; then
    ( cd "$ROOT/spa" && npm ci --no-audit --no-fund || npm install --no-audit --no-fund )
    ( cd "$ROOT/spa" && npm run build )
  else
    SPA_VOL=janus-dash-spa-build
    docker volume inspect "$SPA_VOL" > /dev/null 2>&1 || docker volume create "$SPA_VOL" > /dev/null
    NPM_ENV=()
    [ -z "${NPM_CONFIG_REGISTRY:-}" ] || NPM_ENV+=(-e "NPM_CONFIG_REGISTRY=$NPM_CONFIG_REGISTRY")
    # Bind-mount pattern (same discipline as the janus repo's build
    # scripts — binary stdin pipes into docker run -i are NOT reliable
    # on Windows hosts): spa/ mounted at /spa, a named volume shadows
    # node_modules (keeps the npm cache warm across builds), dist
    # lands back on the host via the bind mount.
    SPA_W="$(cd "$ROOT/spa" && pwd -W 2>/dev/null || pwd)"
    # shellcheck disable=SC2030,SC2031
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker run --rm \
      "${NPM_ENV[@]}" \
      -v "$SPA_W:/spa" \
      -v "$SPA_VOL:/spa/node_modules" \
      -w /spa \
      node:22-alpine sh -eu -c '
        npm ci --no-audit --no-fund || npm install --no-audit --no-fund
        npm run build
        test -f dist/index.html
      '
    # The container writes dist as root; hand the tree back to the
    # invoking user or the NEXT checkout's rm -rf fails on the runner
    # (self-hosted runners run unprivileged; live failure 2026-10-16).
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker run --rm       -v "$SPA_W:/spa" node:22-alpine sh -eu -c       "chown -R $(id -u):$(id -g) /spa/dist"
    rm -rf "$OUT/spa"
    mkdir -p "$OUT/spa"
    cp -a "$ROOT/spa/dist" "$OUT/spa/dist"
  fi
fi
[ -f "$OUT/spa/dist/index.html" ] || die "SPA build produced no spa/dist/index.html"

# ----------------------------------------------------- 2. stage payload ---
note "staging payload tree"
mkdir -p "$OUT/docs"
cp -a "$ROOT/app" "$OUT/app"
cp -a "$ROOT/docs/schemas" "$OUT/docs/schemas"
cp "$ROOT/pyproject.toml" "$OUT/pyproject.toml"
[ -f "$OUT/docs/schemas/config-backup-v1.schema.json" ] \
  || die "docs/schemas/config-backup-v1.schema.json missing — the app refuses to boot without it"
# No __pycache__ / caches in the shipped tree.
find "$OUT/app" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "$OUT/app" -name '*.pyc' -delete 2>/dev/null || true

# ------------------------------------------------ 3. wheelhouse per minor --
PIP_ENV=()
[ -z "${PIP_INDEX_URL:-}" ] || PIP_ENV+=(-e "PIP_INDEX_URL=$PIP_INDEX_URL")
[ -z "${PIP_EXTRA_INDEX_URL:-}" ] || PIP_ENV+=(-e "PIP_EXTRA_INDEX_URL=$PIP_EXTRA_INDEX_URL")

OUT_W="$(cd "$OUT" && pwd -W 2>/dev/null || pwd)"

# H2: a release build refuses a mutable builder tag. F7 says the pinned
# digest is the compatibility guarantee — so the image reference MUST
# carry one; JANUS_ALLOW_UNPINNED_BUILDER=1 is the documented dev/CI
# override and keeps the floating fallback reachable for local work.
JANUS_ALLOW_UNPINNED_BUILDER="${JANUS_ALLOW_UNPINNED_BUILDER:-0}"
builder_image_for() { # <py-minor> -> stdout: the image reference to use
  local minor="$1" key pin b
  key="JANUS_PY_BUILDER_$(printf '%s' "$minor" | tr '.' '_')"
  pin="${!key:-}"
  b=""
  if [ -n "$pin" ] && ! printf '%s' "$pin" | grep -qE 'sha256:0+$'; then
    b="$pin"
  else
    b="python:$minor"
  fi
  if printf '%s' "$b" | grep -qE '@sha256:[0-9a-f]{64}$' \
     || [ "$JANUS_ALLOW_UNPINNED_BUILDER" = 1 ]; then
    printf '%s' "$b"
    return 0
  fi
  die "builder for py$minor ('$b') is not digest-pinned — set $key=python:$minor@sha256:<64 hex> (F7/H2: a mutable builder tag is the same failure class as the unpinned >= dependency ranges). JANUS_ALLOW_UNPINNED_BUILDER=1 accepts that guarantee explicitly for dev/CI builds; never ship the payload it produces"
}

for MINOR in $ALL_MINORS; do
  KEY="JANUS_PY_BUILDER_$(printf '%s' "$MINOR" | tr '.' '_')"
  BUILDER="$(builder_image_for "$MINOR")"
  case "$BUILDER" in
    *@sha256:*) note "wheelhouse [$MINOR]: pinned builder $BUILDER" ;;
    *) note "wheelhouse [$MINOR]: WARNING — builder $BUILDER is NOT digest-pinned (accepted via JANUS_ALLOW_UNPINNED_BUILDER=1; dev/CI only, pin $KEY instead — do not ship this payload, F7)" ;;
  esac
  # shellcheck disable=SC2030,SC2031
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker run --rm --platform linux/amd64 \
    "${PIP_ENV[@]}" \
    -v "$OUT_W:/payload" \
    "$BUILDER" sh -eu -c '
      echo "builder python: $(python -V 2>&1), glibc: $(ldd --version | head -1)"
      # Build from a COPY: pip wheel on a directory can drop build/
      # + egg-info next to the source — never into the shipped payload.
      mkdir -p /tmp/proj
      cp -a /payload/pyproject.toml /payload/app /tmp/proj/
      pip wheel --wheel-dir /payload/wheels /tmp/proj
      # F7 belt-and-braces: setuptools+wheel ride in the wheelhouse
      # (fresh >=3.12 venvs ship neither; the by-name own-wheel
      # install must not need build isolation).
      pip wheel --wheel-dir /payload/wheels setuptools wheel
      if ls /payload/wheels/*-linux_x86_64.whl > /dev/null 2>&1; then
        echo "wheelhouse: linux_x86_64-tagged wheel(s) present — attempting auditwheel repair" >&2
        command -v auditwheel > /dev/null 2>&1 || pip install --quiet auditwheel > /dev/null 2>&1 || true
        if command -v auditwheel > /dev/null 2>&1; then
          mkdir -p /repaired
          for w in /payload/wheels/*-linux_x86_64.whl; do
            auditwheel repair --no-update-tags -w /repaired "$w" && rm -f "$w"
          done
          cp /repaired/*.whl /payload/wheels/ 2> /dev/null || true
        else
          echo "wheelhouse: auditwheel unavailable in builder" >&2
        fi
      fi
    ' || die "wheelhouse build failed for minor $MINOR (builder $BUILDER)"
  # Belt-and-braces: nothing but the payload members may ride along.
  rm -rf "$OUT/build" "$OUT"/janus_dashboard.egg-info
done

# --------------------------------------- 4. platform-tag gate + manifest --
note "wheelhouse platform-tag scan"
BAD=""
while IFS= read -r whl; do
  base="$(basename "$whl" .whl)"
  tags="${base##*-}"           # py-abi-platform field (no build tags produced here)
  case "$tags" in
    *linux_x86_64*) BAD="$BAD $(basename "$whl")" ;;
  esac
done < <(find "$OUT/wheels" -name '*.whl' | sort)
if [ -n "$BAD" ]; then
  if [ "${JANUS_ALLOW_BARE_LINUX_WHEELS:-0}" = 1 ]; then
    note "WARNING: linux_x86_64-tagged wheels accepted via JANUS_ALLOW_BARE_LINUX_WHEELS=1:$BAD — the pinned builder digest is the compatibility guarantee (F7)"
  else
    die "linux_x86_64-tagged wheel(s) in the wheelhouse:$BAD — auditwheel could not repair them (no patchelf in the builder); pin JANUS_PY_BUILDER_<PY3> to a digest whose glibc floor <= every target node, or set JANUS_ALLOW_BARE_LINUX_WHEELS=1 to accept that guarantee explicitly"
  fi
fi

# BUILD-FACTS with per-minor builder + the wheel manifest.
{
  echo "git_sha=$(git -C "$ROOT" rev-parse HEAD)"
  echo "git_short=$SHA"
  printf 'py_minors='; echo "$ALL_MINORS" | tr '\n' ' '; echo
  for MINOR in $ALL_MINORS; do
    B="$(builder_image_for "$MINOR")"
    case "$B" in
      *@sha256:*) echo "builder_$MINOR=$B" ;;
      *) echo "builder_$MINOR=$B (NOT digest-pinned — JANUS_ALLOW_UNPINNED_BUILDER=1 was set, F7; do not ship)" ;;
    esac
  done
  echo "built_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/BUILD-FACTS.txt"

# H2: a REAL `sha256sum -c` manifest — sha256 + bare filename, written
# from inside wheels/ so it verifies in place (install_bare_dashboard.sh
# runs `cd wheels && sha256sum -c ../wheels-manifest.txt` before pip).
: > "$OUT/wheels-manifest.txt"
while IFS= read -r whl; do
  ( cd "$OUT/wheels" && sha256sum "$(basename "$whl")" ) >> "$OUT/wheels-manifest.txt"
done < <(find "$OUT/wheels" -name '*.whl' | sort)
[ -s "$OUT/wheels-manifest.txt" ] || die "wheelhouse manifest is empty — no wheel landed in $OUT/wheels"
# Round-trip it HERE: a manifest that does not verify must never reach a
# node (the installer fails closed on it, which would block the deploy).
( cd "$OUT/wheels" && sha256sum -c --strict --quiet ../wheels-manifest.txt ) \
  || die "wheels-manifest.txt does not verify against the wheelhouse — refusing to ship $OUT"

# --------------------------------------------------- 5. final assertions --
ls "$OUT"/wheels/janus_dashboard-*.whl > /dev/null 2>&1 \
  || die "own wheel missing: pip wheel did not produce janus_dashboard-*.whl"
ls "$OUT"/wheels/setuptools-*.whl "$OUT"/wheels/wheel-*.whl > /dev/null 2>&1 \
  || die "setuptools/wheel missing from the wheelhouse (F7 belt-and-braces)"
for MINOR in $ALL_MINORS; do
  # asyncpg is the cp-tagged canary dep: one wheel per target minor.
  n="$(find "$OUT/wheels" -name "asyncpg-*cp$(printf '%s' "$MINOR" | tr -d .)*.whl" | wc -l)"
  [ "$n" -gt 0 ] || die "no cp$(printf '%s' "$MINOR" | tr -d .) asyncpg wheel in the wheelhouse — minor $MINOR not actually covered"
done

note "payload ready: $OUT"
ls -la "$OUT"
note "facts:"
cat "$OUT/BUILD-FACTS.txt"
note "OK: dash payload dash-$SHA ($(find "$OUT/wheels" -name '*.whl' | wc -l) wheels, minors: $(echo "$ALL_MINORS" | tr '\n' ' '))"
