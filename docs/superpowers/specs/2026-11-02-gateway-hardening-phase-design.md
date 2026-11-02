# Janus Gateway Hardening Phase Specification

## 1. Purpose

This specification governs a hardening-only phase for Janus. Its objective is
to make the existing gateway and management plane more correct, predictable,
observable, and maintainable without expanding their feature surface.

The phase is complete when the behavior Janus currently advertises is covered
by repeatable verification, known reliability and correctness defects are
resolved, operational recovery is demonstrated, and the remaining limitations
are explicit and intentional.

This is not a rewrite, a redesign, or a new-feature program.

## 2. Current-State Assessment

Janus already has a substantial production-oriented core:

- OpenAI Chat, OpenAI Responses, and Anthropic Messages client faces, native
  passthrough, supported cross-protocol translation, streaming, tools, vision,
  and agent-history repair.
- Master/worker execution with worker admission, capacity reservations,
  draining, health/RTT scheduling, local fallback, stream credits, and request
  deadlines.
- Provider/model routing with priorities, weighted selection, cooldowns,
  latency-based shedding, key failover, and entitlement handling.
- Per-agent-key RPM/TPM/daily quotas, usage accounting, tracing, logs,
  Prometheus metrics, alerts, and dashboard inspection.
- Hot catalog reloads, Postgres/SQLite migrations, rolling deployment gates,
  backup tooling, encrypted provider secrets, and authenticated administration.
- A judge-only auto-router with caching, breakers, and availability-first
  fallback. (An earlier rule gate over token size and marker words was removed
  in the prompt-only change; only a deterministic capacity bound survives —
  `gateway/docs/design/auto-router-prompt-only.md`.)

The principal weaknesses are not missing capabilities:

1. CI verifies only formatting and compilation. At the initial assessment,
   19 standalone EUnit files plus inline `-ifdef(TEST)` tests were present,
   but CI executed none of them. Workstream A must reconfirm this inventory
   and enforce a non-vacuous test count.
2. Documentation still says test suites were deleted, so the verification
   contract is inconsistent with the tree. The phase explicitly supersedes
   the old live-only rule for checked-in unit and characterization tests;
   live verification remains the primary end-to-end proof.
3. Several very large modules concentrate correctness-critical behavior and
   make regressions expensive to detect.
4. Some documented surfaces have intentional limitations or deferred work;
   these must remain explicit rather than being presented as complete.
5. Worker resilience is stronger than the demonstrated front-door/master
   recovery story.
6. Live verification is valued by the repository, but it needs a repeatable
   matrix and durable evidence rather than ad hoc scenarios.

## 3. Goals

- Establish one authoritative, continuously executed verification baseline.
- Preserve existing external contracts unless a change corrects a demonstrated
  defect.
- Add characterization coverage before modifying complex core modules.
- Make protocol, streaming, failover, quota, and usage-accounting behavior
  deterministic under normal and injected-failure conditions.
- Reduce implementation complexity only through behavior-preserving changes
  backed by tests.
- Demonstrate backup, restore, rolling-upgrade, rollback, and master-recovery
  procedures without mutating production during verification.
- Keep operator documentation and the actual supported surface synchronized.
- Continue focused management-UI correctness, accessibility, and safety polish.

## 4. Non-Goals and Feature Freeze

The following are explicitly excluded from this phase:

- New providers, provider-dialect adapters, protocols, modalities, endpoints,
  routing algorithms, automatic threshold tuning, or settings knobs.
- Responses-provider streaming Phase 3.
- Video persistence, content download, SSE progress synthesis, upstream
  cancellation, or other deferred video lifecycle work.
- New modality failover capabilities, including embeddings failover.
- Active/active master serving, automatic front-door failover, org RBAC, or a
  new multi-tenancy model.
- A public SLO/on-call package.
- Broad visual redesign, new dashboard pages, or new operator controls.
- Wholesale module rewrites, dependency upgrades, or framework migrations.

Documenting an existing limitation, correcting its error behavior, or proving
its recovery procedure is hardening. Implementing the deferred capability is
not.

## 5. Binding Invariants

Every hardening change must preserve these invariants unless the linked defect
report and updated contract explicitly say otherwise:

1. The gateway translates standard protocol shapes; it does not add
   provider-specific dialect adapters or policy judgment. The existing
   grandfathered MiniMax T2I exception is preserved, not expanded or removed
   as part of this phase.
2. Knob-off behavior remains byte- and error-compatible with the legacy path.
3. No request is retried after a point where retry could double-bill or emit a
   second accepted upstream job.
4. Pre-first-byte worker loss may use the existing local fallback; in-flight
   worker loss aborts as `worker_lost` without a mid-stream retry.
5. Failover never reuses a client-controlled request identifier as a quota or
   accounting idempotency key.
6. Quota admission occurs once per client request, outside upstream failover;
   token charging is idempotent per server-minted charge ID.
7. Hot-path routing does not query SQL. Catalog publication remains atomic and
   generation-checked.
8. Catalog `enabled` values remain SMALLINT 0/1, normalized on read and written
   as 1/0 in SQL.
9. Empty-map checks use `map_size/1`, never `#{}` matching.
10. Upstream and worker failures remain loud, classified, and observable;
    terminal errors preserve the provider's own message where the existing
    contract requires it.
11. Structural fingerprints and decision logs never capture prompt, response,
    secret, or tool-content text.
