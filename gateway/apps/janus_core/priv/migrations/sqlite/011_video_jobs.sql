-- Modality spec M3 — see postgres twin.
CREATE TABLE IF NOT EXISTS video_jobs (
    jvid TEXT PRIMARY KEY,
    provider_id INTEGER,
    upstream_id TEXT,
    status TEXT,
    created_ts BIGINT
);
