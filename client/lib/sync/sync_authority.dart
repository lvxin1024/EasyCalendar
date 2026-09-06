import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sync_models.dart';

class SyncAuthorityMember {
  const SyncAuthorityMember({
    required this.endpointId,
    required this.deviceId,
    required this.displayName,
    required this.status,
    required this.joinedAt,
    this.lastSeenAt,
  });

  final String endpointId;
  final String deviceId;
  final String displayName;
  final String status;
  final DateTime joinedAt;
  final DateTime? lastSeenAt;
}

class SyncAuthorityRequest {
  const SyncAuthorityRequest({
    required this.idempotencyKey,
    required this.requestHash,
    required this.responseJson,
    required this.createdAt,
  });

  final String idempotencyKey;
  final String requestHash;
  final String responseJson;
  final DateTime createdAt;
}

class SyncAuthorityStore {
  const SyncAuthorityStore(this.database);

  final Database database;

  Future<int> appendChange(RemoteSyncChange change) async {
    final existing = await database.query(
      'sync_authority_change_log',
      columns: ['sequence'],
      where: 'change_id = ?',
      whereArgs: [change.changeId],
      limit: 1,
    );
    if (existing.isNotEmpty) return existing.single['sequence'] as int;
    return database.insert('sync_authority_change_log', {
      'change_id': change.changeId,
      'device_id': change.deviceId,
      'entity_type': change.entityType,
      'entity_id': change.entityId,
      'operation': change.operation,
      'entity_version': change.version,
      'changed_at': change.updatedAt.toUtc().toIso8601String(),
      'payload_json': jsonEncode(change.payload),
    });
  }

  Future<void> replaceEntityHead(RemoteSyncChange change) async {
    await database.insert('sync_authority_entity_heads', {
      'entity_type': change.entityType,
      'entity_id': change.entityId,
      'change_id': change.changeId,
      'device_id': change.deviceId,
      'operation': change.operation,
      'entity_version': change.version,
      'updated_at': change.updatedAt.toUtc().toIso8601String(),
      'payload_json': jsonEncode(change.payload),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<PullSyncPage> pull({String? cursor, int limit = 200}) async {
    if (limit < 1 || limit > 1000) {
      throw const FormatException('同步拉取数量必须在 1 到 1000 之间');
    }
    final after = _parseCursor(cursor);
    final rows = await database.query(
      'sync_authority_change_log',
      where: 'sequence > ?',
      whereArgs: [after],
      orderBy: 'sequence ASC',
      limit: limit + 1,
    );
    final hasMore = rows.length > limit;
    final page = hasMore ? rows.take(limit).toList() : rows;
    final changes = page.map(_changeFromRow).toList(growable: false);
    final next = page.isEmpty ? after : page.last['sequence'] as int;
    return PullSyncPage(
      cursor: 'cur_$next',
      hasMore: hasMore,
      changes: changes,
    );
  }

  Future<void> saveRequest(SyncAuthorityRequest request) async {
    await database.insert('sync_authority_requests', {
      'idempotency_key': request.idempotencyKey,
      'request_hash': request.requestHash,
      'response_json': request.responseJson,
      'created_at': request.createdAt.toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<SyncAuthorityRequest?> loadRequest(String idempotencyKey) async {
    final rows = await database.query(
      'sync_authority_requests',
      where: 'idempotency_key = ?',
      whereArgs: [idempotencyKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return SyncAuthorityRequest(
      idempotencyKey: row['idempotency_key'] as String,
      requestHash: row['request_hash'] as String,
      responseJson: row['response_json'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  Future<void> upsertMember(SyncAuthorityMember member) async {
    await database.insert('sync_group_members', {
      'endpoint_id': member.endpointId,
      'device_id': member.deviceId,
      'display_name': member.displayName,
      'status': member.status,
      'joined_at': member.joinedAt.toUtc().toIso8601String(),
      'last_seen_at': member.lastSeenAt?.toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<SyncAuthorityMember>> listMembers() async {
    final rows = await database.query(
      'sync_group_members',
      orderBy: 'joined_at ASC, endpoint_id ASC',
    );
    return rows
        .map(
          (row) => SyncAuthorityMember(
            endpointId: row['endpoint_id'] as String,
            deviceId: row['device_id'] as String,
            displayName: row['display_name'] as String,
            status: row['status'] as String,
            joinedAt: DateTime.parse(row['joined_at'] as String),
            lastSeenAt: (row['last_seen_at'] as String?) == null
                ? null
                : DateTime.parse(row['last_seen_at'] as String),
          ),
        )
        .toList(growable: false);
  }

  Future<void> saveState(
    String key,
    String value, {
    DateTime? updatedAt,
  }) async {
    await database.insert('sync_group_state', {
      'key': key,
      'value': value,
      'updated_at': (updatedAt ?? DateTime.now()).toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> loadState(String key) async {
    final rows = await database.query(
      'sync_group_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  static RemoteSyncChange _changeFromRow(Map<String, Object?> row) =>
      RemoteSyncChange(
        changeId: row['change_id'] as String,
        deviceId: row['device_id'] as String,
        entityType: row['entity_type'] as String,
        entityId: row['entity_id'] as String,
        operation: row['operation'] as String,
        version: row['entity_version'] as int,
        updatedAt: DateTime.parse(row['changed_at'] as String),
        payload: (jsonDecode(row['payload_json'] as String) as Map)
            .cast<String, Object?>(),
      );

  static int _parseCursor(String? cursor) {
    if (cursor == null || cursor.isEmpty) return 0;
    final match = RegExp(r'^cur_(0|[1-9][0-9]*)$').firstMatch(cursor);
    final value = int.tryParse(match?.group(1) ?? '');
    if (value == null || value < 0) {
      throw const FormatException('同步 cursor 无效');
    }
    return value;
  }
}
