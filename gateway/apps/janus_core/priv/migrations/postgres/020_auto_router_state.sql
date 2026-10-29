-- Auto-router reorder loop singleton state (reorder spec D26,
-- migration 020): ONE row, PK id=1, seeded here. Dashboard-owned
-- runtime state — NOT distributed settings (never rides the
-- generation bump). last_manual_edit_at is the D30/D35 anchor (the
-- human PUT /auto-router timestamp; the system entrypoint never sets
-- it) — an additive column over D26's core list, living here because
-- the audit table is append-only.
CREATE TABLE IF NOT EXISTS auto_router_state (
    id SMALLINT PRIMARY KEY CHECK (id = 1),
    pending_tiers JSONB,
    pending_since TIMESTAMPTZ,
    explore_cooldown JSONB,
    last_auto_write_at TIMESTAMPTZ,
    lease_owner TEXT,
    lease_until TIMESTAMPTZ,
    consecutive_rejects INTEGER NOT NULL DEFAULT 0,
    reject_quarantined_until TIMESTAMPTZ,
    reject_marker JSONB,
    last_manual_edit_at TIMESTAMPTZ
);

INSERT INTO auto_router_state (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
