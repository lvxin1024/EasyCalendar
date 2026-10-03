import 'dart:async';

import 'package:easy_calendar/application/item_controller.dart';
import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/data/item_repository.dart';
import 'package:easy_calendar/data/local_ics_service.dart';
import 'package:easy_calendar/data/local_item_repository.dart';
import 'package:easy_calendar/data/subscription_fetch_client.dart';
import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/domain/subscription.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tz_data;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _PausedRepository repository;
  late ItemController controller;

  setUpAll(tz_data.initializeTimeZones);

  setUp(() async {
    sqfliteFfiInit();
    repository = _PausedRepository();
    controller = ItemController(
      repository: repository,
      config: _config,
      subscriptionFetchClient: SubscriptionFetchClient(
        client: MockClient((_) async => http.Response(_calendar, 200)),
      ),
    );
    await controller.initialize();
    expect(controller.error, isNull);
    await controller.createSubscription(
      title: 'Team',
      url: 'https://example.com/team.ics',
      refreshIntervalMinutes: 60,
      tags: const [],
    );
  });

  tearDown(() async {
    controller.dispose();
    await repository.closed.future;
  });

  for (final saveFirst in [true, false]) {
    test(
      saveFirst
          ? 'automatic refresh can finish while a local save is pending'
          : 'local save can finish while automatic refresh is applying',
      () async {
        final subscribedItemVisible = Completer<void>();
        controller.addListener(() {
          if (!subscribedItemVisible.isCompleted &&
              controller.items.any((item) => item.title == 'Team meeting')) {
            subscribedItemVisible.complete();
          }
        });

        if (saveFirst) {
          repository.createRelease = Completer<void>();
          final saved = controller.saveItem(draft: _draft);
          await repository.createStarted.future;
          expect(controller.mutating, isTrue);

          controller.startSubscriptionAutoRefresh();
          await subscribedItemVisible.future.timeout(
            const Duration(seconds: 5),
          );
          expect(controller.mutating, isTrue);
          await expectLater(
            controller.saveItem(draft: _draft),
            throwsA(isA<RepositoryConflict>()),
          );
          repository.createRelease!.complete();
          expect(await saved, isNotNull);
        } else {
          repository.refreshRelease = Completer<void>();
          controller.startSubscriptionAutoRefresh();
          await repository.refreshStarted.future.timeout(
            const Duration(seconds: 5),
          );
          expect(controller.mutating, isFalse);

          expect(await controller.saveItem(draft: _draft), isNotNull);
          expect(controller.items.single.title, 'Local task');
          repository.refreshRelease!.complete();
          await subscribedItemVisible.future.timeout(
            const Duration(seconds: 5),
          );
        }

        controller.stopSubscriptionAutoRefresh();
        expect(controller.mutating, isFalse);
        expect(controller.error, isNull);
        expect(
          controller.items.map((item) => item.title),
          unorderedEquals(['Local task', 'Team meeting']),
        );
        expect(
          (await repository.listItems()).map((item) => item.title),
          unorderedEquals(['Local task', 'Team meeting']),
        );
        final subscription = (await controller.listSubscriptions()).single;
        expect(subscription.lastError, isNull);
        expect(
          (await repository.listSubscriptionFetchLogs(
            subscription.id,
          )).single.status,
          'success',
        );
      },
    );
  }
}

class _PausedRepository extends LocalItemRepository {
  _PausedRepository()
    : super(
        _config,
        databaseFactory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );

  final createStarted = Completer<void>();
  final refreshStarted = Completer<void>();
  final closed = Completer<void>();
  Completer<void>? createRelease;
  Completer<void>? refreshRelease;

  @override
  Future<CalendarItem> createItem(ItemDraft draft) async {
    if (!createStarted.isCompleted) createStarted.complete();
    await createRelease?.future;
    return super.createItem(draft);
  }

  @override
  Future<SubscriptionFetchLog> applySubscriptionRefresh(
    CalendarSubscription current, {
    required List<LocalIcsEvent> events,
    required bool notModified,
    required int httpStatus,
    required DateTime fetchedAt,
    String? etag,
    String? lastModified,
    String? sourceHash,
  }) async {
    if (!refreshStarted.isCompleted) refreshStarted.complete();
    await refreshRelease?.future;
    return super.applySubscriptionRefresh(
      current,
      events: events,
      notModified: notModified,
      httpStatus: httpStatus,
      fetchedAt: fetchedAt,
      etag: etag,
      lastModified: lastModified,
      sourceHash: sourceHash,
    );
  }

  @override
  Future<void> close() async {
    await super.close();
    if (!closed.isCompleted) closed.complete();
  }
}

const _draft = ItemDraft(
  type: ItemType.task,
  title: 'Local task',
  timezone: 'Asia/Shanghai',
);

const _calendar =
    'BEGIN:VCALENDAR\r\n'
    'VERSION:2.0\r\n'
    'PRODID:-//EasyCalendar//Subscription Test//EN\r\n'
    'BEGIN:VEVENT\r\n'
    'UID:team@example.com\r\n'
    'DTSTART:20261002T010000Z\r\n'
    'DTEND:20261002T020000Z\r\n'
    'SUMMARY:Team meeting\r\n'
    'END:VEVENT\r\n'
    'END:VCALENDAR\r\n';

const _config = AppConfig(
  appName: 'EasyCalendar',
  locale: Locale('zh', 'CN'),
  timezone: 'Asia/Shanghai',
  defaultCollectionId: 'collection_local',
  defaultCollectionName: 'My calendar',
  defaultCollectionColor: Color(0xFF2563EB),
  databaseName: 'test.sqlite3',
  deviceId: 'test-device',
  apiUrl: 'https://sync.example.com',
  syncEnabled: false,
  syncRetryLimit: 8,
  notificationsEnabled: false,
);
