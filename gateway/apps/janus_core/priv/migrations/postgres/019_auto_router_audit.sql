-- Auto-router tier reorder audit trail (reorder spec
-- docs/superpowers/specs/2026-10-11-geo-affinity-and-auto-tier-reorder-design.md
-- D11, migration 019): one row per tiers WRITE through either
-- entrypoint (human PUT /auto-router or the dashboard reorder loop's
-- system_reorder_commit), plus kind='restore' compensating writes and
-- kind='dry_run' compute-only rows (D32: enabled AND dry_run computes
-- + audits without the CAS — the extra enum value beyond D11's
-- ('commit'|'restore'|'reject') keeps "latest kind=commit" in the D35
-- restore source unambiguous; 'reject' is reserved for the gateway's
-- master re-validation reject trail). No secrets / egress_ip ever
-- land here. `id` is the monotonic order (at alone can tie).
CREATE TABLE IF NOT EXISTS auto_router_audit (
    id BIGSERIAL PRIMARY KEY,
    at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    actor TEXT NOT NULL CHECK (actor IN ('system', 'human')),
    before_tiers JSONB,
    after_tiers JSONB,
    scores JSONB,
    kind TEXT NOT NULL CHECK (kind IN ('commit', 'restore', 'reject', 'dry_run'))
);

CREATE INDEX IF NOT EXISTS auto_router_audit_kind_id_idx
    ON auto_router_audit (kind, id DESC);
