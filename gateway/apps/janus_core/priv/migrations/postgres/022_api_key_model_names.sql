-- Agent-key grants switch from models.id FK to free-text model_name.
-- Lets restricted keys grant unbound provider listing names, drops
-- CASCADE-unrestrict when a models row is deleted. janus-auto is never
-- grantable (stripped on migrate, dashboard/API reject it on write).
--
-- Old FK was ON DELETE CASCADE, so dangling model_id rows do not exist on
-- a healthy DB, INNER JOIN cannot silently escalate a key to unrestricted
-- via missing models. A key whose ONLY grant was literally 'janus-auto'
-- becomes unrestricted after strip — intentional (virtual name is
-- unrestricted-only). DISTINCT guards composite-PK collisions.
--
-- Rolling deploy: ship gateway + dashboard in the same window as this
-- migration, pre-022 beams SELECT model_id and will fail catalog reload
-- until restarted onto post-022 code.
CREATE TABLE api_key_models_new (
    api_key_id BIGINT NOT NULL REFERENCES api_keys (id) ON DELETE CASCADE,
    model_name TEXT NOT NULL,
    PRIMARY KEY (api_key_id, model_name),
    CONSTRAINT api_key_models_name_nonempty CHECK (char_length(btrim(model_name)) > 0)
);

INSERT INTO api_key_models_new (api_key_id, model_name)
SELECT DISTINCT akm.api_key_id, m.name
FROM api_key_models akm
JOIN models m ON m.id = akm.model_id
WHERE m.name IS NOT NULL
  AND btrim(m.name) <> ''
  AND m.name <> 'janus-auto';

DROP TABLE api_key_models;
ALTER TABLE api_key_models_new RENAME TO api_key_models;
-- Serves janus_auto warn_restricted_keys lookup by model_name alone.
CREATE INDEX IF NOT EXISTS api_key_models_name_idx ON api_key_models (model_name);
