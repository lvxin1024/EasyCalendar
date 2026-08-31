import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../ai/ai_provider.dart';
import '../domain/item.dart';

class LocalPreferencesStore {
  const LocalPreferencesStore(this.database);

  final Database database;

  Future<ClientPreferences> load(ClientPreferences defaults) async {
    final rows = await database.query('app_settings');
    final values = {
      for (final row in rows) row['key'] as String: row['value'] as String,
    };
    return ClientPreferences(
      apiUrl: values['api_url'] ?? defaults.apiUrl,
      featureApiUrl: values['feature_api_url'] ?? defaults.featureApiUrl,
      timezone: values['timezone'] ?? defaults.timezone,
      localeName: values['locale_name'] ?? defaults.localeName,
      firstDayOfWeek: _storedFirstDayOfWeek(
        values['first_day_of_week'],
        defaults.firstDayOfWeek,
      ),
      clockFormat: _storedClockFormat(
        values['clock_format'],
        defaults.clockFormat,
      ),
      onboardingCompleted: values.containsKey('onboarding_completed')
          ? _storedBool(values['onboarding_completed'], false)
          : values.isNotEmpty,
      deviceId: values['device_id'] ?? defaults.deviceId,
      deviceName: values['device_name'] ?? defaults.deviceName,
      defaultCollectionId:
          values['default_collection_id'] ?? defaults.defaultCollectionId,
      defaultCollectionName:
          values['default_collection_name'] ?? defaults.defaultCollectionName,
      syncEnabled: _storedBool(values['sync_enabled'], defaults.syncEnabled),
      notificationsEnabled: _storedBool(
        values['notifications_enabled'],
        defaults.notificationsEnabled,
      ),
      windowOpacity: _storedOpacity(
        values['window_opacity'],
        defaults.windowOpacity,
      ),
      windowAlwaysOnTop: _storedBool(
        values['window_always_on_top'],
        defaults.windowAlwaysOnTop,
      ),
      assistantEnabled: _storedBool(
        values['assistant_enabled'],
        defaults.assistantEnabled,
      ),
      aiProviders: _storedProviders(
        values['ai_providers'],
        defaults.aiProviders,
      ),
      tagColors: _storedTagColors(values['tag_colors'], defaults.tagColors),
      widgetQuotes: _storedWidgetQuotes(
        values['widget_quotes'],
        defaults.widgetQuotes,
      ),
    );
  }

  Future<void> save(ClientPreferences preferences) async {
    await database.transaction((transaction) async {
      for (final entry in {
        'api_url': preferences.apiUrl.trim(),
        'feature_api_url': preferences.featureApiUrl.trim(),
        'timezone': preferences.timezone.trim(),
        'locale_name': preferences.localeName.trim(),
        'first_day_of_week': preferences.firstDayOfWeek.toString(),
        'clock_format': preferences.clockFormat.name,
        'onboarding_completed': preferences.onboardingCompleted
            ? 'true'
            : 'false',
        'device_id': preferences.deviceId.trim(),
        'device_name': preferences.deviceName.trim(),
        'default_collection_id': preferences.defaultCollectionId.trim(),
        'default_collection_name': preferences.defaultCollectionName.trim(),
        'sync_enabled': preferences.syncEnabled ? 'true' : 'false',
        'notifications_enabled': preferences.notificationsEnabled
            ? 'true'
            : 'false',
        'window_opacity': preferences.windowOpacity.toString(),
        'window_always_on_top': preferences.windowAlwaysOnTop
            ? 'true'
            : 'false',
        'assistant_enabled': preferences.assistantEnabled ? 'true' : 'false',
        'ai_providers': jsonEncode(
          preferences.aiProviders.map((provider) => provider.toJson()).toList(),
        ),
        'tag_colors': jsonEncode(preferences.tagColors),
        'widget_quotes': jsonEncode(
          preferences.widgetQuotes
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .take(10)
              .toList(growable: false),
        ),
      }.entries) {
        await transaction.insert('app_settings', {
          'key': entry.key,
          'value': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  static double _storedOpacity(String? value, double fallback) {
    final parsed = double.tryParse(value ?? '');
    return (parsed ?? fallback).clamp(0.2, 1.0).toDouble();
  }

  static List<String> _storedWidgetQuotes(
    String? value,
    List<String> fallback,
  ) {
    if (value == null) return fallback;
    try {
      return (jsonDecode(value) as List<dynamic>)
          .whereType<String>()
          .map((entry) => entry.trim())
          .where((entry) => entry.isNotEmpty)
          .take(10)
          .toList(growable: false);
    } catch (_) {
      return fallback;
    }
  }

  static int _storedFirstDayOfWeek(String? value, int fallback) {
    final parsed = int.tryParse(value ?? '');
    return parsed != null && parsed >= 0 && parsed <= 7 ? parsed : fallback;
  }

  static ClockFormat _storedClockFormat(String? value, ClockFormat fallback) {
    for (final format in ClockFormat.values) {
      if (format.name == value) return format;
    }
    return fallback;
  }

  static List<AiProviderConfig> _storedProviders(
    String? value,
    List<AiProviderConfig> fallback,
  ) {
    if (value == null || value.trim().isEmpty) return fallback;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) return fallback;
      return decoded
          .whereType<Map>()
          .map(
            (entry) =>
                AiProviderConfig.fromJson(Map<String, dynamic>.from(entry)),
          )
          .toList(growable: false);
    } catch (_) {
      return fallback;
    }
  }

  static Map<String, int> _storedTagColors(
    String? value,
    Map<String, int> fallback,
  ) {
    if (value == null || value.trim().isEmpty) return fallback;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return fallback;
      return decoded.map<String, int>((key, value) {
        final parsed = value is int ? value : int.tryParse('$value');
        if (parsed == null) throw const FormatException('invalid tag color');
        return MapEntry('$key', parsed);
      });
    } catch (_) {
      return fallback;
    }
  }

  static bool _storedBool(String? value, bool fallback) =>
      value == null ? fallback : value == 'true';
}