12. Request bodies, decompressed payloads, caches, signal mirrors, and writer
    buffers retain their existing bounds and fail in the documented direction.
13. Migrations remain additive, automatically applied at boot, and safe for the
    supported rolling-deployment order.
14. Production is never mutated by verification. Production checks are
    read-only curl or browser observations.
15. Work occurs in isolated worktrees. No hardening work is performed directly
    on `main`, especially while another agent is using it.

## 6. Workstream A: Verification Truth and CI Baseline

### A0. Binding verification-policy decision

This phase supersedes the 2026-10-18 live-only rule for checked-in EUnit
tests inventoried in A1 and characterization tests added under Workstream B.
Checked-in tests are additive; the live matrix and operational drills remain the primary
end-to-end correctness proof and are never replaced by unit tests. A2 owns the
corresponding rewrite of the verification sections in `AGENTS.md`,
`gateway/README.md`, and `dashboard/README.md`.

### A1. Establish the actual baseline

Before changing production behavior:

- Inventory standalone `*/test/*_tests.erl` files and inline `-ifdef(TEST)`
  tests. Record each path, test count, and owning module; require the total
  executed test count to be greater than zero so `rebar3 eunit` cannot pass
  vacuously. If the inventory is unexpectedly empty, record that valid
  discovery result and let the first B1 characterization suite establish the
  non-vacuous floor before A2's non-vacuity gate is evaluated.
- Inventory every module named in B1/B2 and H1 by path, line count, and test
  presence, and reconcile those target lists with the inventory.
- Name and retain an immutable legacy release/commit artifact for C2
  compatibility comparisons and F2's previous-artifact skew/rollback steps.
- Publish an evidence inventory mapping each required observable to its real
  source: controlled-upstream counters, `usage_events`, `/stats/sched`, log
  rings, Prometheus series that actually exist, or bounded
  `erlang:process_info(Pid, message_queue_len)` samples. Confirm the existing
  wire-corruption fault seam, backup/restore scripts, backup/deploy
  environment variables, and local secret channel; missing prerequisites stop
  the affected drill rather than causing improvisation.
- Run `rebar3 fmt --check`, `rebar3 compile`, and `rebar3 eunit` in an isolated
  worktree using the repository's supported OTP 27 path. On hosts requiring
  Docker, use the documented `test` target and `janus-ebin-otp27` volume,
  recreating that volume when the lockfile, rebar config, or OTP changes.
- Run `bash scripts/lint_all.sh` in `dashboard`, then run `npm run typecheck`
  and `npm run build` in `dashboard/spa` after confirming the commands in the
  package manifests.
- Record failures as pre-existing or introduced and triage each one. A correct
  test exposing a product defect requires a separate correctness fix. A stale
  or incorrect test requires a test-side repair that cites the superseded
  contract in the change rationale. Neither path may weaken, skip, or delete
  coverage merely to obtain a green baseline.
- Confirm the existing `artifacts/` ignore rule before writing. Record exact
  commands, commit, environment, inventory, and summarized results under
  `artifacts/verification/<commit>/`. Register every skipped module/test and
  its rationale in `artifacts/verification/<commit>/exclusions.md`. Raw
  specification-audit output belongs in `/tmp`, not in the repository.

A1 owns baseline artifacts only; A2 owns all verification-policy and CI
documentation rewrites.

For a non-empty inventory, A1 exits with a reproducible, non-vacuous baseline.
For an empty inventory, A1 exits with the empty discovery recorded and the
non-vacuity check explicitly deferred to acceptance of the first B1 suite. In
both cases every failure is classified, target modules and evidence sources
are reconciled, and every exclusion appears in the registry.

### A2. Make CI execute the existing tests

Modify `.github/workflows/ci.yml` so the existing Erlang test suite runs after
compilation on the same events currently used for static gates. Keep
formatting, compilation, and EUnit as separate, readable steps, and update the
header comment that currently describes a compile/format-only gate. Pin rebar3
to 3.24 in both CI and the documented local Docker test target.

Add `gateway/scripts/verification/assert_eunit_nonempty.sh` to sum every
`All N tests passed.` summary emitted across all applications. It must fail if
EUnit exits nonzero, any suite fails, no summary is present, any count is zero
or unparseable, or the summed executed-test count is zero; a bare exit 0 is not
sufficient evidence. Record two parser proofs: a no-test/negative input that
must fail and a multi-application input whose separate counts must be summed.

Execution order is A1, then acceptance of the first B1 characterization suite,
then evaluation of A2's non-vacuity gate. A2 workflow and parser work may be
prepared before that point, but its non-vacuity acceptance remains red until a
suite exists. The induced-failure check uses an existing test when one is
present, otherwise the first B1 test.

The canonical command inside the documented Docker `test` target is
`rebar3 fmt --check && rebar3 compile && rebar3 eunit`; local Docker runs use
that target and its OTP 27 volume. GitHub Actions runs the same three commands
directly on its native OTP 27 runner and uses `actions/cache`, rather than the
local Docker volume.

Correct the existing cache paths in the same change: cache `gateway/_build`,
set the key to `gateway-${{ hashFiles('gateway/rebar.lock') }}`, and use no
broad gateway build-tree `restore-keys` prefix that could resurrect stale
output after a lockfile change.

