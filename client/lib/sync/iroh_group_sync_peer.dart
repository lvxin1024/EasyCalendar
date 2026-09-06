import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'group_sync_transport.dart';
import 'p2p_bridge.dart';
import 'sync_authority_engine.dart';
import 'sync_group.dart';
import 'sync_models.dart';
import 'sync_transport.dart';

enum _GroupFrameKind {
  hello(1),
  authChallenge(2),
  authResponse(3),
  push(4),
  pushResult(5),
  pull(6),
  pullResult(7),
  changesAvailable(8),
  error(255);

  const _GroupFrameKind(this.code);

  final int code;

  static _GroupFrameKind fromCode(int code) => _GroupFrameKind.values
      .firstWhere((kind) => kind.code == code, orElse: () => error);
}

class _GroupFrame {
  const _GroupFrame({required this.kind, required this.payload});

  final _GroupFrameKind kind;
  final Map<String, Object?> payload;
}

/// Iroh-backed implementation of the existing group transport contract.
///
/// The native bridge owns QUIC and relay details. This class only translates
/// existing authority requests into bounded JSON frames and keeps cursor
/// semantics in the Dart authority engine.
class IrohSyncGroupPeer implements SyncGroupPeer {
  IrohSyncGroupPeer({
    required this.bridge,
    required this.endpointSecret,
    this.authority,
    SyncGroupNotificationHub? notifications,
    Random? random,
  }) : _notifications = notifications ?? SyncGroupNotificationHub(),
       _random = random ?? Random.secure();

