class PendingSyncChange {
  const PendingSyncChange({
    required this.changeId,
    required this.deviceId,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.version,
    required this.updatedAt,
    required this.payload,
    required this.retryCount,
  });

  final String changeId;
  final String deviceId;
  final String entityType;
  final String entityId;
  final String operation;
  final int version;
  final DateTime updatedAt;
  final Map<String, Object?> payload;
  final int retryCount;

  Map<String, Object?> toJson() => {
    'change_id': changeId,
    'device_id': deviceId,
    'entity_type': entityType,
    'entity_id': entityId,
    'operation': operation,
    'version': version,
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'payload': payload,
  };
}

class RemoteSyncChange {
  const RemoteSyncChange({
    required this.changeId,
    required this.deviceId,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.version,
    required this.updatedAt,
    required this.payload,
  });

  factory RemoteSyncChange.fromJson(Map<String, Object?> json) {
    final payload = json['payload'];
    if (payload is! Map<String, Object?>) {
      throw const FormatException('Sync change payload must be an object');
    }
    return RemoteSyncChange(
      changeId: json['change_id'] as String,
      deviceId: json['device_id'] as String,
      entityType: json['entity_type'] as String,
      entityId: json['entity_id'] as String,
      operation: json['operation'] as String,
      version: json['version'] as int,
      updatedAt: DateTime.parse(json['updated_at'] as String),
      payload: payload,
    );
  }

  final String changeId;
  final String deviceId;
  final String entityType;
  final String entityId;
  final String operation;
  final int version;
  final DateTime updatedAt;
  final Map<String, Object?> payload;
}

class SyncRejection {
  const SyncRejection({
    required this.changeId,
    required this.code,
    required this.message,
  });

  final String changeId;
  final String code;
  final String message;
}

class PushSyncResult {
  const PushSyncResult({required this.accepted, required this.rejected});

  final List<String> accepted;
  final List<SyncRejection> rejected;
}

class PullSyncPage {
  const PullSyncPage({
    required this.cursor,
    required this.hasMore,
    required this.changes,
  });

  final String cursor;
  final bool hasMore;
  final List<RemoteSyncChange> changes;
}

enum SyncPhase { disabled, idle, syncing, backoff, needsAuthentication, failed }

class SyncSnapshot {
  const SyncSnapshot({
    required this.phase,
    this.lastSyncedAt,
    this.nextRetryAt,
    this.message,
  });

  const SyncSnapshot.disabled() : this(phase: SyncPhase.disabled);

  final SyncPhase phase;
  final DateTime? lastSyncedAt;
  final DateTime? nextRetryAt;
  final String? message;
}
