import 'dart:convert';

import '../ai/ai_provider.dart';
import '../domain/item.dart';

class PortableClientSettings {
  const PortableClientSettings({
    required this.apiUrl,
    required this.featureApiUrl,
    required this.timezone,
    required this.localeName,
    required this.firstDayOfWeek,
    required this.clockFormat,
    required this.syncEnabled,
    required this.notificationsEnabled,
    required this.windowOpacity,
    required this.windowAlwaysOnTop,
    required this.assistantEnabled,
    required this.aiProviders,
    required this.tagColors,
    this.widgetQuotes = defaultWidgetQuotes,
  });

  factory PortableClientSettings.decode(String content) {
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic> || decoded['schema_version'] != 1) {
      throw const FormatException('不支持的设置文件格式');
    }
    final settings = decoded['settings'];
    if (settings is! Map) throw const FormatException('设置内容必须是对象');
    final value = Map<String, dynamic>.from(settings);
    final rawProviders = value['ai_providers'];
    final rawColors = value['tag_colors'];
    if (rawProviders is! List || rawColors is! Map) {
      throw const FormatException('AI Provider 或标签颜色格式无效');
    }
    final providers = rawProviders
        .whereType<Map>()
        .map(
          (item) => AiProviderConfig.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false);
    final colors = <String, int>{};
    for (final entry in rawColors.entries) {
      if (entry.key is! String || entry.value is! int) {
        throw const FormatException('标签颜色格式无效');
      }
      colors[entry.key as String] = entry.value as int;
    }
    final clockName = _string(value, 'clock_format');
    final clockFormat = ClockFormat.values.where(
      (item) => item.name == clockName,
    );
    if (clockFormat.isEmpty) throw const FormatException('时间显示格式无效');
    final firstDay = _integer(value, 'first_day_of_week');
    final opacity = _number(value, 'window_opacity').clamp(0.2, 1).toDouble();
    if (firstDay < 0 || firstDay > 7) {
      throw const FormatException('每周起始日无效');
    }
    final apiUrl = _serviceUrl(value, 'api_url');
    final featureApiUrl = _serviceUrl(value, 'feature_api_url');
    return PortableClientSettings(
      apiUrl: apiUrl,
      featureApiUrl: featureApiUrl,
      timezone: _string(value, 'timezone'),
      localeName: _string(value, 'locale_name'),
      firstDayOfWeek: firstDay,
      clockFormat: clockFormat.single,
      syncEnabled: _boolean(value, 'sync_enabled'),
      notificationsEnabled: _boolean(value, 'notifications_enabled'),
      windowOpacity: opacity,
      windowAlwaysOnTop: _boolean(value, 'window_always_on_top'),
      assistantEnabled: _boolean(value, 'assistant_enabled'),
      aiProviders: providers,
      tagColors: colors,
      widgetQuotes: value.containsKey('widget_quotes')
          ? (value['widget_quotes'] as List<dynamic>? ?? const [])
                .whereType<String>()
                .map((entry) => entry.trim())
                .where((entry) => entry.isNotEmpty)
                .take(10)
                .toList(growable: false)
          : defaultWidgetQuotes,
    );
  }

  final String apiUrl;
  final String featureApiUrl;
  final String timezone;
  final String localeName;
  final int firstDayOfWeek;
  final ClockFormat clockFormat;
  final bool syncEnabled;
  final bool notificationsEnabled;
  final double windowOpacity;
  final bool windowAlwaysOnTop;
  final bool assistantEnabled;
  final List<AiProviderConfig> aiProviders;
  final Map<String, int> tagColors;
  final List<String> widgetQuotes;

  String encode() => jsonEncode({
    'schema_version': 1,
    'exported_at': DateTime.now().toUtc().toIso8601String(),
    'excluded': const [
      'device_id',
      'device_name',
      'default_collection_id',
      'sync_token',
      'feature_token',
      'ai_api_keys',
    ],
    'settings': {
      'api_url': apiUrl,
      'feature_api_url': featureApiUrl,
      'timezone': timezone,
      'locale_name': localeName,
      'first_day_of_week': firstDayOfWeek,
      'clock_format': clockFormat.name,
      'sync_enabled': syncEnabled,
      'notifications_enabled': notificationsEnabled,
      'window_opacity': windowOpacity,
      'window_always_on_top': windowAlwaysOnTop,
      'assistant_enabled': assistantEnabled,
      'ai_providers': aiProviders.map((provider) => provider.toJson()).toList(),
      'tag_colors': tagColors,
      'widget_quotes': widgetQuotes.take(10).toList(growable: false),
    },
  });

  static String _string(Map<String, dynamic> value, String key) {
    final result = value[key];
    if (result is! String) throw FormatException('$key 格式无效');
    return result.trim();
  }

  static String _serviceUrl(Map<String, dynamic> value, String key) {
    final result = _string(value, key);
    if (result.isEmpty) return result;
    final uri = Uri.tryParse(result);
    if (uri == null ||
        !uri.hasAuthority ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty) {
      throw FormatException('$key 必须是无内嵌凭据的 HTTP(S) 地址');
    }
    return result;
  }

  static int _integer(Map<String, dynamic> value, String key) {
    final result = value[key];
    if (result is! int) throw FormatException('$key 格式无效');
    return result;
  }

  static double _number(Map<String, dynamic> value, String key) {
    final result = value[key];
    if (result is! num) throw FormatException('$key 格式无效');
    return result.toDouble();
  }

  static bool _boolean(Map<String, dynamic> value, String key) {
    final result = value[key];
    if (result is! bool) throw FormatException('$key 格式无效');
    return result;
  }
}
