-- Auto-router existence switch (auto-router-prompt-only spec, release B).
-- See the postgres twin for the full rationale. SQLite stores settings as
-- TEXT, so the condition is the same predicate expressed over json_extract
-- (json_valid guards rows written by an older writer that predates JSON).
UPDATE settings
SET value = json_set(value, '$.enabled', json('true'))
WHERE key = 'auto_router'
  AND json_valid(value)
  AND json_type(value) = 'object'
  AND json_extract(value, '$.enabled') IS NULL
  AND (
      coalesce(json_array_length(json_extract(value, '$.tiers.fast')), 0)
    + coalesce(json_array_length(json_extract(value, '$.tiers.big')), 0)
    + coalesce(json_array_length(json_extract(value, '$.tiers.flagship')), 0)
  ) > 0;
