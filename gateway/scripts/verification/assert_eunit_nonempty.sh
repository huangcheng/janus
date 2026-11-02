#!/usr/bin/env bash
# Fail unless EUnit actually executed tests.
#
# Why this exists: `rebar3 eunit` exits 0 when a project has no tests at all,
# and it exits 0 for an application with an empty suite. A green CI job is
# therefore not evidence that anything ran. This script makes "zero tests" and
# "unparseable output" hard failures.
#
# Contract:
#   * exit nonzero if the eunit command itself exits nonzero
#   * exit nonzero if any summary line reports failures
#   * exit nonzero if no `All N tests passed.` / `N tests, 0 failures`
#     summary is present
#   * exit nonzero if any parsed count is zero or unparseable
#   * exit nonzero if the summed executed-test count is zero
#
# Usage:
#   ./assert_eunit_nonempty.sh                  # run rebar3 eunit
#   ./assert_eunit_nonempty.sh --from FILE      # parse an existing log
#
# The --from form exists so CI can keep the raw log as an artifact while the
# assertion logic stays in one place (and so the parser itself can be tested
# without a build).
set -uo pipefail

# Resolve the application root from THIS script's location. `rebar3 eunit`
# looks for rebar.config in the cwd, so invoking the script from the repo
# root or from its own directory would fail with a misleading
# "'rebar3 eunit' exited 1" instead of running the tests.
APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

EUNIT_CMD=(rebar3 eunit)
LOG=""

if [[ "${1:-}" == "--from" ]]; then
  LOG="${2:?--from needs a file}"
  [[ -r "$LOG" ]] || { echo "FAIL: cannot read $LOG" >&2; exit 2; }
else
  LOG="$(mktemp -t janus-eunit-XXXXXX)"
  trap 'rm -f "$LOG"' EXIT
  (cd "$APP_ROOT" && "${EUNIT_CMD[@]}") >"$LOG" 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "FAIL: '${EUNIT_CMD[*]}' exited $rc" >&2
    tail -40 "$LOG" >&2
    exit 1
  fi
fi

python3 - "$LOG" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8", errors="replace").read()

# SUMMARY FORMATS, all observed in real runs:
#   success (rebar3):  All 179 tests passed.
#   failure (rebar3):  179 tests, 2 failures
#   failure (eunit):   Failed: 1.  Skipped: 0.  Passed: 4.
# Multi-application runs emit one summary per application, so counts must be
# SUMMED, not maxed — otherwise a second app's suite is invisible.
#
# The third form matters for `--from`, where there is no exit code to consult:
# parsing only `N tests, M failures` would read a raw-EUnit failure log as
# zero failures and exit OK — the exact false green this wrapper prevents.
passed_re = re.compile(r"All (\d+) tests passed\.")
failed_re = re.compile(r"(\d+) tests, (\d+) failures")
passed = [int(m) for m in passed_re.findall(text)]
totals = [(int(t), int(f)) for t, f in failed_re.findall(text)]

# Raw-EUnit summaries are paired PER LINE, not by two whole-file passes: a
# positional zip of independent findall results would mis-attribute counts
# when one line carries only one of the two fields, and `zip` silently
# truncates to the shorter list — dropping exactly the zero-passed
# application this guard exists to catch.
eunit_line_re = re.compile(r"\bFailed:\s*(\d+)\..*?\bPassed:\s*(\d+)\.")
eunit_partial_re = re.compile(r"\b(?:Failed|Passed):\s*\d+\.")
for m in eunit_line_re.finditer(text):
    totals.append((int(m.group(2)), int(m.group(1))))  # (passed, failed)

# Fail closed, PER LINE: a line carrying a count without a complete
# Failed:/Passed: pair means the output was truncated or shaped unexpectedly,
# and guessing which count belongs to which application is how a failing suite
# turns green. Checking per line (not "any partial anywhere") is what makes
# this robust when good and bad lines are mixed.
for line in text.splitlines():
    if eunit_partial_re.search(line) and not eunit_line_re.search(line):
        print("FAIL: incomplete EUnit summary line: " + line.strip(), file=sys.stderr)
        print("      Refusing to guess which count belongs to which application.", file=sys.stderr)
        sys.exit(1)

if not passed and not totals:
    print("FAIL: no EUnit summary found in the log.", file=sys.stderr)
    print("      A bare exit 0 is not evidence that tests ran.", file=sys.stderr)
    sys.exit(1)

failures = sum(f for _, f in totals)
if failures:
    print(f"FAIL: {failures} test(s) failed.", file=sys.stderr)
    sys.exit(1)

executed = sum(passed) + sum(t for t, _ in totals)
# eunit_passed was folded into totals above; do not count it twice.
if executed == 0:
    print("FAIL: EUnit executed zero tests.", file=sys.stderr)
    sys.exit(1)

# A suite that reports 0 is a discovery bug, not a pass. Check BOTH summary
# shapes: a `0 tests, 0 failures` application is otherwise masked whenever
# another application contributed a positive count, which is exactly the
# per-application discovery regression this gate exists to catch.
zero_suites = [p for p in passed if p == 0] + [t for t, _ in totals if t == 0]
if zero_suites:
    print("FAIL: a suite reported 0 tests; check discovery.", file=sys.stderr)
    sys.exit(1)

print(f"OK: {executed} tests executed, 0 failures "
      f"({len(passed)} passing summaries, {len(totals)} counted summaries).")
PY
