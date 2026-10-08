-- Phase 2 Slice Q: per-agent-key quotas (NULL = unlimited).
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS rpm_limit INTEGER;
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS tpm_limit INTEGER;
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS daily_token_limit BIGINT;
