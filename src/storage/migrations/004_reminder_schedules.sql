CREATE TABLE reminder_schedules (
    reminder_id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    item_version INTEGER NOT NULL CHECK (item_version >= 1),
    fire_at TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('scheduled', 'failed')),
    platform_schedule_id TEXT,
    last_error TEXT,
    updated_at TEXT NOT NULL
);

CREATE INDEX idx_reminder_schedules_item
    ON reminder_schedules(item_id, reminder_id);

CREATE INDEX idx_reminder_schedules_due
    ON reminder_schedules(state, fire_at, reminder_id);
