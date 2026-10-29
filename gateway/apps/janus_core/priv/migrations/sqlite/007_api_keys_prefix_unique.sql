-- Prefix is the auth hot-path index. Duplicate prefixes previously
-- overwrote each other in catalog ETS. Keep the lowest id, then unique.
DELETE FROM api_key_models
WHERE api_key_id NOT IN (
    SELECT id FROM (
        SELECT MIN(id) AS id FROM api_keys GROUP BY prefix
    )
);
DELETE FROM api_keys
WHERE id NOT IN (
    SELECT id FROM (
        SELECT MIN(id) AS id FROM api_keys GROUP BY prefix
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS api_keys_prefix_uidx ON api_keys (prefix);
