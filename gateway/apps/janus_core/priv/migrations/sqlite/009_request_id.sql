-- Client-facing request id (x-request-id) for log/usage correlation.
-- Nullable: rows predating 009 and non-proxy writers have none.
ALTER TABLE usage_events ADD COLUMN request_id TEXT;

CREATE INDEX IF NOT EXISTS usage_events_request_id_idx ON usage_events (request_id);
