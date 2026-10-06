import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/data/item_repository.dart';
import 'package:easy_calendar/data/local_ics_service.dart';
import 'package:easy_calendar/data/local_item_repository.dart';
import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/domain/subscription.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late LocalItemRepository repository;

  setUp(() async {
    sqfliteFfiInit();
    repository = LocalItemRepository(
      _config,
      databaseFactory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await repository.initialize();
  });

  tearDown(() => repository.close());

  Future<CalendarSubscription> createSubscription() =>
      repository.createSubscription(
        title: 'Team calendar',
        url: 'https://example.com/team.ics',
        refreshIntervalMinutes: 60,
        tags: const ['team'],
      );

  Future<CalendarSubscription> update(
    CalendarSubscription current, {
    required bool enabled,
    String? title,
    String? url,
  }) => repository.updateSubscription(
    current,
    title: title ?? current.title,
    url: url ?? current.url,
    enabled: enabled,
    refreshIntervalMinutes: current.refreshIntervalMinutes,
    tags: current.tags,
  );

  Future<SubscriptionFetchLog> refresh(CalendarSubscription current) =>
      repository.applySubscriptionRefresh(
        current,
        events: [
          LocalIcsEvent(
            externalId: 'meeting@example.com',
            draft: ItemDraft(
              type: ItemType.event,
              title: 'Team meeting',
              startAt: DateTime.utc(2026, 10, 2, 1),
              endAt: DateTime.utc(2026, 10, 2, 2),
              timezone: 'Asia/Shanghai',
              location: 'Room 1',
            ),
          ),
        ],
        notModified: false,
        httpStatus: 200,
        fetchedAt: DateTime.now(),
        etag: '"v1"',
        lastModified: 'Thu, 01 Oct 2026 00:00:00 GMT',
        sourceHash: 'hash-v1',
      );

  test(
    'disable removes only its items and re-enable restores stable IDs',
    () async {
      final local = await repository.createItem(
        const ItemDraft(
          type: ItemType.task,
          title: 'Local task',
          timezone: 'Asia/Shanghai',
        ),
      );
      final created = await createSubscription();
      final other = await createSubscription();
      await refresh(created);
      await refresh(other);
      final original = (await repository.listItems()).singleWhere(
        (item) => item.collectionId == created.collectionId,
      );
      final current = (await repository.listSubscriptions()).singleWhere(
        (subscription) => subscription.id == created.id,
      );
      final disabled = await update(current, enabled: false);

      expect(disabled.version, current.version + 1);
      expect(disabled.enabled, isFalse);
      expect(
        (await repository.listItems()).map((item) => item.collectionId),
        unorderedEquals([local.collectionId, other.collectionId]),
      );
      final deleted = (await repository.listDeletedItems()).single;
      expect(deleted.id, original.id);
      expect(deleted.version, original.version + 1);
      final deletes = (await repository.listPendingChanges(
        now: DateTime.now(),
      )).where((change) => change.operation == 'delete');
      expect(deletes, isEmpty);
      expect(
        (await repository.listCollections()).map((collection) => collection.id),
        contains(created.collectionId),
      );

      final enabled = await update(disabled, enabled: true);
      expect(enabled.version, disabled.version + 1);
      expect(enabled.etag, isNull);
      expect(enabled.lastModified, isNull);
      expect(enabled.sourceHash, isNull);
      expect(enabled.lastFetchedAt, isNull);
      expect(enabled.lastSuccessAt, isNull);
      expect(enabled.lastError, isNull);
      final log = await refresh(enabled);
      expect(log.httpStatus, 200);
      expect(log.updatedCount, 1);
      final restored = (await repository.listItems()).singleWhere(
        (item) => item.collectionId == created.collectionId,
      );
      expect(restored.id, original.id);
      expect(restored.version, deleted.version + 1);
      expect(restored.location, original.location);
      expect(restored.tags, ['team']);
      expect(await repository.listDeletedItems(), isEmpty);
      final changes = (await repository.listPendingChanges(
        now: DateTime.now(),
      )).where((change) => change.entityId == original.id);
      expect(changes, isEmpty);
    },
  );

  test(
    'disabled, replaced and deleted subscriptions reject old fetches',
    () async {
      final created = await createSubscription();
      final disabled = await update(created, enabled: false);
      for (final snapshot in [created, disabled]) {
        await expectLater(
          refresh(snapshot),
          throwsA(isA<RepositoryConflict>()),
        );
        await repository.recordSubscriptionRefreshFailure(
          snapshot,
          fetchedAt: DateTime.now(),
          error: 'Old request failed',
        );
      }
      expect(
        (await repository.listSubscriptions()).single.version,
        disabled.version,
      );
      expect(await repository.listSubscriptionFetchLogs(created.id), isEmpty);
      expect(await repository.listItems(), isEmpty);

      final enabled = await update(disabled, enabled: true);
      final edited = await update(
        enabled,
        enabled: true,
        url: 'https://example.com/replacement.ics',
      );
      for (final snapshot in [created, disabled, enabled]) {
        await expectLater(
          refresh(snapshot),
          throwsA(isA<RepositoryConflict>()),
        );
      }
      await repository.deleteSubscription(edited);
      await expectLater(refresh(edited), throwsA(isA<RepositoryConflict>()));
      await repository.recordSubscriptionRefreshFailure(
        edited,
        fetchedAt: DateTime.now(),
        error: 'Deleted request failed',
      );
      expect(await repository.listSubscriptions(), isEmpty);
      expect(await repository.listItems(), isEmpty);
      expect(await repository.listSubscriptionFetchLogs(created.id), isEmpty);
    },
  );

  test(
    'changing a subscription URL resets conditional fetch metadata',
    () async {
      final created = await createSubscription();
      await refresh(created);
      final current = (await repository.listSubscriptions()).single;
      expect(current.etag, isNotNull);
      expect(current.lastModified, isNotNull);
      expect(current.sourceHash, isNotNull);
      final updated = await update(
        current,
        enabled: true,
        url: 'https://example.com/replacement.ics',
      );
      expect(updated.etag, isNull);
      expect(updated.lastModified, isNull);
      expect(updated.sourceHash, isNull);
      expect(updated.lastFetchedAt, isNull);
      expect(updated.lastSuccessAt, isNull);
      expect(updated.version, current.version + 1);
    },
  );

  test(
    'edits survive fetch metadata changes but reject concurrent settings edits',
    () async {
      final created = await createSubscription();
      await refresh(created);
      final fetched = (await repository.listSubscriptions()).single;
      final afterFullFetch = await update(
        created,
        enabled: true,
        title: 'Saved after full fetch',
      );
      expect(afterFullFetch.version, fetched.version + 1);
      expect(afterFullFetch.lastFetchedAt, fetched.lastFetchedAt);
      expect(afterFullFetch.etag, fetched.etag);
      expect(afterFullFetch.lastModified, fetched.lastModified);
      expect(afterFullFetch.sourceHash, fetched.sourceHash);

      final nextFetch = fetched.lastFetchedAt!.add(const Duration(minutes: 1));
      await repository.applySubscriptionRefresh(
        afterFullFetch,
        events: const [],
        notModified: true,
        httpStatus: 304,
        fetchedAt: nextFetch,
        etag: fetched.etag,
        lastModified: fetched.lastModified,
        sourceHash: fetched.sourceHash,
      );
      final afterNotModified = await update(
        afterFullFetch,
        enabled: true,
        title: 'Saved after 304',
      );
      expect(afterNotModified.version, afterFullFetch.version + 2);
      expect(afterNotModified.lastFetchedAt, nextFetch);
      expect(afterNotModified.lastSuccessAt, nextFetch);
      expect(afterNotModified.etag, fetched.etag);
      expect(
        await repository.listSubscriptionFetchLogs(created.id),
        hasLength(2),
      );

      final renamed = await update(
        afterNotModified,
        enabled: true,
        title: 'Renamed elsewhere',
      );
      await expectLater(
        update(afterNotModified, enabled: false),
        throwsA(isA<RepositoryConflict>()),
      );
      final moved = await update(
        renamed,
        enabled: true,
        url: 'https://example.com/replacement.ics',
      );
      await expectLater(
        update(renamed, enabled: false),
        throwsA(isA<RepositoryConflict>()),
      );
      await update(moved, enabled: true);
      await expectLater(
        update(moved, enabled: false),
        throwsA(isA<RepositoryConflict>()),
      );
    },
  );

  test('subscription item deletion stays local', () async {
    final created = await createSubscription();
    await refresh(created);
    final current = (await repository.listSubscriptions()).single;
    final database = await repository.openSharedDatabase();
    await database.execute('''
      CREATE TRIGGER reject_item_delete BEFORE INSERT ON outbox
      WHEN NEW.entity_type = 'item' AND NEW.operation = 'delete'
      BEGIN SELECT RAISE(ABORT, 'outbox unavailable'); END
    ''');

    final disabled = await update(current, enabled: false);
    expect(disabled.enabled, isFalse);
    expect(disabled.version, current.version + 1);
    expect(
      (await repository.listItems()).where(
        (item) => item.collectionId == current.collectionId,
      ),
      isEmpty,
    );
    expect(
      (await repository.listPendingChanges(
        now: DateTime.now(),
      )).where((change) => change.operation == 'delete'),
      isEmpty,
    );
  });
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
