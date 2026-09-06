import 'dart:convert';
import 'dart:typed_data';

import 'package:easy_calendar/sync/p2p_bridge.dart';
import 'package:easy_calendar/sync/sync_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unavailable bridge exposes protocol limits and a stable failure', () async {
    const bridge = UnavailableP2pBridge();
    expect(bridge.protocolVersion, 1);
    expect(bridge.maxFrameBytes, 1024 * 1024);
    expect(
      () => bridge.start(endpointId: 'endpoint-1', groupId: 'group-1'),
      throwsA(
        isA<SyncTransportException>().having(
          (error) => error.permanent,
          'permanent',
          isTrue,
        ),
      ),
    );
    await bridge.close();
  });

  test('native bridge binds once and forwards request lifecycle', () async {
    final api = _FakeP2pNativeApi();
    final bridge = NativeP2pBridge(api: api);
    final secret = base64Url
        .encode(List<int>.filled(32, 7))
        .replaceAll('=', '');

    await bridge.start(
      endpointId: 'endpoint-1',
      groupId: 'group-1',
      endpointSecret: secret,
    );
    await bridge.start(
      endpointId: 'endpoint-1',
      groupId: 'group-1',
      endpointSecret: secret,
    );

    expect(api.bindCalls, 1);
    expect(await bridge.endpointId(), 'endpoint-native');
    expect(await bridge.exportTicket(), 'ticket-native');
    expect(await bridge.connect('ticket-native'), 7);
    expect(await bridge.accept(), 8);
    expect(
      await bridge.request(connectionId: 7, frame: Uint8List.fromList([1])),
      [2],
    );
    expect(
      await bridge.receiveRequest(connectionId: 8),
      [3],
    );
    await bridge.respond(connectionId: 8, frame: Uint8List.fromList([4]));
    await bridge.close();
    expect(api.closeCalls, 1);
  });

  test('native bridge rejects an invalid endpoint secret', () async {
    final bridge = NativeP2pBridge(api: _FakeP2pNativeApi());

    expect(
      () => bridge.start(
        endpointId: 'endpoint-1',
        groupId: 'group-1',
        endpointSecret: 'short',
      ),
      throwsA(
        isA<SyncTransportException>().having(
          (error) => error.permanent,
          'permanent',
          isTrue,
        ),
      ),
    );
  });
}

class _FakeP2pNativeApi implements P2pNativeApi {
  int bindCalls = 0;
  int closeCalls = 0;

  @override
  int get protocolVersion => 1;

  @override
  int get maxFrameBytes => 1024;

  @override
  int bind(Uint8List secret) {
    bindCalls += 1;
    expect(secret, List<int>.filled(32, 7));
    return 42;
  }

  @override
  String endpointId(int handle) => 'endpoint-native';

  @override
  String endpointTicket(int handle) => 'ticket-native';

  @override
  int connect(int handle, String ticket) => 7;

  @override
  int? accept(int handle, Duration timeout) => 8;

  @override
  Uint8List request(int handle, int connectionId, Uint8List frame) =>
      Uint8List.fromList([2]);

  @override
  Uint8List receiveRequest(int handle, int connectionId) =>
      Uint8List.fromList([3]);

  @override
  void respond(int handle, int connectionId, Uint8List frame) {
    expect(frame, [4]);
  }

  @override
  void close(int handle) => closeCalls += 1;
}
