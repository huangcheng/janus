# Modality Gateway — images / audio / video / computer-use — Plan

> For agentic workers: implement task-by-task with checkboxes. Testing
> rules from AGENTS.md: eunit FIRST for pure parsing/mapping with
> production-shaped fixtures (real multipart bodies, real SSE/binary
> chunk shapes, SMALLINT/binary keys); E2E gate for behavior; browser
> only for dashboard.

> rev 10 (final) — audit rounds 1-8 + official-spec alignment pass
> (video status queued/in_progress/completed/failed + documented
> cancelled, /v1/videos/{id}/content download endpoint, ASR
> verbose_json.duration first, images/TTS response_format enums
> explicit; two deliberate divergences remain, both listed in A1).
> Audit rounds 1-8 summary: loop closed at
> convergence (r8: 7/7, "converged and disciplined", remaining items
> were stale sentences + two micro-gaps). R8 applied: chunked-upload
> admission (no content-length → cap on first read + hard body cap),
> two-table idempotency guard order (video_jobs CAS is the sole
> authority; the usage row inserts only on CAS success). R7 summary: R7 (7/7 GO WITH FIXES) fixed:
> TTS commit unified to upstream_accept (A6 stale sentence + M2.1
> third variant deleted), sync-video ACCEPT = first upstream response
> byte with ABSOLUTE lazy emission (gateway heartbeats post-commit
> only), 600s pinned as post-accept/async budget (sync first byte
> must fit 270s), usage status vocabulary homed (terminal-attempt
> statuses in usage_events; pending/abandoned live only in
> video_jobs), single-statement dialect-portable CAS for terminal
> rows, sweep + secret bootstrap owned by the single dashboard
> backend (no gateway leader election; follower bootstrap degrades
> not hangs), poll order local-first (exp never masks results),
> per-listing mode attribute exposed on /v1/models, 64MiB JSON reply
> cap (response_too_large), ASR admission at header time bypassing
> the failover loop, images 429 retryable pre-2xx, total pre-accept
> budget across attempts, test budget override, writer-owned
> finalization E2E. R6 summary: R6 (7/7 GO WITH FIXES) fixed:
> stale-text sweep (mode-homogeneity leftover, grammar 409 block, TTS
> `ok` status — all contradicted the finalized decisions), video_jobs
> migration hoisted to M1.1c (R6 ordering dependency), sync-video
> commit boundary pinned (first SSE event = commit; coincides with
> upstream accept under lazy emission). R5 summary: R5 (7/7 GO WITH FIXES; one
> format-violation retried per protocol) fixed: timeout budgets
> defined RELATIVE to the listener (pre-accept = idle−30s = 270s
> because lazy emission cannot reset the clock; post-accept is
> progress-driven), pre-accept failover pinned SAME-MODE (wire
> contract cannot change shape mid-failover), leftover sync-409 text
> deleted, row model finalized (attempts keep is_terminal only;
> video lifecycle + persistence in video_jobs; ONE guarded-idempotent
> terminal usage row; sync aborts writer-owned truncated, no jvid
> row), status vocabulary unified (completed/truncated/failed),
> cowboy 2.12.0 pinned from rebar.lock (read_part settled, vendored
> branch deleted), HMAC byte layout + decode-reencode tamper eunit,
> backfill prefers catalog metadata, mock + TEST-FLOWS authoring
> tasks per ship unit. R4 summary:
> video wire contradiction resolved ONCE (async POST = JSON+close;
> poll JSON/SSE-upgrade; sync POST = SSE hold with LAZY EMISSION —
> nothing written pre-accept, pre-accept failover may cross modes),
> terminal-result persistence (video_jobs table — provider retention
> is hours vs exp 24h; routing stays stateless, results persist),
> sync-cancel 409 dead branch deleted (cancel is async-only; sync
> abort = client disconnect), usage rows split into per-attempt +
> jvid summary (UNIQUE jvid, dialect upserts, WRITER-OWNED terminal
> finalization on handler death), TTS commit = upstream accept (chars
> bill from accept; first-byte is only the no-error-signal point),
> commit_point table per modality, output byte caps (truncated, not
> 4xx), computer-use EXACT allow-list (no prefix auto-detect),
> single-writer secret bootstrap (leader mints, followers block),
> entitlement namespaces default-allow, ASR monitor-held slots +
> drain + fixed Retry-After + parser decision flow, hot-reload
> mid-job poll honored, every jvid segment base64url. R3 summary:
> video wire decision final (POST JSON `submitted` async / SSE
> envelope for sync holds; poll JSON default, SSE via Accept upgrade;
> A1 divergence documented), progress payload pinned per mode (sync =
> stage heartbeats, no fake percent), cancel = DELETE with
> idempotent post-cancel polls + 409 sync + usage persistence, usage
> gains explicit status column (one row per jvid, upsert-on-terminal)
> replacing NULL-as-pending, family-aware modality backfill,
> commit_point/1 arity + chat default + shared-loop parameterization
> task (M1.0c) incl. entitlement namespaces + per-modality knobs,
> jvid secret lifecycle task (bootstrap/rotation/retention/gate
> injection) + owner-404 + unknown-keyid mapping, ASR slot
> crash-safety + audio-seconds source rule, provider-table gun
> budgets, images edits/variations + video pre-flight caps +
> hardcoded computer tool list + manual-only computer-use probes +
> soak-runner honesty. R2 summary:
> jvid codec specified (versioned base64url segments, keyid rotation,
> agent-key owner check, signed exp, tamper/rotation/expiry eunit),
> listings.modality column as the single modality source of truth
> (backfill + ETS + surface + wrong_modality gating), strict status
> codes (429+Retry-After admission vs 413 size; response oversize
> passes through with warning; request caps pre-flight), TTS sends
> nothing before the first upstream byte + input-char knob, video
> grammar per-mode terminals + best-effort cancel + expired-id
> mapping, pending sweep with documented usage loss, M1.0 static
> route table + behaviour contract (commit_point/1 single source),
> cowboy read_part gated on rebar.lock, CI-fast idle-timeout proof
> with nightly soak, computer-use detection pinned to computer_* tool
> types. R1 summary: stateless
> self-routing HMAC job ids (no registry/TTL/rolling-deploy wipe;
> multi-node LB reality), video wire ALWAYS SSE with synthesized
> heartbeats (Cowboy idle_timeout is listener-level — no per-route
> override exists; blocking JSON cannot heartbeat), spend discipline
> (no failover after upstream 2xx/accept; wall-clock attempt budget),
> TTS contract finalized (bill input chars; no fake truncation
> signaling), ASR buffered with per-node admission control +
> boundary-straddling fixtures, pending=NULL not 0, computer-use
> hard-rejected on translated routes, video SSE event grammar table,
> 413-not-truncate caps, wrong_modality local rejects.

