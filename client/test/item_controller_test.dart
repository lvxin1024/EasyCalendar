import 'dart:convert';

import 'package:easy_calendar/application/item_controller.dart';
import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/data/item_repository.dart';
import 'package:easy_calendar/data/service_probe_client.dart';
import 'package:easy_calendar/data/transfer_models.dart';
import 'package:easy_calendar/device/device_identity.dart';
import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/features/subscriptions/subscriptions_page.dart';
import 'package:easy_calendar/features/transfer/transfer_page.dart';
import 'package:easy_calendar/sync/token_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

  test('controller migrates and persists the legacy device identity', () async {
    final repository = _MemoryRepository(
      storedPreferences: const ClientPreferences(
        apiUrl: 'http://localhost:8000',
        deviceId: DeviceIdentity.legacyDefaultId,
        syncEnabled: false,
        notificationsEnabled: false,
      ),
    );
    final generated = <String>[
      'device-11111111-1111-4111-8111-111111111111',
    ];
    final controller = ItemController(
      repository: repository,
      config: config,
      deviceIdentity: DeviceIdentity(
        idGenerator: () => generated.removeAt(0),
        platformLabel: 'Test',
      ),
    );

    await controller.initialize();

    expect(controller.preferences.deviceId, config.deviceId);
    expect(controller.preferences.deviceName, 'Test-device');
    expect(repository.storedPreferences?.deviceId, config.deviceId);

    final regenerated = await controller.regenerateDeviceIdentity();

    expect(regenerated.deviceId, 'device-11111111-1111-4111-8111-111111111111');
    expect(regenerated.deviceName, 'Test-device');
    expect(repository.storedPreferences?.deviceId, regenerated.deviceId);
  });

  test('feature token has an independent configured state', () async {
    final store = _MemoryTokenStore();
    final controller = ItemController(
      repository: _MemoryRepository(),
      config: config,
      featureTokenStore: store,
    );

    await controller.initialize();
    expect(controller.featureTokenConfigured, isFalse);

    await controller.saveFeatureToken('core-token');
    expect(controller.featureTokenConfigured, isTrue);
    expect(store.value, 'core-token');

    await controller.clearFeatureToken();
    expect(controller.featureTokenConfigured, isFalse);
    expect(store.value, isNull);
  });

  test(
    'service probes use stored tokens and cache successful results',
    () async {
      final store = _MemoryTokenStore()..value = 'stored-core-token';
      late http.Request authRequest;
      final probeClient = _featureProbeClient(
        icsSubscriptions: true,
        icsTransfer: true,
        authRequired: true,
        onAuthCheck: (request) => authRequest = request,
      );
      final controller = ItemController(
        repository: _MemoryRepository(),
        config: config,
        featureTokenStore: store,
        serviceProbeClient: probeClient,
      );
      await controller.initialize();

      final result = await controller.testServiceConnection(
        kind: ServiceKind.feature,
        serverUrl: 'https://core.example.com',
      );

      expect(authRequest.headers['Authorization'], 'Bearer stored-core-token');
      expect(controller.featureServiceProbe, same(result));

      await controller.savePreferences(
        controller.preferences.copyWith(
          featureApiUrl: 'https://other-core.example.com',
        ),
      );
      expect(controller.featureServiceProbe, isNull);
    },
  );

  testWidgets('subscriptions stop before API calls when capability is absent', (
    tester,
  ) async {
    final controller = ItemController(
      repository: _MemoryRepository(),
      config: config,
      featureTokenStore: _MemoryTokenStore(),
      serviceProbeClient: _featureProbeClient(icsTransfer: true),
    );
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SubscriptionsPage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('不支持网址订阅'), findsOneWidget);
    final addButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '添加订阅'),
    );
    expect(addButton.onPressed, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('remote ICS is disabled without affecting local JSON backup', (
    tester,
  ) async {
    final controller = ItemController(
      repository: _MemoryRepository(),
      config: config,
      featureTokenStore: _MemoryTokenStore(),
      serviceProbeClient: _featureProbeClient(icsSubscriptions: true),
    );
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TransferPage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('不支持远程 ICS'), findsOneWidget);
    final exportIcs = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '导出 ICS'),
    );
    final importIcs = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '导入 ICS 文件'),
    );
    final exportJson = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '导出 JSON 备份'),
    );
    expect(exportIcs.onPressed, isNull);
    expect(importIcs.onPressed, isNull);
    expect(exportJson.onPressed, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

ServiceProbeClient _featureProbeClient({
  bool icsSubscriptions = false,
  bool icsTransfer = false,
  bool authRequired = false,
  void Function(http.Request request)? onAuthCheck,
}) => ServiceProbeClient(
  client: MockClient((request) async {
    return switch (request.url.path) {
      '/v1/health' => http.Response(
        jsonEncode({
          'status': 'ok',
          'service': 'easycalendar',
          'version': '0.1.0',
          'schema_version': 1,
        }),
        200,
      ),
      '/v1/capabilities' => http.Response(
        jsonEncode({
          'api_version': 'v1',
          'features': {
            'ics_subscriptions': icsSubscriptions,
            'ics_transfer': icsTransfer,
          },
          'configured': <String, bool>{},
          'authentication': {'required': authRequired, 'scheme': 'bearer'},
        }),
        200,
      ),
      '/v1/auth-check' => (() {
        onAuthCheck?.call(request);
        return http.Response('{}', 200);
      })(),
      _ => http.Response('{}', 404),
    };
  }),
);

class _MemoryTokenStore implements SyncTokenStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String token) async => value = token;

  @override
  Future<void> clear() async => value = null;
}

class _MemoryRepository implements ItemRepository {
  _MemoryRepository({this.storedPreferences});

  ClientPreferences? storedPreferences;
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
  Future<CalendarItem> restoreItem(CalendarItem current) async => current;

  @override
  Future<List<CalendarItem>> listDeletedItems() async => const [];

  @override
  Future<String> exportLocalJsonBackup() async => '{}';

  @override
  Future<TransferResult> previewLocalJsonImport(String content) async =>
      const TransferResult(
        accepted: true,
        committed: false,
        format: 'json',
        created: {},
        skipped: {},
        conflicts: {},
        issues: [],
      );

  @override
  Future<void> commitLocalJsonImport(String content) async {}

  @override
  Future<ClientPreferences> loadPreferences(ClientPreferences defaults) async =>
      storedPreferences ?? defaults;

  @override
  Future<void> savePreferences(ClientPreferences preferences) async {
    storedPreferences = preferences;
  }

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
