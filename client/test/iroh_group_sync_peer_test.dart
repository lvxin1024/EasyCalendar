import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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

void main() {
  late LocalItemRepository repository;
  late GroupSyncTransport primary;
  late GroupSyncTransport replica;

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
        databaseName: 'iroh-peer.sqlite3',
        deviceId: 'primary-device',
        apiUrl: 'http://localhost:8000',
        syncEnabled: false,
        syncRetryLimit: 8,
        notificationsEnabled: false,
      ),
      databaseFactory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
  });

  tearDown(() async {
    await primary.close();
    await replica.close();
    await repository.close();
  });

  test('memory bridge completes authentication and group push/pull', () async {
    final network = _MemoryP2pNetwork();
    final primaryBridge = _MemoryP2pBridge(network, 'endpoint-primary');
    final replicaBridge = _MemoryP2pBridge(network, 'endpoint-replica');
    final profile = SyncGroupProfile.createPrimary(
      primaryEndpointId: 'endpoint-primary',
      endpointTicket: 'ticket-endpoint-primary',
    );
    final replicaProfile = SyncGroupProfile.fromSecret(
      groupSecret: profile.groupSecret,
      role: SyncGroupRole.replica,
      primaryEndpointId: profile.primaryEndpointId,
      endpointTicket: profile.endpointTicket,
    );
    final authority = SyncAuthorityEngine(
      SyncAuthorityStore(await repository.openSharedDatabase()),
      primaryDeviceId: 'primary-device',
    );

    primary = GroupSyncTransport(
      peer: IrohSyncGroupPeer(
        bridge: primaryBridge,
        endpointSecret: _secret('primary'),
        authority: authority,
      ),
      profile: profile,
      deviceId: 'primary-device',
      endpointId: 'endpoint-primary',
    );
    replica = GroupSyncTransport(
      peer: IrohSyncGroupPeer(
        bridge: replicaBridge,
        endpointSecret: _secret('replica'),
      ),
      profile: replicaProfile,
      deviceId: 'replica-device',
      endpointId: 'endpoint-replica',
    );

    await primary.start();
    await replica.start();
    final result = await replica.push(
      serverUrl: Uri.parse('group://primary'),
      token: '',
      deviceId: 'replica-device',
      idempotencyKey: 'replica-push-1',
      changes: [_change()],
    );

    expect(result.accepted, ['change-replica-1']);
    final page = await primary.pull(
      serverUrl: Uri.parse('group://primary'),
      token: '',
    );
    expect(page.changes.single.changeId, 'change-replica-1');
    expect(page.changes.single.deviceId, 'replica-device');
  });
}

PendingSyncChange _change() {
  final updatedAt = DateTime.utc(2026, 9, 6, 8);
  return PendingSyncChange(
    changeId: 'change-replica-1',
    deviceId: 'replica-device',
    entityType: 'item',
    entityId: 'item-1',
    operation: 'create',
    version: 1,
    updatedAt: updatedAt,
    retryCount: 0,
    payload: {
      'id': 'item-1',
      'version': 1,
      'updated_at': updatedAt.toIso8601String(),
      'collection_id': 'collection_local',
      'type': 'note',
    },
  );
}

String _secret(String seed) => base64Url
    .encode(List<int>.generate(32, (index) => seed.codeUnitAt(index % seed.length)))
    .replaceAll('=', '');

class _MemoryP2pNetwork {
  final endpoints = <String, _MemoryP2pBridge>{};

  void register(_MemoryP2pBridge bridge) {
    endpoints[bridge.endpoint] = bridge;
  }

  _MemoryP2pBridge endpointForTicket(String ticket) =>
      endpoints.values.firstWhere((bridge) => bridge.ticket == ticket);
}

class _MemoryP2pBridge implements P2pBridge {
  _MemoryP2pBridge(this.network, this.endpoint)
    : ticket = 'ticket-$endpoint';

