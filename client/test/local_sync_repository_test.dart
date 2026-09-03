import 'dart:io';

import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/data/item_repository.dart';
import 'package:easy_calendar/data/local_cycle_repository.dart';
import 'package:easy_calendar/data/local_item_repository.dart';
import 'package:easy_calendar/data/local_ics_service.dart';
import 'package:easy_calendar/data/transfer_models.dart';
import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/domain/cycle_record.dart';
import 'package:easy_calendar/domain/recurrence.dart';
import 'package:easy_calendar/sync/sync_models.dart';
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

  test('default collection and local mutations are queued for push', () async {
    final initial = await repository.listPendingChanges(now: DateTime.now());
    expect(initial.single.entityType, 'collection');

    await repository.createItem(
      const ItemDraft(
        type: ItemType.task,
        title: 'Offline task',
        timezone: 'Asia/Shanghai',
      ),
    );
    final pending = await repository.listPendingChanges(now: DateTime.now());

    expect(pending.map((change) => change.entityType), ['collection', 'item']);
  });

  test(
    'queues a subscription collection before its dependent subscription',
    () async {
      final created = await repository.createSubscription(
        title: 'Team calendar',
        url: 'https://calendar.example.com/team.ics',
        refreshIntervalMinutes: 180,
        tags: const [],
      );

      final pending = await repository.listPendingChanges(now: DateTime.now());
      final collectionIndex = pending.indexWhere(
        (change) =>
            change.entityType == 'collection' &&
            change.entityId == created.collectionId,
      );
      final subscriptionIndex = pending.indexWhere(
        (change) =>
            change.entityType == 'subscription' &&
            change.entityId == created.id,
      );

      expect(collectionIndex, greaterThanOrEqualTo(0));
      expect(subscriptionIndex, greaterThan(collectionIndex));
    },
  );

  test('tag migration replaces and deduplicates tags atomically', () async {
    await repository.createItem(
      const ItemDraft(
        type: ItemType.task,
        title: 'Tagged task',
        timezone: 'Asia/Shanghai',
        tags: ['work', 'focus'],
      ),
    );
    await repository.createItem(
      const ItemDraft(
        type: ItemType.task,
        title: 'Unrelated task',
        timezone: 'Asia/Shanghai',
        tags: ['personal'],
      ),
    );

    await repository.deleteTag('work', migrateTo: 'focus');

    final items = await repository.listItems();
    final tagged = items.singleWhere((item) => item.title == 'Tagged task');
    final unrelated = items.singleWhere(
      (item) => item.title == 'Unrelated task',
    );
    expect(tagged.tags, ['focus']);
    expect(tagged.version, 2);
    expect(unrelated.tags, ['personal']);
    expect(unrelated.version, 1);
  });

  test('deleting a tag moves its items to the recycle bin', () async {
    final tagged = await repository.createItem(
      const ItemDraft(
        type: ItemType.task,
        title: 'Tagged task',
        timezone: 'Asia/Shanghai',
        tags: ['obsolete'],
      ),
    );
    await repository.createItem(
      const ItemDraft(
        type: ItemType.task,
        title: 'Unrelated task',
        timezone: 'Asia/Shanghai',
        tags: ['active'],
      ),
    );

    await repository.deleteTag('obsolete');

    expect((await repository.listItems()).single.title, 'Unrelated task');
    final deleted = (await repository.listDeletedItems()).singleWhere(
      (item) => item.id == tagged.id,
    );
    expect(deleted.deletedAt, isNotNull);
    expect(deleted.version, 2);
  });

  test(
    'tag migration updates subscription metadata for future refreshes',
    () async {
      await repository.createSubscription(
        title: 'Course calendar',
        url: 'https://calendar.example.com/course.ics',
        refreshIntervalMinutes: 60,
        tags: const ['course', 'work'],
      );

      await repository.deleteTag('work', migrateTo: 'study');

      final subscription = (await repository.listSubscriptions()).single;
      expect(subscription.tags, ['course', 'study']);
      expect(subscription.version, 2);
    },
  );

  test('remote batch and cursor commit atomically', () async {
    final change = _remoteItem('item_remote', 'Remote task');
    await repository.applyRemoteBatch([change], 'cur_1');

    expect((await repository.listItems()).single.title, 'Remote task');
    expect(await repository.loadRemoteCursor(), 'cur_1');

    final invalid = RemoteSyncChange(
      changeId: 'bad_change',
      deviceId: 'other-device',
      entityType: 'unknown',
      entityId: 'item_bad',
      operation: 'create',
      version: 1,
      updatedAt: DateTime.utc(2026, 8, 11, 9),
      payload: const {'id': 'item_bad', 'version': 1},
    );
    await expectLater(
      repository.applyRemoteBatch([
        _remoteItem('item_rolled_back', 'Should rollback'),
        invalid,
      ], 'cur_3'),
      throwsFormatException,
    );

    expect(
      (await repository.listItems()).map((item) => item.id),
      isNot(contains('item_rolled_back')),
    );
    expect(await repository.loadRemoteCursor(), 'cur_1');
  });

  test(
    'cycle aggregates use the existing outbox and remote apply path',
    () async {
      final cycles = LocalCycleRepository(
        databaseProvider: repository.openSharedDatabase,
        syncOutboxWriter: repository.writeCycleSyncOutbox,
      );
      final created = await cycles.createPeriod(
        CyclePeriodDraft(
          startDate: DateTime(2026, 8, 1),
          endDate: DateTime(2026, 8, 5),
        ),
        dailyLogs: [
          CycleDailyLogDraft(
            date: DateTime(2026, 8, 1),
            bleedingLevel: CycleFlowLevel.medium,
          ),
        ],
      );
      final pending = await repository.listPendingChanges(now: DateTime.now());
      final cycleChange = pending.singleWhere(
        (change) => change.entityType == 'cycle_period',
      );
      expect(cycleChange.entityId, created.id);
      expect(cycleChange.payload, isNot(contains('prediction')));

      const remoteId = 'cycle_remote';
      const updatedAt = '2099-08-11T08:00:00.000Z';
      await repository.applyRemoteBatch([
        RemoteSyncChange(
          changeId: 'change_cycle_remote',
          deviceId: 'other-device',
          entityType: 'cycle_period',
          entityId: remoteId,
          operation: 'create',
          version: 1,
          updatedAt: DateTime.parse(updatedAt),
          payload: const {
            'id': remoteId,
            'start_date': '2099-08-01',
            'end_date': '2099-08-04',
            'excluded_from_prediction': false,
            'context': null,
            'created_at': updatedAt,
            'updated_at': updatedAt,
            'deleted_at': null,
            'version': 1,
            'daily_logs': [
              {
                'date': '2099-08-01',
                'bleeding_level': 'light',
                'spotting': false,
                'symptoms': [],
                'updated_at': updatedAt,
              },
            ],
          },
        ),
      ], 'cur_cycle');

      expect(
        (await cycles.listPeriods()).map((period) => period.id),
        contains(remoteId),
      );
      expect(
        (await cycles.listDailyLogs(periodId: remoteId)).single.bleedingLevel,
        CycleFlowLevel.light,
      );
    },
  );

  test('only retries cycle failures rejected by the legacy protocol', () async {
    final cycles = LocalCycleRepository(
      databaseProvider: repository.openSharedDatabase,
      syncOutboxWriter: repository.writeCycleSyncOutbox,
    );
    final settings = await cycles.loadSettings();
    await cycles.saveSettings(
      settings.copyWith(
        enabled: true,
        updatedAt: DateTime.utc(2026, 9, 1),
        version: settings.version + 1,
      ),
    );
    await cycles.createPeriod(
      CyclePeriodDraft(startDate: DateTime(2026, 8, 1)),
    );
    final pending = await repository.listPendingChanges(now: DateTime.now());
    final settingsChange = pending.singleWhere(
      (change) => change.entityType == 'cycle_settings',
    );
    final periodChange = pending.singleWhere(
      (change) => change.entityType == 'cycle_period',
    );
    final collectionChange = pending.singleWhere(
      (change) => change.entityType == 'collection',
    );
    await repository.recordPermanentFailures([
      SyncRejection(
        changeId: settingsChange.changeId,
        code: 'transport_rejected',
        message: 'entity_type is invalid',
      ),
      SyncRejection(
        changeId: periodChange.changeId,
        code: 'constraint_violation',
        message: 'invalid period',
      ),
      SyncRejection(
        changeId: collectionChange.changeId,
        code: 'transport_rejected',
        message: 'entity_type is invalid',
      ),
    ]);

    expect(await repository.resetRetryablePermanentFailures(), 1);

    final retryable = await repository.listPendingChanges(now: DateTime.now());
    expect(retryable.map((change) => change.changeId), [
      settingsChange.changeId,
    ]);
    expect(await repository.loadPermanentFailureMessage(), isNotNull);
  });

  test('retries generic constraint failures during manual sync', () async {
    final created = await repository.createItem(
      const ItemDraft(
        type: ItemType.task,
        title: 'Retryable task',
        timezone: 'Asia/Shanghai',
      ),
    );
    final itemChange = (await repository.listPendingChanges(
      now: DateTime.now(),
    )).singleWhere((change) => change.entityId == created.id);

    await repository.recordPermanentFailures([
      SyncRejection(
        changeId: itemChange.changeId,
        code: 'constraint_violation',
        message: 'Change could not be applied',
      ),
    ]);

    expect(await repository.resetRetryablePermanentFailures(), 1);
    expect(
      (await repository.listPendingChanges(
        now: DateTime.now(),
      )).map((change) => change.changeId),
      contains(itemChange.changeId),
    );
  });

  test('a winning unsent local edit is not overwritten by pull', () async {
    final local = await repository.createItem(
      const ItemDraft(
        type: ItemType.task,
        title: 'Local winner',
        timezone: 'Asia/Shanghai',
      ),
    );
    final remoteLoser = _remoteItem(
      local.id,
      'Remote loser',
      timestamp: '2026-08-11T08:00:00.000Z',
    );

    await repository.applyRemoteBatch([remoteLoser], 'cur_local_wins');

    expect((await repository.listItems()).single.title, 'Local winner');
    final history = await repository.listSyncConflicts();
    expect(history.single.winner.payload['title'], 'Local winner');
    expect(history.single.loser.payload['title'], 'Remote loser');
  });

  test(
    'pulling accepted changes from the same device is only a replay',
    () async {
      final created = await repository.createItem(
        const ItemDraft(
          type: ItemType.task,
          title: 'First local version',
          timezone: 'Asia/Shanghai',
        ),
      );
      await repository.updateItem(
        created,
        const ItemDraft(
          type: ItemType.task,
          title: 'Locally pushed',
          timezone: 'Asia/Shanghai',
        ),
      );
      final pending = await repository.listPendingChanges(now: DateTime.now());
      final replay = pending
          .map(
            (change) => RemoteSyncChange(
              changeId: change.changeId,
              deviceId: change.deviceId,
              entityType: change.entityType,
              entityId: change.entityId,
              operation: change.operation,
              version: change.version,
              updatedAt: change.updatedAt,
              payload: change.payload,
            ),
          )
          .toList();

      await repository.applyRemoteBatch(replay, 'cur_replay');

      expect(await repository.listSyncConflicts(), isEmpty);
      expect((await repository.listItems()).single.title, 'Locally pushed');
    },
  );

  test(
    'a remote winner replaces local state and keeps recovery data',
    () async {
      final local = await repository.createItem(
        const ItemDraft(
          type: ItemType.task,
          title: 'Recoverable local version',
          timezone: 'Asia/Shanghai',
        ),
      );
      final remoteWinner = _remoteItem(
        local.id,
        'Remote winner',
        timestamp: '2099-08-11T08:00:00.000Z',
      );

      await repository.applyRemoteBatch([remoteWinner], 'cur_remote_wins');

      expect((await repository.listItems()).single.title, 'Remote winner');
      final history = await repository.listSyncConflicts();
      expect(history.single.winner.payload['title'], 'Remote winner');
      expect(
        history.single.loser.payload['title'],
        'Recoverable local version',
      );
    },
  );

  test('persists device name and tag color preferences locally', () async {
    final defaults = ClientPreferences(
      apiUrl: _config.apiUrl,
      featureApiUrl: 'https://core.example.com',
      syncEnabled: _config.syncEnabled,
      notificationsEnabled: _config.notificationsEnabled,
    );
    expect(
      (await repository.loadPreferences(defaults)).onboardingCompleted,
      isFalse,
    );
    await repository.savePreferences(
      defaults.copyWith(
        deviceName: '工作电脑',
        tagColors: {'工作': 0xFF2563EB},
        onboardingCompleted: true,
      ),
    );

    final loaded = await repository.loadPreferences(defaults);

    expect(loaded.deviceName, '工作电脑');
    expect(loaded.featureApiUrl, 'https://core.example.com');
    expect(loaded.tagColors, {'工作': 0xFF2563EB});
    expect(loaded.onboardingCompleted, isTrue);

    await repository.savePreferences(
      defaults.copyWith(
        timezone: 'UTC',
        localeName: 'en',
        firstDayOfWeek: 7,
        clockFormat: ClockFormat.hour12,
      ),
    );
    final localized = await repository.loadPreferences(defaults);
    expect(localized.timezone, 'UTC');
    expect(localized.localeName, 'en');
    expect(localized.firstDayOfWeek, 7);
    expect(localized.clockFormat, ClockFormat.hour12);
  });

  test(
    'changing display timezone does not rewrite stored UTC instants',
    () async {
      final start = DateTime.utc(2026, 8, 18, 7, 30);
      await repository.createItem(
        ItemDraft(
          type: ItemType.event,
          title: 'Timezone invariant event',
          startAt: start,
          endAt: start.add(const Duration(hours: 1)),
          timezone: 'UTC',
        ),
      );
      final defaults = ClientPreferences(
        apiUrl: _config.apiUrl,
        syncEnabled: _config.syncEnabled,
        notificationsEnabled: _config.notificationsEnabled,
      );

      await repository.savePreferences(
        defaults.copyWith(timezone: 'America/Los_Angeles'),
      );

      final stored = (await repository.listItems()).single;
      expect(stored.startAt, start);
      expect(stored.endAt, start.add(const Duration(hours: 1)));
    },
  );

  test(
    'runtime settings drive new collection and outbox device identity',
    () async {
      await repository.configureRuntime(
        deviceId: 'lvxin-windows',
        defaultCollectionId: 'collection_shared',
        defaultCollectionName: '共享日历',
      );
      await repository.createItem(
        const ItemDraft(
          type: ItemType.task,
          title: 'Runtime settings task',
          timezone: 'Asia/Shanghai',
        ),
      );

      final item = (await repository.listItems()).single;
      final pending = await repository.listPendingChanges(now: DateTime.now());

      expect(item.collectionId, 'collection_shared');
      expect(
        pending.where((change) => change.entityId == item.id).single.deviceId,
        'lvxin-windows',
      );
      expect(
        (await repository.listCollections()).map((value) => value.id),
        contains('collection_shared'),
      );
    },
  );

  test('persists recurrence and includes it in the sync payload', () async {
    await repository.createItem(
      ItemDraft(
        type: ItemType.event,
        title: 'Weekly event',
        startAt: DateTime.utc(2026, 8, 3, 1),
        endAt: DateTime.utc(2026, 8, 3, 2),
        timezone: 'Asia/Shanghai',
        recurrence: const RecurrenceRule(rrule: 'FREQ=WEEKLY;BYDAY=MO'),
      ),
    );

    final loaded = (await repository.listItems()).single;
    final pending = await repository.listPendingChanges(now: DateTime.now());
    final itemChange = pending.last;

    expect(loaded.recurrence?.rrule, 'FREQ=WEEKLY;BYDAY=MO');
    expect(
      (itemChange.payload['recurrence'] as Map<String, Object?>)['rrule'],
      'FREQ=WEEKLY;BYDAY=MO',
    );
  });

  test('creates, updates and soft deletes local collections', () async {
    final created = await repository.createCollection(
      name: 'Work',
      color: 0xFF0F766E,
    );
    final updated = await repository.updateCollection(
      created,
      name: 'Projects',
      color: 0xFF7A5AF8,
    );

    expect(updated.name, 'Projects');
    expect((await repository.listCollections()), hasLength(2));

    await repository.deleteCollection(updated);

    expect((await repository.listCollections()), hasLength(1));
    final operations =
        (await repository.listPendingChanges(now: DateTime.now()))
            .where((change) => change.entityId == created.id)
            .map((change) => change.operation);
    expect(operations, ['create', 'update', 'delete']);
  });

  test(
    'connecting an existing collection does not publish a create change',
    () async {
      final before = await repository.listPendingChanges(now: DateTime.now());

      final connected = await repository.connectCollection(
        id: 'collection_shared',
        name: 'Shared',
        color: 0xFF0F766E,
      );

      expect(connected.id, 'collection_shared');
      expect(connected.version, 0);
      expect(
        (await repository.listPendingChanges(now: DateTime.now())).length,
        before.length,
      );
      expect(
        (await repository.listCollections())
            .singleWhere((value) => value.id == connected.id)
            .name,
        'Shared',
      );
    },
  );

  test('owns subscription lifecycle and readonly collection locally', () async {
    final created = await repository.createSubscription(
      title: 'Team calendar',
      url: 'webcal://example.com/team.ics',
      refreshIntervalMinutes: 180,
      tags: const ['team'],
    );

    expect(created.url, 'https://example.com/team.ics');
    expect(created.enabled, isTrue);
    expect(created.refreshIntervalMinutes, 180);
    expect(created.tags, ['team']);
    final collection = (await repository.listCollections()).singleWhere(
      (value) => value.id == created.collectionId,
    );
    expect(collection.readonly, isTrue);
    expect(collection.kind, 'subscription');
    await expectLater(
      repository.createItem(
        ItemDraft(
          collectionId: collection.id,
          type: ItemType.event,
          title: 'Cannot edit',
          startAt: DateTime.utc(2026, 8, 18),
          timezone: 'UTC',
        ),
      ),
      throwsA(isA<RepositoryConflict>()),
    );

    final updated = await repository.updateSubscription(
      created,
      title: 'Updated team calendar',
      url: created.url,
      enabled: false,
      refreshIntervalMinutes: 360,
      tags: const ['shared'],
    );
    expect(updated.version, 2);
    expect(updated.enabled, isFalse);
    expect(updated.refreshIntervalMinutes, 360);
    expect(updated.tags, ['shared']);
    expect(
      (await repository.listCollections())
          .singleWhere((value) => value.id == created.collectionId)
          .name,
      'Updated team calendar',
    );

    await repository.deleteSubscription(updated);
    expect(await repository.listSubscriptions(), isEmpty);
    expect(
      (await repository.listCollections()).map((value) => value.id),
      isNot(contains(created.collectionId)),
    );
    final operations =
        (await repository.listPendingChanges(now: DateTime.now()))
            .where((change) => change.entityId == created.id)
            .map((change) => change.operation);
    expect(operations, ['create', 'update', 'delete']);
  });

  test(
    'applies subscription refreshes atomically with stable item ids',
    () async {
      final created = await repository.createSubscription(
        title: 'Team calendar',
        url: 'https://example.com/team.ics',
        refreshIntervalMinutes: 60,
        tags: const ['team'],
      );
      final firstFetch = DateTime.utc(2026, 8, 18, 1);
      final firstLog = await repository.applySubscriptionRefresh(
        created,
        events: [
          LocalIcsEvent(
            externalId: 'meeting@example.com',
            draft: ItemDraft(
              type: ItemType.event,
              title: 'Team meeting',
              startAt: DateTime.utc(2026, 8, 19, 1),
              endAt: DateTime.utc(2026, 8, 19, 2),
              timezone: 'UTC',
            ),
          ),
        ],
        notModified: false,
        httpStatus: 200,
        fetchedAt: firstFetch,
        etag: '"v1"',
        sourceHash: 'hash-v1',
      );

      expect(firstLog.createdCount, 1);
      final firstItem = (await repository.listItems()).single;
      expect(firstItem.collectionId, created.collectionId);
      expect(firstItem.title, 'Team meeting');
      expect(firstItem.tags, ['team']);
      final refreshed = (await repository.listSubscriptions()).single;
      expect(refreshed.etag, '"v1"');
      expect(refreshed.sourceHash, 'hash-v1');

      final unchangedLog = await repository.applySubscriptionRefresh(
        refreshed,
        events: const [],
        notModified: true,
        httpStatus: 304,
        fetchedAt: DateTime.utc(2026, 8, 18, 2),
        etag: refreshed.etag,
        sourceHash: refreshed.sourceHash,
      );
      expect(unchangedLog.status, 'not_modified');
      expect((await repository.listItems()).single.id, firstItem.id);
      final logs = await repository.listSubscriptionFetchLogs(created.id);
      expect(logs.map((value) => value.status), ['not_modified', 'success']);

      final pending = await repository.listPendingChanges(now: DateTime.now());
      expect(
        pending
            .where((change) => change.entityId == firstItem.id)
            .single
            .operation,
        'create',
      );
    },
  );

  test('schema v2 upgrades with pending entity heads intact', () async {
    final directory = await Directory.systemTemp.createTemp(
      'easycalendar-sync-migration-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final databasePath = '${directory.path}/client.sqlite3';
    final original = LocalItemRepository(
      _config,
      databaseFactory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    await original.initialize();
    await original.createItem(
      const ItemDraft(
        type: ItemType.task,
        title: 'Pending before migration',
        timezone: 'Asia/Shanghai',
      ),
    );
    await original.close();

    final legacy = await databaseFactoryFfi.openDatabase(databasePath);
    await legacy.execute('DROP INDEX idx_client_sync_conflicts');
    await legacy.execute('DROP TABLE sync_conflicts');
    await legacy.execute('DROP TABLE sync_entity_heads');
    await legacy.execute('ALTER TABLE items DROP COLUMN recurrence_json');
    await legacy.execute('PRAGMA user_version = 2');
    await legacy.close();

    final migrated = LocalItemRepository(
      _config,
      databaseFactory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    await migrated.initialize();
    addTearDown(migrated.close);

    final migrationBackups = await migrated.listLocalDatabaseBackups();
    expect(migrationBackups, hasLength(1));
    expect(migrationBackups.single.reason, LocalBackupReason.migration);
    expect(migrationBackups.single.schemaVersion, 2);
    expect(await File(migrationBackups.single.path).exists(), isTrue);

    final pending = await migrated.listPendingChanges(now: DateTime.now());
    expect(pending.map((change) => change.entityType), ['collection', 'item']);
    final item = (await migrated.listItems()).single;
    await migrated.applyRemoteBatch([
      _remoteItem(item.id, 'Older remote value'),
    ], 'cur_after_migration');
    expect(
      (await migrated.listItems()).single.title,
      'Pending before migration',
    );
    expect(await migrated.listSyncConflicts(), hasLength(1));
  });

  test(
    'manual database snapshots restore data and preserve pre-restore state',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'easycalendar-local-recovery-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final stored = LocalItemRepository(
        _config,
        databaseFactory: databaseFactoryFfi,
        databasePath: '${directory.path}/client.sqlite3',
      );
      await stored.initialize();
      addTearDown(stored.close);
      await stored.createItem(
        const ItemDraft(
          type: ItemType.task,
          title: 'Included in snapshot',
          timezone: 'Asia/Shanghai',
        ),
      );
      final snapshot = await stored.createLocalDatabaseBackup();
      await stored.createItem(
        const ItemDraft(
          type: ItemType.task,
          title: 'Created after snapshot',
          timezone: 'Asia/Shanghai',
        ),
      );

      await stored.restoreLocalDatabaseBackup(snapshot.path);

      expect((await stored.listItems()).map((item) => item.title), [
        'Included in snapshot',
      ]);
      final backups = await stored.listLocalDatabaseBackups();
      expect(
        backups.map((item) => item.reason),
        contains(LocalBackupReason.preRestore),
      );
      await stored.deleteLocalDatabaseBackup(snapshot.path);
      expect(
        (await stored.listLocalDatabaseBackups()).map((item) => item.path),
        isNot(contains(snapshot.path)),
      );
    },
  );

  test('failed schema migration keeps a readable source backup', () async {
    final directory = await Directory.systemTemp.createTemp(
      'easycalendar-failed-migration-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final databasePath = '${directory.path}/client.sqlite3';
    final original = LocalItemRepository(
      _config,
      databaseFactory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    await original.initialize();
    await original.createItem(
      const ItemDraft(
        type: ItemType.task,
        title: 'Must survive failed migration',
        timezone: 'Asia/Shanghai',
      ),
    );
    await original.close();
    final incompatible = await databaseFactoryFfi.openDatabase(databasePath);
    await incompatible.execute('PRAGMA user_version = 3');
    await incompatible.close();

    final failing = LocalItemRepository(
      _config,
      databaseFactory: databaseFactoryFfi,
      databasePath: databasePath,
    );
    await expectLater(failing.initialize(), throwsA(anything));
    addTearDown(failing.close);

    final backups = await failing.listLocalDatabaseBackups();
    expect(backups.single.reason, LocalBackupReason.migration);
    expect(backups.single.schemaVersion, 3);
    final backupDatabase = await databaseFactoryFfi.openDatabase(
      backups.single.path,
    );
    addTearDown(backupDatabase.close);
    final items = await backupDatabase.query('items');
    expect(items.single['title'], 'Must survive failed migration');
  });
}

RemoteSyncChange _remoteItem(
  String id,
  String title, {
  String timestamp = '2026-08-11T08:00:00.000Z',
}) {
  return RemoteSyncChange(
    changeId: 'change_$id',
    deviceId: 'other-device',
    entityType: 'item',
    entityId: id,
    operation: 'create',
    version: 1,
    updatedAt: DateTime.parse(timestamp),
    payload: {
      'id': id,
      'collection_id': 'collection_local',
      'type': 'task',
      'title': title,
      'body': null,
      'start_at': null,
      'end_at': null,
      'due_at': null,
      'timezone': 'Asia/Shanghai',
      'all_day': false,
      'location': null,
      'status': 'todo',
      'priority': null,
      'reminders': [],
      'tags': [],
      'source': 'local',
      'metadata': {},
      'created_at': timestamp,
      'updated_at': timestamp,
      'deleted_at': null,
      'version': 1,
    },
  );
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
