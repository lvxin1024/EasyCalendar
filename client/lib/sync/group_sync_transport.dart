import 'dart:async';

import 'sync_authority_engine.dart';
import 'sync_group.dart';
import 'sync_models.dart';
import 'sync_transport.dart';

abstract interface class SyncGroupPeer {
  Stream<SyncTransportEvent> get events;

  Future<void> connect({
    required SyncGroupProfile profile,
    required String deviceId,
    required String endpointId,
  });

  Future<PushSyncResult> push({
    required String deviceId,
    required String endpointId,
    required String idempotencyKey,
    required List<PendingSyncChange> changes,
  });

  Future<PullSyncPage> pull({
    required String deviceId,
    required String endpointId,
    String? cursor,
    int limit = 200,
  });

  Future<void> close();
}

class GroupSyncTransport implements SyncTransport, SyncTransportLifecycle {
  GroupSyncTransport({
    required this._peer,
    required this.profile,
    required this.deviceId,
    required this.endpointId,
  });

  final SyncGroupPeer _peer;
  final SyncGroupProfile profile;
  final String deviceId;
  final String endpointId;
  bool _started = false;

  @override
  Stream<SyncTransportEvent> get events => _peer.events;

  @override
  Future<void> start() async {
    if (_started) return;
    await _peer.connect(
      profile: profile,
      deviceId: deviceId,
      endpointId: endpointId,
    );
    _started = true;
  }

  @override
  Future<PushSyncResult> push({
    required Uri serverUrl,
    required String token,
    required String deviceId,
    required String idempotencyKey,
    required List<PendingSyncChange> changes,
  }) {
    _ensureStarted();
    if (deviceId != this.deviceId) {
      throw const SyncTransportException(
        'Group transport device ID does not match the configured endpoint.',
        permanent: true,
      );
    }
    return _peer.push(
      deviceId: deviceId,
      endpointId: endpointId,
      idempotencyKey: idempotencyKey,
      changes: changes,
    );
  }

  @override
  Future<PullSyncPage> pull({
    required Uri serverUrl,
    required String token,
    String? cursor,
    int limit = 200,
  }) {
    _ensureStarted();
    return _peer.pull(
      deviceId: deviceId,
      endpointId: endpointId,
      cursor: cursor,
      limit: limit,
    );
  }

  @override
  Future<void> close() async {
    if (!_started) return;
    _started = false;
    await _peer.close();
  }

  void _ensureStarted() {
    if (!_started) {
      throw const SyncTransportException(
        'Group transport has not been started.',
        permanent: true,
      );
    }
  }
}

class SyncGroupNotificationHub {
  final _controller = StreamController<SyncTransportEvent>.broadcast();

  Stream<SyncTransportEvent> get events => _controller.stream;

  void publish(SyncTransportEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  Future<void> close() => _controller.close();
}

class AuthoritySyncGroupPeer implements SyncGroupPeer {
  AuthoritySyncGroupPeer({
    required this.authority,
    SyncGroupNotificationHub? notifications,
  }) : _notifications = notifications ?? SyncGroupNotificationHub();

  final SyncAuthorityEngine authority;
  final SyncGroupNotificationHub _notifications;
  bool _connected = false;
  String? _deviceId;
  String? _endpointId;

  @override
  Stream<SyncTransportEvent> get events => _notifications.events;

  @override
  Future<void> connect({
    required SyncGroupProfile profile,
    required String deviceId,
    required String endpointId,
  }) async {
    if (profile.protocolVersion != 1) {
      throw const SyncTransportException(
        'Unsupported sync group protocol.',
        permanent: true,
      );
    }
    final member = await authority.store.findMember(
      deviceId: deviceId,
      endpointId: endpointId,
    );
    if (member == null) {
      _notifications.publish(
        const SyncTransportEvent(
          kind: SyncTransportEventKind.authenticationFailed,
          message: 'Device is not an active sync group member.',
        ),
      );
      throw const SyncTransportException(
        'Device is not an active sync group member.',
        permanent: true,
      );
    }
    _connected = true;
    _deviceId = deviceId;
    _endpointId = endpointId;
    _notifications.publish(
      const SyncTransportEvent(kind: SyncTransportEventKind.connected),
    );
  }

  @override
  Future<PushSyncResult> push({
    required String deviceId,
    required String endpointId,
    required String idempotencyKey,
    required List<PendingSyncChange> changes,
  }) async {
    _ensureConnected(deviceId, endpointId);
    final result = await authority.push(
      deviceId: deviceId,
      endpointId: endpointId,
      idempotencyKey: idempotencyKey,
      changes: changes,
    );
    if (result.accepted.isNotEmpty && result.serverCursor != null) {
      _notifications.publish(
        SyncTransportEvent(
          kind: SyncTransportEventKind.changesAvailable,
          cursor: result.serverCursor,
        ),
      );
    }
    return result;
  }

  @override
  Future<PullSyncPage> pull({
    required String deviceId,
    required String endpointId,
    String? cursor,
    int limit = 200,
  }) {
    _ensureConnected(deviceId, endpointId);
    return authority.pull(
      deviceId: deviceId,
      endpointId: endpointId,
      cursor: cursor,
      limit: limit,
    );
  }

  @override
  Future<void> close() async {
    if (!_connected) return;
    _connected = false;
    _notifications.publish(
      const SyncTransportEvent(kind: SyncTransportEventKind.disconnected),
    );
    _deviceId = null;
    _endpointId = null;
  }

  void _ensureConnected(String deviceId, String endpointId) {
    if (!_connected || deviceId != _deviceId || endpointId != _endpointId) {
      throw const SyncTransportException('Primary endpoint is unavailable.');
    }
  }
}
