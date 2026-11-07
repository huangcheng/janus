# OpenTelemetry Alignment Design

Status: Draft for review
Date: 2026-11-06
Supersedes: nothing. Extends the observability sections of
`2026-11-02-gateway-hardening-phase-design.md` without relaxing any invariant there.

Every finding in §3 cites the implementing file, so the claim can be
re-verified directly against the tree without any supporting artifact.

## 1. Purpose

Janus already emits three independent telemetry mechanisms. None of them is
shape-compatible with OpenTelemetry, and the trace handling — the one piece
written against a W3C spec — stops at id minting: no spans are ever produced,
so nothing is traceable.

This specification defines what "align to the OpenTelemetry specification"
means concretely for Janus, records the audit evidence that motivates each
change, and sets the target data model, wire formats, configuration surface,
and verification contract.

The binding outcome: **a Janus request produces an OTLP-exportable trace with
a SERVER span and one CLIENT span per upstream attempt, carrying HTTP and GenAI
semantic-convention attributes, correlated to an OTLP log record and to the
existing `usage_events` ledger.**

## 2. What "align to OpenTelemetry" means here

The OpenTelemetry specification does not define a certification program and
does not require an application to embed an SDK. It binds requirements per
document, and each document's `MUST` clauses are individually mandatory:
*"An implementation of the specification is not compliant if it fails to
satisfy one or more of the 'MUST', 'MUST NOT', 'REQUIRED' requirements defined
in the specification."*
(<https://opentelemetry.io/docs/specs/otel/>)

It further specifies, rather than forbids, SDK-less operation: *"in the absence
of an installed SDK, the Trace API is a 'no-op' API … one important exception …
propagation of a SpanContext … a SpanContext that has been provided by a
configured Propagator will be propagated through to any child span and
ultimately also Inject, but no new SpanContexts will be created."*
(<https://opentelemetry.io/docs/specs/otel/trace/api/>)

Because Janus is Erlang/OTP with a no-new-dependency convention and no OTel SDK
in its dependency set, conformance is decomposed into three independently
verifiable axes:

| Axis | Requirement class | Janus obligation |
|---|---|---|
| Wire format | OTLP `MUST` clauses | Emit OTLP/HTTP JSON that a collector accepts |
| Semantics | Semantic-convention `MUST`/`REQUIRED` attribute rules | Correct names, types, and requirement levels |
| Propagation | W3C Trace Context `MUST` clauses | Honest extract/inject, preserved `tracestate`, honored sampled bit |

OTLP/HTTP JSON is a fully specified encoding, not a second-class one: *"OTLP/HTTP
uses Protobuf payloads encoded either in binary format or in JSON format … the
Protobuf schema of the messages is the same for OTLP/HTTP and OTLP/gRPC."*
Deviations that MUST be honored in JSON: `traceId`/`spanId` are
**case-insensitive hex strings** (not base64), enums are **integer values**, and
enum name strings MUST NOT be used.
(<https://opentelemetry.io/docs/specs/otlp/>)

This yields a dependency-free export path: hand-built JSON over the existing
`gun` HTTP client. It is chosen deliberately over an SDK.

### 2.1 Scope of the conformance claim

The claim is deliberately narrow, and precise about *when* it applies:

- Janus **today** emits no OTLP at all (§3). Nothing in this document is a claim
  about the current build. The conformance target binds **the result of the
  roadmap in §12**, and each phase is only conformant on the axes it delivers —
  P2 delivers wire-format conformance for traces, P3 adds semantics for metrics,
  and so on. Any statement of the form "Janus is OTLP-conformant" is false until
  P2 lands.
- Janus is **not** claiming to be an "OpenTelemetry SDK". It is an application
  that emits conformant OTLP. Requirements addressed to SDK implementors (for
  example `OTEL_BSP_*` env vars, the `MeterProvider` lifecycle) do not bind it,
  though §9 mirrors their defaults where an operator would sensibly expect them.
- `OTEL_EXPORTER_OTLP_*` variables are `SHOULD`-level for a non-SDK emitter. We
  honor them anyway (§9.1), because an operator pointing Janus at a collector
  will use them.
- Once the exporter exists, the retry rule becomes binding:
  *"Transient errors MUST be handled with a retry strategy … MUST implement an
  exponential back-off with jitter."*
  (<https://opentelemetry.io/docs/specs/otel/protocol/exporter/>)
  That obligation is **entirely off the request path** and cannot be discharged
  by blocking a request: §9.2's bounded queue, capped retry episode, and drop
  counter are what make the `MUST` compatible with the never-fail-a-request
  invariant. Retrying is a property of the writer process, never of the caller.

## 3. Audit: current state

The audit below is the evidence base. Every claim cites the implementing file.

### 3.1 Inventory

| Mechanism | Entry point | Transport / storage | OTel-relevant shape |
|---|---|---|---|
| Trace context | `janus_trace.erl` | Inbound `traceparent` header → process dictionary → outbound `traceparent` | Id propagation only. No spans, no `tracestate`, no sampler, no resource |
| Usage ledger | `janus_usage.erl` | Buffered casts → `usage_events` table | Row-per-attempt ledger; close to a span record in spirit but a different schema |
| Metrics | `janus_metrics.erl` | Public ETS registry → Prometheus text at `/metrics` | 56 families, bespoke names/labels, no units, no OTLP |
| Logs | `janus_log_fmt.erl` | Single-line key=value to stdout / rotating file | No trace correlation |
| Event rings | `janus_log_tail.erl`, `janus_ops_tail.erl` | In-memory rings (2000 each) pulled by the dashboard | Heterogeneous JSON, no signal model |
| Node stats | `janus_gateway_stats.erl` | `/stats`, `/stats/health`, `/stats/sched` JSON | Dashboard-specific snapshot shape |
| Shape sentinel | `janus_shape_capture.erl` | Log ring | Structural fingerprints, content-free by design |
| Management plane | `dashboard/app/*`, SPA | Polls the above into Postgres | No OTel dependency, no own metrics/trace endpoint |

### 3.2 Findings

**F1 — No spans are ever recorded, while phantom parent ids are emitted.**
`janus_trace.erl` exports `ensure/1`, `from_trace_id/1`, `header/0`,
`trace_id/1`, `upstream_header/1`. There is no span term, no start/end pair, and
**no span id is ever stored or persisted** — confirmed mechanically: `span_id`
does not occur anywhere in `gateway/apps` or `dashboard/app`.

The precise statement matters, because there *is* an id minted:
`new_parent_id/0` (used by `upstream_header/1`, F2) fabricates a 16-hex
parent-id for every outbound `traceparent`. So the gateway does not merely omit
itself from traces — it **advertises a parent span that was never recorded**.
A downstream participant that links to that id references a span that does not
exist, and the causal gap is indistinguishable from span loss. The fix is not to
stop minting ids (a real span needs one) but to make the minted id the id of an
actual span (§5).

**F2 — Sampling is a hardcoded lie.** `upstream_header/1` emits flags `01`
unconditionally:

```erlang
%% janus_trace.erl:99-101
upstream_header(#trace{tid = Tid}) ->
    Pid = new_parent_id(),
    {<<"traceparent">>, <<"00-", Tid/binary, "-", Pid/binary, "-01">>}.
```

The sampled bit asserts "this trace is being recorded" on every outbound call
while nothing is recorded, and the inbound decision is dropped. The module's own
doc comment states this ("the inbound sampling decision is NOT carried
upstream"). This is the single most misleading behaviour in the current
implementation: an upstream that honors the flag will record a trace that the
gateway never completes.

**F3 — `tracestate` is neither parsed nor forwarded.** `parse/1` matches only
the 55-byte version-`00` `traceparent` shape (`janus_trace.erl:110-119`).
`gateway/README.md:394-395` documents the omission as intentional. Per the W3C
Trace Context spec: *"A W3C Trace Context propagator MUST propagate a valid
tracestate unless the value is empty"*
(<https://opentelemetry.io/docs/specs/otel/context/api-propagators/>). Vendors
rely on `tracestate` to carry their own sampling and tenant hints; dropping it
severs the gateway from vendor-specific trace features.

**F4 — Only the trace id crosses the master→worker wire.** `wire_trace/1`
strips `traceparent` from the prepared headers and adds a bare `trace_id` key
(`janus_http_worker_client.erl:346-353`); the worker re-mints a parent id
(`janus_worker_session.erl:86-93`). This is deliberate, not an oversight: the
parent id must be minted on the executing node, so the master's provisional
`traceparent` is discarded rather than forwarded. The consequence is still the
gap: there is no wire field for a span id at all, so the master's attempt span
and the worker's execution cannot be related as parent/child, and the
relationship is unrecoverable after the fact because parent ids are never
persisted.

**F4b — Workers cannot be scraped.** Workers run no admin listener
(`janus_gateway_stats.erl:22-26`), so `/metrics` and `/stats` exist on masters
only; the worker's own telemetry reaches the master solely through the 30s
coalesced load cast (`janus_worker_dispatch.erl`). This is a hard constraint on
the metrics design: an exporter on a worker *must push*, because there is no
endpoint for a collector to pull.

**F5 — Response trace context uses a non-standard header.** Handlers echo
`x-trace-id` (`janus_http_preamble.erl:76-80`, `janus_http_decisions.erl:50-56`,
`janus_modality.erl:53-54`). A W3C-conformant client has no way to join the
trace it started. There is also no `tracestate` on the response.

**F6 — No Resource identity.** No `service.name`, `service.version`,
`service.instance.id`, or `telemetry.sdk.*`. The raw material exists but is
scattered: `janus_build:sha/0` (git sha), `janus_role:get/0` (master|worker),
`janus_ops_tail:boot_id/0`, `node()`. Nothing composes them into a Resource.

**F7 — Metrics are Prometheus-shaped only.** 56 families are registered in
`janus_metrics_render.erl` (`?FAMILIES`): 35 counters, 1 histogram, 19 gauges,
1 untyped. Every name is prefixed `janus_`. Specific gaps:

- **The only histogram** is `janus_request_duration_seconds`
  (`janus_metrics.erl`), ladder `0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60,
  120, 300, 600`. The first byte of a slow LLM stream is frequently past 10s, so
  five buckets (30–600) exist solely for the tail while the sub-50ms region —
  where auth rejects and cache hits live — has no resolution at all.
- **No unit metadata.** The renderer emits `# TYPE`/`# HELP` but no unit; OTel
  metrics carry a UCUM unit (`s`, `By`, `{token}`) as a first-class field.
- **Labels are the wrong vocabulary.** `janus_requests_total` is labeled
  `endpoint`, `protocol`, `status_class` — all closed enums, genuinely
  low-cardinality, but not the semconv names (`http.request.method`,
  `url.scheme`, `http.response.status_code`, `http.route`).
- **No GenAI metrics at all.** An LLM gateway has no token-count metric.
- Cardinality is otherwise handled well: `?SCHED_FAMILY_CAP` = 256 per family
  with an explicit `_overflow_total` sibling
  (`janus_http_metrics.erl:139,338-341`), and `janus_metrics`' doc comment
  forbids request ids, key ids, and model names as labels. This discipline must
  survive.

**F8 — No log/trace correlation.** 249 `logger:` call sites exist in
`gateway/apps`; **zero** include a trace id. The canonical request log line
(`janus_http_proxy.erl:3433-3442`) carries `request_id` but not `trace_id`, so
the Logs page cannot pivot to a trace, and an OTLP log export would have no
`traceId`/`spanId` to attach.

**F9 — Dead column: `cache_read_input_tokens`, and a second merged dimension.**
Migration `012` added the column; `janus_usage.erl:493` reads the map key
`cache_read_input_tokens` from the event, but **no call site ever sets that
key**. `janus_usage_parse.erl:91-97` does compute the value — then folds it into
`prompt` (`P = Base + Cache`) and discards it. The dashboard selects the column
(`dashboard/app/routers/usage.py:355,405`) and therefore always renders `NULL`.
This matters for OTel because `gen_ai.usage.cache_read.input_tokens` is a
first-class GenAI attribute and part of the anthropic cache-read accounting that
was explicitly specified in the translation work. The data exists; it is thrown
away one line after being computed.

The same line merges a **second** dimension, which is easy to miss:

```erlang
%% janus_usage_parse.erl:92-95
Cache = first_int(U, [<<"cache_creation_input_tokens">>]) +
            first_int(U, [<<"cache_read_input_tokens">>]),
```

Anthropic reports `cache_creation_input_tokens` on every cache *write*. Both
values are summed and both are lost, so a fix that emits only
`gen_ai.usage.cache_read.input_tokens` fixes one merged dimension and leaves the
other. P0 must separate and persist **both** — `cache_read` and `cache_write`
— and emit both.

Naming precision, because the two namespaces differ and are easy to conflate:

| Surface | Name |
|---|---|
| span **attribute** | `gen_ai.usage.cache_read.input_tokens` (§5.3) |
| span **attribute** | `gen_ai.usage.cache_write.input_tokens` |
| **metric** instrument | `gen_ai.client.inference.usage.cache_read.input_tokens` (§8.2) |
| **metric** instrument | `gen_ai.client.inference.usage.cache_write.input_tokens` |

Attributes and instruments are separate namespaces in the GenAI conventions —
`gen_ai.usage.*` for the span attribute, `gen_ai.client.inference.usage.*` for
the counter. Emitting the instrument name as an attribute (or the reverse)
produces a silently-ignored key.

**F10 — The management plane emits nothing.** `dashboard/` polls and persists
(10s node health cadence; retention 14d logs/ops, 30d alerts, 90d audit, 31d
usage), but exposes no metrics endpoint, instruments no request, and has no OTel
dependency (`pyproject.toml` is authoritative; the `opentelemetry-api` in
`.venv` is a transitive FastAPI requirement, not a decision). Its own request
handling is invisible, and its three internal counter registries
(`ops_puller.py:79-99`, `nodes.py:494-507`, `alerts.py:237`) have **zero
callers** — measured telemetry that nothing reads.

Two dashboard-specific findings shape P5 and are easy to miss:

- **Egress pinning is a convention, not a chokepoint.** `egress.pinned_async_client`
  (DNS pinning at connect, loopback/RFC1918/ULA allowed, cloud-metadata/
  link-local/100.64 refused, fail-closed on resolution failure) is applied on the
  **poll paths only** — 9 sites in `nodes.py`, `routers/nodes.py`,
  `ops_puller.py`. It is not mandatory: three gateway/webhook call sites already
  use a plain `httpx.AsyncClient` (`routers/logs.py:173` live log fan-out,
  `maintenance.py:592` `/stats/mmdb/reload`, `alerts.py:2215` alert webhook), and
  the pinned client itself defaults `trust_env=True` (`egress.py:402`) — only
  `alerts.py:2215`, `turnstile.py:51`, and `ops_puller.py:899` disable proxy env.
  So there is **no invariant to inherit and nothing that already protects an
  exporter**. A stock OTLP exporter would be the fourth bypass. The requirement
  is therefore a *decision obligation*, not a preservation obligation: either
  give the exporter a transport that pins (`_PinNetworkBackend`,
  `egress.py:355-437`) and caps (`read_body_capped`, `egress.py:82,444-453`), or
  record the bypass explicitly. Both are acceptable; silence is not.
- **Ingestion cannot be re-pointed at OTLP.** The SPA contract is built on the
  pullers' artifacts, not a generic stream: `/api/logs` returns `idx`-keyed ring
  events, the ops feed carries boot-change and overflow *markers* that have no
  OTLP equivalent, the Failures page's reject half is a SQL filter over
  `gateway_log_events.fields->>'what'`, and three alert rules read
  `gateway_nodes.health_snapshot` / `task_runs`. The dashboard's OTLP story is
  therefore **export out only**; becoming an OTLP *receiver* is a separate,
  strictly larger project.

**F10b — The dashboard's 500-handler correlation id is a dead end.**
`main.py:218-242` mints a 12-hex `correlation_id` and logs it, but never returns
it in a header and never persists it. An operator seeing
`internal error (ref: abc123)` has nothing to join against. This is the same
class of defect as the gateway's trace id: an identifier that looks like
correlation but does not correlate.

**F11 — The ledger is a de-facto span table without the span keys.**
`usage_events` has 25 columns including `trace_id`, `request_id`,
`request_ref`, `attempt`, `is_terminal`, `latency_ms`, `error_code`,
`error_detail`, `failover_reason`, `outcome`. This is a per-attempt record with
almost exactly span semantics — and the one thing missing is the span identity
(`span_id`, `parent_span_id`). The dashboard already reconstructs a per-attempt
timeline from it (`GET /api/usage/timeline`), which is a hand-rolled trace view.

**F12 — `outcome` disagrees with itself for identical 200s.** A successful
local chat-family request calls `track_proxied/3` without ever setting
`note_usage_outcome(ok)` (`janus_http_proxy.erl:1810-1818`), so
`janus_usage.erl:492` defaults the column to `null`. The worker success path
does set it (`stash_done(Done, ok)` at `janus_http_worker_client.erl:859` and
`:1482`, which maps through `outcome_bin(ok) -> <<"completed">>` at `:187`). Two
identical 200s therefore land in the ledger with different `outcome` values
depending on whether the master or a worker executed them. This must be fixed
before `outcome` is projected into any span status, or the span status inherits
the asymmetry.

**F13 — The cardinality guarantee does not hold for two families.**
`janus_metrics`' doc comment states label values come only from closed enums
(`janus_metrics.erl:18-21`), and the per-family cap of 256 backs it up. But two
of the three `auto_tier_*` families have atom catch-alls
(`janus_http_proxy.erl:2618,2628`) and a free-form `tier` value
(`janus_http_proxy.erl:2607-2612`). These are the only unbounded labels in the
hot registry besides `provider`.

Scope this precisely, because the obvious reading overstates it. The `tier`
value comes from operator-configured router settings, not from a client request,
and `janus_metrics:norm_labels/1` only calls `to_bin/1` — it never calls
`list_to_atom` or `binary_to_atom`. So there is **no atom-table exhaustion
hazard**: an unknown tier cannot create an atom, and the 256 cap bounds the
series count. What remains is a real but milder defect — an operator typo, or a
future code path that derives a tier from request data, silently escapes the
closed-enum claim and inflates the series cardinality up to the cap.

The fix is therefore small and belongs to P3 (item 25): validate `tier` and
`reason` against their declared enums at the bump site, map anything else to one
reserved `unknown` value, and keep the existing series untouched. The rule a
span-attribute design must inherit is the general one: **enum-validate at the
producer, never rely on the consumer's cap.**

**F14 — Two counters disagree about the same thing.** `janus_http_stats`
maintains `requests_total`/`requests_failed` atomics
(`janus_http_stats.erl:21-31`) surfaced through `/stats`, while
`janus_metrics` maintains `janus_requests_total` surfaced through `/metrics`.
They are separate counters of the same requests and can diverge. That is
tolerable for a dashboard, not for an OTLP export that claims one source of
truth.

### 3.3 What must not break

Extracted from the hardened implementation and `AGENTS.md`:

1. **Telemetry never fails the request.** Every hot-path entry point is total.
   `janus_metrics:inc/observe` are whole-body `try/catch`; `janus_usage:record`
   never raises; `janus_trace` never rejects. This survives unchanged.
2. **Bounded memory, honest loss.** Buffer caps, mailbox caps, retry-episode
   abandonment, and drop counters (`usage_writer_dropped_total`) exist so that
   loss is *counted and logged, never silent*. New export paths inherit this.
3. **No content in telemetry.** Prompts, responses, tool arguments, and user
   bytes never enter logs, fingerprints, or the ledger. The shape sentinel's
   structure-only rule is the model. This directly constrains GenAI attributes:
   `gen_ai.input.messages`, `gen_ai.output.messages`,
   `gen_ai.system_instructions`, and `gen_ai.tool.definitions` are **Opt-In** in
   the spec and will stay **permanently off**.
4. **No secrets.** Bearer tokens, provider keys, and `sk-`/`gsk-`/`AIza`/PEM
   material are scrubbed before reaching any sink.
5. **Bounded cardinality by construction.** Label values come only from closed
   enums and operator-defined names. Never request ids, key ids, or model names.
6. **Hot reload, no restart.** Settings flow dashboard → Postgres → generation
   bump → `persistent_term` (`janus_config:distribute_settings/1`). New knobs
   follow this path; env vars are the boot-time override.
7. **Knobs default off; knob-off is byte-compatible.** New capability families
   ship disabled. Export off must reproduce today's behaviour exactly.
8. **Additive migrations only, rolling-deploy safe.** New `usage_events` columns
   are nullable; the master→worker wire map already tolerates unknown keys
   (`?JOB_REQUIRED` validates presence of seven keys and ignores extras,
   `janus_worker_wire.erl:522-538`), so additive trace fields are safe in both
   directions.
9. **`/metrics` keeps working.** Prometheus consumers, the example scrape
   config, the alert rules, and the Grafana dashboard are supported surfaces.

## 4. Target architecture

### 4.1 Signal model

```
Request (inbound HTTP)                    → SERVER span
  ├─ translate / guard / route (INTERNAL) → INTERNAL span (opt-in, see §5.1)
  ├─ upstream attempt #1 (CLIENT)         → CLIENT span  (retry legs: sibling CLIENT spans)
  ├─ upstream attempt #2 (CLIENT)         → CLIENT span
  └─ stream drain (INTERNAL, stays open while bytes flow)

Each span                                    → OTLP/HTTP JSON → collector
Each terminal attempt                        → usage_events row (unchanged)
Each log record during a span                → OTLP logs with traceId/spanId
```

Three properties are new and are the whole point:

- **Nesting is recorded.** The SERVER span is the parent of each CLIENT attempt
  span. Retry legs are siblings, not a chain — matching how
  `usage_events.attempt` already models them.
- **The sampled bit is honest.** It is computed once per trace, propagated
  inbound→upstream, and respected by every producer.
- **Everything joins.** `trace_id` and `span_id` appear in the OTLP trace, the
  OTLP log record, and the `usage_events` row.

### 4.2 Why hand-built OTLP and not an SDK

An official Erlang SDK does exist: `opentelemetry` 1.7.0,
`opentelemetry_api` 1.5.0, `opentelemetry_exporter` 1.10.0 (hex.pm, OTP 23+;
Janus builds on OTP 27). It was rejected for a concrete reason:
`opentelemetry_exporter` declares non-optional dependencies on `grpcbox` and
`tls_certificate_check ~> 1.18`. `tls_certificate_check` is already locked, but `grpcbox` drags in `chatterbox`,
`hpack`, and `ctx`. The repo locks 10 packages and ships a minimal relx release
(`janus`, `sasl`, `runtime_tools` — `rebar.config:19-23`), so this path adds 4–6
transitive applications plus a new egress stack — for a feature that must be
default-off.

| Option | Verdict |
|---|---|
| Official Erlang SDK (`opentelemetry_exporter`) | Rejected. Pulls `grpcbox`/`chatterbox`/`hpack`; violates the no-new-dependency convention for a public repo |
| **Hand-built OTLP/HTTP JSON over existing `gun` + `thoas`** | **Chosen.** JSON is a specified OTLP encoding; `gun` and `thoas` are already locked; ~250–400 lines for span model + sampler + propagator + batcher |
| OTLP/gRPC | Rejected. Requires protobuf codegen and HTTP/2 framing; the encoder cost is unjustified |
| Sidecar translating Prometheus → OTel | Rejected as the *primary* path. It cannot produce spans, and makes the gateway depend on an unshipped component. Viable later as a stopgap for metrics only (§8.5) |

The exporter is a bounded buffer plus a batch flush, structurally identical to
`janus_usage`'s proven writer: cap, flush interval, retry with capped backoff,
drop counter, loud abandonment. This is a deliberate reuse of a shape the
codebase already trusts.

The genuinely risky part is not the protocol — it is touching the hot path.
Every span start/end must be fail-open in the same shape as
`janus_metrics:inc/2`.

### 4.3 Pinned semconv version

GenAI conventions are at stability **Development** and have renamed repeatedly
in the past twelve months: `gen_ai.system` → `gen_ai.provider.name` (semconv
v1.37.0, 2025-08-25); `gen_ai.client.token.usage` + `gen_ai.token.type` replaced
by per-direction `gen_ai.client.inference.usage.*` counters (2026-09-22);
`gen_ai.client.operation.duration` **displaced for inference** by
`gen_ai.client.inference.duration` (the generic instrument survives for
embeddings/retrieval/memory); `gen_ai.usage.cache_creation.input_tokens` →
`cache_write` (2026-08-20). The implementation therefore pins
`?GENAI_SEMCONV_VERSION` in one module constant and routes every attribute name
through a single mapping table, so a rename is a table edit rather than a grep
across the tree.

**Pin to a commit, not a date.** The upstream enum is internally inconsistent
*today*: `gen-ai-metrics.md` lists `mistral_ai` while `client-inference.md`
lists `mistral`, both in the same repository at the same time. A date pin
cannot distinguish which of the two a given file was read at, so
`?GENAI_SEMCONV_VERSION` records the semantic-conventions-genai **commit SHA**,
and the mapping table documents the exact file each value came from.

This is not paranoia. During the writing of this document — a window of roughly
two days — the GenAI tree took **four** breaking changes: the modality
attribute was dropped from `reasoning.output_tokens` (2026-11-05), the retrieval
span was replaced and re-kinded (2026-11-04), structured content attributes
lost their JSON-string fallback (2026-11-05), and `gen_ai.client.operation.duration`
finished being carved up so that it now applies to no operation the gateway
performs. The repository has **no tagged releases** in this period. Anything
pinned to a branch name will drift silently; the pin must be a SHA, and it must
be re-checked at every release (§13.5).

The HTTP family is pinned to the stable release, and
`OTEL_SEMCONV_STABILITY_OPT_IN` is honored for it.

## 5. Trace design

### 5.1 Span inventory

| Span name | Kind | Created at | Notes |
|---|---|---|---|
| `{method} {route}` | SERVER | **handler entry, before auth** | `POST /v1/chat/completions`, `POST /v1/messages`, … |
| `{gen_ai.operation.name} {gen_ai.request.model}` | CLIENT | one per upstream attempt | `chat gpt-4o`, `embeddings text-embedding-3-small` |
| `translate {client}->{provider}` | INTERNAL | translation seam | Opt-in, off by default (§5.5) |
| `dispatch worker` | INTERNAL | master→worker seam | Opt-in. Represents queue + relay time |

**The SERVER span opens before auth, not after.** Every Janus route is static,
so `http.route` and `http.request.method` are known at handler entry — the
semconv condition for setting `http.route` at span creation is satisfied with no
dependency on the auth outcome. Starting it after auth would leave the entire
auth/quota phase invisible and, worse, produce **orphaned traces for every
rejected request**: a 401/429 would continue the caller's trace id while
contributing no span, which is precisely the defect this document exists to fix
(F1). An auth reject is a legitimate span outcome — status `ERROR`, no
`http.response.status_code` if none was sent, `error.type` from the reject code.

The cost is one span object on a path that may exit early; the span is created
only after the sampler decides to record (§7), so an unsampled reject costs a
sampler call and nothing else.

**The drain span is bounded.** A stream can stay open for minutes, so the
"stays open while bytes flow" INTERNAL span must not be the mechanism that
tracks it. It closes on any of: drain completion, client disconnect, upstream
failure, or the stream inactivity ceiling already enforced by
`janus_worker_wire:stream_inactivity_timeout_ms/0`. A span still open at the
ceiling is closed and counted (`janus.telemetry.span.truncated`), never left to
pin buffer space — the same counted-loss discipline as §3.3 item 2.

SERVER names follow the semconv rule: `{method} {target}`, where `{target}` is
`http.route` and `{method}` MUST be `http.request.method`. Because every Janus
route is static, `http.route` is available at span creation — the semconv
requires it to be set then when available. The path is never used as the target.

The GenAI CLIENT span name follows *"Span name SHOULD be
`{gen_ai.operation.name} {gen_ai.request.model}`"*, with
`gen_ai.operation.name` from the well-known set: `chat` for OpenAI Chat and
Anthropic Messages, `embeddings` for the embeddings modality,
`generate_content` for image/audio/video generation.

**Why per-attempt CLIENT spans.** A retry or failover leg is a distinct network
call with its own latency, status, and upstream. Collapsing them would lose the
exact information the failover cascade exists to produce, and would disagree
with `usage_events`. Sibling spans are the correct model and match OTel's own
guidance that one client request may involve multiple server-side operations.

### 5.2 Span fields

| Field | Source |
|---|---|
| `traceId` | `janus_trace` (inbound `traceparent` or minted) |
| `spanId` | minted per span (8 random bytes, non-zero) |
| `parentSpanId` | SERVER: inbound parent (or absent); CLIENT/INTERNAL: the SERVER `spanId` |
| `name` | §5.1 |
| `kind` | §5.1 |
| `startTimeUnixNano` / `endTimeUnixNano` | monotonic → wall-clock anchored at span start |
| `attributes` | §5.3 |
| `status` | §5.4 |
| `traceFlags` | sampled bit only |

**Clock discipline.** `erlang:monotonic_time` is the duration source (as
`usage_events.latency_ms` already is); wall-clock nanoseconds are captured once
at span start and durations are added to it. This avoids the wall-clock
regressions that would otherwise produce negative spans.

### 5.3 Attributes

SERVER span (`/v1/chat/completions` example):

| Attribute | Type | Level | Source |
|---|---|---|---|
| `http.request.method` | string | Required | literal `POST` |
| `url.scheme` | string | Required | `http`/`https` from listener config |
| `url.path` | string | Required | request path (static route, low cardinality) |
| `http.route` | string | Cond. Required | the matched route |
| `http.response.status_code` | int | Cond. Required | terminal status |
| `error.type` | string | Cond. Required | status as a string on 5xx (§5.4) |
| `server.address` / `server.port` | string/int | Opt-In | listener config, off by default |
| `network.protocol.version` | string | Recommended | `1.1` |
| `janus.agent_key.id` | int | — | ledger attribution (see §5.6 naming rule) |
| `janus.model.requested` | string | — | client's original model name |

CLIENT span (GenAI):

| Attribute | Type | Level | Source |
|---|---|---|---|
| `gen_ai.operation.name` | string | Required | §5.1 set |
| `gen_ai.provider.name` | string | Required | explicit catalog-name → well-known-value table (§5.9) |
| `gen_ai.request.model` | string | Cond. Required | resolved model name |
| `gen_ai.request.stream` | bool | Cond. Required | stream flag |
| `gen_ai.response.model` | string | Recommended | upstream-reported model |
| `gen_ai.response.finish_reasons` | string[] | Recommended | from the terminal frame |
| `gen_ai.response.time_to_first_chunk` | double | Recommended | **new measurement** — see §5.8; not the existing TTFB clock |
| `gen_ai.usage.input_tokens` | int | Recommended | `janus_usage_parse` |
| `gen_ai.usage.output_tokens` | int | Recommended | `janus_usage_parse` |
| `gen_ai.usage.cache_read.input_tokens` | int | Recommended | **fixes F9** |
| `error.type` | string | Cond. Required | provider-native code or status |
| `server.address` / `server.port` | string/int | Cond./Rec. | provider host |
| `janus.attempt` | int | — | 1-based, matches the ledger |
| `janus.outcome` | string | — | the ledger's `outcome` value |

Notes that are easy to get wrong, and are therefore normative here:

- The attribute is `gen_ai.provider.name`, **not** `gen_ai.system`. The rename
  landed in the GenAI semconv; emitting `gen_ai.system` would produce a
  silently-ignored legacy key.
- `gen_ai.client.token.usage` **no longer exists**. It was replaced by
  per-direction usage metrics. Do not emit it.
- `gen_ai.client.operation.duration` is **displaced for inference** (not
  deleted); the inference duration metric is
  `gen_ai.client.inference.duration`. The generic instrument still applies to
  embeddings and retrieval, which Janus also serves.
- `gen_ai.usage.cache_creation.input_tokens` was renamed to
  `gen_ai.usage.cache_write.input_tokens`.
- The GenAI conventions are at stability **Development** (experimental). The
  spec must therefore pin the semconv version it targets and treat renames as
  expected maintenance, not as regressions. `OTEL_SEMCONV_STABILITY_OPT_IN` is
  honored for the HTTP family so a future stable HTTP release is a config
  change, not a re-instrumentation.

### 5.4 Status

| Condition | `status.code` | `status.message` | `error.type` |
|---|---|---|---|
| HTTP 1xx–3xx | UNSET | — | not set |
| HTTP 4xx on SERVER | UNSET | — | not set on SERVER |
| HTTP 4xx on CLIENT | ERROR | redacted code (§5.4a) | provider code or `4xx` |
| HTTP 5xx | ERROR | redacted code (§5.4a) | status as string, e.g. `"502"` |
| Transport failure / timeout | ERROR | error class | `timeout`, `transport_error`, … |
| Stream aborted mid-flight | ERROR | `worker_lost`/`closed` | matching `error.type` |

The semconv rule is `error.type` = *"the status code number (represented as a
string)"* for an HTTP error — so `"502"`, not `"HTTP 502"` and not a sentence
from the body. `error.type` must stay low-cardinality.

### 5.4a `status.message` must never carry raw provider text

The obvious placement for a provider's own error sentence is `status.message`.
That is a privacy defect, not a convenience: an upstream 4xx/5xx body routinely
echoes back fragments of the request — model names, tool arguments, and in the
worst case prompt bytes — and `status.message` is a new sink that ships to a
collector with different retention and access controls than the Postgres
ledger.

The rule:

- `status.message` carries a **code**, not prose: the provider-native
  `error.type` value plus a fixed, closed-enum short reason
  (`upstream_error`, `timeout`, `transport_error`, `worker_lost`,
  `translate_unsupported`, …). These are the same classes
  `janus_http_proxy:failover_classify/2` already produces.
- Provider free text, when an operator genuinely needs it, follows the
  **existing** redacted channel rather than a new one: `usage_events.error_detail`
  (clamped to 512 bytes at the writer) is already scrubbed for Bearer/`sk-`/
  `gsk-`/`AIza`/PEM patterns by the same discipline `janus_task_run` uses.
  Extending that channel is in scope; creating a second, unredacted one is not.
- If a value does not match the allowlist, it is replaced by the generic code.
  Never pass provider bytes through by default, and never rely on clamping as a
  privacy control — clamping bounds length, not content.

This is stricter than the semconv *suggests*; the semconv has no opinion on
provider text because it assumes an SDK in a trusted process. The project's
no-content rule (§3.3 item 3) is the binding constraint here.

This exactly mirrors what `janus_http_proxy:failover_classify/2` already decides,
so the span status is a projection of an existing single-source classifier — not
a second, divergent judgement.

### 5.5 What is deliberately not a span

- **Quota checks, auth, JSON parsing** — sub-millisecond, high volume; INTERNAL
  spans would swamp any backend for no diagnostic value. They remain counters.
- **Translation** — INTERNAL, opt-in. Usually microseconds, but when a
  translation bug is suspected it is the one thing you want to see.
- **Master→worker dispatch** — INTERNAL, opt-in. Represents queue wait plus
  relay; this is a genuinely useful span *when workers are slow*, which is
  precisely when the extra volume is affordable.
- **Auto-router judge calls** — these are separate LLM calls. They get their own
  CLIENT span under the same trace (a child of the SERVER span, sibling to the
  attempted model call), because attributing judge latency to the main request
  is the single most common routing mystery.

### 5.6 Attribute naming for Janus-specific keys

Vendor attributes must be namespaced. The prefix is `janus.` with dot-separated
segments and snake-free lowercase (`janus.agent_key.id`, `janus.attempt`,
`janus.outcome`, `janus.model.requested`). This is the semconv
attribute-naming rule applied to a non-standard namespace: reverse-domain-ish
prefix, dot separators, no mixed case. It keeps Janus keys visually distinct
from semconv keys and from other vendors' attributes in a shared collector.

### 5.7 Span limits

The spec defines per-span limits so a single pathological request cannot grow a
span without bound: 128 attributes, 128 events, 128 links, and 64 levels of
value depth. Janus adopts those defaults. The one place it departs is the
attribute **value length** limit, whose spec default is *no limit* — that
default is incompatible with the bounded-memory invariant, so Janus sets one.

The limits are fixed values, not vague intentions, because a requirement an
implementer can satisfy differently is not a requirement:

| Limit | Value | Basis |
|---|---|---|
| Attributes per span | 128 | spec default |
| Events per span | 128 | spec default |
| Links per span | 128 | spec default |
| Attribute value depth | 64 | spec default |
| **Attribute value length** | **1024 bytes** | Janus choice; matches the existing 1024-byte cap on `janus_task_run` error text |
| Attributes per event / per link | 128 | spec default |

The choice of 1024 bytes rather than a looser value is deliberate: it
holds any semconv attribute this design emits (URLs, model names, error codes)
while a single attribute cannot contribute more than 1 KiB to a span. There is
**no knob to disable the value-length limit** — only to lower it — because
"unlimited" is exactly the state the invariant forbids.

The mechanism is the same one the metrics registry uses — a cap plus a counted
overflow, never silent truncation. Attributes beyond a count limit are
discarded; values beyond the length limit are truncated at a character boundary
(never mid-codepoint, which would emit invalid UTF-8 and fail the OTLP encode).
`droppedAttributesCount` is set on the span and
`janus.telemetry.span.truncated` increments. The spec requires dropped-item
counts to be reportable by exporters and the limits to be programmable, so the
counts ride the same settings key as the rest of the export config.

The same reasoning applies to `error.type`/`status.message`: §5.4a forbids raw
provider text there entirely, which is stronger than any length cap.

### 5.8 Time to first chunk — do not reuse the TTFB clock

`gen_ai.response.time_to_first_chunk` is `Recommended`, and the obvious
implementation — reuse the existing TTFB measurement — is wrong in **two
independent ways**. Both are `MUST`-level, and both are invisible to a test that
only asserts "the attribute is populated".

**Defect 1: the existing clock starts too late.** `TtfbStart` is captured at
dispatch-ack receipt (`janus_http_worker_client.erl:537-538`, comment: "TTFB
clock starts at ack receipt"). The semconv requires measuring *"from the start
of a logical inference operation — before auth and the first attempt, including
retries"*. The existing clock therefore excludes auth, quota admission, routing,
queueing, dispatch, and every retry backoff — precisely the latency a gateway
exists to add. Reusing it under-reports and would make the gateway look faster
than it is. The measurement anchor MUST move to handler entry
(`janus_http_preamble.erl:70-87`, `janus_modality.erl:47-55`).

Note that the existing `janus_usage_ctx.started`
(`janus_http_proxy.erl:139-144`) is the natural value to reuse for the span's
own start, but it is captured at **proxy** entry — after auth and quota
admission — so it is still too late for TTFC. The two timestamps serve
different purposes and must not be conflated: `started` measures the proxy's
own work for `latency_ms`, while TTFC must measure the whole logical operation
from the moment the request entered the handler.

**Defect 2: a chunk is not a frame.** The semconv defines a chunk as *"a decoded
provider stream event carrying new, non-empty output"* and states that
instrumentations *"MUST NOT treat empty start events or events carrying only
usage, roles, IDs, signatures, keep-alives, progress/status updates, or end
markers as chunks"*. Janus currently measures the first **forwarded frame**
(`janus_http_proxy.erl:1744-1760`), which for both OpenAI and Anthropic is
typically the role-only start event — exactly the case the spec forbids.

So the implementation needs a **content-bearing predicate** over the already
parsed SSE events: text delta, refusal, reasoning, audio, image, or tool-call
name/arguments — and *not* role-only, usage-only, id/signature-only, keep-alive,
or end-marker events. `janus_http_proxy` already parses every event for usage
capture (`capture_usage_chunk/1`), so the predicate attaches at the same seam;
no new parser is required.

Two consequences worth stating:

- **No data source exists today.** The TTFB value feeds only the health EWMA
  (`janus_http_worker_client.erl:769-774` → `janus_worker_pool.erl:1591-1604`)
  and is never exported as a metric or a `/stats` field. Emitting the attribute
  requires a genuinely new export path, not a read of an existing one.
- **`MUST NOT` set it if no chunk is received.** A stream that ends with no
  content event (immediate error, empty completion) must omit the attribute
  rather than record the first frame's timestamp. Absence is the honest signal.

### 5.9 Two Required attributes with no source today

Both are `Required` by the semconv and both currently have no data behind them.
Neither may be fabricated.

**`gen_ai.provider.name`.** The only provider identity Janus holds is the
operator-defined catalog name (`route_provider_name/1`,
`janus_http_proxy.erl:3718-3722`), which is a free-form label like `dashscope`,
`aliyun`, or `openai-compatible` — it will not match a well-known enum value.
The spec therefore needs an explicit mapping table:

| Catalog name (operator-defined) | `gen_ai.provider.name` |
|---|---|
| `openai`, `azure-openai` | `openai` / `azure.ai.openai` |
| `anthropic` | `anthropic` |
| `deepseek` | `deepseek` |
| `mistral` | `mistral` |
| *anything unmapped* | the catalog name verbatim (custom value) |

A custom value is explicitly permitted — the enum's well-known values are
"if one of them applies … otherwise a custom value MAY be used". What is *not*
permitted is inventing a well-known value for a provider that is not that
provider, because `gen_ai.provider.name` is a discriminator the backend uses to
pick the right attribute flavour.

The upstream enum is currently inconsistent (`mistral_ai` in one file, `mistral`
in another, same repo), which is why §4.3 pins a commit SHA rather than a date.

**`gen_ai.token.modality`.** Required on the `input_tokens`,
`output_tokens`, `cache_read.input_tokens`, and `cache_write.input_tokens`
counters; **not** on `reasoning.output_tokens`, which dropped it on 2026-11-05.
Janus cannot determine modality anyway: providers fold image and audio input
into `prompt_tokens`, so after the F9 fix we know the token *count* but not its
modality mix. The semconv permits `unknown` for exactly this case. Mandate
`unknown`; do **not** infer `text`, which would fabricate a dimension and
silently misreport image/audio traffic as text.

## 6. Propagation design

### 6.1 Extraction

- `traceparent`: honor only the version-`00` 55-byte shape with lowercase hex
  and non-zero ids — **keep the existing fixed-shape parser's strictness for the
  fields it validates**. It is already correct and test-pinned.
- **One parser change is required: forward-compatible versions.** The current
  `parse/1` matches `<<"00-", …>>` and rejects everything else, so an inbound
  `traceparent` from a W3C-conformant peer that upgraded to version `01` restarts
  the trace. W3C Trace Context §3.2.2 says a header of at least 55 characters
  whose version prefix parses should be read **using the version-`00` format**,
  and that vendors MUST NOT assume anything about unknown fields. So: accept
  `version` = any two lowercase hex digits except `ff`, and when `version` ≠
  `00` parse the first four fields only and ignore the remainder. Restart the
  trace only when the header is shorter than 55 characters or the version
  prefix is unparseable.
- `tracestate`: **newly parse and retain** up to the W3C limits (32 members,
  256 chars per entry). It is carried opaquely: Janus does not interpret vendor
  entries, it preserves them.
- A `tracestate` arriving without a valid `traceparent` MUST be discarded (W3C
  §4.2), and on a malformed `traceparent` Janus MUST NOT attempt to parse
  `tracestate` (W3C §3.3).
- Extraction MUST NOT throw and MUST NOT overwrite an already-valid context —
  both are propagator-contract requirements, and both hold trivially in the
  current total-function style.
- Baggage: out of scope for this phase (§12), but the extraction seam is
  written so a baggage propagator can be added without touching call sites.

### 6.2 Injection

- Upstream request headers get a fresh `traceparent` per attempt (a new
  `spanId` — this is the span, so the ids finally agree) plus the preserved
  `tracestate`.
- The **sampled bit becomes the computed decision**, not `01`.
- Downstream responses get a W3C `traceparent` **in addition to** the existing
  `x-trace-id`. Keeping `x-trace-id` preserves the current client contract; the
  additive header is what makes Janus a conformant link in a client's trace.

Three W3C mutation rules constrain the injector, and each is easy to violate:

1. If `traceparent` is unchanged, `tracestate` MUST NOT be modified either.
   Janus *does* change `traceparent` (new parent-id per attempt), so it may
   mutate `tracestate`.
2. When mutating, the order of unmodified entries MUST be preserved, and
   modified keys SHOULD move to the front.
3. The header MUST be downgraded to the lowest version the sender supports
   before emitting; Janus emits version `00`, so a forwarded higher-version
   header is rewritten, not echoed.

### 6.3 Master→worker

The wire map gains `tracestate` alongside the existing `trace_id`, plus the
master's SERVER `spanId` as the worker's parent. The worker then mints its own
CLIENT span id, making the parent/child chain intact across the hop.

Rolling-deploy safety is already established: `validate_job_fields/1` requires
seven keys and ignores extras, and `janus_trace:from_trace_id(undefined)` mints
when the key is absent. Old↔new peers degrade to today's behaviour.

## 7. Sampling design

### 7.1 Model

Parent-based head sampling, which is the only model that needs no coordination:

```
Root (no inbound traceparent):  TraceIdRatioBased(ratio, default 0.05)
Else (inbound traceparent):     ParentBased — always inherit the parent's decision
```

Rationale: an LLM gateway's spans are dominated by long streams; tail sampling
would require buffering complete requests, which conflicts with the bounded-
memory invariant. Parent-based is also what a caller expects — if their trace is
sampled, the gateway must contribute to it.

Two precision points that matter normatively:

- The SDK's **default** sampler is `ParentBased(root=AlwaysOn)`. Janus departs
  from that default deliberately, because as the front door it is the *root*
  for most traffic; `AlwaysOn` at 5%-worth-of-traffic volumes would be a
  self-inflicted outage. The departure is explicit in config, documented, and
  overridable (`OTEL_TRACES_SAMPLER=parentbased_always_on` restores the spec
  default).
- `TraceIdRatioBased` is deprecated in favour of `ProbabilitySampler` (W3C
  Trace Context Level 2 consistent probability sampling). The spec requires
  implementations to keep `TraceIdRatioBased` working until at least
  2027-01-01, so Janus implements it as specified — deterministic hash of the
  trace id, and **monotone** (a lower ratio's sampled set must be a subset of a
  higher ratio's). Monotonicity is the property that makes raising the ratio
  during an incident safe; a naive `%`-based implementation breaks it.

### 7.1a The `IsRecording` / `Sampled` distinction

The spec defines two independent properties and forbids one combination:

| `IsRecording` | `Sampled` | Processor sees | Exporter sees |
|---|---|---|---|
| true | true | yes | yes |
| true | false | yes | **no** |
| false | true | **forbidden** | **forbidden** |
| false | false | no | no |

The SDK rule *"MUST NOT allow"* `Sampled=true ∧ IsRecording=false` exists
because it creates gaps in a distributed trace. Janus must therefore never emit
`flags=01` on a span it does not record — which is exactly the F2 defect, now
expressed as a normative constraint rather than a style preference.

### 7.2 Consequences

- **Exported ⇒ sampled ⇒ recorded — one direction only.** The SDK rule *"Span
  Exporters MUST receive those spans which have Sampled flag set to true and they
  SHOULD NOT receive the ones that do not"* is honored by creating an export
  record only for sampled spans. The converse does **not** hold: per §7.1a,
  `IsRecording=true ∧ Sampled=false` is legal and normative — such a span is
  processed but not exported. So the invariant is stated one-way; writing
  "sampled = recorded = exported" would contradict the table.
- **Janus uses `RECORD_AND_SAMPLE` and `DROP` only.** No Janus code path
  returns `RECORD_ONLY`, so in practice recorded and exported coincide *today*,
  and that is what E6 asserts. The distinction is preserved in the model anyway
  so a future `AlwaysRecord`-style knob (or a downstream `OTEL_TRACES_EXPORTER=none`
  run) is a config change rather than a re-instrumentation.
- **`usage_events` is NOT sampled.** It is the billing and reliability ledger.
  Sampling it would silently under-count traffic. Traces sample; the ledger does
  not. This separation is explicit because it is the mistake this design most
  invites.
- **Metrics are NOT sampled.** Counters and histograms aggregate; sampling them
  would corrupt every rate calculation.
- **Id minting is unconditional.** Even on an unsampled trace, ids are minted
  and propagated — a downstream decision to record must remain possible, and
  `usage_events.trace_id` must keep working at 100% coverage.

## 8. Metrics design

### 8.1 Strategy

Keep the existing ETS registry and Prometheus endpoint, and add OTLP export as a
**second view over the same counters**. Do not build a parallel metrics system:
the ETS registry already solves atomic increments, cardinality caps, and scrape
races, and `/metrics` has downstream consumers (scrape config, alert pack,
Grafana dashboard) that must keep working.

The change is therefore: (a) rename/add series to semconv names where a semconv
name exists, (b) attach units, (c) emit the GenAI metrics that do not exist.

### 8.2 Required series

| OTel name | Type | Unit | Buckets / attributes |
|---|---|---|---|
| `http.server.request.duration` | Histogram | `s` | `[0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 7.5, 10]`; Required `http.request.method`, `url.scheme` |
| `gen_ai.client.inference.duration` | Histogram | `s` | `[0.01, 0.02, 0.04, 0.08, 0.16, 0.32, 0.64, 1.28, 2.56, 5.12, 10.24, 20.48, 40.96, 81.92]`; Required `gen_ai.operation.name`, `gen_ai.provider.name` |
| `gen_ai.client.inference.usage.input_tokens` | Counter | `{token}` | per §8.3 |
| `gen_ai.client.inference.usage.output_tokens` | Counter | `{token}` | per §8.3 |
| `gen_ai.client.inference.usage.cache_read.input_tokens` | Counter | `{token}` | per §8.3 |
| `gen_ai.client.inference.usage.cache_write.input_tokens` | Counter | `{token}` | per §8.3; **pairs with F9's second merged dimension** |
| `janus.usage.writer.dropped` | Counter | `{event}` | preserved from `usage_writer_dropped_total` |
| `janus.usage.writer.buffered` | Gauge | `{event}` | preserved from `usage_writer_buffered_rows` |
| `janus.telemetry.export.dropped` | Counter | `{span}` | **new** — the exporter's own loss |
| `janus.telemetry.export.failed` | Counter | `{batch}` | **new** — the exporter's own failures |

### 8.3 The long-tail histogram problem

`gen_ai.client.inference.duration`'s prescribed ladder tops out at **81.92 s**.
A reasoning model streaming for five minutes lands entirely in `+Inf`, which
destroys the quantile. There are two ways to fix this and the choice is left
open (§15 decision 5), because they trade a conformance argument against an
extra series:

| Option | Shape | Trade-off |
|---|---|---|
| **A. Extended ladder** | Prescribed 14 bounds byte-exact as a prefix, then `[163.84, 327.68, 655.36, 1310.72]` | One series, full resolution — but a recorded deviation from the advisory ladder |
| **B. Side histogram** | Prescribed ladder byte-exact; separate `janus.genai.long.duration` for the >81.92 s tail | Zero deviation to defend, same tail resolution — but two series to query |

Either is defensible. What is *not* acceptable is the status quo shape: the
existing `request_duration_seconds` ladder has five buckets above 30 s and none
below 50 ms, which loses resolution exactly where auth rejects and cache hits
live. Whatever option is chosen, the prescribed bounds must appear
**unaltered and in order** — an approximating ladder is the failure mode this
section exists to prevent.

Token metrics carry `gen_ai.token.modality` (`text`/`image`/`audio`/`unknown`)
— **Required on four of the five usage counters, but not on
`reasoning.output_tokens`**, from which it was removed on 2026-11-05 precisely
because reasoning counts are not split by modality. Emitting it there produces a
non-conformant measurement in the `unknown` bucket, so the mapping table must
carry a per-instrument exception rather than applying modality uniformly.
`gen_ai.provider.name` and `gen_ai.request.model` are the discriminators that
make the series useful; model *name* is bounded by the catalog, which is the
same justification the existing code uses for the `provider` label.

### 8.4 The `janus_` prefix

Existing Prometheus series keep their `janus_` names (removing them would break
dashboards). OTLP export uses semconv names where one exists and the `janus.`
namespace otherwise. The two views are generated from the same counters, so
they cannot drift numerically; a rendering test asserts the pairing.

### 8.5 Metrics fallback: collector-side bridge

Reimplementing the OTLP metrics data model (sums/gauges/histograms with
temporality and `startTimeUnixNano` bookkeeping) is materially more work than
spans. If P3 must be deferred, the cheap correct move is a collector-side
`prometheusreceiver` pointed at the existing `/metrics` — **zero gateway
changes**, and the resulting series are genuinely OTLP. The loss is the unit
metadata and semconv naming, which is exactly what P3 fixes. This is recorded
so deferring P3 is a scheduling decision, not an architectural blocker.

### 8.6 Two counters, one truth

`janus_http_stats` (`/stats`) and `janus_metrics` (`/metrics`) each count the
same requests independently (F14). OTLP must export from **one** of them. The
decision: `janus_metrics` is authoritative, because it already has labels,
cardinality caps, and the scrape surface that downstream consumers use.
`janus_http_stats` stays as the `/stats` JSON fast path and is documented as a
derived convenience, not a second source.

## 9. Export design

### 9.1 Configuration

| Knob | Env var | Settings key | Default |
|---|---|---|---|
| Enable export | `JANUS_OTEL_ENABLED` (`true` enables); `OTEL_SDK_DISABLED=true` honored as a hard off-switch | `telemetry.export.enabled` | off |
| Endpoint | `OTEL_EXPORTER_OTLP_ENDPOINT` | `telemetry.export.endpoint` | `http://localhost:4318` |
| Per-signal endpoint | `OTEL_EXPORTER_OTLP_{TRACES,METRICS,LOGS}_ENDPOINT` | — | derived |
| Protocol | `OTEL_EXPORTER_OTLP_PROTOCOL` | — | `http/json` (only supported value; `http/protobuf`/`grpc` rejected loudly at boot, not silently ignored) |
| Headers | `OTEL_EXPORTER_OTLP_HEADERS` | `telemetry.export.headers` | none |
| Timeout | `OTEL_EXPORTER_OTLP_TIMEOUT` | — | `10s` |
| Compression | `OTEL_EXPORTER_OTLP_COMPRESSION` | — | `gzip` when enabled |
| Service name | `OTEL_SERVICE_NAME` | — | `janus` |
| Resource attrs | `OTEL_RESOURCE_ATTRIBUTES` | — | merged over computed |
| Sampler | `OTEL_TRACES_SAMPLER`, `OTEL_TRACES_SAMPLER_ARG` | `telemetry.sampling.ratio` | `parentbased_traceidratio`, `0.05` |
| Signal selection | `OTEL_{TRACES,METRICS,LOGS}_EXPORTER` | `telemetry.export.signals` | `traces` only |

URL construction follows the exporter spec exactly: per-signal variables are
used as-is; otherwise the base URL is suffixed with `v1/traces`, `v1/metrics`,
`v1/logs`. Getting this wrong is the most common integration failure, so it is
called out as a test case.

### 9.2 Buffer and retry

Mirrors `janus_usage`'s proven writer, with the SDK's documented defaults as the
starting point. Note the two signals have **different** spec defaults:

| Parameter | Traces | Logs | Basis |
|---|---|---|---|
| Max queue | 2048 | 2048 | `maxQueueSize` |
| Max export batch | 512 | 512 | `maxExportBatchSize` |
| Schedule delay | 5000 ms | **1000 ms** | `scheduledDelayMillis` |
| Export timeout | 30000 ms | 30000 ms | `exportTimeoutMillis` |
| On full queue | drop newest, increment `janus.telemetry.export.dropped` | same | spec states only *that* spans/logs are dropped, not which; newest-drop matches `janus_usage` |
| On transient failure | exponential backoff with jitter, capped, bounded by the export timeout | same | exporter spec `MUST` |
| On permanent failure | count, log once per episode, drop the batch | same | bounded-memory invariant |

`maxExportBatchSize ≤ maxQueueSize` is asserted at config load.
ForceFlush runs on graceful shutdown, like `janus_usage`'s `terminate/2`.

**Which failures are retryable is normative, not a judgement call.** For
OTLP/HTTP only `429`, `502`, `503`, and `504` are transient. A `400` MUST NOT be
retried, and a response carrying `partial_success` MUST NOT be retried — retrying
either would duplicate accepted data. Jitter is mandatory, not an optimization:
the spec requires "exponential back-off with jitter … to avoid overwhelming the
destination". This matters because a naive implementation retries every non-2xx
and turns a collector misconfiguration into a self-inflicted load spike.

### 9.3 Resource

Computed once at boot, immutable thereafter (the spec requires Resource
stability across an SDK's lifecycle):

| Attribute | Value |
|---|---|
| `service.name` | `janus` (or `OTEL_SERVICE_NAME`) |
| `service.version` | release version |
| `service.instance.id` | `node()` + boot id |
| `telemetry.sdk.name` | `janus` |
| `telemetry.sdk.language` | `erlang` |
| `telemetry.sdk.version` | release version |
| `deployment.environment.name` | operator setting |
| `janus.role` | `master` / `worker` |
| `janus.git.sha` | `janus_build:sha/0` |
| `host.name` | `node()` host part |

Emitting `telemetry.sdk.*` for a hand-built emitter is honest: the spec uses
these to identify the producing telemetry library, and `janus` is that library.
One trap: `telemetry.sdk.name` MUST be `opentelemetry` for an actual OpenTelemetry
SDK. Claiming that value for a hand-built emitter would be a false statement, so
`janus` is the correct value and the difference is deliberate.

Also note `deployment.environment.name` (not `deployment.environment`, which is
deprecated since semconv v1.28.0). Resource is immutable by spec: changing
`service.name` requires a restart, and the config table above reflects that —
the endpoint is boot-time, only the sampler ratio is hot.

## 10. Logs design

### 10.1 Correlation

Every log record emitted while a span is active carries `traceId` and `spanId`,
and **no call site is edited to achieve it**.

Mechanism, in three parts, because the OTP detail decides whether this works at
all:

1. **Context side — process metadata set by the handler.**
   `logger:set_process_metadata/1` is called at span start with
   `#{trace_id => …, span_id => …}` and cleared at span end. This is the only
   piece that touches request code, it is one call per span, and it is
   fail-safe (wrapped like every other telemetry call).

2. **Transport side — a primary logger filter, not the formatter.**
   This is the subtle part and the one an implementer gets wrong. The formatter
   runs inside the **handler process** for a direct `logger:` call, but it runs
   in the **handler's own process only by accident** — for reports routed
   through a handler process or a proxy, `format/2` may execute elsewhere, and
   reading the process dictionary from there would read the wrong dictionary or
   none at all. Metadata, by contrast, is captured by `logger` at the call site
   and carried in the event's `meta`. A `logger` **primary filter** therefore
   stamps `meta.trace_id`/`meta.span_id` from the process metadata, and the
   formatter only *reads* `meta` — never a process dictionary. Filters run in
   the calling process, which is exactly where `set_process_metadata/1` put the
   values.

3. **Render side — one formatter.** `janus_log_fmt:format/2` emits
   `trace_id=… span_id=…` when `meta` carries them. Because every log line in
   the gateway renders through this one formatter (`janus_log:setup/0` installs
   it for both the stdout and rotating-file handlers), all 249 `logger:` call
   sites are covered without editing any of them.

The pdict (`janus_trace`'s existing convention) remains the source the *handler*
publishes from — it is read once at span start, not by the formatter. No second
source of truth, and no logger code path reaches into a process dictionary it
does not own.

The alternative — touching 249 call sites — is neither reviewable nor safe, and
the alternative of a custom logger handler is redundant: the formatter is
already the single funnel, and a handler would need its own bounded queue.

Absence is explicit: a line emitted outside any span (boot, background tasks,
the writer's own errors) carries no `trace_id`. That is correct and must not be
back-filled with a fabricated id.

This closes F8 for the *text* log stream. The OTLP log record's
`traceId`/`spanId` fields (§10.2) come from the same metadata.

### 10.2 OTLP log export

Opt-in, off by default. When enabled, records are mapped to the OTLP log data
model: `timeUnixNano`, `severityNumber`/`severityText` from the logger level,
`body` = the rendered message, `attributes` = the flattened `what`/field map,
plus `traceId`/`spanId`.

The severity mapping is the only non-obvious part. OTLP defines six bands over
1–24 (TRACE 1–4, DEBUG 5–8, INFO 9–12, WARN 13–16, ERROR 17–20, FATAL 21–24);
OTP's logger levels map onto the mid-point of each band:

| OTP level | `severityNumber` | `severityText` |
|---|---|---|
| `debug` | 5 | `DEBUG` |
| `info` | 9 | `INFO` |
| `notice` | 10 | `INFO2` |
| `warning` | 13 | `WARN` |
| `error` | 17 | `ERROR` |
| `critical` | 18 | `ERROR2` |
| `alert` | 21 | `FATAL` |
| `emergency` | 22 | `FATAL2` |

`severityNumber ≥ 17` is normative, not cosmetic: the spec states it "is an
indication that the log record represents an erroneous situation", so backends
count errors from it. Mapping `warning` into the ERROR band would misreport
every recoverable provider hiccup as an error.

Note that the Logs SDK's batching defaults differ from the Trace SDK's:
`maxQueueSize` 2048, `scheduledDelayMillis` **1000**, `exportTimeoutMillis`
30000, `maxExportBatchSize` 512. The trace and log buffers are therefore
configured independently, not shared.

### 10.3 What does not become a log record

The in-memory rings (`janus_log_tail`, `janus_ops_tail`) are *pull* buffers for
the dashboard, not sinks. They keep their current shape and consumers. OTLP log
export taps the logger, not the rings — otherwise ops events would need a
semantic mapping nobody asked for.

## 11. Management-plane design (P5)

The dashboard is the *sole config writer* against the shared Postgres and owns
no gateway tables. P5 is therefore strictly additive and carries its own
constraints.

### 11.1 What to instrument

Instrumenting the FastAPI request surface (128 routes, one operator) is cheap
but nearly worthless. The value is in the **poll loops**, which are the
dashboard's only real backend work:

| Span | Kind | Per |
|---|---|---|
| `GET {node} /stats` (+ `/stats/sched`, `/stats/logs`, `/stats/health`, `/stats/ops-events`) | CLIENT | node × endpoint × 10s cycle |
| `ops drain` | INTERNAL | per successful health poll |
| `alert evaluate` | INTERNAL | per cycle |
| `GET /api/...` | SERVER | per operator request |

The CLIENT spans are what make the dashboard a trace participant: they carry
`http.request.method`, `server.address`, `http.response.status_code`, and — once
the gateway accepts `traceparent` (§6) — the gateway's own spans join the same
trace. That is the whole point of instrumenting the poller.

### 11.2 Wiring

- Provider lifecycle belongs in the existing `lifespan` block
  (`main.py:76-159`), which already owns ordered startup and reverse-ordered
  shutdown; `force_flush`/`shutdown` go on the way out so a deploy does not lose
  the last batch. The mounted MCP sub-app's lifespan is driven by the host, so an
  instrumented mount must not rely on the sub-app.
- Config splits by nature: **endpoint/headers/protocol at boot** (`config.py`
  env idiom, because the provider is process-lifetime), **enable and sampling
  ratio** through the existing DB-backed hot-knob template
  (`routers/settings.py:1481-1524`, the `dash.mcp` precedent) with the
  `?role&reason` breakglass + audit trail, default off.
- Both install paths must carry the env: the container
  (`Dockerfile:15`) and the bare-metal systemd `EnvironmentFile`
  (`deploy/janus-dash.service.template:66-70`), which is generated from the
  compose service definition. `Dockerfile.dev` hard-codes a dependency list that
  already drifts from `pyproject.toml` — a trap for anyone adding a package.
- **Span creation must never be awaited on the hot path.** The six loops are
  latency-coupled by explicit comment; adding synchronous export inside them
  would break the cadence the whole failure-observability system depends on.
- The exporter must not share the DB pool or hold a transaction: statement
  timeouts are 2s (alerts) / 5s (ops) against a `min 2 / max 10` pool.

### 11.3 The SPA trace pivot

The trace id already reaches the SPA as display-only text
(`spa/src/pages/shared.tsx:577-582`) and the API already accepts `?trace_id=`
(`routers/usage.py:419-458`), but the timeline dialog is keyed by `request_ref`
only. P5 makes the trace id a link: clicking it opens the timeline resolved by
`trace_id`. This is a one-line SPA change over an existing, tested endpoint —
the cheapest observable win in the whole project.

Per `dashboard/DESIGN.md`, the surface stays within the existing four nav groups
(the trace view is a dialog under Observe, not a new page), uses semantic
tokens, mono font for the id, and a real stale/partial state when the terminal
row has not landed (the endpoint already distinguishes "in flight" from "not
found" — that distinction must be shown, not collapsed into an error).

## 12. Rollout

Ordered so each phase is independently useful and independently revertible.

| Phase | Content | Exit criteria |
|---|---|---|
| **P0 — Correctness floor** | Honest sampled bit; `tracestate` extract/inject; forward-compatible `traceparent` versions; response `traceparent`; span ids on the wire; `trace_id` in log lines; fix F9 (`cache_read_input_tokens`); fix F12 (`outcome` asymmetry) | **No collector involved.** Assert on emitted artifacts directly: an outbound `traceparent`'s flag byte matches the computed decision (curl a stub upstream and read the header); `tracestate` round-trips on request and response; a `01`-version inbound header continues the trace instead of restarting it; a request log line carries `trace_id`; `cache_read_input_tokens` and `cache_write_input_tokens` are non-null for an Anthropic response; a local 200 and a worker 200 both record `outcome='completed'` |
| **P1 — Spans** | SERVER + CLIENT spans, attribute sets, status mapping, GenAI attributes, `usage_events` span-id columns | In-process: one request yields 1 SERVER + N CLIENT spans with correct parent/child nesting and semconv attributes, asserted from the exporter's buffer before any network send |
| **P2 — Export (traces only)** | OTLP/HTTP JSON trace exporter, resource, buffer/retry, drop counters | A real collector accepts OTLP/HTTP-JSON **spans**; killing the collector loses spans but never requests, and the buffer stays bounded over 10k requests |
| **P3 — Metrics alignment** | semconv names/units, `http.server.request.duration`, GenAI token+duration metrics, long-tail buckets | Both `/metrics` and OTLP report the same numbers (§8.5 is the sanctioned fallback if this slips); the Prometheus view is unchanged while export is off |
| **P4 — Logs** | trace correlation via the logger filter; OTLP log export | A log record's `traceId` matches its span's end to end, and **the collector accepts all three signals** — the three-signal gate lives here, not in P2 |
| **P5 — Management plane** | Dashboard's own OTel: request spans, its own `/metrics`, trace-pivot in the SPA | An operator clicks a failure row and lands on its trace |

P0 is not optional and does not depend on export: fixing the sampled flag and
adding `tracestate` makes the *existing* trace id genuinely useful to third
parties, which is a correctness fix, not a feature. F9 and F12 are also P0
because both are already-committed contracts that silently return wrong data;
they do not need the span machinery to be fixed. This is why P0's criteria are
asserted against emitted headers and stored rows rather than against a collector
— a gate that needs P2 to pass is not a P0 gate.

Each phase's gate is satisfiable **at that phase**, using only what that phase
and its predecessors deliver. A gate that requires a later phase's output is a
defect in the gate.

## 13. Verification

Per the repository's rules, E2E is the proof and unit tests are additive.

### 13.1 E2E matrix

| # | Scenario | Assertion |
|---|---|---|
| E1 | Single non-stream chat request, collector up | Collector receives 1 SERVER + 1 CLIENT span, same `traceId`, CLIENT's `parentSpanId` = SERVER's `spanId` |
| E2 | Inbound `traceparent` + `tracestate` with a vendor entry | Downstream response `traceparent` continues the trace id; upstream request carries the same `tracestate` entry |
| E3 | Two-attempt failover (first provider 500) | 1 SERVER + 2 CLIENT sibling spans; attempt 1 status ERROR with `error.type="500"`; attempt 2 UNSET |
| E4 | Streaming request | CLIENT span `gen_ai.response.time_to_first_chunk` populated with a value **measured from handler entry**; span ends only after drain completes |
| E4b | Streaming request whose first upstream event is role-only, then content | TTFC is anchored at the **content-bearing** event, not the role-only frame — the value must be strictly greater than the frame-arrival time (this is the §5.8 defect-2 regression test) |
| E4c | Stream that ends with no content event | `gen_ai.response.time_to_first_chunk` is **absent** (not 0, not the first-frame time) |
| E5 | Master→worker dispatch | Worker-side CLIENT span's `parentSpanId` equals the master's SERVER `spanId` |
| E6 | Sampled=false inbound (`traceparent` flags `00`) | No spans exported; ids still propagate; `usage_events.trace_id` still written |
| E7 | Collector unreachable | Requests succeed; `janus.telemetry.export.dropped`/`failed` increase; buffer stays bounded; no unbounded growth over 10k requests |
| E8 | Malformed `traceparent` (uppercase / wrong length / zero ids) | Fresh trace minted; `tracestate` discarded; no crash |
| E9 | Anthropic cache-read response | `gen_ai.usage.cache_read.input_tokens` in the span **and** non-null in `usage_events` |
| E10 | `OTEL_EXPORTER_OTLP_ENDPOINT` with a path prefix | Requests go to `<base>/v1/traces`; per-signal override used as-is |
| E11 | Knob off | Zero OTLP traffic; `/metrics` **carries every pre-existing series unchanged** (new semconv families appear only when export is on — see §13.4); `x-trace-id` still echoed |
| E12 | Log pivot | Log line for a request carries the same `traceId`/`spanId` as its SERVER span |

### 13.2 Durable artifacts

- The collector is run locally and its accepted payloads are dumped to a
  versioned directory; each E-row writes its received OTLP JSON there.
- A `scripts/verification/otel_conformance.sh` script validates the dumped
  payloads against the assertions (age of ids, hex shape, enum as integer,
  bucket monotonicity, required attributes present).
- Commit message references the artifact path.

### 13.3 Existing gates must stay green

`rebar3 compile`, `rebar3 fmt --check`, the non-vacuous EUnit gate, and the
dashboard's `lint_all.sh`. The Prometheus alert pack and Grafana dashboard must
still load — asserted by keeping the existing series names.

### 13.4 How P3's metric additions coexist with the Prometheus contract

There is a real tension here and it must be resolved explicitly, not left to the
implementer: P3 adds semconv-named families and unit metadata, while §3.3 item 9
promises the existing Prometheus series keep working. Emitting both
unconditionally would change `/metrics` output for every existing scrape, which
breaks alert rules, the Grafana dashboard, and any operator's `rate()` query.

The resolution:

- **Pre-existing series are never renamed, removed, or re-labeled.** The
  `janus_`-prefixed families in `?FAMILIES` stay byte-for-byte as they are. This
  is the contract §3.3 item 9 protects, and E11 asserts it.
- **New semconv families are additive and gated on the export knob.** With
  `JANUS_OTEL_ENABLED` unset they are not registered at all, so a knob-off
  deployment's `/metrics` is unchanged in content. With it on, they appear
  alongside the legacy series — a superset, not a replacement.
- **Unit metadata renders only when a family is exported.** OTLP needs units;
  the Prometheus text format has no unit field, so units live in the OTLP
  encoding and never alter the text output.
- **A deprecation, if ever, is a separate later decision** with its own release
  window. This document does not deprecate any existing series.

If an implementer finds that a semconv name collides with an existing `janus_`
name, they map the new instrument to the OTLP view only and leave the
Prometheus name alone. Renaming is never the answer.

### 13.5 Semconv drift gate

Because `?GENAI_SEMCONV_VERSION` is a moving target with no tagged releases
(§4.3), the pin needs a recurring check rather than a one-time review. At each
gateway release:

1. Re-fetch the pinned SHA's successor and diff the GenAI registry for renamed
   or removed attributes and instruments.
2. Fail the release if any name in `janus_otel_attr`'s mapping table no longer
   exists upstream — a silently-ignored attribute is worse than a build break,
   because it looks like success.
3. Record the new SHA in the release notes alongside the artifact path.

This is the only gate in this document that guards against *upstream* change
rather than a change in this repository, which is why it is called out
separately: tests can never catch it.

## 14. Risks

| Risk | Mitigation |
|---|---|
| GenAI semconv is Development and renames frequently | Pin the semconv version in a module constant; a single mapping table owns names; a rename becomes a table edit (§4.3) |
| OTLP export adds latency to the request path | Export is never synchronous with the request: spans close into a cast-fed buffer. Enforced by the same rule `janus_usage` follows |
| Cardinality explosion from provider/model attributes | Provider names are catalog-bounded; model names are catalog-bounded; an explicit cap with an `_overflow` sibling, as `?SCHED_FAMILY_CAP` already does. Note the pre-existing holes in F13 that must not be copied |
| Trace volume overwhelms a collector | Default ratio 0.05 and traces-only by default; metrics/logs export is opt-in |
| Stream spans held open for minutes exhaust the buffer | Span close is driven by the drain completion; in-flight spans are capped and the oldest-in-flight is dropped with a counter |
| Attribute values leak content | The Opt-In GenAI attributes stay off; the shape sentinel's structure-only rule is the review checklist item |
| TTFC silently reuses the existing TTFB clock and reports a conformant-looking but wrong value | §5.8 names both defects; E4b/E4c are the regression tests (content-bearing event, and absence when no chunk arrives) |
| A `Required` attribute is emitted with a fabricated value to satisfy the requirement | §5.9: `gen_ai.token.modality` is `unknown`, never inferred `text`; `gen_ai.provider.name` uses a real mapping or a custom value, never a borrowed well-known one |
| An upstream semconv rename silently invalidates an attribute (no error, just an ignored key) | §13.5 drift gate fails the release when a mapped name no longer exists upstream |
| Rolling deploy mixes span-aware and span-blind nodes | Additive wire keys; both directions already validated as tolerant |
| An unsampled trace still mints ids, so `flags` could be written `00` on a span that *is* recorded — the forbidden combination | The sampler decision gates span creation itself; a test asserts `Sampled=0 ⇒ no span object` |
| The dashboard exporter bypasses SSRF pinning | Pinning is a poll-path convention, not an enforced chokepoint (3 sites already bypass it) — so this is a **decision obligation**: adopt a pinning transport or record the bypass (§11.2) |
| Two counters (`/stats` vs `/metrics`) diverge and OTLP picks the wrong one | §8.6 names `janus_metrics` authoritative; the export reads only that registry |
| Metric attribute `endpoint`/`protocol` values are Janus enums, not semconv | P3 maps them; until then an OTLP consumer sees `janus.`-prefixed series that are honest but non-semconv |

## 15. Open decisions

1. **`url.scheme` sourcing.** The listener may or may not be behind TLS
   termination. Options: from listener config always, or from `X-Forwarded-Proto`
   when present. The semconv prefers the original client scheme. Recommendation:
   listener config, with an explicit override knob, because trusting a forwarded
   header would let a client inflate label cardinality.
2. **Metrics temporality.** OTLP supports cumulative and delta. The ETS registry
   is cumulative-by-nature. Recommendation: declare cumulative and do not offer
   delta in this phase.
3. **Whether `usage_events` gains `span_id`/`parent_span_id`.** Recommended yes —
   it makes the existing timeline API a true trace view and costs two nullable
   columns. The alternative (joining on `trace_id` + `attempt`) is fragile once
   retries are nested.
4. **Auto-router judge span visibility.** Recommendation: always emit (it is one
   extra span per routed request and it is the most-requested diagnostic), while
   the translate/dispatch INTERNAL spans stay opt-in.
5. **Long-tail histogram shape (§8.3).** Extended ladder vs side histogram.
   Recommendation: **B (side histogram)** — it keeps the prescribed 14 bounds
   byte-exact, so there is no conformance deviation to defend in review, and the
   tail query is a one-line aggregation. Prefer A only if a single series is a
   hard requirement for the dashboard.
6. **Retrieval-style traffic.** If Janus ever proxies a vector-search or
   retrieval API, the `gen_ai.retrieval.*` conventions are *not* the model —
   they describe a GenAI framework's own retrieval pipeline (span kind
   INTERNAL). A gateway calling a retrieval *service* records a CLIENT span
   under the db client conventions instead. Out of scope now; recorded so it is
   not mis-implemented later.

## Appendix B: P0 as built

P0 (the correctness floor) landed on branch `otel-alignment-p0` in six
commits, each reviewed before commit. The behaviour differs from this
document in four places worth recording, because each was discovered
while building rather than while specifying.

**1. Log correlation needed no formatter change.** §10.1 planned a
`logger` primary filter stamping `meta.trace_id`. It turned out OTP's
`logger:set_process_metadata/1` is captured at the call site and carried
in the event's `meta` already, and `janus_log_fmt` renders every
non-reserved `meta` key. So the whole feature is one call at handler
entry — no filter, no formatter edit, no call-site edits. The filter
would have been redundant work.

**2. The sampler must not memoize.** The first implementation cached the
resolved ratio in `persistent_term` on first read, which silently
defeated hot reload: a dashboard change would never reach a running
node. The ratio is now resolved per call; `persistent_term` reads are
lock-free and the config distributor already did the expensive part.

**3. The SQLite migration runner had a latent boot-breaker.** It split a
migration body on `;` *before* stripping `--` comments, so any migration
whose header comment contained a semicolon cut a statement in half and
failed at boot. Migration 029 was the first migration to trigger it
because it is the first with a multi-line header. Fixed (comments are
stripped first, quote-aware) and pinned by
`janus_db_sqlite_split_tests`.

**4. Invalid telemetry config fails closed.** The first version kept the
previous config on a validation error, so a typo left telemetry in
whatever state it was in while the operator believed their edit applied.
It now erases the config (the documented default, off) and logs why.

Two P0 items were built but are unused until P1: `usage_events.span_id`/
`parent_span_id` (nullable, never written) and `janus_req_started` (the
request-arrival anchor, read by nothing yet). Both are recorded here so a
reviewer does not mistake them for dead code.

## Appendix A: Implementer's checklist

Concrete file-level work, in P-phase order. Sizes are order-of-magnitude to help
sequencing, not estimates of effort.

### P0 — correctness floor (~1 day)

| # | Change | File |
|---|---|---|
| 1 | Add a sampler + store the sampled decision on the trace context; stop hardcoding flags `01` | `janus_trace.erl` |
| 2 | Parse and retain `tracestate` (32 members, 256 chars/entry); discard it when `traceparent` is invalid | `janus_trace.erl` |
| 3 | Forward-compatible `traceparent` versions (≥55 chars ⇒ parse first 4 fields; restart only on unparseable prefix or short header) | `janus_trace.erl` |
| 4 | Emit `traceparent` (+ `tracestate`) on responses alongside `x-trace-id` | `janus_http_preamble.erl`, `janus_http_decisions.erl`, `janus_modality.erl` |
| 5 | Add `trace_id` (and later `span_id`) to `janus_log_fmt` output when the pdict has a context | `janus_log_fmt.erl` |
| 6 | Split the merged cache sum: return `cache_read_input_tokens` **and** `cache_write_input_tokens` as distinct values instead of folding both into `prompt`; set both event keys (F9 has two dimensions, not one) | `janus_usage_parse.erl:91-97`, `janus_http_proxy.erl`, `janus_modality.erl` |
| 6b | Migration: `usage_events.cache_write_input_tokens` (nullable, both dialects) — the read column already exists, the write one does not | `priv/migrations/{postgres,sqlite}/029_*.sql` |
| 7 | Set `note_usage_outcome(ok)` on the local success path so local and worker 200s agree | `janus_http_proxy.erl:1810-1818` |
| 8 | Create the `telemetry` settings key + hot-reload branch (default off) | `janus_config.erl` (`distribute_settings/1`), dashboard `routers/settings.py` |
| 8b | Move the timing anchor to handler entry and store it for later TTFC use (the data source does not exist yet — see P1 item 14b) | `janus_http_preamble.erl`, `janus_modality.erl` |

### P1 — spans (~2-3 days)

| # | Change | File |
|---|---|---|
| 9 | New `janus_otel_span.erl`: record, `start/end`, monotonic→wall clock anchoring, attribute setter, status, bounded attribute count | new |
| 10 | New `janus_otel_attr.erl`: the single semconv name mapping table + `?GENAI_SEMCONV_VERSION` pin | new |
| 11 | SERVER span at handler entry (after auth), closed at terminal reply; `http.*` attributes | `janus_http_proxy.erl`, `janus_modality.erl` |
| 12 | CLIENT span per upstream attempt; `gen_ai.*` attributes; sibling per retry leg | `janus_http_proxy.erl` (`upstream_call/5`, `failover_record_attempt/3`) |
| 13 | Span status from the existing `failover_classify/2` single source — do not re-derive | `janus_http_proxy.erl` |
| 14 | Carry span context across the wire (add `tracestate` + master `spanId`) | `janus_http_worker_client.erl`, `janus_worker_wire.erl`, `janus_worker_session.erl` |
| 14b | Content-bearing chunk predicate + TTFC measurement from the handler-entry anchor (§5.8). Reuses the existing SSE parse seam; does **not** reuse `TtfbStart` | `janus_http_proxy.erl` (`capture_usage_chunk/1` area) |
| 15 | Migration: `usage_events.span_id`, `parent_span_id` (nullable, both dialects) — share the 029 file with item 6b | `priv/migrations/{postgres,sqlite}/029_*.sql` |

### P2 — export (~2 days)

| # | Change | File |
|---|---|---|
| 16 | New `janus_otel_export.erl`: bounded queue, batch flush, retry+jitter, drop counters, `terminate/2` flush | new |
| 17 | New `janus_otel_otlp.erl`: OTLP/HTTP-JSON encoder (hex ids, integer enums, lowerCamelCase) | new |
| 18 | Resource assembly at boot (immutable), env-var merge | new `janus_otel_resource.erl` |
| 19 | Supervisor wiring; default off (no process started when disabled) | `janus_core_sup.erl` |
| 20 | Export drop/fail counters into the existing registry | `janus_metrics.erl` |

### P3 — metrics (~2-3 days)

| # | Change | File |
|---|---|---|
| 21 | `http.server.request.duration` histogram with the semconv ladder + required attributes | `janus_metrics.erl`, `janus_metrics_render.erl`, `janus_http_proxy.erl` |
| 22 | `gen_ai.client.inference.duration` + token counters (+ `gen_ai.token.modality`) | same |
| 23 | Unit metadata on every family (`?FAMILIES` gains a unit field) | `janus_metrics_render.erl` |
| 24 | OTLP metrics view over the same ETS rows (cumulative temporality) | `janus_otel_otlp.erl` |
| 25 | Fix the `auto_tier_*` unbounded label values (F13) | `janus_http_proxy.erl:2607-2628` |

### P4 — logs (~1 day)

| # | Change | File |
|---|---|---|
| 26 | Logger handler that emits OTLP log records with `traceId`/`spanId` and the severity table | new `janus_otel_logs.erl`, `janus_log.erl` |
| 27 | Independent log buffer (1000 ms delay, 2048/512) | `janus_otel_export.erl` |

### P5 — management plane (~2 days)

| # | Change | File |
|---|---|---|
| 28 | Dashboard OTel provider in `lifespan`; CLIENT spans on the five poll endpoints; SERVER span middleware | `dashboard/app/main.py`, `nodes.py`, `ops_puller.py` |
| 29 | Decide the exporter's egress posture: pinning transport (`_PinNetworkBackend`) + body cap, **or** an explicit recorded bypass (pinning is a poll-path convention, not a chokepoint) | `dashboard/app/egress.py` |
| 30 | Dashboard `/metrics` + Resource | new router |
| 31 | SPA: trace id becomes a link that opens the timeline via `?trace_id=` | `spa/src/pages/shared.tsx` |

### Gates that must pass at every phase

- `rebar3 compile`, `rebar3 fmt --check`, `scripts/verification/assert_eunit_nonempty.sh`
- `dashboard/scripts/lint_all.sh`
- `scripts/verification/otel_conformance.sh` (new, §13.2)
- With `JANUS_OTEL_ENABLED` unset: `/metrics` carries every pre-existing series unchanged and emits **no new family** (the P3 additions are gated on the export knob, so the Prometheus contract holds — see §13.4), zero OTLP egress, `x-trace-id` still echoed
