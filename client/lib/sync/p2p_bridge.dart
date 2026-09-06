import 'sync_transport.dart';

/// Stable Dart-side boundary for the native P2P library.
///
/// The concrete Iroh-backed implementation is added after the native crate is
/// validated on each release platform. Keeping this interface small lets the
/// HTTP transport and test doubles remain unchanged.
abstract interface class P2pBridge {
  int get protocolVersion;

  int get maxFrameBytes;

  Future<void> start({
    required String endpointId,
    required String groupId,
  });

  Future<void> close();
}

class UnavailableP2pBridge implements P2pBridge {
  const UnavailableP2pBridge();

  @override
  int get protocolVersion => 1;

  @override
  int get maxFrameBytes => 1024 * 1024;

  @override
  Future<void> start({
    required String endpointId,
    required String groupId,
  }) async {
    throw const SyncTransportException(
      'P2P native bridge is not available on this build.',
      permanent: true,
    );
  }

  @override
  Future<void> close() async {}
}
