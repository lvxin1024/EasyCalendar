import 'dart:async';

import 'sync_authority.dart';
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
    required String displayName,
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
    String? displayName,
    this.deviceIdProvider,
    this.endpointIdProvider,
    this.displayNameProvider,
  }) : displayName = displayName ?? deviceId;

  final SyncGroupPeer _peer;
  final SyncGroupProfile profile;
  final String deviceId;
  final String endpointId;
  final String displayName;
  final String Function()? deviceIdProvider;
  final String Function()? endpointIdProvider;
  final String Function()? displayNameProvider;
  bool _started = false;
  String? _connectedDeviceId;
  String? _connectedEndpointId;

  @override
  Stream<SyncTransportEvent> get events => _peer.events;

  @override
  Future<void> start() async {
    if (_started) return;
    final currentDeviceId = _currentDeviceId;
    final currentEndpointId = _currentEndpointId;
    await _peer.connect(
      profile: profile,
      deviceId: currentDeviceId,
      endpointId: currentEndpointId,
      displayName: _currentDisplayName,
    );
    _started = true;
    _connectedDeviceId = currentDeviceId;
    _connectedEndpointId = currentEndpointId;
  }

  @override
  Future<PushSyncResult> push({
    required Uri serverUrl,
    required String token,
    required String deviceId,
    required String idempotencyKey,
    required List<PendingSyncChange> changes,
  }) async {
    await _ensureCurrentConnection();
    if (deviceId != _currentDeviceId) {
      throw const SyncTransportException(
        'Group transport device ID does not match the configured endpoint.',
        permanent: true,
      );
    }
    return _peer.push(
      deviceId: deviceId,
      endpointId: _currentEndpointId,
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
  }) async {
    await _ensureCurrentConnection();
    return _peer.pull(
      deviceId: _currentDeviceId,
      endpointId: _currentEndpointId,
      cursor: cursor,
      limit: limit,
    );
  }

  @override
  Future<void> close() async {
    if (!_started) return;
    _started = false;
    _connectedDeviceId = null;
    _connectedEndpointId = null;
    await _peer.close();
  }

  String get _currentDeviceId => deviceIdProvider?.call() ?? deviceId;

  String get _currentEndpointId => endpointIdProvider?.call() ?? endpointId;

  String get _currentDisplayName =>
      displayNameProvider?.call() ?? displayName;

  Future<void> _ensureCurrentConnection() async {
    if (!_started) {
      throw const SyncTransportException(
        'Group transport has not been started.',
        permanent: true,
      );
    }
    if (_connectedDeviceId == _currentDeviceId &&
        _connectedEndpointId == _currentEndpointId) {
      return;
    }
    await close();
    await start();
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
    required String displayName,
  }) async {
    if (profile.protocolVersion != 1) {
      throw const SyncTransportException(
        'Unsupported sync group protocol.',
        permanent: true,
      );
    }
    try {
      if (profile.role == SyncGroupRole.primary) {
        if (endpointId != profile.primaryEndpointId ||
            deviceId != authority.primaryDeviceId) {
          throw const SyncTransportException(
            'Primary endpoint identity does not match the sync group.',
            permanent: true,
          );
        }
      }
      if (profile.role == SyncGroupRole.primary) {
        await authority.establishGroup(profile.groupId);
      } else {
        await authority.verifyGroup(profile.groupId);
      }
      await authority.registerMember(
        groupId: profile.groupId,
        deviceId: deviceId,
        endpointId: endpointId,
        displayName: displayName,
      );
    } on SyncAuthorityException catch (error) {
      _notifications.publish(
        SyncTransportEvent(
          kind: error.code == 'member_revoked'
              ? SyncTransportEventKind.authenticationFailed
              : SyncTransportEventKind.error,
          message: error.message,
        ),
      );
      throw SyncTransportException(error.message, permanent: true);
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
