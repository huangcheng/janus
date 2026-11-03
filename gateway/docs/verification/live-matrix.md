# Live verification matrix

Every scenario here is driven against a **real** gateway process through
curl, and the assertion is on the bytes the client received and the rows
the gateway wrote — not on a mock of either. This is the primary
end-to-end proof for Janus; checked-in unit tests (see
`AGENTS.md` § Verification) pin the seams but never replace this.

Production is never touched. Every scenario runs on a disposable stack on
loopback ports.

## Reference stack

Two disposable topologies, one per purpose, and no third:

| Purpose | Topology | Where |
|---|---|---|
| Protocol / streaming / failure injection | Docker Compose, SQLite backend, one gateway, one mock upstream | `gateway/scripts/verify_stream_live.sh` is the worked example |
| Multi-node, upgrade, backup | Docker-in-Docker fleet provisioned from `.example` files | not yet built |

The mock upstream is **exactly one** binary for both purposes and lives at
`dashboard/scripts/mock_upstream.py`; `gateway/scripts/fake_sse_upstream.py`
covers only the "go silent mid-stream" shape that the mock does not model.
Adding a third is out of scope by rule: a second fake drifts from the
first and then neither is authoritative.

### Mock upstream behaviour (the fault surface)

Keyed on the bearer the gateway forwards:

| Key | Upstream response | Exercises |
|---|---|---|
| `mock-key-a` | 401 `InvalidAuthentication` | key-level auth failure |
| `mock-key-b` | 200 always | healthy |
| `mock-key-c` | 400 `ProductNotActivated` | deny-shaped 4xx |
| `mock-key-d` | 429 arrears/balance | quota-class 429 |
| `mock-key-e` | 503 always | provider 5xx |
| `mock-key-f` | 400 `no permission … model` | input-shape 4xx |
| `mock-key-a2`/`c2`/`d2` | duplicates of a/c/d | order-independent classification |
| `sk-slow-*` | 200 after `JANUS_MOCK_SLOW_MS` (default 8000) **before the first byte** | TTFB / inactivity |

Wire compression fixture: a user message containing `wire-enc-fixture`
selects ~2.8 KB payloads so messages cross the 256 B compression
threshold.

## Evidence sources

Each scenario names the source that actually proves it. These are the
only admissible evidence:

| Source | What it proves |
|---|---|
| client stdout (`-i` headers + body / SSE frames) | exactly what the caller saw |
| `usage_events` rows | terminal accounting: status, outcome, attempt, is_terminal |
| `/stats` and `/stats/sched` | gateway-side counters and pool state |
| log ring (`docker logs`) with the `what=` field | which code path ran |
| mock upstream request counter | how many real attempts were made |

A scenario that cannot name one of these is not verifiable and belongs in
the exclusions registry, not in the matrix.

## A. Request and unary response

| # | Client face | Provider face | Shape | Expected | Evidence |
|---|---|---|---|---|---|
| A1 | chat | chat | text only | 200, `choices[0].message.content` echoed | client body |
| A2 | chat | chat | system + user ordering | 200 | client body |
| A3 | chat | chat | parallel tool calls | 200, both `tool_calls` present | client body |
| A4 | chat | chat | malformed tool arguments | 200 passthrough (the gateway does not validate upstream arguments) | client body |
| A5 | chat | chat | image-bearing tool result | 200 | client body |
| A6 | chat | chat | interrupted tool call in history | 200; history repaired, `[tool call interrupted - no result]` synthesized | client body + gateway log |
| A7 | chat | chat | orphan tool result (id matches no call) | 200; orphan dropped | client body |
| A8 | chat | anthropic | text (translated) | 200, same text | client body |
| A9 | anthropic | chat | text (translated) | 200 | client body |
| A10 | responses | chat | text (translated), `translate.responses` on | 200 | client body |
| A11 | responses | chat | text, `translate.responses` **off** | 400 `protocol_requires_native` | client body code |
| A12 | chat | decisions-only listing | any | 400 `protocol_requires_native` | client body code |
| A13 | chat | janus-auto | malformed `messages` (not a list) | local 404, **no upstream round-trip** (SPEC §8: malformed input degrades to `pass`, and no provider lists the virtual name) | client body code + upstream counter |
| A14 | chat | chat | usage present | `usage_events` row carries upstream numbers | DB row |
| A15 | chat | chat | usage absent | row carries the documented estimate marker | DB row |
| A16 | chat | any | provider 4xx | terminal row + provider's own message preserved | DB `error_detail` |
| A17 | chat | any | provider 5xx | as A16, classified as 5xx class | DB `error_detail` |

## B. Streaming

