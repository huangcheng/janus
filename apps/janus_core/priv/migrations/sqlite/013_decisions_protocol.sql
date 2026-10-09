-- OpenAI Decisions face (spec 2026-10-07, D2/D6), SQLite dialect.
-- SQLite cannot ALTER a CHECK in place, so `providers` is rebuilt with
-- the extended protocol enum. FK enforcement is ON on the migration
-- connection and DROP TABLE performs an implicit DELETE that would
-- fire CASCADE/SET NULL actions on every referencing table — so the
-- rebuild is copy-first and drops children in dependency order
-- (usage_events -> provider_keys -> model_routes -> provider_models
-- -> providers), never dropping a table another live table still
-- references. The migration runner wraps this script in its own
-- BEGIN IMMEDIATE - no explicit transaction statements here (never put semicolons in migration comments: the runner splits statements on them).

CREATE TABLE providers_013 (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    base_url TEXT NOT NULL,
    protocol TEXT NOT NULL
        CHECK (protocol IN ('openai_chat', 'anthropic_messages', 'openai_responses', 'openai_decisions')),
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1))
);

CREATE TABLE provider_keys_013 (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider_id INTEGER NOT NULL REFERENCES providers_013 (id) ON DELETE CASCADE,
    secret_ciphertext BLOB NOT NULL,
    key_id TEXT NOT NULL,
    weight INTEGER NOT NULL DEFAULT 1 CHECK (weight > 0),
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1))
);

CREATE TABLE model_routes_013 (
    model_id INTEGER NOT NULL REFERENCES models (id) ON DELETE CASCADE,
    provider_id INTEGER NOT NULL REFERENCES providers_013 (id) ON DELETE CASCADE,
    upstream_model_id TEXT,
    weight INTEGER NOT NULL DEFAULT 1 CHECK (weight > 0),
    priority INTEGER NOT NULL DEFAULT 0,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    PRIMARY KEY (model_id, provider_id)
);

CREATE TABLE provider_models_013 (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider_id INTEGER NOT NULL REFERENCES providers_013 (id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    meta TEXT,
    modality TEXT NOT NULL DEFAULT 'chat',
    UNIQUE (provider_id, name)
);

CREATE TABLE usage_events_013 (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    agent_key_id INTEGER REFERENCES api_keys (id) ON DELETE SET NULL,
    model_id INTEGER REFERENCES models (id) ON DELETE SET NULL,
    provider_id INTEGER REFERENCES providers_013 (id) ON DELETE SET NULL,
    provider_key_id INTEGER REFERENCES provider_keys_013 (id) ON DELETE SET NULL,
    protocol TEXT NOT NULL,
    stream INTEGER NOT NULL DEFAULT 0 CHECK (stream IN (0, 1)),
    status INTEGER NOT NULL,
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    latency_ms INTEGER,
    error_code TEXT,
    attempt SMALLINT NOT NULL DEFAULT 1,
    request_ref TEXT,
    is_terminal BOOLEAN NOT NULL DEFAULT 1,
    request_id TEXT,
    cache_read_input_tokens INTEGER,
    modality TEXT,
    units REAL,
    outcome TEXT
);

INSERT INTO providers_013 (id, name, base_url, protocol, enabled)
    SELECT id, name, base_url, protocol, enabled FROM providers;

INSERT INTO provider_keys_013 (id, provider_id, secret_ciphertext, key_id, weight, enabled)
    SELECT id, provider_id, secret_ciphertext, key_id, weight, enabled FROM provider_keys;

INSERT INTO model_routes_013 (model_id, provider_id, upstream_model_id, weight, priority, enabled)
    SELECT model_id, provider_id, upstream_model_id, weight, priority, enabled FROM model_routes;

INSERT INTO provider_models_013 (id, provider_id, name, enabled, meta, modality)
    SELECT id, provider_id, name, enabled, meta, modality FROM provider_models;

INSERT INTO usage_events_013 (
    id, ts, agent_key_id, model_id, provider_id, provider_key_id, protocol,
    stream, status, prompt_tokens, completion_tokens, latency_ms, error_code,
    attempt, request_ref, is_terminal, request_id, cache_read_input_tokens,
    modality, units, outcome
)
SELECT
    id, ts, agent_key_id, model_id, provider_id, provider_key_id, protocol,
    stream, status, prompt_tokens, completion_tokens, latency_ms, error_code,
    attempt, request_ref, is_terminal, request_id, cache_read_input_tokens,
    modality, units, outcome
FROM usage_events;

DROP TABLE usage_events;
DROP TABLE provider_keys;
DROP TABLE model_routes;
DROP TABLE provider_models;
DROP TABLE providers;

ALTER TABLE providers_013 RENAME TO providers;
ALTER TABLE provider_keys_013 RENAME TO provider_keys;
ALTER TABLE model_routes_013 RENAME TO model_routes;
ALTER TABLE provider_models_013 RENAME TO provider_models;
ALTER TABLE usage_events_013 RENAME TO usage_events;

CREATE UNIQUE INDEX IF NOT EXISTS providers_name_uidx ON providers (name);
CREATE INDEX IF NOT EXISTS provider_keys_provider_idx ON provider_keys (provider_id);
CREATE INDEX IF NOT EXISTS provider_models_provider_id_idx ON provider_models (provider_id);
CREATE INDEX IF NOT EXISTS usage_events_ts_idx ON usage_events (ts);
CREATE INDEX IF NOT EXISTS usage_events_key_ts_idx ON usage_events (agent_key_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_model_ts_idx ON usage_events (model_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_provider_ts_idx ON usage_events (provider_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_pkey_ts_idx ON usage_events (provider_key_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_stream_latency_idx ON usage_events (stream, latency_ms);
CREATE INDEX IF NOT EXISTS usage_events_request_ref_idx ON usage_events (request_ref);
CREATE INDEX IF NOT EXISTS usage_events_request_id_idx ON usage_events (request_id);
CREATE INDEX IF NOT EXISTS usage_events_ts_id_idx ON usage_events (ts, id);
