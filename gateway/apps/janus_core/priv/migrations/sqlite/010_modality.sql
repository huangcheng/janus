-- Modality gateway (spec M1.0b/M1.1) — see postgres twin.
ALTER TABLE provider_models ADD COLUMN modality TEXT NOT NULL DEFAULT 'chat';
ALTER TABLE usage_events ADD COLUMN modality TEXT;
ALTER TABLE usage_events ADD COLUMN units NUMERIC;
ALTER TABLE usage_events ADD COLUMN outcome TEXT;
