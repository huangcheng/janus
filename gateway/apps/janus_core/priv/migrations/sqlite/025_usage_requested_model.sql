-- Resolution accounting (2026-10-19): see the postgres twin.
ALTER TABLE usage_events ADD COLUMN requested_model TEXT;
