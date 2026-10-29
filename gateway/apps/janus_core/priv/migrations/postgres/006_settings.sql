-- Management-plane settings (dashboard-editable, hot-reloaded by the
-- gateways through the catalog generation). Values are JSON objects.
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value JSONB NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
