CREATE TABLE app_metadata (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

INSERT INTO app_metadata (key, value, updated_at)
VALUES ('schema_version', '1', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));

CREATE TABLE collections (
    id TEXT PRIMARY KEY NOT NULL,
    version INTEGER NOT NULL CHECK (version >= 1),
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    payload TEXT NOT NULL CHECK (json_valid(payload))
);

CREATE TABLE items (
    id TEXT PRIMARY KEY NOT NULL,
    collection_id TEXT NOT NULL,
    item_type TEXT NOT NULL CHECK (item_type IN ('event', 'task', 'note')),
    version INTEGER NOT NULL CHECK (version >= 1),
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    payload TEXT NOT NULL CHECK (json_valid(payload)),
    FOREIGN KEY (collection_id) REFERENCES collections(id)
);

CREATE INDEX idx_items_collection_updated
ON items (collection_id, updated_at, id);

CREATE TABLE subscriptions (
    id TEXT PRIMARY KEY NOT NULL,
    collection_id TEXT NOT NULL UNIQUE,
    version INTEGER NOT NULL CHECK (version >= 1),
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    payload TEXT NOT NULL CHECK (json_valid(payload)),
    FOREIGN KEY (collection_id) REFERENCES collections(id)
);

CREATE TABLE change_log (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    change_id TEXT NOT NULL UNIQUE,
    entity_type TEXT NOT NULL CHECK (
        entity_type IN ('item', 'collection', 'subscription')
    ),
    entity_id TEXT NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('create', 'update', 'delete')),
    entity_version INTEGER NOT NULL CHECK (entity_version >= 1),
    changed_at TEXT NOT NULL,
    payload TEXT NOT NULL CHECK (json_valid(payload))
);

CREATE INDEX idx_change_log_cursor ON change_log (sequence);

CREATE TABLE applied_changes (
    change_id TEXT PRIMARY KEY NOT NULL,
    request_hash TEXT NOT NULL,
    applied_at TEXT NOT NULL,
    result TEXT NOT NULL CHECK (json_valid(result))
);
