-- Files API (2026-10-26): see the postgres twin. sqlite has no
-- REFERENCES-enforced BIGINT difference here — same shape.
CREATE TABLE IF NOT EXISTS files (
    id TEXT PRIMARY KEY,
    agent_key_id INTEGER NOT NULL,
    filename TEXT NOT NULL,
    content_type TEXT NOT NULL,
    purpose TEXT NOT NULL DEFAULT 'file-extract',
    sha256 TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    store TEXT NOT NULL DEFAULT 'fs'
);
CREATE INDEX IF NOT EXISTS files_agent_key_idx ON files (agent_key_id);
CREATE INDEX IF NOT EXISTS files_sha_idx ON files (sha256);
