import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import '../domain/item.dart';
import '../sync/sync_models.dart';
import '../sync/sync_repository.dart';
import 'item_repository.dart';

class LocalItemRepository implements ItemRepository, SyncRepository {
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

  @override
  String? databasePath;

  Database get _db {
    final value = _database;
    if (value == null) {
      throw StateError('Repository has not been initialized');
    }
    return value;
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
    _database = await factory.openDatabase(
      databasePath!,
      options: OpenDatabaseOptions(
        version: 2,
        onConfigure: (database) async {
          await database.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
    await _ensureDefaultCollection();
  }

  DatabaseFactory _databaseFactory() {
    if (Platform.isAndroid || Platform.isIOS) {
      return mobile.databaseFactory;
    }
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      return databaseFactoryFfi;
    }
    throw UnsupportedError('EasyCalendar requires Android, macOS, or Windows');
  }

  Future<void> _createSchema(Database database, int version) async {
    await database.execute('''
      CREATE TABLE collections (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'local',
        color TEXT,
        readonly INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        version INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await database.execute('''
      CREATE TABLE items (
        id TEXT PRIMARY KEY,
        collection_id TEXT NOT NULL REFERENCES collections(id),
        item_type TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT,
        start_at TEXT,
        end_at TEXT,
        due_at TEXT,
        timezone TEXT NOT NULL,
        all_day INTEGER NOT NULL DEFAULT 0,
        location TEXT,
        status TEXT NOT NULL,
        priority INTEGER,
        reminder_enabled INTEGER NOT NULL DEFAULT 0,
        reminder_minutes INTEGER NOT NULL DEFAULT 30,
        tags_json TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        version INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await database.execute('''
      CREATE INDEX idx_client_items_schedule
      ON items(deleted_at, start_at, due_at, id)
    ''');
    await database.execute('''
      CREATE TABLE outbox (
        change_id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        operation TEXT NOT NULL,
        entity_version INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        created_at TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        next_attempt_at TEXT,
        permanent_failure INTEGER NOT NULL DEFAULT 0,
        sent_at TEXT
      )
    ''');
    await database.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE sync_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE subscriptions (
        id TEXT PRIMARY KEY,
        collection_id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        version INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _upgradeSchema(
    Database database,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion >= 2) return;
    await database.execute(
      'ALTER TABLE outbox ADD COLUMN next_attempt_at TEXT',
    );
    await database.execute(
      'ALTER TABLE outbox ADD COLUMN permanent_failure INTEGER NOT NULL DEFAULT 0',
    );
    await database.execute('''
      CREATE TABLE sync_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE subscriptions (
        id TEXT PRIMARY KEY,
        collection_id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        version INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _ensureDefaultCollection() async {
    final now = _timeText(DateTime.now());
    await _db.transaction((transaction) async {
      await transaction.insert('collections', {
        'id': config.defaultCollectionId,
        'name': config.defaultCollectionName,
        'kind': 'local',
        'color': _colorText(config.defaultCollectionColor.toARGB32()),
        'readonly': 0,
        'created_at': now,
        'updated_at': now,
        'deleted_at': null,
        'version': 1,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      final seeded = await transaction.query(
        'sync_state',
        where: 'key = ?',
        whereArgs: ['default_collection_enqueued'],
        limit: 1,
      );
      if (seeded.isNotEmpty) return;
      final rows = await transaction.query(
        'collections',
        where: 'id = ?',
        whereArgs: [config.defaultCollectionId],
        limit: 1,
      );
      await _writeCollectionOutbox(transaction, rows.single);
      await transaction.insert('sync_state', {
        'key': 'default_collection_enqueued',
        'value': 'true',
        'updated_at': now,
      });
    });
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
  Future<CalendarItem> createItem(ItemDraft draft) async {
    _validateDraft(draft);
    final now = DateTime.now();
    final item = CalendarItem(
      id: 'item_${_uuid.v4()}',
      collectionId: config.defaultCollectionId,
      type: draft.type,
      title: draft.title.trim(),
      body: _optional(draft.body),
      startAt: draft.startAt,
      endAt: draft.endAt,
      dueAt: draft.dueAt,
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
    final updated = CalendarItem(
      id: current.id,
      collectionId: current.collectionId,
      type: draft.type,
      title: draft.title.trim(),
      body: _optional(draft.body),
      startAt: draft.startAt,
      endAt: draft.endAt,
      dueAt: draft.dueAt,
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
  Future<ClientPreferences> loadPreferences(ClientPreferences defaults) async {
    final rows = await _db.query('app_settings');
    final values = {
      for (final row in rows) row['key'] as String: row['value'] as String,
    };
    return ClientPreferences(
      apiUrl: values['api_url'] ?? defaults.apiUrl,
      syncEnabled: _storedBool(values['sync_enabled'], defaults.syncEnabled),
      notificationsEnabled: _storedBool(
        values['notifications_enabled'],
        defaults.notificationsEnabled,
      ),
    );
  }

  @override
  Future<void> savePreferences(ClientPreferences preferences) async {
    await _db.transaction((transaction) async {
      for (final entry in {
        'api_url': preferences.apiUrl.trim(),
        'sync_enabled': preferences.syncEnabled ? 'true' : 'false',
        'notifications_enabled': preferences.notificationsEnabled
            ? 'true'
            : 'false',
      }.entries) {
        await transaction.insert('app_settings', {
          'key': entry.key,
          'value': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> _writeOutbox(
    Transaction transaction,
    CalendarItem item,
    String operation,
  ) async {
    await transaction.insert('outbox', {
      'change_id': 'change_${_uuid.v4()}',
      'device_id': config.deviceId,
      'entity_type': 'item',
      'entity_id': item.id,
      'operation': operation,
      'entity_version': item.version,
      'payload_json': jsonEncode(_itemPayload(item)),
      'created_at': _timeText(item.updatedAt),
      'retry_count': 0,
      'last_error': null,
      'next_attempt_at': null,
      'permanent_failure': 0,
      'sent_at': null,
    });
  }

  Future<void> _writeCollectionOutbox(
    Transaction transaction,
    Map<String, Object?> collection,
  ) async {
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
    await transaction.insert('outbox', {
      'change_id': 'change_${_uuid.v4()}',
      'device_id': config.deviceId,
      'entity_type': 'collection',
      'entity_id': collection['id'],
      'operation': 'create',
      'entity_version': collection['version'],
      'payload_json': jsonEncode(payload),
      'created_at': collection['updated_at'],
      'retry_count': 0,
      'last_error': null,
      'next_attempt_at': null,
      'permanent_failure': 0,
      'sent_at': null,
    });
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
      orderBy: 'created_at, change_id',
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
  Future<void> applyRemoteBatch(
    List<RemoteSyncChange> changes,
    String cursor,
  ) async {
    await _db.transaction((transaction) async {
      for (final change in changes) {
        if (change.payload['id'] != change.entityId ||
            change.payload['version'] != change.version) {
          throw const FormatException(
            'Remote change envelope does not match payload',
          );
        }
        switch (change.entityType) {
          case 'collection':
            await transaction.insert(
              'collections',
              _remoteCollectionRow(change.payload),
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            break;
          case 'item':
            await transaction.insert(
              'items',
              _remoteItemRow(change.payload),
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            break;
          case 'subscription':
            await transaction.insert('subscriptions', {
              'id': change.entityId,
              'collection_id': change.payload['collection_id'],
              'payload_json': jsonEncode(change.payload),
              'updated_at': change.payload['updated_at'],
              'deleted_at': change.payload['deleted_at'],
              'version': change.version,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
            break;
          default:
            throw FormatException(
              'Unsupported sync entity: ${change.entityType}',
            );
        }
      }
      await transaction.insert('sync_state', {
        'key': 'remote_cursor',
        'value': cursor,
        'updated_at': _timeText(DateTime.now()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
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
    'recurrence': null,
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

  static bool _storedBool(String? value, bool fallback) =>
      value == null ? fallback : value == 'true';

  static String _colorText(int value) =>
      '#${(value & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  @override
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