Add a dashboard job to this workflow with explicit working directories for
dashboard and SPA steps, Python and Node setup, frozen dependency installation
from existing lock/manifests (including `npm ci` for the SPA),
`dashboard/scripts/lint_all.sh`, `npm run typecheck`, and the SPA production
build. Do not introduce a browser-automation framework; browser checks remain
live and recorded.

Update `AGENTS.md`, `gateway/README.md`, and `dashboard/README.md` to describe
A0, the tests and commands that actually run, and the live checks that remain
mandatory.

Use a two-tier gate because push CI currently runs only on `main`:

- pre-integration: run the complete CI-equivalent commands locally or in the
  documented Docker target, validate the edited workflow with a recorded,
  pinned `actionlint` invocation, and retain the output;
- post-integration: the `main` workflow is the authoritative confirmation.

Do not widen CI triggers as part of this phase; that is a separate Actions
budget decision.

Exit criteria:

- CI runs format, compile, a non-vacuous EUnit suite, and the dashboard static
  gates.
- Documentation no longer claims that all test suites are absent or forbids
  the checked-in tests authorized by A0.
- A deliberately failing existing or first-B1 test is confirmed to fail the
  local CI-equivalent gate, then restored without integrating the induced
  failure.

### A3. One live-verification matrix and minimal test infrastructure

Create a reusable operator-facing live-verification matrix at
`gateway/docs/verification/live-matrix.md`, using the existing curl and
browser doctrine. Each scenario records:

- request face, provider face, unary/streaming, and translation knobs;
- representative request shape and expected client status/body/SSE terminal;
- expected upstream attempt count and failover classification;
- expected usage row, trace/request ID behavior, and relevant metric/log
  evidence;
- the evidence source selected from A1's inventory;
- cleanup and evidence-retention requirements.

Use the repository's Docker Compose path with the Postgres profile as the
reference disposable fleet for A3, D, E1, and E3; no undocumented staging
environment is assumed. F1/F2 use the separate three-node topology defined in
Workstream F. Provide exactly one disposable mock upstream with explicit
delay/fault modes and one load generator under
`gateway/scripts/verification/`. These are verification infrastructure, not
product features or a second E2E framework, and they are excluded from release
artifacts and runtime packaging. Mock-upstream request counters establish
attempt counts; real-upstream confirmation remains mandatory for the
representative subset as defined, including its observation-gated discharges,
in Workstream D.

Secrets and real deployment identifiers never enter the matrix or its
artifacts.

## 7. Workstream B: Characterization Before Core Changes

### B1. Coverage by behavioral seam

Add focused EUnit characterization around existing pure or injectable seams
before modifying their implementation. Prioritize:

1. `janus_protocol_translate`: request/response and SSE translation, UTF-8
   truncation, tool-call adjacency, interrupted calls, orphan results, and
   terminal-event ordering.
2. `janus_http_proxy`: route selection errors, failover commit points,
   first-byte versus mid-stream outcomes, and usage terminal rows.
3. `janus_worker_pool`: admission, drain, reservation reconciliation, suspect
   counts, capacity override, health/RTT ordering, and local-fallback reasons.
4. `janus_http_worker_client` and worker wire/session modules: credit flow,
   absolute and inactivity deadlines, worker loss, timeout release rules, and
   client disconnects.
5. `janus_lb`: priority tiers, weighted selection bounds, cooldown escalation,
   key eligibility, latency shedding, and never-shed-last behavior.
6. `janus_quota` and `janus_usage`: admission/charge idempotency, rolling
   windows, buffer saturation, dropped-row observability, and flush retries.
7. `janus_auto`: judge input/cache-key parity (the cache key must cover every
   field the judge sees, plus the prompt digest and the judge contract),
   the capacity floor and its hard resolution, breaker and semaphore
   fallback, and availability-first degradation. The rule gate no longer
   exists, so there is no rule precedence left to characterize.
8. `janus_wire_enc`: identity/zlib tag handling, unknown tags, corrupt streams,
   checksum validation, and the shared decompression cap.

Tests must drive the production function or parser, not a copied
reimplementation of its logic.

### B2. Large-module change rule

`janus_worker_pool`, `janus_http_proxy`, `janus_protocol_translate`,
`janus_auto`, `janus_http_worker_client`, and `janus_lb` require the following
before behavioral edits:

- a named defect, contract ambiguity, or A1-inventory evidence gap;
- a characterization or regression test that distinguishes the behavior;
- explicit failure modes and invariants in the change description;
- a minimal diff confined to the relevant seam.

Refactors are separate changes from behavioral fixes. Do not combine them.

## 8. Workstream C: Protocol and Streaming Correctness

Harden only the currently supported matrix.

### C1. Request and unary-response scenarios

For each supported native and translated pair, cover:

- text-only requests and responses;
- system messages and supported role ordering;
- parallel tool calls, malformed tool arguments, image-bearing tool results,
  interrupted calls, and orphan results;
- unsupported fields and shapes, which must retain precise, distinct errors;
- usage present, absent, or estimated according to the existing contract;
- provider 4xx/5xx classification and upstream error-message preservation.

### C2. Streaming scenarios

For every supported streaming pair, assert:

- first event, content deltas, tool-call deltas, and terminal event ordering;
- SSE frame boundaries across split/coalesced reads and UTF-8 boundaries;
- keepalive behavior without resetting absolute deadlines;
- cancellation and client disconnect behavior;
- no duplicate terminal usage or tool result;
- no mid-stream retry after bytes have reached the client;
- known unsupported constructs fail in the documented direction.