**Goal:** Make Janus a whole-modality gateway, not a chat gateway:
image generation, TTS, ASR, video generation, computer use, and a
plugin path so the next model class (whatever "AGI" ships as) slots
in without redesign. The routing/LB/entitlement/failover/usage
machinery is already modality-agnostic — routes are (model, provider)
pairs; this plan adds the data-plane surfaces those models need.

**Grounding (production, 2026-10-07):** the agent model surface (435
listings) ALREADY contains non-chat models — `qwen-image-2.1-pro`,
`qwen-audio-3.1-realtime-plus`, `qwen-mt-uni`, `ZHIPU/GLM-5.3-FlashX`
etc. Today they are list-only: no endpoint serves them (a chat call
against an image model 400s upstream). Demand already exists on the
catalog side.

## Normative references (pin at implementation start)

No neutral standards body covers LLM APIs — every wire below is a
vendor de-facto standard. Machine-readable OFFICIAL specs exist for
the two canonical families; the capture corpus stays authoritative
for what providers ACTUALLY emit (de-facto deviations beat the doc):

- **OpenAI** — official OpenAPI 3 spec: github.com/openai/openai-openapi
  (operator-provided reference URL, pinned here per the 2026-10-07
  handoff)
  (ALIGNMENT CHECK rev 10: images/audio/videos request+response
  params verified against it — video status vocabulary, /content
  download, verbose_json.duration, response_format enums; remaining
  divergences are exactly the two documented in A1)
  (Chat Completions, Responses, Images, Audio speech/transcriptions,
  Embeddings, Moderations). NOTE: the repo lags the live docs —
  platform.openai.com/docs/api-reference is the live truth; snapshot
  BOTH (repo tag + docs date) in M1.0's first commit.
- **Anthropic Messages** — official OpenAPI spec shipped in their SDK
  repos / docs (docs.claude.com, Messages API + tool-use +
  computer-use beta pages). Snapshot the spec version with M4.
  Community-maintained machine-readable mirror (operator-provided
  reference): github.com/laszukdawid/anthropic-openapi-spec — useful
  for offline schema diffs; the vendor docs remain normative.
