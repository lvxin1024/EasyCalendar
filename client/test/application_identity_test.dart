import 'dart:io';

import 'package:easy_calendar/platform/application_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'easycalendar-identity-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'moves the legacy Windows support directory when target is empty',
    () async {
      final legacy = Directory(path.join(temporaryDirectory.path, 'legacy'));
      final current = Directory(path.join(temporaryDirectory.path, 'current'));
      await legacy.create();
      await current.create();
      await File(
        path.join(legacy.path, 'easycalendar.sqlite3'),
      ).writeAsString('database');
      await File(
        path.join(legacy.path, 'flutter_secure_storage.dat'),
      ).writeAsString('secrets');

      final result = await migrateLegacyWindowsApplicationSupportDirectory(
        operatingSystem: 'windows',
        currentSupportDirectory: current,
        legacySupportDirectory: legacy,
      );

      expect(result, LegacyApplicationDataMigration.moved);
      expect(await legacy.exists(), isFalse);
      expect(
        await File(
          path.join(current.path, 'easycalendar.sqlite3'),
        ).readAsString(),
        'database',
      );
      expect(
        await File(
          path.join(current.path, 'flutter_secure_storage.dat'),
        ).readAsString(),
        'secrets',
      );
    },
  );

  test('copies missing legacy files without replacing current data', () async {
    final legacy = Directory(path.join(temporaryDirectory.path, 'legacy'));
    final current = Directory(path.join(temporaryDirectory.path, 'current'));
    await legacy.create();
    await current.create();
    await File(
      path.join(legacy.path, 'easycalendar.sqlite3'),
    ).writeAsString('legacy database');
    await File(
      path.join(legacy.path, 'recovery.sqlite3'),
    ).writeAsString('recovery');
    await File(
      path.join(current.path, 'easycalendar.sqlite3'),
    ).writeAsString('current database');

    final result = await migrateLegacyWindowsApplicationSupportDirectory(
      operatingSystem: 'windows',
      currentSupportDirectory: current,
      legacySupportDirectory: legacy,
    );

    expect(result, LegacyApplicationDataMigration.copied);
    expect(
      await File(
        path.join(current.path, 'easycalendar.sqlite3'),
      ).readAsString(),
      'current database',
    );
    expect(
      await File(path.join(current.path, 'recovery.sqlite3')).readAsString(),
      'recovery',
    );
    expect(await legacy.exists(), isTrue);
  });

  test('does not touch application data on other platforms', () async {
    final legacy = Directory(path.join(temporaryDirectory.path, 'legacy'));
    final current = Directory(path.join(temporaryDirectory.path, 'current'));
    await legacy.create();

    final result = await migrateLegacyWindowsApplicationSupportDirectory(
      operatingSystem: 'macos',
      currentSupportDirectory: current,
      legacySupportDirectory: legacy,
    );

    expect(result, LegacyApplicationDataMigration.notNeeded);
    expect(await current.exists(), isFalse);
    expect(await legacy.exists(), isTrue);
  });
}
