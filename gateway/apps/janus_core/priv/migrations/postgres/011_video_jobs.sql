-- Modality spec M3: video job lifecycle table (v1 forward-compat; the
-- full persistence flow lands with the leader-bootstrap follow-up).
CREATE TABLE IF NOT EXISTS video_jobs (
    jvid TEXT PRIMARY KEY,
    provider_id BIGINT,
    upstream_id TEXT,
    status TEXT,
    created_ts BIGINT
);
