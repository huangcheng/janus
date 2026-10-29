-- Align existing BOOLEAN enabled columns with SQLite-shaped app SQL
-- (`enabled = 1` / `VALUES (..., 1)`). Safe on already-SMALLINT columns:
-- `enabled::int` works for both boolean and smallint.
ALTER TABLE api_keys
    ALTER COLUMN enabled DROP DEFAULT,
    ALTER COLUMN enabled TYPE SMALLINT USING (enabled::int),
    ALTER COLUMN enabled SET DEFAULT 1;
ALTER TABLE api_keys DROP CONSTRAINT IF EXISTS api_keys_enabled_check;
ALTER TABLE api_keys ADD CONSTRAINT api_keys_enabled_check CHECK (enabled IN (0, 1));

ALTER TABLE providers
    ALTER COLUMN enabled DROP DEFAULT,
    ALTER COLUMN enabled TYPE SMALLINT USING (enabled::int),
    ALTER COLUMN enabled SET DEFAULT 1;
ALTER TABLE providers DROP CONSTRAINT IF EXISTS providers_enabled_check;
ALTER TABLE providers ADD CONSTRAINT providers_enabled_check CHECK (enabled IN (0, 1));

ALTER TABLE provider_keys
    ALTER COLUMN enabled DROP DEFAULT,
    ALTER COLUMN enabled TYPE SMALLINT USING (enabled::int),
    ALTER COLUMN enabled SET DEFAULT 1;
ALTER TABLE provider_keys DROP CONSTRAINT IF EXISTS provider_keys_enabled_check;
ALTER TABLE provider_keys ADD CONSTRAINT provider_keys_enabled_check CHECK (enabled IN (0, 1));

ALTER TABLE models
    ALTER COLUMN enabled DROP DEFAULT,
    ALTER COLUMN enabled TYPE SMALLINT USING (enabled::int),
    ALTER COLUMN enabled SET DEFAULT 1;
ALTER TABLE models DROP CONSTRAINT IF EXISTS models_enabled_check;
ALTER TABLE models ADD CONSTRAINT models_enabled_check CHECK (enabled IN (0, 1));

ALTER TABLE model_routes
    ALTER COLUMN enabled DROP DEFAULT,
    ALTER COLUMN enabled TYPE SMALLINT USING (enabled::int),
    ALTER COLUMN enabled SET DEFAULT 1;
ALTER TABLE model_routes DROP CONSTRAINT IF EXISTS model_routes_enabled_check;
ALTER TABLE model_routes ADD CONSTRAINT model_routes_enabled_check CHECK (enabled IN (0, 1));