For both C1 and C2, A1 must name an immutable legacy release tag or commit as
the compatibility reference in the baseline evidence. For each relevant
translation knob, compare current knob-off output with that legacy reference,
then compare current knob-on output with current knob-off output using the same
representative request. Successful responses must be byte-compatible; error
responses must have identical status and matching error bodies field by field,
not merely successful completion.

Responses-provider streaming Phase 3 remains excluded. Tests and documentation
must preserve the current explicit `stream_requires_native_protocol` behavior
rather than silently expanding support.

### C3. Existing modality surfaces

Verify current knob-off and knob-on behavior for existing modality endpoints.
For `/v1/embeddings`, cover valid unary requests, usage present/absent,
malformed input and dimensions, unknown models, and the existing no-failover
and upstream-error behavior. If route reconciliation proves the endpoint is
not exposed, discharge this row through the H2 documentation correction rather
than adding the route. Do not implement deferred video or new
modality-failover features. Ensure the current 400/501/no-failover behavior
and documentation agree.

## 9. Workstream D: Reliability and Failure Injection

D uses an A3-derived Compose project with real Postgres, one master container,
one worker container configured with `JANUS_ROLE=worker` and
`JANUS_WIRE_ENC=1`, and the A3 mock upstream. The verification-only Compose
overlay lives under `gateway/scripts/verification/` and is torn down with its
volumes after the run. The mixed old/new-node row uses F2's explicit
artifact-skew step and disposable pair instead. This supplies the real worker
hop required by dispatch, worker-loss, and wire-codec scenarios; no row silently
falls back to an easier topology.

Run the following against that stack, then confirm representative scenarios
against real upstreams without production mutation:

| Injected condition | Required existing behavior to prove |
|---|---|
| Empty worker pool | Existing master-local fallback with reason evidence from `/stats/sched`, logs, and metrics listed in A1's evidence inventory |
| Dispatch send failure / missing ack | Existing fallback, timeout, and reservation cleanup |
| Worker loss before first byte | Existing local fallback; no duplicate accepted job |
| Worker loss after first byte | `worker_lost`; no mid-stream retry |
| Slow or stalled upstream | Correct absolute/inactivity timeout and client error |
| Slow client | Credit/backpressure remains bounded; no mailbox growth without limit |
| Provider auth failure | Key/provider cooldown and eligible failover |
| Provider 429 with retry hint | Existing cooldown and Retry-After semantics implemented by `janus_lb` |
| Provider 5xx or malformed body | Existing classification, failover, and terminal usage |
| Corrupt wire-compressed payload after the first client byte | Same error status/body as the post-first-byte `worker_lost` scenario; usage outcome is `wire_enc_inflate_fail`; its counter increments; master health remains passing; no mid-stream retry |
| Oversized upstream response | Existing response/decompression cap rejects safely; client/usage classification and its actual counter are recorded; no fabricated success; master health remains passing |
| Corrupt wire-compressed payload before the first client byte | Same client outcome as the pre-first-byte worker-loss scenario; no duplicate accepted job; wire failure usage/counter evidence is recorded |
| Mixed old/new nodes during rollout | Capability-gated identity degradation without broken decode |
| Catalog reload during traffic | Atomic generation handoff; no partial catalog |
| Postgres temporary outage | Client status/body matches the pre-outage baseline for existing catalog-backed serving; writer failures and health signals are loud; no partial catalog or fabricated usage success |
| Usage-writer saturation | Bounded buffer, counted drops, no fabricated zero metric |
| Usage-writer process down | Dropped-counter series is omitted rather than zero; buffered rows and logs expose the outage |
| Node/process restart | Supervision, `janus_ets_heir`, and cold-reset behavior as documented |

Each scenario records expected client behavior, upstream attempt count, usage
outcome, and observability evidence from A1's inventory. A scenario that cannot
be automated is performed live with a reproducible script and retained result;
it is not silently removed from the matrix. A1 confirms that the
`JANUS_WIRE_ENC_CORRUPT_AFTER` fault seam exists. For the post-first-byte
corruption case, choose the offset so a captured valid chunk reaches the client
before corruption is triggered. If the seam is absent, register only the
corrupt-wire subcases as explicit exclusions with rationale; the oversized
case still uses an oversized mock-upstream response. Mock HTTP payload
mangling is not evidence of a worker-wire inflation failure. Never edit product
code to add a fault seam in this phase. Any existing fault seam is permitted
only in the disposable stack and is never set in production.

The real-upstream subset comprises one native unary request, one native stream,
one supported translated request, provider auth failure, and observation-gated
429/5xx handling. Auth failure uses a deliberately invalid key supplied through
the existing local secret channel. Naturally occurring 429/5xx responses are
recorded only if observed during a bounded confirmation window; otherwise the
corresponding row is discharged on the mock stack with the reason recorded in
the exclusions registry. Never generate load against a real provider to force
429 or 5xx. Use low-cost requests only, never write credentials to artifacts,
and keep load, soak, and destructive fault injection exclusively on the
mock/disposable stack.

## 10. Workstream E: Load, Soak, and Regression Budgets

### E1. Baseline

