-- Entitlement-failover prerequisites (spec Part E.1/E.2): per-attempt
-- usage evidence. attempt is 1-based; request_ref groups the attempts
-- of one client request (UUID); is_terminal is true on exactly the
-- final row of a request. Legacy rows backfill attempt=1,
-- is_terminal=true. error_code carries the provider-native error code
-- parsed from the error body (enables traffic-based deny learning).
ALTER TABLE usage_events ADD COLUMN IF NOT EXISTS error_code TEXT;
ALTER TABLE usage_events ADD COLUMN IF NOT EXISTS attempt SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE usage_events ADD COLUMN IF NOT EXISTS request_ref TEXT;
ALTER TABLE usage_events ADD COLUMN IF NOT EXISTS is_terminal BOOLEAN NOT NULL DEFAULT TRUE;
CREATE INDEX IF NOT EXISTS usage_events_request_ref_idx ON usage_events (request_ref);
