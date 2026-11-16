#!/usr/bin/env bash
# Fail (or warn) when source files exceed the OCR-scannable line budget.
#
# Soft warn:  > 2500 lines
# Hard fail:  > 4000 lines  (OCR `too_large` territory — must split)
#
# Usage:
#   ./scripts/verification/assert_source_line_budget.sh
#   ./scripts/verification/assert_source_line_budget.sh --warn-only
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

WARN_LINES=2500
FAIL_LINES=4000
WARN_ONLY=0
if [[ "${1:-}" == "--warn-only" ]]; then
  WARN_ONLY=1
fi

# Temporary hard-fail exemptions for giants scheduled as later peels
# (after janus_http_proxy). Each path is repo-relative. Remove an entry
# when that module is split under FAIL_LINES.
ALLOWLIST_FILE="$REPO_ROOT/scripts/verification/line_budget_allowlist.txt"

is_allowlisted() {
  local rel="$1"
  [[ -f "$ALLOWLIST_FILE" ]] || return 1
  grep -qxF "$rel" "$ALLOWLIST_FILE"
}

WARNED=0
FAILED=0
SCANNED=0
DEFERRED=0

# Application source only — skip tests, migrations, generated, lockfiles.
# Portable (no mapfile): macOS ships Bash 3.2.
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  SCANNED=$((SCANNED + 1))
  lines=$(wc -l <"$f" | tr -d ' ')
  if [ "$lines" -gt "$FAIL_LINES" ]; then
    if is_allowlisted "$f"; then
      echo "DEFER: $f has $lines lines (allowlisted later peel)" >&2
      DEFERRED=$((DEFERRED + 1))
    else
      echo "FAIL: $f has $lines lines (budget $FAIL_LINES — split for OCR)" >&2
      FAILED=$((FAILED + 1))
    fi
  elif [ "$lines" -gt "$WARN_LINES" ]; then
    echo "WARN: $f has $lines lines (soft budget $WARN_LINES)" >&2
    WARNED=$((WARNED + 1))
  fi
done <<EOF
$(find gateway/apps dashboard/app \
  \( -name '*.erl' -o -name '*.py' \) \
  ! -path '*/test/*' \
  ! -path '*/tests/*' \
  ! -name '*_tests.erl' \
  ! -path '*/migrations/*' \
  ! -path '*/.venv/*' \
  ! -path '*/node_modules/*' \
  -print | sort)
EOF

echo "Source line budget: $SCANNED files scanned · $WARNED warn · $DEFERRED deferred · $FAILED over hard limit" >&2

if [ "$FAILED" -gt 0 ] && [ "$WARN_ONLY" -eq 0 ]; then
  exit 1
fi
exit 0
