#!/usr/bin/env bash
# E2E: assert that a real request produces a conformant OTLP trace.
#
# This is the end-to-end proof for the span work. It boots the gateway on
# SQLite, points one seeded provider at a local mock upstream, points the
# exporter at a local collector, drives the agent face with curl, and then
# inspects the OTLP/HTTP-JSON the collector actually received.
#
# Nothing here is mocked except the two remote parties (provider and
# collector), which are the real wire contracts the gateway talks to.
#
# Usage:  ./scripts/verification/otel_spans_e2e.sh
#         OUT=/some/dir ./scripts/verification/otel_spans_e2e.sh
#
# Artifacts (server log, collector captures, result, spans.json) land in
# $OUT so a later session can inspect what was actually emitted.
#
# Exit 77 when the environment cannot run it (no toolchain / no build).
set -u -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GW="$(cd "$HERE/../.." && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/janus-otel-spans-e2e}"
mkdir -p "$OUT"

for tool in erl curl python3 sqlite3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not found"; exit 77; }
done
[ -d "$GW/_build/default/lib/janus_core/ebin" ] || {
  echo "SKIP: build absent - run 'rebar3 compile' in $GW first"; exit 77
}

PORT=18180
ADMIN=18190
MOCK_PORT=18191
COLLECTOR_PORT=18192
DB="$OUT/janus.db"
COLLECT="$OUT/collected.jsonl"
rm -f "$DB" "$DB"-* "$COLLECT"

# ---------------------------------------------------------------- fixtures
# Mock upstream: a minimal OpenAI-compatible chat completion. Returns the
# usage block the span attributes are derived from, including a cache
# write, so the cache dimension has a real non-zero source.
cat > "$OUT/mock_provider.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length', 0))
        _ = self.rfile.read(n)
        body = {
            "id": "chatcmpl-e2e",
            "object": "chat.completion",
            "model": "mock-model",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "hello"},
                "finish_reason": "stop"
            }],
            "usage": {
                "prompt_tokens": 100,
                "completion_tokens": 7,
                "total_tokens": 107,
                "prompt_tokens_details": {"cached_tokens": 40},
                "cache_write_input_tokens": 10
            }
        }
        raw = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def log_message(self, *a):
        pass

HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY

# Collector: records every OTLP POST body verbatim.
cat > "$OUT/otlp_collector.py" <<'PY'
#!/usr/bin/env python3
"""Throwaway OTLP/HTTP-JSON collector: appends every received body."""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

OUT = sys.argv[2]

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length', 0))
        raw = self.rfile.read(n)
        with open(OUT, 'a') as f:
            f.write(json.dumps({"path": self.path, "body": json.loads(raw)}) + "\n")
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{}')
    def log_message(self, *a):
        pass

open(OUT, 'w').close()
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
python3 "$OUT/otlp_collector.py" "$COLLECTOR_PORT" "$COLLECT" 2>/dev/null &
COLLECTOR=$!

python3 "$OUT/mock_provider.py" "$MOCK_PORT" 2>/dev/null &
PROVIDER=$!

cleanup() {
  # SRV exists only after the boot block runs; an early exit must not
  # turn the trap itself into an "unbound variable" failure that masks
  # the real error.
  kill "${COLLECTOR:-}" "${PROVIDER:-}" "${SRV:-}" 2>/dev/null
  wait "${COLLECTOR:-}" "${PROVIDER:-}" "${SRV:-}" 2>/dev/null
}
trap cleanup EXIT INT TERM

sleep 1

# ---------------------------------------------------------------- seed
# A master role is required: the agent listener lives there.
unset JANUS_DB_URL JANUS_DB_HOST
# `JANUS_SQLITE_PATH' is the documented SQLite knob (JANUS_DB_URL selects
# a Postgres backend, so pointing it at a file is a boot failure).
export JANUS_SQLITE_PATH="$DB"

