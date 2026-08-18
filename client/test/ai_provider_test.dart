import 'package:easy_calendar/ai/ai_key_store.dart';
import 'package:easy_calendar/ai/ai_provider.dart';
import 'package:easy_calendar/ai/ai_provider_connection_tester.dart';
import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/data/local_item_repository.dart';
import 'package:easy_calendar/domain/item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('provider storage JSON never contains an API key', () {
    final config = AiProviderConfig(
      id: 'cloud-main',
      name: 'Cloud',
      kind: AiProviderKind.openaiCompatible,
      baseUrl: 'https://user:url-secret@ai.example.com/v1',
      model: 'gpt-test',
      keyConfigured: true,
      requestParameters: const {
        'temperature': 0.2,
        'request_timeout_seconds': 30,
        'retry_count': 1,
        'proxy_url': 'http://127.0.0.1:7890',
        'api_key': 'nested-secret',
        'headers': {
          'Authorization': 'Bearer nested-authorization',
          'X-Mode': 'safe',
        },
      },
    );

    expect(config.toStorageJson(), isNot(contains('api_key')));
    expect(config.toStorageJson(), isNot(contains('secret')));
    expect(config.toStorageJson(), isNot(contains('nested-authorization')));
    expect(config.toStorageJson(), isNot(contains('url-secret')));
    expect(config.toStorageJson(), contains('X-Mode'));
    expect(config.toStorageJson(), contains('temperature'));
    expect(config.requestTimeoutSeconds, 30);
    expect(config.retryCount, 1);
    expect(config.temperature, 0.2);
    expect(config.proxyUrl, 'http://127.0.0.1:7890');
    expect(config.payloadRequestParameters, isNot(contains('proxy_url')));
  });

  test('provider request settings use bounded defaults for invalid values', () {
    const config = AiProviderConfig(
      id: 'bounded',
      name: 'Bounded',
      kind: AiProviderKind.ollama,
      baseUrl: 'http://localhost:11434',
      model: 'qwen',
      requestParameters: {
        'request_timeout_seconds': 1,
        'retry_count': 99,
        'temperature': 5,
        'max_tokens': 0,
      },
    );

    expect(config.requestTimeoutSeconds, 5);
    expect(config.retryCount, 5);
    expect(config.temperature, 2);
    expect(config.maxTokens, 1);
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

  test(
    'provider connection test uses the pending key without storing it',
    () async {
      late String? authorization;
      final tester = AiProviderConnectionTester(
        client: MockClient((request) async {
          authorization = request.headers['authorization'];
          return http.Response('{"data":[]}', 200);
        }),
      );

      await tester.test(
        const AiProviderConfig(
          id: 'pending',
          name: 'Pending provider',
          kind: AiProviderKind.openaiCompatible,
          baseUrl: 'https://ai.example.com/v1',
          model: 'test-model',
        ),
        apiKey: 'unsaved-secret',
      );

      expect(authorization, 'Bearer unsaved-secret');
    },
  );

  test('provider connection test classifies authentication failures', () async {
    final tester = AiProviderConnectionTester(
      client: MockClient((_) async => http.Response('{}', 401)),
    );

    expect(
      () => tester.test(
        const AiProviderConfig(
          id: 'rejected',
          name: 'Rejected provider',
          kind: AiProviderKind.openaiCompatible,
          baseUrl: 'https://ai.example.com/v1',
          model: 'test-model',
        ),
        apiKey: 'wrong-secret',
      ),
      throwsA(
        isA<AiProviderProbeException>().having(
          (error) => error.kind,
          'kind',
          AiProviderProbeFailureKind.unauthorized,
        ),
      ),
    );
  });

  test('provider model discovery returns sorted OpenAI model ids', () async {
    final tester = AiProviderConnectionTester(
      client: MockClient(
        (_) async => http.Response(
          '{"data":[{"id":"z-model"},{"id":"a-model"},{"id":"a-model"}]}',
          200,
        ),
      ),
    );

    final models = await tester.discoverModels(
      const AiProviderConfig(
        id: 'models',
        name: 'Models provider',
        kind: AiProviderKind.openaiCompatible,
        baseUrl: 'https://ai.example.com/v1',
        model: 'manual-fallback',
      ),
      apiKey: 'pending-secret',
    );

    expect(models, ['a-model', 'z-model']);
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
