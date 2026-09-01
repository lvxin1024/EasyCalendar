import 'package:sqflite_common_ffi/sqflite_ffi.dart';

abstract final class LocalDatabaseSchema {
  static const version = 6;

  static Future<void> create(Database database, int version) async {
    await database.execute('''
      CREATE TABLE collections (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'local',
        color TEXT,
        readonly INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        version INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await database.execute('''
      CREATE TABLE items (
        id TEXT PRIMARY KEY,
        collection_id TEXT NOT NULL REFERENCES collections(id),
        item_type TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT,
        start_at TEXT,
        end_at TEXT,
        due_at TEXT,
        timezone TEXT NOT NULL,
        all_day INTEGER NOT NULL DEFAULT 0,
        location TEXT,
        status TEXT NOT NULL,
        priority INTEGER,
        reminder_enabled INTEGER NOT NULL DEFAULT 0,
        reminder_minutes INTEGER NOT NULL DEFAULT 30,
        recurrence_json TEXT,
        tags_json TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        version INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await database.execute('''
      CREATE INDEX idx_client_items_schedule
      ON items(deleted_at, start_at, due_at, id)
    ''');
    await database.execute('''
      CREATE TABLE outbox (
        change_id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        operation TEXT NOT NULL,
        entity_version INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        created_at TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        next_attempt_at TEXT,
        permanent_failure INTEGER NOT NULL DEFAULT 0,
        sent_at TEXT
      )
    ''');
    await database.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE sync_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE subscriptions (
        id TEXT PRIMARY KEY,
        collection_id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        version INTEGER NOT NULL
      )
    ''');
    await _createConflictSchema(database);
    await _createCycleSchema(database);
  }

  static Future<void> upgrade(
    Database database,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await database.execute(
        'ALTER TABLE outbox ADD COLUMN next_attempt_at TEXT',
      );
      await database.execute(
        'ALTER TABLE outbox ADD COLUMN permanent_failure INTEGER NOT NULL DEFAULT 0',
      );
      await database.execute('''
        CREATE TABLE sync_state (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      await database.execute('''
        CREATE TABLE subscriptions (
          id TEXT PRIMARY KEY,
          collection_id TEXT NOT NULL,
          payload_json TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          deleted_at TEXT,
          version INTEGER NOT NULL
        )
      ''');
    }
    if (oldVersion < 3) {
      await _createConflictSchema(database);
      await database.execute('''
        INSERT INTO sync_entity_heads (
          entity_type, entity_id, change_id, device_id, operation,
          entity_version, updated_at, payload_json
        )
        SELECT entity_type, entity_id, change_id, device_id, operation,
               entity_version, created_at, payload_json
        FROM outbox AS candidate
        WHERE NOT EXISTS (
          SELECT 1 FROM outbox AS other
          WHERE other.entity_type = candidate.entity_type
            AND other.entity_id = candidate.entity_id
            AND (
              other.created_at > candidate.created_at
              OR (
                other.created_at = candidate.created_at
                AND other.entity_version > candidate.entity_version
              )
              OR (
                other.created_at = candidate.created_at
                AND other.entity_version = candidate.entity_version
                AND other.change_id > candidate.change_id
              )
            )
        )
      ''');
    }
    if (oldVersion < 4) {
      await database.execute(
        'ALTER TABLE items ADD COLUMN recurrence_json TEXT',
      );
    }
    if (oldVersion < 5) {
      await _createCycleSchema(database);
    }
    if (oldVersion == 5) {
      await database.execute(
        'DROP INDEX IF EXISTS idx_cycle_periods_start_date',
      );
      await database.execute(
        'CREATE INDEX IF NOT EXISTS idx_cycle_periods_start_date ON cycle_periods(start_date)',
      );
      await database.execute(
        'ALTER TABLE cycle_periods ADD COLUMN deleted_at TEXT',
      );
      await database.execute(
        'ALTER TABLE cycle_periods ADD COLUMN version INTEGER NOT NULL DEFAULT 1',
      );
      await database.execute(
        'ALTER TABLE cycle_settings ADD COLUMN version INTEGER NOT NULL DEFAULT 1',
      );
    }
  }

  static Future<void> _createCycleSchema(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS cycle_periods (
        id TEXT PRIMARY KEY,
        start_date TEXT NOT NULL,
        end_date TEXT,
        excluded_from_prediction INTEGER NOT NULL DEFAULT 0,
        context TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        version INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_cycle_periods_start_date
      ON cycle_periods(start_date)
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS cycle_daily_logs (
        date TEXT PRIMARY KEY,
        period_id TEXT NOT NULL REFERENCES cycle_periods(id) ON DELETE CASCADE,
        bleeding_level TEXT,
        spotting INTEGER NOT NULL DEFAULT 0,
        symptoms_json TEXT NOT NULL DEFAULT '[]',
        updated_at TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_cycle_daily_logs_period
      ON cycle_daily_logs(period_id, date)
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS cycle_settings (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        enabled INTEGER NOT NULL DEFAULT 0,
        forecast_horizon INTEGER NOT NULL DEFAULT 1,
        updated_at TEXT NOT NULL,
        version INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await database.insert('cycle_settings', {
      'id': 1,
      'enabled': 0,
      'forecast_horizon': 1,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'version': 1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> _createConflictSchema(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE sync_entity_heads (
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        change_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        operation TEXT NOT NULL,
        entity_version INTEGER NOT NULL,
        updated_at TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        PRIMARY KEY (entity_type, entity_id)
      )
    ''');
    await database.execute('''
      CREATE TABLE sync_conflicts (
        conflict_id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        winner_change_id TEXT NOT NULL,
        loser_change_id TEXT NOT NULL,
        winner_json TEXT NOT NULL,
        loser_json TEXT NOT NULL,
        recorded_at TEXT NOT NULL,
        UNIQUE (entity_type, entity_id, winner_change_id, loser_change_id)
      )
    ''');
    await database.execute('''
      CREATE INDEX idx_client_sync_conflicts
      ON sync_conflicts (conflict_id DESC)
    ''');
  }
}
