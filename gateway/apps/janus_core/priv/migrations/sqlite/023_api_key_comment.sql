-- Operator-facing free-text note on agent keys (owner / purpose).
-- Dashboard metadata only — not loaded into catalog ETS.
ALTER TABLE api_keys ADD COLUMN comment TEXT;