- **Transport standards these ride on (real standards):** SSE framing
  (WHATWG HTML Living Standard, server-sent events — our `event:`/
  `data:`/`

` terminators conform to IT, not to any vendor doc);
  multipart/form-data (RFC 7578, + MIME RFC 2045) for ASR; chunked
  transfer (RFC 9112 §7.1) for TTS binary; base64url (RFC 4648 §5)
  for jvid segments; JSON Schema for tool parameters.
- **Non-canonical providers** (dashscope native, volcengine, minimax):
  vendor API docs only (no OpenAPI published) — their shapes enter
  the plan exclusively through captured transcripts (C6 discipline).
- **Emerging, watch-only:** OpenAI Realtime (WebSocket/WebRTC,
  non-goal here); community compatibility efforts (e.g. OpenRouter /
  LiteLLM conventions) are NOT normative for us.

## Architecture decisions

**A1 Canonical wire = OpenAI shapes where they exist.**
`POST /v1/images/generations`, `POST /v1/audio/speech` (TTS),
`POST /v1/audio/transcriptions` (ASR), `POST /v1/videos` +
`GET /v1/videos/{id}` + `GET /v1/videos/{id}/content` (byte download,
streamed passthrough). Status vocabulary ALIGNED to the official
OpenAI video API (`queued | in_progress | completed | failed` + our
documented addition `cancelled`); exactly TWO deliberate divergences
remain, both listed here: (a) the jvid envelope (self-routing HMAC
ids, not provider-opaque), (b) the SSE progress envelope on sync
holds and Accept-upgraded polls. POST replies JSON
`{jvid, status:"queued"}`
(async) or streams the SSE envelope while holding a SYNC call
(`submitted → progress* → completed|failed`). POLL (`GET`) replies
JSON by default and upgrades to the same SSE grammar on
`Accept: text/event-stream`. Computer use is NOT a new endpoint — it rides `/v1/messages` with the
computer-use tool + beta header (M4). Non-OpenAI provider shapes
(e.g. dashscope native video/aigc endpoints) translate INTO the
canonical shape; we never expose provider-native surfaces.

**A2 Modality plugin architecture (the "AGI" answer).** Each modality
is one plugin: endpoint(s) + request translator + reply/stream
renderer + usage unit + probe policy + entitlement codes. Adding a
new class = one new plugin module + catalog/usage column values; the
LB, failover loop, key management, agent-key auth, dashboard, and
generation hot-reload are untouched. Plugins live in
`apps/janus_http/src/janus_m_<modality>.erl` behind a shared
`janus_modality` behaviour.

**A3 Routing = same catalog, with an explicit modality source of
truth.** New `listings.modality` column (chat default; one migration
both dialects + flat copies; backfill `chat`; ETS normalized to atoms;
dashboard reads it). `wrong_modality` rejects on THIS column only (no
name heuristics); the agent model surface (`/v1/models` + dashboard)
carries the modality badge; probe/entitlement rows inherit it.
Modality models route exactly like chat listings (direct listing call
or Router-bound); `prefer_proto` applies; `janus-auto` stays
chat-only.

**A4 Usage accounting per modality.** `usage_events` gains
`modality` (chat/image/tts/asr/video/computer) + `units` (generic
count: images, characters, audio-seconds, video-seconds; tokens stay
for chat) — one migration, additive-only, both dialects + flat
copies. Dashboard Usage page groups by modality; per-key budgets per
modality are explicitly LATER (settings knob shape already allows it).

**A5 Transport realities.**
- Images: sync JSON (URL or b64); 60s+ allowed by existing
  idle_timeout; body-size cap on b64.
- TTS: chunked binary out (`audio/mpeg`/`wav` etc. via
  `cowboy_req:stream_reply`), NO SSE.