Measure the unmodified baseline at a named commit on A3's reference disposable
Docker Compose fleet with representative unary, streaming, and mixed-protocol
workloads. Record hardware class, CPU model, core count, CI runner type, node
count, worker capacity, request-size distribution, upstream latency model,
concurrency, duration, throughput, p50/p95/p99, error rate, memory, mailbox
depth, and dropped usage rows. The baseline itself is the median of three runs.

### E2. Regression criteria

Unless a change explicitly fixes a correctness defect that invalidates the
baseline comparison:

- median-of-three throughput regression must not exceed 10%;
- median-of-three p95 latency regression must not exceed 20%;
- client error rate must not increase by more than 0.1 percentage point over
  the same workload windows;
- no dropped usage events, unbounded mailbox growth, or memory growth that does
  not stabilize after warm-up may appear.

Each baseline and candidate measurement is the median of three runs. Every run
uses a two-minute warm-up followed by a fixed 15-minute measurement window.
Error rate is total client errors divided by total client requests in that
identical window; the denominator and request mix are recorded with every run.

Environmental variance beyond these bands triggers investigation and at most
three repeat runs, never silent threshold relaxation. If variance persists,
escalate it as a release blocker and retain the worst observed result.

### E3. Soak

Run one 30-minute mixed-workload soak on A3's reference fleet for each release
candidate affecting a B2 hot-path module. Assert bounded memory after warm-up,
bounded mailboxes, stable worker reservations, no unexplained usage loss, and
no increasing error trend.

Load generation must target only A3's mock/disposable stack. Production
receives read-only observation only.

## 11. Workstream F: Recovery, Upgrade, and Operational Proof

### F1. Backup and restore

Run `gateway/scripts/verification/provision_fleet.sh` first to create three
nodes: the F2 migration leader, its worker follower, and a clean restore
candidate. F1 completes before F2 begins. Use a dedicated
`/tmp/janus-hardening-fleet/` generated only from committed `.example` files,
protected by a single-owner lock so concurrent drills cannot share or mutate
the fleet. Do not read the production inventory or production backup
configuration. A1's prerequisite inventory must confirm the backup/restore
scripts, `JANUS_BACKUP_ENV_FILE`, `JANUS_INVENTORY`, and local secret channel;
a missing prerequisite stops the drill and is reported rather than improvised.

Set `JANUS_BACKUP_ENV_FILE` to a disposable backup configuration with local
hot/cold directories and set `JANUS_INVENTORY` to
`/tmp/janus-hardening-fleet/inventory.env`. The F1 leader and initial F2
follower run A1's retained legacy artifact; F2's candidate artifact is built
from the named release-candidate commit. Both artifacts must be available
before F1 starts. Using that isolated configuration:

- create a backup with `dashboard/scripts/backup_leader.sh` on the disposable
  migration leader;
- restore it into the unused third node with
  `dashboard/scripts/restore_leader.sh` and verify the result with
  `dashboard/scripts/verify_backup.sh`;
- verify schema migrations, catalog readiness, provider/model/key behavior,
  and usage readability;
- prove that secrets required for decryption are handled through the existing
  secret channel and never appear in artifacts.

### F2. Rolling upgrade and rollback

F1/F2 use a separate topology from A3's Compose stack, created only on a
disposable local or CI host. `gateway/scripts/verification/provision_fleet.sh`
provisions the three disposable Docker-in-Docker nodes from the public
`docker:27-dind` image, installs `openssh-server` inside each node, and
generates throwaway SSH host/client keys. Each node runs its own Docker daemon
on an isolated verification network; none mounts the host Docker socket or any
production path. The first two nodes are the catalog-owning migration
leader/master and worker follower; the third remains F1's restore candidate
and does not join the rollout. The same script has a teardown mode that removes
all three nodes, their network, keys, generated configuration, and owner lock.

Generate the inventory from `gateway/deploy/inventory.env.example` into
`/tmp/janus-hardening-fleet/inventory.env`, set `JANUS_INVENTORY` to that file,
and leave `JANUS_DEPLOY_HOSTS` unset so the host-selection logic in
`deploy_prod.sh` derives only from the disposable inventory. The production
inventory is never read.

Exercise `dashboard/scripts/deploy_prod.sh` against that topology:

- migration-leader-first order, where the migration leader is the
  catalog-owning master whose boot applies migrations;
- an explicit artifact-skew step with the candidate artifact on the leader and
  the previous artifact still on the follower; D's mixed old/new-node row runs
  in this state before the follower is upgraded, never on identical artifacts;
- `janus_catalog_ready == 1` observed on the leader's `/metrics` endpoint
  before the follower registers, exactly one `janus_catalog_generation`
  publication per leader boot, and ready, artifact-consistent catalogs with no
  partial state across rollout and rollback;
- follower health and worker registration;
- failed-node halt behavior enforced by the deployment health gate: a
  nonzero exit, an explicit failure log, and no operations on subsequent nodes;
  the operator or deployment tooling then initiates rollback and the health
  gate is re-evaluated on the previous artifact;
- rollback to the previous artifact without attempting destructive database
  rollback. Catalog generation may legitimately return to the previous
  artifact's value; monotonic growth across rollback is not required.

For this drill, `deploy_prod.sh` and its inventory/host-selection layer are
operational tooling. If they cannot target the disposable topology, record the
exact defect. Separately reviewed fixes to demonstrated deploy-tooling defects
are permitted; “no production behavior change” refers specifically to
gateway/API runtime behavior. No release-artifact or runtime behavior change
is made merely to make the drill pass. Never fall back to the production
inventory or waive the drill.

