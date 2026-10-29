-- Auto-router tier reorder audit trail — sqlite twin (see the
-- postgres migration 019 for the spec reference: JSONB -> TEXT,
-- TIMESTAMPTZ -> TEXT, BIGSERIAL -> INTEGER AUTOINCREMENT).
CREATE TABLE IF NOT EXISTS auto_router_audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    at TEXT NOT NULL DEFAULT (STRFTIME('%Y-%m-%dT%H:%M:%fZ', 'now')),
    actor TEXT NOT NULL CHECK (actor IN ('system', 'human')),
    before_tiers TEXT,
    after_tiers TEXT,
    scores TEXT,
    kind TEXT NOT NULL CHECK (kind IN ('commit', 'restore', 'reject', 'dry_run'))
);

CREATE INDEX IF NOT EXISTS auto_router_audit_kind_id_idx
    ON auto_router_audit (kind, id DESC);