- ASR: multipart IN — cowboy has no built-in multipart parser; vendor
  a small streaming parser (eunit-first with REAL curl-shaped
  multipart fixtures whose chunk splits STRADDLE boundaries and split
  binary payloads), 25MiB hard cap → clean 413 (cowboy unread-body
  semantics handled; connection drained or reset, never a hang).
  Translation upstream is BUFFERED-then-rewritten (translators need
  the whole body): bounded memory via admission control — a per-node
  cap (default 4, settings knob) checked at HEADER time
  (content-length; chunked uploads without content-length count
  against the cap on the FIRST read and are cut at the 25MiB body
  cap — no unbounded unknown-length stream) BEFORE reading the body —
  admission never pays for a body it will reject, and the 429 is a LOCAL reject that BYPASSES
  the failover loop (retrying another provider frees no slots); slow
  uploads occupy their slot for the upload duration (documented).
  Beyond it: 429 + Retry-After (fixed 5s). Slots are held via
  a MONITOR (process death releases — idle_timeout kills never leak
  the 4 slots); cap-reject DRAINS the unread body (read-and-discard,
  connection stays reusable) where feasible, else resets.   resets. Parser: SETTLED — `rebar.lock` pins cowboy 2.12.0, which
  has `cowboy_req:read_part/read_part_body`; the vendored-parser
  branch is DELETED (no fallback to maintain). M2.2's fixtures target
  read_part semantics.
  The re-serialization target per provider (form rebuilt vs JSON) is
  part of each provider's translator spec + fixtures; ASR duration
  source rule: request `response_format=verbose_json` (official
  OpenAI param — its reply carries `duration`) → provider-reported
  field → else WAV/header-derived → else `units=NULL` with documented
  loss. Provider table also carries
  PER-ENDPOINT gun await budgets (invariant: budget < the caller's
  SSE window; video default 600s, images 120s).
- Video wire (FINAL, one decision): ASYNC providers — `POST
  /v1/videos` replies JSON `{jvid, status:"queued"}` and CLOSES
  (no SSE on submit); `GET /v1/videos/{id}` replies JSON by default,
  upgrades to the SSE grammar on `Accept: text/event-stream` (then
  streams progress until terminal). SYNC one-shot providers — `POST
  /v1/videos` IS the SSE hold: `submitted → progress* → terminal`,
  with synthesized ≥1-per-10s events keeping the listener idle clock
  and client proxies alive (a blocking JSON body cannot heartbeat —
  that is WHY sync holds are SSE). LAZY EMISSION on sync
  holds — ABSOLUTE: ZERO bytes reach the client before upstream
  ACCEPT, and ACCEPT = the FIRST upstream RESPONSE byte (headers or
  data — native sync upstreams emit no headers until done, so accept
  is the first byte, never request-sent). Synthesized heartbeats are
  gateway-owned and written only AFTER commit (pre-commit heartbeats
  would leak a committed stream and kill pre-accept failover).
  Pre-accept failures answer plain HTTP JSON errors; after accept the
  SSE is committed — same window rule as chat translation C4. Failover across providers only
  pre-accept and only among SAME-MODE routes (A6). Images stay plain sync JSON
  (30-90s typical, under the 300s listener budget).
- Video job ids are STATELESS and self-routing (no registry, no
  rolling-deploy wipe). Codec: `jvid_v1` dot-joined URL-safe
  base64url segments `v1.<upstream_job_id>.<provider_id>.<listing>.
  <agent_key_id>.<exp_unix>.<keyid>.<hmac16>` — HMAC-SHA256 truncated
  to 16 bytes over the canonical dot-joined prefix, keyed by a
  settings-held secret with a visible `keyid` so rotation keeps old
  ids verifiable (retention knob: secret retained until
  `retention > max exp`). Every node parses and verifies (fail-closed
  when the secret is missing: local 500, never accept; UNKNOWN keyid
  → `failed(job_unknown_key)` after retention). Poll/cancel verify
  the HMAC AND the agent-key id; owner mismatch → 404 (no existence
  leak). `exp` embedded in the signed payload
  (default 24h, settings knob) — expired → `failed(job_expired)`.
  Upstream ids containing dots/underscores survive via base64url
  segments + right-anchored parse. Polls NEVER failover across
  providers (job is provider-bound). Sync-mode replies carry no jvid.
  eunit: tamper (mutate a segment; also decode-then-re-encode so
  naive byte-flips that change encoding length still fail), rotation
  (old keyid verifies), expiry, underscore/dot-bearing upstream ids
  and listing names (`ZHIPU/GLM-5.3-FlashX` — EVERY segment is
  base64url, including listing), cross-node parse. HMAC input is the
  UTF-8 dot-joined base64url prefix VERBATIM (no re-encoding);
  `hmac16` = base64url(HMAC-SHA256 truncated to 16 raw bytes).