Document any step that cannot be automated, including its exact manual
verification command.

### F3. Single-master recovery

Do not build active/active HA in this phase. First perform a capability
pre-check that names the supported backup/snapshot procedure and exact restore
command for full master-node replacement. If that capability is unsupported,
record the limitation explicitly in Section 4 and the runbook, and scope F3 to
the supported recovery subset rather than treating an unexecuted replacement
drill as passing. Then prove the supported recovery model:

- master process restart;
- full master-node replacement from backup/snapshot when the pre-check
  confirms support;
- worker reconnection and re-admission;
- catalog readiness before traffic;
- client-visible failure window and measured recovery time on Section 11's
  three-node test fleet, using the clean restore candidate for supported full
  master replacement.

Update the operator runbook so it does not imply automatic front-door failover.

## 12. Workstream G: Security and Data-Protection Regression Checks

Preserve and test existing controls, recording a command and observed result
for each:

- required boot secrets fail closed;
- provider secrets remain AES-256-GCM encrypted with keyring rotation, as
  implemented in `janus_secrets`;
- agent keys remain HMAC-hashed and compared with `crypto:hash_equals/2` in
  `janus_api_keys`;
- admin endpoints require the configured token outside loopback and never
  trust forwarded headers for this decision;
- TLS verification remains enabled for production upstream and distribution
  paths; prove rejection against a local self-signed listener expected to fail
  and verify production settings by read-only configuration assertions only;
- request-body and decompression caps reject oversize input safely;
- when A1 confirms the wire fault seam exists,
  `JANUS_WIRE_ENC_CORRUPT_AFTER` appears only in disposable fault-injection
  configuration, never in production; when absent, its exclusion is recorded
  without adding the seam;
- logs, shape fingerprints, metrics labels, traces, and audit artifacts exclude
  secrets and unbounded high-cardinality values;
- `.github/workflows/gitleaks.yml` remains enabled and the reviewed diff
  contains no fleet or operator identity;
- a focused static and live check confirms that no hot-path SQL was introduced,
  while SMALLINT 0/1 catalog normalization and `map_size/1` empty-map checks
  remain intact.

This workstream adds no RBAC or new authentication capability.

## 13. Workstream H: Maintainability and Documentation

### H1. Behavior-preserving decomposition

Decomposition is conditional, not a required refactor program. Split a large
module only when a planned change needs it and characterization coverage
demonstrates the seam. Each extraction must:

- have one clear responsibility and a small public interface;
- preserve exported behavior used by other modules unless an internal-only
  interface is deliberately narrowed;
- avoid dependency-direction inversions between `janus_core`, `janus_http`, and
  `janus_providers`;
- compile and pass all characterization tests before further edits;
- contain no unrelated renaming or formatting churn.

### H2. Documentation synchronization

Update comments and documentation whenever behavior changes. Specifically:

- after A2 owns verification-policy rewrites, correct remaining non-policy
  documentation drift against the tests and CI that actually exist;
- correct the gateway README's contradictory "separate repo" wording so the
  dashboard is described as a separate management plane within this repository,
  and correct stale sibling-repository script paths;
- reconcile the root and gateway README endpoint inventories, including
  `/v1/embeddings`, with the routes actually exposed;
- distinguish native, translated, and unsupported streaming paths in
  `gateway/README.md` and `gateway/docs/verification/live-matrix.md`;
- keep modality limitations and default-off knobs explicit;
- describe single-master recovery in `gateway/README.md` without implying
  active/active failover;
- remove stale comments that describe pre-change behavior;
- keep all artifacts impersonal, portable, and free of deployment specifics.

## 14. Workstream I: Existing Management-UI Hardening

Limit UI work to existing pages and workflows:

- explicit intent before editing sensitive configuration;
- clearing sensitive local state on cancel/success and correct focus
  restoration; after a failed save, retain non-sensitive values for correction,
  clear sensitive inputs, report the error, and focus the first sensitive input;
- accessible labels, keyboard navigation, dialog focus, and error reporting;
- no misleading loading, empty, disabled, or unsupported-state copy;
- no destructive action without the existing appropriate confirmation;
- desktop and mobile layout without overflow or clipped controls;
- accurate presentation of worker, catalog, provider, and alert states.

Verify changed flows with a real browser against a disposable local stack.
Do not add pages, features, or a new design system.

## 15. Change Packaging and Review Gates

Each change must be one logical unit:

1. verification infrastructure;
2. characterization for one behavioral seam;
3. one correctness fix;
4. one behavior-preserving extraction;
5. one operational runbook or drill;
6. one focused UI correction.

When a planned fix requires an H1 extraction, land the behavior-preserving
extraction first and the behavioral fix second as separate reviewed commits;
neither commit may contain the other's behavior change.

Before every commit:

- stage exactly the intended files;
- check for secrets, deployment identifiers, generated output, and unrelated
  work;
- run the applicable static and behavioral gates, including the A2 local
  CI-equivalent gate for pre-integration changes;
- run `ocr review --audience agent` with business context and resolve every
  Critical/Important finding;
- if `ocr` is unavailable or misconfigured, report the blocker and do not
  commit silently;
- record any rejected finding and the technical reason in the commit body.