  final P2pBridge bridge;
  final String endpointSecret;
  final SyncAuthorityEngine? authority;
  final SyncGroupNotificationHub _notifications;
  final Random _random;
  final Map<int, _ServerConnection> _serverConnections = {};
  Timer? _acceptTimer;
  bool _accepting = false;
  bool _connected = false;
  bool _primary = false;
  String? _activeGroupId;
  String? _activeGroupSecret;
  String? _deviceId;
  String? _endpointId;
  int? _primaryConnection;

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
    _activeGroupId = profile.groupId;
    _activeGroupSecret = profile.groupSecret;
    await bridge.start(
      endpointId: endpointId,
      groupId: profile.groupId,
      endpointSecret: endpointSecret,
    );
    final actualEndpointId = await bridge.endpointId();
    if (profile.role == SyncGroupRole.primary) {
      await _startPrimary(
        profile: profile,
        deviceId: deviceId,
        endpointId: actualEndpointId,
        displayName: displayName,
      );
    } else {
      await _startReplica(
        profile: profile,
        deviceId: deviceId,
        endpointId: actualEndpointId,
        displayName: displayName,
      );
    }
    _connected = true;
    _deviceId = deviceId;
    _endpointId = actualEndpointId;
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
    if (_primary) {
      final result = await _authority.push(
        deviceId: deviceId,
        endpointId: endpointId,
        idempotencyKey: idempotencyKey,
        changes: changes,
      );
      _publishAccepted(result);
      return result;
    }
    final response = await _request(
      connectionId: _primaryConnection!,
      frame: _frame(
        _GroupFrameKind.push,
        {
          'device_id': deviceId,
          'endpoint_id': endpointId,
          'idempotency_key': idempotencyKey,
          'changes': changes.map((change) => change.toJson()).toList(),
        },
      ),
    );
    if (response.kind != _GroupFrameKind.pushResult) {
      throw _remoteError(response);
    }
    final result = _pushResultFromJson(response.payload);
    _publishAccepted(result);
    return result;
  }

  @override
  Future<PullSyncPage> pull({
    required String deviceId,
    required String endpointId,
    String? cursor,
    int limit = 200,
  }) async {
    _ensureConnected(deviceId, endpointId);
    if (_primary) {
      return _authority.pull(
        deviceId: deviceId,
        endpointId: endpointId,
        cursor: cursor,
        limit: limit,
      );
    }
    final response = await _request(
      connectionId: _primaryConnection!,
      frame: _frame(
        _GroupFrameKind.pull,
        {
          'device_id': deviceId,
          'endpoint_id': endpointId,
          'cursor': cursor,
          'limit': limit,
        },
      ),
    );
    if (response.kind != _GroupFrameKind.pullResult) {
      throw _remoteError(response);
    }
    return _pullPageFromJson(response.payload);
  }

  @override
  Future<void> close() async {
    _acceptTimer?.cancel();
    _acceptTimer = null;
    _serverConnections.clear();
    _primaryConnection = null;
    final wasConnected = _connected;
    _connected = false;
    await bridge.close();
    if (wasConnected) {
      _notifications.publish(
        const SyncTransportEvent(kind: SyncTransportEventKind.disconnected),
      );
    }
  }

  Future<void> _startPrimary({
    required SyncGroupProfile profile,
    required String deviceId,
    required String endpointId,
    required String displayName,
  }) async {
    final authority = _authority;
    if (endpointId != profile.primaryEndpointId) {
      throw const SyncTransportException(
        'Primary endpoint identity does not match the sync group.',
        permanent: true,
      );
    }
    await authority.establishGroup(profile.groupId);
    await authority.registerMember(
      groupId: profile.groupId,
      deviceId: deviceId,
      endpointId: endpointId,
      displayName: displayName,
    );
    _primary = true;
    _acceptTimer ??= Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => unawaited(_acceptOnce()),
    );
  }

  Future<void> _startReplica({
    required SyncGroupProfile profile,
    required String deviceId,
    required String endpointId,
    required String displayName,
  }) async {
    final connectionId = await bridge.connect(profile.endpointTicket);
    try {
      await _authenticateReplica(
        connectionId: connectionId,
        profile: profile,
        deviceId: deviceId,
        endpointId: endpointId,
        displayName: displayName,
      );
    } catch (_) {
      await close();
      rethrow;
    }
    _primary = false;
    _primaryConnection = connectionId;
  }

  Future<void> _acceptOnce() async {
    if (!_primary || _accepting || !_connected) return;
    _accepting = true;
    try {
      final connectionId = await bridge.accept();
      if (connectionId != null) {
        final connection = _ServerConnection(connectionId);
        _serverConnections[connectionId] = connection;
        unawaited(_serve(connection));
      }
    } catch (_) {
      // A failed accept is transient; the next timer tick retries it.
    } finally {
      _accepting = false;
    }
  }

  Future<void> _serve(_ServerConnection connection) async {
    try {
      while (_connected) {
        final bytes = await bridge.receiveRequest(
          connectionId: connection.connectionId,
        );
        final request = _decodeFrame(bytes);
        final response = await _handleServerFrame(connection, request);
        await bridge.respond(
          connectionId: connection.connectionId,
          frame: _encodeFrame(response),
        );
      }
    } catch (_) {
      // The peer will reconnect and replay its outbox after a transport error.
    } finally {
      _serverConnections.remove(connection.connectionId);
    }
  }

  Future<_GroupFrame> _handleServerFrame(
    _ServerConnection connection,
    _GroupFrame request,
  ) async {
    if (!connection.authenticated) {
      if (request.kind == _GroupFrameKind.hello) {
        final groupId = request.payload['group_id'];
        final endpointId = request.payload['endpoint_id'];
        final deviceId = request.payload['device_id'];
        final displayName = request.payload['display_name'];
        if (groupId != _activeGroupId ||
            endpointId is! String ||
            deviceId is! String ||
            displayName is! String) {
          return _errorFrame('authentication_failed', 'Sync group identity is invalid');
        }
        connection.endpointId = endpointId;
        connection.deviceId = deviceId;
        connection.displayName = displayName;
        connection.nonce = _randomBytes(32);
        return _frame(_GroupFrameKind.authChallenge, {
          'nonce': base64Url.encode(connection.nonce!).replaceAll('=', ''),
        });
      }
      if (request.kind == _GroupFrameKind.authResponse &&
          connection.nonce != null &&
          request.payload['endpoint_id'] == connection.endpointId) {
        final response = request.payload['response'];
        if (response is! String ||
            !_verifyAuth(connection.endpointId!, connection.nonce!, response)) {
          return _errorFrame('authentication_failed', 'Group authentication failed');
        }
        await _authority.registerMember(
          groupId: _activeGroupId!,
          deviceId: connection.deviceId!,
          endpointId: connection.endpointId!,
          displayName: connection.displayName!,
        );
        connection.authenticated = true;
        return _frame(_GroupFrameKind.hello, {'authenticated': true});
      }
      return _errorFrame('authentication_failed', 'Authentication is required');
    }

    if (request.kind == _GroupFrameKind.push) {
      final changes = _pendingChanges(request.payload['changes']);
      final result = await _authority.push(
        deviceId: connection.deviceId!,
        endpointId: connection.endpointId!,
        idempotencyKey: request.payload['idempotency_key'] as String,
        changes: changes,
      );
      _publishAccepted(result);
      return _frame(_GroupFrameKind.pushResult, _pushResultToJson(result));
    }
    if (request.kind == _GroupFrameKind.pull) {
      final result = await _authority.pull(
        deviceId: connection.deviceId!,
        endpointId: connection.endpointId!,
        cursor: request.payload['cursor'] as String?,
        limit: request.payload['limit'] as int? ?? 200,
      );
      return _frame(_GroupFrameKind.pullResult, _pullPageToJson(result));
    }
    return _errorFrame('invalid_code', 'Unsupported group request');
  }

  Future<void> _authenticateReplica({
    required int connectionId,
    required SyncGroupProfile profile,
    required String deviceId,
    required String endpointId,
    required String displayName,
  }) async {
    final challenge = await _request(
      connectionId: connectionId,
      frame: _frame(_GroupFrameKind.hello, {
        'protocol': 1,
        'group_id': profile.groupId,
        'endpoint_id': endpointId,
        'device_id': deviceId,
        'display_name': displayName,
      }),
    );
    if (challenge.kind != _GroupFrameKind.authChallenge) {
      throw _remoteError(challenge);
    }
    final encodedNonce = challenge.payload['nonce'];
    if (encodedNonce is! String) {
      throw const SyncTransportException('Primary returned an invalid auth challenge.');
    }
    final nonce = base64Url.decode(base64Url.normalize(encodedNonce));
    final response = _authResponse(profile.groupSecret, nonce, endpointId);
    final accepted = await _request(
      connectionId: connectionId,
      frame: _frame(_GroupFrameKind.authResponse, {
        'endpoint_id': endpointId,
        'response': base64Url.encode(response).replaceAll('=', ''),
      }),
    );
    if (accepted.kind != _GroupFrameKind.hello ||
        accepted.payload['authenticated'] != true) {
      throw _remoteError(accepted);
    }
  }

  Future<_GroupFrame> _request({
    required int connectionId,
    required _GroupFrame frame,
  }) async => _decodeFrame(
    await bridge.request(
      connectionId: connectionId,
      frame: _encodeFrame(frame),
    ),
  );

  void _ensureConnected(String deviceId, String endpointId) {
    if (!_connected || deviceId != _deviceId || endpointId != _endpointId) {
      throw const SyncTransportException('Primary endpoint is unavailable.');
    }
  }

  SyncAuthorityEngine get _authority => authority ??
      (throw const SyncTransportException(
        'A primary authority is required for group hosting.',
        permanent: true,
      ));

  void _publishAccepted(PushSyncResult result) {
    if (result.accepted.isEmpty || result.serverCursor == null) return;
    _notifications.publish(
      SyncTransportEvent(
        kind: SyncTransportEventKind.changesAvailable,
        cursor: result.serverCursor,
      ),
    );
  }

  static _GroupFrame _frame(_GroupFrameKind kind, Map<String, Object?> payload) =>
      _GroupFrame(kind: kind, payload: payload);

  static Uint8List _encodeFrame(_GroupFrame frame) {
    final payload = utf8.encode(jsonEncode(frame.payload));
    if (payload.length > 1024 * 1024 - 10) {
      throw const SyncTransportException('P2P frame is too large.', permanent: true);
    }
    final bytes = BytesBuilder();
    bytes.add(const [0x45, 0x43, 0, 1]);
    bytes.add([frame.kind.code, 0]);
    bytes.add([
      (payload.length >> 24) & 0xff,
      (payload.length >> 16) & 0xff,
      (payload.length >> 8) & 0xff,
      payload.length & 0xff,
    ]);
    bytes.add(payload);
    return bytes.takeBytes();
  }

  static _GroupFrame _decodeFrame(Uint8List bytes) {
    if (bytes.length < 10 || bytes[0] != 0x45 || bytes[1] != 0x43) {
      throw const SyncTransportException('Invalid P2P frame.', permanent: true);
    }
    if (bytes[2] != 0 || bytes[3] != 1 || bytes[5] != 0) {
      throw const SyncTransportException('Unsupported P2P frame.', permanent: true);
    }
    final length = (bytes[6] << 24) |
        (bytes[7] << 16) |
        (bytes[8] << 8) |
        bytes[9];
    if (length < 0 || length > 1024 * 1024 - 10 || bytes.length != 10 + length) {
      throw const SyncTransportException('Invalid P2P frame length.', permanent: true);
    }
    final decoded = jsonDecode(utf8.decode(bytes.sublist(10))) as Map;
    return _GroupFrame(
      kind: _GroupFrameKind.fromCode(bytes[4]),
      payload: decoded.cast<String, Object?>(),
    );
  }

  _GroupFrame _errorFrame(String code, String message) =>
      _frame(_GroupFrameKind.error, {'code': code, 'message': message});

  SyncTransportException _remoteError(_GroupFrame frame) =>
      SyncTransportException(
        frame.payload['message'] as String? ?? 'P2P request failed.',
        permanent: frame.payload['code'] != 'primary_unavailable',
      );

  bool _verifyAuth(String endpointId, List<int> nonce, String encodedResponse) {
    try {
      final expected = _authResponse(_activeGroupSecret!, nonce, endpointId);
      final actual = base64Url.decode(base64Url.normalize(encodedResponse));
      if (actual.length != expected.length) return false;
      var difference = 0;
      for (var index = 0; index < expected.length; index++) {
        difference |= expected[index] ^ actual[index];
      }
      return difference == 0;
    } on FormatException {
      return false;
    }
  }

  List<int> _randomBytes(int length) =>
      List<int>.generate(length, (_) => _random.nextInt(256));

  static Uint8List _authResponse(
    String groupSecret,
    List<int> nonce,
    String endpointId,
  ) {
    final secret = base64Url.decode(base64Url.normalize(groupSecret));
    final message = <int>[
      ...utf8.encode('easycalendar.sync.auth.v1\u0000'),
      ...nonce,
      ...utf8.encode(endpointId),
      0,
      1,
    ];
    return Uint8List.fromList(Hmac(sha256, secret).convert(message).bytes);
  }

  static List<PendingSyncChange> _pendingChanges(Object? value) {
    if (value is! List) throw const FormatException('changes must be a list');
    return value
        .map(
          (entry) => PendingSyncChange(
            changeId: (entry as Map)['change_id'] as String,
            deviceId: entry['device_id'] as String,
            entityType: entry['entity_type'] as String,
            entityId: entry['entity_id'] as String,
            operation: entry['operation'] as String,
            version: entry['version'] as int,
            updatedAt: DateTime.parse(entry['updated_at'] as String),
            payload: (entry['payload'] as Map).cast<String, Object?>(),
            retryCount: 0,
          ),
        )
        .toList(growable: false);
  }

  static Map<String, Object?> _pushResultToJson(PushSyncResult result) => {
    'accepted': result.accepted,
    'rejected': result.rejected
        .map(
          (value) => {
            'change_id': value.changeId,
            'code': value.code,
            'message': value.message,
          },
        )
        .toList(),
    'conflicts': result.conflicts
        .map(
          (value) => {
            'entity_type': value.entityType,
            'entity_id': value.entityId,
            'resolution': value.resolution,
            'winner': value.winner.toJson(),
            'loser': value.loser.toJson(),
          },
        )
        .toList(),
    'server_cursor': result.serverCursor,
  };

  static PushSyncResult _pushResultFromJson(Map<String, Object?> json) =>
      PushSyncResult(
        accepted: (json['accepted'] as List).cast<String>(),
        rejected: (json['rejected'] as List)
            .map(
              (value) => SyncRejection(
                changeId: value['change_id'] as String,
                code: value['code'] as String,
                message: value['message'] as String,
              ),
            )
            .toList(growable: false),
        conflicts: (json['conflicts'] as List)
            .map(
              (value) => SyncConflictSummary.fromJson(
                (value as Map).cast<String, Object?>(),
              ),
            )
            .toList(growable: false),
        serverCursor: json['server_cursor'] as String?,
      );

  static Map<String, Object?> _pullPageToJson(PullSyncPage page) => {
    'cursor': page.cursor,
    'has_more': page.hasMore,
    'changes': page.changes.map((change) => change.toJson()).toList(),
  };

  static PullSyncPage _pullPageFromJson(Map<String, Object?> json) =>
      PullSyncPage(
        cursor: json['cursor'] as String,
        hasMore: json['has_more'] as bool,
        changes: (json['changes'] as List)
            .map(
              (value) => RemoteSyncChange.fromJson(
                (value as Map).cast<String, Object?>(),
              ),
            )
            .toList(growable: false),
      );
}

class _ServerConnection {
  _ServerConnection(this.connectionId);

  final int connectionId;
  bool authenticated = false;
  List<int>? nonce;
  String? endpointId;
  String? deviceId;
  String? displayName;
}
