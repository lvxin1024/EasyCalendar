import 'dart:async';

import 'package:easy_calendar/domain/sync_mode.dart';
import 'package:easy_calendar/sync/sync_models.dart';
import 'package:easy_calendar/sync/sync_transport.dart';
import 'package:easy_calendar/sync/sync_transport_selector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starts with cloud transport and switches lifecycle transports by mode', () async {
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
  });

  test('reports a permanent error when group mode has no configured transport', () async {
    final selector = SyncTransportSelector(
      cloudTransport: _RecordingTransport(),
      groupTransportFactory: () async => null,
    );

    await selector.start();
    await expectLater(
      selector.setMode(SyncMode.group),
      throwsA(
        isA<SyncTransportException>().having(
          (error) => error.permanent,
          'permanent',
          isTrue,
        ),
      ),
    );
    await selector.close();
  });
}

class _RecordingTransport implements SyncTransport, SyncTransportLifecycle {
  final _events = StreamController<SyncTransportEvent>.broadcast();
  int startCount = 0;
  int closeCount = 0;

  @override
  Stream<SyncTransportEvent> get events => _events.stream;

  @override
  Future<void> start() async => startCount++;

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
  }) async => const PushSyncResult(accepted: [], rejected: []);

  @override
  Future<PullSyncPage> pull({
    required Uri serverUrl,
    required String token,
    String? cursor,
    int limit = 200,
  }) async => const PullSyncPage(cursor: '0', hasMore: false, changes: []);
}
