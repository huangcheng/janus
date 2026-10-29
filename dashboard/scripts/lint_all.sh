#!/usr/bin/env bash
# Static checks for every language this repo uses (AGENTS.md
# "Verification"): lint / typecheck / syntax only — NO tests.
# Zero extra dependencies beyond what the repos already need
# (`pip install -e ".[dev]"` for ruff, node for the SPA).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PY="${PYTHON:-}"
if [ -z "$PY" ]; then
  if [ -x ./.venv/Scripts/python.exe ]; then PY=./.venv/Scripts/python.exe
  elif [ -x ./.venv/bin/python ]; then PY=./.venv/bin/python
  else PY=python3
  fi
fi
rc=0
fail() { echo "FAIL  $*"; rc=1; }
ok()   { echo "ok    $*"; }

echo "== Python (ruff check + format) =="
if "$PY" -m ruff --version >/dev/null 2>&1; then
  "$PY" -m ruff check app/ scripts/ tools/ && ok "ruff check" || fail "ruff check"
  "$PY" -m ruff format --check app/ scripts/ tools/ >/dev/null \
    && ok "ruff format --check" || fail "ruff format --check (run: ruff format app/ scripts/ tools/)"
else
  fail "ruff not installed — pip install -e \".[dev]\""
fi

echo "== TypeScript (tsc typecheck) + SPA build =="
if [ -d spa/node_modules ]; then
  # Some branches define a separate `typecheck` script and keep `build`
  # build-only — run it when present so the type gate is never skipped.
  (cd spa && npm run typecheck --if-present >/dev/null 2>&1) \
    && ok "spa npm run typecheck" || fail "spa npm run typecheck"
  (cd spa && npm run build >/dev/null 2>&1) && ok "spa npm run build (vite; also compiles CSS/Tailwind + JSON)" \
    || fail "spa npm run build"
else
  fail "spa/node_modules missing — cd spa && npm install"
fi

echo "== Shell (bash -n) =="
sh_fail=0
for f in scripts/*.sh scripts/ci/*.sh; do
  [ -f "$f" ] || continue
  bash -n "$f" || { fail "bash -n $f"; sh_fail=1; }
done
[ "$sh_fail" -eq 0 ] && ok "all scripts/*.sh + scripts/ci/*.sh parse"

echo "== Dockerfile (docker build --check) =="
if docker build --check . >/dev/null 2>&1; then
  ok "docker build --check"
else
  # Older daemons lack --check; only warn — the deploy builds anyway.
  echo "warn  docker build --check unavailable/failed"
fi

echo "== TOML / JSON syntax =="
"$PY" - <<'PY' && ok "pyproject.toml parses" || fail "pyproject.toml"
import sys, tomllib
with open("pyproject.toml", "rb") as f:
    tomllib.load(f)
PY
"$PY" - <<'PY' && ok "spa tsconfig/package JSON parse" || fail "spa JSON"
import json, pathlib, re, sys
# tsconfig files may carry // comments (JSONC) — strip them before parsing.
for p in ["spa/package.json", "spa/tsconfig.json", "spa/tsconfig.node.json"]:
    if pathlib.Path(p).exists():
        text = re.sub(r"^\s*//.*$", "", pathlib.Path(p).read_text(encoding="utf-8"), flags=re.MULTILINE)
        json.loads(text)
PY

echo "== Erlang (gateway ../janus) =="
if [ -d ../janus ] && command -v rebar3 >/dev/null 2>&1; then
  (cd ../janus && rebar3 compile >/dev/null 2>&1) && ok "janus rebar3 compile" || fail "janus rebar3 compile"
else
  echo "skip  ../janus or rebar3 not present"
fi

echo "== Markdown / CSS formatting (optional, no gate) =="
echo "      npx prettier --check '**/*.{md,css,json}' if adopted later"

exit "$rc"
