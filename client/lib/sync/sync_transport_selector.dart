import 'dart:async';

import '../domain/sync_mode.dart';
import 'sync_models.dart';
import 'sync_transport.dart';

typedef SyncGroupTransportFactory = Future<SyncTransport?> Function();

/// Selects the existing HTTP transport or the optional group transport.
///
/// The group factory is lazy so local/cloud startup never requires native
/// libraries or secure group storage to be present.
class SyncTransportSelector implements SyncTransport, SyncTransportLifecycle {
  SyncTransportSelector({
    required this.cloudTransport,
    required this.groupTransportFactory,
  });

  final SyncTransport cloudTransport;
  final SyncGroupTransportFactory groupTransportFactory;
  final _eventsController = StreamController<SyncTransportEvent>.broadcast();
  SyncMode _mode = SyncMode.cloud;
  SyncTransport? _active;
  StreamSubscription<SyncTransportEvent>? _eventsSubscription;
  bool _started = false;

  SyncMode get mode => _mode;

  Future<void> setMode(SyncMode mode) async {
    if (_mode == mode && (!_started || _active != null)) return;
    _mode = mode;
    if (!_started) return;
    await _activate();
  }

  @override
  Stream<SyncTransportEvent> get events => _eventsController.stream;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await _activate();
    } catch (_) {
      _started = false;
      rethrow;
    }
  }

  @override
  Future<PushSyncResult> push({
    required Uri serverUrl,
    required String token,
    required String deviceId,
    required String idempotencyKey,
    required List<PendingSyncChange> changes,
  }) => _requireActive().push(
    serverUrl: serverUrl,
    token: token,
    deviceId: deviceId,
    idempotencyKey: idempotencyKey,
    changes: changes,
  );

  @override
  Future<PullSyncPage> pull({
    required Uri serverUrl,
    required String token,
    String? cursor,
    int limit = 200,
  }) => _requireActive().pull(
    serverUrl: serverUrl,
    token: token,
    cursor: cursor,
    limit: limit,
  );

  @override
  Future<void> close() async {
    _started = false;
    await _closeActive();
    await _eventsController.close();
  }

  Future<void> _activate() async {
    await _closeActive();
    final next = _mode == SyncMode.group
        ? await groupTransportFactory()
        : cloudTransport;
    if (next == null) {
      throw const SyncTransportException(
        '同步组尚未配置或 native P2P bridge 不可用。',
        permanent: true,
      );
    }
    _active = next;
    if (next case final SyncTransportLifecycle lifecycle) {
      _eventsSubscription = lifecycle.events.listen(_eventsController.add);
      await lifecycle.start();
    }
  }

  Future<void> _closeActive() async {
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
    final active = _active;
    _active = null;
    if (active case final SyncTransportLifecycle lifecycle) {
      await lifecycle.close();
    }
  }

  SyncTransport _requireActive() {
    final active = _active;
    if (!_started || active == null) {
      throw const SyncTransportException(
        '同步 transport 尚未启动。',
        permanent: true,
      );
    }
    return active;
  }
}
