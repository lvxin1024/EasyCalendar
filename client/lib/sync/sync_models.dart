abstract interface class SyncChangeValue {
  String get changeId;
  String get deviceId;
  String get entityType;
  String get entityId;
  String get operation;
  int get version;
  DateTime get updatedAt;
  Map<String, Object?> get payload;
}

int compareSyncChanges(SyncChangeValue left, SyncChangeValue right) {
  final time = left.updatedAt.compareTo(right.updatedAt);
  if (time != 0) return time;
  final version = left.version.compareTo(right.version);
  if (version != 0) return version;
  return left.changeId.compareTo(right.changeId);
}

Map<String, Object?> _changeJson(SyncChangeValue change) => {
  'change_id': change.changeId,
  'device_id': change.deviceId,
  'entity_type': change.entityType,
  'entity_id': change.entityId,
  'operation': change.operation,
  'version': change.version,
  'updated_at': change.updatedAt.toUtc().toIso8601String(),
  'payload': change.payload,
};

class PendingSyncChange implements SyncChangeValue {
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

  @override
  final String changeId;
  @override
  final String deviceId;
  @override
  final String entityType;
  @override
  final String entityId;
  @override
  final String operation;
  @override
  final int version;
  @override
  final DateTime updatedAt;
  @override
  final Map<String, Object?> payload;
  final int retryCount;

  Map<String, Object?> toJson() => _changeJson(this);
}

class RemoteSyncChange implements SyncChangeValue {
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

  @override
  final String changeId;
  @override
  final String deviceId;
  @override
  final String entityType;
  @override
  final String entityId;
  @override
  final String operation;
  @override
  final int version;
  @override
  final DateTime updatedAt;
  @override
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => _changeJson(this);
}

class SyncConflictSummary {
  const SyncConflictSummary({
    required this.entityType,
    required this.entityId,
    required this.resolution,
    required this.winner,
    required this.loser,
  });

  factory SyncConflictSummary.fromJson(Map<String, Object?> json) =>
      SyncConflictSummary(
        entityType: json['entity_type'] as String,
        entityId: json['entity_id'] as String,
        resolution: json['resolution'] as String,
        winner: RemoteSyncChange.fromJson(
          (json['winner'] as Map<Object?, Object?>).cast<String, Object?>(),
        ),
        loser: RemoteSyncChange.fromJson(
          (json['loser'] as Map<Object?, Object?>).cast<String, Object?>(),
        ),
      );

  final String entityType;
  final String entityId;
  final String resolution;
  final RemoteSyncChange winner;
  final RemoteSyncChange loser;
}

class SyncConflictRecord {
  const SyncConflictRecord({
    required this.id,
    required this.recordedAt,
    required this.winner,
    required this.loser,
  });

  final int id;
  final DateTime recordedAt;
  final RemoteSyncChange winner;
  final RemoteSyncChange loser;
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
  const PushSyncResult({
    required this.accepted,
    required this.rejected,
    this.conflicts = const [],
  });

  final List<String> accepted;
  final List<SyncRejection> rejected;
  final List<SyncConflictSummary> conflicts;
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
