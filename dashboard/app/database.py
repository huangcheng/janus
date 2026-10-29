"""Asyncpg connection pool and query helpers for the Janus dashboard.

Single pool shared across the app; queries use $N placeholders (Postgres
native — no ? rewriting needed since we only target Postgres).
"""

import logging
from contextlib import asynccontextmanager
from typing import Any

import asyncpg

from .config import config

logger = logging.getLogger("janus.dashboard.db")

_pool: asyncpg.Pool | None = None


async def init_pool() -> asyncpg.Pool:
    """Create the connection pool. Called once at app startup."""
    global _pool
    if _pool is not None:
        return _pool
    _pool = await asyncpg.create_pool(
        host=config.db_host,
        port=config.db_port,
        user=config.db_user,
        password=config.db_password,
        database=config.db_name,
        min_size=2,
        max_size=10,
        command_timeout=30,
    )
    await ensure_schema(_pool)
    logger.info("database pool created: %s:%s/%s", config.db_host, config.db_port, config.db_name)
    return _pool


async def ensure_schema(pool: asyncpg.Pool) -> None:
    """Create the dashboard-owned tables if missing.

    Everything else (catalog, usage_events, …) is owned by the gateway's
    migrations. Management-side tables: gateway_nodes (node registry) and
    the entitlement-matrix tables (spec 2026-10-05 Part A): key_entitlements
    (per-(key, listing) evidence), entitlement_codes (single-source
    classification rules, seeded once), probe_budget_counters (daily probe
    budget accounting that survives restarts), plus provider_probe_state
    (OpenAI Decisions probe budget/cooldown, spec 2026-10-07 §4.3).
    """
    async with pool.acquire() as conn:
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS gateway_nodes (
                id BIGSERIAL PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                data_host TEXT NOT NULL,
                data_port INTEGER NOT NULL DEFAULT 8080,
                stats_host TEXT NOT NULL,
                stats_port INTEGER NOT NULL DEFAULT 8090,
                enabled BOOLEAN NOT NULL DEFAULT TRUE,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                stats_token_ciphertext TEXT
            )
            """
        )
        # Audit trail: persisted dashboard mutations (was an in-memory
        # ring that reset on every restart/deploy, leaving the home
        # page activity chart and Recent actions empty after deploys).
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS audit_events (
                id BIGSERIAL PRIMARY KEY,
                ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                actor TEXT NOT NULL DEFAULT 'console',
                action TEXT NOT NULL,
                target TEXT,
                detail TEXT
            )
            """
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS audit_events_ts_idx ON audit_events (ts DESC)"
        )
        # Per-node stats token (JSEC envelope, hex-encoded TEXT; NULL =
        # fall back to the global JANUS_STATS_TOKEN). The ALTER is the
        # migration path for pre-existing installs; fresh creates get
        # the column from the CREATE above.
        await conn.execute(
            "ALTER TABLE gateway_nodes ADD COLUMN IF NOT EXISTS stats_token_ciphertext TEXT"
        )
        # Build sha per gateway (operator-set at registration). Surfaces
        # #8 fleet version skew in /api/nodes — when two nodes ship
        # different shas, the dashboard flags the row.
        await conn.execute("ALTER TABLE gateway_nodes ADD COLUMN IF NOT EXISTS build_sha TEXT")
        # --- Entitlement matrix (spec 2026-10-05 A.1). Column names are a
        # gateway read contract (Part B reads them via read-only SQL) —
        # do not rename. shape_streak is dashboard-internal (consecutive
        # input_shape re-probes; feeds the escalated circuit breaker) and
        # is invisible to the gateway's named-column SELECT.
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS key_entitlements (
                provider_key_id BIGINT NOT NULL REFERENCES provider_keys (id) ON DELETE CASCADE,
                model_name      TEXT  NOT NULL,
                status          TEXT  NOT NULL CHECK (status IN ('ok','deny','balance','unknown','broken')),
                http_status     INTEGER,
                error_code      TEXT,
                checked_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                source          TEXT  NOT NULL DEFAULT 'probe' CHECK (source IN ('probe','traffic')),
                escalated       BOOLEAN NOT NULL DEFAULT FALSE,
                shape_streak    SMALLINT NOT NULL DEFAULT 0,
                PRIMARY KEY (provider_key_id, model_name)
            )
            """
        )
        # --- Classification rules (spec A.2): the single source of truth
        # for probe, refresher and retry-time classification. Seeded ONCE
        # from production evidence; thereafter managed only through the
        # dashboard admin API (/api/entitlements/codes).
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS entitlement_codes (
                id                 BIGSERIAL PRIMARY KEY,
                provider           TEXT   NOT NULL,
                match_status       TEXT   NOT NULL CHECK (match_status IN ('exact','regex')),
                code_keyword       TEXT   NOT NULL,
                outcome            TEXT   NOT NULL CHECK (outcome IN
                    ('deny','balance','rate','input_shape','premark_input_shape')),
                key_scoped_balance BOOLEAN NOT NULL DEFAULT FALSE,
                created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """
        )
        # --- Daily probe budget counters (spec A.4): per provider + day.
        # `calls` is the day total; `healing_calls` the portion spent by
        # the healing loop (share enforcement: bootstrap <= 75%, healing
        # always keeps >= 25% of JANUS_PROBE_DAILY_CALLS available).
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS probe_budget_counters (
                provider      BIGINT NOT NULL REFERENCES providers (id) ON DELETE CASCADE,
                day           DATE   NOT NULL DEFAULT CURRENT_DATE,
                calls         BIGINT NOT NULL DEFAULT 0,
                healing_calls BIGINT NOT NULL DEFAULT 0,
                PRIMARY KEY (provider, day)
            )
            """
        )
        # Seed the codes table once (production evidence: DashScope / Ark /
        # zhipu classes from the spec, 429 dual-class rows, multi-language
        # deny-regex fallback rows, premark modality families and the
        # key_scoped_balance account-state flags). Guarded by emptiness so
        # restarts and replicas never re-seed over operator edits.
        seeded = await conn.fetchval("SELECT COUNT(*) FROM entitlement_codes")
        if not seeded:
            await conn.execute(_ENTITLEMENT_CODES_SEED)
        # --- OpenAI Decisions probe accounting (spec 2026-10-07 §4.3).
        # The dashboard owns this table; the gateway never reads it.
        # Budget (20/day), cooldown (5 min) and single-flight are enforced
        # transactionally against it by app/decisions_probe.py.
        #
        # Protocol note: providers.protocol itself is GATEWAY-owned — the
        # CHECK constraint accepting 'openai_decisions' is extended by the
        # gateway migration on leader boot (apps/janus_core/priv/migrations).
        # The dashboard write gate (app/decisions.py) fail-closes Decisions
        # writes until every registry node advertises the protocol on
        # /readyz, which by rollout order implies the CHECK is already
        # extended. Dashboard-side acceptance lives in the routers'
        # PROTOCOLS lists; nothing to migrate here.
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS worker_notes (
                node      TEXT PRIMARY KEY,
                note      TEXT NOT NULL DEFAULT '',
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """
        )
        # --- Operator account (2026-10-25): single-admin multi-factor
        # auth. password_hash is an argon2id PHC string (NULL = passkey
        # only); totp_secret is JSEC-encrypted hex (JANUS_SECRETS_KEY,
        # same envelope as gateway_nodes.stats_token); passkeys live in
        # their own table (multiple credentials). auth_events replaces the
        # old in-memory login lockout (restart-safe, auditable).
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS operator_account (
                id           INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
                username     TEXT NOT NULL UNIQUE,
                password_hash TEXT,
                totp_secret  TEXT,
                totp_enabled BOOLEAN NOT NULL DEFAULT FALSE,
                totp_last_step BIGINT,
                created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """
        )
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS passkey_credentials (
                credential_id TEXT PRIMARY KEY,
                public_key    TEXT NOT NULL,
                sign_count    BIGINT NOT NULL DEFAULT 0,
                transports    TEXT,
                name          TEXT NOT NULL,
                created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                last_used_at  TIMESTAMPTZ
            )
            """
        )
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS auth_events (
                id      BIGSERIAL PRIMARY KEY,
                kind    TEXT NOT NULL,
                success BOOLEAN NOT NULL,
                ip      TEXT,
                detail  TEXT,
                ts      TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """
        )
        await conn.execute("CREATE INDEX IF NOT EXISTS auth_events_ts_idx ON auth_events (ts)")
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS auth_events_kind_ts_idx ON auth_events (kind, ts)"
        )
        # One-time TOTP fallback codes. Only the keyed hash is stored; the
        # plaintext is shown exactly once at generation time. Regenerating
        # deletes the whole set, so the table never exceeds RECOVERY_COUNT rows.
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS recovery_codes (
                code_hash  TEXT PRIMARY KEY,
                used_at    TIMESTAMPTZ,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """
        )
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS provider_probe_state (
                provider_id   BIGINT PRIMARY KEY REFERENCES providers (id) ON DELETE CASCADE,
                last_probe_at TIMESTAMPTZ,
                probes_today  INTEGER NOT NULL DEFAULT 0,
                day_utc       DATE,
                in_flight     BOOLEAN NOT NULL DEFAULT FALSE
            )
            """
        )
        # --- Auto-router tier reorder (spec 2026-10-11 D11/D26). The
        # twin SQL lives in the gateway migrations (019/020 — same
        # shared Postgres); this idempotent create lets the dashboard
        # boot first. auto_router_audit: one row per tiers write through
        # either entrypoint + dry_run compute rows + restore rows.
        # auto_router_state: the D26 singleton (id=1 seeded) — pending,
        # lease, reject counters/marker; NOT distributed settings.
        # last_manual_edit_at is the D30/D35 anchor (additive over D26's
        # core list; the audit table is append-only so it lives here).
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS auto_router_audit (
                id BIGSERIAL PRIMARY KEY,
                at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                actor TEXT NOT NULL CHECK (actor IN ('system', 'human')),
                before_tiers JSONB,
                after_tiers JSONB,
                scores JSONB,
                kind TEXT NOT NULL CHECK (kind IN ('commit', 'restore', 'reject', 'dry_run'))
            )
            """
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS auto_router_audit_kind_id_idx "
            "ON auto_router_audit (kind, id DESC)"
        )
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS auto_router_state (
                id SMALLINT PRIMARY KEY CHECK (id = 1),
                pending_tiers JSONB,
                pending_since TIMESTAMPTZ,
                explore_cooldown JSONB,
                last_auto_write_at TIMESTAMPTZ,
                lease_owner TEXT,
                lease_until TIMESTAMPTZ,
                consecutive_rejects INTEGER NOT NULL DEFAULT 0,
                reject_quarantined_until TIMESTAMPTZ,
                reject_marker JSONB,
                last_manual_edit_at TIMESTAMPTZ
            )
            """
        )
        await conn.execute(
            "INSERT INTO auto_router_state (id) VALUES (1) ON CONFLICT (id) DO NOTHING"
        )
        # --- Alerting (observability-depth Task 6 Step 1). All three
        # tables are dashboard-owned; the gateway never reads them.
        # alert_state: one row per (rule, scope) — the persisted firing
        # memory (a dashboard restart can never resolve a firing alert;
        # hysteresis is FM-8). cycles is written on transitions only
        # (streak value at fire, 0 at resolve). alert_events: the
        # append-only outbox (fire/resolve/test rows) the webhook sender
        # drains; delivered/attempts/next_retry_at drive capped
        # exponential backoff (attempts >= 8 retires pre-POST).
        # alert_control: the cross-process pause sentinel (id=1
        # singleton; a missing row reads as unpaused).
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS alert_state (
                rule TEXT NOT NULL, scope TEXT NOT NULL,
                state TEXT NOT NULL CHECK (state IN ('ok','firing')),
                cycles INTEGER NOT NULL DEFAULT 0,
                first_fired_at TIMESTAMPTZ,
                last_eval_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                PRIMARY KEY (rule, scope)
            )
            """
        )
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS alert_events (
                id BIGSERIAL PRIMARY KEY,
                ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                rule TEXT NOT NULL, scope TEXT NOT NULL,
                severity TEXT NOT NULL CHECK (severity IN ('info','warning','critical')),
                state TEXT NOT NULL CHECK (state IN ('firing','resolved','test')),
                message TEXT NOT NULL, detail JSONB,
                delivered BOOLEAN NOT NULL DEFAULT FALSE,
                attempts INTEGER NOT NULL DEFAULT 0,
                next_retry_at TIMESTAMPTZ
            )
            """
        )
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS alert_control (
                id SMALLINT PRIMARY KEY CHECK (id = 1),
                paused BOOLEAN NOT NULL DEFAULT FALSE,
                paused_at TIMESTAMPTZ
            )
            """
        )
        await conn.execute(
            "INSERT INTO alert_control (id, paused) VALUES (1, FALSE) ON CONFLICT (id) DO NOTHING"
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS alert_events_ts_idx ON alert_events (ts DESC)"
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS alert_events_rule_scope_idx "
            "ON alert_events (rule, scope, ts DESC)"
        )
        # --- Gateway log persistence (observability-depth Task 7). The
        # nodes.py puller drains each node's /stats/logs ring into this
        # dashboard-owned table after every successful health poll;
        # /api/logs reads it by default (source=live stays pass-through).
        # UNIQUE (node, idx, ts): idx resets per gateway boot, so ts must
        # disambiguate — and PG NULLs are distinct under UNIQUE, hence
        # ts NOT NULL. ON CONFLICT DO NOTHING in the puller is the
        # backstop; the high-water mark is the primary dedupe.
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS gateway_log_events (
                id BIGSERIAL PRIMARY KEY,
                node TEXT NOT NULL, idx BIGINT NOT NULL,
                ts TIMESTAMPTZ NOT NULL,
                level TEXT NOT NULL, fields JSONB,
                scraped_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE (node, idx, ts)
            )
            """
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS gateway_log_events_ts_idx ON gateway_log_events (ts DESC)"
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS gateway_log_events_node_ts_idx "
            "ON gateway_log_events (node, ts DESC)"
        )
        # --- Cost reporting (spec 2026-10-15-maturity-hardening H8-D1/D3).
        # model_prices is dashboard-owned (operator-entered on the Providers
        # page); the gateway NEVER reads it — spend is computed at query time
        # by the dashboard over usage_events (H8-D2). daily_cost_limit rides
        # the GATEWAY-owned api_keys table via the same additive boot-ALTER
        # idiom the gateway's own quota migration (014) uses, so an agent key
        # and its budget stay one row; the gateway does not read the column
        # (H8-D3: WARN alert only — no enforcement, no 429).
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS model_prices (
                model_name     TEXT PRIMARY KEY,
                input_per_mtok NUMERIC NOT NULL,
                output_per_mtok NUMERIC NOT NULL,
                currency       TEXT NOT NULL DEFAULT 'CNY',
                updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """
        )
        await conn.execute("ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS daily_cost_limit NUMERIC")
        # Cascade journal (spec 2026-10-22 §3): what a provider/listing/model
        # retirement turned off, so enabling the provider again (or re-adding
        # it, or re-binding the model) can replay it. Dashboard-owned — the
        # gateway never reads it, so no gateway migration is involved.
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS config_cascade_events (
                id BIGSERIAL PRIMARY KEY,
                at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                actor TEXT NOT NULL,
                source_kind TEXT NOT NULL,
                source_provider_id BIGINT,
                source_provider_name TEXT,
                source_model_id BIGINT,
                routes JSONB NOT NULL DEFAULT '[]'::jsonb,
                models JSONB NOT NULL DEFAULT '[]'::jsonb,
                tiers JSONB NOT NULL DEFAULT '{}'::jsonb,
                restored_at TIMESTAMPTZ,
                restore_actor TEXT
            )
            """
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS config_cascade_events_open_idx "
            "ON config_cascade_events (source_provider_id, source_provider_name) "
            "WHERE restored_at IS NULL"
        )
        # Deferred tier surgery (spec 2026-10-22 §5.3): when the tiers lock is
        # held past the request's retry budget the prune/restore is recorded
        # here INSIDE the caller's transaction — so the intent commits exactly
        # with the route/model half — and applied by the cascade retry loop.
        # Dashboard-owned; the gateway never reads it.
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS config_cascade_pending (
                id BIGSERIAL PRIMARY KEY,
                at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                kind TEXT NOT NULL,
                payload JSONB NOT NULL DEFAULT '{}'::jsonb,
                source_kind TEXT,
                provider_id BIGINT,
                note TEXT,
                attempts INT NOT NULL DEFAULT 0,
                last_try_at TIMESTAMPTZ,
                resolved_at TIMESTAMPTZ,
                resolution TEXT
            )
            """
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS config_cascade_pending_open_idx "
            "ON config_cascade_pending (kind) WHERE resolved_at IS NULL"
        )
        # The journal event a deferred prune belongs to: when the retry finally
        # removes the member it must also record WHAT it removed (with the
        # indices) on that event, otherwise the later re-enable/route-add has
        # no tier seat to replay (added after the table shipped).
        await conn.execute(
            "ALTER TABLE config_cascade_pending ADD COLUMN IF NOT EXISTS event_id BIGINT"
        )
        await _ensure_failure_observability_schema(conn)


