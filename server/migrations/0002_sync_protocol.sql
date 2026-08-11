ALTER TABLE change_log
ADD COLUMN device_id TEXT NOT NULL DEFAULT 'server-legacy';

CREATE TABLE sync_requests (
    idempotency_key TEXT PRIMARY KEY NOT NULL,
    request_hash TEXT NOT NULL,
    response_json TEXT NOT NULL CHECK (json_valid(response_json)),
    created_at TEXT NOT NULL
);

UPDATE app_metadata
SET value = '2',
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE key = 'schema_version';