- TERMINAL-RESULT PERSISTENCE (provider retention is hours, `exp` is
  24h — a completed job must not become unretrievable): on terminal,
  the gateway persists `{jvid, status, url_or_ref, units, ts}` to a
  shared-DB `video_jobs` table (both dialects + flat copies; swept
  with M3.3b). POLL ORDER: local video_jobs terminal row FIRST (it
  outlives provider retention — exp never masks a completed result);
  only a pending/missing local row consults the provider; provider
  transport-unreachable + local terminal row → serve local. MODE
  DISCOVERABILITY: mode is a per-LISTING attribute (provider table),
  exposed on /v1/models metadata and the dashboard; the POST response
  content-type (JSON vs SSE) always tells the client what happened.
  Routing stays stateless (jvid); persistence is for RESULTS only.
  Hot-reload: a jvid's poll/cancel honors the id even if the listing
  was disabled mid-job (job is bound at submit).
- CANCEL is async-only: `DELETE /v1/videos/{jvid}` (best-effort
  upstream cancel + `status=cancelled` persisted); sync holds carry
  no jvid — client disconnect IS their abort (upstream cancelled,
  usage `status=truncated`). No sync-409 branch exists.
- Upstream timeouts are per-request `gun:await` budgets defined
  RELATIVE to the listener idle_timeout: pre-accept = idle−30s = 270s
  (lazy emission cannot reset the clock); post-accept per-chunk 30s;
  images 120s; the 600s figure is the POST-ACCEPT/async budget ONLY —
  sync providers that cannot produce a FIRST byte within 270s are
  unsupported (documented provider-table limit). The idle−30s formula
  is parameterized for the test listener (explicit override so it
  never goes to zero). Client disconnect aborts upstream (no orphan
  gun streams).
- Computer use: `/v1/messages` + `anthropic-beta` header allow-list +
  the computer-use tool passes ONLY on anthropic-PROTOCOL native
  routes; on any translated route a computer-use-bearing request is
  HARD-REJECTED locally (400 `computer_use_requires_native`) — tool
  JSON "surviving" translation is not an invariant worth having.

