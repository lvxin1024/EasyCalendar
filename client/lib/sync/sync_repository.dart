import 'sync_models.dart';

abstract interface class SyncRepository {
  Future<List<PendingSyncChange>> listPendingChanges({
    required DateTime now,
    int limit = 200,
  });

  Future<void> removeAcceptedChanges(List<String> changeIds);

  Future<DateTime?> recordTransientFailure(
    List<String> changeIds,
    String error, {
    required DateTime now,
    required int retryLimit,
  });

  Future<void> recordPermanentFailures(List<SyncRejection> rejections);

  Future<void> resetTransientBackoff();

  Future<String?> loadRemoteCursor();

  Future<void> applyRemoteBatch(List<RemoteSyncChange> changes, String cursor);
}
