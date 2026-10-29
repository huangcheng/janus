-- Janus initial schema (SQLite)
-- Single-node only. listen/NOTIFY is a no-op (use poll / local reload).
-- Tables per docs/SCHEMA_ETS_CONTRACT.md

CREATE TABLE IF NOT EXISTS schema_migrations (
    version TEXT PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE IF NOT EXISTS config_meta (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    config_generation INTEGER NOT NULL DEFAULT 0
);

INSERT OR IGNORE INTO config_meta (id, config_generation) VALUES (1, 0);

CREATE TABLE IF NOT EXISTS api_keys (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    prefix TEXT NOT NULL,
    key_hash BLOB NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE UNIQUE INDEX IF NOT EXISTS api_keys_key_hash_uidx ON api_keys (key_hash);
CREATE INDEX IF NOT EXISTS api_keys_prefix_idx ON api_keys (prefix);

CREATE TABLE IF NOT EXISTS models (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1))
);

CREATE UNIQUE INDEX IF NOT EXISTS models_name_uidx ON models (name);

CREATE TABLE IF NOT EXISTS api_key_models (
    api_key_id INTEGER NOT NULL REFERENCES api_keys (id) ON DELETE CASCADE,
    model_id INTEGER NOT NULL REFERENCES models (id) ON DELETE CASCADE,
    PRIMARY KEY (api_key_id, model_id)
);

CREATE TABLE IF NOT EXISTS providers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    base_url TEXT NOT NULL,
    protocol TEXT NOT NULL
        CHECK (protocol IN ('openai_chat', 'anthropic_messages', 'openai_responses')),
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1))
);

CREATE UNIQUE INDEX IF NOT EXISTS providers_name_uidx ON providers (name);

CREATE TABLE IF NOT EXISTS provider_keys (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider_id INTEGER NOT NULL REFERENCES providers (id) ON DELETE CASCADE,
    secret_ciphertext BLOB NOT NULL,
    key_id TEXT NOT NULL,
    weight INTEGER NOT NULL DEFAULT 1 CHECK (weight > 0),
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1))
);

CREATE INDEX IF NOT EXISTS provider_keys_provider_idx ON provider_keys (provider_id);

CREATE TABLE IF NOT EXISTS model_routes (
    model_id INTEGER NOT NULL REFERENCES models (id) ON DELETE CASCADE,
    provider_id INTEGER NOT NULL REFERENCES providers (id) ON DELETE CASCADE,
    upstream_model_id TEXT,
    weight INTEGER NOT NULL DEFAULT 1 CHECK (weight > 0),
    priority INTEGER NOT NULL DEFAULT 0,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    PRIMARY KEY (model_id, provider_id)
);
