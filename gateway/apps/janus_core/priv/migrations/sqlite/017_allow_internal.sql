-- v2.2 Part C: dashboard-side allow_internal flag (see the postgres
-- twin). Idempotency here comes from the schema_migrations version
-- table, not IF NOT EXISTS (sqlite has no ALTER-guard).
ALTER TABLE providers ADD COLUMN allow_internal SMALLINT NOT NULL DEFAULT 0;
