-- Master-worker dispatch: optional provider affinity hints.
ALTER TABLE providers ADD COLUMN IF NOT EXISTS region_tag TEXT;
ALTER TABLE providers ADD COLUMN IF NOT EXISTS affinity_node TEXT;
