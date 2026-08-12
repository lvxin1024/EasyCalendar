import 'package:easy_calendar/application/item_controller.dart';
import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/data/item_repository.dart';
import 'package:easy_calendar/domain/item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  const config = AppConfig(
    appName: 'EasyCalendar',
    locale: Locale('zh', 'CN'),
    timezone: 'Asia/Shanghai',
    defaultCollectionId: 'collection_local',
    defaultCollectionName: '我的日程',
    defaultCollectionColor: Color(0xFF2563EB),
    databaseName: 'test.sqlite3',
    deviceId: 'test-device',
    apiUrl: 'http://localhost:8000',
    syncEnabled: false,
    syncRetryLimit: 8,
    notificationsEnabled: false,
  );

  setUpAll(() {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation(config.timezone));
  });

  test('controller persists CRUD and computes today items', () async {
    final repository = _MemoryRepository();
    final controller = ItemController(repository: repository, config: config);
    await controller.initialize();

    final now = DateTime.now();
    final created = await controller.saveItem(
      draft: ItemDraft(
        type: ItemType.event,
        title: '今日会议',
        startAt: now,
        endAt: now.add(const Duration(hours: 1)),
        timezone: config.timezone,
      ),
    );

    expect(created, isNotNull);
    expect(controller.items, hasLength(1));
    expect(controller.todayItems.single.title, '今日会议');
    await controller.deleteItem(created!);
    expect(controller.items, isEmpty);
  });

  test('controller completes Due without creating a duplicate', () async {
    final repository = _MemoryRepository();
    final controller = ItemController(repository: repository, config: config);
    await controller.initialize();
    final created = await controller.saveItem(
      draft: ItemDraft(
        type: ItemType.task,
        title: '提交报告',
        dueAt: DateTime.now().add(const Duration(hours: 2)),
        timezone: config.timezone,
      ),
    );

    await controller.setTaskCompleted(created!, completed: true);

    expect(controller.items, hasLength(1));
    expect(controller.items.single.status, ItemStatus.done);
    expect(controller.items.single.version, 2);
  });
}

class _MemoryRepository implements ItemRepository {
  final List<CalendarItem> _items = [];
  final List<CalendarCollection> _collections = [
    CalendarCollection(
      id: 'collection_local',
      name: 'Local',
      kind: 'local',
      color: 0xFF2563EB,
      readonly: false,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      version: 1,
    ),
  ];

  @override
  String? get databasePath => ':memory:';

  @override
  Future<void> initialize() async {}

  @override
  Future<List<CalendarItem>> listItems({bool includeDeleted = false}) async =>
      _items
          .where((item) => includeDeleted || !item.isDeleted)
          .toList(growable: false);

  @override
  Future<List<CalendarCollection>> listCollections({
    bool includeDeleted = false,
  }) async => _collections;

  @override
  Future<CalendarCollection> createCollection({
    required String name,
    required int color,
  }) async {
    final collection = CalendarCollection(
      id: 'collection_${_collections.length}',
      name: name,
      kind: 'local',
      color: color,
      readonly: false,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      version: 1,
    );
    _collections.add(collection);
    return collection;
  }

  @override
  Future<CalendarCollection> updateCollection(
    CalendarCollection current, {
    required String name,
    required int color,
  }) async => current;

  @override
  Future<void> deleteCollection(CalendarCollection current) async {
    _collections.removeWhere((value) => value.id == current.id);
  }

  @override
  Future<CalendarItem> createItem(ItemDraft draft) async {
    final now = DateTime.now();
    final item = _fromDraft('item_1', draft, now: now, version: 1);
    _items.add(item);
    return item;
  }

  @override
  Future<CalendarItem> updateItem(CalendarItem current, ItemDraft draft) async {
    final item = _fromDraft(
      current.id,
      draft,
      now: DateTime.now(),
      version: current.version + 1,
      createdAt: current.createdAt,
    );
    _items[_items.indexWhere((value) => value.id == current.id)] = item;
    return item;
  }

  @override
  Future<CalendarItem> setTaskCompleted(
    CalendarItem current, {
    required bool completed,
  }) => updateItem(
    current,
    ItemDraft(
      type: current.type,
      title: current.title,
      dueAt: current.dueAt,
      timezone: current.timezone,
      status: completed ? ItemStatus.done : ItemStatus.todo,
    ),
  );

  @override
  Future<void> deleteItem(CalendarItem current) async {
    _items.removeWhere((item) => item.id == current.id);
  }

  @override
  Future<ClientPreferences> loadPreferences(ClientPreferences defaults) async =>
      defaults;

  @override
  Future<void> savePreferences(ClientPreferences preferences) async {}

  @override
  Future<void> close() async {}

  static CalendarItem _fromDraft(
    String id,
    ItemDraft draft, {
    required DateTime now,
    required int version,
    DateTime? createdAt,
  }) => CalendarItem(
    id: id,
    collectionId: draft.collectionId ?? 'collection_local',
    type: draft.type,
    title: draft.title,
    body: draft.body,
    startAt: draft.startAt,
    endAt: draft.endAt,
    dueAt: draft.dueAt,
    timezone: draft.timezone,
    allDay: draft.allDay,
    location: draft.location,
    status: draft.status,
    priority: draft.priority,
    reminderEnabled: draft.reminderEnabled,
    reminderMinutes: draft.reminderMinutes,
    tags: draft.tags,
    createdAt: createdAt ?? now,
    updatedAt: now,
    version: version,
  );
}
