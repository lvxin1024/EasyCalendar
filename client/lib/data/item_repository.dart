import '../domain/item.dart';
import '../domain/subscription.dart';
import 'local_ics_service.dart';
import 'transfer_models.dart';

abstract interface class ItemRepository {
  String? get databasePath;

  Future<void> initialize();

  Future<List<CalendarItem>> listItems({bool includeDeleted = false});

  Future<List<CalendarCollection>> listCollections({
    bool includeDeleted = false,
  });

  Future<CalendarCollection> createCollection({
    required String name,
    required int color,
  });

  Future<CalendarCollection> connectCollection({
    required String id,
    required String name,
    int? color,
  });

  Future<CalendarCollection> updateCollection(
    CalendarCollection current, {
    required String name,
    required int color,
  });

  Future<void> deleteCollection(CalendarCollection current);

  Future<CalendarItem> createItem(ItemDraft draft);

  Future<CalendarItem> updateItem(CalendarItem current, ItemDraft draft);

  Future<CalendarItem> setTaskCompleted(
    CalendarItem current, {
    required bool completed,
  });

  Future<void> deleteItem(CalendarItem current);

  Future<CalendarItem> restoreItem(CalendarItem current);

  Future<List<CalendarItem>> listDeletedItems();

  Future<String> exportLocalJsonBackup();

  Future<TransferResult> previewLocalJsonImport(String content);

  Future<void> commitLocalJsonImport(String content);

  Future<List<CalendarSubscription>> listSubscriptions();

  Future<CalendarSubscription> createSubscription({
    required String title,
    required String url,
    required int refreshIntervalMinutes,
    required List<String> tags,
  });

  Future<CalendarSubscription> updateSubscription(
    CalendarSubscription current, {
    required String title,
    required String url,
    required bool enabled,
    required int refreshIntervalMinutes,
    required List<String> tags,
  });

  Future<void> deleteSubscription(CalendarSubscription current);

  Future<SubscriptionFetchLog> applySubscriptionRefresh(
    CalendarSubscription current, {
    required List<LocalIcsEvent> events,
    required bool notModified,
    required int httpStatus,
    required DateTime fetchedAt,
    String? etag,
    String? lastModified,
    String? sourceHash,
  });

  Future<void> recordSubscriptionRefreshFailure(
    CalendarSubscription current, {
    required DateTime fetchedAt,
    required String error,
    int? httpStatus,
  });

  Future<List<SubscriptionFetchLog>> listSubscriptionFetchLogs(
    String subscriptionId,
  );

  Future<ClientPreferences> loadPreferences(ClientPreferences defaults);

  Future<void> savePreferences(ClientPreferences preferences);

  Future<void> close();
}

abstract interface class RuntimeSettingsPort {
  Future<void> configureRuntime({
    required String deviceId,
    required String defaultCollectionId,
    required String defaultCollectionName,
  });
}

abstract interface class LocalRecoveryPort {
  Future<List<LocalDatabaseBackup>> listLocalDatabaseBackups();

  Future<LocalDatabaseBackup> createLocalDatabaseBackup({
    LocalBackupReason reason = LocalBackupReason.manual,
  });

  Future<void> restoreLocalDatabaseBackup(String backupPath);

  Future<void> deleteLocalDatabaseBackup(String backupPath);
}

class RepositoryConflict implements Exception {
  const RepositoryConflict(this.message);

  final String message;

  @override
  String toString() => message;
}
