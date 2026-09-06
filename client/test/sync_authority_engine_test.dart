import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/data/local_item_repository.dart';
import 'package:easy_calendar/sync/sync_authority.dart';
import 'package:easy_calendar/sync/sync_authority_engine.dart';
import 'package:easy_calendar/sync/sync_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late LocalItemRepository repository;
  late SyncAuthorityStore store;
  late SyncAuthorityEngine authority;
  late _Replica phone;
  late _Replica desktop;

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
        databaseName: 'authority-engine.sqlite3',
        deviceId: 'primary-device',
        apiUrl: 'http://localhost:8000',
        syncEnabled: false,
        syncRetryLimit: 8,
        notificationsEnabled: false,
      ),
      databaseFactory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    store = SyncAuthorityStore(await repository.openSharedDatabase());
    authority = SyncAuthorityEngine(
      store,
      primaryDeviceId: 'primary-device',
      clock: () => DateTime.utc(2026, 9, 6, 1),
    );
    for (final member in [
      SyncAuthorityMember(
        endpointId: 'endpoint-primary',
        deviceId: 'primary-device',
        displayName: '主节点',
        status: 'active',
        joinedAt: DateTime.utc(2026, 9, 6),
      ),
      SyncAuthorityMember(
        endpointId: 'endpoint-phone',
        deviceId: 'phone-device',
        displayName: '手机',
        status: 'active',
        joinedAt: DateTime.utc(2026, 9, 6),
      ),
      SyncAuthorityMember(
        endpointId: 'endpoint-desktop',
        deviceId: 'desktop-device',
        displayName: '桌面',
        status: 'active',
        joinedAt: DateTime.utc(2026, 9, 6),
      ),
    ]) {
      await store.upsertMember(member);
    }
    phone = _Replica(
      authority,
      deviceId: 'phone-device',
      endpointId: 'endpoint-phone',
    );
    desktop = _Replica(
      authority,
      deviceId: 'desktop-device',
      endpointId: 'endpoint-desktop',
    );
  });

  tearDown(() => repository.close());

  test(
    'star topology keeps offline outbox and catches up after reconnect',
    () async {
      final change = _change(
        changeId: 'phone-change-1',
        deviceId: 'phone-device',
        entityId: 'item-1',
        version: 1,
        minute: 1,
      );
      phone.queue(change);
      phone.online = false;

      await phone.synchronize();
      expect(phone.outbox, hasLength(1));
      expect(await store.latestCursor(), 'cur_0');

      phone.online = true;
      await phone.synchronize();
      expect(phone.outbox, isEmpty);
      expect(phone.cursor, 'cur_1');
      expect(phone.heads['item:item-1']?.changeId, 'phone-change-1');
    },
  );

  test('replayed request and change are idempotent', () async {
    final change = _change(
      changeId: 'phone-change-1',
      deviceId: 'phone-device',
      entityId: 'item-1',
      version: 1,
      minute: 1,
    );
    final first = await authority.push(
      deviceId: 'phone-device',
      endpointId: 'endpoint-phone',
      idempotencyKey: 'push-request-1',
      changes: [change],
    );
    final replay = await authority.push(
      deviceId: 'phone-device',
      endpointId: 'endpoint-phone',
      idempotencyKey: 'push-request-1',
      changes: [change],
    );
    final secondKey = await authority.push(
      deviceId: 'phone-device',
      endpointId: 'endpoint-phone',
      idempotencyKey: 'push-request-2',
      changes: [change],
    );

    expect(first.accepted, ['phone-change-1']);
    expect(replay.serverCursor, 'cur_1');
    expect(secondKey.accepted, ['phone-change-1']);
    expect(secondKey.conflicts, isEmpty);
    expect(await store.latestCursor(), 'cur_1');
  });

  test('concurrent edits converge on deterministic LWW winner', () async {
    final phoneChange = _change(
      changeId: 'change-a',
      deviceId: 'phone-device',
      entityId: 'item-shared',
      version: 1,
      minute: 2,
    );
    final desktopChange = _change(
      changeId: 'change-z',
      deviceId: 'desktop-device',
      entityId: 'item-shared',
      version: 1,
      minute: 2,
    );
    phone.queue(phoneChange);
    desktop.queue(desktopChange);
    await desktop.synchronize();
    await phone.synchronize();
    await desktop.synchronize();

    expect(phone.heads['item:item-shared']?.changeId, 'change-z');
    expect(desktop.heads['item:item-shared']?.changeId, 'change-z');
    expect((await store.pull()).changes, hasLength(2));
    expect(
      (await authority.push(
        deviceId: 'phone-device',
        endpointId: 'endpoint-phone',
        idempotencyKey: 'conflict-replay',
        changes: [phoneChange],
      )).conflicts.single.resolution,
      'stored_won',
    );
  });

  test('revoked members and invalid cursors are rejected', () async {
    await store.upsertMember(
      SyncAuthorityMember(
        endpointId: 'endpoint-revoked',
        deviceId: 'revoked-device',
        displayName: '已撤销',
        status: 'revoked',
        joinedAt: DateTime.utc(2026, 9, 6),
      ),
    );
    expect(
      () => authority.pull(
        deviceId: 'revoked-device',
        endpointId: 'endpoint-revoked',
      ),
      throwsA(isA<SyncAuthorityException>()),
    );
    expect(
      () => authority.pull(
        deviceId: 'phone-device',
        endpointId: 'endpoint-phone',
        cursor: 'cursor-invalid',
      ),
      throwsA(isA<SyncAuthorityException>()),
    );
  });
}

class _Replica {
  _Replica(this.authority, {required this.deviceId, required this.endpointId});

  final SyncAuthorityEngine authority;
  final String deviceId;
  final String endpointId;
  final outbox = <PendingSyncChange>[];
  final heads = <String, RemoteSyncChange>{};
  String? cursor;
  bool online = true;
  int _request = 0;

  void queue(PendingSyncChange change) => outbox.add(change);

  Future<void> synchronize() async {
    if (!online) return;
    if (outbox.isNotEmpty) {
      _request += 1;
      final result = await authority.push(
        deviceId: deviceId,
        endpointId: endpointId,
        idempotencyKey: 'replica-$deviceId-$_request',
        changes: List.of(outbox),
      );
      outbox.removeWhere((change) => result.accepted.contains(change.changeId));
    }
    while (true) {
      final page = await authority.pull(
        deviceId: deviceId,
        endpointId: endpointId,
        cursor: cursor,
      );
      for (final change in page.changes) {
        final key = '${change.entityType}:${change.entityId}';
        final current = heads[key];
        if (current == null || compareSyncChanges(change, current) > 0) {
          heads[key] = change;
        }
      }
      cursor = page.cursor;
      if (!page.hasMore) return;
    }
  }
}

PendingSyncChange _change({
  required String changeId,
  required String deviceId,
  required String entityId,
  required int version,
  required int minute,
}) {
  final updatedAt = DateTime.utc(2026, 9, 6, 1, minute);
  return PendingSyncChange(
    changeId: changeId,
    deviceId: deviceId,
    entityType: 'item',
    entityId: entityId,
    operation: 'update',
    version: version,
    updatedAt: updatedAt,
    payload: {
      'id': entityId,
      'collection_id': 'collection_local',
      'type': 'task',
      'title': changeId,
      'updated_at': updatedAt.toIso8601String(),
      'version': version,
    },
    retryCount: 0,
  );
}
