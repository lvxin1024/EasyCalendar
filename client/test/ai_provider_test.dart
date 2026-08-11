import 'package:easy_calendar/ai/ai_key_store.dart';
import 'package:easy_calendar/ai/ai_provider.dart';
import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/data/local_item_repository.dart';
import 'package:easy_calendar/domain/item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('provider storage JSON never contains an API key', () {
    final config = AiProviderConfig(
      id: 'cloud-main',
      name: 'Cloud',
      kind: AiProviderKind.openaiCompatible,
      baseUrl: 'https://ai.example.com/v1',
      model: 'gpt-test',
      keyConfigured: true,
      requestParameters: const {'temperature': 0.2, 'api_key': 'nested-secret'},
    );

    expect(config.toStorageJson(), isNot(contains('api_key')));
    expect(config.toStorageJson(), isNot(contains('secret')));
    expect(config.toStorageJson(), contains('temperature'));
  });

  test('local preferences persist non-sensitive provider fields', () async {
    final repository = LocalItemRepository(
      _config,
      databaseFactory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await repository.initialize();
    addTearDown(repository.close);
    final provider = AiProviderConfig(
      id: 'local',
      name: 'Local Ollama',
      kind: AiProviderKind.ollama,
      baseUrl: 'http://localhost:11434',
      model: 'qwen',
    );
    await repository.savePreferences(
      _defaults.copyWith(assistantEnabled: true, aiProviders: [provider]),
    );

    final loaded = await repository.loadPreferences(_defaults);
    expect(loaded.assistantEnabled, isTrue);
    expect(loaded.aiProviders.single.model, 'qwen');
    expect(loaded.aiProviders.single.keyConfigured, isFalse);
  });

  test('secure provider key store clears provider-specific keys', () async {
    final store = _MemoryKeyStore();
    await store.write('cloud-main', 'top-secret');
    expect(await store.read('cloud-main'), 'top-secret');
    expect(await store.read('other'), isNull);
    await store.clear('cloud-main');
    expect(await store.read('cloud-main'), isNull);
  });
}

const _config = AppConfig(
  appName: 'EasyCalendar',
  locale: Locale('zh', 'CN'),
  timezone: 'Asia/Shanghai',
  defaultCollectionId: 'collection_local',
  defaultCollectionName: '我的日程',
  defaultCollectionColor: Color(0xFF2563EB),
  databaseName: 'test.sqlite3',
  deviceId: 'test-device',
  apiUrl: 'http://localhost:8000',
  syncEnabled: false,
  syncRetryLimit: 8,
  notificationsEnabled: false,
);

const _defaults = ClientPreferences(
  apiUrl: 'http://localhost:8000',
  syncEnabled: false,
  notificationsEnabled: false,
);

class _MemoryKeyStore implements AiApiKeyStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String providerId) async => values[providerId];

  @override
  Future<void> write(String providerId, String apiKey) async =>
      values[providerId] = apiKey;

  @override
  Future<void> clear(String providerId) async => values.remove(providerId);
}
