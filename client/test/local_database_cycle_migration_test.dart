import 'dart:io';

import 'package:easy_calendar/data/local_database_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('schema v4 upgrades to v6 without removing existing data', () async {
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
}