| # | Client → Provider | Shape | Expected | Evidence |
|---|---|---|---|---|
| B1 | chat → chat | content deltas | ordered deltas, one terminal event | client SSE |
| B2 | chat → chat | tool-call deltas | accumulated correctly, no duplicate result | client SSE |
| B3 | chat → chat | SSE frames split across reads | reassembled; no truncated frame | client SSE |
| B4 | chat → chat | UTF-8 split across chunks | multibyte char intact | client SSE |
| B5 | chat → chat | upstream goes silent, stays open | `: keepalive` frames appear **before** the client's idle window | client SSE timestamps |
| B6 | chat → chat | silence longer than the inactivity ceiling | terminated with the named stall message, not the total budget | client SSE + gateway log |
| B7 | chat → chat | client disconnects | gateway abandons; no orphan worker session | gateway log + `/stats/sched` |
| B8 | chat → anthropic | translated stream | deltas + `message_stop` in order | client SSE |
| B9 | anthropic → chat | translated stream | deltas + terminal in order | client SSE |
| B10 | responses → chat | translated stream (`translate.responses` on) | deltas + `response.completed` | client SSE |
| B11 | any | n>1 / vision / tools on a stream where translate cannot serve | 400 `stream_requires_native_protocol` **before** any byte | client headers+body |
| B12 | any | mid-stream upstream error | terminal frame carries the upstream's words, not an Erlang term | client SSE |

Knob-off compatibility: for every row above the response must be
byte-identical to the pre-change baseline when the relevant knob is off,
and error responses must match status *and* body field by field.

## C. Existing modality surfaces

| # | Endpoint | Shape | Expected | Evidence |
|---|---|---|---|---|
| C1 | `/v1/embeddings` | valid unary | 200 + usage | client body |
| C2 | `/v1/embeddings` | usage absent | row carries the documented marker | DB row |
| C3 | `/v1/embeddings` | malformed input / dimensions | 400, distinct code | client body |
| C4 | `/v1/embeddings` | unknown model | 404, no failover attempted | client body + upstream counter |
| C5 | `/v1/embeddings` | upstream error | propagated, **no failover** (documented limitation) | client body + DB row |
| C6 | `POST /v1/videos` | submit, no bound provider | clean 404 `no_route` — no fabricated job, no upstream round-trip | client body |
| C7 | `GET /v1/videos/{jvid}` | poll | rebuilds the route from the jvid and passes the upstream body through byte-for-byte; **polls never re-enter the LB and never fail over** | client body + upstream counter |
| C8 | `GET /v1/videos/{jvid}` | malformed jvid | 400 `bad_jvid` **before** any upstream call (a bad signature is refused, not probed) | client body + upstream counter |
| C9 | `DELETE /v1/videos/{jvid}` | cancel | local `{"status":"cancelled"}`; the upstream cancel is **deferred** — nothing is written to usage | client body + DB row count |

Video is a real three-surface endpoint (`janus_m_video`), not a stub. Its
deferred pieces — `video_jobs` persistence, nightly sweep, SSE progress
synthesis, Accept-upgrade polls — are recorded as deviations, and this
matrix asserts the CURRENT behaviour rather than the intended one.

## D. Failure injection

Runs on the Compose stack; every row asserts the *existing* behaviour, and
none of them change product code to create a seam.

| # | Condition | Expected | Evidence |
|---|---|---|---|
| D1 | empty worker pool | master-local fallback, reason recorded | `/stats/sched` + log |
| D2 | dispatch send failure / missing ack | fallback, timeout, reservation released | log + `/stats` |
| D3 | worker loss before first byte | local fallback; no duplicate accepted job | upstream counter + DB row |
| D4 | worker loss after first byte | `worker_lost`, **no** mid-stream retry | client SSE + DB outcome |
| D5 | slow upstream | correct absolute/inactivity timeout | client error + gateway log |
| D6 | slow client | credits stay bounded, mailbox does not grow without limit | `process_info` mailbox_len samples |
| D7 | provider auth failure (`mock-key-a`) | key cooldown, eligible failover | upstream counter + `/stats` |
| D8 | provider 429 with Retry-After (`mock-key-d`) | cooldown honours the hint | `/stats` cooldown + upstream counter |
| D9 | provider 5xx (`mock-key-e`) | classified, failover, terminal row | DB row |
| D10 | oversized upstream response | response cap rejects safely; no fabricated success | client body + counter |
| D11 | corrupt wire payload after first client byte | same status/body as D4; `wire_enc_inflate_fail` counter increments; master health stays passing | client SSE + `/stats` |
| D12 | corrupt wire payload before first client byte | same as D3; no duplicate accepted job | client SSE + counter |

**D11/D12 seam: confirmed to exist.** `JANUS_WIRE_ENC_CORRUPT_AFTER=<N>`
(`janus_wire_enc.erl`) is a runtime env switch, not a build flag: N >= 0
arms corruption of the compressed message with seq N, producing a real
master-side inflate failure. Unset/garbage/negative disarms it, so a
negative value can never name a chunk. `janus_worker_dispatch` warns
loudly at boot if it is set, and it must never be set outside the
disposable stack.

