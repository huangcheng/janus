-- Per-listing capability metadata captured from the provider's /models
-- payload (context window, output cap, reasoning/vision flags). JSONB;
-- NULL when the provider's catalog carries no metadata.
ALTER TABLE provider_models
    ADD COLUMN IF NOT EXISTS meta JSONB;
