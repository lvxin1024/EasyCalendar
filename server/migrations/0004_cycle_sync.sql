CREATE TABLE cycle_periods (
    id TEXT PRIMARY KEY NOT NULL,
    version INTEGER NOT NULL CHECK (version >= 1),
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    payload TEXT NOT NULL CHECK (json_valid(payload)),
    winner_change_id TEXT NOT NULL DEFAULT '0'
);

CREATE TABLE cycle_settings (
    id TEXT PRIMARY KEY NOT NULL CHECK (id = 'singleton'),
    version INTEGER NOT NULL CHECK (version >= 1),
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    payload TEXT NOT NULL CHECK (json_valid(payload)),
    winner_change_id TEXT NOT NULL DEFAULT '0'
);

ALTER TABLE change_log RENAME TO change_log_legacy;
CREATE TABLE change_log (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    change_id TEXT NOT NULL UNIQUE,
    device_id TEXT NOT NULL,
    entity_type TEXT NOT NULL CHECK (entity_type IN ('item', 'collection', 'subscription', 'cycle_period', 'cycle_settings')),
    entity_id TEXT NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('create', 'update', 'delete')),
    entity_version INTEGER NOT NULL CHECK (entity_version >= 1),
    changed_at TEXT NOT NULL,
    payload TEXT NOT NULL CHECK (json_valid(payload))
);
INSERT INTO change_log (sequence, change_id, device_id, entity_type, entity_id, operation, entity_version, changed_at, payload)
SELECT sequence, change_id, device_id, entity_type, entity_id, operation, entity_version, changed_at, payload FROM change_log_legacy;
DROP TABLE change_log_legacy;
CREATE INDEX idx_change_log_cursor ON change_log (sequence);

ALTER TABLE sync_entity_heads RENAME TO sync_entity_heads_legacy;
CREATE TABLE sync_entity_heads (
    entity_type TEXT NOT NULL CHECK (entity_type IN ('item', 'collection', 'subscription', 'cycle_period', 'cycle_settings')),
    entity_id TEXT NOT NULL,
    change_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('create', 'update', 'delete')),
    entity_version INTEGER NOT NULL CHECK (entity_version >= 1),
    updated_at TEXT NOT NULL,
    payload TEXT NOT NULL CHECK (json_valid(payload)),
    PRIMARY KEY (entity_type, entity_id)
);
INSERT INTO sync_entity_heads SELECT * FROM sync_entity_heads_legacy;
DROP TABLE sync_entity_heads_legacy;

ALTER TABLE sync_conflicts RENAME TO sync_conflicts_legacy;
CREATE TABLE sync_conflicts (
    conflict_id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL CHECK (entity_type IN ('item', 'collection', 'subscription', 'cycle_period', 'cycle_settings')),
    entity_id TEXT NOT NULL,
    winner_change_id TEXT NOT NULL,
    loser_change_id TEXT NOT NULL,
    winner TEXT NOT NULL CHECK (json_valid(winner)),
    loser TEXT NOT NULL CHECK (json_valid(loser)),
    recorded_at TEXT NOT NULL,
    UNIQUE (entity_type, entity_id, winner_change_id, loser_change_id)
);
INSERT INTO sync_conflicts SELECT * FROM sync_conflicts_legacy;
DROP TABLE sync_conflicts_legacy;
CREATE INDEX idx_sync_conflicts_entity ON sync_conflicts (entity_type, entity_id, conflict_id DESC);

UPDATE app_metadata
SET value = '4', updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE key = 'schema_version';
