-- Prefix is the auth hot-path index. Duplicate prefixes previously
-- overwrote each other in catalog ETS. Keep the lowest id, then unique.
DELETE FROM api_key_models
WHERE api_key_id IN (
    SELECT a.id FROM api_keys a
    JOIN api_keys b ON a.prefix = b.prefix AND a.id > b.id
);
DELETE FROM api_keys a USING api_keys b
WHERE a.prefix = b.prefix AND a.id > b.id;
CREATE UNIQUE INDEX IF NOT EXISTS api_keys_prefix_uidx ON api_keys (prefix);
