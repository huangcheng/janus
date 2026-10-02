-- Janus initial schema (Postgres)
-- Tables per docs/SCHEMA_ETS_CONTRACT.md

CREATE TABLE IF NOT EXISTS schema_migrations (
    version TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config_meta (
    id SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    config_generation BIGINT NOT NULL DEFAULT 0
);

INSERT INTO config_meta (id, config_generation)
VALUES (1, 0)
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS api_keys (
    id BIGSERIAL PRIMARY KEY,
    prefix TEXT NOT NULL,
    key_hash BYTEA NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS api_keys_key_hash_uidx ON api_keys (key_hash);
CREATE INDEX IF NOT EXISTS api_keys_prefix_idx ON api_keys (prefix);

CREATE TABLE IF NOT EXISTS models (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE UNIQUE INDEX IF NOT EXISTS models_name_uidx ON models (name);

CREATE TABLE IF NOT EXISTS api_key_models (
    api_key_id BIGINT NOT NULL REFERENCES api_keys (id) ON DELETE CASCADE,
    model_id BIGINT NOT NULL REFERENCES models (id) ON DELETE CASCADE,
    PRIMARY KEY (api_key_id, model_id)
);

CREATE TABLE IF NOT EXISTS providers (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    base_url TEXT NOT NULL,
    protocol TEXT NOT NULL
        CHECK (protocol IN ('openai_chat', 'anthropic_messages', 'openai_responses')),
    enabled BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE UNIQUE INDEX IF NOT EXISTS providers_name_uidx ON providers (name);

CREATE TABLE IF NOT EXISTS provider_keys (
    id BIGSERIAL PRIMARY KEY,
    provider_id BIGINT NOT NULL REFERENCES providers (id) ON DELETE CASCADE,
    secret_ciphertext BYTEA NOT NULL,
    key_id TEXT NOT NULL,
    weight INTEGER NOT NULL DEFAULT 1 CHECK (weight > 0),
    enabled BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX IF NOT EXISTS provider_keys_provider_idx ON provider_keys (provider_id);

CREATE TABLE IF NOT EXISTS model_routes (
    model_id BIGINT NOT NULL REFERENCES models (id) ON DELETE CASCADE,
    provider_id BIGINT NOT NULL REFERENCES providers (id) ON DELETE CASCADE,
    upstream_model_id TEXT,
    weight INTEGER NOT NULL DEFAULT 1 CHECK (weight > 0),
    priority INTEGER NOT NULL DEFAULT 0,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (model_id, provider_id)
);
