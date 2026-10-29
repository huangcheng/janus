-- Provider inventory: models advertised by an upstream, not agent-facing names.
CREATE TABLE IF NOT EXISTS provider_models (
    id BIGSERIAL PRIMARY KEY,
    provider_id BIGINT NOT NULL REFERENCES providers (id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    enabled SMALLINT NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    UNIQUE (provider_id, name)
);

CREATE INDEX IF NOT EXISTS provider_models_provider_id_idx ON provider_models (provider_id);
