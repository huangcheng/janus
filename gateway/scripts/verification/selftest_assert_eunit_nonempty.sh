#!/usr/bin/env bash
# Parser proofs for assert_eunit_nonempty.sh.
#
# The gate exists because `rebar3 eunit` exits 0 when nothing ran. That makes
# the PARSER the safety-critical part, so it is tested against real summary
# shapes rather than trusted. Each case below is a format actually emitted by
# rebar3 or EUnit.
#
# Run: ./selftest_assert_eunit_nonempty.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/assert_eunit_nonempty.sh"
TMP="$(mktemp -d -t janus-gate-selftest-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() {
  local name="$1" want="$2" body="$3"
  printf '%s' "$body" >"$TMP/case.log"
  "$GATE" --from "$TMP/case.log" >"$TMP/out" 2>&1
  local got=$?
  if [[ "$got" == "$want" ]]; then
    printf 'ok    %-46s exit=%s\n' "$name" "$got"
  else
    printf 'FAIL  %-46s exit=%s want=%s\n' "$name" "$got" "$want"
    sed 's/^/        /' "$TMP/out"
    fails=$((fails + 1))
  fi
}

# 1. No summary at all: a green run that proved nothing must be refused.
check "no summary" 1 '===> Performing EUnit tests...
'

# 2. Multi-application success sums (3 + 4 = 7), not maxes.
check "multi-app success sums" 0 'app1: All 3 tests passed.
app2: All 4 tests passed.
'

# 3. rebar3 failure summary.
check "rebar3 failure summary" 1 'All 5 tests passed.
5 tests, 2 failures
'

# 4. Raw EUnit failure summary (no rebar3 line). Without this shape the
#    parser would read a failing log as zero failures.
check "eunit failure summary" 1 'app1: All 10 tests passed.
app2: Failed: 1.  Skipped: 0.  Passed: 4.
'

# 5. A zero-count suite means discovery broke, even when another app passed.
check "zero-count suite via All" 1 'app1: All 5 tests passed.
app2: All 0 tests passed.
'
check "zero-count suite via totals" 1 'app1: All 5 tests passed.
app2: 0 tests, 0 failures
'

# 6. Skipped-only run executed nothing.
check "only skipped, nothing passed" 1 'Failed: 0.  Skipped: 3.  Passed: 0.
'

# 7. A raw-EUnit application that passed NOTHING must not hide behind another
#    that passed several. Collapsing the per-application counts into one sum
#    would make this green.
check "eunit zero-passed app among passing apps" 1 'app1: Failed: 0.  Skipped: 0.  Passed: 4.
app2: Failed: 0.  Skipped: 0.  Passed: 0.
'

# 8. A plain passing run is accepted.
check "single app success" 0 'All 179 tests passed.
'

echo
if [[ "$fails" -ne 0 ]]; then
  echo "FAILED: $fails parser case(s)"
  exit 1
fi
echo "all parser proofs passed"