Before the complete A2 gate exists, A1 bootstrap commits use the A1 baseline
commands. A2 bootstrap commits add the negative and multi-application parser
proofs. If A1's inventory is empty, the first B1 characterization commit may
use that interim gate once, including the parser proofs; accepting it enables
the first complete A2 gate. That gate must re-cover every file touched by the
bootstrap commits and the first B1 commit. Every later commit uses the complete
A2 gate; these exceptions are not reusable.

All durable D/E/F/I verification evidence uses A1's
`artifacts/verification/<commit>/` location and exclusions registry.

Use separate worktrees for concurrent workstreams. Integrate only after the
pre-integration gates pass and the user selects the integration action; `main`
CI then provides the post-integration confirmation.

## 16. Multi-Model Specification Audit Protocol

The specification itself is audited before implementation.

Reviewers:

- `janus/deepseek-v4.1-flash` through Pi;
- `janus/mimo-v2.6-flash` through Pi;
- `janus/step-5-preview` through Pi.

Rules:

1. Each model reviews the same complete specification and repository context
   independently in the first round. Reviewers do not see one another's
   findings before submitting their own.
2. Reviews are read-only. Models must cite specification sections and concrete
   repository evidence for correctness claims.
3. Findings are classified as Critical, Important, Minor, or False Positive.
   Critical covers unsafe, contradictory, or unexecutable requirements.
   Important covers material scope, verification, or acceptance gaps. Minor
   covers clarity and maintainability improvements.
4. The controller resolves every Critical and Important finding in the spec,
   or records an explicit technical rejection with repository evidence. Such a
   rejection requires explicit user acknowledgment before implementation.
   Minor findings are resolved or recorded as accepted trade-offs.
5. Later rounds review the revised complete spec and prior disposition summary
   so resolved findings are not repeated without new evidence.
6. No unavailable model is silently replaced. After three attempts that yield
   no substantive review, the controller records the attempt count and exact
   failure output and asks the user to choose retry, substitution, or an
   explicit waiver. When a substantive disagreement persists for three rounds,
   the controller instead records the round count, disputed positions, and
   supporting evidence, then asks the user to resolve the disagreement or
   accept a documented trade-off. Implementation cannot begin while either
   decision is absent; the settlement rule is never weakened silently.
7. Before the session ends, the final spec records the models, round count,
   and complete disposition summary, with a non-identifying copy under
   `artifacts/verification/<commit>/`. Pi runs from `/tmp` and all harness run
   roots are `/tmp/janus-hardening-audit-runs/`; raw Pi output is retained as
   `/tmp/janus-hardening-audit-*.txt`. No `.orch` directory or raw audit output
   is created in the repository.

The audit is settled only when all three reviewers report no unresolved
Critical or Important findings, every Minor finding has a disposition, and the
controller confirms the placeholder, consistency, scope, and executability
checks.

## 17. Phase Completion Criteria

The hardening phase is complete only when all of the following hold:

- The A2 pre-integration CI-equivalent gate passes, and `main` CI executes the
  documented static and non-vacuous EUnit gates successfully on the final
  integrated result.
- The live protocol/streaming/failure matrix passes for every currently
  supported scenario, with durable evidence.
- No unresolved Critical or Important correctness, security, data-loss, or
  verification defect remains.
- Load, soak, backup/restore, rolling-upgrade, rollback, and single-master
  recovery drills meet this specification.
- Every Section 12 security control has a recorded command and result, and the
  final reviewed diff contains no fleet or operator identity.
- Large-module modifications have the required characterization coverage and
  contain no unrelated behavior change.
- Documentation, comments, advertised support, and actual behavior agree.
- Changed management-UI flows pass real-browser desktop and mobile checks.
- Production was not mutated by verification.
- The Section 16 specification audit is settled, with its disposition summary
  embedded in this specification.
- Every remaining limitation is either listed in Section 4 or documented as an
  accepted trade-off with owner-facing rationale.

## 18. Recommended Execution Order

1. Workstream A: establish verification truth and CI.
2. Workstream B: characterize the highest-risk seams.
3. Workstreams C and D: correct demonstrated protocol and reliability defects;
   defer D's mixed-artifact row until F2 creates the required skew state.
4. Workstreams E and F: prove load, recovery, upgrade, and rollback behavior,
   then execute D's deferred mixed-artifact row.
5. Workstreams G and H: finish security regression and maintainability work.
6. Workstream I: complete focused operator-UI hardening.
7. Confirm Section 16 audit settlement, run the complete final matrix, and
   review every remaining limitation and documentation drift.

No later workstream is used to justify expanding the feature freeze.

## Appendix 0: Changes already landed against this specification

Recorded here so a later reader does not re-open settled work.

- **A1 (baseline inventory) — done.** 19 standalone `*_tests.erl` modules
  plus inline `-ifdef(TEST)` tests; `rebar3 eunit` executes 179 tests. One
  pre-existing failure was found and fixed (a stale row-index assertion in
  `janus_usage:build_insert_shape_test/0`, off by one because it omitted the
  defaulted `ts` parameter; the product code was correct).
- **A2 (CI executes the tests) — done.** `.github/workflows/ci.yml` now runs
  compile, format, the non-vacuous EUnit gate, and a dashboard job
  (ruff + SPA typecheck + build). `gateway/scripts/verification/assert_eunit_nonempty.sh`
  implements the assertion, with parser proofs for: no summary (fails),
  multi-application summing (3 + 4 = 7), reported failures (fails), and a
  zero-count suite (fails). The gate was verified to go red by inducing a
  real test failure and then reverted. `AGENTS.md` § Verification was
  rewritten to match.