For D11 the offset must be chosen so a **valid** chunk reaches the client
first, otherwise the scenario is D12 by accident.
Mock HTTP payload mangling is not evidence for either row.
| D13 | catalog reload during traffic | atomic generation handoff, no partial catalog | `/metrics` generation |
| D14 | Postgres temporary outage | client status/body matches the pre-outage baseline; writer failures loud | client body + logs |
| D15 | usage-writer saturation | bounded buffer, counted drops, no fabricated zero | `/stats` dropped counter |
| D16 | usage-writer process down | dropped series **omitted**, not zero | `/metrics` absence + log |
| D17 | node/process restart | supervision + `janus_ets_heir` behaviour as documented | log |



## Real-upstream confirmation subset

The mock stack proves classification; a small subset confirms the real
path. Low-cost requests only, never load:

1. one native unary request;
2. one native stream;
3. one supported translated request;
4. one provider auth failure, using a deliberately invalid key supplied
   through the existing local secret channel;
5. 429/5xx only if they occur naturally during a bounded observation
   window — **never generate load to force them**. If not observed,
   discharge the row on the mock stack and record why.

## Recording results

Durable evidence goes under `artifacts/verification/<commit>/` (already
gitignored). Each run records: commit, image tag, command, environment,
and the per-row pass/fail with the evidence snippet that proves it.

Rows that cannot be executed are registered in
`artifacts/verification/<commit>/exclusions.md` with the reason. A row
silently dropped from this file is a regression in the matrix itself.

## Execution status

### Group A — executed, 9/9 pass

`bash gateway/scripts/verification/run_matrix_a.sh` runs the automated
subset against a disposable docker stack (SQLite, generated seed, the mock
upstream). Artifacts and a per-row PASS/FAIL summary land in
`/tmp/janus-matrix-a/`.

Row A13 was **rewritten after running it**. It originally asserted that a
malformed `messages` value returns 400 for a DIRECT model name. That check
does not exist and should not: a direct name is a pass-through, and the
gateway translates rather than validating bodies its upstream will reject.
What the contract actually says (SPEC §8) is that malformed input on the
*virtual* name degrades to `pass`, and since no provider lists that name
the caller gets a local 404 with no upstream round-trip — which the row now
asserts, verified against the mock's request counter.

Two stack defects were found by running rather than by reading:

- the container had no C compiler, so the NIF-backed dependency failed to
  build — and because the shared build volume still held beams from an
  earlier run, the boot printed its ready line anyway. Build and boot are
  now separate steps with the build as a hard prerequisite.
- the default SQLite path is the relative `data/janus.db`, and `/app` is the
  mounted checkout, so a run read and wrote the DEVELOPER'S local database;
  seeding then failed with a UNIQUE violation because a previous run's key
  was still there. Each run now uses a fresh DB inside its artifact dir.

### Group B — executed, 7/7 pass

`bash gateway/scripts/verification/run_matrix_b.sh`. Assertions are on the
bytes the client received, because that is the only way to see a keepalive
during a stall or a frame split across reads.

Two rows were corrected by running them:

- **B11** assumed `n>1` blocks any stream. It blocks only the
  CROSS-PROTOCOL translate path: a chat client hitting a chat provider rides
  the native stream and is served normally (verified — 200 with a full SSE
  stream). The row now drives a protocol pair and matches the real code,
  `translate_unsupported`.
- **B6** looked for `stall|idle|timeout` in the terminal frame. The gateway
  actually closes with an SSE **comment**:
  `: janus stream failed - upstream stopped sending data mid-stream`.
  Matching the real text, and asserting it is a comment (not payload), is
  both more precise and less likely to rot.

B6 also needs its OWN gateway: a stall benches the provider on the previous
instance, so reusing B5's stack answers `all_cooling` and never reaches the
stall path.

### Group C — executed, 7/7 pass

`bash gateway/scripts/verification/run_matrix_c.sh`. `/v1/embeddings` covers
the valid path, usage-absent (the gateway must record unknown, never invent
a count), a malformed input code, an unknown model, and — the row that
matters — **no failover**: the provider has exactly one key, so a 5xx
reaching the client IS the proof that nothing was retried.

Video has no mock fixture, so its rows assert the classified failure rather
than a happy path: submit with no bound provider is a clean 404 `no_route`,
and a malformed job id is 400 `bad_jvid` before any upstream call. Both were
corrected after running — the first draft expected 200/201 and a 404
respectively, and neither is what the code does.

One structural finding: modality surfaces ship **disabled** (new capability
families default off), and `settings` are read at BOOT — the config poller
republishes the catalog, not the settings rows, so writing the knob into the
database while the gateway runs has no effect. The seed file now accepts a
`settings` object, which a verification stack sets before first boot.

### Not yet executed

| Group | Rows | Blocker |
|---|---|---|
| D failure injection | 17 | needs the master/worker Compose topology, which does not exist |
| real-upstream subset | 5 | by design, observation-gated |

The multi-node / upgrade / backup topology does not exist yet. Nothing in
groups B–D has been run as a batch.
