import 'sync_models.dart';

abstract interface class SyncTransport {
  Future<PushSyncResult> push({
    required Uri serverUrl,
    required String token,
    required String deviceId,
    required String idempotencyKey,
    required List<PendingSyncChange> changes,
  });

  Future<PullSyncPage> pull({
    required Uri serverUrl,
    required String token,
    String? cursor,
    int limit = 200,
  });
}

class SyncTransportException implements Exception {
  const SyncTransportException(this.message, {this.permanent = false});

  final String message;
  final bool permanent;

  @override
  String toString() => message;
}

class SyncAuthenticationException extends SyncTransportException {
  const SyncAuthenticationException() : super('同步令牌无效或已失效。', permanent: true);
}
