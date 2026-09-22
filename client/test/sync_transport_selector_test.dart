import 'dart:async';

import 'package:easy_calendar/domain/sync_mode.dart';
import 'package:easy_calendar/sync/sync_models.dart';
import 'package:easy_calendar/sync/sync_transport.dart';
import 'package:easy_calendar/sync/sync_transport_selector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final mode in [SyncMode.group, SyncMode.cloud]) {
    for (final failPush in [true, false]) {
      test(
        '$mode retries ${failPush ? 'push' : 'pull'} after failure',
        () async {
          final cloud = _RecordingTransport();
          final groups = <_RecordingTransport>[];
          final selector = SyncTransportSelector(
            cloudTransport: cloud,
            groupTransportFactory: () async {
              final group = _RecordingTransport();
              groups.add(group);
              return group;
            },
          );
          addTearDown(selector.close);
          await selector.setMode(mode);
          await selector.start();
          final failed = mode == SyncMode.group ? groups.single : cloud;
          failed.requestError = const SyncTransportException('connection lost');

          Future<Object> request() => failPush
              ? selector.push(
                  serverUrl: Uri.parse('group://primary'),
                  token: '',
                  deviceId: 'device',
                  idempotencyKey: 'retry-key',
                  changes: const [],
                )
              : selector.pull(
                  serverUrl: Uri.parse('group://primary'),
                  token: '',
                );

          await expectLater(request(), throwsA(isA<SyncTransportException>()));
          expect(failed.closeCount, mode == SyncMode.group ? 1 : 0);
          await request();
          if (mode == SyncMode.group) {
            expect(groups, hasLength(2));
            expect(groups.last.startCount, 1);
          } else {
            expect(cloud.startCount, 1);
          }
        },
      );
    }
  }

  test(
    'starts with cloud transport and switches lifecycle transports by mode',
    () async {
      final cloud = _RecordingTransport();
      final group = _RecordingTransport();
      final selector = SyncTransportSelector(
        cloudTransport: cloud,
        groupTransportFactory: () async => group,
      );

      await selector.start();
      expect(cloud.startCount, 1);
      expect(group.startCount, 0);

      await selector.setMode(SyncMode.group);
      expect(cloud.closeCount, 1);
      expect(group.startCount, 1);

      await selector.setMode(SyncMode.cloud);
      expect(group.closeCount, 1);
      expect(cloud.startCount, 2);

      await selector.close();
      expect(cloud.closeCount, 2);
    },
  );

  test(
    'keeps the selector usable when group transport is temporarily unavailable',
    () async {
      final selector = SyncTransportSelector(
        cloudTransport: _RecordingTransport(),
        groupTransportFactory: () async => null,
      );
      final event = selector.events.first;

      await selector.start();
      await selector.setMode(SyncMode.group);

      expect((await event).message, '同步组尚未配置或 native P2P bridge 不可用。');
      await expectLater(
        selector.pull(serverUrl: Uri.parse('group://primary'), token: ''),
        throwsA(
          isA<SyncTransportException>().having(
            (error) => error.permanent,
            'permanent',
            isTrue,
          ),
        ),
      );
      await selector.close();
    },
  );

  test('waits for a mode switch before exposing the new transport', () async {
    final cloud = _RecordingTransport();
    final group = _RecordingTransport(
      startDelay: const Duration(milliseconds: 20),
    );
    final selector = SyncTransportSelector(
      cloudTransport: cloud,
      groupTransportFactory: () async => group,
    );

    await selector.start();
    final switching = selector.setMode(SyncMode.group);
    expect(group.startCount, 0);
    await switching;

    expect(group.startCount, 1);
    await selector.push(
      serverUrl: Uri.parse('group://primary'),
      token: '',
      deviceId: 'device',
      idempotencyKey: 'key',
      changes: const [],
    );
    await selector.close();
  });
}

class _RecordingTransport implements SyncTransport, SyncTransportLifecycle {
  _RecordingTransport({this.startDelay = Duration.zero});

  final Duration startDelay;
  final _events = StreamController<SyncTransportEvent>.broadcast();
  int startCount = 0;
  int closeCount = 0;
  SyncTransportException? requestError;

  void _checkRequest() {
    final error = requestError;
    requestError = null;
    if (error != null) throw error;
  }

  @override
  Stream<SyncTransportEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    if (startDelay > Duration.zero) await Future<void>.delayed(startDelay);
    startCount++;
  }

  @override
  Future<void> close() async {
    closeCount++;
    await _events.close();
  }

  @override
  Future<PushSyncResult> push({
    required Uri serverUrl,
    required String token,
    required String deviceId,
    required String idempotencyKey,
    required List<PendingSyncChange> changes,
  }) async {
    _checkRequest();
    return const PushSyncResult(accepted: [], rejected: []);
  }

  @override
  Future<PullSyncPage> pull({
    required Uri serverUrl,
    required String token,
    String? cursor,
    int limit = 200,
  }) async {
    _checkRequest();
    return const PullSyncPage(cursor: '0', hasMore: false, changes: []);
  }
}
