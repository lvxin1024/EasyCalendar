import 'dart:async';

import 'package:easy_calendar/sync/connectivity_monitor.dart';
import 'package:easy_calendar/sync/sync_coordinator.dart';
import 'package:easy_calendar/sync/sync_models.dart';
import 'package:easy_calendar/sync/sync_repository.dart';
import 'package:easy_calendar/sync/sync_transport.dart';
import 'package:easy_calendar/sync/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _MemorySyncRepository repository;
  late _FakeTransport transport;
  late _MemoryTokenStore tokenStore;
  late _FakeConnectivityMonitor connectivity;
  late SyncCoordinator coordinator;

  setUp(() async {
    repository = _MemorySyncRepository()..pending.add(_pendingChange());
    transport = _FakeTransport();
    tokenStore = _MemoryTokenStore(
      'a-secure-token-with-at-least-32-characters',
    );
    connectivity = _FakeConnectivityMonitor();
    coordinator = SyncCoordinator(
      repository: repository,
      transport: transport,
      tokenStore: tokenStore,
      connectivityMonitor: connectivity,
      deviceId: 'test-device',
      retryLimit: 3,
      clock: () => DateTime.utc(2026, 8, 11, 8),
    );
    await coordinator.start(
      enabled: false,
      serverUrl: 'https://sync.example.com',
    );
    coordinator.configure(enabled: true, serverUrl: 'https://sync.example.com');
  });

  tearDown(() {
    coordinator.dispose();
    connectivity.close();
  });

  test('pushes the outbox, applies pull, and advances the cursor', () async {
    transport.pushResult = const PushSyncResult(
      accepted: ['change_01'],
      rejected: [],
    );
    transport.pullPages.add(
      PullSyncPage(cursor: 'cur_2', hasMore: false, changes: [_remoteChange()]),
    );

    await coordinator.synchronize();

    expect(repository.pending, isEmpty);
    expect(repository.applied.single.changeId, 'remote_01');
    expect(repository.cursor, 'cur_2');
    expect(coordinator.snapshot.phase, SyncPhase.idle);
    expect(transport.pushCalls, 1);
    expect(transport.pullCalls, 1);
  });

  test(
    'records exponential backoff after a transient transport failure',
    () async {
      transport.pushError = const SyncTransportException('offline');

      await coordinator.synchronize();

      expect(repository.transientFailures, 1);
      expect(repository.pending.single.retryCount, 1);
      expect(coordinator.snapshot.phase, SyncPhase.backoff);
      expect(
        coordinator.snapshot.nextRetryAt,
        DateTime.utc(2026, 8, 11, 8, 0, 4),
      );
    },
  );

  test('marks rejected changes permanent and does not retry them', () async {
    transport.pushResult = const PushSyncResult(
      accepted: [],
      rejected: [
        SyncRejection(
          changeId: 'change_01',
          code: 'constraint_violation',
          message: 'invalid item',
        ),
      ],
    );

    await coordinator.synchronize();

    expect(repository.pending, isEmpty);
    expect(repository.permanentFailures, ['change_01']);
    expect(transport.pushCalls, 1);
    expect(coordinator.snapshot.phase, SyncPhase.idle);
  });

  test(
    'network recovery clears backoff and triggers synchronization',
    () async {
      repository.pending.clear();
      transport.pullPages.add(
        const PullSyncPage(cursor: 'cur_0', hasMore: false, changes: []),
      );

      connectivity.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(repository.resetCalls, 1);
      expect(transport.pullCalls, 1);
    },
  );
}

PendingSyncChange _pendingChange({int retryCount = 0}) => PendingSyncChange(
  changeId: 'change_01',
  deviceId: 'test-device',
  entityType: 'item',
  entityId: 'item_01',
  operation: 'create',
  version: 1,
  updatedAt: DateTime.utc(2026, 8, 11, 8),
  payload: {
    'id': 'item_01',
    'collection_id': 'collection_local',
    'type': 'task',
    'title': 'Sync me',
    'updated_at': '2026-08-11T08:00:00.000Z',
    'version': 1,
  },
  retryCount: retryCount,
);

