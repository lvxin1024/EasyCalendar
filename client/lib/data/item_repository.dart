import '../domain/item.dart';

abstract interface class ItemRepository {
  String? get databasePath;

  Future<void> initialize();

  Future<List<CalendarItem>> listItems({bool includeDeleted = false});

  Future<CalendarItem> createItem(ItemDraft draft);

  Future<CalendarItem> updateItem(CalendarItem current, ItemDraft draft);

  Future<CalendarItem> setTaskCompleted(
    CalendarItem current, {
    required bool completed,
  });

  Future<void> deleteItem(CalendarItem current);

  Future<ClientPreferences> loadPreferences(ClientPreferences defaults);

  Future<void> savePreferences(ClientPreferences preferences);

  Future<void> close();
}

class RepositoryConflict implements Exception {
  const RepositoryConflict(this.message);

  final String message;

  @override
  String toString() => message;
}
