-- Per-listing capability metadata captured from the provider's /models
-- payload, as a JSON TEXT column. NULL when no metadata available.
ALTER TABLE provider_models
    ADD COLUMN meta TEXT;
