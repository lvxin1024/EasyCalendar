class CalendarSubscription {
  const CalendarSubscription({
    required this.id,
    required this.collectionId,
    required this.title,
    required this.url,
    required this.enabled,
    required this.version,
    this.lastFetchedAt,
    this.lastSuccessAt,
    this.lastError,
    this.etag,
    this.lastModified,
    this.sourceHash,
    this.refreshIntervalMinutes = 60,
  });

  factory CalendarSubscription.fromJson(Map<String, Object?> json) {
    final metadata = _map(json['metadata']);
    return CalendarSubscription(
      id: json['id'] as String,
      collectionId: json['collection_id'] as String? ?? '',
      title: json['title'] as String? ?? 'ICS 订阅',
      url: json['url'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
      version: json['version'] as int? ?? 1,
      lastFetchedAt: _date(json['last_fetched_at']),
      lastSuccessAt: _date(json['last_success_at']),
      lastError: json['last_error'] as String?,
      etag: json['etag'] as String?,
      lastModified: json['last_modified'] as String?,
      sourceHash: json['source_hash'] as String?,
      refreshIntervalMinutes:
          metadata['refresh_interval_minutes'] as int? ?? 60,
    );
  }

  final String id;
  final String collectionId;
  final String title;
  final String url;
  final bool enabled;
  final int version;
  final DateTime? lastFetchedAt;
  final DateTime? lastSuccessAt;
  final String? lastError;
  final String? etag;
  final String? lastModified;
  final String? sourceHash;
  final int refreshIntervalMinutes;
}

class SubscriptionFetchLog {
  const SubscriptionFetchLog({
    required this.status,
    this.fetchedAt,
    this.httpStatus,
    this.error,
    this.etag,
    this.sourceHash,
    this.createdCount = 0,
    this.updatedCount = 0,
    this.deletedCount = 0,
    this.unchangedCount = 0,
  });

  factory SubscriptionFetchLog.fromJson(Map<String, Object?> json) =>
      SubscriptionFetchLog(
        status: json['status'] as String? ?? 'unknown',
        fetchedAt: _date(json['fetched_at'] ?? json['finished_at']),
        httpStatus: json['http_status'] as int?,
        error: json['error'] as String? ?? json['last_error'] as String?,
        etag: json['etag'] as String?,
        sourceHash: json['source_hash'] as String?,
        createdCount: json['created_count'] as int? ?? 0,
        updatedCount: json['updated_count'] as int? ?? 0,
        deletedCount: json['deleted_count'] as int? ?? 0,
        unchangedCount: json['unchanged_count'] as int? ?? 0,
      );

  final String status;
  final DateTime? fetchedAt;
  final int? httpStatus;
  final String? error;
  final String? etag;
  final String? sourceHash;
  final int createdCount;
  final int updatedCount;
  final int deletedCount;
  final int unchangedCount;

  Map<String, Object?> toJson() => {
    'status': status,
    'fetched_at': fetchedAt?.toUtc().toIso8601String(),
    'http_status': httpStatus,
    'error': error,
    'etag': etag,
    'source_hash': sourceHash,
    'created_count': createdCount,
    'updated_count': updatedCount,
    'deleted_count': deletedCount,
    'unchanged_count': unchangedCount,
  };
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

Map<String, Object?> _map(Object? value) =>
    value is Map<Object?, Object?> ? value.cast<String, Object?>() : const {};
