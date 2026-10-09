-- Master-worker dispatch: optional provider affinity hints.
ALTER TABLE providers ADD COLUMN region_tag TEXT;
ALTER TABLE providers ADD COLUMN affinity_node TEXT;
