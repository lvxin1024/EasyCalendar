import 'dart:io';

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

  test('a winning unsent local edit is not overwritten by pull', () async {
    final local = await repository.createItem(
      const ItemDraft(
        type: ItemType.task,
        title: 'Local winner',
        timezone: 'Asia/Shanghai',
      ),
    );
    final remoteLoser = _remoteItem(
      local.id,
      'Remote loser',
      timestamp: '2026-08-11T08:00:00.000Z',
    );

    await repository.applyRemoteBatch([remoteLoser], 'cur_local_wins');

    expect((await repository.listItems()).single.title, 'Local winner');
    final history = await repository.listSyncConflicts();
    expect(history.single.winner.payload['title'], 'Local winner');
    expect(history.single.loser.payload['title'], 'Remote loser');
  });

  test(
    'pulling accepted changes from the same device is only a replay',
    () async {
      final created = await repository.createItem(
        const ItemDraft(
          type: ItemType.task,
          title: 'First local version',
          timezone: 'Asia/Shanghai',
        ),
      );
      await repository.updateItem(
        created,
        const ItemDraft(
          type: ItemType.task,
          title: 'Locally pushed',
          timezone: 'Asia/Shanghai',
        ),
      );
      final pending = await repository.listPendingChanges(now: DateTime.now());
      final replay = pending
          .map(
            (change) => RemoteSyncChange(
              changeId: change.changeId,
              deviceId: change.deviceId,
              entityType: change.entityType,
              entityId: change.entityId,
              operation: change.operation,
              version: change.version,
              updatedAt: change.updatedAt,
              payload: change.payload,
            ),
          )
          .toList();

      await repository.applyRemoteBatch(replay, 'cur_replay');

      expect(await repository.listSyncConflicts(), isEmpty);
      expect((await repository.listItems()).single.title, 'Locally pushed');
    },
  );

  test(
    'a remote winner replaces local state and keeps recovery data',
    () async {
      final local = await repository.createItem(
        const ItemDraft(
          type: ItemType.task,
          title: 'Recoverable local version',
          timezone: 'Asia/Shanghai',
        ),
      );
      final remoteWinner = _remoteItem(
        local.id,
        'Remote winner',
        timestamp: '2099-08-11T08:00:00.000Z',
      );

      await repository.applyRemoteBatch([remoteWinner], 'cur_remote_wins');

      expect((await repository.listItems()).single.title, 'Remote winner');
      final history = await repository.listSyncConflicts();
      expect(history.single.winner.payload['title'], 'Remote winner');
      expect(
        history.single.loser.payload['title'],
        'Recoverable local version',
      );
    },
  );

  test('persists tag color preferences locally', () async {
    final defaults = ClientPreferences(
      apiUrl: _config.apiUrl,
      syncEnabled: _config.syncEnabled,
      notificationsEnabled: _config.notificationsEnabled,
    );
    await repository.savePreferences(
      defaults.copyWith(tagColors: {'工作': 0xFF2563EB}),
    );

    final loaded = await repository.loadPreferences(defaults);

    expect(loaded.tagColors, {'工作': 0xFF2563EB});
  });

  test('schema v2 upgrades with pending entity heads intact', () async {
    final directory = await Directory.systemTemp.createTemp(
      'easycalendar-sync-migration-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final databasePath = '${directory.path}/client.sqlite3';
    final original = LocalItemRepository(
      _config,
      databaseFactory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    await original.initialize();
    await original.createItem(
      const ItemDraft(
        type: ItemType.task,
        title: 'Pending before migration',
        timezone: 'Asia/Shanghai',
      ),
    );
    await original.close();

    final legacy = await databaseFactoryFfi.openDatabase(databasePath);
    await legacy.execute('DROP INDEX idx_client_sync_conflicts');
    await legacy.execute('DROP TABLE sync_conflicts');
    await legacy.execute('DROP TABLE sync_entity_heads');
    await legacy.execute('PRAGMA user_version = 2');
    await legacy.close();

    final migrated = LocalItemRepository(
      _config,
      databaseFactory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    await migrated.initialize();
    addTearDown(migrated.close);

    final pending = await migrated.listPendingChanges(now: DateTime.now());
    expect(pending.map((change) => change.entityType), ['collection', 'item']);
    final item = (await migrated.listItems()).single;
    await migrated.applyRemoteBatch([
      _remoteItem(item.id, 'Older remote value'),
    ], 'cur_after_migration');
    expect(
      (await migrated.listItems()).single.title,
      'Pending before migration',
    );
    expect(await migrated.listSyncConflicts(), hasLength(1));
  });
}

RemoteSyncChange _remoteItem(
  String id,
  String title, {
  String timestamp = '2026-08-11T08:00:00.000Z',
}) {
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
