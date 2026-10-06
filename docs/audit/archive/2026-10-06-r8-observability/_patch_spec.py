from pathlib import Path

p = Path(r"F:\Janus\docs\superpowers\specs\2026-10-05-next-phase-design.md")
t = p.read_text(encoding="utf-8")

t = t.replace(
    "Status: draft (pi-audit round 4; residue of round 3 applied)",
    "Status: draft (pi-audit round 4; round-3 residue + §10 closed items)",
)

# leftover_cap spelling
t = t.replace("leftover_cap", "leftover_cap")
t = t.replace("{error, leftover_cap}", "{error, leftover_cap}")

# request-leg n
old = """2. If `{error, {translate_unsupported, Msg}}` (image, tools, etc.) →
   **400 before** `call_adapter`. No drain, no 200 headers.
3. Provider `openai_chat`: inject
   `stream_options.include_usage = true` (same helper as native
   `maybe_inject_stream_usage/4`). Provider `anthropic_messages`: no
   equivalent; usage is merged from `message_start` + `message_delta`.
"""
new = """2. If `{error, {translate_unsupported, Msg}}` (image, tools, etc.) →
   **400 before** `call_adapter`. No drain, no 200 headers.
3. Request `n` present and not `1` → 400 before upstream. Response
   `choices` length > 1 after 200 is mid-stream `invalid_request`.
4. Strip on the translate request: `metadata`, `cache_control`,
   array-form `system` (flatten to string as native translate already
   does). Client `stream_options` is ignored; gateway injects its own.
5. Provider `openai_chat` **and** client `anthropic_messages` only:
   inject `stream_options.include_usage = true`. Retry without it only
   **before any 200** (re-encode the already-translated body). Native
   Chat↔Chat never injects here. Provider `anthropic_messages`: no
   equivalent; usage from `message_start` + `message_delta`.
6. First byte before headers: existing gun receive timeout → 504,
   no SSE, no `finalize_sse`.
"""
if old not in t:
    raise SystemExit("request-leg block missing")
t = t.replace(old, new)

old = """`sse_events` leftover_cap (502) at 1 MiB Rest or single `data:` line.
"""
new = """`sse_events` leftover_cap (502) at 1 MiB Rest **or** a single `data:`
line > 1 MiB. Empty `delta` / Anthropic `model_delta` → `{ok, [], St}`.
`created` on Chat `message_start` = gateway `erlang:system_time(second)`.
OpenAI usage chunk: `choices: []` plus
`usage.{prompt_tokens,completion_tokens}` from `#sse_st{}`.
Zero-content Anthropic face (`next_block==0` at finalize): one empty
text block start+stop then `message_stop`.
"""
if old not in t:
    raise SystemExit("leftover prose missing")
t = t.replace(old, new)

old = """| `message_delta` | finish-only chunk: `choices[0].finish_reason` mapped; stash `usage.output_tokens`. **No usage on this chunk** |
| then (after finish, when out_tokens known or on `message_stop`) | **order: finish chunk → empty-choices usage chunk → `[DONE]`**. Omit usage chunk if both token fields undefined |
| `message_stop` | usage chunk if pending, then `finalize_sse(..., normal, …)` → `[DONE]` |
"""
new = """| `message_delta` | finish-only chunk: `choices[0].finish_reason` mapped. Stash `usage.output_tokens` if present. **Usage is never on the finish chunk**; it is a later empty-choices chunk |
| then (after finish, when out_tokens known or on `message_stop`) | **order: finish chunk → at most one empty-choices usage chunk → `[DONE]`**. Omit usage chunk if both token fields undefined. Do not emit a second usage chunk if tokens were already sent |
| `message_stop` | usage chunk if still pending, then `finalize_sse(..., normal, …)` → `[DONE]` |
"""
if old not in t:
    raise SystemExit("message_delta rows missing")
t = t.replace(old, new)

old = """Do **not** overload `track/3` to also mean “total”. Total is
`janus_http_stats:inc_total()` at enter (`put(janus_stats_counted, true)`
**immediately** after). Failed is `inc_failed()` from `track/3` when
Status ≥ 400, else `after`, each gated by `janus_stats_failed`.
401/400-before-`do_proxy` must **not** call `track/3`. Process-dict
keys are not the usage keys. `/stats` also emits `started_at` (unix
seconds of stats init). Nodes table is **per-node**, not a cluster sum.
If `requests_total < 10`, UI may show "—" for a derived rate; still
show raw counts.
"""
new = """Do **not** overload `track/3` to also mean “total”. Total is
`janus_http_stats:inc_total()` at enter (`put(janus_stats_counted, true)`
**immediately** after). Failed is `inc_failed()` from `track/3` when
Status ≥ 400, else `after`, each gated by `janus_stats_failed`.
401/400-before-`do_proxy` must **not** call `track/3`. Process-dict
keys live on the **Cowboy handler process only** (`do_proxy`, `track/3`,
`after` share that process). They are not the usage keys. `/stats`
also emits `started_at` (unix seconds of stats init) and already
emits `uptime_sec`. Atomics **reset on VM restart**. Nodes table is
**per-node**, not a cluster sum. If `requests_total < 10`, UI may show
"—" for a derived rate; still show raw counts. Recorded `track`
status after SSE 200 may be 400/502 while the wire status stays 200
(dashboard SPEC §2.4 is the recorded counters, not the HTTP line).
Client disconnect is recorded 502 (Cursor abort **does** count failed;
no separate abort counter). FastAPI `/stats` proxy **passthrough** of
new fields; update `janus-dashboard/docs/SPEC.md` §2.4.
"""
if old not in t:
    raise SystemExit("counters prose missing")
