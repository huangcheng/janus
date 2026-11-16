#!/usr/bin/env bash
# OCR-audit a single commit (or the working tree) and fail on critical/high.
#
# Every Janus commit must pass this gate before it lands on main / is pushed.
# Medium and low findings are printed but do not fail the gate.
#
# Usage:
#   ./scripts/verification/ocr_audit_commit.sh              # audit HEAD
#   ./scripts/verification/ocr_audit_commit.sh <sha>        # audit one commit
#   ./scripts/verification/ocr_audit_commit.sh --workspace  # staged+unstaged+untracked
#
# Environment:
#   JANUS_OCR_REQUIRED=1  — missing `ocr` CLI is a hard failure (CI sets CI=true)
#   CI=true               — same as JANUS_OCR_REQUIRED=1
#   OCR_TIMEOUT_MIN       — passed to `ocr review --timeout` (default 30)
#
# Exit codes:
#   0  clean (or soft-skipped when OCR is optional and missing)
#   1  critical/high findings, OCR failure, or required-but-missing CLI
#   2  usage / argument error
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BACKGROUND='Janus is an Erlang/OTP LLM gateway with a Python/React management plane. Iron rules: fail closed and fail loud; hot config via Postgres; master/worker soft geo zone dispatch; protocol translation only (OpenAI/Anthropic/modality); never invent token limits; repair agent histories at the door. Review for real bugs, security issues, and invariant breaks — not style nits.'

TIMEOUT_MIN="${OCR_TIMEOUT_MIN:-30}"
REQUIRED=0
if [[ "${JANUS_OCR_REQUIRED:-}" == "1" || "${CI:-}" == "true" ]]; then
  REQUIRED=1
fi

MODE="commit"
SHA="HEAD"
if [[ "${1:-}" == "--workspace" ]]; then
  MODE="workspace"
elif [[ -n "${1:-}" ]]; then
  SHA="$1"
elif [[ $# -gt 1 ]]; then
  echo "usage: $0 [<sha>|--workspace]" >&2
  exit 2
fi

if ! command -v ocr >/dev/null 2>&1; then
  if [[ "$REQUIRED" -eq 1 ]]; then
    echo "FAIL: ocr CLI not found (JANUS_OCR_REQUIRED/CI). Install: npm i -g @alibaba-group/open-code-review" >&2
    exit 1
  fi
  echo "SKIP: ocr CLI not found (set JANUS_OCR_REQUIRED=1 to enforce)" >&2
  exit 0
fi

OUT="$(mktemp -t janus-ocr-XXXXXX.json)"
trap 'rm -f "$OUT"' EXIT

OCR_ARGS=(review --audience agent --format json --timeout "$TIMEOUT_MIN"
  --background "$BACKGROUND" -o "$OUT" --repo "$REPO_ROOT")

echo "OCR audit (${MODE}${MODE:+: }${SHA})…" >&2
set +e
if [[ "$MODE" == "workspace" ]]; then
  ocr "${OCR_ARGS[@]}"
else
  ocr "${OCR_ARGS[@]}" --commit "$SHA"
fi
OCR_RC=$?
set -e

if [[ ! -s "$OUT" ]]; then
  if [[ "$OCR_RC" -ne 0 ]]; then
    echo "FAIL: ocr exited $OCR_RC with empty output" >&2
    exit 1
  fi
  echo "OK: no OCR output (empty diff / nothing to review)" >&2
  exit 0
fi

# A non-zero OCR exit with a partial JSON payload must still fail the
# gate — otherwise a timed-out/errored review that wrote zero
# critical/high comments would silently pass (ocr high).
if [[ "$OCR_RC" -ne 0 ]]; then
  echo "FAIL: ocr exited $OCR_RC (review incomplete; refusing to pass)" >&2
  exit 1
fi

# OCR may emit a bare comment array or an object with a comments field.
python3 - "$OUT" <<'PY'
import json, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    raw = f.read().strip()
if not raw:
    print("OK: empty review payload", file=sys.stderr)
    sys.exit(0)

data = json.loads(raw)
if isinstance(data, dict):
    comments = data.get("comments") or data.get("items") or data.get("results") or []
elif isinstance(data, list):
    comments = data
else:
    print(f"FAIL: unexpected OCR JSON type {type(data).__name__}", file=sys.stderr)
    sys.exit(1)

blocking = []
for c in comments:
    if not isinstance(c, dict):
        continue
    sev = (c.get("severity") or "").lower()
    if sev in ("critical", "high"):
        blocking.append(c)

medium = sum(1 for c in comments if isinstance(c, dict) and (c.get("severity") or "").lower() == "medium")
low = sum(1 for c in comments if isinstance(c, dict) and (c.get("severity") or "").lower() == "low")

print(
    f"OCR findings: {len(blocking)} critical/high · {medium} medium · {low} low · {len(comments)} total",
    file=sys.stderr,
)

if not blocking:
    print("OK: no critical/high OCR findings", file=sys.stderr)
    sys.exit(0)

for c in blocking:
    path = c.get("path") or "?"
    start = c.get("start_line")
    end = c.get("end_line")
    loc = f"{path}:{start}-{end}" if start is not None else path
    sev = (c.get("severity") or "?").upper()
    cat = c.get("category") or "?"
    body = (c.get("content") or "").strip().replace("\n", " ")
    print(f"  [{sev}/{cat}] {loc} — {body[:240]}", file=sys.stderr)

print(f"FAIL: {len(blocking)} critical/high OCR finding(s)", file=sys.stderr)
sys.exit(1)
PY
