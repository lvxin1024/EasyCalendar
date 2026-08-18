import 'package:flutter/material.dart';

import '../device/device_identity.dart';

class AppConfig {
  const AppConfig({
    required this.appName,
    required this.locale,
    required this.timezone,
    required this.defaultCollectionId,
    required this.defaultCollectionName,
    required this.defaultCollectionColor,
    required this.databaseName,
    required this.deviceId,
    required this.apiUrl,
    this.featureApiUrl = 'http://localhost:8000',
    required this.syncEnabled,
    required this.syncRetryLimit,
    required this.notificationsEnabled,
    this.localePreference,
    this.timezonePreference,
  });

  factory AppConfig.fromEnvironment({
    DeviceIdentity? deviceIdentity,
    Locale? systemLocale,
    String? systemTimezone,
  }) {
    final identity = deviceIdentity ?? DeviceIdentity();
    const localeName = String.fromEnvironment(
      'EASYCALENDAR_LOCALE',
      defaultValue: '',
    );
    const timezoneName = String.fromEnvironment('EASYCALENDAR_TIMEZONE');
    final resolvedLocale = localeName.trim().isEmpty
        ? systemLocale ?? const Locale('zh', 'CN')
        : _parseLocale(localeName);
    final resolvedTimezone = timezoneName.trim().isEmpty
        ? systemTimezone ?? 'Asia/Shanghai'
        : timezoneName.trim();
    const colorValue = String.fromEnvironment(
      'EASYCALENDAR_DEFAULT_COLLECTION_COLOR',
      defaultValue: '#2563EB',
    );
    const configuredDeviceId = String.fromEnvironment(
      'EASYCALENDAR_DEVICE_ID',
      defaultValue: '',
    );
    return AppConfig(
      appName: const String.fromEnvironment(
        'EASYCALENDAR_APP_NAME',
        defaultValue: 'EasyCalendar',
      ),
      locale: resolvedLocale,
      timezone: resolvedTimezone,
      localePreference: localeName.trim().isEmpty ? 'system' : localeName,
      timezonePreference: timezoneName.trim().isEmpty
          ? 'system'
          : timezoneName.trim(),
      defaultCollectionId: const String.fromEnvironment(
        'EASYCALENDAR_DEFAULT_COLLECTION_ID',
        defaultValue: 'collection_local',
      ),
      defaultCollectionName: const String.fromEnvironment(
        'EASYCALENDAR_DEFAULT_COLLECTION_NAME',
        defaultValue: '我的日程',
      ),
      defaultCollectionColor: _parseColor(colorValue),
      databaseName: const String.fromEnvironment(
        'EASYCALENDAR_DATABASE_NAME',
        defaultValue: 'easycalendar.sqlite3',
      ),
      deviceId: identity.resolveInitialId(configuredDeviceId),
      apiUrl: const String.fromEnvironment(
        'EASYCALENDAR_API_URL',
        defaultValue: 'http://localhost:8000',
      ),
      featureApiUrl: const String.fromEnvironment(
        'EASYCALENDAR_FEATURE_API_URL',
        defaultValue: 'http://localhost:8000',
      ),
      syncEnabled: _parseBool(
        const String.fromEnvironment(
          'EASYCALENDAR_SYNC_ENABLED',
          defaultValue: 'false',
        ),
      ),
      syncRetryLimit: const int.fromEnvironment(
        'EASYCALENDAR_SYNC_RETRY_LIMIT',
        defaultValue: 8,
      ),
      notificationsEnabled: _parseBool(
        const String.fromEnvironment(
          'EASYCALENDAR_NOTIFICATIONS_ENABLED',
          defaultValue: 'false',
        ),
      ),
    );
  }

  final String appName;
  final Locale locale;
  final String timezone;
  final String defaultCollectionId;
  final String defaultCollectionName;
  final Color defaultCollectionColor;
  final String databaseName;
  final String deviceId;
  final String apiUrl;
  final String featureApiUrl;
  final bool syncEnabled;
  final int syncRetryLimit;
  final bool notificationsEnabled;
  final String? localePreference;
  final String? timezonePreference;

  static bool _parseBool(String value) => value.toLowerCase() == 'true';

  static Locale _parseLocale(String value) {
    final parts = value.replaceAll('_', '-').split('-');
    return Locale(parts.first, parts.length > 1 ? parts[1] : null);
  }

  static Color _parseColor(String value) {
    final normalized = value.replaceFirst('#', '');
    final parsed = int.tryParse(normalized, radix: 16);
    return Color(0xFF000000 | (parsed ?? 0x2563EB));
  }
}
