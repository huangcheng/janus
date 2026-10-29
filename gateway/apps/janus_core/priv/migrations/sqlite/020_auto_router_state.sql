-- Auto-router reorder loop singleton state — sqlite twin (see the
-- postgres migration 020 for the spec reference: JSONB -> TEXT,
-- TIMESTAMPTZ -> TEXT, SMALLINT -> INTEGER).
CREATE TABLE IF NOT EXISTS auto_router_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    pending_tiers TEXT,
    pending_since TEXT,
    explore_cooldown TEXT,
    last_auto_write_at TEXT,
    lease_owner TEXT,
    lease_until TEXT,
    consecutive_rejects INTEGER NOT NULL DEFAULT 0,
    reject_quarantined_until TEXT,
    reject_marker TEXT,
    last_manual_edit_at TEXT
);

INSERT INTO auto_router_state (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
