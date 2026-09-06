import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../platform/secure_storage.dart';
import 'sync_group.dart';

abstract interface class SyncGroupProfileStore {
  Future<SyncGroupProfile?> read();

  Future<void> write(SyncGroupProfile profile);

  Future<void> clear();
}

abstract interface class SyncEndpointIdentityStore {
  Future<String?> read();

  Future<void> write(String endpointId);

  Future<void> clear();
}

class SecureSyncEndpointIdentityStore implements SyncEndpointIdentityStore {
  SecureSyncEndpointIdentityStore({FlutterSecureStorage? storage})
    : _storage = storage ?? easyCalendarSecureStorage;

  static const _key = 'easycalendar_sync_endpoint_id';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() async {
    final value = await _storage.read(key: _key);
    final normalized = value?.trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }

  @override
  Future<void> write(String endpointId) =>
      _storage.write(key: _key, value: endpointId.trim());

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class SecureSyncGroupProfileStore implements SyncGroupProfileStore {
  SecureSyncGroupProfileStore({FlutterSecureStorage? storage})
    : _storage = storage ?? easyCalendarSecureStorage;

  static const _key = 'easycalendar_sync_group_code';
  final FlutterSecureStorage _storage;

  @override
  Future<SyncGroupProfile?> read() async {
    final encoded = await _storage.read(key: _key);
    if (encoded == null || encoded.trim().isEmpty) return null;
    return SyncGroupCode.decode(encoded);
  }

  @override
  Future<void> write(SyncGroupProfile profile) =>
      _storage.write(key: _key, value: profile.encode());

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class SyncGroupSetupController {
  SyncGroupSetupController(
    this.store, {
    SyncEndpointIdentityStore? endpointIdentityStore,
    Uuid? uuid,
  }) : endpointIdentityStore =
           endpointIdentityStore ?? SecureSyncEndpointIdentityStore(),
       _uuid = uuid ?? Uuid();

  final SyncGroupProfileStore store;
  final SyncEndpointIdentityStore endpointIdentityStore;
  final Uuid _uuid;

  Future<String> ensureLocalEndpointId({
    required String fallbackDeviceId,
  }) async {
    final existing = await endpointIdentityStore.read();
    if (existing != null && _validEndpointId(existing)) return existing;
    final fallback = fallbackDeviceId.trim();
    final endpointId = _validEndpointId(fallback)
        ? fallback
        : 'endpoint-${_uuid.v4()}';
    await endpointIdentityStore.write(endpointId);
    return endpointId;
  }

  Future<SyncGroupProfile> createPrimary({
    required String primaryEndpointId,
    required String endpointTicket,
    SyncRelayMode relayMode = SyncRelayMode.publicBestEffort,
    List<String> relayUrls = const [],
    int topologyEpoch = 1,
  }) async {
    final profile = SyncGroupProfile.createPrimary(
      primaryEndpointId: primaryEndpointId,
      endpointTicket: endpointTicket,
      relayMode: relayMode,
      relayUrls: relayUrls,
      topologyEpoch: topologyEpoch,
    );
    await store.write(profile);
    return profile;
  }

  Future<SyncGroupProfile> join({
    required String code,
    required String localEndpointId,
  }) async {
    final advertised = SyncGroupCode.decode(code);
    final profile = SyncGroupProfile.fromSecret(
      groupSecret: advertised.groupSecret,
      role: SyncGroupRole.replica,
      primaryEndpointId: advertised.primaryEndpointId,
      endpointTicket: advertised.endpointTicket,
      relayMode: advertised.relayMode,
      relayUrls: advertised.relayUrls,
      topologyEpoch: advertised.topologyEpoch,
    );
    if (localEndpointId.trim() == profile.primaryEndpointId) {
      throw const FormatException('从节点 endpoint ID 不能与主节点相同');
    }
    await store.write(profile);
    return profile;
  }

  Future<SyncGroupProfile> joinAutomatically({
    required String code,
    required String fallbackDeviceId,
  }) async {
    final endpointId = await ensureLocalEndpointId(
      fallbackDeviceId: fallbackDeviceId,
    );
    return join(code: code, localEndpointId: endpointId);
  }

  Future<SyncGroupProfile?> load() => store.read();

  Future<String?> exportCode() async => (await store.read())?.encode();

  Future<void> clear() => store.clear();

  static bool _validEndpointId(String value) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{1,199}$').hasMatch(value.trim());
}
