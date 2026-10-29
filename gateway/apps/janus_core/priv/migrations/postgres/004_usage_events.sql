-- Data-plane usage events: one row per proxied agent request.
-- Token columns are NULL when the upstream did not report usage
-- (distinguishable from a real zero).
CREATE TABLE IF NOT EXISTS usage_events (
    id BIGSERIAL PRIMARY KEY,
    ts BIGINT NOT NULL,
    agent_key_id BIGINT REFERENCES api_keys (id) ON DELETE SET NULL,
    model_id BIGINT REFERENCES models (id) ON DELETE SET NULL,
    provider_id BIGINT REFERENCES providers (id) ON DELETE SET NULL,
    provider_key_id BIGINT REFERENCES provider_keys (id) ON DELETE SET NULL,
    protocol TEXT NOT NULL,
    stream SMALLINT NOT NULL DEFAULT 0 CHECK (stream IN (0, 1)),
    status INTEGER NOT NULL,
    prompt_tokens BIGINT,
    completion_tokens BIGINT,
    latency_ms INTEGER
);

CREATE INDEX IF NOT EXISTS usage_events_ts_idx ON usage_events (ts);
CREATE INDEX IF NOT EXISTS usage_events_key_ts_idx ON usage_events (agent_key_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_model_ts_idx ON usage_events (model_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_provider_ts_idx ON usage_events (provider_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_pkey_ts_idx ON usage_events (provider_key_id, ts);
CREATE INDEX IF NOT EXISTS usage_events_stream_latency_idx ON usage_events (stream, latency_ms);
