-- Observability (OpenTelemetry alignment, P0): the cache WRITE dimension
-- and span identity on the usage ledger.
--
-- cache_read_input_tokens existed since migration 012 but was NEVER
-- written: the parser summed read+write into `prompt` and discarded both.
-- cache_write_input_tokens is the missing twin, so a cache fill stops
-- being invisible while a cache hit is reported.
--
-- span_id/parent_span_id are nullable and appear only once spans exist
-- (P1). They let the ledger join to the trace instead of reconstructing
-- a timeline from `trace_id` + `attempt`.
ALTER TABLE usage_events ADD COLUMN cache_write_input_tokens BIGINT;
ALTER TABLE usage_events ADD COLUMN span_id TEXT;
ALTER TABLE usage_events ADD COLUMN parent_span_id TEXT;

CREATE INDEX IF NOT EXISTS usage_events_span_id_idx ON usage_events (span_id);
