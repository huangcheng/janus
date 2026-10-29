-- Entitlement-failover prerequisites (spec Part E.1/E.2), SQLite
-- dialect. Plain ALTERs (schema_migrations guards re-runs).
ALTER TABLE usage_events ADD COLUMN error_code TEXT;
ALTER TABLE usage_events ADD COLUMN attempt SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE usage_events ADD COLUMN request_ref TEXT;
ALTER TABLE usage_events ADD COLUMN is_terminal BOOLEAN NOT NULL DEFAULT 1;
CREATE INDEX IF NOT EXISTS usage_events_request_ref_idx ON usage_events (request_ref);
