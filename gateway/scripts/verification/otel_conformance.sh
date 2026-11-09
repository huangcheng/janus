#!/usr/bin/env bash
# Conformance gate for the OpenTelemetry work (design doc §13.2).
#
# Each check pins something the per-request E2E scripts cannot see: that a
# rule holds across ALL families/fields, not just the one a request
# happened to exercise. A rule only ever asserted on one example rots
# silently the first time a new example is added without it.
#
# Usage:  ./scripts/verification/otel_conformance.sh
#
# Exit 77 when the environment cannot run it (no toolchain / no build).
set -u -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GW="$(cd "$HERE/../.." && pwd)"

command -v erl >/dev/null 2>&1 || { echo "SKIP: erl not found"; exit 77; }
[ -d "$GW/_build/default/lib/janus_http/ebin" ] || {
  echo "SKIP: build absent - run 'rebar3 compile' in $GW first"; exit 77
}

EBINS=(); for d in "$GW"/_build/default/lib/*/ebin; do EBINS+=(-pa "$d"); done

# Run from a scratch directory: booting an application may create files
# (SQLite), and a gate must not leave anything in the working tree.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
cd "$SCRATCH"
pass=0; fail=0

# Run one check: the erl program prints exactly one PASS/FAIL line.
# stderr is captured separately and surfaced only on failure, so a crash
# cannot be mistaken for a passing check by matching on stdout alone.
check() {
  local label="$1" prog="$2" out rc err
  err="$(mktemp)"
  out=$(erl -noshell "${EBINS[@]}" -eval "$prog" 2>"$err")
  rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    fail=$((fail+1))
    printf '  FAIL %s: erl exited %s\n' "$label" "$rc"
    head -5 "$err" | sed 's/^/  stderr: /'
    rm -f "$err"
    return
  fi
  rm -f "$err"
  case "$(printf '%s' "$out" | grep -E '^(PASS|FAIL)' | tail -1)" in
    PASS*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)) ;;
  esac
}

# C1 — every registered family declares a unit, and no unit is orphaned.
#
# Both directions matter: a family without a unit exports with no `unit'
# field (a consumer reads that as "unknown scale"), and a unit entry left
# behind after a family is deleted is a stale claim that the next reader
# will trust.
check "unit coverage" '
  Fam = janus_metrics_render:family_names(),
  Un = janus_metrics_render:units(),
  Missing = [N || N <- Fam, not maps:is_key(N, Un)],
  Orphan = [N || N <- maps:keys(Un), not lists:member(N, Fam)],
  Bogus = [N || {N, U} <- maps:to_list(Un), not is_binary(U) orelse byte_size(U) =:= 0],
  case {Missing, Orphan, Bogus} of
    {[], [], []} ->
      io:format("PASS every family declares a unit and no unit is orphaned (~p families)~n", [length(Fam)]);
    _ ->
      io:format("FAIL unit coverage: missing=~p orphaned=~p empty=~p~n", [Missing, Orphan, Bogus])
  end,
  halt().'

# C2 — a unit string must be UCUM, not prose. The specific mistake this
# blocks is `seconds'/'milliseconds'/'bytes': they look right and are wrong
# for OTLP, which specifies UCUM (`s', `ms', `By').
check "units are UCUM" '
  Un = janus_metrics_render:units(),
  Prose = [<<"seconds">>, <<"milliseconds">>, <<"microseconds">>, <<"nanoseconds">>,
           <<"bytes">>, <<"count">>, <<"counts">>, <<"percent">>, <<"percentage">>,
           <<"ratio">>],
  Bad = lists:usort([U || {_N, U} <- maps:to_list(Un), lists:member(U, Prose)]),
  case Bad of
    [] -> io:format("PASS units are UCUM, not prose~n");
    _ -> io:format("FAIL non-UCUM units: ~p~n", [Bad])
  end,
  halt().'

# C3 — the HELP unit suffix is OPT-IN. With the knob off no unit may
# appear; with it on, at least the unit of the family exercised here must.
# That is enough to catch the suffix leaking in unconditionally, which is
# the failure mode this gate exists for; C1 already proves every family
# HAS a unit, so per-unit rendering is not re-proven here.
check "help text respects the knob" '
  application:set_env(janus, sqlite_path, os:getenv("CONF_DB", "janus_conf.db")),
  ok = janus_metrics:init(),
  janus_metrics:inc(requests_total, #{endpoint => chat, protocol => openai_chat, status_class => <<"2xx">>}),
  os:putenv("JANUS_METRICS_HELP_UNITS", "0"),
  Plain = binary_to_list(janus_metrics_render:render(janus_metrics:snapshot(), [])),
  os:putenv("JANUS_METRICS_HELP_UNITS", "1"),
  WithUnit = binary_to_list(janus_metrics_render:render(janus_metrics:snapshot(), [])),
  OffHas = string:find(Plain, "(unit:") =/= nomatch,
  OnHas = string:find(WithUnit, "(unit: {request})") =/= nomatch,
  case {OffHas, OnHas} of
    {false, true} -> io:format("PASS HELP units are opt-in and complete when enabled~n");
    {true, _} -> io:format("FAIL unit suffix leaked into the default output~n");
    {_, false} -> io:format("FAIL unit suffix missing when the knob is on~n")
  end,
  halt().'

echo "--- $pass passed, $fail failed ---"
[ "$fail" -eq 0 ]
