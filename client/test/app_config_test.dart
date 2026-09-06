import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/domain/sync_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runtime defaults follow the injected host locale and timezone', () {
    final config = AppConfig.fromEnvironment(
      systemLocale: const Locale('en', 'GB'),
      systemTimezone: 'Europe/London',
    );

    expect(config.locale, const Locale('en', 'GB'));
    expect(config.timezone, 'Europe/London');
    expect(config.localePreference, 'system');
    expect(config.timezonePreference, 'system');
    expect(config.syncMode, SyncMode.local);
    expect(config.syncEnabled, isFalse);
  });

  test('explicit sync mode is independent from the legacy enable flag', () {
    const config = AppConfig(
      appName: 'EasyCalendar',
      locale: Locale('zh', 'CN'),
      timezone: 'Asia/Shanghai',
      defaultCollectionId: 'collection_local',
      defaultCollectionName: '我的日程',
      defaultCollectionColor: Color(0xFF2563EB),
      databaseName: 'test.sqlite3',
      deviceId: 'test-device',
      apiUrl: 'https://sync.example.com',
      syncMode: SyncMode.group,
      syncEnabled: true,
      syncRetryLimit: 8,
      notificationsEnabled: false,
    );

    expect(config.syncMode, SyncMode.group);
    expect(config.syncEnabled, isTrue);
  });
}
