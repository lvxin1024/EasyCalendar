import '../domain/item.dart';
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

class RepositoryConflict implements Exception {
  const RepositoryConflict(this.message);

  final String message;

  @override
  String toString() => message;
}
