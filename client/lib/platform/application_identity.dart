import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

enum LegacyApplicationDataMigration { notNeeded, moved, copied }

/// Keeps data created by Windows builds whose version metadata used the
/// original Flutter project name. Other platforms retain their package IDs.
Future<LegacyApplicationDataMigration>
migrateLegacyWindowsApplicationSupportDirectory({
  String? operatingSystem,
  Directory? currentSupportDirectory,
  Directory? legacySupportDirectory,
}) async {
  if ((operatingSystem ?? Platform.operatingSystem) != 'windows') {
    return LegacyApplicationDataMigration.notNeeded;
  }

  final current =
      currentSupportDirectory ?? await getApplicationSupportDirectory();
  final legacy =
      legacySupportDirectory ??
      Directory(
        path.join(
          current.parent.parent.path,
          'io.easycalendar',
          'easy_calendar',
        ),
      );
  if (path.equals(current.path, legacy.path) || !await legacy.exists()) {
    return LegacyApplicationDataMigration.notNeeded;
  }

  await current.create(recursive: true);
  if (await _isEmpty(current)) {
    await current.delete();
    try {
      await legacy.rename(current.path);
      return LegacyApplicationDataMigration.moved;
    } on FileSystemException {
      await current.create(recursive: true);
    }
  }

  // A partially initialized target may contain newer data. Copy only missing
  // entries and retain the legacy directory as a recovery source.
  await _copyMissingEntries(legacy, current);
  return LegacyApplicationDataMigration.copied;
}

Future<bool> _isEmpty(Directory directory) =>
    directory.list(followLinks: false).isEmpty;

Future<void> _copyMissingEntries(Directory source, Directory target) async {
  await for (final entity in source.list(followLinks: false)) {
    final destinationPath = path.join(target.path, path.basename(entity.path));
    if (entity is Directory) {
      final destination = Directory(destinationPath);
      await destination.create(recursive: true);
      await _copyMissingEntries(entity, destination);
    } else if (entity is File && !await File(destinationPath).exists()) {
      await entity.copy(destinationPath);
    }
  }
}
