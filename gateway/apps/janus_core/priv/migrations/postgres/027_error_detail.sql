-- Failure observability (2026-10-27): the terminal usage row carries
-- the reply's error message (upstream's own sentence, clamped to 512
-- bytes at the writer) so the dashboard Failures page can show WHY a
-- request failed instead of a bare status + code. Additive only —
-- rolling deploy safe (old writers leave it NULL).
ALTER TABLE usage_events ADD COLUMN IF NOT EXISTS error_detail TEXT;
