import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class AiApiKeyStore {
  Future<String?> read(String providerId);
  Future<void> write(String providerId, String apiKey);
  Future<void> clear(String providerId);
}

class SecureAiApiKeyStore implements AiApiKeyStore {
  SecureAiApiKeyStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _key(String providerId) {
    final normalized = providerId.trim();
    if (normalized.isEmpty ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(normalized)) {
      throw ArgumentError.value(providerId, 'providerId');
    }
    return 'easycalendar_ai_api_key_$normalized';
  }

  @override
  Future<String?> read(String providerId) =>
      _storage.read(key: _key(providerId));

  @override
  Future<void> write(String providerId, String apiKey) {
    final value = apiKey.trim();
    if (value.isEmpty) throw ArgumentError.value(apiKey, 'apiKey');
    return _storage.write(key: _key(providerId), value: value);
  }

  @override
  Future<void> clear(String providerId) =>
      _storage.delete(key: _key(providerId));
}