**A6 Failover + spend discipline:** identical loop; attempt rows carry
`modality` + `units`. Commit points: images = upstream 2xx (the whole
call is one commit — retry only on PRE-2xx transport/5xx/auth/429
(the entitlement classifier's rate class), NEVER after a 2xx:
generation is billed, a retry double-charges); TTS = upstream accept; video submit = upstream accept (job id or sync
start) — after accept, an upstream timeout is an ERROR, not a retry;
polls never failover (provider-bound). Wall-clock attempt budget per
request (settings knob) caps total spend across retries and bounds TOTAL pre-accept wall
time across all attempts of one request. Each plugin exports
`commit_point/1 :: (request_map()) -> pre_2xx | first_media_byte |
upstream_accept` — images/chat-nonstream: pre_2xx; chat streams and
sync-video holds: first_media_byte — lazy emission means the
first SSE event IS the commit, and since nothing is emitted before
upstream accept, first-event-commit and upstream-accept coincide in
practice; TTS and video submits: upstream_accept. M1.0c
parameterizes the shared failover loop's commit checks + renderers
per plugin; A6 rules live in ONE place (the behaviour's docs).

**A7 Entitlement & probe:** same carrier; per-modality probe policies
— images/video probes SPEND REAL MONEY per call, so batch probes for
image/video models are OFF by default (settings knob), single
one-shot "Test" buttons (like the listing test) remain manual-only.

**A8 Security:** REQUEST bodies capped (25MiB ASR in, image/video
request params pre-flight per provider table); RESPONSES pass through
under the Contracts rule (size unknown pre-upstream; warn-log). ASR
slots are crash-safe (release on any exit — process death never leaks
a slot) with drain semantics on cap reject. Content-type strictly
validated per endpoint; no multipart spooling to disk; binary bodies
never logged; API keys never in logs (existing rule).

## Contracts (shared with the translation plan where applicable)

- Video SSE event grammar (normative; fixtures from 1.0-style
  captures): `event: submitted` (carries jvid when async) →
  `event: progress` — SYNC mode: `{stage:"processing"}` heartbeats,
  NO percent (there is nothing to measure); ASYNC: provider percent
  when offered, else synthesized stage; ≥1 per 10s — terminal is
  EXACTLY ONE of `event: completed` (official download semantics + our canonical
  `GET /v1/videos/{jvid}/content` byte download as the primary
  retrieval path; b64 passes through under the response rule
  regardless of size, + usage) /
  `event: failed` (canonical error envelope;
  `job_not_found/job_expired/job_unknown_key` map here) /
  `event: cancelled`. Mid-stream upstream failure → `failed` replaces
  the success terminal (chat translation C2 rule). Cancel is
  `DELETE /v1/videos/{jvid}` (best-effort upstream cancel, ASYNC ids
  only); cancel persists on the usage row (`status=cancelled`);
  poll-after-cancel answers JSON/SSE `cancelled` (idempotent).
- TTS final contract: COMMIT = upstream ACCEPT (2xx headers — input
  chars are billed from that moment; no failover after accept).
  NOTHING is sent to the client until the FIRST audio byte (headers
  included) — pre-first-byte upstream failures still answer a proper
  JSON error with a real status;
  from the first byte, binary chunks stream and connection close is
  the terminator; truncation is POST-first-byte only and lands in
  `status=truncated` (the status vocabulary is
  completed/truncated/failed — never `ok`). Input cap knob `tts_max_input_chars` (default
  5000; over → 400 BEFORE any upstream spend). OUTPUT caps:
  settings knobs for streamed response bytes (TTS default 100MiB, ASR
  reply 10MiB) — exceed → stop streaming, `status=truncated`,
  warn-log (post-accept, no 4xx possible). After the first
  audio byte NO failover and NO mid-stream error signaling is possible
  (binary has no error frame) — an upstream cut truncates the audio;
  billing = INPUT CHARACTERS (consumed upstream regardless of output);
  the usage row records chars + final status (`completed`/`truncated`);
  never invent output seconds.
- Images: REQUEST-side caps enforced pre-flight per provider table
  (`n`, `size`, quality; over-cap → 400 before any upstream spend).
  RESPONSE-side oversize cannot be known pre-upstream: pass through
  with a warning log (never silently truncate — a truncated b64 is a
  corrupt image).   Status codes are strict: 413 = body size only;
  admission/capacity = 429 + Retry-After (never 413). IMAGE/VIDEO
  JSON reply buffering cap (64MiB): exceed → `failed
  (response_too_large)` (upstream-paid error — pass-through cannot
  apply to an unbounded single body).
- Modality mismatch: a chat/completions call naming an image/audio/
  video-listed model is rejected LOCALLY (400 `wrong_modality` naming
  the correct endpoint) instead of 400ing upstream.
- Error envelopes: upstream HTTP errors translate into the canonical
  JSON error shape (per-modality provider table).
- Streaming translate interplay: none — modalities translate once per
  request/reply, not per event.

## Phase M1 — framework + images

- [ ] M1.0 `janus_modality` behaviour (exports: routes/0,
      translate_request/2, render_reply|stream handlers, usage_unit/1,
      probe_policy/0, commit_point/1) + STATIC route table compiled
      into the agent dispatch (no hot registration — plugins are
      code, endpoints appear on deploy); content-type routing;
      request-size guards.
- [ ] M1.0b `listings.modality` migration (see A3) + catalog ETS
      normalization + backfill + dashboard model-surface/badge field;
      dashboard tolerates a not-yet-migrated gateway (column absent →
      badge hidden) so the rolling deploy order is safe.
- [ ] M1.0c Shared-loop parameterization: janus_http_proxy commit
      checks + error renderers per plugin (A6); entitlement-code
      namespaces per modality — DEFAULT-ALLOW: an agent key may use a
      modality unless deny codes are configured for it (flipping a
      modality knob never silently denies existing keys) +
      `janus_usage` writer units plumbing;
      per-modality knob + dashboard exposure (`modality_image_enabled`
      etc., default off).
- [ ] M1.1 usage migration: `modality` TEXT NOT NULL DEFAULT 'chat'
      + `units` NUMERIC NULL + `status` TEXT NULL
      ('completed|failed|cancelled|truncated', set ONLY on terminal
      attempts; `pending|abandoned` never appear in usage_events —
      that lifecycle is video_jobs-only; NULL for old chat rows) — additive, both dialects + flat copies,
      migration-before-code per the boot-migration leader flow (old
      code writing without the columns stays correct via defaults).
      Writer + dashboard Usage grouping. Backfill prefers CATALOG
      metadata (provider-declared model types) where available;
      family-name regex (image/audio/video/tts) is the documented
      fallback; truly unknown rows default to chat.
Row kinds, explicit (no double-encoding): (1) PER-ATTEMPT rows —
      the existing failover machinery unchanged
      (request_ref/attempt/is_terminal + modality/units; is_terminal
      stays the attempt-row lifecycle flag — `status` never appears
      here); (2) video lifecycle lives in the `video_jobs` table
      (pending→terminal summary + terminal payload persistence, swept
      at exp) — NOT in usage_events; usage_events receives exactly ONE
      terminal row per jvid, inserted once, guarded by the
      video_jobs.status transition — a SINGLE-STATEMENT conditional
      UPDATE ... WHERE status = 'pending' (+ affected-rows check),
      identical semantics on epgsql and esqlite; two nodes racing to
      finalize the same jvid cannot both win. GUARD ORDER: the CAS on
      video_jobs runs FIRST and is the sole authority — the
      usage_events terminal row is inserted only when the CAS reports
      the transition (so exactly one node inserts it). No UNIQUE jvid
      index needed. Sync holds have NO
      jvid row (writer-owned per-attempt `truncated` row on abort).
      Terminal finalization is WRITER-OWNED (a monitor notifies the
      usage writer on handler death — idle_timeout kill, client
      reset); eunit SMALLINT/binary fixtures + insert-once idempotency.
- [ ] M1.1c `video_jobs` table migration (jvid PK, status, url_or_ref,
      units, ts; both dialects + flat copies) + sweep at exp — created
      in M1 so the M3 lifecycle has its substrate documented up front
      (and the R6 ordering dependency is closed).
- [ ] M1.2 Images: POST /v1/images/generations only —
      `/v1/images/edits` and `/v1/images/variations` are documented
      DEFERRED non-goals (add when a consumer asks; the plugin shape
      takes them without redesign). — passthrough for
      OpenAI-shaped providers; dashscope native-shape translator IN
      (qwen-image family); reply normalization (url/b64_json);
      size/quality/n + official `response_format` (url | b64_json)
      validated pre-flight per provider table (400 before spend;
      responses pass through under the Contracts rule);
      wrong_modality local reject for image models called via chat;
      eunit on captured real request/reply JSON (dashscope + OpenAI
      reference).
- [ ] M1.3 E2E gate steps: listing call on qwen-image (mock or real
      1-image minimal), usage row `modality=image units=1`, failover
      row on 401 key, agent-key auth 401, entitlement deny path.
- [ ] M1.4 Dashboard: modality badge on model surface; per-modality
      usage breakdown card; TEST button on image listings (manual,
      money-spending, confirmation dialog).

## Phase M2 — TTS + ASR

- [ ] M2.1 TTS: POST /v1/audio/speech — chunked binary stream out,
      format (official enum: mp3 | opus | aac | flac | wav | pcm) /
      voice params, provider translators (dashscope qwen-tts
      family; minimax/volcengine as providers offer); failover window
      = PRE-ACCEPT (A6's single commit point — there is no separate
      "first-byte" window for TTS); usage `units=characters`.
- [ ] M2.2 ASR: multipart streaming parser (eunit FIRST with real
      curl multipart fixtures incl. headers/boundary/binary payloads),
      25MiB cap, provider translators (paraformer family),
      usage `units=audio_seconds`.
- [ ] M2.3 E2E: TTS 200 + audio/mpeg bytes + usage row (chars) +
      input-cap 400 + pre-first-byte upstream error as JSON; ASR real
      multipart (curl -F shape), >25MiB clean 413, 5th concurrent ASR
      429 + Retry-After (slot released on every exit path);
      truncation recorded as `status=truncated` post-first-byte.

## Phase M3 — video (async jobs)

- [ ] M3.1 Stateless job id codec: `jvid_` encode/parse/HMAC-verify
      (eunit-first: tamper cases, cross-node parse with shared
      secret); submit/poll/cancel endpoints; poll routes via the id
      (no registry); no cross-provider failover on polls.
- [ ] M3.1b jvid secret lifecycle: SINGLE-WRITER bootstrap (the
      migration LEADER generates + writes via settings; followers
      block/poll until present — two booting nodes must never mint
      different secrets), dual-key storage for rotation, dashboard
      generation UI under the settings surface; gate injects a
      test-secret for expired/tamper/rotation E2E. Followers wait
      with a TIMEOUT: a wedged leader degrades the node to
      video-disabled (the knob is default-off anyway) — boot never
      hangs the fleet.
- [ ] M3.2 Providers: OpenAI /v1/videos shape (submit+poll+SSE
      progress passthrough) + dashscope/volcengine native video
      translators (seedance/wan family) into the canonical envelope —
      BOTH directions of mode: native SYNC one-shot endpoints map to
      the inline-completed reply (no job rows), native async map to
      job submit/poll. Mode is a provider-endpoint property recorded
      in the plugin's provider table, not a per-request guess.
- [ ] M3.2c Video pre-flight request caps per provider table
      (duration/size/aspect), mirroring images — 400 before spend.
- [ ] M3.2d Content download: `GET /v1/videos/{jvid}/content` —
      streams bytes from the provider (or the persisted terminal ref
      after provider expiry), same jvid auth/owner checks,
      content-type from the provider; range requests pass through
      where supported.
- [ ] M3.2b SSE envelope machinery: synthesized progress/heartbeat
      events (≥1 per 10s) wrapping ANY provider mode; per-request
      gun await budgets; client-disconnect aborts upstream. Gate
      asserts a >310s mock video completes end-to-end through the
      envelope (listener idle_timeout untouched).
- [ ] M3.3 Usage: lifecycle rows live in `video_jobs` (pending →
      terminal, swept at exp); the ONE usage_events row is inserted
      at terminal (`units=video_seconds` on completion), guarded
      idempotent by the video_jobs transition; polls write nothing;
      sync-hold client abort → writer-owned per-attempt `truncated`
      row (no jvid row).
- [ ] M3.3b Pending sweep: the DASHBOARD backend (single management
      instance — no gateway leader election needed) runs the nightly
      scan over video_jobs (idempotent UPDATE, indexed on status+ts),
      marking pending rows `abandoned` after id-expiry, preserving
      `cancelled` rows; usage loss for
      never-polled jobs is accepted and DOCUMENTED (reconcile only on
      a late poll before expiry).
- [ ] M3.4 E2E: submit→poll→completed against a mock job provider;
      cancel → `cancelled`; expired id → `failed(job_expired)`; tamper
      → 400; entitlement deny on submit; CI-fast latency proof via a
      test-only `idle_timeout=30s` listener + 31s mock job (the true
      >310s check is a DOCUMENTED manual soak via a scripts/ runner —
      a nightly CI job is future work, not claimed).

## Phase M4 — computer use + beta surface

- [ ] M4.1 `anthropic-beta` (and `OpenAI-Beta` when relevant) header
      allow-list passthrough on /v1/messages + /v1/chat/completions;
      unknown beta values stripped + recorded (C2 channel rule from
      the translation plan: headers non-stream, terminal-event/usage
      on streams).
- [ ] M4.2 Computer-use gate: DETECTION = tool entries with
      `type == "computer_20250124"` (and successor `computer_*`
      versions — EXACT match against an allow-list, INITIAL
      `["computer_20250124"]` + settings knob additions; unknown
      `computer_*` versions are NOT auto-detected — they ride as
      ordinary tools until the operator adds them) on anthropic
      requests;
      chat-compat `type:"function"` with the canonical computer-use
      name is NOT treated as computer use. Non-anthropic-native route
      + detected → local 400 `computer_use_requires_native`; native
      routes passthrough e2e incl. beta header; Router binds warn when
      a computer-use model has no anthropic-native route. Probe
      policy for computer-use models: manual one-shot Test only (no
      batch probes — they drive real computer interactions). eunit on
      real tool JSON fixtures.
- [ ] M4.3 Dashboard: per-route "supports computer use" derived badge
      (tools + beta header capability), bind-time warning when a
      computer-use-bound model has no capable route.

## Test-surface tasks (shared)

- [ ] T.1 Extend the deterministic mock upstream per phase: image
      JSON (url+b64 shapes, slow image >31s), TTS audio bytes
      (multi-chunk, cut-after-first-byte), ASR multipart replies,
      video job provider (submit/poll/percent/expire/cancel) + sync
      slow video; the exact `progress` JSON fixture grammar lives
      with the mock.
- [ ] T.2 TEST-FLOWS.md sections authored in the SAME commits as each
      ship unit's gate steps (per that repo's authoring rules).
- [ ] T.3 Writer-owned finalization E2E: kill a handler mid-TTS
      (post-first-byte) and a sync video mid-hold — assert the
      monitor-driven `truncated` rows land without the request
      process.

## Non-goals (documented, not faked)

- Realtime websocket APIs (audio/video live) — separate spec if ever;
  the listing shows realtime models, they stay list-only.
- Embeddings/moderations/fine-tunes — trivial passthroughs, add when
  a consumer asks.
- Cross-provider video job migration (job dies with its provider).
- Mode bridging (`wait=true` server-side poll-and-hold) — deferred;
  clients read the envelope's mode.
- AGI-as-buzzword: nothing to build until it ships as a wire shape;
  the plugin architecture (A2) is the hedge.

## Ordering vs the translation plan

Independent tracks; M4.2 depends on translation Phase 1's tools work.
Both share: C2 degradation channels, per-attempt usage rows, ship-
unit discipline (default-off knob `modality_<name>_enabled` per M1/M2/
M3 unblock, e2e in the same commit, flip after gate+smoke).
