-- Observability depth: per-attempt failover classification + W3C trace id.
-- Both nullable: rows predating 021 and non-proxy writers have none.
-- The runner's schema_migrations tracking makes these non-idempotent ALTERs safe
-- (verified via the 020→021 boot in the gate). Do not add IF NOT EXISTS blindly.
ALTER TABLE usage_events ADD COLUMN failover_reason TEXT;
ALTER TABLE usage_events ADD COLUMN trace_id TEXT;
CREATE INDEX IF NOT EXISTS usage_events_trace_id_idx ON usage_events (trace_id);