RemoteSyncChange _remoteChange() => RemoteSyncChange(
  changeId: 'remote_01',
  deviceId: 'other-device',
  entityType: 'item',
  entityId: 'item_02',
  operation: 'create',
  version: 1,
  updatedAt: DateTime.utc(2026, 8, 11, 8),
  payload: const {'id': 'item_02', 'version': 1},
);

class _MemorySyncRepository implements SyncRepository {
  final List<PendingSyncChange> pending = [];
  final List<RemoteSyncChange> applied = [];
  final List<String> permanentFailures = [];
  final List<SyncConflictSummary> pushConflicts = [];
  String? cursor;
  int transientFailures = 0;
  int resetCalls = 0;

  @override
  Future<List<PendingSyncChange>> listPendingChanges({
    required DateTime now,
    int limit = 200,
  }) async => pending.take(limit).toList();

  @override
  Future<void> removeAcceptedChanges(List<String> changeIds) async {
    pending.removeWhere((change) => changeIds.contains(change.changeId));
  }

  @override
  Future<void> recordPermanentFailures(List<SyncRejection> rejections) async {
    permanentFailures.addAll(rejections.map((value) => value.changeId));
    pending.removeWhere(
      (change) => rejections.any((value) => value.changeId == change.changeId),
    );
  }

  @override
  Future<void> applyPushConflicts(List<SyncConflictSummary> conflicts) async {
    pushConflicts.addAll(conflicts);
  }

  @override
  Future<DateTime?> recordTransientFailure(
    List<String> changeIds,
    String error, {
    required DateTime now,
    required int retryLimit,
  }) async {
    transientFailures += 1;
    for (var index = 0; index < pending.length; index += 1) {
      final change = pending[index];
      if (changeIds.contains(change.changeId)) {
        pending[index] = _pendingChange(retryCount: change.retryCount + 1);
      }
    }
    return now.add(const Duration(seconds: 4));
  }

  @override
  Future<void> resetTransientBackoff() async {
    resetCalls += 1;
  }

  @override
  Future<String?> loadRemoteCursor() async => cursor;

  @override
  Future<void> applyRemoteBatch(
    List<RemoteSyncChange> changes,
    String nextCursor,
  ) async {
    applied.addAll(changes);
    cursor = nextCursor;
  }

  @override
  Future<List<SyncConflictRecord>> listSyncConflicts({int limit = 100}) async =>
      const [];
}

class _FakeTransport implements SyncTransport {
  PushSyncResult pushResult = const PushSyncResult(accepted: [], rejected: []);
  final List<PullSyncPage> pullPages = [];
  SyncTransportException? pushError;
  int pushCalls = 0;
  int pullCalls = 0;

  @override
  Future<PushSyncResult> push({
    required Uri serverUrl,
    required String token,
    required String deviceId,
    required String idempotencyKey,
    required List<PendingSyncChange> changes,
  }) async {
    pushCalls += 1;
    if (pushError case final error?) throw error;
    return pushResult;
  }

  @override
  Future<PullSyncPage> pull({
    required Uri serverUrl,
    required String token,
    String? cursor,
    int limit = 200,
  }) async {
    pullCalls += 1;
    return pullPages.isEmpty
        ? PullSyncPage(
            cursor: cursor ?? 'cur_0',
            hasMore: false,
            changes: const [],
          )
        : pullPages.removeAt(0);
  }
}

class _MemoryTokenStore implements SyncTokenStore {
  _MemoryTokenStore(this.value);

  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String token) async => value = token;

  @override
  Future<void> clear() async => value = null;
}

class _FakeConnectivityMonitor implements ConnectivityMonitor {
  final _controller = StreamController<bool>.broadcast();

  @override
  Stream<bool> get onlineChanges => _controller.stream;

  void add(bool online) => _controller.add(online);

  void close() => _controller.close();
}
