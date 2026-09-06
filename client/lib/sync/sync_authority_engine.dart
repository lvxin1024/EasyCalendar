import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'sync_authority.dart';
import 'sync_models.dart';

class SyncAuthorityEngine {
  SyncAuthorityEngine(
    this.store, {
    required this.primaryDeviceId,
    this.maxBatchSize = 200,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _validateId(primaryDeviceId, 'primaryDeviceId');
    if (maxBatchSize < 1 || maxBatchSize > 1000) {
      throw const FormatException('Authority 批次大小必须在 1 到 1000 之间');
    }
  }

  final SyncAuthorityStore store;
  final String primaryDeviceId;
  final int maxBatchSize;
  final DateTime Function() _clock;

  Future<PushSyncResult> push({
    required String deviceId,
    required String idempotencyKey,
    required List<PendingSyncChange> changes,
    String? endpointId,
  }) async {
    _validateId(deviceId, 'deviceId');
    _validateIdempotencyKey(idempotencyKey);
    final member = await store.findMember(
      deviceId: deviceId,
      endpointId: endpointId,
    );
    if (member == null) {
      throw const SyncAuthorityException(
        'member_revoked',
        'Device is not an active sync group member',
      );
    }
    final validated = _validateBatch(deviceId, changes);
    final requestHash = _hashJson({
      'device_id': deviceId,
      'changes': validated.map((change) => change.toJson()).toList(),
    });
    final replay = await store.loadRequest(idempotencyKey);
    if (replay != null) {
      if (replay.requestHash != requestHash) {
        throw const SyncAuthorityException(
          'idempotency_conflict',
          'Idempotency-Key was already used for a different request',
        );
      }
      return _pushResultFromJson(
        jsonDecode(replay.responseJson) as Map<Object?, Object?>,
      );
    }

    final accepted = <String>[];
    final rejected = <SyncRejection>[];
    final conflicts = <SyncConflictSummary>[];
    for (final change in _orderChanges(validated)) {
      try {
        final result = await store.applyChange(
          change,
          changeHash: _hashJson(change.toJson()),
        );
        accepted.add(change.changeId);
        if (result.conflict != null) conflicts.add(result.conflict!);
      } on SyncAuthorityException catch (error) {
        rejected.add(
          SyncRejection(
            changeId: change.changeId,
            code: error.code,
            message: error.message,
          ),
        );
      } catch (_) {
        rejected.add(
          SyncRejection(
            changeId: change.changeId,
            code: 'constraint_violation',
            message: 'Change could not be applied',
          ),
        );
      }
    }
    final response = PushSyncResult(
      accepted: accepted,
      rejected: rejected,
      conflicts: conflicts,
      serverCursor: await store.latestCursor(),
    );
    await store.saveRequest(
      SyncAuthorityRequest(
        idempotencyKey: idempotencyKey,
        requestHash: requestHash,
        responseJson: jsonEncode(_pushResultToJson(response)),
        createdAt: _clock(),
      ),
    );
    return response;
  }

  Future<PullSyncPage> pull({
    required String deviceId,
    String? endpointId,
    String? cursor,
    int limit = 200,
  }) async {
    _validateId(deviceId, 'deviceId');
    final member = await store.findMember(
      deviceId: deviceId,
      endpointId: endpointId,
    );
    if (member == null) {
      throw const SyncAuthorityException(
        'member_revoked',
        'Device is not an active sync group member',
      );
    }
    if (limit < 1 || limit > maxBatchSize) {
      throw const SyncAuthorityException(
        'validation_error',
        'Pull limit is outside the configured range',
      );
    }
    try {
      return await store.pull(cursor: cursor, limit: limit);
    } on FormatException catch (error) {
      throw SyncAuthorityException('cursor_invalid', error.message);
    }
  }

  List<RemoteSyncChange> _validateBatch(
    String deviceId,
    List<PendingSyncChange> changes,
  ) {
    if (changes.isEmpty) {
      throw const SyncAuthorityException(
        'validation_error',
        'changes must contain at least one change',
      );
    }
    if (changes.length > maxBatchSize) {
      throw const SyncAuthorityException(
        'validation_error',
        'changes exceed the configured batch size',
      );
    }
    final ids = <String>{};
    final result = <RemoteSyncChange>[];
    for (final change in changes) {
      if (!ids.add(change.changeId)) {
        throw const SyncAuthorityException(
          'validation_error',
          'change_id values must be unique within a batch',
        );
      }
      if (change.deviceId != deviceId) {
        throw const SyncAuthorityException(
          'validation_error',
          'change device_id must match the batch device_id',
        );
      }
      _validateId(change.changeId, 'change_id');
      _validateId(change.deviceId, 'device_id');
      _validateId(change.entityId, 'entity_id');
      if (!_entityTypes.contains(change.entityType)) {
        throw const SyncAuthorityException(
          'validation_error',
          'entity_type is invalid',
        );
      }
      if (!_operations.contains(change.operation)) {
        throw const SyncAuthorityException(
          'validation_error',
          'operation is invalid',
        );
      }
      if (change.version < 1) {
        throw const SyncAuthorityException(
          'validation_error',
          'version must be an integer of at least 1',
        );
      }
      if (!_hasTimezone(change.updatedAt)) {
        throw const SyncAuthorityException(
          'validation_error',
          'updated_at must include a timezone',
        );
      }
      _validatePayload(change);
      result.add(
        RemoteSyncChange(
          changeId: change.changeId,
          deviceId: change.deviceId,
          entityType: change.entityType,
          entityId: change.entityId,
          operation: change.operation,
          version: change.version,
          updatedAt: change.updatedAt,
          payload: change.payload,
        ),
      );
    }
    return result;
  }

  void _validatePayload(SyncChangeValue change) {
    final payload = change.payload;
    if (payload['id'] != change.entityId ||
        payload['version'] != change.version) {
      throw const SyncAuthorityException(
        'validation_error',
        'payload id and version must match the change',
      );
    }
    if (payload['updated_at'] != change.updatedAt.toUtc().toIso8601String()) {
      throw const SyncAuthorityException(
        'validation_error',
        'payload.updated_at must match change updated_at',
      );
    }
    if (change.operation == 'delete' &&
        !_validTimestamp(payload['deleted_at'])) {
      throw const SyncAuthorityException(
        'validation_error',
        'delete payload requires a deleted_at tombstone',
      );
    }
    switch (change.entityType) {
      case 'item':
        if (!_validIdValue(payload['collection_id']) ||
            !{'event', 'task', 'note'}.contains(payload['type'])) {
          throw const SyncAuthorityException(
            'validation_error',
            'Item payload requires collection_id and a valid type',
          );
        }
      case 'subscription':
        if (!_validIdValue(payload['collection_id'])) {
          throw const SyncAuthorityException(
            'validation_error',
            'Subscription payload requires collection_id',
          );
        }
      case 'cycle_period':
        if (payload['start_date'] is! String ||
            (payload['end_date'] != null && payload['end_date'] is! String) ||
            !_validTimestamp(payload['created_at']) ||
            !_validTimestamp(payload['updated_at']) ||
            payload['daily_logs'] is! List) {
          throw const SyncAuthorityException(
            'validation_error',
            'Cycle period payload is invalid',
          );
        }
      case 'cycle_settings':
        if (change.entityId != 'singleton' ||
            payload['enabled'] is! bool ||
            payload['forecast_horizon'] is! int ||
            !_validTimestamp(payload['updated_at'])) {
          throw const SyncAuthorityException(
            'validation_error',
            'Cycle settings payload is invalid',
          );
        }
      case 'collection':
        break;
    }
  }

  static List<RemoteSyncChange> _orderChanges(List<RemoteSyncChange> changes) =>
      [...changes]..sort((left, right) {
        final entity = (_entityPriority[left.entityType] ?? 99).compareTo(
          _entityPriority[right.entityType] ?? 99,
        );
        if (entity != 0) return entity;
        final time = left.updatedAt.compareTo(right.updatedAt);
        if (time != 0) return time;
        final id = left.changeId.compareTo(right.changeId);
        return id;
      });

  static void _validateId(String value, String field) {
    if (!_validIdValue(value)) {
      throw SyncAuthorityException('validation_error', '$field is invalid');
    }
  }

  static void _validateIdempotencyKey(String value) {
    _validateId(value, 'idempotency_key');
  }

  static bool _validIdValue(Object? value) =>
      value is String &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$').hasMatch(value);

  static bool _hasTimezone(DateTime value) =>
      value.isUtc || value.timeZoneOffset != Duration.zero;

  static bool _validTimestamp(Object? value) {
    if (value is! String || !RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(value)) {
      return false;
    }
    return DateTime.tryParse(value) != null;
  }

  static String _hashJson(Object? value) =>
      sha256.convert(utf8.encode(_canonicalJson(value))).toString();

  static String _canonicalJson(Object? value) {
    if (value is List) {
      return '[${value.map(_canonicalJson).join(',')}]';
    }
    if (value is Map) {
      final entries = value.keys.map((key) {
        if (key is! String) {
          throw const FormatException('JSON object keys must be strings');
        }
        return key;
      }).toList()..sort();
      return '{${entries.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
    }
    return jsonEncode(value);
  }

  static Map<String, Object?> _pushResultToJson(PushSyncResult result) => {
    'accepted': result.accepted,
    'rejected': result.rejected
        .map(
          (value) => {
            'change_id': value.changeId,
            'code': value.code,
            'message': value.message,
          },
        )
        .toList(),
    'conflicts': result.conflicts.map(_conflictToJson).toList(),
    'server_cursor': result.serverCursor,
  };

  static PushSyncResult _pushResultFromJson(Map<Object?, Object?> json) {
    final rejected = (json['rejected'] as List<Object?>)
        .map((value) {
          final item = (value as Map<Object?, Object?>).cast<String, Object?>();
          return SyncRejection(
            changeId: item['change_id'] as String,
            code: item['code'] as String,
            message: item['message'] as String,
          );
        })
        .toList(growable: false);
    final conflicts = (json['conflicts'] as List<Object?>)
        .map(
          (value) => SyncConflictSummary.fromJson(
            (value as Map<Object?, Object?>).cast<String, Object?>(),
          ),
        )
        .toList(growable: false);
    return PushSyncResult(
      accepted: (json['accepted'] as List<Object?>).cast<String>(),
      rejected: rejected,
      conflicts: conflicts,
      serverCursor: json['server_cursor'] as String?,
    );
  }

  static Map<String, Object?> _conflictToJson(SyncConflictSummary value) => {
    'entity_type': value.entityType,
    'entity_id': value.entityId,
    'resolution': value.resolution,
    'winner': value.winner.toJson(),
    'loser': value.loser.toJson(),
  };

  static const _entityTypes = {
    'item',
    'collection',
    'subscription',
    'cycle_period',
    'cycle_settings',
  };
  static const _operations = {'create', 'update', 'delete'};
  static const _entityPriority = {
    'collection': 0,
    'subscription': 1,
    'item': 2,
    'cycle_period': 3,
    'cycle_settings': 4,
  };
}
