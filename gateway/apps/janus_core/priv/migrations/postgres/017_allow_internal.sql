-- v2.2 Part C (spec 2026-10-11-v2.2-quota-egress-security.md): the
-- dashboard's base_url SSRF write-gate persists an audited
-- allow_internal escape flag on provider rows. Dashboard policy only:
-- the gateway catalog reads NAMED columns (janus_db_conn do_fetch_catalog)
-- and never selects this column; prod keeps it 0/NULL (deploy smoke asserts).
ALTER TABLE providers ADD COLUMN IF NOT EXISTS allow_internal SMALLINT NOT NULL DEFAULT 0;
