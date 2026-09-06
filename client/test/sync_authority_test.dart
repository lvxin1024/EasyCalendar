import 'dart:convert';

import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/data/local_item_repository.dart';
import 'package:easy_calendar/sync/sync_authority.dart';
import 'package:easy_calendar/sync/sync_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late LocalItemRepository repository;
  late SyncAuthorityStore authority;

  setUp(() async {
    sqfliteFfiInit();
    repository = LocalItemRepository(
      const AppConfig(
        appName: 'EasyCalendar',
        locale: Locale('zh', 'CN'),
        timezone: 'Asia/Shanghai',
        defaultCollectionId: 'collection_local',
        defaultCollectionName: '我的日程',
        defaultCollectionColor: Color(0xFF2563EB),
        databaseName: 'test.sqlite3',
        deviceId: 'authority-test',
        apiUrl: 'http://localhost:8000',
        syncEnabled: false,
        syncRetryLimit: 8,
        notificationsEnabled: false,
      ),
      databaseFactory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    authority = SyncAuthorityStore(await repository.openSharedDatabase());
  });

  tearDown(() => repository.close());

  test(
    'authority schema stores idempotent changes and paginates cursors',
    () async {
      final first = _change('change-1', 'item-1', 1);
      final second = _change('change-2', 'item-2', 1);

      expect(await authority.appendChange(first), 1);
      expect(await authority.appendChange(first), 1);
      expect(await authority.appendChange(second), 2);

      final page = await authority.pull(limit: 1);
      expect(page.cursor, 'cur_1');
      expect(page.hasMore, isTrue);
      expect(page.changes.single.changeId, 'change-1');

      final next = await authority.pull(cursor: page.cursor, limit: 1);
      expect(next.cursor, 'cur_2');
      expect(next.hasMore, isFalse);
      expect(next.changes.single.changeId, 'change-2');
    },
  );

  test(
    'authority schema persists requests, members, state and entity heads',
    () async {
      final change = _change('change-1', 'item-1', 1);
      await authority.appendChange(change);
      await authority.replaceEntityHead(change);
      await authority.saveRequest(
        SyncAuthorityRequest(
          idempotencyKey: 'push-1',
          requestHash: 'hash-1',
          responseJson: jsonEncode({
            'accepted': ['change-1'],
          }),
          createdAt: DateTime.utc(2026, 9, 6),
        ),
      );
      await authority.upsertMember(
        SyncAuthorityMember(
          endpointId: 'endpoint-1',
          deviceId: 'device-1',
          displayName: '手机',
          status: 'active',
          joinedAt: DateTime.utc(2026, 9, 6),
        ),
      );
      await authority.saveState('topology_epoch', '1');

      expect((await authority.loadRequest('push-1'))?.requestHash, 'hash-1');
      expect((await authority.listMembers()).single.displayName, '手机');
      expect(await authority.loadState('topology_epoch'), '1');
      final database = await repository.openSharedDatabase();
      expect(
        (await database.query(
          'sync_authority_entity_heads',
        )).single['change_id'],
        'change-1',
      );
    },
  );

  test('authority cursor validation rejects unsupported values', () async {
    expect(() => authority.pull(cursor: 'not-a-cursor'), throwsFormatException);
    expect(() => authority.pull(limit: 0), throwsFormatException);
  });
}

RemoteSyncChange _change(String changeId, String entityId, int version) =>
    RemoteSyncChange(
      changeId: changeId,
      deviceId: 'device-1',
      entityType: 'item',
      entityId: entityId,
      operation: 'update',
      version: version,
      updatedAt: DateTime.utc(2026, 9, 6, 1, version),
      payload: {
        'id': entityId,
        'version': version,
        'updated_at': DateTime.utc(2026, 9, 6, 1, version).toIso8601String(),
      },
    );