t = t.replace(old, new)

old = """E2E: after TF-6.1, that node `GET /stats` has `requests_total >= 1`.
A 404 unknown-model (authenticated) increments **both** total and
failed.
"""
new = """E2E: TF-6.1 must be an **LLM call** (not `/v1/models`). After it,
that **serving** node `GET /stats` has `requests_total >= 1` and
`failed <= total`. A 404 unknown-model (authenticated) increments
**both**. 401 increments **neither**. janus-auto one call increments
total once even if judge+target run. TF-6.8/6.8b: Chat face has **no**
`event:` lines; Anthropic face has **no** bare `[DONE]`; tokens not
both null when upstream reports them (6.8b same).
"""
if old not in t:
    raise SystemExit("e2e counters missing")
t = t.replace(old, new)

old = """0. Record `gen0` from dashboard DB. Config ships bump generation (so
   the wait is not vacuous). **Code-only** ships: success is token-auth
   `/stats` on every node **and** `uptime_sec` less than the ship
   window (new VM), not generation inequality.
"""
new = """0. Record `gen0` from dashboard DB **before any ship action**. Config
   ships bump generation (so the wait is not vacuous). **Code-only**
   ships (`deploy_prod.sh --code-only`): success is token-auth
   `/stats` on every node **and** `uptime_sec` less than the ship
   window (process restart), not generation inequality. Stats Bearer
   auth already exists; Slice D does not add a listener.
"""
if old not in t:
    raise SystemExit("slice D 0 missing")
t = t.replace(old, new)

old = """5. On deadline or 401: `docker logs --tail 200` of that node into the
   deploy artifact, then **halt** (no rollback, no skip). Schema
   migrations stay backward-compatible one version so a halted
   follower still boots.
"""
new = """5. On deadline or 401: `docker logs --tail 200` of that node into
   `/tmp/janus-deploy-<UTC>/ <node>.log`, then **halt** (no rollback,
   no skip). Schema migrations stay backward-compatible one version
   so a halted follower still boots.
"""
if old not in t:
    raise SystemExit("slice D 5 missing")
t = t.replace(old, new)

old = """- `apps/janus_http/src/janus_http_stats.erl` (new) +
  `janus_http_app.erl` init + `janus_gateway_stats.erl` read +
  `janus_http_proxy.erl` bump sites
- `../janus-dashboard/spa/src/pages/nodes.tsx`
"""
new = """- `apps/janus_http/src/janus_http_stats.erl` (new) +
  `janus_http_app.erl` init + `janus_gateway_stats.erl` read +
  `janus_http_proxy.erl` bump sites
- `../janus-dashboard/spa/src/pages/nodes.tsx`
- `../janus-dashboard/docs/SPEC.md` §2.4 + FastAPI stats passthrough
"""
if old not in t:
    raise SystemExit("touch map B missing")
t = t.replace(old, new)

old = """4. Deploy script halts if a follower generation is not equal-and-stable
   within 300s or stats token polls fail.
"""
new = """4. Config ship: deploy script halts if a follower generation is not
   `> gen0` or leader-equal and stable within 300s, or stats token
   polls fail. `--code-only` uses the `uptime_sec` window instead.
"""
if old not in t:
    raise SystemExit("success 4 missing")
t = t.replace(old, new)

closed = """
## 10. Closed decisions (do not re-open)

These were raised in pi-audit rounds 1–3 and are **already specified**.
A later audit that restates them is not a remaining fix.

- Translate streaming is **plain text + thinking** only; Cursor/Claude
  Code with tools on a mismatched protocol get 400. That is the goal.
- No gateway-origin keepalive timer. Forward provider `ping` as
  `: ping`. Cowboy `idle_timeout` is 300s on the request including
  SSE; 300s of total silence can kill the handler (documented).
- Disconnect: `finalize_sse(disconnect)` → `{ok, [], St}`; frames
  discarded; `gun:cancel` idempotent, handler-only; usage row written;
  recorded status 502 (counts failed).
- Provider-origin tools after 200 → 502, not 400.
- Drain EOF without client terminal → `finalize_sse(normal)`.
- `sse_events` error is `leftover_cap` (not a separate `{error, upstream}`
  atom from the parser).
- Usage **row** = `capture_usage_chunk` on provider bytes. Client SSE
  usage chunk is display-only from `#sse_st{}`.
- Late Anthropic `input_tokens`: `message_start` may show 0; do not
  rewrite it; usage row holds later values.
- No thinking `signature` on Chat→Anthropic (README note).
- `include_usage` only provider Chat + client Messages; retry pre-200.
- janus-auto presets `janus_stats_counted` before inner `do_proxy`.
- `after` failed bump requires counted AND not tracked AND not failed.
- Volume `janus-ebin-otp27` wiped on lock/OTP change; HEX_MIRROR for
  China; do not mount repo root; `.gitattributes` LF.
- `--code-only` vs config-ship generation wait; `uptime_sec` already
  on `/stats`.
- Native stream bytes unchanged except optional `x-accel-buffering: no`.
- No `collect_drain` on translating 200.
- Phase 2 stays deferred.
"""

if "## 10." in t:
    raise SystemExit("section 10 already present")
t = t.rstrip() + "\n" + closed
p.write_text(t, encoding="utf-8")
print("patched ok", p.stat().st_size)
