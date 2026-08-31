import 'dart:convert';

import 'package:easy_calendar/data/local_database_schema.dart';
import 'package:easy_calendar/data/local_json_transfer_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Database database;
  late LocalJsonTransferService service;

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: LocalDatabaseSchema.version,
        onCreate: LocalDatabaseSchema.create,
      ),
    );
    service = LocalJsonTransferService(database);
  });

  tearDown(() => database.close());

  test('exports every local transfer table', () async {
    await database.insert('collections', _collection('collection_existing'));
    await database.insert('outbox', _outbox('change_existing'));
    await database.insert('sync_state', {
      'key': 'remote_cursor',
      'value': 'cursor_1',
      'updated_at': '2026-08-31T00:00:00.000Z',
    });

    final decoded = jsonDecode(await service.exportBackup()) as Map;

    expect(decoded['schema_version'], 1);
    expect(decoded['collections'], hasLength(1));
    expect(decoded['outbox'], hasLength(1));
    expect(decoded['sync_state'], hasLength(1));
  });

  test('previews non-id transfer tables without type errors', () async {
    await database.insert('outbox', _outbox('change_existing'));
    await database.insert('sync_state', {
      'key': 'remote_cursor',
      'value': 'cursor_1',
      'updated_at': '2026-08-31T00:00:00.000Z',
    });
    final backup = await service.exportBackup();

    final result = await service.previewImport(backup);

    expect(result.accepted, isTrue);
    expect(result.skipped['outbox'], 1);
    expect(result.skipped['sync_state'], 1);
  });

  test(
    'reports references to collections missing from local and backup data',
    () async {
      final result = await service.previewImport(
        jsonEncode({
          'schema_version': 1,
          'collections': <Object?>[],
          'items': [
            {'id': 'item_1', 'collection_id': 'collection_missing'},
          ],
          'subscriptions': <Object?>[],
          'outbox': <Object?>[],
          'sync_state': <Object?>[],
        }),
      );

      expect(result.accepted, isFalse);
      expect(result.conflicts['items'], 1);
      expect(result.issues.single.resourceId, 'item_1');
    },
  );

  test('commits new rows and preserves existing identities', () async {
    await database.insert('collections', _collection('collection_existing'));
    final backup = jsonEncode({
      'schema_version': 1,
      'collections': [
        _collection('collection_existing', name: 'Replacement'),
        _collection('collection_new', name: 'Imported'),
      ],
      'items': <Object?>[],
      'subscriptions': <Object?>[],
      'outbox': <Object?>[],
      'sync_state': <Object?>[],
    });

    await service.commitImport(backup);

    final rows = await database.query('collections', orderBy: 'id');
    expect(rows, hasLength(2));
    expect(rows.first['name'], 'Existing');
    expect(rows.last['name'], 'Imported');
  });
}

Map<String, Object?> _collection(String id, {String name = 'Existing'}) => {
  'id': id,
  'name': name,
  'kind': 'local',
  'color': null,
  'readonly': 0,
  'created_at': '2026-08-31T00:00:00.000Z',
  'updated_at': '2026-08-31T00:00:00.000Z',
  'deleted_at': null,
  'version': 1,
};

Map<String, Object?> _outbox(String changeId) => {
  'change_id': changeId,
  'device_id': 'device_1',
  'entity_type': 'collection',
  'entity_id': 'collection_1',
  'operation': 'create',
  'entity_version': 1,
  'payload_json': '{}',
  'created_at': '2026-08-31T00:00:00.000Z',
  'retry_count': 0,
  'last_error': null,
  'next_attempt_at': null,
  'permanent_failure': 0,
  'sent_at': null,
};
