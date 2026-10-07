-- Translation spec 1.8b: anthropic cache-read token accounting.
ALTER TABLE usage_events ADD COLUMN IF NOT EXISTS cache_read_input_tokens BIGINT;
