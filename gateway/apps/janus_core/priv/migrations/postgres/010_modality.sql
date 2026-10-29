-- Modality gateway (spec M1.0b/M1.1): listings gain a modality tag;
-- usage rows gain modality/units/outcome. Additive only — rolling
-- deploy safe (old code writes defaults). NOTE: the lifecycle status
-- column is named `outcome` here, not `status` as the spec draft
-- said — usage_events.status is already the HTTP status INTEGER.
ALTER TABLE provider_models ADD COLUMN IF NOT EXISTS modality TEXT NOT NULL DEFAULT 'chat';
ALTER TABLE usage_events ADD COLUMN IF NOT EXISTS modality TEXT;
ALTER TABLE usage_events ADD COLUMN IF NOT EXISTS units NUMERIC;
ALTER TABLE usage_events ADD COLUMN IF NOT EXISTS outcome TEXT;
