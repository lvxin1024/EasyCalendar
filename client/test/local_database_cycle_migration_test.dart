import 'dart:io';

import 'package:easy_calendar/data/local_database_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('schema v4 upgrades to v7 without removing existing data', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp(
      'easy_calendar_cycle_migration_',
    );
    final path = '${directory.path}/calendar.db';
    var database = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: LocalDatabaseSchema.version,
        singleInstance: false,
        onCreate: LocalDatabaseSchema.create,
      ),
    );
    await database.insert('app_settings', {
      'key': 'migration_sentinel',
      'value': 'kept',
    });
    await database.execute('DROP TABLE cycle_daily_logs');
    await database.execute('DROP TABLE cycle_periods');
    await database.execute('DROP TABLE cycle_settings');
    await database.execute('PRAGMA user_version = 4');
    await database.close();

    database = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: LocalDatabaseSchema.version,
        singleInstance: false,
        onUpgrade: LocalDatabaseSchema.upgrade,
      ),
    );

    expect(
      (await database.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['migration_sentinel'],
      )).single['value'],
      'kept',
    );
    final tables = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'cycle_%'",
    );
    expect(
      tables.map((row) => row['name']),
      containsAll(['cycle_periods', 'cycle_daily_logs', 'cycle_settings']),
    );
    final settings = await database.query('cycle_settings');
    expect(settings.single['enabled'], 0);

    await database.close();
    await directory.delete(recursive: true);
  });

  test('schema v7 only requeues legacy cycle protocol failures', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp(
      'easy_calendar_cycle_retry_migration_',
    );
    final path = '${directory.path}/calendar.db';
    var database = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 6,
        singleInstance: false,
        onCreate: LocalDatabaseSchema.create,
      ),
    );
    final createdAt = DateTime.utc(2026, 9, 1).toIso8601String();
    for (final row in [
      {
        'change_id': 'retry_cycle_period',
        'entity_type': 'cycle_period',
        'last_error': 'transport_rejected: entity_type is invalid',
      },
      {
        'change_id': 'retry_cycle_settings',
        'entity_type': 'cycle_settings',
        'last_error': 'transport_rejected: entity_type is invalid',
      },
      {
        'change_id': 'keep_invalid_item',
        'entity_type': 'item',
        'last_error': 'transport_rejected: entity_type is invalid',
      },
      {
        'change_id': 'keep_cycle_constraint',
        'entity_type': 'cycle_period',
        'last_error': 'constraint_violation: invalid period',
      },
    ]) {
      await database.insert('outbox', {
        'change_id': row['change_id'],
        'device_id': 'migration-device',
        'entity_type': row['entity_type'],
        'entity_id': row['change_id'],
        'operation': 'update',
        'entity_version': 1,
        'payload_json': '{}',
        'created_at': createdAt,
        'retry_count': 3,
        'last_error': row['last_error'],
        'next_attempt_at': null,
        'permanent_failure': 1,
        'sent_at': null,
      });
    }
    await database.close();

    database = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: LocalDatabaseSchema.version,
        singleInstance: false,
        onUpgrade: LocalDatabaseSchema.upgrade,
      ),
    );

    final rows = await database.query('outbox', orderBy: 'change_id');
    final byId = {for (final row in rows) row['change_id']: row};
    for (final id in ['retry_cycle_period', 'retry_cycle_settings']) {
      expect(byId[id]!['permanent_failure'], 0);
      expect(byId[id]!['retry_count'], 0);
      expect(byId[id]!['last_error'], isNull);
    }
    for (final id in ['keep_invalid_item', 'keep_cycle_constraint']) {
      expect(byId[id]!['permanent_failure'], 1);
      expect(byId[id]!['retry_count'], 3);
      expect(byId[id]!['last_error'], isNotNull);
    }

    await database.close();
    await directory.delete(recursive: true);
  });
}
