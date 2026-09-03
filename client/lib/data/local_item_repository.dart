import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import '../domain/item.dart';
import '../domain/recurrence.dart';
import '../domain/subscription.dart';
import '../sync/sync_models.dart';
import '../sync/sync_repository.dart';
import 'item_repository.dart';
import 'local_database_backup_store.dart';
import 'local_database_schema.dart';
import 'local_ics_service.dart';
import 'local_json_transfer_service.dart';
import 'local_preferences_store.dart';
import 'transfer_models.dart';

class LocalItemRepository
    implements
        ItemRepository,
        LocalRecoveryPort,
        RuntimeSettingsPort,
        SyncRepository {
  LocalItemRepository(
    this.config, {
    Uuid? uuid,
    DatabaseFactory? databaseFactory,
    String? databasePath,
  }) : _uuid = uuid ?? Uuid(),
       _databaseFactoryOverride = databaseFactory,
       _databasePathOverride = databasePath;

  final AppConfig config;
  final Uuid _uuid;
  final DatabaseFactory? _databaseFactoryOverride;
  final String? _databasePathOverride;
  Database? _database;
  late String _runtimeDeviceId = config.deviceId;
  late String _runtimeDefaultCollectionId = config.defaultCollectionId;
  late String _runtimeDefaultCollectionName = config.defaultCollectionName;

  static const schemaVersion = LocalDatabaseSchema.version;

  @override
  String? databasePath;

  @override
  Future<void> configureRuntime({
    required String deviceId,
    required String defaultCollectionId,
    required String defaultCollectionName,
  }) async {
    final nextDeviceId = deviceId.trim();
    final nextCollectionId = defaultCollectionId.trim();
    final nextCollectionName = defaultCollectionName.trim();
    if (nextDeviceId.isEmpty ||
        nextCollectionId.isEmpty ||
        nextCollectionName.isEmpty) {
      throw const FormatException('设备 ID、默认 Collection ID 和名称不能为空。');
    }
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{1,127}$').hasMatch(nextDeviceId)) {
      throw const FormatException('设备 ID 只能包含字母、数字、点、下划线和连字符。');
    }
    _runtimeDeviceId = nextDeviceId;
    _runtimeDefaultCollectionId = nextCollectionId;
    _runtimeDefaultCollectionName = nextCollectionName;
    await _ensureDefaultCollection();
  }

  Database get _db {
    final value = _database;
    if (value == null) {
      throw StateError('Repository has not been initialized');
    }
    return value;
  }

  Future<Database> openSharedDatabase() async {
    await initialize();
    return _db;
  }

  @override
  Future<void> initialize() async {
    if (_database != null) {
      return;
    }
    final configuredPath = _databasePathOverride;
    if (configuredPath == null) {
      final supportDirectory = await getApplicationSupportDirectory();
      await supportDirectory.create(recursive: true);
      databasePath = path.join(supportDirectory.path, config.databaseName);
    } else {
      databasePath = configuredPath;
    }
    final factory = _databaseFactoryOverride ?? _databaseFactory();
    await _backupStore(factory).backupBeforeMigrationIfNeeded();
    try {
      _database = await factory.openDatabase(
        databasePath!,
        options: OpenDatabaseOptions(
          version: schemaVersion,
          onConfigure: (database) async {
            await database.execute('PRAGMA foreign_keys = ON');
          },
          onCreate: LocalDatabaseSchema.create,
          onUpgrade: LocalDatabaseSchema.upgrade,
        ),
      );
      await _ensureDefaultCollection();
      await _ensureLegacySyncHeads();
    } catch (_) {
      // Do not leave a partially opened handle behind. The controller exposes
      // a retry action when startup fails, and retry must be able to reopen it.
      await _database?.close();
      _database = null;
      rethrow;
    }
  }

  @override
  Future<List<LocalDatabaseBackup>> listLocalDatabaseBackups() =>
      _backupStore().listBackups();

  @override
  Future<LocalDatabaseBackup> createLocalDatabaseBackup({
    LocalBackupReason reason = LocalBackupReason.manual,
  }) => _backupStore().createBackup(_db, reason: reason);

  @override
  Future<void> restoreLocalDatabaseBackup(String backupPath) async {
    final backupStore = _backupStore();
    final selected = await backupStore.validatedBackupFile(backupPath);
    final safety = _database == null
        ? await backupStore.copyBackup(
            reason: LocalBackupReason.preRestore,
            sourceSchemaVersion: await backupStore
                .closedDatabaseSchemaVersion(),
          )
        : await createLocalDatabaseBackup(reason: LocalBackupReason.preRestore);
    await close();
    try {
      await backupStore.replaceDatabaseWith(selected.path);
      await initialize();
    } catch (error) {
      await close();
      await backupStore.replaceDatabaseWith(safety.path);
      await initialize();
      throw RepositoryConflict('恢复失败，已回滚到恢复前状态：$error');
    }
  }

  @override
  Future<void> deleteLocalDatabaseBackup(String backupPath) =>
      _backupStore().deleteBackup(backupPath);

  LocalDatabaseBackupStore _backupStore([DatabaseFactory? factory]) =>
      LocalDatabaseBackupStore(
        databasePath: databasePath!,
        databaseFactory:
            factory ?? _databaseFactoryOverride ?? _databaseFactory(),
        currentSchemaVersion: schemaVersion,
      );

  DatabaseFactory _databaseFactory() {
    if (Platform.isAndroid || Platform.isIOS) {
      return mobile.databaseFactory;
    }
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      return databaseFactoryFfi;
    }
    throw UnsupportedError(
      'EasyCalendar requires Android, iOS, macOS, or Windows',
    );
  }

  Future<void> _ensureDefaultCollection() async {
    final now = _timeText(DateTime.now());
    await _db.transaction((transaction) async {
      final existing = await transaction.query(
        'collections',
        where: 'id = ?',
        whereArgs: [_runtimeDefaultCollectionId],
        limit: 1,
      );
      if (existing.isNotEmpty) return;
      await transaction.insert('collections', {
        'id': _runtimeDefaultCollectionId,
        'name': _runtimeDefaultCollectionName,
        'kind': 'local',
        'color': _colorText(config.defaultCollectionColor.toARGB32()),
        'readonly': 0,
        'created_at': now,
        'updated_at': now,
        'deleted_at': null,
        'version': 1,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      final rows = await transaction.query(
        'collections',
        where: 'id = ?',
        whereArgs: [_runtimeDefaultCollectionId],
        limit: 1,
      );
      await _writeCollectionOutbox(
        transaction,
        rows.single,
        operation: 'create',
      );
    });
  }

  Future<void> _ensureWritableCollection(String collectionId) async {
    final rows = await _db.query(
      'collections',
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [collectionId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const RepositoryConflict('Collection 不存在。');
    }
    if (rows.single['readonly'] == 1) {
      throw const RepositoryConflict('订阅 Collection 不能写入本地事项。');
    }
  }

  Future<void> _ensureLegacySyncHeads() async {
    await _db.transaction((transaction) async {
      for (final collection in await transaction.query('collections')) {
        if (await _hasSyncHead(transaction, 'collection', collection['id'])) {
          continue;
        }
        final payload = {
          'id': collection['id'],
          'name': collection['name'],
          'kind': collection['kind'],
          'color': collection['color'],
          'readonly': collection['readonly'] == 1,
          'created_at': collection['created_at'],
          'updated_at': collection['updated_at'],
          'deleted_at': collection['deleted_at'],
          'version': collection['version'],
        };
        await _upsertSyncHead(
          transaction,
          _legacyChange('collection', collection, payload),
        );
      }
      for (final itemRow in await transaction.query('items')) {
        if (await _hasSyncHead(transaction, 'item', itemRow['id'])) continue;
        final item = _itemFromRow(itemRow);
        await _upsertSyncHead(
          transaction,
          _legacyChange('item', itemRow, _itemPayload(item)),
        );
      }
      for (final subscription in await transaction.query('subscriptions')) {
        if (await _hasSyncHead(
          transaction,
          'subscription',
          subscription['id'],
        )) {
          continue;
        }
        final payload =
            (jsonDecode(subscription['payload_json'] as String)
                    as Map<String, dynamic>)
                .cast<String, Object?>();
        await _upsertSyncHead(
          transaction,
          _legacyChange('subscription', subscription, payload),
        );
      }
      for (final period in await transaction.query('cycle_periods')) {
        if (await _hasSyncHead(transaction, 'cycle_period', period['id'])) {
          continue;
        }
        final logs = await transaction.query(
          'cycle_daily_logs',
          where: 'period_id = ?',
          whereArgs: [period['id']],
          orderBy: 'date ASC',
        );
        final payload = {
          'id': period['id'],
          'start_date': period['start_date'],
          'end_date': period['end_date'],
          'excluded_from_prediction': period['excluded_from_prediction'] == 1,
          'context': period['context'],
          'created_at': period['created_at'],
          'updated_at': period['updated_at'],
          'deleted_at': period['deleted_at'],
          'version': period['version'],
          'daily_logs': logs
              .map(
                (log) => {
                  'date': log['date'],
                  'bleeding_level': log['bleeding_level'],
                  'spotting': log['spotting'] == 1,
                  'symptoms': jsonDecode(log['symptoms_json'] as String),
                  'updated_at': log['updated_at'],
                },
              )
              .toList(growable: false),
        };
        await writeCycleSyncOutbox(
          transaction,
          'cycle_period',
          period['id'] as String,
          period['deleted_at'] == null ? 'create' : 'delete',
          period['version'] as int,
          DateTime.parse(period['updated_at'] as String),
          payload,
        );
      }
      final settings = await transaction.query(
        'cycle_settings',
        where: 'id = 1',
        limit: 1,
      );
      if (settings.isNotEmpty &&
          (settings.single['enabled'] == 1 ||
              settings.single['forecast_horizon'] != 1 ||
              (settings.single['version'] as int? ?? 1) > 1) &&
          !await _hasSyncHead(transaction, 'cycle_settings', 'singleton')) {
        final row = settings.single;
        final payload = {
          'id': 'singleton',
          'enabled': row['enabled'] == 1,
          'forecast_horizon': row['forecast_horizon'],
          'version': row['version'] as int? ?? 1,
          'updated_at': row['updated_at'],
          'deleted_at': null,
        };
        await writeCycleSyncOutbox(
          transaction,
          'cycle_settings',
          'singleton',
          'update',
          row['version'] as int? ?? 1,
          DateTime.parse(row['updated_at'] as String),
          payload,
        );
      }
    });
  }

  RemoteSyncChange _legacyChange(
    String entityType,
    Map<String, Object?> row,
    Map<String, Object?> payload,
  ) => RemoteSyncChange(
    changeId: '0',
    deviceId: _runtimeDeviceId,
    entityType: entityType,
    entityId: row['id'] as String,
    operation: row['deleted_at'] == null ? 'update' : 'delete',
    version: row['version'] as int,
    updatedAt: DateTime.parse(row['updated_at'] as String),
    payload: payload,
  );

  static Future<bool> _hasSyncHead(
    Transaction transaction,
    String entityType,
    Object? entityId,
  ) async {
    final rows = await transaction.query(
      'sync_entity_heads',
      columns: ['entity_id'],
      where: 'entity_type = ? AND entity_id = ?',
      whereArgs: [entityType, entityId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<List<CalendarItem>> listItems({bool includeDeleted = false}) async {
    final rows = await _db.query(
      'items',
      where: includeDeleted ? null : 'deleted_at IS NULL',
      orderBy:
          'COALESCE(start_at, due_at) IS NULL, '
          'COALESCE(start_at, due_at), id',
    );
    return rows.map(_itemFromRow).toList(growable: false);
  }

  @override
  Future<List<CalendarCollection>> listCollections({
    bool includeDeleted = false,
  }) async {
    final rows = await _db.query(
      'collections',
      where: includeDeleted ? null : 'deleted_at IS NULL',
      orderBy: 'readonly, name, id',
    );
    return rows.map(_collectionFromRow).toList(growable: false);
  }

  @override
  Future<CalendarCollection> createCollection({
    required String name,
    required int color,
  }) async {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      throw const RepositoryConflict('Collection 名称不能为空。');
    }
    final now = DateTime.now();
    final collection = CalendarCollection(
      id: 'collection_${_uuid.v4()}',
      name: normalized,
      kind: 'local',
      color: color,
      readonly: false,
      createdAt: now,
      updatedAt: now,
      version: 1,
    );
    await _db.transaction((transaction) async {
      final row = _collectionToRow(collection);
      await transaction.insert('collections', row);
      await _writeCollectionOutbox(transaction, row, operation: 'create');
    });
    return collection;
  }

  @override
  Future<CalendarCollection> connectCollection({
    required String id,
    required String name,
    int? color,
  }) async {
    final normalizedId = id.trim();
    final normalizedName = name.trim();
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$').hasMatch(normalizedId) ||
        normalizedName.isEmpty ||
        normalizedName.length > 80) {
      throw const RepositoryConflict('日历配置码内容无效。');
    }
    final existingRows = await _db.query(
      'collections',
      where: 'id = ?',
      whereArgs: [normalizedId],
      limit: 1,
    );
    if (existingRows.isNotEmpty && existingRows.single['deleted_at'] == null) {
      final existing = _collectionFromRow(existingRows.single);
      if (existing.readonly) {
        throw const RepositoryConflict('只读订阅日历不能作为同步默认日历。');
      }
      return existing;
    }
    final now = DateTime.now();
    final collection = CalendarCollection(
      id: normalizedId,
      name: normalizedName,
      kind: 'local',
      color: color,
      readonly: false,
      createdAt: now,
      updatedAt: now,
      version: 0,
    );
    await _db.insert(
      'collections',
      _collectionToRow(collection),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return collection;
  }

  @override
  Future<CalendarCollection> updateCollection(
    CalendarCollection current, {
    required String name,
    required int color,
  }) async {
    if (current.readonly) {
      throw const RepositoryConflict('订阅 Collection 不能在本地编辑。');
    }
    final normalized = name.trim();
    if (normalized.isEmpty) {
      throw const RepositoryConflict('Collection 名称不能为空。');
    }
    final updated = CalendarCollection(
      id: current.id,
      name: normalized,
      kind: current.kind,
      color: color,
      readonly: false,
      createdAt: current.createdAt,
      updatedAt: DateTime.now(),
      version: current.version + 1,
    );
    await _db.transaction((transaction) async {
      final row = _collectionToRow(updated);
      final count = await transaction.update(
        'collections',
        row,
        where: 'id = ? AND version = ? AND deleted_at IS NULL',
        whereArgs: [current.id, current.version],
      );
      if (count != 1) {
        throw const RepositoryConflict('Collection 已更新，请刷新后重试。');
      }
      await _writeCollectionOutbox(transaction, row, operation: 'update');
    });
    return updated;
  }

  @override
  Future<void> deleteCollection(CalendarCollection current) async {
    if (current.id == _runtimeDefaultCollectionId) {
      throw const RepositoryConflict('默认 Collection 不能删除。');
    }
    if (current.readonly) {
      throw const RepositoryConflict('请从订阅入口删除只读 Collection。');
    }
    await _db.transaction((transaction) async {
      final itemRows = await transaction.rawQuery(
        'SELECT COUNT(*) AS item_count FROM items '
        'WHERE collection_id = ? AND deleted_at IS NULL',
        [current.id],
      );
      if ((itemRows.single['item_count'] as int? ?? 0) > 0) {
        throw const RepositoryConflict('请先移动或删除 Collection 中的事项。');
      }
      final deleted = CalendarCollection(
        id: current.id,
        name: current.name,
        kind: current.kind,
        color: current.color,
        readonly: current.readonly,
        createdAt: current.createdAt,
        updatedAt: DateTime.now(),
        deletedAt: DateTime.now(),
        version: current.version + 1,
      );
      final row = _collectionToRow(deleted);
      final count = await transaction.update(
        'collections',
        row,
        where: 'id = ? AND version = ? AND deleted_at IS NULL',
        whereArgs: [current.id, current.version],
      );
      if (count != 1) {
        throw const RepositoryConflict('Collection 已更新，请刷新后重试。');
      }
      await _writeCollectionOutbox(transaction, row, operation: 'delete');
    });
  }

  @override
  Future<CalendarItem> createItem(ItemDraft draft) async {
    _validateDraft(draft);
    final collectionId = draft.collectionId ?? _runtimeDefaultCollectionId;
    await _ensureWritableCollection(collectionId);
    final now = DateTime.now();
    final item = CalendarItem(
      id: 'item_${_uuid.v4()}',
      collectionId: collectionId,
      type: draft.type,
      title: draft.title.trim(),
      body: _optional(draft.body),
      startAt: draft.startAt,
      endAt: draft.endAt,
      dueAt: draft.dueAt,
      recurrence: draft.recurrence,
      timezone: draft.timezone,
      allDay: draft.allDay,
      location: _optional(draft.location),
      status: draft.status,
      priority: draft.priority,
      reminderEnabled: draft.reminderEnabled,
      reminderMinutes: draft.reminderMinutes,
      tags: _normalizeTags(draft.tags),
      createdAt: now,
      updatedAt: now,
      version: 1,
    );
    await _db.transaction((transaction) async {
      await transaction.insert('items', _itemToRow(item));
      await _writeOutbox(transaction, item, 'create');
    });
    return item;
  }

  @override
  Future<CalendarItem> updateItem(CalendarItem current, ItemDraft draft) async {
    _validateDraft(draft);
    final collectionId = draft.collectionId ?? current.collectionId;
    await _ensureWritableCollection(collectionId);
    final updated = CalendarItem(
      id: current.id,
      collectionId: collectionId,
      type: draft.type,
      title: draft.title.trim(),
      body: _optional(draft.body),
      startAt: draft.startAt,
      endAt: draft.endAt,
      dueAt: draft.dueAt,
      recurrence: draft.recurrence,
      timezone: draft.timezone,
      allDay: draft.allDay,
      location: _optional(draft.location),
      status: draft.status,
      priority: draft.priority,
      reminderEnabled: draft.reminderEnabled,
      reminderMinutes: draft.reminderMinutes,
      tags: _normalizeTags(draft.tags),
      createdAt: current.createdAt,
      updatedAt: DateTime.now(),
      version: current.version + 1,
    );
    await _db.transaction((transaction) async {
      final count = await transaction.update(
        'items',
        _itemToRow(updated),
        where: 'id = ? AND version = ? AND deleted_at IS NULL',
        whereArgs: [current.id, current.version],
      );
      if (count != 1) {
        throw const RepositoryConflict('事项已在其他操作中更新，请刷新后重试。');
      }
      await _writeOutbox(transaction, updated, 'update');
    });
    return updated;
  }

  @override
  Future<CalendarItem> setTaskCompleted(
    CalendarItem current, {
    required bool completed,
  }) {
    if (current.type != ItemType.task) {
      throw const RepositoryConflict('只有 Due 可以标记完成。');
    }
    return updateItem(
      current,
      ItemDraft(
        type: current.type,
        title: current.title,
        body: current.body,
        dueAt: current.dueAt,
        recurrence: null,
        timezone: current.timezone,
        status: completed ? ItemStatus.done : ItemStatus.todo,
        priority: current.priority,
        reminderEnabled: current.reminderEnabled,
        reminderMinutes: current.reminderMinutes,
        tags: current.tags,
      ),
    );
  }

  @override
  Future<void> deleteItem(CalendarItem current) async {
    final now = DateTime.now();
    final deleted = CalendarItem(
      id: current.id,
      collectionId: current.collectionId,
      type: current.type,
      title: current.title,
      body: current.body,
      startAt: current.startAt,
      endAt: current.endAt,
      dueAt: current.dueAt,
      recurrence: current.recurrence,
      timezone: current.timezone,
      allDay: current.allDay,
      location: current.location,
      status: current.status,
      priority: current.priority,
      reminderEnabled: current.reminderEnabled,
      reminderMinutes: current.reminderMinutes,
      tags: current.tags,
      createdAt: current.createdAt,
      updatedAt: now,
      deletedAt: now,
      version: current.version + 1,
    );
    await _db.transaction((transaction) async {
      final count = await transaction.update(
        'items',
        _itemToRow(deleted),
        where: 'id = ? AND version = ? AND deleted_at IS NULL',
        whereArgs: [current.id, current.version],
      );
      if (count != 1) {
        throw const RepositoryConflict('事项已被删除或更新，请刷新后重试。');
      }
      await _writeOutbox(transaction, deleted, 'delete');
    });
  }

  @override
  Future<void> deleteTag(String tag, {String? migrateTo}) async {
    final source = tag.trim();
    final target = migrateTo?.trim();
    if (source.isEmpty) {
      throw const RepositoryConflict('标签不能为空。');
    }
    if (migrateTo != null && (target!.isEmpty || target == source)) {
      throw const RepositoryConflict('目标标签必须与原标签不同。');
    }

    final now = DateTime.now();
    await _db.transaction((transaction) async {
      final itemRows = await transaction.query(
        'items',
        where: 'deleted_at IS NULL',
      );
      for (final row in itemRows) {
        final current = _itemFromRow(row);
        if (!current.tags.contains(source)) continue;
        final deletingItem = target == null;
        final nextTags = deletingItem
            ? current.tags
            : _normalizeTags([
                for (final currentTag in current.tags)
                  currentTag == source ? target : currentTag,
              ]);
        final updated = CalendarItem(
          id: current.id,
          collectionId: current.collectionId,
          type: current.type,
          title: current.title,
          body: current.body,
          startAt: current.startAt,
          endAt: current.endAt,
          dueAt: current.dueAt,
          recurrence: current.recurrence,
          timezone: current.timezone,
          allDay: current.allDay,
          location: current.location,
          status: current.status,
          priority: current.priority,
          reminderEnabled: current.reminderEnabled,
          reminderMinutes: current.reminderMinutes,
          tags: nextTags,
          createdAt: current.createdAt,
          updatedAt: now,
          deletedAt: deletingItem ? now : null,
          version: current.version + 1,
        );
        final count = await transaction.update(
          'items',
          _itemToRow(updated),
          where: 'id = ? AND version = ? AND deleted_at IS NULL',
          whereArgs: [current.id, current.version],
        );
        if (count != 1) {
          throw const RepositoryConflict('标签关联事项已更新，请刷新后重试。');
        }
        await _writeOutbox(
          transaction,
          updated,
          deletingItem ? 'delete' : 'update',
        );
      }

      final subscriptionRows = await transaction.query(
        'subscriptions',
        where: 'deleted_at IS NULL',
      );
      for (final row in subscriptionRows) {
        final payload = _subscriptionPayloadFromRow(row);
        final metadata = Map<String, Object?>.from(
          payload['metadata'] is Map
              ? (payload['metadata'] as Map).cast<String, Object?>()
              : const {},
        );
        final currentTags = (metadata['tags'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(growable: false);
        if (!currentTags.contains(source)) continue;
        metadata['tags'] = _normalizeTags([
          for (final currentTag in currentTags)
            currentTag == source ? target ?? '' : currentTag,
        ]);
        final updatedPayload = {
          ...payload,
          'metadata': metadata,
          'updated_at': _timeText(now),
          'version': (payload['version'] as int) + 1,
        };
        final count = await transaction.update(
          'subscriptions',
          _subscriptionRow(updatedPayload),
          where: 'id = ? AND version = ? AND deleted_at IS NULL',
          whereArgs: [payload['id'], payload['version']],
        );
        if (count != 1) {
          throw const RepositoryConflict('标签关联订阅已更新，请刷新后重试。');
        }
        await _writeSubscriptionOutbox(
          transaction,
          updatedPayload,
          operation: 'update',
        );
      }
    });
  }

  @override
  Future<CalendarItem> restoreItem(CalendarItem current) async {
    if (current.deletedAt == null) {
      throw const RepositoryConflict('事项未被删除。');
    }
    final restored = CalendarItem(
      id: current.id,
      collectionId: current.collectionId,
      type: current.type,
      title: current.title,
      body: current.body,
      startAt: current.startAt,
      endAt: current.endAt,
      dueAt: current.dueAt,
      recurrence: current.recurrence,
      timezone: current.timezone,
      allDay: current.allDay,
      location: current.location,
      status: current.status,
      priority: current.priority,
      reminderEnabled: current.reminderEnabled,
      reminderMinutes: current.reminderMinutes,
      tags: current.tags,
      createdAt: current.createdAt,
      updatedAt: DateTime.now(),
      deletedAt: null,
      version: current.version + 1,
    );
    await _db.transaction((transaction) async {
      final count = await transaction.update(
        'items',
        _itemToRow(restored),
        where: 'id = ? AND version = ? AND deleted_at IS NOT NULL',
        whereArgs: [current.id, current.version],
      );
      if (count != 1) {
        throw const RepositoryConflict('事项已被更新，请刷新后重试。');
      }
      await _writeOutbox(transaction, restored, 'update');
    });
    return restored;
  }

  @override
  Future<List<CalendarItem>> listDeletedItems() async {
    final rows = await _db.query(
      'items',
      where: 'deleted_at IS NOT NULL',
      orderBy: 'deleted_at DESC, id',
    );
    return rows.map(_itemFromRow).toList(growable: false);
  }

  @override
  Future<String> exportLocalJsonBackup() =>
      LocalJsonTransferService(_db).exportBackup();

  @override
  Future<TransferResult> previewLocalJsonImport(String content) =>
      LocalJsonTransferService(_db).previewImport(content);

  @override
  Future<void> commitLocalJsonImport(String content) =>
      LocalJsonTransferService(_db).commitImport(content);

  @override
  Future<List<CalendarSubscription>> listSubscriptions() async {
    final rows = await _db.query(
      'subscriptions',
      where: 'deleted_at IS NULL',
      orderBy: 'updated_at DESC, id',
    );
    return rows.map(_subscriptionFromRow).toList(growable: false);
  }

  @override
  Future<CalendarSubscription> createSubscription({
    required String title,
    required String url,
    required int refreshIntervalMinutes,
    required List<String> tags,
  }) async {
    final normalizedTitle = title.trim();
    final normalizedUrl = _validateSubscriptionUrl(url);
    final normalizedTags = _normalizeTags(tags);
    _validateRefreshInterval(refreshIntervalMinutes);
    if (normalizedTitle.isEmpty) {
      throw const RepositoryConflict('订阅名称不能为空。');
    }
    final now = DateTime.now();
    final subscriptionId = 'subscription_${_uuid.v4()}';
    final collectionId = 'collection_${_uuid.v4()}';
    final collection = {
      'id': collectionId,
      'name': normalizedTitle,
      'kind': 'subscription',
      'color': _colorText(config.defaultCollectionColor.toARGB32()),
      'readonly': 1,
      'created_at': _timeText(now),
      'updated_at': _timeText(now),
      'deleted_at': null,
      'version': 1,
    };
    final payload = _subscriptionPayload(
      id: subscriptionId,
      collectionId: collectionId,
      title: normalizedTitle,
      url: normalizedUrl,
      enabled: true,
      refreshIntervalMinutes: refreshIntervalMinutes,
      tags: normalizedTags,
      createdAt: now,
      updatedAt: now,
      version: 1,
    );
    await _db.transaction((transaction) async {
      await transaction.insert('collections', collection);
      await _writeCollectionOutbox(
        transaction,
        collection,
        operation: 'create',
      );
      await transaction.insert('subscriptions', _subscriptionRow(payload));
      await _writeSubscriptionOutbox(transaction, payload, operation: 'create');
    });
    return CalendarSubscription.fromJson(payload);
  }

  @override
  Future<CalendarSubscription> updateSubscription(
    CalendarSubscription current, {
    required String title,
    required String url,
    required bool enabled,
    required int refreshIntervalMinutes,
    required List<String> tags,
  }) async {
    final normalizedTitle = title.trim();
    final normalizedUrl = _validateSubscriptionUrl(url);
    final normalizedTags = _normalizeTags(tags);
    _validateRefreshInterval(refreshIntervalMinutes);
    if (normalizedTitle.isEmpty) {
      throw const RepositoryConflict('订阅名称不能为空。');
    }
    final now = DateTime.now();
    late Map<String, Object?> updatedPayload;
    await _db.transaction((transaction) async {
      final rows = await transaction.query(
        'subscriptions',
        where: 'id = ? AND version = ? AND deleted_at IS NULL',
        whereArgs: [current.id, current.version],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw const RepositoryConflict('订阅已更新或删除，请刷新后重试。');
      }
      final payload = _subscriptionPayloadFromRow(rows.single);
      final metadata = Map<String, Object?>.from(
        payload['metadata'] is Map
            ? (payload['metadata'] as Map).cast<String, Object?>()
            : const {},
      )..['refresh_interval_minutes'] = refreshIntervalMinutes;
      metadata['tags'] = normalizedTags;
      updatedPayload = {
        ...payload,
        'title': normalizedTitle,
        'url': normalizedUrl,
        'enabled': enabled,
        'metadata': metadata,
        'updated_at': _timeText(now),
        'version': current.version + 1,
        if (normalizedUrl != current.url) ...{
          'last_fetched_at': null,
          'last_success_at': null,
          'last_error': null,
          'etag': null,
          'last_modified': null,
          'source_hash': null,
        },
      };
      await transaction.update(
        'subscriptions',
        _subscriptionRow(updatedPayload),
        where: 'id = ? AND version = ? AND deleted_at IS NULL',
        whereArgs: [current.id, current.version],
      );
      await _writeSubscriptionOutbox(
        transaction,
        updatedPayload,
        operation: 'update',
      );
      if (normalizedTitle != current.title) {
        final collectionRows = await transaction.query(
          'collections',
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [current.collectionId],
          limit: 1,
        );
        if (collectionRows.isNotEmpty) {
          final collection = {
            ...collectionRows.single,
            'name': normalizedTitle,
            'updated_at': _timeText(now),
            'version': (collectionRows.single['version'] as int) + 1,
          };
          await transaction.update(
            'collections',
            collection,
            where: 'id = ?',
            whereArgs: [current.collectionId],
          );
          await _writeCollectionOutbox(
            transaction,
            collection,
            operation: 'update',
          );
        }
      }
      if (jsonEncode(normalizedTags) != jsonEncode(current.tags)) {
        final itemRows = await transaction.query(
          'items',
          where: 'collection_id = ? AND deleted_at IS NULL',
          whereArgs: [current.collectionId],
        );
        for (final row in itemRows) {
          final previous = _itemFromRow(row);
          final nextTags = _normalizeTags([
            ...previous.tags.where((tag) => !current.tags.contains(tag)),
            ...normalizedTags,
          ]);
          if (jsonEncode(nextTags) == jsonEncode(previous.tags)) continue;
          final updated = _subscriptionItem(
            id: previous.id,
            collectionId: previous.collectionId,
            draft: ItemDraft(
              type: previous.type,
              title: previous.title,
              body: previous.body,
              startAt: previous.startAt,
              endAt: previous.endAt,
              dueAt: previous.dueAt,
              recurrence: previous.recurrence,
              timezone: previous.timezone,
              allDay: previous.allDay,
              location: previous.location,
              status: previous.status,
              priority: previous.priority,
              tags: nextTags,
            ),
            createdAt: previous.createdAt,
            updatedAt: now,
            version: previous.version + 1,
          );
          await transaction.update(
            'items',
            _itemToRow(updated),
            where: 'id = ? AND version = ?',
            whereArgs: [previous.id, previous.version],
          );
          await _writeOutbox(transaction, updated, 'update');
        }
      }
    });
    return CalendarSubscription.fromJson(updatedPayload);
  }

  @override
  Future<void> deleteSubscription(CalendarSubscription current) async {
    final now = DateTime.now();
    await _db.transaction((transaction) async {
      final rows = await transaction.query(
        'subscriptions',
        where: 'id = ? AND version = ? AND deleted_at IS NULL',
        whereArgs: [current.id, current.version],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw const RepositoryConflict('订阅已更新或删除，请刷新后重试。');
      }
      final deletedPayload = {
        ..._subscriptionPayloadFromRow(rows.single),
        'updated_at': _timeText(now),
        'deleted_at': _timeText(now),
        'version': current.version + 1,
      };
      await transaction.update(
        'subscriptions',
        _subscriptionRow(deletedPayload),
        where: 'id = ? AND version = ?',
        whereArgs: [current.id, current.version],
      );
      await _writeSubscriptionOutbox(
        transaction,
        deletedPayload,
        operation: 'delete',
      );

      final itemRows = await transaction.query(
        'items',
        where: 'collection_id = ? AND deleted_at IS NULL',
        whereArgs: [current.collectionId],
      );
      for (final row in itemRows) {
        final item = _itemFromRow(row);
        final deletedItem = CalendarItem(
          id: item.id,
          collectionId: item.collectionId,
          type: item.type,
          title: item.title,
          body: item.body,
          startAt: item.startAt,
          endAt: item.endAt,
          dueAt: item.dueAt,
          recurrence: item.recurrence,
          timezone: item.timezone,
          allDay: item.allDay,
          location: item.location,
          status: item.status,
          priority: item.priority,
          reminderEnabled: item.reminderEnabled,
          reminderMinutes: item.reminderMinutes,
          tags: item.tags,
          createdAt: item.createdAt,
          updatedAt: now,
          deletedAt: now,
          version: item.version + 1,
        );
        await transaction.update(
          'items',
          _itemToRow(deletedItem),
          where: 'id = ?',
          whereArgs: [item.id],
        );
        await _writeOutbox(transaction, deletedItem, 'delete');
      }

      final collectionRows = await transaction.query(
        'collections',
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [current.collectionId],
        limit: 1,
      );
      if (collectionRows.isNotEmpty) {
        final collection = {
          ...collectionRows.single,
          'updated_at': _timeText(now),
          'deleted_at': _timeText(now),
          'version': (collectionRows.single['version'] as int) + 1,
        };
        await transaction.update(
          'collections',
          collection,
          where: 'id = ?',
          whereArgs: [current.collectionId],
        );
        await _writeCollectionOutbox(
          transaction,
          collection,
          operation: 'delete',
        );
      }
    });
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
    var createdCount = 0;
    var updatedCount = 0;
    var deletedCount = 0;
    var unchangedCount = 0;
    late SubscriptionFetchLog log;
    await _db.transaction((transaction) async {
      final subscriptionRows = await transaction.query(
        'subscriptions',
        where: 'id = ? AND version = ? AND deleted_at IS NULL',
        whereArgs: [current.id, current.version],
        limit: 1,
      );
      if (subscriptionRows.isEmpty) {
        throw const RepositoryConflict('订阅已更新或删除，请刷新后重试。');
      }
      if (!notModified) {
        final existingRows = await transaction.query(
          'items',
          where: 'collection_id = ?',
          whereArgs: [current.collectionId],
        );
        final existing = {
          for (final row in existingRows)
            row['id'] as String: _itemFromRow(row),
        };
        final seen = <String>{};
        for (final event in events) {
          final taggedDraft = _withSubscriptionTags(event.draft, current.tags);
          final itemId = _subscriptionItemId(current.id, event.externalId);
          seen.add(itemId);
          final previous = existing[itemId];
          if (previous == null) {
            final created = _subscriptionItem(
              id: itemId,
              collectionId: current.collectionId,
              draft: taggedDraft,
              createdAt: fetchedAt,
              updatedAt: fetchedAt,
              version: 1,
            );
            await transaction.insert('items', _itemToRow(created));
            await _writeOutbox(transaction, created, 'create');
            createdCount += 1;
          } else if (_sameSubscriptionItem(previous, taggedDraft) &&
              !previous.isDeleted) {
            unchangedCount += 1;
          } else {
            final updated = _subscriptionItem(
              id: previous.id,
              collectionId: current.collectionId,
              draft: taggedDraft,
              createdAt: previous.createdAt,
              updatedAt: fetchedAt,
              version: previous.version + 1,
            );
            await transaction.update(
              'items',
              _itemToRow(updated),
              where: 'id = ? AND version = ?',
              whereArgs: [previous.id, previous.version],
            );
            await _writeOutbox(transaction, updated, 'update');
            updatedCount += 1;
          }
        }
        for (final previous in existing.values) {
          if (seen.contains(previous.id) || previous.isDeleted) continue;
          final deleted = CalendarItem(
            id: previous.id,
            collectionId: previous.collectionId,
            type: previous.type,
            title: previous.title,
            body: previous.body,
            startAt: previous.startAt,
            endAt: previous.endAt,
            dueAt: previous.dueAt,
            recurrence: previous.recurrence,
            timezone: previous.timezone,
            allDay: previous.allDay,
            location: previous.location,
            status: previous.status,
            priority: previous.priority,
            reminderEnabled: previous.reminderEnabled,
            reminderMinutes: previous.reminderMinutes,
            tags: previous.tags,
            createdAt: previous.createdAt,
            updatedAt: fetchedAt,
            deletedAt: fetchedAt,
            version: previous.version + 1,
          );
          await transaction.update(
            'items',
            _itemToRow(deleted),
            where: 'id = ? AND version = ?',
            whereArgs: [previous.id, previous.version],
          );
          await _writeOutbox(transaction, deleted, 'delete');
          deletedCount += 1;
        }
      }

      log = SubscriptionFetchLog(
        status: notModified ? 'not_modified' : 'success',
        fetchedAt: fetchedAt,
        httpStatus: httpStatus,
        etag: etag,
        sourceHash: sourceHash,
        createdCount: createdCount,
        updatedCount: updatedCount,
        deletedCount: deletedCount,
        unchangedCount: unchangedCount,
      );
      final currentPayload = _subscriptionPayloadFromRow(
        subscriptionRows.single,
      );
      final updatedPayload = _appendSubscriptionLog({
        ...currentPayload,
        'last_fetched_at': _timeText(fetchedAt),
        'last_success_at': _timeText(fetchedAt),
        'last_error': null,
        'etag': etag,
        'last_modified': lastModified,
        'source_hash': sourceHash,
        'updated_at': _timeText(fetchedAt),
        'version': current.version + 1,
      }, log);
      await transaction.update(
        'subscriptions',
        _subscriptionRow(updatedPayload),
        where: 'id = ? AND version = ?',
        whereArgs: [current.id, current.version],
      );
      await _writeSubscriptionOutbox(
        transaction,
        updatedPayload,
        operation: 'update',
      );
    });
    return log;
  }

  @override
  Future<void> recordSubscriptionRefreshFailure(
    CalendarSubscription current, {
    required DateTime fetchedAt,
    required String error,
    int? httpStatus,
  }) async {
    await _db.transaction((transaction) async {
      final rows = await transaction.query(
        'subscriptions',
        where: 'id = ? AND version = ? AND deleted_at IS NULL',
        whereArgs: [current.id, current.version],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final log = SubscriptionFetchLog(
        status: 'failed',
        fetchedAt: fetchedAt,
        httpStatus: httpStatus,
        error: error,
      );
      final updatedPayload = _appendSubscriptionLog({
        ..._subscriptionPayloadFromRow(rows.single),
        'last_fetched_at': _timeText(fetchedAt),
        'last_error': error,
        'updated_at': _timeText(fetchedAt),
        'version': current.version + 1,
      }, log);
      await transaction.update(
        'subscriptions',
        _subscriptionRow(updatedPayload),
        where: 'id = ? AND version = ?',
        whereArgs: [current.id, current.version],
      );
      await _writeSubscriptionOutbox(
        transaction,
        updatedPayload,
        operation: 'update',
      );
    });
  }

  @override
  Future<List<SubscriptionFetchLog>> listSubscriptionFetchLogs(
    String subscriptionId,
  ) async {
    final rows = await _db.query(
      'subscriptions',
      where: 'id = ?',
      whereArgs: [subscriptionId],
      limit: 1,
    );
    if (rows.isEmpty) return const [];
    final payload = _subscriptionPayloadFromRow(rows.single);
    final metadata = payload['metadata'];
    if (metadata is! Map) return const [];
    final logs = metadata['_fetch_logs'];
    if (logs is! List) return const [];
    return logs
        .whereType<Map>()
        .map(
          (value) =>
              SubscriptionFetchLog.fromJson(value.cast<String, Object?>()),
        )
        .toList(growable: false);
  }

  static CalendarSubscription _subscriptionFromRow(Map<String, Object?> row) =>
      CalendarSubscription.fromJson(_subscriptionPayloadFromRow(row));

  static Map<String, Object?> _subscriptionPayloadFromRow(
    Map<String, Object?> row,
  ) => (jsonDecode(row['payload_json'] as String) as Map<String, dynamic>)
      .cast<String, Object?>();

  static Map<String, Object?> _subscriptionRow(Map<String, Object?> payload) =>
      {
        'id': payload['id'],
        'collection_id': payload['collection_id'],
        'payload_json': jsonEncode(payload),
        'updated_at': payload['updated_at'],
        'deleted_at': payload['deleted_at'],
        'version': payload['version'],
      };

  static Map<String, Object?> _subscriptionPayload({
    required String id,
    required String collectionId,
    required String title,
    required String url,
    required bool enabled,
    required int refreshIntervalMinutes,
    required List<String> tags,
    required DateTime createdAt,
    required DateTime updatedAt,
    required int version,
  }) => {
    'id': id,
    'collection_id': collectionId,
    'type': 'ics',
    'title': title,
    'url': url,
    'enabled': enabled,
    'last_fetched_at': null,
    'last_success_at': null,
    'last_error': null,
    'etag': null,
    'last_modified': null,
    'source_hash': null,
    'metadata': {
      'refresh_interval_minutes': refreshIntervalMinutes,
      'tags': tags,
    },
    'created_at': _timeText(createdAt),
    'updated_at': _timeText(updatedAt),
    'deleted_at': null,
    'version': version,
  };

  static Map<String, Object?> _appendSubscriptionLog(
    Map<String, Object?> payload,
    SubscriptionFetchLog log,
  ) {
    final metadata = Map<String, Object?>.from(
      payload['metadata'] is Map
          ? (payload['metadata'] as Map).cast<String, Object?>()
          : const {},
    );
    final previous = metadata['_fetch_logs'];
    final logs = <Object?>[
      log.toJson(),
      if (previous is List) ...previous.take(99),
    ];
    metadata['_fetch_logs'] = logs;
    return {...payload, 'metadata': metadata};
  }

  String _subscriptionItemId(String subscriptionId, String externalId) =>
      'item_ics_${_uuid.v5(Namespace.url.value, '$subscriptionId|$externalId').replaceAll('-', '')}';

  static CalendarItem _subscriptionItem({
    required String id,
    required String collectionId,
    required ItemDraft draft,
    required DateTime createdAt,
    required DateTime updatedAt,
    required int version,
  }) => CalendarItem(
    id: id,
    collectionId: collectionId,
    type: ItemType.event,
    title: draft.title.trim(),
    body: _optional(draft.body),
    startAt: draft.startAt,
    endAt: draft.endAt,
    recurrence: draft.recurrence,
    timezone: draft.timezone,
    allDay: draft.allDay,
    location: _optional(draft.location),
    status: draft.status,
    reminderEnabled: false,
    reminderMinutes: 30,
    tags: _normalizeTags(draft.tags),
    createdAt: createdAt,
    updatedAt: updatedAt,
    version: version,
  );

  static ItemDraft _withSubscriptionTags(
    ItemDraft draft,
    List<String> subscriptionTags,
  ) => ItemDraft(
    collectionId: draft.collectionId,
    type: draft.type,
    title: draft.title,
    body: draft.body,
    startAt: draft.startAt,
    endAt: draft.endAt,
    dueAt: draft.dueAt,
    recurrence: draft.recurrence,
    timezone: draft.timezone,
    allDay: draft.allDay,
    location: draft.location,
    status: draft.status,
    priority: draft.priority,
    reminderEnabled: draft.reminderEnabled,
    reminderMinutes: draft.reminderMinutes,
    tags: _normalizeTags([...draft.tags, ...subscriptionTags]),
  );

  static bool _sameSubscriptionItem(CalendarItem item, ItemDraft draft) =>
      item.title == draft.title.trim() &&
      item.body == _optional(draft.body) &&
      item.startAt == draft.startAt &&
      item.endAt == draft.endAt &&
      item.recurrence?.rrule == draft.recurrence?.rrule &&
      jsonEncode(item.recurrence?.exdates ?? const []) ==
          jsonEncode(draft.recurrence?.exdates ?? const []) &&
      item.timezone == draft.timezone &&
      item.allDay == draft.allDay &&
      item.location == _optional(draft.location) &&
      item.status == draft.status &&
      jsonEncode(item.tags) == jsonEncode(_normalizeTags(draft.tags));

  static String _validateSubscriptionUrl(String value) {
    final normalized = value.trim().startsWith('webcal://')
        ? value.trim().replaceFirst('webcal://', 'https://')
        : value.trim();
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty) {
      throw const RepositoryConflict('订阅地址必须是无内嵌凭据的 HTTP(S) 或 webcal URL。');
    }
    return normalized;
  }

  static void _validateRefreshInterval(int value) {
    if (value < 1 || value > 10080) {
      throw const RepositoryConflict('刷新间隔必须在 1 分钟到 7 天之间。');
    }
  }

  @override
  Future<ClientPreferences> loadPreferences(ClientPreferences defaults) =>
      LocalPreferencesStore(_db).load(defaults);

  @override
  Future<void> savePreferences(ClientPreferences preferences) =>
      LocalPreferencesStore(_db).save(preferences);
  Future<void> _writeOutbox(
    Transaction transaction,
    CalendarItem item,
    String operation,
  ) async {
    final changeId = 'change_${_uuid.v4()}';
    final payload = _itemPayload(item);
    await transaction.insert('outbox', {
      'change_id': changeId,
      'device_id': _runtimeDeviceId,
      'entity_type': 'item',
      'entity_id': item.id,
      'operation': operation,
      'entity_version': item.version,
      'payload_json': jsonEncode(payload),
      'created_at': _timeText(item.updatedAt),
      'retry_count': 0,
      'last_error': null,
      'next_attempt_at': null,
      'permanent_failure': 0,
      'sent_at': null,
    });
    await _upsertSyncHead(
      transaction,
      RemoteSyncChange(
        changeId: changeId,
        deviceId: _runtimeDeviceId,
        entityType: 'item',
        entityId: item.id,
        operation: operation,
        version: item.version,
        updatedAt: item.updatedAt,
        payload: payload,
      ),
    );
  }

  Future<void> writeCycleSyncOutbox(
    Transaction transaction,
    String entityType,
    String entityId,
    String operation,
    int version,
    DateTime updatedAt,
    Map<String, Object?> payload,
  ) async {
    final changeId = 'change_${_uuid.v4()}';
    await transaction.insert('outbox', {
      'change_id': changeId,
      'device_id': _runtimeDeviceId,
      'entity_type': entityType,
      'entity_id': entityId,
      'operation': operation,
      'entity_version': version,
      'payload_json': jsonEncode(payload),
      'created_at': _timeText(updatedAt),
      'retry_count': 0,
      'last_error': null,
      'next_attempt_at': null,
      'permanent_failure': 0,
      'sent_at': null,
    });
    await _upsertSyncHead(
      transaction,
      RemoteSyncChange(
        changeId: changeId,
        deviceId: _runtimeDeviceId,
        entityType: entityType,
        entityId: entityId,
        operation: operation,
        version: version,
        updatedAt: updatedAt,
        payload: payload,
      ),
    );
  }

  Future<void> _writeCollectionOutbox(
    Transaction transaction,
    Map<String, Object?> collection, {
    required String operation,
  }) async {
    final payload = {
      'id': collection['id'],
      'name': collection['name'],
      'kind': collection['kind'],
      'color': collection['color'],
      'readonly': collection['readonly'] == 1,
      'created_at': collection['created_at'],
      'updated_at': collection['updated_at'],
      'deleted_at': collection['deleted_at'],
      'version': collection['version'],
    };
    final changeId = 'change_${_uuid.v4()}';
    await transaction.insert('outbox', {
      'change_id': changeId,
      'device_id': _runtimeDeviceId,
      'entity_type': 'collection',
      'entity_id': collection['id'],
      'operation': operation,
      'entity_version': collection['version'],
      'payload_json': jsonEncode(payload),
      'created_at': collection['updated_at'],
      'retry_count': 0,
      'last_error': null,
      'next_attempt_at': null,
      'permanent_failure': 0,
      'sent_at': null,
    });
    await _upsertSyncHead(
      transaction,
      RemoteSyncChange(
        changeId: changeId,
        deviceId: _runtimeDeviceId,
        entityType: 'collection',
        entityId: collection['id'] as String,
        operation: operation,
        version: collection['version'] as int,
        updatedAt: DateTime.parse(collection['updated_at'] as String),
        payload: payload,
      ),
    );
  }

  Future<void> _writeSubscriptionOutbox(
    Transaction transaction,
    Map<String, Object?> payload, {
    required String operation,
  }) async {
    final changeId = 'change_${_uuid.v4()}';
    await transaction.insert('outbox', {
      'change_id': changeId,
      'device_id': _runtimeDeviceId,
      'entity_type': 'subscription',
      'entity_id': payload['id'],
      'operation': operation,
      'entity_version': payload['version'],
      'payload_json': jsonEncode(payload),
      'created_at': payload['updated_at'],
      'retry_count': 0,
      'last_error': null,
      'next_attempt_at': null,
      'permanent_failure': 0,
      'sent_at': null,
    });
    await _upsertSyncHead(
      transaction,
      RemoteSyncChange(
        changeId: changeId,
        deviceId: _runtimeDeviceId,
        entityType: 'subscription',
        entityId: payload['id'] as String,
        operation: operation,
        version: payload['version'] as int,
        updatedAt: DateTime.parse(payload['updated_at'] as String),
        payload: payload,
      ),
    );
  }

  @override
  Future<List<PendingSyncChange>> listPendingChanges({
    required DateTime now,
    int limit = 200,
  }) async {
    final rows = await _db.query(
      'outbox',
      where:
          'sent_at IS NULL AND permanent_failure = 0 '
          'AND (next_attempt_at IS NULL OR next_attempt_at <= ?)',
      whereArgs: [_timeText(now)],
      orderBy:
          'CASE entity_type '
          "WHEN 'collection' THEN 0 "
          "WHEN 'subscription' THEN 1 "
          "WHEN 'item' THEN 2 "
          'ELSE 3 END, created_at, change_id',
      limit: limit,
    );
    return rows
        .map(
          (row) => PendingSyncChange(
            changeId: row['change_id'] as String,
            deviceId: row['device_id'] as String,
            entityType: row['entity_type'] as String,
            entityId: row['entity_id'] as String,
            operation: row['operation'] as String,
            version: row['entity_version'] as int,
            updatedAt: DateTime.parse(row['created_at'] as String),
            payload:
                (jsonDecode(row['payload_json'] as String)
                        as Map<String, dynamic>)
                    .cast<String, Object?>(),
            retryCount: row['retry_count'] as int,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> removeAcceptedChanges(List<String> changeIds) async {
    if (changeIds.isEmpty) return;
    final placeholders = List.filled(changeIds.length, '?').join(',');
    await _db.delete(
      'outbox',
      where: 'change_id IN ($placeholders)',
      whereArgs: changeIds,
    );
  }

  @override
  Future<DateTime?> recordTransientFailure(
    List<String> changeIds,
    String error, {
    required DateTime now,
    required int retryLimit,
  }) async {
    if (changeIds.isEmpty) return now.add(const Duration(seconds: 2));
    DateTime? earliest;
    await _db.transaction((transaction) async {
      for (final changeId in changeIds) {
        final rows = await transaction.query(
          'outbox',
          columns: ['retry_count'],
          where: 'change_id = ?',
          whereArgs: [changeId],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final retryCount = (rows.single['retry_count'] as int) + 1;
        if (retryCount >= retryLimit) {
          await transaction.update(
            'outbox',
            {
              'retry_count': retryCount,
              'last_error': error,
              'next_attempt_at': null,
              'permanent_failure': 1,
            },
            where: 'change_id = ?',
            whereArgs: [changeId],
          );
          continue;
        }
        final seconds = (1 << retryCount).clamp(2, 300);
        final nextAttempt = now.add(Duration(seconds: seconds));
        if (earliest == null || nextAttempt.isBefore(earliest!)) {
          earliest = nextAttempt;
        }
        await transaction.update(
          'outbox',
          {
            'retry_count': retryCount,
            'last_error': error,
            'next_attempt_at': _timeText(nextAttempt),
          },
          where: 'change_id = ?',
          whereArgs: [changeId],
        );
      }
    });
    return earliest;
  }

  @override
  Future<void> recordPermanentFailures(List<SyncRejection> rejections) async {
    if (rejections.isEmpty) return;
    await _db.transaction((transaction) async {
      for (final rejection in rejections) {
        await transaction.update(
          'outbox',
          {
            'last_error': '${rejection.code}: ${rejection.message}',
            'next_attempt_at': null,
            'permanent_failure': 1,
          },
          where: 'change_id = ?',
          whereArgs: [rejection.changeId],
        );
      }
    });
  }

  @override
  Future<int> resetRetryablePermanentFailures() => _db.update(
    'outbox',
    {
      'retry_count': 0,
      'last_error': null,
      'next_attempt_at': null,
      'permanent_failure': 0,
    },
    where:
        'sent_at IS NULL AND permanent_failure = 1 AND ('
        "(entity_type IN ('cycle_period', 'cycle_settings') "
        "AND last_error LIKE '%entity_type is invalid%') OR "
        'last_error IN ('
        "'constraint_violation: Change could not be applied', "
        "'constraint_violation: Referenced collection does not exist'"
        '))',
  );

  @override
  Future<String?> loadPermanentFailureMessage() async {
    final rows = await _db.query(
      'outbox',
      columns: ['last_error'],
      where: 'sent_at IS NULL AND permanent_failure = 1',
      orderBy: 'created_at DESC, change_id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.single['last_error'] as String? ?? '存在无法同步的数据。';
  }

  @override
  Future<void> resetTransientBackoff() => _db.update('outbox', {
    'next_attempt_at': null,
  }, where: 'sent_at IS NULL AND permanent_failure = 0');

  @override
  Future<String?> loadRemoteCursor() async {
    final rows = await _db.query(
      'sync_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['remote_cursor'],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  @override
  Future<void> applyPushConflicts(List<SyncConflictSummary> conflicts) async {
    if (conflicts.isEmpty) return;
    await _db.transaction((transaction) async {
      for (final conflict in conflicts) {
        await _recordSyncConflict(transaction, conflict.winner, conflict.loser);
        await _applyRemoteChange(transaction, conflict.winner);
      }
    });
  }

  @override
  Future<void> applyRemoteBatch(
    List<RemoteSyncChange> changes,
    String cursor,
  ) async {
    await _db.transaction((transaction) async {
      for (final change in changes) {
        await _applyRemoteChange(transaction, change);
      }
      await transaction.insert('sync_state', {
        'key': 'remote_cursor',
        'value': cursor,
        'updated_at': _timeText(DateTime.now()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  @override
  Future<List<SyncConflictRecord>> listSyncConflicts({int limit = 100}) async {
    if (limit < 1 || limit > 500) {
      throw const FormatException('Conflict history limit must be 1 to 500');
    }
    final rows = await _db.query(
      'sync_conflicts',
      orderBy: 'conflict_id DESC',
      limit: limit,
    );
    return rows
        .map(
          (row) => SyncConflictRecord(
            id: row['conflict_id'] as int,
            recordedAt: DateTime.parse(row['recorded_at'] as String),
            winner: RemoteSyncChange.fromJson(
              (jsonDecode(row['winner_json'] as String) as Map<String, dynamic>)
                  .cast<String, Object?>(),
            ),
            loser: RemoteSyncChange.fromJson(
              (jsonDecode(row['loser_json'] as String) as Map<String, dynamic>)
                  .cast<String, Object?>(),
            ),
          ),
        )
        .toList(growable: false);
  }

  Future<void> _applyRemoteChange(
    Transaction transaction,
    RemoteSyncChange change,
  ) async {
    final payloadUpdatedAt = change.payload['updated_at'];
    if (change.payload['id'] != change.entityId ||
        change.payload['version'] != change.version ||
        payloadUpdatedAt is! String ||
        DateTime.parse(payloadUpdatedAt).toUtc() != change.updatedAt.toUtc()) {
      throw const FormatException(
        'Remote change envelope does not match payload',
      );
    }
    if (change.operation == 'delete' &&
        change.payload['deleted_at'] is! String) {
      throw const FormatException('Remote delete requires a tombstone');
    }
    final rows = await transaction.query(
      'sync_entity_heads',
      where: 'entity_type = ? AND entity_id = ?',
      whereArgs: [change.entityType, change.entityId],
      limit: 1,
    );
    final current = rows.isEmpty ? null : _syncChangeFromHead(rows.single);
    if (current?.changeId == change.changeId) return;
    final incomingWins =
        current == null || compareSyncChanges(change, current) > 0;
    final isSuccessor =
        current != null &&
        incomingWins &&
        change.version == current.version + 1;
    final sameDeviceReplay =
        current != null &&
        !incomingWins &&
        current.deviceId == change.deviceId &&
        change.version <= current.version;
    if (current != null && !isSuccessor && !sameDeviceReplay) {
      await _recordSyncConflict(
        transaction,
        incomingWins ? change : current,
        incomingWins ? current : change,
      );
    }
    if (!incomingWins) return;

    switch (change.entityType) {
      case 'collection':
        await _updateOrInsert(
          transaction,
          'collections',
          _remoteCollectionRow(change.payload),
        );
        break;
      case 'item':
        await _updateOrInsert(
          transaction,
          'items',
          _remoteItemRow(change.payload),
        );
        break;
      case 'subscription':
        await _updateOrInsert(transaction, 'subscriptions', {
          'id': change.entityId,
          'collection_id': change.payload['collection_id'],
          'payload_json': jsonEncode(change.payload),
          'updated_at': change.payload['updated_at'],
          'deleted_at': change.payload['deleted_at'],
          'version': change.version,
        });
        break;
      case 'cycle_period':
        await _applyRemoteCyclePeriod(transaction, change);
        break;
      case 'cycle_settings':
        final settingsRow = {
          'id': 1,
          'enabled': change.payload['enabled'] == true ? 1 : 0,
          'forecast_horizon':
              (change.payload['forecast_horizon'] as num?)?.toInt() ?? 1,
          'updated_at': change.payload['updated_at'],
          'version': change.version,
        };
        final updatedSettings = await transaction.update(
          'cycle_settings',
          settingsRow,
          where: 'id = 1',
        );
        if (updatedSettings == 0) {
          await transaction.insert('cycle_settings', settingsRow);
        }
        break;
      default:
        throw FormatException('Unsupported sync entity: ${change.entityType}');
    }
    await _upsertSyncHead(transaction, change);
  }

  Future<void> _applyRemoteCyclePeriod(
    Transaction transaction,
    RemoteSyncChange change,
  ) async {
    final payload = change.payload;
    final row = {
      'id': change.entityId,
      'start_date': payload['start_date'],
      'end_date': payload['end_date'],
      'excluded_from_prediction': payload['excluded_from_prediction'] == true
          ? 1
          : 0,
      'context': payload['context'],
      'created_at': payload['created_at'],
      'updated_at': payload['updated_at'],
      'deleted_at': payload['deleted_at'],
      'version': change.version,
    };
    await _updateOrInsert(transaction, 'cycle_periods', row);
    await transaction.delete(
      'cycle_daily_logs',
      where: 'period_id = ?',
      whereArgs: [change.entityId],
    );
    final logs = payload['daily_logs'];
    if (logs is List && payload['deleted_at'] == null) {
      for (final value in logs) {
        if (value is! Map) continue;
        final log = value.cast<String, Object?>();
        await transaction.insert('cycle_daily_logs', {
          'date': log['date'],
          'period_id': change.entityId,
          'bleeding_level': log['bleeding_level'],
          'spotting': log['spotting'] == true ? 1 : 0,
          'symptoms_json': jsonEncode(
            log['symptoms'] is List ? log['symptoms'] : const [],
          ),
          'updated_at': log['updated_at'] ?? payload['updated_at'],
        });
      }
    }
  }

  static Future<void> _updateOrInsert(
    Transaction transaction,
    String table,
    Map<String, Object?> values,
  ) async {
    final updated = await transaction.update(
      table,
      values,
      where: 'id = ?',
      whereArgs: [values['id']],
    );
    if (updated == 0) await transaction.insert(table, values);
  }

  static Future<void> _upsertSyncHead(
    Transaction transaction,
    SyncChangeValue change,
  ) => transaction.insert('sync_entity_heads', {
    'entity_type': change.entityType,
    'entity_id': change.entityId,
    'change_id': change.changeId,
    'device_id': change.deviceId,
    'operation': change.operation,
    'entity_version': change.version,
    'updated_at': _timeText(change.updatedAt),
    'payload_json': jsonEncode(change.payload),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  static RemoteSyncChange _syncChangeFromHead(Map<String, Object?> row) =>
      RemoteSyncChange(
        changeId: row['change_id'] as String,
        deviceId: row['device_id'] as String,
        entityType: row['entity_type'] as String,
        entityId: row['entity_id'] as String,
        operation: row['operation'] as String,
        version: row['entity_version'] as int,
        updatedAt: DateTime.parse(row['updated_at'] as String),
        payload:
            (jsonDecode(row['payload_json'] as String) as Map<String, dynamic>)
                .cast<String, Object?>(),
      );

  static Future<void> _recordSyncConflict(
    Transaction transaction,
    RemoteSyncChange winner,
    RemoteSyncChange loser,
  ) => transaction.insert('sync_conflicts', {
    'entity_type': winner.entityType,
    'entity_id': winner.entityId,
    'winner_change_id': winner.changeId,
    'loser_change_id': loser.changeId,
    'winner_json': jsonEncode(winner.toJson()),
    'loser_json': jsonEncode(loser.toJson()),
    'recorded_at': _timeText(DateTime.now()),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);

  static CalendarCollection _collectionFromRow(Map<String, Object?> row) =>
      CalendarCollection(
        id: row['id'] as String,
        name: row['name'] as String,
        kind: row['kind'] as String,
        color: _parseColor(row['color']),
        readonly: row['readonly'] == 1,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
        deletedAt: _parseTime(row['deleted_at']),
        version: row['version'] as int,
      );

  static Map<String, Object?> _collectionToRow(
    CalendarCollection collection,
  ) => {
    'id': collection.id,
    'name': collection.name,
    'kind': collection.kind,
    'color': collection.color == null ? null : _colorText(collection.color!),
    'readonly': collection.readonly ? 1 : 0,
    'created_at': _timeText(collection.createdAt),
    'updated_at': _timeText(collection.updatedAt),
    'deleted_at': _optionalTime(collection.deletedAt),
    'version': collection.version,
  };

  static int? _parseColor(Object? value) {
    if (value is int) return value;
    if (value is! String) return null;
    final normalized = value.replaceFirst('#', '');
    final parsed = int.tryParse(normalized, radix: 16);
    if (parsed == null) return null;
    return normalized.length <= 6 ? 0xFF000000 | parsed : parsed;
  }

  static Map<String, Object?> _remoteCollectionRow(
    Map<String, Object?> payload,
  ) => {
    'id': payload['id'],
    'name': payload['name'],
    'kind': payload['kind'],
    'color': payload['color'],
    'readonly': payload['readonly'] == true ? 1 : 0,
    'created_at': payload['created_at'],
    'updated_at': payload['updated_at'],
    'deleted_at': payload['deleted_at'],
    'version': payload['version'],
  };

  static Map<String, Object?> _remoteItemRow(Map<String, Object?> payload) {
    final reminders = payload['reminders'] as List<Object?>? ?? const [];
    final reminder = reminders.isEmpty
        ? null
        : (reminders.first as Map<Object?, Object?>).cast<String, Object?>();
    return {
      'id': payload['id'],
      'collection_id': payload['collection_id'],
      'item_type': payload['type'],
      'title': payload['title'],
      'body': payload['body'],
      'start_at': payload['start_at'],
      'end_at': payload['end_at'],
      'due_at': payload['due_at'],
      'recurrence_json': payload['recurrence'] == null
          ? null
          : jsonEncode(payload['recurrence']),
      'timezone': payload['timezone'],
      'all_day': payload['all_day'] == true ? 1 : 0,
      'location': payload['location'],
      'status': payload['status'],
      'priority': payload['priority'],
      'reminder_enabled': reminder?['enabled'] == true ? 1 : 0,
      'reminder_minutes': reminder?['minutes_before'] as int? ?? 30,
      'tags_json': jsonEncode(payload['tags'] ?? const []),
      'created_at': payload['created_at'],
      'updated_at': payload['updated_at'],
      'deleted_at': payload['deleted_at'],
      'version': payload['version'],
    };
  }

  static void _validateDraft(ItemDraft draft) {
    if (draft.title.trim().isEmpty) {
      throw const RepositoryConflict('标题不能为空。');
    }
    if (draft.type == ItemType.event && draft.startAt == null) {
      throw const RepositoryConflict('日程需要开始时间。');
    }
    if (draft.recurrence != null && draft.type != ItemType.event) {
      throw const RepositoryConflict('只有日程可以设置循环。');
    }
    if (draft.startAt != null &&
        draft.endAt != null &&
        draft.endAt!.isBefore(draft.startAt!)) {
      throw const RepositoryConflict('结束时间不能早于开始时间。');
    }
    if (draft.reminderMinutes < 0) {
      throw const RepositoryConflict('提醒时间不能为负数。');
    }
    if (draft.timezone.trim().isEmpty) {
      throw const RepositoryConflict('时区不能为空。');
    }
    if (draft.priority != null &&
        (draft.priority! < 1 || draft.priority! > 3)) {
      throw const RepositoryConflict('优先级必须在 1 到 3 之间。');
    }
  }

  static CalendarItem _itemFromRow(Map<String, Object?> row) => CalendarItem(
    id: row['id'] as String,
    collectionId: row['collection_id'] as String,
    type: ItemType.values.byName(row['item_type'] as String),
    title: row['title'] as String,
    body: row['body'] as String?,
    startAt: _parseTime(row['start_at']),
    endAt: _parseTime(row['end_at']),
    dueAt: _parseTime(row['due_at']),
    recurrence: _parseRecurrence(row['recurrence_json']),
    timezone: row['timezone'] as String,
    allDay: row['all_day'] == 1,
    location: row['location'] as String?,
    status: ItemStatus.values.byName(row['status'] as String),
    priority: row['priority'] as int?,
    reminderEnabled: row['reminder_enabled'] == 1,
    reminderMinutes: row['reminder_minutes'] as int,
    tags: (jsonDecode(row['tags_json'] as String) as List<dynamic>)
        .cast<String>(),
    createdAt: DateTime.parse(row['created_at'] as String),
    updatedAt: DateTime.parse(row['updated_at'] as String),
    deletedAt: _parseTime(row['deleted_at']),
    version: row['version'] as int,
  );

  static Map<String, Object?> _itemToRow(CalendarItem item) => {
    'id': item.id,
    'collection_id': item.collectionId,
    'item_type': item.type.name,
    'title': item.title,
    'body': item.body,
    'start_at': _optionalTime(item.startAt),
    'end_at': _optionalTime(item.endAt),
    'due_at': _optionalTime(item.dueAt),
    'recurrence_json': item.recurrence == null
        ? null
        : jsonEncode(item.recurrence!.toJson()),
    'timezone': item.timezone,
    'all_day': item.allDay ? 1 : 0,
    'location': item.location,
    'status': item.status.name,
    'priority': item.priority,
    'reminder_enabled': item.reminderEnabled ? 1 : 0,
    'reminder_minutes': item.reminderMinutes,
    'tags_json': jsonEncode(item.tags),
    'created_at': _timeText(item.createdAt),
    'updated_at': _timeText(item.updatedAt),
    'deleted_at': _optionalTime(item.deletedAt),
    'version': item.version,
  };

  static Map<String, Object?> _itemPayload(CalendarItem item) => {
    'id': item.id,
    'collection_id': item.collectionId,
    'type': item.type.name,
    'title': item.title,
    'body': item.body,
    'start_at': _optionalTime(item.startAt),
    'end_at': _optionalTime(item.endAt),
    'due_at': _optionalTime(item.dueAt),
    'timezone': item.timezone,
    'all_day': item.allDay,
    'location': item.location,
    'status': item.status.name,
    'priority': item.priority,
    'recurrence': item.recurrence?.toJson(),
    'reminders': item.reminderEnabled
        ? [
            {
              'id': '${item.id}:reminder:0',
              'item_id': item.id,
              'mode': 'relative',
              'minutes_before': item.reminderMinutes,
              'remind_at': null,
              'enabled': true,
            },
          ]
        : <Map<String, Object?>>[],
    'tags': item.tags,
    'source': 'local',
    'source_ref': null,
    'metadata': <String, Object?>{},
    'created_at': _timeText(item.createdAt),
    'updated_at': _timeText(item.updatedAt),
    'deleted_at': _optionalTime(item.deletedAt),
    'version': item.version,
  };

  static DateTime? _parseTime(Object? value) =>
      value == null ? null : DateTime.parse(value as String);

  static RecurrenceRule? _parseRecurrence(Object? value) {
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value as String);
      if (decoded is! Map) return null;
      return RecurrenceRule.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  static String _timeText(DateTime value) => value.toUtc().toIso8601String();

  static String? _optionalTime(DateTime? value) =>
      value == null ? null : _timeText(value);

  static String? _optional(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static List<String> _normalizeTags(List<String> tags) => {
    for (final tag in tags)
      if (tag.trim().isNotEmpty) tag.trim(),
  }.toList(growable: false);

  static String _colorText(int value) =>
      '#${(value & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  @override
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
