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
    'device id changes preserve and separately push older outbox batches',
    () async {
      repository.pending.add(
        PendingSyncChange(
          changeId: 'change_02',
          deviceId: 'renamed-device',
          entityType: 'item',
          entityId: 'item_02',
          operation: 'create',
          version: 1,
          updatedAt: DateTime.utc(2026, 8, 11, 9),
          payload: const {'id': 'item_02', 'version': 1},
          retryCount: 0,
        ),
      );
      transport.acceptAll = true;
      coordinator.configureDeviceId('renamed-device');

      await coordinator.synchronize();

      expect(transport.pushedDeviceIds, ['test-device', 'renamed-device']);
      expect(repository.pending, isEmpty);
    },
  );

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

  test('keeps rejected changes visible as a failed sync', () async {
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
    expect(coordinator.snapshot.phase, SyncPhase.failed);
    expect(coordinator.snapshot.message, contains('invalid item'));
  });

  test('manual sync retries cycle failures after a server upgrade', () async {
    repository.pending.clear();
    repository.retryablePermanentChange = _pendingChange(
      entityType: 'cycle_settings',
    );
    repository.permanentFailureMessage =
        'transport_rejected: entity_type is invalid';
    transport.acceptAll = true;

    await coordinator.synchronize(retryPermanentFailures: true);

    expect(repository.resetPermanentCalls, 1);
    expect(repository.retryablePermanentChange, isNull);
    expect(repository.pending, isEmpty);
    expect(transport.pushCalls, 1);
    expect(coordinator.snapshot.phase, SyncPhase.idle);
  });

  test(
    'reports failures while exposing remotely applied local changes',
    () async {
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
      transport.pullPages.add(
        PullSyncPage(
          cursor: 'cur_2',
          hasMore: false,
          changes: [_remoteChange()],
        ),
      );

      await coordinator.synchronize();

      expect(coordinator.snapshot.phase, SyncPhase.failed);
      expect(coordinator.snapshot.localDataChanged, isTrue);
      expect(repository.applied.single.changeId, 'remote_01');
    },
  );

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

  test('secure storage failure does not block local startup', () async {
    final failingTokenStore = _MemoryTokenStore(null)..readFails = true;
    final localCoordinator = SyncCoordinator(
      repository: repository,
      transport: transport,
      tokenStore: failingTokenStore,
      connectivityMonitor: connectivity,
      deviceId: 'test-device',
      retryLimit: 3,
    );

    await localCoordinator.start(
      enabled: false,
      serverUrl: 'https://sync.example.com',
    );

    expect(localCoordinator.snapshot.phase, SyncPhase.disabled);
    expect(localCoordinator.tokenConfigured, isFalse);
    localCoordinator.dispose();
  });
}

PendingSyncChange _pendingChange({
  int retryCount = 0,
  String entityType = 'item',
}) => PendingSyncChange(
  changeId: 'change_01',
  deviceId: 'test-device',
  entityType: entityType,
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
  int resetPermanentCalls = 0;
  PendingSyncChange? retryablePermanentChange;
  String? permanentFailureMessage;

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
    if (rejections.isNotEmpty) {
      permanentFailureMessage =
          '${rejections.first.code}: ${rejections.first.message}';
    }
    pending.removeWhere(
      (change) => rejections.any((value) => value.changeId == change.changeId),
    );
  }

  @override
  Future<int> resetRetryablePermanentFailures() async {
    resetPermanentCalls += 1;
    final change = retryablePermanentChange;
    if (change == null) return 0;
    pending.add(change);
    retryablePermanentChange = null;
    permanentFailureMessage = null;
    return 1;
  }

  @override
  Future<String?> loadPermanentFailureMessage() async =>
      permanentFailureMessage;

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
  bool acceptAll = false;
  final List<String> pushedDeviceIds = [];

  @override
  Future<PushSyncResult> push({
    required Uri serverUrl,
    required String token,
    required String deviceId,
    required String idempotencyKey,
    required List<PendingSyncChange> changes,
  }) async {
    pushCalls += 1;
    pushedDeviceIds.add(deviceId);
    if (pushError case final error?) throw error;
    if (acceptAll) {
      return PushSyncResult(
        accepted: changes.map((change) => change.changeId).toList(),
        rejected: const [],
      );
    }
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
  bool readFails = false;

  @override
  Future<String?> read() async {
    if (readFails) throw StateError('Keychain is unavailable');
    return value;
  }

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
