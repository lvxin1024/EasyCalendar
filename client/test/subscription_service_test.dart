import 'dart:async';

import 'package:easy_calendar/application/subscription_service.dart';
import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/data/item_repository.dart';
import 'package:easy_calendar/data/local_ics_service.dart';
import 'package:easy_calendar/data/local_item_repository.dart';
import 'package:easy_calendar/data/subscription_fetch_client.dart';
import 'package:easy_calendar/domain/subscription.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('SubscriptionService', () {
    late LocalItemRepository repository;
    late SubscriptionService service;
    late DateTime now;
    late List<http.Request> requests;
    late Future<http.Response> Function(http.Request) respond;

    setUp(() async {
      sqfliteFfiInit();
      repository = LocalItemRepository(
        _config,
        databaseFactory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      await repository.initialize();
      now = DateTime.utc(2026, 10, 1);
      requests = [];
      respond = (_) async => _calendarResponse();
      service = SubscriptionService(
        repository: repository,
        localIcsService: const LocalIcsService(),
        activeTimezone: () => 'Asia/Shanghai',
        runMutation: _runMutation,
        clock: () => now,
        fetchClient: SubscriptionFetchClient(
          client: MockClient((request) {
            requests.add(request);
            return respond(request);
          }),
        ),
      );
    });

    tearDown(() async {
      service.close();
      await repository.close();
    });

    Future<CalendarSubscription> create({String name = 'team'}) =>
        service.create(
          title: name,
          url: 'https://example.com/$name.ics',
          refreshIntervalMinutes: 60,
          tags: const ['team'],
        );

    Future<CalendarSubscription> update(
      CalendarSubscription current, {
      bool? enabled,
      String? url,
    }) => service.update(
      current,
      title: current.title,
      url: url ?? current.url,
      enabled: enabled ?? current.enabled,
      refreshIntervalMinutes: current.refreshIntervalMinutes,
      tags: current.tags,
    );

    test(
      'uses fresh validators and fully fetches again after re-enabling',
      () async {
        final created = await create();
        expect(requests, isEmpty);
        await service.refresh(created);
        final item = (await repository.listItems()).single;

        respond = (_) async => http.Response('', 304);
        final unchanged = await service.refresh(created);
        expect(unchanged.status, 'not_modified');
        expect(requests.last.headers['If-None-Match'], '"v1"');
        expect(
          requests.last.headers['If-Modified-Since'],
          'Thu, 01 Oct 2026 00:00:00 GMT',
        );
        expect((await repository.listItems()).single.version, item.version);

        final current = (await service.list()).single;
        final disabled = await update(current, enabled: false);
        expect(await repository.listItems(), isEmpty);
        expect(requests, hasLength(2));

        respond = (_) async => _calendarResponse();
        await update(disabled, enabled: true);
        expect(requests, hasLength(3));
        expect(requests.last.headers['If-None-Match'], isNull);
        expect(requests.last.headers['If-Modified-Since'], isNull);
        final restored = (await repository.listItems()).single;
        expect(restored.id, item.id);
        expect(restored.title, 'Team meeting');
        expect(restored.location, 'Room 1');
        expect((await service.list()).single.lastFetchedAt, now);

        final enabled = (await service.list()).single;
        respond = (_) async => _calendarResponse(title: 'Replacement meeting');
        await update(enabled, url: 'https://example.com/replacement.ics');
        expect(requests.last.url.path, '/replacement.ics');
        expect(requests.last.headers['If-None-Match'], isNull);
        expect(
          (await repository.listItems()).single.title,
          'Replacement meeting',
        );
      },
    );

    test(
      'refreshes only due enabled sources and retries failures next interval',
      () async {
        await create(name: 'broken');
        await create(name: 'healthy');
        final disabled = await create(name: 'disabled');
        await update(disabled, enabled: false);
        final enabled = (await service.list())
            .where((value) => value.enabled)
            .toList();
        final broken = enabled.first;
        final healthy = enabled.last;
        respond = (request) async => request.url.toString() == broken.url
            ? http.Response('Unavailable', 503)
            : _calendarResponse();

        await service.refreshDue();
        expect(
          requests.map((request) => request.url.path),
          unorderedEquals(['/broken.ics', '/healthy.ics']),
        );
        expect(
          (await repository.listItems()).single.collectionId,
          healthy.collectionId,
        );
        final failure = (await service.listLogs(broken.id)).single;
        expect(failure.status, 'failed');
        expect(failure.httpStatus, 503);
        expect(failure.fetchedAt, now);
        expect(await service.listLogs(disabled.id), isEmpty);

        now = now.add(const Duration(minutes: 59));
        await service.refreshDue();
        expect(requests, hasLength(2));

        now = now.add(const Duration(minutes: 1));
        respond = (_) async => _calendarResponse();
        await service.refreshDue();
        expect(requests, hasLength(4));
        expect(await repository.listItems(), hasLength(2));
        final recovered = (await service.list()).singleWhere(
          (subscription) => subscription.id == broken.id,
        );
        expect(recovered.lastError, isNull);
        expect(recovered.lastSuccessAt, now);
        expect(await service.listLogs(broken.id), hasLength(2));
      },
    );

    test('manual refresh reports failures and records them', () async {
      final created = await create();
      respond = (_) async => http.Response('Unavailable', 503);

      await expectLater(
        service.refresh(created),
        throwsA(isA<SubscriptionFetchException>()),
      );
      expect((await service.listLogs(created.id)).single.httpStatus, 503);
      expect((await service.list()).single.lastFetchedAt, now);
      expect(await repository.listItems(), isEmpty);
    });

    test(
      'overlapping manual and scheduled refresh share the same fetch',
      () async {
        final created = await create();
        final started = Completer<void>();
        final response = Completer<http.Response>();
        respond = (_) {
          if (!started.isCompleted) started.complete();
          return response.future;
        };
        final manual = service.refresh(created);
        await started.future;
        final scheduled = service.refreshDue();
        final duplicate = service.refresh(created);
        await repository.listSubscriptions();
        await Future<void>.delayed(Duration.zero);
        expect(requests, hasLength(1));

        response.complete(_calendarResponse());
        await Future.wait([manual, scheduled, duplicate]);
        expect(await service.listLogs(created.id), hasLength(1));
        expect(await repository.listItems(), hasLength(1));
      },
    );

    test(
      're-enabling starts a new fetch while an old fetch is pending',
      () async {
        final created = await create();
        final started = Completer<void>();
        final oldResponse = Completer<http.Response>();
        respond = (_) {
          if (requests.length == 1) {
            started.complete();
            return oldResponse.future;
          }
          return Future.value(_calendarResponse(title: 'Current meeting'));
        };
        final oldRefresh = expectLater(
          service.refresh(created),
          throwsA(isA<RepositoryConflict>()),
        );
        await started.future;
        final disabled = await update(created, enabled: false);
        await update(disabled, enabled: true);
        expect(requests, hasLength(2));
        expect((await repository.listItems()).single.title, 'Current meeting');

        oldResponse.complete(_calendarResponse(title: 'Outdated meeting'));
        await oldRefresh;
        expect((await repository.listItems()).single.title, 'Current meeting');
        expect(await service.listLogs(created.id), hasLength(1));
        expect((await service.list()).single.lastError, isNull);
      },
    );

    test(
      'stopping a scan skips later sources without blocking manual refresh',
      () async {
        await create(name: 'first');
        await create(name: 'second');
        final started = Completer<void>();
        final response = Completer<http.Response>();
        respond = (_) {
          if (requests.length == 1) {
            started.complete();
            return response.future;
          }
          return Future.value(_calendarResponse());
        };

        final scheduled = service.refreshDue();
        await started.future;
        service.stopAutoRefresh();
        response.complete(_calendarResponse());
        await scheduled;
        expect(requests, hasLength(1));
        expect(await repository.listItems(), hasLength(1));

        final remaining = (await service.list()).singleWhere(
          (subscription) => subscription.lastFetchedAt == null,
        );
        await service.refresh(remaining);
        expect(requests, hasLength(2));
        expect(await repository.listItems(), hasLength(2));
      },
    );

    test(
      'close prevents in-flight requests from writing items or logs',
      () async {
        final created = await create();
        final started = Completer<void>();
        final response = Completer<http.Response>();
        respond = (_) {
          started.complete();
          return response.future;
        };
        final completed = expectLater(
          service.refresh(created),
          throwsA(anything),
        );
        await started.future;
        service.close();
        response.complete(_calendarResponse());
        await completed;

        expect(await repository.listItems(), isEmpty);
        expect(await service.listLogs(created.id), isEmpty);
        expect((await service.list()).single.version, created.version);
      },
    );
  });

  testWidgets(
    'auto-refresh checks immediately, ticks, pauses and stops on close',
    (tester) async {
      final repository = _TimerRepository();
      final service = SubscriptionService(
        repository: repository,
        localIcsService: const LocalIcsService(),
        activeTimezone: () => 'Asia/Shanghai',
        runMutation: _runMutation,
        fetchClient: SubscriptionFetchClient(
          client: MockClient((_) async => _calendarResponse()),
        ),
      );
      addTearDown(service.close);

      service.startAutoRefresh();
      await tester.pump();
      expect(repository.listCalls, 1);
      await tester.pump(const Duration(seconds: 59));
      expect(repository.listCalls, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(repository.listCalls, 2);

      service.stopAutoRefresh();
      await tester.pump(const Duration(minutes: 2));
      expect(repository.listCalls, 2);
      service.startAutoRefresh();
      await tester.pump();
      expect(repository.listCalls, 3);
      service.close();
      await tester.pump(const Duration(minutes: 2));
      expect(repository.listCalls, 3);
    },
  );
}

Future<void> _runMutation(
  Future<void> Function() operation, {
  bool reloadItems = true,
}) => operation();

http.Response _calendarResponse({String title = 'Team meeting'}) =>
    http.Response(
      'BEGIN:VCALENDAR\r\n'
      'VERSION:2.0\r\n'
      'PRODID:-//EasyCalendar//Subscription Test//EN\r\n'
      'BEGIN:VEVENT\r\n'
      'UID:meeting@example.com\r\n'
      'DTSTART:20261002T010000Z\r\n'
      'DTEND:20261002T020000Z\r\n'
      'SUMMARY:$title\r\n'
      'LOCATION:Room 1\r\n'
      'END:VEVENT\r\n'
      'END:VCALENDAR\r\n',
      200,
      headers: {
        'etag': '"v1"',
        'last-modified': 'Thu, 01 Oct 2026 00:00:00 GMT',
      },
    );

class _TimerRepository implements ItemRepository {
  int listCalls = 0;

  @override
  Future<List<CalendarSubscription>> listSubscriptions() async {
    listCalls += 1;
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
  syncEnabled: true,
  syncRetryLimit: 8,
  notificationsEnabled: false,
);