- **Still open:** A3 and every workstream after it.

## Appendix A: Multi-Model Specification Audit Record

### A.1 Review execution

All reviews were read-only and run through Pi with the required model IDs. Raw
output and retry evidence remain under `/tmp/janus-hardening-audit-*.txt`.
MiMo required chunked prompts because large requests failed or timed out; no
model was substituted or waived.

| Reviewer | Substantive review rounds | Final result |
|---|---:|---|
| `janus/deepseek-v4.1-flash` | 6 | SETTLED |
| `janus/step-5-preview` | 6 | SETTLED |
| `janus/mimo-v2.6-flash` | 3 chunked rounds | SETTLED across all chunks |

### A.2 Complete disposition summary

- Round 1 resolved verification-policy contradictions, non-vacuous test
  inventory, pre/post-integration gates, cache paths, evidence sources, reusable
  verification infrastructure, target-module inventory, wire/mixed-version
  coverage, completion gates, real operational script names, dashboard CI, and
  security-control evidence. Minor dispositions covered CI comments, OTP/Docker
  pinning, evidence locations, conditional decomposition, OCR blocking, audit
  paths, numeric load/soak limits, and documentation ownership. Step's CI,
  gitleaks, fleet, local-gate, MiniMax T2I, module-inventory, and OTP findings
  were resolved by the same changes.
- Round 1 rejected three suggested spec defects with technical evidence:
  `janus_lb` already implements Retry-After cooldown handling; usage estimation
  already has production seams and tests; `/v1/embeddings` was already an
  advertised existing surface, so the freeze on new failover was correct.
- Round 2 isolated backup/deploy configuration to generated disposable files,
  blocked production fallback, added the EUnit non-vacuity assertion, preserved
  static invariants and artifact ignores, reconciled endpoint documentation,
  required knob compatibility checks, and bounded the real-upstream subset.
  Step settled after empty-inventory, metric-inventory, and fleet clarifications.
  MiMo availability remained an explicit process blocker, not a hidden waiver.
- Round 3 separated the Compose and Docker-in-Docker fleets, expanded
  embeddings verification, added reviewer-escalation rules, and distinguished
  product defects from stale tests. Its minor resolutions added SPA typecheck,
  a negative parser proof, a bounded bootstrap exception, median-of-three
  baselines, durable audit summaries, deploy host selection, canonical Docker
  commands, distinct writer-outage evidence, packaging exclusions, and fixed
  load-measurement windows. Step remained settled.
- Round 4 gave D a real master/worker Compose topology and replaced invalid
  catalog-convergence wording with readiness and generation checks. It also
  fixed load symmetry, F1/F2 ordering, documentation ownership, matrix and
  command paths, and disposable-host restrictions. Step's inventory-path and
  absent-embeddings-route clarifications were resolved.
- MiMo's first substantive chunked review resolved empty-inventory sequencing,
  Docker/native CI command roles, exact multi-application EUnit parsing and
  parser proofs, exclusions registration, cache-key precision, `npm ci`, and
  workflow syntax validation. It made real 429/5xx checks observation-gated,
  named the legacy compatibility reference, required fault-seam and operational
  prerequisite checks, defined a clean restore node and artifact skew, and made
  wire outcomes measurable. Minor resolutions capped environmental repeats,
  allowed A1 evidence gaps, recorded CPU/runner details, clarified deploy-tool
  fixes and rollback generation, added F3 capability pre-checks and halt/
  rollback sequencing, moved audit run roots to `/tmp`, fixed security-check
  wording, specified local TLS rejection, added fleet locking, and required
  bootstrap re-coverage.
- Round 5 removed the invalid mock-HTTP substitute for worker-wire corruption,
  separated pre/post-first-byte behavior, and gave the first B1 commit a
  one-time interim-gate exception in the empty-inventory branch. It also
  deferred mixed-artifact verification to F2, retained named legacy/candidate
  artifacts, conditioned fault-seam controls on existence, pinned local rebar3,
  centralized durable evidence, made Postgres-outage acceptance observable,
  corrected A3 to the three-node fleet, and deferred to D's observation-gated
  real-upstream rules. Step settled; MiMo's remaining findings were resolved.
- Round 6 DeepSeek and Step settled with no Critical or Important findings.
  Their minor dispositions retained the complete CI-equivalent gate around the
  Docker target, allowed documented manual failure injection on disposable
  nodes, accepted the pre-forward corruption trigger, and named baseline commit
  `223c8b6` for audit artifacts. The corrupt-wire and oversized-response rows
  were separated so each asserts its actual classification and counter. Every
  MiMo chunk and targeted follow-up settled. Its final minor dispositions named
  Section 11's recovery fleet, required extraction before a separate behavioral
  fix, named the streaming/recovery documentation targets, defined failed-save
  clearing and focus for sensitive inputs, required user acknowledgment for
  rejected Critical/Important findings, and separated reviewer-failure evidence
  from persistent-disagreement evidence.

### A.3 Settlement

The controller confirms that the feature freeze, production read-only rule,
worktree isolation, placeholder scan, internal consistency, and executability
checks pass. No unresolved Critical or Important finding remains, every Minor
finding has a disposition, and all three required reviewers are settled.
