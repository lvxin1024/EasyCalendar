CREATE TABLE collections (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT NOT NULL,
    readonly INTEGER NOT NULL CHECK (readonly IN (0, 1)),
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    version INTEGER NOT NULL CHECK (version >= 1),
    payload_json TEXT NOT NULL
);

CREATE INDEX idx_collections_active_name
    ON collections(deleted_at, name, id);

CREATE TABLE items (
    id TEXT PRIMARY KEY,
    collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE RESTRICT,
    item_type TEXT NOT NULL,
    status TEXT NOT NULL,
    start_at TEXT,
    due_at TEXT,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    version INTEGER NOT NULL CHECK (version >= 1),
    payload_json TEXT NOT NULL
);

CREATE INDEX idx_items_collection_active
    ON items(collection_id, deleted_at, id);
CREATE INDEX idx_items_schedule
    ON items(deleted_at, start_at, due_at, id);
CREATE INDEX idx_items_type_status
    ON items(item_type, status, deleted_at, id);

CREATE TABLE reminders (
    id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    position INTEGER NOT NULL CHECK (position >= 0),
    mode TEXT NOT NULL,
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    payload_json TEXT NOT NULL
);

CREATE UNIQUE INDEX idx_reminders_item_position
    ON reminders(item_id, position);

CREATE TABLE subscriptions (
    id TEXT PRIMARY KEY,
    collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE RESTRICT,
    subscription_type TEXT NOT NULL,
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    version INTEGER NOT NULL CHECK (version >= 1),
    payload_json TEXT NOT NULL
);

CREATE INDEX idx_subscriptions_collection_active
    ON subscriptions(collection_id, deleted_at, id);

CREATE TABLE outbox (
    change_id TEXT PRIMARY KEY,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    operation TEXT NOT NULL,
    entity_version INTEGER NOT NULL CHECK (entity_version >= 1),
    created_at TEXT NOT NULL,
    retry_count INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    last_error TEXT,
    sent_at TEXT,
    payload_json TEXT NOT NULL
);

CREATE INDEX idx_outbox_pending
    ON outbox(sent_at, created_at, change_id);
CREATE INDEX idx_outbox_entity
    ON outbox(entity_type, entity_id, entity_version);

CREATE TABLE sync_state (
    key TEXT PRIMARY KEY,
    value_json TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