async def _ensure_failure_observability_schema(conn: asyncpg.Connection) -> None:
    """Failure-observability persistence (spec 2026-10-13 section 5).

    All tables are dashboard-owned; the gateway never reads or writes
    them. node_id is TEXT everywhere: the stringified gateway_nodes.id
    for gateway-sourced rows, or the literal 'dashboard' for the
    dashboard-native task writer (the only allowed second writer; the
    single-writer rule covers the ops-event drain path only).
    """
    # Live snapshot columns on the nodes poller's registry row. They are
    # touched ONLY by the ops puller (app/ops_puller.py); PATCH/PUT of a
    # node never names them, so a registry edit cannot clobber them.
    # ops_boot_id doubles as the "last stored boot" for exactly-once
    # boot-change detection.
    await conn.execute("ALTER TABLE gateway_nodes ADD COLUMN IF NOT EXISTS health_snapshot JSONB")
    await conn.execute(
        "ALTER TABLE gateway_nodes ADD COLUMN IF NOT EXISTS health_pulled_at TIMESTAMPTZ"
    )
    await conn.execute(
        "ALTER TABLE gateway_nodes ADD COLUMN IF NOT EXISTS "
        "ops_lagging BOOLEAN NOT NULL DEFAULT FALSE"
    )
    await conn.execute("ALTER TABLE gateway_nodes ADD COLUMN IF NOT EXISTS ops_boot_id TEXT")
    # Ring events only. PK (node_id, boot_id, idx): idx restarts at 1 on
    # every gateway boot, so boot_id is part of the identity (this is
    # the fix for the gateway_log_events boot-reset PK hazard — do not
    # copy that table's shape). Boot/gap facts live in markers, never
    # in this PK space.
    await conn.execute(
        """
        CREATE TABLE IF NOT EXISTS gateway_ops_events (
            node_id TEXT NOT NULL,
            boot_id TEXT NOT NULL,
            idx BIGINT NOT NULL,
            ts TIMESTAMPTZ NOT NULL,
            type TEXT NOT NULL,
            schema_version INTEGER NOT NULL DEFAULT 1,
            payload JSONB NOT NULL DEFAULT '{}'::jsonb,
            scraped_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY (node_id, boot_id, idx)
        )
        """
    )
    await conn.execute(
        "CREATE INDEX IF NOT EXISTS gateway_ops_events_ts_idx ON gateway_ops_events (ts DESC)"
    )
    await conn.execute(
        "CREATE INDEX IF NOT EXISTS gateway_ops_events_node_ts_idx "
        "ON gateway_ops_events (node_id, ts DESC)"
    )
    # Drain high-water per (node, boot): the max idx durably committed
    # AND applied. Written in the same transaction as the batch it
    # covers, never on peek. Pruned with the events (14d), except the
    # row of a node's current ops_boot_id (an idle node must not
    # re-apply an old ring after a prune).
    await conn.execute(
        """
        CREATE TABLE IF NOT EXISTS gateway_ops_highwater (
            node_id TEXT NOT NULL,
            boot_id TEXT NOT NULL,
            high_water BIGINT NOT NULL,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY (node_id, boot_id)
        )
        """
    )
    # Markers: boot-change and overflow facts. marker_seq comes from one
    # shared sequence (monotonic per node by construction; the spec's
    # "per-node sequence" without a sequence-per-node DDL race).
    # UNIQUE (node_id, prior_boot_id, reason) makes boot-change
    # idempotent (ON CONFLICT DO NOTHING); overflow markers carry a
    # NULL prior_boot_id, so PG's distinct-NULL rule leaves them keyed
    # by marker_seq alone.
    await conn.execute("CREATE SEQUENCE IF NOT EXISTS gateway_ops_marker_seq")
    await conn.execute(
        """
        CREATE TABLE IF NOT EXISTS gateway_ops_markers (
            node_id TEXT NOT NULL,
            marker_seq BIGINT NOT NULL DEFAULT nextval('gateway_ops_marker_seq'),
            ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            reason TEXT NOT NULL CHECK (reason IN ('boot_change', 'overflow')),
            prior_boot_id TEXT,
            boot_id TEXT,
            detail JSONB NOT NULL DEFAULT '{}'::jsonb,
            PRIMARY KEY (node_id, marker_seq)
        )
        """
    )
    await conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS gateway_ops_markers_boot_uq "
        "ON gateway_ops_markers (node_id, prior_boot_id, reason)"
    )
    await conn.execute(
        "CREATE INDEX IF NOT EXISTS gateway_ops_markers_ts_idx ON gateway_ops_markers (ts DESC)"
    )
    # Cool episodes. Open identity = (node_id, target_kind, target_id,
    # model_id); reason is NOT part of it (a reason change is a
    # supersede). model_id is NOT NULL DEFAULT '' so the partial unique
    # index treats "no model" as one value (SQL NULLs are distinct and
    # would let duplicates through). First close wins: the BEFORE UPDATE
    # trigger pins ended_at/end_reason once set, and every close in the
    # puller also carries WHERE ended_at IS NULL.
    await conn.execute(
        """
        CREATE TABLE IF NOT EXISTS cool_episodes (
            id BIGSERIAL PRIMARY KEY,
            node_id TEXT NOT NULL,
            target_kind TEXT NOT NULL
                CHECK (target_kind IN ('provider_key', 'provider', 'route')),
            target_id TEXT NOT NULL,
            provider_id TEXT NOT NULL DEFAULT '',
            model_id TEXT NOT NULL DEFAULT '',
            reason TEXT NOT NULL,
            started_at TIMESTAMPTZ NOT NULL,
            last_until_ms BIGINT,
            last_error_code TEXT,
            ended_at TIMESTAMPTZ,
            end_reason TEXT CHECK (end_reason IN
                ('clear', 'expired', 'reconcile', 'lost_edge', 'superseded')),
            boot_id TEXT,
            absent_polls INTEGER NOT NULL DEFAULT 0,
            meta JSONB NOT NULL DEFAULT '{}'::jsonb,
            CHECK ((ended_at IS NULL) = (end_reason IS NULL))
        )
        """
    )
    await conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS cool_episodes_open_uq "
        "ON cool_episodes (node_id, target_kind, target_id, model_id) "
        "WHERE ended_at IS NULL"
    )
    await conn.execute(
        "CREATE INDEX IF NOT EXISTS cool_episodes_node_started_idx "
        "ON cool_episodes (node_id, started_at DESC)"
    )
    await conn.execute(
        "CREATE INDEX IF NOT EXISTS cool_episodes_ended_idx "
        "ON cool_episodes (ended_at) WHERE ended_at IS NOT NULL"
    )
    await conn.execute(
        """
        CREATE OR REPLACE FUNCTION cool_episodes_first_close_wins() RETURNS trigger AS $$
        BEGIN
            IF OLD.ended_at IS NOT NULL THEN
                NEW.ended_at := OLD.ended_at;
                NEW.end_reason := OLD.end_reason;
            END IF;
            RETURN NEW;
        END
        $$ LANGUAGE plpgsql
        """
    )
    await conn.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM pg_trigger
                WHERE tgname = 'cool_episodes_first_close'
                  AND tgrelid = 'cool_episodes'::regclass
            ) THEN
                CREATE TRIGGER cool_episodes_first_close
                BEFORE UPDATE ON cool_episodes
                FOR EACH ROW EXECUTE FUNCTION cool_episodes_first_close_wins();
            END IF;
        END
        $$
        """
    )
    # Task runs: unique (node_id, run_id). Unfinished <=> finished_at IS
    # NULL; every close is WHERE finished_at IS NULL (idempotent).
    # node_id='dashboard' rows come from the dashboard-native writer.
    await conn.execute(
        """
        CREATE TABLE IF NOT EXISTS task_runs (
            id BIGSERIAL PRIMARY KEY,
            node_id TEXT NOT NULL,
            run_id TEXT NOT NULL,
            name TEXT NOT NULL,
            boot_id TEXT,
            started_at TIMESTAMPTZ NOT NULL,
            finished_at TIMESTAMPTZ,
            phase TEXT,
            outcome TEXT,
            error_class TEXT,
            error TEXT,
            duration_ms BIGINT,
            expected_duration_ms BIGINT,
            schedule_interval_ms BIGINT,
            closed_by TEXT,
            meta JSONB NOT NULL DEFAULT '{}'::jsonb,
            UNIQUE (node_id, run_id)
        )
        """
    )
    await conn.execute(
        "CREATE INDEX IF NOT EXISTS task_runs_name_finished_idx "
        "ON task_runs (node_id, name, finished_at DESC)"
    )
    await conn.execute(
        "CREATE INDEX IF NOT EXISTS task_runs_open_idx "
        "ON task_runs (node_id) WHERE finished_at IS NULL"
    )


# One-time entitlement_codes seed (spec A.2, production evidence).
# - exact rows: provider-native error codes (deny / 429 balance vs rate).
# - regex rows: anchored multi-language wording fallback. Deny wording is
#   explicit activation/entitlement phrasing only — the phrases
#   "no permission" / "unsupported operation" are deliberately seeded as
#   input_shape (NOT deny): they fire on input-shape and content-policy
#   paths, and a false deny removes a good key entirely (fail-open rule).
# - premark_input_shape rows: modality families matched against listing
#   names — those listings are marked ok+input_shape locally, spending
#   zero probe budget and never entering the hourly loop.
# - key_scoped_balance=TRUE marks providers whose balance is account
#   state (one canary probe per key updates all of that key's balance
#   rows). provider='' rows apply to every provider.
_ENTITLEMENT_CODES_SEED = """
INSERT INTO entitlement_codes (provider, match_status, code_keyword, outcome, key_scoped_balance) VALUES
  -- DashScope native codes
  ('dashscope', 'exact', 'ProductNotActivated', 'deny', FALSE),
  ('dashscope', 'exact', 'Throttling', 'rate', FALSE),
  ('dashscope', 'exact', 'Arrearage', 'balance', TRUE),
  -- Ark: InvalidEndpointOrModel arrives as 400 OR 404 (never assume 404)
  ('ark', 'exact', 'InvalidEndpointOrModel', 'deny', FALSE),
  ('ark', 'exact', 'Throttling', 'rate', FALSE),
  ('ark', 'exact', 'InsufficientAccountBalance', 'balance', TRUE),
  -- zhipu: 1113 = balance/资源包 (429); 1211 = model-not-exist (400);
  -- 1302 = call-rate limit (429). Coding-plan keys only work on the
  -- coding endpoint (production evidence).
  ('zhipu', 'exact', '1113', 'balance', TRUE),
  ('zhipu', 'exact', '1211', 'deny', FALSE),
  ('zhipu', 'exact', '1302', 'rate', FALSE),
  -- Multi-language deny wording (any provider). Anchored phrasing only;
  -- the bare product.*not.*activate shape is forbidden (it matches
  -- "activation not required").
  ('', 'regex', 'product (is )?not activated|products? not activated|未开通|not entitled|product.*未开通', 'deny', FALSE),
  -- input_shape wording (any provider): NOT deny evidence by themselves
  ('', 'regex', 'no permission|unsupported operation for this model|unsupported operation', 'input_shape', FALSE),
  -- 429 balance wording fallback (any provider); unmatched 429 defaults
  -- to rate-class (retry, no cooldown)
  ('', 'regex', 'insufficient[ _-]?balance|arrearage|余额不足|欠费', 'balance', FALSE),
  -- Premark modality families (listing-name substring, zero probe spend)
  ('dashscope', 'exact', 'wanx', 'premark_input_shape', FALSE),
  ('dashscope', 'exact', 'wan2', 'premark_input_shape', FALSE),
  ('dashscope', 'exact', 'wan-v', 'premark_input_shape', FALSE),
  ('dashscope', 'exact', 'qwen-image', 'premark_input_shape', FALSE),
  ('dashscope', 'exact', 'cosyvoice', 'premark_input_shape', FALSE),
  ('dashscope', 'exact', 'paraformer', 'premark_input_shape', FALSE),
  ('dashscope', 'exact', 'sambert', 'premark_input_shape', FALSE),
  ('dashscope', 'exact', 'qwen-audio', 'premark_input_shape', FALSE),
  ('dashscope', 'exact', 'qwen-tts', 'premark_input_shape', FALSE),
  ('ark', 'exact', 'seedance', 'premark_input_shape', FALSE),
  ('ark', 'exact', 'seedream', 'premark_input_shape', FALSE),
  ('ark', 'exact', 'doubao-seed-tts', 'premark_input_shape', FALSE),
  ('zhipu', 'exact', 'cogview', 'premark_input_shape', FALSE),
  ('zhipu', 'exact', 'cogvideo', 'premark_input_shape', FALSE)
