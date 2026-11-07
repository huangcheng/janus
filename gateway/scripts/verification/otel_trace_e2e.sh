#!/usr/bin/env bash
# E2E: assert the W3C Trace Context contract over a real socket.
#
# Boots janus_core + janus_http on SQLite (the documented local path),
# drives the agent face with curl, and checks the headers a caller
# actually receives. This is the end-to-end proof for the trace work:
# the EUnit suite pins the pure functions, this pins the wire behaviour.
#
# Usage:  ./scripts/verification/otel_trace_e2e.sh
#         OUT=/some/dir ./scripts/verification/otel_trace_e2e.sh
#
# Artifacts (server log, per-case output, result) land in $OUT.
set -u -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GW="$(cd "$HERE/../.." && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/janus-otel-trace-e2e}"
mkdir -p "$OUT"

for tool in erl curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not found"; exit 77; }
done
[ -d "$GW/_build/default/lib/janus_core/ebin" ] || {
  echo "SKIP: build absent — run 'rebar3 compile' in $GW first"; exit 77;
}
PORT=18080
ADMIN=18090
unset JANUS_DB_URL
unset JANUS_DB_HOST

EBINS=()
for d in "$GW"/_build/default/lib/*/ebin; do EBINS+=(-pa "$d"); done
erl -noshell "${EBINS[@]}" \
  -eval "
    application:set_env(janus, http_port, $PORT),
    application:set_env(janus, admin_port, $ADMIN),
    %% The agent listener (:18080) is master-only; pin the role so the
    %% script cannot silently start a worker and fail every case.
    application:set_env(janus, role, master),
    
    {ok,_} = application:ensure_all_started(janus_core),
    {ok,_} = application:ensure_all_started(janus_http),
    io:format(\"READY~n\"),
    timer:sleep(120000),
    halt()." > "$OUT/server.log" 2>&1 &
SRV=$!
cleanup() { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }
trap cleanup EXIT INT TERM
for i in $(seq 1 60); do grep -q READY "$OUT/server.log" 2>/dev/null && break; sleep 1; done
if ! grep -q READY "$OUT/server.log"; then echo "SERVER FAILED"; tail -20 "$OUT/server.log"; kill $SRV 2>/dev/null; exit 1; fi
sleep 2

pass=0; fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "PASS $1"; pass=$((pass+1));
  else echo "FAIL $1: expected [$2] got [$3]"; fail=$((fail+1)); fi
}
present() { if [ -n "$2" ]; then echo "PASS $1 ($2)"; pass=$((pass+1)); else echo "FAIL $1: absent"; fail=$((fail+1)); fi; }

BASE="http://127.0.0.1:$PORT"

# A1: no inbound traceparent -> both headers present, traceparent well-formed
CHAT=(-s --max-time 10 -X POST -H "content-type: application/json" -d '{"model":"m","messages":[]}')
H=$(curl -D - -o /dev/null "${CHAT[@]}" "$BASE/v1/chat/completions" 2>/dev/null || true)
TP=$(printf '%s' "$H" | tr -d '\r' | awk 'tolower($1)=="traceparent:"{print $2}')
XT=$(printf '%s' "$H" | tr -d '\r' | awk 'tolower($1)=="x-trace-id:"{print $2}')
present "A1 traceparent emitted" "$TP"
present "A1 x-trace-id emitted" "$XT"
check "A1 traceparent shape" "55" "${#TP}"
check "A1 ids agree" "$XT" "$(printf '%s' "$TP" | cut -d- -f2)"

# A2: inbound traceparent continues the trace id
IN="00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
H2=$(curl -D - -o /dev/null "${CHAT[@]}" -H "traceparent: $IN" "$BASE/v1/chat/completions")
TP2=$(printf '%s' "$H2" | tr -d '\r' | awk 'tolower($1)=="traceparent:"{print $2}')
check "A2 inbound trace continued" "4bf92f3577b34da6a3ce929d0e0e4736" "$(printf '%s' "$TP2" | cut -d- -f2)"

# A3: unsampled inbound is honoured on the response
IN0="00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00"
H3=$(curl -D - -o /dev/null "${CHAT[@]}" -H "traceparent: $IN0" "$BASE/v1/chat/completions")
TP3=$(printf '%s' "$H3" | tr -d '\r' | awk 'tolower($1)=="traceparent:"{print $2}')
check "A3 unsampled bit preserved" "00" "$(printf '%s' "$TP3" | cut -d- -f4)"

# A4: tracestate round-trips
H4=$(curl -D - -o /dev/null "${CHAT[@]}" -H "traceparent: $IN" -H "tracestate: vend=keep" "$BASE/v1/chat/completions")
TS4=$(printf '%s' "$H4" | tr -d '\r' | awk 'tolower($1)=="tracestate:"{print $2}')
check "A4 tracestate echoed" "vend=keep" "$TS4"

# A5: malformed traceparent -> fresh trace, no crash
H5=$(curl -D - -o /dev/null "${CHAT[@]}" -H "traceparent: garbage" "$BASE/v1/chat/completions")
TP5=$(printf '%s' "$H5" | tr -d '\r' | awk 'tolower($1)=="traceparent:"{print $2}')
present "A5 malformed still responds" "$TP5"
if [ "$(printf '%s' "$TP5" | cut -d- -f2)" != "4bf92f3577b34da6a3ce929d0e0e4736" ]; then
  echo "PASS A5 trace restarted"; pass=$((pass+1))
else echo "FAIL A5 trace not restarted"; fail=$((fail+1)); fi

# A6: higher version continues the trace (the regression this fixes)
IN6="01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-future"
H6=$(curl -D - -o /dev/null "${CHAT[@]}" -H "traceparent: $IN6" "$BASE/v1/chat/completions")
TP6=$(printf '%s' "$H6" | tr -d '\r' | awk 'tolower($1)=="traceparent:"{print $2}')
check "A6 version-01 trace continued" "4bf92f3577b34da6a3ce929d0e0e4736" "$(printf '%s' "$TP6" | cut -d- -f2)"


# A8: log/trace correlation. The request's log line must carry the SAME
# trace id the response advertises, so a log can be pivoted to a trace.
# This is the whole point of the log-context work and no unit test can
# prove it: it only holds if the logger metadata reaches the formatter
# on a real Cowboy handler process.
A8TID="00-aaaabbbbccccddddeeeeffff00001111-00f067aa0ba902b7-01"
H8=$(curl -D - -o /dev/null "${CHAT[@]}" -H "traceparent: $A8TID" "$BASE/v1/chat/completions")
sleep 1
if grep -q "trace_id=aaaabbbbccccddddeeeeffff00001111" "$OUT/server.log"; then
  echo "PASS A8 log line carries the request trace id"; pass=$((pass+1))
else
  echo "FAIL A8 no log line carried the request trace id"; fail=$((fail+1))
fi

# A9: a line logged with no active request (boot) must NOT claim an id.
if grep -E "^[0-9T:.\-]+Z (info|warn|error) " "$OUT/server.log" | grep -qv "trace_id="; then
  echo "PASS A9 lines outside a request carry no trace id"; pass=$((pass+1))
else
  echo "FAIL A9 every line claimed a trace id"; fail=$((fail+1))
fi

# A7: tracestate without traceparent is discarded
H7=$(curl -D - -o /dev/null "${CHAT[@]}" -H "tracestate: orphan=1" "$BASE/v1/chat/completions")
TS7=$(printf '%s' "$H7" | tr -d '\r' | awk 'tolower($1)=="tracestate:"{print $2}')
check "A7 orphan tracestate dropped" "" "$TS7"

printf '%s\n' "--- $pass passed, $fail failed ---" | tee "$OUT/summary.txt"
echo "$pass passed, $fail failed" > "$OUT/result.txt"
[ "$fail" -eq 0 ] || exit 1