# Boot once to run migrations, then stop, then seed, then boot for real.
EBINS=()
for d in "$GW"/_build/default/lib/*/ebin; do EBINS+=(-pa "$d"); done

erl -noshell "${EBINS[@]}" \
  -eval "
    application:set_env(janus, role, master),
    {ok,_} = application:ensure_all_started(janus_core),
    init:stop()." > "$OUT/migrate.log" 2>&1

if [ ! -f "$DB" ]; then
  echo "FAIL: migrations produced no database"; tail -20 "$OUT/migrate.log"; exit 1
fi

# Seed through the documented JSON seed path (`JANUS_SEED_PATH`), not
# hand-written SQL: the agent key hash is HMAC-SHA256 with a pepper and a
# hand-rolled row would silently never authenticate.
AGENT_KEY="sk-e2e-agent-key-$RANDOM"
cat > "$OUT/seed.json" <<JSON
{
  "agent_api_key": "$AGENT_KEY",
  "providers": [
    {
      "name": "mockprov",
      "base_url": "http://127.0.0.1:$MOCK_PORT",
      "protocol": "openai_chat",
      "keys": ["upstream-secret"],
      "models": ["mock-model"]
    }
  ],
  "settings": {
    "telemetry": {
      "export": {"enabled": true, "endpoint": "http://127.0.0.1:__COLLECTOR_PORT__"},
      "sampling": {"ratio": 1.0}
    }
  }
}
JSON
python3 - "$OUT/seed.json" "$COLLECTOR_PORT" <<'PYEDIT'
import sys
path, port = sys.argv[1], sys.argv[2]
# Read BEFORE opening for write: `open(p,'w')` truncates the file, so the
# one-liner form silently produced an empty seed.
with open(path) as f:
    text = f.read()
with open(path, 'w') as f:
    f.write(text.replace('__COLLECTOR_PORT__', port))
PYEDIT

# Both the seed and the serving boot must share the pepper and secrets
# key, or the seeded hash will not verify and every request 401s.
# JANUS_SECRETS_KEY is a KEYRING: `id:base64key[,id:base64key...]`, not a
# bare key. A bare base64 string fails with bad_JANUS_SECRETS_KEY_format.
SECRETS_KEY="k1:$(head -c 32 /dev/urandom | base64)"
JANUS_SEED_PATH="$OUT/seed.json" \
JANUS_API_KEY_PEPPER="e2e-pepper" \
JANUS_SECRETS_KEY="$SECRETS_KEY" \
erl -noshell "${EBINS[@]}" \
  -eval "
    application:set_env(janus, role, master),
    {ok,_} = application:ensure_all_started(janus_core),
    case janus_seed:from_file(\"$OUT/seed.json\") of
        ok -> io:format(\"SEEDED~n\");
        Err -> io:format(\"SEED_FAILED ~p~n\", [Err])
    end,
    init:stop()." > "$OUT/seed.log" 2>&1

if ! grep -q SEEDED "$OUT/seed.log"; then
  echo "FAIL: seeding failed"; tail -25 "$OUT/seed.log"; exit 1
fi
echo "$AGENT_KEY" > "$OUT/agent_key.txt"
echo "seeded: $DB"

# ---------------------------------------------------------------- boot
# Export ON, sampler ALWAYS ON (so the span path is exercised on every
# request regardless of the production default ratio).
JANUS_API_KEY_PEPPER="e2e-pepper" \
JANUS_SECRETS_KEY="$SECRETS_KEY" \
erl -noshell "${EBINS[@]}" \
  -eval "
    application:set_env(janus, role, master),
    application:set_env(janus, http_port, $PORT),
    application:set_env(janus, admin_port, $ADMIN),
    {ok,_} = application:ensure_all_started(janus_core),
    {ok,_} = application:ensure_all_started(janus_http),
    io:format(\"READY~n\"),
    timer:sleep(180000),
    halt()." > "$OUT/server.log" 2>&1 &
SRV=$!

for i in $(seq 1 60); do grep -q READY "$OUT/server.log" 2>/dev/null && break; sleep 1; done
if ! grep -q READY "$OUT/server.log"; then
  echo "FAIL: server did not boot"; tail -30 "$OUT/server.log"; exit 1
fi
sleep 2

pass=0; fail=0
ok()   { echo "PASS $1"; pass=$((pass+1)); }
bad()  { echo "FAIL $1${2:+: $2}"; fail=$((fail+1)); }

BASE="http://127.0.0.1:$PORT"
TRACE_ID="aaaabbbbccccddddeeeeffff00002222"

# ---------------------------------------------------------------- drive
RESP=$(curl -s -D "$OUT/headers.txt" -o "$OUT/body.json" \
  --max-time 20 \
  -H "Authorization: Bearer $AGENT_KEY" \
  -H "content-type: application/json" \
  -H "traceparent: 00-$TRACE_ID-00f067aa0ba902b7-01" \
  -d '{"model":"mock-model","messages":[{"role":"user","content":"hi"}]}' \
  "$BASE/v1/chat/completions" 2>/dev/null; echo "curl=$?")

if [ "$RESP" = "curl=0" ]; then ok "request served"; else bad "request served" "$RESP"; fi

# The exporter flushes on a 2s timer; give it a couple of cycles.
for _ in $(seq 1 12); do
  [ -s "$COLLECT" ] && break
  sleep 1
done

if [ -s "$COLLECT" ]; then
  ok "collector received an OTLP export"
else
  bad "collector received an OTLP export" "nothing in $COLLECT"
fi

python3 - "$COLLECT" "$TRACE_ID" "$OUT" <<'PY'
import json, sys, os

collect, tid, out = sys.argv[1], sys.argv[2], sys.argv[3]
if not os.path.exists(collect) or os.path.getsize(collect) == 0:
    print("FAIL spans: no export captured"); sys.exit(1)

posts = [json.loads(l) for l in open(collect) if l.strip()]
spans = []
for p in posts:
    if p.get("path") != "/v1/traces":
        print(f"FAIL path: got {p.get('path')}"); sys.exit(1)
    for rs in p["body"].get("resourceSpans", []):
        for ss in rs.get("scopeSpans", []):
            spans.extend(ss.get("spans", []))

json.dump(spans, open(os.path.join(out, "spans.json"), "w"), indent=2)

def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f": {detail}"))
    return 0 if cond else 1

bad = 0
bad += check("export post path is /v1/traces", True)

mine = [s for s in spans if s.get("traceId") == tid]
bad += check("spans carry the inbound trace id", len(mine) >= 2,
             f"found {len(mine)} of {len(spans)}")

kinds = {s.get("kind") for s in mine}
bad += check("a SERVER span exists (kind 2)", 2 in kinds, f"kinds={kinds}")
bad += check("a CLIENT span exists (kind 3)", 3 in kinds, f"kinds={kinds}")

server = next((s for s in mine if s.get("kind") == 2), None)
client = next((s for s in mine if s.get("kind") == 3), None)

if server and client:
    bad += check("CLIENT span is a child of SERVER span",
                 client.get("parentSpanId") == server.get("spanId"),
                 f"parent={client.get('parentSpanId')} server={server.get('spanId')}")
    bad += check("SERVER span has no parent", "parentSpanId" not in server,
                 server.get("parentSpanId"))

# Timestamps must be decimal STRINGS (OTLP/JSON): a numeric nanosecond
# epoch is silently rounded by every JS consumer. Asserted per field on
# every span, so a single bad one cannot hide behind a passing sibling.
ts_bad = [
    (s.get("name"), k)
    for s in mine
    for k in ("startTimeUnixNano", "endTimeUnixNano")
    if not isinstance(s.get(k), str)
]
bad += check("timestamps are decimal strings", not ts_bad, ts_bad)

def attrs(s):
    return {a["key"]: next(iter(a["value"].values())) for a in s.get("attributes", [])}

if client:
    a = attrs(client)
    bad += check("gen_ai.operation.name present", a.get("gen_ai.operation.name") == "chat",
                 a.get("gen_ai.operation.name"))
    bad += check("gen_ai.provider.name present", a.get("gen_ai.provider.name") == "mockprov",
                 a.get("gen_ai.provider.name"))
    bad += check("gen_ai.request.model present", a.get("gen_ai.request.model") == "mock-model",
                 a.get("gen_ai.request.model"))
    bad += check("gen_ai.request.stream is a bool", a.get("gen_ai.request.stream") is False,
                 a.get("gen_ai.request.stream"))
    bad += check("span name is '{op} {model}'",
                 client.get("name") == "chat mock-model", client.get("name"))

# Token usage: the semconv wants billed input (cache included).
if client:
    a = attrs(client)
    # OpenAI's prompt_tokens ALREADY includes cached tokens, so the billed
    # input is 100 - not 100+40+10. Double-counting here is the bug this
    # assertion exists to catch.
    bad += check("gen_ai.usage.input_tokens emitted",
                 str(a.get("gen_ai.usage.input_tokens")) == "100",
                 a.get("gen_ai.usage.input_tokens"))
    bad += check("gen_ai.usage.cache_read.input_tokens emitted",
                 str(a.get("gen_ai.usage.cache_read.input_tokens")) == "40",
                 a.get("gen_ai.usage.cache_read.input_tokens"))
    bad += check("gen_ai.usage.cache_write.input_tokens emitted",
                 str(a.get("gen_ai.usage.cache_write.input_tokens")) == "10",
                 a.get("gen_ai.usage.cache_write.input_tokens"))
    bad += check("gen_ai.usage.output_tokens emitted",
                 str(a.get("gen_ai.usage.output_tokens")) == "7",
                 a.get("gen_ai.usage.output_tokens"))

# Status: a 200 must NOT be ERROR.
if server:
    bad += check("SERVER status is not ERROR on 200",
                 server.get("status", {}).get("code") != 2,
                 server.get("status"))

# No prompt content may ever appear in an attribute value (iron rule).
leak = []
for s in mine:
    for a in s.get("attributes", []):
        v = str(next(iter(a["value"].values())))
        if "hi" == v.strip() and a["key"] != "gen_ai.request.model":
            leak.append(a["key"])
bad += check("no prompt content in attributes", not leak, leak)

sys.exit(1 if bad else 0)
PY
SPAN_CHECK=$?
if [ "$SPAN_CHECK" -eq 0 ]; then pass=$((pass+6)); else fail=$((fail+1)); fi

# Ledger join: the row must carry the span ids, so a trace can be joined
# to billing.
ROWS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM usage_events WHERE trace_id='$TRACE_ID' AND span_id IS NOT NULL AND parent_span_id IS NOT NULL;" 2>/dev/null || echo 0)
if [ "${ROWS:-0}" -ge 1 ]; then ok "usage row carries span_id and parent_span_id"
else bad "usage row carries span_id and parent_span_id" "rows=$ROWS"; fi

echo "--- $pass passed, $fail failed ---"
echo "artifacts: $OUT (server.log, collected.jsonl, spans.json)"
[ "$fail" -eq 0 ]