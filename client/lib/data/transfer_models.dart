class TransferResult {
  const TransferResult({
    required this.accepted,
    required this.committed,
    required this.format,
    required this.created,
    required this.skipped,
    required this.conflicts,
    required this.issues,
  });

  final bool accepted;
  final bool committed;
  final String format;
  final Map<String, int> created;
  final Map<String, int> skipped;
  final Map<String, int> conflicts;
  final List<TransferIssue> issues;
}

class TransferIssue {
  const TransferIssue({
    required this.resourceType,
    required this.index,
    required this.message,
    this.resourceId,
    this.code = 'invalid',
  });

  final String resourceType;
  final int index;
  final String message;
  final String? resourceId;
  final String code;
}

enum LocalBackupReason { migration, manual, preRestore }

class LocalDatabaseBackup {
  const LocalDatabaseBackup({
    required this.path,
    required this.createdAt,
    required this.byteSize,
    required this.reason,
    required this.schemaVersion,
  });

  final String path;
  final DateTime createdAt;
  final int byteSize;
  final LocalBackupReason reason;
  final int schemaVersion;

  String get fileName => path.replaceAll('\\', '/').split('/').last;
}
