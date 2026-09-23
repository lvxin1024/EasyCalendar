import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/data/local_item_repository.dart';
import 'package:easy_calendar/sync/group_sync_transport.dart';
import 'package:easy_calendar/sync/iroh_group_sync_peer.dart';
import 'package:easy_calendar/sync/p2p_bridge.dart';
import 'package:easy_calendar/sync/sync_authority.dart';
import 'package:easy_calendar/sync/sync_authority_engine.dart';
import 'package:easy_calendar/sync/sync_group.dart';
import 'package:easy_calendar/sync/sync_models.dart';
import 'package:easy_calendar/sync/sync_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Opt in with EASYCALENDAR_NATIVE_TEST=1 and put the compiled native library
// on DYLD_LIBRARY_PATH (macOS), LD_LIBRARY_PATH (Linux), or PATH (Windows).
// Ticket discovery uses Iroh's public relay, so this also requires networking.
void main() {
  test(
    'native peers authenticate and keep serving while another replica is idle',
    () async {
      sqfliteFfiInit();
      final repository = LocalItemRepository(
        const AppConfig(
          appName: 'EasyCalendar',
          locale: Locale('zh', 'CN'),
          timezone: 'Asia/Shanghai',
          defaultCollectionId: 'collection_local',
          defaultCollectionName: '我的日程',
          defaultCollectionColor: Color(0xFF2563EB),
          databaseName: 'iroh-native-test.sqlite3',
          deviceId: 'primary-device',
          apiUrl: 'http://localhost:8000',
          syncEnabled: false,
          syncRetryLimit: 8,
          notificationsEnabled: false,
        ),
        databaseFactory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      addTearDown(repository.close);
      final authority = SyncAuthorityEngine(
        SyncAuthorityStore(await repository.openSharedDatabase()),
        primaryDeviceId: 'primary-device',
      );
      final primaryBridge = IsolateP2pBridge();
      addTearDown(primaryBridge.close);
      final primarySecret = _secret();
      final provisional = SyncGroupProfile.createPrimary(
        primaryEndpointId: 'pending-primary',
        endpointTicket: 'pending',
      );
      await primaryBridge.start(
        endpointId: provisional.primaryEndpointId,
        groupId: provisional.groupId,
        endpointSecret: primarySecret,
      );
      final primaryEndpointId = await primaryBridge.endpointId();
      final profile = SyncGroupProfile.fromSecret(
        groupSecret: provisional.groupSecret,
        role: SyncGroupRole.primary,
        primaryEndpointId: primaryEndpointId,
        endpointTicket: await primaryBridge.exportTicket(),
      );
      final primary = GroupSyncTransport(
        peer: IrohSyncGroupPeer(
          bridge: primaryBridge,
          endpointSecret: primarySecret,
          authority: authority,
        ),
        profile: profile,
        deviceId: 'primary-device',
        endpointId: primaryEndpointId,
      );
      addTearDown(primary.close);
      await primary.start();

      Future<GroupSyncTransport> startReplica(String deviceId) async {
        final bridge = IsolateP2pBridge();
        addTearDown(bridge.close);
        final secret = _secret();
        await bridge.start(
          endpointId: deviceId,
          groupId: profile.groupId,
          endpointSecret: secret,
        );
        final replica = GroupSyncTransport(
          peer: IrohSyncGroupPeer(bridge: bridge, endpointSecret: secret),
          profile: SyncGroupProfile.fromSecret(
            groupSecret: profile.groupSecret,
            role: SyncGroupRole.replica,
            primaryEndpointId: profile.primaryEndpointId,
            endpointTicket: profile.endpointTicket,
          ),
          deviceId: deviceId,
          endpointId: await bridge.endpointId(),
        );
        addTearDown(replica.close);
        await replica.start();
        return replica;
      }

      final serverUrl = Uri.parse('group://primary');
      final first = await startReplica('first-device');
      final firstPush = await first.push(
        serverUrl: serverUrl,
        token: '',
        deviceId: 'first-device',
        idempotencyKey: 'native-push-1',
        changes: [_change('first-device', 1)],
      );
      expect(firstPush.accepted, ['native-change-1']);
      expect(firstPush.rejected, isEmpty);
      final initial = await first.pull(serverUrl: serverUrl, token: '');
      expect(initial.changes.single.changeId, 'native-change-1');
      expect(initial.hasMore, isFalse);

      // The primary now waits for another request from the idle first replica.
      // That wait must yield its native worker so a second peer can authenticate.
      final second = await startReplica('second-device');
      final secondInitial = await second.pull(serverUrl: serverUrl, token: '');
      expect(secondInitial.changes.single.changeId, 'native-change-1');
      expect(secondInitial.cursor, initial.cursor);
      var cursor = initial.cursor;

      for (var version = 2; version <= 4; version++) {
        final pushed = await second.push(
          serverUrl: serverUrl,
          token: '',
          deviceId: 'second-device',
          idempotencyKey: 'native-push-$version',
          changes: [_change('second-device', version)],
        );
        expect(pushed.accepted, ['native-change-$version']);
        expect(pushed.rejected, isEmpty);
        for (final replica in [second, first]) {
          final page = await replica.pull(
            serverUrl: serverUrl,
            token: '',
            cursor: cursor,
          );
          expect(page.changes.single.changeId, 'native-change-$version');
          expect(page.changes.single.version, version);
          expect(page.cursor, 'cur_$version');
          expect(page.hasMore, isFalse);
        }
        cursor = 'cur_$version';
      }

      for (final replica in [first, second]) {
        await expectLater(
          replica.pull(
            serverUrl: serverUrl,
            token: '',
            cursor: 'invalid-cursor',
          ),
          throwsA(isA<SyncTransportException>().having(
            (error) => error.permanent,
            'permanent rejection',
            isTrue,
          )),
        );
        final page = await replica.pull(
          serverUrl: serverUrl,
          token: '',
          cursor: cursor,
        );
        expect(page.changes, isEmpty);
        expect(page.cursor, cursor);
        expect(page.hasMore, isFalse);
      }
    },
    skip: Platform.environment['EASYCALENDAR_NATIVE_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

PendingSyncChange _change(String deviceId, int version) {
  final updatedAt = DateTime.utc(2026, 9, 22, 8, 0, version);
  return PendingSyncChange(
    changeId: 'native-change-$version',
    deviceId: deviceId,
    entityType: 'item',
    entityId: 'native-item',
    operation: version == 1 ? 'create' : 'update',
    version: version,
    updatedAt: updatedAt,
    retryCount: 0,
    payload: {
      'id': 'native-item',
      'version': version,
      'updated_at': updatedAt.toIso8601String(),
      'collection_id': 'collection_local',
      'type': 'note',
    },
  );
}

String _secret() {
  final random = Random.secure();
  return base64Url
      .encode(List<int>.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}
