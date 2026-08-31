import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'transfer_models.dart';

class LocalDatabaseBackupStore {
  const LocalDatabaseBackupStore({
    required this.databasePath,
    required this.databaseFactory,
    required this.currentSchemaVersion,
  });

  final String databasePath;
  final DatabaseFactory databaseFactory;
  final int currentSchemaVersion;

  Future<void> backupBeforeMigrationIfNeeded() async {
    // A second mobile connection can outlive sqflite's singleton/WAL owner.
    // The normal onUpgrade callback still performs the actual migration.
    if (Platform.isAndroid || Platform.isIOS) return;
    final source = File(databasePath);
    if (isMemoryDatabase || !await source.exists()) return;
    Database? probe;
    try {
      probe = await databaseFactory.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await probe.rawQuery('PRAGMA wal_checkpoint(FULL)');
      final rows = await probe.rawQuery('PRAGMA user_version');
      final existingVersion = _firstInteger(rows) ?? 0;
      await probe.close();
      probe = null;
      if (existingVersion > 0 && existingVersion < currentSchemaVersion) {
        await copyBackup(
          reason: LocalBackupReason.migration,
          sourceSchemaVersion: existingVersion,
        );
      }
    } finally {
      await probe?.close();
    }
  }

  Future<List<LocalDatabaseBackup>> listBackups() async {
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

  Future<LocalDatabaseBackup> createBackup(
    Database database, {
    LocalBackupReason reason = LocalBackupReason.manual,
  }) async {
    if (isMemoryDatabase) {
      throw UnsupportedError('内存数据库不支持本地快照');
    }
    await database.rawQuery('PRAGMA wal_checkpoint(FULL)');
    final rows = await database.rawQuery('PRAGMA user_version');
    return copyBackup(
      reason: reason,
      sourceSchemaVersion: _firstInteger(rows) ?? currentSchemaVersion,
    );
  }

  Future<LocalDatabaseBackup> copyBackup({
    required LocalBackupReason reason,
    required int sourceSchemaVersion,
  }) async {
    final source = File(databasePath);
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

  Future<int> closedDatabaseSchemaVersion() async {
    Database? probe;
    try {
      probe = await databaseFactory.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final rows = await probe.rawQuery('PRAGMA user_version');
      return _firstInteger(rows) ?? 0;
    } finally {
      await probe?.close();
    }
  }

  Future<void> deleteBackup(String backupPath) async {
    final backup = await validatedBackupFile(backupPath);
    await backup.delete();
  }

  Future<File> validatedBackupFile(String backupPath) async {
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

  Future<void> replaceDatabaseWith(String sourcePath) async {
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      final file = File('$databasePath$suffix');
      if (await file.exists()) await file.delete();
    }
    await File(sourcePath).copy(databasePath);
  }

  bool get isMemoryDatabase =>
      databasePath.isEmpty ||
      databasePath == inMemoryDatabasePath ||
      databasePath == ':memory:';

  Directory _backupDirectory() {
    if (isMemoryDatabase) {
      throw StateError('本地数据库路径不可用于备份');
    }
    return Directory(path.join(path.dirname(databasePath), 'backups'));
  }

  static int? _firstInteger(List<Map<String, Object?>> rows) {
    if (rows.isEmpty || rows.first.isEmpty) return null;
    final value = rows.first.values.first;
    return value is int ? value : null;
  }
}
