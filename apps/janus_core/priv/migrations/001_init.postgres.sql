-- Janus initial schema (Postgres)
-- Multi-node: share this database; do not rely on Erlang clustering for catalog sync.
-- api_keys.key_hash: opaque digest (HMAC+pepper hashing owned elsewhere).

CREATE TABLE IF NOT EXISTS schema_migrations (
    version TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config_meta (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    config_generation BIGINT NOT NULL DEFAULT 1
);

INSERT INTO config_meta (id, config_generation)
VALUES (1, 1)
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS api_keys (
    id BIGSERIAL PRIMARY KEY,
    prefix TEXT NOT NULL,
    key_hash BYTEA NOT NULL,
    -- INTEGER 0/1 (not BOOLEAN): app SQL is SQLite-shaped (`enabled = 1`).
    enabled SMALLINT NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS api_keys_key_hash_uidx ON api_keys (key_hash);
CREATE INDEX IF NOT EXISTS api_keys_prefix_idx ON api_keys (prefix);

CREATE TABLE IF NOT EXISTS providers (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    base_url TEXT NOT NULL,
    protocol TEXT NOT NULL
        CHECK (protocol IN ('openai_chat', 'anthropic_messages', 'openai_responses')),
    enabled SMALLINT NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1))
);

CREATE TABLE IF NOT EXISTS provider_keys (
    id BIGSERIAL PRIMARY KEY,
    provider_id BIGINT NOT NULL REFERENCES providers (id) ON DELETE CASCADE,
    secret_ciphertext BYTEA NOT NULL,
    key_id TEXT NOT NULL,
    weight INTEGER NOT NULL DEFAULT 1 CHECK (weight >= 0),
    enabled SMALLINT NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1))
);

CREATE INDEX IF NOT EXISTS provider_keys_provider_id_idx ON provider_keys (provider_id);

CREATE TABLE IF NOT EXISTS models (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    enabled SMALLINT NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1))
);

CREATE TABLE IF NOT EXISTS api_key_models (
    api_key_id BIGINT NOT NULL REFERENCES api_keys (id) ON DELETE CASCADE,
    model_id BIGINT NOT NULL REFERENCES models (id) ON DELETE CASCADE,
    PRIMARY KEY (api_key_id, model_id)
);

CREATE TABLE IF NOT EXISTS model_routes (
    id BIGSERIAL PRIMARY KEY,
    model_id BIGINT NOT NULL REFERENCES models (id) ON DELETE CASCADE,
    provider_id BIGINT NOT NULL REFERENCES providers (id) ON DELETE CASCADE,
    upstream_model_id TEXT,
    weight INTEGER NOT NULL DEFAULT 1 CHECK (weight >= 0),
    priority INTEGER NOT NULL DEFAULT 0,
    enabled SMALLINT NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1))
);

CREATE INDEX IF NOT EXISTS model_routes_model_id_idx ON model_routes (model_id);
CREATE INDEX IF NOT EXISTS model_routes_provider_id_idx ON model_routes (provider_id);
