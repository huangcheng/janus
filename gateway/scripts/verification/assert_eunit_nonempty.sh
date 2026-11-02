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
eunit_failed_re = re.compile(r"Failed:\s*(\d+)\.")
eunit_passed_re = re.compile(r"Passed:\s*(\d+)\.")
eunit_skipped_re = re.compile(r"Skipped:\s*(\d+)\.")

passed = [int(m) for m in passed_re.findall(text)]
totals = [(int(t), int(f)) for t, f in failed_re.findall(text)]
eunit_failed = [int(m) for m in eunit_failed_re.findall(text)]
eunit_passed = [int(m) for m in eunit_passed_re.findall(text)]
eunit_skipped = [int(m) for m in eunit_skipped_re.findall(text)]

# A raw-EUnit summary is per-application too, and its `Passed:` count is real
# executed work (`Skipped:` is NOT). Keep ONE tuple per occurrence: collapsing
# them into a single sum would hide an application that passed zero tests
# behind another that passed several, which is the per-application discovery
# regression the zero-count guard below is meant to catch.
totals = totals + list(zip(eunit_passed, eunit_failed))

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
