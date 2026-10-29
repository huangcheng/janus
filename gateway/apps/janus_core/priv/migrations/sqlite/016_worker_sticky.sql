-- Master-worker dispatch: worker nodes in sticky-only drain mode.
CREATE TABLE IF NOT EXISTS worker_sticky_drained (
    node_name TEXT PRIMARY KEY,
    drained_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
