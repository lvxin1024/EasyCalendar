CREATE TABLE subscription_fetch_logs (
    fetch_id TEXT PRIMARY KEY,
    subscription_id TEXT NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
    started_at TEXT NOT NULL,
    finished_at TEXT NOT NULL,
    status TEXT NOT NULL,
    http_status INTEGER,
    etag TEXT,
    last_modified TEXT,
    source_hash TEXT,
    error TEXT,
    created_count INTEGER NOT NULL CHECK (created_count >= 0),
    updated_count INTEGER NOT NULL CHECK (updated_count >= 0),
    deleted_count INTEGER NOT NULL CHECK (deleted_count >= 0),
    unchanged_count INTEGER NOT NULL CHECK (unchanged_count >= 0)
);

CREATE INDEX idx_subscription_fetch_logs_subscription
    ON subscription_fetch_logs(subscription_id, finished_at DESC, fetch_id);
