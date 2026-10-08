-- Phase 2 Slice Q: per-agent-key quotas (NULL = unlimited).
ALTER TABLE api_keys ADD COLUMN rpm_limit INTEGER;
ALTER TABLE api_keys ADD COLUMN tpm_limit INTEGER;
ALTER TABLE api_keys ADD COLUMN daily_token_limit INTEGER;
