import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'transfer_models.dart';

class LocalJsonTransferService {
  const LocalJsonTransferService(this.database);

  final Database database;

  static const _backupKeys = [
    'collections',
    'items',
    'subscriptions',
    'outbox',
    'sync_state',
  ];

  Future<String> exportBackup() async {
    final payload = <String, Object?>{
      'schema_version': 1,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
    };
    for (final key in _backupKeys) {
      payload[key] = await database.query(_tableForBackupKey(key));
    }
    return jsonEncode(payload);
  }

  Future<TransferResult> previewImport(String content) async {
    final decoded = _decodeBackup(content, validateVersion: true);
    final created = <String, int>{};
    final skipped = <String, int>{};
    final conflicts = <String, int>{};
    final issues = <TransferIssue>[];

    final backupCollectionIds = <String>{};
    for (final key in _backupKeys) {
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
      final existingRows = await database.query(_tableForBackupKey(key));
      final identityColumn = _identityColumnForBackupKey(key);
      final existingIds = existingRows
          .map((row) => row[identityColumn] as String)
          .toSet();
      for (var index = 0; index < values.length; index++) {
        final entry = values[index];
        if (entry is! Map) {
          issues.add(
            TransferIssue(resourceType: key, index: index, message: '条目必须是对象'),
          );
          continue;
        }
        final id = entry[identityColumn];
        if (id is! String || id.isEmpty) {
          issues.add(
            TransferIssue(resourceType: key, index: index, message: '缺少有效 ID'),
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
    await _validateCollectionReferences(
      decoded,
      backupCollectionIds: backupCollectionIds,
      conflicts: conflicts,
      issues: issues,
    );

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

  Future<void> commitImport(String content) async {
    final decoded = _decodeBackup(content);
    await database.transaction((transaction) async {
      for (final key in _backupKeys) {
        final values = decoded[key];
        if (values is! List) continue;
        final table = _tableForBackupKey(key);
        final identityColumn = _identityColumnForBackupKey(key);
        final existingRows = await transaction.query(table);
        final existingIds = existingRows
            .map((row) => row[identityColumn] as String)
            .toSet();
        for (final entry in values) {
          if (entry is! Map) continue;
          final id = entry[identityColumn];
          if (id is! String || id.isEmpty || existingIds.contains(id)) {
            continue;
          }
          final row = Map<String, Object?>.from(
            entry.map((key, value) => MapEntry(key, value)),
          );
          await transaction.insert(table, row);
        }
      }
    });
  }

  Future<void> _validateCollectionReferences(
    Map<String, dynamic> decoded, {
    required Set<String> backupCollectionIds,
    required Map<String, int> conflicts,
    required List<TransferIssue> issues,
  }) async {
    final allCollectionIds = {
      ...backupCollectionIds,
      ...(await database.query(
        'collections',
      )).map((row) => row['id'] as String),
    };
    for (final key in const ['items', 'subscriptions']) {
      final values = decoded[key];
      if (values is! List) continue;
      for (var index = 0; index < values.length; index++) {
        final entry = values[index];
        if (entry is! Map) continue;
        final collectionId = entry['collection_id'];
        if (collectionId is! String ||
            collectionId.isEmpty ||
            allCollectionIds.contains(collectionId)) {
          continue;
        }
        final resourceId = entry['id'];
        issues.add(
          TransferIssue(
            resourceType: key,
            index: index,
            message: 'Collection $collectionId 不存在',
            resourceId: resourceId is String ? resourceId : null,
          ),
        );
        conflicts[key] = (conflicts[key] ?? 0) + 1;
      }
    }
  }

  static Map<String, dynamic> _decodeBackup(
    String content, {
    bool validateVersion = false,
  }) {
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('备份文件根节点必须是 JSON object');
    }
    if (validateVersion && decoded['schema_version'] != 1) {
      throw FormatException('不支持的备份版本：${decoded['schema_version']}');
    }
    return decoded;
  }

  static String _tableForBackupKey(String key) => switch (key) {
    'collections' => 'collections',
    'items' => 'items',
    'subscriptions' => 'subscriptions',
    'outbox' => 'outbox',
    'sync_state' => 'sync_state',
    _ => throw FormatException('Unknown backup key: $key'),
  };

  static String _identityColumnForBackupKey(String key) => switch (key) {
    'outbox' => 'change_id',
    'sync_state' => 'key',
    'collections' || 'items' || 'subscriptions' => 'id',
    _ => throw FormatException('Unknown backup key: $key'),
  };
}
