import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../platform/secure_storage.dart';
import 'sync_group.dart';

abstract interface class SyncGroupProfileStore {
  Future<SyncGroupProfile?> read();

  Future<void> write(SyncGroupProfile profile);

  Future<void> clear();
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
  const SyncGroupSetupController(this.store);

  final SyncGroupProfileStore store;

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

  Future<SyncGroupProfile?> load() => store.read();

  Future<String?> exportCode() async => (await store.read())?.encode();

  Future<void> clear() => store.clear();
}
