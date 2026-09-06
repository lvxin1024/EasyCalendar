import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/data/local_item_repository.dart';
import 'package:easy_calendar/sync/group_sync_transport.dart';
import 'package:easy_calendar/sync/sync_authority.dart';
import 'package:easy_calendar/sync/sync_authority_engine.dart';
import 'package:easy_calendar/sync/sync_group.dart';
import 'package:easy_calendar/sync/sync_models.dart';
import 'package:easy_calendar/sync/sync_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late LocalItemRepository repository;
  late SyncAuthorityStore store;
  late SyncAuthorityEngine authority;
  late SyncGroupProfile primaryProfile;
  late SyncGroupProfile replicaProfile;
  late SyncGroupNotificationHub hub;

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
        databaseName: 'group-transport.sqlite3',
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
    authority = SyncAuthorityEngine(store, primaryDeviceId: 'primary-device');
    await store.upsertMember(
      SyncAuthorityMember(
        endpointId: 'endpoint-primary',
        deviceId: 'primary-device',
        displayName: '主节点',
        status: 'active',
        joinedAt: DateTime.utc(2026, 9, 6),
      ),
    );
    await store.upsertMember(
      SyncAuthorityMember(
        endpointId: 'endpoint-phone',
        deviceId: 'phone-device',
        displayName: '手机',
        status: 'active',
        joinedAt: DateTime.utc(2026, 9, 6),
      ),
    );
    primaryProfile = SyncGroupProfile.createPrimary(
      primaryEndpointId: 'endpoint-primary',
      endpointTicket: 'ticket-primary',
    );
    replicaProfile = SyncGroupProfile.fromSecret(
      groupSecret: primaryProfile.groupSecret,
      role: SyncGroupRole.replica,
      primaryEndpointId: primaryProfile.primaryEndpointId,
      endpointTicket: primaryProfile.endpointTicket,
    );
    hub = SyncGroupNotificationHub();
  });

  tearDown(() async {
    await hub.close();
    await repository.close();
  });

  test('group transport broadcasts changes and pulls by cursor', () async {
    final phone = GroupSyncTransport(
      peer: AuthoritySyncGroupPeer(authority: authority, notifications: hub),
      profile: replicaProfile,
      deviceId: 'phone-device',
      endpointId: 'endpoint-phone',
    );
    final primary = GroupSyncTransport(
      peer: AuthoritySyncGroupPeer(authority: authority, notifications: hub),
      profile: primaryProfile,
      deviceId: 'primary-device',
      endpointId: 'endpoint-primary',
    );
    final events = <SyncTransportEvent>[];
    final subscription = phone.events.listen(events.add);

    await phone.start();
    await primary.start();
    final change = _change();
    final result = await primary.push(
      serverUrl: Uri.parse('group://primary'),
      token: '',
      deviceId: 'primary-device',
      idempotencyKey: 'primary-push-1',
      changes: [change],
    );
    await Future<void>.delayed(Duration.zero);

    final page = await phone.pull(
      serverUrl: Uri.parse('group://primary'),
      token: '',
    );
    expect(result.accepted, ['primary-change-1']);
    expect(
      events.map((event) => event.kind),
      containsAll([
        SyncTransportEventKind.connected,
        SyncTransportEventKind.changesAvailable,
      ]),
    );
    expect(
      events
          .singleWhere(
            (event) => event.kind == SyncTransportEventKind.changesAvailable,
          )
          .cursor,
      'cur_1',
    );
    expect(page.cursor, 'cur_1');
    expect(page.changes.single.changeId, 'primary-change-1');

    await primary.close();
    await phone.close();
    await subscription.cancel();
  });

  test(
    'group transport rejects calls before start and emits disconnect',
    () async {
      final transport = GroupSyncTransport(
        peer: AuthoritySyncGroupPeer(authority: authority, notifications: hub),
        profile: replicaProfile,
        deviceId: 'phone-device',
        endpointId: 'endpoint-phone',
      );
      final events = <SyncTransportEvent>[];
      final subscription = transport.events.listen(events.add);

      expect(
        () =>
            transport.pull(serverUrl: Uri.parse('group://primary'), token: ''),
        throwsA(isA<SyncTransportException>()),
      );
      await transport.start();
      await transport.close();
      await Future<void>.delayed(Duration.zero);

      expect(events.map((event) => event.kind), [
        SyncTransportEventKind.connected,
        SyncTransportEventKind.disconnected,
      ]);
      await subscription.cancel();
    },
  );
}

PendingSyncChange _change() {
  final updatedAt = DateTime.utc(2026, 9, 6, 1);
  return PendingSyncChange(
    changeId: 'primary-change-1',
    deviceId: 'primary-device',
    entityType: 'item',
    entityId: 'item-1',
    operation: 'update',
    version: 1,
    updatedAt: updatedAt,
    payload: {
      'id': 'item-1',
      'collection_id': 'collection_local',
      'type': 'task',
      'updated_at': updatedAt.toIso8601String(),
      'version': 1,
    },
    retryCount: 0,
  );
}