"""


async def close_pool() -> None:
    """Close the pool. Called on app shutdown."""
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None
        logger.info("database pool closed")


def pool() -> asyncpg.Pool:
    if _pool is None:
        raise RuntimeError("database pool not initialized — call init_pool() first")
    return _pool


async def fetch(sql: str, *args: Any) -> list[asyncpg.Record]:
    """Execute a query and return all rows."""
    async with pool().acquire() as conn:
        return await conn.fetch(sql, *args)


async def fetchrow(sql: str, *args: Any) -> asyncpg.Record | None:
    """Execute a query and return the first row or None."""
    async with pool().acquire() as conn:
        return await conn.fetchrow(sql, *args)


async def execute(sql: str, *args: Any) -> str:
    """Execute a statement and return the status tag."""
    async with pool().acquire() as conn:
        return await conn.execute(sql, *args)


@asynccontextmanager
async def transaction():
    """Acquire a connection with a transaction context."""
    async with pool().acquire() as conn, conn.transaction():
        yield conn


async def fetchval(sql: str, *args: Any) -> Any:
    """Execute and return a single value (first column of first row)."""
    async with pool().acquire() as conn:
        return await conn.fetchval(sql, *args)


async def notify(channel: str, payload: str = "") -> None:
    """Send a Postgres NOTIFY on the given channel.

    NOTIFY itself has no parameter binding, so channel/payload are passed
    to pg_notify($1, $2) instead of being interpolated into SQL text.
    """
    async with pool().acquire() as conn:
        await conn.execute("SELECT pg_notify($1, $2)", channel, payload)


async def bump_generation(conn: asyncpg.Connection | None = None) -> int:
    """Atomically bump config generation and NOTIFY, in one transaction.

    If a connection is provided, uses it (already inside a transaction).
    Otherwise acquires a new connection with its own transaction.
    """
    if conn is not None:
        gen = await conn.fetchval(
            "UPDATE config_meta SET config_generation = config_generation + 1 "
            "WHERE id = 1 RETURNING config_generation"
        )
        await conn.execute("NOTIFY janus_config")
        return gen
    async with transaction() as tx:
        gen = await tx.fetchval(
            "UPDATE config_meta SET config_generation = config_generation + 1 "
            "WHERE id = 1 RETURNING config_generation"
        )
        await tx.execute("NOTIFY janus_config")
        return gen


async def current_generation() -> int:
    """Read the current config generation without bumping."""
    val = await fetchval("SELECT config_generation FROM config_meta WHERE id = 1")
    return val or 0
