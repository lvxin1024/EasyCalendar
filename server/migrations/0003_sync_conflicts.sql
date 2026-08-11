CREATE TABLE sync_entity_heads (
    entity_type TEXT NOT NULL CHECK (
        entity_type IN ('item', 'collection', 'subscription')
    ),
    entity_id TEXT NOT NULL,
    change_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('create', 'update', 'delete')),
    entity_version INTEGER NOT NULL CHECK (entity_version >= 1),
    updated_at TEXT NOT NULL,
    payload TEXT NOT NULL CHECK (json_valid(payload)),
    PRIMARY KEY (entity_type, entity_id)
);

ALTER TABLE collections
ADD COLUMN winner_change_id TEXT NOT NULL DEFAULT '0';

ALTER TABLE items
ADD COLUMN winner_change_id TEXT NOT NULL DEFAULT '0';

ALTER TABLE subscriptions
ADD COLUMN winner_change_id TEXT NOT NULL DEFAULT '0';

INSERT INTO sync_entity_heads (
    entity_type, entity_id, change_id, device_id, operation,
    entity_version, updated_at, payload
)
SELECT entity_type, entity_id, change_id, device_id, operation,
       entity_version, changed_at, payload
FROM change_log AS candidate
WHERE NOT EXISTS (
    SELECT 1
    FROM change_log AS other
    WHERE other.entity_type = candidate.entity_type
      AND other.entity_id = candidate.entity_id
      AND (
          julianday(other.changed_at) > julianday(candidate.changed_at)
          OR (
              julianday(other.changed_at) = julianday(candidate.changed_at)
              AND other.entity_version > candidate.entity_version
          )
          OR (
              julianday(other.changed_at) = julianday(candidate.changed_at)
              AND other.entity_version = candidate.entity_version
              AND other.change_id > candidate.change_id
          )
      )
);

UPDATE collections
SET version = (
        SELECT entity_version FROM sync_entity_heads
        WHERE entity_type = 'collection' AND entity_id = collections.id
    ),
    updated_at = (
        SELECT updated_at FROM sync_entity_heads
        WHERE entity_type = 'collection' AND entity_id = collections.id
    ),
    deleted_at = json_extract((
        SELECT payload FROM sync_entity_heads
        WHERE entity_type = 'collection' AND entity_id = collections.id
    ), '$.deleted_at'),
    payload = (
        SELECT payload FROM sync_entity_heads
        WHERE entity_type = 'collection' AND entity_id = collections.id
    ),
    winner_change_id = (
        SELECT change_id FROM sync_entity_heads
        WHERE entity_type = 'collection' AND entity_id = collections.id
    )
WHERE EXISTS (
    SELECT 1 FROM sync_entity_heads
    WHERE entity_type = 'collection' AND entity_id = collections.id
);

UPDATE items
SET collection_id = json_extract((
        SELECT payload FROM sync_entity_heads
        WHERE entity_type = 'item' AND entity_id = items.id
    ), '$.collection_id'),
    item_type = json_extract((
        SELECT payload FROM sync_entity_heads
        WHERE entity_type = 'item' AND entity_id = items.id
    ), '$.type'),
    version = (
        SELECT entity_version FROM sync_entity_heads
        WHERE entity_type = 'item' AND entity_id = items.id
    ),
    updated_at = (
        SELECT updated_at FROM sync_entity_heads
        WHERE entity_type = 'item' AND entity_id = items.id
    ),
    deleted_at = json_extract((
        SELECT payload FROM sync_entity_heads
        WHERE entity_type = 'item' AND entity_id = items.id
    ), '$.deleted_at'),
    payload = (
        SELECT payload FROM sync_entity_heads
        WHERE entity_type = 'item' AND entity_id = items.id
    ),
    winner_change_id = (
        SELECT change_id FROM sync_entity_heads
        WHERE entity_type = 'item' AND entity_id = items.id
    )
WHERE EXISTS (
    SELECT 1 FROM sync_entity_heads
    WHERE entity_type = 'item' AND entity_id = items.id
);

UPDATE subscriptions
SET collection_id = json_extract((
        SELECT payload FROM sync_entity_heads
        WHERE entity_type = 'subscription' AND entity_id = subscriptions.id
    ), '$.collection_id'),
    version = (
        SELECT entity_version FROM sync_entity_heads
        WHERE entity_type = 'subscription' AND entity_id = subscriptions.id
    ),
    updated_at = (
        SELECT updated_at FROM sync_entity_heads
        WHERE entity_type = 'subscription' AND entity_id = subscriptions.id
    ),
    deleted_at = json_extract((
        SELECT payload FROM sync_entity_heads
        WHERE entity_type = 'subscription' AND entity_id = subscriptions.id
    ), '$.deleted_at'),
    payload = (
        SELECT payload FROM sync_entity_heads
        WHERE entity_type = 'subscription' AND entity_id = subscriptions.id
    ),
    winner_change_id = (
        SELECT change_id FROM sync_entity_heads
        WHERE entity_type = 'subscription' AND entity_id = subscriptions.id
    )
WHERE EXISTS (
    SELECT 1 FROM sync_entity_heads
    WHERE entity_type = 'subscription' AND entity_id = subscriptions.id
);

CREATE TABLE sync_conflicts (
    conflict_id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL CHECK (
        entity_type IN ('item', 'collection', 'subscription')
    ),
    entity_id TEXT NOT NULL,
    winner_change_id TEXT NOT NULL,
    loser_change_id TEXT NOT NULL,
    winner TEXT NOT NULL CHECK (json_valid(winner)),
    loser TEXT NOT NULL CHECK (json_valid(loser)),
    recorded_at TEXT NOT NULL,
    UNIQUE (entity_type, entity_id, winner_change_id, loser_change_id)
);

CREATE INDEX idx_sync_conflicts_entity
ON sync_conflicts (entity_type, entity_id, conflict_id DESC);

UPDATE app_metadata
SET value = '3',
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE key = 'schema_version';
