import 'dart:convert';

import 'package:easy_calendar/ai/ai_provider.dart';
import 'package:easy_calendar/data/settings_transfer.dart';
import 'package:easy_calendar/domain/item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('portable settings exclude device identity and every secret', () {
    const settings = PortableClientSettings(
      apiUrl: 'https://sync.example.com',
      featureApiUrl: 'https://core.example.com',
      timezone: 'Asia/Shanghai',
      localeName: 'zh-CN',
      firstDayOfWeek: 1,
      clockFormat: ClockFormat.hour24,
      syncEnabled: true,
      notificationsEnabled: true,
      windowOpacity: 0.9,
      windowAlwaysOnTop: false,
      assistantEnabled: true,
      aiProviders: [
        AiProviderConfig(
          id: 'cloud',
          name: 'Cloud',
          kind: AiProviderKind.openaiCompatible,
          baseUrl: 'https://ai.example.com/v1',
          model: 'model',
          keyConfigured: true,
          requestParameters: {
            'temperature': 0.2,
            'api_key': 'nested-secret',
            'headers': {'Authorization': 'Bearer hidden-header'},
          },
        ),
      ],
      tagColors: {'work': 0xFF0F766E},
    );

    final encoded = settings.encode();
    final decoded = PortableClientSettings.decode(encoded);
    final portable =
        (jsonDecode(encoded) as Map<String, dynamic>)['settings']
            as Map<String, dynamic>;

    expect(encoded, isNot(contains('nested-secret')));
    expect(encoded, isNot(contains('hidden-header')));
    expect(encoded, isNot(contains('device-')));
    expect(portable, isNot(contains('device_id')));
    expect(portable, isNot(contains('sync_token')));
    expect(portable, isNot(contains('feature_token')));
    expect(portable, isNot(contains('ai_api_keys')));
    expect(decoded.timezone, 'Asia/Shanghai');
    expect(decoded.aiProviders.single.temperature, 0.2);
    expect(decoded.aiProviders.single.keyConfigured, isFalse);
  });

  test('portable settings reject URLs with embedded credentials', () {
    final encoded =
        const PortableClientSettings(
          apiUrl: 'https://sync.example.com',
          featureApiUrl: '',
          timezone: 'system',
          localeName: 'system',
          firstDayOfWeek: 0,
          clockFormat: ClockFormat.system,
          syncEnabled: false,
          notificationsEnabled: false,
          windowOpacity: 1,
          windowAlwaysOnTop: false,
          assistantEnabled: false,
          aiProviders: [],
          tagColors: {},
        ).encode().replaceFirst(
          'https://sync.example.com',
          'https://user:secret@sync.example.com',
        );

    expect(() => PortableClientSettings.decode(encoded), throwsFormatException);
  });
}
