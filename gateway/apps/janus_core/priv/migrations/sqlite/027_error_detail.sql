-- Failure observability (2026-10-27): see the postgres twin.
ALTER TABLE usage_events ADD COLUMN error_detail TEXT;
