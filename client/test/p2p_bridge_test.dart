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
}
