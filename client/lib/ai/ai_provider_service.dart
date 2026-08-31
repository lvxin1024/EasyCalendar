import 'ai_key_store.dart';
import 'ai_provider.dart';
import 'ai_provider_connection_tester.dart';

class AiProviderService {
  AiProviderService({
    AiApiKeyStore? keyStore,
    AiProviderConnectionTester? connectionTester,
  }) : _keyStore = keyStore ?? SecureAiApiKeyStore(),
       _connectionTester = connectionTester ?? AiProviderConnectionTester();

  final AiApiKeyStore _keyStore;
  final AiProviderConnectionTester _connectionTester;

  Future<List<AiProviderConfig>> refreshKeyStatus(
    List<AiProviderConfig> providers,
  ) async {
    final refreshed = <AiProviderConfig>[];
    for (final provider in providers) {
      bool configured = false;
      try {
        configured = (await _keyStore.read(provider.id))?.isNotEmpty == true;
      } catch (_) {
        // Secure storage is optional while running on unsupported test targets.
      }
      refreshed.add(provider.copyWith(keyConfigured: configured));
    }
    return List.unmodifiable(refreshed);
  }

  Future<AiProviderConfig> saveKey(
    AiProviderConfig provider, {
    String? apiKey,
    bool clearApiKey = false,
  }) async {
    final normalizedKey = apiKey?.trim() ?? '';
    if (clearApiKey && normalizedKey.isNotEmpty) {
      throw ArgumentError('Cannot replace and clear an AI API key together.');
    }
    if (clearApiKey) {
      await _keyStore.clear(provider.id);
    } else if (normalizedKey.isNotEmpty) {
      await _keyStore.write(provider.id, normalizedKey);
    }
    return provider.copyWith(
      keyConfigured: clearApiKey
          ? false
          : normalizedKey.isNotEmpty
          ? true
          : provider.keyConfigured,
    );
  }

  Future<void> clearKey(String providerId) => _keyStore.clear(providerId);

  Future<void> test(
    AiProviderConfig provider, {
    String pendingApiKey = '',
  }) async {
    final key = await _resolveKey(provider.id, pendingApiKey);
    await _connectionTester.test(provider, apiKey: key);
  }

  Future<List<String>> discoverModels(
    AiProviderConfig provider, {
    String pendingApiKey = '',
  }) async {
    final key = await _resolveKey(provider.id, pendingApiKey);
    return _connectionTester.discoverModels(provider, apiKey: key);
  }

  Future<String?> _resolveKey(String providerId, String pendingApiKey) async {
    final pending = pendingApiKey.trim();
    if (pending.isNotEmpty) return pending;
    try {
      return await _keyStore.read(providerId);
    } catch (_) {
      // Keyless and local providers remain usable without secure storage.
      return null;
    }
  }

  void close() => _connectionTester.close();
}
