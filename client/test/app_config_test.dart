import 'package:easy_calendar/config/app_config.dart';
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
  });
}
