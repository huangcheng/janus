-- Files API (2026-10-26): gateway-owned standard /v1/files so agent
-- harnesses (dsh etc.) can attach files to ANY chat-family upstream
-- without provider-dialect file stores. METADATA ONLY — bytes live in
-- a janus_files_store backend (v1: content-addressed filesystem;
-- SeaweedFS/S3 later behind the same behavior). Rows are small by
-- design; quota accounting reads size_bytes, never the blobs.
CREATE TABLE IF NOT EXISTS files (
    id TEXT PRIMARY KEY,
    agent_key_id BIGINT NOT NULL REFERENCES api_keys (id) ON DELETE CASCADE,
    filename TEXT NOT NULL,
    content_type TEXT NOT NULL,
    purpose TEXT NOT NULL DEFAULT 'file-extract',
    sha256 TEXT NOT NULL,
    size_bytes BIGINT NOT NULL,
    created_at BIGINT NOT NULL,
    store TEXT NOT NULL DEFAULT 'fs'
);
CREATE INDEX IF NOT EXISTS files_agent_key_idx ON files (agent_key_id);
CREATE INDEX IF NOT EXISTS files_sha_idx ON files (sha256);
