import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/data/local_item_repository.dart';
import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/sync/sync_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late LocalItemRepository repository;

  setUp(() async {
    sqfliteFfiInit();
    repository = LocalItemRepository(
      _config,
      databaseFactory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await repository.initialize();
  });

  tearDown(() => repository.close());

  test('default collection and local mutations are queued for push', () async {
    final initial = await repository.listPendingChanges(now: DateTime.now());
    expect(initial.single.entityType, 'collection');

    await repository.createItem(
      const ItemDraft(
        type: ItemType.task,
        title: 'Offline task',
        timezone: 'Asia/Shanghai',
      ),
    );
    final pending = await repository.listPendingChanges(now: DateTime.now());

    expect(pending.map((change) => change.entityType), ['collection', 'item']);
  });

  test('remote batch and cursor commit atomically', () async {
    final change = _remoteItem('item_remote', 'Remote task');
    await repository.applyRemoteBatch([change], 'cur_1');

    expect((await repository.listItems()).single.title, 'Remote task');
    expect(await repository.loadRemoteCursor(), 'cur_1');

    final invalid = RemoteSyncChange(
      changeId: 'bad_change',
      deviceId: 'other-device',
      entityType: 'unknown',
      entityId: 'item_bad',
      operation: 'create',
      version: 1,
      updatedAt: DateTime.utc(2026, 8, 11, 9),
      payload: const {'id': 'item_bad', 'version': 1},
    );
    await expectLater(
      repository.applyRemoteBatch([
        _remoteItem('item_rolled_back', 'Should rollback'),
        invalid,
      ], 'cur_3'),
      throwsFormatException,
    );

    expect(
      (await repository.listItems()).map((item) => item.id),
      isNot(contains('item_rolled_back')),
    );
    expect(await repository.loadRemoteCursor(), 'cur_1');
  });
}

RemoteSyncChange _remoteItem(String id, String title) {
  const timestamp = '2026-08-11T08:00:00.000Z';
  return RemoteSyncChange(
    changeId: 'change_$id',
    deviceId: 'other-device',
    entityType: 'item',
    entityId: id,
    operation: 'create',
    version: 1,
    updatedAt: DateTime.parse(timestamp),
    payload: {
      'id': id,
      'collection_id': 'collection_local',
      'type': 'task',
      'title': title,
      'body': null,
      'start_at': null,
      'end_at': null,
      'due_at': null,
      'timezone': 'Asia/Shanghai',
      'all_day': false,
      'location': null,
      'status': 'todo',
      'priority': null,
      'reminders': [],
      'tags': [],
      'source': 'local',
      'metadata': {},
      'created_at': timestamp,
      'updated_at': timestamp,
      'deleted_at': null,
      'version': 1,
    },
  );
}

const _config = AppConfig(
  appName: 'EasyCalendar',
  locale: Locale('zh', 'CN'),
  timezone: 'Asia/Shanghai',
  defaultCollectionId: 'collection_local',
  defaultCollectionName: 'My calendar',
  defaultCollectionColor: Color(0xFF2563EB),
  databaseName: 'test.sqlite3',
  deviceId: 'test-device',
  apiUrl: 'https://sync.example.com',
  syncEnabled: true,
  syncRetryLimit: 8,
  notificationsEnabled: false,
);
