-- Resolution accounting (2026-10-19): the client's ORIGINAL model name
-- rides every usage row as requested_model. janus-auto requests record
-- the virtual name here while model_id stays the RESOLVED concrete
-- model, so spend per resolution (virtual -> real) is a plain GROUP BY.
-- NULL on rows written before this migration and on faces that never
-- see a model name (modality probes etc.).
ALTER TABLE usage_events ADD COLUMN IF NOT EXISTS requested_model TEXT;
