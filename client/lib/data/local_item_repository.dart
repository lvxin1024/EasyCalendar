import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import '../ai/ai_provider.dart';
import '../domain/item.dart';
import '../domain/recurrence.dart';
import '../domain/subscription.dart';
import '../sync/sync_models.dart';
import '../sync/sync_repository.dart';
import 'item_repository.dart';
import 'local_ics_service.dart';
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

  static const schemaVersion = 4;

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
    await _backupBeforeMigrationIfNeeded(factory);
    _database = await factory.openDatabase(
      databasePath!,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (database) async {
          await database.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
    await _ensureDefaultCollection();
    await _ensureLegacySyncHeads();
  }

  Future<void> _backupBeforeMigrationIfNeeded(DatabaseFactory factory) async {
    final source = File(databasePath!);
    if (_isMemoryDatabase(databasePath!) || !await source.exists()) return;
    Database? probe;
    try {
      probe = await factory.openDatabase(
        databasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await probe.execute('PRAGMA wal_checkpoint(FULL)');
      final rows = await probe.rawQuery('PRAGMA user_version');
      final existingVersion = _firstInteger(rows) ?? 0;
      await probe.close();
      probe = null;
      if (existingVersion > 0 && existingVersion < schemaVersion) {
        await _copyDatabaseBackup(
          reason: LocalBackupReason.migration,
          sourceSchemaVersion: existingVersion,
        );
      }
    } finally {
      await probe?.close();
    }
  }

  @override
  Future<List<LocalDatabaseBackup>> listLocalDatabaseBackups() async {
    final directory = _backupDirectory();
    if (!await directory.exists()) return const [];
    final backups = <LocalDatabaseBackup>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final match = RegExp(
        r'^easycalendar_(migration|manual|preRestore)_v(\d+)_(\d+)\.sqlite3$',
      ).firstMatch(path.basename(entity.path));
      if (match == null) continue;
      final reason = switch (match.group(1)) {
        'migration' => LocalBackupReason.migration,
        'preRestore' => LocalBackupReason.preRestore,
        _ => LocalBackupReason.manual,
      };
      final stat = await entity.stat();
      backups.add(
        LocalDatabaseBackup(
          path: entity.path,
          createdAt: DateTime.fromMicrosecondsSinceEpoch(
            int.parse(match.group(3)!),
            isUtc: true,
          ),
          byteSize: stat.size,
          reason: reason,
          schemaVersion: int.parse(match.group(2)!),
        ),
      );
    }
    backups.sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return backups;
  }

  @override
  Future<LocalDatabaseBackup> createLocalDatabaseBackup({
    LocalBackupReason reason = LocalBackupReason.manual,
  }) async {
    if (_isMemoryDatabase(databasePath ?? '')) {
      throw UnsupportedError('内存数据库不支持本地快照');
    }
    await _db.execute('PRAGMA wal_checkpoint(FULL)');
    final rows = await _db.rawQuery('PRAGMA user_version');
    return _copyDatabaseBackup(
      reason: reason,
      sourceSchemaVersion: _firstInteger(rows) ?? schemaVersion,
    );
  }

  Future<LocalDatabaseBackup> _copyDatabaseBackup({
    required LocalBackupReason reason,
    required int sourceSchemaVersion,
  }) async {
    final source = File(databasePath!);
    if (!await source.exists()) throw StateError('本地数据库文件不存在');
    final directory = _backupDirectory();
    await directory.create(recursive: true);
    final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final target = File(
      path.join(
        directory.path,
        'easycalendar_${reason.name}_v${sourceSchemaVersion}_$timestamp.sqlite3',
      ),
    );
    await source.copy(target.path);
    final stat = await target.stat();
    return LocalDatabaseBackup(
      path: target.path,
      createdAt: DateTime.fromMicrosecondsSinceEpoch(timestamp, isUtc: true),
      byteSize: stat.size,
      reason: reason,
      schemaVersion: sourceSchemaVersion,
    );
  }

  @override
  Future<void> restoreLocalDatabaseBackup(String backupPath) async {
    final selected = await _validatedBackupFile(backupPath);
    final safety = _database == null
        ? await _copyDatabaseBackup(
            reason: LocalBackupReason.preRestore,
            sourceSchemaVersion: await _closedDatabaseSchemaVersion(),
          )
        : await createLocalDatabaseBackup(reason: LocalBackupReason.preRestore);
    await close();
    try {
      await _replaceDatabaseWith(selected);
      await initialize();
    } catch (error) {
      await close();
      await _replaceDatabaseWith(File(safety.path));
      await initialize();
      throw RepositoryConflict('恢复失败，已回滚到恢复前状态：$error');
    }
  }

  Future<int> _closedDatabaseSchemaVersion() async {
    final factory = _databaseFactoryOverride ?? _databaseFactory();
    Database? probe;
    try {
      probe = await factory.openDatabase(
        databasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final rows = await probe.rawQuery('PRAGMA user_version');
      return _firstInteger(rows) ?? 0;
    } finally {
      await probe?.close();
    }
  }

  @override
  Future<void> deleteLocalDatabaseBackup(String backupPath) async {
    final backup = await _validatedBackupFile(backupPath);
    await backup.delete();
  }

  Future<File> _validatedBackupFile(String backupPath) async {
    final directory = path.normalize(path.absolute(_backupDirectory().path));
    final candidate = path.normalize(path.absolute(backupPath));
    if (path.dirname(candidate) != directory ||
        !RegExp(
          r'^easycalendar_(migration|manual|preRestore)_v\d+_\d+\.sqlite3$',
        ).hasMatch(path.basename(candidate))) {
      throw const FormatException('备份文件不在 EasyCalendar 恢复目录中');
    }
    final file = File(candidate);
    if (!await file.exists()) throw const FormatException('备份文件不存在');
    return file;
  }

  Future<void> _replaceDatabaseWith(File source) async {
    final targetPath = databasePath!;
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      final file = File('$targetPath$suffix');
      if (await file.exists()) await file.delete();
    }
    await source.copy(targetPath);
  }

  Directory _backupDirectory() {
    final value = databasePath;
    if (value == null || _isMemoryDatabase(value)) {
      throw StateError('本地数据库路径不可用于备份');
    }
    return Directory(path.join(path.dirname(value), 'backups'));
  }

  static bool _isMemoryDatabase(String value) =>
      value.isEmpty || value == inMemoryDatabasePath || value == ':memory:';

  static int? _firstInteger(List<Map<String, Object?>> rows) {
    if (rows.isEmpty || rows.first.isEmpty) return null;
    final value = rows.first.values.first;
    return value is int ? value : null;
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
        recurrence_json TEXT,
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
    await _createConflictSchema(database);
  }

  Future<void> _upgradeSchema(
    Database database,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
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
    if (oldVersion < 3) {
      await _createConflictSchema(database);
      await database.execute('''
        INSERT INTO sync_entity_heads (
          entity_type, entity_id, change_id, device_id, operation,
          entity_version, updated_at, payload_json
        )
        SELECT entity_type, entity_id, change_id, device_id, operation,
               entity_version, created_at, payload_json
        FROM outbox AS candidate
        WHERE NOT EXISTS (
          SELECT 1 FROM outbox AS other
          WHERE other.entity_type = candidate.entity_type
            AND other.entity_id = candidate.entity_id
            AND (
              other.created_at > candidate.created_at
              OR (
                other.created_at = candidate.created_at
                AND other.entity_version > candidate.entity_version
              )
              OR (
                other.created_at = candidate.created_at
                AND other.entity_version = candidate.entity_version
                AND other.change_id > candidate.change_id
              )
            )
        )
      ''');
    }
    if (oldVersion < 4) {
      await database.execute(
        'ALTER TABLE items ADD COLUMN recurrence_json TEXT',
      );
    }
  }

  static Future<void> _createConflictSchema(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE sync_entity_heads (
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        change_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        operation TEXT NOT NULL,
        entity_version INTEGER NOT NULL,
        updated_at TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        PRIMARY KEY (entity_type, entity_id)
      )
    ''');
    await database.execute('''
      CREATE TABLE sync_conflicts (
        conflict_id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        winner_change_id TEXT NOT NULL,
        loser_change_id TEXT NOT NULL,
        winner_json TEXT NOT NULL,
        loser_json TEXT NOT NULL,
        recorded_at TEXT NOT NULL,
        UNIQUE (entity_type, entity_id, winner_change_id, loser_change_id)
      )
    ''');
    await database.execute('''
      CREATE INDEX idx_client_sync_conflicts
      ON sync_conflicts (conflict_id DESC)
    ''');
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
  Future<String> exportLocalJsonBackup() async {
    final collections = await _db.query('collections');
    final items = await _db.query('items');
    final subscriptions = await _db.query('subscriptions');
    final outbox = await _db.query('outbox');
    final syncState = await _db.query('sync_state');
    final now = DateTime.now().toUtc().toIso8601String();
    final payload = {
      'schema_version': 1,
      'exported_at': now,
      'collections': collections,
      'items': items,
      'subscriptions': subscriptions,
      'outbox': outbox,
      'sync_state': syncState,
    };
    return jsonEncode(payload);
  }

  @override
  Future<TransferResult> previewLocalJsonImport(String content) async {
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('备份文件根节点必须是 JSON object');
    }
    final schemaVersion = decoded['schema_version'];
    if (schemaVersion != 1) {
      throw FormatException('不支持的备份版本：$schemaVersion');
    }
    final created = <String, int>{};
    final skipped = <String, int>{};
    final conflicts = <String, int>{};
    final issues = <TransferIssue>[];

    final backupCollectionIds = <String>{};
    for (final key in [
      'collections',
      'items',
      'subscriptions',
      'outbox',
      'sync_state',
    ]) {
      final values = decoded[key];
      if (values is! List) {
        issues.add(
          TransferIssue(resourceType: key, index: 0, message: '$key 必须是数组'),
        );
        continue;
      }
      if (key == 'collections') {
        for (final entry in values) {
          if (entry is Map) {
            final id = entry['id'];
            if (id is String && id.isNotEmpty) backupCollectionIds.add(id);
          }
        }
      }
      final existingRows = await _db.query(_tableForBackupKey(key));
      final existingIds = existingRows.map((r) => r['id'] as String).toSet();
      for (var i = 0; i < values.length; i++) {
        final entry = values[i];
        if (entry is! Map) {
          issues.add(
            TransferIssue(resourceType: key, index: i, message: '条目必须是对象'),
          );
          continue;
        }
        final id = entry['id'];
        if (id is! String || id.isEmpty) {
          issues.add(
            TransferIssue(resourceType: key, index: i, message: '缺少有效 ID'),
          );
          continue;
        }
        if (existingIds.contains(id)) {
          skipped[key] = (skipped[key] ?? 0) + 1;
        } else {
          created[key] = (created[key] ?? 0) + 1;
        }
      }
    }
    // Validate foreign keys: items and subscriptions must reference known collections
    final allCollectionIds = {
      ...backupCollectionIds,
      ...(await _db.query('collections')).map((r) => r['id'] as String),
    };
    final items = decoded['items'];
    if (items is List) {
      for (var i = 0; i < items.length; i++) {
        final entry = items[i];
        if (entry is! Map) continue;
        final collectionId = entry['collection_id'];
        if (collectionId is String &&
            collectionId.isNotEmpty &&
            !allCollectionIds.contains(collectionId)) {
          final itemId = entry['id'];
          issues.add(
            TransferIssue(
              resourceType: 'items',
              index: i,
              message: 'Collection $collectionId 不存在',
              resourceId: itemId is String ? itemId : null,
            ),
          );
          conflicts['items'] = (conflicts['items'] ?? 0) + 1;
        }
      }
    }
    final subscriptions = decoded['subscriptions'];
    if (subscriptions is List) {
      for (var i = 0; i < subscriptions.length; i++) {
        final entry = subscriptions[i];
        if (entry is! Map) continue;
        final collectionId = entry['collection_id'];
        if (collectionId is String &&
            collectionId.isNotEmpty &&
            !allCollectionIds.contains(collectionId)) {
          final subId = entry['id'];
          issues.add(
            TransferIssue(
              resourceType: 'subscriptions',
              index: i,
              message: 'Collection $collectionId 不存在',
              resourceId: subId is String ? subId : null,
            ),
          );
          conflicts['subscriptions'] = (conflicts['subscriptions'] ?? 0) + 1;
        }
      }
    }

    return TransferResult(
      accepted: issues.isEmpty,
      committed: false,
      format: 'json',
      created: created,
      skipped: skipped,
      conflicts: conflicts,
      issues: issues,
    );
  }

  @override
  Future<void> commitLocalJsonImport(String content) async {
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('备份文件根节点必须是 JSON object');
    }
    await _db.transaction((transaction) async {
      for (final key in [
        'collections',
        'items',
        'subscriptions',
        'outbox',
        'sync_state',
      ]) {
        final values = decoded[key];
        if (values is! List) continue;
        final table = _tableForBackupKey(key);
        final existingRows = await transaction.query(table);
        final existingIds = existingRows.map((r) => r['id'] as String).toSet();
        for (final entry in values) {
          if (entry is! Map) continue;
          final id = entry['id'];
          if (id is! String || id.isEmpty) continue;
          if (existingIds.contains(id)) continue;
          final row = Map<String, Object?>.from(
            entry.map((k, v) => MapEntry(k, v)),
          );
          await transaction.insert(table, row);
        }
      }
    });
  }

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
  }) async {
    final normalizedTitle = title.trim();
    final normalizedUrl = _validateSubscriptionUrl(url);
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
  }) async {
    final normalizedTitle = title.trim();
    final normalizedUrl = _validateSubscriptionUrl(url);
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
          final itemId = _subscriptionItemId(current.id, event.externalId);
          seen.add(itemId);
          final previous = existing[itemId];
          if (previous == null) {
            final created = _subscriptionItem(
              id: itemId,
              collectionId: current.collectionId,
              draft: event.draft,
              createdAt: fetchedAt,
              updatedAt: fetchedAt,
              version: 1,
            );
            await transaction.insert('items', _itemToRow(created));
            await _writeOutbox(transaction, created, 'create');
            createdCount += 1;
          } else if (_sameSubscriptionItem(previous, event.draft) &&
              !previous.isDeleted) {
            unchangedCount += 1;
          } else {
            final updated = _subscriptionItem(
              id: previous.id,
              collectionId: current.collectionId,
              draft: event.draft,
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

  static String _tableForBackupKey(String key) => switch (key) {
    'collections' => 'collections',
    'items' => 'items',
    'subscriptions' => 'subscriptions',
    'outbox' => 'outbox',
    'sync_state' => 'sync_state',
    _ => throw FormatException('Unknown backup key: $key'),
  };

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
    'metadata': {'refresh_interval_minutes': refreshIntervalMinutes},
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
  Future<ClientPreferences> loadPreferences(ClientPreferences defaults) async {
    final rows = await _db.query('app_settings');
    final values = {
      for (final row in rows) row['key'] as String: row['value'] as String,
    };
    return ClientPreferences(
      apiUrl: values['api_url'] ?? defaults.apiUrl,
      featureApiUrl: values['feature_api_url'] ?? defaults.featureApiUrl,
      timezone: values['timezone'] ?? defaults.timezone,
      localeName: values['locale_name'] ?? defaults.localeName,
      firstDayOfWeek: _storedFirstDayOfWeek(
        values['first_day_of_week'],
        defaults.firstDayOfWeek,
      ),
      clockFormat: _storedClockFormat(
        values['clock_format'],
        defaults.clockFormat,
      ),
      onboardingCompleted: values.containsKey('onboarding_completed')
          ? _storedBool(values['onboarding_completed'], false)
          : values.isNotEmpty,
      deviceId: values['device_id'] ?? defaults.deviceId,
      deviceName: values['device_name'] ?? defaults.deviceName,
      defaultCollectionId:
          values['default_collection_id'] ?? defaults.defaultCollectionId,
      defaultCollectionName:
          values['default_collection_name'] ?? defaults.defaultCollectionName,
      syncEnabled: _storedBool(values['sync_enabled'], defaults.syncEnabled),
      notificationsEnabled: _storedBool(
        values['notifications_enabled'],
        defaults.notificationsEnabled,
      ),
      windowOpacity: _storedOpacity(
        values['window_opacity'],
        defaults.windowOpacity,
      ),
      windowAlwaysOnTop: _storedBool(
        values['window_always_on_top'],
        defaults.windowAlwaysOnTop,
      ),
      assistantEnabled: _storedBool(
        values['assistant_enabled'],
        defaults.assistantEnabled,
      ),
      aiProviders: _storedProviders(
        values['ai_providers'],
        defaults.aiProviders,
      ),
      tagColors: _storedTagColors(values['tag_colors'], defaults.tagColors),
    );
  }

  @override
  Future<void> savePreferences(ClientPreferences preferences) async {
    await _db.transaction((transaction) async {
      for (final entry in {
        'api_url': preferences.apiUrl.trim(),
        'feature_api_url': preferences.featureApiUrl.trim(),
        'timezone': preferences.timezone.trim(),
        'locale_name': preferences.localeName.trim(),
        'first_day_of_week': preferences.firstDayOfWeek.toString(),
        'clock_format': preferences.clockFormat.name,
        'onboarding_completed': preferences.onboardingCompleted
            ? 'true'
            : 'false',
        'device_id': preferences.deviceId.trim(),
        'device_name': preferences.deviceName.trim(),
        'default_collection_id': preferences.defaultCollectionId.trim(),
        'default_collection_name': preferences.defaultCollectionName.trim(),
        'sync_enabled': preferences.syncEnabled ? 'true' : 'false',
        'notifications_enabled': preferences.notificationsEnabled
            ? 'true'
            : 'false',
        'window_opacity': preferences.windowOpacity.toString(),
        'window_always_on_top': preferences.windowAlwaysOnTop
            ? 'true'
            : 'false',
        'assistant_enabled': preferences.assistantEnabled ? 'true' : 'false',
        'ai_providers': jsonEncode(
          preferences.aiProviders.map((provider) => provider.toJson()).toList(),
        ),
        'tag_colors': jsonEncode(preferences.tagColors),
      }.entries) {
        await transaction.insert('app_settings', {
          'key': entry.key,
          'value': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  static double _storedOpacity(String? value, double fallback) {
    final parsed = double.tryParse(value ?? '');
    return (parsed ?? fallback).clamp(0.2, 1.0).toDouble();
  }

  static int _storedFirstDayOfWeek(String? value, int fallback) {
    final parsed = int.tryParse(value ?? '');
    return parsed != null && parsed >= 0 && parsed <= 7 ? parsed : fallback;
  }

  static ClockFormat _storedClockFormat(String? value, ClockFormat fallback) {
    for (final format in ClockFormat.values) {
      if (format.name == value) return format;
    }
    return fallback;
  }

  static List<AiProviderConfig> _storedProviders(
    String? value,
    List<AiProviderConfig> fallback,
  ) {
    if (value == null || value.trim().isEmpty) return fallback;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) return fallback;
      return decoded
          .whereType<Map>()
          .map(
            (entry) =>
                AiProviderConfig.fromJson(Map<String, dynamic>.from(entry)),
          )
          .toList(growable: false);
    } catch (_) {
      return fallback;
    }
  }

  static Map<String, int> _storedTagColors(
    String? value,
    Map<String, int> fallback,
  ) {
    if (value == null || value.trim().isEmpty) return fallback;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return fallback;
      return decoded.map<String, int>((key, value) {
        final parsed = value is int ? value : int.tryParse('$value');
        if (parsed == null) throw const FormatException('invalid tag color');
        return MapEntry('$key', parsed);
      });
    } catch (_) {
      return fallback;
    }
  }

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
      default:
        throw FormatException('Unsupported sync entity: ${change.entityType}');
    }
    await _upsertSyncHead(transaction, change);
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