  final _MemoryP2pNetwork network;
  final String endpoint;
  final String ticket;
  final _incoming = <int>[];
  final _incomingWaiters = <Completer<int>>[];
  final connections = <int, _MemoryConnection>{};
  int _nextConnectionId = 1;

  @override
  int get protocolVersion => 1;

  @override
  int get maxFrameBytes => 1024 * 1024;

  @override
  Future<void> start({
    required String endpointId,
    required String groupId,
    String? endpointSecret,
  }) async {
    network.register(this);
  }

  @override
  Future<String> endpointId() async => endpoint;

  @override
  Future<String> exportTicket() async => ticket;

  @override
  Future<int> connect(String ticket) async {
    final remote = network.endpointForTicket(ticket);
    final localId = _nextConnectionId++;
    final remoteId = remote._nextConnectionId++;
    final localConnection = _MemoryConnection(remote, remoteId);
    final remoteConnection = _MemoryConnection(this, localId);
    connections[localId] = localConnection;
    remote.connections[remoteId] = remoteConnection;
    remote._enqueueIncoming(remoteId);
    return localId;
  }

  @override
  Future<int?> accept({Duration timeout = const Duration(milliseconds: 250)}) async {
    if (_incoming.isNotEmpty) return _incoming.removeAt(0);
    final waiter = Completer<int>();
    _incomingWaiters.add(waiter);
    try {
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      _incomingWaiters.remove(waiter);
      return null;
    }
  }

  @override
  Future<Uint8List> request({
    required int connectionId,
    required Uint8List frame,
  }) {
    final connection = connections[connectionId]!;
    final response = Completer<Uint8List>();
    connection.remote.connections[connection.remoteConnectionId]!._enqueueRequest(
      frame,
      response,
    );
    return response.future;
  }

  @override
  Future<Uint8List> receiveRequest({required int connectionId}) {
    final connection = connections[connectionId]!;
    return connection.receiveRequest();
  }

  @override
  Future<void> respond({
    required int connectionId,
    required Uint8List frame,
  }) async {
    connections[connectionId]!._respond(frame);
  }

  @override
  Future<void> close() async {
    for (final connection in connections.values) {
      connection.close();
    }
    connections.clear();
  }

  void _enqueueIncoming(int connectionId) {
    if (_incomingWaiters.isNotEmpty) {
      _incomingWaiters.removeAt(0).complete(connectionId);
    } else {
      _incoming.add(connectionId);
    }
  }
}

class _MemoryConnection {
  _MemoryConnection(this.remote, this.remoteConnectionId);

  final _MemoryP2pBridge remote;
  final int remoteConnectionId;
  final _requests = <_PendingMemoryRequest>[];
  final _requestWaiters = <Completer<Uint8List>>[];
  Completer<Uint8List>? _response;

  Future<Uint8List> receiveRequest() {
    if (_requests.isNotEmpty) {
      final request = _requests.removeAt(0);
      _response = request.response;
      return Future.value(request.frame);
    }
    final waiter = Completer<Uint8List>();
    _requestWaiters.add(waiter);
    return waiter.future;
  }

  void _enqueueRequest(Uint8List frame, Completer<Uint8List> response) {
    if (_requestWaiters.isNotEmpty) {
      _response = response;
      _requestWaiters.removeAt(0).complete(frame);
    } else {
      _requests.add(_PendingMemoryRequest(frame, response));
    }
  }

  void _respond(Uint8List frame) {
    final response = _response;
    _response = null;
    response?.complete(frame);
  }

  void close() {
    for (final request in _requests) {
      if (!request.response.isCompleted) {
        request.response.completeError(SyncTransportException('closed'));
      }
    }
    _requests.clear();
  }
}

class _PendingMemoryRequest {
  const _PendingMemoryRequest(this.frame, this.response);

  final Uint8List frame;
  final Completer<Uint8List> response;
}
